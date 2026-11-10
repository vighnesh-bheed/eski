namespace Vectors

def stampMax : Nat := 2 ^ 8 - 1

structure Visited where
  stamps : List Nat
  epoch : Nat
deriving Repr

def Visited.cap (v : Visited) : Nat := v.stamps.length

def visitedInit : Visited := ⟨[], 0⟩

def grownCap (cap n : Nat) : Nat := max n (max (cap + cap / 2) 64)

def visitedGrow (v : Visited) (n : Nat) : Visited :=
  if n > v.cap then ⟨v.stamps ++ List.replicate (grownCap v.cap n - v.cap) 0, v.epoch⟩ else v

def visitedReset (v : Visited) : Visited :=
  if v.epoch = stampMax then ⟨List.replicate v.cap 0, 0⟩ else v

def visitedBegin (v : Visited) (n : Nat) : Visited :=
  let v := visitedReset (visitedGrow v n)
  ⟨v.stamps, (v.epoch + 1) % 2 ^ 8⟩

def stampAt (v : Visited) (id : Nat) : Nat := v.stamps[id]?.getD 0

def visitedMark (v : Visited) (id : Nat) : Visited × Bool :=
  if stampAt v id = v.epoch then (v, false) else (⟨v.stamps.set id v.epoch, v.epoch⟩, true)

def visitedContains (v : Visited) (id : Nat) : Bool := stampAt v id == v.epoch

