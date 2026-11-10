import Storage.Lanes

namespace Storage

inductive Role where
  | slab
  | heap
  deriving DecidableEq, Repr, Inhabited

inductive KeyForm where
  | inline
  | slab
  | heap
  deriving DecidableEq, Repr, Inhabited

def heapTableMax : Nat := 1024

def rehashSyncCap : Nat := 1024

def finishBudget : Nat := 9223372036854775807

def tableBytes (cap : Nat) : Nat := ((cap + 63) / 64 * 64 + cap * 18 + 4095) / 4096 * 4096

def heapTableBytes (cap : Nat) : Nat := (cap + 63) / 64 * 64 + cap * 18

def heapTable : Role → Nat → Bool
  | .slab, _ => false
  | .heap, cap => decide (cap ≤ heapTableMax)

def tablesOf (r : Role) (cap : Nat) : Nat := if heapTable r cap then heapTableBytes cap else tableBytes cap

def mappedOf (r : Role) (cap : Nat) : Nat := if heapTable r cap then 0 else tableBytes cap

def keyBytesR : Role → KeyCell → Nat
  | .slab, c => if c.timed then (if c.len + 8 ≤ 4096 then c.len + 8 else c.len + 16)
    else if c.len ≤ 7 then 0 else if c.len ≤ 4096 then c.len else c.len + 8
  | .heap, c => if c.timed then c.len + 16 else if c.len ≤ 7 then 0 else c.len + 8

def keyBytes (c : KeyCell) : Nat := keyBytesR .slab c

def keyForm : Role → KeyCell → KeyForm
  | .slab, c => if c.timed then (if c.len + 8 ≤ 4096 then .slab else .heap)
    else if c.len ≤ 7 then .inline else if c.len ≤ 4096 then .slab else .heap
  | .heap, c => if c.timed then .heap else if c.len ≤ 7 then .inline else .heap

def formBytes : KeyForm → KeyCell → Nat
  | .inline, _ => 0
  | .slab, c => c.len + (if c.timed then 8 else 0)
  | .heap, c => c.len + 8 + (if c.timed then 8 else 0)

def setDeadline (c : KeyCell) (deadline : Nat) : KeyCell :=
  if deadline = 0 then {c with timed := false, deadline := 0} else {c with timed := true, deadline := deadline}

def freshCell (len deadline : Nat) : KeyCell := setDeadline ⟨len, false, 0⟩ deadline

def timedOf (e : Entry) : Nat := if e.cell.timed then 1 else 0

def cellOf (r : Role) (e : Entry) : Nat := keyBytesR r e.cell

def updateEntry (old : Entry) (value deadline clock : Nat) : Entry :=
  {old with value := value, clock := clock, cell := setDeadline old.cell deadline}

def shortTableBytes (lanes : Nat) : Nat := 16 + lanes * 18

def isShort (t : Table) : Bool := decide (t.lanes < t.slots.length)

def tableCost (r : Role) (t : Table) : Nat := if isShort t then shortTableBytes t.lanes else tablesOf r t.slots.length

def mappedCost (r : Role) (t : Table) : Nat := if isShort t then 0 else mappedOf r t.slots.length

def ladderLanes : Option Nat → Nat
  | none => shortFirst
  | some lanes => lanes * 2

def allocTable (r : Role) (compact : Bool) (src : Option Nat) (cap : Nat) : Table :=
  match r with
  | .heap =>
    if compact && cap == 16 && decide (ladderLanes src < shortFull) then shortTable (ladderLanes src)
    else emptyTable cap
  | .slab => emptyTable cap

def presentLanes (t : Table) : Option Nat := if t.slots.length = 0 then none else some t.lanes

def ShapeOk (r : Role) (t : Table) : Prop :=
  t.lanes = t.slots.length ∨ (r = .heap ∧ t.slots.length = 16 ∧ t.lanes < shortFull)

structure Keyspace where
  banks : Banks
  role : Role
  compact : Bool
  expires : Int
  cells : Int
  tables : Int
  mapped : Int
  deriving Repr, Inhabited

def Exact (k : Keyspace) : Prop :=
  k.expires = (total timedOf k.banks.src.slots k.banks.dst.slots : Int) ∧
  k.cells = (total (cellOf k.role) k.banks.src.slots k.banks.dst.slots : Int) ∧
  k.tables = (tableCost k.role k.banks.src + tableCost k.role k.banks.dst : Int) ∧
  k.mapped = (mappedCost k.role k.banks.src + mappedCost k.role k.banks.dst : Int)

