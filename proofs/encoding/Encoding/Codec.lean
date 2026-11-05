import Std

namespace Encoding

def digits (base : Nat) : Nat → Nat → List Nat
  | 0, _ => []
  | width + 1, value => value % base :: digits base width (value / base)

def number (base : Nat) : List Nat → Nat
  | [] => 0
  | byte :: rest => byte + base * number base rest

theorem digits_length (base width value : Nat) : (digits base width value).length = width := by
  induction width generalizing value with
  | zero => rfl
  | succ width ih => simp [digits, ih]

theorem digits_bounded (base width value : Nat) (hb : 0 < base) :
    ∀ byte ∈ digits base width value, byte < base := by
  induction width generalizing value with
  | zero => simp [digits]
  | succ width ih =>
    simp only [digits, List.mem_cons]
    intro byte h
    rcases h with rfl | h
    · exact Nat.mod_lt _ hb
    · exact ih _ _ h

theorem digits_reconstruct (base width value : Nat) (hb : 0 < base)
    (hv : value < base ^ width) : number base (digits base width value) = value := by
  induction width generalizing value with
  | zero => simp only [Nat.pow_zero] at hv; simp [digits, number]; omega
  | succ width ih =>
    have hdiv : value / base < base ^ width := by
      apply (Nat.div_lt_iff_lt_mul hb).2
      simpa [Nat.pow_succ, Nat.mul_comm] using hv
    simp only [digits, number, ih _ hdiv]
    exact Nat.mod_add_div _ _

def byteBits (width : Nat) (value : Int) := BitVec.ofInt (8 * width) value

def encodeSigned (width : Nat) (value : Int) : List Nat :=
  digits 256 width (byteBits width value).toNat

def decodeSigned (width : Nat) (bytes : List Nat) : Int :=
  (BitVec.ofNat (8 * width) (number 256 bytes)).toInt

theorem byte_capacity (width : Nat) : 2 ^ (8 * width) = 256 ^ width := by
  rw [Nat.pow_mul]

theorem signed_bytes_bits (width : Nat) (value : Int) :
    number 256 (encodeSigned width value) = (byteBits width value).toNat := by
  apply digits_reconstruct _ _ _ (by decide)
  rw [← byte_capacity]
  exact BitVec.isLt _

theorem signed_bytes_roundtrip (width : Nat) (value : Int) (hw : 0 < width)
    (lo : -(2 : Int) ^ (8 * width - 1) ≤ value)
    (hi : value < (2 : Int) ^ (8 * width - 1)) :
    decodeSigned width (encodeSigned width value) = value := by
  unfold decodeSigned
  rw [signed_bytes_bits]
  simp only [BitVec.ofNat_toNat, BitVec.setWidth_eq]
  exact BitVec.toInt_ofInt_eq_self (by omega) lo hi

def encode13 (value : Int) : List Nat :=
  let raw := (BitVec.ofInt 13 value).toNat
  [192 + raw / 256, raw % 256]

def decode13 (tag byte : Nat) : Int :=
  (BitVec.ofNat 13 ((tag - 192) * 256 + byte)).toInt

theorem int13_tags (value : Int) :
    ∀ tag ∈ (encode13 value).take 1, 192 ≤ tag ∧ tag < 224 := by
  have h := (BitVec.ofInt 13 value).isLt
  simp only [encode13, List.take_succ_cons, List.take_zero, List.mem_cons, List.not_mem_nil,
    or_false]
  intro tag heq
  subst tag
  omega

theorem int13_roundtrip (value : Int) (lo : -4096 ≤ value) (hi : value ≤ 4095) :
    decode13 (192 + (BitVec.ofInt 13 value).toNat / 256)
      ((BitVec.ofInt 13 value).toNat % 256) = value := by
  unfold decode13
  rw [Nat.add_sub_cancel_left, Nat.mul_comm, Nat.div_add_mod]
  simp only [BitVec.ofNat_toNat]
  exact BitVec.toInt_ofInt_eq_self (by decide) lo (by omega)

