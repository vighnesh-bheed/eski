import Vectors.Bits
import Vectors.Quantise

namespace Vectors

def binWords (dim : Nat) : Nat := (dim + 63) >>> 6

def orBit (w : List Nat) (i : Nat) : List Nat :=
  w.set (i >>> 6) ((w[i >>> 6]?.getD 0) ||| (1 <<< (i &&& 63)))

def packFrom (xs : List Rat) (d : Rat) : Nat → List Nat → List Nat
  | 0, w => w
  | m + 1, w =>
    let w := packFrom xs d m w
    if xs[m]?.getD 0 / d > 0 then orBit w m else w

def packBits (xs : List Rat) (d : Rat) (words : Nat) : List Nat :=
  packFrom xs d xs.length (List.replicate words 0)

def paddingClear (ws : List Nat) (dim : Nat) : Prop :=
  ∀ k u, k < ws.length → u < 64 → dim ≤ 64 * k + u → (ws[k]?.getD 0).testBit u = false

def binPaddingClear (ws : List Nat) (dim : Nat) : Bool :=
  let tail := dim &&& 63
  if tail = 0 ∨ ws = [] then true else (ws.getLast?.getD 0) >>> tail == 0

def hamming (a b : List Nat) : Nat := (List.zipWith (fun x y => popcount (x ^^^ y)) a b).sum

def distanceBin (h dim : Nat) : Rat := (h : Rat) / (dim : Rat) * 2

def scoreFromDistance (dist : Rat) : Rat := 1 - dist / 2

def scoreBin (h dim : Nat) : Rat := scoreFromDistance (distanceBin h dim)

def q8Dist (idot : Int) (ra rb : Rat) : Rat := clampR (1 - ra / q8Scale * (rb / q8Scale) * idot) 0 2

theorem mask63 (i : Nat) : i &&& 63 = i % 64 := Nat.and_two_pow_sub_one_eq_mod i 6

theorem shift6 (i : Nat) : i >>> 6 = i / 64 := by rw [Nat.shiftRight_eq_div_pow]

theorem binWords_eq (dim : Nat) : binWords dim = (dim + 63) / 64 := shift6 _

theorem testBit_lt_64 {x u : Nat} (hx : x < 2 ^ 64) (hu : 64 ≤ u) : x.testBit u = false :=
  Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le hx (Nat.pow_le_pow_right (by omega) hu))

