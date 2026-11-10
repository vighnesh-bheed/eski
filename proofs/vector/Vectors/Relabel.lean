import Vectors.Partition

namespace Vectors

structure MoveOps (N V P : Type) where
  extract : P → N → V
  insertRaw : P → N → V → P

inductive MoveOutcome (L : Type) where
  | moved (fromGone toNew : Bool)
  | inUse (l : L)
  | notFound

section Relabel
set_option linter.unusedSectionVars false
variable {L N V P : Type} [DecidableEq L] [DecidableEq N]

def rawAdd (ops : PartOps N V P) (mops : MoveOps N V P) (s : LState L N P) (t : L) (n : N) (v : V) :
    LState L N P :=
  match s.parts t with
  | some q => setIndex (setPart s t (some (mops.insertRaw q n v))) n (s.index n ++ [t])
  | none =>
    let st := ops.advance (s.stream t)
    setIndex (setPart (setStream s t st) t (some (mops.insertRaw (ops.create (ops.output st)) n v))) n
      (s.index n ++ [t])

def relabelState (ops : PartOps N V P) (mops : MoveOps N V P) (sees : L → L → Bool) (src t : L) (n : N)
    (s : LState L N P) : LState L N P :=
  if src ∈ s.index n ∧ t ∉ s.index n then
    match s.parts src with
    | some p => wstep ops sees ⟨src, .rem n⟩ (rawAdd ops mops s t n (mops.extract p n))
    | none => s
  else s