def Sound (k : Keyspace) : Prop :=
  Exact k ∧ WellPlaced k.banks.src.slots ∧ WellPlaced k.banks.dst.slots ∧
  CounterConsistent k.banks.src ∧ CounterConsistent k.banks.dst ∧ Behind k.banks ∧
  k.banks.src.slots.length % 16 = 0 ∧ k.banks.dst.slots.length % 16 = 0 ∧
  (k.banks.cursor < 0 → k.banks.dst.slots = []) ∧ ShapeOk k.role k.banks.src ∧ ShapeOk k.role k.banks.dst

def ksReset (r : Role) (compact : Bool) (cap : Nat) : Keyspace :=
  ⟨⟨allocTable r compact none cap, emptyTable 0, -1⟩, r, compact, 0, 0,
    tableCost r (allocTable r compact none cap), mappedCost r (allocTable r compact none cap)⟩

def ksUpsert (k : Keyspace) (key hash value deadline clock len : Nat) : Option (Keyspace × Bool) :=
  let fresh : Entry := ⟨key, hash, value, clock, freshCell len deadline⟩
  let change := fun old => updateEntry old value deadline clock
  match upsert k.banks key hash fresh change with
  | none => none
  | some (b, none) =>
    some ({k with banks := b, expires := k.expires + timedOf fresh, cells := k.cells + cellOf k.role fresh}, true)
  | some (b, some old) =>
    some ({k with
      banks := b
      expires := k.expires + timedOf (change old) - timedOf old
      cells := k.cells + cellOf k.role (change old) - cellOf k.role old}, false)

def ksRemove (k : Keyspace) (key hash : Nat) : Keyspace × Bool :=
  match remove k.banks key hash with
  | (b, none) => ({k with banks := b}, false)
  | (b, some old) => ({k with banks := b, expires := k.expires - timedOf old, cells := k.cells - cellOf k.role old}, true)

def ksStart (k : Keyspace) (cap : Nat) : Keyspace :=
  {k with
    banks := ⟨k.banks.src, allocTable k.role k.compact (presentLanes k.banks.src) cap, 0⟩
    tables := k.tables + tableCost k.role (allocTable k.role k.compact (presentLanes k.banks.src) cap)
    mapped := k.mapped + mappedCost k.role (allocTable k.role k.compact (presentLanes k.banks.src) cap)}

def ksMigrate (k : Keyspace) (groups want : Nat) : Keyspace :=
  if k.banks.cursor < 0 then k else
    let b := rehash k.banks groups want
    if b.cursor < 0 then
      {k with
        banks := b
        tables := k.tables - tableCost k.role k.banks.src
        mapped := k.mapped - mappedCost k.role k.banks.src}
    else {k with banks := b}

def ksBegin (k : Keyspace) (cap : Nat) : Keyspace :=
  if k.banks.src.slots.length ≤ rehashSyncCap then ksMigrate (ksStart k cap) finishBudget finishBudget
  else ksStart k cap

def ksMakeRoom (k : Keyspace) : Keyspace :=
  let f := ksMigrate k finishBudget finishBudget
  if f.banks.cursor < 0 then
    ksBegin f (if f.banks.src.live > (f.banks.src.slots.length * 7 / 16 : Nat)
      then growCap f.banks.src.slots.length else f.banks.src.slots.length)
  else f

def targetBank (b : Banks) : Table := if 0 ≤ b.cursor then b.dst else b.src

def needsRoom (k : Keyspace) (key hash : Nat) : Bool :=
  match locate k.banks key hash with
  | some _ => false
  | none =>
    (targetBank k.banks).growth == 0 &&
      match claimIndex (targetBank k.banks).slots hash with
      | some i => (targetBank k.banks).slots[i]? == some .empty
      | none => false

def ksInsert (k : Keyspace) (key hash value deadline clock len : Nat) : Option (Keyspace × Bool) :=
  ksUpsert (if needsRoom k key hash then ksMakeRoom k else k) key hash value deadline clock len

def compactable (k : Keyspace) : Bool :=
  k.compact && k.role == .heap && decide (k.banks.cursor < 0) && k.banks.src.slots.length == 16 &&
    k.banks.src.lanes == 16 && k.banks.src.tombs == 0 && k.banks.src.slots.any isLive &&
    (k.banks.src.slots.drop shortKeep).all fun c => !isLive c

def ksCompact (k : Keyspace) : Keyspace :=
  if compactable k then
    {k with
      banks := {k.banks with src := compactTable k.banks.src}
      tables := k.tables - tableCost k.role k.banks.src + tableCost k.role (compactTable k.banks.src)
      mapped := k.mapped - mappedCost k.role k.banks.src + mappedCost k.role (compactTable k.banks.src)}
  else k