theorem packFrom_spec (xs : List Rat) (d : Rat) (words m : Nat) (hm : m ≤ 64 * words) :
    (packFrom xs d m (List.replicate words 0)).length = words ∧
      (∀ k, k < words → (packFrom xs d m (List.replicate words 0))[k]?.getD 0 < 2 ^ 64) ∧
      ∀ k u, k < words → u < 64 →
        ((packFrom xs d m (List.replicate words 0))[k]?.getD 0).testBit u =
          decide (64 * k + u < m ∧ xs[64 * k + u]?.getD 0 / d > 0) := by
  induction m with
  | zero =>
    refine ⟨by simp [packFrom], fun k hk => ?_, fun k u hk _ => ?_⟩
    · simp [packFrom, hk]
    · simp [packFrom, hk]
  | succ m ih =>
    obtain ⟨hl, hb, hbit⟩ := ih (by omega)
    simp only [packFrom]
    generalize packFrom xs d m (List.replicate words 0) = w at hl hb hbit
    have hk0 : m / 64 < words := by omega
    split
    · rename_i hpos
      unfold orBit
      rw [shift6, mask63, Nat.one_shiftLeft]
      refine ⟨by simp [hl], fun k hk => ?_, fun k u hk hu => ?_⟩
      · rw [List.getElem?_set]
        split
        · have := hb (m / 64) hk0
          simp only [hl, hk0, ite_true, Option.getD_some]
          exact Nat.or_lt_two_pow this (Nat.pow_lt_pow_right (by omega) (Nat.mod_lt _ (by omega)))
        · exact hb k hk
      · rw [List.getElem?_set]
        by_cases he : m / 64 = k
        · subst he
          simp only [ite_true, hl, hk0, Option.getD_some, Nat.testBit_or, Nat.testBit_two_pow, hbit (m / 64) u hk hu]
          by_cases hu' : m % 64 = u
          · have : 64 * (m / 64) + u = m := by omega
            simp [hu', this, hpos]
          · have : 64 * (m / 64) + u ≠ m := by omega
            have e : (64 * (m / 64) + u < m + 1) = (64 * (m / 64) + u < m) := by
              apply propext; omega
            simp [hu', e]
        · simp only [he, ite_false]
          rw [hbit k u hk hu]
          have : 64 * k + u ≠ m := by omega
          have e : (64 * k + u < m + 1) = (64 * k + u < m) := by apply propext; omega
          simp [e]
    · rename_i hpos
      refine ⟨hl, hb, fun k u hk hu => ?_⟩
      rw [hbit k u hk hu]
      by_cases he : 64 * k + u = m
      · rw [he]
        simp [hpos]
      · have e : (64 * k + u < m + 1) = (64 * k + u < m) := by apply propext; omega
        simp [e]

theorem packBits_length (xs : List Rat) (d : Rat) (words : Nat) (h : xs.length ≤ 64 * words) :
    (packBits xs d words).length = words := (packFrom_spec xs d words xs.length h).1

theorem packBits_word_bound (xs : List Rat) (d : Rat) (words : Nat) (h : xs.length ≤ 64 * words) (k : Nat)
    (hk : k < words) : (packBits xs d words)[k]?.getD 0 < 2 ^ 64 := (packFrom_spec xs d words xs.length h).2.1 k hk

theorem packBits_bit (xs : List Rat) (d : Rat) (words : Nat) (h : xs.length ≤ 64 * words) (k u : Nat)
    (hk : k < words) (hu : u < 64) :
    ((packBits xs d words)[k]?.getD 0).testBit u = decide (64 * k + u < xs.length ∧ xs[64 * k + u]?.getD 0 / d > 0) :=
  (packFrom_spec xs d words xs.length h).2.2 k u hk hu

theorem div_pos_iff (x d : Rat) (hd : 0 < d) : 0 < x / d ↔ 0 < x := by
  rw [Rat.lt_div_iff hd]
  constructor <;> intro h <;> grind

theorem packBits_positive (xs : List Rat) (d : Rat) (hd : 0 < d) (words : Nat) (h : xs.length ≤ 64 * words)
    (i : Nat) (hi : i < xs.length) : ((packBits xs d words)[i / 64]?.getD 0).testBit (i % 64) = decide (0 < xs[i]) := by
  rw [packBits_bit xs d words h (i / 64) (i % 64) (by omega) (Nat.mod_lt _ (by omega))]
  have e : 64 * (i / 64) + i % 64 = i := by omega
  rw [e, List.getElem?_eq_getElem hi, Option.getD_some]
  have := div_pos_iff xs[i] d hd
  by_cases hp : 0 < xs[i] <;> simp [hi, hp] <;> grind

theorem words_cover (dim : Nat) : dim ≤ 64 * binWords dim := by rw [binWords_eq]; omega

theorem packBits_padding (xs : List Rat) (d : Rat) : paddingClear (packBits xs d (binWords xs.length)) xs.length := by
  intro k u hk hu hd
  have hw := words_cover xs.length
  rw [packBits_length xs d _ hw] at hk
  rw [packBits_bit xs d _ hw k u hk hu]
  simp; omega

theorem popcount_xor_le (x y dim : Nat) (hx : ∀ u, u < 64 → dim ≤ u → x.testBit u = false)
    (hy : ∀ u, u < 64 → dim ≤ u → y.testBit u = false) : popcount (x ^^^ y) ≤ min 64 dim := by
  unfold popcount
  by_cases hd : 64 ≤ dim
  · have := bitCount_le (x ^^^ y) 64; omega
  · rw [bitCount_mono_clear (w := dim) (by omega) (fun u h1 h2 => by rw [Nat.testBit_xor, hx u h2 h1, hy u h2 h1]; rfl)]
    have := bitCount_le (x ^^^ y) dim; omega

theorem hamming_le (a b : List Nat) (dim : Nat) (hab : a.length = b.length) (ha : paddingClear a dim)
    (hb : paddingClear b dim) : hamming a b ≤ dim := by
  induction a generalizing b dim with
  | nil => simp [hamming]
  | cons x a ih =>
    cases b with
    | nil => simp at hab
    | cons y b =>
      simp only [List.length_cons] at hab
      unfold hamming
      rw [List.zipWith_cons_cons, List.sum_cons]
      have h0 := popcount_xor_le x y dim
        (fun u hu hd => by simpa using ha 0 u (by simp) hu (by omega))
        (fun u hu hd => by simpa using hb 0 u (by simp) hu (by omega))
      have ht := ih b (dim - 64) (by omega)
        (fun k u hk hu hd => by simpa using ha (k + 1) u (by simp; omega) hu (by omega))
        (fun k u hk hu hd => by simpa using hb (k + 1) u (by simp; omega) hu (by omega))
      unfold hamming at ht
      omega

theorem hamming_counterexample : hamming [2 ^ 64 - 1] [0] = 64 ∧ binWords 1 = 1 := by decide

theorem binPaddingClear_iff (ws : List Nat) (dim : Nat) (hl : ws.length = binWords dim)
    (hw : ∀ k, k < ws.length → ws[k]?.getD 0 < 2 ^ 64) : binPaddingClear ws dim = true ↔ paddingClear ws dim := by
  rw [binWords_eq] at hl
  unfold binPaddingClear
  rw [mask63]
  by_cases ht : dim % 64 = 0
  · simp only [ht, true_or, ite_true, true_iff]
    intro k u hk hu hd
    omega
  · by_cases he : ws = []
    · subst he
      simp only [or_true, ite_true, true_iff]
      intro k u hk; simp at hk
    · simp only [ht, he, or_self, ite_false, beq_iff_eq]
      have hlast : ws.getLast?.getD 0 = ws[dim / 64]?.getD 0 := by
        rw [List.getLast?_eq_getElem?]
        congr 2; omega
      rw [hlast]
      have hbound := hw (dim / 64) (by omega)
      generalize hL : ws[dim / 64]?.getD 0 = last at hbound
      constructor
      · intro h0 k u hk hu hd
        have hk' : k = dim / 64 := by omega
        subst hk'
        have := congrArg (fun z => z.testBit (u - dim % 64)) h0
        simp only [Nat.testBit_shiftRight, Nat.zero_testBit] at this
        have e : dim % 64 + (u - dim % 64) = u := by omega
        rw [e] at this
        rw [hL]; exact this
      · intro hp
        apply Nat.eq_of_testBit_eq
        intro j
        rw [Nat.testBit_shiftRight, Nat.zero_testBit]
        by_cases hj : dim % 64 + j < 64
        · have := hp (dim / 64) (dim % 64 + j) (by omega) hj (by omega)
          rw [hL] at this; exact this
        · exact testBit_lt_64 hbound (by omega)

theorem scoreBin_eq (h dim : Nat) : scoreBin h dim = 1 - (h : Rat) / dim := by
  unfold scoreBin scoreFromDistance distanceBin
  grind

theorem scoreBin_unit (h dim : Nat) (hd : 0 < dim) (hh : h ≤ dim) : 0 ≤ scoreBin h dim ∧ scoreBin h dim ≤ 1 := by
  rw [scoreBin_eq h dim]
  have hd' : (0 : Rat) < dim := Rat.natCast_pos.mpr hd
  have h0 : (0 : Rat) ≤ h := Rat.natCast_nonneg
  have h1 : (h : Rat) ≤ dim := Rat.natCast_le_natCast.mpr hh
  have u1 : (h : Rat) / dim ≤ 1 := by
    have : ¬ (1 < (h : Rat) / dim) := fun h' => by have := (Rat.lt_div_iff hd').mp h'; grind
    grind
  have u0 : 0 ≤ (h : Rat) / dim := by
    have : ¬ ((h : Rat) / dim < 0) := fun h' => by have := (Rat.div_lt_iff hd').mp h'; grind
    grind
  constructor <;> grind

