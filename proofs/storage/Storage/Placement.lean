import Storage.Reachability
import Storage.Probe

namespace Storage

def Placed (xs : List Cell) (i hash : Nat) : Prop :=
  ∃ before g after, probeOf xs hash = before ++ g :: after ∧ i ∈ groupIndices g ∧
    ∀ prior ∈ before, GroupClear xs prior

def WellPlaced (xs : List Cell) : Prop :=
  ∀ i e, xs[i]? = some (.live e) → Placed xs i e.hash

def UniqueKeys (xs : List Cell) : Prop :=
  ∀ (i j : Nat) (e f : Entry), xs[i]? = some (.live e) → xs[j]? = some (.live f) → e.key = f.key → i = j

def Behind (b : Banks) : Prop := ∀ g, g < b.cursor.toNat → groupLive b.src g = false

def bankOf (b : Banks) (dst : Bool) : Table := if dst then b.dst else b.src

def entryAt (b : Banks) (dst : Bool) (i : Nat) : Option Entry :=
  match (bankOf b dst).slots[i]? with
  | some (.live e) => some e
  | _ => none

def writeAt (b : Banks) (dst : Bool) (i : Nat) (c : Cell) : Banks :=
  if dst then {b with dst := {b.dst with slots := put b.dst.slots i c}}
  else {b with src := {b.src with slots := put b.src.slots i c}}

def upsert (b : Banks) (key hash : Nat) (fresh : Entry) (change : Entry → Entry) :
    Option (Banks × Option Entry) :=
  match locate b key hash with
  | some (d, i) =>
    match entryAt b d i with
    | some old => some (writeAt b d i (.live (change old)), some old)
    | none => none
  | none =>
    if 0 ≤ b.cursor then (claimIndex b.dst.slots fresh.hash).map fun j => ({b with dst := place b.dst j fresh}, none)
    else (claimIndex b.src.slots fresh.hash).map fun j => ({b with src := place b.src j fresh}, none)

def remove (b : Banks) (key hash : Nat) : Banks × Option Entry :=
  match locate b key hash with
  | some (d, i) =>
    match entryAt b d i with
    | some old =>
      if d then ({b with dst := erase b.dst i}, some old) else ({b with src := erase b.src i}, some old)
    | none => (b, none)
  | none => (b, none)

theorem put_at (xs : List Cell) (i : Nat) (c : Cell) : (put xs i c)[i]? = xs[i]?.map fun _ => c := by
  induction i generalizing xs with
  | zero => cases xs <;> simp [put]
  | succ i ih => cases xs <;> simp [put, ih]

theorem put_nonlive (xs : List Cell) (i : Nat) (c : Cell) (hc : ∀ e, c ≠ .live e) (e : Entry) :
    (put xs i c)[i]? ≠ some (.live e) := by
  rw [put_at]
  cases xs[i]? with
  | none => simp
  | some _ => simpa using hc e

theorem probe_of_put (xs : List Cell) (i : Nat) (c : Cell) (hash : Nat) :
    probeOf (put xs i c) hash = probeOf xs hash := by
  simp [probeOf, groupsOf, put_length]

theorem placed_preserved (xs ys : List Cell) (i hash : Nat) (hlen : ys.length = xs.length)
    (hn : NoNewEmpty xs ys) (h : Placed xs i hash) : Placed ys i hash := by
  obtain ⟨before, g, after, hp, hi, hc⟩ := h
  refine ⟨before, g, after, ?_, hi, fun prior hm => clear_preserved xs ys prior hn (hc prior hm)⟩
  simpa [probeOf, groupsOf, hlen] using hp

theorem placed_reachable (xs : List Cell) (i : Nat) (e : Entry) (hs : xs[i]? = some (.live e))
    (h : Placed xs i e.hash) : Reachable xs e.key e.hash (probeOf xs e.hash) := by
  obtain ⟨before, g, after, hp, hi, hc⟩ := h
  exact ⟨before, g, after, i, hp, hi, by simp [keyAt, hs], hc⟩

theorem lookup_finds_placed (t : Table) (i : Nat) (e : Entry)
    (hs : t.slots[i]? = some (.live e)) (h : WellPlaced t.slots) :
    ∃ j, findIndex t e.key e.hash = some j ∧ keyAt t.slots e.key e.hash j = true := by
  obtain ⟨j, hj⟩ := lookup_reachable _ _ _ _ (placed_reachable t.slots i e hs (h i e hs))
  exact ⟨j, hj, lookup_sound _ _ _ _ _ hj⟩

theorem lookup_exact (t : Table) (i : Nat) (e : Entry)
    (hs : t.slots[i]? = some (.live e)) (h : WellPlaced t.slots) (unique : UniqueKeys t.slots) :
    findIndex t e.key e.hash = some i := by
  obtain ⟨j, hj, hk⟩ := lookup_finds_placed t i e hs h
  rw [hj]
  cases hc : t.slots[j]? with
  | none => simp [keyAt, hc] at hk
  | some c =>
    cases c with
    | live f =>
      simp [keyAt, hc] at hk
      rw [unique j i f e hc hs hk.1]
    | empty => simp [keyAt, hc] at hk
    | deleted => simp [keyAt, hc] at hk

theorem find_flat_split (l : List Nat) (p : Nat → Bool) (i : Nat)
    (h : (l.flatMap groupIndices).find? p = some i) :
    ∃ before g after, l = before ++ g :: after ∧ i ∈ groupIndices g ∧
      ∀ prior ∈ before, ∀ j ∈ groupIndices prior, p j = false := by
  rw [List.find?_flatMap] at h
  obtain ⟨before, g, after, hl, hg, hb⟩ := List.findSome?_eq_some_iff.mp h
  refine ⟨before, g, after, hl, List.mem_of_find?_eq_some hg, ?_⟩
  intro prior hp j hj
  have hn := List.find?_eq_none.mp (hb prior hp) j hj
  simpa using hn

