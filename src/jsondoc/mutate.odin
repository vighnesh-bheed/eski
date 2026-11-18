package jsondoc

import "core:math"
import "core:mem"
import "core:slice"

MISSING_KEY :: "ERR could not perform this operation on a key that doesn't exist"
ROOT_REQUIRED :: "ERR new objects must be created at the root"
NOT_ARRAY :: "ERR Path does not exist or not an array"
NOT_OBJECT :: "ERR Path does not exist or not an object"
NOT_STRING :: "ERR Path does not exist or not a string"
NOT_BOOL :: "ERR Path does not exist or not a bool"
NOT_NUMBER :: "ERR Path does not exist or does not contains a number"
WRONG_STRING :: "WRONGTYPE wrong type of path value - expected string"
WRONG_ARRAY :: "WRONGTYPE wrong type of path value - expected array"
WRONG_OBJECT :: "WRONGTYPE wrong type of path value - expected object"
STATIC_PATH :: "Err wrong static path"
ARRAY_RANGE :: "ERR array index out of range"

Condition :: enum {
	None, NX, XX,
}

Outcome :: struct {
	reply: Reply,
	changed: bool,
}

type_error :: proc(text: string, changed := false) -> Outcome {
	return {reply_error(text), changed}
}

Retirement :: struct {
	values: [dynamic]^Value,
	old: [dynamic]Data,
}

retirement_init :: proc(r: ^Retirement, allocator: mem.Allocator) {
	r.values.allocator = allocator
	r.old.allocator = allocator
}

retirement_finish :: proc(r: ^Retirement, allocator: mem.Allocator) {
	for v in r.values {
		release(v, allocator)
	}
	for data in r.old {
		release_data(data, allocator)
	}
	delete(r.values)
	delete(r.old)
}

retirement_room :: proc(r: ^Retirement, count: int) -> string {
	if count > MAX_ITEMS - len(r.values) {
		return SIZE_LIMIT
	}
	if reserve(&r.values, counts_capacity(len(r.values) + count, cap(r.values))) != nil {
		return OUT_OF_MEMORY
	}
	return ""
}

retire_value :: proc(r: ^Retirement, value: ^Value) {
	value.detached = true
	append(&r.values, value)
}

retire_replace :: proc(r: ^Retirement, v, next: ^Value, allocator: mem.Allocator) -> string {
	_, err := append(&r.old, v.data)
	if err != nil {
		return OUT_OF_MEMORY
	}
	#partial switch old in v.data {
	case ^Array:
		for child in old.items {
			child.detached = true
		}
	case ^Object:
		for m in old.members {
			m.value.detached = true
		}
	}
	v.data = nil
	replace(v, next, allocator)
	return ""
}

attached :: proc(v: ^Value) -> bool {
	for node := v; node != nil; node = node.parent {
		if node.detached {
			return false
		}
	}
	return true
}

validate_set :: proc(root: ^Value, path: Path) -> string {
	if path.expr == nil {
		return PATH_MISSING
	}
	if path.expr.kind != .Selector {
		return PROJECTION_ERROR
	}
	if root == nil && len(path.expr.steps) > 0 {
		return ROOT_REQUIRED
	}
	return ""
}

static_step :: proc(step: Step) -> bool {
	return !step.descend && (step.kind == .Name || step.kind == .Index)
}

set_value :: proc(doc: ^Document, path: Path, source: ^Value, condition: Condition, merge: bool, allocator: mem.Allocator) -> Outcome {
	err := validate_set(doc.root, path)
	if err != "" {
		return type_error(err)
	}
	if doc.root == nil {
		if condition == .XX {
			return {}
		}
		doc.root = clone(source, doc.allocator)
		if doc.root == nil {
			return type_error(OUT_OF_MEMORY)
		}
		return {reply_status("OK"), true}
	}

	e := path.expr
	result, selection_error := select_path(doc.root, path, allocator)
	if selection_error != "" {
		return type_error(selection_error)
	}
	steps := e.steps[:]
	is_static := true
	for step in steps {
		is_static = is_static && static_step(step)
	}
	if !is_static && condition == .NX {
		return type_error(STATIC_PATH)
	}
	if len(result.matches) == 0 {
		if condition == .XX && is_static {
			return {}
		}
		if !is_static {
			return type_error(STATIC_PATH)
		}
		if len(steps) == 0 {
			return {}
		}
		return create_at_path(doc, steps, source, condition, merge, allocator)
	}
	if condition == .NX {
		return {}
	}
	r: Retirement
	retirement_init(&r, allocator)
	defer retirement_finish(&r, doc.allocator)
	patch_depth := depth(source)
	for match in result.matches {
		if patch_depth + parent_depth(match.value) > MAX_DEPTH {
			return {}
		}
		if merge && !path.legacy && as_array(match.parent) != nil {
			return type_error("ERR bad object type")
		}
	}
	if merge {
		return merge_matches(doc, result.matches[:], source, &r, allocator)
	}
	changed := false
	for match in result.matches {
		target := match.value
		if !attached(target) {
			continue
		}
		replacement := clone(source, doc.allocator)
		if replacement == nil {
			return type_error(OUT_OF_MEMORY, changed)
		}
		if replace_error := retire_replace(&r, target, replacement, doc.allocator); replace_error != "" {
			release(replacement, doc.allocator)
			return type_error(replace_error, changed)
		}
		changed = true
	}
	return {reply_status("OK"), changed}
}

