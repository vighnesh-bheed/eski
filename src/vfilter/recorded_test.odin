package vfilter

import "core:strings"
import "core:testing"

Recorded_Element :: struct {
	name:    string,
	present: bool,
	text:    string,
}

ATTR_SET_A :: `{"n":1,"s":"x","b":true,"arr":[1,2],"o":{"k":5},"f":1.5}`
ATTR_SET_B :: `{"n":2,"s":"y","b":false}`
ATTR_SET_C :: `{"n":3,"s":"10"}`

recorded_elements :: proc(which: Recorded_Context, allocator := context.allocator) -> []Recorded_Element {
	switch which {
	case .Attr_Set:
		return slice_clone_elements({{"a", true, ATTR_SET_A}, {"b", true, ATTR_SET_B}, {"c", true, ATTR_SET_C}, {"d", false, ""}, {"e", true, "notjson"}}, allocator)
	case .Attr_Set_Bad_A:
		return slice_clone_elements({{"a", true, "{bad json"}, {"b", true, ATTR_SET_B}, {"c", true, ATTR_SET_C}, {"d", false, ""}, {"e", true, "notjson"}}, allocator)
	case .Variants:
		return slice_clone_elements({{"a", false, ""}, {"b", false, ""}, {"c", false, ""}, {"d", false, ""}, {"e", true, `{"k":1}`}, {"f", false, ""}, {"g", false, ""}, {"h", true, `{"h":true}`}}, allocator)
	case .Lowercase:
		return slice_clone_elements({{"a", true, "{}"}}, allocator)
	case .Counted:
		elements := make([]Recorded_Element, 100, allocator)
		for &element in elements {
			element = Recorded_Element{name = "?", present = false}
		}
		return elements
	}
	return nil
}

slice_clone_elements :: proc(elements: []Recorded_Element, allocator := context.allocator) -> []Recorded_Element {
	result := make([]Recorded_Element, len(elements), allocator)
	copy(result, elements)
	return result
}

@(test)
recorded_filter_cases :: proc(t: ^testing.T) {
	reproduced := 0
	for recorded in RECORDED_CASES {
		elements := recorded_elements(recorded.context_of)
		defer delete(elements)
		program, near, err := compile(recorded.expression)
		defer program_destroy(&program)
		if recorded.error != "" {
			ok := err == .Syntax
			if ok {
				text, _ := error_text(near)
				defer delete(text)
				ok = text == recorded.error
				if !ok {
					testing.expectf(t, false, "case %d %q: error %q want %q", recorded.id, recorded.expression, text, recorded.error)
				}
			} else {
				testing.expectf(t, false, "case %d %q: compiled, want error %q", recorded.id, recorded.expression, recorded.error)
			}
			if ok {
				reproduced += 1
			}
			continue
		}
		if err != .None {
			testing.expectf(t, false, "case %d %q: error near %q, want a program", recorded.id, recorded.expression, near)
			continue
		}
		all := true
		for element in elements {
			attribute: Attribute
			pointer: ^Attribute
			if element.present {
				attribute, _ = attribute_make(element.text)
				pointer = &attribute
			}
			matched := evaluate(&program, pointer)
			attribute_destroy(&attribute)
			wanted := element.name != "?" && strings.contains(recorded.matches, element.name)
			if matched != wanted {
				all = false
				testing.expectf(t, false, "case %d %q element %s: matched %v want %v", recorded.id, recorded.expression, element.name, matched, wanted)
			}
		}
		if all {
			reproduced += 1
		}
	}
	testing.expect_value(t, reproduced, len(RECORDED_CASES))
	testing.expect_value(t, len(RECORDED_CASES), 181)
}
