namespace Vectors

structure TotalLe {α : Type} (le : α → α → Bool) : Prop where
  trans : ∀ a b c, le a b = true → le b c = true → le a c = true
  total : ∀ a b, (le a b || le b a) = true
  antisymm : ∀ a b, le a b = true → le b a = true → a = b

section Merge
variable {α : Type}

def topk (le : α → α → Bool) (k : Nat) (l : List α) : List α := (l.mergeSort le).take k

def strictlyBefore [DecidableEq α] (le : α → α → Bool) (y x : α) : Bool := le y x && decide (y ≠ x)

def rankIn [DecidableEq α] (le : α → α → Bool) (l : List α) (x : α) : Nat := l.countP (strictlyBefore le · x)

def mergeTop (le : α → α → Bool) (k : Nat) (own : List (List α)) : List α := topk le k own.flatten

theorem le_refl_of_total {le : α → α → Bool} (h : TotalLe le) (a : α) : le a a = true := by
  have := h.total a a
  simp at this
  exact this

theorem sorted_take_mem [DecidableEq α] {le : α → α → Bool} (h : TotalLe le) :
    ∀ (l : List α) (k : Nat) (x : α), l.Pairwise (fun a b => le a b = true) → l.Nodup →
      (x ∈ l.take k ↔ x ∈ l ∧ rankIn le l x < k) := by
  intro l
  induction l with
  | nil => intro k x _ _; simp
  | cons a t ih =>
    intro k x hs hn
    rw [List.pairwise_cons] at hs
    rw [List.nodup_cons] at hn
    have hzero : rankIn le t a = 0 := by
      unfold rankIn
      rw [List.countP_eq_zero]
      intro y hy hb
      simp only [strictlyBefore, Bool.and_eq_true, decide_eq_true_eq] at hb
      have := h.antisymm y a hb.1 (hs.1 y hy)
      exact hb.2 this
    cases k with
    | zero => simp
    | succ k =>
      have hcons : rankIn le (a :: t) x = rankIn le t x + (if strictlyBefore le a x then 1 else 0) := by
        unfold rankIn
        rw [List.countP_cons]
      rw [List.take_succ_cons, hcons]
      by_cases hx : x = a
      · subst hx
        rw [hzero]
        simp [strictlyBefore]
      · have iht := ih k x hs.2 hn.2
        simp only [List.mem_cons, hx, false_or]
        by_cases hxt : x ∈ t
        · have hb : strictlyBefore le a x = true := by
            simp only [strictlyBefore, Bool.and_eq_true, decide_eq_true_eq]
            exact ⟨hs.1 x hxt, fun e => hx e.symm⟩
          rw [hb, iht]
          simp only [hxt, true_and, ite_true]
          omega
        · simp only [hxt, false_and, iff_false]
          intro hm
          exact hxt (List.mem_of_mem_take hm)

theorem mergeSort_nodup {le : α → α → Bool} (l : List α) (hn : l.Nodup) : (l.mergeSort le).Nodup :=
  (List.mergeSort_perm l le).symm.nodup hn

theorem mergeSort_sorted {le : α → α → Bool} (h : TotalLe le) (l : List α) :
    (l.mergeSort le).Pairwise (fun a b => le a b = true) :=
  List.pairwise_mergeSort (fun a b c hab hbc => h.trans a b c hab hbc) (fun a b => h.total a b) l

theorem rankIn_perm [DecidableEq α] {le : α → α → Bool} {l₁ l₂ : List α} (p : l₁.Perm l₂) (x : α) :
    rankIn le l₁ x = rankIn le l₂ x := p.countP_eq _

theorem topk_mem [DecidableEq α] {le : α → α → Bool} (h : TotalLe le) (k : Nat) (l : List α) (hn : l.Nodup) (x : α) :
    x ∈ topk le k l ↔ x ∈ l ∧ rankIn le l x < k := by
  unfold topk
  rw [sorted_take_mem h _ k x (mergeSort_sorted h l) (mergeSort_nodup l hn)]
  rw [rankIn_perm (List.mergeSort_perm l le) x, (List.mergeSort_perm l le).mem_iff]

