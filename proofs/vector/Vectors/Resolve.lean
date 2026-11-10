import Vectors.Bits
import Vectors.Merge

namespace Vectors

structure ReaderOf (L : Type) where
  own : L
  vis : L → Bool
  gt : L → L → Bool

section Resolve
variable {L : Type} [DecidableEq L]

def resolveFrom (r : ReaderOf L) : List L → Option L → Option L
  | [], best => best
  | c :: cs, best =>
    if c = r.own then some c
    else if r.vis c then
      match best with
      | none => resolveFrom r cs (some c)
      | some b => if r.gt c b then resolveFrom r cs (some c) else resolveFrom r cs (some b)
    else resolveFrom r cs best

def resolveL (r : ReaderOf L) (ls : List L) : Option L := resolveFrom r ls none

theorem resolveFrom_visible (r : ReaderOf L) (hown : r.vis r.own = true) :
    ∀ (ls : List L) (best : Option L), resolveFrom r ls best = resolveFrom r (ls.filter r.vis) best := by
  intro ls
  induction ls with
  | nil => intro best; rfl
  | cons c cs ih =>
    intro best
    by_cases hv : r.vis c = true
    · rw [List.filter_cons_of_pos hv]
      by_cases hc : c = r.own
      · simp only [resolveFrom, hc, ↓reduceIte]
      · cases best with
        | none => simp only [resolveFrom, hc, hv, ↓reduceIte]; exact ih _
        | some b =>
          by_cases hg : r.gt c b = true
          · simp only [resolveFrom, hc, hv, hg, ↓reduceIte]; exact ih _
          · simp only [resolveFrom, hc, hv, hg, ↓reduceIte]; exact ih _
    · have hf : r.vis c = false := by simpa using hv
      rw [List.filter_cons_of_neg hv]
      have hne : c ≠ r.own := fun e => by rw [e, hown] at hf; exact absurd hf (by decide)
      simp only [resolveFrom, hne, hf, ↓reduceIte, Bool.false_eq_true]
      exact ih best

theorem resolve_visible (r : ReaderOf L) (hown : r.vis r.own = true) (ls : List L) :
    resolveL r ls = resolveL r (ls.filter r.vis) :=
  resolveFrom_visible r hown ls none

theorem resolve_congr (r : ReaderOf L) (hown : r.vis r.own = true) {l₁ l₂ : List L}
    (h : l₁.filter r.vis = l₂.filter r.vis) : resolveL r l₁ = resolveL r l₂ := by
  rw [resolve_visible r hown l₁, resolve_visible r hown l₂, h]

theorem resolveFrom_own (r : ReaderOf L) : ∀ (ls : List L) (best : Option L),
    r.own ∈ ls → resolveFrom r ls best = some r.own := by
  intro ls
  induction ls with
  | nil => intro best h; simp at h
  | cons c cs ih =>
    intro best h
    by_cases hc : c = r.own
    · simp only [resolveFrom, hc, ↓reduceIte]
    · have hm : r.own ∈ cs := by
        rcases List.mem_cons.mp h with e | e
        · exact absurd e.symm hc
        · exact e
      by_cases hv : r.vis c = true
      · cases best with
        | none => simp only [resolveFrom, hc, hv, ↓reduceIte]; exact ih _ hm
        | some b =>
          by_cases hg : r.gt c b = true
          · simp only [resolveFrom, hc, hv, hg, ↓reduceIte]; exact ih _ hm
          · simp only [resolveFrom, hc, hv, hg, ↓reduceIte]; exact ih _ hm
      · simp only [resolveFrom, hc, hv, ↓reduceIte]; exact ih _ hm

theorem resolve_own (r : ReaderOf L) (ls : List L) (h : r.own ∈ ls) : resolveL r ls = some r.own :=
  resolveFrom_own r ls none h