def integerSize (value : Int) : Nat :=
  if 0 ≤ value ∧ value ≤ 127 then 1
  else if -4096 ≤ value ∧ value ≤ 4095 then 2
  else if -32768 ≤ value ∧ value ≤ 32767 then 3
  else if -8388608 ≤ value ∧ value ≤ 8388607 then 4
  else if -2147483648 ≤ value ∧ value ≤ 2147483647 then 5 else 9

def encodeInteger (value : Int) : List Nat :=
  let size := integerSize value
  if size = 1 then [value.toNat]
  else if size = 2 then encode13 value
  else (if size = 3 then 241 else if size = 4 then 242 else if size = 5 then 243 else 244)
    :: encodeSigned (size - 1) value

theorem int7_roundtrip (value : Nat) (h : value ≤ 127) :
    encodeInteger value = [value] ∧ number 256 [value] = value := by
  have hi : (value : Int) ≤ 127 := by omega
  simp [encodeInteger, integerSize, hi, number]

theorem extended_integer_roundtrip (width : Nat) (value : Int) (hw : width ∈ [2, 3, 4, 8])
    (lo : -(2 : Int) ^ (8 * width - 1) ≤ value)
    (hi : value < (2 : Int) ^ (8 * width - 1)) :
    decodeSigned width (encodeSigned width value) = value := by
  apply signed_bytes_roundtrip width value _ lo hi
  simp only [List.mem_cons, List.not_mem_nil, or_false] at hw
  omega

def stringHeaderSize (length : Nat) : Nat :=
  if length < 64 then 1 else if length < 4096 then 2 else 5

def stringHeader (length : Nat) : List Nat :=
  if length < 64 then [128 + length]
  else if length < 4096 then [224 + length / 256, length % 256]
  else 240 :: digits 256 4 length

def stringLength : List Nat → Option Nat
  | tag :: rest =>
    if 128 ≤ tag ∧ tag < 192 then some (tag - 128)
    else if 224 ≤ tag ∧ tag < 240 then
      match rest with
      | byte :: _ => some ((tag - 224) * 256 + byte)
      | _ => none
    else if tag = 240 ∧ 4 ≤ rest.length then some (number 256 (rest.take 4))
    else none
  | _ => none

theorem string_header_length (length : Nat) :
    (stringHeader length).length = stringHeaderSize length := by
  unfold stringHeader stringHeaderSize
  split <;> (try split) <;> simp [digits_length]

theorem string_header_roundtrip (length : Nat) (h : length < 2 ^ 32) :
    stringLength (stringHeader length) = some length := by
  unfold stringHeader
  split
  · rename_i hsmall
    simp [stringLength, show 128 + length < 192 by omega]
  · rename_i hlarge
    split
    · rename_i hsmall
      have ht : 224 + length / 256 < 240 := by omega
      simp [stringLength, ht, show ¬224 + length / 256 < 192 by omega,
        Nat.mul_comm, Nat.div_add_mod]
    · simp only [stringLength, show ¬ (128 ≤ 240 ∧ 240 < 192) by decide,
        show ¬ (224 ≤ 240 ∧ 240 < 240) by decide, ↓reduceIte, digits_length,
        Nat.le_refl, and_self]
      congr 1
      exact digits_reconstruct 256 4 length (by decide) h

def backWidth (length : Nat) : Nat :=
  if length ≤ 127 then 1 else if length < 16383 then 2
  else if length < 2097151 then 3 else if length < 268435455 then 4 else 5

def backEncode (length : Nat) : List Nat :=
  match (digits 128 (backWidth length) length).reverse with
  | [] => []
  | first :: rest => first :: rest.map (· + 128)

def backDecode (bytes : List Nat) : Nat :=
  number 128 ((bytes.map (· % 128)).reverse)

theorem back_width_capacity (length : Nat) (h : length < 2 ^ 32) :
    length < 128 ^ backWidth length := by
  unfold backWidth
  split <;> (try split) <;> (try split) <;> (try split) <;> omega

