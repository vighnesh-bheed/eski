import Bitfield.Arithmetic

namespace Bitfield

abbrev Buffer := Array (BitVec 8)

inductive Opcode where
  | get | set | incr
  deriving DecidableEq, Repr

inductive Overflow where
  | wrap | sat | fail
  deriving DecidableEq, Repr

structure Op where
  opcode : Opcode
  signed : Bool
  bits : Nat
  offset : Nat
  arg : Int
  overflow : Overflow
  deriving Repr

def byteAt (buf : Buffer) (i : Nat) : BitVec 8 := buf[i]?.getD 0

def loadWord (buf : Buffer) (index : Nat) : BitVec 64 :=
  (List.range 8).foldl (fun acc k => (acc <<< 8) ||| (byteAt buf (index + k)).setWidth 64) 0

def mask (bits : Nat) : BitVec 64 :=
  if bits ≥ 64 then -1 else (1 <<< bits) - 1

def extract (buf : Buffer) (offset bits : Nat) : BitVec 64 := Id.run do
  if bits = 0 ∨ bits > 64 then return 0
  let index := offset / 8
  let shift := offset % 8
  let mut w := loadWord buf index <<< shift
  if shift + bits > 64 then
    w := w ||| ((byteAt buf (index + 8)).setWidth 64 >>> (8 - shift))
  return w >>> (64 - bits)

def getField (buf : Buffer) (op : Op) : Int :=
  let raw := extract buf op.offset op.bits
  if op.signed then (raw.setWidth op.bits).toInt else raw.toNat

def storeWord (buf : Buffer) (index : Nat) (w : BitVec 64) : Buffer :=
  (List.range 8).foldl (fun buf k =>
    if index + k < buf.size then buf.set! (index + k) ((w >>> (56 - 8 * k)).setWidth 8) else buf) buf

def deposit (buf : Buffer) (offset bits : Nat) (value : Int) : Buffer := Id.run do
  if bits = 0 ∨ bits > 64 then return buf
  let index := offset / 8
  if index ≥ buf.size then return buf
  let shift := offset % 8
  let v := word value
  let mut w := loadWord buf index
  if shift + bits ≤ 64 then
    let place := 64 - shift - bits
    let m := mask bits <<< place
    w := (w &&& ~~~m) ||| ((v <<< place) &&& m)
    return storeWord buf index w
  let spill := shift + bits - 64
  let m := (-1 : BitVec 64) >>> shift
  w := (w &&& ~~~m) ||| ((v >>> spill) &&& m)
  let buf := storeWord buf index w
  let keep := (255 : BitVec 8) >>> spill
  let last := (byteAt buf (index + 8) &&& keep) ||| ((v <<< (8 - spill)).setWidth 8)
  return if index + 8 < buf.size then buf.set! (index + 8) last else buf

def direction (op : Op) (value incr : Int) : Int :=
  let lo := bottom op.bits op.signed
  let hi := top op.bits op.signed
  if op.signed then
    if op.bits < 64 then signedNarrowDirection value incr lo hi
    else signedWideDirection value incr lo hi
  else unsignedDirection value incr hi

def changedWord (bits : Nat) (old next : Int) : Bool :=
  ((word old ^^^ word next) &&& mask bits) != 0

def counted (bits : Nat) (old next : Int) (grown : Bool) : Bool :=
  grown || changedWord bits old next

structure Result where
  buf : Buffer
  reply : Option Int
  counted : Bool
  deriving Repr

def finish (buf : Buffer) (op : Op) (old : Int) (next : Option Int) (grown : Bool) : Result :=
  match next with
  | none => ⟨buf, none, false⟩
  | some next => ⟨deposit buf op.offset op.bits next,
      some (if op.opcode = .set then old else next), counted op.bits old next grown⟩

def nextValue (op : Op) (old : Int) : Option Int :=
  let value := if op.opcode = .incr then old else
    if op.signed then op.arg else machineUnsigned op.arg
  let incr := if op.opcode = .incr then op.arg else 0
  if op.overflow = .wrap then
    some (if op.signed then (wrapBits op.bits value incr).toInt
      else (wrapBits op.bits value incr).toNat)
  else
    let d := direction op value incr
    if d = 0 then some (value + incr)
    else if op.overflow = .sat then
      some (if d > 0 then top op.bits op.signed else bottom op.bits op.signed)
    else none

def applyOp (buf : Buffer) (op : Op) (grown : Bool) : Result :=
  if op.opcode = .get then ⟨buf, some (getField buf op), false⟩
  else finish buf op (getField buf op) (nextValue op (getField buf op)) grown

def needBytes (ops : List Op) : Nat :=
  ops.foldl (fun n op => if op.opcode = .get then n else max n ((op.offset + op.bits - 1) / 8 + 1)) 0

def grow (buf : Buffer) (need : Nat) : Buffer :=
  buf ++ Array.replicate (need - buf.size) 0

