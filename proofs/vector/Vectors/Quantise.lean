import Vectors.Bits

namespace Vectors

def q8Scale : Rat := 127

def clampR (x lo hi : Rat) : Rat := min (max x lo) hi

def roundHalfAway (t : Rat) : Int :=
  if t < 0 then -((-t + 1 / 2).floor) else (t + 1 / 2).floor

def q8Round (t : Rat) : Int := roundHalfAway (clampR t (-q8Scale) q8Scale)

def rangeStep (d r x : Rat) : Rat :=
  if Rat.abs (x / d) > r then Rat.abs (x / d) else r

def q8Range (xs : List Rat) (d : Rat) : Rat := xs.foldl (rangeStep d) 0

def quantise (xs : List Rat) (d : Rat) : Rat × List Int :=
  let range := q8Range xs d
  if range = 0 then (range, xs.map fun _ => 0)
  else
    let scale := q8Scale / range
    (range, xs.map fun x => q8Round (x / d * scale))

def dequantise (qs : List Int) (range norm : Rat) : List Rat :=
  qs.map fun (q : Int) => (q : Rat) * range / q8Scale * norm

theorem abs_le_iff (y b : Rat) : Rat.abs y ≤ b ↔ -b ≤ y ∧ y ≤ b := by
  unfold Rat.abs; split <;> grind

theorem abs_nonneg' (y : Rat) : 0 ≤ Rat.abs y := by
  unfold Rat.abs; split <;> grind

theorem round_error (t : Rat) :
    -(1 / 2) ≤ (roundHalfAway t : Rat) - t ∧ (roundHalfAway t : Rat) - t ≤ 1 / 2 := by
  unfold roundHalfAway
  split
  · have h1 := Rat.floor_le (-t + 1 / 2)
    have h2 := Rat.lt_floor_add_one (-t + 1 / 2)
    push_cast at *
    constructor <;> grind
  · have h1 := Rat.floor_le (t + 1 / 2)
    have h2 := Rat.lt_floor_add_one (t + 1 / 2)
    push_cast at *
    constructor <;> grind

theorem round_odd (t : Rat) : roundHalfAway (-t) = -roundHalfAway t := by
  unfold roundHalfAway
  by_cases hn : t < 0
  · have : ¬ (-t < 0) := by grind
    simp only [hn, this, ite_true, ite_false, Int.neg_neg]
  · by_cases hz : t = 0
    · subst hz
      have : ¬ ((0 : Rat) < 0) := by grind
      have e : -(0 : Rat) = 0 := by grind
      simp only [e, this, ite_false]
      have : ((0 : Rat) + 1 / 2).floor = 0 := by
        have a : (0 : Int) ≤ ((0 : Rat) + 1 / 2).floor := Rat.le_floor_iff.mpr (by push_cast; grind)
        have b : ((0 : Rat) + 1 / 2).floor < (1 : Int) := Rat.floor_lt_iff.mpr (by push_cast; grind)
        omega
      rw [this]; rfl
    · have : -t < 0 := by grind
      simp only [hn, this, ite_true, ite_false, Rat.neg_neg]

theorem round_int (k : Int) : roundHalfAway k = k := by
  have h := round_error (k : Rat)
  have e1 : ((roundHalfAway k - k : Int) : Rat) = (roundHalfAway k : Rat) - k := by push_cast; rfl
  have a : ((roundHalfAway k - k : Int) : Rat) < ((1 : Int) : Rat) := by rw [e1]; push_cast; grind
  have b : ((-1 : Int) : Rat) < ((roundHalfAway k - k : Int) : Rat) := by rw [e1]; push_cast; grind
  have a' := Rat.intCast_lt_intCast.mp a
  have b' := Rat.intCast_lt_intCast.mp b
  omega

theorem round_half_up (k : Nat) : roundHalfAway ((k : Rat) + 1 / 2) = k + 1 := by
  unfold roundHalfAway
  have : ¬ ((k : Rat) + 1 / 2 < 0) := by
    have := Rat.natCast_nonneg (a := k)
    grind
  simp only [this, ite_false]
  have e : (k : Rat) + 1 / 2 + 1 / 2 = (((k : Int) + 1 : Int) : Rat) := by push_cast; grind
  rw [e, Rat.floor_intCast]

theorem round_half_down (k : Nat) : roundHalfAway (-((k : Rat) + 1 / 2)) = -(k + 1) := by
  rw [round_odd, round_half_up]