theorem back_width_positive (length : Nat) : 0 < backWidth length := by
  unfold backWidth
  split <;> (try split) <;> (try split) <;> (try split) <;> decide

theorem back_roundtrip (length : Nat) (h : length < 2 ^ 32) :
    backDecode (backEncode length) = length := by
  have hb := digits_bounded 128 (backWidth length) length (by decide)
  have hnonempty : (digits 128 (backWidth length) length).reverse ≠ [] := by
    intro he
    have hl := congrArg List.length he
    simp only [List.length_reverse, digits_length, List.length_nil] at hl
    have := back_width_positive length
    omega
  unfold backEncode
  split
  · rename_i he
    exact False.elim (hnonempty he)
  · rename_i first rest he
    have hbound : ∀ b ∈ first :: rest, b < 128 := by
      intro b hm
      apply hb b
      rw [← List.mem_reverse]
      rw [he]
      exact hm
    have hmod : (first :: rest).map (· % 128) = first :: rest := by
      calc
        _ = (first :: rest).map id := List.map_congr_left (fun b hm => Nat.mod_eq_of_lt (hbound b hm))
        _ = _ := List.map_id _
    unfold backDecode
    simp only [List.map_cons, List.map_map]
    simp only [Function.comp_def, Nat.add_mod, Nat.mod_self, Nat.add_zero, Nat.mod_mod]
    change number 128 (((first :: rest).map (· % 128)).reverse) = length
    rw [hmod, ← he, List.reverse_reverse]
    exact digits_reconstruct 128 _ length (by decide) (back_width_capacity length h)

def entryExtent (offset body back limit : Nat) : Option Nat :=
  if 0 < body ∧ offset + body ≤ limit ∧ back ≤ limit - (offset + body)
    then some (offset + body + back) else none

theorem entry_extent_bounds (offset body back limit finish : Nat)
    (h : entryExtent offset body back limit = some finish) :
    offset < finish ∧ finish ≤ limit := by
  unfold entryExtent at h
  split at h <;> simp_all <;> omega

structure DecodedBody where
  bytes : Nat
  value : Int := 0
  payload : Option (List Nat) := none
  deriving Repr, BEq, DecidableEq

def decodeBody (data : List Nat) (offset : Nat := 0) : Option DecodedBody := do
  let bytes := data.drop offset
  let tag ← bytes.head?
  if tag < 128 then return {bytes := 1, value := tag}
  else if tag < 192 then
    let length := tag % 64
    if length + 1 ≤ bytes.length then
      return {bytes := length + 1, payload := some ((bytes.drop 1).take length)}
    else none
  else if tag < 224 then
    let b ← bytes[1]?
    return {bytes := 2, value := decode13 tag b}
  else if tag < 240 then
    let b ← bytes[1]?
    let length := (tag % 16) * 256 + b
    if length + 2 ≤ bytes.length then
      return {bytes := length + 2, payload := some ((bytes.drop 2).take length)}
    else none
  else if tag = 240 then
    if 5 ≤ bytes.length then
      let length := number 256 ((bytes.drop 1).take 4)
      if length + 5 ≤ bytes.length then
        return {bytes := length + 5, payload := some ((bytes.drop 5).take length)}
      else none
    else none
  else
    let width := if tag = 241 then 2 else if tag = 242 then 3
      else if tag = 243 then 4 else if tag = 244 then 8 else 0
    if width = 0 ∨ bytes.length < width + 1 then none
    else return {bytes := width + 1, value := decodeSigned width ((bytes.drop 1).take width)}

def backScan : Nat → List Nat → Option (Nat × Nat)
  | 0, _ => none
  | _ + 1, [] => none
  | fuel + 1, byte :: rest =>
    if byte < 128 then some (byte, 1)
    else do
      let (value, width) ← backScan fuel rest
      return (byte % 128 + 128 * value, width + 1)

