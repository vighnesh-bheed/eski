import Labels.Marking

namespace Labels

def trustLimit : Nat := 256

structure TLabel where
  sec : Label
  trust : Nat
deriving DecidableEq, Repr

def tbottom : TLabel := ⟨bottom, 0⟩

def domT (a b : TLabel) : Bool := dom a.sec b.sec && decide (a.trust ≤ b.trust)

def joinT (a b : TLabel) : TLabel := ⟨join a.sec b.sec, min a.trust b.trust⟩

def meetT (a b : TLabel) : TLabel := ⟨meet a.sec b.sec, max a.trust b.trust⟩

def trustCount (trusts : Nat) : Nat := max 1 trusts

def ValidT (levels comps trusts : Nat) (l : TLabel) : Prop := Valid levels comps l.sec ∧ l.trust < trustCount trusts

def ttop (levels comps : Nat) : TLabel := ⟨top levels comps, 0⟩

def tleast (trusts : Nat) : TLabel := ⟨bottom, trustCount trusts - 1⟩

def ceilingAdmits (c l : TLabel) : Bool := dom c.sec l.sec && decide (l.trust ≤ c.trust)

def ceilingSession (c : TLabel) : TLabel := ⟨c.sec, 0⟩

def compCount (l : TLabel) : Nat := (idsOf l.sec.comps compLimit).length

def rcmp (a b : TLabel) : Int :=
  if a.sec.level ≠ b.sec.level then (if b.sec.level < a.sec.level then 1 else -1)
  else if compCount a ≠ compCount b then (if compCount b < compCount a then 1 else -1)
  else if a.trust ≠ b.trust then (if b.trust < a.trust then 1 else -1)
  else 0

theorem domT_iff (a b : TLabel) : domT a b = true ↔ dom a.sec b.sec = true ∧ a.trust ≤ b.trust := by
  unfold domT
  rw [Bool.and_eq_true, decide_eq_true_iff]

theorem admission_iff (r d : TLabel) :
    domT r d = true ↔ d.sec.level ≤ r.sec.level ∧ (∀ i, d.sec.comps.testBit i = true → r.sec.comps.testBit i = true) ∧
      r.trust ≤ d.trust := by
  rw [domT_iff, dom_iff, and_assoc]

theorem tlabel_ext {a b : TLabel} (h1 : a.sec = b.sec) (h2 : a.trust = b.trust) : a = b := by
  cases a
  cases b
  simp only at h1 h2
  rw [h1, h2]

theorem domT_refl (a : TLabel) : domT a a = true :=
  (domT_iff a a).2 ⟨dom_refl _, Nat.le_refl _⟩

theorem domT_antisymm {a b : TLabel} (h1 : domT a b = true) (h2 : domT b a = true) : a = b := by
  rw [domT_iff] at h1 h2
  exact tlabel_ext (dom_antisymm h1.1 h2.1) (Nat.le_antisymm h1.2 h2.2)

theorem domT_trans {a b c : TLabel} (h1 : domT a b = true) (h2 : domT b c = true) : domT a c = true := by
  rw [domT_iff] at h1 h2 ⊢
  exact ⟨dom_trans h1.1 h2.1, Nat.le_trans h1.2 h2.2⟩

theorem domT_joinT_iff (a b c : TLabel) : domT c (joinT a b) = true ↔ domT c a = true ∧ domT c b = true := by
  simp only [domT_iff, joinT, dom_join_iff, Nat.le_min]
  constructor
  · intro ⟨⟨h1, h2⟩, h3, h4⟩
    exact ⟨⟨h1, h3⟩, ⟨h2, h4⟩⟩
  · intro ⟨⟨h1, h3⟩, ⟨h2, h4⟩⟩
    exact ⟨⟨h1, h2⟩, h3, h4⟩

theorem domT_meetT_iff (a b c : TLabel) : domT (meetT a b) c = true ↔ domT a c = true ∧ domT b c = true := by
  simp only [domT_iff, meetT, dom_meet_iff, Nat.max_le]
  constructor
  · intro ⟨⟨h1, h2⟩, h3, h4⟩
    exact ⟨⟨h1, h3⟩, ⟨h2, h4⟩⟩
  · intro ⟨⟨h1, h3⟩, ⟨h2, h4⟩⟩
    exact ⟨⟨h1, h2⟩, h3, h4⟩

theorem joinT_upper_left (a b : TLabel) : domT (joinT a b) a = true :=
  ((domT_joinT_iff a b (joinT a b)).1 (domT_refl _)).1

theorem joinT_upper_right (a b : TLabel) : domT (joinT a b) b = true :=
  ((domT_joinT_iff a b (joinT a b)).1 (domT_refl _)).2

theorem joinT_least {a b c : TLabel} (ha : domT c a = true) (hb : domT c b = true) : domT c (joinT a b) = true :=
  (domT_joinT_iff a b c).2 ⟨ha, hb⟩

theorem meetT_lower_left (a b : TLabel) : domT a (meetT a b) = true :=
  ((domT_meetT_iff a b (meetT a b)).1 (domT_refl _)).1