structure Execution where
  buf : Buffer
  replies : List (Option Int)
  changes : Nat
  deriving Repr

def runOps (ops : List Op) (grown : Bool) (buf : Buffer) : Execution :=
  match ops with
  | [] => ⟨buf, [], 0⟩
  | op :: rest =>
    let first := applyOp buf op grown
    let tail := runOps rest grown first.buf
    ⟨tail.buf, first.reply :: tail.replies, (if first.counted then 1 else 0) + tail.changes⟩

def execute (buf : Buffer) (ops : List Op) : Execution :=
  let data := grow buf (needBytes ops)
  runOps ops (data.size > buf.size) data

theorem finish_failure_preserves (buf : Buffer) (op : Op) (old : Int) (grown : Bool) :
    finish buf op old none grown = ⟨buf, none, false⟩ := rfl

theorem apply_failure_preserves (buf : Buffer) (op : Op) (grown : Bool)
    (hw : op.opcode ≠ .get) (hf : nextValue op (getField buf op) = none) :
    applyOp buf op grown = ⟨buf, none, false⟩ := by
  simp [applyOp, hw, hf, finish]

theorem reads_preserve (buf : Buffer) (op : Op) (grown : Bool) (h : op.opcode = .get) :
    applyOp buf op grown = ⟨buf, some (getField buf op), false⟩ := by
  simp [applyOp, h]

theorem counted_when_grown (bits : Nat) (old next : Int) :
    counted bits old next true = true := by simp [counted]

theorem unchanged_not_counted (bits : Nat) (old : Int) :
    counted bits old old false = false := by simp [counted, changedWord]

theorem mask_as_allOnes (bits : Nat) (h : bits ≤ 64) :
    mask bits = (BitVec.allOnes bits).setWidth 64 := by
  have finite : ∀ b : Fin 65, mask b.val = (BitVec.allOnes b.val).setWidth 64 := by decide
  exact finite ⟨bits, by omega⟩

theorem mask_truncates (bits : Nat) (x : BitVec 64) (h : bits ≤ 64) :
    x &&& mask bits = (x.setWidth bits).setWidth 64 := by
  rw [mask_as_allOnes bits h]
  apply BitVec.eq_of_getLsbD_eq_iff.mpr
  intro i hi
  simp [hi, Bool.and_comm]

theorem masked_xor_refines (bits : Nat) (old next : BitVec 64) (h : bits ≤ 64) :
    ((old ^^^ next) &&& mask bits) = 0 ↔ old.setWidth bits = next.setWidth bits := by
  rw [mask_truncates bits _ h, BitVec.setWidth_xor]
  constructor
  · intro hz
    have hz' := congrArg (BitVec.setWidth bits) hz
    simpa [BitVec.setWidth_setWidth_of_le _ h, BitVec.xor_eq_zero_iff] using hz'
  · intro heq
    simp [heq]

theorem counted_refines (bits : Nat) (h : bits ≤ 64) (old next : Int) (grown : Bool) :
    counted bits old next grown = true ↔ grown = true ∨
      (word old).setWidth bits ≠ (word next).setWidth bits := by
  simp [counted, changedWord]
  exact or_congr Iff.rfl (not_congr (masked_xor_refines bits (word old) (word next) h))

theorem fail_rejects_direction (op : Op) (old : Int)
    (hf : op.overflow = .fail)
    (hd : direction op (if op.opcode = .incr then old else
      if op.signed then op.arg else machineUnsigned op.arg)
      (if op.opcode = .incr then op.arg else 0) ≠ 0) :
    nextValue op old = none := by
  simp [nextValue, hf, hd]

theorem unsigned_fail_accepts (op : Op) (old : Int)
    (hf : op.overflow = .fail) (hs : op.signed = false)
    (hv : 0 ≤ old ∧ old ≤ top op.bits false) (hc : op.opcode = .incr)
    (hin : 0 ≤ old + op.arg ∧ old + op.arg ≤ top op.bits false) :
    nextValue op old = some (old + op.arg) := by
  have hd := unsigned_direction_refines old op.arg (top op.bits false) hv.1 (Or.inl hv.2)
  have hz : directionSpec (old + op.arg) 0 (top op.bits false) = 0 := by
    unfold directionSpec
    split <;> (try split) <;> omega
  simp [nextValue, hf, hc, direction, hs, hd, hz]

theorem narrow_fail_accepts (op : Op) (old : Int)
    (hf : op.overflow = .fail) (hs : op.signed = true) (hb : op.bits < 64)
    (hv : bottom op.bits true ≤ old ∧ old ≤ top op.bits true) (hc : op.opcode = .incr)
    (hin : bottom op.bits true ≤ old + op.arg ∧ old + op.arg ≤ top op.bits true) :
    nextValue op old = some (old + op.arg) := by
  obtain ⟨hlo, hlo', hhi, hhi'⟩ := narrow_headroom op.bits hb old hv
  have hd := narrow_direction_refines old op.arg _ _ hlo hlo' hhi hhi' (Or.inl hv)
  have hz : directionSpec (old + op.arg) (bottom op.bits true) (top op.bits true) = 0 := by
    unfold directionSpec
    split <;> (try split) <;> omega
  simp [nextValue, hf, hc, direction, hs, hb, hd, hz]