theorem table_bytes_bounds (cap : Nat) :
    cap * 19 ≤ tableBytes cap ∧ tableBytes cap < cap * 19 + 4096 + 64 ∧ tableBytes cap % 4096 = 0 := by
  unfold tableBytes
  omega

theorem heap_table_bytes_bounds (cap : Nat) :
    cap * 19 ≤ heapTableBytes cap ∧ heapTableBytes cap < cap * 19 + 64 := by
  unfold heapTableBytes
  omega

theorem mapped_table_rounds_heap (cap : Nat) :
    tableBytes cap = (heapTableBytes cap + 4095) / 4096 * 4096 ∧
      heapTableBytes cap ≤ tableBytes cap ∧ tableBytes cap < heapTableBytes cap + 4096 := by
  unfold tableBytes heapTableBytes
  omega

theorem timed_cell_bytes (c : KeyCell) (h : c.timed = true) :
    keyBytes c = c.len + 8 + (if c.len + 8 ≤ 4096 then 0 else 8) := by
  unfold keyBytes keyBytesR
  simp only [h, ↓reduceIte]
  split <;> omega

theorem key_bytes_by_form (r : Role) (c : KeyCell) : keyBytesR r c = formBytes (keyForm r c) c := by
  cases r <;> cases ht : c.timed <;> simp only [keyBytesR, keyForm, ht] <;> repeat' split
  all_goals simp_all [formBytes]

theorem heap_cell_premium (c : KeyCell) :
    keyBytesR .heap c = keyBytesR .slab c + (if keyForm .slab c = .slab then 8 else 0) := by
  cases ht : c.timed <;> simp only [keyBytesR, keyForm, ht] <;> repeat' split
  all_goals simp_all <;> omega

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

theorem cost_congr (r : Role) (t u : Table) (hl : t.lanes = u.lanes) (hs : t.slots.length = u.slots.length) :
    tableCost r t = tableCost r u ∧ mappedCost r t = mappedCost r u := by
  simp [tableCost, mappedCost, isShort, hl, hs]

theorem absent_bank_free (r : Role) (t : Table) (h : t.slots = []) : tableCost r t = 0 ∧ mappedCost r t = 0 := by
  cases r <;> simp [tableCost, mappedCost, isShort, h, tablesOf, mappedOf, heapTable, heapTableMax, tableBytes,
    heapTableBytes]

theorem alloc_fresh (r : Role) (c : Bool) (s : Option Nat) (cap : Nat) :
    (allocTable r c s cap).slots = List.replicate cap .empty ∧ (allocTable r c s cap).live = 0 ∧
      ShapeOk r (allocTable r c s cap) := by
  cases r
  · simp [allocTable, emptyTable, ShapeOk]
  · simp only [allocTable]
    split
    next h =>
      simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at h
      obtain ⟨⟨-, hc⟩, hl⟩ := h
      subst hc
      exact ⟨rfl, rfl, Or.inr ⟨rfl, by simp [shortTable], hl⟩⟩
    next => simp [emptyTable, ShapeOk]

theorem ladder_tables :
    allocTable .heap true none 16 = shortTable 1 ∧ allocTable .heap true (some 1) 16 = shortTable 2 ∧
      allocTable .heap true (some 2) 16 = shortTable 4 ∧
      (∀ lanes, 4 ≤ lanes → allocTable .heap true (some lanes) 16 = emptyTable 16) ∧
      (∀ s, allocTable .heap false s 16 = emptyTable 16) ∧
      (∀ c s cap, cap ≠ 16 → allocTable .heap c s cap = emptyTable cap) ∧
      tableCost .heap (shortTable 1) = 34 ∧ tableCost .heap (shortTable 2) = 52 ∧
      tableCost .heap (shortTable 4) = 88 ∧ tableCost .heap (emptyTable 16) = 352 ∧
      mappedCost .heap (shortTable 4) = 0 ∧ mappedCost .heap (emptyTable 16) = 0 ∧
      ∀ lanes, lanes < 16 → LaneBound (shortTable lanes) := by
  refine ⟨rfl, rfl, rfl, ?_, ?_, ?_, rfl, rfl, rfl, rfl, rfl, rfl, ?_⟩
  · intro lanes hl
    have hno : ¬lanes * 2 < 8 := by omega
    simp [allocTable, ladderLanes, shortFull, hno]
  · intro s
    simp [allocTable]
  · intro c s cap hc
    simp [allocTable, hc]
  · intro lanes hl
    refine ⟨by simp [shortTable], hl, rfl, by simp [shortTable], ?_⟩
    intro i c hi hne
    simp only [shortTable, List.getElem?_replicate] at hi
    split at hi
    · simp at hi
      exact absurd hi.symm hne
    · simp at hi

