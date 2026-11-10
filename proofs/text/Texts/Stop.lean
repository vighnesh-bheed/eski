import Texts.Fold

namespace Texts

def fnv (w : List Nat) : Nat := w.foldl (fun h b => (h ^^^ b) * 16777619 % 4294967296) 2166136261

def lexLe : List Nat → List Nat → Bool
  | [], _ => true
  | _ :: _, [] => false
  | a :: as, b :: bs => if a < b then true else if a = b then lexLe as bs else false

def insertWord (w : List Nat) : List (List Nat) → List (List Nat)
  | [] => [w]
  | x :: rest => if lexLe w x then w :: x :: rest else x :: insertWord w rest

def sortWords : List (List Nat) → List (List Nat)
  | [] => []
  | w :: rest => insertWord w (sortWords rest)

def dedupAdj : List (List Nat) → List (List Nat)
  | a :: b :: rest => if a = b then dedupAdj (b :: rest) else a :: dedupAdj (b :: rest)
  | l => l

def sizeLoop : Nat → Nat → Nat → Nat
  | 0, size, _ => size
  | f + 1, size, u => if size < 2 * u then sizeLoop f (2 * size) u else size

def tableSize (u : Nat) : Nat := sizeLoop (u + 4) 8 u

def insertSlot (size v : Nat) : Nat → Nat → List Nat → List Nat
  | 0, _, slots => slots
  | f + 1, h, slots => if slots.getD h 0 = 0 then slots.set h v else insertSlot size v f ((h + 1) % size) slots

def buildSlots (words : List (List Nat)) (size : Nat) : List Nat :=
  words.zipIdx.foldl (fun slots p => insertSlot size (p.2 + 1) size (fnv p.1 % size) slots) (List.replicate size 0)

structure StopWords where
  words : List (List Nat)
  size : Nat
  slots : List Nat
  lengths : Nat
  firsts : Nat

def buildStop (input : List (List Nat)) : StopWords :=
  let words := dedupAdj (sortWords input)
  let size := tableSize words.length
  ⟨words, size, buildSlots words size, words.foldl (fun acc w => acc ||| 1 <<< min w.length 63) 0,
    words.foldl (fun acc w => if w = [] then acc else acc ||| 1 <<< w.headD 0) 0⟩

def probe (sw : StopWords) (term : List Nat) : Nat → Nat → Bool
  | 0, _ => false
  | f + 1, h =>
    if sw.slots.getD h 0 = 0 then false
    else if sw.words.getD (sw.slots.getD h 0 - 1) [] = term then true
    else probe sw term f ((h + 1) % sw.size)

def isStop (sw : StopWords) (term : List Nat) : Bool :=
  if sw.words = [] then false
  else if !(sw.lengths.testBit (min term.length 63)) then false
  else if term ≠ [] ∧ !(sw.firsts.testBit (term.headD 0)) then false
  else probe sw term sw.size (fnv term % sw.size)

def defaultStop : List (List Nat) :=
  ["a", "is", "the", "an", "and", "are", "as", "at", "be", "but", "by", "for", "if", "in", "into", "it", "no", "not",
    "of", "on", "or", "such", "that", "their", "then", "there", "these", "they", "this", "to", "was", "will", "with"].map
    fun s => s.toList.map Char.toNat

theorem mem_dedupAdj : ∀ (l : List (List Nat)) (x : List Nat), x ∈ dedupAdj l ↔ x ∈ l
  | [], x => by simp [dedupAdj]
  | [a], x => by simp [dedupAdj]
  | a :: b :: rest, x => by
    simp only [dedupAdj]
    split
    · rename_i h; subst h
      rw [mem_dedupAdj (a :: rest) x]
      simp
    · rw [List.mem_cons, mem_dedupAdj (b :: rest) x]
      simp

theorem mem_insertWord (w x : List Nat) : ∀ l : List (List Nat), x ∈ insertWord w l ↔ x = w ∨ x ∈ l
  | [] => by simp [insertWord]
  | y :: rest => by
    simp only [insertWord]
    split
    · simp
    · rw [List.mem_cons, mem_insertWord w x rest, List.mem_cons]
      constructor
      · rintro (h | h | h) <;> simp [h]
      · rintro (h | h | h) <;> simp [h]

theorem mem_sortWords (x : List Nat) : ∀ l : List (List Nat), x ∈ sortWords l ↔ x ∈ l
  | [] => by simp [sortWords]
  | w :: rest => by
    simp only [sortWords]
    rw [mem_insertWord, mem_sortWords x rest, List.mem_cons]

theorem length_insertWord (w : List Nat) : ∀ l : List (List Nat), (insertWord w l).length = l.length + 1
  | [] => by simp [insertWord]
  | y :: rest => by
    simp only [insertWord]
    split
    · simp
    · simp [length_insertWord w rest]

theorem length_sortWords : ∀ l : List (List Nat), (sortWords l).length = l.length
  | [] => by simp [sortWords]
  | w :: rest => by simp [sortWords, length_insertWord, length_sortWords rest]

