import Vectors.Owner

set_option autoImplicit false

namespace Vectors

section OwnerSteps
set_option linter.unusedSectionVars false
variable {L N V P : Type} [DecidableEq L] [DecidableEq N]

theorem owner_step_local (ops : PartOps N V P) (sees gt : L → L → Bool) (R : L × Nat)
    (c : Cmd (L × Nat) N V) (s : LState (L × Nat) N P)
    (hid : sees R.1 c.label.1 = false ∨ (c.label.2 ≠ SHARED ∧ c.label.2 ≠ R.2)) :
    restrictTo (seesP sees) (gtP gt) R (wstep ops (seesP sees) c s) = restrictTo (seesP sees) (gtP gt) R s :=
  step_local ops (seesP sees) (gtP gt) R c s ((seesP_hidden sees R c.label).mpr hid)

theorem other_owner_step (ops : PartOps N V P) (sees gt : L → L → Bool) (R : L × Nat)
    (c : Cmd (L × Nat) N V) (s : LState (L × Nat) N P) (h1 : c.label.2 ≠ SHARED) (h2 : c.label.2 ≠ R.2) :
    restrictTo (seesP sees) (gtP gt) R (wstep ops (seesP sees) c s) = restrictTo (seesP sees) (gtP gt) R s :=
  owner_step_local ops sees gt R c s (Or.inr ⟨h1, h2⟩)

theorem owner_step_consistent (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (R : L × Nat) (c : Cmd (L × Nat) N V) (s : LState (L × Nat) N P) (hvis : seesP sees R c.label = true) :
    restrictTo (seesP sees) (gtP gt) R (wstep ops (seesP sees) c (restrictTo (seesP sees) (gtP gt) R s)) =
      restrictTo (seesP sees) (gtP gt) R (wstep ops (seesP sees) c s) :=
  step_consistent ops (seesP sees) (seesP_sees sees hs) (gtP gt) R c s hvis

theorem owner_run_purge (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (R : L × Nat) (cs : List (Cmd (L × Nat) N V)) (s : LState (L × Nat) N P) :
    restrictTo (seesP sees) (gtP gt) R (wrun ops (seesP sees) cs s) =
      restrictTo (seesP sees) (gtP gt) R (wrun ops (seesP sees) (purge (seesP sees) R cs) s) :=
  run_purge ops (seesP sees) (seesP_sees sees hs) (gtP gt) R cs s

theorem purge_keeps (sees : L → L → Bool) (R : L × Nat) (cs : List (Cmd (L × Nat) N V)) (c : Cmd (L × Nat) N V) :
    c ∈ purge (seesP sees) R cs ↔ c ∈ cs ∧ sees R.1 c.label.1 = true ∧ (c.label.2 = SHARED ∨ c.label.2 = R.2) := by
  unfold purge
  rw [List.mem_filter, seesP_iff]

theorem run_filter_hidden (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (R : L)
    (keep : Cmd L N V → Bool) (cs : List (Cmd L N V)) (s : LState L N P)
    (hk : ∀ c ∈ cs, keep c = false → sees R c.label = false) :
    restrictTo sees gt R (wrun ops sees cs s) = restrictTo sees gt R (wrun ops sees (cs.filter keep) s) := by
  rw [run_purge ops sees hs gt R cs s, run_purge ops sees hs gt R (cs.filter keep) s]
  congr 2
  unfold purge
  rw [List.filter_filter]
  apply List.filter_congr
  intro c hc
  cases hv : sees R c.label
  · simp
  · cases hkc : keep c
    · rw [hk c hc hkc] at hv; exact absurd hv (by decide)
    · rfl

theorem owner_isolation (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (u v : Nat) (hv : v ≠ SHARED) (huv : u ≠ v) (r : L) (cs : List (Cmd (L × Nat) N V)) (s : LState (L × Nat) N P) :
    restrictTo (seesP sees) (gtP gt) (r, u) (wrun ops (seesP sees) cs s) =
      restrictTo (seesP sees) (gtP gt) (r, u) (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 != v)) s) := by
  apply run_filter_hidden ops (seesP sees) (seesP_sees sees hs) (gtP gt)
  intro c _ hk
  have he : c.label.2 = v := by simpa using hk
  rw [seesP_hidden]
  right
  exact ⟨he ▸ hv, fun e => huv (e.symm.trans he)⟩

theorem shared_isolation (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (r : L) (cs : List (Cmd (L × Nat) N V)) (s : LState (L × Nat) N P) :
    restrictTo (seesP sees) (gtP gt) (r, SHARED) (wrun ops (seesP sees) cs s) =
      restrictTo (seesP sees) (gtP gt) (r, SHARED) (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 == SHARED)) s) := by
  apply run_filter_hidden ops (seesP sees) (seesP_sees sees hs) (gtP gt)
  intro c _ hk
  have he : c.label.2 ≠ SHARED := by simpa using hk
  rw [seesP_hidden]
  exact Or.inr ⟨he, he⟩

theorem owner_isolation_view (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (acc : PartAcc N P) (le : L × Nat → L × Nat → Bool) (labelsU : List (L × Nat)) (namesU : List N)
    (u v : Nat) (hv : v ≠ SHARED) (huv : u ≠ v) (r : L) (cs : List (Cmd (L × Nat) N V)) (s : LState (L × Nat) N P) :
    viewOpen acc le labelsU namesU (readerP sees gt (r, u)) (wrun ops (seesP sees) cs s) =
      viewOpen acc le labelsU namesU (readerP sees gt (r, u))
        (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 != v)) s) := by
  rw [← owner_viewOpen_restrict sees hs gt acc le labelsU namesU (r, u) (wrun ops (seesP sees) cs s),
    ← owner_viewOpen_restrict sees hs gt acc le labelsU namesU (r, u)
      (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 != v)) s)]
  have := owner_isolation ops sees hs gt u v hv huv r cs s
  unfold restrictTo at this
  have h : restrict (readerP sees gt (r, u)) (wrun ops (seesP sees) cs s) =
      restrict (readerP sees gt (r, u)) (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 != v)) s) := this
  rw [h]

