import Storage.Table

namespace Storage

theorem widen_power (fuel p groups : Nat) (h : ∃ m, p = 2 ^ m) :
    ∃ m, widen fuel p groups = 2 ^ m := by
  induction fuel generalizing p with
  | zero => simpa [widen] using h
  | succ fuel ih =>
    obtain ⟨m, rfl⟩ := h
    simp only [widen]
    split
    · exact ih _ ⟨m + 1, by rw [Nat.pow_succ]⟩
    · exact ⟨m, rfl⟩

theorem widen_covers (fuel p groups : Nat) (hp : 1 ≤ p) (h : groups ≤ p + fuel) :
    groups ≤ widen fuel p groups := by
  induction fuel generalizing p with
  | zero => simpa [widen] using h
  | succ fuel ih =>
    simp only [widen]
    split
    · exact ih _ (by omega) (by omega)
    · omega

theorem probe_span_power (groups : Nat) : ∃ m, probeSpan groups = 2 ^ m :=
  widen_power groups 1 groups ⟨0, rfl⟩

theorem probe_span_covers (groups : Nat) : groups ≤ probeSpan groups :=
  widen_covers groups 1 groups (Nat.le_refl 1) (by omega)

theorem walk_closed_form (groups home m : Nat) : ∀ n k,
    walkFrom groups (2 ^ m - 1) n ((home + tri k) % 2 ^ m) k =
      ((List.range' k n).map fun j => (home + tri j) % 2 ^ m).filter (· < groups) := by
  intro n
  induction n with
  | zero => intro k; simp [walkFrom]
  | succ n ih =>
    intro k
    have step : ((home + tri k) % 2 ^ m + (k + 1)) &&& (2 ^ m - 1) = (home + tri (k + 1)) % 2 ^ m := by
      rw [Nat.and_two_pow_sub_one_eq_mod, Nat.mod_add_mod]
      simp only [tri, Nat.add_assoc]
    simp only [walkFrom, List.range'_succ, List.map_cons, List.filter_cons]
    rw [step, ih (k + 1)]
    by_cases hc : (home + tri k) % 2 ^ m < groups <;> simp [hc]

theorem probe_closed_form (groups home : Nat) (hh : home < probeSpan groups) :
    probeGroups groups home =
      ((List.range (probeSpan groups)).map fun k => (home + tri k) % probeSpan groups).filter (· < groups) := by
  obtain ⟨m, hm⟩ := probe_span_power groups
  have start : home = (home + tri 0) % 2 ^ m := by
    rw [hm] at hh
    simp [tri, Nat.mod_eq_of_lt hh]
  unfold probeGroups
  rw [hm, List.range_eq_range']
  conv => lhs; rw [start]
  exact walk_closed_form groups home m (2 ^ m) 0

theorem tri_add (a b : Nat) : tri (a + b) = tri a + tri b + a * b := by
  induction b with
  | zero => simp [tri]
  | succ b ih =>
    rw [← Nat.add_assoc, tri, ih, tri, Nat.mul_add_one]
    omega

theorem tri_double (k : Nat) : 2 * tri k = k * k + k := by
  induction k with
  | zero => simp [tri]
  | succ k ih =>
    simp only [tri, Nat.add_mul, Nat.mul_add, Nat.mul_one, Nat.one_mul]
    omega

theorem tri_reflect (k k' h : Nat) (sum : k + k' + 1 = h + h) :
    tri k' + h * 2 * (k + 1) = tri k + h + h * 2 * h := by
  have whole := tri_add k' (k + 1)
  have hsum : k' + (k + 1) = h + h := by omega
  rw [hsum, tri_add h h] at whole
  have dh := tri_double h
  have dk := tri_double k
  have prod : (k + k' + 1) * k = (h + h) * k := by rw [sum]
  simp only [Nat.add_mul, Nat.one_mul] at prod
  have next : tri (k + 1) = tri k + (k + 1) := rfl
  have left : h * 2 * (k + 1) = h * k + h * k + h + h := by
    rw [Nat.mul_right_comm, Nat.mul_add h k 1, Nat.mul_one]; omega
  have right : h * 2 * h = h * h + h * h := by
    rw [Nat.mul_right_comm]; omega
  have cross : k' * (k + 1) = k' * k + k' := Nat.mul_add_one k' k
  rw [left, right]
  rw [next, cross] at whole
  omega

theorem tri_mod_surjective (m : Nat) : ∀ t, t < 2 ^ m → ∃ k, k < 2 ^ m ∧ tri k % 2 ^ m = t := by
  induction m with
  | zero =>
    intro t ht
    refine ⟨0, by simp, ?_⟩
    simp at ht
    simp [ht, tri]
  | succ m ih =>
    intro t ht
    have hH : 0 < 2 ^ m := Nat.two_pow_pos m
    have hN : 2 ^ (m + 1) = 2 ^ m * 2 := Nat.pow_succ 2 m
    rw [hN] at ht ⊢
    obtain ⟨k, hk, hmod⟩ := ih (t % 2 ^ m) (Nat.mod_lt _ hH)
    have hdvd : 2 ^ m ∣ 2 ^ m * 2 := ⟨2, rfl⟩
    have rlow : tri k % (2 ^ m * 2) % 2 ^ m = t % 2 ^ m := by
      rw [Nat.mod_mod_of_dvd _ hdvd, hmod]
    have rlt : tri k % (2 ^ m * 2) < 2 ^ m * 2 := Nat.mod_lt _ (by omega)
    generalize hr : tri k % (2 ^ m * 2) = r at rlow rlt
    generalize hH' : 2 ^ m = H at hH hk rlow rlt ht hr ⊢
    have rsplit := Nat.mod_add_div r H
    have tsplit := Nat.mod_add_div t H
    have rq : r / H < 2 := (Nat.div_lt_iff_lt_mul hH).mpr (by omega)
    have tq : t / H < 2 := (Nat.div_lt_iff_lt_mul hH).mpr (by omega)
    have rl := Nat.mod_lt r hH
    generalize r % H = r1 at rsplit rlow rl
    generalize t % H = t1 at tsplit rlow
    generalize r / H = q1 at rsplit rq
    generalize t / H = q2 at tsplit tq
    by_cases same : r = t
    · exact ⟨k, by omega, by rw [hr, same]⟩
    · refine ⟨H * 2 - 1 - k, by omega, ?_⟩
      have mirror := tri_reflect k (H * 2 - 1 - k) H (by omega)
      have shift : tri (H * 2 - 1 - k) % (H * 2) = (r + H) % (H * 2) := by
        have a : (tri (H * 2 - 1 - k) + H * 2 * (k + 1)) % (H * 2) = tri (H * 2 - 1 - k) % (H * 2) :=
          Nat.add_mul_mod_self_left _ _ _
        have b : (tri k + H + H * 2 * H) % (H * 2) = (tri k + H) % (H * 2) :=
          Nat.add_mul_mod_self_left _ _ _
        rw [← a, mirror, b, ← Nat.mod_add_mod, hr]
      rw [shift]
      rcases (show q1 = 0 ∨ q1 = 1 by omega) with r0 | r0 <;>
        rcases (show q2 = 0 ∨ q2 = 1 by omega) with t0 | t0 <;>
        subst r0 <;> subst t0 <;> simp only [Nat.mul_zero, Nat.mul_one, Nat.add_zero] at rsplit tsplit
      · omega
      · rw [Nat.mod_eq_of_lt (by omega)]
        omega
      · have e : r + H = r1 + H * 2 := by omega
        rw [e, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega)]
        omega
      · omega

theorem probe_reaches_every_group (groups home g : Nat) (hh : home < groups) (hg : g < groups) :
    g ∈ probeGroups groups home := by
  have cover := probe_span_covers groups
  rw [probe_closed_form groups home (by omega)]
  obtain ⟨m, hm⟩ := probe_span_power groups
  rw [hm]
  rw [hm] at cover
  have hP : 0 < 2 ^ m := Nat.two_pow_pos m
  obtain ⟨k, hk, ht⟩ := tri_mod_surjective m ((g + (2 ^ m - home)) % 2 ^ m) (Nat.mod_lt _ hP)
  apply List.mem_filter.mpr
  refine ⟨List.mem_map.mpr ⟨k, List.mem_range.mpr hk, ?_⟩, by simpa using hg⟩
  rw [← Nat.add_mod_mod, ht, Nat.add_mod_mod]
  have e : home + (g + (2 ^ m - home)) = g + 2 ^ m := by omega
  rw [e, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega)]

theorem probe_groups_bounded (groups home g : Nat) (h : g ∈ probeGroups groups home) (hh : home < groups) :
    g < groups := by
  have cover := probe_span_covers groups
  rw [probe_closed_form groups home (by omega)] at h
  simpa using (List.mem_filter.mp h).2

theorem hash_home_bounded (h groups : Nat) (pos : 0 < groups) : hashHome h groups < groups := by
  unfold hashHome
  have hw : 0 < wordSpan := by decide
  have hm := Nat.mod_lt h hw
  apply (Nat.div_lt_iff_lt_mul hw).mpr
  rw [Nat.mul_comm groups wordSpan]
  exact Nat.mul_lt_mul_of_pos_right hm pos

theorem group_index_member (i : Nat) : i ∈ groupIndices (i / 16) := by
  apply List.mem_map.mpr
  exact ⟨i % 16, List.mem_range.mpr (Nat.mod_lt _ (by decide)), by omega⟩

theorem claim_some_of_free (xs : List Cell) (hash i : Nat) (whole : xs.length % 16 = 0)
    (inside : i < xs.length) (free : freeAt xs i = true) :
    ∃ j, claimIndex xs hash = some j := by
  have pos : 0 < groupsOf xs := by unfold groupsOf; omega
  have hg : i / 16 < groupsOf xs := by unfold groupsOf; omega
  have reach := probe_reaches_every_group (groupsOf xs) (hashHome hash (groupsOf xs)) (i / 16)
    (hash_home_bounded hash _ pos) hg
  have member : i ∈ candidates xs hash :=
    List.mem_flatMap.mpr ⟨i / 16, reach, group_index_member i⟩
  cases hc : claimIndex xs hash with
  | some j => exact ⟨j, rfl⟩
  | none =>
    have hn := List.find?_eq_none.mp hc i member
    simp [free] at hn

end Storage