create_at_path :: proc(doc: ^Document, steps: []Step, source: ^Value, condition: Condition, merge: bool, allocator: mem.Allocator) -> Outcome {
	last := steps[len(steps)-1]
	ev := Evaluation{root = doc.root, allocator = allocator}
	parents := eval_selector(&ev, doc.root, steps[:len(steps)-1])
	if ev.error != "" {
		return type_error(ev.error)
	}
	if len(parents.matches) != 1 {
		return {}
	}
	parent := parents.matches[0].value
	if last.kind == .Index {
		return type_error(ARRAY_RANGE)
	}
	if as_object(parent) == nil || condition == .XX || depth(source) + parent_depth(parent) + 1 > MAX_DEPTH {
		return {}
	}
	name, copied := copy_text(last.name, doc.allocator)
	if !copied {
		return type_error(OUT_OF_MEMORY)
	}
	item, item_error := merged_value(source, merge, doc.allocator)
	if item_error != "" {
		free_text(name, doc.allocator)
		return type_error(item_error)
	}
	err := object_add(parent, name, item, doc.allocator)
	if err != "" {
		free_text(name, doc.allocator)
		release(item, doc.allocator)
		return type_error(err)
	}
	return {reply_status("OK"), true}
}

Merge_Relation :: enum u8 {
	Independent, Has_Ancestor, Has_Descendant,
}

merge_matches :: proc(doc: ^Document, matches: []Match, source: ^Value, retirement: ^Retirement, allocator: mem.Allocator) -> Outcome {
	relations: map[^Value]Merge_Relation
	if len(matches) > 1 {
		var, err := make(map[^Value]Merge_Relation, len(matches), allocator)
		if err != nil {
			return type_error(OUT_OF_MEMORY)
		}
		relations = var
		for m in matches {
			if map_insert(&relations, m.value, .Independent) == nil {
				return type_error(OUT_OF_MEMORY)
			}
		}
		for m in matches {
			for parent := m.parent; parent != nil; parent = parent.parent {
				if _, selected := relations[parent]; selected {
					relations[parent] = .Has_Descendant
					if relations[m.value] == .Independent {
						relations[m.value] = .Has_Ancestor
					}
				}
			}
		}
	}
	changed := false
	for m in matches {
		relation := relations[m.value]
		if relation == .Has_Descendant {
			continue
		}
		if relation == .Independent && as_object(m.value) != nil && as_object(source) != nil {
			patch_changed, err := apply_object_patch(m.value, as_object(source), retirement, doc.allocator)
			changed = changed || patch_changed
			if err != "" {
				return type_error(err, changed)
			}
		} else {
			replacement, err := merged_value(source, relation == .Independent, doc.allocator)
			if err != "" {
				return type_error(err, changed)
			}
			if replace_error := retire_replace(retirement, m.value, replacement, doc.allocator); replace_error != "" {
				release(replacement, doc.allocator)
				return type_error(replace_error, changed)
			}
		}
		changed = true
	}
	return {reply_status("OK"), changed}
}

merged_value :: proc(source: ^Value, merge: bool, allocator: mem.Allocator) -> (^Value, string) {
	out: ^Value
	if patch := as_object(source); merge && patch != nil {
		out = make_object(allocator)
		if out == nil {
			return nil, OUT_OF_MEMORY
		}
		retirement: Retirement
		retirement_init(&retirement, allocator)
		defer retirement_finish(&retirement, allocator)
		if _, err := apply_object_patch(out, patch, &retirement, allocator); err != "" {
			release(out, allocator)
			return nil, err
		}
	} else {
		out = clone(source, allocator)
		if out == nil {
			return nil, OUT_OF_MEMORY
		}
	}
	return out, ""
}

