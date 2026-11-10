import Postings.Sorted

namespace Postings

def endDoc : Nat := 4294967295

def atLeast (S : List Nat) (t : Nat) : Nat := (S.find? fun x => decide (t ≤ x)).getD endDoc

def Docs (S : List Nat) : Prop := Strict S ∧ ∀ x ∈ S, 1 ≤ x ∧ x < endDoc

structure Leaf where
  S : List Nat
  doc : Nat
deriving Repr

def Leaf.advance (c : Leaf) (t : Nat) : Leaf :=
  if c.doc ≠ 0 ∧ t ≤ c.doc then c else { c with doc := atLeast c.S t }

def Leaf.next (c : Leaf) : Leaf :=
  if c.doc = endDoc then c else { c with doc := atLeast c.S (c.doc + 1) }

def Leaf.Valid (c : Leaf) : Prop := Docs c.S ∧ (c.doc = 0 ∨ c.doc = endDoc ∨ c.doc ∈ c.S)

def interSetL (S0 : List Nat) (Ss : List (List Nat)) : List Nat := S0.filter fun x => Ss.all fun S => decide (x ∈ S)

def interSet (S0 : List Nat) (rs : List Leaf) : List Nat := interSetL S0 (rs.map Leaf.S)

theorem mem_interSet {S0 : List Nat} {rs : List Leaf} {x : Nat} : x ∈ interSet S0 rs ↔ x ∈ S0 ∧ ∀ c ∈ rs, x ∈ c.S := by
  simp only [interSet, interSetL, List.mem_filter, List.all_eq_true, List.mem_map, decide_eq_true_eq]
  constructor
  · intro ⟨h1, h2⟩; exact ⟨h1, fun c hc => h2 c.S ⟨c, hc, rfl⟩⟩
  · intro ⟨h1, h2⟩; refine ⟨h1, ?_⟩; rintro S ⟨c, hc, rfl⟩; exact h2 c hc

def innerCheck (cand : Nat) : List Leaf → List Leaf × Option Nat
  | [] => ([], none)
  | c :: cs =>
    if (c.advance cand).doc = cand then ((c.advance cand) :: (innerCheck cand cs).1, (innerCheck cand cs).2)
    else ((c.advance cand) :: cs, some (c.advance cand).doc)

def leapfrog : Nat → Leaf → List Leaf → Nat → Leaf × List Leaf × Nat
  | 0, r0, rs, _ => (r0, rs, endDoc)
  | f + 1, r0, rs, cand =>
    if cand = endDoc then (r0, rs, endDoc)
    else
      match (innerCheck cand rs).2 with
      | none => (r0, (innerCheck cand rs).1, cand)
      | some d => leapfrog f (r0.advance d) (innerCheck cand rs).1 (r0.advance d).doc

def seek (fuel : Nat) (r0 : Leaf) (rs : List Leaf) (target : Nat) : Leaf × List Leaf × Nat :=
  leapfrog fuel (r0.advance target) rs (r0.advance target).doc

theorem atLeast_ge (S : List Nat) (t : Nat) (hS : ∀ x ∈ S, x < endDoc) (ht : t ≤ endDoc) : t ≤ atLeast S t := by
  unfold atLeast
  cases h : S.find? (fun x => decide (t ≤ x)) with
  | none => simpa using ht
  | some x => simpa using List.find?_some h

theorem atLeast_le_end (S : List Nat) (t : Nat) (hS : ∀ x ∈ S, x < endDoc) : atLeast S t ≤ endDoc := by
  unfold atLeast
  cases h : S.find? (fun x => decide (t ≤ x)) with
  | none => simp
  | some x => simp only [Option.getD_some]; exact Nat.le_of_lt (hS x (List.mem_of_find?_eq_some h))

theorem atLeast_mem (S : List Nat) (t : Nat) (h : atLeast S t ≠ endDoc) : atLeast S t ∈ S := by
  unfold atLeast at *
  cases hf : S.find? (fun x => decide (t ≤ x)) with
  | none => rw [hf] at h; simp at h
  | some x => simp only [Option.getD_some]; exact List.mem_of_find?_eq_some hf

theorem atLeast_least {S : List Nat} (hs : Strict S) {t x : Nat} (hx : x ∈ S) (htx : t ≤ x) : atLeast S t ≤ x := by
  unfold atLeast
  induction S with
  | nil => simp at hx
  | cons y ys ih =>
    simp only [List.find?_cons]
    by_cases hy : t ≤ y
    · simp only [hy, decide_true, Option.getD_some]
      rcases List.mem_cons.1 hx with e | e
      · omega
      · exact Nat.le_of_lt (strict_head hs x e)
    · simp only [hy, decide_false]
      rcases List.mem_cons.1 hx with e | e
      · omega
      · exact ih (strict_cons hs) e

theorem atLeast_end {S : List Nat} (hS : ∀ x ∈ S, x < endDoc) : atLeast S endDoc = endDoc := by
  unfold atLeast
  have : S.find? (fun x => decide (endDoc ≤ x)) = none := by
    rw [List.find?_eq_none]; intro x hx; have := hS x hx; simp; omega
  rw [this]; rfl

def ansOf (S : List Nat) (t : Nat) : Nat := atLeast S t

theorem advance_spec {c : Leaf} (hv : c.Valid) {t : Nat} (ht : 1 ≤ t) (hte : t ≤ endDoc) :
    (c.advance t).Valid ∧ t ≤ (c.advance t).doc ∧ (c.advance t).S = c.S ∧
      (c.doc < t → (c.advance t).doc = atLeast c.S t) ∧ (t ≤ c.doc → (c.advance t).doc = c.doc) := by
  have hS : ∀ x ∈ c.S, x < endDoc := fun x hx => (hv.1.2 x hx).2
  unfold Leaf.advance
  split
  · rename_i h
    exact ⟨hv, h.2, rfl, fun h' => absurd h.2 (by omega), fun _ => rfl⟩
  · rename_i h
    refine ⟨⟨hv.1, ?_⟩, atLeast_ge _ _ hS hte, rfl, fun _ => rfl, fun h' => ?_⟩
    · by_cases e : atLeast c.S t = endDoc
      · exact Or.inr (Or.inl e)
      · exact Or.inr (Or.inr (atLeast_mem _ _ e))
    · rcases hv.2 with e | e | e
      · omega
      · exfalso; apply h; exact ⟨by unfold endDoc at e; omega, h'⟩
      · exfalso; apply h; exact ⟨by have := (hv.1.2 _ e).1; omega, h'⟩

theorem advance_le {c : Leaf} (hv : c.Valid) {t a : Nat} (ht : 1 ≤ t) (hte : t ≤ a) (ha : a = endDoc ∨ a ∈ c.S)
    (hc : c.doc ≤ a) : (c.advance t).doc ≤ a := by
  have hs := advance_spec hv ht (by rcases ha with e | e; omega; have := (hv.1.2 a e).2; omega)
  by_cases h : c.doc < t
  · rw [hs.2.2.2.1 h]
    rcases ha with e | e
    · rw [e]; exact atLeast_le_end _ _ (fun x hx => (hv.1.2 x hx).2)
    · exact atLeast_least hv.1.1 e hte
  · rw [hs.2.2.2.2 (by omega)]; exact hc

