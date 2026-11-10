namespace Vectors

structure Cand where
  dist : Int
  id : Nat
deriving DecidableEq, Repr, Inhabited

def closer (a b : Cand) : Bool :=
  decide (a.dist < b.dist) || (decide (a.dist = b.dist) && decide (a.id < b.id))

def farther (a b : Cand) : Bool := closer b a

structure StrictTotal (lt : Cand → Cand → Bool) : Prop where
  irrefl : ∀ a, lt a a = false
  trans : ∀ a b c, lt a b = true → lt b c = true → lt a c = true
  total : ∀ a b, a ≠ b → lt a b = true ∨ lt b a = true

def get (l : List Cand) (i : Nat) : Cand := l[i]?.getD default

def parent (j : Nat) : Nat := (j - 1) / 2

def IsHeap (lt : Cand → Cand → Bool) (l : List Cand) : Prop :=
  ∀ j, 0 < j → j < l.length → lt (get l j) (get l (parent j)) = false

def siftUp (lt : Cand → Cand → Bool) (c : Cand) (h : List Cand) (i : Nat) : List Cand :=
  if i = 0 then h.set i c
  else if !lt c (get h ((i - 1) / 2)) then h.set i c
  else siftUp lt c (h.set i (get h ((i - 1) / 2))) ((i - 1) / 2)
termination_by i
decreasing_by omega

def heapPush (lt : Cand → Cand → Bool) (h : List Cand) (c : Cand) : List Cand :=
  siftUp lt c (h ++ [c]) h.length

def pickChild (lt : Cand → Cand → Bool) (h : List Cand) (n i : Nat) : Nat :=
  if 2 * i + 2 < n && lt (get h (2 * i + 2)) (get h (2 * i + 1)) then 2 * i + 2 else 2 * i + 1

def siftDown (lt : Cand → Cand → Bool) (c : Cand) (h : List Cand) (n i : Nat) : List Cand :=
  if n ≤ 2 * i + 1 then h.set i c
  else if !lt (get h (pickChild lt h n i)) c then h.set i c
  else siftDown lt c (h.set i (get h (pickChild lt h n i))) n (pickChild lt h n i)
termination_by n - i
decreasing_by unfold pickChild; split <;> omega

def heapPop (lt : Cand → Cand → Bool) (h : List Cand) : Cand × List Cand :=
  let n := h.length - 1
  (get h 0, if 0 < n then siftDown lt (get h n) (h.take n) n 0 else h.take n)

def replaceTop (lt : Cand → Cand → Bool) (h : List Cand) (c : Cand) : Cand × List Cand :=
  (get h 0, siftDown lt c h h.length 0)

def heapTop (h : List Cand) : Cand := get h 0

def minPush := heapPush closer
def minPop := heapPop closer
def maxPush := heapPush farther
def maxPop := heapPop farther
def maxReplaceTop := replaceTop farther

