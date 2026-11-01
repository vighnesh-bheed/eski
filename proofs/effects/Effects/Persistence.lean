import Std

namespace Effects

structure Field where
  value : String
  deadline : Option Nat := none
  deriving DecidableEq, Repr, Inhabited

abbrev Hash := Nat → Option Field

def update (s : Hash) (field : Nat) (v : Option Field) : Hash :=
  fun k => if k = field then v else s k

inductive Condition where
  | any | nx | xx | gt | lt
  deriving DecidableEq, Repr

def permits (cond : Condition) (old : Option Nat) (deadline : Nat) : Bool :=
  match cond, old with
  | .any, _ => true
  | .nx, none => true
  | .nx, some _ => false
  | .xx, none => false
  | .xx, some _ => true
  | .gt, none => false
  | .gt, some n => n < deadline
  | .lt, none => true
  | .lt, some n => deadline < n

inductive Operation where
  | write (field : Nat) (value : String)
  | finalFloat (field : Nat) (value : String) (deadline : Option Nat)
  | expire (field deadline : Nat) (cond : Condition)
  | persist (field : Nat)
  | remove (field : Nat)
  | read (field : Nat)
  deriving Repr

inductive Replay where
  | hset (field : Nat) (value : String)
  | hpexpireat (field deadline : Nat)
  | hpersist (field : Nat)
  | hdel (field : Nat)
  deriving Repr, DecidableEq

def applyOperation (now : Nat) (s : Hash) : Operation → Hash
  | .write f v => update s f (some ⟨v, none⟩)
  | .finalFloat f v deadline => update s f (some ⟨v, deadline⟩)
  | .expire f deadline cond =>
    match s f with
    | none => s
    | some old =>
      if permits cond old.deadline deadline then
        update s f (if deadline ≤ now then none else some {old with deadline := some deadline})
      else s
  | .persist f =>
    match s f with
    | none => s
    | some old =>
      match old.deadline with
      | none => s
      | some deadline => if now ≤ deadline then update s f (some {old with deadline := none}) else s
  | .remove f => update s f none
  | .read f =>
    match s f with
    | none => s
    | some old => if old.deadline.any (· < now) then update s f none else s

def replayOne (now : Nat) (s : Hash) : Replay → Hash
  | .hset f v => update s f (some ⟨v, none⟩)
  | .hpexpireat f deadline =>
    fun k => if k = f then
      (s k).bind fun old => if deadline ≤ now then none else some {old with deadline := some deadline}
    else s k
  | .hpersist f =>
    fun k => if k = f then
      (s k).map fun old =>
        match old.deadline with
        | none => old
        | some deadline => if now ≤ deadline then {old with deadline := none} else old
    else s k
  | .hdel f => update s f none

def replay (now : Nat) (s : Hash) (commands : List Replay) : Hash :=
  commands.foldl (replayOne now) s

def expiryReply (now : Nat) (s : Hash) (f deadline : Nat) (cond : Condition) : Int :=
  match s f with
  | none => -2
  | some old =>
    if permits cond old.deadline deadline then if deadline ≤ now then 2 else 1 else 0

def expiryReplyCommands (f deadline : Nat) (reply : Int) : List Replay :=
  if reply = 1 then [.hpexpireat f deadline]
  else if reply = 2 then [.hdel f] else []

def translate (now : Nat) (s : Hash) : Operation → List Replay
  | .write f v => [.hset f v]
  | .finalFloat f v none => [.hset f v]
  | .finalFloat f v (some deadline) => [.hset f v, .hpexpireat f deadline]
  | .expire f deadline cond => expiryReplyCommands f deadline (expiryReply now s f deadline cond)
  | .persist f =>
    match s f with
    | none => []
    | some old =>
      match old.deadline with
      | none => []
      | some deadline => if now ≤ deadline then [.hpersist f] else []
  | .remove f => if (s f).isSome then [.hdel f] else []
  | .read f =>
    match s f with
    | none => []
    | some old => if old.deadline.any (· < now) then [.hdel f] else []

def validOperation (now : Nat) : Operation → Prop
  | .finalFloat _ _ (some deadline) => now < deadline
  | _ => True

