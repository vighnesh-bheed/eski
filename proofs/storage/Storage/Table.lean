import Std

namespace Storage

structure KeyCell where
  len : Nat
  timed : Bool
  deadline : Nat
  deriving DecidableEq, Repr, Inhabited

structure Entry where
  key : Nat
  hash : Nat
  value : Nat
  clock : Nat
  cell : KeyCell
  deriving DecidableEq, Repr, Inhabited

inductive Cell where
  | empty | deleted | live (entry : Entry)
  deriving DecidableEq, Repr, Inhabited

def put : List Cell → Nat → Cell → List Cell
  | [], _, _ => []
  | _ :: xs, 0, c => c :: xs
  | x :: xs, n + 1, c => x :: put xs n c

def weight (w : Cell → Nat) : List Cell → Nat
  | [] => 0
  | x :: xs => w x + weight w xs

def liftWeight (f : Entry → Nat) : Cell → Nat
  | .live e => f e
  | _ => 0

def total (f : Entry → Nat) (src dst : List Cell) : Nat :=
  weight (liftWeight f) src + weight (liftWeight f) dst

def entryWeight (p : Entry → Bool) : Cell → Nat
  | .live e => if p e then 1 else 0
  | _ => 0

def logical (p : Entry → Bool) (src dst : List Cell) : Nat :=
  weight (entryWeight p) src + weight (entryWeight p) dst

def freeAt (xs : List Cell) (i : Nat) : Bool :=
  match xs[i]? with
  | some .empty | some .deleted => true
  | _ => false

def wordSpan : Nat := 18446744073709551616

def hashHome (h groups : Nat) : Nat := h % wordSpan * groups / wordSpan

def tri : Nat → Nat
  | 0 => 0
  | k + 1 => tri k + (k + 1)

def widen : Nat → Nat → Nat → Nat
  | 0, p, _ => p
  | fuel + 1, p, groups => if p < groups then widen fuel (p * 2) groups else p

def probeSpan (groups : Nat) : Nat := widen groups 1 groups

def walkFrom (groups mask : Nat) : Nat → Nat → Nat → List Nat
  | 0, _, _ => []
  | fuel + 1, pos, step =>
    let rest := walkFrom groups mask fuel ((pos + (step + 1)) &&& mask) (step + 1)
    if pos < groups then pos :: rest else rest

def probeGroups (groups home : Nat) : List Nat :=
  walkFrom groups (probeSpan groups - 1) (probeSpan groups) home 0

def groupIndices (g : Nat) : List Nat := (List.range 16).map (g * 16 + ·)

def groupsOf (xs : List Cell) : Nat := xs.length / 16

def probeOf (xs : List Cell) (hash : Nat) : List Nat :=
  probeGroups (groupsOf xs) (hashHome hash (groupsOf xs))

def candidates (xs : List Cell) (hash : Nat) : List Nat :=
  (probeOf xs hash).flatMap groupIndices

def claimIndex (xs : List Cell) (hash : Nat) : Option Nat :=
  (candidates xs hash).find? (freeAt xs)

structure Table where
  slots : List Cell
  live : Int
  tombs : Int
  growth : Int
  deriving Repr, Inhabited

def emptyTable (cap : Nat) : Table :=
  ⟨List.replicate cap .empty, 0, 0, cap - cap / 8⟩

def growCap (cap : Nat) : Nat := max (cap + 16) ((cap * 5 / 4 + 15) / 16 * 16)

def roundCap (n : Nat) : Nat := max 16 ((n + 15) / 16 * 16)

def place (t : Table) (i : Nat) (e : Entry) : Table :=
  let deleted := t.slots[i]? == some .deleted
  ⟨put t.slots i (.live e), t.live + 1,
    t.tombs - (if deleted then 1 else 0), t.growth - (if deleted then 0 else 1)⟩

structure Banks where
  src : Table
  dst : Table
  cursor : Int
  deriving Repr, Inhabited

def moveOne (b : Banks) (i j : Nat) (e : Entry) : Banks :=
  ⟨⟨put b.src.slots i .deleted, b.src.live - 1, b.src.tombs + 1, b.src.growth⟩,
    place b.dst j e, b.cursor⟩

def migrateAt (b : Banks) (i : Nat) : Banks × Nat :=
  match b.src.slots[i]? with
  | some (.live e) =>
    match claimIndex b.dst.slots e.hash with
    | some j => (moveOne b i j e, 1)
    | none => (b, 0)
  | _ => (b, 0)

def groupLive (t : Table) (g : Nat) : Bool :=
  (List.range 16).any fun k => match t.slots[g * 16 + k]? with
    | some (.live _) => true
    | _ => false

