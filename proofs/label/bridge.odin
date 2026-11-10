package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import hn "../../src/hnsw"
import lb "../../src/label"
import vf "../../src/vfilter"

nat :: proc(s: string) -> int {
	v, ok := strconv.parse_i64(s, 10)
	assert(ok && v >= 0)
	return int(v)
}

big :: proc(s: string) -> u64 {
	v, ok := strconv.parse_u64(s, 10)
	assert(ok)
	return v
}

integer :: proc(s: string) -> i64 {
	v, ok := strconv.parse_i64(s, 10)
	assert(ok)
	return v
}

unhex :: proc(s: string) -> []u8 {
	if s == "-" {
		return nil
	}
	assert(len(s) % 2 == 0)
	out := make([]u8, len(s) / 2)
	for i in 0 ..< len(out) {
		v, ok := strconv.parse_u64(s[2 * i:2 * i + 2], 16)
		assert(ok)
		out[i] = u8(v)
	}
	return out
}

write_hex :: proc(b: ^strings.Builder, bytes: []u8) {
	if len(bytes) == 0 {
		strings.write_byte(b, '-')
		return
	}
	for x in bytes {
		fmt.sbprintf(b, "%02x", x)
	}
}

ids_list :: proc(s: string) -> [dynamic]int {
	out := make([dynamic]int)
	if s == "-" {
		return out
	}
	parts := strings.split(s, ",")
	defer delete(parts)
	for p in parts {
		append(&out, nat(p))
	}
	return out
}

label_of :: proc(s: string) -> lb.Label {
	parts := strings.split(s, ":")
	defer delete(parts)
	assert(len(parts) == 2)
	ids := ids_list(parts[1])
	defer delete(ids)
	l, ok := lb.label_make(nat(parts[0]), ..ids[:])
	assert(ok)
	return l
}

write_label :: proc(b: ^strings.Builder, l: lb.Label) {
	fmt.sbprintf(b, "%d:", l.level)
	first := true
	for c := lb.compartment_next(l, 0); c < lb.COMPARTMENT_LIMIT; c = lb.compartment_next(l, c + 1) {
		if !first {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%d", c)
		first = false
	}
	if first {
		strings.write_byte(b, '-')
	}
}

write_bool :: proc(b: ^strings.Builder, v: bool) {
	strings.write_byte(b, '1' if v else '0')
}

config_error :: proc(e: lb.Config_Error) -> string {
	switch e {
	case .None:
		return "ok"
	case .Empty_Name:
		return "empty"
	case .Name_Too_Long:
		return "toolong"
	case .Invalid_Name:
		return "invalid"
	case .Duplicate_Name:
		return "duplicate"
	case .Too_Many_Levels:
		return "toomanylevels"
	case .Too_Many_Compartments:
		return "toomanycomps"
	case .Out_Of_Memory:
		return "oom"
	}
	return "?"
}

parse_error :: proc(e: lb.Parse_Error) -> string {
	switch e {
	case .None:
		return "ok"
	case .Empty:
		return "empty"
	case .Too_Long:
		return "toolong"
	case .Invalid_Byte:
		return "invalidbyte"
	case .Empty_Level:
		return "emptylevel"
	case .Unknown_Level:
		return "unknownlevel"
	case .Bad_Separator:
		return "badseparator"
	case .Empty_Compartment:
		return "emptycomp"
	case .Unknown_Compartment:
		return "unknowncomp"
	case .Duplicate_Compartment:
		return "dupcomp"
	}
	return "?"
}

codec_error :: proc(e: lb.Codec_Error) -> string {
	#partial switch e {
	case .Truncated:
		return "truncated"
	case .Bad_Magic:
		return "badmagic"
	case .Bad_Version:
		return "badversion"
	case .Bad_Level_Count:
		return "badlevelcount"
	case .Bad_Compartment_Count:
		return "badcompcount"
	case .Bad_Name:
		return "badname"
	case .Duplicate_Name:
		return "dupname"
	case .Bad_Label_Count:
		return "badlabelcount"
	case .Bad_Level:
		return "badlevel"
	case .Bad_Compartment:
		return "badcomp"
	case .Not_Bottom:
		return "notbottom"
	case .Duplicate_Label:
		return "duplabel"
	case .Trailing:
		return "trailing"
	}
	return "?"
}