def readBack (data : List Nat) (last lower : Nat) : Option (Nat × Nat) := do
  if last < lower ∨ data.length ≤ last then none
  else
    let (value, width) ← backScan 5 (((data.take (last + 1)).drop lower).reverse)
    if value < 2 ^ 32 then some (value, width) else none

def decodeExtent (data : List Nat) (offset limit : Nat) : Option Nat := do
  if limit > data.length ∨ offset ≥ limit then none
  else
    let body ← decodeBody (data.take limit) offset
    let finish ← entryExtent offset body.bytes (backWidth body.bytes) limit
    let (back, _) ← readBack data (finish - 1) 0
    if back = body.bytes then some finish else none

def encodeString (value : List Nat) := stringHeader value.length ++ value

theorem string_payload_reconstruction (value : List Nat) :
    ((encodeString value).drop (stringHeaderSize value.length)).take value.length = value := by
  unfold encodeString
  rw [← string_header_length]
  simp

theorem string_body_length (value : List Nat) :
    (encodeString value).length = stringHeaderSize value.length + value.length := by
  simp [encodeString, string_header_length]

theorem encoded_entry_boundary (offset body limit : Nat) (hb : 0 < body)
    (hl : offset + body + backWidth body ≤ limit) :
    entryExtent offset body (backWidth body) limit = some (offset + body + backWidth body) := by
  simp [entryExtent, hb, show offset + body ≤ limit by omega,
    show backWidth body ≤ limit - (offset + body) by omega]

def extendedTag (width : Nat) : Nat :=
  if width = 2 then 241 else if width = 3 then 242 else if width = 4 then 243 else 244

theorem extended_body_roundtrip (width : Nat) (value : Int) (hw : width ∈ [2, 3, 4, 8])
    (lo : -(2 : Int) ^ (8 * width - 1) ≤ value)
    (hi : value < (2 : Int) ^ (8 * width - 1)) :
    decodeBody (extendedTag width :: encodeSigned width value) =
      some {bytes := width + 1, value := value} := by
  have hlength : (encodeSigned width value).length = width := digits_length _ _ _
  have htake : (encodeSigned width value).take width = encodeSigned width value := by
    exact List.take_of_length_le (by omega)
  have hround := extended_integer_roundtrip width value hw lo hi
  have htags : 240 < extendedTag width ∧ extendedTag width ≤ 244 := by
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hw
    rcases hw with rfl | rfl | rfl | rfl <;> decide
  have hselect : (if extendedTag width = 241 then 2 else if extendedTag width = 242 then 3
    else if extendedTag width = 243 then 4 else if extendedTag width = 244 then 8 else 0) = width := by
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hw
    rcases hw with rfl | rfl | rfl | rfl <;> decide
  have hpos : 0 < width := by
    simp only [List.mem_cons, List.not_mem_nil, or_false] at hw
    omega
  simp [decodeBody, show ¬extendedTag width < 128 by omega,
    show ¬extendedTag width < 192 by omega, show ¬extendedTag width < 224 by omega,
    show ¬extendedTag width < 240 by omega, show extendedTag width ≠ 240 by omega,
    hselect, hlength, show width ≠ 0 by omega, htake, hround]

