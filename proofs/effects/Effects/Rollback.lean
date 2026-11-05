import Std

namespace Effects

structure Record where
  value : Nat
  present : Bool
  clock : Nat
  changed : Bool
  valueChanged : Bool
  stringCopy : Bool
  expires : Nat
  encoding : Nat
  kind : Nat
  touched : Bool
  hashMinimum : Nat
  deriving DecidableEq, Repr, Inhabited

abbrev Records := Nat → Record

def putRecord (s : Records) (id : Nat) (r : Record) : Records :=
  fun k => if k = id then r else s k

def distinct : List Nat → List Nat
  | [] => []
  | id :: ids => if id ∈ ids then distinct ids else id :: distinct ids

theorem distinct_membership (ids : List Nat) (id : Nat) : id ∈ distinct ids ↔ id ∈ ids := by
  induction ids with
  | nil => simp [distinct]
  | cons a ids ih =>
    simp only [distinct]
    split <;> simp_all

theorem distinct_no_aliases (ids : List Nat) : (distinct ids).Nodup := by
  induction ids with
  | nil => simp [distinct]
  | cons a ids ih =>
    simp only [distinct]
    split <;> simp_all [distinct_membership]

def capture (before : Records) (ids : List Nat) : List (Nat × Record) :=
  (distinct ids).map fun id => (id, before id)

def restore : List (Nat × Record) → Records → Records
  | [], work => work
  | (id, snapshot) :: rest, work => restore rest (putRecord work id snapshot)

theorem restore_captured_lookup (before work : Records) (ids : List Nat) (id : Nat) :
    restore (ids.map fun k => (k, before k)) work id =
      if id ∈ ids then before id else work id := by
  induction ids generalizing work with
  | nil => simp [restore]
  | cons a ids ih =>
    simp only [List.map_cons, restore, ih, List.mem_cons, putRecord]
    by_cases h : id ∈ ids <;> by_cases ha : id = a <;> simp_all

theorem rollback_restores_distinct (before work : Records) (ids : List Nat) (id : Nat)
    (h : id ∈ ids) : restore (capture before ids) work id = before id := by
  simp [capture, restore_captured_lookup, distinct_membership, h]

theorem rollback_preserves_other_records (before work : Records) (ids : List Nat) (id : Nat)
    (h : id ∉ ids) : restore (capture before ids) work id = work id := by
  simp [capture, restore_captured_lookup, distinct_membership, h]

structure Visible where
  events : List Nat := []
  poststates : List Nat := []
  hashExpired : List Nat := []
  hashReady : Bool := false
  dirty : Nat := 0
  hits : Nat := 0
  misses : Nat := 0
  expired : Nat := 0
  subexpired : Nat := 0
  sanitized : Nat := 0
  deriving DecidableEq, Repr, Inhabited

inductive Outcome where
  | internalFailure | commandError | success
  deriving DecidableEq, Repr

inductive ResourceEvent where
  | destroyCandidate (id : Nat)
  | transferSnapshot (id : Nat)
  | destroySnapshot (id : Nat)
  deriving DecidableEq, Repr

def releaseTrace (ids : List Nat) (failed : Bool) : List ResourceEvent :=
  if failed then
    (distinct ids).map ResourceEvent.destroyCandidate ++ (distinct ids).map ResourceEvent.transferSnapshot
  else (distinct ids).map ResourceEvent.destroySnapshot

def restoreOwned : List (Nat × Record) → Records → Records × List ResourceEvent
  | [], work => (work, [])
  | (id, snapshot) :: rest, work =>
    let next := restoreOwned rest (putRecord work id snapshot)
    (next.1, .destroyCandidate id :: .transferSnapshot id :: next.2)

structure Completion where
  records : Records
  visible : Visible
  rolledBack : Bool
  resources : List ResourceEvent

theorem restoreOwned_records (snapshots : List (Nat × Record)) (work : Records) :
    (restoreOwned snapshots work).1 = restore snapshots work := by
  induction snapshots generalizing work with
  | nil => rfl
  | cons item rest ih => simp [restoreOwned, restore, ih]

theorem restoreOwned_trace (snapshots : List (Nat × Record)) (work : Records) :
    (restoreOwned snapshots work).2 = snapshots.flatMap (fun item => [.destroyCandidate item.1, .transferSnapshot item.1]) := by
  induction snapshots generalizing work with
  | nil => rfl
  | cons item rest ih => simp [restoreOwned, ih]