write_verdict :: proc(v: lb.Write_Verdict) -> string {
	switch v {
	case .Allowed:
		return "allowed"
	case .Above_Clearance:
		return "above"
	case .Write_Down:
		return "down"
	}
	return "?"
}

modify_verdict :: proc(v: lb.Modify_Verdict) -> string {
	switch v {
	case .Allowed:
		return "allowed"
	case .Not_Visible:
		return "hidden"
	case .Write_Down:
		return "down"
	}
	return "?"
}

counter_error :: proc(e: lb.Error) -> string {
	#partial switch e {
	case .None:
		return "ok"
	case .Overflow:
		return "overflow"
	case .Underflow:
		return "underflow"
	case .Invalid_Label:
		return "invalid"
	}
	return "?"
}

write_vis :: proc(b: ^strings.Builder, v: ^lb.Visibility) {
	fmt.sbprintf(b, "V|%d|", v.built)
	if len(v.words) == 0 {
		strings.write_byte(b, '-')
		return
	}
	for w, i in v.words {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%x", w)
	}
}

Spec_Attributes :: struct {
	spec:       string,
	attributes: []vf.Attribute,
}

spec_attribute :: proc(ctx: rawptr, slot: u32) -> ^vf.Attribute {
	a := (^Spec_Attributes)(ctx)
	if int(slot) >= len(a.spec) || a.spec[slot] == 'n' {
		return nil
	}
	return &a.attributes[slot]
}

Line :: struct {
	points: []i64,
	query:  i64,
}

line_distance :: proc(ctx: rawptr, a, b: u32) -> f32 {
	l := (^Line)(ctx)
	d := f32(l.points[a] - l.points[b])
	return d * d
}

line_query :: proc(ctx: rawptr, slot: u32) -> f32 {
	l := (^Line)(ctx)
	d := f32(l.points[slot] - l.query)
	return d * d
}

gate_row :: proc(b: ^strings.Builder, v: ^lb.Visibility, ids_text: string, spec: string, program: ^vf.Program) {
	ids := ids_list(ids_text)
	defer delete(ids)
	labels := make([]lb.Id, len(ids))
	defer delete(labels)
	for id, i in ids {
		labels[i] = lb.Id(id)
	}
	attributes := make([]vf.Attribute, len(spec))
	defer {
		for &a in attributes {
			vf.attribute_destroy(&a)
		}
		delete(attributes)
	}
	for i in 0 ..< len(spec) {
		switch spec[i] {
		case 'p':
			attributes[i], _ = vf.attribute_make(`{"f":1}`)
		case 'f':
			attributes[i], _ = vf.attribute_make(`{"f":0}`)
		case 'm':
			attributes[i], _ = vf.attribute_make(`{"g":1}`)
		}
	}
	ctx := Spec_Attributes{spec, attributes}
	g := lb.gate_make(v, labels)
	fg := lb.filter_gate_make(g, program, spec_attribute, &ctx)
	blind := lb.filter_gate_make(g, program, nil, nil)
	open := lb.filter_gate_make(g, nil, nil, nil)
	gates := [4]rawptr{&g, &fg, &blind, &open}
	procs := [4]hn.Accept_Proc{lb.gate_accept, lb.filter_gate_accept, lb.filter_gate_accept, lb.filter_gate_accept}
	strings.write_string(b, "G")
	for k in 0 ..< 4 {
		strings.write_byte(b, '|')
		for slot in 0 ..< len(labels) + 3 {
			write_bool(b, procs[k](gates[k], u32(slot)))
		}
	}
}

