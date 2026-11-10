namespace Vectors

def bitCount (x : Nat) : Nat → Nat
  | 0 => 0
  | w + 1 => bitCount x w + (if x.testBit w then 1 else 0)

def popcount (x : Nat) : Nat := bitCount x 64

def sumTo (f : Nat → Int) : Nat → Int
  | 0 => 0
  | n + 1 => sumTo f n + f n

theorem bitCount_le (x w : Nat) : bitCount x w ≤ w := by
  induction w with
  | zero => simp [bitCount]
  | succ w ih => simp only [bitCount]; split <;> omega

theorem bitCount_congr {x y : Nat} (w : Nat) (h : ∀ u, u < w → x.testBit u = y.testBit u) :
    bitCount x w = bitCount y w := by
  induction w with
  | zero => rfl
  | succ w ih =>
    simp only [bitCount]
    rw [ih (fun u hu => h u (by omega)), h w (by omega)]

theorem bitCount_zero (w : Nat) : bitCount 0 w = 0 := by
  induction w with
  | zero => rfl
  | succ w ih => simp [bitCount, ih]

theorem bitCount_of_clear {x : Nat} (w : Nat) (h : ∀ u, u < w → x.testBit u = false) : bitCount x w = 0 := by
  rw [bitCount_congr w (y := 0) (fun u hu => by rw [h u hu, Nat.zero_testBit]), bitCount_zero]

theorem bitCount_two_pow {s w : Nat} (hs : s < w) : bitCount (2 ^ s) w = 1 := by
  induction w with
  | zero => omega
  | succ w ih =>
    simp only [bitCount, Nat.testBit_two_pow]
    by_cases hw : s = w
    · subst hw
      rw [bitCount_of_clear s (fun u hu => by rw [Nat.testBit_two_pow]; simp; omega)]
      simp
    · rw [ih (by omega)]
      simp [hw]

theorem bitCount_parity (x y i w : Nat) :
    bitCount (x &&& i) w + bitCount (y &&& i) w =
      bitCount ((x ^^^ y) &&& i) w + 2 * bitCount (x &&& y &&& i) w := by
  induction w with
  | zero => simp [bitCount]
  | succ w ih =>
    simp only [bitCount, Nat.testBit_and, Nat.testBit_xor]
    cases x.testBit w <;> cases y.testBit w <;> cases i.testBit w <;> simp <;> omega

theorem bitCount_mono_clear {x : Nat} {w w' : Nat} (hw : w ≤ w') (h : ∀ u, w ≤ u → u < w' → x.testBit u = false) :
    bitCount x w' = bitCount x w := by
  induction w' with
  | zero =>
    have : w = 0 := by omega
    subst this; rfl
  | succ w' ih =>
    by_cases he : w = w' + 1
    · subst he; rfl
    · simp only [bitCount]
      rw [ih (by omega) (fun u h1 h2 => h u h1 (by omega)), h w' (by omega) (by omega)]
      simp

theorem sumTo_add (f : Nat → Int) (a b : Nat) :
    sumTo f (a + b) = sumTo f a + sumTo (fun t => f (a + t)) b := by
  induction b with
  | zero => simp [sumTo]
  | succ b ih =>
    rw [← Nat.add_assoc, sumTo, ih, sumTo]
    omega

theorem sumTo_congr {f g : Nat → Int} (n : Nat) (h : ∀ i, i < n → f i = g i) : sumTo f n = sumTo g n := by
  induction n with
  | zero => rfl
  | succ n ih =>
    simp only [sumTo]
    rw [ih (fun i hi => h i (by omega)), h n (by omega)]

theorem sumTo_const (c : Int) (n : Nat) : sumTo (fun _ => c) n = n * c := by
  induction n with
  | zero => simp [sumTo]
  | succ n ih =>
    simp only [sumTo, ih]
    push_cast
    rw [Int.add_mul, Int.one_mul]

theorem sumTo_mul_left (c : Int) (f : Nat → Int) (n : Nat) :
    sumTo (fun i => c * f i) n = c * sumTo f n := by
  induction n with
  | zero => simp [sumTo]
  | succ n ih =>
    simp only [sumTo, ih]
    rw [Int.mul_add]

end Vectors