theorem resolveFrom_mem (r : ReaderOf L) : ∀ (ls : List L) (best : Option L) (c : L),
    resolveFrom r ls best = some c → best = some c ∨ (c ∈ ls ∧ (c = r.own ∨ r.vis c = true)) := by
  intro ls
  induction ls with
  | nil => intro best c h; left; exact h
  | cons x xs ih =>
    intro best c h
    have lift : ∀ o, (o = some c ∨ (c ∈ xs ∧ (c = r.own ∨ r.vis c = true))) →
        (o = some c → (best = some c ∨ (c ∈ x :: xs ∧ (c = r.own ∨ r.vis c = true)))) →
        best = some c ∨ (c ∈ x :: xs ∧ (c = r.own ∨ r.vis c = true)) := by
      intro o e f
      rcases e with e | e
      · exact f e
      · right; exact ⟨List.mem_cons_of_mem x e.1, e.2⟩
    by_cases hx : x = r.own
    · subst hx
      simp only [resolveFrom, ↓reduceIte] at h
      cases h
      right; exact ⟨List.mem_cons_self .., Or.inl rfl⟩
    · by_cases hv : r.vis x = true
      · cases best with
        | none =>
          simp only [resolveFrom, hx, hv, ↓reduceIte] at h
          exact lift _ (ih _ c h) (fun e => by cases e; right; exact ⟨List.mem_cons_self .., Or.inr hv⟩)
        | some b =>
          by_cases hg : r.gt x b = true
          · simp only [resolveFrom, hx, hv, hg, ↓reduceIte] at h
            exact lift _ (ih _ c h) (fun e => by cases e; right; exact ⟨List.mem_cons_self .., Or.inr hv⟩)
          · simp only [resolveFrom, hx, hv, hg, ↓reduceIte] at h
            exact lift _ (ih _ c h) (fun e => Or.inl e)
      · simp only [resolveFrom, hx, hv, ↓reduceIte] at h
        exact lift _ (ih _ c h) (fun e => Or.inl e)

theorem resolve_mem (r : ReaderOf L) (ls : List L) (c : L) (h : resolveL r ls = some c) :
    c ∈ ls ∧ (c = r.own ∨ r.vis c = true) := by
  rcases resolveFrom_mem r ls none c h with e | e
  · cases e
  · exact e

theorem resolveFrom_some (r : ReaderOf L) : ∀ (ls : List L) (b : L), resolveFrom r ls (some b) ≠ none := by
  intro ls
  induction ls with
  | nil => intro b; simp [resolveFrom]
  | cons x xs ih =>
    intro b
    by_cases hx : x = r.own
    · simp only [resolveFrom, hx, ↓reduceIte]; simp
    · by_cases hv : r.vis x = true
      · by_cases hg : r.gt x b = true
        · simp only [resolveFrom, hx, hv, hg, ↓reduceIte]; exact ih _
        · simp only [resolveFrom, hx, hv, hg, ↓reduceIte]; exact ih _
      · simp only [resolveFrom, hx, hv, ↓reduceIte]; exact ih _

theorem resolve_none_iff (r : ReaderOf L) (ls : List L) :
    resolveL r ls = none ↔ ∀ c ∈ ls, c ≠ r.own ∧ r.vis c = false := by
  unfold resolveL
  induction ls with
  | nil => simp [resolveFrom]
  | cons x xs ih =>
    by_cases hx : x = r.own
    · simp only [resolveFrom, hx, ↓reduceIte]
      constructor
      · intro h; cases h
      · intro h; exact absurd rfl (h r.own (List.mem_cons_self ..)).1
    · by_cases hv : r.vis x = true
      · simp only [resolveFrom, hx, hv, ↓reduceIte]
        constructor
        · intro h; exact absurd h (resolveFrom_some r xs x)
        · intro h; have := (h x (List.mem_cons_self ..)).2; rw [hv] at this; exact absurd this (by decide)
      · have hf : r.vis x = false := by simpa using hv
        simp only [resolveFrom, hx, hf, Bool.false_eq_true, ↓reduceIte]
        rw [ih]
        constructor
        · intro h c hc
          rcases List.mem_cons.mp hc with e | e
          · subst e; exact ⟨hx, hf⟩
          · exact h c e
        · intro h c hc; exact h c (List.mem_cons_of_mem x hc)

structure RankOrder {L : Type} (gt : L → L → Bool) : Prop where
  irrefl : ∀ a, gt a a = false
  trans : ∀ a b c, gt a b = true → gt b c = true → gt a c = true
  neg_trans : ∀ a b c, gt a b = true → gt a c = true ∨ gt c b = true

