namespace Postings

def u32Mod : Nat := 4294967296

def sumBelow (f : Nat → Nat) : Nat → Nat
  | 0 => 0
  | n + 1 => sumBelow f n + f n

def valueLength (v : Nat) : Nat :=
  1 + (if 255 < v then 1 else 0) + (if 65535 < v then 1 else 0) + (if 16777215 < v then 1 else 0)

def leBytes (v : Nat) : Nat → List Nat
  | 0 => []
  | n + 1 => v % 256 :: leBytes (v / 256) n

def getLE : List Nat → Nat
  | [] => 0
  | b :: bs => b + 256 * getLE bs

def ctrlByte : List Nat → Nat
  | [] => 0
  | l :: rest => (l - 1) + 4 * ctrlByte rest

def controls : List Nat → List Nat
  | [] => []
  | [a] => [ctrlByte [a]]
  | [a, b] => [ctrlByte [a, b]]
  | [a, b, c] => [ctrlByte [a, b, c]]
  | a :: b :: c :: d :: rest => ctrlByte [a, b, c, d] :: controls rest

def payload (vs : List Nat) : List Nat := vs.flatMap fun v => leBytes v (valueLength v)

def encode (vs : List Nat) : List Nat := controls (vs.map valueLength) ++ payload vs

def controlCount (n : Nat) : Nat := (n + 3) / 4

def codeLength (data : List Nat) (i : Nat) : Nat := data.getD (i / 4) 0 / 4 ^ (i % 4) % 4 + 1

def getValue (data : List Nat) (pos len : Nat) : Nat := getLE ((data.drop pos).take len)

def decodeWith (lenf : Nat → Nat) (data : List Nat) : Nat → Nat → Nat → List Nat × Nat
  | _, pos, 0 => ([], pos)
  | i, pos, k + 1 =>
    let r := decodeWith lenf data (i + 1) (pos + lenf i) k
    (getValue data pos (lenf i) :: r.1, r.2)

def decode (data : List Nat) (n : Nat) : List Nat × Nat :=
  decodeWith (codeLength data) data 0 (controlCount n) n

def groupLength (c : Nat) : Nat := (c % 4 + 1) + (c / 4 % 4 + 1) + (c / 16 % 4 + 1) + (c / 64 % 4 + 1)

def encodedLength (data : List Nat) (n : Nat) : Option Nat :=
  if data.length < controlCount n then none
  else some (controlCount n + sumBelow (fun g => groupLength (data.getD g 0)) (n / 4) +
    sumBelow (fun k => codeLength data (n / 4 * 4 + k)) (n % 4))

def deltas (prev : Nat) : List Nat → List Nat
  | [] => []
  | v :: vs => (v + u32Mod - prev) % u32Mod :: deltas v vs

def prefixSums (prev : Nat) : List Nat → List Nat
  | [] => []
  | d :: ds => (prev + d) % u32Mod :: prefixSums ((prev + d) % u32Mod) ds

def encodeDelta (vs : List Nat) (prev : Nat) : List Nat := encode (deltas prev vs)

def decodeDelta (data : List Nat) (n prev : Nat) : List Nat × Nat :=
  let r := decode data n
  (prefixSums prev r.1, r.2)

def paddingClear (data : List Nat) (n : Nat) : Prop :=
  n % 4 = 0 ∨ data.getD (n / 4) 0 / 4 ^ (n % 4) = 0

def Bytes (data : List Nat) : Prop := ∀ b ∈ data, b < 256

theorem length_leBytes (v n : Nat) : (leBytes v n).length = n := by
  induction n generalizing v with
  | zero => rfl
  | succ n ih => simp [leBytes, ih]

theorem getLE_leBytes (v n : Nat) : getLE (leBytes v n) = v % 256 ^ n := by
  induction n generalizing v with
  | zero => simp [leBytes, getLE, Nat.mod_one]
  | succ n ih =>
    simp only [leBytes, getLE, ih]
    rw [Nat.pow_succ, Nat.mul_comm (256 ^ n) 256, Nat.mod_mul]

theorem leBytes_bytes (v n : Nat) : Bytes (leBytes v n) := by
  induction n generalizing v with
  | zero => intro b hb; simp [leBytes] at hb
  | succ n ih =>
    intro b hb
    simp only [leBytes, List.mem_cons] at hb
    rcases hb with h | h
    · subst h; exact Nat.mod_lt _ (by decide)
    · exact ih _ b h