def migrateSlots : List Nat → Nat → Banks → Nat → Banks × Nat
  | [], _, b, moved => (b, moved)
  | i :: rest, limit, b, moved =>
    if moved < limit then
      let next := migrateAt b i
      migrateSlots rest limit next.1 (moved + next.2)
    else (b, moved)

def migrateGroup (b : Banks) (g limit : Nat) : Banks × Nat × Bool :=
  let result := migrateSlots (groupIndices g) limit b 0
  (result.1, result.2, !groupLive result.1.src g)

def nextCursor (cursor : Int) (done : Bool) : Int := if done then cursor + 1 else cursor

def swapBanks (b : Banks) : Banks := ⟨b.dst, emptyTable 0, -1⟩

def rehashLoop : Nat → Banks → Nat → Nat → Nat → Nat → Banks
  | 0, b, _, _, _, _ => b
  | fuel + 1, b, maxGroups, want, moved, visited =>
    if b.cursor < 0 ∨ groupsOf b.src.slots ≤ b.cursor.toNat ∨ want ≤ moved ∨ maxGroups ≤ visited then b
    else
      let r := migrateGroup b b.cursor.toNat (want - moved)
      if r.2.2 then
        rehashLoop fuel {r.1 with cursor := nextCursor r.1.cursor true} maxGroups want (moved + r.2.1) (visited + 1)
      else r.1

def rehash (b : Banks) (maxGroups want : Nat) : Banks :=
  let next := rehashLoop (groupsOf b.src.slots) b maxGroups want 0 0
  if groupsOf next.src.slots ≤ next.cursor.toNat ∨ next.src.live = 0 then swapBanks next else next

def keyAt (xs : List Cell) (key hash i : Nat) : Bool :=
  match xs[i]? with
  | some (.live e) => e.key == key && e.hash % 128 == hash % 128
  | _ => false

def lookupCandidates (xs : List Cell) (key hash : Nat) (indices : List Nat) : Option Nat :=
  indices.find? (keyAt xs key hash)

def groupEmpty (xs : List Cell) (g : Nat) : Bool :=
  (List.range 16).any fun k => xs[g * 16 + k]? == some .empty

def lookupPath (xs : List Cell) (key hash : Nat) : List Nat → Option Nat
  | [] => none
  | g :: rest =>
    match lookupCandidates xs key hash (groupIndices g) with
    | some i => some i
    | none => if groupEmpty xs g then none else lookupPath xs key hash rest

def findIndex (t : Table) (key hash : Nat) : Option Nat :=
  lookupPath t.slots key hash (probeOf t.slots hash)

def erase (t : Table) (i : Nat) : Table :=
  let g := i / 16
  let empty := (List.range 16).any fun k => t.slots[g * 16 + k]? == some .empty
  ⟨put t.slots i (if empty then .empty else .deleted), t.live - 1,
    t.tombs + (if empty then 0 else 1), t.growth + (if empty then 1 else 0)⟩

def locate (b : Banks) (key hash : Nat) : Option (Bool × Nat) :=
  match findIndex b.src key hash with
  | some i => some (false, i)
  | none => if 0 ≤ b.cursor then (findIndex b.dst key hash).map (true, ·) else none

theorem put_weight (xs : List Cell) (i : Nat) (old new : Cell) (w : Cell → Nat)
    (h : xs[i]? = some old) :
    weight w (put xs i new) + w old = weight w xs + w new := by
  induction i generalizing xs with
  | zero =>
    cases xs with
    | nil => simp at h
    | cons x xs => simp at h; subst x; simp only [put, weight]; omega
  | succ i ih =>
    cases xs with
    | nil => simp at h
    | cons x xs =>
      have hi : xs[i]? = some old := by simpa using h
      have hh := ih xs hi
      simp only [put, weight]
      omega

theorem put_length (xs : List Cell) (i : Nat) (c : Cell) :
    (put xs i c).length = xs.length := by
  induction i generalizing xs with
  | zero => cases xs <;> simp [put]
  | succ i ih => cases xs <;> simp [put, ih]

theorem put_selected (xs : List Cell) (i : Nat) (old new : Cell)
    (h : xs[i]? = some old) : (put xs i new)[i]? = some new := by
  induction i generalizing xs with
  | zero => cases xs <;> simp_all [put]
  | succ i ih => cases xs <;> simp_all [put]

theorem claim_is_free (xs : List Cell) (hash i : Nat)
    (h : claimIndex xs hash = some i) : freeAt xs i = true := by
  exact List.find?_some h

theorem claim_first_reachable (xs : List Cell) (hash i : Nat)
    (h : claimIndex xs hash = some i) :
    ∃ before after, candidates xs hash = before ++ i :: after ∧ ∀ j ∈ before, freeAt xs j = false := by
  obtain ⟨_, before, after, heq, hbefore⟩ := List.find?_eq_some_iff_append.mp h
  refine ⟨before, after, heq, ?_⟩
  intro j hj
  have hh := hbefore j hj
  simpa using hh