def finish (before work : Records) (ids : List Nat) (v : Visible) : Outcome → Completion
  | .internalFailure => let restored := restoreOwned (capture before ids) work
    ⟨restored.1, {}, true, restored.2⟩
  | .commandError | .success => ⟨work, v, false, releaseTrace ids false⟩

theorem failure_restores_record_and_metadata (before work : Records) (ids : List Nat) (v : Visible) (id : Nat)
    (h : id ∈ ids) : (finish before work ids v .internalFailure).records id = before id := by
  simpa [finish, restoreOwned_records] using rollback_restores_distinct before work ids id h

theorem failure_restores_authorized_state (before work : Records) (ids : List Nat) (v : Visible)
    (untouched : ∀ id, id ∉ ids → work id = before id) :
    (finish before work ids v .internalFailure).records = before := by
  funext id
  by_cases h : id ∈ ids
  · exact failure_restores_record_and_metadata before work ids v id h
  · simpa [finish, restoreOwned_records, capture, restore_captured_lookup, distinct_membership, h] using untouched id h

theorem failure_discards_unpublished (before work : Records) (ids : List Nat) (v : Visible) :
    (finish before work ids v .internalFailure).visible = {} ∧
    (finish before work ids v .internalFailure).rolledBack = true := by
  simp [finish]

theorem protocol_error_preserves_allowed_effects (before work : Records) (ids : List Nat) (v : Visible) :
    (finish before work ids v .commandError).records = work ∧
    (finish before work ids v .commandError).visible = v ∧
    (finish before work ids v .commandError).rolledBack = false := by
  simp [finish]

theorem snapshot_token_once (ids : List Nat) (id : Nat) :
    (distinct ids).count id = if id ∈ ids then 1 else 0 := by
  simpa [distinct_membership] using (distinct_no_aliases ids).count (a := id)

theorem restoreOwned_candidate_count (snapshots : List (Nat × Record)) (work : Records) (id : Nat) :
    ((restoreOwned snapshots work).2.countP (fun e => decide (e = .destroyCandidate id))) =
      snapshots.countP (fun item => item.1 == id) := by
  induction snapshots generalizing work with
  | nil => rfl
  | cons item rest ih => simp [restoreOwned, List.countP_cons, ih, Bool.beq_eq_decide_eq]

theorem restoreOwned_transfer_count (snapshots : List (Nat × Record)) (work : Records) (id : Nat) :
    ((restoreOwned snapshots work).2.countP (fun e => decide (e = .transferSnapshot id))) =
      snapshots.countP (fun item => item.1 == id) := by
  induction snapshots generalizing work with
  | nil => rfl
  | cons item rest ih => simp [restoreOwned, List.countP_cons, ih, Bool.beq_eq_decide_eq]

theorem candidate_destroy_once (before work : Records) (ids : List Nat) (v : Visible) (id : Nat) :
    ((finish before work ids v .internalFailure).resources.countP (fun e => decide (e = .destroyCandidate id))) =
      if id ∈ ids then 1 else 0 := by
  simpa [finish, restoreOwned_candidate_count, capture, List.countP_map, Function.comp_def, List.count] using snapshot_token_once ids id

theorem snapshot_transfer_once (before work : Records) (ids : List Nat) (v : Visible) (id : Nat) :
    ((finish before work ids v .internalFailure).resources.countP (fun e => decide (e = .transferSnapshot id))) =
      if id ∈ ids then 1 else 0 := by
  simpa [finish, restoreOwned_transfer_count, capture, List.countP_map, Function.comp_def, List.count] using snapshot_token_once ids id

theorem success_snapshot_destroy_once (before work : Records) (ids : List Nat) (v : Visible) (id : Nat) :
    ((finish before work ids v .success).resources.countP (fun e => decide (e = .destroySnapshot id))) =
      if id ∈ ids then 1 else 0 := by
  simpa [finish, releaseTrace, List.count, List.countP_map, Function.comp_def, Bool.beq_eq_decide_eq] using snapshot_token_once ids id

theorem rollback_does_not_destroy_transferred_snapshot (snapshots : List (Nat × Record)) (work : Records) (id : Nat) :
    ((restoreOwned snapshots work).2.countP (fun e => decide (e = .destroySnapshot id))) = 0 := by
  induction snapshots generalizing work with
  | nil => rfl
  | cons item rest ih => simp [restoreOwned, ih]

end Effects