theorem resolveFrom_highest (r : ReaderOf L) (ho : RankOrder r.gt) :
    ∀ (ls : List L) (best : Option L) (c : L), r.own ∉ ls →
      resolveFrom r ls best = some c →
      (∀ d ∈ ls, r.vis d = true → r.gt d c = false) ∧
      (∀ b, best = some b → r.gt b c = false) := by
  intro ls
  induction ls with
  | nil =>
    intro best c _ h
    refine ⟨fun d hd => by simp at hd, ?_⟩
    intro b hb
    rw [hb] at h
    cases h
    exact ho.irrefl _
  | cons x xs ih =>
    intro best c hno h
    have hx : x ≠ r.own := fun e => hno (e ▸ List.mem_cons_self ..)
    have hno' : r.own ∉ xs := fun e => hno (List.mem_cons_of_mem x e)
    simp only [resolveFrom, ite_eq_right hx] at h
    by_cases hv : r.vis x = true
    · rw [ite_eq_left hv] at h
      cases best with
      | none =>
        have := ih (some x) c hno' h
        refine ⟨?_, fun b hb => by cases hb⟩
        intro d hd hdv
        rcases List.mem_cons.mp hd with e | e
        · subst e; exact this.2 d rfl
        · exact this.1 d e hdv
      | some b =>
        simp only at h
        by_cases hg : r.gt x b = true
        · rw [ite_eq_left hg] at h
          have := ih (some x) c hno' h
          refine ⟨?_, ?_⟩
          · intro d hd hdv
            rcases List.mem_cons.mp hd with e | e
            · subst e; exact this.2 d rfl
            · exact this.1 d e hdv
          · intro b' hb'
            cases hb'
            cases hbc : r.gt b c
            · rfl
            · rcases ho.neg_trans b c x hbc with e | e
              · have := ho.trans b x b e hg
                rw [ho.irrefl] at this
                exact absurd this (by decide)
              · rw [this.2 x rfl] at e
                exact absurd e (by decide)
        · have hgf : r.gt x b = false := by simpa using hg
          rw [hgf] at h
          simp only [Bool.false_eq_true, ite_false] at h
          have := ih (some b) c hno' h
          refine ⟨?_, this.2⟩
          intro d hd hdv
          rcases List.mem_cons.mp hd with e | e
          · subst e
            cases hdc : r.gt d c
            · rfl
            · rcases ho.neg_trans d c b hdc with e | e
              · rw [hgf] at e; exact absurd e (by decide)
              · rw [this.2 b rfl] at e; exact absurd e (by decide)
          · exact this.1 d e hdv
    · have hf : r.vis x = false := by simpa using hv
      rw [hf] at h
      simp only [Bool.false_eq_true, ite_false] at h
      have := ih best c hno' h
      refine ⟨?_, this.2⟩
      intro d hd hdv
      rcases List.mem_cons.mp hd with e | e
      · subst e; rw [hf] at hdv; exact absurd hdv (by decide)
      · exact this.1 d e hdv

theorem resolve_highest (r : ReaderOf L) (ho : RankOrder r.gt) (ls : List L) (c : L)
    (hno : r.own ∉ ls) (h : resolveL r ls = some c) :
    r.vis c = true ∧ ∀ d ∈ ls, r.vis d = true → r.gt d c = false := by
  have hm := resolve_mem r ls c h
  refine ⟨?_, (resolveFrom_highest r ho ls none c hno h).1⟩
  rcases hm.2 with e | e
  · exact absurd (e ▸ hm.1) hno
  · exact e