theorem topk_sorted {le : α → α → Bool} (h : TotalLe le) (k : Nat) (l : List α) :
    (topk le k l).Pairwise (fun a b => le a b = true) :=
  (mergeSort_sorted h l).sublist (List.take_sublist k _)

theorem topk_nodup {le : α → α → Bool} (k : Nat) (l : List α) (hn : l.Nodup) : (topk le k l).Nodup :=
  (mergeSort_nodup l hn).sublist (List.take_sublist k _)

theorem topk_subset {le : α → α → Bool} (k : Nat) (l : List α) : ∀ x, x ∈ topk le k l → x ∈ l := by
  intro x hx
  exact (List.mergeSort_perm l le).mem_iff.mp (List.mem_of_mem_take hx)

theorem sorted_eq_of_mem {le : α → α → Bool} (h : TotalLe le) {l₁ l₂ : List α}
    (s₁ : l₁.Pairwise (fun a b => le a b = true)) (s₂ : l₂.Pairwise (fun a b => le a b = true))
    (n₁ : l₁.Nodup) (n₂ : l₂.Nodup) (hm : ∀ x, x ∈ l₁ ↔ x ∈ l₂) : l₁ = l₂ := by
  have p := (List.perm_ext_iff_of_nodup n₁ n₂).mpr hm
  exact List.Perm.eq_of_pairwise (fun a b _ _ hab hba => h.antisymm a b hab hba) s₁ s₂ p

theorem topk_before [DecidableEq α] {le : α → α → Bool} (h : TotalLe le) (k : Nat) (l : List α)
    (y z : α) (hy : y ∈ l) (hyt : y ∉ topk le k l) (hz : z ∈ topk le k l) :
    strictlyBefore le z y = true := by
  have hs := mergeSort_sorted h l
  have hsplit := List.take_append_drop k (l.mergeSort le)
  have hym : y ∈ l.mergeSort le := (List.mergeSort_perm l le).mem_iff.mpr hy
  have hyd : y ∈ (l.mergeSort le).drop k := by
    rw [← hsplit] at hym
    rcases List.mem_append.mp hym with h1 | h1
    · exact absurd h1 hyt
    · exact h1
  rw [← hsplit, List.pairwise_append] at hs
  have hzy := hs.2.2 z hz y hyd
  simp only [strictlyBefore, Bool.and_eq_true, decide_eq_true_eq]
  exact ⟨hzy, fun e => hyt (e ▸ hz)⟩

theorem topk_full {le : α → α → Bool} (k : Nat) (l : List α) (y : α) (hy : y ∈ l) (hyt : y ∉ topk le k l) :
    (topk le k l).length = k := by
  unfold topk
  rw [List.length_take]
  have hym : y ∈ l.mergeSort le := (List.mergeSort_perm l le).mem_iff.mpr hy
  have : k < (l.mergeSort le).length := by
    apply Nat.lt_of_not_le
    intro hc
    have : (l.mergeSort le).take k = l.mergeSort le := List.take_of_length_le hc
    unfold topk at hyt
    rw [this] at hyt
    exact hyt hym
  omega

theorem flatten_topk_nodup {le : α → α → Bool} (k : Nat) :
    ∀ (parts : List (List α)), parts.flatten.Nodup → (parts.map (topk le k)).flatten.Nodup := by
  intro parts
  induction parts with
  | nil => simp
  | cons p ps ih =>
    intro hn
    simp only [List.flatten_cons, List.map_cons] at hn ⊢
    rw [List.nodup_append] at hn ⊢
    refine ⟨topk_nodup k p hn.1, ih hn.2.1, ?_⟩
    intro a ha b hb
    apply hn.2.2 a (topk_subset k p a ha) b
    rcases List.mem_flatten.mp hb with ⟨q, hq, hbq⟩
    rcases List.mem_map.mp hq with ⟨r, hr, rfl⟩
    exact List.mem_flatten.mpr ⟨r, hr, topk_subset k r b hbq⟩

