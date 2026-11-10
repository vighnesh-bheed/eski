namespace Postings

theorem rdiv_le_iff {a b c : Rat} (hb : 0 < b) : a / b ≤ c ↔ a ≤ c * b := by
  rw [← Rat.not_lt, Rat.lt_div_iff hb, Rat.not_lt]

theorem rle_div_iff {a b c : Rat} (hc : 0 < c) : a ≤ b / c ↔ a * c ≤ b := by
  rw [← Rat.not_lt, Rat.div_lt_iff hc, Rat.not_lt]

theorem rdiv_le_div_iff {a b c d : Rat} (hb : 0 < b) (hd : 0 < d) : a / b ≤ c / d ↔ a * d ≤ c * b := by
  rw [rle_div_iff hd]
  have e : a / b * d = (a * d) / b := by rw [Rat.div_def, Rat.div_def]; grind
  rw [e, rdiv_le_iff hb]

theorem rdiv_nonneg {a b : Rat} (ha : 0 ≤ a) (hb : 0 < b) : 0 ≤ a / b := by
  rw [rle_div_iff hb]; grind

theorem rdiv_pos {a b : Rat} (ha : 0 < a) (hb : 0 < b) : 0 < a / b := by
  rw [Rat.lt_div_iff hb]; grind

def bm25Norm (k1 b dl avgdl : Rat) : Rat := k1 * (1 - b + b * dl / avgdl)

def bm25Term (w idf f k1 b dl avgdl : Rat) : Rat := w * idf * f * (k1 + 1) / (f + bm25Norm k1 b dl avgdl)

def idfArg (N n : Nat) : Rat := 1 + ((max N n : Nat) - (n : Rat) + 1 / 2) / ((n : Rat) + 1 / 2)

structure Bm25Domain (w idf f k1 b dl avgdl : Rat) : Prop where
  w_nonneg : 0 ≤ w
  idf_nonneg : 0 ≤ idf
  f_nonneg : 0 ≤ f
  k1_pos : 0 < k1
  b_nonneg : 0 ≤ b
  b_le_one : b ≤ 1
  dl_nonneg : 0 ≤ dl
  avgdl_pos : 0 < avgdl

theorem norm_nonneg {w idf f k1 b dl avgdl : Rat} (h : Bm25Domain w idf f k1 b dl avgdl) : 0 ≤ bm25Norm k1 b dl avgdl := by
  unfold bm25Norm
  have h1 : 0 ≤ b * dl / avgdl := rdiv_nonneg (Rat.mul_nonneg h.b_nonneg h.dl_nonneg) h.avgdl_pos
  have h2 : 0 ≤ 1 - b + b * dl / avgdl := by have := h.b_le_one; grind
  exact Rat.mul_nonneg (Rat.le_of_lt h.k1_pos) h2

theorem idfArg_gt_one (N n : Nat) : 1 < idfArg N n := by
  unfold idfArg
  have hden : (0 : Rat) < (n : Rat) + 1 / 2 := by have := Rat.natCast_nonneg (a := n); grind
  have hmax : (n : Rat) ≤ ((max N n : Nat) : Rat) := Rat.natCast_le_natCast.2 (Nat.le_max_right _ _)
  have hnum : (0 : Rat) < ((max N n : Nat) : Rat) - n + 1 / 2 := by grind
  have := rdiv_pos hnum hden
  grind

