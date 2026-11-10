import Vectors.Resolve

namespace Vectors

structure PartOps (N V P : Type) where
  create : Nat → P
  insert : P → N → V → P
  update : P → N → V → P
  setAttr : P → N → V → P
  remove : P → N → P
  empty : P → Bool
  advance : Nat → Nat
  output : Nat → Nat

inductive WOp (N V : Type) where
  | add (n : N) (v : V)
  | set (n : N) (v : V)
  | rem (n : N)
  | drop
  | draw (k : Nat)

structure Cmd (L N V : Type) where
  label : L
  op : WOp N V

section Steps
set_option linter.unusedSectionVars false
variable {L N V P : Type} [DecidableEq L] [DecidableEq N]

def writerOf (sees : L → L → Bool) (gt : L → L → Bool) (w : L) : ReaderOf L := ⟨w, sees w, gt⟩

def setPart (s : LState L N P) (w : L) (p : Option P) : LState L N P :=
  { s with parts := fun l => if l = w then p else s.parts l }

def setIndex (s : LState L N P) (n : N) (ls : List L) : LState L N P :=
  { s with index := fun m => if m = n then ls else s.index m }

def setStream (s : LState L N P) (w : L) (v : Nat) : LState L N P :=
  { s with stream := fun l => if l = w then v else s.stream l }

def visibleOther (sees : L → L → Bool) (w : L) (ls : List L) : Bool := ls.any (fun l => decide (l ≠ w) && sees w l)

def drawN (ops : PartOps N V P) : Nat → Nat → Nat
  | 0, x => x
  | k + 1, x => drawN ops k (ops.advance x)

def wstep (ops : PartOps N V P) (sees : L → L → Bool) (c : Cmd L N V) (s : LState L N P) : LState L N P :=
  let w := c.label
  match c.op with
  | .add n v =>
    let ls := s.index n
    if w ∈ ls then
      match s.parts w with
      | some p => setPart s w (some (ops.update p n v))
      | none => s
    else if visibleOther sees w ls then s
    else
      match s.parts w with
      | some p => setIndex (setPart s w (some (ops.insert p n v))) n (ls ++ [w])
      | none =>
        let st := ops.advance (s.stream w)
        setIndex (setPart (setStream s w st) w (some (ops.insert (ops.create (ops.output st)) n v))) n (ls ++ [w])
  | .set n v =>
    if w ∈ s.index n then
      match s.parts w with
      | some p => setPart s w (some (ops.setAttr p n v))
      | none => s
    else s
  | .rem n =>
    let ls := s.index n
    if w ∈ ls then
      match s.parts w with
      | some p =>
        let q := ops.remove p n
        setIndex (setPart s w (if ops.empty q then none else some q)) n (ls.erase w)
      | none => s
    else s
  | .drop => { s with parts := fun l => if l = w then none else s.parts l, index := fun n => (s.index n).erase w }
  | .draw k => setStream s w (drawN ops k (s.stream w))

def wrun (ops : PartOps N V P) (sees : L → L → Bool) : List (Cmd L N V) → LState L N P → LState L N P
  | [], s => s
  | c :: cs, s => wrun ops sees cs (wstep ops sees c s)

structure Sees (sees : L → L → Bool) : Prop where
  refl : ∀ a, sees a a = true
  trans : ∀ a b c, sees a b = true → sees b c = true → sees a c = true

def restrictTo (sees : L → L → Bool) (gt : L → L → Bool) (R : L) (s : LState L N P) : LState L N P :=
  restrict (writerOf sees gt R) s

theorem filter_erase_comm (p : L → Bool) (w : L) (hp : p w = true) :
    ∀ (ls : List L), (ls.erase w).filter p = (ls.filter p).erase w := by
  intro ls
  induction ls with
  | nil => rfl
  | cons x xs ih =>
    by_cases hx : x = w
    · subst hx
      simp [List.erase_cons_head, hp]
    · have hne : (x == w) = false := by simpa using hx
      rw [List.erase_cons_tail (by simpa using hne)]
      by_cases hpx : p x = true
      · rw [List.filter_cons_of_pos hpx, List.filter_cons_of_pos hpx, List.erase_cons_tail (by simpa using hne), ih]
      · rw [List.filter_cons_of_neg hpx, List.filter_cons_of_neg hpx, ih]