apply_object_patch :: proc(value: ^Value, patch: ^Object, retirement: ^Retirement, allocator: mem.Allocator) -> (bool, string) {
	current := as_object(value)
	changed := false
	for member in patch.members {
		index := object_index(current, member.name)
		if _, is_null := member.value.data.(Null); is_null {
			if index >= 0 {
				if err := retirement_room(retirement, 1); err != "" {
					return changed, err
				}
				retire_value(retirement, object_remove(value, index, allocator))
				changed = true
			}
			continue
		}
		if index >= 0 {
			prev := current.members[index].value
			if child_patch := as_object(member.value); as_object(prev) != nil && child_patch != nil {
				child_changed, err := apply_object_patch(prev, child_patch, retirement, allocator)
				changed = changed || child_changed
				if err != "" {
					return changed, err
				}
				continue
			}
			replacement, err := merged_value(member.value, true, allocator)
			if err != "" {
				return changed, err
			}
			if replace_error := retire_replace(retirement, prev, replacement, allocator); replace_error != "" {
				release(replacement, allocator)
				return changed, replace_error
			}
		} else {
			part, err := merged_value(member.value, true, allocator)
			if err != "" {
				return changed, err
			}
			name, ok := copy_text(member.name, allocator)
			if !ok {
				release(part, allocator)
				return changed, OUT_OF_MEMORY
			}
			if add_error := object_add(value, name, part, allocator); add_error != "" {
				free_text(name, allocator)
				release(part, allocator)
				return changed, add_error
			}
		}
		changed = true
	}
	return changed, ""
}

array_clear :: proc(v: ^Value, a: ^Array, retirement: ^Retirement) -> string {
	if err := retirement_room(retirement, len(a.items)); err != "" {
		return err
	}
	delta := 0
	for item in a.items {
		delta -= item.charge
		retire_value(retirement, item)
	}
	clear(&a.items)
	adjust_charge(v, delta)
	return ""
}

clear_values :: proc(doc: ^Document, matches: []Match, allocator: mem.Allocator) -> Outcome {
	retirement: Retirement
	retirement_init(&retirement, allocator)
	defer retirement_finish(&retirement, doc.allocator)
	count: i64
	for match in matches {
		node := match.value
		if !attached(node) {
			return type_error(PATH_MISSING, count != 0)
		}
		#partial switch data in node.data {
		case ^Array:
			if len(data.items) > 0 {
				if err := array_clear(node, data, &retirement); err != "" {
					return type_error(err, count != 0)
				}
				count += 1
			}
		case ^Object:
			if len(data.members) > 0 {
				if err := retirement_room(&retirement, len(data.members)); err != "" {
					return type_error(err, count != 0)
				}
				for len(data.members) > 0 {
					item := object_remove(node, len(data.members)-1, doc.allocator)
					retire_value(&retirement, item)
				}
				count += 1
			}
		case i64, u64, f64:
			n, _ := number(node)
			if n != 0 {
				set_scalar(node, i64(0))
				count += 1
			}
		}
	}
	return {reply_integer(count), count != 0}
}

set_scalar :: proc(v: ^Value, data: Data) {
	adjust_charge(v, local_charge(data) - local_charge(v.data))
	v.narrow = .Normal
	v.data = data
}

delete_values :: proc(doc: ^Document, matches: []Match, shifting: bool, allocator: mem.Allocator) -> Outcome {
	retirement: Retirement
	retirement_init(&retirement, allocator)
	defer retirement_finish(&retirement, doc.allocator)
	if err := retirement_room(&retirement, len(matches)); err != "" {
		return type_error(err)
	}
	count: i64
	for i := 0; i < len(matches); {
		match := matches[i]
		node, parent := match.value, match.parent
		i += 1
		if parent == nil {
			destroy(doc)
			return {reply_integer(1), true}
		}
		if !attached(parent) {
			continue
		}
		if o := as_object(parent); o != nil {
			if attached(node) {
				if index := object_index(o, match.name); index >= 0 {
					retire_value(&retirement, object_remove(parent, index, doc.allocator))
					count += 1
				}
			}
		} else if a := as_array(parent); a != nil {
			start := i-1
			for i < len(matches) && matches[i].parent == parent {
				i += 1
			}
			group := matches[start:i]
			count += i64(delete_array_group(parent, a, group, shifting, &retirement))
		}
	}

	if n, container := value_length(doc.root); count > 0 && container && n == 0 && is_container(doc.root) {
		destroy(doc)
	}
	return {reply_integer(count), count != 0}
}

