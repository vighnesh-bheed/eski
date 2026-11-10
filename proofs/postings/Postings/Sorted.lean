namespace Postings

def Sorted (a : List Nat) : Prop := List.Pairwise (· ≤ ·) a

def Strict (a : List Nat) : Prop := List.Pairwise (· < ·) a

def lbLoop (a : List Nat) (t lo hi : Nat) : Nat :=
  if lo < hi then
    if a.getD ((lo + hi) / 2) 0 < t then lbLoop a t ((lo + hi) / 2 + 1) hi else lbLoop a t lo ((lo + hi) / 2)
  else lo
termination_by hi - lo

def lowerBound (a : List Nat) (t : Nat) : Nat := lbLoop a t 0 a.length

def ubLoop (a : List Nat) (t lo hi : Nat) : Nat :=
  if lo < hi then
    if a.getD ((lo + hi) / 2) 0 ≤ t then ubLoop a t ((lo + hi) / 2 + 1) hi else ubLoop a t lo ((lo + hi) / 2)
  else lo
termination_by hi - lo

def upperBound (a : List Nat) (t : Nat) : Nat := ubLoop a t 0 a.length

def gallopGrow (a : List Nat) (t lo s hi : Nat) : Nat × Nat :=
  if hi < a.length ∧ a.getD hi 0 < t then gallopGrow a t hi (s + 1) (hi + 2 ^ (s + 1)) else (lo, hi)
termination_by a.length - hi
decreasing_by have := Nat.two_pow_pos (s + 1); omega

def gallop (a : List Nat) (start t : Nat) : Nat :=
  if a.length ≤ start ∨ t ≤ a.getD start 0 then start
  else
    let r := gallopGrow a t start 0 (start + 1)
    lbLoop a t (r.1 + 1) (min r.2 a.length)

def intersectRef : List Nat → List Nat → List Nat
  | [], _ => []
  | _ :: _, [] => []
  | x :: xs, y :: ys =>
    if x < y then intersectRef xs (y :: ys)
    else if y < x then intersectRef (x :: xs) ys
    else x :: intersectRef xs ys
termination_by a b => a.length + b.length

def intersectMerge : List Nat → List Nat → List Nat
  | [], _ => []
  | _ :: _, [] => []
  | x :: xs, y :: ys =>
    (if x = y then [x] else []) ++ intersectMerge (if x ≤ y then xs else x :: xs) (if y ≤ x then ys else y :: ys)
termination_by a b => a.length + b.length
decreasing_by all_goals (split <;> split <;> simp <;> omega)

def intersectCount : List Nat → List Nat → Nat
  | [], _ => 0
  | _ :: _, [] => 0
  | x :: xs, y :: ys =>
    (if x = y then 1 else 0) + intersectCount (if x ≤ y then xs else x :: xs) (if y ≤ x then ys else y :: ys)
termination_by a b => a.length + b.length
decreasing_by all_goals (split <;> split <;> simp <;> omega)

def intersectGallopAux (large : List Nat) : List Nat → Nat → List Nat
  | [], _ => []
  | x :: xs, j =>
    if large.length ≤ gallop large j x then []
    else if large.getD (gallop large j x) 0 = x then x :: intersectGallopAux large xs (gallop large j x + 1)
    else intersectGallopAux large xs (gallop large j x)

def intersectGallop (small large : List Nat) : List Nat := intersectGallopAux large small 0

def gallopRatio : Nat := 32

def intersect (a b : List Nat) : List Nat :=
  if a.length = 0 ∨ b.length = 0 then []
  else if a.length * gallopRatio < b.length then intersectGallop a b
  else if b.length * gallopRatio < a.length then intersectGallop b a
  else intersectMerge a b

def unionMerge : List Nat → List Nat → List Nat
  | [], ys => ys
  | x :: xs, [] => x :: xs
  | x :: xs, y :: ys =>
    if x < y then x :: unionMerge xs (y :: ys)
    else if y < x then y :: unionMerge (x :: xs) ys
    else x :: unionMerge xs ys
termination_by a b => a.length + b.length

def differenceMerge : List Nat → List Nat → List Nat
  | [], _ => []
  | x :: xs, ys =>
    match ys.dropWhile (· < x) with
    | y :: rest => if y = x then differenceMerge xs rest else x :: differenceMerge xs (y :: rest)
    | [] => x :: differenceMerge xs []