theorem filter_erase_hidden (p : L → Bool) (w : L) (hp : p w = false) :
    ∀ (ls : List L), (ls.erase w).filter p = ls.filter p := by
  intro ls
  induction ls with
  | nil => rfl
  | cons x xs ih =>
    by_cases hx : x = w
    · subst hx
      simp [List.erase_cons_head, hp]
    · have hne : (x == w) = false := by simpa using hx
      rw [List.erase_cons_tail (by simpa using hne)]
      by_cases hpx : p x = true
      · rw [List.filter_cons_of_pos hpx, List.filter_cons_of_pos hpx, ih]
      · rw [List.filter_cons_of_neg hpx, List.filter_cons_of_neg hpx, ih]

theorem state_ext (a b : LState L N P) (hp : a.parts = b.parts) (hi : a.index = b.index) (hs : a.stream = b.stream) :
    a = b := by
  cases a; cases b; simp_all

theorem restrict_eq_of (r : ReaderOf L) (a b : LState L N P)
    (hp : ∀ l, r.vis l = true → a.parts l = b.parts l)
    (hi : ∀ n, (a.index n).filter r.vis = (b.index n).filter r.vis)
    (hs : ∀ l, r.vis l = true → a.stream l = b.stream l) :
    restrict r a = restrict r b := by
  apply state_ext
  · funext l; simp only [restrict]; cases h : r.vis l <;> simp [hp l, h]
  · funext n; exact hi n
  · funext l; simp only [restrict]; cases h : r.vis l <;> simp [hs l, h]

theorem step_local (ops : PartOps N V P) (sees : L → L → Bool) (gt : L → L → Bool)
    (R : L) (c : Cmd L N V) (s : LState L N P) (hid : sees R c.label = false) :
    restrictTo sees gt R (wstep ops sees c s) = restrictTo sees gt R s := by
  have hne : ∀ l, sees R l = true → l ≠ c.label := fun l hl e => by rw [e, hid] at hl; exact absurd hl (by decide)
  unfold restrictTo
  apply restrict_eq_of
  · intro l hl
    have hlw := hne l hl
    unfold wstep
    cases c.op with
    | add n v =>
      simp only
      split
      · split <;> simp [setPart, hlw]
      · split
        · rfl
        · split <;> simp [setPart, setIndex, setStream, hlw]
    | set n v => simp only; split <;> (try split) <;> simp [setPart, hlw]
    | rem n => simp only; split <;> (try split) <;> simp [setPart, setIndex, hlw]
    | drop => simp [hlw]
    | draw k => simp [setStream]
  · intro n
    have hwf : (writerOf sees gt R).vis c.label = false := hid
    unfold wstep
    cases c.op with
    | add m v =>
      simp only
      split
      · split <;> simp [setPart]
      · split
        · rfl
        · split <;>
          · simp only [setIndex, setPart, setStream]
            by_cases hm : n = m
            · subst hm; simp [List.filter_append, hwf]
            · simp [hm]
    | set m v => simp only; split <;> (try split) <;> simp [setPart]
    | rem m =>
      simp only
      split
      · split
        · simp only [setIndex, setPart]
          by_cases hm : n = m
          · subst hm; simp only [↓reduceIte]; exact filter_erase_hidden _ _ hwf _
          · simp [hm]
        · rfl
      · rfl
    | drop => exact filter_erase_hidden _ _ hwf _
    | draw k => rfl
  · intro l hl
    have hlw := hne l hl
    unfold wstep
    cases c.op with
    | add n v =>
      simp only
      split
      · split <;> simp [setPart]
      · split
        · rfl
        · split <;> simp [setPart, setIndex, setStream, hlw]
    | set n v => simp only; split <;> (try split) <;> simp [setPart]
    | rem n => simp only; split <;> (try split) <;> simp [setPart, setIndex]
    | drop => rfl
    | draw k => simp [setStream, hlw]

theorem restrict_idem (r : ReaderOf L) (s : LState L N P) : restrict r (restrict r s) = restrict r s := by
  apply restrict_eq_of
  · intro l hl; simp [restrict, hl]
  · intro n; simp only [restrict]; rw [List.filter_filter]; apply List.filter_congr; intro l _; cases r.vis l <;> rfl
  · intro l hl; simp [restrict, hl]

