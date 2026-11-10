namespace Labels

structure Label where
  level : Nat
  comps : Nat
deriving DecidableEq, Repr

def bottom : Label := ⟨0, 0⟩

def dom (a b : Label) : Bool := decide (b.level ≤ a.level) && (b.comps &&& a.comps == b.comps)

def join (a b : Label) : Label := ⟨max a.level b.level, a.comps ||| b.comps⟩

def meet (a b : Label) : Label := ⟨min a.level b.level, a.comps &&& b.comps⟩

def Valid (levels comps : Nat) (l : Label) : Prop := l.level < levels ∧ l.comps < 2 ^ comps

def top (levels comps : Nat) : Label := ⟨levels - 1, 2 ^ comps - 1⟩

theorem sub_iff (x y : Nat) : (x &&& y = x) ↔ ∀ i, x.testBit i = true → y.testBit i = true := by
  constructor
  · intro h i hx
    have := congrArg (fun n => n.testBit i) h
    simp only [Nat.testBit_and] at this
    rw [hx] at this
    simpa using this
  · intro h
    apply Nat.eq_of_testBit_eq
    intro i
    rw [Nat.testBit_and]
    cases hx : x.testBit i
    · simp
    · simp [h i hx]

theorem dom_iff (a b : Label) :
    dom a b = true ↔ b.level ≤ a.level ∧ ∀ i, b.comps.testBit i = true → a.comps.testBit i = true := by
  unfold dom
  rw [Bool.and_eq_true, decide_eq_true_iff, beq_iff_eq, sub_iff]

theorem label_ext {a b : Label} (hl : a.level = b.level) (hc : ∀ i, a.comps.testBit i = b.comps.testBit i) : a = b := by
  cases a; cases b
  simp only at hl hc
  rw [hl, Nat.eq_of_testBit_eq hc]

theorem dom_refl (a : Label) : dom a a = true := by
  rw [dom_iff]
  exact ⟨Nat.le_refl _, fun _ h => h⟩

theorem dom_antisymm {a b : Label} (h1 : dom a b = true) (h2 : dom b a = true) : a = b := by
  rw [dom_iff] at h1 h2
  apply label_ext (Nat.le_antisymm h2.1 h1.1)
  intro i
  cases ha : a.comps.testBit i <;> cases hb : b.comps.testBit i
  · rfl
  · have := h1.2 i hb; rw [ha] at this; exact this
  · have := h2.2 i ha; rw [hb] at this; exact this.symm
  · rfl

theorem dom_trans {a b c : Label} (h1 : dom a b = true) (h2 : dom b c = true) : dom a c = true := by
  rw [dom_iff] at h1 h2 ⊢
  exact ⟨Nat.le_trans h2.1 h1.1, fun i h => h1.2 i (h2.2 i h)⟩

theorem bottom_least (a : Label) : dom a bottom = true := by
  rw [dom_iff]
  exact ⟨Nat.zero_le _, fun i h => by simp [bottom] at h⟩

theorem dom_join_iff (a b c : Label) : dom c (join a b) = true ↔ dom c a = true ∧ dom c b = true := by
  simp only [dom_iff, join, Nat.testBit_or, Bool.or_eq_true, Nat.max_le]
  constructor
  · intro ⟨⟨h1, h2⟩, h3⟩
    exact ⟨⟨h1, fun i h => h3 i (Or.inl h)⟩, ⟨h2, fun i h => h3 i (Or.inr h)⟩⟩
  · intro ⟨⟨h1, h2⟩, ⟨h3, h4⟩⟩
    exact ⟨⟨h1, h3⟩, fun i h => h.elim (h2 i) (h4 i)⟩

theorem dom_meet_iff (a b c : Label) : dom (meet a b) c = true ↔ dom a c = true ∧ dom b c = true := by
  simp only [dom_iff, meet, Nat.testBit_and, Bool.and_eq_true, Nat.le_min]
  constructor
  · intro ⟨⟨h1, h2⟩, h3⟩
    exact ⟨⟨h1, fun i h => (h3 i h).1⟩, ⟨h2, fun i h => (h3 i h).2⟩⟩
  · intro ⟨⟨h1, h2⟩, ⟨h3, h4⟩⟩
    exact ⟨⟨h1, h3⟩, fun i h => ⟨h2 i h, h4 i h⟩⟩

theorem join_upper_left (a b : Label) : dom (join a b) a = true :=
  ((dom_join_iff a b (join a b)).1 (dom_refl _)).1

theorem join_upper_right (a b : Label) : dom (join a b) b = true :=
  ((dom_join_iff a b (join a b)).1 (dom_refl _)).2

theorem join_least {a b c : Label} (ha : dom c a = true) (hb : dom c b = true) : dom c (join a b) = true :=
  (dom_join_iff a b c).2 ⟨ha, hb⟩

