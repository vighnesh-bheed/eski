import Vectors.Owner

set_option autoImplicit false

namespace Vectors

section ViewNames
set_option linter.unusedSectionVars false
variable {L N V P : Type} [DecidableEq L] [DecidableEq N]

structure IndexInv (names : P → List N) (s : LState L N P) : Prop where
  mem : ∀ n l, l ∈ s.index n ↔ ∃ p, s.parts l = some p ∧ n ∈ names p
  nodup : ∀ n, (s.index n).Nodup
  part_nodup : ∀ l p, s.parts l = some p → (names p).Nodup

structure NameLaws (ops : PartOps N V P) (names : P → List N) : Prop where
  create : ∀ x, names (ops.create x) = []
  insert : ∀ p n v, (names (ops.insert p n v)).Perm (names p ++ [n])
  update : ∀ p n v, (names (ops.update p n v)).Perm (names p)
  setAttr : ∀ p n v, (names (ops.setAttr p n v)).Perm (names p)
  remove : ∀ p n, (names (ops.remove p n)).Perm ((names p).erase n)
  empty : ∀ p, ops.empty p = true ↔ names p = []

def partNames (names : P → List N) (s : LState L N P) (l : L) : List N := ((s.parts l).map names).getD []

def unshadowed (names : P → List N) (s : LState L N P) (vo : ViewObj L N) (l : L) : List N :=
  (partNames names s l).filter (fun n => decide ((l, n) ∉ vo.shadows))

theorem nodup_one {α : Type} (a : α) : [a].Nodup := List.nodup_cons.mpr ⟨by simp, List.nodup_nil⟩

theorem flatMap_nodup_of {β : Type} (f : L → List β) : ∀ (vl : List L), vl.Nodup → (∀ l, (f l).Nodup) →
    (∀ l₁ ∈ vl, ∀ l₂ ∈ vl, ∀ b, b ∈ f l₁ → b ∈ f l₂ → l₁ = l₂) → (vl.flatMap f).Nodup := by
  intro vl
  induction vl with
  | nil => intro _ _ _; simp
  | cons x xs ih =>
    intro hnd hf hu
    rw [List.nodup_cons] at hnd
    rw [List.flatMap_cons, List.nodup_append]
    refine ⟨hf x, ih hnd.2 hf (fun l₁ h₁ l₂ h₂ => hu l₁ (List.mem_cons_of_mem x h₁) l₂ (List.mem_cons_of_mem x h₂)), ?_⟩
    intro a ha b hb e
    subst e
    rcases List.mem_flatMap.mp hb with ⟨y, hy, hay⟩
    have := hu x (List.mem_cons_self ..) y (List.mem_cons_of_mem x hy) a ha hay
    subst this
    exact hnd.1 hy

theorem indexInv_empty (names : P → List N) (st : L → Nat) :
    IndexInv names (⟨fun _ => none, fun _ => [], st⟩ : LState L N P) := by
  refine ⟨?_, ?_, ?_⟩
  · intro n l; simp
  · intro n; exact List.nodup_nil
  · intro l p h; simp at h

theorem indexInv_congr (names : P → List N) (a b : LState L N P) (hp : a.parts = b.parts) (hi : a.index = b.index)
    (h : IndexInv names a) : IndexInv names b := by
  refine ⟨?_, ?_, ?_⟩
  · intro n l; rw [← hp, ← hi]; exact h.mem n l
  · intro n; rw [← hi]; exact h.nodup n
  · intro l p hl; rw [← hp] at hl; exact h.part_nodup l p hl