theorem words_mem (input : List (List Nat)) (x : List Nat) : x ∈ (buildStop input).words ↔ x ∈ input := by
  simp only [buildStop]
  rw [mem_dedupAdj, mem_sortWords]

theorem testBit_foldl_or (ws : List (List Nat)) (g : List Nat → Option Nat) (acc : Nat) (k : Nat) :
    (ws.foldl (fun a w => match g w with | some i => a ||| 1 <<< i | none => a) acc).testBit k =
      (acc.testBit k || ws.any fun w => g w == some k) := by
  induction ws generalizing acc with
  | nil => simp
  | cons w rest ih =>
    simp only [List.foldl_cons, List.any_cons]
    rw [ih]
    cases hg : g w with
    | none => simp
    | some i =>
      simp only [Nat.testBit_or, Nat.one_shiftLeft, Nat.testBit_two_pow]
      by_cases e : i = k
      · subst e; simp
      · have e' : (some i == some k) = false := beq_eq_false_iff_ne.mpr (fun h => e (Option.some.inj h))
        rw [e', decide_eq_false e]
        simp

theorem lengths_spec (ws : List (List Nat)) (k : Nat) :
    (ws.foldl (fun acc w => acc ||| 1 <<< min w.length 63) 0).testBit k = ws.any fun w => min w.length 63 == k := by
  have := testBit_foldl_or ws (fun w => some (min w.length 63)) 0 k
  simp only at this
  rw [this]; simp

theorem firsts_spec (ws : List (List Nat)) (k : Nat) :
    (ws.foldl (fun acc w => if w = [] then acc else acc ||| 1 <<< w.headD 0) 0).testBit k =
      ws.any fun w => w ≠ [] && w.headD 0 == k := by
  have h := testBit_foldl_or ws (fun w => if w = [] then none else some (w.headD 0)) 0 k
  have e : (fun a w => match (if w = [] then none else some (w.headD 0)) with | some i => a ||| 1 <<< i | none => a) =
      (fun acc (w : List Nat) => if w = [] then acc else acc ||| 1 <<< w.headD 0) := by
    funext a w; split <;> simp_all
  rw [e] at h
  rw [h]
  simp only [Nat.zero_testBit, Bool.false_or]
  congr 1
  funext w
  by_cases hw : w = [] <;> simp [hw]

theorem filters_pass (input : List (List Nat)) (t : List Nat) (ht : t ∈ input) :
    (buildStop input).lengths.testBit (min t.length 63) = true ∧
      (t ≠ [] → (buildStop input).firsts.testBit (t.headD 0) = true) := by
  have hm := (words_mem input t).2 ht
  constructor
  · simp only [buildStop]
    rw [lengths_spec]
    exact List.any_eq_true.2 ⟨t, hm, by simp⟩
  · intro hne
    simp only [buildStop]
    rw [firsts_spec]
    exact List.any_eq_true.2 ⟨t, hm, by simp [hne]⟩

def SlotsOk (sw : StopWords) : Prop := ∀ h, sw.slots.getD h 0 ≠ 0 → sw.slots.getD h 0 - 1 < sw.words.length

theorem probe_sound (sw : StopWords) (hs : SlotsOk sw) (term : List Nat) :
    ∀ f h, probe sw term f h = true → term ∈ sw.words
  | 0, _, hp => by simp [probe] at hp
  | f + 1, h, hp => by
    simp only [probe] at hp
    split at hp
    · cases hp
    · rename_i hz
      split at hp
      · rename_i he
        rw [← he]
        have := hs h hz
        rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem this]
        exact List.getElem_mem this
      · exact probe_sound sw hs term f _ hp

theorem isStop_sound (sw : StopWords) (hs : SlotsOk sw) (term : List Nat) (h : isStop sw term = true) : term ∈ sw.words := by
  unfold isStop at h
  split at h
  · cases h
  · split at h
    · cases h
    · split at h
      · cases h
      · exact probe_sound sw hs term _ _ h

theorem getD_set_ne (l : List Nat) (i j v : Nat) (h : j ≠ i) : (l.set i v).getD j 0 = l.getD j 0 := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_set_ne (Ne.symm h)]