theorem restrict_setPart (r : ReaderOf L) (a b : LState L N P) (w : L) (p : Option P)
    (h : restrict r a = restrict r b) : restrict r (setPart a w p) = restrict r (setPart b w p) := by
  have hp : ∀ l, r.vis l = true → a.parts l = b.parts l := by
    intro l hl
    have := congrArg (fun s => s.parts l) h
    simpa [restrict, hl] using this
  have hi : ∀ n, (a.index n).filter r.vis = (b.index n).filter r.vis := fun n => congrArg (fun s => s.index n) h
  have hs : ∀ l, r.vis l = true → a.stream l = b.stream l := by
    intro l hl
    have := congrArg (fun s => s.stream l) h
    simpa [restrict, hl] using this
  apply restrict_eq_of
  · intro l hl; simp only [setPart]; split <;> simp_all
  · intro n; exact hi n
  · intro l hl; exact hs l hl

theorem restrict_parts_eq (r : ReaderOf L) (a b : LState L N P) (h : restrict r a = restrict r b) (l : L)
    (hl : r.vis l = true) : a.parts l = b.parts l := by
  have := congrArg (fun s => s.parts l) h
  simpa [restrict, hl] using this

theorem restrict_index_eq (r : ReaderOf L) (a b : LState L N P) (h : restrict r a = restrict r b) (n : N) :
    (a.index n).filter r.vis = (b.index n).filter r.vis := congrArg (fun s => s.index n) h

theorem restrict_stream_eq (r : ReaderOf L) (a b : LState L N P) (h : restrict r a = restrict r b) (l : L)
    (hl : r.vis l = true) : a.stream l = b.stream l := by
  have := congrArg (fun s => s.stream l) h
  simpa [restrict, hl] using this

theorem restrict_setIndex (r : ReaderOf L) (a b : LState L N P) (n : N) (la lb : List L)
    (h : restrict r a = restrict r b) (hl : la.filter r.vis = lb.filter r.vis) :
    restrict r (setIndex a n la) = restrict r (setIndex b n lb) := by
  apply restrict_eq_of
  · intro l hv; exact restrict_parts_eq r a b h l hv
  · intro m; simp only [setIndex]; split
    · exact hl
    · exact restrict_index_eq r a b h m
  · intro l hv; exact restrict_stream_eq r a b h l hv

theorem restrict_setStream (r : ReaderOf L) (a b : LState L N P) (w : L) (v : Nat)
    (h : restrict r a = restrict r b) : restrict r (setStream a w v) = restrict r (setStream b w v) := by
  apply restrict_eq_of
  · intro l hv; exact restrict_parts_eq r a b h l hv
  · intro m; exact restrict_index_eq r a b h m
  · intro l hv; simp only [setStream]; split
    · rfl
    · exact restrict_stream_eq r a b h l hv

theorem visibleOther_restrict (sees : L → L → Bool) (hs : Sees sees) (R w : L) (hw : sees R w = true)
    (ls : List L) : visibleOther sees w (ls.filter (sees R)) = visibleOther sees w ls := by
  unfold visibleOther
  apply Bool.eq_iff_iff.mpr
  simp only [List.any_eq_true, List.mem_filter, Bool.and_eq_true, decide_eq_true_eq]
  constructor
  · intro ⟨l, ⟨hl, _⟩, h⟩; exact ⟨l, hl, h⟩
  · intro ⟨l, hl, h⟩; exact ⟨l, ⟨hl, hs.trans R w l hw h.2⟩, h⟩