def markAll : Visited → List Nat → Visited × List Bool
  | v, [] => (v, [])
  | v, id :: ids =>
    let (v', r) := visitedMark v id
    let (vf, rs) := markAll v' ids
    (vf, r :: rs)

def naiveBegin (v : Visited) : Visited := ⟨v.stamps, (v.epoch + 1) % 2 ^ 8⟩

def VInv (v : Visited) : Prop := v.epoch < 2 ^ 8 ∧ ∀ s ∈ v.stamps, s ≤ v.epoch

theorem init_inv : VInv visitedInit := ⟨by decide, by simp [visitedInit]⟩

theorem stampAt_le {v : Visited} (h : VInv v) (id : Nat) : stampAt v id ≤ v.epoch := by
  unfold stampAt
  cases hs : v.stamps[id]? with
  | none => simp
  | some s => exact h.2 s (List.mem_of_getElem? hs)

theorem grow_spec (v : Visited) (n : Nat) (h : VInv v) :
    VInv (visitedGrow v n) ∧ n ≤ (visitedGrow v n).cap ∧ (visitedGrow v n).epoch = v.epoch ∧
      v.cap ≤ (visitedGrow v n).cap := by
  unfold visitedGrow
  split
  · refine ⟨⟨h.1, fun s hs => ?_⟩, ?_, rfl, ?_⟩
    · simp only [List.mem_append, List.mem_replicate] at hs
      rcases hs with hs | ⟨_, rfl⟩
      · exact h.2 s hs
      · simp
    · simp [Visited.cap, grownCap]; omega
    · simp [Visited.cap]
  · refine ⟨h, by omega, rfl, Nat.le_refl _⟩

theorem reset_spec (v : Visited) (h : VInv v) :
    (∀ s ∈ (visitedReset v).stamps, s ≤ (visitedReset v).epoch) ∧ (visitedReset v).epoch < stampMax ∧
      (visitedReset v).cap = v.cap := by
  unfold visitedReset
  split
  · refine ⟨fun s hs => ?_, by show (0 : Nat) < stampMax; decide, by simp [Visited.cap]⟩
    simp only [List.mem_replicate] at hs
    simp [hs.2]
  · refine ⟨h.2, ?_, rfl⟩
    have := h.1
    unfold stampMax at *
    omega

theorem begin_spec (v : Visited) (n : Nat) (h : VInv v) :
    VInv (visitedBegin v n) ∧ n ≤ (visitedBegin v n).cap ∧ 1 ≤ (visitedBegin v n).epoch ∧
      (∀ s ∈ (visitedBegin v n).stamps, s < (visitedBegin v n).epoch) := by
  obtain ⟨g1, g2, _, _⟩ := grow_spec v n h
  obtain ⟨r1, r2, r3⟩ := reset_spec (visitedGrow v n) g1
  unfold visitedBegin
  simp only
  generalize visitedReset (visitedGrow v n) = w at r1 r2 r3
  have he : (w.epoch + 1) % 2 ^ 8 = w.epoch + 1 := by
    apply Nat.mod_eq_of_lt; unfold stampMax at r2; omega
  rw [he]
  have hcap : w.cap = w.stamps.length := rfl
  refine ⟨⟨show w.epoch + 1 < 2 ^ 8 by unfold stampMax at r2; omega, fun s hs => Nat.le_succ_of_le (r1 s hs)⟩,
    show n ≤ w.stamps.length by rw [← hcap, r3]; exact g2, show 1 ≤ w.epoch + 1 by omega,
    fun s hs => Nat.lt_succ_of_le (r1 s hs)⟩

theorem begin_clears (v : Visited) (n : Nat) (h : VInv v) (j : Nat) :
    visitedContains (visitedBegin v n) j = false := by
  obtain ⟨_, _, h1, h2⟩ := begin_spec v n h
  unfold visitedContains stampAt
  cases hs : (visitedBegin v n).stamps[j]? with
  | none => simp; omega
  | some s =>
    have := h2 s (List.mem_of_getElem? hs)
    simp; omega

theorem begin_wrap (v : Visited) (n : Nat) (hw : v.epoch = stampMax) :
    (visitedBegin v n).epoch = 1 ∧ ∀ s ∈ (visitedBegin v n).stamps, s = 0 := by
  have hg : (visitedGrow v n).epoch = v.epoch := by unfold visitedGrow; split <;> rfl
  unfold visitedBegin visitedReset
  rw [hg, hw]
  simp only [ite_true]
  refine ⟨by decide, fun s hs => ?_⟩
  simp only [List.mem_replicate] at hs
  exact hs.2

theorem mark_spec (v : Visited) (id : Nat) (hid : id < v.cap) (j : Nat) :
    (visitedMark v id).1.epoch = v.epoch ∧ (visitedMark v id).1.cap = v.cap ∧
      (visitedMark v id).2 = !visitedContains v id ∧
      visitedContains (visitedMark v id).1 j = (visitedContains v j || j == id) := by
  unfold visitedMark
  split
  · next hs =>
    refine ⟨rfl, rfl, by simp [visitedContains, hs], ?_⟩
    by_cases hj : j = id
    · subst hj; simp [visitedContains, hs]
    · simp [hj]
  · next hs =>
    refine ⟨rfl, by simp [Visited.cap], by simp [visitedContains, hs], ?_⟩
    dsimp only
    unfold visitedContains stampAt
    simp only [List.getElem?_set]
    by_cases hj : j = id
    · subst hj
      have : j < v.stamps.length := hid
      simp [this]
    · have : ¬ id = j := fun e => hj e.symm
      simp [this, hj]

theorem mark_inv (v : Visited) (id : Nat) (h : VInv v) : VInv (visitedMark v id).1 := by
  unfold visitedMark
  split
  · exact h
  · refine ⟨h.1, fun s hs => ?_⟩
    show s ≤ v.epoch
    have hs' : s ∈ v.stamps.set id v.epoch := hs
    obtain ⟨k, hk, he⟩ := List.getElem_of_mem hs'
    simp only [List.getElem_set] at he
    split at he
    · omega
    · exact h.2 s (he ▸ List.getElem_mem _)

theorem markAll_spec (ids : List Nat) : ∀ (v : Visited) (marked : List Nat), VInv v → 1 ≤ v.epoch →
    (∀ x ∈ ids, x < v.cap) → (∀ j, visitedContains v j = decide (j ∈ marked)) →
    (∀ j, visitedContains (markAll v ids).1 j = decide (j ∈ marked ∨ j ∈ ids)) ∧
      (markAll v ids).2.length = ids.length ∧
      ∀ k (hk : k < ids.length), (markAll v ids).2[k]? = some (decide (ids[k] ∉ marked ∧ ids[k] ∉ ids.take k)) := by
  induction ids with
  | nil =>
    intro v marked _ _ _ hc
    refine ⟨fun j => by simp [markAll, hc j], by simp [markAll], fun k hk => by simp at hk⟩
  | cons id ids ih =>
    intro v marked hv he hids hc
    have hid : id < v.cap := hids id (by simp)
    obtain ⟨m1, m2, m3, _⟩ := mark_spec v id hid 0
    have m4 := fun j => (mark_spec v id hid j).2.2.2
    have hv' := mark_inv v id hv
    have hc' : ∀ j, visitedContains (visitedMark v id).1 j = decide (j ∈ id :: marked) := by
      intro j; rw [m4 j, hc j]
      by_cases h1 : j ∈ marked <;> by_cases h2 : j = id <;> simp [h1, h2]
    obtain ⟨r1, r2, r3⟩ := ih (visitedMark v id).1 (id :: marked) hv' (by rw [m1]; exact he)
      (fun x hx => by rw [m2]; exact hids x (by simp [hx])) hc'
    unfold markAll
    simp only
    refine ⟨fun j => ?_, by simp [r2], fun k hk => ?_⟩
    · rw [r1 j]
      by_cases h1 : j ∈ marked <;> by_cases h2 : j = id <;> by_cases h3 : j ∈ ids <;> simp [h1, h2, h3]
    · cases k with
      | zero =>
        simp only [List.getElem?_cons_zero, List.getElem_cons_zero, List.take_zero, List.not_mem_nil,
          not_false_eq_true, and_true, Option.some.injEq]
        rw [m3, hc id]
        simp
      | succ k =>
        simp only [List.getElem?_cons_succ, List.getElem_cons_succ, List.take_succ_cons, List.mem_cons]
        rw [r3 k (by simp at hk; omega)]
        simp only [List.mem_cons, Option.some.injEq, decide_eq_decide]
        constructor
        · rintro ⟨h1, h2⟩
          refine ⟨fun h => h1 (Or.inr h), fun h => ?_⟩
          rcases h with h | h
          · exact h1 (Or.inl h)
          · exact h2 h
        · rintro ⟨h1, h2⟩
          refine ⟨fun h => ?_, fun h => h2 (Or.inr h)⟩
          rcases h with h | h
          · exact h2 (Or.inl h)
          · exact h1 h

theorem search_visited (v : Visited) (n : Nat) (h : VInv v) (ids : List Nat) (hids : ∀ x ∈ ids, x < n) :
    (∀ j, visitedContains (markAll (visitedBegin v n) ids).1 j = decide (j ∈ ids)) ∧
      ∀ k (hk : k < ids.length), (markAll (visitedBegin v n) ids).2[k]? = some (decide (ids[k] ∉ ids.take k)) := by
  obtain ⟨b1, b2, b3, _⟩ := begin_spec v n h
  obtain ⟨r1, _, r3⟩ := markAll_spec ids (visitedBegin v n) [] b1 b3 (fun x hx => by have := hids x hx; omega)
    (fun j => by rw [begin_clears v n h j]; simp)
  exact ⟨fun j => by rw [r1 j]; simp, fun k hk => by rw [r3 k hk]; simp⟩

theorem visited_inv_after_search (v : Visited) (n : Nat) (h : VInv v) (ids : List Nat) :
    VInv (markAll (visitedBegin v n) ids).1 := by
  have hb := (begin_spec v n h).1
  generalize visitedBegin v n = w at hb
  induction ids generalizing w with
  | nil => exact hb
  | cons id ids ih =>
    unfold markAll
    exact ih _ (mark_inv w id hb)

theorem naive_wrap_counterexample :
    VInv ⟨[0], stampMax⟩ ∧ visitedContains (naiveBegin ⟨[0], stampMax⟩) 0 = true ∧
      visitedContains (visitedBegin ⟨[0], stampMax⟩ 1) 0 = false := by
  refine ⟨⟨by decide, by simp [stampMax]⟩, by decide, by decide⟩

theorem stale_stamp_counterexample :
    visitedContains (visitedBegin ⟨[stampMax], stampMax - 1⟩ 1) 0 = true ∧ ¬ VInv ⟨[stampMax], stampMax - 1⟩ := by
  refine ⟨by decide, fun h => ?_⟩
  have := h.2 stampMax (by simp)
  simp [stampMax] at this

def searchRound (v : Visited) (r : Nat × List Nat) : Visited := (markAll (visitedBegin v r.1) r.2).1

def runRounds (v : Visited) (rs : List (Nat × List Nat)) : Visited := rs.foldl searchRound v

theorem markAll_epoch (ids : List Nat) : ∀ v : Visited, (markAll v ids).1.epoch = v.epoch := by
  induction ids with
  | nil => intro v; rfl
  | cons id ids ih =>
    intro v
    unfold markAll
    simp only
    rw [ih]
    unfold visitedMark
    split <;> rfl

theorem begin_epoch (v : Visited) (n : Nat) (h : VInv v) : (visitedBegin v n).epoch = v.epoch % stampMax + 1 := by
  have hg : (visitedGrow v n).epoch = v.epoch := by unfold visitedGrow; split <;> rfl
  have he := h.1
  unfold visitedBegin visitedReset
  rw [hg]
  unfold stampMax at *
  split
  · next hw => simp only; rw [hw]
  · next hw => simp only; omega

theorem begin_keeps (v : Visited) (n : Nat) (hw : v.epoch ≠ stampMax) :
    (visitedBegin v n).stamps = (visitedGrow v n).stamps := by
  have hg : (visitedGrow v n).epoch = v.epoch := by unfold visitedGrow; split <;> rfl
  unfold visitedBegin visitedReset
  rw [hg]
  simp [hw]

theorem round_inv (v : Visited) (r : Nat × List Nat) (h : VInv v) : VInv (searchRound v r) :=
  visited_inv_after_search v r.1 h r.2

theorem round_epoch (v : Visited) (r : Nat × List Nat) (h : VInv v) :
    (searchRound v r).epoch = v.epoch % stampMax + 1 := by
  unfold searchRound
  rw [markAll_epoch, begin_epoch v r.1 h]

theorem rounds_spec (rs : List (Nat × List Nat)) : ∀ v : Visited, VInv v →
    VInv (runRounds v rs) ∧
      (rs ≠ [] → (runRounds v rs).epoch = (v.epoch % stampMax + rs.length - 1) % stampMax + 1) := by
  induction rs with
  | nil => intro v h; exact ⟨h, fun h' => absurd rfl h'⟩
  | cons r rs ih =>
    intro v h
    have h1 := round_inv v r h
    have e1 := round_epoch v r h
    obtain ⟨i1, i2⟩ := ih (searchRound v r) h1
    unfold runRounds at i1 i2 ⊢
    simp only [List.foldl_cons]
    refine ⟨i1, fun _ => ?_⟩
    by_cases hr : rs = []
    · subst hr
      simp only [List.foldl_nil, List.length_singleton]
      rw [e1]
      unfold stampMax
      omega
    · have hl : 0 < rs.length := List.length_pos_iff.mpr hr
      rw [i2 hr, e1]
      simp only [List.length_cons]
      unfold stampMax
      omega

theorem rounds_epoch (rs : List (Nat × List Nat)) (hne : rs ≠ []) :
    (runRounds visitedInit rs).epoch = (rs.length - 1) % stampMax + 1 := by
  have := (rounds_spec rs visitedInit init_inv).2 hne
  rw [this]
  show (0 % stampMax + rs.length - 1) % stampMax + 1 = (rs.length - 1) % stampMax + 1
  unfold stampMax
  omega

theorem rounds_clear_every_255 (rs : List (Nat × List Nat)) (k : Nat) :
    (runRounds visitedInit (rs.take k)).epoch = stampMax ↔ 0 < (rs.take k).length ∧ (rs.take k).length % stampMax = 0 := by
  by_cases hk : rs.take k = []
  · rw [hk]
    show visitedInit.epoch = stampMax ↔ 0 < 0 ∧ _
    simp [visitedInit, stampMax]
  · rw [rounds_epoch _ hk]
    have : 0 < (rs.take k).length := List.length_pos_iff.mpr hk
    unfold stampMax
    omega

theorem rounds_exact (rs : List (Nat × List Nat)) (k : Nat) (hk : k < rs.length)
    (hids : ∀ x ∈ rs[k].2, x < rs[k].1) :
    (∀ j, visitedContains (markAll (visitedBegin (runRounds visitedInit (rs.take k)) rs[k].1) rs[k].2).1 j =
        decide (j ∈ rs[k].2)) ∧
      ∀ i (hi : i < rs[k].2.length),
        (markAll (visitedBegin (runRounds visitedInit (rs.take k)) rs[k].1) rs[k].2).2[i]? =
          some (decide (rs[k].2[i] ∉ rs[k].2.take i)) :=
  search_visited _ rs[k].1 (rounds_spec (rs.take k) visitedInit init_inv).1 rs[k].2 hids

end Vectors