theorem short_table_saving (lanes : Nat) (h : lanes < 16) :
    shortTableBytes lanes + 18 * (16 - lanes) + 48 = heapTableBytes 16 ∧ shortTableBytes lanes < heapTableBytes 16 := by
  unfold shortTableBytes heapTableBytes
  omega

theorem exact_table_split (k : Keyspace) (h : Sound k) :
    k.mapped ≤ k.tables ∧ k.tables ≤ k.mapped + (if k.role = .heap then 2 * heapTableBytes heapTableMax else 0) := by
  obtain ⟨⟨-, -, ht, hm⟩, -, -, -, -, -, -, -, -, shs, shd⟩ := h
  rw [ht, hm]
  generalize k.role = r at shs shd
  have split : ∀ t : Table, ShapeOk r t → mappedCost r t ≤ tableCost r t ∧
      tableCost r t ≤ mappedCost r t + (if r = .heap then heapTableBytes heapTableMax else 0) := by
    intro t hs
    by_cases hshort : isShort t = true
    · rcases hs with hl | ⟨hr, -, hl⟩
      · simp [isShort, hl] at hshort
      · subst hr
        simp only [tableCost, mappedCost, hshort, ↓reduceIte, shortTableBytes, heapTableBytes, heapTableMax,
          shortFull] at hl ⊢
        omega
    · simp only [tableCost, mappedCost, Bool.not_eq_true] at hshort ⊢
      simp only [hshort, Bool.false_eq_true, ↓reduceIte]
      cases r
      · simp [tablesOf, mappedOf, heapTable]
      · simp only [tablesOf, mappedOf, heapTable, heapTableMax, heapTableBytes, ↓reduceIte]
        by_cases hc : t.slots.length ≤ 1024
        · simp only [hc, decide_true, ↓reduceIte]
          omega
        · simp only [hc, decide_false, Bool.false_eq_true, ↓reduceIte]
          omega
  obtain ⟨a1, a2⟩ := split _ shs
  obtain ⟨b1, b2⟩ := split _ shd
  cases r <;> simp only [reduceCtorEq, ↓reduceIte] at a2 b2 ⊢ <;> omega

theorem reset_sound (r : Role) (c : Bool) (cap : Nat) (whole : cap % 16 = 0) : Sound (ksReset r c cap) := by
  obtain ⟨hs, hl, hshape⟩ := alloc_fresh r c none cap
  obtain ⟨z1, z2⟩ := absent_bank_free r (emptyTable 0) rfl
  have hlw : liftWeight (fun _ => 1) = liveWeight := by funext c; cases c <;> rfl
  refine ⟨⟨?_, ?_, ?_, ?_⟩, ?_, empty_wellplaced 0, ?_, ?_, ?_, ?_, ?_, fun _ => rfl, hshape, Or.inl rfl⟩
  · simp only [ksReset, total]
    rw [hs, replicate_weight]
    simp [emptyTable, weight]
  · simp only [ksReset, total]
    rw [hs, replicate_weight]
    simp [emptyTable, weight]
  · simp [ksReset, z1]
  · simp [ksReset, z2]
  · simp only [ksReset]
    rw [hs]
    exact empty_wellplaced cap
  · simp only [CounterConsistent, ksReset]
    rw [hl, hs]
    have := replicate_weight cap (fun _ => 1)
    rw [hlw] at this
    rw [this]
    rfl
  · simp [CounterConsistent, ksReset, emptyTable, weight]
  · intro g hg
    simp [ksReset] at hg
  · simp only [ksReset]
    rw [hs]
    simpa using whole
  · simp [ksReset, emptyTable]