theorem owner_isolation_find (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (u v : Nat) (hv : v ≠ SHARED) (huv : u ≠ v) (r : L) (cs : List (Cmd (L × Nat) N V)) (s : LState (L × Nat) N P)
    (n : N) :
    viewFind (readerP sees gt (r, u)) (wrun ops (seesP sees) cs s) n =
      viewFind (readerP sees gt (r, u)) (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 != v)) s) n := by
  rw [← owner_viewFind_restrict sees hs gt (r, u) (wrun ops (seesP sees) cs s) n,
    ← owner_viewFind_restrict sees hs gt (r, u) (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 != v)) s) n]
  have := owner_isolation ops sees hs gt u v hv huv r cs s
  unfold restrictTo at this
  have h : restrict (readerP sees gt (r, u)) (wrun ops (seesP sees) cs s) =
      restrict (readerP sees gt (r, u)) (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 != v)) s) := this
  rw [h]

theorem owner_isolation_range (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (u v : Nat) (hv : v ≠ SHARED) (huv : u ≠ v) (r : L) (cs : List (Cmd (L × Nat) N V)) (s : LState (L × Nat) N P)
    (namesU : List N) (inRange : N → Bool) (limit : Option Nat) :
    viewRange (readerP sees gt (r, u)) (wrun ops (seesP sees) cs s) namesU inRange limit =
      viewRange (readerP sees gt (r, u)) (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 != v)) s)
        namesU inRange limit := by
  rw [← owner_viewRange_restrict sees hs gt (r, u) (wrun ops (seesP sees) cs s),
    ← owner_viewRange_restrict sees hs gt (r, u) (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 != v)) s)]
  have := owner_isolation ops sees hs gt u v hv huv r cs s
  unfold restrictTo at this
  have h : restrict (readerP sees gt (r, u)) (wrun ops (seesP sees) cs s) =
      restrict (readerP sees gt (r, u)) (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 != v)) s) := this
  rw [h]