theorem flatten_topk_subset {le : α → α → Bool} (k : Nat) (parts : List (List α)) :
    ∀ x, x ∈ (parts.map (topk le k)).flatten → x ∈ parts.flatten := by
  intro x hx
  rcases List.mem_flatten.mp hx with ⟨q, hq, hxq⟩
  rcases List.mem_map.mp hq with ⟨r, hr, rfl⟩
  exact List.mem_flatten.mpr ⟨r, hr, topk_subset k r x hxq⟩

theorem countP_flatten_topk_le {le : α → α → Bool} (k : Nat) (q : α → Bool) :
    ∀ (parts : List (List α)), ((parts.map (topk le k)).flatten).countP q ≤ parts.flatten.countP q := by
  intro parts
  induction parts with
  | nil => simp
  | cons p ps ih =>
    simp only [List.flatten_cons, List.map_cons, List.countP_append]
    have h1 : (topk le k p).countP q ≤ p.countP q := by
      unfold topk
      calc ((p.mergeSort le).take k).countP q ≤ (p.mergeSort le).countP q := (List.take_sublist k _).countP_le
        _ = p.countP q := (List.mergeSort_perm p le).countP_eq q
    omega

theorem merge_exact [DecidableEq α] {le : α → α → Bool} (h : TotalLe le) (k : Nat) (parts : List (List α))
    (hn : parts.flatten.Nodup) :
    mergeTop le k (parts.map (topk le k)) = topk le k parts.flatten := by
  unfold mergeTop
  have hTn := flatten_topk_nodup (le := le) k parts hn
  apply sorted_eq_of_mem h (topk_sorted h k _) (topk_sorted h k _) (topk_nodup k _ hTn) (topk_nodup k _ hn)
  intro x
  rw [topk_mem h k _ hTn, topk_mem h k _ hn]
  constructor
  · intro ⟨hxT, hr⟩
    refine ⟨flatten_topk_subset k parts x hxT, ?_⟩
    have hcover : ∀ y, y ∈ parts.flatten → strictlyBefore le y x = true →
        y ∈ (parts.map (topk le k)).flatten := by
      intro y hy hb
      rcases List.mem_flatten.mp hy with ⟨p, hp, hyp⟩
      have hpn : p.Nodup := hn.sublist (List.sublist_flatten_of_mem hp)
      by_cases hyt : y ∈ topk le k p
      · exact List.mem_flatten.mpr ⟨topk le k p, List.mem_map.mpr ⟨p, hp, rfl⟩, hyt⟩
      · exfalso
        have hall : ∀ z, z ∈ topk le k p → strictlyBefore le z x = true := by
          intro z hz
          have hzy := topk_before h k p y z hyp hyt hz
          simp only [strictlyBefore, Bool.and_eq_true, decide_eq_true_eq] at hzy hb ⊢
          refine ⟨h.trans z y x hzy.1 hb.1, ?_⟩
          intro e
          subst e
          exact hb.2 (h.antisymm y z hb.1 hzy.1)
        have hcount : (topk le k p).countP (strictlyBefore le · x) = k := by
          rw [List.countP_eq_length.mpr hall]
          exact topk_full k p y hyp hyt
        have hsub : List.Sublist (topk le k p) (parts.map (topk le k)).flatten :=
          List.sublist_flatten_of_mem (List.mem_map.mpr ⟨p, hp, rfl⟩)
        have := hsub.countP_le (p := (strictlyBefore le · x))
        unfold rankIn at hr
        omega
    have hle : rankIn le parts.flatten x ≤ rankIn le (parts.map (topk le k)).flatten x := by
      unfold rankIn
      rw [List.countP_eq_length_filter, List.countP_eq_length_filter]
      apply List.Nodup.length_le_of_subset (hn.sublist List.filter_sublist)
      intro y hy
      rw [List.mem_filter] at hy ⊢
      exact ⟨hcover y hy.1 hy.2, hy.2⟩
    omega
  · intro ⟨hxU, hr⟩
    rcases List.mem_flatten.mp hxU with ⟨p, hp, hxp⟩
    have hpn : p.Nodup := hn.sublist (List.sublist_flatten_of_mem hp)
    have hrp : rankIn le p x ≤ rankIn le parts.flatten x :=
      (List.sublist_flatten_of_mem hp).countP_le
    have hxtop : x ∈ topk le k p := (topk_mem h k p hpn x).mpr ⟨hxp, by omega⟩
    refine ⟨List.mem_flatten.mpr ⟨topk le k p, List.mem_map.mpr ⟨p, hp, rfl⟩, hxtop⟩, ?_⟩
    have := countP_flatten_topk_le (le := le) k (strictlyBefore le · x) parts
    unfold rankIn at hr hrp ⊢
    omega