theorem score_antitone (a b : Rat) (hab : a ≤ b) : scoreFromDistance b ≤ scoreFromDistance a := by
  unfold scoreFromDistance; grind

theorem score_unit (dist : Rat) (h0 : 0 ≤ dist) (h2 : dist ≤ 2) :
    0 ≤ scoreFromDistance dist ∧ scoreFromDistance dist ≤ 1 := by
  unfold scoreFromDistance; constructor <;> grind

theorem q8Dist_range (idot : Int) (ra rb : Rat) : 0 ≤ q8Dist idot ra rb ∧ q8Dist idot ra rb ≤ 2 := by
  unfold q8Dist clampR; constructor <;> grind

theorem q8_score_unit (idot : Int) (ra rb : Rat) :
    0 ≤ scoreFromDistance (q8Dist idot ra rb) ∧ scoreFromDistance (q8Dist idot ra rb) ≤ 1 := by
  have := q8Dist_range idot ra rb
  exact score_unit _ this.1 this.2

theorem encoded_score_unit (xs ys : List Rat) (d e : Rat) (hl : xs.length = ys.length) (hd : 0 < xs.length) :
    0 ≤ scoreBin (hamming (packBits xs d (binWords xs.length)) (packBits ys e (binWords xs.length))) xs.length ∧
      scoreBin (hamming (packBits xs d (binWords xs.length)) (packBits ys e (binWords xs.length))) xs.length ≤ 1 := by
  apply scoreBin_unit _ _ hd
  have hw := words_cover xs.length
  apply hamming_le
  · rw [packBits_length xs d _ hw, packBits_length ys e _ (by omega)]
  · exact packBits_padding xs d
  · have := packBits_padding ys e
    rw [hl]; exact this

end Vectors