theorem owner_isolation_stream (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (u v : Nat) (hv : v ≠ SHARED) (huv : u ≠ v) (r : L) (cs : List (Cmd (L × Nat) N V)) (s : LState (L × Nat) N P) :
    (wrun ops (seesP sees) cs s).stream (r, u) =
      (wrun ops (seesP sees) (cs.filter (fun c => c.label.2 != v)) s).stream (r, u) := by
  have := owner_isolation ops sees hs gt u v hv huv r cs s
  unfold restrictTo at this
  exact restrict_stream_eq _ _ _ this (r, u) (seesP_refl sees hs (r, u))

theorem owner_partition_history (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (x : L × Nat) (cs : List (Cmd (L × Nat) N V)) (s : LState (L × Nat) N P) :
    (wrun ops (seesP sees) cs s).parts x = (wrun ops (seesP sees) (purge (seesP sees) x cs) s).parts x ∧
    (wrun ops (seesP sees) cs s).stream x = (wrun ops (seesP sees) (purge (seesP sees) x cs) s).stream x :=
  partition_history ops (seesP sees) (seesP_sees sees hs) (gtP gt) x cs s

def forgetOwner (o : Nat) (s : LState (L × Nat) N P) : LState (L × Nat) N P :=
  { parts := fun x => if x.2 = o then none else s.parts x,
    index := fun n => (s.index n).filter (fun x => x.2 != o),
    stream := s.stream }

theorem forget_gone (o : Nat) (s : LState (L × Nat) N P) (x : L × Nat) (hx : x.2 = o) :
    (forgetOwner o s).parts x = none ∧ ∀ n, x ∉ (forgetOwner o s).index n := by
  refine ⟨by simp [forgetOwner, hx], ?_⟩
  intro n hm
  simp only [forgetOwner, List.mem_filter, bne_iff_ne, ne_eq] at hm
  exact hm.2 hx

theorem forget_keeps (o : Nat) (s : LState (L × Nat) N P) (x : L × Nat) (hx : x.2 ≠ o) :
    (forgetOwner o s).parts x = s.parts x ∧ ∀ n, (x ∈ (forgetOwner o s).index n ↔ x ∈ s.index n) := by
  refine ⟨by simp [forgetOwner, hx], ?_⟩
  intro n
  simp only [forgetOwner, List.mem_filter, bne_iff_ne, ne_eq, hx, not_false_eq_true, and_true]

theorem forget_local (sees gt : L → L → Bool) (o : Nat) (ho : o ≠ SHARED) (R : L × Nat) (hR : R.2 ≠ o)
    (s : LState (L × Nat) N P) :
    restrictTo (seesP sees) (gtP gt) R (forgetOwner o s) = restrictTo (seesP sees) (gtP gt) R s := by
  have hne : ∀ x, seesP sees R x = true → x.2 ≠ o := by
    intro x hx e
    rcases ((seesP_iff sees R x).mp hx).2 with h | h
    · exact ho (e ▸ h)
    · exact hR (h ▸ e)
  unfold restrictTo
  apply restrict_eq_of
  · intro l hl
    exact (forget_keeps o s l (hne l hl)).1
  · intro n
    simp only [forgetOwner]
    rw [List.filter_filter]
    apply List.filter_congr
    intro x _
    cases hv : (writerOf (seesP sees) (gtP gt) R).vis x
    · simp
    · have : x.2 ≠ o := hne x hv
      simp [this]
  · intro l _
    rfl

theorem forget_history (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (o : Nat) (ho : o ≠ SHARED) (R : L × Nat) (hR : R.2 ≠ o) (cs₁ cs₂ : List (Cmd (L × Nat) N V))
    (s : LState (L × Nat) N P) :
    restrictTo (seesP sees) (gtP gt) R (wrun ops (seesP sees) cs₂ (forgetOwner o (wrun ops (seesP sees) cs₁ s))) =
      restrictTo (seesP sees) (gtP gt) R (wrun ops (seesP sees) cs₂ (wrun ops (seesP sees) cs₁ s)) :=
  run_congr ops (seesP sees) (seesP_sees sees hs) (gtP gt) R cs₂ _ _ (forget_local sees gt o ho R hR _)

theorem forget_leaves_shared (sees gt : L → L → Bool) (o : Nat) (ho : o ≠ SHARED) (r : L)
    (s : LState (L × Nat) N P) :
    (restrictTo (seesP sees) (gtP gt) (r, o) (forgetOwner o s)).parts =
      (restrictTo (seesP sees) (gtP gt) (r, SHARED) s).parts ∧
    (restrictTo (seesP sees) (gtP gt) (r, o) (forgetOwner o s)).index =
      (restrictTo (seesP sees) (gtP gt) (r, SHARED) s).index := by
  have key : ∀ x : L × Nat, (ownerSees o x.2 && x.2 != o) = ownerSees SHARED x.2 := by
    intro x
    simp only [ownerSees, bne]
    by_cases hx : x.2 = o
    · have e1 : (x.2 == SHARED) = false := beq_false_of_ne (fun e => ho (hx ▸ e))
      have e2 : (x.2 == o) = true := beq_iff_eq.mpr hx
      rw [e1, e2]; rfl
    · have e2 : (x.2 == o) = false := beq_false_of_ne hx
      by_cases hs : x.2 = SHARED
      · have e1 : (x.2 == SHARED) = true := beq_iff_eq.mpr hs
        rw [e1, e2]; rfl
      · have e1 : (x.2 == SHARED) = false := beq_false_of_ne hs
        rw [e1, e2]; rfl
  constructor
  · funext x
    simp only [restrictTo, restrict, writerOf, forgetOwner, seesP]
    by_cases hx : x.2 = o
    · have h1 : ownerSees SHARED o = false := by
        simp only [ownerSees, Bool.or_self]
        exact beq_false_of_ne ho
      simp [hx, h1]
    · have k := key x
      have h3 : (x.2 != o) = true := bne_iff_ne.mpr hx
      rw [h3, Bool.and_true] at k
      simp [hx, k]
  · funext n
    simp only [restrictTo, restrict, writerOf, forgetOwner]
    rw [List.filter_filter]
    apply List.filter_congr
    intro x _
    simp only [seesP]
    rw [Bool.and_assoc, key x]

theorem forget_no_own (o : Nat) (s : LState (L × Nat) N P) (r : L) :
    (∀ x : L × Nat, x.2 = (r, o).2 → (forgetOwner o s).parts x = none) ∧
    (∀ m, ∀ c ∈ (forgetOwner o s).index m, c.2 ≠ (r, o).2) :=
  ⟨fun x hx => (forget_gone o s x hx).1, fun m c hc e => (forget_gone o s c e).2 m hc⟩

theorem forget_restrict_shared (sees gt : L → L → Bool) (o : Nat) (ho : o ≠ SHARED) (r : L)
    (s : LState (L × Nat) N P) :
    restrict (readerP sees gt (r, SHARED)) (forgetOwner o s) = restrict (readerP sees gt (r, SHARED)) s := by
  have h := forget_local sees gt o ho (r, SHARED) (Ne.symm ho) s
  unfold restrictTo at h
  exact h

theorem forget_find_shared (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (o : Nat) (ho : o ≠ SHARED)
    (r : L) (s : LState (L × Nat) N P) (n : N) :
    viewFind (readerP sees gt (r, o)) (forgetOwner o s) n = viewFind (readerP sees gt (r, SHARED)) s n := by
  rw [no_own_find_shared sees hs gt (r, o) (forgetOwner o s) (forget_no_own o s r).1 (forget_no_own o s r).2 n]
  dsimp only
  rw [← owner_viewFind_restrict sees hs gt (r, SHARED) (forgetOwner o s) n,
    ← owner_viewFind_restrict sees hs gt (r, SHARED) s n, forget_restrict_shared sees gt o ho r s]

theorem forget_view_shared (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (o : Nat) (ho : o ≠ SHARED)
    (acc : PartAcc N P) (le : L × Nat → L × Nat → Bool) (labelsU : List (L × Nat)) (namesU : List N)
    (r : L) (s : LState (L × Nat) N P) :
    viewOpen acc le labelsU namesU (readerP sees gt (r, o)) (forgetOwner o s) =
      viewOpen acc le labelsU namesU (readerP sees gt (r, SHARED)) s := by
  rw [no_own_view_shared sees hs gt acc le labelsU namesU (r, o) (forgetOwner o s) (forget_no_own o s r).1
    (forget_no_own o s r).2]
  dsimp only
  rw [← owner_viewOpen_restrict sees hs gt acc le labelsU namesU (r, SHARED) (forgetOwner o s),
    ← owner_viewOpen_restrict sees hs gt acc le labelsU namesU (r, SHARED) s, forget_restrict_shared sees gt o ho r s]

theorem forget_range_shared (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (o : Nat) (ho : o ≠ SHARED)
    (r : L) (s : LState (L × Nat) N P) (namesU : List N) (inRange : N → Bool) (limit : Option Nat) :
    viewRange (readerP sees gt (r, o)) (forgetOwner o s) namesU inRange limit =
      viewRange (readerP sees gt (r, SHARED)) s namesU inRange limit := by
  rw [no_own_range_shared sees hs gt (r, o) (forgetOwner o s) (forget_no_own o s r).1 (forget_no_own o s r).2]
  dsimp only
  rw [← owner_viewRange_restrict sees hs gt (r, SHARED) (forgetOwner o s),
    ← owner_viewRange_restrict sees hs gt (r, SHARED) s, forget_restrict_shared sees gt o ho r s]

end OwnerSteps

end Vectors
