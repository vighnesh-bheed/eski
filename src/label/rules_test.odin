package label

import "core:testing"

@(test)
read_write_and_modify_rules_follow_the_lattice :: proc(t: ^testing.T) {
	for ci in 0 ..< SMALL_LABELS {
		clearance := small_label(ci)
		for si in 0 ..< SMALL_LABELS {
			session := small_label(si)
			s := subject_make(clearance)
			testing.expect(t, s.session == clearance)
			testing.expect_value(t, may_write(s, subject_write_label(s)), Write_Verdict.Allowed)
			testing.expect_value(t, subject_set_session(&s, session), dominates(clearance, session))
			if !dominates(clearance, session) {
				testing.expect(t, s.session == clearance)
				s.session = session
			}
			for li in 0 ..< SMALL_LABELS {
				l := small_label(li)
				read := may_read(s, l)
				testing.expect_value(t, read, dominates(session, l) && dominates(clearance, l))
				if read {
					testing.expect(t, dominates(clearance, l))
				}
				w := may_write(s, l)
				testing.expect_value(t, w == .Allowed, dominates(clearance, l) && dominates(l, session))
				if !dominates(clearance, l) {
					testing.expect_value(t, w, Write_Verdict.Above_Clearance)
				} else if !dominates(l, session) {
					testing.expect_value(t, w, Write_Verdict.Write_Down)
				}
				m := may_modify(s, l)
				if dominates(clearance, session) {
					testing.expect_value(t, m == .Allowed, l == session)
				}
				testing.expect_value(t, m == .Not_Visible, !read)
				if w == .Allowed {
					for xi in 0 ..< SMALL_LABELS {
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
