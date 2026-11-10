import Labels.Rules

namespace Labels

section KeyModel
set_option linter.unusedSectionVars false
variable {N V : Type} [DecidableEq N]

structure KCopy (N V : Type) where
  name : N
  label : TLabel
  val : V

structure KState (N V : Type) where
  copies : List (KCopy N V)
  parts : List TLabel

def ownOf (s : KState N V) (R : TLabel) (n : N) : Option (KCopy N V) :=
  s.copies.find? (fun c => c.name == n && c.label == R)

def cands (s : KState N V) (R : TLabel) (n : N) : List (KCopy N V) :=
  s.copies.filter (fun c => c.name == n && c.label != R && domT R c.label)

def better (c b : KCopy N V) : Bool := decide (0 < rcmp c.label b.label)

def pickFrom : KCopy N V → List (KCopy N V) → KCopy N V
  | b, [] => b
  | b, c :: cs => pickFrom (if better c b then c else b) cs

def pick : List (KCopy N V) → Option (KCopy N V)
  | [] => none
  | c :: cs => some (pickFrom c cs)

def other (s : KState N V) (R : TLabel) (n : N) : Option (KCopy N V) := pick (cands s R n)

def resolve (s : KState N V) (R : TLabel) (n : N) : Option (KCopy N V) :=
  match ownOf s R n with
  | some c => some c
  | none => other s R n

def restrict (R : TLabel) (s : KState N V) : KState N V :=
  ⟨s.copies.filter (fun c => domT R c.label), s.parts.filter (fun l => domT R l)⟩

theorem rcmp_pos_trans {a b c : TLabel} (h1 : 0 < rcmp a b) (h2 : 0 < rcmp b c) : 0 < rcmp a c := by
  rw [rcmp_pos_iff] at h1 h2 ⊢
  omega

theorem rcmp_pos_of_le {a b c : TLabel} (h1 : 0 < rcmp a b) (h2 : ¬0 < rcmp c b) : 0 < rcmp a c := by
  rw [rcmp_pos_iff] at h1 h2 ⊢
  omega

theorem rcmp_pos_asymm {a b : TLabel} (h : 0 < rcmp a b) : ¬0 < rcmp b a := by
  rw [rcmp_antisymm a b] at h
  omega

theorem better_trans {a b c : KCopy N V} (h1 : better a b = true) (h2 : better b c = true) : better a c = true := by
  unfold better at *
  simp only [decide_eq_true_eq] at *
  exact rcmp_pos_trans h1 h2

theorem better_of_not {a b c : KCopy N V} (h1 : better a b = true) (h2 : better c b = false) : better a c = true := by
  unfold better at *
  simp only [decide_eq_true_eq, decide_eq_false_iff_not] at *
  exact rcmp_pos_of_le h1 h2

theorem better_asymm {a b : KCopy N V} (h : better a b = true) : better b a = false := by
  unfold better at *
  simp only [decide_eq_true_eq, decide_eq_false_iff_not] at *
  exact rcmp_pos_asymm h

theorem better_irrefl (a : KCopy N V) : better a a = false := by
  simp [better, rcmp_refl]