def relabelOutcome (ops : PartOps N V P) (mops : MoveOps N V P) (sees : L → L → Bool) (gt : L → L → Bool)
    (src t : L) (n : N) (s : LState L N P) : MoveOutcome L :=
  let ls := s.index n
  if src ∉ ls then
    if visibleOther sees src ls then .inUse ((resolveL (writerOf sees gt src) ls).getD src) else .notFound
  else if t ∈ ls then .inUse t
  else
    let s' := relabelState ops mops sees src t n s
    .moved (s'.parts src).isNone (s.parts t).isNone

theorem erase_append_of_mem (a b : L) (ls : List L) (ha : a ∈ ls) : (ls ++ [b]).erase a = ls.erase a ++ [b] :=
  List.erase_append_left [b] ha

def rawBase (ops : PartOps N V P) (s : LState L N P) (t : L) : P :=
  match s.parts t with
  | some q => q
  | none => ops.create (ops.output (ops.advance (s.stream t)))

def rawStream (ops : PartOps N V P) (s : LState L N P) (t : L) : Nat :=
  match s.parts t with
  | some _ => s.stream t
  | none => ops.advance (s.stream t)

theorem rawAdd_parts (ops : PartOps N V P) (mops : MoveOps N V P) (s : LState L N P) (t : L) (n : N) (v : V)
    (l : L) : (rawAdd ops mops s t n v).parts l =
      if l = t then some (mops.insertRaw (rawBase ops s t) n v) else s.parts l := by
  unfold rawAdd rawBase
  cases s.parts t <;> simp [setIndex, setPart, setStream]

theorem rawAdd_index (ops : PartOps N V P) (mops : MoveOps N V P) (s : LState L N P) (t : L) (n : N) (v : V)
    (m : N) : (rawAdd ops mops s t n v).index m = if m = n then s.index n ++ [t] else s.index m := by
  unfold rawAdd
  cases s.parts t <;> simp [setIndex, setPart, setStream]

theorem rawAdd_stream (ops : PartOps N V P) (mops : MoveOps N V P) (s : LState L N P) (t : L) (n : N) (v : V)
    (l : L) : (rawAdd ops mops s t n v).stream l = if l = t then rawStream ops s t else s.stream l := by
  by_cases hl : l = t
  · subst hl
    unfold rawAdd rawStream
    cases s.parts l <;> simp [setIndex, setPart, setStream]
  · unfold rawAdd
    cases s.parts t <;> simp [setIndex, setPart, setStream, hl]

theorem remStep_parts (ops : PartOps N V P) (sees : L → L → Bool) (src : L) (n : N) (s : LState L N P) (p : P)
    (hs : src ∈ s.index n) (hp : s.parts src = some p) (l : L) :
    (wstep ops sees ⟨src, .rem n⟩ s).parts l =
      if l = src then (if ops.empty (ops.remove p n) then none else some (ops.remove p n)) else s.parts l := by
  simp only [wstep, hs, ↓reduceIte, hp]
  simp [setIndex, setPart]

theorem remStep_index (ops : PartOps N V P) (sees : L → L → Bool) (src : L) (n : N) (s : LState L N P) (p : P)
    (hs : src ∈ s.index n) (hp : s.parts src = some p) (m : N) :
    (wstep ops sees ⟨src, .rem n⟩ s).index m = if m = n then (s.index n).erase src else s.index m := by
  simp only [wstep, hs, ↓reduceIte, hp]
  simp [setIndex, setPart]

theorem remStep_stream (ops : PartOps N V P) (sees : L → L → Bool) (src : L) (n : N) (s : LState L N P) (p : P)
    (hs : src ∈ s.index n) (hp : s.parts src = some p) :
    (wstep ops sees ⟨src, .rem n⟩ s).stream = s.stream := by
  simp only [wstep, hs, ↓reduceIte, hp]
  simp [setIndex, setPart]

theorem relabel_as_remove_then_write (ops : PartOps N V P) (mops : MoveOps N V P) (sees : L → L → Bool)
    (src t : L) (n : N) (s : LState L N P) (hne : src ≠ t) (hs : src ∈ s.index n) (ht : t ∉ s.index n)
    (p : P) (hp : s.parts src = some p) :
    relabelState ops mops sees src t n s =
      rawAdd ops mops (wstep ops sees ⟨src, .rem n⟩ s) t n (mops.extract p n) := by
  have hts : t ≠ src := fun e => hne e.symm
  have hrel : relabelState ops mops sees src t n s = wstep ops sees ⟨src, .rem n⟩ (rawAdd ops mops s t n (mops.extract p n)) := by
    unfold relabelState
    simp only [hs, ht, not_false_eq_true, and_self, ↓reduceIte, hp]
  rw [hrel]
  generalize hv : mops.extract p n = v
  have hAs : (rawAdd ops mops s t n v).parts src = some p := by rw [rawAdd_parts]; simp [hne, hp]
  have hAi : src ∈ (rawAdd ops mops s t n v).index n := by
    rw [rawAdd_index]; simp only [↓reduceIte]; exact List.mem_append_left _ hs
  have hBt : (wstep ops sees ⟨src, .rem n⟩ s).parts t = s.parts t := by
    rw [remStep_parts ops sees src n s p hs hp]; simp [hts]
  have hBs := remStep_stream ops sees src n s p hs hp
  have hbase : rawBase ops (wstep ops sees ⟨src, .rem n⟩ s) t = rawBase ops s t := by
    unfold rawBase; rw [hBt, hBs]
  have hrs : rawStream ops (wstep ops sees ⟨src, .rem n⟩ s) t = rawStream ops s t := by
    unfold rawStream; rw [hBt, hBs]
  have hAp : ∀ l, (rawAdd ops mops s t n v).parts l = if l = t then some (mops.insertRaw (rawBase ops s t) n v) else s.parts l :=
    fun l => rawAdd_parts ops mops s t n v l
  have hAix : ∀ m, (rawAdd ops mops s t n v).index m = if m = n then s.index n ++ [t] else s.index m :=
    fun m => rawAdd_index ops mops s t n v m
  have hAst : ∀ l, (rawAdd ops mops s t n v).stream l = if l = t then rawStream ops s t else s.stream l :=
    fun l => rawAdd_stream ops mops s t n v l
  have hBp : ∀ l, (wstep ops sees ⟨src, .rem n⟩ s).parts l =
      if l = src then (if ops.empty (ops.remove p n) then none else some (ops.remove p n)) else s.parts l :=
    fun l => remStep_parts ops sees src n s p hs hp l
  have hBix : ∀ m, (wstep ops sees ⟨src, .rem n⟩ s).index m = if m = n then (s.index n).erase src else s.index m :=
    fun m => remStep_index ops sees src n s p hs hp m
  apply state_ext
  · funext l
    rw [remStep_parts ops sees src n _ p hAi hAs l, rawAdd_parts ops mops (wstep ops sees ⟨src, .rem n⟩ s) t n v l, hbase]
    by_cases h1 : l = src
    · subst h1; simp [hne, hBp]
    · by_cases h2 : l = t
      · subst h2; simp [h1, hAp]
      · simp [h1, h2, hAp, hBp]
  · funext m
    rw [remStep_index ops sees src n _ p hAi hAs m, rawAdd_index ops mops (wstep ops sees ⟨src, .rem n⟩ s) t n v m]
    by_cases hm : m = n
    · subst hm; simp [hAix, hBix, erase_append_of_mem src t _ hs]
    · simp [hm, hAix, hBix]
  · funext l
    rw [remStep_stream ops sees src n _ p hAi hAs, rawAdd_stream ops mops (wstep ops sees ⟨src, .rem n⟩ s) t n v l, hrs, hBs, hAst]

theorem relabel_age (ops : PartOps N V P) (mops : MoveOps N V P) (sees : L → L → Bool)
    (src t : L) (n : N) (s : LState L N P) (hne : src ≠ t) (hs : src ∈ s.index n) (ht : t ∉ s.index n)
    (p : P) (hp : s.parts src = some p) :
    (relabelState ops mops sees src t n s).index n = (s.index n).erase src ++ [t] := by
  rw [relabel_as_remove_then_write ops mops sees src t n s hne hs ht p hp, rawAdd_index,
    remStep_index ops sees src n s p hs hp]
  simp

theorem relabel_contents (ops : PartOps N V P) (mops : MoveOps N V P) (sees : L → L → Bool)
    (src t : L) (n : N) (s : LState L N P) (hne : src ≠ t) (hs : src ∈ s.index n) (ht : t ∉ s.index n)
    (p : P) (hp : s.parts src = some p) :
    (relabelState ops mops sees src t n s).parts t =
      some (mops.insertRaw (rawBase ops (wstep ops sees ⟨src, .rem n⟩ s) t) n (mops.extract p n)) := by
  rw [relabel_as_remove_then_write ops mops sees src t n s hne hs ht p hp, rawAdd_parts]
  simp

theorem relabel_is_write (ops : PartOps N V P) (mops : MoveOps N V P) (sees : L → L → Bool)
    (src t : L) (n : N) (s : LState L N P) (hne : src ≠ t) (hs : src ∈ s.index n) (ht : t ∉ s.index n)
    (p : P) (hp : s.parts src = some p) (v : V) (hlaw : ∀ q, mops.insertRaw q n (mops.extract p n) = ops.insert q n v)
    (hfree : visibleOther sees t ((s.index n).erase src) = false) :
    relabelState ops mops sees src t n s = wstep ops sees ⟨t, .add n v⟩ (wstep ops sees ⟨src, .rem n⟩ s) := by
  rw [relabel_as_remove_then_write ops mops sees src t n s hne hs ht p hp]
  have hix := remStep_index ops sees src n s p hs hp n
  simp only [↓reduceIte] at hix
  have htn : t ∉ (wstep ops sees ⟨src, .rem n⟩ s).index n := by
    rw [hix]; exact fun h => ht (List.mem_of_mem_erase h)
  have hvo : visibleOther sees t ((wstep ops sees ⟨src, .rem n⟩ s).index n) = false := by rw [hix]; exact hfree
  generalize wstep ops sees ⟨src, .rem n⟩ s = B at htn hvo
  unfold rawAdd
  simp only [wstep, htn, hvo, ↓reduceIte, Bool.false_eq_true]
  cases B.parts t <;> simp [hlaw]

theorem relabel_hidden (ops : PartOps N V P) (mops : MoveOps N V P) (sees : L → L → Bool) (gt : L → L → Bool)
    (R src t : L) (n : N) (s : LState L N P) (hsrc : sees R src = false) (ht : sees R t = false) :
    restrictTo sees gt R (relabelState ops mops sees src t n s) = restrictTo sees gt R s := by
  unfold relabelState
  split
  · split
    · rename_i p _
      have hrem := step_local ops sees gt R ⟨src, .rem n⟩ (rawAdd ops mops s t n (mops.extract p n)) hsrc
      rw [hrem]
      have hnt : ∀ l, sees R l = true → l ≠ t := fun l hl e => by rw [e, ht] at hl; exact absurd hl (by decide)
      have hwf : (writerOf sees gt R).vis t = false := ht
      unfold restrictTo
      apply restrict_eq_of
      · intro l hl
        rw [rawAdd_parts]
        simp [hnt l hl]
      · intro m
        rw [rawAdd_index]
        by_cases hm : m = n
        · subst hm; simp [List.filter_append, hwf]
        · simp [hm]
      · intro l hl
        rw [rawAdd_stream]
        simp [hnt l hl]
    · rfl
  · rfl

end Relabel

end Vectors