delete_array_group :: proc(parent: ^Value, a: ^Array, targets: []Match, shifting: bool, retirement: ^Retirement) -> int {
	if shifting {
		slice.sort_by(targets, proc(a, b: Match) -> bool { return a.index > b.index })
		count := 0
		for target in targets {
			if target.index < len(a.items) {
				retire_value(retirement, array_remove(parent, target.index))
				count += 1
			}
		}
		return count
	}
	direct := true
	previous := -1
	for target in targets {
		if target.index <= previous || target.index >= len(a.items) || a.items[target.index] != target.value {
			direct = false
			break
		}
		previous = target.index
	}
	if !direct {
		count := 0
		for target in targets {
			if attached(target.value) {
				for index := min(target.index, len(a.items)-1); index >= 0; index -= 1 {
					if a.items[index] == target.value {
						retire_value(retirement, array_remove(parent, index))
						count += 1
						break
					}
				}
			}
		}
		return count
	}
	write := targets[0].index
	read := write
	delta := 0
	for target in targets {
		write += copy(a.items[write:], a.items[read:target.index])
		delta -= target.value.charge
		retire_value(retirement, target.value)
		read = target.index+1
	}
	write += copy(a.items[write:], a.items[read:])
	resize(&a.items, write)
	adjust_charge(parent, delta)
	return len(targets)
}

array_insert :: proc(node: ^Value, array: ^Array, index: int, values: []^Value, allocator, scratch: mem.Allocator) -> string {
	count := len(values)
	if count > MAX_ITEMS - len(array.items) {
		return SIZE_LIMIT
	}
	child_depth := parent_depth(node) + 1
	for value in values {
		if child_depth + depth(value) > MAX_DEPTH {
			return DEPTH_LIMIT
		}
	}
	staged, err := make([]^Value, count, scratch)
	if err != nil {
		return OUT_OF_MEMORY
	}
	defer delete(staged, scratch)
	for value, i in values {
		staged[i] = clone(value, allocator)
		if staged[i] == nil {
			for v in staged[:i] {
				release(v, allocator)
			}
			return OUT_OF_MEMORY
		}
	}
	previous := len(array.items)
	if reserve(&array.items, counts_capacity(previous+count, cap(array.items))) != nil {
		for v in staged {
			release(v, allocator)
		}
		return OUT_OF_MEMORY
	}
	append(&array.items, ..staged)
	copy(array.items[index+count:], array.items[index:previous])
	copy(array.items[index:index+count], staged)
	delta := 0
	for value in staged {
		value.parent = node
		delta += value.charge
	}
	node.narrow = .Normal
	adjust_charge(node, delta)
	return ""
}

array_trim :: proc(node: ^Value, array: ^Array, low, high: i64, retirement: ^Retirement) -> string {
	length := len(array.items)
	start := relative_index(low, length)
	stop := min(length, relative_index(high, length)+1)
	if start >= stop {
		return array_clear(node, array, retirement)
	}
	if err := retirement_room(retirement, length-stop+start); err != "" {
		return err
	}
	delta := 0
	for index in 0 ..< start {
		value := array.items[index]
		delta -= value.charge
		retire_value(retirement, value)
	}
	for index in stop ..< length {
		value := array.items[index]
		delta -= value.charge
		retire_value(retirement, value)
	}
	copy(array.items[:], array.items[start:stop])
	resize(&array.items, stop-start)
	adjust_charge(node, delta)
	return ""
}

update_number :: proc(v, argument: ^Value, op: Operation) -> (bool, string) {
	x, x_ok := number(v)
	y, y_ok := number(argument)
	if !x_ok || !y_ok {
		return false, ""
	}
	a, a_signed := v.data.(i64)
	b, b_signed := argument.data.(i64)
	if a_signed && b_signed {
		n: i128
		if op == .Num_Incr {
			n = i128(a) + i128(b)
		} else if op == .Num_Mult {
			n = i128(a) * i128(b)
		} else {
			exact, ok := integer_power(a, b)
			if !ok {
				return false, "ERR numeric overflow"
			}
			n = i128(exact)
		}
		if n < i128(min(i64)) || n > i128(max(i64)) {
			return false, "ERR numeric overflow"
		}
		set_scalar(v, i64(n))
		return true, ""
	}
	n: f64
	if op == .Num_Incr {
		n = x + y
	} else if op == .Num_Mult {
		n = x * y
	} else {
		n = math.pow(x, y)
	}
	if math.is_inf(n) || math.is_nan(n) {
		return false, "ERR result is not a number"
	}
	set_scalar(v, n)
	return true, ""
}

integer_power :: proc(a, b: i64) -> (i64, bool) {
	if b < 0 {
		return 0, false
	}
	base, result := i128(a), i128(1)
	exp := b
	for exp != 0 {
		if exp & 1 != 0 {
			result *= base
			if result > i128(max(i64)) || result < i128(min(i64)) {
				return 0, false
			}
		}
		exp >>= 1
		if exp != 0 {
			base *= base
			if base > i128(max(i64)) {
				return 0, false
			}
		}
	}
	return i64(result), true
}
