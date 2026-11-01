import Storage.Table

namespace Storage

def GroupClear (xs : List Cell) (g : Nat) : Prop :=
  ∀ k, k < 16 → xs[g * 16 + k]? ≠ some .empty

def NoNewEmpty (xs ys : List Cell) : Prop :=
  ∀ i : Nat, ys[i]? = some Cell.empty → xs[i]? = some Cell.empty

def Reachable (xs : List Cell) (key hash : Nat) (path : List Nat) : Prop :=
  ∃ before g after i, path = before ++ g :: after ∧ i ∈ groupIndices g ∧
    keyAt xs key hash i = true ∧ ∀ prior ∈ before, GroupClear xs prior

theorem put_other (xs : List Cell) (i j : Nat) (c : Cell) (h : i ≠ j) :
    (put xs i c)[j]? = xs[j]? := by
  induction i generalizing xs j with
  | zero => cases xs <;> cases j <;> simp_all [put]
  | succ i ih =>
    cases xs with
    | nil => simp [put]
    | cons x xs =>
      cases j with
      | zero => simp [put]
      | succ j => simpa [put] using ih xs j (by omega)

theorem replacement_creates_no_empty (xs : List Cell) (i : Nat) (c : Cell) (h : c ≠ .empty) :
    NoNewEmpty xs (put xs i c) := by
  intro j hj
  by_cases he : i = j
  · subst j
    cases hi : xs[i]? with
    | none =>
      have hn : (put xs i c)[i]? = none := by
        have bound : xs.length ≤ i := List.getElem?_eq_none_iff.mp hi
        exact List.getElem?_eq_none_iff.mpr (by simpa [put_length] using bound)
      rw [hn] at hj
      contradiction
    | some old =>
      rw [put_selected xs i old c hi] at hj
      cases hj
      contradiction
  · rw [put_other xs i j c he] at hj
    exact hj

theorem clear_preserved (xs ys : List Cell) (g : Nat) (hn : NoNewEmpty xs ys)
    (h : GroupClear xs g) : GroupClear ys g := by
  intro k hk he
  exact h k hk (hn _ he)

theorem clear_prevents_stop (xs : List Cell) (g : Nat) (h : GroupClear xs g) :
    groupEmpty xs g = false := by
  simp only [groupEmpty, List.any_eq_false]
  intro k hk
  have hh := h k (List.mem_range.mp hk)
  simpa using hh

theorem lookup_reachable (xs : List Cell) (key hash : Nat) (path : List Nat)
    (h : Reachable xs key hash path) : ∃ i, lookupPath xs key hash path = some i := by
  obtain ⟨before, g, after, i, rfl, hi, hm, hc⟩ := h
  have target : ∃ j, lookupCandidates xs key hash (groupIndices g) = some j := by
    cases hh : lookupCandidates xs key hash (groupIndices g) with
    | some j => exact ⟨j, rfl⟩
    | none =>
      have hf := List.find?_eq_none.mp hh i hi
      simp [hm] at hf
  induction before with
  | nil =>
    obtain ⟨j, hj⟩ := target
    exact ⟨j, by simp [lookupPath, hj]⟩
  | cons prior rest ih =>
    have hprior := clear_prevents_stop xs prior (hc prior (by simp))
    have hrest : ∀ p ∈ rest, GroupClear xs p := fun p hp => hc p (by simp [hp])
    obtain ⟨j, hj⟩ := ih hrest
    cases hp : lookupCandidates xs key hash (groupIndices prior) with
    | some k => exact ⟨k, by simp [lookupPath, hp]⟩
    | none => exact ⟨j, by simp [lookupPath, hp, hprior, hj]⟩

theorem lookup_sound (xs : List Cell) (key hash : Nat) (path : List Nat) (i : Nat)
    (h : lookupPath xs key hash path = some i) : keyAt xs key hash i = true := by
  induction path with
  | nil => simp [lookupPath] at h
  | cons g rest ih =>
    simp only [lookupPath] at h
    split at h
    next j hj => cases h; exact List.find?_some hj
    next hn =>
      split at h
      next => contradiction
      next => exact ih h