theorem topk_min_length {le : α → α → Bool} (k : Nat) (l : List α) :
    topk le (min k l.length) l = topk le k l := by
  unfold topk
  have hlen : (l.mergeSort le).length = l.length := (List.mergeSort_perm l le).length_eq
  by_cases hk : k ≤ l.length
  · rw [Nat.min_eq_left hk]
  · rw [Nat.min_eq_right (by omega), List.take_of_length_le (by omega), List.take_of_length_le (by omega)]

theorem topk_of_sorted {le : α → α → Bool} (k : Nat) (l : List α)
    (hs : l.Pairwise (fun a b => le a b = true)) (hk : l.length ≤ k) : topk le k l = l := by
  unfold topk
  have : List.mergeSort l le = l := List.mergeSort_of_pairwise hs
  rw [this, List.take_of_length_le hk]

theorem flatten_map_filter (f : α → Bool) :
    ∀ (parts : List (List α)), (parts.map (List.filter f)).flatten = parts.flatten.filter f := by
  intro parts
  induction parts with
  | nil => simp
  | cons p ps ih => rw [List.map_cons, List.flatten_cons, List.flatten_cons, List.filter_append, ih]

theorem merge_filter_exact [DecidableEq α] {le : α → α → Bool} (h : TotalLe le) (k : Nat) (f : α → Bool)
    (parts : List (List α)) (hn : parts.flatten.Nodup) :
    mergeTop le k (parts.map (fun p => topk le k (p.filter f))) = topk le k (parts.flatten.filter f) := by
  have hfn : (parts.map (List.filter f)).flatten.Nodup := by
    rw [flatten_map_filter]
    exact hn.sublist List.filter_sublist
  have := merge_exact h k (parts.map (List.filter f)) hfn
  rw [List.map_map, flatten_map_filter] at this
  exact this

theorem merge_truth [DecidableEq α] {le : α → α → Bool} (h : TotalLe le) (k : Nat)
    (parts : List (List α)) (hn : parts.flatten.Nodup) :
    mergeTop le k (parts.map (fun p => topk le (min k p.length) p)) = topk le k parts.flatten := by
  have : parts.map (fun p => topk le (min k p.length) p) = parts.map (topk le k) :=
    List.map_congr_left (fun p _ => topk_min_length k p)
  rw [this]
  exact merge_exact h k parts hn

theorem merge_epsilon [DecidableEq α] {le : α → α → Bool} (h : TotalLe le) (k : Nat) (keep : α → Bool)
    (parts : List (List α)) (hn : parts.flatten.Nodup) :
    (mergeTop le k (parts.map (topk le k))).filter keep = (topk le k parts.flatten).filter keep := by
  rw [merge_exact h k parts hn]

structure OwnResult {α : Type} (le : α → α → Bool) (k : Nat) (p o : List α) : Prop where
  subset : ∀ x, x ∈ o → x ∈ p
  sorted : o.Pairwise (fun a b => le a b = true)
  nodup : o.Nodup
  short : o.length ≤ k

def contributes {α : Type} (exact : Bool) (p o : List α) : List α :=
  if exact then p else o

