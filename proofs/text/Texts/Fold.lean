import Texts.Classes

namespace Texts

def asciiLower (b : Nat) : Nat := if 65 ≤ b ∧ b ≤ 90 then b + 32 else b

def srcByte (text tail : List Nat) (i : Nat) : Nat :=
  if i < text.length then text.getD i 0 else tail.getD (i - text.length) 0

def decodeUnit (text tail : List Nat) (i : Nat) : Nat × Nat :=
  let b0 := srcByte text tail i
  let b1 := srcByte text tail (i + 1)
  let b2 := srcByte text tail (i + 2)
  let b3 := srcByte text tail (i + 3)
  if b0 < 128 then (b0, i + 1)
  else if b0 < 224 then (b0 % 32 * 64 + b1 % 64, i + 2)
  else if b0 < 240 then (b0 % 16 * 4096 + b1 % 64 * 64 + b2 % 64, i + 3)
  else (b0 % 8 * 262144 + b1 % 64 * 4096 + b2 % 64 * 64 + b3 % 64, i + 4)

def encodeUnit (cp : Nat) : List Nat :=
  if cp < 128 then [cp]
  else if cp < 2048 then [192 + cp / 64, 128 + cp % 64]
  else if cp < 65536 then [224 + cp / 4096, 128 + cp / 64 % 64, 128 + cp % 64]
  else [240 + cp / 262144 % 8, 128 + cp / 4096 % 64, 128 + cp / 64 % 64, 128 + cp % 64]

def lowerOf (low : Nat → List Nat) (cp : Nat) : List Nat := if cp < 128 then [asciiLower cp] else low cp

def foldUnits (low : Nat → List Nat) (text tail : List Nat) : Nat → Nat → List Nat
  | 0, _ => []
  | f + 1, i =>
    if text.length ≤ i then []
    else
      let r := decodeUnit text tail i
      if r.1 = 0 then [] else (lowerOf low r.1).flatMap encodeUnit ++ foldUnits low text tail f r.2

def asciiRun (text : List Nat) : Nat := (text.takeWhile fun b => decide (b < 128 ∧ b ≠ 0)).length

def fold (low : Nat → List Nat) (text tail : List Nat) : List Nat :=
  if asciiRun text = text.length then text.map asciiLower
  else if text.getD (asciiRun text) 0 = 0 then (text.take (asciiRun text)).map asciiLower
  else (text.take (asciiRun text)).map asciiLower ++ foldUnits low text tail (text.length + 1) (asciiRun text)

def trieUnits (term : List Nat) : Nat → Nat → Bool → Nat × List Nat
  | 0, _, _ => (0, [])
  | f + 1, i, stopped =>
    if term.length ≤ i then (0, [])
    else
      let r := decodeUnit term [] i
      let u := r.1 % 65536
      if stopped then let rest := trieUnits term f r.2 true; (rest.1 + 1, rest.2)
      else if u = 0 then let rest := trieUnits term f r.2 true; (rest.1 + 1, rest.2)
      else let rest := trieUnits term f r.2 false; (rest.1 + 1, encodeUnit u ++ rest.2)

def trieForm (term : List Nat) : List Nat × Bool :=
  let r := trieUnits term (term.length + 1) 0 false
  (r.2, decide (r.1 ≤ 255))

theorem encodeUnit_bytes (cp : Nat) (h : cp < 2097152) : ∀ b ∈ encodeUnit cp, b < 256 := by
  unfold encodeUnit
  split
  · simp; omega
  · split
    · simp; omega
    · split
      · simp; omega
      · simp; omega

theorem encodeUnit_head (cp : Nat) (h : 128 ≤ cp) (hc : cp < 2097152) : ∃ b rest, encodeUnit cp = b :: rest ∧ 192 ≤ b := by
  unfold encodeUnit
  simp only [show ¬ cp < 128 from by omega, ↓reduceIte]
  split
  · exact ⟨_, _, rfl, by omega⟩
  · split
    · exact ⟨_, _, rfl, by omega⟩
    · exact ⟨_, _, rfl, by omega⟩