theorem valueLength_pos (v : Nat) : 1 ≤ valueLength v ∧ valueLength v ≤ 4 := by
  unfold valueLength; split <;> split <;> split <;> omega

theorem valueLength_fits {v : Nat} (h : v < 2 ^ 32) : v < 256 ^ valueLength v := by
  unfold valueLength
  by_cases a : 255 < v <;> by_cases b : 65535 < v <;> by_cases c : 16777215 < v <;> simp [a, b, c] <;> omega

theorem valueLength_minimal {v len : Nat} (h : v < 256 ^ len) (hl : 1 ≤ len) : valueLength v ≤ len := by
  unfold valueLength
  rcases len with _ | _ | _ | _ | len
  · omega
  · simp at h; split <;> split <;> split <;> omega
  · simp at h; split <;> split <;> split <;> omega
  · simp at h; split <;> split <;> split <;> omega
  · split <;> split <;> split <;> omega

theorem getLE_lt {bs : List Nat} (h : Bytes bs) : getLE bs < 256 ^ bs.length := by
  induction bs with
  | nil => simp [getLE]
  | cons b bs ih =>
    have hb : b < 256 := h b (by simp)
    have hr := ih (fun x hx => h x (by simp [hx]))
    simp only [getLE, List.length_cons, Nat.pow_succ]
    have : 256 * getLE bs ≤ 256 * (256 ^ bs.length - 1) := Nat.mul_le_mul_left _ (by omega)
    have hp : 1 ≤ 256 ^ bs.length := Nat.one_le_pow _ _ (by decide)
    rw [Nat.mul_sub, Nat.mul_one] at this
    rw [Nat.mul_comm (256 ^ bs.length) 256]
    omega

theorem leBytes_getLE {bs : List Nat} (h : Bytes bs) : leBytes (getLE bs) bs.length = bs := by
  induction bs with
  | nil => rfl
  | cons b bs ih =>
    have hb : b < 256 := h b (by simp)
    simp only [getLE, List.length_cons, leBytes]
    have e1 : (b + 256 * getLE bs) % 256 = b := by omega
    have e2 : (b + 256 * getLE bs) / 256 = getLE bs := by omega
    rw [e1, e2, ih (fun x hx => h x (by simp [hx]))]

theorem getD_cons_zero (a : Nat) (l : List Nat) : (a :: l).getD 0 0 = a := rfl

theorem getD_cons_succ (a : Nat) (l : List Nat) (i : Nat) : (a :: l).getD (i + 1) 0 = l.getD i 0 := rfl

theorem length_controls (L : List Nat) : (controls L).length = controlCount L.length := by
  unfold controlCount
  induction L using controls.induct with
  | case1 => rfl
  | case2 => simp [controls]
  | case3 => simp [controls]
  | case4 => simp [controls]
  | case5 a b c d rest ih => simp only [controls, List.length_cons, ih]; omega

