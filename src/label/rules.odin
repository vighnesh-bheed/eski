package label

Subject :: struct {
	clearance: Label,
	session:   Label,
}

Write_Verdict :: enum u8 {
	Allowed,
	Above_Clearance,
	Not_Session,
}

Modify_Verdict :: enum u8 {
	Allowed,
	Not_Visible,
	Not_Session,
}

subject_make :: proc "contextless" (clearance: Label) -> Subject {
	return Subject{clearance = clearance, session = ceiling_session(clearance)}
}

subject_set_session :: proc "contextless" (s: ^Subject, session: Label) -> bool {
	if !ceiling_admits(s.clearance, session) {
		return false
	}
	s.session = session
	return true
}

subject_ok :: #force_inline proc "contextless" (s: Subject) -> bool {
	return ceiling_admits(s.clearance, s.session)
}

subject_reader :: #force_inline proc "contextless" (s: Subject) -> Label {
	return s.session
}

subject_write_label :: #force_inline proc "contextless" (s: Subject) -> Label {
	return s.session
}

may_read :: proc "contextless" (s: Subject, l: Label) -> bool {
	return subject_ok(s) && dominates(s.session, l)
}

may_write :: proc "contextless" (s: Subject, l: Label) -> Write_Verdict {
	if !ceiling_admits(s.clearance, l) {
		return .Above_Clearance
	}
	if l != s.session {
		return .Not_Session
	}
	return .Allowed
}

may_modify :: proc "contextless" (s: Subject, existing: Label) -> Modify_Verdict {
	if !may_read(s, existing) {
		return .Not_Visible
	}
	if existing != s.session {
		return .Not_Session
	}
	return .Allowed
}
