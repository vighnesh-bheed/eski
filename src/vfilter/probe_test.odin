package vfilter

import "core:strings"
import "core:testing"

Probe_Attribute :: struct {
	name:      string,
	present:   bool,
	attribute: Attribute,
}

probe_element_text :: proc(element: Probe_Element, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, element.head)
	for _ in 0 ..< element.count {
		strings.write_string(&builder, element.open)
	}
	strings.write_string(&builder, element.inner)
	for _ in 0 ..< element.count {
		strings.write_string(&builder, element.close)
	}
	strings.write_string(&builder, element.tail)
	return strings.to_string(builder)
}

probe_context_attributes :: proc(context_of: string) -> [dynamic]Probe_Attribute {
	result := make([dynamic]Probe_Attribute)
	for element in PROBE_ELEMENTS {
		if element.context_of != context_of {
			continue
		}
		entry := Probe_Attribute{name = element.name, present = element.present}
		if element.present {
			text := probe_element_text(element)
			entry.attribute, _ = attribute_make(text)
			delete(text)
		}
		append(&result, entry)
	}
	return result
}

testing_expect_text :: proc(attribute: Attribute, element: Probe_Element) -> bool {
	text := probe_element_text(element, context.temp_allocator)
	return attribute_text(attribute) == text
}

@(test)
probe_cases_reproduce :: proc(t: ^testing.T) {
	contexts := make(map[string][dynamic]Probe_Attribute)
	defer {
		for _, &list in contexts {
			for &entry in list {
				attribute_destroy(&entry.attribute)
			}
			delete(list)
		}
		delete(contexts)
	}
	for element in PROBE_ELEMENTS {
		if element.context_of not_in contexts {
			contexts[element.context_of] = probe_context_attributes(element.context_of)
		}
		if element.present {
			for entry in contexts[element.context_of] {
				if entry.name == element.name {
					testing.expectf(t, testing_expect_text(entry.attribute, element), "element %s text was not kept verbatim", element.name)
				}
			}
		}
	}
	free_all(context.temp_allocator)
	reproduced := 0
	for probe in PROBE_CASES {
		program, near, err := compile(probe.expression)
		defer program_destroy(&program)
		if probe.error != "" {
			ok := err == .Syntax
			if ok {
				text, _ := error_text(near)
				defer delete(text)
				ok = text == probe.error
				testing.expectf(t, ok, "probe %d %q: error %q want %q", probe.id, probe.expression, text, probe.error)
			} else {
				testing.expectf(t, false, "probe %d %q: compiled, want error %q", probe.id, probe.expression, probe.error)
			}
			if ok {
				reproduced += 1
			}
			continue
		}
		if err != .None {
			testing.expectf(t, false, "probe %d %q: error near %q, want a program", probe.id, probe.expression, near)
			continue
		}
		all := true
		for &entry in contexts[probe.context_of] {
			pointer: ^Attribute = &entry.attribute if entry.present else nil
			matched := evaluate(&program, pointer)
			marker := strings.concatenate({",", entry.name, ","}, context.temp_allocator)
			wanted := strings.contains(probe.matches, marker)
			if matched != wanted {
				all = false
				testing.expectf(t, false, "probe %d %q element %s: matched %v want %v", probe.id, probe.expression, entry.name, matched, wanted)
			}
		}
		free_all(context.temp_allocator)
		if all {
			reproduced += 1
		}
	}
	testing.expect_value(t, reproduced, len(PROBE_CASES))
	testing.expect_value(t, len(PROBE_CASES), 1208)
	testing.expect_value(t, PROBE_IMAGE_DIGEST, "sha256:f245f4c83b84a9e9a0588da1c9456e579455310f0945d5db52cd2ba27f2000cc")
}