theorem tagged_integer_roundtrip (value : Int)
    (lo : -9223372036854775808 ≤ value) (hi : value ≤ 9223372036854775807) :
    decodeBody (encodeInteger value) = some {bytes := integerSize value, value := value} := by
  unfold encodeInteger integerSize
  split
  · rename_i hsmall
    have hn : value.toNat < 128 := by omega
    have hv : (value.toNat : Int) = value := Int.toNat_of_nonneg hsmall.1
    simp [decodeBody, hn, hv]
  · rename_i hsmall
    split
    · rename_i h13
      have hrange := (BitVec.ofInt 13 value).isLt
      have ht0 : ¬192 + (BitVec.ofInt 13 value).toNat / 256 < 128 := by omega
      have ht1 : ¬192 + (BitVec.ofInt 13 value).toNat / 256 < 192 := by omega
      have ht2 : 192 + (BitVec.ofInt 13 value).toNat / 256 < 224 := by omega
      have hr := int13_roundtrip value h13.1 h13.2
      change ¬192 + (value % 8192).toNat / 256 < 128 at ht0
      change ¬192 + (value % 8192).toNat / 256 < 192 at ht1
      change 192 + (value % 8192).toNat / 256 < 224 at ht2
      change decode13 (192 + (value % 8192).toNat / 256) ((value % 8192).toNat % 256) = value at hr
      simp [encode13, decodeBody, ht0, ht1, ht2, hr]
    · rename_i h13
      split
      · rename_i h16
        simpa [extendedTag] using extended_body_roundtrip 2 value (by simp) h16.1 (by omega)
      · rename_i h16
        split
        · rename_i h24
          simpa [extendedTag] using extended_body_roundtrip 3 value (by simp) h24.1 (by omega)
        · rename_i h24
          split
          · rename_i h32
            simpa [extendedTag] using extended_body_roundtrip 4 value (by simp) h32.1 (by omega)
          · simpa [extendedTag] using extended_body_roundtrip 8 value (by simp) lo (by omega)

theorem string_body_roundtrip (value : List Nat) (h : value.length < 2 ^ 32) :
    decodeBody (encodeString value) =
      some {bytes := stringHeaderSize value.length + value.length, payload := some value} := by
  by_cases hsmall : value.length < 64
  · have ht0 : ¬128 + value.length < 128 := by omega
    have ht1 : 128 + value.length < 192 := by omega
    have hmod : (128 + value.length) % 64 = value.length := by omega
    simp [encodeString, stringHeader, stringHeaderSize, hsmall, decodeBody, ht0, ht1, hmod,
      List.take_length]
    simp [Nat.add_comm]
  · by_cases hmedium : value.length < 4096
    · have ht0 : ¬224 + value.length / 256 < 128 := by omega
      have ht1 : ¬224 + value.length / 256 < 192 := by omega
      have ht2 : ¬224 + value.length / 256 < 224 := by omega
      have ht3 : 224 + value.length / 256 < 240 := by omega
      have hmod : (224 + value.length / 256) % 16 = value.length / 256 := by omega
      have hsum : value.length / 256 * 256 + value.length % 256 = value.length := by omega
      simp [encodeString, stringHeader, stringHeaderSize, hsmall, hmedium, decodeBody,
        ht0, ht1, ht2, ht3, hmod, hsum, List.take_length]
      simp [Nat.add_comm]
    · have hlength : (digits 256 4 value.length).length = 4 := digits_length _ _ _
      have htake : (digits 256 4 value.length ++ value).take 4 = digits 256 4 value.length := by
        exact List.take_left' hlength
      have hdrop : (digits 256 4 value.length ++ value).drop 4 = value := by
        exact List.drop_left' hlength
      have hnum : number 256 (digits 256 4 value.length) = value.length :=
        digits_reconstruct 256 4 _ (by decide) h
      simp [encodeString, stringHeader, stringHeaderSize, hsmall, hmedium, decodeBody,
        hlength, htake, hdrop, hnum, List.take_length]
      simp [Nat.add_comm]

theorem back_scan_groups (fuel first : Nat) (rest : List Nat) (hfirst : first < 128)
    (hrest : ∀ byte ∈ rest, byte < 128) (hlen : rest.length + 1 ≤ fuel) :
    backScan fuel (rest.map (· + 128) ++ [first]) =
      some (number 128 (rest ++ [first]), rest.length + 1) := by
  induction rest generalizing fuel with
  | nil =>
    cases fuel with
    | zero => simp at hlen
    | succ fuel => simp [backScan, hfirst, number]
  | cons byte rest ih =>
    cases fuel with
    | zero => simp at hlen
    | succ fuel =>
      have hb : byte < 128 := hrest byte (by simp)
      have hr : ∀ b ∈ rest, b < 128 := by intro b hm; exact hrest b (by simp [hm])
      have hl : rest.length + 1 ≤ fuel := by simpa using hlen
      have hmod : (byte + 128) % 128 = byte := by omega
      simp [backScan, show ¬byte + 128 < 128 by omega, ih fuel hr hl, hmod, number]