def isStrict : List Nat → Bool
  | x :: y :: rest => decide (x < y) && isStrict (y :: rest)
  | _ => true

theorem strict_sorted {a : List Nat} (h : Strict a) : Sorted a := List.Pairwise.imp (fun h => Nat.le_of_lt h) h

theorem sorted_getD {a : List Nat} (h : Sorted a) {i j : Nat} (hij : i ≤ j) (hj : j < a.length) :
    a.getD i 0 ≤ a.getD j 0 := by
  rcases Nat.lt_or_eq_of_le hij with hlt | heq
  · have := (List.pairwise_iff_getElem.1 h) i j (by omega) hj hlt
    rw [List.getD_eq_getElem?_getD, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem (by omega),
      List.getElem?_eq_getElem hj]
    exact this
  · rw [heq]; exact Nat.le_refl _

def LowerOf (a : List Nat) (t r : Nat) : Prop :=
  r ≤ a.length ∧ (∀ i, i < r → a.getD i 0 < t) ∧ (∀ i, r ≤ i → i < a.length → t ≤ a.getD i 0)

theorem lowerOf_unique {a : List Nat} {t r s : Nat} (hr : LowerOf a t r) (hs : LowerOf a t s) : r = s := by
  rcases Nat.lt_trichotomy r s with h | h | h
  · have := hs.2.1 r h; have := hr.2.2 r (Nat.le_refl _) (by have := hs.1; omega); omega
  · exact h
  · have := hr.2.1 s h; have := hs.2.2 s (Nat.le_refl _) (by have := hr.1; omega); omega

theorem lbLoop_spec {a : List Nat} (hs : Sorted a) (t : Nat) :
    ∀ lo hi, lo ≤ hi → hi ≤ a.length → (∀ i, i < lo → a.getD i 0 < t) →
      (∀ i, hi ≤ i → i < a.length → t ≤ a.getD i 0) → LowerOf a t (lbLoop a t lo hi) := by
  intro lo hi
  induction lo, hi using lbLoop.induct a t with
  | case1 lo hi hlt hmid ih =>
    intro hle hhi hlo hup
    rw [lbLoop, ite_eq_left hlt, ite_eq_left hmid]
    apply ih (by omega) hhi _ hup
    intro i hi'
    rcases Nat.lt_or_ge i ((lo + hi) / 2) with h | h
    · exact Nat.lt_of_le_of_lt (sorted_getD hs (Nat.le_of_lt h) (by omega)) hmid
    · have : i = (lo + hi) / 2 := by omega
      rw [this]; exact hmid
  | case2 lo hi hlt hmid ih =>
    intro hle hhi hlo hup
    rw [lbLoop, ite_eq_left hlt, ite_eq_right hmid]
    apply ih (by omega) (by omega) hlo
    intro i hi hn
    exact Nat.le_trans (Nat.le_of_not_lt hmid) (sorted_getD hs hi hn)
  | case3 lo hi hlt =>
    intro hle hhi hlo hup
    rw [lbLoop, ite_eq_right hlt]
    have : lo = hi := by omega
    subst this
    exact ⟨hhi, hlo, hup⟩

theorem lowerBound_spec {a : List Nat} (hs : Sorted a) (t : Nat) : LowerOf a t (lowerBound a t) :=
  lbLoop_spec hs t 0 a.length (Nat.zero_le _) (Nat.le_refl _) (fun i hi => absurd hi (Nat.not_lt_zero _))
    (fun i h1 h2 => absurd h2 (by omega))

def UpperOf (a : List Nat) (t r : Nat) : Prop :=
  r ≤ a.length ∧ (∀ i, i < r → a.getD i 0 ≤ t) ∧ (∀ i, r ≤ i → i < a.length → t < a.getD i 0)

