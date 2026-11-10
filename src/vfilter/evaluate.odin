package vfilter

STACK_INLINE :: 64

program_execute :: proc(program: ^Program, blob: []u8, stack: []Value) -> bool #no_bounds_check {
	sp := 0
	for instruction in program.code {
		switch instruction.op {
		case .Push:
			stack[sp] = program.constants[instruction.arg]
			sp += 1
		case .Load:
			value, found := attribute_lookup(blob, program.fields[instruction.arg])
			if !found {
				return false
			}
			stack[sp] = value
			sp += 1
		case .Not:
			stack[sp - 1] = bool_value(!value_truthy(stack[sp - 1]))
		case .Pow, .Mul, .Div, .Mod, .Add, .Sub, .Gt, .Ge, .Lt, .Le, .Eq, .Ne, .In, .And, .Or:
			sp -= 1
			stack[sp - 1] = apply_binary(instruction.op, stack[sp - 1], stack[sp])
		}
	}
	return value_truthy(stack[0])
}

program_run :: proc(program: ^Program, blob: []u8) -> bool {
	if len(program.code) == 0 || program.depth <= 0 {
		return false
	}
	if program.depth <= STACK_INLINE {
		stack: [STACK_INLINE]Value = ---
		return program_execute(program, blob, stack[:])
	}
	stack, err := make([]Value, program.depth)
	if err != nil {
		return false
	}
	defer delete(stack)
	return program_execute(program, blob, stack)
}

program_run_constant :: proc(program: ^Program) -> bool {
	return program_run(program, nil)
}

evaluate :: proc(program: ^Program, attribute: ^Attribute) -> bool {
	if attribute == nil {
		return false
	}
	if program.constant {
		return program.result && len(program.code) > 0
	}
	return program_run(program, attribute.blob)
}

program_reads_fields :: proc "contextless" (program: ^Program) -> bool {
	return len(program.fields) > 0
}
