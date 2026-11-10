import Labels.MarkingTrust
import Labels.Intern

namespace Labels

def codecMagic : List Nat := [69, 83, 76, 84]

def codecVersion : Nat := 2

def codecUntrusted : Nat := 1

def u16 (v : Nat) : List Nat := [v % 256, v / 256]

def encName (n : List Nat) : List Nat := n.length :: n

def encNames (ns : List (List Nat)) : List Nat := u16 ns.length ++ (ns.map encName).flatten

def encLabel (l : TLabel) : List Nat :=
  l.sec.level :: l.trust :: (u16 (idsOf l.sec.comps compLimit).length ++ idsOf l.sec.comps compLimit)

def encode (c : TConfig) (t : List TLabel) : List Nat :=
  codecMagic ++ [codecVersion] ++ encNames c.base.levels ++ encNames c.base.comps ++ encNames c.trusts ++
    u16 t.length ++ (t.map encLabel).flatten

def encodeChecked (c : TConfig) (t : List TLabel) : Option (List Nat) :=
  if t.head? = some tbottom ∧ t.all (labelValidT c) = true then some (encode c t) else none

inductive DErr
  | truncated
  | badMagic
  | badVersion
  | badLevelCount
  | badCompCount
  | badTrustCount
  | badName
  | dupName
  | badLabelCount
  | badLevel
  | badTrust
  | badComp
  | notBottom
  | dupLabel
  | trailing
deriving DecidableEq, Repr

def readU16 : List Nat → Option (Nat × List Nat)
  | a :: b :: rest => some (a + 256 * b, rest)
  | _ => none

def readName (used : List (List Nat)) : List Nat → Except DErr (List Nat × List Nat)
  | [] => .error .truncated
  | len :: rest =>
    if rest.length < len then .error .truncated
    else if !nameCanonical (rest.take len) then .error .badName
    else if rest.take len ∈ used then .error .dupName
    else .ok (rest.take len, rest.drop len)