theorem int_le_of_rat {q : Int} {b : Int} (h : (q : Rat) < (b : Rat) + 1) : q ≤ b := by
  have : (q : Rat) < ((b + 1 : Int) : Rat) := by push_cast; exact h
  have := Rat.intCast_lt_intCast.mp this
  omega

theorem clamp_bounds (t : Rat) : -q8Scale ≤ clampR t (-q8Scale) q8Scale ∧ clampR t (-q8Scale) q8Scale ≤ q8Scale := by
  unfold clampR q8Scale
  constructor <;> grind

theorem q8Round_bounds (t : Rat) : -127 ≤ q8Round t ∧ q8Round t ≤ 127 := by
  unfold q8Round
  have hc := clamp_bounds t
  generalize clampR t (-q8Scale) q8Scale = c at *
  have he := round_error c
  generalize roundHalfAway c = q at *
  unfold q8Scale at hc
  constructor
  · have : ((-128 : Int) : Rat) < ((q : Int) : Rat) := by push_cast; grind
    have := Rat.intCast_lt_intCast.mp this
    omega
  · have : ((q : Int) : Rat) < ((128 : Int) : Rat) := by push_cast; grind
    have := Rat.intCast_lt_intCast.mp this
    omega

theorem clamp_id {t : Rat} (h1 : -q8Scale ≤ t) (h2 : t ≤ q8Scale) : clampR t (-q8Scale) q8Scale = t := by
  unfold clampR; grind

theorem quantise_error (x r : Rat) (hr : 0 < r) (hx1 : -r ≤ x) (hx2 : x ≤ r) :
    -(r / 254) ≤ (q8Round (x * (q8Scale / r)) : Rat) * r / q8Scale - x ∧
      (q8Round (x * (q8Scale / r)) : Rat) * r / q8Scale - x ≤ r / 254 := by
  have hr0 : r ≠ 0 := by grind
  have u1 : x / r ≤ 1 := by
    have h1 : ¬ (1 < x / r) := fun h' => by have := (Rat.lt_div_iff hr).mp h'; grind
    grind
  have u2 : -1 ≤ x / r := by
    have h1 : ¬ (x / r < -1) := fun h' => by have := (Rat.div_lt_iff hr).mp h'; grind
    grind
  have et : x * (q8Scale / r) = q8Scale * (x / r) := by grind
  have t1 : -q8Scale ≤ x * (q8Scale / r) := by rw [et]; unfold q8Scale; grind
  have t2 : x * (q8Scale / r) ≤ q8Scale := by rw [et]; unfold q8Scale; grind
  unfold q8Round
  rw [clamp_id t1 t2]
  generalize ht : x * (q8Scale / r) = t at *
  have he := round_error t
  generalize hq : roundHalfAway t = q at he
  have back : (q : Rat) * r / q8Scale - x = ((q : Rat) - t) * (r / q8Scale) := by
    rw [← ht]; unfold q8Scale; grind
  have hk : 0 ≤ r / q8Scale := by
    unfold q8Scale
    have : (0 : Rat) < r / 127 := by
      have := (Rat.lt_div_iff (show (0 : Rat) < 127 by decide) (a := 0) (b := r)).mpr (by grind)
      exact this
    grind
  rw [back]
  have a1 := Rat.mul_le_mul_of_nonneg_right he.1 hk
  have a2 := Rat.mul_le_mul_of_nonneg_right he.2 hk
  have er : r / 254 = 1 / 2 * (r / q8Scale) := by unfold q8Scale; grind
  rw [er]
  constructor <;> grind

theorem rangeStep_ge (d r x : Rat) : r ≤ rangeStep d r x ∧ Rat.abs (x / d) ≤ rangeStep d r x := by
  unfold rangeStep; split <;> grind

theorem foldl_range_ge (d : Rat) (xs : List Rat) (r : Rat) :
    r ≤ xs.foldl (rangeStep d) r ∧ ∀ x ∈ xs, Rat.abs (x / d) ≤ xs.foldl (rangeStep d) r := by
  induction xs generalizing r with
  | nil => simp
  | cons y ys ih =>
    simp only [List.foldl_cons]
    obtain ⟨a, b⟩ := rangeStep_ge d r y
    obtain ⟨c, e⟩ := ih (rangeStep d r y)
    refine ⟨by grind, fun x hx => ?_⟩
    cases hx with
    | head => grind
    | tail _ hx => exact e x hx