theorem resolveFrom_older (r : ReaderOf L) (ho : RankOrder r.gt) :
    ∀ (ls : List L) (best : Option L) (c : L), r.own ∉ ls →
      resolveFrom r ls best = some c →
      best = some c ∨ ∃ pre post, ls = pre ++ c :: post ∧ (∀ b, best = some b → r.gt c b = true) ∧
        ∀ d ∈ pre, r.vis d = true → r.gt c d = true := by
  intro ls
  induction ls with
  | nil => intro best c _ h; left; exact h
  | cons x xs ih =>
    intro best c hno h
    have hx : x ≠ r.own := fun e => hno (e ▸ List.mem_cons_self ..)
    have hno' : r.own ∉ xs := fun e => hno (List.mem_cons_of_mem x e)
    simp only [resolveFrom, ite_eq_right hx] at h
    by_cases hv : r.vis x = true
    · rw [ite_eq_left hv] at h
      cases best with
      | none =>
        rcases ih (some x) c hno' h with e | ⟨pre, post, hl, hb, hpre⟩
        · cases e
          right; exact ⟨[], xs, rfl, (fun b hb => by cases hb), (fun d hd => by simp at hd)⟩
        · right
          refine ⟨x :: pre, post, by rw [hl]; rfl, (fun b hb => by cases hb), ?_⟩
          intro d hd hdv
          rcases List.mem_cons.mp hd with e | e
          · subst e; exact hb d rfl
          · exact hpre d e hdv
      | some b =>
        simp only at h
        by_cases hg : r.gt x b = true
        · rw [ite_eq_left hg] at h
          rcases ih (some x) c hno' h with e | ⟨pre, post, hl, hb, hpre⟩
          · cases e
            right; exact ⟨[], xs, rfl, (fun b' hb' => by cases hb'; exact hg), (fun d hd => by simp at hd)⟩
          · right
            refine ⟨x :: pre, post, by rw [hl]; rfl, ?_, ?_⟩
            · intro b' hb'
              cases hb'
              exact ho.trans c x b (hb x rfl) hg
            · intro d hd hdv
              rcases List.mem_cons.mp hd with e | e
              · subst e; exact hb d rfl
              · exact hpre d e hdv
        · have hgf : r.gt x b = false := by simpa using hg
          rw [hgf] at h
          simp only [Bool.false_eq_true, ite_false] at h
          rcases ih (some b) c hno' h with e | ⟨pre, post, hl, hb, hpre⟩
          · left; exact e
          · right
            refine ⟨x :: pre, post, by rw [hl]; rfl, hb, ?_⟩
            intro d hd hdv
            rcases List.mem_cons.mp hd with e | e
            · subst e
              rcases ho.neg_trans c b d (hb b rfl) with e | e
              · exact e
              · rw [hgf] at e; exact absurd e (by decide)
            · exact hpre d e hdv
    · have hf : r.vis x = false := by simpa using hv
      rw [hf] at h
      simp only [Bool.false_eq_true, ite_false] at h
      rcases ih best c hno' h with e | ⟨pre, post, hl, hb, hpre⟩
      · left; exact e
      · right
        refine ⟨x :: pre, post, by rw [hl]; rfl, hb, ?_⟩
        intro d hd hdv
        rcases List.mem_cons.mp hd with e | e
        · subst e; rw [hf] at hdv; exact absurd hdv (by decide)
        · exact hpre d e hdv

theorem resolve_older (r : ReaderOf L) (ho : RankOrder r.gt) (ls : List L) (c : L)
    (hno : r.own ∉ ls) (h : resolveL r ls = some c) :
    ∃ pre post, ls = pre ++ c :: post ∧ ∀ d ∈ pre, r.vis d = true → r.gt c d = true := by
  rcases resolveFrom_older r ho ls none c hno h with e | ⟨pre, post, hl, _, hd⟩
  · cases e
  · exact ⟨pre, post, hl, hd⟩

end Resolve

structure Lbl where
  level : Nat
  comps : Nat
  trust : Nat
deriving DecidableEq, Repr, Inhabited

def compCount (l : Lbl) : Nat := bitCount l.comps 256

def rankGt (x y : Lbl) : Bool :=
  decide (x.level > y.level) || (decide (x.level = y.level) &&
    (decide (compCount x > compCount y) || (decide (compCount x = compCount y) && decide (x.trust > y.trust))))

def dominates (r d : Lbl) : Bool :=
  decide (d.level ≤ r.level) && decide (d.comps &&& r.comps = d.comps) && decide (r.trust ≤ d.trust)

theorem rankGt_order : RankOrder rankGt := by
  refine ⟨?_, ?_, ?_⟩
  · intro a; simp [rankGt]
  · intro a b c hab hbc
    simp only [rankGt, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hab hbc ⊢
    omega
  · intro a b c hab
    simp only [rankGt, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hab ⊢
    omega

theorem rankGt_lex (x y : Lbl) : rankGt x y = true ↔
    x.level > y.level ∨ (x.level = y.level ∧ (compCount x > compCount y ∨
      (compCount x = compCount y ∧ x.trust > y.trust))) := by
  simp [rankGt]

theorem dominates_refl (a : Lbl) : dominates a a = true := by
  simp [dominates, Nat.and_self]

theorem dominates_trans (a b c : Lbl) (hab : dominates a b = true) (hbc : dominates b c = true) :
    dominates a c = true := by
  simp only [dominates, Bool.and_eq_true, decide_eq_true_eq] at hab hbc ⊢
  refine ⟨⟨by omega, ?_⟩, by omega⟩
  calc c.comps &&& a.comps = (c.comps &&& b.comps) &&& a.comps := by rw [hbc.1.2]
    _ = c.comps &&& (b.comps &&& a.comps) := Nat.and_assoc _ _ _
    _ = c.comps &&& b.comps := by rw [hab.1.2]
    _ = c.comps := hbc.1.2

theorem bitCount_subset_le (d r : Nat) (h : d &&& r = d) : ∀ (w : Nat), bitCount d w ≤ bitCount r w := by
  intro w
  induction w with
  | zero => simp [bitCount]
  | succ w ih =>
    simp only [bitCount]
    have hb : d.testBit w = true → r.testBit w = true := by
      intro hd
      have := congrArg (fun x => x.testBit w) h
      simp only [Nat.testBit_and] at this
      rw [hd] at this
      simpa using this
    cases hd : d.testBit w <;> cases hr : r.testBit w <;> simp_all <;> omega

theorem own_outranked_only_by_trust (r d : Lbl) (hdom : dominates r d = true) (hgt : rankGt d r = true) :
    d.level = r.level ∧ compCount d = compCount r ∧ d.trust > r.trust := by
  simp only [dominates, Bool.and_eq_true, decide_eq_true_eq] at hdom
  have hc : compCount d ≤ compCount r := bitCount_subset_le d.comps r.comps hdom.1.2 256
  simp only [rankGt, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hgt
  omega

theorem rankOrder_comap {L K : Type} (f : L → K) (gt : K → K → Bool) (h : RankOrder gt) :
    RankOrder (fun x y => gt (f x) (f y)) :=
  ⟨fun a => h.irrefl (f a), fun a b c => h.trans (f a) (f b) (f c), fun a b c => h.neg_trans (f a) (f b) (f c)⟩

def labelReader (tbl : Nat → Lbl) (own : Nat) : ReaderOf Nat :=
  ⟨own, fun d => dominates (tbl own) (tbl d), fun x y => rankGt (tbl x) (tbl y)⟩

theorem labelReader_own (tbl : Nat → Lbl) (own : Nat) : (labelReader tbl own).vis own = true :=
  dominates_refl (tbl own)

theorem labelReader_order (tbl : Nat → Lbl) (own : Nat) : RankOrder (labelReader tbl own).gt :=
  rankOrder_comap tbl rankGt rankGt_order

structure LState (L N P : Type) where
  parts : L → Option P
  index : N → List L
  stream : L → Nat

structure PartAcc (N P : Type) where
  count : P → Nat
  attrs : P → Nat
  hasAttr : P → N → Bool

structure ViewObj (L N : Type) where
  labels : List L
  shadows : List (L × N)
  size : Nat
  attrs : Nat
deriving DecidableEq

section View
set_option linter.unusedSectionVars false
variable {L N P : Type} [DecidableEq L] [DecidableEq N]

def present (s : LState L N P) (l : L) : Bool := (s.parts l).isSome

def inView (r : ReaderOf L) (s : LState L N P) (l : L) : Bool := present s l && r.vis l

def visibleLabels (le : L → L → Bool) (labelsU : List L) (r : ReaderOf L) (s : LState L N P) : List L :=
  (labelsU.filter (inView r s)).mergeSort le

def shadowsOf (r : ReaderOf L) (s : LState L N P) (n : N) : List (L × N) :=
  let ls := s.index n
  if 2 ≤ ls.length then
    let v := ls.filter (inView r s)
    if 2 ≤ v.length then (v.filter (fun l => decide (some l ≠ resolveL r ls))).map (fun l => (l, n)) else []
  else []

def partCount (acc : PartAcc N P) (s : LState L N P) (l : L) : Nat := ((s.parts l).map acc.count).getD 0

def partAttrs (acc : PartAcc N P) (s : LState L N P) (l : L) : Nat := ((s.parts l).map acc.attrs).getD 0

def shadowAttr (acc : PartAcc N P) (s : LState L N P) (e : L × N) : Bool :=
  ((s.parts e.1).map (fun p => acc.hasAttr p e.2)).getD false

def viewOpen (acc : PartAcc N P) (le : L → L → Bool) (labelsU : List L) (namesU : List N)
    (r : ReaderOf L) (s : LState L N P) : ViewObj L N :=
  let vl := visibleLabels le labelsU r s
  let sh := namesU.flatMap (shadowsOf r s)
  { labels := vl, shadows := sh,
    size := (vl.map (partCount acc s)).sum - sh.length,
    attrs := (vl.map (partAttrs acc s)).sum - (sh.filter (shadowAttr acc s)).length }

def restrict (r : ReaderOf L) (s : LState L N P) : LState L N P :=
  { parts := fun l => if r.vis l then s.parts l else none,
    index := fun n => (s.index n).filter r.vis,
    stream := fun l => if r.vis l then s.stream l else 0 }

theorem inView_restrict (r : ReaderOf L) (s : LState L N P) (l : L) : inView r (restrict r s) l = inView r s l := by
  unfold inView present restrict
  cases h : r.vis l <;> simp [h]

theorem restrict_parts_view (r : ReaderOf L) (s : LState L N P) (l : L) (h : r.vis l = true) :
    (restrict r s).parts l = s.parts l := by
  simp [restrict, h]

theorem visibleLabels_restrict (le : L → L → Bool) (labelsU : List L) (r : ReaderOf L) (s : LState L N P) :
    visibleLabels le labelsU r (restrict r s) = visibleLabels le labelsU r s := by
  unfold visibleLabels
  congr 1
  exact List.filter_congr (fun l _ => inView_restrict r s l)

theorem visibleLabels_vis (le : L → L → Bool) (labelsU : List L) (r : ReaderOf L) (s : LState L N P) (l : L)
    (h : l ∈ visibleLabels le labelsU r s) : r.vis l = true := by
  unfold visibleLabels at h
  have := (List.mergeSort_perm _ le).mem_iff.mp h
  rw [List.mem_filter] at this
  simp only [inView, Bool.and_eq_true] at this
  exact this.2.2

theorem shadowsOf_restrict (r : ReaderOf L) (hown : r.vis r.own = true) (s : LState L N P) (n : N) :
    shadowsOf r (restrict r s) n = shadowsOf r s n := by
  unfold shadowsOf
  have hiv : inView r (restrict r s) = inView r s := funext (inView_restrict r s)
  have hidx : (restrict r s).index n = (s.index n).filter r.vis := rfl
  have hsub : (s.index n).filter (inView r s) = ((s.index n).filter r.vis).filter (inView r s) := by
    rw [List.filter_filter]
    apply List.filter_congr
    intro l _
    unfold inView
    cases r.vis l <;> simp
  have hv : ((restrict r s).index n).filter (inView r (restrict r s)) = (s.index n).filter (inView r s) := by
    rw [hiv, hidx, ← hsub]
  have hres : resolveL r ((restrict r s).index n) = resolveL r (s.index n) := by
    rw [hidx]
    exact (resolve_visible r hown (s.index n)).symm
  simp only
  rw [hv, hres]
  by_cases h2 : 2 ≤ ((s.index n).filter (inView r s)).length
  · have h1 : 2 ≤ (s.index n).length := Nat.le_trans h2 (List.length_filter_le _ _)
    have h1' : 2 ≤ ((restrict r s).index n).length := by
      rw [hidx]
      have : ((s.index n).filter (inView r s)).length ≤ ((s.index n).filter r.vis).length := by
        rw [hsub]; exact List.length_filter_le _ _
      omega
    simp only [h1, h1', h2, ↓reduceIte]
  · simp only [h2, ↓reduceIte, ite_self]

theorem partCount_restrict (acc : PartAcc N P) (r : ReaderOf L) (s : LState L N P) (l : L) (h : r.vis l = true) :
    partCount acc (restrict r s) l = partCount acc s l := by
  simp [partCount, restrict, h]

theorem partAttrs_restrict (acc : PartAcc N P) (r : ReaderOf L) (s : LState L N P) (l : L) (h : r.vis l = true) :
    partAttrs acc (restrict r s) l = partAttrs acc s l := by
  simp [partAttrs, restrict, h]

theorem shadowsOf_vis (r : ReaderOf L) (s : LState L N P) (n : N) (e : L × N) (h : e ∈ shadowsOf r s n) :
    r.vis e.1 = true := by
  unfold shadowsOf at h
  simp only at h
  split at h
  · split at h
    · rcases List.mem_map.mp h with ⟨l, hl, rfl⟩
      rw [List.mem_filter, List.mem_filter] at hl
      simp only [inView, Bool.and_eq_true] at hl
      exact hl.1.2.2
    · simp at h
  · simp at h

theorem viewOpen_restrict (acc : PartAcc N P) (le : L → L → Bool) (labelsU : List L) (namesU : List N)
    (r : ReaderOf L) (hown : r.vis r.own = true) (s : LState L N P) :
    viewOpen acc le labelsU namesU r (restrict r s) = viewOpen acc le labelsU namesU r s := by
  unfold viewOpen
  have hvl := visibleLabels_restrict le labelsU r s
  have hsh : namesU.flatMap (shadowsOf r (restrict r s)) = namesU.flatMap (shadowsOf r s) := by
    congr 1
    funext n
    exact shadowsOf_restrict r hown s n
  simp only [hvl, hsh]
  have hc : (visibleLabels le labelsU r s).map (partCount acc (restrict r s)) =
      (visibleLabels le labelsU r s).map (partCount acc s) :=
    List.map_congr_left (fun l hl => partCount_restrict acc r s l (visibleLabels_vis le labelsU r s l hl))
  have ha : (visibleLabels le labelsU r s).map (partAttrs acc (restrict r s)) =
      (visibleLabels le labelsU r s).map (partAttrs acc s) :=
    List.map_congr_left (fun l hl => partAttrs_restrict acc r s l (visibleLabels_vis le labelsU r s l hl))
  have hs : (namesU.flatMap (shadowsOf r s)).filter (shadowAttr acc (restrict r s)) =
      (namesU.flatMap (shadowsOf r s)).filter (shadowAttr acc s) := by
    apply List.filter_congr
    intro e he
    rcases List.mem_flatMap.mp he with ⟨n, _, hn⟩
    have := shadowsOf_vis r s n e hn
    simp [shadowAttr, restrict, this]
  rw [hc, ha, hs]

def viewFind (r : ReaderOf L) (s : LState L N P) (n : N) : Option L :=
  match resolveL r (s.index n) with
  | some l => if inView r s l then some l else none
  | none => none

theorem viewFind_restrict (r : ReaderOf L) (hown : r.vis r.own = true) (s : LState L N P) (n : N) :
    viewFind r (restrict r s) n = viewFind r s n := by
  unfold viewFind
  have hres : resolveL r ((restrict r s).index n) = resolveL r (s.index n) := by
    simp only [restrict]
    exact (resolve_visible r hown (s.index n)).symm
  rw [hres]
  cases resolveL r (s.index n) with
  | none => rfl
  | some l => simp only [inView_restrict]

def viewRange (r : ReaderOf L) (s : LState L N P) (namesU : List N) (inRange : N → Bool) (limit : Option Nat) :
    List (N × L) :=
  let hits := (namesU.filter (fun n => inRange n && !(s.index n).isEmpty)).filterMap
    (fun n => (viewFind r s n).map (fun l => (n, l)))
  match limit with
  | some k => hits.take k
  | none => hits

theorem viewFind_hidden (r : ReaderOf L) (hown : r.vis r.own = true) (s : LState L N P) (n : N)
    (h : (s.index n).filter r.vis = []) : viewFind r s n = none := by
  have : resolveL r (s.index n) = none := by
    rw [resolve_visible r hown, h]; rfl
  unfold viewFind
  rw [this]

theorem viewRange_restrict (r : ReaderOf L) (hown : r.vis r.own = true) (s : LState L N P) (namesU : List N)
    (inRange : N → Bool) (limit : Option Nat) :
    viewRange r (restrict r s) namesU inRange limit = viewRange r s namesU inRange limit := by
  unfold viewRange
  have key : ∀ (xs : List N),
      (xs.filter (fun n => inRange n && !((restrict r s).index n).isEmpty)).filterMap
        (fun n => (viewFind r (restrict r s) n).map (fun l => (n, l))) =
      (xs.filter (fun n => inRange n && !(s.index n).isEmpty)).filterMap
        (fun n => (viewFind r s n).map (fun l => (n, l))) := by
    intro xs
    induction xs with
    | nil => rfl
    | cons n ns ih =>
      have hf := viewFind_restrict r hown s n
      by_cases hr : inRange n = true
      · by_cases he : (s.index n).filter r.vis = []
        · have hnone := viewFind_hidden r hown s n he
          have hrest : ((restrict r s).index n).isEmpty = true := by
            simp only [restrict, he]; rfl
          rw [List.filter_cons, List.filter_cons]
          simp only [hr, hrest, Bool.not_true, Bool.and_false, Bool.false_eq_true, ↓reduceIte]
          by_cases hs : (s.index n).isEmpty = true
          · simp only [hs, Bool.not_true, Bool.and_false, Bool.false_eq_true, ↓reduceIte]; exact ih
          · have hs' : (s.index n).isEmpty = false := by simpa using hs
            simp only [hs', Bool.not_false, Bool.and_true, ↓reduceIte, List.filterMap_cons, hnone,
              Option.map_none]
            exact ih
        · have hrest : ((restrict r s).index n).isEmpty = false := by
            simp only [restrict]
            cases hq : (s.index n).filter r.vis with
            | nil => exact absurd hq he
            | cons _ _ => rfl
          have hs' : (s.index n).isEmpty = false := by
            cases hq : s.index n with
            | nil => rw [hq] at he; exact absurd rfl he
            | cons _ _ => rfl
          rw [List.filter_cons, List.filter_cons]
          simp only [hr, hrest, hs', Bool.not_false, Bool.and_true, ↓reduceIte, List.filterMap_cons, hf]
          rw [ih]
      · have hr' : inRange n = false := by simpa using hr
        rw [List.filter_cons, List.filter_cons]
        simp only [hr', Bool.false_and, Bool.false_eq_true, ↓reduceIte]
        exact ih
  simp only
  rw [key]

end View

def skipShadows : List Nat → Nat → Nat
  | [], x => x
  | p :: ps, x => if p ≤ x then skipShadows ps (x + 1) else x

theorem skipShadows_ge : ∀ (ps : List Nat) (x : Nat), x ≤ skipShadows ps x := by
  intro ps
  induction ps with
  | nil => intro x; simp [skipShadows]
  | cons p ps ih =>
    intro x
    unfold skipShadows
    split
    · have := ih (x + 1); omega
    · omega

theorem skipShadows_spec : ∀ (ps : List Nat) (t : Nat), ps.Pairwise (· < ·) →
    skipShadows ps t ∉ ps ∧ skipShadows ps t = t + (ps.filter (fun q => decide (q < skipShadows ps t))).length := by
  intro ps
  induction ps with
  | nil => intro t _; simp [skipShadows]
  | cons p ps ih =>
    intro t hs
    rw [List.pairwise_cons] at hs
    unfold skipShadows
    by_cases hp : p ≤ t
    · simp only [hp, ↓reduceIte]
      have hih := ih (t + 1) hs.2
      have hge := skipShadows_ge ps (t + 1)
      refine ⟨?_, ?_⟩
      · intro hm
        rcases List.mem_cons.mp hm with e | e
        · omega
        · exact hih.1 e
      · rw [List.filter_cons]
        have : decide (p < skipShadows ps (t + 1)) = true := by simp; omega
        simp only [this, ↓reduceIte, List.length_cons]
        omega
    · simp only [hp, ↓reduceIte]
      refine ⟨?_, ?_⟩
      · intro hm
        rcases List.mem_cons.mp hm with e | e
        · omega
        · have := hs.1 t e; omega
      · have : (p :: ps).filter (fun q => decide (q < t)) = [] := by
          rw [List.filter_eq_nil_iff]
          intro q hq
          rcases List.mem_cons.mp hq with e | e
          · subst e; simp; omega
          · have := hs.1 q e; simp; omega
        rw [this]; rfl

end Vectors
