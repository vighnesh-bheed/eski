namespace Texts

def isSep (b : Nat) : Bool :=
  b = 9 || b = 32 || (33 ≤ b && b ≤ 47) || (58 ≤ b && b ≤ 64) || b = 91 || b = 93 || b = 94 || b = 96 || (123 ≤ b && b ≤ 126)

def isDropped (b : Nat) : Bool := (1 ≤ b && b ≤ 8) || (10 ≤ b && b ≤ 31) || b = 127

def isEnd (b : Nat) : Bool := b = 0

def isEscape (b : Nat) : Bool := b = 92

def isUpper (b : Nat) : Bool := 65 ≤ b && b ≤ 90

def isTerm (b : Nat) : Bool := (48 ≤ b && b ≤ 57) || (97 ≤ b && b ≤ 122) || b = 95 || (128 ≤ b && b ≤ 255)

def isTagSpace (b : Nat) : Bool := b = 9 || (10 ≤ b && b ≤ 13) || b = 32

def isQueryBreak (b : Nat) : Bool := (1 ≤ b && b ≤ 31) || b = 32 || (33 ≤ b && b ≤ 47) || (58 ≤ b && b ≤ 64) ||
  (91 ≤ b && b ≤ 94) || b = 96 || (123 ≤ b && b ≤ 127)

def isControl (b : Nat) : Bool := b < 32 || b = 127

def isAlnum (b : Nat) : Bool := (48 ≤ b && b ≤ 57) || (65 ≤ b && b ≤ 90) || (97 ≤ b && b ≤ 122)

def isPunct (b : Nat) : Bool := 33 ≤ b && b ≤ 126 && !isAlnum b

def classBits (b : Nat) : Nat :=
  (if isTerm b then 1 else 0) + (if isUpper b then 2 else 0) + (if isSep b then 4 else 0) + (if isDropped b then 8 else 0) +
    (if isEscape b then 16 else 0) + (if isEnd b then 32 else 0) + (if isTagSpace b then 64 else 0) +
    (if isQueryBreak b then 128 else 0)

def isSpecial (b : Nat) : Bool := isSep b || isEnd b || isDropped b || isEscape b

set_option maxRecDepth 100000 in
theorem separator_rule : ∀ b, b < 256 → (isSep b = true ↔ (b = 9 ∨ b = 32 ∨ (isPunct b = true ∧ b ≠ 95 ∧ b ≠ 92))) := by
  decide

set_option maxRecDepth 100000 in
theorem dropped_rule : ∀ b, b < 256 → (isDropped b = true ↔ ((isControl b = true ∧ b ≠ 0 ∧ b ≠ 9))) := by
  decide

set_option maxRecDepth 100000 in
theorem classes_partition : ∀ b, b < 256 →
    ([isEnd b, isSep b, isDropped b, isEscape b, isTerm b || isUpper b].filter id).length = 1 := by
  decide

set_option maxRecDepth 100000 in
theorem query_break_rule : ∀ b, b < 256 → (isQueryBreak b = true ↔ (b ≠ 0 ∧ isTerm b = false ∧ isUpper b = false)) := by
  decide

set_option maxRecDepth 100000 in
theorem tag_space_rule : ∀ b, b < 256 → (isTagSpace b = true ↔ (b = 32 ∨ (9 ≤ b ∧ b ≤ 13))) := by
  decide

set_option maxRecDepth 100000 in
theorem plain_not_control : ∀ b, b < 256 → isSpecial b = false → isControl b = false := by
  decide

end Texts