def readNames : Nat → List (List Nat) → List Nat → Except DErr (List (List Nat) × List Nat)
  | 0, _, s => .ok ([], s)
  | k + 1, used, s =>
    match readName used s with
    | .error e => .error e
    | .ok (n, s') =>
      match readNames k (used ++ [n]) s' with
      | .error e => .error e
      | .ok (ns, s'') => .ok (n :: ns, s'')

def idsOk (C : Nat) : Nat → List Nat → Bool
  | _, [] => true
  | lo, x :: xs => decide (x < C) && decide (lo ≤ x) && idsOk C (x + 1) xs

def readTrust (wide : Bool) (T : Nat) (s : List Nat) : Except DErr (Nat × List Nat) :=
  if wide then
    match s with
    | [] => .error .truncated
    | t :: rest => if trustCount T ≤ t then .error .badTrust else .ok (t, rest)
  else .ok (0, s)

def readLabels (L C T : Nat) (wide : Bool) : Nat → Bool → List TLabel → List Nat → Except DErr (List TLabel × List Nat)
  | 0, _, acc, s => .ok (acc, s)
  | k + 1, first, acc, s =>
    match s with
    | [] => .error .truncated
    | lv :: s0 =>
      if L ≤ lv then .error .badLevel
      else match readTrust wide T s0 with
      | .error e => .error e
      | .ok (tr, s1) =>
        match readU16 s1 with
        | none => .error .truncated
        | some (n, s2) =>
          if C < n then .error .badComp
          else if s2.length < n then .error .truncated
          else if !idsOk C 0 (s2.take n) then .error .badComp
          else if first then
            (if (⟨⟨lv, ofIds (s2.take n)⟩, tr⟩ : TLabel) ≠ tbottom then .error .notBottom
             else readLabels L C T wide k false acc (s2.drop n))
          else if (⟨⟨lv, ofIds (s2.take n)⟩, tr⟩ : TLabel) ∈ acc then .error .dupLabel
          else readLabels L C T wide k false (acc ++ [⟨⟨lv, ofIds (s2.take n)⟩, tr⟩]) (s2.drop n)

def readTrustNames (wide : Bool) (s : List Nat) : Except DErr (List (List Nat) × List Nat) :=
  if wide then
    match readU16 s with
    | none => .error .truncated
    | some (T, s) => if trustLimit < T then .error .badTrustCount else readNames T [] s
  else .ok ([], s)

def decode (s : List Nat) : Except DErr (TConfig × List TLabel) :=
  if s.length < 4 then .error .truncated
  else if s.take 4 ≠ codecMagic then .error .badMagic
  else match s.drop 4 with
  | [] => .error .truncated
  | v :: s =>
    if v ≠ codecVersion ∧ v ≠ codecUntrusted then .error .badVersion
    else match readU16 s with
    | none => .error .truncated
    | some (L, s) =>
      if L = 0 ∨ levelLimit < L then .error .badLevelCount
      else match readNames L [] s with
      | .error e => .error e
      | .ok (levels, s) =>
        match readU16 s with
        | none => .error .truncated
        | some (C, s) =>
          if compLimit < C then .error .badCompCount
          else match readNames C levels s with
          | .error e => .error e
          | .ok (comps, s) =>
            match readTrustNames (v == codecVersion) s with
            | .error e => .error e
            | .ok (trusts, s) =>
              match readU16 s with
              | none => .error .truncated
              | some (n, s) =>
                if n = 0 then .error .badLabelCount
                else match readLabels L C trusts.length (v == codecVersion) n true [tbottom] s with
                | .error e => .error e
                | .ok (labels, s) => if s ≠ [] then .error .trailing else .ok (⟨⟨levels, comps⟩, trusts⟩, labels)

def TableValid (c : TConfig) (t : List TLabel) : Prop := TableOk t ∧ ∀ l ∈ t, LabelOkT c l

theorem readU16_u16 (v : Nat) (rest : List Nat) : readU16 (u16 v ++ rest) = some (v, rest) := by
  simp only [u16, List.cons_append, List.nil_append, readU16, Option.some.injEq, Prod.mk.injEq, and_true]
  omega

theorem readName_enc (used : List (List Nat)) (n rest : List Nat) (hc : nameCanonical n = true) (hu : n ∉ used) :
    readName used (encName n ++ rest) = .ok (n, rest) := by
  simp only [encName, List.cons_append, readName]
  have h2 : (n ++ rest).take n.length = n := by simp
  have h3 : (n ++ rest).drop n.length = rest := by simp
  simp [h2, h3, hc, hu]

theorem readNames_enc (ns : List (List Nat)) (used : List (List Nat)) (rest : List Nat)
    (hc : ∀ n ∈ ns, nameCanonical n = true) (hn : (used ++ ns).Nodup) :
    readNames ns.length used ((ns.map encName).flatten ++ rest) = .ok (ns, rest) := by
  induction ns generalizing used with
  | nil => rfl
  | cons n ns ih =>
    simp only [List.length_cons, List.map_cons, List.flatten_cons, List.append_assoc, readNames]
    have hnu : n ∉ used := by
      intro hm
      rw [List.nodup_append] at hn
      exact hn.2.2 n hm n List.mem_cons_self rfl
    rw [readName_enc used n _ (hc n List.mem_cons_self) hnu]
    simp only
    rw [ih (used ++ [n]) (fun m hm => hc m (List.mem_cons_of_mem _ hm)) (by simpa using hn)]

theorem idsOk_range' {C : Nat} : ∀ (lo n : Nat) (m : Nat), lo + n ≤ C →
    idsOk C lo ((List.range' lo n).filter (m.testBit ·)) = true := by
  intro lo n
  induction n generalizing lo with
  | zero => intro m _; rfl
  | succ n ih =>
    intro m hle
    rw [List.range'_succ, List.filter_cons]
    split
    · simp only [idsOk, Bool.and_eq_true, decide_eq_true_eq]
      exact ⟨⟨by omega, Nat.le_refl _⟩, ih (lo + 1) m (by omega)⟩
    · have := ih (lo + 1) m (by omega)
      exact idsOk_mono this (Nat.le_succ lo)
where
  idsOk_mono {C a b : Nat} {xs : List Nat} (hx : idsOk C a xs = true) (hab : b ≤ a) : idsOk C b xs = true := by
    cases xs with
    | nil => rfl
    | cons x xs =>
      simp only [idsOk, Bool.and_eq_true, decide_eq_true_eq] at hx ⊢
      exact ⟨⟨hx.1.1, Nat.le_trans hab hx.1.2⟩, hx.2⟩

theorem idsOf_restrict {C : Nat} (m : Nat) (hC : C ≤ compLimit) (hm : m < 2 ^ C) :
    idsOf m compLimit = idsOf m C := by
  unfold idsOf
  have hsplit : List.range compLimit = List.range C ++ List.range' C (compLimit - C) := by
    rw [List.range_eq_range', List.range_eq_range']
    rw [show compLimit = C + (compLimit - C) by omega]
    rw [← List.range'_append]
    simp
  rw [hsplit, List.filter_append]
  have : (List.range' C (compLimit - C)).filter (m.testBit ·) = [] := by
    rw [List.filter_eq_nil_iff]
    intro j hj
    simp only [List.mem_range'_1] at hj
    rw [Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le hm (Nat.pow_le_pow_right (by decide) hj.1))]
    simp
  rw [this, List.append_nil]

theorem idsOk_idsOf {C : Nat} (m : Nat) (hC : C ≤ compLimit) (hm : m < 2 ^ C) : idsOk C 0 (idsOf m compLimit) = true := by
  rw [idsOf_restrict m hC hm]
  unfold idsOf
  rw [List.range_eq_range']
  exact idsOk_range' 0 C m (by omega)

theorem idsOf_below {m C : Nat} (hC : C ≤ compLimit) (hm : m < 2 ^ C) : (idsOf m compLimit).length ≤ C := by
  rw [idsOf_restrict m hC hm]
  exact idsOf_length m C

theorem comps_fit {c : TConfig} (hc : TConfigOk c) {l : TLabel} (hl : LabelOkT c l) : l.sec.comps < 2 ^ compLimit :=
  Nat.lt_of_lt_of_le hl.1.2 (Nat.pow_le_pow_right (by decide) hc.1.1.2.1)

theorem readLabel_step (c : TConfig) (hc : TConfigOk c) (l : TLabel) (hl : LabelOkT c l) (first : Bool) (k : Nat)
    (acc : List TLabel) (rest : List Nat) :
    readLabels c.base.levels.length c.base.comps.length c.trusts.length true (k + 1) first acc (encLabel l ++ rest) =
      if first then
        (if l ≠ tbottom then .error .notBottom
         else readLabels c.base.levels.length c.base.comps.length c.trusts.length true k false acc rest)
      else if l ∈ acc then .error .dupLabel
      else readLabels c.base.levels.length c.base.comps.length c.trusts.length true k false (acc ++ [l]) rest := by
  have hlen := idsOf_below hc.1.1.2.1 hl.1.2
  have hok := idsOk_idsOf l.sec.comps hc.1.1.2.1 hl.1.2
  have hof : (⟨⟨l.sec.level, ofIds (idsOf l.sec.comps compLimit)⟩, l.trust⟩ : TLabel) = l := by
    rw [ofIds_idsOf (comps_fit hc hl)]
  have hnotlv : ¬ c.base.levels.length ≤ l.sec.level := Nat.not_le.2 hl.1.1
  have hnott : ¬ trustCount c.trusts.length ≤ l.trust := Nat.not_le.2 hl.2
  have hnotc : ¬ c.base.comps.length < (idsOf l.sec.comps compLimit).length := Nat.not_lt.2 hlen
  have hr := readU16_u16 (idsOf l.sec.comps compLimit).length (idsOf l.sec.comps compLimit ++ rest)
  simp only [encLabel, List.cons_append, List.append_assoc, readLabels, readTrust, hnotlv, hnott, ↓reduceIte, hr,
    hnotc, List.length_append, Nat.not_lt.2 (Nat.le_add_right _ _), List.take_left', List.drop_left', hok,
    Bool.not_true, Bool.false_eq_true, hof]

theorem readLabels_enc (c : TConfig) (hc : TConfigOk c) :
    ∀ (ls : List TLabel) (acc : List TLabel) (rest : List Nat),
      (∀ l ∈ ls, LabelOkT c l) → (acc ++ ls).Nodup →
      readLabels c.base.levels.length c.base.comps.length c.trusts.length true ls.length false acc
        ((ls.map encLabel).flatten ++ rest) = .ok (acc ++ ls, rest) := by
  intro ls
  induction ls with
  | nil => intro acc rest _ _; simp [readLabels]
  | cons l ls ih =>
    intro acc rest hv hn
    simp only [List.length_cons, List.map_cons, List.flatten_cons, List.append_assoc]
    rw [readLabel_step c hc l (hv l List.mem_cons_self) false ls.length acc _]
    have hna : l ∉ acc := by
      intro hm
      rw [List.nodup_append] at hn
      exact hn.2.2 l hm l List.mem_cons_self rfl
    simp only [Bool.false_eq_true, ↓reduceIte, hna]
    rw [ih (acc ++ [l]) rest (fun m hm => hv m (List.mem_cons_of_mem _ hm)) (by simpa using hn)]
    simp

theorem decode_encode {c : TConfig} {t : List TLabel} (hc : TConfigOk c) (ht : TableValid c t) :
    decode (encode c t) = .ok (c, t) := by
  obtain ⟨⟨h0, hnd, hlim⟩, hv⟩ := ht
  have hc' := hc
  obtain ⟨⟨⟨hL, hC, hcan, hnames⟩, hpos⟩, hT, htcan, htnd⟩ := hc
  match t, h0, hnd, hlim, hv with
  | b :: rest, h0, hnd, hlim, hv =>
    simp only [List.getElem?_cons_zero, Option.some.injEq] at h0
    subst h0
    have hlevels := readNames_enc c.base.levels []
      (u16 c.base.comps.length ++ ((c.base.comps.map encName).flatten ++ (u16 c.trusts.length ++
        ((c.trusts.map encName).flatten ++ (u16 (rest.length + 1) ++
        (encLabel tbottom ++ (rest.map encLabel).flatten))))))
      (fun n hn => hcan n (List.mem_append_left _ hn)) (by simpa using (List.nodup_append.1 hnames).1)
    have hcomps := readNames_enc c.base.comps c.base.levels
      (u16 c.trusts.length ++ ((c.trusts.map encName).flatten ++ (u16 (rest.length + 1) ++
        (encLabel tbottom ++ (rest.map encLabel).flatten))))
      (fun n hn => hcan n (List.mem_append_right _ hn)) hnames
    have htrusts := readNames_enc c.trusts []
      (u16 (rest.length + 1) ++ (encLabel tbottom ++ (rest.map encLabel).flatten))
      htcan (by simpa using htnd)
    have hlab := readLabels_enc c hc' rest [tbottom] [] (fun l hl => hv l (List.mem_cons_of_mem _ hl)) hnd
    have hfirst := readLabel_step c hc' tbottom (hv tbottom List.mem_cons_self) true rest.length [tbottom]
      ((rest.map encLabel).flatten)
    have hbot : ¬ (tbottom ≠ tbottom) := fun h => h rfl
    simp only [hbot, ↓reduceIte] at hfirst
    simp only [List.append_nil, List.singleton_append] at hlab
    have r1 := readU16_u16 c.base.levels.length ((c.base.levels.map encName).flatten ++ (u16 c.base.comps.length ++
      ((c.base.comps.map encName).flatten ++ (u16 c.trusts.length ++ ((c.trusts.map encName).flatten ++
      (u16 (rest.length + 1) ++ (encLabel tbottom ++ (rest.map encLabel).flatten)))))))
    have r2 := readU16_u16 c.base.comps.length ((c.base.comps.map encName).flatten ++
      (u16 c.trusts.length ++ ((c.trusts.map encName).flatten ++
      (u16 (rest.length + 1) ++ (encLabel tbottom ++ (rest.map encLabel).flatten)))))
    have rt := readU16_u16 c.trusts.length ((c.trusts.map encName).flatten ++
      (u16 (rest.length + 1) ++ (encLabel tbottom ++ (rest.map encLabel).flatten)))
    have r3 := readU16_u16 (rest.length + 1) (encLabel tbottom ++ (rest.map encLabel).flatten)
    have hL0 : ¬ (c.base.levels.length = 0 ∨ levelLimit < c.base.levels.length) := by omega
    have hC0 : ¬ compLimit < c.base.comps.length := by omega
    have hT0 : ¬ trustLimit < c.trusts.length := by omega
    have hn0 : ¬ (rest.length + 1 = 0) := by omega
    unfold decode encode encNames
    simp only [codecMagic, List.append_assoc, List.cons_append, List.nil_append, List.length_cons,
      List.map_cons, List.flatten_cons, List.take_succ_cons, List.take_zero, List.drop_succ_cons, List.drop_zero]
    simp only [List.length_append, Nat.not_lt.2 (Nat.le_add_left 4 _), ↓reduceIte, beq_self_eq_true,
      readTrustNames, r1, hL0, hlevels, r2, hC0, hcomps, rt, hT0, htrusts, r3, hn0, hfirst, hlab, ne_eq,
      not_true_eq_false, false_and]

def Bytes (s : List Nat) : Prop := ∀ b ∈ s, b < 256

theorem bytes_suffix {p r : List Nat} (h : Bytes (p ++ r)) : Bytes r := fun b hb => h b (List.mem_append_right _ hb)

theorem bytes_cons {a : Nat} {r : List Nat} (h : Bytes (a :: r)) : Bytes r := fun b hb => h b (List.mem_cons_of_mem _ hb)

theorem readU16_inv {s r : List Nat} {v : Nat} (h : readU16 s = some (v, r)) (hb : Bytes s) : s = u16 v ++ r := by
  match s, h with
  | a :: b :: rest, h =>
    simp only [readU16, Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    have ha := hb a List.mem_cons_self
    have hbb := hb b (List.mem_cons_of_mem _ List.mem_cons_self)
    have e1 : (a + 256 * b) % 256 = a := by omega
    have e2 : (a + 256 * b) / 256 = b := by omega
    simp only [u16, e1, e2, List.cons_append, List.nil_append]

theorem readName_inv {used : List (List Nat)} {s n r : List Nat} (h : readName used s = .ok (n, r)) :
    s = encName n ++ r ∧ nameCanonical n = true ∧ n ∉ used := by
  match s, h with
  | len :: rest, h =>
    simp only [readName] at h
    split at h
    · simp at h
    · rename_i hlen
      split at h
      · simp at h
      · rename_i hc
        split at h
        · simp at h
        · rename_i hu
          simp only [Except.ok.injEq, Prod.mk.injEq] at h
          obtain ⟨rfl, rfl⟩ := h
          have hl : (rest.take len).length = len := List.length_take_of_le (Nat.le_of_not_lt hlen)
          refine ⟨?_, by revert hc; cases nameCanonical (rest.take len) <;> simp, hu⟩
          simp only [encName, hl, List.cons_append, List.take_append_drop]

theorem readNames_inv : ∀ (k : Nat) (used : List (List Nat)) (s : List Nat) (ns : List (List Nat)) (r : List Nat),
    readNames k used s = .ok (ns, r) → used.Nodup →
      s = (ns.map encName).flatten ++ r ∧ ns.length = k ∧ (∀ n ∈ ns, nameCanonical n = true) ∧ (used ++ ns).Nodup := by
  intro k
  induction k with
  | zero =>
    intro used s ns r h hn
    simp only [readNames, Except.ok.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    simpa using hn
  | succ k ih =>
    intro used s ns r h hn
    simp only [readNames] at h
    split at h
    · simp at h
    · rename_i n s' hr
      split at h
      · simp at h
      · rename_i ns' s'' hrest
        simp only [Except.ok.injEq, Prod.mk.injEq] at h
        obtain ⟨rfl, rfl⟩ := h
        obtain ⟨hs, hc, hu⟩ := readName_inv hr
        have hn' : (used ++ [n]).Nodup := by
          rw [List.nodup_append]
          refine ⟨hn, List.nodup_cons.2 ⟨by simp, List.nodup_nil⟩, fun a ha b hb => ?_⟩
          simp only [List.mem_singleton] at hb
          subst hb
          intro he; subst he; exact hu ha
        obtain ⟨hs', hl, hc', hn''⟩ := ih (used ++ [n]) s' ns' s'' hrest hn'
        refine ⟨?_, by simp [hl], ?_, by simpa using hn''⟩
        · rw [hs, hs']
          simp
        · intro m hm
          simp only [List.mem_cons] at hm
          rcases hm with rfl | hm
          · exact hc
          · exact hc' m hm

theorem idsOk_lower {C : Nat} : ∀ {lo : Nat} {ids : List Nat}, idsOk C lo ids = true → ∀ y ∈ ids, lo ≤ y ∧ y < C := by
  intro lo ids
  induction ids generalizing lo with
  | nil => intro _ y hy; simp at hy
  | cons x xs ih =>
    intro h y hy
    simp only [idsOk, Bool.and_eq_true, decide_eq_true_eq] at h
    simp only [List.mem_cons] at hy
    rcases hy with rfl | hy
    · exact ⟨h.1.2, h.1.1⟩
    · have := ih h.2 y hy
      exact ⟨by omega, this.2⟩

theorem idsOk_bound {C C' lo : Nat} {ids : List Nat} (h : idsOk C lo ids = true) (hC : C ≤ C') :
    idsOk C' lo ids = true := by
  induction ids generalizing lo with
  | nil => rfl
  | cons x xs ih =>
    simp only [idsOk, Bool.and_eq_true, decide_eq_true_eq] at h ⊢
    exact ⟨⟨by omega, h.1.2⟩, ih h.2⟩

theorem filter_range_ids : ∀ (n lo : Nat) (ids : List Nat), idsOk (lo + n) lo ids = true →
    (List.range' lo n).filter (fun i => decide (i ∈ ids)) = ids := by
  intro n
  induction n with
  | zero =>
    intro lo ids h
    cases ids with
    | nil => rfl
    | cons x xs =>
      simp only [idsOk, Bool.and_eq_true, decide_eq_true_eq] at h
      omega
  | succ n ih =>
    intro lo ids h
    rw [List.range'_succ]
    cases ids with
    | nil =>
      rw [List.filter_cons_of_neg (by simp)]
      exact ih (lo + 1) [] rfl
    | cons x xs =>
      have h' := h
      simp only [idsOk, Bool.and_eq_true, decide_eq_true_eq] at h'
      obtain ⟨⟨hxC, hlox⟩, hrest⟩ := h'
      have hlow := idsOk_lower hrest
      by_cases hx : x = lo
      · subst hx
        rw [List.filter_cons_of_pos (by simp)]
        congr 1
        rw [List.filter_congr (q := fun i => decide (i ∈ xs))]
        · exact ih (x + 1) xs (by rw [show x + 1 + n = x + (n + 1) by omega]; exact hrest)
        · intro i hi
          simp only [List.mem_range'_1] at hi
          have : i ≠ x := by omega
          simp [this]
      · rw [List.filter_cons_of_neg]
        · apply ih (lo + 1) (x :: xs)
          simp only [idsOk, Bool.and_eq_true, decide_eq_true_eq]
          exact ⟨⟨by omega, by omega⟩, idsOk_bound hrest (by omega)⟩
        · simp only [decide_eq_true_eq, List.mem_cons, not_or]
          refine ⟨fun he => hx he.symm, fun hm => ?_⟩
          have := (hlow lo hm).1
          omega

theorem idsOf_ofIds {C : Nat} {ids : List Nat} (h : idsOk C 0 ids = true) (hC : C ≤ compLimit) :
    idsOf (ofIds ids) compLimit = ids := by
  unfold idsOf
  rw [List.range_eq_range']
  have : (List.range' 0 compLimit).filter ((ofIds ids).testBit ·) =
      (List.range' 0 compLimit).filter (fun i => decide (i ∈ ids)) := by
    apply List.filter_congr
    intro i _
    unfold ofIds
    rw [foldl_or_testBit, Nat.zero_testBit, Bool.false_or]
  rw [this]
  exact filter_range_ids compLimit 0 ids (by simpa using idsOk_bound h hC)

theorem readTrust_inv {T : Nat} {s0 s1 : List Nat} {tr : Nat} (h : readTrust true T s0 = .ok (tr, s1)) :
    s0 = tr :: s1 := by
  unfold readTrust at h
  simp only [↓reduceIte] at h
  match s0, h with
  | t :: rest, h =>
    simp only at h
    split at h
    · simp at h
    · simp only [Except.ok.injEq, Prod.mk.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      rfl

theorem readLabel_inv {C : Nat} (hC : C ≤ compLimit) (lv tr : Nat) {s1 s2 : List Nat} {n : Nat}
    (hr : readU16 s1 = some (n, s2)) (hb : Bytes s1) (hlen : ¬ s2.length < n) (hok : idsOk C 0 (s2.take n) = true) :
    lv :: tr :: s1 = encLabel ⟨⟨lv, ofIds (s2.take n)⟩, tr⟩ ++ s2.drop n := by
  have hs1 := readU16_inv hr hb
  have hl : (s2.take n).length = n := List.length_take_of_le (Nat.le_of_not_lt hlen)
  simp only [encLabel, idsOf_ofIds hok hC, hl, List.cons_append, List.append_assoc, List.take_append_drop]
  rw [hs1]

theorem readLabels_inv {L C T : Nat} (hC : C ≤ compLimit) : ∀ (k : Nat) (acc : List TLabel) (s : List Nat)
    (t : List TLabel) (r : List Nat), readLabels L C T true k false acc s = .ok (t, r) → Bytes s →
      ∃ ls, s = (ls.map encLabel).flatten ++ r ∧ t = acc ++ ls ∧ ls.length = k := by
  intro k
  induction k with
  | zero =>
    intro acc s t r h _
    simp only [readLabels, Except.ok.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    exact ⟨[], by simp, by simp, rfl⟩
  | succ k ih =>
    intro acc s t r h hb
    match s, h with
    | lv :: s0, h =>
      simp only [readLabels] at h
      split at h
      · simp at h
      · split at h
        · simp at h
        · rename_i tr s1 htr
          have hs0 := readTrust_inv htr
          split at h
          · simp at h
          · rename_i n s2 hr
            split at h
            · simp at h
            · split at h
              · simp at h
              · rename_i hlen
                split at h
                · simp at h
                · rename_i hok
                  simp only [Bool.false_eq_true, ↓reduceIte] at h
                  split at h
                  · simp at h
                  · have hok' : idsOk C 0 (s2.take n) = true := by
                      revert hok; cases idsOk C 0 (s2.take n) <;> simp
                    subst hs0
                    have he := readLabel_inv hC lv tr hr (bytes_cons (bytes_cons hb)) hlen hok'
                    obtain ⟨ls, hs, ht, hk⟩ := ih _ _ t r h (by rw [he] at hb; exact bytes_suffix hb)
                    refine ⟨⟨⟨lv, ofIds (s2.take n)⟩, tr⟩ :: ls, ?_, ?_, by simp [hk]⟩
                    · rw [he, hs]; simp
                    · rw [ht]; simp

theorem readLabels_first_inv {L C T : Nat} (hC : C ≤ compLimit) {k : Nat} {acc : List TLabel} {s : List Nat}
    {t : List TLabel} {r : List Nat} (h : readLabels L C T true (k + 1) true acc s = .ok (t, r)) (hb : Bytes s) :
    ∃ ls, s = ((tbottom :: ls).map encLabel).flatten ++ r ∧ t = acc ++ ls ∧ ls.length = k := by
  match s, h with
  | lv :: s0, h =>
    simp only [readLabels] at h
    split at h
    · simp at h
    · split at h
      · simp at h
      · rename_i tr s1 htr
        have hs0 := readTrust_inv htr
        split at h
        · simp at h
        · rename_i n s2 hr
          split at h
          · simp at h
          · split at h
            · simp at h
            · rename_i hlen
              split at h
              · simp at h
              · rename_i hok
                simp only [↓reduceIte] at h
                split at h
                · simp at h
                · rename_i hbot
                  have hbot' : (⟨⟨lv, ofIds (s2.take n)⟩, tr⟩ : TLabel) = tbottom := by
                    revert hbot; simp
                  have hok' : idsOk C 0 (s2.take n) = true := by
                    revert hok; cases idsOk C 0 (s2.take n) <;> simp
                  subst hs0
                  have he := readLabel_inv hC lv tr hr (bytes_cons (bytes_cons hb)) hlen hok'
                  rw [hbot'] at he
                  obtain ⟨ls, hs, ht, hk⟩ := readLabels_inv hC k acc _ t r h (by rw [he] at hb; exact bytes_suffix hb)
                  refine ⟨ls, ?_, ht, hk⟩
                  rw [he, hs]
                  simp

theorem readTrustNames_inv {s r : List Nat} {ns : List (List Nat)} (h : readTrustNames true s = .ok (ns, r))
    (hb : Bytes s) : s = encNames ns ++ r ∧ (∀ n ∈ ns, nameCanonical n = true) ∧ ns.Nodup ∧ ns.length ≤ trustLimit := by
  unfold readTrustNames at h
  simp only [↓reduceIte] at h
  split at h
  · simp at h
  · rename_i T s1 hr
    split at h
    · simp at h
    · rename_i hT
      have e1 := readU16_inv hr hb
      obtain ⟨e2, hl, hc, hn⟩ := readNames_inv T [] s1 ns r h List.nodup_nil
      refine ⟨?_, hc, by simpa using hn, by omega⟩
      rw [e1, e2]
      simp [encNames, hl]

theorem encode_decode {s : List Nat} {c : TConfig} {t : List TLabel} (h : decode s = .ok (c, t)) (hb : Bytes s)
    (hv2 : (s.drop 4).head? = some codecVersion) : encode c t = s := by
  unfold decode at h
  split at h
  · simp at h
  · rename_i hlen
    split at h
    · simp at h
    · rename_i hmag
      split at h
      · simp at h
      · rename_i v s' hdrop
        rw [hdrop] at hv2
        simp only [List.head?_cons, Option.some.injEq] at hv2
        subst hv2
        split at h
        · simp at h
        · split at h
          · simp at h
          · rename_i L s1 hr1
            split at h
            · simp at h
            · split at h
              · simp at h
              · rename_i levels s2 hn1
                split at h
                · simp at h
                · rename_i C s3 hr2
                  split at h
                  · simp at h
                  · rename_i hC
                    split at h
                    · simp at h
                    · rename_i comps s4 hn2
                      split at h
                      · simp at h
                      · rename_i trusts s4t hnt
                        split at h
                        · simp at h
                        · rename_i n s5 hr3
                          split at h
                          · simp at h
                          · rename_i hn0
                            split at h
                            · simp at h
                            · rename_i labels s6 hl
                              split at h
                              · simp at h
                              · rename_i hs6
                                simp only [Except.ok.injEq, Prod.mk.injEq] at h
                                obtain ⟨rfl, rfl⟩ := h
                                have hs6' : s6 = [] := by simpa using hs6
                                subst hs6'
                                have hsplit : s = codecMagic ++ (codecVersion :: s') := by
                                  rw [← hdrop, ← List.take_append_drop 4 s]
                                  simp only [List.take_append_drop]
                                  have : s.take 4 = codecMagic := by simpa using hmag
                                  rw [← this, List.take_append_drop]
                                have hb1 : Bytes s' := by rw [hsplit] at hb; exact bytes_cons (bytes_suffix hb)
                                have e1 := readU16_inv hr1 hb1
                                have hb2 : Bytes s1 := by rw [e1] at hb1; exact bytes_suffix hb1
                                obtain ⟨e2, hL, _, hnl⟩ := readNames_inv L [] s1 levels s2 hn1 List.nodup_nil
                                have hb3 : Bytes s2 := by rw [e2] at hb2; exact bytes_suffix hb2
                                have e3 := readU16_inv hr2 hb3
                                have hb4 : Bytes s3 := by rw [e3] at hb3; exact bytes_suffix hb3
                                obtain ⟨e4, hCl, _, _⟩ := readNames_inv C levels s3 comps s4 hn2 (by simpa using hnl)
                                have hb5 : Bytes s4 := by rw [e4] at hb4; exact bytes_suffix hb4
                                simp only [beq_self_eq_true] at hnt
                                obtain ⟨et, _, _, _⟩ := readTrustNames_inv hnt hb5
                                have hb5t : Bytes s4t := by rw [et] at hb5; exact bytes_suffix hb5
                                have e5 := readU16_inv hr3 hb5t
                                have hb6 : Bytes s5 := by rw [e5] at hb5t; exact bytes_suffix hb5t
                                obtain ⟨k, rfl⟩ : ∃ k, n = k + 1 := ⟨n - 1, by omega⟩
                                have hC' : C ≤ compLimit := Nat.le_of_not_lt hC
                                simp only [beq_self_eq_true] at hl
                                obtain ⟨ls, e6, ht, hk⟩ := readLabels_first_inv hC' hl hb6
                                subst ht
                                rw [hsplit, e1, e2, e3, e4, et, e5, e6]
                                simp only [encode, encNames, hL, hCl, hk, List.append_nil, List.map_cons, List.flatten_cons,
                                  List.append_assoc, List.cons_append, List.nil_append, List.length_cons]

theorem decode_injective {s1 s2 : List Nat} {c : TConfig} {t : List TLabel} (h1 : decode s1 = .ok (c, t))
    (h2 : decode s2 = .ok (c, t)) (hb1 : Bytes s1) (hb2 : Bytes s2) (hv1 : (s1.drop 4).head? = some codecVersion)
    (hv2 : (s2.drop 4).head? = some codecVersion) : s1 = s2 := by
  rw [← encode_decode h1 hb1 hv1, ← encode_decode h2 hb2 hv2]

theorem readLabels_narrow {L C T : Nat} : ∀ (k : Nat) (first : Bool) (acc : List TLabel) (s : List Nat)
    (t : List TLabel) (r : List Nat), readLabels L C T false k first acc s = .ok (t, r) →
      (∀ l ∈ acc, l.trust = 0) → ∀ l ∈ t, l.trust = 0 := by
  intro k
  induction k with
  | zero =>
    intro first acc s t r h hacc
    simp only [readLabels, Except.ok.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    exact hacc
  | succ k ih =>
    intro first acc s t r h hacc
    match s, h with
    | lv :: s0, h =>
      simp only [readLabels, readTrust, Bool.false_eq_true, ↓reduceIte] at h
      split at h
      · simp at h
      · split at h
        · simp at h
        · rename_i n s2 _
          split at h
          · simp at h
          · split at h
            · simp at h
            · split at h
              · simp at h
              · split at h
                · split at h
                  · simp at h
                  · exact ih false acc _ t r h hacc
                · split at h
                  · simp at h
                  · refine ih false _ _ t r h ?_
                    intro l hl
                    simp only [List.mem_append, List.mem_singleton] at hl
                    rcases hl with hl | rfl
                    · exact hacc l hl
                    · rfl

theorem decode_untrusted {s : List Nat} {c : TConfig} {t : List TLabel} (h : decode s = .ok (c, t))
    (hv1 : (s.drop 4).head? = some codecUntrusted) : c.trusts = [] ∧ ∀ l ∈ t, l.trust = 0 := by
  unfold decode at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · split at h
      · simp at h
      · rename_i v s' hdrop
        rw [hdrop] at hv1
        simp only [List.head?_cons, Option.some.injEq] at hv1
        subst hv1
        have hw : (codecUntrusted == codecVersion) = false := by decide
        simp only [hw, readTrustNames, Bool.false_eq_true, ↓reduceIte] at h
        split at h
        · simp at h
        · split at h
          · simp at h
          · split at h
            · simp at h
            · split at h
              · simp at h
              · split at h
                · simp at h
                · split at h
                  · simp at h
                  · split at h
                    · simp at h
                    · split at h
                      · simp at h
                      · split at h
                        · simp at h
                        · split at h
                          · simp at h
                          · rename_i labels s6 hl
                            split at h
                            · simp at h
                            · simp only [Except.ok.injEq, Prod.mk.injEq] at h
                              obtain ⟨rfl, rfl⟩ := h
                              refine ⟨rfl, readLabels_narrow _ _ _ _ _ _ hl ?_⟩
                              intro l hl
                              simp only [List.mem_singleton] at hl
                              subst hl
                              rfl

end Labels