theorem idfArg_antitone (N n1 n2 : Nat) (h12 : n1 ≤ n2) (h2 : n2 ≤ N) : idfArg N n2 ≤ idfArg N n1 := by
  unfold idfArg
  rw [Nat.max_eq_left h2, Nat.max_eq_left (Nat.le_trans h12 h2)]
  have hn1 : (n1 : Rat) ≤ n2 := Rat.natCast_le_natCast.2 h12
  have hN : (n2 : Rat) ≤ N := Rat.natCast_le_natCast.2 h2
  have h1 : (0 : Rat) < (n1 : Rat) + 1 / 2 := by have := Rat.natCast_nonneg (a := n1); grind
  have h2' : (0 : Rat) < (n2 : Rat) + 1 / 2 := by have := Rat.natCast_nonneg (a := n2); grind
  have : ((N : Rat) - n2 + 1 / 2) / ((n2 : Rat) + 1 / 2) ≤ ((N : Rat) - n1 + 1 / 2) / ((n1 : Rat) + 1 / 2) := by
    rw [rdiv_le_div_iff h2' h1]
    have hprod := Rat.mul_nonneg (Rat.natCast_nonneg (a := N)) (show (0 : Rat) ≤ (n2 : Rat) - n1 by grind)
    grind
  grind

theorem bm25_zero_frequency (w idf k1 b dl avgdl : Rat) : bm25Term w idf 0 k1 b dl avgdl = 0 := by
  unfold bm25Term
  rw [show w * idf * 0 * (k1 + 1) = 0 by grind, Rat.div_def, Rat.zero_mul]

theorem bm25_nonneg {w idf f k1 b dl avgdl : Rat} (h : Bm25Domain w idf f k1 b dl avgdl) (hf : 0 < f) :
    0 ≤ bm25Term w idf f k1 b dl avgdl := by
  unfold bm25Term
  have hn := norm_nonneg h
  apply rdiv_nonneg
  · have := h.k1_pos
    exact Rat.mul_nonneg (Rat.mul_nonneg (Rat.mul_nonneg h.w_nonneg h.idf_nonneg) h.f_nonneg) (by grind)
  · grind

theorem bm25_bound {w idf f k1 b dl avgdl : Rat} (h : Bm25Domain w idf f k1 b dl avgdl) (hf : 0 < f) :
    bm25Term w idf f k1 b dl avgdl ≤ w * idf * (k1 + 1) := by
  unfold bm25Term
  have hn := norm_nonneg h
  have hd : 0 < f + bm25Norm k1 b dl avgdl := by grind
  rw [rdiv_le_iff hd]
  have hc : 0 ≤ w * idf * (k1 + 1) := Rat.mul_nonneg (Rat.mul_nonneg h.w_nonneg h.idf_nonneg) (by have := h.k1_pos; grind)
  have := Rat.mul_nonneg hc hn
  grind

theorem bm25_mono_frequency {w idf f1 f2 k1 b dl avgdl : Rat} (h : Bm25Domain w idf f1 k1 b dl avgdl) (hf1 : 0 < f1)
    (h12 : f1 ≤ f2) : bm25Term w idf f1 k1 b dl avgdl ≤ bm25Term w idf f2 k1 b dl avgdl := by
  unfold bm25Term
  have hn := norm_nonneg h
  have hd1 : 0 < f1 + bm25Norm k1 b dl avgdl := by grind
  have hd2 : 0 < f2 + bm25Norm k1 b dl avgdl := by grind
  rw [rdiv_le_div_iff hd1 hd2]
  have hc : 0 ≤ w * idf * (k1 + 1) := Rat.mul_nonneg (Rat.mul_nonneg h.w_nonneg h.idf_nonneg) (by have := h.k1_pos; grind)
  have := Rat.mul_le_mul_of_nonneg_left h12 (Rat.mul_nonneg hc hn)
  grind

theorem bm25_antitone_length {w idf f k1 b dl1 dl2 avgdl : Rat} (h : Bm25Domain w idf f k1 b dl1 avgdl) (hf : 0 < f)
    (h12 : dl1 ≤ dl2) : bm25Term w idf f k1 b dl2 avgdl ≤ bm25Term w idf f k1 b dl1 avgdl := by
  have h2 : Bm25Domain w idf f k1 b dl2 avgdl := ⟨h.w_nonneg, h.idf_nonneg, h.f_nonneg, h.k1_pos, h.b_nonneg, h.b_le_one,
    by have := h.dl_nonneg; grind, h.avgdl_pos⟩
  unfold bm25Term
  have hn1 := norm_nonneg h
  have hn2 := norm_nonneg h2
  have hd1 : 0 < f + bm25Norm k1 b dl1 avgdl := by grind
  have hd2 : 0 < f + bm25Norm k1 b dl2 avgdl := by grind
  rw [rdiv_le_div_iff hd2 hd1]
  have hnorm : bm25Norm k1 b dl1 avgdl ≤ bm25Norm k1 b dl2 avgdl := by
    unfold bm25Norm
    have : b * dl1 / avgdl ≤ b * dl2 / avgdl := by
      rw [rdiv_le_div_iff h.avgdl_pos h.avgdl_pos]
      have := Rat.mul_le_mul_of_nonneg_left h12 h.b_nonneg
      exact Rat.mul_le_mul_of_nonneg_right this (Rat.le_of_lt h.avgdl_pos)
    exact Rat.mul_le_mul_of_nonneg_left (by grind) (Rat.le_of_lt h.k1_pos)
  have hc : 0 ≤ w * idf * f * (k1 + 1) :=
    Rat.mul_nonneg (Rat.mul_nonneg (Rat.mul_nonneg h.w_nonneg h.idf_nonneg) h.f_nonneg) (by have := h.k1_pos; grind)
  have := Rat.mul_le_mul_of_nonneg_left (show f + bm25Norm k1 b dl1 avgdl ≤ f + bm25Norm k1 b dl2 avgdl by grind) hc
  grind

theorem bm25_average_length (w idf f k1 b avgdl : Rat) (ha : 0 < avgdl) :
    bm25Term w idf f k1 b avgdl avgdl = w * idf * f * (k1 + 1) / (f + k1) := by
  unfold bm25Term bm25Norm
  have : b * avgdl / avgdl = b := by rw [Rat.div_def, Rat.mul_assoc, Rat.mul_inv_cancel _ (Rat.ne_of_gt ha), Rat.mul_one]
  rw [this]
  congr 1
  grind

def rrfTerm (c : Rat) (rank : Nat) : Rat := 1 / (c + (rank + 1 : Nat))

def rankList (c : Rat) : List Nat → Nat → List (Nat × Rat)
  | [], _ => []
  | d :: ds, r => (d, rrfTerm c r) :: rankList c ds (r + 1)

def rrfContribs (c : Rat) (window : Nat) (branches : List (List Nat)) : List (Nat × Rat) :=
  branches.flatMap fun b => rankList c (b.take (if window = 0 then b.length else window)) 0

theorem mem_rankList (c : Rat) : ∀ (ds : List Nat) (r : Nat) (p : Nat × Rat), p ∈ rankList c ds r →
    p.1 ∈ ds ∧ ∃ k, p.2 = rrfTerm c k
  | [], _, _, h => by simp [rankList] at h
  | d :: ds, r, p, h => by
    simp only [rankList, List.mem_cons] at h
    rcases h with e | e
    · subst e; exact ⟨by simp, r, rfl⟩
    · have := mem_rankList c ds (r + 1) p e; exact ⟨List.mem_cons_of_mem _ this.1, this.2⟩

def rrfScore (c : Rat) (window : Nat) (branches : List (List Nat)) (doc : Nat) : Rat :=
  ((rrfContribs c window branches).filter fun p => p.1 = doc).foldl (fun acc p => acc + p.2) 0

theorem rrfTerm_pos (c : Rat) (hc : 0 ≤ c) (r : Nat) : 0 < rrfTerm c r := by
  unfold rrfTerm
  have : (0 : Rat) < ((r + 1 : Nat) : Rat) := Rat.natCast_pos.2 (by omega)
  exact rdiv_pos (by decide) (by grind)

theorem rrfTerm_antitone (c : Rat) (hc : 0 ≤ c) (r1 r2 : Nat) (h : r1 ≤ r2) : rrfTerm c r2 ≤ rrfTerm c r1 := by
  unfold rrfTerm
  have h1 : (0 : Rat) < ((r1 + 1 : Nat) : Rat) := Rat.natCast_pos.2 (by omega)
  have h12 : ((r1 + 1 : Nat) : Rat) ≤ ((r2 + 1 : Nat) : Rat) := Rat.natCast_le_natCast.2 (by omega)
  rw [rdiv_le_div_iff (by grind) (by grind)]
  grind

theorem foldl_add_init (l : List (Nat × Rat)) (a : Rat) :
    l.foldl (fun acc p => acc + p.2) a = a + l.foldl (fun acc p => acc + p.2) 0 := by
  induction l generalizing a with
  | nil => exact (Rat.add_zero a).symm
  | cons p ps ih => simp only [List.foldl_cons]; rw [ih (a + p.2), ih (0 + p.2)]; grind

theorem rrfScore_pos (c : Rat) (hc : 0 ≤ c) (window : Nat) (branches : List (List Nat)) (doc : Nat)
    (h : ∃ p ∈ rrfContribs c window branches, p.1 = doc) : 0 < rrfScore c window branches doc := by
  unfold rrfScore
  have hall : ∀ p ∈ rrfContribs c window branches, 0 < p.2 := by
    intro p hp
    unfold rrfContribs at hp
    simp only [List.mem_flatMap] at hp
    obtain ⟨b, _, hq⟩ := hp
    obtain ⟨_, k, hk⟩ := mem_rankList c _ 0 p hq
    rw [hk]; exact rrfTerm_pos c hc k
  obtain ⟨p, hp, hpd⟩ := h
  have hmem : p ∈ (rrfContribs c window branches).filter fun q => q.1 = doc := List.mem_filter.2 ⟨hp, by simp [hpd]⟩
  have hpos : ∀ q ∈ (rrfContribs c window branches).filter (fun q => q.1 = doc), 0 < q.2 :=
    fun q hq => hall q (List.mem_filter.1 hq).1
  generalize (rrfContribs c window branches).filter (fun q => q.1 = doc) = l at hmem hpos
  induction l with
  | nil => simp at hmem
  | cons q qs ih =>
    simp only [List.foldl_cons]
    rw [foldl_add_init]
    have hq := hpos q (by simp)
    have hrest : 0 ≤ qs.foldl (fun acc p => acc + p.2) 0 := by
      clear ih hmem
      induction qs with
      | nil => simp
      | cons r rs ihr =>
        simp only [List.foldl_cons]; rw [foldl_add_init]
        have := hpos r (by simp)
        have := ihr (fun x hx => hpos x (by simp at hx ⊢; rcases hx with h | h <;> simp [h]))
        grind
    grind

theorem rrf_outside_window (c : Rat) (window : Nat) (branches : List (List Nat)) (doc : Nat)
    (h : ∀ b ∈ branches, doc ∉ b.take (if window = 0 then b.length else window)) : rrfScore c window branches doc = 0 := by
  unfold rrfScore
  have : (rrfContribs c window branches).filter (fun p => p.1 = doc) = [] := by
    rw [List.filter_eq_nil_iff]
    intro p hp hpd
    unfold rrfContribs at hp
    simp only [List.mem_flatMap] at hp
    obtain ⟨b, hb, hq⟩ := hp
    simp only [decide_eq_true_eq] at hpd
    apply h b hb
    rw [← hpd]
    exact (mem_rankList c _ 0 p hq).1
  rw [this]; rfl

def ranksBefore (a b : Nat × Rat) : Prop := b.2 < a.2 ∨ (a.2 = b.2 ∧ a.1 < b.1)

theorem ranksBefore_irrefl (a : Nat × Rat) : ¬ ranksBefore a a := by
  unfold ranksBefore; intro h; rcases h with h | h; exact Rat.lt_irrefl h; omega

theorem ranksBefore_trans {a b c : Nat × Rat} (h1 : ranksBefore a b) (h2 : ranksBefore b c) : ranksBefore a c := by
  unfold ranksBefore at *
  rcases h1 with h1 | ⟨e1, h1⟩ <;> rcases h2 with h2 | ⟨e2, h2⟩
  · left; grind
  · left; rw [← e2]; exact h1
  · left; rw [e1]; exact h2
  · right; exact ⟨by rw [e1, e2], by omega⟩

theorem ranksBefore_total {a b : Nat × Rat} (h : a.1 ≠ b.1) : ranksBefore a b ∨ ranksBefore b a := by
  unfold ranksBefore
  rcases (Rat.le_total (a := a.2) (b := b.2)) with e | e
  · rcases (Rat.le_iff_lt_or_eq).1 e with e | e
    · right; left; exact e
    · rcases Nat.lt_or_gt_of_ne h with h' | h'
      · left; right; exact ⟨e, h'⟩
      · right; right; exact ⟨e.symm, h'⟩
  · rcases (Rat.le_iff_lt_or_eq).1 e with e | e
    · left; left; exact e
    · rcases Nat.lt_or_gt_of_ne h with h' | h'
      · left; right; exact ⟨e.symm, h'⟩
      · right; right; exact ⟨e, h'⟩

end Postings