theorem range_nonneg (xs : List Rat) (d : Rat) : 0 ≤ q8Range xs d := (foldl_range_ge d xs 0).1

theorem range_bounds (xs : List Rat) (d : Rat) (x : Rat) (hx : x ∈ xs) :
    -(q8Range xs d) ≤ x / d ∧ x / d ≤ q8Range xs d :=
  (abs_le_iff _ _).mp ((foldl_range_ge d xs 0).2 x hx)

theorem quantise_reconstructs (xs : List Rat) (d : Rat) (i : Nat) (hi : i < xs.length) :
    (quantise xs d).2.length = xs.length ∧
      -((quantise xs d).1 / 254) ≤ (((quantise xs d).2[i]?.getD 0 : Int) : Rat) * (quantise xs d).1 / q8Scale - xs[i] / d ∧
      (((quantise xs d).2[i]?.getD 0 : Int) : Rat) * (quantise xs d).1 / q8Scale - xs[i] / d ≤ (quantise xs d).1 / 254 := by
  have hb := range_bounds xs d xs[i] (List.getElem_mem hi)
  have hn := range_nonneg xs d
  unfold quantise
  by_cases hz : q8Range xs d = 0
  · simp only [hz, ite_true, List.length_map, true_and]
    have hx : xs[i] / d = 0 := by grind
    simp [hi, hx]
    unfold q8Scale
    constructor <;> grind
  · simp only [hz, ite_false, List.length_map, true_and]
    have hpos : 0 < q8Range xs d := by grind
    simp only [List.getElem?_map, List.getElem?_eq_getElem hi, Option.map_some, Option.getD_some]
    exact quantise_error (xs[i] / d) (q8Range xs d) hpos hb.1 hb.2