theorem replay_expire_refines (now : Nat) (s : Hash) (f deadline : Nat) (cond : Condition) :
    replay now s (translate now s (.expire f deadline cond)) = applyOperation now s (.expire f deadline cond) := by
  funext k
  cases h : s f with
  | none => simp [translate, expiryReplyCommands, expiryReply, applyOperation, h, replay]
  | some old =>
    by_cases hp : permits cond old.deadline deadline = true
    · by_cases ht : deadline ≤ now
      · simp [translate, expiryReplyCommands, expiryReply, applyOperation, h, hp, ht, replay, replayOne]
      · by_cases hk : k = f
        · subst k; simp [translate, expiryReplyCommands, expiryReply, applyOperation, h, hp, ht, replay, replayOne, update]
        · simp [translate, expiryReplyCommands, expiryReply, applyOperation, h, hp, ht, replay, replayOne, update, hk]
    · simp [translate, expiryReplyCommands, expiryReply, applyOperation, h, hp, replay]

theorem consistent_expiry_reply_refines (now : Nat) (s : Hash) (f deadline : Nat) (cond : Condition)
    (reply : Int) (h : reply = expiryReply now s f deadline cond) :
    replay now s (expiryReplyCommands f deadline reply) = applyOperation now s (.expire f deadline cond) := by
  subst reply
  exact replay_expire_refines now s f deadline cond

theorem future_expiry_reply_ne_delete (now : Nat) (s : Hash) (f deadline : Nat) (cond : Condition)
    (future : now < deadline) : expiryReply now s f deadline cond ≠ 2 := by
  cases h : s f <;> simp [expiryReply, h, Nat.not_le_of_lt future]
  split <;> decide

theorem due_expiry_reply_ne_update (now : Nat) (s : Hash) (f deadline : Nat) (cond : Condition)
    (due : deadline ≤ now) : expiryReply now s f deadline cond ≠ 1 := by
  cases h : s f <;> simp [expiryReply, h, due]
  split <;> decide

theorem replay_persist_refines (now : Nat) (s : Hash) (f : Nat) :
    replay now s (translate now s (.persist f)) = applyOperation now s (.persist f) := by
  funext k
  cases h : s f with
  | none => simp [translate, applyOperation, h, replay]
  | some old =>
    cases hd : old.deadline with
    | none => simp [translate, applyOperation, h, hd, replay]
    | some deadline =>
      by_cases ht : now ≤ deadline
      · by_cases hk : k = f
        · subst k; simp [translate, applyOperation, h, hd, ht, replay, replayOne, update]
        · simp [translate, applyOperation, h, hd, ht, replay, replayOne, update, hk]
      · simp [translate, applyOperation, h, hd, ht, replay]

theorem replay_final_bytes_preserves_deadline (now : Nat) (s : Hash) (f : Nat) (v : String) (deadline : Option Nat)
    (hvalid : validOperation now (.finalFloat f v deadline)) :
    replay now s (translate now s (.finalFloat f v deadline)) = applyOperation now s (.finalFloat f v deadline) := by
  funext k
  cases deadline with
  | none => rfl
  | some deadline =>
    have ht : ¬deadline ≤ now := by simpa [validOperation] using Nat.not_le_of_lt hvalid
    by_cases hk : k = f <;> simp [translate, replay, replayOne, applyOperation, update, hk, ht]

theorem replay_remove_refines (now : Nat) (s : Hash) (f : Nat) :
    replay now s (translate now s (.remove f)) = applyOperation now s (.remove f) := by
  funext k
  cases h : s f with
  | none =>
    by_cases hk : k = f
    · subst k; simp [translate, replay, applyOperation, update, h]
    · simp [translate, replay, applyOperation, update, h, hk]
  | some old => simp [translate, replay, replayOne, applyOperation, h]

theorem lazy_expiry_translation_refines (now : Nat) (s : Hash) (f : Nat) :
    replay now s (translate now s (.read f)) = applyOperation now s (.read f) := by
  cases h : s f with
  | none => simp [translate, applyOperation, replay, h]
  | some old =>
    by_cases expired : old.deadline.any (· < now) = true
    · simp [translate, applyOperation, replay, replayOne, h, expired]
    · simp [translate, applyOperation, replay, h, expired]