theorem existing_key_reachability_preserved (xs : List Cell) (key hash : Nat) (path : List Nat)
    (changed : Nat) (c : Cell) (nonempty : c ≠ .empty)
    (h : Reachable xs key hash path)
    (different : ∀ i, keyAt xs key hash i = true → changed ≠ i) :
    Reachable (put xs changed c) key hash path := by
  obtain ⟨before, g, after, i, hp, hi, hm, hc⟩ := h
  refine ⟨before, g, after, i, hp, hi, ?_, ?_⟩
  · simpa only [keyAt, put_other xs changed i c (different i hm)] using hm
  · intro prior hh
    exact clear_preserved xs (put xs changed c) prior
      (replacement_creates_no_empty xs changed c nonempty) (hc prior hh)

theorem first_claim_clears_prior_groups (xs : List Cell) (before after : List Nat) (g i : Nat)
    (claim : ((before ++ g :: after).flatMap groupIndices).find? (freeAt xs) = some i)
    (notEarlier : i ∉ before.flatMap groupIndices) :
    ∀ prior ∈ before, GroupClear xs prior := by
  have nofree : (before.flatMap groupIndices).find? (freeAt xs) = none := by
    cases hp : (before.flatMap groupIndices).find? (freeAt xs) with
    | none => rfl
    | some j =>
      have he : j = i := by simpa [List.flatMap_append, List.find?_append, hp] using claim
      subst j
      exact False.elim (notEarlier (List.mem_of_find?_eq_some hp))
  intro prior hprior k hk he
  have member : prior * 16 + k ∈ before.flatMap groupIndices := by
    apply List.mem_flatMap.mpr
    exact ⟨prior, hprior, List.mem_map.mpr ⟨k, List.mem_range.mpr hk, rfl⟩⟩
  have hf := List.find?_eq_none.mp nofree _ member
  simp [freeAt, he] at hf

theorem free_slot_preserves_existing_lookup (xs : List Cell) (key hash : Nat) (path : List Nat)
    (i : Nat) (e : Entry) (free : freeAt xs i = true) (h : Reachable xs key hash path) :
    ∃ j, lookupPath (put xs i (.live e)) key hash path = some j := by
  apply lookup_reachable
  apply existing_key_reachability_preserved xs key hash path i (.live e) (by simp) h
  intro j hj he
  subst j
  cases hc : xs[i]? with
  | none => simp [freeAt, hc] at free
  | some c => cases c <;> simp_all [freeAt, keyAt]

theorem insertion_reachable (xs : List Cell) (e : Entry) (before after : List Nat) (g i : Nat)
    (hi : i ∈ groupIndices g) (free : freeAt xs i = true)
    (priorClear : ∀ prior ∈ before, GroupClear xs prior) :
    Reachable (put xs i (.live e)) e.key e.hash (before ++ g :: after) := by
  have cell : ∃ old, xs[i]? = some old := by
    cases hh : xs[i]? with
    | none => simp [freeAt, hh] at free
    | some c => exact ⟨c, rfl⟩
  obtain ⟨old, hold⟩ := cell
  refine ⟨before, g, after, i, rfl, hi, ?_, ?_⟩
  · simp [keyAt, put_selected xs i old (.live e) hold]
  · intro prior hp
    exact clear_preserved xs (put xs i (.live e)) prior
      (replacement_creates_no_empty xs i (.live e) (by simp)) (priorClear prior hp)

theorem tombstone_preserves_other_lookup (xs : List Cell) (key hash : Nat) (path : List Nat) (i : Nat)
    (reachable : Reachable xs key hash path)
    (other : ∀ j, keyAt xs key hash j = true → i ≠ j) :
    ∃ j, lookupPath (put xs i .deleted) key hash path = some j := by
  exact lookup_reachable _ _ _ _
    (existing_key_reachability_preserved xs key hash path i .deleted (by decide) reachable other)

def liveWeight : Cell → Nat
  | .live _ => 1
  | _ => 0

def CounterConsistent (t : Table) : Prop := t.live = (weight liveWeight t.slots : Int)

theorem empty_live_has_no_entries (xs : List Cell) (p : Entry → Bool)
    (h : weight liveWeight xs = 0) : weight (entryWeight p) xs = 0 := by
  induction xs with
  | nil => rfl
  | cons c rest ih =>
    cases c with
    | empty => simpa [weight, liveWeight, entryWeight] using ih (by simpa [weight, liveWeight] using h)
    | deleted => simpa [weight, liveWeight, entryWeight] using ih (by simpa [weight, liveWeight] using h)
    | live e => simp [weight, liveWeight] at h