theorem pickFrom_spec (l : List (KCopy N V)) : ∀ (b : KCopy N V),
    (pickFrom b l = b ∧ ∀ d ∈ l, better d b = false) ∨
    ∃ pre post, l = pre ++ pickFrom b l :: post ∧ better (pickFrom b l) b = true ∧
      (∀ d ∈ pre, better (pickFrom b l) d = true) ∧ ∀ d ∈ post, better d (pickFrom b l) = false := by
  induction l with
  | nil => intro b; exact Or.inl ⟨rfl, by simp⟩
  | cons c cs ih =>
    intro b
    by_cases hc : better c b = true
    · have hp : pickFrom b (c :: cs) = pickFrom c cs := by simp [pickFrom, hc]
      rw [hp]
      rcases ih c with ⟨h1, h2⟩ | ⟨pre, post, h1, h2, h3, h4⟩
      · rw [h1]
        exact Or.inr ⟨[], cs, by simp, hc, by simp, h2⟩
      · refine Or.inr ⟨c :: pre, post, by rw [List.cons_append, ← h1], better_trans h2 hc, ?_, h4⟩
        intro d hd
        rcases List.mem_cons.1 hd with rfl | hd
        · exact h2
        · exact h3 d hd
    · have hc' : better c b = false := by simpa using hc
      have hp : pickFrom b (c :: cs) = pickFrom b cs := by simp [pickFrom, hc']
      rw [hp]
      rcases ih b with ⟨h1, h2⟩ | ⟨pre, post, h1, h2, h3, h4⟩
      · refine Or.inl ⟨h1, ?_⟩
        intro d hd
        rcases List.mem_cons.1 hd with rfl | hd
        · exact hc'
        · exact h2 d hd
      · refine Or.inr ⟨c :: pre, post, by rw [List.cons_append, ← h1], h2, ?_, h4⟩
        intro d hd
        rcases List.mem_cons.1 hd with rfl | hd
        · exact better_of_not h2 hc'
        · exact h3 d hd

theorem pick_spec {l : List (KCopy N V)} {r : KCopy N V} (h : pick l = some r) :
    ∃ pre post, l = pre ++ r :: post ∧ (∀ d ∈ pre, better r d = true) ∧ ∀ d ∈ post, better d r = false := by
  cases l with
  | nil => simp [pick] at h
  | cons c cs =>
    simp only [pick, Option.some.injEq] at h
    subst h
    rcases pickFrom_spec cs c with ⟨h1, h2⟩ | ⟨pre, post, h1, h2, h3, h4⟩
    · rw [h1]
      exact ⟨[], cs, by simp, by simp, h2⟩
    · refine ⟨c :: pre, post, by rw [List.cons_append, ← h1], ?_, h4⟩
      intro d hd
      rcases List.mem_cons.1 hd with rfl | hd
      · exact h2
      · exact h3 d hd

theorem pick_none {l : List (KCopy N V)} : pick l = none ↔ l = [] := by
  cases l <;> simp [pick]

theorem pick_mem {l : List (KCopy N V)} {r : KCopy N V} (h : pick l = some r) : r ∈ l := by
  obtain ⟨pre, post, h1, _, _⟩ := pick_spec h
  rw [h1]
  simp

theorem pick_best {l : List (KCopy N V)} {r : KCopy N V} (h : pick l = some r) : ∀ d ∈ l, better d r = false := by
  obtain ⟨pre, post, h1, h2, h3⟩ := pick_spec h
  intro d hd
  rw [h1] at hd
  rcases List.mem_append.1 hd with hd | hd
  · exact better_asymm (h2 d hd)
  · rcases List.mem_cons.1 hd with rfl | hd
    · exact better_irrefl d
    · exact h3 d hd

theorem ownOf_some {s : KState N V} {R : TLabel} {n : N} {c : KCopy N V} (h : ownOf s R n = some c) :
    c ∈ s.copies ∧ c.name = n ∧ c.label = R := by
  unfold ownOf at h
  have hm := List.mem_of_find?_eq_some h
  have hp := List.find?_some h
  simp only [Bool.and_eq_true, beq_iff_eq] at hp
  exact ⟨hm, hp.1, hp.2⟩

theorem ownOf_none {s : KState N V} {R : TLabel} {n : N} (h : ownOf s R n = none) :
    ∀ c ∈ s.copies, c.name = n → c.label ≠ R := by
  unfold ownOf at h
  intro c hc hn hl
  have := List.find?_eq_none.1 h c hc
  simp [hn, hl] at this

theorem cands_mem {s : KState N V} {R : TLabel} {n : N} {c : KCopy N V} :
    c ∈ cands s R n ↔ c ∈ s.copies ∧ c.name = n ∧ c.label ≠ R ∧ domT R c.label = true := by
  unfold cands
  simp [List.mem_filter, and_assoc]

theorem resolve_own {s : KState N V} {R : TLabel} {n : N} {c : KCopy N V} (h : ownOf s R n = some c) :
    resolve s R n = some c := by
  simp [resolve, h]

theorem resolve_other {s : KState N V} {R : TLabel} {n : N} (h : ownOf s R n = none) :
    resolve s R n = other s R n := by
  simp [resolve, h]

theorem resolve_visible {s : KState N V} {R : TLabel} {n : N} {c : KCopy N V} (h : resolve s R n = some c) :
    c ∈ s.copies ∧ c.name = n ∧ domT R c.label = true := by
  unfold resolve at h
  split at h
  · rename_i c' hc
    simp only [Option.some.injEq] at h
    subst h
    obtain ⟨h1, h2, h3⟩ := ownOf_some hc
    exact ⟨h1, h2, by rw [h3]; exact domT_refl R⟩
  · obtain ⟨h1, h2, _, h4⟩ := cands_mem.1 (pick_mem h)
    exact ⟨h1, h2, h4⟩

theorem resolve_best {s : KState N V} {R : TLabel} {n : N} {c : KCopy N V} (ho : ownOf s R n = none)
    (h : resolve s R n = some c) :
    c ∈ cands s R n ∧ ∀ d ∈ s.copies, d.name = n → domT R d.label = true → better d c = false := by
  rw [resolve_other ho] at h
  refine ⟨pick_mem h, fun d hd hn hv => pick_best h d (cands_mem.2 ⟨hd, hn, ownOf_none ho d hd hn, hv⟩)⟩

theorem resolve_oldest {s : KState N V} {R : TLabel} {n : N} {c : KCopy N V} (ho : ownOf s R n = none)
    (h : resolve s R n = some c) :
    ∃ pre post, cands s R n = pre ++ c :: post ∧ (∀ d ∈ pre, better c d = true) ∧ ∀ d ∈ post, better d c = false := by
  rw [resolve_other ho] at h
  exact pick_spec h

theorem resolve_none {s : KState N V} {R : TLabel} {n : N} :
    resolve s R n = none ↔ ∀ c ∈ s.copies, c.name = n → domT R c.label = false := by
  constructor
  · intro h c hc hn
    unfold resolve at h
    split at h
    · simp at h
    · rename_i ho
      have hnil := pick_none.1 h
      by_cases hv : domT R c.label = true
      · have : c ∈ cands s R n := cands_mem.2 ⟨hc, hn, ownOf_none ho c hc hn, hv⟩
        rw [hnil] at this
        simp at this
      · simpa using hv
  · intro h
    have ho : ownOf s R n = none := by
      unfold ownOf
      apply List.find?_eq_none.2
      intro c hc
      have := h c hc
      by_cases hn : c.name = n
      · have hv := this hn
        have hl : c.label ≠ R := fun e => by rw [e, domT_refl] at hv; simp at hv
        simp [hn, hl]
      · simp [hn]
    rw [resolve_other ho]
    apply pick_none.2
    apply List.eq_nil_iff_forall_not_mem.2
    intro c hc
    obtain ⟨h1, h2, _, h4⟩ := cands_mem.1 hc
    rw [h c h1 h2] at h4
    simp at h4

theorem find_filter_of {α : Type} (p q : α → Bool) (h : ∀ x, p x = true → q x = true) (l : List α) :
    (l.filter q).find? p = l.find? p := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    by_cases hp : p x = true
    · simp [List.filter, h x hp, List.find?, hp]
    · by_cases hq : q x = true
      · simp [List.filter, hq, List.find?, hp, ih]
      · simp [List.filter, hq, List.find?, hp, ih]

theorem filter_filter_of {α : Type} (p q : α → Bool) (h : ∀ x, p x = true → q x = true) (l : List α) :
    (l.filter q).filter p = l.filter p := by
  rw [List.filter_filter]
  congr 1
  funext x
  by_cases hp : p x = true
  · simp [hp, h x hp]
  · simp [hp]

theorem ownOf_restrict (R : TLabel) (s : KState N V) (n : N) : ownOf (restrict R s) R n = ownOf s R n := by
  unfold ownOf restrict
  apply find_filter_of
  intro c hc
  simp only [Bool.and_eq_true, beq_iff_eq] at hc
  rw [hc.2]
  exact domT_refl R

theorem cands_restrict (R : TLabel) (s : KState N V) (n : N) : cands (restrict R s) R n = cands s R n := by
  unfold cands restrict
  apply filter_filter_of
  intro c hc
  simp only [Bool.and_eq_true] at hc
  exact hc.2

theorem resolve_restrict (R : TLabel) (s : KState N V) (n : N) : resolve (restrict R s) R n = resolve s R n := by
  unfold resolve other
  rw [ownOf_restrict, cands_restrict]

theorem cands_restrict_of {R W : TLabel} (hw : domT R W = true) (s : KState N V) (n : N) :
    cands (restrict R s) W n = cands s W n := by
  unfold cands restrict
  apply filter_filter_of
  intro c hc
  simp only [Bool.and_eq_true] at hc
  exact domT_trans hw hc.2

theorem ownOf_restrict_of {R W : TLabel} (hw : domT R W = true) (s : KState N V) (n : N) :
    ownOf (restrict R s) W n = ownOf s W n := by
  unfold ownOf restrict
  apply find_filter_of
  intro c hc
  simp only [Bool.and_eq_true, beq_iff_eq] at hc
  rw [hc.2]
  exact hw

theorem resolve_restrict_of {R W : TLabel} (hw : domT R W = true) (s : KState N V) (n : N) :
    resolve (restrict R s) W n = resolve s W n := by
  unfold resolve other
  rw [ownOf_restrict_of hw, cands_restrict_of hw]

theorem other_restrict_of {R W : TLabel} (hw : domT R W = true) (s : KState N V) (n : N) :
    other (restrict R s) W n = other s W n := by
  unfold other
  rw [cands_restrict_of hw]

end KeyModel

end Labels