brute_row :: proc(b: ^strings.Builder, v: ^lb.Visibility, k: int, query: i64, points_text: string, ids_text: string) {
	ids := ids_list(ids_text)
	defer delete(ids)
	points := make([dynamic]i64)
	defer delete(points)
	if points_text != "-" {
		parts := strings.split(points_text, ",")
		defer delete(parts)
		for p in parts {
			append(&points, integer(p))
		}
	}
	assert(len(points) == len(ids))
	labels := make([]lb.Id, len(ids))
	defer delete(labels)
	for id, i in ids {
		labels[i] = lb.Id(id)
	}
	line := Line{points[:], query}
	ix: hn.Index
	assert(hn.init(&ix, hn.params_default(), line_distance, &line, context.allocator) == .None)
	defer hn.destroy(&ix)
	s: hn.Scratch
	hn.scratch_init(&s, context.allocator)
	defer hn.scratch_destroy(&s)
	for i in 0 ..< len(points) {
		slot, err := hn.reserve(&ix)
		assert(err == .None && int(slot) == i)
		assert(hn.insert(&ix, &s, slot) == .None)
	}
	g := lb.gate_make(v, labels)
	out := make([]hn.Candidate, max(k, 1))
	defer delete(out)
	n, err := hn.brute_force(&ix, &s, line_query, &line, k, out[:k], lb.gate_accept, &g)
	assert(err == .None)
	strings.write_string(b, "B|")
	if n == 0 {
		strings.write_byte(b, '-')
	}
	for c, i in out[:n] {
		if i > 0 {
			strings.write_byte(b, ',')
		}
		fmt.sbprintf(b, "%d:%d", c.id, i64(c.dist))
	}
}