theorem claim_placed (xs : List Cell) (hash i : Nat) (e : Entry) (hc : claimIndex xs hash = some i) :
    Placed (put xs i (.live e)) i hash := by
  unfold claimIndex candidates at hc
  obtain ⟨before, g, after, hp, hi, hb⟩ := find_flat_split (probeOf xs hash) (freeAt xs) i hc
  refine ⟨before, g, after, by rw [probe_of_put]; exact hp, hi, ?_⟩
  intro prior hm
  apply clear_preserved xs _ prior (replacement_creates_no_empty xs i _ (by simp))
  intro k hk he
  have hf := hb prior hm (prior * 16 + k) (List.mem_map.mpr ⟨k, List.mem_range.mpr hk, rfl⟩)
  simp [freeAt, he] at hf

theorem claim_preserves_wellplaced (xs : List Cell) (e : Entry) (i : Nat)
    (hc : claimIndex xs e.hash = some i) (h : WellPlaced xs) : WellPlaced (put xs i (.live e)) := by
  intro j f hj
  by_cases hij : i = j
  · subst hij
    have free := claim_is_free xs e.hash i hc
    cases hx : xs[i]? with
    | none => simp [freeAt, hx] at free
    | some old =>
      rw [put_selected xs i old _ hx] at hj
      simp only [Option.some.injEq, Cell.live.injEq] at hj
      subst hj
      exact claim_placed xs e.hash i e hc
  · rw [put_other xs i j _ hij] at hj
    exact placed_preserved xs _ j f.hash (put_length _ _ _)
      (replacement_creates_no_empty xs i _ (by simp)) (h j f hj)

theorem tombstone_preserves_wellplaced (xs : List Cell) (i : Nat) (h : WellPlaced xs) :
    WellPlaced (put xs i .deleted) := by
  intro j f hj
  by_cases hij : i = j
  · subst hij
    exact absurd hj (put_nonlive xs i .deleted (by simp) f)
  · rw [put_other xs i j _ hij] at hj
    exact placed_preserved xs _ j f.hash (put_length _ _ _)
      (replacement_creates_no_empty xs i _ (by simp)) (h j f hj)