theorem move_preserves_consistent_counters (b : Banks) (i j : Nat) (e : Entry)
    (hs : b.src.slots[i]? = some (.live e)) (hd : freeAt b.dst.slots j = true)
    (hsrc : CounterConsistent b.src) (hdst : CounterConsistent b.dst) :
    CounterConsistent (moveOne b i j e).src ∧ CounterConsistent (moveOne b i j e).dst := by
  have source := put_weight b.src.slots i (.live e) .deleted liveWeight hs
  simp only [liveWeight] at source
  unfold CounterConsistent at *
  constructor
  · simp only [moveOne]
    omega
  · cases hc : b.dst.slots[j]? with
    | none => simp [freeAt, hc] at hd
    | some c =>
      cases c with
      | live v => simp [freeAt, hc] at hd
      | empty =>
        have dest := put_weight b.dst.slots j .empty (.live e) liveWeight hc
        simp only [liveWeight] at dest
        simp only [moveOne, place]
        omega
      | deleted =>
        have dest := put_weight b.dst.slots j .deleted (.live e) liveWeight hc
        simp only [liveWeight] at dest
        simp only [moveOne, place]
        omega

theorem migrateAt_preserves_consistent_counters (b : Banks) (i : Nat)
    (hsrc : CounterConsistent b.src) (hdst : CounterConsistent b.dst) :
    CounterConsistent (migrateAt b i).1.src ∧ CounterConsistent (migrateAt b i).1.dst := by
  unfold migrateAt
  split
  next e hs =>
    split
    next j hj => exact move_preserves_consistent_counters b i j e hs (claim_is_free _ _ _ hj) hsrc hdst
    next => exact ⟨hsrc, hdst⟩
  next => exact ⟨hsrc, hdst⟩

theorem migrateSlots_preserves_consistent_counters (indices : List Nat) (limit moved : Nat) (b : Banks)
    (hsrc : CounterConsistent b.src) (hdst : CounterConsistent b.dst) :
    CounterConsistent (migrateSlots indices limit b moved).1.src ∧
      CounterConsistent (migrateSlots indices limit b moved).1.dst := by
  induction indices generalizing b moved with
  | nil => exact ⟨hsrc, hdst⟩
  | cons i rest ih =>
    simp only [migrateSlots]
    split
    next =>
      obtain ⟨hs, hd⟩ := migrateAt_preserves_consistent_counters b i hsrc hdst
      exact ih _ _ hs hd
    next => exact ⟨hsrc, hdst⟩

theorem migrateGroup_preserves_consistent_counters (b : Banks) (g limit : Nat)
    (hsrc : CounterConsistent b.src) (hdst : CounterConsistent b.dst) :
    CounterConsistent (migrateGroup b g limit).1.src ∧ CounterConsistent (migrateGroup b g limit).1.dst := by
  exact migrateSlots_preserves_consistent_counters _ limit 0 b hsrc hdst

theorem consistent_zero_live_swap (b : Banks) (p : Entry → Bool)
    (consistent : CounterConsistent b.src) (zero : b.src.live = 0) :
    logical p (swapBanks b).src.slots (swapBanks b).dst.slots = logical p b.src.slots b.dst.slots := by
  apply swap_preserves b p
  apply empty_live_has_no_entries
  unfold CounterConsistent at consistent
  omega

theorem final_batch_swap_preserves (b : Banks) (g limit : Nat) (p : Entry → Bool)
    (hsrc : CounterConsistent b.src) (hdst : CounterConsistent b.dst)
    (zero : (migrateGroup b g limit).1.src.live = 0) :
    logical p (swapBanks (migrateGroup b g limit).1).src.slots
      (swapBanks (migrateGroup b g limit).1).dst.slots = logical p b.src.slots b.dst.slots := by
  rw [consistent_zero_live_swap (migrateGroup b g limit).1 p
    (migrateGroup_preserves_consistent_counters b g limit hsrc hdst).1 zero]
  exact migrateGroup_preserves b g limit p

end Storage
