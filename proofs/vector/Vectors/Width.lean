namespace Vectors

def widthU16Slots : Nat := 65535

def widthU24Slots : Nat := 16777215

def hnswSlotLimit : Nat := 2 ^ 32 - 2

def linkWidth (capacity : Nat) : Nat :=
  if capacity ≤ widthU16Slots then 2 else if capacity ≤ widthU24Slots then 3 else 4

def widthNone (w : Nat) : Nat := 2 ^ (8 * w) - 1

def loadBytes (mem : Nat → Nat) (base : Nat) : Nat → Nat
  | 0 => 0
  | n + 1 => mem base + 256 * loadBytes mem (base + 1) n

def storeBytes (mem : Nat → Nat) (base v : Nat) : Nat → Nat → Nat
  | 0 => mem
  | n + 1 => fun j => if j = base then v % 256 else storeBytes mem (base + 1) (v / 256) n j

def wordGet (mem : Nat → Nat) (w i : Nat) : Nat := loadBytes mem (w * i) w

def wordSet (mem : Nat → Nat) (w i v : Nat) : Nat → Nat := storeBytes mem (w * i) v w

def widenWord (src dst v : Nat) : Nat := if v = widthNone src then widthNone dst else v

def encodeRow (w : Nat) (mem : Nat → Nat) : Nat → List Nat → Nat → Nat
  | _, [] => mem
  | i, v :: vs => encodeRow w (wordSet mem w i v) (i + 1) vs

def decodeRow (mem : Nat → Nat) (w count : Nat) : List Nat := (List.range count).map (wordGet mem w)

def widenRow (src : Nat → Nat) (dst : Nat → Nat) (wsrc wdst : Nat) : Nat → Nat → Nat → Nat
  | _, 0 => dst
  | i, n + 1 => widenRow src (wordSet dst wdst i (widenWord wsrc wdst (wordGet src wsrc i))) wsrc wdst (i + 1) n

theorem width_cases (c : Nat) : linkWidth c = 2 ∨ linkWidth c = 3 ∨ linkWidth c = 4 := by
  unfold linkWidth; split
  · exact Or.inl rfl
  · split
    · exact Or.inr (Or.inl rfl)
    · exact Or.inr (Or.inr rfl)

theorem link_width_fits (c s : Nat) (hc : c ≤ hnswSlotLimit) (hs : s < c) : s < widthNone (linkWidth c) := by
  unfold linkWidth widthNone widthU16Slots widthU24Slots hnswSlotLimit at *
  split
  · omega
  · split <;> omega

theorem link_width_mono (c c' : Nat) (h : c ≤ c') : linkWidth c ≤ linkWidth c' := by
  unfold linkWidth widthU16Slots widthU24Slots
  split <;> split <;> (try split) <;> (try split) <;> omega