theorem ubLoop_spec {a : List Nat} (hs : Sorted a) (t : Nat) :
    ∀ lo hi, lo ≤ hi → hi ≤ a.length → (∀ i, i < lo → a.getD i 0 ≤ t) →
      (∀ i, hi ≤ i → i < a.length → t < a.getD i 0) → UpperOf a t (ubLoop a t lo hi) := by
  intro lo hi
  induction lo, hi using ubLoop.induct a t with
  | case1 lo hi hlt hmid ih =>
    intro hle hhi hlo hup
    rw [ubLoop, ite_eq_left hlt, ite_eq_left hmid]
    apply ih (by omega) hhi _ hup
    intro i hi'
    rcases Nat.lt_or_ge i ((lo + hi) / 2) with h | h
    · exact Nat.le_trans (sorted_getD hs (Nat.le_of_lt h) (by omega)) hmid
    · have : i = (lo + hi) / 2 := by omega
      rw [this]; exact hmid
  | case2 lo hi hlt hmid ih =>
    intro hle hhi hlo hup
    rw [ubLoop, ite_eq_left hlt, ite_eq_right hmid]
    apply ih (by omega) (by omega) hlo
    intro i hi hn
    exact Nat.lt_of_lt_of_le (Nat.lt_of_not_le hmid) (sorted_getD hs hi hn)
  | case3 lo hi hlt =>
    intro hle hhi hlo hup
    rw [ubLoop, ite_eq_right hlt]
    have : lo = hi := by omega
    subst this
    exact ⟨hhi, hlo, hup⟩

theorem upperBound_spec {a : List Nat} (hs : Sorted a) (t : Nat) : UpperOf a t (upperBound a t) :=
  ubLoop_spec hs t 0 a.length (Nat.zero_le _) (Nat.le_refl _) (fun i hi => absurd hi (Nat.not_lt_zero _))
    (fun i h1 h2 => absurd h2 (by omega))

theorem gallopGrow_spec {a : List Nat} (hs : Sorted a) (t : Nat) :
    ∀ lo s hi, lo < hi → lo < a.length → a.getD lo 0 < t →
      let r := gallopGrow a t lo s hi
      r.1 < r.2 ∧ r.1 < a.length ∧ a.getD r.1 0 < t ∧ (r.2 < a.length → t ≤ a.getD r.2 0) := by
  intro lo s hi
  induction lo, s, hi using gallopGrow.induct a t with
  | case1 lo s hi hc ih =>
    intro hlh hlo hv
    rw [gallopGrow, ite_eq_left hc]
    exact ih (by have := Nat.two_pow_pos (s + 1); omega) hc.1 hc.2
  | case2 lo s hi hc =>
    intro hlh hlo hv
    rw [gallopGrow, ite_eq_right hc]
    refine ⟨hlh, hlo, hv, fun h => ?_⟩
    exact Nat.le_of_not_lt (fun h' => hc ⟨h, h'⟩)