theorem indexInv_setPart (names : P → List N) (s : LState L N P) (inv : IndexInv names s) (w : L) (p p' : P)
    (hp : s.parts w = some p) (hperm : (names p').Perm (names p)) : IndexInv names (setPart s w (some p')) := by
  refine ⟨?_, ?_, ?_⟩
  · intro n l
    simp only [setPart]
    by_cases hl : l = w
    · subst hl
      simp only [↓reduceIte, Option.some.injEq, exists_eq_left']
      rw [inv.mem, hperm.mem_iff]
      simp [hp]
    · simp only [hl, ↓reduceIte]
      exact inv.mem n l
  · exact inv.nodup
  · intro l q hq
    simp only [setPart] at hq
    by_cases hl : l = w
    · subst hl
      simp only [↓reduceIte, Option.some.injEq] at hq
      subst hq
      exact hperm.nodup_iff.mpr (inv.part_nodup l p hp)
    · simp only [hl, ↓reduceIte] at hq
      exact inv.part_nodup l q hq

theorem indexInv_insert (names : P → List N) (s : LState L N P) (inv : IndexInv names s) (w : L) (n : N) (p' : P)
    (hw : w ∉ s.index n)
    (hnew : (∃ p, s.parts w = some p ∧ (names p').Perm (names p ++ [n])) ∨ (s.parts w = none ∧ (names p').Perm [n])) :
    IndexInv names (setIndex (setPart s w (some p')) n (s.index n ++ [w])) := by
  have hpn : ∀ p, s.parts w = some p → n ∉ names p := by
    intro p hp hn
    exact hw ((inv.mem n w).mpr ⟨p, hp, hn⟩)
  refine ⟨?_, ?_, ?_⟩
  · intro m l
    simp only [setIndex, setPart]
    by_cases hm : m = n
    · subst hm
      simp only [↓reduceIte, List.mem_append, List.mem_singleton]
      by_cases hl : l = w
      · subst hl
        simp only [↓reduceIte, Option.some.injEq, exists_eq_left', or_true, true_iff]
        rcases hnew with ⟨p, _, hperm⟩ | ⟨_, hperm⟩
        · rw [hperm.mem_iff]; simp
        · rw [hperm.mem_iff]; simp
      · simp only [hl, ↓reduceIte, or_false]
        exact inv.mem m l
    · simp only [hm, ↓reduceIte]
      by_cases hl : l = w
      · subst hl
        simp only [↓reduceIte, Option.some.injEq, exists_eq_left']
        rw [inv.mem]
        rcases hnew with ⟨p, hp, hperm⟩ | ⟨hp, hperm⟩
        · rw [hperm.mem_iff]; simp [hp, hm]
        · rw [hperm.mem_iff]; simp [hp, hm]
      · simp only [hl, ↓reduceIte]
        exact inv.mem m l
  · intro m
    simp only [setIndex]
    by_cases hm : m = n
    · subst hm
      simp only [↓reduceIte]
      rw [List.nodup_append]
      refine ⟨inv.nodup m, nodup_one w, ?_⟩
      intro a ha b hb e
      rw [List.mem_singleton] at hb
      subst hb; subst e
      exact hw ha
    · simp only [hm, ↓reduceIte]
      exact inv.nodup m
  · intro l q hq
    simp only [setIndex, setPart] at hq
    by_cases hl : l = w
    · subst hl
      simp only [↓reduceIte, Option.some.injEq] at hq
      subst hq
      rcases hnew with ⟨p, hp, hperm⟩ | ⟨_, hperm⟩
      · apply hperm.nodup_iff.mpr
        rw [List.nodup_append]
        refine ⟨inv.part_nodup l p hp, nodup_one n, ?_⟩
        intro a ha b hb e
        rw [List.mem_singleton] at hb
        subst hb; subst e
        exact hpn p hp ha
      · exact hperm.nodup_iff.mpr (nodup_one n)
    · simp only [hl, ↓reduceIte] at hq
      exact inv.part_nodup l q hq

theorem indexInv_remove (names : P → List N) (s : LState L N P) (inv : IndexInv names s) (w : L) (n : N) (p q : P)
    (hp : s.parts w = some p) (hperm : (names q).Perm ((names p).erase n)) (b : Bool) (hb : b = true → names q = []) :
    IndexInv names (setIndex (setPart s w (if b then none else some q)) n ((s.index n).erase w)) := by
  have hnd := inv.part_nodup w p hp
  have hq : ∀ m, m ∈ names q ↔ m ≠ n ∧ m ∈ names p := by
    intro m; rw [hperm.mem_iff]; exact hnd.mem_erase_iff
  refine ⟨?_, ?_, ?_⟩
  · intro m l
    simp only [setIndex, setPart]
    by_cases hl : l = w
    · subst hl
      by_cases hm : m = n
      · subst hm
        simp only [↓reduceIte]
        rw [(inv.nodup m).mem_erase_iff]
        constructor
        · intro h; exact absurd rfl h.1
        · intro ⟨p', hp', hm'⟩
          cases b
          · simp only [Bool.false_eq_true, ↓reduceIte, Option.some.injEq] at hp'
            subst hp'
            exact absurd rfl ((hq m).mp hm').1
          · simp at hp'
      · simp only [hm, ↓reduceIte]
        rw [inv.mem]
        simp only [hp, Option.some.injEq, exists_eq_left']
        cases b
        · simp only [Bool.false_eq_true, ↓reduceIte, Option.some.injEq, exists_eq_left']
          rw [hq m]
          exact ⟨fun h => ⟨hm, h⟩, fun h => h.2⟩
        · simp only [↓reduceIte, reduceCtorEq, false_and, exists_false, iff_false]
          intro h
          have := (hq m).mpr ⟨hm, h⟩
          rw [hb rfl] at this
          simp at this
    · simp only [hl, ↓reduceIte]
      by_cases hm : m = n
      · subst hm
        simp only [↓reduceIte]
        rw [(inv.nodup m).mem_erase_iff]
        simp only [hl, ne_eq, not_false_eq_true, true_and]
        exact inv.mem m l
      · simp only [hm, ↓reduceIte]
        exact inv.mem m l
  · intro m
    simp only [setIndex]
    by_cases hm : m = n
    · subst hm
      simp only [↓reduceIte]
      exact (inv.nodup m).erase w
    · simp only [hm, ↓reduceIte]
      exact inv.nodup m
  · intro l r hr
    simp only [setIndex, setPart] at hr
    by_cases hl : l = w
    · subst hl
      cases b
      · simp only [↓reduceIte, Bool.false_eq_true, Option.some.injEq] at hr
        subst hr
        exact hperm.nodup_iff.mpr (hnd.erase n)
      · simp at hr
    · simp only [hl, ↓reduceIte] at hr
      exact inv.part_nodup l r hr

theorem indexInv_drop (names : P → List N) (s : LState L N P) (inv : IndexInv names s) (w : L) :
    IndexInv names { s with parts := fun l => if l = w then none else s.parts l, index := fun n => (s.index n).erase w } := by
  refine ⟨?_, ?_, ?_⟩
  · intro n l
    simp only
    by_cases hl : l = w
    · subst hl
      simp only [↓reduceIte, reduceCtorEq, false_and, exists_false, iff_false]
      rw [(inv.nodup n).mem_erase_iff]
      simp
    · simp only [hl, ↓reduceIte]
      rw [(inv.nodup n).mem_erase_iff]
      simp only [hl, ne_eq, not_false_eq_true, true_and]
      exact inv.mem n l
  · intro n
    exact (inv.nodup n).erase w
  · intro l p hp
    simp only at hp
    by_cases hl : l = w
    · simp [hl] at hp
    · simp only [hl, ↓reduceIte] at hp
      exact inv.part_nodup l p hp

theorem indexInv_step (ops : PartOps N V P) (names : P → List N) (laws : NameLaws ops names)
    (sees : L → L → Bool) (c : Cmd L N V) (s : LState L N P) (inv : IndexInv names s) :
    IndexInv names (wstep ops sees c s) := by
  unfold wstep
  cases hop : c.op with
  | add n v =>
    simp only
    by_cases hm : c.label ∈ s.index n
    · simp only [hm, ↓reduceIte]
      split
      · rename_i p hp
        exact indexInv_setPart names s inv _ p _ hp (laws.update p n v)
      · exact inv
    · simp only [hm, ↓reduceIte]
      split
      · exact inv
      · split
        · rename_i p hp
          exact indexInv_insert names s inv _ n _ hm (Or.inl ⟨p, hp, laws.insert p n v⟩)
        · rename_i hp
          have h := indexInv_insert names s inv c.label n
            (ops.insert (ops.create (ops.output (ops.advance (s.stream c.label)))) n v) hm
            (Or.inr ⟨hp, by
              have := laws.insert (ops.create (ops.output (ops.advance (s.stream c.label)))) n v
              rw [laws.create] at this
              simpa using this⟩)
          apply indexInv_congr names _ _ _ _ h
          · funext l; simp [setIndex, setPart, setStream]
          · funext m; simp [setIndex, setPart, setStream]
  | set n v =>
    simp only
    by_cases hm : c.label ∈ s.index n
    · simp only [hm, ↓reduceIte]
      split
      · rename_i p hp
        exact indexInv_setPart names s inv _ p _ hp (laws.setAttr p n v)
      · exact inv
    · simp only [hm, ↓reduceIte]
      exact inv
  | rem n =>
    simp only
    by_cases hm : c.label ∈ s.index n
    · simp only [hm, ↓reduceIte]
      split
      · rename_i p hp
        exact indexInv_remove names s inv _ n p _ hp (laws.remove p n) _ (fun h => (laws.empty _).mp h)
      · exact inv
    · simp only [hm, ↓reduceIte]
      exact inv
  | drop => exact indexInv_drop names s inv c.label
  | draw k =>
    exact indexInv_congr names s _ rfl rfl inv

theorem indexInv_run (ops : PartOps N V P) (names : P → List N) (laws : NameLaws ops names)
    (sees : L → L → Bool) : ∀ (cs : List (Cmd L N V)) (s : LState L N P), IndexInv names s →
      IndexInv names (wrun ops sees cs s) := by
  intro cs
  induction cs with
  | nil => intro s h; exact h
  | cons c cs ih => intro s h; exact ih _ (indexInv_step ops names laws sees c s h)

theorem two_le_length {α : Type} (l : List α) (a b : α) (ha : a ∈ l) (hb : b ∈ l) (hab : a ≠ b) : 2 ≤ l.length := by
  match l with
  | [] => simp at ha
  | [x] =>
    simp only [List.mem_singleton] at ha hb
    exact absurd (ha.trans hb.symm) hab
  | _ :: _ :: _ => simp

theorem view_labels_spec (acc : PartAcc N P) (le : L → L → Bool) (labelsU : List L) (namesU : List N)
    (r : ReaderOf L) (s : LState L N P) (hl : labelsU.Nodup) :
    (viewOpen acc le labelsU namesU r s).labels.Nodup ∧
      ∀ l, l ∈ (viewOpen acc le labelsU namesU r s).labels ↔ l ∈ labelsU ∧ inView r s l = true := by
  have hp := List.mergeSort_perm (labelsU.filter (inView r s)) le
  refine ⟨hp.nodup_iff.mpr (hl.sublist List.filter_sublist), ?_⟩
  intro l
  show l ∈ visibleLabels le labelsU r s ↔ _
  unfold visibleLabels
  rw [hp.mem_iff, List.mem_filter]

theorem unshadowed_unique (names : P → List N) (acc : PartAcc N P) (le : L → L → Bool) (labelsU : List L)
    (namesU : List N) (r : ReaderOf L) (s : LState L N P) (inv : IndexInv names s) (hl : labelsU.Nodup)
    (hn : ∀ n, 2 ≤ (s.index n).length → n ∈ namesU) (l₁ l₂ : L) (n : N)
    (h₁ : l₁ ∈ (viewOpen acc le labelsU namesU r s).labels) (h₂ : l₂ ∈ (viewOpen acc le labelsU namesU r s).labels)
    (m₁ : n ∈ unshadowed names s (viewOpen acc le labelsU namesU r s) l₁)
    (m₂ : n ∈ unshadowed names s (viewOpen acc le labelsU namesU r s) l₂) : l₁ = l₂ := by
  apply Classical.byContradiction
  intro hne
  have spec := view_labels_spec acc le labelsU namesU r s hl
  have v₁ := ((spec.2 l₁).mp h₁).2
  have v₂ := ((spec.2 l₂).mp h₂).2
  have inIdx : ∀ l, n ∈ unshadowed names s (viewOpen acc le labelsU namesU r s) l → l ∈ s.index n ∧
      (l, n) ∉ (viewOpen acc le labelsU namesU r s).shadows := by
    intro l hm
    unfold unshadowed at hm
    rw [List.mem_filter] at hm
    refine ⟨?_, by simpa using hm.2⟩
    unfold partNames at hm
    cases hp : s.parts l with
    | none => rw [hp] at hm; simp at hm
    | some p =>
      rw [hp] at hm
      exact (inv.mem n l).mpr ⟨p, hp, hm.1⟩
  have i₁ := inIdx l₁ m₁
  have i₂ := inIdx l₂ m₂
  have f₁ : l₁ ∈ (s.index n).filter (inView r s) := List.mem_filter.mpr ⟨i₁.1, v₁⟩
  have f₂ : l₂ ∈ (s.index n).filter (inView r s) := List.mem_filter.mpr ⟨i₂.1, v₂⟩
  have hv2 := two_le_length _ l₁ l₂ f₁ f₂ hne
  have hi2 : 2 ≤ (s.index n).length := Nat.le_trans hv2 (List.length_filter_le _ _)
  have hnU := hn n hi2
  have hsh : ∀ l, l ∈ (s.index n).filter (inView r s) → some l ≠ resolveL r (s.index n) →
      (l, n) ∈ (viewOpen acc le labelsU namesU r s).shadows := by
    intro l hl' hres
    show (l, n) ∈ namesU.flatMap (shadowsOf r s)
    rw [List.mem_flatMap]
    refine ⟨n, hnU, ?_⟩
    unfold shadowsOf
    simp only [hi2, hv2, ↓reduceIte]
    rw [List.mem_map]
    exact ⟨l, List.mem_filter.mpr ⟨hl', by simpa using hres⟩, rfl⟩
  by_cases hr : some l₁ = resolveL r (s.index n)
  · have : some l₂ ≠ resolveL r (s.index n) := by
      intro e; rw [← e] at hr; exact hne (Option.some.inj hr)
    exact i₂.2 (hsh l₂ f₂ this)
  · exact i₁.2 (hsh l₁ f₁ hr)

theorem view_names_unique (names : P → List N) (acc : PartAcc N P) (le : L → L → Bool) (labelsU : List L)
    (namesU : List N) (r : ReaderOf L) (s : LState L N P) (inv : IndexInv names s) (hl : labelsU.Nodup)
    (hn : ∀ n, 2 ≤ (s.index n).length → n ∈ namesU) :
    ((viewOpen acc le labelsU namesU r s).labels.flatMap
      (unshadowed names s (viewOpen acc le labelsU namesU r s))).Nodup := by
  have spec := view_labels_spec acc le labelsU namesU r s hl
  have huniq := unshadowed_unique names acc le labelsU namesU r s inv hl hn
  have hpart : ∀ l, (unshadowed names s (viewOpen acc le labelsU namesU r s) l).Nodup := by
    intro l
    unfold unshadowed partNames
    apply List.Nodup.sublist List.filter_sublist
    cases hp : s.parts l with
    | none => simp
    | some p => simpa using inv.part_nodup l p hp
  exact flatMap_nodup_of _ _ spec.1 hpart (fun l₁ h₁ l₂ h₂ n m₁ m₂ => huniq l₁ l₂ n h₁ h₂ m₁ m₂)

def viewHits {α : Type} (names : P → List N) (s : LState L N P) (vo : ViewObj L N) (hit : L → N → α)
    (keep : L → N → Bool) (l : L) : List α :=
  ((unshadowed names s vo l).filter (keep l)).map (hit l)

theorem nodup_of_map {α β : Type} (f : α → β) (l : List α) (h : (l.map f).Nodup) : l.Nodup := by
  rw [List.Nodup, List.pairwise_map] at h
  exact h.imp (fun hne e => hne (congrArg f e))

theorem view_merge_exact {α : Type} [DecidableEq α] {hle : α → α → Bool} (h : TotalLe hle) (k : Nat)
    (names : P → List N) (acc : PartAcc N P) (le : L → L → Bool) (labelsU : List L) (namesU : List N)
    (r : ReaderOf L) (s : LState L N P) (inv : IndexInv names s) (hl : labelsU.Nodup)
    (hn : ∀ n, 2 ≤ (s.index n).length → n ∈ namesU) (hit : L → N → α) (key : α → N)
    (hkey : ∀ l n, key (hit l n) = n) (keep : L → N → Bool) (vo : ViewObj L N)
    (hvo : vo = viewOpen acc le labelsU namesU r s) :
    mergeTop hle k (vo.labels.map (fun l => topk hle k (viewHits names s vo hit keep l))) =
      topk hle k (vo.labels.flatMap (viewHits names s vo hit keep)) := by
  have hu := view_names_unique names acc le labelsU namesU r s inv hl hn
  rw [← hvo] at hu
  have hmap : ∀ l, (viewHits names s vo hit keep l).map key = (unshadowed names s vo l).filter (keep l) := by
    intro l
    unfold viewHits
    rw [List.map_map]
    conv => rhs; rw [← List.map_id ((unshadowed names s vo l).filter (keep l))]
    apply List.map_congr_left
    intro n _
    exact hkey l n
  have hsubl : List.Sublist (vo.labels.flatMap (fun l => (unshadowed names s vo l).filter (keep l)))
      (vo.labels.flatMap (unshadowed names s vo)) := by
    generalize vo.labels = vl
    induction vl with
    | nil => simp
    | cons x xs ih =>
      rw [List.flatMap_cons, List.flatMap_cons]
      exact List.Sublist.append List.filter_sublist ih
  have hnd : (vo.labels.flatMap (viewHits names s vo hit keep)).Nodup := by
    apply nodup_of_map key
    have : (vo.labels.flatMap (viewHits names s vo hit keep)).map key =
        vo.labels.flatMap (fun l => (unshadowed names s vo l).filter (keep l)) := by
      rw [List.map_flatMap]
      congr 1
      funext l
      exact hmap l
    rw [this]
    exact hu.sublist hsubl
  have hflat : (vo.labels.map (viewHits names s vo hit keep)).flatten = vo.labels.flatMap (viewHits names s vo hit keep) := by
    rw [List.flatMap_def]
  have := merge_exact h k (vo.labels.map (viewHits names s vo hit keep)) (hflat ▸ hnd)
  rw [List.map_map] at this
  rw [← hflat]
  exact this

theorem topk_perm {α : Type} [DecidableEq α] {le : α → α → Bool} (h : TotalLe le) (k : Nat) {l₁ l₂ : List α}
    (hp : l₁.Perm l₂) (hn : l₁.Nodup) : topk le k l₁ = topk le k l₂ := by
  have hn₂ : l₂.Nodup := hp.nodup_iff.mp hn
  apply sorted_eq_of_mem h (topk_sorted h k _) (topk_sorted h k _) (topk_nodup k _ hn) (topk_nodup k _ hn₂)
  intro x
  rw [topk_mem h k _ hn, topk_mem h k _ hn₂, hp.mem_iff]
  unfold rankIn
  rw [hp.countP_eq]

theorem merge_order_free {α : Type} [DecidableEq α] {le : α → α → Bool} (h : TotalLe le) (k : Nat)
    {ps₁ ps₂ : List (List α)} (hp : ps₁.Perm ps₂) (hn : ps₁.flatten.Nodup) :
    mergeTop le k (ps₁.map (topk le k)) = mergeTop le k (ps₂.map (topk le k)) := by
  have hpf : ps₁.flatten.Perm ps₂.flatten := hp.flatten
  rw [merge_exact h k ps₁ hn, merge_exact h k ps₂ (hpf.nodup_iff.mp hn)]
  exact topk_perm h k hpf hn

theorem owner_view_scopes (sees gt : L → L → Bool) (acc : PartAcc N P) (le : L × Nat → L × Nat → Bool)
    (labelsU : List (L × Nat)) (namesU : List N) (w : L × Nat) (s : LState (L × Nat) N P) (hl : labelsU.Nodup)
    (x : L × Nat) :
    x ∈ (viewOpen acc le labelsU namesU (readerP sees gt w) s).labels ↔
      x ∈ labelsU ∧ (s.parts x).isSome = true ∧ sees w.1 x.1 = true ∧ (x.2 = SHARED ∨ x.2 = w.2) := by
  rw [(view_labels_spec acc le labelsU namesU (readerP sees gt w) s hl).2 x]
  simp only [inView, present, readerP, Bool.and_eq_true]
  rw [seesP_iff]

theorem owner_merge_exact {α : Type} [DecidableEq α] {hle : α → α → Bool} (h : TotalLe hle) (k : Nat)
    (sees gt : L → L → Bool) (names : P → List N) (acc : PartAcc N P) (le : L × Nat → L × Nat → Bool)
    (labelsU : List (L × Nat)) (namesU : List N) (w : L × Nat) (s : LState (L × Nat) N P)
    (inv : IndexInv names s) (hl : labelsU.Nodup) (hn : ∀ n, 2 ≤ (s.index n).length → n ∈ namesU)
    (hit : L × Nat → N → α) (key : α → N) (hkey : ∀ l n, key (hit l n) = n) (keep : L × Nat → N → Bool)
    (vo : ViewObj (L × Nat) N) (hvo : vo = viewOpen acc le labelsU namesU (readerP sees gt w) s) :
    (∀ x ∈ vo.labels, x.2 = SHARED ∨ x.2 = w.2) ∧
    mergeTop hle k (vo.labels.map (fun l => topk hle k (viewHits names s vo hit keep l))) =
      topk hle k (vo.labels.flatMap (viewHits names s vo hit keep)) := by
  refine ⟨?_, view_merge_exact h k names acc le labelsU namesU (readerP sees gt w) s inv hl hn hit key hkey keep vo hvo⟩
  intro x hx
  rw [hvo, owner_view_scopes sees gt acc le labelsU namesU w s hl x] at hx
  exact hx.2.2.2

theorem reachable_view_unique (ops : PartOps N V P) (names : P → List N) (laws : NameLaws ops names)
    (sees : L → L → Bool) (cs : List (Cmd L N V)) (st : L → Nat) (acc : PartAcc N P) (le : L → L → Bool)
    (labelsU : List L) (namesU : List N) (r : ReaderOf L) (hl : labelsU.Nodup)
    (hn : ∀ n, 2 ≤ ((wrun ops sees cs ⟨fun _ => none, fun _ => [], st⟩).index n).length → n ∈ namesU) :
    ((viewOpen acc le labelsU namesU r (wrun ops sees cs ⟨fun _ => none, fun _ => [], st⟩)).labels.flatMap
      (unshadowed names (wrun ops sees cs ⟨fun _ => none, fun _ => [], st⟩)
        (viewOpen acc le labelsU namesU r (wrun ops sees cs ⟨fun _ => none, fun _ => [], st⟩)))).Nodup :=
  view_names_unique names acc le labelsU namesU r _
    (indexInv_run ops names laws sees cs _ (indexInv_empty names st)) hl hn

end ViewNames

end Vectors