theorem merge_relative [DecidableEq α] {le : α → α → Bool} (h : TotalLe le) (k : Nat)
    (parts : List (Bool × List α × List α))
    (hown : ∀ e ∈ parts, (e.1 = true → e.2.2 = topk le k e.2.1) ∧ (e.1 = false → OwnResult le k e.2.1 e.2.2))
    (hn : (parts.map (fun e => e.2.1)).flatten.Nodup) :
    mergeTop le k (parts.map (fun e => e.2.2)) =
      topk le k (parts.map (fun e => contributes e.1 e.2.1 e.2.2)).flatten := by
  have hsub : ∀ e ∈ parts, ∀ x, x ∈ contributes e.1 e.2.1 e.2.2 → x ∈ e.2.1 := by
    intro e he x hx
    unfold contributes at hx
    cases hb : e.1
    · rw [hb] at hx
      exact ((hown e he).2 hb).subset x hx
    · rw [hb] at hx
      exact hx
  have hcn : (parts.map (fun e => contributes e.1 e.2.1 e.2.2)).flatten.Nodup := by
    revert hn hsub hown
    induction parts with
    | nil => intros; simp
    | cons e es ih =>
      intro hown hn hsub
      simp only [List.map_cons, List.flatten_cons] at hn ⊢
      rw [List.nodup_append] at hn ⊢
      have hen : (contributes e.1 e.2.1 e.2.2).Nodup := by
        unfold contributes
        cases hb : e.1
        · exact ((hown e (List.mem_cons_self ..)).2 hb).nodup
        · exact hn.1
      refine ⟨hen, ih (fun x hx => hown x (List.mem_cons_of_mem e hx)) hn.2.1
        (fun x hx => hsub x (List.mem_cons_of_mem e hx)), ?_⟩
      intro a ha b hb
      apply hn.2.2 a (hsub e (List.mem_cons_self ..) a ha) b
      rcases List.mem_flatten.mp hb with ⟨q, hq, hbq⟩
      rcases List.mem_map.mp hq with ⟨r, hr, rfl⟩
      exact List.mem_flatten.mpr ⟨r.2.1, List.mem_map.mpr ⟨r, hr, rfl⟩,
        hsub r (List.mem_cons_of_mem e hr) b hbq⟩
  have hparts : parts.map (fun e => e.2.2) =
      (parts.map (fun e => contributes e.1 e.2.1 e.2.2)).map (topk le k) := by
    rw [List.map_map]
    apply List.map_congr_left
    intro e he
    simp only [Function.comp]
    unfold contributes
    cases hb : e.1
    · have o := (hown e he).2 hb
      exact (topk_of_sorted k e.2.2 o.sorted o.short).symm
    · exact (hown e he).1 hb
  rw [hparts]
  exact merge_exact h k _ hcn

end Merge

def scoreBefore : Option Int → Option Int → Bool
  | some x, some y => decide (x > y)
  | some _, none => true
  | none, _ => false

def nameLt : List Nat → List Nat → Bool
  | [], [] => false
  | [], _ :: _ => true
  | _ :: _, [] => false
  | a :: as, b :: bs => decide (a < b) || (decide (a = b) && nameLt as bs)

def hitLe (a b : Option Int × List Nat) : Bool :=
  scoreBefore a.1 b.1 || (decide (a.1 = b.1) && (nameLt a.2 b.2 || decide (a.2 = b.2)))

theorem nameLt_irrefl : ∀ (a : List Nat), nameLt a a = false := by
  intro a
  induction a with
  | nil => rfl
  | cons x xs ih => simp [nameLt, ih]

