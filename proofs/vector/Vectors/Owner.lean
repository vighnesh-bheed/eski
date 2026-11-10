import Vectors.Partition

set_option autoImplicit false

namespace Vectors

def SHARED : Nat := 0

def EVERY_OWNER : Nat := 4294967295

def ownerSees (o w : Nat) : Bool := w == SHARED || w == o

def ownerLe (w o : Nat) : Bool := w == SHARED || w == o || o == EVERY_OWNER

def accessValid (o : Nat) (stream : Bool) : Bool := o == SHARED || (o != EVERY_OWNER && stream)

theorem ownerLe_refl (o : Nat) : ownerLe o o = true := by
  simp [ownerLe]

theorem ownerLe_trans (a b c : Nat) (hab : ownerLe a b = true) (hbc : ownerLe b c = true) : ownerLe a c = true := by
  simp only [ownerLe, SHARED, EVERY_OWNER, Bool.or_eq_true, beq_iff_eq] at hab hbc ⊢
  omega

theorem ownerLe_antisymm (a b : Nat) (hab : ownerLe a b = true) (hba : ownerLe b a = true) : a = b := by
  simp only [ownerLe, SHARED, EVERY_OWNER, Bool.or_eq_true, beq_iff_eq] at hab hba
  omega

theorem shared_bottom (o : Nat) : ownerLe SHARED o = true := by
  simp [ownerLe]

theorem every_top (o : Nat) : ownerLe o EVERY_OWNER = true := by
  simp [ownerLe]

theorem users_incomparable (u v : Nat) (hu : u ≠ SHARED) (hv : v ≠ EVERY_OWNER) (huv : u ≠ v) :
    ownerLe u v = false := by
  simp only [ownerLe, Bool.or_eq_false_iff, beq_eq_false_iff_ne]
  exact ⟨⟨hu, huv⟩, hv⟩

theorem ownerSees_le (o w : Nat) (h : o ≠ EVERY_OWNER) : ownerSees o w = ownerLe w o := by
  simp only [ownerSees, ownerLe]
  have : (o == EVERY_OWNER) = false := by simpa using h
  rw [this, Bool.or_false]

theorem access_every (b : Bool) : accessValid EVERY_OWNER b = false := by
  simp [accessValid, SHARED, EVERY_OWNER]

theorem access_shared (b : Bool) : accessValid SHARED b = true := by
  simp [accessValid]

theorem access_user (o : Nat) (b : Bool) (hs : o ≠ SHARED) (he : o ≠ EVERY_OWNER) : accessValid o b = b := by
  have h1 : (o == SHARED) = false := by simpa using hs
  have h2 : (o != EVERY_OWNER) = true := by simpa using he
  simp only [accessValid, h1, h2, Bool.false_or, Bool.true_and]

section Scoped
set_option linter.unusedSectionVars false
variable {L : Type} [DecidableEq L]

def seesP (sees : L → L → Bool) (r d : L × Nat) : Bool := sees r.1 d.1 && ownerSees r.2 d.2

theorem seesP_iff (sees : L → L → Bool) (r d : L × Nat) :
    seesP sees r d = true ↔ sees r.1 d.1 = true ∧ (d.2 = SHARED ∨ d.2 = r.2) := by
  simp [seesP, ownerSees]

theorem seesP_hidden (sees : L → L → Bool) (r d : L × Nat) :
    seesP sees r d = false ↔ sees r.1 d.1 = false ∨ (d.2 ≠ SHARED ∧ d.2 ≠ r.2) := by
  have h := seesP_iff sees r d
  constructor
  · intro hf
    by_cases hv : sees r.1 d.1 = true
    · right
      constructor
      · intro e; rw [hf] at h; exact absurd (h.mpr ⟨hv, Or.inl e⟩) (by decide)
      · intro e; rw [hf] at h; exact absurd (h.mpr ⟨hv, Or.inr e⟩) (by decide)
    · left; simpa using hv
  · intro hd
    cases hq : seesP sees r d
    · rfl
    · rcases h.mp hq with ⟨h1, h2⟩
      rcases hd with e | ⟨e1, e2⟩
      · rw [h1] at e; exact absurd e (by decide)
      · rcases h2 with e | e
        · exact absurd e e1
        · exact absurd e e2

theorem seesP_product (sees : L → L → Bool) (r d : L × Nat) (h : r.2 ≠ EVERY_OWNER) :
    seesP sees r d = (sees r.1 d.1 && ownerLe d.2 r.2) := by
  unfold seesP
  rw [ownerSees_le r.2 d.2 h]