theorem insertSlot_ok (size v : Nat) (bound : Nat) (hv : 0 < v ∧ v - 1 < bound) :
    ∀ f h (slots : List Nat), (∀ k, slots.getD k 0 ≠ 0 → slots.getD k 0 - 1 < bound) →
      ∀ k, (insertSlot size v f h slots).getD k 0 ≠ 0 → (insertSlot size v f h slots).getD k 0 - 1 < bound
  | 0, _, slots, hs => by simpa [insertSlot] using hs
  | f + 1, h, slots, hs => by
    simp only [insertSlot]
    split
    · intro k hk
      by_cases e : k = h
      · subst e
        by_cases hl : k < slots.length
        · simp only [List.getD_eq_getElem?_getD, List.getElem?_set_self hl, Option.getD_some] at hk ⊢; omega
        · exfalso
          have hl' : (slots.set k v).length ≤ k := by simp; omega
          simp [List.getD_eq_getElem?_getD, List.getElem?_eq_none hl'] at hk
      · rw [getD_set_ne _ _ _ _ e] at hk ⊢; exact hs k hk
    · exact insertSlot_ok size v bound hv f _ slots hs

theorem buildSlots_ok (words : List (List Nat)) (size : Nat) :
    ∀ k, (buildSlots words size).getD k 0 ≠ 0 → (buildSlots words size).getD k 0 - 1 < words.length := by
  unfold buildSlots
  have : ∀ (ps : List (List Nat × Nat)) (slots : List Nat), (∀ p ∈ ps, p.2 < words.length) →
      (∀ k, slots.getD k 0 ≠ 0 → slots.getD k 0 - 1 < words.length) →
      ∀ k, (ps.foldl (fun slots p => insertSlot size (p.2 + 1) size (fnv p.1 % size) slots) slots).getD k 0 ≠ 0 →
        (ps.foldl (fun slots p => insertSlot size (p.2 + 1) size (fnv p.1 % size) slots) slots).getD k 0 - 1 < words.length := by
    intro ps
    induction ps with
    | nil => intro slots _ hs; simpa using hs
    | cons p rest ih =>
      intro slots hp hs
      simp only [List.foldl_cons]
      apply ih _ (fun q hq => hp q (by simp [hq]))
      exact insertSlot_ok size (p.2 + 1) words.length ⟨by omega, by have := hp p (by simp); omega⟩ size _ slots hs
  apply this
  · intro p hp
    have := List.mem_zipIdx hp
    omega
  · intro k hk
    exfalso
    rw [List.getD_eq_getElem?_getD, List.getElem?_replicate] at hk
    split at hk <;> simp at hk

theorem buildStop_slotsOk (input : List (List Nat)) : SlotsOk (buildStop input) := by
  intro h hz
  exact buildSlots_ok _ _ h hz

theorem isStop_sound_build (input : List (List Nat)) (term : List Nat) (h : isStop (buildStop input) term = true) :
    term ∈ input := (words_mem input term).1 (isStop_sound _ (buildStop_slotsOk input) term h)

set_option maxRecDepth 100000 in
theorem default_count : (buildStop defaultStop).words.length = 33 ∧ (buildStop defaultStop).size = 128 := by decide

set_option maxRecDepth 100000 in
theorem default_complete : defaultStop.all (isStop (buildStop defaultStop)) = true := by decide

def queryDrops (sw : StopWords) (term : List Nat) (plain noStop : Bool) : Bool := !noStop && plain && isStop sw term

theorem queryDrops_spec (sw : StopWords) (term : List Nat) (plain noStop : Bool) :
    queryDrops sw term plain noStop = true ↔ noStop = false ∧ plain = true ∧ isStop sw term = true := by
  cases noStop <;> cases plain <;> simp [queryDrops]

theorem sizeLoop_ge : ∀ (f size u : Nat), 2 * u ≤ size * 2 ^ f → 2 * u ≤ sizeLoop f size u
  | 0, size, u, h => by simpa [sizeLoop] using h
  | f + 1, size, u, h => by
    simp only [sizeLoop]
    split
    · apply sizeLoop_ge f (2 * size) u
      rw [Nat.pow_succ] at h
      have : size * (2 ^ f * 2) = 2 * size * 2 ^ f := by rw [Nat.mul_comm (2 ^ f) 2, ← Nat.mul_assoc, Nat.mul_comm size 2]
      omega
    · omega

theorem sizeLoop_pow : ∀ (f size u : Nat), (∃ e, size = 2 ^ e) → ∃ e, sizeLoop f size u = 2 ^ e
  | 0, size, u, h => by simpa [sizeLoop] using h
  | f + 1, size, u, ⟨e, he⟩ => by
    simp only [sizeLoop]
    split
    · exact sizeLoop_pow f (2 * size) u ⟨e + 1, by rw [he, Nat.pow_succ, Nat.mul_comm]⟩
    · exact ⟨e, he⟩

theorem two_pow_ge (n : Nat) : n + 1 ≤ 2 ^ n := by
  induction n with
  | zero => simp
  | succ n ih => rw [Nat.pow_succ]; omega

theorem tableSize_spec (u : Nat) : 2 * u ≤ tableSize u ∧ 8 ≤ tableSize u ∧ ∃ e, tableSize u = 2 ^ e := by
  refine ⟨sizeLoop_ge (u + 4) 8 u ?_, ?_, sizeLoop_pow (u + 4) 8 u ⟨3, rfl⟩⟩
  · have := two_pow_ge (u + 4)
    omega
  · unfold tableSize
    have : ∀ f size, 8 ≤ size → 8 ≤ sizeLoop f size u := by
      intro f
      induction f with
      | zero => intro size h; simpa [sizeLoop] using h
      | succ f ih =>
        intro size h
        simp only [sizeLoop]
        split
        · exact ih _ (by omega)
        · exact h
    exact this _ _ (Nat.le_refl 8)

end Texts