theorem meet_lower_left (a b : Label) : dom a (meet a b) = true :=
  ((dom_meet_iff a b (meet a b)).1 (dom_refl _)).1

theorem meet_lower_right (a b : Label) : dom b (meet a b) = true :=
  ((dom_meet_iff a b (meet a b)).1 (dom_refl _)).2

theorem meet_greatest {a b c : Label} (ha : dom a c = true) (hb : dom b c = true) : dom (meet a b) c = true :=
  (dom_meet_iff a b c).2 ⟨ha, hb⟩

theorem join_comm (a b : Label) : join a b = join b a := by
  apply label_ext
  · exact Nat.max_comm _ _
  · intro i; simp only [join, Nat.testBit_or, Bool.or_comm]

theorem meet_comm (a b : Label) : meet a b = meet b a := by
  apply label_ext
  · exact Nat.min_comm _ _
  · intro i; simp only [meet, Nat.testBit_and, Bool.and_comm]

theorem join_assoc (a b c : Label) : join (join a b) c = join a (join b c) := by
  apply label_ext
  · exact Nat.max_assoc _ _ _
  · intro i; simp only [join, Nat.testBit_or, Bool.or_assoc]

theorem meet_assoc (a b c : Label) : meet (meet a b) c = meet a (meet b c) := by
  apply label_ext
  · exact Nat.min_assoc _ _ _
  · intro i; simp only [meet, Nat.testBit_and, Bool.and_assoc]

theorem join_idem (a : Label) : join a a = a :=
  label_ext (Nat.max_self _) (fun i => by simp only [join, Nat.testBit_or, Bool.or_self])

theorem meet_idem (a : Label) : meet a a = a :=
  label_ext (Nat.min_self _) (fun i => by simp only [meet, Nat.testBit_and, Bool.and_self])

theorem join_meet_absorb (a b : Label) : join a (meet a b) = a := by
  apply label_ext
  · simp only [join, meet]; omega
  · intro i; simp only [join, meet, Nat.testBit_or, Nat.testBit_and]; cases a.comps.testBit i <;> simp

theorem meet_join_absorb (a b : Label) : meet a (join a b) = a := by
  apply label_ext
  · simp only [join, meet]; omega
  · intro i; simp only [join, meet, Nat.testBit_or, Nat.testBit_and]; cases a.comps.testBit i <;> simp

theorem meet_join_distrib (a b c : Label) : meet a (join b c) = join (meet a b) (meet a c) := by
  apply label_ext
  · simp only [join, meet]; omega
  · intro i
    simp only [join, meet, Nat.testBit_or, Nat.testBit_and]
    cases a.comps.testBit i <;> cases b.comps.testBit i <;> cases c.comps.testBit i <;> rfl

theorem join_dom_iff (a b : Label) : join a b = a ↔ dom a b = true := by
  constructor
  · intro h; rw [← h]; exact join_upper_right a b
  · intro h; exact dom_antisymm (join_upper_left a b) (join_least (dom_refl a) h)

theorem meet_dom_iff (a b : Label) : meet a b = b ↔ dom a b = true := by
  constructor
  · intro h; rw [← h]; exact meet_lower_left a b
  · intro h; exact dom_antisymm (meet_greatest h (dom_refl b)) (meet_lower_right a b)

theorem valid_bottom {levels comps : Nat} (h : 0 < levels) : Valid levels comps bottom :=
  ⟨h, Nat.two_pow_pos _⟩

theorem valid_join {levels comps : Nat} {a b : Label} (ha : Valid levels comps a) (hb : Valid levels comps b) :
    Valid levels comps (join a b) :=
  ⟨Nat.max_lt.2 ⟨ha.1, hb.1⟩, Nat.or_lt_two_pow ha.2 hb.2⟩

theorem valid_meet {levels comps : Nat} {a b : Label} (ha : Valid levels comps a) (_hb : Valid levels comps b) :
    Valid levels comps (meet a b) :=
  ⟨Nat.lt_of_le_of_lt (Nat.min_le_left _ _) ha.1, Nat.lt_of_le_of_lt Nat.and_le_left ha.2⟩

theorem valid_top {levels comps : Nat} (h : 0 < levels) : Valid levels comps (top levels comps) :=
  ⟨by simp only [top]; omega, Nat.sub_lt (Nat.two_pow_pos _) (by decide)⟩

theorem top_greatest {levels comps : Nat} {l : Label} (h : Valid levels comps l) :
    dom (top levels comps) l = true := by
  rw [dom_iff]
  refine ⟨by simp only [top]; have := h.1; omega, fun i hi => ?_⟩
  have hlt : i < comps := by
    rcases Nat.lt_or_ge i comps with hlt | hge
    · exact hlt
    · have := Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le h.2 (Nat.pow_le_pow_right (by decide) hge))
      rw [this] at hi; exact absurd hi (by decide)
  simp only [top]
  rw [Nat.testBit_two_pow_sub_one]
  exact decide_eq_true hlt

end Labels