main :: proc() {
	assert(len(os.args) == 2)
	input, err := os.read_entire_file(os.args[1], context.allocator)
	assert(err == nil)
	defer delete(input)
	lines := strings.split(string(input), "\n")
	defer delete(lines)
	cfg: lb.Config
	lb.config_init(&cfg)
	defer lb.config_destroy(&cfg)
	table: lb.Table
	assert(lb.table_init(&table) == .None)
	defer lb.table_destroy(&table)
	vis: lb.Visibility
	assert(lb.visibility_build(&vis, &table, lb.BOTTOM) == .None)
	defer lb.visibility_destroy(&vis)
	counters: lb.Counters
	lb.counters_init(&counters)
	defer lb.counters_destroy(&counters)
	subject := lb.subject_make(lb.BOTTOM)
	program, _, cerr := vf.compile(".f == 1")
	assert(cerr == .None)
	defer vf.program_destroy(&program)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for line in lines {
		if len(line) == 0 {
			continue
		}
		f := strings.split(line, " ")
		defer delete(f)
		strings.builder_reset(&b)
		switch f[0] {
		case "CR":
			lb.config_destroy(&cfg)
			lb.config_init(&cfg)
			strings.write_string(&b, "CR")
		case "CL", "CC":
			raw := unhex(f[1])
			defer delete(raw)
			e := lb.config_add_level(&cfg, string(raw)) if f[0] == "CL" else lb.config_add_compartment(&cfg, string(raw))
			fmt.sbprintf(&b, "%s|%s|%d|%d|", f[0], config_error(e), lb.config_level_count(&cfg), lb.config_compartment_count(&cfg))
			if e != .None {
				strings.write_byte(&b, '-')
			} else if f[0] == "CL" {
				write_hex(&b, transmute([]u8)lb.config_level_name(&cfg, lb.config_level_count(&cfg) - 1))
			} else {
				write_hex(&b, transmute([]u8)lb.config_compartment_name(&cfg, lb.config_compartment_count(&cfg) - 1))
			}
		case "M":
			raw := unhex(f[1])
			defer delete(raw)
			l, failure := lb.parse(&cfg, string(raw))
			if failure.error != .None {
				fmt.sbprintf(&b, "M|%s|%d|%d", parse_error(failure.error), failure.offset, failure.length)
				break
			}
			strings.write_string(&b, "M|ok|")
			write_label(&b, l)
			strings.write_byte(&b, '|')
			text, ok := lb.format(&cfg, l)
			defer delete(text)
			if ok {
				write_hex(&b, transmute([]u8)text)
			} else {
				strings.write_string(&b, "unformattable")
			}
		case "F":
			text, ok := lb.format(&cfg, label_of(f[1]))
			defer delete(text)
			strings.write_string(&b, "F|")
			if ok {
				write_hex(&b, transmute([]u8)text)
			} else {
				strings.write_string(&b, "invalid")
			}
		case "L":
			x := label_of(f[1])
			y := label_of(f[2])
			strings.write_string(&b, "L|")
			write_bool(&b, lb.dominates(x, y))
			strings.write_byte(&b, '|')
			write_bool(&b, lb.dominates(y, x))
			strings.write_byte(&b, '|')
			write_label(&b, lb.join(x, y))
			strings.write_byte(&b, '|')
			write_label(&b, lb.meet(x, y))
		case "TR":
			lb.table_destroy(&table)
			assert(lb.table_init(&table) == .None)
			strings.write_string(&b, "TR|1")
		case "TI":
			id, e := lb.table_intern(&table, label_of(f[1]))
			switch e {
			case .None:
				fmt.sbprintf(&b, "TI|ok|%d|%d", id, lb.table_count(&table))
			case .Table_Full:
				fmt.sbprintf(&b, "TI|full|-|%d", lb.table_count(&table))
			case .Out_Of_Memory, .Invalid_Label, .Overflow, .Underflow:
				panic("intern failed")
			}
		case "TF":
			id, found := lb.table_find(&table, label_of(f[1]))
			if found {
				fmt.sbprintf(&b, "TF|%d", id)
			} else {
				strings.write_string(&b, "TF|-")
			}
		case "E":
			bytes := make([dynamic]u8)
			defer delete(bytes)
			strings.write_string(&b, "E|")
			if lb.encode(&cfg, &table, &bytes) == .None {
				write_hex(&b, bytes[:])
			} else {
				strings.write_string(&b, "invalid")
			}
		case "D":
			raw := unhex(f[1])
			defer delete(raw)
			dc: lb.Config
			dt: lb.Table
			e := lb.decode(raw, &dc, &dt)
			if e != .None {
				fmt.sbprintf(&b, "D|%s", codec_error(e))
				break
			}
			again := make([dynamic]u8)
			defer delete(again)
			assert(lb.encode(&dc, &dt, &again) == .None)
			fmt.sbprintf(&b, "D|ok|%d|%d|%d|", lb.config_level_count(&dc), lb.config_compartment_count(&dc), lb.table_count(&dt))
			write_hex(&b, again[:])
			lb.config_destroy(&dc)
			lb.table_destroy(&dt)
		case "V":
			lb.visibility_destroy(&vis)
			assert(lb.visibility_build(&vis, &table, label_of(f[1])) == .None)
			write_vis(&b, &vis)
		case "VR":
			assert(lb.visibility_refresh(&vis, &table) == .None)
			write_vis(&b, &vis)
		case "G":
			gate_row(&b, &vis, f[1], "" if f[2] == "-" else f[2], &program)
		case "B":
			brute_row(&b, &vis, nat(f[1]), integer(f[2]), f[3], f[4])
		case "SU":
			subject = lb.subject_make(label_of(f[1]))
			ok := lb.subject_set_session(&subject, label_of(f[2]))
			fmt.sbprintf(&b, "SU|%d|", 1 if ok else 0)
			write_label(&b, lb.subject_reader(subject))
		case "SR":
			strings.write_string(&b, "SR|")
			write_bool(&b, lb.may_read(subject, label_of(f[1])))
		case "SW":
			fmt.sbprintf(&b, "SW|%s", write_verdict(lb.may_write(subject, label_of(f[1]))))
		case "SM":
			fmt.sbprintf(&b, "SM|%s", modify_verdict(lb.may_modify(subject, label_of(f[1]))))
		case "SD":
			strings.write_string(&b, "SD|")
			write_label(&b, lb.subject_write_label(subject))
			fmt.sbprintf(&b, "|%s", write_verdict(lb.may_write(subject, lb.subject_write_label(subject))))
		case "NR":
			lb.counters_destroy(&counters)
			lb.counters_init(&counters)
			strings.write_string(&b, "NR")
		case "NA":
			e := lb.counters_add(&counters, lb.Id(nat(f[1])), big(f[2]))
			fmt.sbprintf(&b, "NA|%s|%d", counter_error(e), lb.counters_total(&counters))
		case "NS":
			e := lb.counters_sub(&counters, lb.Id(nat(f[1])), big(f[2]))
			fmt.sbprintf(&b, "NS|%s|%d", counter_error(e), lb.counters_total(&counters))
		case "NV":
			fmt.sbprintf(&b, "NV|%d|", lb.counters_visible(&counters, &vis))
			if len(counters.counts) == 0 {
				strings.write_byte(&b, '-')
			}
			for c, i in counters.counts {
				if i > 0 {
					strings.write_byte(&b, ',')
				}
				fmt.sbprintf(&b, "%d", c)
			}
		case:
			panic("unknown case")
		}
		fmt.println(strings.to_string(b))
	}
}