theorem seesP_sees (sees : L → L → Bool) (hs : Sees sees) : Sees (seesP sees) := by
  refine ⟨?_, ?_⟩
  · intro a
    rw [seesP_iff]
    exact ⟨hs.refl a.1, Or.inr rfl⟩
  · intro a b c hab hbc
    rw [seesP_iff] at hab hbc ⊢
    refine ⟨hs.trans _ _ _ hab.1 hbc.1, ?_⟩
    rcases hbc.2 with h | h
    · exact Or.inl h
    · rcases hab.2 with h' | h'
      · exact Or.inl (h.trans h')
      · exact Or.inr (h.trans h')

theorem seesP_refl (sees : L → L → Bool) (hs : Sees sees) (w : L × Nat) : seesP sees w w = true :=
  (seesP_sees sees hs).refl w

def gtP (gt : L → L → Bool) (x y : L × Nat) : Bool :=
  gt x.1 y.1 || (!gt y.1 x.1 && x.2 != SHARED && y.2 == SHARED)

theorem gtP_iff (gt : L → L → Bool) (x y : L × Nat) :
    gtP gt x y = true ↔ gt x.1 y.1 = true ∨ (gt y.1 x.1 = false ∧ x.2 ≠ SHARED ∧ y.2 = SHARED) := by
  simp [gtP, and_assoc]

theorem gtP_order (gt : L → L → Bool) (ho : RankOrder gt) : RankOrder (gtP gt) := by
  refine ⟨?_, ?_, ?_⟩
  · intro a
    cases h : gtP gt a a
    · rfl
    · rcases (gtP_iff gt a a).mp h with e | ⟨_, e1, e2⟩
      · rw [ho.irrefl] at e; exact absurd e (by decide)
      · exact absurd e2 e1
  · intro a b c hab hbc
    rw [gtP_iff] at hab hbc ⊢
    rcases hab with h1 | ⟨h1, h2, h3⟩ <;> rcases hbc with h4 | ⟨h4, h5, h6⟩
    · exact Or.inl (ho.trans _ _ _ h1 h4)
    · left
      rcases ho.neg_trans _ _ c.1 h1 with e | e
      · exact e
      · rw [h4] at e; exact absurd e (by decide)
    · left
      rcases ho.neg_trans _ _ a.1 h4 with e | e
      · rw [h1] at e; exact absurd e (by decide)
      · exact e
    · exact absurd h3 h5
  · intro a b c hab
    rw [gtP_iff] at hab
    rw [gtP_iff, gtP_iff]
    rcases hab with h1 | ⟨h1, h2, h3⟩
    · rcases ho.neg_trans _ _ c.1 h1 with e | e
      · exact Or.inl (Or.inl e)
      · exact Or.inr (Or.inl e)
    · cases hac : gt a.1 c.1
      · cases hcb : gt c.1 b.1
        · by_cases hcs : c.2 = SHARED
          · left; right
            refine ⟨?_, h2, hcs⟩
            cases hca : gt c.1 a.1
            · rfl
            · rcases ho.neg_trans _ _ b.1 hca with e | e
              · rw [hcb] at e; exact absurd e (by decide)
              · rw [h1] at e; exact absurd e (by decide)
          · right; right
            refine ⟨?_, hcs, h3⟩
            cases hbc : gt b.1 c.1
            · rfl
            · rcases ho.neg_trans _ _ a.1 hbc with e | e
              · rw [h1] at e; exact absurd e (by decide)
              · rw [hac] at e; exact absurd e (by decide)
        · exact Or.inr (Or.inl rfl)
      · exact Or.inl (Or.inl rfl)

def rankReader (sees : L → L → Bool) (gt : L → L → Bool) (w : L × Nat) : ReaderOf (L × Nat) :=
  ⟨w, seesP sees w, gtP gt⟩

theorem rankReader_own (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (w : L × Nat) :
    (rankReader sees gt w).vis (rankReader sees gt w).own = true :=
  seesP_refl sees hs w

theorem rankReader_order (sees gt : L → L → Bool) (ho : RankOrder gt) (w : L × Nat) :
    RankOrder (rankReader sees gt w).gt :=
  gtP_order gt ho

def exactIn (lab : L) : List (L × Nat) → Option (L × Nat)
  | [] => none
  | c :: cs => if c.1 = lab then some c else exactIn lab cs

def rankStep (vis : L × Nat → Bool) (gt : L → L → Bool) (b : Option (L × Nat)) (c : L × Nat) :
    Option (L × Nat) :=
  if vis c then
    match b with
    | none => some c
    | some x => if gt c.1 x.1 then some c else some x
  else b

def rankPass (vis : L × Nat → Bool) (gt : L → L → Bool) (cs : List (L × Nat)) (b : Option (L × Nat)) :
    Option (L × Nat) :=
  cs.foldl (rankStep vis gt) b

def rankScoped (sees gt : L → L → Bool) (w : L × Nat) (own shared : List (L × Nat)) : Option (L × Nat) :=
  if w.2 = SHARED then
    match exactIn w.1 shared with
    | some c => some c
    | none => rankPass (seesP sees w) gt shared none
  else
    match exactIn w.1 own with
    | some c => some c
    | none => rankPass (seesP sees w) gt shared (rankPass (seesP sees w) gt own none)

def rankRefusal (sees gt : L → L → Bool) (w : L × Nat) (own shared : List (L × Nat)) : Option (L × Nat) :=
  let skip := fun c : L × Nat => decide (c.1 ≠ w.1) && seesP sees w c
  if w.2 = SHARED then rankPass skip gt shared none
  else rankPass (seesP sees w) gt shared (rankPass skip gt own none)

def ownList (w : L × Nat) (ls : List (L × Nat)) : List (L × Nat) :=
  ls.filter (fun c => c.2 == w.2 && c.2 != SHARED)

def sharedList (ls : List (L × Nat)) : List (L × Nat) := ls.filter (fun c => c.2 == SHARED)

end Scoped

section Pick
set_option linter.unusedSectionVars false
variable {α : Type} [DecidableEq α]

def pickStep (r : ReaderOf α) (b : Option α) (c : α) : Option α :=
  if r.vis c then
    match b with
    | none => some c
    | some x => if r.gt c x then some c else some x
  else b

theorem resolveFrom_fold (r : ReaderOf α) : ∀ (ls : List α) (b : Option α), r.own ∉ ls →
    resolveFrom r ls b = ls.foldl (pickStep r) b := by
  intro ls
  induction ls with
  | nil => intro b _; rfl
  | cons c cs ih =>
    intro b hno
    have hc : c ≠ r.own := fun e => hno (e ▸ List.mem_cons_self ..)
    have hno' : r.own ∉ cs := fun e => hno (List.mem_cons_of_mem c e)
    rw [List.foldl_cons]
    by_cases hv : r.vis c = true
    · cases b with
      | none => simp only [resolveFrom, hc, hv, ↓reduceIte, pickStep]; exact ih _ hno'
      | some x =>
        by_cases hg : r.gt c x = true
        · simp only [resolveFrom, hc, hv, hg, ↓reduceIte, pickStep]; exact ih _ hno'
        · simp only [resolveFrom, hc, hv, hg, ↓reduceIte, pickStep, Bool.false_eq_true]; exact ih _ hno'
    · have hf : r.vis c = false := by simpa using hv
      simp only [resolveFrom, hc, hf, ↓reduceIte, pickStep, Bool.false_eq_true]
      exact ih _ hno'

theorem fold_filter_vis (r : ReaderOf α) : ∀ (ls : List α) (b : Option α),
    ls.foldl (pickStep r) b = (ls.filter r.vis).foldl (pickStep r) b := by
  intro ls
  induction ls with
  | nil => intro b; rfl
  | cons c cs ih =>
    intro b
    by_cases hv : r.vis c = true
    · rw [List.filter_cons_of_pos hv, List.foldl_cons, List.foldl_cons]
      exact ih _
    · have hf : r.vis c = false := by simpa using hv
      rw [List.filter_cons_of_neg hv, List.foldl_cons]
      have : pickStep r b c = b := by simp [pickStep, hf]
      rw [this]
      exact ih _

theorem pick_swap (r : ReaderOf α) (ho : RankOrder r.gt) (b : Option α) (x y : α)
    (hx : r.vis x = true) (hy : r.vis y = true) (hxy : r.gt x y = true ∨ r.gt y x = true) :
    pickStep r (pickStep r b x) y = pickStep r (pickStep r b y) x := by
  have asym : ∀ a c, r.gt a c = true → r.gt c a = false := by
    intro a c h
    cases h' : r.gt c a
    · rfl
    · have := ho.trans _ _ _ h h'
      rw [ho.irrefl] at this
      exact absurd this (by decide)
  cases b with
  | none =>
    rcases hxy with h | h
    · simp [pickStep, hx, hy, h, asym _ _ h]
    · simp [pickStep, hx, hy, h, asym _ _ h]
  | some z =>
    rcases hxy with h | h
    · cases hxz : r.gt x z
      · cases hyz : r.gt y z
        · simp [pickStep, hx, hy, hxz, hyz]
        · have := ho.trans _ _ _ h hyz
          rw [hxz] at this
          exact absurd this (by decide)
      · cases hyz : r.gt y z
        · simp [pickStep, hx, hy, hxz, hyz, asym _ _ h]
        · simp [pickStep, hx, hy, hxz, hyz, h, asym _ _ h]
    · cases hyz : r.gt y z
      · cases hxz : r.gt x z
        · simp [pickStep, hx, hy, hxz, hyz]
        · have := ho.trans _ _ _ h hxz
          rw [hyz] at this
          exact absurd this (by decide)
      · cases hxz : r.gt x z
        · simp [pickStep, hx, hy, hxz, hyz, asym _ _ h]
        · simp [pickStep, hx, hy, hxz, hyz, h, asym _ _ h]

theorem pick_past (r : ReaderOf α) (ho : RankOrder r.gt) (c : α) (hc : r.vis c = true) :
    ∀ (A : List α), (∀ a ∈ A, r.vis a = true ∧ (r.gt a c = true ∨ r.gt c a = true)) → ∀ (b : Option α),
      A.foldl (pickStep r) (pickStep r b c) = pickStep r (A.foldl (pickStep r) b) c := by
  intro A
  induction A with
  | nil => intro _ b; rfl
  | cons a A ih =>
    intro hA b
    have ha := hA a (List.mem_cons_self ..)
    rw [List.foldl_cons, List.foldl_cons, pick_swap r ho b c a hc ha.1 (ha.2.symm)]
    exact ih (fun x hx => hA x (List.mem_cons_of_mem a hx)) _

theorem fold_sort (r : ReaderOf α) (ho : RankOrder r.gt) (isA : α → Bool) : ∀ (V : List α),
    (∀ x ∈ V, r.vis x = true) →
    (∀ x ∈ V, ∀ y ∈ V, isA x = true → isA y = false → r.gt x y = true ∨ r.gt y x = true) → ∀ (b : Option α),
      V.foldl (pickStep r) b =
        (V.filter (fun x => !isA x)).foldl (pickStep r) ((V.filter isA).foldl (pickStep r) b) := by
  intro V
  induction V with
  | nil => intro _ _ b; rfl
  | cons c V ih =>
    intro hv hcmp b
    have hv' : ∀ x ∈ V, r.vis x = true := fun x hx => hv x (List.mem_cons_of_mem c hx)
    have hcmp' : ∀ x ∈ V, ∀ y ∈ V, isA x = true → isA y = false → r.gt x y = true ∨ r.gt y x = true :=
      fun x hx y hy => hcmp x (List.mem_cons_of_mem c hx) y (List.mem_cons_of_mem c hy)
    rw [List.foldl_cons]
    by_cases hA : isA c = true
    · rw [List.filter_cons_of_pos hA, List.filter_cons_of_neg (by simp [hA]), List.foldl_cons]
      exact ih hv' hcmp' _
    · have hA' : isA c = false := by simpa using hA
      rw [List.filter_cons_of_neg hA, List.filter_cons_of_pos (by simp [hA']), List.foldl_cons]
      rw [ih hv' hcmp' _]
      congr 1
      apply pick_past r ho c (hv c (List.mem_cons_self ..))
      intro a ha
      rw [List.mem_filter] at ha
      exact ⟨hv' a ha.1, hcmp a (List.mem_cons_of_mem c ha.1) c (List.mem_cons_self ..) ha.2 hA'⟩

end Pick

section Scoped2
set_option linter.unusedSectionVars false
variable {L : Type} [DecidableEq L]

theorem exactIn_some (lab : L) : ∀ (ls : List (L × Nat)) (c : L × Nat), exactIn lab ls = some c → c ∈ ls ∧ c.1 = lab := by
  intro ls
  induction ls with
  | nil => intro c h; simp [exactIn] at h
  | cons x xs ih =>
    intro c h
    unfold exactIn at h
    split at h
    · cases h; exact ⟨List.mem_cons_self .., by assumption⟩
    · have := ih c h
      exact ⟨List.mem_cons_of_mem x this.1, this.2⟩

theorem exactIn_none (lab : L) : ∀ (ls : List (L × Nat)), exactIn lab ls = none ↔ ∀ c ∈ ls, c.1 ≠ lab := by
  intro ls
  induction ls with
  | nil => simp [exactIn]
  | cons x xs ih =>
    unfold exactIn
    by_cases hx : x.1 = lab
    · simp only [hx, ↓reduceIte, reduceCtorEq, false_iff]
      intro h
      exact h x (List.mem_cons_self ..) hx
    · simp only [hx, ↓reduceIte, ih]
      constructor
      · intro h c hc
        rcases List.mem_cons.mp hc with e | e
        · rw [e]; exact hx
        · exact h c e
      · intro h c hc; exact h c (List.mem_cons_of_mem x hc)

theorem rankStep_pick_own (sees gt : L → L → Bool) (w : L × Nat) (b : Option (L × Nat))
    (hb : ∀ x, b = some x → x.2 ≠ SHARED) (c : L × Nat) :
    rankStep (seesP sees w) gt b c = pickStep (rankReader sees gt w) b c := by
  unfold rankStep pickStep rankReader
  simp only
  cases b with
  | none => rfl
  | some x =>
    have hx := hb x rfl
    have : gtP gt c x = gt c.1 x.1 := by
      have hx' : (x.2 == SHARED) = false := by simpa using hx
      simp [gtP, hx']
    dsimp only
    simp only [this]

theorem rankStep_pick_shared (sees gt : L → L → Bool) (w : L × Nat) (b : Option (L × Nat))
    (c : L × Nat) (hc : c.2 = SHARED) :
    rankStep (seesP sees w) gt b c = pickStep (rankReader sees gt w) b c := by
  unfold rankStep pickStep rankReader
  simp only
  cases b with
  | none => rfl
  | some x =>
    have : gtP gt c x = gt c.1 x.1 := by
      simp [gtP, hc]
    dsimp only
    simp only [this]

theorem rankPass_own (sees gt : L → L → Bool) (w : L × Nat) :
    ∀ (cs : List (L × Nat)), (∀ c ∈ cs, c.2 ≠ SHARED) → ∀ (b : Option (L × Nat)), (∀ x, b = some x → x.2 ≠ SHARED) →
      rankPass (seesP sees w) gt cs b = cs.foldl (pickStep (rankReader sees gt w)) b := by
  intro cs
  induction cs with
  | nil => intro _ b _; rfl
  | cons c cs ih =>
    intro hcs b hb
    have hc := hcs c (List.mem_cons_self ..)
    unfold rankPass at ih ⊢
    rw [List.foldl_cons, List.foldl_cons, rankStep_pick_own sees gt w b hb c]
    apply ih (fun x hx => hcs x (List.mem_cons_of_mem c hx))
    intro x hx
    unfold pickStep at hx
    split at hx
    · split at hx
      · cases hx; exact hc
      · split at hx
        · cases hx; exact hc
        · cases hx; exact hb _ rfl
    · exact hb x hx

theorem rankPass_shared (sees gt : L → L → Bool) (w : L × Nat) :
    ∀ (cs : List (L × Nat)), (∀ c ∈ cs, c.2 = SHARED) → ∀ (b : Option (L × Nat)),
      rankPass (seesP sees w) gt cs b = cs.foldl (pickStep (rankReader sees gt w)) b := by
  intro cs
  induction cs with
  | nil => intro _ b; rfl
  | cons c cs ih =>
    intro hcs b
    unfold rankPass at ih ⊢
    rw [List.foldl_cons, List.foldl_cons, rankStep_pick_shared sees gt w b c (hcs c (List.mem_cons_self ..))]
    exact ih (fun x hx => hcs x (List.mem_cons_of_mem c hx)) _

theorem visible_owner (sees : L → L → Bool) (w c : L × Nat) (h : seesP sees w c = true) :
    c.2 = SHARED ∨ c.2 = w.2 := ((seesP_iff sees w c).mp h).2

theorem rankScoped_eq (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (ho : RankOrder gt)
    (w : L × Nat) (ls : List (L × Nat)) :
    rankScoped sees gt w (ownList w ls) (sharedList ls) = resolveL (rankReader sees gt w) ls := by
  have hown := rankReader_own sees hs gt w
  have hord := rankReader_order sees gt ho w
  by_cases hin : w ∈ ls
  · rw [resolveL, resolveFrom_own _ ls none hin]
    unfold rankScoped
    by_cases hw : w.2 = SHARED
    · simp only [hw, ↓reduceIte]
      have hm : w ∈ sharedList ls := by
        unfold sharedList; rw [List.mem_filter]; exact ⟨hin, by simp [hw]⟩
      cases he : exactIn w.1 (sharedList ls) with
      | none =>
        have := (exactIn_none w.1 _).mp he w hm
        exact absurd rfl this
      | some c =>
        have hc := exactIn_some w.1 _ c he
        have hcs : c.2 = SHARED := by
          have := hc.1; unfold sharedList at this; rw [List.mem_filter] at this; simpa using this.2
        simp only [rankReader]
        congr 1
        exact Prod.ext hc.2 (hcs.trans hw.symm)
    · simp only [hw, ↓reduceIte]
      have hm : w ∈ ownList w ls := by
        unfold ownList; rw [List.mem_filter]; refine ⟨hin, ?_⟩; simp [hw]
      cases he : exactIn w.1 (ownList w ls) with
      | none =>
        have := (exactIn_none w.1 _).mp he w hm
        exact absurd rfl this
      | some c =>
        have hc := exactIn_some w.1 _ c he
        have hco : c.2 = w.2 := by
          have := hc.1; unfold ownList at this; rw [List.mem_filter] at this
          have h2 := this.2; simp at h2; exact h2.1
        simp only [rankReader]
        congr 1
        exact Prod.ext hc.2 hco
  · rw [resolveL, resolveFrom_fold _ ls none hin, fold_filter_vis]
    have hvis : ∀ x ∈ ls.filter (rankReader sees gt w).vis, (rankReader sees gt w).vis x = true := by
      intro x hx; rw [List.mem_filter] at hx; exact hx.2
    have hnoexact : ∀ (l : List (L × Nat)), (∀ c ∈ l, c ∈ ls ∧ c.2 = w.2) → exactIn w.1 l = none := by
      intro l hl
      rw [exactIn_none]
      intro c hc e
      have := hl c hc
      exact hin (Prod.ext e this.2 ▸ this.1)
    unfold rankScoped
    by_cases hw : w.2 = SHARED
    · simp only [hw, ↓reduceIte]
      rw [hnoexact (sharedList ls) (by
        intro c hc; unfold sharedList at hc; rw [List.mem_filter] at hc
        exact ⟨hc.1, by have := hc.2; simp at this; rw [this, hw]⟩)]
      simp only
      rw [rankPass_shared sees gt w _ (by intro c hc; unfold sharedList at hc; rw [List.mem_filter] at hc; simpa using hc.2)]
      rw [fold_filter_vis]
      unfold sharedList
      congr 1
      rw [List.filter_filter]
      apply List.filter_congr
      intro c hc
      cases hv : (rankReader sees gt w).vis c
      · simp
      · have := visible_owner sees w c hv
        simp only [Bool.true_and]
        rcases this with e | e
        · simp [e]
        · simp [e, hw]
    · simp only [hw, ↓reduceIte]
      rw [hnoexact (ownList w ls) (by
        intro c hc; unfold ownList at hc; rw [List.mem_filter] at hc
        exact ⟨hc.1, by have := hc.2; simp at this; exact this.1⟩)]
      simp only
      rw [rankPass_own sees gt w _ (by
        intro c hc; unfold ownList at hc; rw [List.mem_filter] at hc; simp at hc; exact hc.2.2) none (by simp)]
      rw [rankPass_shared sees gt w _ (by intro c hc; unfold sharedList at hc; rw [List.mem_filter] at hc; simpa using hc.2)]
      rw [fold_filter_vis _ (ownList w ls), fold_filter_vis _ (sharedList ls)]
      have hsplit := fold_sort (rankReader sees gt w) hord (fun c => c.2 != SHARED) (ls.filter (rankReader sees gt w).vis)
        hvis (by
          intro x hx y hy hxs hys
          have hxs' : x.2 ≠ SHARED := by simpa using hxs
          have hys' : y.2 = SHARED := by simpa using hys
          by_cases hg : gt x.1 y.1 = true
          · left; simp [rankReader, gtP, hg]
          · cases hyx : gt y.1 x.1
            · left
              have hg' : gt x.1 y.1 = false := by simpa using hg
              simp [rankReader, gtP, hg', hyx, hxs', hys']
            · right; simp [rankReader, gtP, hyx]) none
      rw [hsplit]
      have e1 : (ownList w ls).filter (rankReader sees gt w).vis =
          (ls.filter (rankReader sees gt w).vis).filter (fun c => c.2 != SHARED) := by
        unfold ownList
        rw [List.filter_filter, List.filter_filter]
        apply List.filter_congr
        intro c _
        cases hv : (rankReader sees gt w).vis c
        · simp
        · rcases visible_owner sees w c hv with e | e
          · simp [e]
          · simp [e]
      have e2 : (sharedList ls).filter (rankReader sees gt w).vis =
          (ls.filter (rankReader sees gt w).vis).filter (fun c => !(c.2 != SHARED)) := by
        unfold sharedList
        rw [List.filter_filter, List.filter_filter]
        apply List.filter_congr
        intro c _
        cases hv : (rankReader sees gt w).vis c
        · simp
        · simp [bne]
      rw [e1, e2]

theorem rankPass_congr (gt : L → L → Bool) (v₁ v₂ : L × Nat → Bool) : ∀ (cs : List (L × Nat)),
    (∀ c ∈ cs, v₁ c = v₂ c) → ∀ (b : Option (L × Nat)), rankPass v₁ gt cs b = rankPass v₂ gt cs b := by
  intro cs
  induction cs with
  | nil => intro _ b; rfl
  | cons c cs ih =>
    intro h b
    unfold rankPass at ih ⊢
    rw [List.foldl_cons, List.foldl_cons]
    have : rankStep v₁ gt b c = rankStep v₂ gt b c := by
      unfold rankStep; rw [h c (List.mem_cons_self ..)]
    rw [this]
    exact ih (fun x hx => h x (List.mem_cons_of_mem c hx)) _

theorem rankRefusal_eq (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (ho : RankOrder gt)
    (w : L × Nat) (ls : List (L × Nat)) (hno : w ∉ ls) :
    rankRefusal sees gt w (ownList w ls) (sharedList ls) = resolveL (rankReader sees gt w) ls := by
  rw [← rankScoped_eq sees hs gt ho w ls]
  have skip_eq : ∀ (l : List (L × Nat)), (∀ c ∈ l, c ∈ ls ∧ c.2 = w.2) →
      ∀ c ∈ l, (decide (c.1 ≠ w.1) && seesP sees w c) = seesP sees w c := by
    intro l hl c hc
    have hcl := hl c hc
    have : c.1 ≠ w.1 := fun e => hno (Prod.ext e hcl.2 ▸ hcl.1)
    simp [this]
  have hnoexact : ∀ (l : List (L × Nat)), (∀ c ∈ l, c ∈ ls ∧ c.2 = w.2) → exactIn w.1 l = none := by
    intro l hl
    rw [exactIn_none]
    intro c hc e
    have := hl c hc
    exact hno (Prod.ext e this.2 ▸ this.1)
  have hsh : ∀ c ∈ sharedList ls, c ∈ ls ∧ c.2 = SHARED := by
    intro c hc; unfold sharedList at hc; rw [List.mem_filter] at hc; exact ⟨hc.1, by simpa using hc.2⟩
  have how : ∀ c ∈ ownList w ls, c ∈ ls ∧ c.2 = w.2 := by
    intro c hc; unfold ownList at hc; rw [List.mem_filter] at hc
    have h2 := hc.2; simp at h2; exact ⟨hc.1, h2.1⟩
  unfold rankRefusal rankScoped
  by_cases hw : w.2 = SHARED
  · simp only [hw, ↓reduceIte]
    have hsh' : ∀ c ∈ sharedList ls, c ∈ ls ∧ c.2 = w.2 := fun c hc => ⟨(hsh c hc).1, (hsh c hc).2.trans hw.symm⟩
    rw [hnoexact _ hsh']
    exact rankPass_congr gt _ _ _ (skip_eq _ hsh') none
  · simp only [hw, ↓reduceIte]
    rw [hnoexact _ how]
    simp only
    rw [rankPass_congr gt _ (seesP sees w) _ (skip_eq _ how) none]

theorem resolveFrom_congr {α : Type} [DecidableEq α] (r₁ r₂ : ReaderOf α) (S : List α)
    (hown : ∀ x ∈ S, (x = r₁.own ↔ x = r₂.own))
    (hvis : ∀ x ∈ S, r₁.vis x = r₂.vis x) (hgt : ∀ x ∈ S, ∀ y ∈ S, r₁.gt x y = r₂.gt x y) :
    ∀ (ls : List α) (b : Option α), (∀ x ∈ ls, x ∈ S) → (∀ x, b = some x → x ∈ S) →
      resolveFrom r₁ ls b = resolveFrom r₂ ls b := by
  intro ls
  induction ls with
  | nil => intro b _ _; rfl
  | cons c cs ih =>
    intro b hls hb
    have hc := hls c (List.mem_cons_self ..)
    have hcs : ∀ x ∈ cs, x ∈ S := fun x hx => hls x (List.mem_cons_of_mem c hx)
    have hiff := hown c hc
    unfold resolveFrom
    by_cases h1 : c = r₁.own
    · rw [ite_eq_left h1, ite_eq_left (hiff.mp h1)]
    · rw [ite_eq_right h1, ite_eq_right (fun e => h1 (hiff.mpr e)), hvis c hc]
      cases hv : r₂.vis c
      · simp only [Bool.false_eq_true, ↓reduceIte]
        exact ih b hcs hb
      · simp only [↓reduceIte]
        cases b with
        | none => exact ih (some c) hcs (fun x hx => by cases hx; exact hc)
        | some x =>
          have hx := hb x rfl
          simp only
          rw [hgt c hc x hx]
          split
          · exact ih (some c) hcs (fun y hy => by cases hy; exact hc)
          · exact ih (some x) hcs (fun y hy => by cases hy; exact hx)

theorem resolveFrom_keep_top {α : Type} [DecidableEq α] (r : ReaderOf α) (t : α) (htop : ∀ x, r.gt x t = false) :
    ∀ (ls : List α), r.own ∉ ls → resolveFrom r ls (some t) = some t := by
  intro ls
  induction ls with
  | nil => intro _; rfl
  | cons c cs ih =>
    intro hno
    have hc : c ≠ r.own := fun e => hno (e ▸ List.mem_cons_self ..)
    have hno' : r.own ∉ cs := fun e => hno (List.mem_cons_of_mem c e)
    unfold resolveFrom
    simp only [hc, ↓reduceIte, htop c, Bool.false_eq_true]
    split <;> exact ih hno'

theorem resolveFrom_top {α : Type} [DecidableEq α] (r : ReaderOf α) (t : α) (hvt : r.vis t = true)
    (htop : ∀ x, r.gt x t = false) (hbeat : ∀ y, y ≠ t → r.gt t y = true) :
    ∀ (ls : List α) (b : Option α), t ∈ ls → r.own ∉ ls → resolveFrom r ls b = some t := by
  intro ls
  induction ls with
  | nil => intro b h; simp at h
  | cons c cs ih =>
    intro b hm hno
    have hc : c ≠ r.own := fun e => hno (e ▸ List.mem_cons_self ..)
    have hno' : r.own ∉ cs := fun e => hno (List.mem_cons_of_mem c e)
    by_cases hct : c = t
    · subst hct
      unfold resolveFrom
      simp only [hc, ↓reduceIte, hvt]
      cases b with
      | none => exact resolveFrom_keep_top r c htop cs hno'
      | some x =>
        simp only
        by_cases hx : x = c
        · subst hx
          simp only [htop, Bool.false_eq_true, ↓reduceIte]
          exact resolveFrom_keep_top r x htop cs hno'
        · simp only [hbeat x hx, ↓reduceIte]
          exact resolveFrom_keep_top r c htop cs hno'
    · have hm' : t ∈ cs := by
        rcases List.mem_cons.mp hm with e | e
        · exact absurd e.symm hct
        · exact e
      unfold resolveFrom
      simp only [hc, ↓reduceIte]
      split
      · split
        · exact ih _ hm' hno'
        · split <;> exact ih _ hm' hno'
      · exact ih _ hm' hno'

def gtX (gt : L → L → Bool) (w : L × Nat) (x y : L × Nat) : Bool :=
  if y = (w.1, SHARED) then false else if x = (w.1, SHARED) then true else gtP gt x y

theorem gtX_order (gt : L → L → Bool) (ho : RankOrder gt) (w : L × Nat) : RankOrder (gtX gt w) := by
  have hp := gtP_order gt ho
  refine ⟨?_, ?_, ?_⟩
  · intro a
    unfold gtX
    by_cases h : a = (w.1, SHARED)
    · simp [h]
    · simp [h, hp.irrefl]
  · intro a b c hab hbc
    unfold gtX at hab hbc ⊢
    by_cases hc : c = (w.1, SHARED)
    · simp [hc] at hbc
    · by_cases ha : a = (w.1, SHARED)
      · simp [hc, ha]
      · by_cases hb : b = (w.1, SHARED)
        · simp [hb] at hab
        · simp only [ha, hb, hc, ↓reduceIte] at hab hbc ⊢
          exact hp.trans _ _ _ hab hbc
  · intro a b c hab
    unfold gtX at hab ⊢
    by_cases hb : b = (w.1, SHARED)
    · simp [hb] at hab
    · by_cases hc : c = (w.1, SHARED)
      · right; simp [hc, hb]
      · by_cases ha : a = (w.1, SHARED)
        · left; simp [hc, ha]
        · simp only [ha, hb, ↓reduceIte] at hab
          rcases hp.neg_trans _ _ c hab with e | e
          · left; simp [hc, ha, e]
          · right; simp [hc, hb, e]

def readerP (sees : L → L → Bool) (gt : L → L → Bool) (w : L × Nat) : ReaderOf (L × Nat) :=
  ⟨w, seesP sees w, gtX gt w⟩

theorem readerP_writer (sees gt : L → L → Bool) (w : L × Nat) :
    readerP sees gt w = writerOf (seesP sees) (gtX gt w) w := rfl

theorem readerP_own (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (w : L × Nat) :
    (readerP sees gt w).vis (readerP sees gt w).own = true :=
  seesP_refl sees hs w

theorem readerP_order (sees gt : L → L → Bool) (ho : RankOrder gt) (w : L × Nat) :
    RankOrder (readerP sees gt w).gt :=
  gtX_order gt ho w

theorem resolve_falls_to_rank (sees gt : L → L → Bool) (w : L × Nat) (ls : List (L × Nat))
    (hns : (w.1, SHARED) ∉ ls) : resolveL (readerP sees gt w) ls = resolveL (rankReader sees gt w) ls := by
  unfold resolveL
  refine resolveFrom_congr (readerP sees gt w) (rankReader sees gt w) ls (fun _ _ => Iff.rfl) (fun _ _ => rfl) ?_ ls none
    (fun x hx => hx) (fun x hx => by cases hx)
  intro x hx y hy
  have h1 : y ≠ (w.1, SHARED) := fun e => hns (e ▸ hy)
  have h2 : x ≠ (w.1, SHARED) := fun e => hns (e ▸ hx)
  simp [readerP, rankReader, gtX, h1, h2]

theorem resolve_shared_exact (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (w : L × Nat)
    (ls : List (L × Nat)) (hno : w ∉ ls) (hin : (w.1, SHARED) ∈ ls) :
    resolveL (readerP sees gt w) ls = some (w.1, SHARED) := by
  apply resolveFrom_top _ _ _ _ _ ls none hin hno
  · show seesP sees w (w.1, SHARED) = true
    rw [seesP_iff]; exact ⟨hs.refl w.1, Or.inl rfl⟩
  · intro x; simp [readerP, gtX]
  · intro y hy; simp [readerP, gtX, hy]

def resolveScoped (sees gt : L → L → Bool) (w : L × Nat) (own shared : List (L × Nat)) : Option (L × Nat) :=
  if w.2 = SHARED then rankScoped sees gt w own shared
  else
    match exactIn w.1 own with
    | some c => some c
    | none =>
      match exactIn w.1 shared with
      | some c => some c
      | none => rankScoped sees gt w own shared

def refusalScoped (sees gt : L → L → Bool) (w : L × Nat) (own shared : List (L × Nat)) : Option (L × Nat) :=
  if w.2 = SHARED then rankRefusal sees gt w own shared
  else
    match exactIn w.1 shared with
    | some c => some c
    | none => rankRefusal sees gt w own shared

theorem sharedList_exact (w : L × Nat) (ls : List (L × Nat)) :
    exactIn w.1 (sharedList ls) = (if (w.1, SHARED) ∈ ls then some (w.1, SHARED) else none) := by
  by_cases hin : (w.1, SHARED) ∈ ls
  · simp only [hin, ↓reduceIte]
    cases he : exactIn w.1 (sharedList ls) with
    | none =>
      have := (exactIn_none w.1 _).mp he (w.1, SHARED) (by unfold sharedList; rw [List.mem_filter]; exact ⟨hin, by simp⟩)
      exact absurd rfl this
    | some c =>
      have hc := exactIn_some w.1 _ c he
      unfold sharedList at hc
      rw [List.mem_filter] at hc
      have : c.2 = SHARED := by simpa using hc.1.2
      exact congrArg some (Prod.ext hc.2 this)
  · simp only [hin, ↓reduceIte]
    rw [exactIn_none]
    intro c hc e
    unfold sharedList at hc
    rw [List.mem_filter] at hc
    have h2 : c.2 = SHARED := by simpa using hc.2
    have hceq : c = (w.1, SHARED) := Prod.ext e h2
    exact hin (hceq ▸ hc.1)

theorem ownList_exact_none (w : L × Nat) (ls : List (L × Nat)) (hno : w ∉ ls) : exactIn w.1 (ownList w ls) = none := by
  rw [exactIn_none]
  intro c hc e
  unfold ownList at hc
  rw [List.mem_filter] at hc
  have h2 := hc.2
  simp at h2
  exact hno (Prod.ext e h2.1 ▸ hc.1)

theorem resolveScoped_eq (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (ho : RankOrder gt)
    (w : L × Nat) (ls : List (L × Nat)) :
    resolveScoped sees gt w (ownList w ls) (sharedList ls) = resolveL (readerP sees gt w) ls := by
  by_cases hin : w ∈ ls
  · have hr : resolveL (readerP sees gt w) ls = some w := resolve_own _ ls hin
    have hk : resolveL (rankReader sees gt w) ls = some w := resolve_own _ ls hin
    rw [hr, ← hk, ← rankScoped_eq sees hs gt ho w ls]
    unfold resolveScoped
    by_cases hw : w.2 = SHARED
    · simp only [hw, ↓reduceIte]
    · simp only [hw, ↓reduceIte]
      have hm : w ∈ ownList w ls := by
        unfold ownList; rw [List.mem_filter]; refine ⟨hin, ?_⟩; simp [hw]
      cases he : exactIn w.1 (ownList w ls) with
      | none => exact absurd rfl ((exactIn_none w.1 _).mp he w hm)
      | some c =>
        simp only
        unfold rankScoped
        simp only [hw, ↓reduceIte, he]
  · unfold resolveScoped
    by_cases hw : w.2 = SHARED
    · simp only [hw, ↓reduceIte]
      have hns : (w.1, SHARED) ∉ ls := by
        intro e; exact hin (by rw [← hw] at e; exact e)
      rw [resolve_falls_to_rank sees gt w ls hns]
      exact rankScoped_eq sees hs gt ho w ls
    · simp only [hw, ↓reduceIte, ownList_exact_none w ls hin, sharedList_exact w ls]
      by_cases hns : (w.1, SHARED) ∈ ls
      · simp only [hns, ↓reduceIte]
        exact (resolve_shared_exact sees hs gt w ls hin hns).symm
      · simp only [hns, ↓reduceIte]
        rw [resolve_falls_to_rank sees gt w ls hns]
        exact rankScoped_eq sees hs gt ho w ls

theorem refusal_eq (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (ho : RankOrder gt)
    (w : L × Nat) (ls : List (L × Nat)) (hno : w ∉ ls) :
    refusalScoped sees gt w (ownList w ls) (sharedList ls) = resolveL (readerP sees gt w) ls := by
  unfold refusalScoped
  by_cases hw : w.2 = SHARED
  · simp only [hw, ↓reduceIte]
    have hns : (w.1, SHARED) ∉ ls := by
      intro e; exact hno (by rw [← hw] at e; exact e)
    rw [resolve_falls_to_rank sees gt w ls hns]
    exact rankRefusal_eq sees hs gt ho w ls hno
  · simp only [hw, ↓reduceIte, sharedList_exact w ls]
    by_cases hns : (w.1, SHARED) ∈ ls
    · simp only [hns, ↓reduceIte]
      exact (resolve_shared_exact sees hs gt w ls hno hns).symm
    · simp only [hns, ↓reduceIte]
      rw [resolve_falls_to_rank sees gt w ls hns]
      exact rankRefusal_eq sees hs gt ho w ls hno

theorem refusal_iff (sees : L → L → Bool) (gt : L → L → Bool) (w : L × Nat) (ls : List (L × Nat)) (hno : w ∉ ls) :
    visibleOther (seesP sees) w ls = true ↔ (resolveL (readerP sees gt w) ls).isSome = true := by
  unfold visibleOther
  rw [List.any_eq_true]
  constructor
  · intro ⟨c, hc, hv⟩
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hv
    cases hr : resolveL (readerP sees gt w) ls with
    | none =>
      have := ((resolve_none_iff _ ls).mp hr c hc).2
      simp only [readerP] at this
      rw [hv.2] at this
      exact absurd this (by decide)
    | some _ => rfl
  · intro h
    cases hr : resolveL (readerP sees gt w) ls with
    | none => rw [hr] at h; simp at h
    | some c =>
      have hm := resolve_mem _ ls c hr
      have hne : c ≠ w := fun e => hno (e ▸ hm.1)
      refine ⟨c, hm.1, ?_⟩
      rcases hm.2 with e | e
      · exact absurd e hne
      · simp only [Bool.and_eq_true, decide_eq_true_eq]
        exact ⟨hne, e⟩

theorem inuse_names_resolved (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (ho : RankOrder gt)
    (w : L × Nat) (ls : List (L × Nat)) (hno : w ∉ ls) (hv : visibleOther (seesP sees) w ls = true) :
    ∃ c, refusalScoped sees gt w (ownList w ls) (sharedList ls) = some c ∧
      resolveL (readerP sees gt w) ls = some c ∧ c ∈ ls ∧ seesP sees w c = true := by
  have hsome := (refusal_iff sees gt w ls hno).mp hv
  cases hr : resolveL (readerP sees gt w) ls with
  | none => rw [hr] at hsome; simp at hsome
  | some c =>
    refine ⟨c, by rw [refusal_eq sees hs gt ho w ls hno, hr], rfl, ?_⟩
    have hm := resolve_mem _ ls c hr
    refine ⟨hm.1, ?_⟩
    rcases hm.2 with e | e
    · have e' : c = w := e
      exact absurd (e' ▸ hm.1) hno
    · exact e

theorem resolve_owner_result (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (w : L × Nat)
    (ls : List (L × Nat)) (c : L × Nat) (h : resolveL (readerP sees gt w) ls = some c) :
    c ∈ ls ∧ sees w.1 c.1 = true ∧ (c.2 = SHARED ∨ c.2 = w.2) := by
  have hm := resolve_mem _ ls c h
  have hv : seesP sees w c = true := by
    rcases hm.2 with e | e
    · have : c = w := e
      rw [this]; exact seesP_refl sees hs w
    · exact e
  exact ⟨hm.1, ((seesP_iff sees w c).mp hv).1, ((seesP_iff sees w c).mp hv).2⟩

theorem resolve_rank_max (sees : L → L → Bool) (gt : L → L → Bool) (ho : RankOrder gt) (w : L × Nat)
    (ls : List (L × Nat)) (hno : w ∉ ls) (hns : (w.1, SHARED) ∉ ls) (c : L × Nat)
    (h : resolveL (readerP sees gt w) ls = some c) :
    ∀ d ∈ ls, seesP sees w d = true → gt d.1 c.1 = false := by
  rw [resolve_falls_to_rank sees gt w ls hns] at h
  have hh := resolve_highest _ (rankReader_order sees gt ho w) ls c hno h
  intro d hd hv
  have := hh.2 d hd hv
  simp only [rankReader, gtP, Bool.or_eq_false_iff] at this
  exact this.1

theorem resolve_own_tie (sees : L → L → Bool) (gt : L → L → Bool) (ho : RankOrder gt) (w : L × Nat)
    (ls : List (L × Nat)) (hno : w ∉ ls) (hns : (w.1, SHARED) ∉ ls) (c : L × Nat)
    (h : resolveL (readerP sees gt w) ls = some c)
    (hc : c.2 = SHARED) (d : L × Nat) (hd : d ∈ ls) (hdv : seesP sees w d = true) (hdo : d.2 ≠ SHARED) :
    gt c.1 d.1 = true := by
  rw [resolve_falls_to_rank sees gt w ls hns] at h
  have hh := resolve_highest _ (rankReader_order sees gt ho w) ls c hno h
  have := hh.2 d hd hdv
  simp only [rankReader] at this
  cases hcd : gt c.1 d.1
  · have hdc : gt d.1 c.1 = false := by
      simp only [gtP, Bool.or_eq_false_iff] at this; exact this.1
    have : gtP gt d c = true := by
      rw [gtP_iff]; exact Or.inr ⟨hcd, hdo, hc⟩
    simp_all
  · rfl

theorem resolve_scope_older (sees : L → L → Bool) (gt : L → L → Bool) (ho : RankOrder gt) (w : L × Nat)
    (ls : List (L × Nat)) (hno : w ∉ ls) (hns : (w.1, SHARED) ∉ ls) (c : L × Nat)
    (h : resolveL (readerP sees gt w) ls = some c) :
    ∃ pre post, ls = pre ++ c :: post ∧
      ∀ d ∈ pre, seesP sees w d = true → d.2 = c.2 → gt c.1 d.1 = true := by
  rw [resolve_falls_to_rank sees gt w ls hns] at h
  rcases resolve_older _ (rankReader_order sees gt ho w) ls c hno h with ⟨pre, post, hl, hd⟩
  refine ⟨pre, post, hl, ?_⟩
  intro d hdm hdv hdo
  have := hd d hdm hdv
  simp only [rankReader] at this
  rw [gtP_iff] at this
  rcases this with e | ⟨_, e1, e2⟩
  · exact e
  · rw [hdo] at e2; exact absurd e2 e1

theorem resolve_other_owners (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (w : L × Nat)
    (l₁ l₂ : List (L × Nat)) (h : l₁.filter (fun c => ownerSees w.2 c.2) = l₂.filter (fun c => ownerSees w.2 c.2)) :
    resolveL (readerP sees gt w) l₁ = resolveL (readerP sees gt w) l₂ := by
  apply resolve_congr _ (readerP_own sees hs gt w)
  have key : ∀ (l : List (L × Nat)), l.filter (readerP sees gt w).vis =
      (l.filter (fun c => ownerSees w.2 c.2)).filter (fun c => sees w.1 c.1) := by
    intro l
    rw [List.filter_filter]
    apply List.filter_congr
    intro c _
    simp only [readerP, seesP]
  rw [key l₁, key l₂, h]

theorem owner_viewOpen_restrict {N P : Type} [DecidableEq N] (sees : L → L → Bool) (hs : Sees sees)
    (gt : L → L → Bool) (acc : PartAcc N P) (le : L × Nat → L × Nat → Bool) (labelsU : List (L × Nat))
    (namesU : List N) (w : L × Nat) (s : LState (L × Nat) N P) :
    viewOpen acc le labelsU namesU (readerP sees gt w) (restrict (readerP sees gt w) s) =
      viewOpen acc le labelsU namesU (readerP sees gt w) s :=
  viewOpen_restrict acc le labelsU namesU _ (readerP_own sees hs gt w) s

theorem owner_viewFind_restrict {N P : Type} [DecidableEq N] (sees : L → L → Bool) (hs : Sees sees)
    (gt : L → L → Bool) (w : L × Nat) (s : LState (L × Nat) N P) (n : N) :
    viewFind (readerP sees gt w) (restrict (readerP sees gt w) s) n = viewFind (readerP sees gt w) s n :=
  viewFind_restrict _ (readerP_own sees hs gt w) s n

theorem owner_viewRange_restrict {N P : Type} [DecidableEq N] (sees : L → L → Bool) (hs : Sees sees)
    (gt : L → L → Bool) (w : L × Nat) (s : LState (L × Nat) N P) (namesU : List N) (inRange : N → Bool)
    (limit : Option Nat) :
    viewRange (readerP sees gt w) (restrict (readerP sees gt w) s) namesU inRange limit =
      viewRange (readerP sees gt w) s namesU inRange limit :=
  viewRange_restrict _ (readerP_own sees hs gt w) s namesU inRange limit

theorem one_label_own_then_shared (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (l : L) (o : Nat)
    (ls : List (L × Nat)) (hls : ∀ c ∈ ls, c = (l, o) ∨ c = (l, SHARED)) :
    resolveL (readerP sees gt (l, o)) ls =
      if (l, o) ∈ ls then some (l, o) else if (l, SHARED) ∈ ls then some (l, SHARED) else none := by
  by_cases h1 : (l, o) ∈ ls
  · simp only [h1, ↓reduceIte]
    exact resolve_own _ ls h1
  · simp only [h1, ↓reduceIte]
    by_cases h2 : (l, SHARED) ∈ ls
    · simp only [h2, ↓reduceIte]
      cases hr : resolveL (readerP sees gt (l, o)) ls with
      | none =>
        have := ((resolve_none_iff _ ls).mp hr (l, SHARED) h2).2
        have hv : seesP sees (l, o) (l, SHARED) = true := by
          rw [seesP_iff]; exact ⟨hs.refl l, Or.inl rfl⟩
        simp only [readerP] at this
        rw [hv] at this
        exact absurd this (by decide)
      | some c =>
        have hm := (resolve_mem _ ls c hr).1
        rcases hls c hm with e | e
        · rw [e] at hm; exact absurd hm h1
        · rw [e]
    · simp only [h2, ↓reduceIte]
      rw [resolve_none_iff]
      intro c hc
      rcases hls c hc with e | e
      · rw [e] at hc; exact absurd hc h1
      · rw [e] at hc; exact absurd hc h2

theorem no_own_resolves_shared (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (w : L × Nat)
    (ls : List (L × Nat)) (hno : ∀ c ∈ ls, c.2 ≠ w.2) :
    resolveL (readerP sees gt w) ls = resolveL (readerP sees gt (w.1, SHARED)) ls := by
  have hwl : w ∉ ls := fun h => hno w h rfl
  by_cases hin : (w.1, SHARED) ∈ ls
  · rw [resolve_shared_exact sees hs gt w ls hwl hin]
    exact (resolve_own (readerP sees gt (w.1, SHARED)) ls hin).symm
  · rw [resolve_falls_to_rank sees gt w ls hin, resolve_falls_to_rank sees gt (w.1, SHARED) ls hin]
    unfold resolveL
    refine resolveFrom_congr _ _ ls ?_ ?_ ?_ ls none (fun x hx => hx) (fun x hx => by cases hx)
    · intro x hx
      constructor
      · intro e
        have e' : x = w := e
        exact absurd (e' ▸ hx) hwl
      · intro e
        have e' : x = (w.1, SHARED) := e
        exact absurd (e' ▸ hx) hin
    · intro x hx
      have h1 : (x.2 == w.2) = false := beq_false_of_ne (hno x hx)
      simp [rankReader, seesP, ownerSees, h1]
    · intro x _ y _; rfl

theorem no_own_inView {N P : Type} (sees gt : L → L → Bool) (w : L × Nat) (s : LState (L × Nat) N P)
    (hparts : ∀ x : L × Nat, x.2 = w.2 → s.parts x = none) (x : L × Nat) :
    inView (readerP sees gt w) s x = inView (readerP sees gt (w.1, SHARED)) s x := by
  unfold inView present
  by_cases hx : x.2 = w.2
  · simp [hparts x hx]
  · have h1 : (x.2 == w.2) = false := beq_false_of_ne hx
    simp [readerP, seesP, ownerSees, h1]

theorem no_own_find_shared {N P : Type} [DecidableEq N] (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (w : L × Nat) (s : LState (L × Nat) N P) (hparts : ∀ x : L × Nat, x.2 = w.2 → s.parts x = none)
    (hidx : ∀ n, ∀ c ∈ s.index n, c.2 ≠ w.2) (n : N) :
    viewFind (readerP sees gt w) s n = viewFind (readerP sees gt (w.1, SHARED)) s n := by
  have hiv : inView (readerP sees gt w) s = inView (readerP sees gt (w.1, SHARED)) s :=
    funext (no_own_inView sees gt w s hparts)
  unfold viewFind
  rw [no_own_resolves_shared sees hs gt w (s.index n) (hidx n), hiv]

theorem no_own_view_shared {N P : Type} [DecidableEq N] (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (acc : PartAcc N P) (le : L × Nat → L × Nat → Bool) (labelsU : List (L × Nat)) (namesU : List N)
    (w : L × Nat) (s : LState (L × Nat) N P) (hparts : ∀ x : L × Nat, x.2 = w.2 → s.parts x = none)
    (hidx : ∀ n, ∀ c ∈ s.index n, c.2 ≠ w.2) :
    viewOpen acc le labelsU namesU (readerP sees gt w) s =
      viewOpen acc le labelsU namesU (readerP sees gt (w.1, SHARED)) s := by
  have hiv : inView (readerP sees gt w) s = inView (readerP sees gt (w.1, SHARED)) s :=
    funext (no_own_inView sees gt w s hparts)
  have hsh : shadowsOf (readerP sees gt w) s = shadowsOf (readerP sees gt (w.1, SHARED)) s := by
    funext n
    unfold shadowsOf
    simp only [hiv, no_own_resolves_shared sees hs gt w (s.index n) (hidx n)]
  unfold viewOpen visibleLabels
  rw [hiv, hsh]

theorem no_own_range_shared {N P : Type} [DecidableEq N] (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (w : L × Nat) (s : LState (L × Nat) N P) (hparts : ∀ x : L × Nat, x.2 = w.2 → s.parts x = none)
    (hidx : ∀ n, ∀ c ∈ s.index n, c.2 ≠ w.2) (namesU : List N) (inRange : N → Bool) (limit : Option Nat) :
    viewRange (readerP sees gt w) s namesU inRange limit =
      viewRange (readerP sees gt (w.1, SHARED)) s namesU inRange limit := by
  have hf : (fun n => (viewFind (readerP sees gt w) s n).map (fun l => (n, l))) =
      (fun n => (viewFind (readerP sees gt (w.1, SHARED)) s n).map (fun l => (n, l))) := by
    funext n
    rw [no_own_find_shared sees hs gt w s hparts hidx n]
  unfold viewRange
  rw [hf]

end Scoped2

end Vectors