theorem width_none_mono (w w' : Nat) (h : w ≤ w') : widthNone w ≤ widthNone w' := by
  unfold widthNone
  have : 2 ^ (8 * w) ≤ 2 ^ (8 * w') := Nat.pow_le_pow_right (by decide) (by omega)
  omega

theorem storeBytes_outside (mem : Nat → Nat) : ∀ (n base v j : Nat), (j < base ∨ base + n ≤ j) →
    storeBytes mem base v n j = mem j := by
  intro n
  induction n with
  | zero => intro base v j _; rfl
  | succ n ih =>
    intro base v j h
    show (if j = base then v % 256 else storeBytes mem (base + 1) (v / 256) n j) = mem j
    rw [ite_eq_right (show ¬ (j = base) by omega)]
    exact ih (base + 1) (v / 256) j (by omega)

theorem loadBytes_congr (mem mem' : Nat → Nat) : ∀ (n base : Nat), (∀ j, base ≤ j → j < base + n → mem j = mem' j) →
    loadBytes mem base n = loadBytes mem' base n := by
  intro n
  induction n with
  | zero => intro base _; rfl
  | succ n ih =>
    intro base h
    simp only [loadBytes]
    rw [h base (by omega) (by omega), ih (base + 1) (fun j h1 h2 => h j (by omega) (by omega))]

theorem load_store (mem : Nat → Nat) : ∀ (n base v : Nat), loadBytes (storeBytes mem base v n) base n = v % 256 ^ n := by
  intro n
  induction n with
  | zero => intro base v; simp [loadBytes]; omega
  | succ n ih =>
    intro base v
    simp only [loadBytes]
    have h1 : storeBytes mem base v (n + 1) base = v % 256 := by
      show (if base = base then v % 256 else _) = v % 256
      simp
    have h2 : loadBytes (storeBytes mem base v (n + 1)) (base + 1) n =
        loadBytes (storeBytes mem (base + 1) (v / 256) n) (base + 1) n := by
      apply loadBytes_congr
      intro j hj _
      show (if j = base then v % 256 else storeBytes mem (base + 1) (v / 256) n j) = _
      rw [ite_eq_right (show ¬ (j = base) by omega)]
    rw [h1, h2, ih, Nat.pow_succ, Nat.mul_comm (256 ^ n) 256, Nat.mod_mul]

theorem word_set_get (mem : Nat → Nat) (w i v : Nat) : wordGet (wordSet mem w i v) w i = v % 256 ^ w :=
  load_store mem w (w * i) v

theorem word_set_other (mem : Nat → Nat) (w i j v : Nat) (hij : i ≠ j) :
    wordGet (wordSet mem w j v) w i = wordGet mem w i := by
  unfold wordGet wordSet
  apply loadBytes_congr
  intro k hk1 hk2
  apply storeBytes_outside
  rcases Nat.lt_or_gt_of_ne hij with h | h
  · left
    have : w * (i + 1) ≤ w * j := Nat.mul_le_mul_left w (by omega)
    rw [Nat.mul_succ] at this; omega
  · right
    have : w * (j + 1) ≤ w * i := Nat.mul_le_mul_left w (by omega)
    rw [Nat.mul_succ] at this; omega

theorem load_three_of_four (mem : Nat → Nat) (base : Nat) : loadBytes mem base 4 % 2 ^ 24 = loadBytes mem base 3 % 2 ^ 24 := by
  simp only [loadBytes]
  omega

theorem encodeRow_get (w : Nat) : ∀ (vs : List Nat) (mem : Nat → Nat) (start k : Nat),
    wordGet (encodeRow w mem start vs) w k =
      if start ≤ k ∧ k < start + vs.length then (vs[k - start]?.getD 0) % 256 ^ w else wordGet mem w k := by
  intro vs
  induction vs with
  | nil =>
    intro mem start k
    simp only [encodeRow, List.length_nil, Nat.add_zero]
    rw [ite_eq_right (show ¬ (start ≤ k ∧ k < start) by omega)]
  | cons v vs ih =>
    intro mem start k
    simp only [encodeRow, List.length_cons]
    rw [ih]
    by_cases hk : k = start
    · rw [ite_eq_right (show ¬ (start + 1 ≤ k ∧ k < start + 1 + vs.length) by omega), hk, word_set_get,
        ite_eq_left (show start ≤ start ∧ start < start + (vs.length + 1) by omega), Nat.sub_self]
      simp
    · rw [word_set_other _ _ _ _ _ hk]
      by_cases h1 : start + 1 ≤ k ∧ k < start + 1 + vs.length
      · rw [ite_eq_left h1, ite_eq_left (show start ≤ k ∧ k < start + (vs.length + 1) by omega)]
        have : k - start = (k - (start + 1)) + 1 := by omega
        rw [this]; simp
      · rw [ite_eq_right h1, ite_eq_right (show ¬ (start ≤ k ∧ k < start + (vs.length + 1)) by omega)]

theorem decode_encode (w : Nat) (mem : Nat → Nat) (vs : List Nat) (hv : ∀ x ∈ vs, x < 256 ^ w) :
    decodeRow (encodeRow w mem 0 vs) w vs.length = vs := by
  unfold decodeRow
  apply List.ext_getElem
  · simp
  · intro i h1 h2
    rw [List.getElem_map, List.getElem_range, encodeRow_get,
      ite_eq_left (show 0 ≤ i ∧ i < 0 + vs.length by omega), Nat.sub_zero, List.getElem?_eq_getElem h2,
      Option.getD_some]
    exact Nat.mod_eq_of_lt (hv _ (List.getElem_mem h2))

theorem widenRow_get (src : Nat → Nat) (wsrc wdst : Nat) : ∀ (n : Nat) (dst : Nat → Nat) (start k : Nat),
    wordGet (widenRow src dst wsrc wdst start n) wdst k =
      if start ≤ k ∧ k < start + n then widenWord wsrc wdst (wordGet src wsrc k) % 256 ^ wdst else wordGet dst wdst k := by
  intro n
  induction n with
  | zero =>
    intro dst start k
    simp only [widenRow, Nat.add_zero]
    rw [ite_eq_right (show ¬ (start ≤ k ∧ k < start) by omega)]
  | succ n ih =>
    intro dst start k
    simp only [widenRow]
    rw [ih]
    by_cases hk : k = start
    · rw [ite_eq_right (show ¬ (start + 1 ≤ k ∧ k < start + 1 + n) by omega), hk, word_set_get,
        ite_eq_left (show start ≤ start ∧ start < start + (n + 1) by omega)]
    · rw [word_set_other _ _ _ _ _ hk]
      by_cases h1 : start + 1 ≤ k ∧ k < start + 1 + n
      · rw [ite_eq_left h1, ite_eq_left (show start ≤ k ∧ k < start + (n + 1) by omega)]
      · rw [ite_eq_right h1, ite_eq_right (show ¬ (start ≤ k ∧ k < start + (n + 1)) by omega)]

theorem widen_word_id (wsrc wdst v : Nat) (hv : v < widthNone wsrc) : widenWord wsrc wdst v = v := by
  unfold widenWord; rw [ite_eq_right (show ¬ (v = widthNone wsrc) by omega)]

theorem none_lt_byte_pow (w : Nat) : widthNone w < 256 ^ w := by
  unfold widthNone
  rw [show 256 = 2 ^ 8 by rfl, ← Nat.pow_mul]
  have : 0 < 2 ^ (8 * w) := Nat.two_pow_pos _
  omega

theorem reencode_preserves (mem dst : Nat → Nat) (wsrc wdst count : Nat) (hle : wsrc ≤ wdst)
    (ids : List Nat) (hids : ∀ x ∈ ids, x < widthNone wsrc) (hcount : ids.length ≤ count) :
    (decodeRow (widenRow (encodeRow wsrc mem 0 ids) dst wsrc wdst 0 count) wdst ids.length) = ids := by
  have hn := width_none_mono wsrc wdst hle
  unfold decodeRow
  apply List.ext_getElem
  · simp
  · intro i h1 h2
    rw [List.getElem_map, List.getElem_range, widenRow_get, ite_eq_left (show 0 ≤ i ∧ i < 0 + count by omega),
      encodeRow_get, ite_eq_left (show 0 ≤ i ∧ i < 0 + ids.length by omega), Nat.sub_zero,
      List.getElem?_eq_getElem h2, Option.getD_some]
    have hx := hids _ (List.getElem_mem h2)
    have hlt : ids[i] < 256 ^ wsrc := Nat.lt_trans hx (none_lt_byte_pow wsrc)
    rw [Nat.mod_eq_of_lt hlt, widen_word_id _ _ _ hx]
    exact Nat.mod_eq_of_lt (Nat.lt_of_lt_of_le hx (Nat.le_of_lt (Nat.lt_of_le_of_lt hn (none_lt_byte_pow wdst))))

theorem reencode_terminator (wsrc wdst : Nat) :
    widenWord wsrc wdst (widthNone wsrc) = widthNone wdst ∧ widthNone wdst < 256 ^ wdst :=
  ⟨by unfold widenWord; simp, none_lt_byte_pow wdst⟩

theorem counts_fit (m : Nat) (hm : m ≤ 32767) (c : Nat) (hc : c ≤ m) : c < widthNone 2 := by
  unfold widthNone; omega

end Vectors