theorem srcByte_at (pre mid post tail : List Nat) (j : Nat) (hj : j < mid.length) :
    srcByte (pre ++ mid ++ post) tail (pre.length + j) = mid.getD j 0 := by
  unfold srcByte
  rw [ite_eq_left (by simp; omega)]
  simp only [List.getD_eq_getElem?_getD, List.append_assoc]
  rw [List.getElem?_append_right (by omega), Nat.add_sub_cancel_left, List.getElem?_append_left hj]

theorem decode_at (pre post tail : List Nat) (bs : List Nat) (k : Nat) (hk : k < bs.length) :
    srcByte (pre ++ bs ++ post) tail (pre.length + k) = bs.getD k 0 := srcByte_at pre bs post tail k hk

theorem decode_encode_unit (pre post tail : List Nat) (cp : Nat) (h : cp < 2097152) :
    decodeUnit (pre ++ encodeUnit cp ++ post) tail pre.length = (cp, pre.length + (encodeUnit cp).length) := by
  by_cases c1 : cp < 128
  · have e : encodeUnit cp = [cp] := by simp [encodeUnit, c1]
    rw [e]
    have d0 : srcByte (pre ++ [cp] ++ post) tail pre.length = cp := by
      have h' := decode_at pre post tail [cp] 0 (by simp); simpa using h'
    simp only [decodeUnit, d0, c1, ↓reduceIte, List.length_cons, List.length_nil]
  · by_cases c2 : cp < 2048
    · have e : encodeUnit cp = [192 + cp / 64, 128 + cp % 64] := by simp [encodeUnit, c1, c2]
      rw [e]
      have d0 : srcByte (pre ++ [192 + cp / 64, 128 + cp % 64] ++ post) tail pre.length = 192 + cp / 64 := by
        have h' := decode_at pre post tail [192 + cp / 64, 128 + cp % 64] 0 (by simp); simpa using h'
      have d1 : srcByte (pre ++ [192 + cp / 64, 128 + cp % 64] ++ post) tail (pre.length + 1) = 128 + cp % 64 := by
        have h' := decode_at pre post tail [192 + cp / 64, 128 + cp % 64] 1 (by simp); simpa using h'
      simp only [decodeUnit, d0, d1, List.length_cons, List.length_nil]
      rw [ite_eq_right (by omega), ite_eq_left (by omega)]
      simp only [Prod.mk.injEq]
      clear d0 d1
      simp only [and_true]; clear e
      omega
    · by_cases c3 : cp < 65536
      · have e : encodeUnit cp = [224 + cp / 4096, 128 + cp / 64 % 64, 128 + cp % 64] := by simp [encodeUnit, c1, c2, c3]
        rw [e]
        have d0 : srcByte (pre ++ [224 + cp / 4096, 128 + cp / 64 % 64, 128 + cp % 64] ++ post) tail pre.length = 224 + cp / 4096 := by
          have h' := decode_at pre post tail [224 + cp / 4096, 128 + cp / 64 % 64, 128 + cp % 64] 0 (by simp); simpa using h'
        have d1 : srcByte (pre ++ [224 + cp / 4096, 128 + cp / 64 % 64, 128 + cp % 64] ++ post) tail (pre.length + 1) =
            128 + cp / 64 % 64 := by
          have h' := decode_at pre post tail [224 + cp / 4096, 128 + cp / 64 % 64, 128 + cp % 64] 1 (by simp); simpa using h'
        have d2 : srcByte (pre ++ [224 + cp / 4096, 128 + cp / 64 % 64, 128 + cp % 64] ++ post) tail (pre.length + 2) =
            128 + cp % 64 := by
          have h' := decode_at pre post tail [224 + cp / 4096, 128 + cp / 64 % 64, 128 + cp % 64] 2 (by simp); simpa using h'
        simp only [decodeUnit, d0, d1, d2, List.length_cons, List.length_nil]
        rw [ite_eq_right (by omega), ite_eq_right (by omega), ite_eq_left (by omega)]
        simp only [Prod.mk.injEq]
        clear d0 d1 d2
        simp only [and_true]; clear e
        omega
      · have e : encodeUnit cp = [240 + cp / 262144 % 8, 128 + cp / 4096 % 64, 128 + cp / 64 % 64, 128 + cp % 64] := by
          simp [encodeUnit, c1, c2, c3]
        rw [e]
        have d0 : srcByte (pre ++ [240 + cp / 262144 % 8, 128 + cp / 4096 % 64, 128 + cp / 64 % 64, 128 + cp % 64] ++ post) tail
            pre.length = 240 + cp / 262144 % 8 := by
          have h' := decode_at pre post tail [240 + cp / 262144 % 8, 128 + cp / 4096 % 64, 128 + cp / 64 % 64, 128 + cp % 64] 0
            (by simp); simpa using h'
        have d1 : srcByte (pre ++ [240 + cp / 262144 % 8, 128 + cp / 4096 % 64, 128 + cp / 64 % 64, 128 + cp % 64] ++ post) tail
            (pre.length + 1) = 128 + cp / 4096 % 64 := by
          have h' := decode_at pre post tail [240 + cp / 262144 % 8, 128 + cp / 4096 % 64, 128 + cp / 64 % 64, 128 + cp % 64] 1
            (by simp); simpa using h'
        have d2 : srcByte (pre ++ [240 + cp / 262144 % 8, 128 + cp / 4096 % 64, 128 + cp / 64 % 64, 128 + cp % 64] ++ post) tail
            (pre.length + 2) = 128 + cp / 64 % 64 := by
          have h' := decode_at pre post tail [240 + cp / 262144 % 8, 128 + cp / 4096 % 64, 128 + cp / 64 % 64, 128 + cp % 64] 2
            (by simp); simpa using h'
        have d3 : srcByte (pre ++ [240 + cp / 262144 % 8, 128 + cp / 4096 % 64, 128 + cp / 64 % 64, 128 + cp % 64] ++ post) tail
            (pre.length + 3) = 128 + cp % 64 := by
          have h' := decode_at pre post tail [240 + cp / 262144 % 8, 128 + cp / 4096 % 64, 128 + cp / 64 % 64, 128 + cp % 64] 3
            (by simp); simpa using h'
        simp only [decodeUnit, d0, d1, d2, d3, List.length_cons, List.length_nil]
        rw [ite_eq_right (by omega), ite_eq_right (by omega), ite_eq_right (by omega)]
        simp only [Prod.mk.injEq]
        clear d0 d1 d2 d3
        simp only [and_true]; clear e
        omega