theorem translation_refines (now : Nat) (s : Hash) (op : Operation) (h : validOperation now op) :
    replay now s (translate now s op) = applyOperation now s op := by
  cases op with
  | write f v => rfl
  | finalFloat f v deadline => exact replay_final_bytes_preserves_deadline now s f v deadline h
  | expire f deadline cond => exact replay_expire_refines now s f deadline cond
  | persist f => exact replay_persist_refines now s f
  | remove f => exact replay_remove_refines now s f
  | read f => exact lazy_expiry_translation_refines now s f

def runOperations (now : Nat) (s : Hash) (ops : List Operation) : Hash :=
  ops.foldl (applyOperation now) s

def emitOperations (now : Nat) (s : Hash) : List Operation → List Replay
  | [] => []
  | op :: ops => translate now s op ++ emitOperations now (applyOperation now s op) ops

theorem replay_append (now : Nat) (s : Hash) (a b : List Replay) :
    replay now s (a ++ b) = replay now (replay now s a) b := by
  simp [replay, List.foldl_append]

theorem sequences_preserve_values_and_absolute_deadlines (now : Nat) (s : Hash) (ops : List Operation)
    (h : ∀ op ∈ ops, validOperation now op) :
    replay now s (emitOperations now s ops) = runOperations now s ops := by
  induction ops generalizing s with
  | nil => rfl
  | cons op ops ih =>
    rw [emitOperations, replay_append, translation_refines now s op (h op (by simp))]
    exact ih (applyOperation now s op) (fun x hx => h x (by simp [hx]))

def logicalLive (now : Nat) (s : Hash) : Hash :=
  fun f => (s f).filter fun entry => entry.deadline.all (now ≤ ·)

def removeDue (now : Nat) (s : Hash) : Hash :=
  fun f => match s f with
    | none => none
    | some entry => if entry.deadline.any (· < now) then none else some entry

theorem physical_expiry_preserves_live_view (now : Nat) (s : Hash) :
    logicalLive now (removeDue now s) = logicalLive now s := by
  funext f
  cases h : s f with
  | none => simp [logicalLive, removeDue, h]
  | some entry =>
    cases hd : entry.deadline with
    | none => simp [logicalLive, removeDue, h, hd]
    | some deadline =>
      by_cases ht : deadline < now <;> simp_all [logicalLive, removeDue, Option.filter, Nat.not_le_of_lt, Nat.not_lt_of_ge]

structure RegisteredHash where
  fields : Hash
  cachedMinimum : Option Nat

def observed (now : Nat) (s : RegisteredHash) : Hash := logicalLive now s.fields

theorem cached_minimum_does_not_define_liveness (now : Nat) (s : Hash) (a b : Option Nat) :
    observed now ⟨s, a⟩ = observed now ⟨s, b⟩ := rfl

theorem expire_then_persist_absolute (now deadline f : Nat) (s : Hash) (v : String) (h : now < deadline) :
    runOperations now s [.write f v, .expire f deadline .any, .persist f] f = some ⟨v, none⟩ := by
  simp [runOperations, applyOperation, update, permits, Nat.not_le_of_lt h, Nat.le_of_lt h]

theorem existing_deadline_live_at_exact_now (now f : Nat) (s : Hash) (v : String) :
    logicalLive now (update s f (some ⟨v, some now⟩)) f = some ⟨v, some now⟩ := by
  simp [logicalLive, update]

theorem new_deadline_at_now_deletes (now f : Nat) (s : Hash) (old : Field) (h : s f = some old) :
    applyOperation now s (.expire f now .any) f = none := by
  simp [applyOperation, permits, update, h]

theorem existing_deadline_expires_after_now (now f : Nat) (s : Hash) (v : String) :
    logicalLive (now + 1) (update s f (some ⟨v, some now⟩)) f = none := by
  simp [logicalLive, update]

def activeSweep (now : Nat) (s : Hash) : Hash :=
  fun f => (s f).filter fun entry => entry.deadline.all (now < ·)

theorem active_sweep_removes_at_exact_now (now f : Nat) (s : Hash) (v : String) :
    activeSweep now (update s f (some ⟨v, some now⟩)) f = none := by
  simp [activeSweep, update]

end Effects
