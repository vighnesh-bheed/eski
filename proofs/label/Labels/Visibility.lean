import Labels.Lattice

namespace Labels

structure Vis where
  reader : Label
  words : List Nat
  built : Nat
deriving DecidableEq, Repr

def testAt (ws : List Nat) (i : Nat) : Bool := (ws.getD (i / 64) 0).testBit (i % 64)

def visible (v : Vis) (i : Nat) : Bool := decide (i < v.built) && testAt v.words i

def domBit (a b : Label) : Nat := if dom a b then 1 else 0

def orBits (f : Nat → Nat) (acc : Nat) (js : List Nat) : Nat :=
  js.foldl (fun acc j => acc ||| f j <<< (j % 64)) acc

def chunk (reader : Label) (t : List Label) (i stop : Nat) : Nat :=
  orBits (fun j => domBit reader (t.getD j bottom)) 0 (List.range' i (stop - i))

def fill (reader : Label) (t : List Label) (n : Nat) : Nat → Nat → List Nat → List Nat
  | 0, _, ws => ws
  | fuel + 1, i, ws =>
    if n ≤ i then ws
    else
      let w := i / 64
      let stop := min n ((w + 1) * 64)
      fill reader t n fuel stop (ws.set w (ws.getD w 0 ||| chunk reader t i stop))

def wordsFor (n : Nat) : Nat := (n + 63) / 64

def refresh (t : List Label) (v : Vis) : Vis :=
  if t.length ≤ v.built then v
  else
    let ws := v.words ++ List.replicate (wordsFor t.length - v.words.length) 0
    { v with words := fill v.reader t t.length (t.length - v.built) v.built ws, built := t.length }

def build (reader : Label) (t : List Label) : Vis := refresh t ⟨reader, [], 0⟩

def VisOk (t : List Label) (v : Vis) : Prop :=
  v.built = t.length ∧ v.words.length = wordsFor t.length ∧
  (∀ k, testAt v.words k = (decide (k < t.length) && dom v.reader (t.getD k bottom))) ∧
  ∀ w ∈ v.words, w < 2 ^ 64

theorem one_testBit (q : Nat) : Nat.testBit 1 q = decide (q = 0) := by
  by_cases hq : q = 0
  · subst hq; rfl
  · rw [decide_eq_false hq, Bool.eq_false_iff]
    intro h1
    exact hq (Nat.testBit_one_eq_true_iff_self_eq_zero.1 h1)

theorem bit_shift (b s p : Nat) (hb : b ≤ 1) : (b <<< s).testBit p = (decide (b = 1) && decide (p = s)) := by
  rw [Nat.testBit_shiftLeft]
  rcases Nat.le_one_iff_eq_zero_or_eq_one.1 hb with h | h
  · subst h; simp
  · subst h
    rw [one_testBit, ← Bool.decide_and, decide_eq_true rfl, Bool.true_and]
    exact decide_eq_decide.2 (by omega)

theorem orBits_testBit (f : Nat → Nat) (hf : ∀ j, f j ≤ 1) (js : List Nat) (acc p : Nat) :
    (orBits f acc js).testBit p = (acc.testBit p || js.any (fun j => decide (f j = 1) && decide (p = j % 64))) := by
  induction js generalizing acc with
  | nil => simp [orBits]
  | cons j rest ih =>
    simp only [orBits, List.foldl_cons] at ih ⊢
    rw [ih, Nat.testBit_or, bit_shift _ _ _ (hf j), List.any_cons, Bool.or_assoc]

theorem orBits_lt (f : Nat → Nat) (hf : ∀ j, f j ≤ 1) (js : List Nat) (acc : Nat) (h : acc < 2 ^ 64) :
    orBits f acc js < 2 ^ 64 := by
  induction js generalizing acc with
  | nil => simpa [orBits] using h
  | cons j rest ih =>
    simp only [orBits, List.foldl_cons] at ih ⊢
    apply ih
    apply Nat.or_lt_two_pow h
    rw [Nat.shiftLeft_eq]
    have hj : j % 64 < 64 := Nat.mod_lt _ (by decide)
    have : 2 ^ (j % 64) ≤ 2 ^ 63 := Nat.pow_le_pow_right (by decide) (by omega)
    rcases Nat.le_one_iff_eq_zero_or_eq_one.1 (hf j) with h0 | h1
    · rw [h0, Nat.zero_mul]; exact Nat.two_pow_pos 64
    · rw [h1, Nat.one_mul]; exact Nat.lt_of_le_of_lt this (by decide)

theorem domBit_le (a b : Label) : domBit a b ≤ 1 := by
  unfold domBit; split <;> decide

theorem domBit_one (a b : Label) : domBit a b = 1 ↔ dom a b = true := by
  unfold domBit; split <;> simp_all

theorem chunk_testBit (reader : Label) (t : List Label) (i stop k : Nat)
    (hw : k / 64 = i / 64) (hs : stop ≤ (i / 64 + 1) * 64) :
    (chunk reader t i stop).testBit (k % 64) = (decide (i ≤ k ∧ k < stop) && dom reader (t.getD k bottom)) := by
  unfold chunk
  rw [orBits_testBit _ (fun j => domBit_le _ _), Nat.zero_testBit, Bool.false_or]
  cases hd : dom reader (t.getD k bottom)
  · simp only [Bool.and_false]
    rw [List.any_eq_false]
    intro j hj
    simp only [List.mem_range'_1] at hj
    have hjw : j / 64 = i / 64 := by omega
    simp only [Bool.and_eq_true, decide_eq_true_eq, not_and]
    intro h1 h2
    have : j = k := by omega
    subst this
    rw [domBit_one, hd] at h1
    exact absurd h1 (by decide)
  · simp only [Bool.and_true]
    by_cases hk : i ≤ k ∧ k < stop
    · rw [decide_eq_true hk, List.any_eq_true]
      refine ⟨k, ?_, ?_⟩
      · simp only [List.mem_range'_1]; omega
      · simp only [Bool.and_eq_true, decide_eq_true_eq]; exact ⟨(domBit_one _ _).2 hd, trivial⟩
    · rw [decide_eq_false hk, List.any_eq_false]
      intro j hj
      simp only [List.mem_range'_1] at hj
      simp only [Bool.and_eq_true, decide_eq_true_eq, not_and]
      intro _ h2
      have : j = k := by omega
      omega

theorem chunk_lt (reader : Label) (t : List Label) (i stop : Nat) : chunk reader t i stop < 2 ^ 64 :=
  orBits_lt _ (fun j => domBit_le _ _) _ 0 (by decide)

theorem chunk_high (reader : Label) (t : List Label) (i stop p : Nat) (hp : 64 ≤ p) :
    (chunk reader t i stop).testBit p = false :=
  Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (chunk_lt reader t i stop) (Nat.pow_le_pow_right (by decide) hp))

theorem getD_set_self (ws : List Nat) (w x : Nat) (h : w < ws.length) : (ws.set w x).getD w 0 = x := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_set_self h]

theorem getD_set_other (ws : List Nat) (w v x : Nat) (h : w ≠ v) : (ws.set w x).getD v 0 = ws.getD v 0 := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_set_ne h]

theorem fill_length (reader : Label) (t : List Label) (n fuel i : Nat) (ws : List Nat) :
    (fill reader t n fuel i ws).length = ws.length := by
  induction fuel generalizing i ws with
  | zero => rfl
  | succ fuel ih =>
    simp only [fill]
    split
    · rfl
    · rw [ih, List.length_set]

theorem fill_bound (reader : Label) (t : List Label) (n fuel i : Nat) (ws : List Nat) (h : ∀ w ∈ ws, w < 2 ^ 64) :
    ∀ w ∈ fill reader t n fuel i ws, w < 2 ^ 64 := by
  induction fuel generalizing i ws with
  | zero => exact h
  | succ fuel ih =>
    simp only [fill]
    split
    · exact h
    · apply ih
      intro w hw
      rcases List.mem_or_eq_of_mem_set hw with hm | he
      · exact h w hm
      · rw [he]
        apply Nat.or_lt_two_pow _ (chunk_lt _ _ _ _)
        simp only [List.getD_eq_getElem?_getD]
        cases hg : ws[i / 64]? with
        | none => decide
        | some x => exact h x (List.mem_of_getElem? hg)

theorem split_range (x d : Bool) (i stop n k : Nat) (h1 : i ≤ stop) (h2 : stop ≤ n) :
    ((x || (decide (i ≤ k ∧ k < stop) && d)) || (decide (stop ≤ k ∧ k < n) && d)) =
      (x || (decide (i ≤ k ∧ k < n) && d)) := by
  have e : ((i ≤ k ∧ k < stop) ∨ (stop ≤ k ∧ k < n)) ↔ (i ≤ k ∧ k < n) := by omega
  cases x <;> cases d <;> simp only [Bool.true_or, Bool.false_or, Bool.and_true, Bool.and_false, Bool.or_false]
  rw [← Bool.decide_or]
  exact decide_eq_decide.2 e

theorem fill_testAt (reader : Label) (t : List Label) (n fuel i : Nat) (ws : List Nat)
    (hlen : wordsFor n ≤ ws.length) (hfuel : n - i ≤ fuel) (k : Nat) :
    testAt (fill reader t n fuel i ws) k =
      (testAt ws k || (decide (i ≤ k ∧ k < n) && dom reader (t.getD k bottom))) := by
  induction fuel generalizing i ws with
  | zero =>
    simp only [fill]
    have : ¬ (i ≤ k ∧ k < n) := by omega
    simp [decide_eq_false this]
  | succ fuel ih =>
    simp only [fill]
    split
    · rename_i hn
      have : ¬ (i ≤ k ∧ k < n) := by omega
      simp [decide_eq_false this]
    · rename_i hn
      have hwl : i / 64 < ws.length := by unfold wordsFor at hlen; omega
      have hstop1 : i < min n ((i / 64 + 1) * 64) := by omega
      have hstop2 : min n ((i / 64 + 1) * 64) ≤ n := Nat.min_le_left _ _
      rw [ih _ _ (by rw [List.length_set]; exact hlen) (by omega)]
      unfold testAt
      by_cases hk : k / 64 = i / 64
      · rw [hk, getD_set_self _ _ _ hwl, Nat.testBit_or, chunk_testBit reader t i _ k hk (Nat.min_le_right _ _)]
        exact split_range _ _ _ _ _ _ (Nat.le_of_lt hstop1) hstop2
      · rw [getD_set_other _ _ _ _ (Ne.symm hk)]
        have e : (min n ((i / 64 + 1) * 64) ≤ k ∧ k < n) ↔ (i ≤ k ∧ k < n) := by omega
        rw [decide_eq_decide.2 e]

theorem getD_append_zeros (ws : List Nat) (m j : Nat) : (ws ++ List.replicate m 0).getD j 0 = ws.getD j 0 := by
  simp only [List.getD_eq_getElem?_getD, List.getElem?_append]
  split
  · rfl
  · rename_i h
    rw [List.getElem?_eq_none (Nat.le_of_not_lt h)]
    simp only [List.getElem?_replicate]
    split <;> rfl

theorem testAt_append_zeros (ws : List Nat) (m k : Nat) : testAt (ws ++ List.replicate m 0) k = testAt ws k := by
  unfold testAt; rw [getD_append_zeros]

theorem wordsFor_mono {a b : Nat} (h : a ≤ b) : wordsFor a ≤ wordsFor b := by
  unfold wordsFor; omega

theorem prefix_getD {t t' : List Label} (h : t <+: t') {k : Nat} (hk : k < t.length) :
    t'.getD k bottom = t.getD k bottom := by
  obtain ⟨u, rfl⟩ := h
  simp [List.getD_eq_getElem?_getD, List.getElem?_append_left hk]

theorem empty_ok (reader : Label) : VisOk [] ⟨reader, [], 0⟩ := by
  refine ⟨rfl, rfl, fun k => ?_, fun w hw => by simp at hw⟩
  simp [testAt]

theorem refresh_reader (t : List Label) (v : Vis) : (refresh t v).reader = v.reader := by
  unfold refresh; split <;> rfl

theorem refresh_ok {t t' : List Label} {v : Vis} (h : VisOk t v) (hp : t <+: t') : VisOk t' (refresh t' v) := by
  obtain ⟨hb, hl, ht, hw⟩ := h
  unfold refresh
  split
  · rename_i hle
    have heq : t = t' := hp.eq_of_length (Nat.le_antisymm hp.length_le (hb ▸ hle))
    subst heq
    exact ⟨hb, hl, ht, hw⟩
  · rename_i hlt
    have hgrow : t.length < t'.length := by omega
    have hmono := wordsFor_mono (Nat.le_of_lt hgrow)
    refine ⟨rfl, ?_, fun k => ?_, ?_⟩
    · simp only
      rw [fill_length, List.length_append, List.length_replicate, hl]
      omega
    · simp only
      rw [fill_testAt _ _ _ _ _ _ (by rw [List.length_append, List.length_replicate, hl]; omega) (Nat.le_refl _),
        testAt_append_zeros, ht, hb]
      by_cases hk : k < t.length
      · rw [prefix_getD hp hk]
        have h1 : k < t'.length := by omega
        have h2 : ¬ (t.length ≤ k ∧ k < t'.length) := by omega
        simp [decide_eq_true hk, decide_eq_true h1, decide_eq_false h2]
      · have e : (t.length ≤ k ∧ k < t'.length) ↔ k < t'.length := by omega
        simp [decide_eq_false hk, decide_eq_decide.2 e]
    · apply fill_bound
      intro w hm
      rcases List.mem_append.1 hm with hm | hm
      · exact hw w hm
      · rw [List.eq_of_mem_replicate hm]; exact Nat.two_pow_pos 64

theorem build_ok (reader : Label) (t : List Label) : VisOk t (build reader t) :=
  refresh_ok (empty_ok reader) (List.nil_prefix)

theorem word_testBit {t : List Label} {v : Vis} (h : VisOk t v) (j p : Nat) (hp : p < 64) :
    (v.words.getD j 0).testBit p = (decide (64 * j + p < t.length) && dom v.reader (t.getD (64 * j + p) bottom)) := by
  have := h.2.2.1 (64 * j + p)
  unfold testAt at this
  have e1 : (64 * j + p) / 64 = j := by omega
  have e2 : (64 * j + p) % 64 = p := by omega
  rw [e1, e2] at this
  exact this

theorem visok_unique {t : List Label} {v w : Vis} (hv : VisOk t v) (hw : VisOk t w) (hr : v.reader = w.reader) :
    v = w := by
  cases v with
  | mk rv wv bv =>
  cases w with
  | mk rw ww bw =>
  simp only at hr
  subst hr
  have hb : bv = bw := hv.1.trans hw.1.symm
  subst hb
  have hlen : wv.length = ww.length := hv.2.1.trans hw.2.1.symm
  have hwords : wv = ww := by
    apply List.ext_getElem hlen
    intro j h1 h2
    apply Nat.eq_of_testBit_eq
    intro p
    rcases Nat.lt_or_ge p 64 with hp | hp
    · have a := word_testBit hv j p hp
      have b := word_testBit hw j p hp
      simp only [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h1, List.getElem?_eq_getElem h2,
        Option.getD_some] at a b
      rw [a, b]
    · rw [Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (hv.2.2.2 _ (List.getElem_mem h1)) (Nat.pow_le_pow_right (by decide) hp)),
        Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le (hw.2.2.2 _ (List.getElem_mem h2)) (Nat.pow_le_pow_right (by decide) hp))]
  rw [hwords]