theorem wide_fail_accepts (op : Op) (old : Int)
    (hf : op.overflow = .fail) (hs : op.signed = true) (hb : op.bits = 64)
    (hv : -(2 : Int) ^ 63 ≤ old ∧ old ≤ (2 : Int) ^ 63 - 1)
    (ha : -(2 : Int) ^ 63 ≤ op.arg ∧ op.arg ≤ (2 : Int) ^ 63 - 1)
    (hc : op.opcode = .incr)
    (hin : -(2 : Int) ^ 63 ≤ old + op.arg ∧ old + op.arg ≤ (2 : Int) ^ 63 - 1) :
    nextValue op old = some (old + op.arg) := by
  have hd := wide_direction_refines old op.arg hv ha
  have hz : directionSpec (old + op.arg) (-(2 : Int) ^ 63) ((2 : Int) ^ 63 - 1) = 0 := by
    unfold directionSpec
    split <;> (try split) <;> omega
  have hz' : signedWideDirection old op.arg (-9223372036854775808) 9223372036854775807 = 0 := by
    simpa using hd.trans hz
  simp [nextValue, hf, hc, direction, hs, hb, top, bottom, hz']

theorem unsigned_fail_refines (op : Op) (old : Int)
    (hf : op.overflow = .fail) (hs : op.signed = false)
    (hv : 0 ≤ old ∧ old ≤ top op.bits false) (hc : op.opcode = .incr)
    (hout : old + op.arg < 0 ∨ old + op.arg > top op.bits false) :
    nextValue op old = none := by
  apply fail_rejects_direction op old hf
  simp [hc, direction, hs]
  rw [unsigned_direction_refines old op.arg _ hv.1 (Or.inl hv.2)]
  unfold directionSpec
  split <;> (try split) <;> omega

theorem narrow_fail_refines (op : Op) (old : Int)
    (hf : op.overflow = .fail) (hs : op.signed = true) (hb : op.bits < 64)
    (hv : bottom op.bits true ≤ old ∧ old ≤ top op.bits true) (hc : op.opcode = .incr)
    (hout : old + op.arg < bottom op.bits true ∨ old + op.arg > top op.bits true) :
    nextValue op old = none := by
  apply fail_rejects_direction op old hf
  simp [hc, direction, hs, hb]
  obtain ⟨hlo, hlo', hhi, hhi'⟩ := narrow_headroom op.bits hb old hv
  rw [narrow_direction_refines old op.arg _ _ hlo hlo' hhi hhi' (Or.inl hv)]
  unfold directionSpec
  split <;> (try split) <;> omega

theorem wide_fail_refines (op : Op) (old : Int)
    (hf : op.overflow = .fail) (hs : op.signed = true) (hb : op.bits = 64)
    (hv : -(2 : Int) ^ 63 ≤ old ∧ old ≤ (2 : Int) ^ 63 - 1)
    (ha : -(2 : Int) ^ 63 ≤ op.arg ∧ op.arg ≤ (2 : Int) ^ 63 - 1)
    (hc : op.opcode = .incr)
    (hout : old + op.arg < -(2 : Int) ^ 63 ∨ old + op.arg > (2 : Int) ^ 63 - 1) :
    nextValue op old = none := by
  apply fail_rejects_direction op old hf
  simp [hc, direction, hs, hb, top, bottom]
  have hd := wide_direction_refines old op.arg hv ha
  simp only [show (-(2 : Int) ^ 63) = -9223372036854775808 by decide,
    show ((2 : Int) ^ 63 - 1) = 9223372036854775807 by decide] at hd
  rw [hd]
  unfold directionSpec
  split <;> (try split) <;> omega

theorem runOps_append (xs ys : List Op) (grown : Bool) (buf : Buffer) :
    runOps (xs ++ ys) grown buf =
      let first := runOps xs grown buf
      let last := runOps ys grown first.buf
      ⟨last.buf, first.replies ++ last.replies, first.changes + last.changes⟩ := by
  induction xs generalizing buf with
  | nil => simp [runOps]
  | cons op rest ih =>
    simp [runOps, ih, Nat.add_assoc]

theorem all_reads_no_changes (ops : List Op) (grown : Bool) (buf : Buffer)
    (h : ∀ op ∈ ops, op.opcode = .get) :
    (runOps ops grown buf).buf = buf ∧ (runOps ops grown buf).changes = 0 := by
  induction ops with
  | nil => simp [runOps]
  | cons op rest ih =>
    have ho := h op (by simp)
    have hr : ∀ x ∈ rest, x.opcode = .get := by
      intro x hx
      exact h x (by simp [hx])
    simp [runOps, reads_preserve buf op grown ho, ih hr]

end Bitfield