theorem gallop_eq {a : List Nat} (hs : Sorted a) (start t : Nat) : gallop a start t = max start (lowerBound a t) := by
  have hlb := lowerBound_spec hs t
  unfold gallop
  split
  · rename_i h
    rcases h with h | h
    · have := hlb.1; omega
    · have : lowerBound a t ≤ start := by
        rcases Nat.lt_or_ge start (lowerBound a t) with hl | hl
        · have := hlb.2.1 start hl; omega
        · exact hl
      omega
  · rename_i h
    have hn : start < a.length := by omega
    have hv : a.getD start 0 < t := by omega
    have hg := gallopGrow_spec hs t start 0 (start + 1) (by omega) hn hv
    simp only at hg
    obtain ⟨g1, g2, g3, g4⟩ := hg
    have hr := lbLoop_spec hs t ((gallopGrow a t start 0 (start + 1)).1 + 1) (min (gallopGrow a t start 0 (start + 1)).2 a.length)
      (by omega) (Nat.min_le_right _ _)
      (fun i hi => by
        rcases Nat.lt_or_ge i (gallopGrow a t start 0 (start + 1)).1 with h1 | h1
        · exact Nat.lt_of_le_of_lt (sorted_getD hs (Nat.le_of_lt h1) g2) g3
        · have : i = (gallopGrow a t start 0 (start + 1)).1 := by omega
          rw [this]; exact g3)
      (fun i hi hn' => by
        have hlt : (gallopGrow a t start 0 (start + 1)).2 < a.length := by omega
        exact Nat.le_trans (g4 hlt) (sorted_getD hs (by omega) hn'))
    have heq := lowerOf_unique hr hlb
    have : start < lowerBound a t := by
      rcases Nat.lt_or_ge start (lowerBound a t) with h1 | h1
      · exact h1
      · have := hlb.2.2 start h1 hn; omega
    simp only
    rw [heq]; omega

theorem strict_cons {x : Nat} {xs : List Nat} (h : Strict (x :: xs)) : Strict xs := List.Pairwise.of_cons h

theorem strict_head {x : Nat} {xs : List Nat} (h : Strict (x :: xs)) : ∀ y ∈ xs, x < y := (List.pairwise_cons.1 h).1

theorem not_mem_of_lt {x : Nat} {ys : List Nat} (h : ∀ y ∈ ys, x < y) : x ∉ ys := fun hm => Nat.lt_irrefl _ (h x hm)

theorem intersectRef_spec : ∀ a b : List Nat, Strict a → Strict b → intersectRef a b = a.filter (fun x => decide (x ∈ b))
  | [], _, _, _ => by simp [intersectRef]
  | x :: xs, [], _, _ => by simp [intersectRef]
  | x :: xs, y :: ys, ha, hb => by
    have hxs := strict_cons ha
    have hys := strict_cons hb
    rw [intersectRef]
    split
    · rename_i hxy
      rw [intersectRef_spec xs (y :: ys) hxs hb]
      have : x ∉ y :: ys := by
        intro hm
        rcases List.mem_cons.1 hm with h | h
        · omega
        · have := strict_head hb x h; omega
      have h' : decide (x ∈ y :: ys) = false := by simp only [decide_eq_false_iff_not]; exact this
      rw [List.filter_cons, h']
      simp
    · split
      · rename_i hxy hyx
        rw [intersectRef_spec (x :: xs) ys ha hys]
        apply List.filter_congr
        intro z hz
        have hne : z ≠ y := by
          intro hzy
          rcases List.mem_cons.1 hz with h | h
          · omega
          · have := strict_head ha z h; omega
        simp [hne]
      · rename_i hxy hyx
        have hxy' : x = y := by omega
        subst hxy'
        rw [intersectRef_spec xs ys hxs hys]
        simp only [List.filter_cons, List.mem_cons, true_or, decide_true, ↓reduceIte]
        congr 1
        apply List.filter_congr
        intro z hz
        have : z ≠ x := fun h => by have := strict_head ha z hz; omega
        simp [this]
termination_by a b => a.length + b.length

theorem intersectMerge_ref : ∀ a b : List Nat, intersectMerge a b = intersectRef a b
  | [], _ => by simp [intersectMerge, intersectRef]
  | x :: xs, [] => by simp [intersectMerge, intersectRef]
  | x :: xs, y :: ys => by
    rw [intersectMerge, intersectRef]
    by_cases h1 : x < y
    · have : ¬ x = y := by omega
      have : x ≤ y := by omega
      have : ¬ y ≤ x := by omega
      simp only [*, ↓reduceIte, List.nil_append]
      exact intersectMerge_ref xs (y :: ys)
    · by_cases h2 : y < x
      · have : ¬ x = y := by omega
        have : ¬ x ≤ y := by omega
        have : y ≤ x := by omega
        simp only [*, ↓reduceIte, List.nil_append]
        exact intersectMerge_ref (x :: xs) ys
      · have e : x = y := by omega
        subst e
        simp only [h1, ↓reduceIte, Nat.le_refl, List.cons_append, List.nil_append]
        rw [intersectMerge_ref xs ys]
termination_by a b => a.length + b.length

theorem intersectCount_eq : ∀ a b : List Nat, intersectCount a b = (intersectMerge a b).length
  | [], _ => by simp [intersectCount, intersectMerge]
  | x :: xs, [] => by simp [intersectCount, intersectMerge]
  | x :: xs, y :: ys => by
    rw [intersectCount, intersectMerge, List.length_append, intersectCount_eq]
    split <;> simp
termination_by a b => a.length + b.length
decreasing_by all_goals (split <;> split <;> simp <;> omega)

theorem intersectMerge_spec (a b : List Nat) (ha : Strict a) (hb : Strict b) :
    intersectMerge a b = a.filter (fun x => decide (x ∈ b)) := by
  rw [intersectMerge_ref, intersectRef_spec a b ha hb]

theorem getD_mem {l : List Nat} {i : Nat} (h : i < l.length) : l.getD i 0 ∈ l := by
  rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h]
  exact List.getElem_mem h

theorem mem_index {l : List Nat} {x : Nat} (h : x ∈ l) : ∃ i, i < l.length ∧ l.getD i 0 = x := by
  obtain ⟨i, hi, he⟩ := List.getElem_of_mem h
  exact ⟨i, hi, by rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hi]; exact he⟩

theorem intersectGallopAux_spec (large : List Nat) (hl : Strict large) :
    ∀ (xs : List Nat) (j : Nat), Strict xs → (∀ i, i < j → ∀ x ∈ xs, large.getD i 0 < x) → j ≤ large.length →
      intersectGallopAux large xs j = xs.filter (fun x => decide (x ∈ large))
  | [], _, _, _, _ => by simp [intersectGallopAux]
  | x :: xs, j, hxs, hj, hjl => by
    have hs := strict_sorted hl
    have hlb := lowerBound_spec hs x
    have hjle : j ≤ lowerBound large x := by
      rcases Nat.lt_or_ge (lowerBound large x) j with h | h
      · have h1 := hj (lowerBound large x) h x (by simp)
        have h2 := hlb.2.2 (lowerBound large x) (Nat.le_refl _) (by omega)
        omega
      · exact h
    have hg : gallop large j x = lowerBound large x := by rw [gallop_eq hs]; omega
    rw [intersectGallopAux, hg]
    have hrest := strict_cons hxs
    have hhead := strict_head hxs
    split
    · rename_i hge
      symm
      rw [List.filter_eq_nil_iff]
      intro z hz hzm
      simp only [decide_eq_true_eq] at hzm
      obtain ⟨i, hi, he⟩ := mem_index hzm
      have hzx : x ≤ z := by
        rcases List.mem_cons.1 hz with h | h
        · omega
        · exact Nat.le_of_lt (hhead z h)
      have := hlb.2.1 i (by omega)
      omega
    · rename_i hlt
      split
      · rename_i heq
        rw [intersectGallopAux_spec large hl xs (lowerBound large x + 1) hrest
          (fun i hi z hz => by
            have hz' := hhead z hz
            rcases Nat.lt_or_ge i (lowerBound large x) with h | h
            · have := hlb.2.1 i h; omega
            · have : i = lowerBound large x := by omega
              rw [this, heq]; exact hz')
          (by omega)]
        have hmem : x ∈ large := by rw [← heq]; exact getD_mem (by omega)
        simp [List.filter_cons, hmem]
      · rename_i hne
        rw [intersectGallopAux_spec large hl xs (lowerBound large x) hrest
          (fun i hi z hz => by have := hlb.2.1 i hi; have := hhead z hz; omega) (by omega)]
        have hnot : x ∉ large := by
          intro hm
          obtain ⟨i, hi, he⟩ := mem_index hm
          rcases Nat.lt_trichotomy i (lowerBound large x) with h | h | h
          · have := hlb.2.1 i h; omega
          · exact hne (by rw [← h]; exact he)
          · have h1 := (List.pairwise_iff_getElem.1 hl) (lowerBound large x) i (by omega) hi h
            have h2 := hlb.2.2 (lowerBound large x) (Nat.le_refl _) (by omega)
            rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hi] at he
            rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem (by omega)] at h2
            simp at he h2
            omega
        simp [List.filter_cons, hnot]

