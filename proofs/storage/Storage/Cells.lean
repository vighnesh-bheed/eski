import Storage.Placement

namespace Storage

def tableBytes (cap : Nat) : Nat := ((cap + 63) / 64 * 64 + cap * 18 + 4095) / 4096 * 4096

def keyBytes (c : KeyCell) : Nat :=
  if c.timed then (if c.len + 8 ≤ 4096 then c.len + 8 else c.len + 16)
  else if c.len ≤ 7 then 0 else if c.len ≤ 4096 then c.len else c.len + 8

def setDeadline (c : KeyCell) (deadline : Nat) : KeyCell :=
  if deadline = 0 then {c with timed := false, deadline := 0} else {c with timed := true, deadline := deadline}

def freshCell (len deadline : Nat) : KeyCell := setDeadline ⟨len, false, 0⟩ deadline

def timedOf (e : Entry) : Nat := if e.cell.timed then 1 else 0

def cellOf (e : Entry) : Nat := keyBytes e.cell

def updateEntry (old : Entry) (value deadline clock : Nat) : Entry :=
  {old with value := value, clock := clock, cell := setDeadline old.cell deadline}

structure Keyspace where
  banks : Banks
  expires : Int
  cells : Int
  tables : Int
  deriving Repr, Inhabited

def Exact (k : Keyspace) : Prop :=
  k.expires = (total timedOf k.banks.src.slots k.banks.dst.slots : Int) ∧
  k.cells = (total cellOf k.banks.src.slots k.banks.dst.slots : Int) ∧
  k.tables = (tableBytes k.banks.src.slots.length + tableBytes k.banks.dst.slots.length : Int)

def Sound (k : Keyspace) : Prop :=
  Exact k ∧ WellPlaced k.banks.src.slots ∧ WellPlaced k.banks.dst.slots ∧
  CounterConsistent k.banks.src ∧ CounterConsistent k.banks.dst ∧ Behind k.banks ∧
  k.banks.src.slots.length % 16 = 0 ∧ k.banks.dst.slots.length % 16 = 0 ∧
  (k.banks.cursor < 0 → k.banks.dst.slots = [])

def ksReset (cap : Nat) : Keyspace := ⟨⟨emptyTable cap, emptyTable 0, -1⟩, 0, 0, tableBytes cap⟩

def ksUpsert (k : Keyspace) (key hash value deadline clock len : Nat) : Option (Keyspace × Bool) :=
  let fresh : Entry := ⟨key, hash, value, clock, freshCell len deadline⟩
  let change := fun old => updateEntry old value deadline clock
  match upsert k.banks key hash fresh change with
  | none => none
  | some (b, none) => some (⟨b, k.expires + timedOf fresh, k.cells + cellOf fresh, k.tables⟩, true)
  | some (b, some old) =>
    some (⟨b, k.expires + timedOf (change old) - timedOf old, k.cells + cellOf (change old) - cellOf old,
      k.tables⟩, false)

def ksRemove (k : Keyspace) (key hash : Nat) : Keyspace × Bool :=
  match remove k.banks key hash with
  | (b, none) => (⟨b, k.expires, k.cells, k.tables⟩, false)
  | (b, some old) => (⟨b, k.expires - timedOf old, k.cells - cellOf old, k.tables⟩, true)

def ksStart (k : Keyspace) (cap : Nat) : Keyspace :=
  ⟨⟨k.banks.src, emptyTable cap, 0⟩, k.expires, k.cells, k.tables + tableBytes cap⟩

def ksMigrate (k : Keyspace) (groups want : Nat) : Keyspace :=
  if k.banks.cursor < 0 then k else
    let b := rehash k.banks groups want
    if b.cursor < 0 then ⟨b, k.expires, k.cells, k.tables - tableBytes k.banks.src.slots.length⟩
    else ⟨b, k.expires, k.cells, k.tables⟩

theorem table_bytes_bounds (cap : Nat) :
    cap * 19 ≤ tableBytes cap ∧ tableBytes cap < cap * 19 + 4096 + 64 ∧ tableBytes cap % 4096 = 0 := by
  unfold tableBytes
  omega

theorem timed_cell_bytes (c : KeyCell) (h : c.timed = true) :
    keyBytes c = c.len + 8 + (if c.len + 8 ≤ 4096 then 0 else 8) := by
  unfold keyBytes
  simp only [h, ↓reduceIte]
  split <;> omega

theorem deadline_in_cell (c : KeyCell) (deadline : Nat) :
    (setDeadline c deadline).len = c.len ∧ ((setDeadline c deadline).timed = true ↔ deadline ≠ 0) ∧
      (setDeadline c deadline).deadline = deadline := by
  unfold setDeadline
  split <;> simp_all

theorem replicate_weight (n : Nat) (f : Entry → Nat) :
    weight (liftWeight f) (List.replicate n .empty) = 0 := by
  induction n with
  | zero => rfl
  | succ n ih => simp [List.replicate, weight, liftWeight, ih]