theorem refresh_eq_build {t t' : List Label} {v : Vis} (h : VisOk t v) (hp : t <+: t') :
    refresh t' v = build v.reader t' :=
  visok_unique (refresh_ok h hp) (build_ok v.reader t') (by rw [refresh_reader]; unfold build; rw [refresh_reader])

theorem visible_spec {t : List Label} {v : Vis} (h : VisOk t v) (k : Nat) :
    visible v k = (decide (k < t.length) && dom v.reader (t.getD k bottom)) := by
  unfold visible
  rw [h.2.2.1, h.1]
  cases decide (k < t.length) <;> rfl

theorem visible_build (reader : Label) (t : List Label) (k : Nat) :
    visible (build reader t) k = (decide (k < t.length) && dom reader (t.getD k bottom)) := by
  have := visible_spec (build_ok reader t) k
  rw [this]
  unfold build; rw [refresh_reader]

theorem stale_closed (v : Vis) (k : Nat) (h : v.built ≤ k) : visible v k = false := by
  unfold visible
  rw [decide_eq_false (Nat.not_lt.2 h), Bool.false_and]

theorem visible_after_growth {t t' : List Label} {v : Vis} (h : VisOk t v) (hp : t <+: t') (k : Nat) :
    visible (refresh t' v) k = (decide (k < t'.length) && dom v.reader (t'.getD k bottom)) := by
  rw [visible_spec (refresh_ok h hp), refresh_reader]

end Labels