theorem intersectGallop_spec (small large : List Nat) (hs : Strict small) (hl : Strict large) :
    intersectGallop small large = small.filter (fun x => decide (x ∈ large)) :=
  intersectGallopAux_spec large hl small 0 hs (fun i hi => absurd hi (Nat.not_lt_zero _)) (Nat.zero_le _)

theorem strict_ext : ∀ (l1 l2 : List Nat), Strict l1 → Strict l2 → (∀ x, x ∈ l1 ↔ x ∈ l2) → l1 = l2
  | [], [], _, _, _ => rfl
  | [], y :: ys, _, _, h => absurd ((h y).2 (by simp)) (by simp)
  | x :: xs, [], _, _, h => absurd ((h x).1 (by simp)) (by simp)
  | x :: xs, y :: ys, h1, h2, h => by
    have hx := (h x).1 (by simp)
    have hy := (h y).2 (by simp)
    have hxy : x = y := by
      rcases List.mem_cons.1 hx with e | e
      · exact e
      · rcases List.mem_cons.1 hy with e' | e'
        · exact e'.symm
        · have := strict_head h2 x e; have := strict_head h1 y e'; omega
    subst hxy
    rw [strict_ext xs ys (strict_cons h1) (strict_cons h2) (fun z => by
      constructor
      · intro hz
        have hz1 := strict_head h1 z hz
        rcases List.mem_cons.1 ((h z).1 (by simp [hz])) with e | e
        · omega
        · exact e
      · intro hz
        have hz1 := strict_head h2 z hz
        rcases List.mem_cons.1 ((h z).2 (by simp [hz])) with e | e
        · omega
        · exact e)]