theorem takeWhile_all {p : Nat → Bool} : ∀ {l : List Nat}, (∀ b ∈ l, p b = true) → l.takeWhile p = l
  | [], _ => rfl
  | b :: bs, h => by rw [List.takeWhile_cons_of_pos (h b (by simp)), takeWhile_all (fun x hx => h x (by simp [hx]))]

theorem asciiRun_le (text : List Nat) : asciiRun text ≤ text.length := by
  unfold asciiRun; exact (List.takeWhile_prefix _).length_le

theorem fold_ascii (low : Nat → List Nat) (text tail : List Nat) (h : ∀ b ∈ text, 0 < b ∧ b < 128) :
    fold low text tail = text.map asciiLower := by
  have : asciiRun text = text.length := by
    unfold asciiRun
    rw [takeWhile_all (fun b hb => by have := h b hb; simp; omega)]
  unfold fold
  rw [ite_eq_left this]

theorem fold_nul (low : Nat → List Nat) (pre post tail : List Nat) (h : ∀ b ∈ pre, 0 < b ∧ b < 128) :
    fold low (pre ++ 0 :: post) tail = pre.map asciiLower := by
  have hrun : asciiRun (pre ++ 0 :: post) = pre.length := by
    unfold asciiRun
    rw [List.takeWhile_append_of_pos (fun b hb => by have := h b hb; simp; omega)]
    simp
  unfold fold
  rw [hrun, ite_eq_right (by simp), ite_eq_left (by simp [List.getD_eq_getElem?_getD, List.getElem?_append_right])]
  simp

def lowerSeq (low : Nat → List Nat) (cps : List Nat) : List Nat := (cps.flatMap (lowerOf low)).flatMap encodeUnit

