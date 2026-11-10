import Vectors.Bits

namespace Vectors

def dimMax : Nat := 2 ^ 19

def projectionValid (input output : Nat) : Bool :=
  decide (1 ≤ input) && decide (input ≤ dimMax) && decide (1 ≤ output) && decide (output ≤ input)

def hadamardSign (row col : Nat) : Int :=
  if popcount (row &&& col) &&& 1 ≠ 0 then -1 else 1

def rowDot (n j k : Nat) : Int := sumTo (fun i => hadamardSign j i * hadamardSign k i) n

def walsh (c n : Nat) : Int := sumTo (hadamardSign c) n

def lowBit (c : Nat) : Nat :=
  if c = 0 then 0 else if c % 2 = 1 then 0 else lowBit (c / 2) + 1
termination_by c
decreasing_by omega

def gram (n j k : Nat) : Int :=
  if j = k then n else
    let c := j ^^^ k
    let p := 2 ^ (lowBit c + 1)
    let r := n % p
    hadamardSign c (n - r) * (min r (p - r) : Nat)

theorem hadamardSign_eq (row col : Nat) :
    hadamardSign row col = if popcount (row &&& col) % 2 = 1 then -1 else 1 := by
  unfold hadamardSign
  rw [Nat.and_one_is_mod]
  by_cases h : popcount (row &&& col) % 2 = 1 <;> simp [h] <;> omega

theorem hadamardSign_comm (row col : Nat) : hadamardSign row col = hadamardSign col row := by
  unfold hadamardSign; rw [Nat.and_comm row col]

theorem xor_eq_zero_imp {j k : Nat} (h : j ^^^ k = 0) : j = k := by
  apply Nat.eq_of_testBit_eq
  intro i
  have := congrArg (fun x => x.testBit i) h
  simp only [Nat.testBit_xor, Nat.zero_testBit] at this
  revert this
  cases j.testBit i <;> cases k.testBit i <;> simp

theorem hadamardSign_mul (x y i : Nat) :
    hadamardSign x i * hadamardSign y i = hadamardSign (x ^^^ y) i := by
  rw [hadamardSign_eq, hadamardSign_eq, hadamardSign_eq]
  unfold popcount
  have h := bitCount_parity x y i 64
  split <;> split <;> split <;> omega

theorem hadamardSign_zero (i : Nat) : hadamardSign 0 i = 1 := by
  rw [hadamardSign_eq]
  simp [popcount, bitCount_zero]

theorem block_xor {w q t : Nat} (ht : t < 2 ^ w) : 2 ^ w * q + t = (2 ^ w * q) ^^^ t := by
  apply Nat.eq_of_testBit_eq
  intro j
  rw [Nat.testBit_two_pow_mul_add q ht, Nat.testBit_xor, Nat.testBit_two_pow_mul]
  by_cases hj : j < w
  · have : ¬ w ≤ j := by omega
    simp [hj, this]
  · have hb : t.testBit j = false :=
      Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le ht (Nat.pow_le_pow_right (by omega) (by omega)))
    simp [hj, hb]
    omega

theorem sign_block (c w q t : Nat) (ht : t < 2 ^ w) :
    hadamardSign c (2 ^ w * q + t) = hadamardSign c (2 ^ w * q) * hadamardSign c t := by
  rw [block_xor ht, hadamardSign_comm, ← hadamardSign_mul, hadamardSign_comm (2 ^ w * q), hadamardSign_comm t]

theorem lowBit_spec (c : Nat) (hc : c ≠ 0) :
    c.testBit (lowBit c) = true ∧ ∀ u, u < lowBit c → c.testBit u = false := by
  induction c using Nat.strongRecOn with
  | ind c ih =>
    unfold lowBit
    simp only [hc, ite_false]
    by_cases ho : c % 2 = 1
    · simp only [ho, ite_true]
      exact ⟨by simp [Nat.testBit_zero, ho], fun u hu => by omega⟩
    · simp only [ho, ite_false]
      have hh : c / 2 ≠ 0 := by omega
      obtain ⟨h1, h2⟩ := ih (c / 2) (by omega) hh
      refine ⟨by rw [Nat.testBit_succ]; exact h1, fun u hu => ?_⟩
      cases u with
      | zero => simp [Nat.testBit_zero]; omega
      | succ u => rw [Nat.testBit_succ]; exact h2 u (by omega)

theorem lowBit_lt {c m : Nat} (hc : c ≠ 0) (hm : c < 2 ^ m) : lowBit c < m := by
  have h := (lowBit_spec c hc).1
  have := Nat.ge_two_pow_of_testBit h
  by_cases hl : lowBit c < m
  · exact hl
  · have : 2 ^ m ≤ 2 ^ lowBit c := Nat.pow_le_pow_right (by omega) (by omega)
    omega

section closed

