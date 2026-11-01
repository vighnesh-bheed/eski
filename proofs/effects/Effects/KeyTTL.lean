import Effects.Persistence

namespace Effects

abbrev KeyState := Option Field

def keyLive (now : Nat) (s : KeyState) : KeyState :=
  s.filter fun entry => entry.deadline.all (now < ·)

inductive KeyOperation where
  | setRelative (value : String) (milliseconds : Nat)
  | setAbsolute (value : String) (deadline : Nat)
  | setKeepTTL (value : String)
  | expireAbsolute (deadline : Nat)
  | persist
  | delete
  deriving Repr

inductive KeyReplay where
  | setPXAT (value : String) (deadline : Nat)
  | setKeepTTL (value : String)
  | pexpireat (deadline : Nat)
  | persist
  | del
  deriving Repr, DecidableEq

def applyKey (now : Nat) (s : KeyState) : KeyOperation → KeyState
  | .setRelative v milliseconds => keyLive now (some ⟨v, some (now + milliseconds)⟩)
  | .setAbsolute v deadline => keyLive now (some ⟨v, some deadline⟩)
  | .setKeepTTL v => some ⟨v, (keyLive now s).bind Field.deadline⟩
  | .expireAbsolute deadline =>
    (keyLive now s).bind fun old => if deadline ≤ now then none else some {old with deadline := some deadline}
  | .persist => (keyLive now s).map fun old => {old with deadline := none}
  | .delete => none

def replayKey (now : Nat) (s : KeyState) : KeyReplay → KeyState
  | .setPXAT v deadline => if deadline ≤ now then none else some ⟨v, some deadline⟩
  | .setKeepTTL v =>
    match keyLive now s with
    | none => some ⟨v, none⟩
    | some old => some ⟨v, old.deadline⟩
  | .pexpireat deadline =>
    if deadline ≤ now then none else (keyLive now s).map fun old => {old with deadline := some deadline}
  | .persist => (keyLive now s).map fun old => ⟨old.value, none⟩
  | .del => none

def translateKey (now : Nat) (s : KeyState) : KeyOperation → KeyReplay
  | .setRelative v milliseconds =>
    if milliseconds = 0 then .del else .setPXAT v (now + milliseconds)
  | .setAbsolute v deadline => if deadline ≤ now then .del else .setPXAT v deadline
  | .setKeepTTL v => .setKeepTTL v
  | .expireAbsolute deadline =>
    if (applyKey now s (.expireAbsolute deadline)).isSome then .pexpireat deadline else .del
  | .persist => .persist
  | .delete => .del

def validKeyDuration (now milliseconds : Nat) : Prop :=
  0 < milliseconds ∧ now + milliseconds ≤ 2 ^ 48 - 1

theorem relative_set_replays_absolute_deadline (now : Nat) (s : KeyState) (v : String) (milliseconds : Nat)
    (valid : validKeyDuration now milliseconds) :
    replayKey now s (translateKey now s (.setRelative v milliseconds)) = applyKey now s (.setRelative v milliseconds) := by
  have positive : 0 < milliseconds := valid.1
  have h : milliseconds ≠ 0 := by omega
  have future : now < now + milliseconds := by omega
  simp [translateKey, replayKey, applyKey, keyLive, Option.filter, h, Nat.not_le_of_lt future, future]

theorem absolute_set_replays_value_and_deadline (now : Nat) (s : KeyState) (v : String) (deadline : Nat) :
    replayKey now s (translateKey now s (.setAbsolute v deadline)) = applyKey now s (.setAbsolute v deadline) := by
  by_cases due : deadline ≤ now <;> simp [translateKey, replayKey, applyKey, keyLive, Option.filter, due, Nat.lt_of_not_ge]

theorem set_keep_ttl_replays_value_and_deadline (now : Nat) (s : KeyState) (v : String) :
    replayKey now s (translateKey now s (.setKeepTTL v)) = applyKey now s (.setKeepTTL v) := by
  cases h : keyLive now s <;> simp [translateKey, replayKey, applyKey, h]

theorem key_expiry_translation_refines (now : Nat) (s : KeyState) (deadline : Nat) :
    replayKey now s (translateKey now s (.expireAbsolute deadline)) = applyKey now s (.expireAbsolute deadline) := by
  cases h : keyLive now s with
  | none => simp [translateKey, replayKey, applyKey, h]
  | some old =>
    by_cases due : deadline ≤ now <;> simp [translateKey, replayKey, applyKey, h, due]

theorem key_persist_translation_refines (now : Nat) (s : KeyState) :
    replayKey now s (translateKey now s .persist) = applyKey now s .persist := rfl

theorem key_delete_translation_refines (now : Nat) (s : KeyState) :
    replayKey now s (translateKey now s .delete) = applyKey now s .delete := rfl

theorem key_deadline_equal_now_is_expired (now : Nat) (v : String) :
    keyLive now (some ⟨v, some now⟩) = none := by simp [keyLive, Option.filter]

end Effects
