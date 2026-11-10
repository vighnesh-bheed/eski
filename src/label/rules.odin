package label

Subject :: struct {
	clearance: Label,
	session:   Label,
}

Write_Verdict :: enum u8 {
	Allowed,
	Above_Clearance,
	Write_Down,
}

Modify_Verdict :: enum u8 {
	Allowed,
	Not_Visible,
	Write_Down,
}

subject_make :: proc "contextless" (clearance: Label) -> Subject {
	return Subject{clearance = clearance, session = clearance}
}

subject_set_session :: proc "contextless" (s: ^Subject, session: Label) -> bool {
	if !dominates(s.clearance, session) {
		return false
	}
	s.session = session
	return true
}

subject_reader :: #force_inline proc "contextless" (s: Subject) -> Label {
	return meet(s.session, s.clearance)
}

subject_write_label :: #force_inline proc "contextless" (s: Subject) -> Label {
	return s.session
}

may_read :: proc "contextless" (s: Subject, l: Label) -> bool {
	return dominates(subject_reader(s), l)
}

may_write :: proc "contextless" (s: Subject, l: Label) -> Write_Verdict {
	if !dominates(s.clearance, l) {
		return .Above_Clearance
	}
	if !dominates(l, s.session) {
		return .Write_Down
	}
	return .Allowed
}

may_modify :: proc "contextless" (s: Subject, existing: Label) -> Modify_Verdict {
	if !may_read(s, existing) {
		return .Not_Visible
	}
	if !dominates(existing, s.session) {
		return .Write_Down
	}
	return .Allowed
}
