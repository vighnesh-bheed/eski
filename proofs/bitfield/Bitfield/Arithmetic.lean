import Std

namespace Bitfield

def word (x : Int) : BitVec 64 := BitVec.ofInt 64 x

def machineSigned (x : Int) : Int := (word x).toInt

def machineUnsigned (x : Int) : Int := (word x).toNat

def wrapBits (bits : Nat) (value incr : Int) : BitVec bits :=
  (word value + word incr).setWidth bits

def unsignedSpec (bits : Nat) (target : Int) : Nat :=
  (target % (2 ^ bits : Nat)).toNat

def signedSpec (bits : Nat) (target : Int) : Int :=
  target.bmod (2 ^ bits)

theorem narrow_word (bits : Nat) (h : bits ≤ 64) (x : Int) :
    (word x).setWidth bits = BitVec.ofInt bits x := by
  apply BitVec.eq_of_toInt_eq
  rw [← BitVec.signExtend_eq_setWidth_of_le _ h]
  rw [BitVec.toInt_signExtend_eq_toInt_bmod_of_le _ h]
  simp only [word, BitVec.toInt_ofInt]
  exact Int.bmod_bmod_of_dvd (Nat.pow_dvd_pow 2 h)

theorem wrap_refines (bits : Nat) (h : bits ≤ 64) (value incr : Int) :
    wrapBits bits value incr = BitVec.ofInt bits (value + incr) := by
  unfold wrapBits word
  rw [← BitVec.ofInt_add]
  exact narrow_word bits h (value + incr)

theorem unsigned_wrap_modular (bits : Nat) (h : bits ≤ 64) (value incr : Int) :
    (wrapBits bits value incr).toNat = unsignedSpec bits (value + incr) := by
  rw [wrap_refines bits h]
  exact BitVec.toNat_ofInt _

theorem signed_wrap_modular (bits : Nat) (h : bits ≤ 64) (value incr : Int) :
    (wrapBits bits value incr).toInt = signedSpec bits (value + incr) := by
  rw [wrap_refines bits h]
  exact BitVec.toInt_ofInt _

theorem unsigned_wrap_range (bits : Nat) (value incr : Int) :
    (wrapBits bits value incr).toNat < 2 ^ bits :=
  (wrapBits bits value incr).isLt

theorem signed_wrap_range (bits : Nat) (value incr : Int) :
    -(2 : Int) ^ (bits - 1) ≤ (wrapBits bits value incr).toInt ∧
      (wrapBits bits value incr).toInt < (2 : Int) ^ (bits - 1) := by
  exact ⟨BitVec.le_toInt _, BitVec.toInt_lt⟩

def top (bits : Nat) (signed : Bool) : Int :=
  if signed then (2 : Int) ^ (bits - 1) - 1 else (2 : Int) ^ bits - 1

def bottom (bits : Nat) (signed : Bool) : Int :=
  if signed then -(2 : Int) ^ (bits - 1) else 0

def unsignedDirection (value incr hi : Int) : Int :=
  if value > hi ∨ (incr > 0 ∧ incr > hi - value) then 1
  else if incr < 0 ∧ -incr > value then -1 else 0

def signedNarrowDirection (value incr lo hi : Int) : Int :=
  if value > hi ∨ incr > machineSigned (hi - value) then 1
  else if value < lo ∨ incr < machineSigned (lo - value) then -1 else 0

def signedWideDirection (value incr lo hi : Int) : Int :=
  if value ≥ 0 ∧ incr > 0 ∧ incr > hi - value then 1
  else if value < 0 ∧ incr < 0 ∧ incr < lo - value then -1 else 0

def directionSpec (target lo hi : Int) : Int :=
  if target > hi then 1 else if target < lo then -1 else 0

def clamp (target lo hi : Int) : Int := max lo (min hi target)

def saturate (direction target lo hi : Int) : Int :=
  if direction = 0 then target else if direction > 0 then hi else lo

theorem machineSigned_exact (x : Int)
    (lo : -(2 : Int) ^ 63 ≤ x) (hi : x < (2 : Int) ^ 63) :
    machineSigned x = x := by
  exact BitVec.toInt_ofInt_eq_self (by decide) lo hi

theorem unsigned_direction_refines (value incr hi : Int)
    (hv : 0 ≤ value) (hh : value ≤ hi ∨ incr = 0) :
    unsignedDirection value incr hi = directionSpec (value + incr) 0 hi := by
  unfold unsignedDirection directionSpec
  split <;> split <;> (try split) <;> omega