theorem nameLt_trans : ∀ (a b c : List Nat), nameLt a b = true → nameLt b c = true → nameLt a c = true := by
  intro a
  induction a with
  | nil =>
    intro b c hab hbc
    cases b <;> cases c <;> simp_all [nameLt]
  | cons x xs ih =>
    intro b c hab hbc
    cases b with
    | nil => simp [nameLt] at hab
    | cons y ys =>
      cases c with
      | nil => simp [nameLt] at hbc
      | cons z zs =>
        simp only [nameLt, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hab hbc ⊢
        rcases hab with h1 | ⟨h1, h2⟩ <;> rcases hbc with h3 | ⟨h3, h4⟩
        · left; omega
        · left; omega
        · left; omega
        · right; exact ⟨by omega, ih ys zs h2 h4⟩

theorem nameLt_total : ∀ (a b : List Nat), a ≠ b → nameLt a b = true ∨ nameLt b a = true := by
  intro a
  induction a with
  | nil =>
    intro b hb
    cases b with
    | nil => exact absurd rfl hb
    | cons y ys => left; rfl
  | cons x xs ih =>
    intro b hb
    cases b with
    | nil => right; rfl
    | cons y ys =>
      simp only [nameLt, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
      by_cases hxy : x = y
      · subst hxy
        have hne : xs ≠ ys := fun e => hb (e ▸ rfl)
        rcases ih ys hne with h | h
        · left; right; exact ⟨rfl, h⟩
        · right; right; exact ⟨rfl, h⟩
      · omega

theorem nameLt_asymm (a b : List Nat) (h : nameLt a b = true) : nameLt b a = false := by
  cases hba : nameLt b a
  · rfl
  · have := nameLt_trans a b a h hba
    rw [nameLt_irrefl] at this
    exact absurd this (by decide)

theorem scoreBefore_irrefl : ∀ (a : Option Int), scoreBefore a a = false := by
  intro a
  cases a <;> simp [scoreBefore]

theorem scoreBefore_trans : ∀ (a b c : Option Int), scoreBefore a b = true → scoreBefore b c = true → scoreBefore a c = true := by
  intro a b c hab hbc
  cases a <;> cases b <;> cases c <;> simp_all [scoreBefore] <;> omega

theorem scoreBefore_total : ∀ (a b : Option Int), a ≠ b → scoreBefore a b = true ∨ scoreBefore b a = true := by
  intro a b h
  cases a <;> cases b <;> simp_all [scoreBefore] <;> omega

theorem hitLe_total_order : TotalLe hitLe := by
  refine ⟨?_, ?_, ?_⟩
  · intro a b c hab hbc
    simp only [hitLe, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hab hbc ⊢
    rcases hab with h1 | ⟨h1, h2⟩ <;> rcases hbc with h3 | ⟨h3, h4⟩
    · left; exact scoreBefore_trans _ _ _ h1 h3
    · left; rw [← h3]; exact h1
    · left; rw [h1]; exact h3
    · right
      refine ⟨h1.trans h3, ?_⟩
      rcases h2 with h2 | h2 <;> rcases h4 with h4 | h4
      · left; exact nameLt_trans _ _ _ h2 h4
      · left; rw [← h4]; exact h2
      · left; rw [h2]; exact h4
      · right; exact h2.trans h4
  · intro a b
    simp only [hitLe, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
    by_cases hs : a.1 = b.1
    · by_cases hn : a.2 = b.2
      · left; right; exact ⟨hs, Or.inr hn⟩
      · rcases nameLt_total a.2 b.2 hn with h | h
        · left; right; exact ⟨hs, Or.inl h⟩
        · right; right; exact ⟨hs.symm, Or.inl h⟩
    · rcases scoreBefore_total a.1 b.1 hs with h | h
      · left; left; exact h
      · right; left; exact h
  · intro a b hab hba
    simp only [hitLe, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hab hba
    rcases hab with h1 | ⟨h1, h2⟩
    · rcases hba with h3 | ⟨h3, _⟩
      · have := scoreBefore_trans _ _ _ h1 h3
        rw [scoreBefore_irrefl] at this
        exact absurd this (by decide)
      · rw [h3, scoreBefore_irrefl] at h1
        exact absurd h1 (by decide)
    · rcases hba with h3 | ⟨_, h4⟩
      · rw [h1, scoreBefore_irrefl] at h3
        exact absurd h3 (by decide)
      · rcases h2 with h2 | h2
        · rcases h4 with h4 | h4
          · rw [nameLt_asymm _ _ h2] at h4
            exact absurd h4 (by decide)
          · rw [h4, nameLt_irrefl] at h2
            exact absurd h2 (by decide)
        · exact Prod.ext h1 h2

theorem hit_merge_exact (k : Nat) (parts : List (List (Option Int × List Nat))) (hn : parts.flatten.Nodup) :
    mergeTop hitLe k (parts.map (topk hitLe k)) = topk hitLe k parts.flatten :=
  merge_exact hitLe_total_order k parts hn

end Vectors