theorem closer_strict : StrictTotal closer := by
  refine ⟨fun a => by simp [closer], fun a b c h1 h2 => ?_, fun a b hne => ?_⟩
  · simp only [closer, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at *
    omega
  · simp only [closer, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
    have : a.dist ≠ b.dist ∨ a.id ≠ b.id := by
      cases a; cases b; simp only [ne_eq, Cand.mk.injEq] at *; omega
    omega

theorem farther_strict : StrictTotal farther := by
  have h := closer_strict
  exact ⟨fun a => h.irrefl a, fun a b c h1 h2 => h.trans c b a h2 h1, fun a b hne =>
    (h.total b a (Ne.symm hne)).elim Or.inl Or.inr⟩

section order

variable {lt : Cand → Cand → Bool} (hlt : StrictTotal lt)
include hlt

theorem StrictTotal.asymm' {a b : Cand} (h : lt a b = true) : lt b a = false := by
  cases hb : lt b a
  · rfl
  · have := hlt.trans a b a h hb
    rw [hlt.irrefl] at this
    exact absurd this (by simp)

theorem StrictTotal.le_trans' {a b c : Cand} (h1 : lt b a = false) (h2 : lt c b = false) : lt c a = false := by
  cases hc : lt c a
  · rfl
  · by_cases he : b = a
    · subst he; rw [hc] at h2; exact h2
    · rcases hlt.total b a he with h | h
      · rw [h] at h1; exact h1
      · have := hlt.trans c a b hc h
        rw [this] at h2; exact h2

theorem StrictTotal.lt_of_lt_le {a b c : Cand} (h1 : lt a b = true) (h2 : lt c b = false) : lt c a = false := by
  cases hc : lt c a
  · rfl
  · have := hlt.trans c a b hc h1
    rw [this] at h2; exact h2

end order

theorem get_set (l : List Cand) (a : Cand) (i j : Nat) :
    get (l.set i a) j = if i = j ∧ i < l.length then a else get l j := by
  unfold get
  rw [List.getElem?_set]
  by_cases h1 : i = j
  · subst h1
    by_cases h2 : i < l.length
    · simp [h2]
    · simp [h2]
  · simp [h1]

def swap (V : List Cand) (i p : Nat) : List Cand := (V.set i (get V p)).set p (get V i)

theorem swap_length (V : List Cand) (i p : Nat) : (swap V i p).length = V.length := by
  simp [swap]

theorem get_swap (V : List Cand) (i p x : Nat) (hi : i < V.length) (hp : p < V.length) :
    get (swap V i p) x = if x = p then get V i else if x = i then get V p else get V x := by
  unfold swap
  rw [get_set, get_set]
  simp only [List.length_set]
  by_cases h1 : x = p
  · subst h1; simp [hp]
  · by_cases h2 : x = i
    · subst h2
      have : p ≠ x := fun e => h1 e.symm
      simp [h1, this, hi]
    · have : p ≠ x := fun e => h1 e.symm
      have : i ≠ x := fun e => h2 e.symm
      simp [*]

theorem get_eq_getElem (l : List Cand) (i : Nat) (h : i < l.length) : get l i = l[i] := by
  simp [get, List.getElem?_eq_getElem h]

theorem swap_perm (V : List Cand) (i p : Nat) (hi : i < V.length) (hp : p < V.length) : (swap V i p).Perm V := by
  unfold swap
  rw [get_eq_getElem V p hp, get_eq_getElem V i hi]
  exact List.set_set_perm hi hp

theorem parent_lt (j : Nat) (h : 0 < j) : parent j < j := by unfold parent; omega

theorem parent_child (i j : Nat) (h : 0 < j) : parent j = i ↔ j = 2 * i + 1 ∨ j = 2 * i + 2 := by
  unfold parent; omega

def InvUp (lt : Cand → Cand → Bool) (V : List Cand) (i : Nat) : Prop :=
  (∀ j, 0 < j → j < V.length → j ≠ i → lt (get V j) (get V (parent j)) = false) ∧
    (0 < i → ∀ j, 0 < j → j < V.length → parent j = i → lt (get V j) (get V (parent i)) = false)

def InvDown (lt : Cand → Cand → Bool) (V : List Cand) (i : Nat) : Prop :=
  (∀ j, 0 < j → j < V.length → parent j ≠ i → lt (get V j) (get V (parent j)) = false) ∧
    (0 < i → ∀ j, 0 < j → j < V.length → parent j = i → lt (get V j) (get V (parent i)) = false)

section proofs

variable {lt : Cand → Cand → Bool} (hlt : StrictTotal lt)
include hlt

omit hlt in
theorem invUp_done {V : List Cand} {i : Nat} (hinv : InvUp lt V i)
    (h : i = 0 ∨ lt (get V i) (get V (parent i)) = false) : IsHeap lt V := by
  intro j hj hjl
  by_cases he : j = i
  · subst he
    rcases h with h | h
    · omega
    · exact h
  · exact hinv.1 j hj hjl he

theorem invUp_step {V : List Cand} {i : Nat} (hil : i < V.length) (h0 : 0 < i) (hinv : InvUp lt V i)
    (hc : lt (get V i) (get V (parent i)) = true) : InvUp lt (swap V i (parent i)) (parent i) := by
  have hpi := parent_lt i h0
  have hpl : parent i < V.length := by omega
  have hip : i ≠ parent i := by omega
  have hip' : parent i ≠ i := by omega
  obtain ⟨ha, hb⟩ := hinv
  refine ⟨fun j hj hjl hjp => ?_, fun hp0 j hj hjl hjpar => ?_⟩
  · rw [swap_length] at hjl
    have hpj := parent_lt j hj
    rw [get_swap V i (parent i) j hil hpl, get_swap V i (parent i) (parent j) hil hpl]
    by_cases hji : j = i
    · subst hji
      simp only [hjp, hip', ite_false, ite_true]
      exact hlt.asymm' hc
    · by_cases hpp : parent j = parent i
      · simp only [hjp, hji, hpp, ite_false, ite_true]
        have := ha j hj hjl hji
        rw [hpp] at this
        exact hlt.lt_of_lt_le hc this
      · by_cases hpj' : parent j = i
        · have hjne : j ≠ parent i := by omega
          simp only [hjne, hji, hpj', hip, ite_false, ite_true]
          exact hb h0 j hj hjl hpj'
        · simp only [hjp, hji, hpp, hpj', ite_false]
          exact ha j hj hjl hji
  · rw [swap_length] at hjl
    have hpp := parent_lt (parent i) hp0
    rw [get_swap V i (parent i) j hil hpl, get_swap V i (parent i) (parent (parent i)) hil hpl]
    have hn1 : parent (parent i) ≠ parent i := by omega
    have hn2 : parent (parent i) ≠ i := by omega
    simp only [hn1, hn2, ite_false]
    have hjp : j ≠ parent i := by have := parent_lt j hj; omega
    have hpar := ha (parent i) hp0 hpl hip'
    by_cases hji : j = i
    · subst hji
      simp only [hjp, ite_false, ite_true]
      exact hpar
    · simp only [hjp, hji, ite_false]
      have := ha j hj hjl hji
      rw [hjpar] at this
      exact hlt.le_trans' hpar this

theorem siftUp_spec (c : Cand) : ∀ i (h : List Cand), i < h.length → InvUp lt (h.set i c) i →
    IsHeap lt (siftUp lt c h i) ∧ (siftUp lt c h i).Perm (h.set i c) := by
  intro i
  induction i using Nat.strongRecOn with
  | ind i ih =>
    intro h hil hinv
    unfold siftUp
    by_cases h0 : i = 0
    · simp only [h0, ite_true]
      subst h0
      exact ⟨invUp_done hinv (Or.inl rfl), List.Perm.refl _⟩
    · simp only [h0, ite_false]
      have hV : get (h.set i c) i = c := by rw [get_set]; simp [hil]
      have hp : (i - 1) / 2 = parent i := rfl
      have hpi := parent_lt i (by omega)
      have hVp : get (h.set i c) (parent i) = get h (parent i) := by
        rw [get_set]; have : i ≠ parent i := by omega
        simp [this]
      rw [hp]
      by_cases hs : lt c (get h (parent i)) = true
      · simp only [hs, Bool.not_true, Bool.false_eq_true, ite_false]
        have hl' : parent i < (h.set i (get h (parent i))).length := by simp; omega
        have eq : (h.set i (get h (parent i))).set (parent i) c = swap (h.set i c) i (parent i) := by
          unfold swap
          rw [hV, hVp, List.set_set]
        have hstep := invUp_step hlt (by simp; exact hil) (by omega) hinv (by rw [hV, hVp]; exact hs)
        rw [← eq] at hstep
        obtain ⟨r1, r2⟩ := ih (parent i) hpi (h.set i (get h (parent i))) hl' hstep
        refine ⟨r1, r2.trans ?_⟩
        rw [eq]
        exact swap_perm _ _ _ (by simp; exact hil) (by simp; omega)
      · have hs' : lt c (get h (parent i)) = false := by simpa using hs
        simp only [hs', Bool.not_false, ite_true]
        exact ⟨invUp_done hinv (Or.inr (by rw [hV, hVp]; exact hs')), List.Perm.refl _⟩

theorem heapPush_spec (h : List Cand) (c : Cand) (hh : IsHeap lt h) :
    IsHeap lt (heapPush lt h c) ∧ (heapPush lt h c).Perm (h ++ [c]) := by
  unfold heapPush
  have e : (h ++ [c]).set h.length c = h ++ [c] := by simp
  have := siftUp_spec hlt c h.length (h ++ [c]) (by simp)
  rw [e] at this
  apply this
  constructor
  · intro j hj hjl hjne
    simp at hjl
    have hjl' : j < h.length := by omega
    have hpj := parent_lt j hj
    have g1 : get (h ++ [c]) j = get h j := by
      unfold get; rw [List.getElem?_append_left hjl']
    have g2 : get (h ++ [c]) (parent j) = get h (parent j) := by
      unfold get; rw [List.getElem?_append_left (by omega)]
    rw [g1, g2]; exact hh j hj hjl'
  · intro _ j hj hjl hjp
    simp at hjl
    have := (parent_child h.length j hj).mp hjp
    omega

theorem invDown_done {V : List Cand} {i : Nat} (hinv : InvDown lt V i)
    (h : V.length ≤ 2 * i + 1 ∨ (lt (get V (pickChild lt V V.length i)) (get V i) = false)) : IsHeap lt V := by
  intro j hj hjl
  by_cases hp : parent j = i
  · rcases h with h | h
    · have := (parent_child i j hj).mp hp; omega
    · rw [hp]
      have hc := (parent_child i j hj).mp hp
      unfold pickChild at h
      by_cases hcc : (2 * i + 2 < V.length && lt (get V (2 * i + 2)) (get V (2 * i + 1))) = true
      · simp only [hcc, ite_true] at h
        rcases hc with hc | hc
        · subst hc
          simp only [Bool.and_eq_true, decide_eq_true_eq] at hcc
          exact hlt.le_trans' h (hlt.asymm' hcc.2)
        · subst hc; exact h
      · simp only [Bool.not_eq_true] at hcc
        simp only [hcc, Bool.false_eq_true, ite_false] at h
        rcases hc with hc | hc
        · subst hc; exact h
        · subst hc
          have : lt (get V (2 * i + 2)) (get V (2 * i + 1)) = false := by
            simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not] at hcc
            rcases hcc with h' | h'
            · omega
            · exact h'
          exact hlt.le_trans' h this
  · exact hinv.1 j hj hjl hp

theorem pickChild_spec (V : List Cand) (n i : Nat) (hn : 2 * i + 1 < n) :
    (pickChild lt V n i = 2 * i + 1 ∨ pickChild lt V n i = 2 * i + 2) ∧ pickChild lt V n i < n ∧
      ∀ s, (s = 2 * i + 1 ∨ s = 2 * i + 2) → s < n → s ≠ pickChild lt V n i →
        lt (get V s) (get V (pickChild lt V n i)) = false := by
  unfold pickChild
  by_cases hcc : (2 * i + 2 < n && lt (get V (2 * i + 2)) (get V (2 * i + 1))) = true
  · rw [ite_eq_left_of_eq_true _ _ (eq_true hcc)]
    simp only [Bool.and_eq_true, decide_eq_true_eq] at hcc
    refine ⟨Or.inr rfl, hcc.1, fun s hs _ hne => ?_⟩
    have : s = 2 * i + 1 := by omega
    subst this
    exact hlt.asymm' hcc.2
  · rw [ite_eq_right_of_eq_false _ _ (eq_false hcc)]
    simp only [Bool.not_eq_true] at hcc
    refine ⟨Or.inl rfl, hn, fun s hs hsn hne => ?_⟩
    have : s = 2 * i + 2 := by omega
    subst this
    simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not] at hcc
    rcases hcc with h' | h'
    · omega
    · exact h'

theorem invDown_step {V : List Cand} {i : Nat} (hil : i < V.length) (hn : 2 * i + 1 < V.length)
    (hinv : InvDown lt V i) (hc : lt (get V (pickChild lt V V.length i)) (get V i) = true) :
    InvDown lt (swap V i (pickChild lt V V.length i)) (pickChild lt V V.length i) := by
  obtain ⟨hch, hchl, hsib⟩ := pickChild_spec hlt V V.length i hn
  generalize pickChild lt V V.length i = ch at hch hchl hsib hc ⊢
  have hpch : parent ch = i := (parent_child i ch (by omega)).mpr hch
  have hich : i ≠ ch := by omega
  have hchi : ch ≠ i := by omega
  obtain ⟨ha, hb⟩ := hinv
  refine ⟨fun j hj hjl hjp => ?_, fun _ j hj hjl hjpar => ?_⟩
  · rw [swap_length] at hjl
    rw [get_swap V i ch j hil hchl, get_swap V i ch (parent j) hil hchl]
    have hpj := parent_lt j hj
    by_cases hjc : j = ch
    · subst hjc
      simp only [hpch, hchi, hich, ite_true, ite_false]
      exact hlt.asymm' hc
    · by_cases hji : j = i
      · subst hji
        have h1 : parent j ≠ ch := by omega
        have h2 : parent j ≠ j := by omega
        simp only [hjc, h1, h2, ite_false, ite_true]
        exact hb hj ch (by omega) hchl hpch
      · by_cases hpi : parent j = i
        · have hs := hsib j ((parent_child i j hj).mp hpi) hjl hjc
          simp only [hjc, hji, hpi, hich, ite_false, ite_true]
          exact hs
        · simp only [hjc, hji, hjp, hpi, ite_false]
          exact ha j hj hjl hpi
  · rw [swap_length] at hjl
    have hpj := parent_lt j hj
    rw [get_swap V i ch j hil hchl, get_swap V i ch (parent ch) hil hchl]
    have h1 : j ≠ ch := by omega
    have h2 : j ≠ i := by omega
    simp only [h1, h2, hpch, hich, ite_false, ite_true]
    have := ha j hj hjl (by omega)
    rw [hjpar] at this
    exact this

theorem siftDown_spec (c : Cand) (n : Nat) : ∀ k i (h : List Cand), n - i = k → h.length = n → i < n →
    InvDown lt (h.set i c) i →
    IsHeap lt (siftDown lt c h n i) ∧ (siftDown lt c h n i).Perm (h.set i c) := by
  intro k
  induction k using Nat.strongRecOn with
  | ind k ih =>
    intro i h hk hl hin hinv
    have hV : get (h.set i c) i = c := by rw [get_set]; simp; omega
    have hlen : (h.set i c).length = n := by simp [hl]
    unfold siftDown
    by_cases hc : n ≤ 2 * i + 1
    · simp only [hc, ite_true]
      exact ⟨invDown_done hlt hinv (Or.inl (by omega)), List.Perm.refl _⟩
    · simp only [hc, ite_false]
      have hpick : pickChild lt h n i = pickChild lt (h.set i c) (h.set i c).length i := by
        rw [hlen]; unfold pickChild
        rw [get_set, get_set]
        have : i ≠ 2 * i + 2 := by omega
        have : i ≠ 2 * i + 1 := by omega
        simp [*]
      obtain ⟨hch, hchl, _⟩ := pickChild_spec hlt (h.set i c) n i (by omega)
      rw [← hlen, ← hpick] at hch hchl
      rw [hlen] at hchl
      generalize hch' : pickChild lt h n i = ch at hpick hch hchl ⊢
      have hgc : get (h.set i c) ch = get h ch := by
        rw [get_set]; have : i ≠ ch := by omega
        simp [this]
      by_cases hs : lt (get h ch) c = true
      · simp only [hs, Bool.not_true, Bool.false_eq_true, ite_false]
        have eq : (h.set i (get h ch)).set ch c = swap (h.set i c) i ch := by
          unfold swap; rw [hV, hgc, List.set_set]
        have hstep := invDown_step hlt (by rw [hlen]; exact hin) (by rw [hlen]; omega) hinv
          (by rw [← hpick, hV, hgc]; exact hs)
        rw [← hpick, ← eq] at hstep
        obtain ⟨r1, r2⟩ := ih (n - ch) (by omega) ch (h.set i (get h ch)) rfl (by simp [hl]) hchl hstep
        refine ⟨r1, r2.trans ?_⟩
        rw [eq]
        exact swap_perm _ _ _ (by rw [hlen]; exact hin) (by rw [hlen]; exact hchl)
      · have hs' : lt (get h ch) c = false := by simpa using hs
        simp only [hs', Bool.not_false, ite_true]
        refine ⟨invDown_done hlt hinv (Or.inr ?_), List.Perm.refl _⟩
        rw [← hpick, hV, hgc]; exact hs'

theorem heap_root_extreme (l : List Cand) (hh : IsHeap lt l) : ∀ j, j < l.length → lt (get l j) (get l 0) = false := by
  intro j
  induction j using Nat.strongRecOn with
  | ind j ih =>
    intro hj
    by_cases h0 : j = 0
    · subst h0; exact hlt.irrefl _
    · have hp := parent_lt j (by omega)
      exact hlt.le_trans' (ih (parent j) hp (by omega)) (hh j (by omega) hj)

theorem top_extreme (l : List Cand) (hh : IsHeap lt l) : ∀ x ∈ l, lt x (heapTop l) = false := by
  intro x hx
  obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem hx
  have := heap_root_extreme hlt l hh j hj
  rw [get_eq_getElem l j hj] at this
  exact this

theorem heapPop_spec (h : List Cand) (hh : IsHeap lt h) (hne : h ≠ []) :
    (heapPop lt h).1 = heapTop h ∧ (∀ x ∈ h, lt x (heapPop lt h).1 = false) ∧
      IsHeap lt (heapPop lt h).2 ∧ ((heapPop lt h).1 :: (heapPop lt h).2).Perm h := by
  have hlpos : 0 < h.length := List.length_pos_iff.mpr hne
  refine ⟨rfl, top_extreme hlt h hh, ?_⟩
  unfold heapPop
  simp only
  generalize hn : h.length - 1 = n
  have htake : (h.take n).length = n := by simp; omega
  have hsplit : h = h.take n ++ [get h n] := by
    rw [get_eq_getElem h n (by omega)]
    conv => lhs; rw [← List.take_append_drop n h]
    congr
    rw [List.drop_eq_getElem_cons (by omega)]
    simp [List.drop_eq_nil_of_le (show h.length ≤ n + 1 by omega)]
  have htk : ∀ x, x < n → get (h.take n) x = get h x := by
    intro x hx; unfold get; rw [List.getElem?_take]; simp [hx]
  by_cases hpos : 0 < n
  · simp only [hpos, ite_true]
    have hinv : InvDown lt ((h.take n).set 0 (get h n)) 0 := by
      refine ⟨fun j hj hjl hjp => ?_, fun h0 => absurd h0 (by omega)⟩
      simp at hjl
      have hpj := parent_lt j hj
      rw [get_set, get_set]
      have e1 : ¬ (0 = j) := by omega
      have e2 : ¬ (0 = parent j) := by omega
      simp only [e1, e2, false_and, ite_false]
      rw [htk j (by omega), htk (parent j) (by omega)]
      exact hh j hj (by omega)
    obtain ⟨r1, r2⟩ := siftDown_spec hlt (get h n) n (n - 0) 0 (h.take n) rfl htake hpos hinv
    refine ⟨r1, ?_⟩
    have p1 : (get h 0 :: siftDown lt (get h n) (h.take n) n 0).Perm (get h 0 :: (h.take n).set 0 (get h n)) :=
      List.Perm.cons _ r2
    refine p1.trans ?_
    have hd : h.take n = get h 0 :: (h.take n).tail := by
      have : 0 < (h.take n).length := by omega
      rw [← List.cons_head_tail (List.ne_nil_of_length_pos this)]
      simp only [List.tail_cons, List.cons.injEq, and_true]
      rw [List.head_eq_getElem, ← get_eq_getElem _ 0 this, htk 0 hpos]
    rw [hd, List.set_cons_zero]
    conv => rhs; rw [hsplit, hd]
    simp only [List.cons_append]
    exact List.Perm.cons _ (List.perm_append_singleton _ _).symm
  · rw [ite_eq_right_of_eq_false _ _ (eq_false hpos)]
    have hz : n = 0 := by omega
    subst hz
    simp only [List.take_zero]
    refine ⟨fun j hj hjl => by simp at hjl, ?_⟩
    have : h.length = 1 := by omega
    obtain ⟨a, rfl⟩ : ∃ a, h = [a] := by
      match h, this with
      | [a], _ => exact ⟨a, rfl⟩
    simp [get]

theorem replaceTop_spec (h : List Cand) (c : Cand) (hh : IsHeap lt h) (hne : h ≠ []) :
    (replaceTop lt h c).1 = heapTop h ∧ (∀ x ∈ h, lt x (replaceTop lt h c).1 = false) ∧
      IsHeap lt (replaceTop lt h c).2 ∧ (replaceTop lt h c).2.Perm (c :: h.tail) := by
  have hlpos : 0 < h.length := List.length_pos_iff.mpr hne
  refine ⟨rfl, top_extreme hlt h hh, ?_⟩
  unfold replaceTop
  simp only
  have hinv : InvDown lt (h.set 0 c) 0 := by
    refine ⟨fun j hj hjl hjp => ?_, fun h0 => absurd h0 (by omega)⟩
    simp at hjl
    rw [get_set, get_set]
    have e1 : ¬ (0 = j) := by omega
    have e2 : ¬ (0 = parent j) := by omega
    simp only [e1, e2, false_and, ite_false]
    exact hh j hj hjl
  obtain ⟨r1, r2⟩ := siftDown_spec hlt c h.length (h.length - 0) 0 h rfl rfl hlpos hinv
  refine ⟨r1, r2.trans ?_⟩
  obtain ⟨a, t, rfl⟩ : ∃ a t, h = a :: t := ⟨h.head hne, h.tail, (List.cons_head_tail hne).symm⟩
  simp

end proofs

theorem minHeap_push (h : List Cand) (c : Cand) (hh : IsHeap closer h) :
    IsHeap closer (minPush h c) ∧ (minPush h c).Perm (h ++ [c]) := heapPush_spec closer_strict h c hh

theorem maxHeap_push (h : List Cand) (c : Cand) (hh : IsHeap farther h) :
    IsHeap farther (maxPush h c) ∧ (maxPush h c).Perm (h ++ [c]) := heapPush_spec farther_strict h c hh

theorem minHeap_top (h : List Cand) (hh : IsHeap closer h) : ∀ x ∈ h, closer x (heapTop h) = false :=
  top_extreme closer_strict h hh

theorem maxHeap_top (h : List Cand) (hh : IsHeap farther h) : ∀ x ∈ h, closer (heapTop h) x = false :=
  top_extreme farther_strict h hh

theorem minHeap_pop (h : List Cand) (hh : IsHeap closer h) (hne : h ≠ []) :
    (minPop h).1 = heapTop h ∧ (∀ x ∈ h, closer x (minPop h).1 = false) ∧
      IsHeap closer (minPop h).2 ∧ ((minPop h).1 :: (minPop h).2).Perm h := heapPop_spec closer_strict h hh hne

theorem maxHeap_pop (h : List Cand) (hh : IsHeap farther h) (hne : h ≠ []) :
    (maxPop h).1 = heapTop h ∧ (∀ x ∈ h, closer (maxPop h).1 x = false) ∧
      IsHeap farther (maxPop h).2 ∧ ((maxPop h).1 :: (maxPop h).2).Perm h := heapPop_spec farther_strict h hh hne

theorem maxHeap_replaceTop (h : List Cand) (c : Cand) (hh : IsHeap farther h) (hne : h ≠ []) :
    (maxReplaceTop h c).1 = heapTop h ∧ (∀ x ∈ h, closer (maxReplaceTop h c).1 x = false) ∧
      IsHeap farther (maxReplaceTop h c).2 ∧ (maxReplaceTop h c).2.Perm (c :: h.tail) :=
  replaceTop_spec farther_strict h c hh hne

theorem empty_heap (lt : Cand → Cand → Bool) : IsHeap lt [] := fun j _ hj => by simp at hj

end Vectors