theorem update_preserves_wellplaced (xs : List Cell) (i : Nat) (e e' : Entry)
    (hs : xs[i]? = some (.live e)) (hh : e'.hash = e.hash) (h : WellPlaced xs) :
    WellPlaced (put xs i (.live e')) := by
  intro j f hj
  by_cases hij : i = j
  · subst hij
    rw [put_selected xs i _ _ hs] at hj
    simp only [Option.some.injEq, Cell.live.injEq] at hj
    subst hj
    rw [hh]
    exact placed_preserved xs _ i e.hash (put_length _ _ _)
      (replacement_creates_no_empty xs i _ (by simp)) (h i e hs)
  · rw [put_other xs i j _ hij] at hj
    exact placed_preserved xs _ j f.hash (put_length _ _ _)
      (replacement_creates_no_empty xs i _ (by simp)) (h j f hj)

theorem erase_preserves_wellplaced (t : Table) (i : Nat) (h : WellPlaced t.slots) :
    WellPlaced (erase t i).slots := by
  by_cases hem : ((List.range 16).any fun k => t.slots[i / 16 * 16 + k]? == some .empty) = true
  · have he : (erase t i).slots = put t.slots i .empty := by simp [erase, hem]
    rw [he]
    intro j f hj
    by_cases hij : i = j
    · subst hij
      exact absurd hj (put_nonlive t.slots i .empty (by simp) f)
    · rw [put_other _ _ _ _ hij] at hj
      obtain ⟨before, g, after, hp, hi, hc⟩ := h j f hj
      refine ⟨before, g, after, by rw [probe_of_put]; exact hp, hi, ?_⟩
      intro prior hm k hk hq
      have clear := hc prior hm
      by_cases hpr : prior = i / 16
      · subst hpr
        obtain ⟨k', hk', hk'e⟩ := List.any_eq_true.mp hem
        exact clear k' (List.mem_range.mp hk') (by simpa using hk'e)
      · have hne : i ≠ prior * 16 + k := by omega
        rw [put_other _ _ _ _ hne] at hq
        exact clear k hk hq
  · have he : (erase t i).slots = put t.slots i .deleted := by simp [erase, hem]
    rw [he]
    exact tombstone_preserves_wellplaced t.slots i h

theorem empty_wellplaced (n : Nat) : WellPlaced (List.replicate n .empty) := by
  intro i e hi
  rw [List.getElem?_replicate] at hi
  split at hi <;> simp at hi

theorem move_preserves_wellplaced (b : Banks) (i j : Nat) (e : Entry)
    (hj : claimIndex b.dst.slots e.hash = some j)
    (hsrc : WellPlaced b.src.slots) (hdst : WellPlaced b.dst.slots) :
    WellPlaced (moveOne b i j e).src.slots ∧ WellPlaced (moveOne b i j e).dst.slots :=
  ⟨tombstone_preserves_wellplaced _ _ hsrc, claim_preserves_wellplaced _ _ _ hj hdst⟩

theorem migrateAt_preserves_wellplaced (b : Banks) (i : Nat)
    (hsrc : WellPlaced b.src.slots) (hdst : WellPlaced b.dst.slots) :
    WellPlaced (migrateAt b i).1.src.slots ∧ WellPlaced (migrateAt b i).1.dst.slots := by
  unfold migrateAt
  split
  next e hs =>
    split
    next j hj => exact move_preserves_wellplaced b i j e hj hsrc hdst
    next => exact ⟨hsrc, hdst⟩
  next => exact ⟨hsrc, hdst⟩

theorem migrateSlots_preserves_wellplaced (indices : List Nat) (limit moved : Nat) (b : Banks)
    (hsrc : WellPlaced b.src.slots) (hdst : WellPlaced b.dst.slots) :
    WellPlaced (migrateSlots indices limit b moved).1.src.slots ∧
      WellPlaced (migrateSlots indices limit b moved).1.dst.slots := by
  induction indices generalizing b moved with
  | nil => exact ⟨hsrc, hdst⟩
  | cons i rest ih =>
    simp only [migrateSlots]
    split
    next =>
      obtain ⟨hs, hd⟩ := migrateAt_preserves_wellplaced b i hsrc hdst
      exact ih _ _ hs hd
    next => exact ⟨hsrc, hdst⟩

theorem migrateGroup_preserves_wellplaced (b : Banks) (g limit : Nat)
    (hsrc : WellPlaced b.src.slots) (hdst : WellPlaced b.dst.slots) :
    WellPlaced (migrateGroup b g limit).1.src.slots ∧ WellPlaced (migrateGroup b g limit).1.dst.slots :=
  migrateSlots_preserves_wellplaced _ limit 0 b hsrc hdst

theorem swap_preserves_wellplaced (b : Banks) (hdst : WellPlaced b.dst.slots) :
    WellPlaced (swapBanks b).src.slots ∧ WellPlaced (swapBanks b).dst.slots :=
  ⟨hdst, empty_wellplaced 0⟩

theorem locate_finds_present (b : Banks) (i : Nat) (e : Entry)
    (wsrc : WellPlaced b.src.slots) (wdst : WellPlaced b.dst.slots)
    (present : b.src.slots[i]? = some (.live e) ∨ (0 ≤ b.cursor ∧ b.dst.slots[i]? = some (.live e))) :
    ∃ d j, locate b e.key e.hash = some (d, j) ∧ keyAt (bankOf b d).slots e.key e.hash j = true := by
  unfold locate
  cases hs : findIndex b.src e.key e.hash with
  | some j => exact ⟨false, j, rfl, lookup_sound _ _ _ _ _ hs⟩
  | none =>
    rcases present with hsrc | ⟨hc, hdst⟩
    · obtain ⟨j, hj, _⟩ := lookup_finds_placed b.src i e hsrc wsrc
      rw [hs] at hj
      contradiction
    · obtain ⟨j, hj, hk⟩ := lookup_finds_placed b.dst i e hdst wdst
      exact ⟨true, j, by simp [hc, hj], hk⟩

theorem groupLive_put_nonlive (t t' : Table) (i g : Nat) (c : Cell) (hs : t'.slots = put t.slots i c)
    (hc : ∀ e, c ≠ .live e) (h : groupLive t g = false) : groupLive t' g = false := by
  unfold groupLive at h ⊢
  rw [List.any_eq_false] at h ⊢
  intro k hk
  have hk' := h k hk
  rw [hs]
  by_cases hik : i = g * 16 + k
  · rw [← hik, put_at]
    cases t.slots[i]? with
    | none => simp
    | some old =>
      cases c with
      | live e => exact absurd rfl (hc e)
      | empty => simp
      | deleted => simp
  · rw [put_other _ _ _ _ hik]
    exact hk'

theorem groupLive_put_away (t t' : Table) (i g : Nat) (c : Cell) (old : Entry)
    (hs : t'.slots = put t.slots i c) (hi : t.slots[i]? = some (.live old))
    (h : groupLive t g = false) : groupLive t' g = false := by
  unfold groupLive at h ⊢
  rw [List.any_eq_false] at h ⊢
  intro k hk
  have hk' := h k hk
  rw [hs]
  by_cases hik : i = g * 16 + k
  · rw [← hik, hi] at hk'
    simp at hk'
  · rw [put_other _ _ _ _ hik]
    exact hk'

theorem migrateAt_shape (b : Banks) (i : Nat) :
    (migrateAt b i).1.cursor = b.cursor ∧ (migrateAt b i).1.src.slots.length = b.src.slots.length ∧
      (migrateAt b i).1.dst.slots.length = b.dst.slots.length := by
  unfold migrateAt
  split
  next =>
    split
    next => simp [moveOne, place, put_length]
    next => simp
  next => simp

theorem migrateSlots_shape (indices : List Nat) (limit moved : Nat) (b : Banks) :
    (migrateSlots indices limit b moved).1.cursor = b.cursor ∧
      (migrateSlots indices limit b moved).1.src.slots.length = b.src.slots.length ∧
      (migrateSlots indices limit b moved).1.dst.slots.length = b.dst.slots.length := by
  induction indices generalizing b moved with
  | nil => simp [migrateSlots]
  | cons i rest ih =>
    simp only [migrateSlots]
    split
    next =>
      obtain ⟨a, c, d⟩ := ih (moved + (migrateAt b i).2) (migrateAt b i).1
      obtain ⟨a', c', d'⟩ := migrateAt_shape b i
      exact ⟨a.trans a', c.trans c', d.trans d'⟩
    next => simp

theorem migrateAt_behind (b : Banks) (i : Nat) (h : Behind b) : Behind (migrateAt b i).1 := by
  unfold migrateAt
  split
  next e hs =>
    split
    next j hj =>
      intro g hg
      exact groupLive_put_nonlive b.src _ i g .deleted rfl (by simp) (h g hg)
    next => exact h
  next => exact h

theorem migrateSlots_behind (indices : List Nat) (limit moved : Nat) (b : Banks) (h : Behind b) :
    Behind (migrateSlots indices limit b moved).1 := by
  induction indices generalizing b moved with
  | nil => exact h
  | cons i rest ih =>
    simp only [migrateSlots]
    split
    next => exact ih _ _ (migrateAt_behind b i h)
    next => exact h

theorem rehashLoop_invariant (fuel : Nat) (b : Banks) (maxGroups want moved visited : Nat)
    (f : Entry → Nat) (hc : 0 ≤ b.cursor) (behind : Behind b)
    (hsrc : CounterConsistent b.src) (hdst : CounterConsistent b.dst)
    (wsrc : WellPlaced b.src.slots) (wdst : WellPlaced b.dst.slots) :
    let n := rehashLoop fuel b maxGroups want moved visited
    total f n.src.slots n.dst.slots = total f b.src.slots b.dst.slots ∧ 0 ≤ n.cursor ∧ Behind n ∧
      CounterConsistent n.src ∧ CounterConsistent n.dst ∧ WellPlaced n.src.slots ∧ WellPlaced n.dst.slots ∧
      n.src.slots.length = b.src.slots.length ∧ n.dst.slots.length = b.dst.slots.length := by
  induction fuel generalizing b moved visited with
  | zero => exact ⟨rfl, hc, behind, hsrc, hdst, wsrc, wdst, rfl, rfl⟩
  | succ fuel ih =>
    simp only [rehashLoop]
    split
    next => exact ⟨rfl, hc, behind, hsrc, hdst, wsrc, wdst, rfl, rfl⟩
    next hstop =>
      have ht := migrateSlots_preserves_total (groupIndices b.cursor.toNat) (want - moved) 0 b f
      obtain ⟨hcur, hls, hld⟩ := migrateSlots_shape (groupIndices b.cursor.toNat) (want - moved) 0 b
      have hb := migrateSlots_behind (groupIndices b.cursor.toNat) (want - moved) 0 b behind
      obtain ⟨cs, cd⟩ := migrateGroup_preserves_consistent_counters b b.cursor.toNat (want - moved) hsrc hdst
      obtain ⟨ws, wd⟩ := migrateGroup_preserves_wellplaced b b.cursor.toNat (want - moved) wsrc wdst
      split
      next hdone =>
        have hlive := (group_done_exact b b.cursor.toNat (want - moved)).mp hdone
        obtain ⟨a, c, d, e, g, h, k, l, m⟩ := ih {(migrateGroup b b.cursor.toNat (want - moved)).1 with
            cursor := nextCursor (migrateGroup b b.cursor.toNat (want - moved)).1.cursor true}
          (moved + (migrateGroup b b.cursor.toNat (want - moved)).2.1) (visited + 1)
          (by simp only [nextCursor, migrateGroup]; omega)
          (by
            intro g hg
            simp only [nextCursor, migrateGroup] at hg
            rw [hcur] at hg
            by_cases hgc : g = b.cursor.toNat
            · subst hgc; exact hlive
            · exact hb g (by rw [hcur]; omega))
          cs cd ws wd
        refine ⟨a.trans ht, c, d, e, g, h, k, l.trans hls, m.trans hld⟩
      next => exact ⟨ht, by rw [migrateGroup, hcur]; exact hc, hb, cs, cd, ws, wd, hls, hld⟩

theorem no_live_weight (xs : List Cell) (f : Entry → Nat) (h : ∀ (i : Nat) (e : Entry), xs[i]? ≠ some (.live e)) :
    weight (liftWeight f) xs = 0 := by
  induction xs with
  | nil => rfl
  | cons c rest ih =>
    have tail : ∀ (i : Nat) (e : Entry), rest[i]? ≠ some (.live e) := fun i e => by simpa using h (i + 1) e
    cases c with
    | live e => exact absurd (by simp) (h 0 e)
    | empty => simp [weight, liftWeight, ih tail]
    | deleted => simp [weight, liftWeight, ih tail]

theorem zero_live_none (xs : List Cell) (h : weight liveWeight xs = 0) :
    ∀ (i : Nat) (e : Entry), xs[i]? ≠ some (.live e) := by
  induction xs with
  | nil => intro i e; simp
  | cons c rest ih =>
    intro i e
    cases c with
    | live f => simp [weight, liveWeight] at h
    | empty =>
      cases i with
      | zero => simp
      | succ i => simpa using ih (by simpa [weight, liveWeight] using h) i e
    | deleted =>
      cases i with
      | zero => simp
      | succ i => simpa using ih (by simpa [weight, liveWeight] using h) i e

theorem cleared_groups_none (t : Table) (whole : t.slots.length % 16 = 0)
    (h : ∀ g, g < groupsOf t.slots → groupLive t g = false) :
    ∀ (i : Nat) (e : Entry), t.slots[i]? ≠ some (.live e) := by
  intro i e hi
  have hlt : i < t.slots.length := by
    apply Classical.byContradiction
    intro hc
    rw [List.getElem?_eq_none_iff.mpr (by omega)] at hi
    contradiction
  have hg : i / 16 < groupsOf t.slots := by unfold groupsOf; omega
  have hl := h (i / 16) hg
  unfold groupLive at hl
  rw [List.any_eq_false] at hl
  have hk := hl (i % 16) (List.mem_range.mpr (Nat.mod_lt _ (by decide)))
  have e16 : i / 16 * 16 + i % 16 = i := by omega
  rw [e16, hi] at hk
  simp at hk

theorem rehash_invariant (b : Banks) (maxGroups want : Nat) (f : Entry → Nat)
    (hc : 0 ≤ b.cursor) (whole : b.src.slots.length % 16 = 0) (behind : Behind b)
    (hsrc : CounterConsistent b.src) (hdst : CounterConsistent b.dst)
    (wsrc : WellPlaced b.src.slots) (wdst : WellPlaced b.dst.slots) :
    let r := rehash b maxGroups want
    total f r.src.slots r.dst.slots = total f b.src.slots b.dst.slots ∧ Behind r ∧
      CounterConsistent r.src ∧ CounterConsistent r.dst ∧ WellPlaced r.src.slots ∧ WellPlaced r.dst.slots ∧
      ((0 ≤ r.cursor ∧ r.src.slots.length = b.src.slots.length ∧ r.dst.slots.length = b.dst.slots.length) ∨
        (r.cursor = -1 ∧ r.src.slots.length = b.dst.slots.length ∧ r.dst.slots = [])) := by
  obtain ⟨ht, hc', hb', cs, cd, ws, wd, hls, hld⟩ :=
    rehashLoop_invariant (groupsOf b.src.slots) b maxGroups want 0 0 f hc behind hsrc hdst wsrc wdst
  unfold rehash
  generalize rehashLoop (groupsOf b.src.slots) b maxGroups want 0 0 = n at ht hc' hb' cs cd ws wd hls hld
  simp only
  split
  next hswap =>
    have none : ∀ (i : Nat) (e : Entry), n.src.slots[i]? ≠ some (.live e) := by
      rcases hswap with hg | hz
      · apply cleared_groups_none n.src (by rw [hls]; exact whole)
        intro g hgl
        exact hb' g (by unfold groupsOf at hg hgl; omega)
      · apply zero_live_none
        unfold CounterConsistent at cs
        omega
    have hw := no_live_weight _ f none
    refine ⟨?_, ?_, cd, ?_, wd, empty_wellplaced 0, Or.inr ⟨rfl, hld, rfl⟩⟩
    · simp only [total, swapBanks, emptyTable, List.replicate, weight] at ht ⊢
      omega
    · intro g hg
      simp [swapBanks] at hg
    · simp [CounterConsistent, swapBanks, emptyTable, weight]
  next => exact ⟨ht, hb', cs, cd, ws, wd, Or.inl ⟨hc', hls, hld⟩⟩

theorem rehash_preserves_logical (b : Banks) (maxGroups want : Nat) (p : Entry → Bool)
    (hc : 0 ≤ b.cursor) (whole : b.src.slots.length % 16 = 0) (behind : Behind b)
    (hsrc : CounterConsistent b.src) (hdst : CounterConsistent b.dst)
    (wsrc : WellPlaced b.src.slots) (wdst : WellPlaced b.dst.slots) :
    logical p (rehash b maxGroups want).src.slots (rehash b maxGroups want).dst.slots =
      logical p b.src.slots b.dst.slots := by
  have h := (rehash_invariant b maxGroups want (fun e => if p e then 1 else 0) hc whole behind hsrc hdst wsrc wdst).1
  simp only [total, ← entry_weight_lift] at h
  exact h

theorem present_weight (xs : List Cell) (i : Nat) (e : Entry) (h : xs[i]? = some (.live e)) :
    0 < weight (liftWeight fun x => if x = e then 1 else 0) xs := by
  have hw := put_weight xs i (.live e) .deleted (liftWeight fun x => if x = e then 1 else 0) h
  simp [liftWeight] at hw
  omega

theorem weight_pos_present (xs : List Cell) (e : Entry)
    (h : 0 < weight (liftWeight fun x => if x = e then 1 else 0) xs) : ∃ j : Nat, xs[j]? = some (Cell.live e) := by
  induction xs with
  | nil => simp [weight] at h
  | cons c rest ih =>
    by_cases hc : c = .live e
    · exact ⟨0, by simp [hc]⟩
    · have tail : 0 < weight (liftWeight fun x => if x = e then 1 else 0) rest := by
        cases c with
        | live f =>
          have hf : f ≠ e := fun hf => hc (by rw [hf])
          simpa [weight, liftWeight, hf] using h
        | empty => simpa [weight, liftWeight] using h
        | deleted => simpa [weight, liftWeight] using h
      obtain ⟨j, hj⟩ := ih tail
      exact ⟨j + 1, by simpa using hj⟩

theorem rehash_finds_present (b : Banks) (maxGroups want i : Nat) (e : Entry)
    (hc : 0 ≤ b.cursor) (whole : b.src.slots.length % 16 = 0) (behind : Behind b)
    (hsrc : CounterConsistent b.src) (hdst : CounterConsistent b.dst)
    (wsrc : WellPlaced b.src.slots) (wdst : WellPlaced b.dst.slots)
    (present : b.src.slots[i]? = some (.live e) ∨ b.dst.slots[i]? = some (.live e)) :
    ∃ d j, locate (rehash b maxGroups want) e.key e.hash = some (d, j) ∧
      keyAt (bankOf (rehash b maxGroups want) d).slots e.key e.hash j = true := by
  obtain ⟨ht, _, _, _, ws, wd, shape⟩ :=
    rehash_invariant b maxGroups want (fun x => if x = e then 1 else 0) hc whole behind hsrc hdst wsrc wdst
  have before : 0 < total (fun x => if x = e then 1 else 0) b.src.slots b.dst.slots := by
    unfold total
    rcases present with hp | hp
    · have := present_weight _ i e hp; omega
    · have := present_weight _ i e hp; omega
  rw [← ht] at before
  unfold total at before
  generalize rehash b maxGroups want = r at ws wd shape before ⊢
  by_cases hs : 0 < weight (liftWeight fun x => if x = e then 1 else 0) r.src.slots
  · obtain ⟨j, hj⟩ := weight_pos_present _ e hs
    exact locate_finds_present r j e ws wd (Or.inl hj)
  · have hd : 0 < weight (liftWeight fun x => if x = e then 1 else 0) r.dst.slots := by omega
    obtain ⟨j, hj⟩ := weight_pos_present _ e hd
    rcases shape with ⟨hcur, _, _⟩ | ⟨_, _, hnil⟩
    · exact locate_finds_present r j e ws wd (Or.inr ⟨hcur, hj⟩)
    · rw [hnil] at hj
      simp at hj

theorem migration_finds_present (b : Banks) (g limit i : Nat) (e : Entry) (hc : 0 ≤ b.cursor)
    (wsrc : WellPlaced b.src.slots) (wdst : WellPlaced b.dst.slots)
    (present : b.src.slots[i]? = some (.live e) ∨ b.dst.slots[i]? = some (.live e)) :
    ∃ d j, locate (migrateGroup b g limit).1 e.key e.hash = some (d, j) ∧
      keyAt (bankOf (migrateGroup b g limit).1 d).slots e.key e.hash j = true := by
  have ht := migrateSlots_preserves_total (groupIndices g) limit 0 b (fun x => if x = e then 1 else 0)
  obtain ⟨hcur, _, _⟩ := migrateSlots_shape (groupIndices g) limit 0 b
  obtain ⟨ws, wd⟩ := migrateGroup_preserves_wellplaced b g limit wsrc wdst
  have before : 0 < total (fun x => if x = e then 1 else 0) b.src.slots b.dst.slots := by
    unfold total
    rcases present with hp | hp
    · have := present_weight _ i e hp; omega
    · have := present_weight _ i e hp; omega
  rw [← ht] at before
  unfold total at before
  unfold migrateGroup at ws wd ⊢
  generalize (migrateSlots (groupIndices g) limit b 0).1 = r at ws wd hcur before ⊢
  by_cases hs : 0 < weight (liftWeight fun x => if x = e then 1 else 0) r.src.slots
  · obtain ⟨j, hj⟩ := weight_pos_present _ e hs
    exact locate_finds_present r j e ws wd (Or.inl hj)
  · obtain ⟨j, hj⟩ := weight_pos_present r.dst.slots e (by omega)
    exact locate_finds_present r j e ws wd (Or.inr ⟨by rw [hcur]; exact hc, hj⟩)

theorem entryAt_slot (b : Banks) (d : Bool) (i : Nat) (old : Entry) (h : entryAt b d i = some old) :
    (bankOf b d).slots[i]? = some (.live old) := by
  unfold entryAt at h
  split at h
  next e he =>
    simp only [Option.some.injEq] at h
    subst h
    exact he
  next => simp at h

theorem upsert_cases (b : Banks) (key hash : Nat) (fresh : Entry) (change : Entry → Entry)
    (b' : Banks) (r : Option Entry) (h : upsert b key hash fresh change = some (b', r)) :
    (∃ d i old, r = some old ∧ (bankOf b d).slots[i]? = some (.live old) ∧
      b' = writeAt b d i (.live (change old))) ∨
    (r = none ∧ 0 ≤ b.cursor ∧ ∃ j, claimIndex b.dst.slots fresh.hash = some j ∧
      b' = {b with dst := place b.dst j fresh}) ∨
    (r = none ∧ b.cursor < 0 ∧ ∃ j, claimIndex b.src.slots fresh.hash = some j ∧
      b' = {b with src := place b.src j fresh}) := by
  unfold upsert at h
  split at h
  next d i _ =>
    split at h
    next old ho =>
      simp only [Option.some.injEq, Prod.mk.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      exact Or.inl ⟨d, i, old, rfl, entryAt_slot b d i old ho, rfl⟩
    next => simp at h
  next =>
    split at h
    next hc =>
      obtain ⟨j, hj, he⟩ := Option.map_eq_some_iff.mp h
      simp only [Prod.mk.injEq] at he
      obtain ⟨rfl, rfl⟩ := he
      exact Or.inr (Or.inl ⟨rfl, hc, j, hj, rfl⟩)
    next hc =>
      obtain ⟨j, hj, he⟩ := Option.map_eq_some_iff.mp h
      simp only [Prod.mk.injEq] at he
      obtain ⟨rfl, rfl⟩ := he
      exact Or.inr (Or.inr ⟨rfl, by omega, j, hj, rfl⟩)

theorem upsert_preserves_wellplaced (b : Banks) (key hash : Nat) (fresh : Entry) (change : Entry → Entry)
    (b' : Banks) (r : Option Entry) (hch : ∀ x, (change x).hash = x.hash)
    (wsrc : WellPlaced b.src.slots) (wdst : WellPlaced b.dst.slots)
    (h : upsert b key hash fresh change = some (b', r)) :
    WellPlaced b'.src.slots ∧ WellPlaced b'.dst.slots := by
  rcases upsert_cases b key hash fresh change b' r h with ⟨d, i, old, _, hs, rfl⟩ | ⟨_, _, j, hj, rfl⟩ | ⟨_, _, j, hj, rfl⟩
  · cases d
    · exact ⟨update_preserves_wellplaced _ i old _ hs (hch old) wsrc, wdst⟩
    · exact ⟨wsrc, update_preserves_wellplaced _ i old _ hs (hch old) wdst⟩
  · exact ⟨wsrc, claim_preserves_wellplaced _ fresh j hj wdst⟩
  · exact ⟨claim_preserves_wellplaced _ fresh j hj wsrc, wdst⟩

theorem upsert_preserves_behind (b : Banks) (key hash : Nat) (fresh : Entry) (change : Entry → Entry)
    (b' : Banks) (r : Option Entry) (behind : Behind b)
    (h : upsert b key hash fresh change = some (b', r)) : Behind b' := by
  rcases upsert_cases b key hash fresh change b' r h with ⟨d, i, old, _, hs, rfl⟩ | ⟨_, _, j, hj, rfl⟩ | ⟨_, hc, j, hj, rfl⟩
  · cases d
    · intro g hg
      exact groupLive_put_away b.src _ i g _ old rfl hs (behind g hg)
    · exact behind
  · exact behind
  · intro g hg
    simp only at hg
    omega

theorem free_live_weight (xs : List Cell) (j : Nat) (e : Entry) (f : Cell → Nat)
    (hf : freeAt xs j = true) (hz : f .empty = 0) (hd : f .deleted = 0) :
    weight f (put xs j (.live e)) = weight f xs + f (.live e) := by
  cases hc : xs[j]? with
  | none => simp [freeAt, hc] at hf
  | some c =>
    have hw := put_weight xs j c (.live e) f hc
    cases c with
    | live v => simp [freeAt, hc] at hf
    | empty => rw [hz] at hw; omega
    | deleted => rw [hd] at hw; omega

theorem place_consistent (t : Table) (j : Nat) (e : Entry) (hf : freeAt t.slots j = true)
    (h : CounterConsistent t) : CounterConsistent (place t j e) := by
  have hw := free_live_weight t.slots j e liveWeight hf rfl rfl
  unfold CounterConsistent at *
  simp only [place, hw, liveWeight]
  omega

theorem update_consistent (t : Table) (i : Nat) (old new : Entry) (hs : t.slots[i]? = some (.live old))
    (h : CounterConsistent t) : CounterConsistent {t with slots := put t.slots i (.live new)} := by
  have hw := put_weight t.slots i (.live old) (.live new) liveWeight hs
  unfold CounterConsistent at *
  simp only [liveWeight] at hw
  simp only
  omega

theorem upsert_preserves_consistent (b : Banks) (key hash : Nat) (fresh : Entry) (change : Entry → Entry)
    (b' : Banks) (r : Option Entry) (hsrc : CounterConsistent b.src) (hdst : CounterConsistent b.dst)
    (h : upsert b key hash fresh change = some (b', r)) :
    CounterConsistent b'.src ∧ CounterConsistent b'.dst := by
  rcases upsert_cases b key hash fresh change b' r h with ⟨d, i, old, _, hs, rfl⟩ | ⟨_, _, j, hj, rfl⟩ | ⟨_, _, j, hj, rfl⟩
  · cases d
    · exact ⟨update_consistent b.src i old _ hs hsrc, hdst⟩
    · exact ⟨hsrc, update_consistent b.dst i old _ hs hdst⟩
  · exact ⟨hsrc, place_consistent b.dst j fresh (claim_is_free _ _ _ hj) hdst⟩
  · exact ⟨place_consistent b.src j fresh (claim_is_free _ _ _ hj) hsrc, hdst⟩

theorem upsert_total (b : Banks) (key hash : Nat) (fresh : Entry) (change : Entry → Entry)
    (b' : Banks) (r : Option Entry) (f : Entry → Nat)
    (h : upsert b key hash fresh change = some (b', r)) :
    (r = none → total f b'.src.slots b'.dst.slots = total f b.src.slots b.dst.slots + f fresh) ∧
    (∀ old, r = some old →
      total f b'.src.slots b'.dst.slots + f old = total f b.src.slots b.dst.slots + f (change old)) := by
  rcases upsert_cases b key hash fresh change b' r h with ⟨d, i, old, rfl, hs, rfl⟩ | ⟨rfl, _, j, hj, rfl⟩ | ⟨rfl, _, j, hj, rfl⟩
  · refine ⟨fun hn => by simp at hn, ?_⟩
    intro o ho
    simp only [Option.some.injEq] at ho
    subst ho
    have hw := put_weight _ i (.live old) (.live (change old)) (liftWeight f) hs
    cases d <;> simp only [total, writeAt, bankOf, liftWeight] at hw ⊢ <;> simp at hw ⊢ <;> omega
  · refine ⟨fun _ => ?_, fun o ho => by simp at ho⟩
    have hw := free_live_weight b.dst.slots j fresh (liftWeight f) (claim_is_free _ _ _ hj) rfl rfl
    simp only [total, place, hw, liftWeight]
    omega
  · refine ⟨fun _ => ?_, fun o ho => by simp at ho⟩
    have hw := free_live_weight b.src.slots j fresh (liftWeight f) (claim_is_free _ _ _ hj) rfl rfl
    simp only [total, place, hw, liftWeight]
    omega

theorem upsert_shape (b : Banks) (key hash : Nat) (fresh : Entry) (change : Entry → Entry)
    (b' : Banks) (r : Option Entry) (h : upsert b key hash fresh change = some (b', r)) :
    b'.cursor = b.cursor ∧ b'.src.slots.length = b.src.slots.length ∧
      b'.dst.slots.length = b.dst.slots.length := by
  rcases upsert_cases b key hash fresh change b' r h with ⟨d, i, old, _, hs, rfl⟩ | ⟨_, _, j, hj, rfl⟩ | ⟨_, _, j, hj, rfl⟩
  · cases d <;> simp [writeAt, put_length]
  · simp [place, put_length]
  · simp [place, put_length]

theorem erase_shape (t : Table) (i : Nat) :
    ∃ c, (c = .empty ∨ c = .deleted) ∧ (erase t i).slots = put t.slots i c ∧ (erase t i).live = t.live - 1 := by
  by_cases hem : ((List.range 16).any fun k => t.slots[i / 16 * 16 + k]? == some .empty) = true
  · exact ⟨.empty, Or.inl rfl, by simp [erase, hem], by simp [erase]⟩
  · exact ⟨.deleted, Or.inr rfl, by simp [erase, hem], by simp [erase]⟩

theorem remove_cases (b : Banks) (key hash : Nat) :
    ((remove b key hash).2 = none ∧ (remove b key hash).1 = b) ∨
    (∃ d i old, (remove b key hash).2 = some old ∧ (bankOf b d).slots[i]? = some (.live old) ∧
      (remove b key hash).1 = if d then {b with dst := erase b.dst i} else {b with src := erase b.src i}) := by
  unfold remove
  split
  next d i _ =>
    split
    next old ho =>
      right
      refine ⟨d, i, old, ?_, entryAt_slot b d i old ho, ?_⟩ <;> cases d <;> rfl
    next => exact Or.inl ⟨rfl, rfl⟩
  next => exact Or.inl ⟨rfl, rfl⟩

theorem remove_preserves_wellplaced (b : Banks) (key hash : Nat)
    (wsrc : WellPlaced b.src.slots) (wdst : WellPlaced b.dst.slots) :
    WellPlaced (remove b key hash).1.src.slots ∧ WellPlaced (remove b key hash).1.dst.slots := by
  rcases remove_cases b key hash with ⟨_, he⟩ | ⟨d, i, old, _, hs, he⟩
  · rw [he]; exact ⟨wsrc, wdst⟩
  · rw [he]
    cases d
    · exact ⟨erase_preserves_wellplaced b.src i wsrc, wdst⟩
    · exact ⟨wsrc, erase_preserves_wellplaced b.dst i wdst⟩

theorem remove_preserves_behind (b : Banks) (key hash : Nat) (behind : Behind b) :
    Behind (remove b key hash).1 := by
  rcases remove_cases b key hash with ⟨_, he⟩ | ⟨d, i, old, _, hs, he⟩
  · rw [he]; exact behind
  · rw [he]
    cases d
    · intro g hg
      obtain ⟨c, hc, hsl, _⟩ := erase_shape b.src i
      exact groupLive_put_nonlive b.src _ i g c hsl (by rcases hc with rfl | rfl <;> simp) (behind g hg)
    · exact behind

theorem erase_consistent (t : Table) (i : Nat) (old : Entry) (hs : t.slots[i]? = some (.live old))
    (h : CounterConsistent t) : CounterConsistent (erase t i) := by
  obtain ⟨c, hc, hsl, hlive⟩ := erase_shape t i
  have hw := put_weight t.slots i (.live old) c liveWeight hs
  unfold CounterConsistent at *
  rw [hsl, hlive]
  rcases hc with rfl | rfl <;> simp only [liveWeight] at hw <;> omega

theorem remove_preserves_consistent (b : Banks) (key hash : Nat)
    (hsrc : CounterConsistent b.src) (hdst : CounterConsistent b.dst) :
    CounterConsistent (remove b key hash).1.src ∧ CounterConsistent (remove b key hash).1.dst := by
  rcases remove_cases b key hash with ⟨_, he⟩ | ⟨d, i, old, _, hs, he⟩
  · rw [he]; exact ⟨hsrc, hdst⟩
  · rw [he]
    cases d
    · exact ⟨erase_consistent b.src i old hs hsrc, hdst⟩
    · exact ⟨hsrc, erase_consistent b.dst i old hs hdst⟩

theorem remove_total (b : Banks) (key hash : Nat) (f : Entry → Nat) :
    ((remove b key hash).2 = none → (remove b key hash).1 = b) ∧
    (∀ old, (remove b key hash).2 = some old →
      total f (remove b key hash).1.src.slots (remove b key hash).1.dst.slots + f old =
        total f b.src.slots b.dst.slots) := by
  rcases remove_cases b key hash with ⟨hn, he⟩ | ⟨d, i, old, ho, hs, he⟩
  · exact ⟨fun _ => he, fun o h => by rw [hn] at h; simp at h⟩
  · refine ⟨fun h => by rw [ho] at h; simp at h, ?_⟩
    intro o h
    rw [ho] at h
    simp only [Option.some.injEq] at h
    subst h
    rw [he]
    cases d
    · obtain ⟨c, hc, hsl, _⟩ := erase_shape b.src i
      have hw := put_weight b.src.slots i (.live old) c (liftWeight f) hs
      simp only [Bool.false_eq_true, ↓reduceIte, total]
      rw [hsl]
      rcases hc with rfl | rfl <;> simp only [liftWeight] at hw <;> omega
    · obtain ⟨c, hc, hsl, _⟩ := erase_shape b.dst i
      have hw := put_weight b.dst.slots i (.live old) c (liftWeight f) hs
      simp only [↓reduceIte, total]
      rw [hsl]
      rcases hc with rfl | rfl <;> simp only [liftWeight] at hw <;> omega

theorem remove_shape (b : Banks) (key hash : Nat) :
    (remove b key hash).1.cursor = b.cursor ∧
      (remove b key hash).1.src.slots.length = b.src.slots.length ∧
      (remove b key hash).1.dst.slots.length = b.dst.slots.length := by
  rcases remove_cases b key hash with ⟨_, he⟩ | ⟨d, i, old, _, hs, he⟩
  · rw [he]; exact ⟨rfl, rfl, rfl⟩
  · rw [he]
    cases d
    · obtain ⟨c, _, hsl, _⟩ := erase_shape b.src i
      simp [hsl, put_length]
    · obtain ⟨c, _, hsl, _⟩ := erase_shape b.dst i
      simp [hsl, put_length]

theorem free_of_room (xs : List Cell) (room : weight liveWeight xs < xs.length) :
    ∃ i, i < xs.length ∧ freeAt xs i = true := by
  induction xs with
  | nil => simp [weight] at room
  | cons c rest ih =>
    cases c with
    | live e =>
      obtain ⟨i, hi, hf⟩ := ih (by simp [weight, liveWeight] at room; omega)
      exact ⟨i + 1, by simp; omega, by simpa [freeAt] using hf⟩
    | empty => exact ⟨0, by simp, by simp [freeAt]⟩
    | deleted => exact ⟨0, by simp, by simp [freeAt]⟩

theorem claim_some_of_room (xs : List Cell) (hash : Nat) (whole : xs.length % 16 = 0)
    (room : weight liveWeight xs < xs.length) : ∃ j, claimIndex xs hash = some j := by
  obtain ⟨i, hi, hf⟩ := free_of_room xs room
  exact claim_some_of_free xs hash i whole hi hf

end Storage