variable {c s : Nat} (hs : c.testBit s = true) (hlow : ∀ u, u < s → c.testBit u = false) (h64 : s < 64)
include hs hlow h64

set_option linter.unusedSectionVars false

theorem sign_low (t : Nat) (ht : t < 2 ^ s) : hadamardSign c t = 1 := by
  rw [hadamardSign_eq]
  have : popcount (c &&& t) = 0 := by
    unfold popcount
    apply bitCount_of_clear
    intro u _
    rw [Nat.testBit_and]
    by_cases hu : u < s
    · rw [hlow u hu]; simp
    · have : t.testBit u = false :=
        Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le ht (Nat.pow_le_pow_right (by omega) (by omega)))
      rw [this]; simp
  rw [this]; simp

theorem sign_high (t : Nat) (ht : t < 2 ^ s) : hadamardSign c (2 ^ s + t) = -1 := by
  rw [hadamardSign_eq]
  have : popcount (c &&& (2 ^ s + t)) = 1 := by
    unfold popcount
    rw [← bitCount_two_pow h64]
    apply bitCount_congr
    intro u _
    have e : 2 ^ s + t = 2 ^ s * 1 + t := by omega
    rw [e, Nat.testBit_and, Nat.testBit_two_pow_mul_add 1 ht, Nat.testBit_two_pow]
    by_cases hu : u < s
    · rw [hlow u hu]; simp; omega
    · by_cases he : u = s
      · subst he; simp [hs]
      · have hk : u - s ≠ 0 := by omega
        have h1 : (1 : Nat).testBit (u - s) = false := by
          obtain ⟨k, hk'⟩ : ∃ k, u - s = k + 1 := ⟨u - s - 1, by omega⟩
          rw [hk', Nat.testBit_succ]; simp
        simp [hu, h1]; omega
  rw [this]; simp

theorem walsh_block : walsh c (2 ^ (s + 1)) = 0 := by
  unfold walsh
  have e : 2 ^ (s + 1) = 2 ^ s + 2 ^ s := by rw [Nat.pow_succ]; omega
  rw [e, sumTo_add]
  rw [sumTo_congr (2 ^ s) (fun i hi => sign_low hs hlow h64 i hi)]
  rw [sumTo_congr (2 ^ s) (fun i hi => sign_high hs hlow h64 i hi)]
  rw [sumTo_const, sumTo_const]
  omega

theorem walsh_full (q : Nat) : walsh c (2 ^ (s + 1) * q) = 0 := by
  induction q with
  | zero => simp [walsh, sumTo]
  | succ q ih =>
    unfold walsh at *
    rw [Nat.mul_succ, sumTo_add, ih]
    rw [sumTo_congr (2 ^ (s + 1)) (fun t ht => sign_block c (s + 1) q t ht)]
    rw [sumTo_mul_left]
    have := walsh_block hs hlow h64
    unfold walsh at this
    rw [this]; simp

theorem walsh_tail (r : Nat) (hr : r ≤ 2 ^ (s + 1)) : walsh c r = (min r (2 ^ (s + 1) - r) : Nat) := by
  unfold walsh
  have e : 2 ^ (s + 1) = 2 ^ s + 2 ^ s := by rw [Nat.pow_succ]; omega
  by_cases hlo : r ≤ 2 ^ s
  · rw [sumTo_congr r (fun i hi => sign_low hs hlow h64 i (by omega)), sumTo_const]
    have : min r (2 ^ (s + 1) - r) = r := by omega
    rw [this]; simp
  · obtain ⟨r', hr'⟩ : ∃ r', r = 2 ^ s + r' := ⟨r - 2 ^ s, by omega⟩
    subst hr'
    rw [sumTo_add, sumTo_congr (2 ^ s) (fun i hi => sign_low hs hlow h64 i hi)]
    rw [sumTo_congr r' (fun i hi => sign_high hs hlow h64 i (by omega))]
    rw [sumTo_const, sumTo_const, e]
    rw [e] at hr
    generalize 2 ^ s = P at *
    have : min (P + r') (P + P - (P + r')) = P - r' := by omega
    rw [this]
    omega

theorem walsh_closed (n : Nat) :
    walsh c n = hadamardSign c (n - n % 2 ^ (s + 1)) *
      (min (n % 2 ^ (s + 1)) (2 ^ (s + 1) - n % 2 ^ (s + 1)) : Nat) := by
  have hp : 0 < 2 ^ (s + 1) := Nat.two_pow_pos _
  have split := Nat.div_add_mod n (2 ^ (s + 1))
  have hr := Nat.mod_lt n hp
  have hbase : n - n % 2 ^ (s + 1) = 2 ^ (s + 1) * (n / 2 ^ (s + 1)) := by omega
  rw [hbase]
  conv => lhs; rw [← split]
  unfold walsh
  rw [sumTo_add]
  have h0 := walsh_full hs hlow h64 (n / 2 ^ (s + 1))
  unfold walsh at h0
  rw [h0, sumTo_congr (n % 2 ^ (s + 1)) (fun t ht => sign_block c (s + 1) _ t (by omega))]
  rw [sumTo_mul_left]
  have ht := walsh_tail hs hlow h64 (n % 2 ^ (s + 1)) (by omega)
  unfold walsh at ht
  rw [ht]
  simp

end closed

theorem rowDot_walsh (n j k : Nat) : rowDot n j k = walsh (j ^^^ k) n := by
  unfold rowDot walsh
  exact sumTo_congr n (fun i _ => hadamardSign_mul j k i)

theorem rowDot_self (n j : Nat) : rowDot n j j = n := by
  rw [rowDot_walsh, Nat.xor_self]
  unfold walsh
  rw [sumTo_congr n (fun i _ => hadamardSign_zero i), sumTo_const]
  simp

theorem rowDot_gram (n j k : Nat) (hj : j < 2 ^ 64) (hk : k < 2 ^ 64) : rowDot n j k = gram n j k := by
  unfold gram
  by_cases he : j = k
  · subst he; simp [rowDot_self]
  · simp only [he, ite_false]
    have hc : j ^^^ k ≠ 0 := by
      intro h
      exact he (xor_eq_zero_imp h)
    obtain ⟨h1, h2⟩ := lowBit_spec (j ^^^ k) hc
    have h64 := lowBit_lt hc (Nat.xor_lt_two_pow hj hk)
    rw [rowDot_walsh, walsh_closed h1 h2 h64]

theorem rows_orthogonal_pow2 (m j k : Nat) (hm : m ≤ 64) (hj : j < 2 ^ m) (hk : k < 2 ^ m) :
    rowDot (2 ^ m) j k = if j = k then (2 ^ m : Nat) else 0 := by
  by_cases he : j = k
  · subst he; simp [rowDot_self]
  · simp only [he, ite_false]
    have hc : j ^^^ k ≠ 0 := fun h => he (xor_eq_zero_imp h)
    obtain ⟨h1, h2⟩ := lowBit_spec (j ^^^ k) hc
    have hlt := lowBit_lt hc (Nat.xor_lt_two_pow hj hk)
    rw [rowDot_walsh, walsh_closed h1 h2 (by omega)]
    have hd : 2 ^ m % 2 ^ (lowBit (j ^^^ k) + 1) = 0 := by
      apply Nat.mod_eq_zero_of_dvd
      exact Nat.pow_dvd_pow 2 (by omega)
    rw [hd]
    simp

theorem hadamardSign_cases (x y : Nat) : hadamardSign x y = 1 ∨ hadamardSign x y = -1 := by
  unfold hadamardSign; split <;> simp

theorem mod_two_pow_odd (a o : Nat) (ho : o % 2 = 1) : (2 ^ a * o) % 2 ^ (a + 1) = 2 ^ a := by
  have e : 2 ^ a * o = 2 ^ (a + 1) * (o / 2) + 2 ^ a := by
    have : o = 2 * (o / 2) + 1 := by omega
    conv => lhs; rw [this]
    rw [Nat.mul_add, Nat.mul_one, ← Nat.mul_assoc, ← Nat.pow_succ]
  rw [e, Nat.mul_add_mod]
  exact Nat.mod_eq_of_lt (Nat.pow_lt_pow_right (by omega) (by omega))

theorem rows_prefix_orthogonal_iff (a o out : Nat) (ho : o % 2 = 1) (ha : a < 64) :
    (∀ j k, j < out → k < out → j ≠ k → rowDot (2 ^ a * o) j k = 0) ↔ out ≤ 2 ^ a := by
  constructor
  · intro h
    by_cases hout : out ≤ 2 ^ a
    · exact hout
    · exfalso
      have hpos : 0 < 2 ^ a := Nat.two_pow_pos a
      have := h 0 (2 ^ a) (by omega) (by omega) (by omega)
      rw [rowDot_walsh, Nat.zero_xor] at this
      have hs : (2 ^ a).testBit a = true := by rw [Nat.testBit_two_pow]; simp
      have hlow : ∀ u, u < a → (2 ^ a).testBit u = false := by
        intro u hu; rw [Nat.testBit_two_pow]; simp; omega
      rw [walsh_closed hs hlow ha, mod_two_pow_odd a o ho] at this
      have hm : min (2 ^ a) (2 ^ (a + 1) - 2 ^ a) = 2 ^ a := by rw [Nat.pow_succ]; omega
      rw [hm] at this
      rcases hadamardSign_cases (2 ^ a) (2 ^ a * o - 2 ^ a) with h1 | h1 <;> rw [h1] at this <;> omega
  · intro hout j k hj hk hne
    have hc : j ^^^ k ≠ 0 := fun h => hne (xor_eq_zero_imp h)
    obtain ⟨h1, h2⟩ := lowBit_spec (j ^^^ k) hc
    have hlt := lowBit_lt hc (Nat.xor_lt_two_pow (by omega : j < 2 ^ a) (by omega : k < 2 ^ a))
    rw [rowDot_walsh, walsh_closed h1 h2 (by omega)]
    have hd : (2 ^ a * o) % 2 ^ (lowBit (j ^^^ k) + 1) = 0 := by
      apply Nat.mod_eq_zero_of_dvd
      exact Nat.dvd_trans (Nat.pow_dvd_pow 2 (by omega)) (Nat.dvd_mul_right _ _)
    rw [hd]
    simp

def twoVal (n : Nat) : Nat := if n = 0 then 0 else if n % 2 = 1 then 0 else twoVal (n / 2) + 1
termination_by n
decreasing_by omega

theorem twoVal_spec (n : Nat) (hn : n ≠ 0) : ∃ o, o % 2 = 1 ∧ n = 2 ^ twoVal n * o := by
  induction n using Nat.strongRecOn with
  | ind n ih =>
    unfold twoVal
    simp only [hn, ite_false]
    by_cases ho : n % 2 = 1
    · simp only [ho, ite_true]; exact ⟨n, ho, by simp⟩
    · simp only [ho, ite_false]
      obtain ⟨o, h1, h2⟩ := ih (n / 2) (by omega) (by omega)
      refine ⟨o, h1, ?_⟩
      rw [Nat.pow_succ, Nat.mul_comm (2 ^ twoVal (n / 2)) 2, Nat.mul_assoc, ← h2]
      omega

theorem twoVal_lt (n : Nat) (hn : n ≠ 0) (hb : n < 2 ^ 64) : twoVal n < 64 := by
  obtain ⟨o, h1, h2⟩ := twoVal_spec n hn
  have ho : 1 ≤ o := by omega
  have : 2 ^ twoVal n ≤ n := by
    calc 2 ^ twoVal n ≤ 2 ^ twoVal n * o := Nat.le_mul_of_pos_right _ ho
      _ = n := h2.symm
  by_cases ht : twoVal n < 64
  · exact ht
  · have : 2 ^ 64 ≤ 2 ^ twoVal n := Nat.pow_le_pow_right (by omega) (by omega)
    omega

theorem projection_rows_orthogonal_iff (input output : Nat) (hv : projectionValid input output = true) :
    (∀ j k, j < output → k < output → j ≠ k → rowDot input j k = 0) ↔ output ≤ 2 ^ twoVal input := by
  simp only [projectionValid, dimMax, Bool.and_eq_true, decide_eq_true_eq] at hv
  obtain ⟨⟨⟨h1, h2⟩, _⟩, _⟩ := hv
  have h2 : input ≤ 2 ^ 19 := of_decide_eq_true h2
  have hb : input < 2 ^ 64 := Nat.lt_of_le_of_lt h2 (by decide)
  obtain ⟨o, ho, he⟩ := twoVal_spec input (by omega)
  have ht := twoVal_lt input (by omega) hb
  conv => lhs; rw [he]
  exact rows_prefix_orthogonal_iff (twoVal input) o output ho ht

theorem projection_rows_pow2 (m output j k : Nat) (hv : projectionValid (2 ^ m) output = true)
    (hj : j < output) (hk : k < output) : rowDot (2 ^ m) j k = if j = k then (2 ^ m : Nat) else 0 := by
  simp only [projectionValid, dimMax, Bool.and_eq_true, decide_eq_true_eq] at hv
  obtain ⟨⟨⟨_, h2⟩, _⟩, h4⟩ := hv
  have h2 : 2 ^ m ≤ 2 ^ 19 := of_decide_eq_true h2
  have hm : m ≤ 19 := by
    by_cases h : m ≤ 19
    · exact h
    · have : 2 ^ 20 ≤ 2 ^ m := Nat.pow_le_pow_right (by omega) (by omega)
      have : 2 ^ m ≤ 2 ^ 19 := h2
      have : (2 : Nat) ^ 19 < 2 ^ 20 := by decide
      omega
  exact rows_orthogonal_pow2 m j k (by omega) (by omega) (by omega)

theorem rows_counterexample : rowDot 3 0 1 = 1 ∧ projectionValid 3 2 = true := by decide

theorem rows_counterexample_768 : rowDot 768 0 256 = 256 ∧ projectionValid 768 257 = true := by
  refine ⟨?_, by decide⟩
  have hs : (256 : Nat).testBit 8 = true := by decide
  have hlow : ∀ u, u < 8 → (256 : Nat).testBit u = false := by decide
  rw [rowDot_walsh, Nat.zero_xor, walsh_closed hs hlow (by decide)]
  decide

end Vectors