theorem reset_sound (cap : Nat) (whole : cap % 16 = 0) : Sound (ksReset cap) := by
  refine ⟨⟨?_, ?_, ?_⟩, empty_wellplaced cap, empty_wellplaced 0, ?_, ?_, ?_, ?_, ?_, fun _ => rfl⟩
  · simp [ksReset, total, replicate_weight, emptyTable, weight]
  · simp [ksReset, total, replicate_weight, emptyTable, weight]
  · simp [ksReset, emptyTable, tableBytes]
  · simp only [CounterConsistent, ksReset, emptyTable]
    have := replicate_weight cap (fun _ => 1)
    have e : liftWeight (fun _ => 1) = liveWeight := by funext c; cases c <;> rfl
    rw [e] at this
    rw [this]
    rfl
  · simp [CounterConsistent, ksReset, emptyTable, weight]
  · intro g hg
    simp [ksReset] at hg
  · simpa [ksReset, emptyTable] using whole
  · simp [ksReset, emptyTable]

theorem upsert_sound (k k' : Keyspace) (key hash value deadline clock len : Nat) (created : Bool)
    (h : Sound k) (hr : ksUpsert k key hash value deadline clock len = some (k', created)) : Sound k' := by
  obtain ⟨⟨he, hcl, htb⟩, ws, wd, cs, cd, behind, ls, ld, idle⟩ := h
  unfold ksUpsert at hr
  dsimp only at hr
  split at hr
  next => simp at hr
  next b hb =>
    simp only [Option.some.injEq, Prod.mk.injEq] at hr
    obtain ⟨rfl, -⟩ := hr
    obtain ⟨tn, -⟩ := upsert_total _ _ _ _ _ _ _ timedOf hb
    obtain ⟨cn, -⟩ := upsert_total _ _ _ _ _ _ _ cellOf hb
    obtain ⟨w1, w2⟩ := upsert_preserves_wellplaced k.banks key hash _ (fun old => updateEntry old value deadline clock) _ _ (fun _ => rfl) ws wd hb
    obtain ⟨c1, c2⟩ := upsert_preserves_consistent _ _ _ _ _ _ _ cs cd hb
    obtain ⟨hcur, hl1, hl2⟩ := upsert_shape _ _ _ _ _ _ _ hb
    refine ⟨⟨?_, ?_, ?_⟩, w1, w2, c1, c2, upsert_preserves_behind _ _ _ _ _ _ _ behind hb,
      by rw [hl1]; exact ls, by rw [hl2]; exact ld, ?_⟩
    · simp only
      rw [tn rfl, he]
      push_cast
      rfl
    · simp only
      rw [cn rfl, hcl]
      push_cast
      rfl
    · simp only
      rw [hl1, hl2, htb]
    · intro hneg
      rw [hcur] at hneg
      have hnil := idle hneg
      exact List.eq_nil_of_length_eq_zero (by rw [hl2, hnil]; rfl)
  next b old hb =>
    simp only [Option.some.injEq, Prod.mk.injEq] at hr
    obtain ⟨rfl, -⟩ := hr
    obtain ⟨-, tn⟩ := upsert_total _ _ _ _ _ _ _ timedOf hb
    obtain ⟨-, cn⟩ := upsert_total _ _ _ _ _ _ _ cellOf hb
    have tn' := tn old rfl
    have cn' := cn old rfl
    obtain ⟨w1, w2⟩ := upsert_preserves_wellplaced k.banks key hash _ (fun old => updateEntry old value deadline clock) _ _ (fun _ => rfl) ws wd hb
    obtain ⟨c1, c2⟩ := upsert_preserves_consistent _ _ _ _ _ _ _ cs cd hb
    obtain ⟨hcur, hl1, hl2⟩ := upsert_shape _ _ _ _ _ _ _ hb
    refine ⟨⟨?_, ?_, ?_⟩, w1, w2, c1, c2, upsert_preserves_behind _ _ _ _ _ _ _ behind hb,
      by rw [hl1]; exact ls, by rw [hl2]; exact ld, ?_⟩
    · simp only
      rw [he]
      omega
    · simp only
      rw [hcl]
      omega
    · simp only
      rw [hl1, hl2, htb]
    · intro hneg
      rw [hcur] at hneg
      have hnil := idle hneg
      exact List.eq_nil_of_length_eq_zero (by rw [hl2, hnil]; rfl)

theorem remove_sound (k : Keyspace) (key hash : Nat) (h : Sound k) : Sound (ksRemove k key hash).1 := by
  obtain ⟨⟨he, hcl, htb⟩, ws, wd, cs, cd, behind, ls, ld, idle⟩ := h
  obtain ⟨hn, hs⟩ := remove_total k.banks key hash timedOf
  obtain ⟨-, hc⟩ := remove_total k.banks key hash cellOf
  obtain ⟨w1, w2⟩ := remove_preserves_wellplaced k.banks key hash ws wd
  obtain ⟨c1, c2⟩ := remove_preserves_consistent k.banks key hash cs cd
  obtain ⟨hcur, hl1, hl2⟩ := remove_shape k.banks key hash
  have hb := remove_preserves_behind k.banks key hash behind
  unfold ksRemove
  generalize hr : remove k.banks key hash = r at hn hs hc w1 w2 c1 c2 hcur hl1 hl2 hb
  obtain ⟨b, o⟩ := r
  cases o with
  | none =>
    have hbk := hn rfl
    simp only at hbk
    subst hbk
    exact ⟨⟨he, hcl, htb⟩, ws, wd, cs, cd, behind, ls, ld, idle⟩
  | some old =>
    have t1 := hs old rfl
    have t2 := hc old rfl
    simp only at t1 t2 w1 w2 c1 c2 hcur hl1 hl2 hb ⊢
    refine ⟨⟨?_, ?_, ?_⟩, w1, w2, c1, c2, hb, by rw [hl1]; exact ls, by rw [hl2]; exact ld, ?_⟩
    · dsimp only
      rw [he]; omega
    · dsimp only
      rw [hcl]; omega
    · dsimp only
      rw [hl1, hl2, htb]
    · intro hneg
      rw [hcur] at hneg
      have hnil := idle hneg
      exact List.eq_nil_of_length_eq_zero (by rw [hl2, hnil]; rfl)

theorem start_sound (k : Keyspace) (cap : Nat) (h : Sound k) (idle : k.banks.cursor < 0)
    (whole : cap % 16 = 0) : Sound (ksStart k cap) := by
  obtain ⟨⟨he, hcl, htb⟩, ws, wd, cs, cd, behind, ls, ld, empty⟩ := h
  have hnil := empty idle
  refine ⟨⟨?_, ?_, ?_⟩, ws, empty_wellplaced cap, cs, ?_, ?_, ls, by simpa [ksStart, emptyTable] using whole, ?_⟩
  · simp only [ksStart, total, emptyTable, replicate_weight]
    rw [he]
    simp [total, hnil, weight]
  · simp only [ksStart, total, emptyTable, replicate_weight]
    rw [hcl]
    simp [total, hnil, weight]
  · simp only [ksStart, emptyTable, List.length_replicate]
    rw [htb, hnil]
    simp [tableBytes]
  · simp only [CounterConsistent, ksStart, emptyTable]
    have := replicate_weight cap (fun _ => 1)
    have e : liftWeight (fun _ => 1) = liveWeight := by funext c; cases c <;> rfl
    rw [e] at this
    rw [this]
    rfl
  · intro g hg
    simp [ksStart] at hg
  · intro hneg
    simp [ksStart] at hneg

theorem migrate_sound (k : Keyspace) (groups want : Nat) (h : Sound k) : Sound (ksMigrate k groups want) := by
  unfold ksMigrate
  split
  · exact h
  next hc =>
    obtain ⟨⟨he, hcl, htb⟩, ws, wd, cs, cd, behind, ls, ld, _⟩ := h
    obtain ⟨t1, b1, c1, c2, w1, w2, shape⟩ :=
      rehash_invariant k.banks groups want timedOf (by omega) ls behind cs cd ws wd
    have t2 := (rehash_invariant k.banks groups want cellOf (by omega) ls behind cs cd ws wd).1
    rcases shape with ⟨hcur, hl1, hl2⟩ | ⟨hcur, hl1, hnil⟩
    · simp only [show ¬(rehash k.banks groups want).cursor < 0 by omega, ↓reduceIte]
      refine ⟨⟨?_, ?_, ?_⟩, w1, w2, c1, c2, b1, by rw [hl1]; exact ls, by rw [hl2]; exact ld, ?_⟩
      rotate_left 3
      · intro hneg
        dsimp only at hneg
        omega
      · rw [he, ← t1]
      · rw [hcl, ← t2]
      · simp only
        rw [htb, hl1, hl2]
    · simp only [show (rehash k.banks groups want).cursor < 0 by omega, ↓reduceIte]
      refine ⟨⟨?_, ?_, ?_⟩, w1, w2, c1, c2, b1, by rw [hl1]; exact ld, by rw [hnil]; rfl, fun _ => hnil⟩
      · rw [he, ← t1]
      · rw [hcl, ← t2]
      · simp only
        rw [htb, hl1, hnil]
        simp only [List.length_nil, tableBytes]
        omega

theorem sound_finds_present (k : Keyspace) (i : Nat) (e : Entry) (h : Sound k)
    (present : k.banks.src.slots[i]? = some (.live e) ∨ k.banks.dst.slots[i]? = some (.live e)) :
    ∃ d j, locate k.banks e.key e.hash = some (d, j) ∧ keyAt (bankOf k.banks d).slots e.key e.hash j = true := by
  obtain ⟨_, ws, wd, _, _, _, _, _, idle⟩ := h
  apply locate_finds_present k.banks i e ws wd
  rcases present with hs | hd
  · exact Or.inl hs
  · by_cases hc : k.banks.cursor < 0
    · rw [idle hc] at hd
      simp at hd
    · exact Or.inr ⟨by omega, hd⟩

end Storage
