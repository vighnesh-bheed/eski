import Labels.Lattice

namespace Labels

structure Subject where
  clearance : Label
  session : Label
deriving DecidableEq, Repr

inductive WV
  | allowed
  | aboveClearance
  | writeDown
deriving DecidableEq, Repr

inductive MV
  | allowed
  | notVisible
  | writeDown
deriving DecidableEq, Repr

def subjectMake (c : Label) : Subject := ⟨c, c⟩

def setSession (s : Subject) (l : Label) : Option Subject :=
  if dom s.clearance l then some { s with session := l } else none

def reader (s : Subject) : Label := meet s.session s.clearance

def writeLabel (s : Subject) : Label := s.session

def mayRead (s : Subject) (l : Label) : Bool := dom (reader s) l

def mayWrite (s : Subject) (l : Label) : WV :=
  if !dom s.clearance l then .aboveClearance else if !dom l s.session then .writeDown else .allowed

def mayModify (s : Subject) (e : Label) : MV :=
  if !mayRead s e then .notVisible else if !dom e s.session then .writeDown else .allowed

def SubjectOk (s : Subject) : Prop := dom s.clearance s.session = true

theorem make_ok (c : Label) : SubjectOk (subjectMake c) := dom_refl c

theorem setSession_ok {s s' : Subject} {l : Label} (h : setSession s l = some s') :
    SubjectOk s' ∧ s'.clearance = s.clearance ∧ s'.session = l := by
  unfold setSession at h
  split at h
  · rename_i hd
    simp only [Option.some.injEq] at h
    subst h
    exact ⟨hd, rfl, rfl⟩
  · simp at h

theorem setSession_none (s : Subject) (l : Label) : setSession s l = none ↔ dom s.clearance l = false := by
  unfold setSession
  split <;> simp_all

theorem read_clearance {s : Subject} {l : Label} (h : mayRead s l = true) : dom s.clearance l = true :=
  dom_trans (meet_lower_right s.session s.clearance) h

theorem read_session {s : Subject} {l : Label} (h : mayRead s l = true) : dom s.session l = true :=
  dom_trans (meet_lower_left s.session s.clearance) h

theorem read_iff_both (s : Subject) (l : Label) :
    mayRead s l = true ↔ dom s.session l = true ∧ dom s.clearance l = true := dom_meet_iff _ _ _

theorem reader_eq {s : Subject} (h : SubjectOk s) : reader s = s.session := by
  unfold reader
  rw [meet_comm]
  exact (meet_dom_iff _ _).2 h

theorem read_iff {s : Subject} (h : SubjectOk s) (l : Label) : mayRead s l = true ↔ dom s.session l = true := by
  unfold mayRead
  rw [reader_eq h]

theorem write_iff (s : Subject) (l : Label) :
    mayWrite s l = .allowed ↔ dom s.clearance l = true ∧ dom l s.session = true := by
  unfold mayWrite
  cases h1 : dom s.clearance l <;> cases h2 : dom l s.session <;> simp

theorem write_above_iff (s : Subject) (l : Label) : mayWrite s l = .aboveClearance ↔ dom s.clearance l = false := by
  unfold mayWrite
  cases h1 : dom s.clearance l <;> cases h2 : dom l s.session <;> simp

theorem write_down_iff (s : Subject) (l : Label) :
    mayWrite s l = .writeDown ↔ dom s.clearance l = true ∧ dom l s.session = false := by
  unfold mayWrite
  cases h1 : dom s.clearance l <;> cases h2 : dom l s.session <;> simp

theorem flow_up {s : Subject} {w r : Label} (hw : mayWrite s w = .allowed) (hr : mayRead s r = true) :
    dom w r = true :=
  dom_trans ((write_iff s w).1 hw).2 (read_session hr)

theorem default_write {s : Subject} (h : SubjectOk s) : mayWrite s (writeLabel s) = .allowed :=
  (write_iff s s.session).2 ⟨h, dom_refl _⟩

theorem modify_iff {s : Subject} (h : SubjectOk s) (e : Label) : mayModify s e = .allowed ↔ e = s.session := by
  unfold mayModify
  constructor
  · intro hm
    cases h1 : mayRead s e <;> cases h2 : dom e s.session <;> simp_all
    exact dom_antisymm h2 ((read_iff h e).1 h1)
  · intro he
    subst he
    rw [(read_iff h _).2 (dom_refl _), dom_refl]
    rfl

theorem modify_hidden (s : Subject) (e : Label) : mayModify s e = .notVisible ↔ mayRead s e = false := by
  unfold mayModify
  cases h1 : mayRead s e <;> cases h2 : dom e s.session <;> simp

theorem modify_flow {s : Subject} {e r : Label} (hm : mayModify s e = .allowed) (hr : mayRead s r = true) :
    dom e r = true := by
  unfold mayModify at hm
  cases h1 : mayRead s e <;> cases h2 : dom e s.session <;> simp_all
  exact dom_trans h2 (read_session hr)

theorem lower_session_reads_less {c a b l : Label} (hab : dom a b = true) (h : mayRead ⟨c, b⟩ l = true) :
    mayRead ⟨c, a⟩ l = true := by
  rw [read_iff_both] at h ⊢
  exact ⟨dom_trans hab h.1, h.2⟩

end Labels