theorem step_consistent (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (R : L) (c : Cmd L N V) (s : LState L N P) (hvis : sees R c.label = true) :
    restrictTo sees gt R (wstep ops sees c (restrictTo sees gt R s)) = restrictTo sees gt R (wstep ops sees c s) := by
  unfold restrictTo
  generalize hr : writerOf sees gt R = r
  have hrv : r.vis = sees R := by rw [← hr]; rfl
  generalize hw : c.label = w
  have hwv : r.vis w = true := by rw [hrv, ← hw]; exact hvis
  have hidem := restrict_idem r s
  have hpw : (restrict r s).parts w = s.parts w := by simp [restrict, hwv]
  have hsw : (restrict r s).stream w = s.stream w := by simp [restrict, hwv]
  have hix : ∀ n, (restrict r s).index n = (s.index n).filter r.vis := fun n => rfl
  have hmem : ∀ n, (w ∈ (restrict r s).index n) ↔ (w ∈ s.index n) := by
    intro n; rw [hix, List.mem_filter]; simp [hwv]
  have hvo : ∀ n, visibleOther sees w ((restrict r s).index n) = visibleOther sees w (s.index n) := by
    intro n; rw [hix, hrv]; exact visibleOther_restrict sees hs R w (hw ▸ hvis) _
  have hfl : ∀ (ls : List L), (ls.filter r.vis ++ [w]).filter r.vis = (ls ++ [w]).filter r.vis := by
    intro ls; rw [List.filter_append, List.filter_append, List.filter_filter]; congr 1
    apply List.filter_congr; intro l _; cases r.vis l <;> rfl
  unfold wstep
  rw [hw]
  cases c.op with
  | add n v =>
    simp only
    by_cases hm : w ∈ s.index n
    · have hm' : w ∈ (restrict r s).index n := (hmem n).mpr hm
      simp only [hm, hm', ↓reduceIte, hpw]
      split
      · exact restrict_setPart r _ _ w _ hidem
      · exact hidem
    · have hm' : w ∉ (restrict r s).index n := fun e => hm ((hmem n).mp e)
      simp only [hm, hm', ↓reduceIte, hvo n]
      split
      · exact hidem
      · rw [hpw]
        split
        · apply restrict_setIndex
          · exact restrict_setPart r _ _ w _ hidem
          · rw [hix]; exact hfl _
        · rw [hsw]
          apply restrict_setIndex
          · exact restrict_setPart r _ _ w _ (restrict_setStream r _ _ w _ hidem)
          · rw [hix]; exact hfl _
  | set n v =>
    simp only
    by_cases hm : w ∈ s.index n
    · have hm' : w ∈ (restrict r s).index n := (hmem n).mpr hm
      simp only [hm, hm', ↓reduceIte, hpw]
      split
      · exact restrict_setPart r _ _ w _ hidem
      · exact hidem
    · have hm' : w ∉ (restrict r s).index n := fun e => hm ((hmem n).mp e)
      simp only [hm, hm', ↓reduceIte]
      exact hidem
  | rem n =>
    simp only
    by_cases hm : w ∈ s.index n
    · have hm' : w ∈ (restrict r s).index n := (hmem n).mpr hm
      simp only [hm, hm', ↓reduceIte, hpw]
      split
      · apply restrict_setIndex
        · exact restrict_setPart r _ _ w _ hidem
        · rw [hix, filter_erase_comm _ w hwv, filter_erase_comm _ w hwv, List.filter_filter]
          congr 1
          apply List.filter_congr; intro l _; cases r.vis l <;> rfl
      · exact hidem
    · have hm' : w ∉ (restrict r s).index n := fun e => hm ((hmem n).mp e)
      simp only [hm, hm', ↓reduceIte]
      exact hidem
  | drop =>
    apply restrict_eq_of
    · intro l hl
      simp only
      split
      · rfl
      · exact restrict_parts_eq r _ _ hidem l hl
    · intro n
      simp only
      rw [filter_erase_comm _ w hwv, filter_erase_comm _ w hwv]
      rw [restrict_index_eq r _ _ hidem n]
    · intro l hl; exact restrict_stream_eq r _ _ hidem l hl
  | draw k =>
    simp only
    rw [hsw]
    exact restrict_setStream r _ _ w _ hidem

theorem run_congr (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (R : L) :
    ∀ (cs : List (Cmd L N V)) (a b : LState L N P), restrictTo sees gt R a = restrictTo sees gt R b →
      restrictTo sees gt R (wrun ops sees cs a) = restrictTo sees gt R (wrun ops sees cs b) := by
  intro cs
  induction cs with
  | nil => intro a b h; exact h
  | cons c cs ih =>
    intro a b h
    apply ih
    by_cases hv : sees R c.label = true
    · rw [← step_consistent ops sees hs gt R c a hv, ← step_consistent ops sees hs gt R c b hv]
      unfold restrictTo at h ⊢
      rw [h]
    · have hf : sees R c.label = false := by simpa using hv
      rw [step_local ops sees gt R c a hf, step_local ops sees gt R c b hf]
      exact h

def purge (sees : L → L → Bool) (R : L) (cs : List (Cmd L N V)) : List (Cmd L N V) :=
  cs.filter (fun c => sees R c.label)

theorem run_purge (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (R : L) :
    ∀ (cs : List (Cmd L N V)) (s : LState L N P),
      restrictTo sees gt R (wrun ops sees cs s) = restrictTo sees gt R (wrun ops sees (purge sees R cs) s) := by
  intro cs
  induction cs with
  | nil => intro s; rfl
  | cons c cs ih =>
    intro s
    by_cases hv : sees R c.label = true
    · simp only [purge, List.filter_cons, hv, ↓reduceIte, wrun]
      exact ih _
    · have hf : sees R c.label = false := by simpa using hv
      simp only [purge, List.filter_cons, hf, Bool.false_eq_true, ↓reduceIte, wrun]
      rw [run_congr ops sees hs gt R cs _ _ (step_local ops sees gt R c s hf)]
      exact ih s

theorem partition_history (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (L₀ : L) (cs : List (Cmd L N V)) (s : LState L N P) :
    (wrun ops sees cs s).parts L₀ = (wrun ops sees (purge sees L₀ cs) s).parts L₀ ∧
    (wrun ops sees cs s).stream L₀ = (wrun ops sees (purge sees L₀ cs) s).stream L₀ := by
  have h := run_purge ops sees hs gt L₀ cs s
  have hv : (writerOf sees gt L₀).vis L₀ = true := hs.refl L₀
  unfold restrictTo at h
  exact ⟨restrict_parts_eq _ _ _ h L₀ hv, restrict_stream_eq _ _ _ h L₀ hv⟩

theorem hidden_write_view (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (acc : PartAcc N P) (le : L → L → Bool) (labelsU : List L) (namesU : List N)
    (R : L) (c : Cmd L N V) (s : LState L N P) (hid : sees R c.label = false) :
    viewOpen acc le labelsU namesU (writerOf sees gt R) (wstep ops sees c s) =
      viewOpen acc le labelsU namesU (writerOf sees gt R) s := by
  have hown : (writerOf sees gt R).vis R = true := hs.refl R
  rw [← viewOpen_restrict acc le labelsU namesU _ hown (wstep ops sees c s),
    ← viewOpen_restrict acc le labelsU namesU _ hown s]
  have := step_local ops sees gt R c s hid
  unfold restrictTo at this
  rw [this]

theorem hidden_write_find (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (R : L) (c : Cmd L N V) (s : LState L N P) (hid : sees R c.label = false) (n : N) :
    viewFind (writerOf sees gt R) (wstep ops sees c s) n = viewFind (writerOf sees gt R) s n := by
  have hown : (writerOf sees gt R).vis R = true := hs.refl R
  rw [← viewFind_restrict _ hown (wstep ops sees c s), ← viewFind_restrict _ hown s]
  have := step_local ops sees gt R c s hid
  unfold restrictTo at this
  rw [this]

theorem hidden_write_range (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (R : L) (c : Cmd L N V) (s : LState L N P) (hid : sees R c.label = false) (namesU : List N)
    (inRange : N → Bool) (limit : Option Nat) :
    viewRange (writerOf sees gt R) (wstep ops sees c s) namesU inRange limit =
      viewRange (writerOf sees gt R) s namesU inRange limit := by
  have hown : (writerOf sees gt R).vis R = true := hs.refl R
  rw [← viewRange_restrict _ hown (wstep ops sees c s), ← viewRange_restrict _ hown s]
  have := step_local ops sees gt R c s hid
  unfold restrictTo at this
  rw [this]

theorem hidden_history_view (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (acc : PartAcc N P) (le : L → L → Bool) (labelsU : List L) (namesU : List N)
    (R : L) (cs : List (Cmd L N V)) (s : LState L N P) :
    viewOpen acc le labelsU namesU (writerOf sees gt R) (wrun ops sees cs s) =
      viewOpen acc le labelsU namesU (writerOf sees gt R) (wrun ops sees (purge sees R cs) s) := by
  have hown : (writerOf sees gt R).vis R = true := hs.refl R
  rw [← viewOpen_restrict acc le labelsU namesU _ hown (wrun ops sees cs s),
    ← viewOpen_restrict acc le labelsU namesU _ hown (wrun ops sees (purge sees R cs) s)]
  have := run_purge ops sees hs gt R cs s
  unfold restrictTo at this
  rw [this]

def viewMemory (acc : PartAcc N P) (bytes : P → Nat) (base : Nat) (le : L → L → Bool) (labelsU : List L)
    (namesU : List N) (r : ReaderOf L) (s : LState L N P) : Nat :=
  if (viewOpen acc le labelsU namesU r s).size = 0 then 0
  else base + ((viewOpen acc le labelsU namesU r s).labels.map (fun l => ((s.parts l).map bytes).getD 0)).sum

theorem viewMemory_restrict (acc : PartAcc N P) (bytes : P → Nat) (base : Nat) (le : L → L → Bool)
    (labelsU : List L) (namesU : List N) (r : ReaderOf L) (hown : r.vis r.own = true) (s : LState L N P) :
    viewMemory acc bytes base le labelsU namesU r (restrict r s) = viewMemory acc bytes base le labelsU namesU r s := by
  unfold viewMemory
  rw [viewOpen_restrict acc le labelsU namesU r hown s]
  have h : (viewOpen acc le labelsU namesU r s).labels.map (fun l => (((restrict r s).parts l).map bytes).getD 0) =
      (viewOpen acc le labelsU namesU r s).labels.map (fun l => ((s.parts l).map bytes).getD 0) := by
    apply List.map_congr_left
    intro l hl
    rw [restrict_parts_view r s l (visibleLabels_vis le labelsU r s l hl)]
  rw [h]

theorem hidden_history_memory (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (acc : PartAcc N P) (bytes : P → Nat) (base : Nat) (le : L → L → Bool) (labelsU : List L) (namesU : List N)
    (R : L) (cs : List (Cmd L N V)) (s : LState L N P) :
    viewMemory acc bytes base le labelsU namesU (writerOf sees gt R) (wrun ops sees cs s) =
      viewMemory acc bytes base le labelsU namesU (writerOf sees gt R) (wrun ops sees (purge sees R cs) s) := by
  have hown : (writerOf sees gt R).vis R = true := hs.refl R
  rw [← viewMemory_restrict acc bytes base le labelsU namesU _ hown (wrun ops sees cs s),
    ← viewMemory_restrict acc bytes base le labelsU namesU _ hown (wrun ops sees (purge sees R cs) s)]
  have := run_purge ops sees hs gt R cs s
  unfold restrictTo at this
  rw [this]

end Steps

inductive PMode where
  | pinned
  | flat
  | graph
deriving DecidableEq, Repr, Inhabited

def modeAfterInsert (flatLimit : Nat) (m : PMode) (count : Nat) : PMode :=
  match m with
  | .flat => if flatLimit < count then .graph else .flat
  | x => x

def modeAfterRemove (shrinkLimit : Nat) (m : PMode) (count : Nat) : PMode :=
  match m with
  | .graph => if count ≤ shrinkLimit then .flat else .graph
  | x => x

theorem pinned_insert (f c : Nat) : modeAfterInsert f .pinned c = .pinned := rfl

theorem pinned_remove (s c : Nat) : modeAfterRemove s .pinned c = .pinned := rfl

theorem mode_insert_not_pinned (f c : Nat) (m : PMode) (h : m ≠ .pinned) : modeAfterInsert f m c ≠ .pinned := by
  cases m <;> simp [modeAfterInsert] at h ⊢ <;> split <;> simp

theorem mode_remove_not_pinned (s c : Nat) (m : PMode) (h : m ≠ .pinned) : modeAfterRemove s m c ≠ .pinned := by
  cases m <;> simp [modeAfterRemove] at h ⊢ <;> split <;> simp

def modeRun (f s : Nat) : PMode → List (Bool × Nat) → PMode
  | m, [] => m
  | m, (ins, c) :: rest => modeRun f s (if ins then modeAfterInsert f m c else modeAfterRemove s m c) rest

theorem pinned_forever (f s : Nat) : ∀ (ops : List (Bool × Nat)), modeRun f s .pinned ops = .pinned := by
  intro ops
  induction ops with
  | nil => rfl
  | cons o rest ih => cases o with | mk ins c => cases ins <;> exact ih

theorem graduate_threshold (f c : Nat) : modeAfterInsert f .flat c = .graph ↔ f < c := by
  simp only [modeAfterInsert]
  split <;> simp_all

theorem flatten_threshold (s c : Nat) : modeAfterRemove s .graph c = .flat ↔ c ≤ s := by
  simp only [modeAfterRemove]
  split <;> simp_all

theorem hysteresis_gap (f s c c' : Nat) (hfs : s < f) (hup : modeAfterInsert f .flat c = .graph)
    (hdown : modeAfterRemove s .graph c' = .flat) : c' + (f - s) < c + 1 := by
  rw [graduate_threshold] at hup
  rw [flatten_threshold] at hdown
  omega

def footprintCore (fixed ledger objectBytes : Nat) : Nat := fixed + (ledger - objectBytes)

def footprintBlock (fixed charge : Nat) : Nat := fixed + charge

theorem convert_footprint (fixed ledger objectBytes blocks : Nat) (hledger : ledger = objectBytes + blocks) :
    footprintCore fixed ledger objectBytes = footprintBlock fixed blocks := by
  unfold footprintCore footprintBlock
  omega

end Vectors