theorem dequantise_error (xs : List Rat) (d : Rat) (hd : 0 < d) (i : Nat) (hi : i < xs.length) :
    -((quantise xs d).1 * d / 254) ≤ ((dequantise (quantise xs d).2 (quantise xs d).1 d)[i]?.getD 0) - xs[i] ∧
      ((dequantise (quantise xs d).2 (quantise xs d).1 d)[i]?.getD 0) - xs[i] ≤ (quantise xs d).1 * d / 254 := by
  obtain ⟨hl, h1, h2⟩ := quantise_reconstructs xs d i hi
  generalize hq : quantise xs d = p at *
  obtain ⟨range, qs⟩ := p
  simp only at hl h1 h2 ⊢
  have hi' : i < qs.length := by omega
  unfold dequantise
  simp only [List.getElem?_map, List.getElem?_eq_getElem hi', Option.map_some, Option.getD_some]
  simp only [List.getElem?_eq_getElem hi', Option.getD_some] at h1 h2
  generalize (qs[i] : Rat) = q at *
  have hd0 : d ≠ 0 := by grind
  have e : q * range / q8Scale * d - xs[i] = (q * range / q8Scale - xs[i] / d) * d := by grind
  have hd' : 0 ≤ d := by grind
  have a1 := Rat.mul_le_mul_of_nonneg_right h1 hd'
  have a2 := Rat.mul_le_mul_of_nonneg_right h2 hd'
  rw [e]
  constructor <;> grind

inductive XF where
  | fin (q : Rat)
  | inf (neg : Bool)
  | nan

def q8RoundX : XF → Int
  | .fin t => q8Round t
  | .inf _ => 0
  | .nan => 0

def q8RoundOld : XF → Int
  | .fin t => q8Round t
  | .inf neg => if neg then -127 else 127
  | .nan => 0

def mulX : XF → XF → XF
  | .fin x, .fin y => .fin (x * y)
  | .fin x, .inf n => if x = 0 then .nan else .inf (decide (x < 0) != n)
  | .inf n, .fin y => if y = 0 then .nan else .inf (n != decide (y < 0))
  | .inf a, .inf b => .inf (a != b)
  | .nan, _ => .nan
  | _, .nan => .nan

def f32Overflow : Rat := 2 ^ 128 - 2 ^ 103

def scaleX (range : Rat) : XF := if f32Overflow ≤ q8Scale / range then .inf false else .fin (q8Scale / range)

def quantiseF (xs : List Rat) (d : Rat) : Rat × List Int :=
  let range := q8Range xs d
  if range = 0 then (range, xs.map fun _ => 0)
  else (range, xs.map fun x => q8RoundX (mulX (.fin (x / d)) (scaleX range)))

theorem q8RoundX_finite (t : Rat) : q8RoundX (.fin t) = q8Round t := rfl

theorem q8RoundX_bounds (v : XF) : -127 ≤ q8RoundX v ∧ q8RoundX v ≤ 127 := by
  cases v with
  | fin t => exact q8Round_bounds t
  | inf n => simp [q8RoundX]
  | nan => simp [q8RoundX]

theorem q8RoundX_special : q8RoundX (.inf false) = 0 ∧ q8RoundX (.inf true) = 0 ∧ q8RoundX .nan = 0 :=
  ⟨rfl, rfl, rfl⟩

theorem inf_round_counterexample :
    q8RoundOld (.inf false) = 127 ∧ q8RoundOld (.inf true) = -127 ∧ q8RoundX (.inf false) = 0 := ⟨rfl, rfl, rfl⟩

theorem mul_inf_zero (x : Rat) : q8RoundX (mulX (.fin x) (.inf false)) = 0 := by
  show q8RoundX (if x = 0 then .nan else .inf (decide (x < 0) != false)) = 0
  split <;> rfl

theorem quantiseF_finite (xs : List Rat) (d : Rat)
    (h : q8Range xs d = 0 ∨ q8Scale / q8Range xs d < f32Overflow) : quantiseF xs d = quantise xs d := by
  unfold quantiseF quantise
  by_cases hz : q8Range xs d = 0
  · simp [hz]
  · have hs : ¬ (f32Overflow ≤ q8Scale / q8Range xs d) := by
      rcases h with h | h
      · exact absurd h hz
      · grind
    simp only [hz, ite_false, scaleX, hs, mulX, q8RoundX]

theorem quantiseF_overflow (xs : List Rat) (d : Rat) (hz : q8Range xs d ≠ 0)
    (h : f32Overflow ≤ q8Scale / q8Range xs d) : quantiseF xs d = (q8Range xs d, xs.map fun _ => 0) := by
  unfold quantiseF
  simp only [hz, ite_false, scaleX, h, ite_true, mul_inf_zero]

theorem tiny_range_overflows (r : Rat) (h0 : 0 < r) (h : r * 2 ^ 126 < 1) : f32Overflow ≤ q8Scale / r := by
  unfold f32Overflow q8Scale
  have : ¬ ((127 : Rat) / r < 127 * 2 ^ 126) := by
    intro h1
    have := (Rat.div_lt_iff h0).mp h1
    grind
  grind

theorem overflow_reconstruction (xs : List Rat) (d : Rat) (hz : q8Range xs d ≠ 0)
    (h : f32Overflow ≤ q8Scale / q8Range xs d) (i : Nat) (hi : i < xs.length) :
    (((quantiseF xs d).2[i]?.getD 0 : Int) : Rat) * (quantiseF xs d).1 / q8Scale = 0 ∧
      -((quantiseF xs d).1) ≤ 0 - xs[i] / d ∧ 0 - xs[i] / d ≤ (quantiseF xs d).1 := by
  rw [quantiseF_overflow xs d hz h]
  have hb := range_bounds xs d xs[i] (List.getElem_mem hi)
  simp only [List.getElem?_map, List.getElem?_eq_getElem hi, Option.map_some, Option.getD_some]
  refine ⟨by grind, ?_, ?_⟩ <;> grind

theorem overflow_bound_counterexample :
    quantiseF [(1 : Rat) / 2 ^ 140] 1 = ((1 : Rat) / 2 ^ 140, [0]) ∧
      (1 : Rat) / 2 ^ 140 / 254 < (1 / 2 ^ 140) / 1 - ((0 : Int) : Rat) * (1 / 2 ^ 140) / q8Scale := by
  have hr : q8Range [(1 : Rat) / 2 ^ 140] 1 = 1 / 2 ^ 140 := by
    unfold q8Range rangeStep
    simp only [List.foldl_cons, List.foldl_nil]
    unfold Rat.abs
    split <;> split <;> grind
  have hz : q8Range [(1 : Rat) / 2 ^ 140] 1 ≠ 0 := by rw [hr]; grind
  have ho : f32Overflow ≤ q8Scale / q8Range [(1 : Rat) / 2 ^ 140] 1 := by
    rw [hr]; exact tiny_range_overflows _ (by grind) (by grind)
  refine ⟨by rw [quantiseF_overflow _ _ hz ho, hr]; rfl, ?_⟩
  unfold q8Scale
  grind

end Vectors
