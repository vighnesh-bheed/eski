package label

import vf "../vfilter"

Accept_Proc :: #type proc(ctx: rawptr, slot: u32) -> bool

Attribute_Proc :: #type proc(ctx: rawptr, slot: u32) -> ^vf.Attribute

Gate :: struct {
	visibility: ^Visibility,
	labels:     []Id,
}

Filter_Gate :: struct {
	gate:          Gate,
	program:       ^vf.Program,
	attribute:     Attribute_Proc,
	attribute_ctx: rawptr,
}

gate_make :: proc "contextless" (v: ^Visibility, labels: []Id) -> Gate {
	return Gate{visibility = v, labels = labels}
}

gate_admits :: #force_inline proc "contextless" (g: ^Gate, slot: u32) -> bool #no_bounds_check {
	if int(slot) >= len(g.labels) {
		return false
	}
	return visible(g.visibility, g.labels[slot])
}

gate_accept :: proc(ctx: rawptr, slot: u32) -> bool {
	return gate_admits((^Gate)(ctx), slot)
}

filter_gate_make :: proc "contextless" (g: Gate, program: ^vf.Program, attribute: Attribute_Proc, attribute_ctx: rawptr) -> Filter_Gate {
	return Filter_Gate{gate = g, program = program, attribute = attribute, attribute_ctx = attribute_ctx}
}

filter_gate_accept :: proc(ctx: rawptr, slot: u32) -> bool {
	f := (^Filter_Gate)(ctx)
	if !gate_admits(&f.gate, slot) {
		return false
	}
	if f.program == nil {
		return true
	}
	if f.attribute == nil {
		return false
	}
	return vf.evaluate(f.program, f.attribute(f.attribute_ctx, slot))
}

slice_attribute :: proc(ctx: rawptr, slot: u32) -> ^vf.Attribute {
	attributes := (^[]vf.Attribute)(ctx)
	if int(slot) >= len(attributes) {
		return nil
	}
	return &attributes[slot]
}
