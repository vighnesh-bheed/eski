import Labels.Trust

namespace Labels

structure Subject where
  clearance : TLabel
  session : TLabel
deriving DecidableEq, Repr

inductive WV
  | allowed
  | aboveClearance
  | notSession
deriving DecidableEq, Repr

inductive MV
  | allowed
  | notVisible
  | notSession
deriving DecidableEq, Repr

def subjectMake (c : TLabel) : Subject := ⟨c, ceilingSession c⟩

def setSession (s : Subject) (l : TLabel) : Option Subject :=
  if ceilingAdmits s.clearance l then some { s with session := l } else none

def subjectOk (s : Subject) : Bool := ceilingAdmits s.clearance s.session

def reader (s : Subject) : TLabel := s.session

def writeLabel (s : Subject) : TLabel := s.session

def mayRead (s : Subject) (l : TLabel) : Bool := subjectOk s && domT s.session l

def mayWrite (s : Subject) (l : TLabel) : WV :=
  if !ceilingAdmits s.clearance l then .aboveClearance else if l ≠ s.session then .notSession else .allowed

def mayModify (s : Subject) (e : TLabel) : MV :=
  if !mayRead s e then .notVisible else if e ≠ s.session then .notSession else .allowed

def SubjectOk (s : Subject) : Prop := subjectOk s = true

theorem make_ok (c : TLabel) : SubjectOk (subjectMake c) := ceiling_session_admitted c

theorem make_session (c : TLabel) : (subjectMake c).session = ⟨c.sec, 0⟩ := rfl

theorem setSession_ok {s s' : Subject} {l : TLabel} (h : setSession s l = some s') :
    SubjectOk s' ∧ s'.clearance = s.clearance ∧ s'.session = l := by
  unfold setSession at h
  split at h
  · rename_i hd
    simp only [Option.some.injEq] at h
    subst h
    exact ⟨hd, rfl, rfl⟩
  · simp at h

theorem setSession_none (s : Subject) (l : TLabel) : setSession s l = none ↔ ceilingAdmits s.clearance l = false := by
  unfold setSession
  split <;> simp_all

theorem read_iff {s : Subject} (h : SubjectOk s) (l : TLabel) : mayRead s l = true ↔ domT s.session l = true := by
  unfold mayRead
  unfold SubjectOk at h
  rw [h, Bool.true_and]

theorem read_fails_closed {s : Subject} (h : subjectOk s = false) (l : TLabel) : mayRead s l = false := by
  unfold mayRead
  rw [h, Bool.false_and]

theorem read_clearance {s : Subject} {l : TLabel} (h : mayRead s l = true) : dom s.clearance.sec l.sec = true := by
  unfold mayRead subjectOk at h
  rw [Bool.and_eq_true] at h
  exact dom_trans ((ceilingAdmits_iff _ _).1 h.1).1 ((domT_iff _ _).1 h.2).1

theorem read_trust {s : Subject} {l : TLabel} (h : mayRead s l = true) : s.session.trust ≤ l.trust := by
  unfold mayRead at h
  rw [Bool.and_eq_true] at h
  exact ((domT_iff _ _).1 h.2).2

theorem write_iff (s : Subject) (l : TLabel) :
    mayWrite s l = .allowed ↔ ceilingAdmits s.clearance l = true ∧ l = s.session := by
  unfold mayWrite
  cases h1 : ceilingAdmits s.clearance l <;> by_cases h2 : l = s.session <;> simp [h2]

theorem write_exact {s : Subject} {l : TLabel} (h : mayWrite s l = .allowed) : l = s.session :=
  ((write_iff s l).1 h).2

theorem write_within_clearance {s : Subject} {l : TLabel} (h : mayWrite s l = .allowed) :
    ceilingAdmits s.clearance l = true :=
  ((write_iff s l).1 h).1

theorem write_above_iff (s : Subject) (l : TLabel) :
    mayWrite s l = .aboveClearance ↔ ceilingAdmits s.clearance l = false := by
  unfold mayWrite
  cases h1 : ceilingAdmits s.clearance l <;> by_cases h2 : l = s.session <;> simp [h2]

theorem write_elsewhere_iff (s : Subject) (l : TLabel) :
    mayWrite s l = .notSession ↔ ceilingAdmits s.clearance l = true ∧ l ≠ s.session := by
  unfold mayWrite
  cases h1 : ceilingAdmits s.clearance l <;> by_cases h2 : l = s.session <;> simp [h2]

theorem default_write {s : Subject} (h : SubjectOk s) : mayWrite s (writeLabel s) = .allowed :=
  (write_iff s s.session).2 ⟨h, rfl⟩

theorem flow_up {s : Subject} {w r : TLabel} (hw : mayWrite s w = .allowed) (hr : mayRead s r = true) :
    domT w r = true := by
  rw [write_exact hw]
  unfold mayRead at hr
  rw [Bool.and_eq_true] at hr
  exact hr.2

theorem modify_iff (s : Subject) (e : TLabel) : mayModify s e = .allowed ↔ SubjectOk s ∧ e = s.session := by
  unfold mayModify
  constructor
  · intro hm
    by_cases h2 : e = s.session
    · cases h1 : mayRead s e
      · simp [h1] at hm
      · unfold mayRead at h1
        rw [Bool.and_eq_true] at h1
        exact ⟨h1.1, h2⟩
    · cases h1 : mayRead s e <;> simp [h1, h2] at hm
  · intro ⟨hs, he⟩
    subst he
    rw [(read_iff hs _).2 (domT_refl _)]
    simp

theorem modify_hidden (s : Subject) (e : TLabel) : mayModify s e = .notVisible ↔ mayRead s e = false := by
  unfold mayModify
  cases h1 : mayRead s e <;> by_cases h2 : e = s.session <;> simp [h2]

theorem modify_flow {s : Subject} {e r : TLabel} (hm : mayModify s e = .allowed) (hr : mayRead s r = true) :
    domT e r = true := by
  rw [((modify_iff s e).1 hm).2]
  unfold mayRead at hr
  rw [Bool.and_eq_true] at hr
  exact hr.2

theorem lower_session_reads_less {c a b l : TLabel} (hok : ceilingAdmits c a = true) (hab : domT a b = true)
    (h : mayRead ⟨c, b⟩ l = true) : mayRead ⟨c, a⟩ l = true := by
  unfold mayRead subjectOk at h ⊢
  rw [Bool.and_eq_true] at h ⊢
  exact ⟨hok, domT_trans hab h.2⟩

end Labels