theorem meetT_lower_right (a b : TLabel) : domT b (meetT a b) = true :=
  ((domT_meetT_iff a b (meetT a b)).1 (domT_refl _)).2

theorem meetT_greatest {a b c : TLabel} (ha : domT a c = true) (hb : domT b c = true) : domT (meetT a b) c = true :=
  (domT_meetT_iff a b c).2 ⟨ha, hb⟩

theorem joinT_comm (a b : TLabel) : joinT a b = joinT b a :=
  tlabel_ext (join_comm _ _) (Nat.min_comm _ _)

theorem meetT_comm (a b : TLabel) : meetT a b = meetT b a :=
  tlabel_ext (meet_comm _ _) (Nat.max_comm _ _)

theorem joinT_assoc (a b c : TLabel) : joinT (joinT a b) c = joinT a (joinT b c) :=
  tlabel_ext (join_assoc _ _ _) (Nat.min_assoc _ _ _)

theorem meetT_assoc (a b c : TLabel) : meetT (meetT a b) c = meetT a (meetT b c) :=
  tlabel_ext (meet_assoc _ _ _) (Nat.max_assoc _ _ _)

theorem joinT_idem (a : TLabel) : joinT a a = a :=
  tlabel_ext (join_idem _) (Nat.min_self _)

theorem meetT_idem (a : TLabel) : meetT a a = a :=
  tlabel_ext (meet_idem _) (Nat.max_self _)

theorem joinT_meetT_absorb (a b : TLabel) : joinT a (meetT a b) = a :=
  tlabel_ext (join_meet_absorb _ _) (by simp only [joinT, meetT]; omega)

theorem meetT_joinT_absorb (a b : TLabel) : meetT a (joinT a b) = a :=
  tlabel_ext (meet_join_absorb _ _) (by simp only [joinT, meetT]; omega)

theorem meetT_joinT_distrib (a b c : TLabel) : meetT a (joinT b c) = joinT (meetT a b) (meetT a c) :=
  tlabel_ext (meet_join_distrib _ _ _) (by simp only [joinT, meetT]; omega)

theorem joinT_dom_iff (a b : TLabel) : joinT a b = a ↔ domT a b = true := by
  constructor
  · intro h; rw [← h]; exact joinT_upper_right a b
  · intro h; exact domT_antisymm (joinT_upper_left a b) (joinT_least (domT_refl a) h)

theorem meetT_dom_iff (a b : TLabel) : meetT a b = b ↔ domT a b = true := by
  constructor
  · intro h; rw [← h]; exact meetT_lower_left a b
  · intro h; exact domT_antisymm (meetT_greatest h (domT_refl b)) (meetT_lower_right a b)

theorem tbottom_least_untrusted {a : TLabel} (h : a.trust = 0) : domT a tbottom = true :=
  (domT_iff a tbottom).2 ⟨bottom_least _, by simp [tbottom, h]⟩

theorem tleast_least {levels comps trusts : Nat} {l : TLabel} (h : ValidT levels comps trusts l) :
    domT l (tleast trusts) = true :=
  (domT_iff l (tleast trusts)).2 ⟨bottom_least _, by show l.trust ≤ trustCount trusts - 1; have := h.2; omega⟩

theorem untrusted_reads_more {r d : TLabel} (h : domT r d = true) : domT ⟨r.sec, 0⟩ d = true :=
  (domT_iff _ _).2 ⟨((domT_iff r d).1 h).1, Nat.zero_le _⟩

theorem trusted_reads_trusted {r d : TLabel} (h : domT r d = true) : r.trust ≤ d.trust :=
  ((domT_iff r d).1 h).2

theorem lower_trust_hidden (s : Label) {t u : Nat} (h : u < t) : domT ⟨s, t⟩ ⟨s, u⟩ = false := by
  unfold domT
  simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not, Nat.not_le]
  exact Or.inr h

theorem validT_tbottom {levels comps trusts : Nat} (h : 0 < levels) : ValidT levels comps trusts tbottom :=
  ⟨valid_bottom h, by unfold trustCount; simp [tbottom]; omega⟩

theorem validT_joinT {levels comps trusts : Nat} {a b : TLabel} (ha : ValidT levels comps trusts a)
    (hb : ValidT levels comps trusts b) : ValidT levels comps trusts (joinT a b) :=
  ⟨valid_join ha.1 hb.1, by simp only [joinT]; have := ha.2; omega⟩

theorem validT_meetT {levels comps trusts : Nat} {a b : TLabel} (ha : ValidT levels comps trusts a)
    (hb : ValidT levels comps trusts b) : ValidT levels comps trusts (meetT a b) :=
  ⟨valid_meet ha.1 hb.1, by simp only [meetT]; have := ha.2; have := hb.2; omega⟩

theorem validT_ttop {levels comps trusts : Nat} (h : 0 < levels) : ValidT levels comps trusts (ttop levels comps) :=
  ⟨valid_top h, by unfold trustCount; simp [ttop]; omega⟩