theorem move_preserves_total (b : Banks) (i j : Nat) (e : Entry)
    (hs : b.src.slots[i]? = some (.live e)) (hd : freeAt b.dst.slots j = true)
    (f : Entry → Nat) :
    total f (moveOne b i j e).src.slots (moveOne b i j e).dst.slots =
      total f b.src.slots b.dst.slots := by
  have hsrc := put_weight b.src.slots i (.live e) .deleted (liftWeight f) hs
  cases ht : b.dst.slots[j]? with
  | none => simp [freeAt, ht] at hd
  | some c =>
    cases c with
    | live v => simp [freeAt, ht] at hd
    | empty =>
      have hdst := put_weight b.dst.slots j .empty (.live e) (liftWeight f) ht
      simp only [liftWeight] at hsrc hdst
      simp only [total, moveOne, place]
      omega
    | deleted =>
      have hdst := put_weight b.dst.slots j .deleted (.live e) (liftWeight f) ht
      simp only [liftWeight] at hsrc hdst
      simp only [total, moveOne, place]
      omega

theorem entry_weight_lift (p : Entry → Bool) :
    entryWeight p = liftWeight (fun e => if p e then 1 else 0) := by
  funext c
  cases c <;> rfl

theorem move_preserves_logical (b : Banks) (i j : Nat) (e : Entry)
    (hs : b.src.slots[i]? = some (.live e)) (hd : freeAt b.dst.slots j = true)
    (p : Entry → Bool) :
    logical p (moveOne b i j e).src.slots (moveOne b i j e).dst.slots =
      logical p b.src.slots b.dst.slots := by
  have h := move_preserves_total b i j e hs hd (fun e => if p e then 1 else 0)
  simp only [total, ← entry_weight_lift] at h
  exact h

theorem move_preserves_unique_keys (b : Banks) (i j : Nat) (e : Entry)
    (hs : b.src.slots[i]? = some (.live e)) (hd : freeAt b.dst.slots j = true)
    (unique : ∀ key, logical (fun e => e.key == key) b.src.slots b.dst.slots ≤ 1) :
    ∀ key, logical (fun e => e.key == key) (moveOne b i j e).src.slots
      (moveOne b i j e).dst.slots ≤ 1 := by
  intro key
  rw [move_preserves_logical b i j e hs hd]
  exact unique key

theorem move_source_tombstone (b : Banks) (i j : Nat) (e : Entry)
    (hs : b.src.slots[i]? = some (.live e)) :
    (moveOne b i j e).src.slots[i]? = some .deleted := by
  exact put_selected b.src.slots i (.live e) .deleted hs

theorem move_accounting (b : Banks) (i j : Nat) (e : Entry) :
    (moveOne b i j e).src.live + (moveOne b i j e).dst.live = b.src.live + b.dst.live ∧
    (moveOne b i j e).src.tombs = b.src.tombs + 1 ∧
    (moveOne b i j e).src.growth = b.src.growth ∧
    (moveOne b i j e).dst.live = b.dst.live + 1 ∧
    (moveOne b i j e).dst.tombs + (moveOne b i j e).dst.growth = b.dst.tombs + b.dst.growth - 1 := by
  simp only [moveOne, place]
  split <;> simp_all <;> omega

def CounterBounds (t : Table) : Prop :=
  0 ≤ t.live ∧ t.live ≤ 9223372036854775807 ∧
  0 ≤ t.tombs ∧ t.tombs ≤ 9223372036854775807 ∧
  0 ≤ t.growth ∧ t.growth ≤ 9223372036854775807

theorem migration_machine_bounds (b : Banks) (i j : Nat) (e : Entry)
    (hs : CounterBounds b.src) (hd : CounterBounds b.dst)
    (sourceLive : 0 < b.src.live) (sourceTombs : b.src.tombs < 9223372036854775807)
    (destLive : b.dst.live < 9223372036854775807)
    (room : if b.dst.slots[j]? == some .deleted then 0 < b.dst.tombs else 0 < b.dst.growth) :
    CounterBounds (moveOne b i j e).src ∧ CounterBounds (moveOne b i j e).dst := by
  unfold CounterBounds at *
  simp only [moveOne, place]
  split at room <;> simp_all <;> omega

theorem migrateAt_preserves_total (b : Banks) (i : Nat) (f : Entry → Nat) :
    total f (migrateAt b i).1.src.slots (migrateAt b i).1.dst.slots =
      total f b.src.slots b.dst.slots := by
  unfold migrateAt
  split
  next e hs =>
    split
    next j hj => exact move_preserves_total b i j e hs (claim_is_free _ _ _ hj) f
    next => rfl
  next => rfl