theorem innerCheck_spec (cand ans : Nat) (hc1 : 1 ≤ cand) (hca : cand ≤ ans)
    (hans : ans = endDoc ∨ True) : ∀ rs : List Leaf, (∀ c ∈ rs, c.Valid) →
      (∀ c ∈ rs, c.doc ≤ ans) → (∀ c ∈ rs, ans = endDoc ∨ ans ∈ c.S) →
      (innerCheck cand rs).1.length = rs.length ∧
      (∀ c ∈ (innerCheck cand rs).1, c.Valid ∧ c.doc ≤ ans ∧ (ans = endDoc ∨ ans ∈ c.S)) ∧
      List.map Leaf.S (innerCheck cand rs).1 = List.map Leaf.S rs ∧
      (match (innerCheck cand rs).2 with
        | none => ∀ c ∈ (innerCheck cand rs).1, c.doc = cand
        | some d => cand < d ∧ d ≤ ans)
  | [], _, _, _ => by simp [innerCheck]
  | c :: cs, hv, hd, ha => by
    have hcv := hv c (by simp)
    have hca' := ha c (by simp)
    have hcand_end : cand ≤ endDoc := by
      rcases hca' with e | e
      · omega
      · have := (hcv.1.2 ans e).2; omega
    have hs := advance_spec hcv hc1 hcand_end
    have hle := advance_le hcv hc1 hca hca' (hd c (by simp))
    have ih := innerCheck_spec cand ans hc1 hca hans cs (fun x hx => hv x (by simp [hx]))
      (fun x hx => hd x (by simp [hx])) (fun x hx => ha x (by simp [hx]))
    unfold innerCheck
    split
    · rename_i heq
      refine ⟨by simp [ih.1], fun x hx => ?_, by simp [hs.2.2.1, ih.2.2.1], ?_⟩
      · rcases List.mem_cons.1 hx with e | e
        · subst e; exact ⟨hs.1, hle, by rw [hs.2.2.1]; exact hca'⟩
        · exact ih.2.1 x e
      · have := ih.2.2.2
        revert this
        cases (innerCheck cand cs).2 with
        | none =>
          intro h x hx
          rcases List.mem_cons.1 hx with e | e
          · subst e; exact heq
          · exact h x e
        | some d => intro h; exact h
    · rename_i hne
      refine ⟨by simp, fun x hx => ?_, by simp [hs.2.2.1], ⟨by have := hs.2.1; omega, hle⟩⟩
      rcases List.mem_cons.1 hx with e | e
      · subst e; exact ⟨hs.1, hle, by rw [hs.2.2.1]; exact hca'⟩
      · exact ⟨hv x (by simp [e]), hd x (by simp [e]), ha x (by simp [e])⟩