theorem strict_filter {a : List Nat} (h : Strict a) (p : Nat → Bool) : Strict (a.filter p) := List.Pairwise.filter p h

theorem filter_comm_strict (a b : List Nat) (ha : Strict a) (hb : Strict b) :
    b.filter (fun x => decide (x ∈ a)) = a.filter (fun x => decide (x ∈ b)) :=
  strict_ext _ _ (strict_filter hb _) (strict_filter ha _) (fun x => by simp [List.mem_filter, And.comm])

theorem intersect_spec (a b : List Nat) (ha : Strict a) (hb : Strict b) :
    intersect a b = a.filter (fun x => decide (x ∈ b)) := by
  unfold intersect
  split
  · rename_i h
    rcases h with h | h
    · rw [List.length_eq_zero_iff] at h; subst h; simp
    · rw [List.length_eq_zero_iff] at h; subst h; simp
  · split
    · exact intersectGallop_spec a b ha hb
    · split
      · rw [intersectGallop_spec b a hb ha, filter_comm_strict a b ha hb]
      · exact intersectMerge_spec a b ha hb

theorem unionMerge_spec : ∀ a b : List Nat, Strict a → Strict b →
    Strict (unionMerge a b) ∧ ∀ z, z ∈ unionMerge a b ↔ z ∈ a ∨ z ∈ b
  | [], ys, _, hb => by simp [unionMerge, hb]
  | x :: xs, [], ha, _ => by simp [unionMerge, ha]
  | x :: xs, y :: ys, ha, hb => by
    rw [unionMerge]
    have hxs := strict_cons ha
    have hys := strict_cons hb
    split
    · rename_i hxy
      have ih := unionMerge_spec xs (y :: ys) hxs hb
      refine ⟨List.pairwise_cons.2 ⟨fun z hz => ?_, ih.1⟩, fun z => ?_⟩
      · rcases (ih.2 z).1 hz with h | h
        · exact strict_head ha z h
        · rcases List.mem_cons.1 h with e | e
          · omega
          · have := strict_head hb z e; omega
      · simp only [List.mem_cons, ih.2 z]; grind
    · split
      · rename_i hxy hyx
        have ih := unionMerge_spec (x :: xs) ys ha hys
        refine ⟨List.pairwise_cons.2 ⟨fun z hz => ?_, ih.1⟩, fun z => ?_⟩
        · rcases (ih.2 z).1 hz with h | h
          · rcases List.mem_cons.1 h with e | e
            · omega
            · have := strict_head ha z e; omega
          · exact strict_head hb z h
        · simp only [List.mem_cons, ih.2 z]; grind
      · rename_i hxy hyx
        have e : x = y := by omega
        subst e
        have ih := unionMerge_spec xs ys hxs hys
        refine ⟨List.pairwise_cons.2 ⟨fun z hz => ?_, ih.1⟩, fun z => ?_⟩
        · rcases (ih.2 z).1 hz with h | h
          · exact strict_head ha z h
          · exact strict_head hb z h
        · simp only [List.mem_cons, ih.2 z]; grind
termination_by a b => a.length + b.length