theorem migrateAt_preserves_logical (b : Banks) (i : Nat) (p : Entry → Bool) :
    logical p (migrateAt b i).1.src.slots (migrateAt b i).1.dst.slots =
      logical p b.src.slots b.dst.slots := by
  have h := migrateAt_preserves_total b i (fun e => if p e then 1 else 0)
  simp only [total, ← entry_weight_lift] at h
  exact h

theorem repeated_migration_preserves (steps : List Nat) (b : Banks) (p : Entry → Bool) :
    logical p (steps.foldl (fun s i => (migrateAt s i).1) b).src.slots
      (steps.foldl (fun s i => (migrateAt s i).1) b).dst.slots = logical p b.src.slots b.dst.slots := by
  induction steps generalizing b with
  | nil => rfl
  | cons i rest ih =>
    simp only [List.foldl_cons]
    rw [ih, migrateAt_preserves_logical]

theorem migrateSlots_preserves_total (indices : List Nat) (limit moved : Nat) (b : Banks)
    (f : Entry → Nat) :
    total f (migrateSlots indices limit b moved).1.src.slots
      (migrateSlots indices limit b moved).1.dst.slots = total f b.src.slots b.dst.slots := by
  induction indices generalizing b moved with
  | nil => rfl
  | cons i rest ih =>
    simp only [migrateSlots]
    split
    next => rw [ih, migrateAt_preserves_total]
    next => rfl

theorem migrateSlots_preserves (indices : List Nat) (limit moved : Nat) (b : Banks) (p : Entry → Bool) :
    logical p (migrateSlots indices limit b moved).1.src.slots
      (migrateSlots indices limit b moved).1.dst.slots = logical p b.src.slots b.dst.slots := by
  have h := migrateSlots_preserves_total indices limit moved b (fun e => if p e then 1 else 0)
  simp only [total, ← entry_weight_lift] at h
  exact h

theorem migrateGroup_preserves (b : Banks) (g limit : Nat) (p : Entry → Bool) :
    logical p (migrateGroup b g limit).1.src.slots (migrateGroup b g limit).1.dst.slots =
      logical p b.src.slots b.dst.slots := by
  exact migrateSlots_preserves _ limit 0 b p

theorem group_done_exact (b : Banks) (g limit : Nat) :
    (migrateGroup b g limit).2.2 = true ↔ groupLive (migrateGroup b g limit).1.src g = false := by
  simp [migrateGroup]

theorem migrateSlots_stopped (indices : List Nat) (limit moved : Nat) (b : Banks)
    (h : limit ≤ moved) : migrateSlots indices limit b moved = (b, moved) := by
  cases indices <;> simp [migrateSlots, Nat.not_lt.mpr h]

theorem zero_budget_preserves (b : Banks) (g : Nat) : (migrateGroup b g 0).1 = b := by
  simp [migrateGroup, migrateSlots_stopped]

theorem partial_group_retains_cursor (cursor : Int) : nextCursor cursor false = cursor := rfl

theorem completed_group_advances_cursor (cursor : Int) : nextCursor cursor true = cursor + 1 := rfl

theorem swap_preserves (b : Banks) (p : Entry → Bool)
    (empty : weight (entryWeight p) b.src.slots = 0) :
    logical p (swapBanks b).src.slots (swapBanks b).dst.slots = logical p b.src.slots b.dst.slots := by
  simp [logical, swapBanks, emptyTable, weight, empty]

theorem positive_budget_progress (b : Banks) (i j : Nat) (e : Entry)
    (hs : b.src.slots[i]? = some (.live e)) (hd : claimIndex b.dst.slots e.hash = some j) :
    (migrateAt b i).2 = 1 ∧ (migrateAt b i).1.src.live = b.src.live - 1 := by
  simp [migrateAt, hs, hd, moveOne]

theorem grow_cap_valid (cap : Nat) (h : cap % 16 = 0) :
    growCap cap % 16 = 0 ∧ cap < growCap cap ∧ cap * 5 / 4 ≤ growCap cap ∧ growCap cap ≤ cap * 5 / 4 + 16 := by
  unfold growCap
  omega

theorem grow_holds_live (cap live : Nat) (h : live ≤ cap - cap / 8) :
    live ≤ growCap cap - growCap cap / 8 := by
  unfold growCap
  omega

theorem round_cap_valid (n : Nat) :
    roundCap n % 16 = 0 ∧ 16 ≤ roundCap n ∧ n ≤ roundCap n ∧ roundCap n < max 16 n + 16 := by
  unfold roundCap
  omega

theorem shrink_holds_live (live : Nat) : live ≤ roundCap (live * 2) - roundCap (live * 2) / 8 := by
  unfold roundCap
  omega

end Storage