theorem leapfrog_spec (S0 : List Nat) (target : Nat) (ht : 1 ≤ target) :
    ∀ (fuel : Nat) (r0 : Leaf) (rs : List Leaf) (cand : Nat), r0.S = S0 → r0.Valid → (∀ c ∈ rs, c.Valid) →
      target ≤ cand → cand = r0.doc → cand ≤ atLeast (interSet S0 rs) target →
      (∀ c ∈ rs, c.doc ≤ atLeast (interSet S0 rs) target) → endDoc - cand < fuel →
      (leapfrog fuel r0 rs cand).2.2 = atLeast (interSet S0 rs) target ∧
        List.map Leaf.S (leapfrog fuel r0 rs cand).2.1 = List.map Leaf.S rs ∧
        (atLeast (interSet S0 rs) target ≠ endDoc →
          (leapfrog fuel r0 rs cand).1.doc = atLeast (interSet S0 rs) target ∧
          ∀ c ∈ (leapfrog fuel r0 rs cand).2.1, c.doc = atLeast (interSet S0 rs) target) ∧
        (leapfrog fuel r0 rs cand).1.S = S0 ∧ (leapfrog fuel r0 rs cand).1.Valid ∧
        ∀ c ∈ (leapfrog fuel r0 rs cand).2.1, c.Valid := by
  intro fuel
  induction fuel with
  | zero => intro r0 rs cand _ _ _ _ _ _ _ hf; omega
  | succ f ih =>
    intro r0 rs cand hS0 hv hvs htc hcr hca hcs hf
    have hS0b : ∀ x ∈ S0, x < endDoc := fun x hx => (hv.1.2 x (hS0 ▸ hx)).2
    have hinter_b : ∀ x ∈ interSet S0 rs, x < endDoc := fun x hx => hS0b x (mem_interSet.1 hx).1
    have hans_le := atLeast_le_end (interSet S0 rs) target hinter_b
    have hans_mem : atLeast (interSet S0 rs) target = endDoc ∨ atLeast (interSet S0 rs) target ∈ interSet S0 rs := by
      by_cases e : atLeast (interSet S0 rs) target = endDoc
      · exact Or.inl e
      · exact Or.inr (atLeast_mem _ _ e)
    have hans_in : ∀ c ∈ rs, atLeast (interSet S0 rs) target = endDoc ∨ atLeast (interSet S0 rs) target ∈ c.S := by
      intro c hc
      rcases hans_mem with e | e
      · exact Or.inl e
      · right
        exact (mem_interSet.1 e).2 c hc
    have hans_S0 : atLeast (interSet S0 rs) target = endDoc ∨ atLeast (interSet S0 rs) target ∈ r0.S := by
      rcases hans_mem with e | e
      · exact Or.inl e
      · right; rw [hS0]; exact (mem_interSet.1 e).1
    unfold leapfrog
    split
    · rename_i hend
      refine ⟨by dsimp only; omega, rfl, fun h => absurd (by omega) h, hS0, hv, hvs⟩
    · rename_i hnend
      have hic := innerCheck_spec cand (atLeast (interSet S0 rs) target) (by omega) hca (Or.inr trivial) rs hvs hcs hans_in
      have hic4 := hic.2.2.2
      split
      · rename_i hnone
        rw [hnone] at hic4
        simp only at hic4
        have hcmem : cand ∈ interSet S0 rs := by
          refine mem_interSet.2 ⟨?_, ?_⟩
          · rcases hv.2 with e | e | e
            · omega
            · omega
            · rw [← hS0, hcr]; exact e
          · intro c hc
            have hall := hic.2.1
            have hlen := hic.1
            have hmap := hic.2.2.1
            obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem hc
            have hi' : i < (innerCheck cand rs).1.length := by omega
            have hci := hic4 _ (List.getElem_mem hi')
            have hvi := (hall _ (List.getElem_mem hi')).1
            have hSi : (innerCheck cand rs).1[i].S = rs[i].S := by
              have := congrArg (fun l => l[i]?) hmap
              simp only [List.getElem?_map, List.getElem?_eq_getElem hi', List.getElem?_eq_getElem hi, Option.map_some,
                Option.some.injEq] at this
              exact this
            rw [← hSi]
            rcases hvi.2 with e | e | e
            · omega
            · omega
            · rw [hci] at e; exact e
        have hge : atLeast (interSet S0 rs) target ≤ cand := atLeast_least (strict_filter (hS0 ▸ hv.1.1) _) hcmem htc
        have heq : cand = atLeast (interSet S0 rs) target := by omega
        refine ⟨heq, hic.2.2.1, fun _ => ⟨by rw [← hcr, heq], fun c hc => by rw [hic4 c hc, heq]⟩, hS0, hv,
          fun c hc => (hic.2.1 c hc).1⟩
      · rename_i d hsome
        rw [hsome] at hic4
        simp only at hic4
        have hS0' : (r0.advance d).S = S0 := by unfold Leaf.advance; split <;> simp [hS0]
        have hdend : d ≤ endDoc := by omega
        have hadv := advance_spec hv (show 1 ≤ d by omega) hdend
        have hle := advance_le hv (show 1 ≤ d by omega) hic4.2 hans_S0 (by omega)
        have hsame : interSet S0 (innerCheck cand rs).1 = interSet S0 rs := by
          unfold interSet; rw [hic.2.2.1]
        have ihr := ih (r0.advance d) (innerCheck cand rs).1 (r0.advance d).doc hS0' hadv.1
          (fun c hc => (hic.2.1 c hc).1) (by have := hadv.2.1; omega) rfl
          (by rw [hsame]; exact hle) (fun c hc => by rw [hsame]; exact (hic.2.1 c hc).2.1)
          (by have := hadv.2.1; omega)
        rw [hsame] at ihr
        refine ⟨ihr.1, by rw [ihr.2.1, hic.2.2.1], ihr.2.2.1, ihr.2.2.2.1, ihr.2.2.2.2.1, ihr.2.2.2.2.2⟩

theorem seek_spec (S0 : List Nat) (r0 : Leaf) (rs : List Leaf) (target : Nat) (ht : 1 ≤ target) (hte : target ≤ endDoc)
    (hS0 : r0.S = S0) (hv : r0.Valid) (hvs : ∀ c ∈ rs, c.Valid)
    (h0 : r0.doc ≤ atLeast (interSet S0 rs) target) (hcs : ∀ c ∈ rs, c.doc ≤ atLeast (interSet S0 rs) target) :
    (seek (endDoc + 1) r0 rs target).2.2 = atLeast (interSet S0 rs) target ∧
      (atLeast (interSet S0 rs) target ≠ endDoc →
        (seek (endDoc + 1) r0 rs target).1.doc = atLeast (interSet S0 rs) target ∧
        ∀ c ∈ (seek (endDoc + 1) r0 rs target).2.1, c.doc = atLeast (interSet S0 rs) target) ∧
      List.map Leaf.S (seek (endDoc + 1) r0 rs target).2.1 = List.map Leaf.S rs ∧
      (seek (endDoc + 1) r0 rs target).1.S = S0 ∧ (seek (endDoc + 1) r0 rs target).1.Valid ∧
      ∀ c ∈ (seek (endDoc + 1) r0 rs target).2.1, c.Valid := by
  have hS0b : ∀ x ∈ S0, x < endDoc := fun x hx => (hv.1.2 x (hS0 ▸ hx)).2
  have hans_S0 : atLeast (interSet S0 rs) target = endDoc ∨ atLeast (interSet S0 rs) target ∈ r0.S := by
    by_cases e : atLeast (interSet S0 rs) target = endDoc
    · exact Or.inl e
    · right; rw [hS0]; exact (mem_interSet.1 (atLeast_mem _ _ e)).1
  have hadv := advance_spec hv ht hte
  have hle := advance_le hv ht (atLeast_ge _ _ (fun x hx => hS0b x (mem_interSet.1 hx).1) hte) hans_S0 h0
  have hS0' : (r0.advance target).S = S0 := by rw [hadv.2.2.1, hS0]
  have := leapfrog_spec S0 target ht (endDoc + 1) (r0.advance target) rs (r0.advance target).doc hS0' hadv.1 hvs
    hadv.2.1 rfl hle hcs (by omega)
  unfold seek
  exact ⟨this.1, this.2.2.1, this.2.1, this.2.2.2.1, this.2.2.2.2.1, this.2.2.2.2.2⟩

structure Inter where
  r0 : Leaf
  rs : List Leaf
  doc : Nat

def Inter.next (ix : Inter) : Inter :=
  if ix.doc = endDoc then ix
  else
    let r := seek (endDoc + 1) ix.r0 ix.rs (ix.doc + 1)
    ⟨r.1, r.2.1, r.2.2⟩

def interDrain : Nat → Inter → List Nat
  | 0, _ => []
  | f + 1, ix =>
    let nx := ix.next
    if nx.doc = endDoc then [] else nx.doc :: interDrain f nx

def fresh (S : List Nat) : Leaf := ⟨S, 0⟩

theorem atLeast_eq_of {L : List Nat} (hs : Strict L) {t x : Nat} (hx : x ∈ L) (htx : t ≤ x)
    (hmin : ∀ y ∈ L, t ≤ y → x ≤ y) : atLeast L t = x := by
  unfold atLeast
  induction L with
  | nil => simp at hx
  | cons y ys ih =>
    simp only [List.find?_cons]
    by_cases hy : t ≤ y
    · simp only [hy, decide_true, Option.getD_some]
      have := hmin y (by simp) hy
      rcases List.mem_cons.1 hx with e | e
      · omega
      · have := strict_head hs x e; omega
    · simp only [hy, decide_false]
      rcases List.mem_cons.1 hx with e | e
      · omega
      · exact ih (strict_cons hs) e (fun z hz htz => hmin z (by simp [hz]) htz)

theorem atLeast_none {L : List Nat} {t : Nat} (h : ∀ y ∈ L, y < t) : atLeast L t = endDoc := by
  unfold atLeast
  have : L.find? (fun x => decide (t ≤ x)) = none := by
    rw [List.find?_eq_none]; intro x hx; have := h x hx; simp; omega
  rw [this]; rfl

theorem atLeast_cases {L : List Nat} (hs : Strict L) (hb : ∀ y ∈ L, y < endDoc) (t : Nat) :
    (atLeast L t = endDoc ∧ ∀ y ∈ L, y < t) ∨
      (atLeast L t ∈ L ∧ t ≤ atLeast L t ∧ ∀ y ∈ L, t ≤ y → atLeast L t ≤ y) := by
  by_cases h : ∃ y ∈ L, t ≤ y
  · right
    obtain ⟨y, hy, hty⟩ := h
    have hne : atLeast L t ≠ endDoc := by
      intro e
      unfold atLeast at e
      cases hf : L.find? (fun x => decide (t ≤ x)) with
      | none => rw [List.find?_eq_none] at hf; have := hf y hy; simp at this; omega
      | some z => rw [hf] at e; simp at e; subst e; have := hb _ (List.mem_of_find?_eq_some hf); omega
    have hm := atLeast_mem L t hne
    refine ⟨hm, ?_, fun z hz htz => atLeast_least hs hz htz⟩
    unfold atLeast at hne ⊢
    cases hf : L.find? (fun x => decide (t ≤ x)) with
    | none => rw [hf] at hne; simp at hne
    | some z => simp only [Option.getD_some]; simpa using List.find?_some hf
  · left
    have hall : ∀ y ∈ L, y < t := fun y hy => Nat.lt_of_not_le (fun h' => h ⟨y, hy, h'⟩)
    exact ⟨atLeast_none hall, hall⟩

theorem filter_gt_step {L : List Nat} (hs : Strict L) (hb : ∀ x ∈ L, x < endDoc) (d : Nat) :
    L.filter (fun y => decide (d < y)) =
      if atLeast L (d + 1) = endDoc then []
      else atLeast L (d + 1) :: L.filter (fun y => decide (atLeast L (d + 1) < y)) := by
  rcases atLeast_cases hs hb (d + 1) with ⟨he, hall⟩ | ⟨hm, hge, hmin⟩
  · rw [ite_eq_left he]
    rw [List.filter_eq_nil_iff]; intro y hy; have := hall y hy; simp; omega
  · have hne : atLeast L (d + 1) ≠ endDoc := by have := hb _ hm; omega
    rw [ite_eq_right hne]
    apply strict_ext _ _ (strict_filter hs _)
    · refine List.pairwise_cons.2 ⟨fun y hy => ?_, strict_filter hs _⟩
      have := (List.mem_filter.1 hy).2; simp at this; exact this
    · intro y
      simp only [List.mem_filter, decide_eq_true_eq, List.mem_cons]
      constructor
      · intro ⟨hy, hdy⟩
        by_cases e : y = atLeast L (d + 1)
        · left; exact e
        · right; exact ⟨hy, by have := hmin y hy (by omega); omega⟩
      · intro h
        rcases h with e | ⟨hy, hgt⟩
        · subst e; exact ⟨hm, by omega⟩
        · exact ⟨hy, by omega⟩

theorem interSet_strict (S0 : List Nat) (rs : List Leaf) (h : Strict S0) : Strict (interSet S0 rs) := strict_filter h _

theorem interDrain_spec (S0 : List Nat) (hS : Docs S0) :
    ∀ (fuel : Nat) (ix : Inter), ix.r0.S = S0 → ix.r0.Valid → (∀ c ∈ ix.rs, c.Valid) → ix.doc < endDoc →
      ix.r0.doc ≤ ix.doc → (∀ c ∈ ix.rs, c.doc ≤ ix.doc) →
      ((interSet S0 ix.rs).filter fun y => decide (ix.doc < y)).length < fuel →
      interDrain fuel ix = (interSet S0 ix.rs).filter fun y => decide (ix.doc < y) := by
  intro fuel
  induction fuel with
  | zero => intro _ _ _ _ _ _ _ h; omega
  | succ f ih =>
    intro ix hS0 hv hvs hlt h0 hcs hf
    have hne : ix.doc ≠ endDoc := by omega
    have hb : ∀ x ∈ interSet S0 ix.rs, x < endDoc := fun x hx => (hS.2 x (mem_interSet.1 hx).1).2
    have hstrict := interSet_strict S0 ix.rs hS.1
    have hstep := filter_gt_step hstrict hb ix.doc
    have hge := atLeast_ge (interSet S0 ix.rs) (ix.doc + 1) hb (by omega)
    have hle := atLeast_le_end (interSet S0 ix.rs) (ix.doc + 1) hb
    have hsk := seek_spec S0 ix.r0 ix.rs (ix.doc + 1) (by omega) (by omega) hS0 hv hvs (by omega)
      (fun c hc => by have := hcs c hc; omega)
    unfold interDrain Inter.next
    simp only [hne, ↓reduceIte]
    generalize hq : seek (endDoc + 1) ix.r0 ix.rs (ix.doc + 1) = q at hsk
    obtain ⟨r0', rs', x⟩ := q
    simp only at hsk ⊢
    rw [hstep, ← hsk.1]
    by_cases hx : x = endDoc
    · simp only [hx, ↓reduceIte]
    · simp only [hx, ↓reduceIte]
      have hx' : atLeast (interSet S0 ix.rs) (ix.doc + 1) ≠ endDoc := by rw [← hsk.1]; exact hx
      have hsame : interSet S0 rs' = interSet S0 ix.rs := by unfold interSet; rw [hsk.2.2.1]
      have hxlt : x < endDoc := by omega
      have hpos := hsk.2.1 hx'
      have ih' := ih ⟨r0', rs', x⟩ hsk.2.2.2.1 hsk.2.2.2.2.1 hsk.2.2.2.2.2 hxlt
        (by simp only; rw [hpos.1, hsk.1]; exact Nat.le_refl _)
        (fun c hc => by simp only; rw [hpos.2 c hc, hsk.1]; exact Nat.le_refl _)
        (by
          simp only
          rw [hsame]
          rw [hstep, ← hsk.1] at hf
          simp only [hx, ↓reduceIte, List.length_cons] at hf
          omega)
      simp only at ih'
      rw [ih', hsame]

theorem interDrain_fresh (S0 : List Nat) (Ss : List (List Nat)) (hS : Docs S0) (hSs : ∀ S ∈ Ss, Docs S) :
    interDrain ((interSet S0 (Ss.map fresh)).length + 1) ⟨fresh S0, Ss.map fresh, 0⟩ = interSet S0 (Ss.map fresh) := by
  have h := interDrain_spec S0 hS ((interSet S0 (Ss.map fresh)).length + 1) ⟨fresh S0, Ss.map fresh, 0⟩ rfl
    ⟨hS, Or.inl rfl⟩
    (fun c hc => by
      simp only [List.mem_map] at hc
      obtain ⟨S, hS', rfl⟩ := hc
      exact ⟨hSs S hS', Or.inl rfl⟩)
    (show (0 : Nat) < endDoc by unfold endDoc; decide) (Nat.le_refl _)
    (fun c hc => by simp only [List.mem_map] at hc; obtain ⟨S, _, rfl⟩ := hc; exact Nat.le_refl _)
    (by simp only; have := List.length_filter_le (fun y => decide (0 < y)) (interSet S0 (Ss.map fresh)); omega)
  rw [h]
  apply List.filter_eq_self.2
  intro y hy
  have := (hS.2 y (mem_interSet.1 hy).1).1
  simp; omega

theorem interSet_spec (S0 : List Nat) (Ss : List (List Nat)) (x : Nat) :
    x ∈ interSet S0 (Ss.map fresh) ↔ x ∈ S0 ∧ ∀ S ∈ Ss, x ∈ S := by
  rw [mem_interSet]; simp [fresh]

theorem atLeast_gap {S : List Nat} (hs : Strict S) (hb : ∀ y ∈ S, y < endDoc) {t t' : Nat} (htt : t ≤ t')
    (hgap : ∀ y ∈ S, t ≤ y → t' ≤ y) : atLeast S t = atLeast S t' := by
  rcases atLeast_cases hs hb t with ⟨he, hall⟩ | ⟨hm, hge, hmin⟩
  · rw [he]; symm; exact atLeast_none (fun y hy => by have := hall y hy; omega)
  · symm; exact atLeast_eq_of hs hm (hgap _ hm hge) (fun y hy hty => hmin y hy (by omega))

theorem atLeast_skip {S : List Nat} (hs : Strict S) (hb : ∀ y ∈ S, y < endDoc) {d : Nat} (hne : atLeast S d ≠ d) :
    atLeast S (d + 1) = atLeast S d := by
  rcases atLeast_cases hs hb d with ⟨he, hall⟩ | ⟨hm, hge, hmin⟩
  · rw [he]; exact atLeast_none (fun y hy => by have := hall y hy; omega)
  · exact atLeast_eq_of hs hm (by omega) (fun y hy hdy => hmin y hy (by omega))

theorem atLeast_union {A B : List Nat} (ha : Strict A) (hb : Strict B) (hA : ∀ y ∈ A, y < endDoc)
    (hB : ∀ y ∈ B, y < endDoc) (t : Nat) : atLeast (unionMerge A B) t = min (atLeast A t) (atLeast B t) := by
  have hu := unionMerge_spec A B ha hb
  have hU : ∀ y ∈ unionMerge A B, y < endDoc := fun y hy => by
    rcases (hu.2 y).1 hy with h | h
    · exact hA y h
    · exact hB y h
  rcases atLeast_cases ha hA t with ⟨hea, halla⟩ | ⟨hma, hgea, hmina⟩ <;>
    rcases atLeast_cases hb hB t with ⟨heb, hallb⟩ | ⟨hmb, hgeb, hminb⟩
  · rw [hea, heb, Nat.min_self]
    exact atLeast_none (fun y hy => by rcases (hu.2 y).1 hy with h | h; exact halla y h; exact hallb y h)
  · rw [hea, Nat.min_eq_right (atLeast_le_end B t hB)]
    exact atLeast_eq_of hu.1 ((hu.2 _).2 (Or.inr hmb)) hgeb (fun y hy hty => by
      rcases (hu.2 y).1 hy with h | h
      · have := halla y h; omega
      · exact hminb y h hty)
  · rw [heb, Nat.min_eq_left (atLeast_le_end A t hA)]
    exact atLeast_eq_of hu.1 ((hu.2 _).2 (Or.inl hma)) hgea (fun y hy hty => by
      rcases (hu.2 y).1 hy with h | h
      · exact hmina y h hty
      · have := hallb y h; omega)
  · by_cases hab : atLeast A t ≤ atLeast B t
    · rw [Nat.min_eq_left hab]
      exact atLeast_eq_of hu.1 ((hu.2 _).2 (Or.inl hma)) hgea (fun y hy hty => by
        rcases (hu.2 y).1 hy with h | h
        · exact hmina y h hty
        · have := hminb y h hty; omega)
    · rw [Nat.min_eq_right (by omega)]
      exact atLeast_eq_of hu.1 ((hu.2 _).2 (Or.inr hmb)) hgeb (fun y hy hty => by
        rcases (hu.2 y).1 hy with h | h
        · have := hmina y h hty; omega
        · exact hminb y h hty)

def minDoc : List Leaf → Nat
  | [] => endDoc
  | c :: cs => min c.doc (minDoc cs)

def unionAllL : List (List Nat) → List Nat
  | [] => []
  | S :: Ss => unionMerge S (unionAllL Ss)

def unionAll (kids : List Leaf) : List Nat := unionAllL (kids.map Leaf.S)

theorem unionAll_ok : ∀ kids : List Leaf, (∀ c ∈ kids, Docs c.S) → Strict (unionAll kids) ∧ ∀ y ∈ unionAll kids, 1 ≤ y ∧ y < endDoc
  | [], _ => ⟨List.Pairwise.nil, by simp [unionAll, unionAllL]⟩
  | c :: cs, h => by
    have ih := unionAll_ok cs (fun x hx => h x (by simp [hx]))
    have hc := h c (by simp)
    have hu := unionMerge_spec c.S (unionAll cs) hc.1 ih.1
    have he : unionAll (c :: cs) = unionMerge c.S (unionAll cs) := rfl
    rw [he]
    refine ⟨hu.1, fun y hy => ?_⟩
    rcases (hu.2 y).1 hy with e | e
    · exact hc.2 y e
    · exact ih.2 y e

theorem mem_unionAll : ∀ (kids : List Leaf), (∀ c ∈ kids, Docs c.S) → ∀ y, y ∈ unionAll kids ↔ ∃ c ∈ kids, y ∈ c.S
  | [], _, y => by simp [unionAll, unionAllL]
  | c :: cs, h, y => by
    have ih := mem_unionAll cs (fun x hx => h x (by simp [hx])) y
    have hc := h c (by simp)
    have hu := unionMerge_spec c.S (unionAll cs) hc.1 (unionAll_ok cs (fun x hx => h x (by simp [hx]))).1
    have he : unionAll (c :: cs) = unionMerge c.S (unionAll cs) := rfl
    rw [he, hu.2 y, ih]
    simp only [List.mem_cons, exists_eq_or_imp]

theorem minDoc_atLeast : ∀ (kids : List Leaf) (t : Nat), (∀ c ∈ kids, Docs c.S) → (∀ c ∈ kids, c.doc = atLeast c.S t) →
    minDoc kids = atLeast (unionAll kids) t
  | [], t, _, _ => by simp [minDoc, unionAll, unionAllL, atLeast]
  | c :: cs, t, hd, hp => by
    have ih := minDoc_atLeast cs t (fun x hx => hd x (by simp [hx])) (fun x hx => hp x (by simp [hx]))
    have hc := hd c (by simp)
    have hok := unionAll_ok cs (fun x hx => hd x (by simp [hx]))
    have he : unionAll (c :: cs) = unionMerge c.S (unionAll cs) := rfl
    simp only [minDoc]
    rw [he, ih, hp c (by simp), atLeast_union hc.1 hok.1 (fun y hy => (hc.2 y hy).2) (fun y hy => (hok.2 y hy).2)]

structure Uni where
  kids : List Leaf
  doc : Nat
  started : Bool

def Uni.next (u : Uni) : Uni :=
  if u.doc = endDoc then u
  else if u.started then
    ⟨u.kids.map (fun c => if c.doc = u.doc then c.next else c), minDoc (u.kids.map fun c => if c.doc = u.doc then c.next else c), true⟩
  else ⟨u.kids.map (fun c => c.advance 1), minDoc (u.kids.map fun c => c.advance 1), true⟩

def uniDrain : Nat → Uni → List Nat
  | 0, _ => []
  | f + 1, u => if u.next.doc = endDoc then [] else u.next.doc :: uniDrain f u.next

def matchedOf (kids : List Leaf) (d : Nat) : List Nat := (List.range kids.length).filter fun i => decide ((kids[i]?.map Leaf.doc) = some d)

def UniOk (u : Uni) : Prop :=
  u.started = true ∧ (∀ c ∈ u.kids, c.Valid) ∧ (∀ c ∈ u.kids, c.doc = atLeast c.S u.doc) ∧ u.doc < endDoc

theorem uni_step (u : Uni) (h : UniOk u) :
    u.next.kids.map Leaf.S = u.kids.map Leaf.S ∧ (∀ c ∈ u.next.kids, c.Valid) ∧
      (∀ c ∈ u.next.kids, c.doc = atLeast c.S (u.doc + 1)) ∧ u.next.doc = atLeast (unionAll u.kids) (u.doc + 1) ∧
      u.next.started = true := by
  have hne : u.doc ≠ endDoc := by have := h.2.2.2; omega
  have hkids : ∀ c ∈ u.kids, (if c.doc = u.doc then c.next else c).S = c.S ∧
      (if c.doc = u.doc then c.next else c).Valid ∧
      (if c.doc = u.doc then c.next else c).doc = atLeast c.S (u.doc + 1) := by
    intro c hc
    have hv := h.2.1 c hc
    have hp := h.2.2.1 c hc
    have hb : ∀ y ∈ c.S, y < endDoc := fun y hy => (hv.1.2 y hy).2
    split
    · rename_i he
      have hne' : c.doc ≠ endDoc := by rw [he]; exact hne
      unfold Leaf.next
      simp only [hne', ↓reduceIte]
      refine ⟨by simp, ⟨hv.1, ?_⟩, by rw [he]⟩
      by_cases e : atLeast c.S (c.doc + 1) = endDoc
      · exact Or.inr (Or.inl e)
      · exact Or.inr (Or.inr (atLeast_mem _ _ e))
    · rename_i he
      exact ⟨rfl, hv, by rw [hp]; exact (atLeast_skip hv.1.1 hb (by rw [← hp]; exact he)).symm⟩
  unfold Uni.next
  simp only [hne, ↓reduceIte, h.1]
  refine ⟨?_, fun c hc => ?_, fun c hc => ?_, ?_, by simp⟩
  · rw [List.map_map]; apply List.map_congr_left; intro c hc; exact (hkids c hc).1
  · simp only [List.mem_map] at hc; obtain ⟨c', hc', rfl⟩ := hc; exact (hkids c' hc').2.1
  · simp only [List.mem_map] at hc; obtain ⟨c', hc', rfl⟩ := hc; rw [(hkids c' hc').2.2, (hkids c' hc').1]
  · have hS : unionAll (u.kids.map fun c => if c.doc = u.doc then c.next else c) = unionAll u.kids := by
      unfold unionAll; rw [List.map_map]; congr 1; apply List.map_congr_left; intro c hc; exact (hkids c hc).1
    rw [← hS]
    apply minDoc_atLeast
    · intro c hc; simp only [List.mem_map] at hc; obtain ⟨c', hc', rfl⟩ := hc; exact (hkids c' hc').2.1.1
    · intro c hc; simp only [List.mem_map] at hc; obtain ⟨c', hc', rfl⟩ := hc
      rw [(hkids c' hc').2.2, (hkids c' hc').1]

theorem matched_spec (u : Uni) (h : UniOk u) (i : Nat) (hi : i < u.kids.length) :
    i ∈ matchedOf u.kids u.doc ↔ u.doc ∈ u.kids[i].S := by
  simp only [matchedOf, List.mem_filter, List.mem_range, hi, true_and, List.getElem?_eq_getElem hi, Option.map_some,
    Option.some.injEq, decide_eq_true_eq]
  have hv := h.2.1 _ (List.getElem_mem hi)
  have hp := h.2.2.1 _ (List.getElem_mem hi)
  have hb : ∀ y ∈ u.kids[i].S, y < endDoc := fun y hy => (hv.1.2 y hy).2
  rw [hp]
  constructor
  · intro e
    have := atLeast_mem u.kids[i].S u.doc (by rw [e]; have := h.2.2.2; omega)
    rw [e] at this; exact this
  · intro hm
    exact atLeast_eq_of hv.1.1 hm (Nat.le_refl _) (fun y _ hy => hy)

theorem uniDrain_spec (kids0 : List Leaf) (hd : ∀ c ∈ kids0, Docs c.S) :
    ∀ (fuel : Nat) (u : Uni), u.kids.map Leaf.S = kids0.map Leaf.S → UniOk u →
      ((unionAll kids0).filter fun y => decide (u.doc < y)).length < fuel →
      uniDrain fuel u = (unionAll kids0).filter fun y => decide (u.doc < y) := by
  have hU := unionAll_ok kids0 hd
  intro fuel
  induction fuel with
  | zero => intro _ _ _ h; omega
  | succ f ih =>
    intro u hmap h hf
    have hsameU : unionAll u.kids = unionAll kids0 := by unfold unionAll; rw [hmap]
    have hst := uni_step u h
    have hstep := filter_gt_step hU.1 (fun y hy => (hU.2 y hy).2) u.doc
    unfold uniDrain
    rw [hst.2.2.2.1, hsameU, hstep]
    by_cases hx : atLeast (unionAll kids0) (u.doc + 1) = endDoc
    · simp only [hx, ↓reduceIte]
    · simp only [hx, ↓reduceIte]
      have hle := atLeast_le_end (unionAll kids0) (u.doc + 1) (fun y hy => (hU.2 y hy).2)
      have hok : UniOk u.next := ⟨hst.2.2.2.2, hst.2.1, fun c hc => by
        rw [hst.2.2.1 c hc, hst.2.2.2.1, hsameU]
        have hvc := hst.2.1 c hc
        have hcS : c.S ∈ kids0.map Leaf.S := by rw [← hmap, ← hst.1]; exact List.mem_map_of_mem hc
        apply atLeast_gap hvc.1.1 (fun y hy => (hvc.1.2 y hy).2) (atLeast_ge _ _ (fun y hy => (hU.2 y hy).2) (by have := h.2.2.2; omega))
        intro y hy hty
        have hyU : y ∈ unionAll kids0 := by
          obtain ⟨c0, hc0, he0⟩ := List.mem_map.1 hcS
          exact (mem_unionAll kids0 hd y).2 ⟨c0, hc0, by rw [he0]; exact hy⟩
        rcases atLeast_cases hU.1 (fun y hy => (hU.2 y hy).2) (u.doc + 1) with ⟨he, _⟩ | ⟨_, _, hmin⟩
        · exact absurd he hx
        · exact hmin y hyU hty, by
        rw [hst.2.2.2.1, hsameU]; omega⟩
      rw [ih u.next (by rw [hst.1, hmap]) hok (by
        rw [hst.2.2.2.1, hsameU]
        rw [hstep] at hf
        simp only [hx, ↓reduceIte, List.length_cons] at hf
        omega)]
      rw [hst.2.2.2.1, hsameU]

theorem uni_start (kids : List Leaf) (hd : ∀ c ∈ kids, Docs c.S) (h0 : ∀ c ∈ kids, c.doc = 0) :
    let u : Uni := ⟨kids, 0, false⟩
    u.next.kids.map Leaf.S = kids.map Leaf.S ∧ u.next.doc = atLeast (unionAll kids) 1 ∧
      (u.next.doc ≠ endDoc → UniOk u.next) := by
  have hadv : ∀ c ∈ kids, (c.advance 1).S = c.S ∧ (c.advance 1).Valid ∧ (c.advance 1).doc = atLeast c.S 1 := by
    intro c hc
    have hv : c.Valid := ⟨hd c hc, Or.inl (h0 c hc)⟩
    have := advance_spec hv (Nat.le_refl 1) (by unfold endDoc; decide)
    exact ⟨this.2.2.1, this.1, this.2.2.2.1 (by rw [h0 c hc]; decide)⟩
  have hdocs : ∀ c ∈ kids.map (fun c => c.advance 1), Docs c.S := by
    intro c hc; simp only [List.mem_map] at hc; obtain ⟨c', hc', rfl⟩ := hc; rw [(hadv c' hc').1]; exact hd c' hc'
  have hS : unionAll (kids.map fun c => c.advance 1) = unionAll kids := by
    unfold unionAll; rw [List.map_map]; congr 1; apply List.map_congr_left; intro c hc; exact (hadv c hc).1
  have hmin : minDoc (kids.map fun c => c.advance 1) = atLeast (unionAll kids) 1 := by
    rw [← hS]
    apply minDoc_atLeast _ 1 hdocs
    intro c hc; simp only [List.mem_map] at hc; obtain ⟨c', hc', rfl⟩ := hc; rw [(hadv c' hc').2.2, (hadv c' hc').1]
  simp only [Uni.next, show (0 : Nat) ≠ endDoc from by unfold endDoc; decide, ↓reduceIte, Bool.false_eq_true]
  refine ⟨?_, hmin, fun hne => ⟨by simp, ?_, ?_, ?_⟩⟩
  · rw [List.map_map]; apply List.map_congr_left; intro c hc; exact (hadv c hc).1
  · intro c hc; simp only [List.mem_map] at hc; obtain ⟨c', hc', rfl⟩ := hc; exact (hadv c' hc').2.1
  · intro c hc; simp only [List.mem_map] at hc; obtain ⟨c', hc', rfl⟩ := hc
    rw [(hadv c' hc').2.2, (hadv c' hc').1, hmin]
    have hok := unionAll_ok kids hd
    rw [hmin] at hne
    have hm := atLeast_mem _ _ hne
    have hpos := (hok.2 _ hm).1
    have hv := hd c' hc'
    rcases atLeast_cases hv.1 (fun y hy => (hv.2 y hy).2) 1 with ⟨he, hall⟩ | ⟨hm2, hge2, hmin2⟩
    · rw [he]; symm; apply atLeast_none; intro y hy; have := hall y hy; have := (hv.2 y hy).1; omega
    · symm; apply atLeast_eq_of hv.1 hm2 (by
        rcases (atLeast_cases hok.1 (fun y hy => (hok.2 y hy).2) 1) with ⟨he3, _⟩ | ⟨_, _, hmin3⟩
        · exact absurd he3 hne
        · exact hmin3 _ ((mem_unionAll kids hd _).2 ⟨c', hc', hm2⟩) hge2)
      intro y hy hty; exact hmin2 y hy (by have := (hv.2 y hy).1; omega)
  · change minDoc (kids.map fun c => c.advance 1) < endDoc
    change minDoc (kids.map fun c => c.advance 1) ≠ endDoc at hne
    rw [hmin] at hne ⊢
    have := atLeast_le_end (unionAll kids) 1 (fun y hy => ((unionAll_ok kids hd).2 y hy).2); omega

structure Diff where
  inc : Leaf
  exc : Leaf
  doc : Nat

def dSettle : Nat → Leaf → Leaf → Leaf × Leaf × Nat
  | 0, i, e => (i, e, endDoc)
  | f + 1, i, e =>
    if i.doc = endDoc then (i, e, endDoc)
    else if (e.advance i.doc).doc ≠ i.doc then (i, e.advance i.doc, i.doc)
    else dSettle f i.next (e.advance i.doc)

def Diff.next (x : Diff) : Diff :=
  if x.doc = endDoc then x
  else ⟨(dSettle (endDoc + 1) x.inc.next x.exc).1, (dSettle (endDoc + 1) x.inc.next x.exc).2.1,
    (dSettle (endDoc + 1) x.inc.next x.exc).2.2⟩

def diffDrain : Nat → Diff → List Nat
  | 0, _ => []
  | f + 1, x => if x.next.doc = endDoc then [] else x.next.doc :: diffDrain f x.next

def diffSet (A B : List Nat) : List Nat := A.filter fun y => decide (y ∉ B)

def ExcOk (e : Leaf) (d : Nat) : Prop := e.Valid ∧ (e.doc = 0 ∨ ∃ t, 1 ≤ t ∧ t ≤ d ∧ e.doc = atLeast e.S t)

theorem advance_exact {e : Leaf} {d : Nat} (h : ExcOk e d) (hd1 : 1 ≤ d) (hde : d ≤ endDoc) :
    (e.advance d).doc = atLeast e.S d ∧ (e.advance d).S = e.S ∧ (e.advance d).Valid := by
  have hs := advance_spec h.1 hd1 hde
  have hb : ∀ y ∈ e.S, y < endDoc := fun y hy => (h.1.1.2 y hy).2
  refine ⟨?_, hs.2.2.1, hs.1⟩
  by_cases hlt : e.doc < d
  · exact hs.2.2.2.1 hlt
  · rw [hs.2.2.2.2 (by omega)]
    rcases h.2 with e0 | ⟨t, ht1, htd, het⟩
    · omega
    · rw [het]
      apply atLeast_gap h.1.1.1 hb htd
      intro y hy hty
      have := atLeast_least h.1.1.1 hy hty
      omega

theorem excOk_mono {e : Leaf} {d d' : Nat} (h : ExcOk e d) (hle : d ≤ d') : ExcOk e d' := by
  refine ⟨h.1, ?_⟩
  rcases h.2 with e0 | ⟨t, ht1, htd, het⟩
  · exact Or.inl e0
  · exact Or.inr ⟨t, ht1, by omega, het⟩

theorem next_spec {c : Leaf} (hv : c.Valid) (hne : c.doc ≠ endDoc) :
    c.next.doc = atLeast c.S (c.doc + 1) ∧ c.next.S = c.S ∧ c.next.Valid := by
  unfold Leaf.next
  simp only [hne, ↓reduceIte]
  refine ⟨by simp, by simp, hv.1, ?_⟩
  by_cases e : atLeast c.S (c.doc + 1) = endDoc
  · exact Or.inr (Or.inl e)
  · exact Or.inr (Or.inr (atLeast_mem _ _ e))

theorem dSettle_spec (A B : List Nat) (hA : Docs A) (hB : Docs B) :
    ∀ (fuel : Nat) (i e : Leaf) (s : Nat), i.S = A → e.S = B → i.Valid → 1 ≤ s → s ≤ endDoc → i.doc = atLeast A s →
      ExcOk e i.doc → endDoc - i.doc < fuel →
      (dSettle fuel i e).2.2 = atLeast (diffSet A B) s ∧ (dSettle fuel i e).1.S = A ∧ (dSettle fuel i e).2.1.S = B ∧
        (dSettle fuel i e).1.Valid ∧ (dSettle fuel i e).1.doc = (dSettle fuel i e).2.2 ∧
        ExcOk (dSettle fuel i e).2.1 (dSettle fuel i e).2.2 := by
  have hAb : ∀ y ∈ A, y < endDoc := fun y hy => (hA.2 y hy).2
  have hBb : ∀ y ∈ B, y < endDoc := fun y hy => (hB.2 y hy).2
  have hDs : Strict (diffSet A B) := strict_filter hA.1 _
  have hDb : ∀ y ∈ diffSet A B, y < endDoc := fun y hy => hAb y (List.mem_filter.1 hy).1
  intro fuel
  induction fuel with
  | zero => intro _ _ _ _ _ _ _ _ _ _ hf; omega
  | succ f ih =>
    intro i e s hiA heB hiv hs1 hse hid hex hf
    unfold dSettle
    split
    · rename_i hend
      have hnone : ∀ y ∈ A, y < s := by
        rcases atLeast_cases hA.1 hAb s with ⟨_, hall⟩ | ⟨hm, _, _⟩
        · exact hall
        · rw [← hid, hend] at hm; have := hAb _ hm; omega
      have : atLeast (diffSet A B) s = endDoc := atLeast_none (fun y hy => hnone y (List.mem_filter.1 hy).1)
      refine ⟨by simp only; rw [this], hiA, heB, hiv, by simp only; exact hend, ?_⟩
      simp only; rw [← hend]; exact hex
    · rename_i hne
      have hdA : i.doc ∈ A := by rw [hid] at hne ⊢; exact atLeast_mem _ _ hne
      have hds : s ≤ i.doc := by rw [hid]; exact atLeast_ge _ _ hAb hse
      have hdmin : ∀ y ∈ A, s ≤ y → i.doc ≤ y := fun y hy hsy => by rw [hid]; exact atLeast_least hA.1 hy hsy
      have hde : i.doc < endDoc := hAb _ hdA
      have hadv := advance_exact hex (by omega) (by omega)
      split
      · rename_i hmis
        have hnotB : i.doc ∉ B := by
          intro hm
          apply hmis
          rw [hadv.1, heB]
          exact atLeast_eq_of hB.1 hm (Nat.le_refl _) (fun y _ hy => hy)
        have hres : atLeast (diffSet A B) s = i.doc :=
          atLeast_eq_of hDs (List.mem_filter.2 ⟨hdA, by simp [hnotB]⟩) hds
            (fun y hy hsy => hdmin y (List.mem_filter.1 hy).1 hsy)
        refine ⟨by simp only; rw [hres], hiA, by simp only; rw [hadv.2.1, heB], hiv, rfl, ?_⟩
        simp only
        exact ⟨hadv.2.2, Or.inr ⟨i.doc, by omega, Nat.le_refl _, by rw [hadv.1, hadv.2.1]⟩⟩
      · rename_i hmat
        simp only [Decidable.not_not] at hmat
        have h1 : atLeast B i.doc = i.doc := by rw [← heB, ← hadv.1]; exact hmat
        have hdB : i.doc ∈ B := by
          have := atLeast_mem B i.doc (by rw [h1]; omega)
          rw [h1] at this; exact this
        have hn := next_spec hiv hne
        have hnA : i.next.doc = atLeast A (i.doc + 1) := by rw [hn.1, hiA]
        have hnge : i.doc + 1 ≤ i.next.doc := by rw [hnA]; exact atLeast_ge _ _ hAb (by omega)
        have hex' : ExcOk (e.advance i.doc) i.next.doc :=
          ⟨hadv.2.2, Or.inr ⟨i.doc, by omega, by omega, by rw [hadv.1, hadv.2.1]⟩⟩
        have ihr := ih i.next (e.advance i.doc) (i.doc + 1) (by rw [hn.2.1, hiA]) (by rw [hadv.2.1, heB]) hn.2.2
          (by omega) (by omega) hnA hex' (by omega)
        have hgap : atLeast (diffSet A B) s = atLeast (diffSet A B) (i.doc + 1) := by
          apply atLeast_gap hDs hDb (by omega)
          intro y hy hsy
          have hyA := (List.mem_filter.1 hy).1
          have hyB : y ∉ B := by have := (List.mem_filter.1 hy).2; simpa using this
          have := hdmin y hyA hsy
          have : y ≠ i.doc := fun e' => hyB (e' ▸ hdB)
          omega
        rw [hgap]
        exact ihr

theorem diffDrain_spec (A B : List Nat) (hA : Docs A) (hB : Docs B) :
    ∀ (fuel : Nat) (x : Diff), x.inc.S = A → x.exc.S = B → x.inc.Valid → x.inc.doc = x.doc → ExcOk x.exc x.doc →
      x.doc < endDoc → ((diffSet A B).filter fun y => decide (x.doc < y)).length < fuel →
      diffDrain fuel x = (diffSet A B).filter fun y => decide (x.doc < y) := by
  have hAb : ∀ y ∈ A, y < endDoc := fun y hy => (hA.2 y hy).2
  have hDs : Strict (diffSet A B) := strict_filter hA.1 _
  have hDb : ∀ y ∈ diffSet A B, y < endDoc := fun y hy => hAb y (List.mem_filter.1 hy).1
  intro fuel
  induction fuel with
  | zero => intro _ _ _ _ _ _ _ h; omega
  | succ f ih =>
    intro x hiA heB hiv hid hex hlt hf
    have hne : x.inc.doc ≠ endDoc := by omega
    have hn := next_spec hiv hne
    have hnA : x.inc.next.doc = atLeast A (x.doc + 1) := by rw [hn.1, hiA, hid]
    have hnge : x.doc + 1 ≤ x.inc.next.doc := by rw [hnA]; exact atLeast_ge _ _ hAb (by omega)
    have hds := dSettle_spec A B hA hB (endDoc + 1) x.inc.next x.exc (x.doc + 1) (by rw [hn.2.1, hiA]) heB hn.2.2
      (by omega) (by omega) hnA (excOk_mono hex (by omega)) (by omega)
    have hstep := filter_gt_step hDs hDb x.doc
    have hdoc : x.next.doc = atLeast (diffSet A B) (x.doc + 1) := by
      unfold Diff.next; simp only [show x.doc ≠ endDoc from by omega, ↓reduceIte]; exact hds.1
    unfold diffDrain
    rw [hdoc, hstep]
    by_cases hx : atLeast (diffSet A B) (x.doc + 1) = endDoc
    · simp only [hx, ↓reduceIte]
    · simp only [hx, ↓reduceIte]
      have hle := atLeast_le_end (diffSet A B) (x.doc + 1) hDb
      have hnext : x.next = ⟨(dSettle (endDoc + 1) x.inc.next x.exc).1, (dSettle (endDoc + 1) x.inc.next x.exc).2.1,
          (dSettle (endDoc + 1) x.inc.next x.exc).2.2⟩ := by
        unfold Diff.next; simp only [show x.doc ≠ endDoc from by omega, ↓reduceIte]
      rw [ih x.next (by rw [hnext]; exact hds.2.1) (by rw [hnext]; exact hds.2.2.1) (by rw [hnext]; exact hds.2.2.2.1)
        (by rw [hnext]; exact hds.2.2.2.2.1) (by rw [hnext]; exact hds.2.2.2.2.2) (by rw [hdoc]; omega)
        (by rw [hdoc]; rw [hstep] at hf; simp only [hx, ↓reduceIte, List.length_cons] at hf; omega), hdoc]

theorem diffDrain_fresh (A B : List Nat) (hA : Docs A) (hB : Docs B) :
    diffDrain ((diffSet A B).length + 1) ⟨fresh A, fresh B, 0⟩ = diffSet A B := by
  have h := diffDrain_spec A B hA hB ((diffSet A B).length + 1) ⟨fresh A, fresh B, 0⟩ rfl rfl ⟨hA, Or.inl rfl⟩ rfl
    ⟨⟨hB, Or.inl rfl⟩, Or.inl rfl⟩ (show (0 : Nat) < endDoc by unfold endDoc; decide)
    (by simp only; have := List.length_filter_le (fun y => decide (0 < y)) (diffSet A B); omega)
  rw [h]
  apply List.filter_eq_self.2
  intro y hy
  have := (hA.2 y (List.mem_filter.1 hy).1).1
  simp; omega

theorem uniDrain_fresh (kids : List Leaf) (hd : ∀ c ∈ kids, Docs c.S) (h0 : ∀ c ∈ kids, c.doc = 0) :
    uniDrain ((unionAll kids).length + 1) ⟨kids, 0, false⟩ = unionAll kids := by
  have hst := uni_start kids hd h0
  simp only at hst
  have hU := unionAll_ok kids hd
  unfold uniDrain
  rw [hst.2.1]
  have hstep := filter_gt_step hU.1 (fun y hy => (hU.2 y hy).2) 0
  have hall : (unionAll kids).filter (fun y => decide (0 < y)) = unionAll kids := by
    apply List.filter_eq_self.2; intro y hy; have := (hU.2 y hy).1; simp; omega
  rw [hall] at hstep
  simp only [Nat.zero_add] at hstep
  by_cases hx : atLeast (unionAll kids) 1 = endDoc
  · simp only [hx, ↓reduceIte]; rw [hstep]; simp [hx]
  · simp only [hx, ↓reduceIte]
    have hok := hst.2.2 (by rw [hst.2.1]; exact hx)
    conv => rhs; rw [hstep]
    simp only [hx, ↓reduceIte]
    rw [uniDrain_spec kids hd _ _ (by rw [hst.1]) hok (by
      rw [hst.2.1]
      have := congrArg List.length hstep
      simp only [hx, ↓reduceIte, List.length_cons] at this
      omega), hst.2.1]

end Postings