theorem ttop_greatest {levels comps trusts : Nat} {l : TLabel} (h : ValidT levels comps trusts l) :
    domT (ttop levels comps) l = true :=
  (domT_iff _ _).2 ⟨top_greatest h.1, Nat.zero_le _⟩

theorem ceilingAdmits_iff (c l : TLabel) :
    ceilingAdmits c l = true ↔ dom c.sec l.sec = true ∧ l.trust ≤ c.trust := by
  unfold ceilingAdmits
  rw [Bool.and_eq_true, decide_eq_true_iff]

theorem ceiling_session_admitted (c : TLabel) : ceilingAdmits c (ceilingSession c) = true :=
  (ceilingAdmits_iff _ _).2 ⟨dom_refl _, Nat.zero_le _⟩

theorem ceiling_session_reads (c : TLabel) {l : TLabel} (h : ceilingAdmits c l = true) :
    domT (ceilingSession c) ⟨l.sec, l.trust⟩ = true :=
  (domT_iff _ _).2 ⟨((ceilingAdmits_iff c l).1 h).1, Nat.zero_le _⟩

theorem ceiling_trans {c a b : TLabel} (h1 : ceilingAdmits c a = true) (h2 : ceilingAdmits a b = true) :
    ceilingAdmits c b = true := by
  rw [ceilingAdmits_iff] at h1 h2 ⊢
  exact ⟨dom_trans h1.1 h2.1, Nat.le_trans h2.2 h1.2⟩

theorem ceiling_not_dominance : ceilingAdmits ⟨bottom, 1⟩ tbottom = true ∧ domT ⟨bottom, 1⟩ tbottom = false := by
  decide

theorem rcmp_refl (a : TLabel) : rcmp a a = 0 := by
  simp [rcmp]

theorem rcmp_antisymm (a b : TLabel) : rcmp a b = - rcmp b a := by
  unfold rcmp
  by_cases h1 : a.sec.level = b.sec.level
  · by_cases h2 : compCount a = compCount b
    · by_cases h3 : a.trust = b.trust
      · simp [h1, h2, h3]
      · have h3' : b.trust ≠ a.trust := fun e => h3 e.symm
        simp only [h1, h2, h3, h3', ne_eq, not_true_eq_false, not_false_eq_true, ↓reduceIte]
        by_cases h4 : b.trust < a.trust
        · have : ¬ a.trust < b.trust := by omega
          simp [h4, this]
        · have : a.trust < b.trust := by omega
          simp [h4, this]
    · have h2' : compCount b ≠ compCount a := fun e => h2 e.symm
      simp only [h1, h2, h2', ne_eq, not_true_eq_false, not_false_eq_true, ↓reduceIte]
      by_cases h4 : compCount b < compCount a
      · have : ¬ compCount a < compCount b := by omega
        simp [h4, this]
      · have : compCount a < compCount b := by omega
        simp [h4, this]
  · have h1' : b.sec.level ≠ a.sec.level := fun e => h1 e.symm
    simp only [h1, h1', ne_eq, not_false_eq_true, ↓reduceIte]
    by_cases h4 : b.sec.level < a.sec.level
    · have : ¬ a.sec.level < b.sec.level := by omega
      simp [h4, this]
    · have : a.sec.level < b.sec.level := by omega
      simp [h4, this]

theorem rcmp_pos_iff (a b : TLabel) :
    0 < rcmp a b ↔ b.sec.level < a.sec.level ∨ (a.sec.level = b.sec.level ∧ compCount b < compCount a) ∨
      (a.sec.level = b.sec.level ∧ compCount a = compCount b ∧ b.trust < a.trust) := by
  unfold rcmp
  by_cases h1 : a.sec.level = b.sec.level
  · by_cases h2 : compCount a = compCount b
    · by_cases h3 : a.trust = b.trust
      · simp [h1, h2, h3]
      · by_cases h4 : b.trust < a.trust
        · simp [h1, h2, h3, h4]
        · simp [h1, h2, h3, h4]
    · by_cases h4 : compCount b < compCount a
      · simp [h1, h2, h4]
      · simp [h1, h2, h4]
  · by_cases h4 : b.sec.level < a.sec.level
    · simp [h1, h4]
    · simp [h1, h4]

theorem rcmp_zero_iff (a b : TLabel) :
    rcmp a b = 0 ↔ a.sec.level = b.sec.level ∧ compCount a = compCount b ∧ a.trust = b.trust := by
  unfold rcmp
  by_cases h1 : a.sec.level = b.sec.level
  · by_cases h2 : compCount a = compCount b
    · by_cases h3 : a.trust = b.trust
      · simp [h1, h2, h3]
      · by_cases h4 : b.trust < a.trust <;> simp [h1, h2, h3, h4]
    · by_cases h4 : compCount b < compCount a <;> simp [h1, h2, h4]
  · by_cases h4 : b.sec.level < a.sec.level <;> simp [h1, h4]

end Labels