theorem foldUnits_encoded (low : Nat → List Nat) (pre tail : List Nat) :
    ∀ (cps : List Nat) (f : Nat), (∀ c ∈ cps, 0 < c ∧ c < 2097152) → (cps.flatMap encodeUnit).length < f →
      foldUnits low (pre ++ cps.flatMap encodeUnit) tail f pre.length = lowerSeq low cps
  | [], f, _, _ => by
    cases f with
    | zero => rfl
    | succ f => simp [foldUnits, lowerSeq]
  | c :: cs, f, hc, hf => by
    have hc0 := hc c (by simp)
    cases f with
    | zero => omega
    | succ f =>
      have hlen : 0 < (encodeUnit c).length := by unfold encodeUnit; split <;> (try split) <;> (try split) <;> simp
      unfold foldUnits
      have hl : ¬ (pre ++ (c :: cs).flatMap encodeUnit).length ≤ pre.length := by simp; omega
      rw [ite_eq_right hl]
      have hd := decode_encode_unit pre (cs.flatMap encodeUnit) tail c hc0.2
      simp only [List.flatMap_cons, ← List.append_assoc] at hd ⊢
      rw [hd]
      simp only [show ¬ c = 0 from by omega, ↓reduceIte]
      have ih := foldUnits_encoded low (pre ++ encodeUnit c) tail cs f (fun x hx => hc x (by simp [hx]))
        (by rw [List.flatMap_cons, List.length_append] at hf; omega)
      simp only [List.length_append] at ih
      rw [List.append_assoc] at ih ⊢
      rw [ih]
      simp [lowerSeq, List.flatMap_append]

theorem fold_encoded (low : Nat → List Nat) (asc rest tail : List Nat) (ha : ∀ b ∈ asc, 0 < b ∧ b < 128)
    (hr : ∀ c ∈ rest, 0 < c ∧ c < 2097152) (hfirst : ∀ c ∈ rest.head?, 128 ≤ c) :
    fold low (asc ++ rest.flatMap encodeUnit) tail = asc.map asciiLower ++ lowerSeq low rest := by
  cases rest with
  | nil => simp [lowerSeq]; exact fold_ascii low asc tail ha
  | cons c cs =>
    have hc := hr c (by simp)
    have hc1 := hfirst c (by simp)
    obtain ⟨b, brest, hb, hb192⟩ := encodeUnit_head c hc1 hc.2
    have hrun : asciiRun (asc ++ (c :: cs).flatMap encodeUnit) = asc.length := by
      unfold asciiRun
      rw [List.takeWhile_append_of_pos (fun x hx => by have := ha x hx; simp; omega)]
      simp only [List.flatMap_cons, hb, List.cons_append, List.takeWhile_cons]
      simp [show ¬ b < 128 from by omega]
    unfold fold
    rw [hrun]
    have hne : asc.length ≠ (asc ++ (c :: cs).flatMap encodeUnit).length := by simp [hb]
    rw [ite_eq_right hne]
    have hb0 : (asc ++ (c :: cs).flatMap encodeUnit).getD asc.length 0 ≠ 0 := by
      simp [List.getD_eq_getElem?_getD, List.getElem?_append_right, hb]; omega
    rw [ite_eq_right hb0]
    have hu := foldUnits_encoded low asc tail (c :: cs) ((asc ++ (c :: cs).flatMap encodeUnit).length + 1) hr (by simp; omega)
    rw [hu]
    congr 1
    simp [List.take_append_of_le_length]

theorem lowerSeq_ascii (low : Nat → List Nat) (cps : List Nat) (h : ∀ c ∈ cps, c < 128) :
    lowerSeq low cps = cps.map asciiLower := by
  induction cps with
  | nil => rfl
  | cons c cs ih =>
    have hc := h c (by simp)
    simp only [lowerSeq, List.flatMap_cons, lowerOf, hc, ↓reduceIte, List.cons_append, List.nil_append, List.map_cons] at ih ⊢
    rw [ih (fun x hx => h x (by simp [hx]))]
    have : asciiLower c < 128 := by unfold asciiLower; split <;> omega
    simp [encodeUnit, this]

set_option maxRecDepth 100000 in
theorem trie_truncates_emoji : trieForm (encodeUnit 0x1F600) = (encodeUnit 0xF600, true) := by decide

set_option maxRecDepth 100000 in
theorem trie_limit : (trieForm (List.replicate 256 97)).2 = false ∧ (trieForm (List.replicate 255 97)).2 = true := by decide

end Texts