theorem narrow_direction_refines (value incr lo hi : Int)
    (hlo : -(2 : Int) ^ 63 ≤ lo - value)
    (hlo' : lo - value < (2 : Int) ^ 63)
    (hhi : -(2 : Int) ^ 63 ≤ hi - value)
    (hhi' : hi - value < (2 : Int) ^ 63)
    (hv : lo ≤ value ∧ value ≤ hi ∨ incr = 0) :
    signedNarrowDirection value incr lo hi = directionSpec (value + incr) lo hi := by
  unfold signedNarrowDirection
  rw [machineSigned_exact (hi - value) hhi hhi', machineSigned_exact (lo - value) hlo hlo']
  unfold directionSpec
  split <;> split <;> (try split) <;> omega

theorem wide_direction_refines (value incr : Int)
    (hv : -(2 : Int) ^ 63 ≤ value ∧ value ≤ (2 : Int) ^ 63 - 1)
    (hi : -(2 : Int) ^ 63 ≤ incr ∧ incr ≤ (2 : Int) ^ 63 - 1) :
    signedWideDirection value incr (-(2 : Int) ^ 63) ((2 : Int) ^ 63 - 1) =
      directionSpec (value + incr) (-(2 : Int) ^ 63) ((2 : Int) ^ 63 - 1) := by
  unfold signedWideDirection directionSpec
  split <;> split <;> (try split) <;> omega

theorem saturation_clamps (target lo hi : Int) (h : lo ≤ hi) :
    saturate (directionSpec target lo hi) target lo hi = clamp target lo hi := by
  by_cases hu : target > hi
  · have ht : hi ≤ target := by omega
    simp [saturate, directionSpec, hu, clamp, Int.min_eq_left ht, Int.max_eq_right h]
  · by_cases hl : target < lo
    · have ht : target ≤ hi := by omega
      have ht' : target ≤ lo := by omega
      simp [saturate, directionSpec, hu, hl, clamp, Int.min_eq_right ht, Int.max_eq_left ht']
    · have ht : target ≤ hi := by omega
      have ht' : lo ≤ target := by omega
      simp [saturate, directionSpec, hu, hl, clamp, Int.min_eq_right ht, Int.max_eq_right ht']

theorem unsigned_sat_clamps (value incr hi : Int)
    (hv : 0 ≤ value) (hh : value ≤ hi ∨ incr = 0) (ht : 0 ≤ hi) :
    saturate (unsignedDirection value incr hi) (value + incr) 0 hi =
      clamp (value + incr) 0 hi := by
  rw [unsigned_direction_refines value incr hi hv hh]
  exact saturation_clamps _ _ _ ht

theorem narrow_sat_clamps (value incr lo hi : Int)
    (hlo : -(2 : Int) ^ 63 ≤ lo - value)
    (hlo' : lo - value < (2 : Int) ^ 63)
    (hhi : -(2 : Int) ^ 63 ≤ hi - value)
    (hhi' : hi - value < (2 : Int) ^ 63)
    (hv : lo ≤ value ∧ value ≤ hi ∨ incr = 0) (ht : lo ≤ hi) :
    saturate (signedNarrowDirection value incr lo hi) (value + incr) lo hi =
      clamp (value + incr) lo hi := by
  rw [narrow_direction_refines value incr lo hi hlo hlo' hhi hhi' hv]
  exact saturation_clamps _ _ _ ht

theorem narrow_headroom (bits : Nat) (hbits : bits < 64) (value : Int)
    (hv : bottom bits true ≤ value ∧ value ≤ top bits true) :
    -(2 : Int) ^ 63 ≤ bottom bits true - value ∧
      bottom bits true - value < (2 : Int) ^ 63 ∧
      -(2 : Int) ^ 63 ≤ top bits true - value ∧
      top bits true - value < (2 : Int) ^ 63 := by
  have bound : ∀ b : Fin 64, 1 ≤ (2 : Int) ^ (b.val - 1) ∧
      (2 : Int) ^ (b.val - 1) ≤ (2 : Int) ^ 62 := by decide
  have hb := bound ⟨bits, hbits⟩
  simp only [bottom, top, ↓reduceIte] at *
  omega

theorem narrow_incr_sat_clamps (bits : Nat) (hbits : bits < 64) (value incr : Int)
    (hv : bottom bits true ≤ value ∧ value ≤ top bits true) :
    saturate (signedNarrowDirection value incr (bottom bits true) (top bits true))
      (value + incr) (bottom bits true) (top bits true) =
      clamp (value + incr) (bottom bits true) (top bits true) := by
  obtain ⟨hlo, hlo', hhi, hhi'⟩ := narrow_headroom bits hbits value hv
  exact narrow_sat_clamps value incr _ _ hlo hlo' hhi hhi' (Or.inl hv) (by omega)

theorem wide_sat_clamps (value incr : Int)
    (hv : -(2 : Int) ^ 63 ≤ value ∧ value ≤ (2 : Int) ^ 63 - 1)
    (hi : -(2 : Int) ^ 63 ≤ incr ∧ incr ≤ (2 : Int) ^ 63 - 1) :
    saturate (signedWideDirection value incr (-(2 : Int) ^ 63) ((2 : Int) ^ 63 - 1))
      (value + incr) (-(2 : Int) ^ 63) ((2 : Int) ^ 63 - 1) =
      clamp (value + incr) (-(2 : Int) ^ 63) ((2 : Int) ^ 63 - 1) := by
  rw [wide_direction_refines value incr hv hi]
  exact saturation_clamps _ _ _ (by decide)

theorem signed_set_sat_exception :
    saturate (signedNarrowDirection (-9223372036854775808) 0 (-128) 127)
      (-9223372036854775808) (-128) 127 = 127 ∧
      clamp (-9223372036854775808) (-128) 127 = -128 := by decide

end Bitfield