theorem upsert_sound (k k' : Keyspace) (key hash value deadline clock len : Nat) (created : Bool)
    (h : Sound k) (hr : ksUpsert k key hash value deadline clock len = some (k', created)) : Sound k' := by
  obtain ⟨⟨he, hcl, htb, hmp⟩, ws, wd, cs, cd, behind, ls, ld, idle, shs, shd⟩ := h
  unfold ksUpsert at hr
  dsimp only at hr
  split at hr
  next => simp at hr
  next b hb =>
    simp only [Option.some.injEq, Prod.mk.injEq] at hr
    obtain ⟨rfl, -⟩ := hr
    obtain ⟨tn, -⟩ := upsert_total _ _ _ _ _ _ _ timedOf hb
    obtain ⟨cn, -⟩ := upsert_total _ _ _ _ _ _ _ (cellOf k.role) hb
    obtain ⟨w1, w2⟩ := upsert_preserves_wellplaced k.banks key hash _ (fun old => updateEntry old value deadline clock) _ _ (fun _ => rfl) ws wd hb
    obtain ⟨c1, c2⟩ := upsert_preserves_consistent _ _ _ _ _ _ _ cs cd hb
    obtain ⟨hcur, hl1, hl2⟩ := upsert_shape _ _ _ _ _ _ _ hb
    obtain ⟨hn1, hn2⟩ := upsert_lanes _ _ _ _ _ _ _ hb
    obtain ⟨s1, m1⟩ := cost_congr k.role _ _ hn1 hl1
    obtain ⟨s2, m2⟩ := cost_congr k.role _ _ hn2 hl2
    refine ⟨⟨?_, ?_, ?_, ?_⟩, w1, w2, c1, c2, upsert_preserves_behind _ _ _ _ _ _ _ behind hb,
      by rw [hl1]; exact ls, by rw [hl2]; exact ld, ?_, ?_, ?_⟩
    · simp only
      rw [tn rfl, he]
      push_cast
      rfl
    · simp only
      rw [cn rfl, hcl]
      push_cast
      rfl
    · simp only
      rw [s1, s2, htb]
    · simp only
      rw [m1, m2, hmp]
    · intro hneg
      rw [hcur] at hneg
      have hnil := idle hneg
      exact List.eq_nil_of_length_eq_zero (by rw [hl2, hnil]; rfl)
    · unfold ShapeOk at shs ⊢
      rw [hn1, hl1]
      exact shs
    · unfold ShapeOk at shd ⊢
      rw [hn2, hl2]
      exact shd
  next b old hb =>
    simp only [Option.some.injEq, Prod.mk.injEq] at hr
    obtain ⟨rfl, -⟩ := hr
    obtain ⟨-, tn⟩ := upsert_total _ _ _ _ _ _ _ timedOf hb
    obtain ⟨-, cn⟩ := upsert_total _ _ _ _ _ _ _ (cellOf k.role) hb
    have tn' := tn old rfl
    have cn' := cn old rfl
    obtain ⟨w1, w2⟩ := upsert_preserves_wellplaced k.banks key hash _ (fun old => updateEntry old value deadline clock) _ _ (fun _ => rfl) ws wd hb
    obtain ⟨c1, c2⟩ := upsert_preserves_consistent _ _ _ _ _ _ _ cs cd hb
    obtain ⟨hcur, hl1, hl2⟩ := upsert_shape _ _ _ _ _ _ _ hb
    obtain ⟨hn1, hn2⟩ := upsert_lanes _ _ _ _ _ _ _ hb
    obtain ⟨s1, m1⟩ := cost_congr k.role _ _ hn1 hl1
    obtain ⟨s2, m2⟩ := cost_congr k.role _ _ hn2 hl2
    refine ⟨⟨?_, ?_, ?_, ?_⟩, w1, w2, c1, c2, upsert_preserves_behind _ _ _ _ _ _ _ behind hb,
      by rw [hl1]; exact ls, by rw [hl2]; exact ld, ?_, ?_, ?_⟩
    · simp only
      rw [he]
      omega
    · simp only
      rw [hcl]
      omega
    · simp only
      rw [s1, s2, htb]
    · simp only
      rw [m1, m2, hmp]
    · intro hneg
      rw [hcur] at hneg
      have hnil := idle hneg
      exact List.eq_nil_of_length_eq_zero (by rw [hl2, hnil]; rfl)
    · unfold ShapeOk at shs ⊢
      rw [hn1, hl1]
      exact shs
    · unfold ShapeOk at shd ⊢
      rw [hn2, hl2]
      exact shd

theorem remove_sound (k : Keyspace) (key hash : Nat) (h : Sound k) : Sound (ksRemove k key hash).1 := by
  obtain ⟨⟨he, hcl, htb, hmp⟩, ws, wd, cs, cd, behind, ls, ld, idle, shs, shd⟩ := h
  obtain ⟨hn, hs⟩ := remove_total k.banks key hash timedOf
  obtain ⟨-, hc⟩ := remove_total k.banks key hash (cellOf k.role)
  obtain ⟨w1, w2⟩ := remove_preserves_wellplaced k.banks key hash ws wd
  obtain ⟨c1, c2⟩ := remove_preserves_consistent k.banks key hash cs cd
  obtain ⟨hcur, hl1, hl2⟩ := remove_shape k.banks key hash
  obtain ⟨hn1, hn2⟩ := remove_lanes k.banks key hash
  have hb := remove_preserves_behind k.banks key hash behind
  unfold ksRemove
  generalize hr : remove k.banks key hash = r at hn hs hc w1 w2 c1 c2 hcur hl1 hl2 hb hn1 hn2
  obtain ⟨b, o⟩ := r
  obtain ⟨s1, m1⟩ := cost_congr k.role _ _ hn1 hl1
  obtain ⟨s2, m2⟩ := cost_congr k.role _ _ hn2 hl2
  cases o with
  | none =>
    have hbk := hn rfl
    simp only at hbk
    subst hbk
    exact ⟨⟨he, hcl, htb, hmp⟩, ws, wd, cs, cd, behind, ls, ld, idle, shs, shd⟩
  | some old =>
    have t1 := hs old rfl
    have t2 := hc old rfl
    simp only at t1 t2 w1 w2 c1 c2 hcur hl1 hl2 hb hn1 hn2 s1 s2 m1 m2 ⊢
    refine ⟨⟨?_, ?_, ?_, ?_⟩, w1, w2, c1, c2, hb, by rw [hl1]; exact ls, by rw [hl2]; exact ld, ?_, ?_, ?_⟩
    · dsimp only
      rw [he]; omega
    · dsimp only
      rw [hcl]; omega
    · dsimp only
      rw [s1, s2, htb]
    · dsimp only
      rw [m1, m2, hmp]
    · intro hneg
      rw [hcur] at hneg
      have hnil := idle hneg
      exact List.eq_nil_of_length_eq_zero (by rw [hl2, hnil]; rfl)
    · unfold ShapeOk at shs ⊢
      rw [hn1, hl1]
      exact shs
    · unfold ShapeOk at shd ⊢
      rw [hn2, hl2]
      exact shd

theorem start_sound (k : Keyspace) (cap : Nat) (h : Sound k) (idle : k.banks.cursor < 0)
    (whole : cap % 16 = 0) : Sound (ksStart k cap) := by
  obtain ⟨⟨he, hcl, htb, hmp⟩, ws, wd, cs, cd, behind, ls, ld, empty, shs, shd⟩ := h
  have hnil := empty idle
  obtain ⟨hs, hl, hshape⟩ := alloc_fresh k.role k.compact (presentLanes k.banks.src) cap
  obtain ⟨z1, z2⟩ := absent_bank_free k.role k.banks.dst hnil
  have hlw : liftWeight (fun _ => 1) = liveWeight := by funext c; cases c <;> rfl
  refine ⟨⟨?_, ?_, ?_, ?_⟩, ws, ?_, cs, ?_, ?_, ls, ?_, ?_, shs, hshape⟩
  · simp only [ksStart, total]
    rw [hs, replicate_weight, he]
    simp [total, hnil, weight]
  · simp only [ksStart, total]
    rw [hs, replicate_weight, hcl]
    simp [total, hnil, weight]
  · simp only [ksStart]
    rw [htb, z1]
    push_cast
    omega
  · simp only [ksStart]
    rw [hmp, z2]
    push_cast
    omega
  · simp only [ksStart]
    rw [hs]
    exact empty_wellplaced cap
  · simp only [CounterConsistent, ksStart]
    rw [hl, hs]
    have := replicate_weight cap (fun _ => 1)
    rw [hlw] at this
    rw [this]
    rfl
  · intro g hg
    simp [ksStart] at hg
  · simp only [ksStart]
    rw [hs]
    simpa using whole
  · intro hneg
    simp [ksStart] at hneg

theorem migrate_sound (k : Keyspace) (groups want : Nat) (h : Sound k) : Sound (ksMigrate k groups want) := by
  unfold ksMigrate
  split
  · exact h
  next hc =>
    obtain ⟨⟨he, hcl, htb, hmp⟩, ws, wd, cs, cd, behind, ls, ld, _, shs, shd⟩ := h
    obtain ⟨t1, b1, c1, c2, w1, w2, shape⟩ :=
      rehash_invariant k.banks groups want timedOf (by omega) ls behind cs cd ws wd
    have t2 := (rehash_invariant k.banks groups want (cellOf k.role) (by omega) ls behind cs cd ws wd).1
    have lanes := rehash_lanes k.banks groups want (by omega)
    rcases shape with ⟨hcur, hl1, hl2⟩ | ⟨hcur, hl1, hnil⟩
    · have hn : (rehash k.banks groups want).src.lanes = k.banks.src.lanes ∧
          (rehash k.banks groups want).dst.lanes = k.banks.dst.lanes := by
        rcases lanes with ⟨-, a, b⟩ | ⟨hc', -, -⟩
        · exact ⟨a, b⟩
        · omega
      obtain ⟨s1, m1⟩ := cost_congr k.role _ _ hn.1 hl1
      obtain ⟨s2, m2⟩ := cost_congr k.role _ _ hn.2 hl2
      simp only [show ¬(rehash k.banks groups want).cursor < 0 by omega, ↓reduceIte]
      refine ⟨⟨?_, ?_, ?_, ?_⟩, w1, w2, c1, c2, b1, by rw [hl1]; exact ls, by rw [hl2]; exact ld, ?_, ?_, ?_⟩
      · rw [he, ← t1]
      · rw [hcl, ← t2]
      · simp only
        rw [htb, s1, s2]
      · simp only
        rw [hmp, m1, m2]
      · intro hneg
        dsimp only at hneg
        omega
      · unfold ShapeOk at shs ⊢
        rw [hn.1, hl1]
        exact shs
      · unfold ShapeOk at shd ⊢
        rw [hn.2, hl2]
        exact shd
    · have hn : (rehash k.banks groups want).src.lanes = k.banks.dst.lanes ∧
          (rehash k.banks groups want).dst.lanes = 0 := by
        rcases lanes with ⟨hc', -, -⟩ | ⟨-, a, b⟩
        · omega
        · exact ⟨a, b⟩
      obtain ⟨s1, m1⟩ := cost_congr k.role _ _ hn.1 hl1
      obtain ⟨z1, z2⟩ := absent_bank_free k.role _ hnil
      simp only [show (rehash k.banks groups want).cursor < 0 by omega, ↓reduceIte]
      refine ⟨⟨?_, ?_, ?_, ?_⟩, w1, w2, c1, c2, b1, by rw [hl1]; exact ld, by rw [hnil]; rfl, fun _ => hnil, ?_, ?_⟩
      · rw [he, ← t1]
      · rw [hcl, ← t2]
      · simp only
        rw [htb, s1, z1]
        omega
      · simp only
        rw [hmp, m1, z2]
        omega
      · unfold ShapeOk at shd ⊢
        rw [hn.1, hl1]
        exact shd
      · left
        rw [hn.2, hnil]
        rfl

theorem begin_sound (k : Keyspace) (cap : Nat) (h : Sound k) (idle : k.banks.cursor < 0)
    (whole : cap % 16 = 0) : Sound (ksBegin k cap) := by
  unfold ksBegin
  split
  · exact migrate_sound _ _ _ (start_sound k cap h idle whole)
  · exact start_sound k cap h idle whole

theorem make_room_sound (k : Keyspace) (h : Sound k) : Sound (ksMakeRoom k) := by
  have hf := migrate_sound k finishBudget finishBudget h
  unfold ksMakeRoom
  dsimp only
  split
  next idle =>
    apply begin_sound _ _ hf idle
    have whole := hf.2.2.2.2.2.2.1
    split
    · exact (grow_cap_valid _ whole).1
    · exact whole
  · exact hf

theorem insert_sound (k k' : Keyspace) (key hash value deadline clock len : Nat) (created : Bool)
    (h : Sound k) (hr : ksInsert k key hash value deadline clock len = some (k', created)) : Sound k' := by
  unfold ksInsert at hr
  refine upsert_sound _ k' key hash value deadline clock len created ?_ hr
  split
  · exact make_room_sound k h
  · exact h

theorem compact_sound (k : Keyspace) (h : Sound k) : Sound (ksCompact k) := by
  unfold ksCompact
  split
  next hc =>
    obtain ⟨⟨he, hcl, htb, hmp⟩, ws, wd, cs, cd, behind, ls, ld, idle, shs, shd⟩ := h
    simp only [compactable, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hc
    obtain ⟨⟨⟨⟨⟨⟨⟨-, hrole⟩, hcur⟩, hlen⟩, -⟩, -⟩, -⟩, hdrop⟩ := hc
    have hk : ∀ (i : Nat) (e : Entry), k.banks.src.slots[i]? = some (Cell.live e) → i < shortKeep := by
      intro i e hi
      rcases Nat.lt_or_ge i shortKeep with hlt | hge
      · exact hlt
      exfalso
      have hmem : Cell.live e ∈ k.banks.src.slots.drop shortKeep := by
        apply List.mem_of_getElem?
        rw [List.getElem?_drop, show shortKeep + (i - shortKeep) = i by omega]
        exact hi
      have := List.all_eq_true.mp hdrop _ hmem
      simp [isLive] at this
    obtain ⟨hidx, hw, wp, cc, hl16, hlanes⟩ := compaction_preserves k.banks.src hlen hk cs
    refine ⟨⟨?_, ?_, ?_, ?_⟩, wp, wd, cc, cd, ?_, by rw [hl16], ld, idle, ?_, shd⟩
    · simp only [total] at he ⊢
      rw [hw, he]
    · simp only [total] at hcl ⊢
      rw [hw, hcl]
    · simp only
      rw [htb]
      omega
    · simp only
      rw [hmp]
      omega
    · intro g hg
      simp only at hg
      omega
    · right
      exact ⟨hrole, hl16, by rw [hlanes]; decide⟩
  · exact h

theorem compaction_bytes (k : Keyspace) (hc : compactable k = true) :
    (ksCompact k).tables = k.tables - (heapTableBytes 16 - shortTableBytes shortShrink) ∧
      (ksCompact k).mapped = k.mapped ∧ (ksCompact k).banks.src.lanes = shortShrink := by
  have hc' := hc
  simp only [compactable, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hc'
  obtain ⟨⟨⟨⟨⟨⟨⟨-, hrole⟩, -⟩, hlen⟩, hlanes⟩, -⟩, -⟩, -⟩ := hc'
  unfold ksCompact
  rw [ite_eq_left hc]
  simp only [tableCost, mappedCost, isShort, compactTable, hlen, hlanes, hrole]
  simp [shortKeep, shortShrink, shortTableBytes, tablesOf, mappedOf, heapTable, heapTableMax, heapTableBytes]
  omega

theorem ladder_keeps_slots (k : Keyspace) (es : List Entry) (idle : k.banks.cursor < 0)
    (hsrc : LivePrefix k.banks.src.slots es) (hlive : k.banks.src.live ≤ 7) :
    (ksMakeRoom k).banks.src.slots = k.banks.src.slots ∧
      (ksMakeRoom k).banks.src.lanes = (allocTable k.role k.compact (some k.banks.src.lanes) 16).lanes ∧
      (ksMakeRoom k).banks.cursor = -1 := by
  have hlen : k.banks.src.slots.length = 16 := hsrc.1
  have hmig : ksMigrate k finishBudget finishBudget = k := by
    unfold ksMigrate
    rw [ite_eq_left idle]
  have hpresent : presentLanes k.banks.src = some k.banks.src.lanes := by
    simp [presentLanes, hlen]
  obtain ⟨hs, -, -⟩ := alloc_fresh k.role k.compact (some k.banks.src.lanes) 16
  have hrh := lane_preserving_rehash ⟨k.banks.src, allocTable k.role k.compact (some k.banks.src.lanes) 16, 0⟩ es
    finishBudget finishBudget hsrc hs rfl (by decide) (by have := hsrc.2.1; unfold finishBudget; omega)
    (by decide)
  obtain ⟨r1, r2, r3, -⟩ := hrh
  unfold ksMakeRoom
  simp only [hmig, idle, ↓reduceIte]
  have hcap : ¬(k.banks.src.live > ((k.banks.src.slots.length * 7 / 16 : Nat) : Int)) := by
    rw [hlen]
    omega
  rw [ite_eq_right hcap, hlen]
  unfold ksBegin
  rw [ite_eq_left (by rw [hlen]; decide)]
  unfold ksMigrate ksStart
  simp only [hpresent]
  rw [ite_eq_right (by decide)]
  simp only [r3]
  rw [ite_eq_left (by decide)]
  exact ⟨r1, r2, r3⟩

theorem sound_finds_present (k : Keyspace) (i : Nat) (e : Entry) (h : Sound k)
    (present : k.banks.src.slots[i]? = some (.live e) ∨ k.banks.dst.slots[i]? = some (.live e)) :
    ∃ d j, locate k.banks e.key e.hash = some (d, j) ∧ keyAt (bankOf k.banks d).slots e.key e.hash j = true := by
  obtain ⟨_, ws, wd, _, _, _, _, _, idle, _, _⟩ := h
  apply locate_finds_present k.banks i e ws wd
  rcases present with hs | hd
  · exact Or.inl hs
  · by_cases hc : k.banks.cursor < 0
    · rw [idle hc] at hd
      simp at hd
    · exact Or.inr ⟨by omega, hd⟩

end Storage