theorem dropWhile_lt (x : Nat) : ∀ ys : List Nat, Strict ys →
    Strict (ys.dropWhile (· < x)) ∧ (∀ w ∈ ys.dropWhile (· < x), x ≤ w) ∧
      (∀ z, x ≤ z → (z ∈ ys ↔ z ∈ ys.dropWhile (· < x))) ∧ (∀ w ∈ ys, w ∉ ys.dropWhile (· < x) → w < x)
  | [], _ => by simp only [List.dropWhile_nil]; exact ⟨List.Pairwise.nil, by simp, by simp, by simp⟩
  | y :: ys, h => by
    rw [List.dropWhile_cons]
    have ih := dropWhile_lt x ys (strict_cons h)
    split
    · rename_i hy
      simp only [decide_eq_true_eq] at hy
      refine ⟨ih.1, ih.2.1, fun z hz => ?_, fun w hw hn => ?_⟩
      · constructor
        · intro hm
          rcases List.mem_cons.1 hm with e | e
          · omega
          · exact (ih.2.2.1 z hz).1 e
        · intro hm; exact List.mem_cons_of_mem _ ((ih.2.2.1 z hz).2 hm)
      · rcases List.mem_cons.1 hw with e | e
        · omega
        · exact ih.2.2.2 w e hn
    · rename_i hy
      simp only [decide_eq_true_eq] at hy
      refine ⟨h, fun w hw => ?_, fun z _ => Iff.rfl, fun w hw hn => absurd hw hn⟩
      rcases List.mem_cons.1 hw with e | e
      · omega
      · have := strict_head h w e; omega

theorem differenceMerge_spec : ∀ a b : List Nat, Strict a → Strict b →
    differenceMerge a b = a.filter (fun x => decide (x ∉ b))
  | [], _, _, _ => by simp [differenceMerge]
  | x :: xs, ys, ha, hb => by
    have hxs := strict_cons ha
    have hd := dropWhile_lt x ys hb
    rw [differenceMerge]
    split
    · rename_i y rest heq
      rw [heq] at hd
      split
      · rename_i hyx
        subst hyx
        rw [differenceMerge_spec xs rest hxs (strict_cons hd.1)]
        have hmem : y ∈ ys := (hd.2.2.1 y (Nat.le_refl _)).2 (by simp)
        simp only [List.filter_cons, hmem, not_true_eq_false, decide_false, Bool.false_eq_true, ↓reduceIte]
        apply List.filter_congr
        intro z hz
        have hzy := strict_head ha z hz
        have : z ∈ ys ↔ z ∈ rest := by
          rw [hd.2.2.1 z (by omega)]
          simp only [List.mem_cons]
          constructor
          · intro h; rcases h with h | h
            · omega
            · exact h
          · intro h; exact Or.inr h
        simp [this]
      · rename_i hyx
        rw [differenceMerge_spec xs (y :: rest) hxs hd.1]
        have hnot : x ∉ ys := by
          intro hm
          have := (hd.2.2.1 x (Nat.le_refl _)).1 hm
          rcases List.mem_cons.1 this with e | e
          · exact hyx e.symm
          · have := strict_head hd.1 x e; have := hd.2.1 y (by simp); omega
        simp only [List.filter_cons, hnot, not_false_eq_true, decide_true, ↓reduceIte]
        congr 1
        apply List.filter_congr
        intro z hz
        have hzy := strict_head ha z hz
        simp [hd.2.2.1 z (by omega)]
    · rename_i heq
      rw [heq] at hd
      rw [differenceMerge_spec xs [] hxs List.Pairwise.nil]
      have hall : ∀ w ∈ ys, w < x := fun w hw => hd.2.2.2 w hw (by simp)
      have hnot : x ∉ ys := fun hm => by have := hall x hm; omega
      simp only [List.filter_cons, hnot, not_false_eq_true, decide_true, ↓reduceIte]
      congr 1
      apply List.filter_congr
      intro z hz
      have hzy := strict_head ha z hz
      have : z ∉ ys := fun hm => by have := hall z hm; omega
      simp [this]

theorem isStrict_spec : ∀ a : List Nat, isStrict a = true ↔ Strict a
  | [] => by simp [isStrict, Strict]
  | [x] => by simp [isStrict, Strict]
  | x :: y :: rest => by
    rw [isStrict, Bool.and_eq_true, decide_eq_true_eq, isStrict_spec (y :: rest)]
    constructor
    · intro ⟨hxy, hr⟩
      refine List.pairwise_cons.2 ⟨fun z hz => ?_, hr⟩
      rcases List.mem_cons.1 hz with e | e
      · omega
      · have := strict_head hr z e; omega
    · intro h
      exact ⟨strict_head h y (by simp), strict_cons h⟩

theorem intersectCount_spec (a b : List Nat) (ha : Strict a) (hb : Strict b) :
    intersectCount a b = (a.filter (fun x => decide (x ∈ b))).length := by
  rw [intersectCount_eq, intersectMerge_spec a b ha hb]

end Postings