theorem codeLength_controls (L rest : List Nat) (hL : ∀ l ∈ L, 1 ≤ l ∧ l ≤ 4) (i : Nat) (hi : i < L.length) :
    codeLength (controls L ++ rest) i = L.getD i 0 := by
  induction L using controls.induct generalizing i with
  | case1 => simp at hi
  | case2 a =>
    have ha := hL a (by simp)
    simp at hi; subst hi
    simp [codeLength, controls, ctrlByte]; omega
  | case3 a b =>
    have ha := hL a (by simp); have hb := hL b (by simp)
    simp at hi
    rcases (by omega : i = 0 ∨ i = 1) with h | h <;> subst h <;> simp [codeLength, controls, ctrlByte] <;> omega
  | case4 a b c =>
    have ha := hL a (by simp); have hb := hL b (by simp); have hc := hL c (by simp)
    simp at hi
    rcases (by omega : i = 0 ∨ i = 1 ∨ i = 2) with h | h | h <;> subst h <;> simp [codeLength, controls, ctrlByte] <;> omega
  | case5 a b c d rest' ih =>
    have ha := hL a (by simp); have hb := hL b (by simp); have hc := hL c (by simp); have hd := hL d (by simp)
    simp only [List.length_cons] at hi
    by_cases hlt : i < 4
    · rcases (by omega : i = 0 ∨ i = 1 ∨ i = 2 ∨ i = 3) with h | h | h | h <;> subst h <;>
        simp [codeLength, controls, ctrlByte] <;> omega
    · have hi' : i - 4 < rest'.length := by omega
      have ih' := ih (fun l hl => hL l (by simp [hl])) (i - 4) hi'
      have e : i = (i - 4) + 4 := by omega
      rw [e]
      simp only [codeLength] at ih' ⊢
      have q : ((i - 4) + 4) / 4 = (i - 4) / 4 + 1 := by omega
      have r : ((i - 4) + 4) % 4 = (i - 4) % 4 := by omega
      rw [q, r, controls, List.cons_append, getD_cons_succ, ih']
      rfl

theorem decodeWith_used (lenf : Nat → Nat) (data : List Nat) (i pos k : Nat) :
    (decodeWith lenf data i pos k).2 = pos + sumBelow (fun j => lenf (i + j)) k := by
  induction k generalizing i pos with
  | zero => simp [decodeWith, sumBelow]
  | succ k ih =>
    simp only [decodeWith, ih, sumBelow]
    have : sumBelow (fun j => lenf (i + 1 + j)) k + lenf i = sumBelow (fun j => lenf (i + j)) k + lenf (i + k) := by
      clear ih
      induction k with
      | zero => simp [sumBelow]
      | succ k ih2 =>
        simp only [sumBelow]
        have e : i + 1 + k = i + (k + 1) := by omega
        rw [e]; omega
    omega

theorem decodeWith_length (lenf : Nat → Nat) (data : List Nat) (i pos k : Nat) :
    (decodeWith lenf data i pos k).1.length = k := by
  induction k generalizing i pos with
  | zero => rfl
  | succ k ih => simp [decodeWith, ih]

theorem decodeWith_payload (lenf : Nat → Nat) (vs pre rest : List Nat) (i : Nat)
    (hv : ∀ v ∈ vs, v < 2 ^ 32) (hl : ∀ j, j < vs.length → lenf (i + j) = valueLength (vs.getD j 0)) :
    decodeWith lenf (pre ++ payload vs ++ rest) i pre.length vs.length = (vs, pre.length + (payload vs).length) := by
  induction vs generalizing pre i with
  | nil => simp [decodeWith, payload]
  | cons v vs ih =>
    have h0 := hl 0 (by simp)
    simp only [Nat.add_zero, getD_cons_zero] at h0
    have hfit := valueLength_fits (hv v (by simp))
    have hpay : payload (v :: vs) = leBytes v (valueLength v) ++ payload vs := by simp [payload]
    have ih' := ih (pre ++ leBytes v (valueLength v)) (i + 1) (fun x hx => hv x (by simp [hx]))
      (fun j hj => by
        have := hl (j + 1) (by simp; omega)
        rw [show i + 1 + j = i + (j + 1) by omega, this]; rfl)
    simp only [List.length_cons, decodeWith, h0]
    rw [hpay] at ⊢
    have e1 : pre ++ (leBytes v (valueLength v) ++ payload vs) ++ rest = pre ++ leBytes v (valueLength v) ++ payload vs ++ rest := by
      simp [List.append_assoc]
    have hval : getValue (pre ++ (leBytes v (valueLength v) ++ payload vs) ++ rest) pre.length (valueLength v) = v := by
      unfold getValue
      rw [List.append_assoc, List.drop_left, List.append_assoc]
      rw [List.take_append_of_le_length (by rw [length_leBytes]; exact Nat.le_refl _),
        List.take_of_length_le (by rw [length_leBytes]; exact Nat.le_refl _),
        getLE_leBytes, Nat.mod_eq_of_lt hfit]
    rw [hval, e1]
    have hlen : (pre ++ leBytes v (valueLength v)).length = pre.length + valueLength v := by simp [length_leBytes]
    rw [← hlen, ih']
    simp [List.length_append, length_leBytes, Nat.add_assoc]

theorem length_encode (vs : List Nat) :
    (encode vs).length = controlCount vs.length + sumBelow (fun j => valueLength (vs.getD j 0)) vs.length := by
  unfold encode
  rw [List.length_append, length_controls, List.length_map]
  congr 1
  induction vs with
  | nil => rfl
  | cons v vs ih =>
    simp only [payload, List.flatMap_cons, List.length_append, length_leBytes] at ih ⊢
    rw [ih]
    simp only [List.length_cons]
    clear ih
    induction vs.length with
    | zero => simp [sumBelow]
    | succ n ihn =>
      simp only [sumBelow, getD_cons_succ] at ihn ⊢
      omega

theorem decode_encode (vs rest : List Nat) (hv : ∀ v ∈ vs, v < 2 ^ 32) :
    decode (encode vs ++ rest) vs.length = (vs, (encode vs).length) := by
  unfold decode
  have hL : ∀ l ∈ vs.map valueLength, 1 ≤ l ∧ l ≤ 4 := by
    intro l hl
    simp only [List.mem_map] at hl
    obtain ⟨v, _, rfl⟩ := hl
    exact valueLength_pos v
  have hc := length_controls (vs.map valueLength)
  rw [List.length_map] at hc
  have key := decodeWith_payload (codeLength (encode vs ++ rest)) vs (controls (vs.map valueLength)) rest 0 hv
    (fun j hj => by
      simp only [Nat.zero_add]
      unfold encode
      rw [List.append_assoc, codeLength_controls _ _ hL j (by simp; exact hj)]
      simp [List.getD_eq_getElem?_getD, List.getElem?_map, List.getElem?_eq_getElem hj])
  rw [hc] at key
  unfold encode at key ⊢
  rw [List.append_assoc] at key ⊢
  rw [key, List.length_append, hc]

theorem decode_used (data : List Nat) (n : Nat) :
    (decode data n).2 = controlCount n + sumBelow (fun j => codeLength data j) n := by
  unfold decode
  rw [decodeWith_used]
  simp

theorem sumBelow_groups (f : Nat → Nat) (m : Nat) :
    sumBelow f (4 * m) = sumBelow (fun g => f (4 * g) + f (4 * g + 1) + f (4 * g + 2) + f (4 * g + 3)) m := by
  induction m with
  | zero => rfl
  | succ m ih =>
    rw [show 4 * (m + 1) = 4 * m + 1 + 1 + 1 + 1 by omega]
    simp only [sumBelow]
    rw [ih]
    have e1 : 4 * m + 1 + 1 = 4 * m + 2 := by omega
    have e2 : 4 * m + 1 + 1 + 1 = 4 * m + 3 := by omega
    rw [e1, e2]
    omega

theorem sumBelow_add (f : Nat → Nat) (a b : Nat) : sumBelow f (a + b) = sumBelow f a + sumBelow (fun k => f (a + k)) b := by
  induction b with
  | zero => rfl
  | succ b ih =>
    rw [← Nat.add_assoc]
    simp only [sumBelow]
    rw [ih]
    omega

theorem groupLength_codeLength (data : List Nat) (g : Nat) :
    groupLength (data.getD g 0) = codeLength data (4 * g) + codeLength data (4 * g + 1) +
      codeLength data (4 * g + 2) + codeLength data (4 * g + 3) := by
  unfold groupLength codeLength
  have a0 : 4 * g / 4 = g := by omega
  have a1 : (4 * g + 1) / 4 = g := by omega
  have a2 : (4 * g + 2) / 4 = g := by omega
  have a3 : (4 * g + 3) / 4 = g := by omega
  have b0 : 4 * g % 4 = 0 := by omega
  have b1 : (4 * g + 1) % 4 = 1 := by omega
  have b2 : (4 * g + 2) % 4 = 2 := by omega
  have b3 : (4 * g + 3) % 4 = 3 := by omega
  rw [a0, a1, a2, a3, b0, b1, b2, b3]
  simp

theorem encodedLength_decode (data : List Nat) (n : Nat) (h : controlCount n ≤ data.length) :
    encodedLength data n = some (decode data n).2 := by
  unfold encodedLength
  simp only [show ¬ (data.length < controlCount n) from by omega, ↓reduceIte]
  rw [decode_used]
  congr 1
  have hn : n = 4 * (n / 4) + n % 4 := by omega
  have hsplit : sumBelow (fun j => codeLength data j) n = sumBelow (fun j => codeLength data j) (4 * (n / 4)) +
      sumBelow (fun k => codeLength data (4 * (n / 4) + k)) (n % 4) := by
    have := sumBelow_add (fun j => codeLength data j) (4 * (n / 4)) (n % 4)
    rw [← hn] at this
    exact this
  rw [hsplit, sumBelow_groups]
  have : sumBelow (fun g => groupLength (data.getD g 0)) (n / 4) =
      sumBelow (fun g => codeLength data (4 * g) + codeLength data (4 * g + 1) + codeLength data (4 * g + 2) +
        codeLength data (4 * g + 3)) (n / 4) := by
    congr 1; funext g; exact groupLength_codeLength data g
  rw [this]
  have e : (fun k => codeLength data (n / 4 * 4 + k)) = (fun k => codeLength data (4 * (n / 4) + k)) := by
    funext k; rw [Nat.mul_comm]
  rw [e]
  omega

theorem encodedLength_encode (vs : List Nat) (hv : ∀ v ∈ vs, v < 2 ^ 32) :
    encodedLength (encode vs) vs.length = some (encode vs).length := by
  have h := decode_encode vs [] hv
  rw [List.append_nil] at h
  rw [encodedLength_decode _ _ (by rw [length_encode]; omega), h]

theorem prefixSums_deltas (prev : Nat) (vs : List Nat) (hp : prev < u32Mod) (hv : ∀ v ∈ vs, v < u32Mod) :
    prefixSums prev (deltas prev vs) = vs := by
  induction vs generalizing prev with
  | nil => rfl
  | cons v vs ih =>
    have h1 := hv v (by simp)
    simp only [deltas, prefixSums]
    have e : (prev + (v + u32Mod - prev) % u32Mod) % u32Mod = v := by unfold u32Mod at *; omega
    rw [e, ih v h1 (fun x hx => hv x (by simp [hx]))]

theorem deltas_lt (prev : Nat) (vs : List Nat) : ∀ d ∈ deltas prev vs, d < u32Mod := by
  induction vs generalizing prev with
  | nil => intro d hd; simp [deltas] at hd
  | cons v vs ih =>
    intro d hd
    simp only [deltas, List.mem_cons] at hd
    rcases hd with h | h
    · subst h; exact Nat.mod_lt _ (by decide)
    · exact ih v d h

theorem length_deltas (prev : Nat) (vs : List Nat) : (deltas prev vs).length = vs.length := by
  induction vs generalizing prev with
  | nil => rfl
  | cons v vs ih => simp [deltas, ih]

theorem decodeDelta_encodeDelta (vs rest : List Nat) (prev : Nat) (hp : prev < u32Mod) (hv : ∀ v ∈ vs, v < u32Mod) :
    decodeDelta (encodeDelta vs prev ++ rest) vs.length prev = (vs, (encodeDelta vs prev).length) := by
  unfold decodeDelta encodeDelta
  have h := decode_encode (deltas prev vs) rest (fun d hd => by have := deltas_lt prev vs d hd; unfold u32Mod at this; omega)
  rw [length_deltas] at h
  rw [h]
  simp only [prefixSums_deltas prev vs hp hv]

theorem deltas_sorted (prev : Nat) (vs : List Nat) (hp : prev < u32Mod) (hv : ∀ v ∈ vs, v < u32Mod)
    (hs : List.Pairwise (· < ·) (prev :: vs)) : deltas prev vs = (List.zipWith (· - ·) vs (prev :: vs)) := by
  induction vs generalizing prev with
  | nil => rfl
  | cons v vs ih =>
    have hpv : prev < v := (List.pairwise_cons.1 hs).1 v (by simp)
    have hlt := hv v (by simp)
    simp only [deltas, List.zipWith_cons_cons]
    rw [ih v hlt (fun x hx => hv x (by simp [hx])) (List.pairwise_cons.1 hs).2]
    congr 1
    unfold u32Mod at *; omega

theorem getLE_lt_pow {bs : List Nat} (h : Bytes bs) (len : Nat) (hl : bs.length ≤ len) : getLE bs < 256 ^ len :=
  Nat.lt_of_lt_of_le (getLE_lt h) (Nat.pow_le_pow_right (by decide) hl)

theorem bytes_take_drop {data : List Nat} (h : Bytes data) (pos len : Nat) : Bytes ((data.drop pos).take len) :=
  fun b hb => h b (List.mem_of_mem_drop (List.mem_of_mem_take hb))

theorem getValue_lt {data : List Nat} (h : Bytes data) (pos len : Nat) : getValue data pos len < 256 ^ len :=
  getLE_lt_pow (bytes_take_drop h pos len) len (by rw [List.length_take]; exact Nat.min_le_left _ _)

def offsetOf (lenf : Nat → Nat) (i pos j : Nat) : Nat := pos + sumBelow (fun m => lenf (i + m)) j

theorem decodeWith_get (lenf : Nat → Nat) (data : List Nat) (i pos k j : Nat) (hj : j < k) :
    (decodeWith lenf data i pos k).1.getD j 0 = getValue data (offsetOf lenf i pos j) (lenf (i + j)) := by
  induction k generalizing i pos j with
  | zero => omega
  | succ k ih =>
    rcases j with _ | j
    · simp [decodeWith, offsetOf, sumBelow]
    · simp only [decodeWith]
      rw [getD_cons_succ, ih (i + 1) (pos + lenf i) j (by omega)]
      unfold offsetOf
      have e : pos + lenf i + sumBelow (fun m => lenf (i + 1 + m)) j = pos + sumBelow (fun m => lenf (i + m)) (j + 1) := by
        clear ih hj
        induction j with
        | zero => simp [sumBelow]
        | succ j ihj =>
          simp only [sumBelow] at ihj ⊢
          rw [show i + 1 + j = i + (j + 1) by omega]
          omega
      rw [e, show i + 1 + j = i + (j + 1) by omega]

theorem sumBelow_le_pointwise {f g : Nat → Nat} {n : Nat} (h : ∀ i, i < n → f i ≤ g i) : sumBelow f n ≤ sumBelow g n := by
  induction n with
  | zero => exact Nat.le_refl _
  | succ n ih => simp only [sumBelow]; exact Nat.add_le_add (ih fun i hi => h i (by omega)) (h n (by omega))

theorem sumBelow_eq_pointwise {f g : Nat → Nat} {n : Nat} (h : ∀ i, i < n → f i ≤ g i) (he : sumBelow f n = sumBelow g n) :
    ∀ i, i < n → f i = g i := by
  induction n with
  | zero => intro i hi; omega
  | succ n ih =>
    simp only [sumBelow] at he
    have a := sumBelow_le_pointwise (fun i (hi : i < n) => h i (by omega))
    have b := h n (by omega)
    intro i hi
    rcases Nat.lt_or_ge i n with hlt | hge
    · exact ih (fun j hj => h j (by omega)) (by omega) i hlt
    · have : i = n := by omega
      subst this; omega

theorem codeLength_bounds (data : List Nat) (i : Nat) : 1 ≤ codeLength data i ∧ codeLength data i ≤ 4 := by
  unfold codeLength; omega

theorem decode_get (data : List Nat) (n j : Nat) (hj : j < n) :
    (decode data n).1.getD j 0 = getValue data (offsetOf (codeLength data) 0 (controlCount n) j) (codeLength data j) := by
  unfold decode; rw [decodeWith_get _ _ _ _ _ _ hj, Nat.zero_add]

theorem decode_shortest (data : List Nat) (n : Nat) (h : Bytes data) :
    (encode (decode data n).1).length ≤ (decode data n).2 := by
  rw [length_encode, decode_used]
  unfold decode; rw [decodeWith_length]; rw [← decode.eq_1]
  apply Nat.add_le_add_left
  apply sumBelow_le_pointwise
  intro j hj
  rw [decode_get _ _ _ hj]
  exact valueLength_minimal (getValue_lt h _ _) (codeLength_bounds data j).1

theorem lengths_minimal (data : List Nat) (n : Nat) (h : Bytes data)
    (hmin : (decode data n).2 = (encode (decode data n).1).length) :
    ∀ j, j < n → valueLength ((decode data n).1.getD j 0) = codeLength data j := by
  have hlen : (decode data n).1.length = n := by unfold decode; rw [decodeWith_length]
  rw [length_encode, decode_used, hlen] at hmin
  have hsum : sumBelow (fun j => valueLength ((decode data n).1.getD j 0)) n = sumBelow (fun j => codeLength data j) n := by omega
  apply sumBelow_eq_pointwise _ hsum
  intro j hj
  rw [decode_get _ _ _ hj]
  exact valueLength_minimal (getValue_lt h _ _) (codeLength_bounds data j).1

theorem controls_unique (L C rest : List Nat) (hL : ∀ l ∈ L, 1 ≤ l ∧ l ≤ 4) (hC : Bytes C)
    (hCl : C.length = controlCount L.length)
    (hcode : ∀ i, i < L.length → codeLength (C ++ rest) i = L.getD i 0)
    (hpad : L.length % 4 = 0 ∨ C.getD (L.length / 4) 0 / 4 ^ (L.length % 4) = 0) : C = controls L := by
  induction L using controls.induct generalizing C with
  | case1 => unfold controlCount at hCl; simp at hCl; simp [hCl, controls]
  | case2 a =>
    unfold controlCount at hCl; simp at hCl
    obtain ⟨c, hc⟩ : ∃ c, C = [c] := by
      rcases C with _ | ⟨c, _ | _⟩ <;> simp at hCl
      exact ⟨c, rfl⟩
    subst hc
    have hc256 := hC c (by simp)
    have h0 := hcode 0 (by simp)
    simp [codeLength] at h0 hpad
    simp [controls, ctrlByte]; omega
  | case3 a b =>
    unfold controlCount at hCl; simp at hCl
    obtain ⟨c, hc⟩ : ∃ c, C = [c] := by
      rcases C with _ | ⟨c, _ | _⟩ <;> simp at hCl
      exact ⟨c, rfl⟩
    subst hc
    have hc256 := hC c (by simp)
    have h0 := hcode 0 (by simp)
    have h1 := hcode 1 (by simp)
    simp [codeLength] at h0 h1 hpad
    simp [controls, ctrlByte]; omega
  | case4 a b c =>
    unfold controlCount at hCl; simp at hCl
    obtain ⟨x, hx⟩ : ∃ x, C = [x] := by
      rcases C with _ | ⟨x, _ | _⟩ <;> simp at hCl
      exact ⟨x, rfl⟩
    subst hx
    have hc256 := hC x (by simp)
    have h0 := hcode 0 (by simp)
    have h1 := hcode 1 (by simp)
    have h2 := hcode 2 (by simp)
    simp [codeLength] at h0 h1 h2 hpad
    simp [controls, ctrlByte]; omega
  | case5 a b c d rest' ih =>
    obtain ⟨x, C', hx⟩ : ∃ x C', C = x :: C' := by
      rcases C with _ | ⟨x, C'⟩
      · unfold controlCount at hCl; simp at hCl; omega
      · exact ⟨x, C', rfl⟩
    subst hx
    have hx256 := hC x (by simp)
    have h0 := hcode 0 (by simp)
    have h1 := hcode 1 (by simp)
    have h2 := hcode 2 (by simp)
    have h3 := hcode 3 (by simp)
    simp [codeLength] at h0 h1 h2 h3
    have hx' : x = ctrlByte [a, b, c, d] := by simp [ctrlByte]; omega
    have ih' := ih C' (fun l hl => hL l (by simp [hl])) (fun y hy => hC y (by simp [hy]))
      (by unfold controlCount at hCl ⊢; simp at hCl; omega)
      (fun i hi => by
        have := hcode (i + 4) (by simp; omega)
        simp only [codeLength] at this ⊢
        rw [show (i + 4) / 4 = i / 4 + 1 by omega, show (i + 4) % 4 = i % 4 by omega, List.cons_append, getD_cons_succ] at this
        rw [this]; rfl)
      (by
        simp only [List.length_cons] at hpad
        rcases hpad with hp | hp
        · left; omega
        · right
          rw [show (rest'.length + 1 + 1 + 1 + 1) / 4 = rest'.length / 4 + 1 by omega,
            show (rest'.length + 1 + 1 + 1 + 1) % 4 = rest'.length % 4 by omega, getD_cons_succ] at hp
          exact hp)
    rw [hx', ih']
    rfl

theorem payload_of_decode (lenf : Nat → Nat) (data : List Nat) (h : Bytes data) (i pos k : Nat)
    (hlen : (decodeWith lenf data i pos k).2 ≤ data.length)
    (hmin : ∀ j, j < k → valueLength ((decodeWith lenf data i pos k).1.getD j 0) = lenf (i + j)) :
    (data.drop pos).take ((decodeWith lenf data i pos k).2 - pos) = payload (decodeWith lenf data i pos k).1 := by
  induction k generalizing i pos with
  | zero => simp [decodeWith, payload]
  | succ k ih =>
    have h0 := hmin 0 (by omega)
    simp only [decodeWith, getD_cons_zero, Nat.add_zero] at h0 hlen ⊢
    have hused := decodeWith_used lenf data (i + 1) (pos + lenf i) k
    have ih' := ih (i + 1) (pos + lenf i) hlen (fun j hj => by
      have := hmin (j + 1) (by omega)
      simp only [decodeWith, getD_cons_succ] at this
      rw [this]; congr 1; omega)
    simp only [payload, List.flatMap_cons] at ih' ⊢
    rw [h0]
    have hsplit : (data.drop pos).take ((decodeWith lenf data (i + 1) (pos + lenf i) k).2 - pos) =
        (data.drop pos).take (lenf i) ++ (data.drop (pos + lenf i)).take ((decodeWith lenf data (i + 1) (pos + lenf i) k).2 - (pos + lenf i)) := by
      rw [show (decodeWith lenf data (i + 1) (pos + lenf i) k).2 - pos = lenf i + ((decodeWith lenf data (i + 1) (pos + lenf i) k).2 - (pos + lenf i)) by omega]
      rw [List.take_add, List.drop_drop]
    rw [hsplit, ih']
    congr 1
    unfold getValue
    have hl : ((data.drop pos).take (lenf i)).length = lenf i := by
      simp only [List.length_take, List.length_drop]; omega
    have := leBytes_getLE (bytes_take_drop h pos (lenf i))
    rw [hl] at this
    exact this.symm

theorem decode_canonical (data : List Nat) (n : Nat) (h : Bytes data) (hlen : (decode data n).2 ≤ data.length)
    (hmin : (decode data n).2 = (encode (decode data n).1).length) (hpad : paddingClear data n) :
    data.take (decode data n).2 = encode (decode data n).1 := by
  have hm := lengths_minimal data n h hmin
  have hdl : (decode data n).1.length = n := by unfold decode; rw [decodeWith_length]
  have hcb : controlCount n ≤ (decode data n).2 := by rw [decode_used]; omega
  have hsplit : data.take (decode data n).2 = data.take (controlCount n) ++ (data.drop (controlCount n)).take ((decode data n).2 - controlCount n) := by
    conv => lhs; rw [show (decode data n).2 = controlCount n + ((decode data n).2 - controlCount n) by omega]
    rw [List.take_add]
  rw [hsplit]
  unfold encode
  congr 1
  · have hL : ∀ l ∈ (decode data n).1.map valueLength, 1 ≤ l ∧ l ≤ 4 := by
      intro l hl; simp only [List.mem_map] at hl; obtain ⟨v, _, rfl⟩ := hl; exact valueLength_pos v
    apply controls_unique _ _ (data.drop (controlCount n)) hL (fun b hb => h b (List.mem_of_mem_take hb))
    · simp only [List.length_take, List.length_map, hdl]; omega
    · intro i hi
      simp only [List.length_map, hdl] at hi
      rw [List.take_append_drop]
      simp only [List.getD_eq_getElem?_getD, List.getElem?_map]
      rw [List.getElem?_eq_getElem (by rw [hdl]; exact hi)]
      simp only [Option.map_some, Option.getD_some]
      have := hm i hi
      rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem (by rw [hdl]; exact hi)] at this
      exact this.symm
    · simp only [List.length_map, hdl]
      by_cases h0 : n % 4 = 0
      · left; exact h0
      · right
        rcases hpad with hp | hp
        · exact absurd hp h0
        · have hlt : n / 4 < controlCount n := by unfold controlCount; omega
          rw [List.getD_eq_getElem?_getD, List.getElem?_take]
          simp only [hlt, ↓reduceIte]; rw [← List.getD_eq_getElem?_getD]; exact hp
  · unfold decode at hmin hm hlen ⊢
    have := payload_of_decode (codeLength data) data h 0 (controlCount n) n hlen
      (fun j hj => by rw [Nat.zero_add]; exact hm j hj)
    exact this

end Postings
