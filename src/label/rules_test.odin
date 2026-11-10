package label

import "core:testing"

@(test)
read_write_and_modify_rules_follow_the_lattice :: proc(t: ^testing.T) {
	for ci := 0; ci < SMALL_TRUSTED_LABELS; ci += 3 {
		clearance := small_label(ci)
		for si in 0 ..< SMALL_TRUSTED_LABELS {
			session := small_label(si)
			s := subject_make(clearance)
			testing.expect(t, s.session == ceiling_session(clearance))
			testing.expect(t, subject_ok(s))
			testing.expect_value(t, may_write(s, subject_write_label(s)), Write_Verdict.Allowed)
			testing.expect_value(t, subject_set_session(&s, session), ceiling_admits(clearance, session))
			if !ceiling_admits(clearance, session) {
				testing.expect(t, s.session == ceiling_session(clearance))
				s.session = session
			}
			ok := ceiling_admits(clearance, session)
			testing.expect_value(t, subject_ok(s), ok)
			for li in 0 ..< SMALL_TRUSTED_LABELS {
				l := small_label(li)
				read := may_read(s, l)
				testing.expect_value(t, read, ok && dominates(session, l))
				w := may_write(s, l)
				testing.expect_value(t, w == .Allowed, ceiling_admits(clearance, l) && l == session)
				if !ceiling_admits(clearance, l) {
					testing.expect_value(t, w, Write_Verdict.Above_Clearance)
				} else if l != session {
					testing.expect_value(t, w, Write_Verdict.Not_Session)
				}
				m := may_modify(s, l)
				testing.expect_value(t, m == .Allowed, ok && l == session)
				testing.expect_value(t, m == .Not_Visible, !read)
				if w == .Allowed {
					for xi in 0 ..< SMALL_TRUSTED_LABELS {
						x := small_label(xi)
						if may_read(s, x) {
							testing.expect(t, dominates(l, x))
						}
					}
				}
			}
		}
	}
}