theorem back_scan_roundtrip (length : Nat) (h : length < 2 ^ 32) :
    backScan 5 (backEncode length).reverse = some (length, backWidth length) := by
  have hb := digits_bounded 128 (backWidth length) length (by decide)
  have hw : backWidth length ≤ 5 := by
    unfold backWidth
    split <;> (try split) <;> (try split) <;> (try split) <;> decide
  have hp := back_width_positive length
  have hn : (digits 128 (backWidth length) length).reverse ≠ [] := by
    intro he
    have := congrArg List.length he
    simp only [List.length_reverse, digits_length, List.length_nil] at this
    omega
  unfold backEncode
  split
  · rename_i he
    exact False.elim (hn he)
  · rename_i first rest he
    have hbounded : ∀ b ∈ first :: rest, b < 128 := by
      intro b hm
      apply hb b
      rw [← List.mem_reverse, he]
      exact hm
    have hsize : rest.length + 1 = backWidth length := by
      have hh := congrArg List.length he
      simpa [digits_length] using hh.symm
    have htail : ∀ b ∈ rest.reverse, b < 128 := by
      intro b hm
      apply hbounded b
      simp only [List.mem_reverse] at hm
      simp [hm]
    have hscan := back_scan_groups 5 first rest.reverse (hbounded first (by simp)) htail (by simpa [hsize] using hw)
    simp only [List.reverse_cons, ← List.map_reverse] at *
    rw [hscan]
    have he' : rest.reverse ++ [first] = digits 128 (backWidth length) length := by
      rw [← List.reverse_cons, ← he, List.reverse_reverse]
    rw [he', digits_reconstruct 128 _ length (by decide) (back_width_capacity length h)]
    simp only [List.length_reverse, hsize]

theorem read_back_roundtrip (length : Nat) (h : length < 2 ^ 32) :
    readBack (backEncode length) ((backEncode length).length - 1) 0 = some (length, backWidth length) := by
  have hlength : (backEncode length).length = backWidth length := by
    unfold backEncode
    split
    · rename_i he
      have hh := congrArg List.length he
      simp only [List.length_reverse, digits_length, List.length_nil] at hh
      have hp := back_width_positive length
      omega
    · rename_i first rest he
      have hh := congrArg List.length he
      simpa [digits_length] using hh.symm
  have hp : 0 < (backEncode length).length := by rw [hlength]; exact back_width_positive length
  have hs : (backEncode length).length - 1 + 1 = (backEncode length).length := by omega
  simp [readBack, show ¬(backEncode length).length ≤ (backEncode length).length - 1 by omega,
    hs, back_scan_roundtrip length h, h]

theorem decoded_entry_bounds (data : List Nat) (offset limit finish : Nat)
    (h : decodeExtent data offset limit = some finish) :
    offset < finish ∧ finish ≤ limit ∧ limit ≤ data.length := by
  by_cases hc : limit > data.length ∨ offset ≥ limit
  · simp [decodeExtent, hc] at h
  · cases hb : decodeBody (data.take limit) offset with
    | none => simp [decodeExtent, hc, hb] at h
    | some body =>
      cases he : entryExtent offset body.bytes (backWidth body.bytes) limit with
      | none => simp [decodeExtent, hc, hb, he] at h
      | some endPos =>
        cases hr : readBack data (endPos - 1) 0 with
        | none => simp [decodeExtent, hc, hb, he, hr] at h
        | some pair =>
          by_cases hv : pair.1 = body.bytes
          · simp [decodeExtent, hc, hb, he, hr, hv] at h
            subst finish
            have hext := entry_extent_bounds offset body.bytes (backWidth body.bytes) limit endPos he
            exact ⟨hext.1, hext.2, by omega⟩
          · simp [decodeExtent, hc, hb, he, hr, hv] at h

end Encoding
