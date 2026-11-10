import Storage.Placement

namespace Storage

def shortFirst : Nat := 1

def shortKeep : Nat := 2

def shortShrink : Nat := 4

def shortFull : Nat := 8

def isLive : Cell → Bool
  | .live _ => true
  | _ => false

def LaneBound (t : Table) : Prop :=
  t.slots.length = 16 ∧ t.lanes < 16 ∧ t.tombs = 0 ∧ t.live + t.growth + t.tombs = t.lanes ∧
    ∀ i c, t.slots[i]? = some c → c ≠ .empty → c ≠ .deleted ∧ i < t.lanes

def compactTable (t : Table) : Table :=
  ⟨t.slots.take shortKeep ++ List.replicate (16 - shortKeep) .empty, t.live, 0, shortShrink - t.live, shortShrink⟩

theorem one_group_probe (xs : List Cell) (hash : Nat) (h : xs.length = 16) : probeOf xs hash = [0] := by
  have hg : groupsOf xs = 1 := by simp [groupsOf, h]
  have hh : hashHome hash 1 = 0 := by
    unfold hashHome wordSpan
    have := Nat.mod_lt hash (show 0 < 18446744073709551616 by decide)
    omega
  simp only [probeOf, hg, hh]
  rfl

theorem one_group_candidates (xs : List Cell) (hash : Nat) (h : xs.length = 16) :
    candidates xs hash = List.range 16 := by
  simp [candidates, one_group_probe xs hash h, groupIndices]

theorem find_range_first (p : Nat → Bool) (m : Nat) (hp : p m = true) (hlt : ∀ j, j < m → p j = false) :
    ∀ n, m < n → (List.range n).find? p = some m := by
  intro n hn
  induction n with
  | zero => omega
  | succ n ih =>
    rw [List.range_succ, List.find?_append]
    by_cases h : m < n
    · rw [ih h]
      rfl
    · have hmn : m = n := by omega
      subst hmn
      have hnone : (List.range m).find? p = none := by
        rw [List.find?_eq_none]
        intro x hx
        simp only [List.mem_range] at hx
        simp [hlt x hx]
      rw [hnone]
      simp [hp]

theorem find_range_lowest (p : Nat → Bool) (n j : Nat) (h : (List.range n).find? p = some j) :
    j < n ∧ p j = true ∧ ∀ i, i < j → p i = false := by
  obtain ⟨hp, as, bs, heq, hbefore⟩ := List.find?_eq_some_iff_append.mp h
  have hlen : as.length < n := by
    have := congrArg List.length heq
    simp at this
    omega
  have hj : j = as.length := by
    have h1 : (List.range n)[as.length]? = some j := by rw [heq]; simp
    rw [List.getElem?_range hlen] at h1
    simp at h1
    exact h1.symm
  have has : as = List.range as.length := by
    have h2 := congrArg (List.take as.length) heq
    rw [List.take_range, List.take_left, Nat.min_eq_left (by omega)] at h2
    exact h2.symm
  refine ⟨by omega, hp, ?_⟩
  intro i hi
  have hmem : i ∈ as := by
    rw [has, List.mem_range]
    omega
  simpa using hbefore i hmem

theorem claim_lowest_lane (xs : List Cell) (hash j : Nat) (hl : xs.length = 16)
    (h : claimIndex xs hash = some j) : j < 16 ∧ freeAt xs j = true ∧ ∀ i, i < j → freeAt xs i = false := by
  unfold claimIndex at h
  rw [one_group_candidates xs hash hl] at h
  exact find_range_lowest _ 16 j h

theorem claim_at_lowest (xs : List Cell) (hash m : Nat) (hl : xs.length = 16) (hm : m < 16)
    (hf : freeAt xs m = true) (hlt : ∀ j, j < m → freeAt xs j = false) : claimIndex xs hash = some m := by
  unfold claimIndex
  rw [one_group_candidates xs hash hl]
  exact find_range_first _ m hf hlt 16 hm

theorem one_group_wellplaced (xs : List Cell) (hl : xs.length = 16) : WellPlaced xs := by
  intro i e hs
  have hi : i < 16 := by
    have := (List.getElem?_eq_some_iff.mp hs).1
    omega
  refine ⟨[], 0, [], by rw [one_group_probe xs e.hash hl]; rfl, ?_, by simp⟩
  simp [groupIndices]
  omega

theorem live_prefix_weight (xs : List Cell) (n : Nat) (h : ∀ i, i < n → isLive (xs[i]?.getD .empty) = true) :
    n ≤ weight liveWeight xs := by
  induction n generalizing xs with
  | zero => omega
  | succ n ih =>
    cases xs with
    | nil => simpa [isLive] using h 0 (by omega)
    | cons x rest =>
      have hx := h 0 (by omega)
      have hrest := ih rest (fun i hi => by simpa using h (i + 1) (by omega))
      cases x with
      | live e => simp only [weight, liveWeight]; omega
      | empty => simp [isLive] at hx
      | deleted => simp [isLive] at hx

theorem lane_claim_preserves (t : Table) (e : Entry) (j : Nat) (hb : LaneBound t) (hc : CounterConsistent t)
    (hg : 0 < t.growth) (hj : claimIndex t.slots e.hash = some j) :
    j < t.lanes ∧ t.slots[j]? = some .empty ∧ LaneBound (place t j e) ∧ CounterConsistent (place t j e) := by
  obtain ⟨hl, hk, ht, hs, hn⟩ := hb
  obtain ⟨hj16, hfree, hlow⟩ := claim_lowest_lane t.slots e.hash j hl hj
  have hcell : t.slots[j]? = some .empty := by
    have hsome : ∃ c, t.slots[j]? = some c := ⟨t.slots[j]'(by omega), by simp [List.getElem?_eq_getElem (show j < t.slots.length by omega)]⟩
    obtain ⟨c, hc'⟩ := hsome
    rw [hc']
    cases c with
    | empty => rfl
    | deleted => exact absurd rfl (hn j .deleted hc' (by simp)).1
    | live v => simp [freeAt, hc'] at hfree
  have hjl : j < t.lanes := by
    rcases Nat.lt_or_ge j t.lanes with hlt | hge
    · exact hlt
    exfalso
    have hall : ∀ i, i < t.lanes → isLive (t.slots[i]?.getD .empty) = true := by
      intro i hi
      have hf := hlow i (by omega)
      have hsome : ∃ c, t.slots[i]? = some c := ⟨t.slots[i]'(by omega), by simp [List.getElem?_eq_getElem (show i < t.slots.length by omega)]⟩
      obtain ⟨c, hc'⟩ := hsome
      cases c with
      | live v => simp [hc', isLive]
      | empty => simp [freeAt, hc'] at hf
      | deleted => simp [freeAt, hc'] at hf
    have hw := live_prefix_weight t.slots t.lanes hall
    unfold CounterConsistent at hc
    omega
  refine ⟨hjl, hcell, ⟨by simp [place, put_length, hl], hk, ?_, ?_, ?_⟩, place_consistent t j e hfree hc⟩
  · simp [place, hcell, ht]
  · simp only [place, hcell]
    simp
    omega
  · intro i c hi hne
    by_cases hij : i = j
    · subst hij
      simp only [place] at hi
      rw [put_at, hcell] at hi
      simp at hi
      subst hi
      exact ⟨by simp, hjl⟩
    · simp only [place] at hi
      rw [put_other t.slots j i _ (Ne.symm hij)] at hi
      exact hn i c hi hne

theorem lane_erase_preserves (t : Table) (i : Nat) (e : Entry) (hb : LaneBound t) (hs : t.slots[i]? = some (.live e)) :
    (erase t i).slots[i]? = some .empty ∧ LaneBound (erase t i) := by
  obtain ⟨hl, hk, ht, hsum, hn⟩ := hb
  have hi : i < t.lanes := (hn i (.live e) hs (by simp)).2
  have h15 : t.slots[15]? = some .empty := by
    have hsome : t.slots[15]? = some (t.slots[15]'(by omega)) := by
      simp [List.getElem?_eq_getElem (show 15 < t.slots.length by omega)]
    rw [hsome]
    cases hc15 : t.slots[15]'(by omega) with
    | empty => rfl
    | live v =>
      have := (hn 15 _ (hc15 ▸ hsome) (by simp)).2
      omega
    | deleted =>
      have := (hn 15 _ (hc15 ▸ hsome) (by simp)).2
      omega
  have hgroup : i / 16 = 0 := by omega
  have hempty : ((List.range 16).any fun k => t.slots[i / 16 * 16 + k]? == some .empty) = true := by
    rw [hgroup, List.any_eq_true]
    exact ⟨15, by simp, by simp [h15]⟩
  have hslots : (erase t i).slots = put t.slots i .empty := by
    simp only [erase]
    rw [ite_eq_left hempty]
  refine ⟨?_, ⟨?_, hk, ?_, ?_, ?_⟩⟩
  · rw [hslots, put_at, hs]
    rfl
  · rw [hslots, put_length, hl]
  · simp only [erase]
    rw [ite_eq_left hempty]
    simp [ht]
  · simp only [erase]
    rw [ite_eq_left hempty, ite_eq_left hempty]
    simp
    omega
  · intro j c hj hne
    rw [hslots] at hj
    by_cases hij : j = i
    · subst hij
      rw [put_at, hs] at hj
      simp at hj
      exact absurd hj.symm hne
    · rw [put_other t.slots i j _ (Ne.symm hij)] at hj
      exact hn j c hj hne

def LivePrefix (xs : List Cell) (es : List Entry) : Prop :=
  xs.length = 16 ∧ es.length ≤ 16 ∧
    ∀ i, xs[i]? = if h : i < es.length then some (.live es[i]) else if i < 16 then some .empty else none

def MigState (b : Banks) (es : List Entry) (m : Nat) : Prop :=
  b.src.slots.length = 16 ∧ b.dst.slots.length = 16 ∧
    (∀ i, b.src.slots[i]? = if h : i < es.length then (if i < m then some .deleted else some (.live es[i]))
      else if i < 16 then some .empty else none) ∧
    (∀ i, b.dst.slots[i]? = if h : i < es.length then (if i < m then some (.live es[i]) else some .empty)
      else if i < 16 then some .empty else none)

theorem mig_step (b : Banks) (es : List Entry) (m : Nat) (hm : m < 16) (hs : MigState b es m) :
    MigState (migrateAt b m).1 es (m + 1) ∧ (migrateAt b m).2 = (if m < es.length then 1 else 0) ∧
      (migrateAt b m).1.cursor = b.cursor ∧ (migrateAt b m).1.src.lanes = b.src.lanes ∧
      (migrateAt b m).1.dst.lanes = b.dst.lanes := by
  obtain ⟨ls, ld, hsrc, hdst⟩ := hs
  by_cases hme : m < es.length
  · have hcell : b.src.slots[m]? = some (.live es[m]) := by rw [hsrc m]; simp [hme]
    have hclaim : claimIndex b.dst.slots es[m].hash = some m := by
      apply claim_at_lowest _ _ m ld hm
      · simp [freeAt, hdst m, hme]
      · intro j hj
        simp [freeAt, hdst j, show j < es.length by omega, hj]
    have hmig : migrateAt b m = (moveOne b m m es[m], 1) := by
      unfold migrateAt
      rw [hcell]
      simp only
      rw [hclaim]
    rw [hmig]
    refine ⟨⟨?_, ?_, ?_, ?_⟩, by simp [hme], rfl, rfl, rfl⟩
    · simp [moveOne, put_length, ls]
    · simp [moveOne, place, put_length, ld]
    · intro i
      simp only [moveOne]
      by_cases hi : i = m
      · subst hi
        rw [put_at, hcell]
        simp [hme]
      · rw [put_other _ m i _ (Ne.symm hi), hsrc i]
        split
        · have : i < m + 1 ↔ i < m := by omega
          simp [this]
        · rfl
    · intro i
      simp only [moveOne, place]
      by_cases hi : i = m
      · subst hi
        rw [put_at, hdst i]
        simp [hme]
      · rw [put_other _ m i _ (Ne.symm hi), hdst i]
        split
        · have : i < m + 1 ↔ i < m := by omega
          simp [this]
        · rfl
  · have hcell : b.src.slots[m]? = some .empty := by rw [hsrc m]; simp [hme, hm]
    have hmig : migrateAt b m = (b, 0) := by
      unfold migrateAt
      rw [hcell]
    rw [hmig]
    refine ⟨⟨ls, ld, ?_, ?_⟩, by simp [hme], rfl, rfl, rfl⟩
    · intro i
      rw [hsrc i]
      split
      · have : i < m + 1 ↔ i < m := by omega
        simp [this]
      · rfl
    · intro i
      rw [hdst i]
      split
      · have : i < m + 1 ↔ i < m := by omega
        simp [this]
      · rfl

def MigDone (r b : Banks) (es : List Entry) : Prop :=
  (∃ m', es.length ≤ m' ∧ MigState r es m') ∧ r.cursor = b.cursor ∧ r.src.lanes = b.src.lanes ∧
    r.dst.lanes = b.dst.lanes

theorem mig_slots (es : List Entry) (limit : Nat) (hlim : es.length ≤ limit) (hle : es.length ≤ 16) :
    ∀ k m (b : Banks), m + k = 16 → MigState b es m →
      MigDone (migrateSlots (List.range' m k) limit b (min m es.length)).1 b es := by
  intro k
  induction k with
  | zero =>
    intro m b hmk hs
    exact ⟨⟨m, by omega, hs⟩, rfl, rfl, rfl⟩
  | succ k ih =>
    intro m b hmk hs
    rw [List.range'_succ]
    unfold migrateSlots
    split
    next hlt =>
      obtain ⟨hs', hmoved, hcur, hsl, hdl⟩ := mig_step b es m (by omega) hs
      have hnext : min m es.length + (migrateAt b m).2 = min (m + 1) es.length := by
        rw [hmoved]
        split <;> omega
      show MigDone (migrateSlots (List.range' (m + 1) k) limit (migrateAt b m).1
        (min m es.length + (migrateAt b m).2)).1 b es
      rw [hnext]
      obtain ⟨hfin, hc2, hs2, hd2⟩ := ih (m + 1) (migrateAt b m).1 (by omega) hs'
      exact ⟨hfin, by rw [hc2, hcur], by rw [hs2, hsl], by rw [hd2, hdl]⟩
    next hge =>
      exact ⟨⟨m, by omega, hs⟩, rfl, rfl, rfl⟩

theorem mig_final (b : Banks) (es : List Entry) (m : Nat) (hm : es.length ≤ m) (hs : MigState b es m)
    (src : List Cell) (hsrc : LivePrefix src es) :
    b.dst.slots = src ∧ groupLive b.src 0 = false := by
  obtain ⟨ls, ld, hbs, hbd⟩ := hs
  obtain ⟨lo, le, ho⟩ := hsrc
  constructor
  · apply List.ext_getElem?
    intro i
    rw [hbd i, ho i]
    split
    · next h => simp [show i < m by omega]
    · rfl
  · unfold groupLive
    rw [Bool.eq_false_iff]
    intro hany
    rw [List.any_eq_true] at hany
    obtain ⟨k, hk, hlive⟩ := hany
    simp only [List.mem_range] at hk
    have hnot : ∀ e, b.src.slots[k]? ≠ some (.live e) := by
      intro e he
      rw [hbs k] at he
      by_cases h1 : k < es.length
      · simp [h1, show k < m by omega] at he
      · simp only [h1, dite_false] at he
        split at he <;> simp at he
    simp only [Nat.zero_mul, Nat.zero_add] at hlive
    cases hc : b.src.slots[k]? with
    | none => simp at hlive
    | some c =>
      cases c with
      | live e => exact hnot e hc
      | empty => simp at hlive
      | deleted => simp at hlive

theorem lane_preserving_migration (b : Banks) (es : List Entry) (limit : Nat) (hsrc : LivePrefix b.src.slots es)
    (hdst : b.dst.slots = List.replicate 16 .empty) (hlim : es.length ≤ limit) :
    (migrateGroup b 0 limit).1.dst.slots = b.src.slots ∧ (migrateGroup b 0 limit).2.2 = true ∧
      (migrateGroup b 0 limit).1.cursor = b.cursor ∧ (migrateGroup b 0 limit).1.src.lanes = b.src.lanes ∧
      (migrateGroup b 0 limit).1.dst.lanes = b.dst.lanes := by
  obtain ⟨lo, le, ho⟩ := hsrc
  have h0 : MigState b es 0 := by
    refine ⟨lo, by rw [hdst]; simp, ?_, ?_⟩
    · intro i
      rw [ho i]
      split <;> simp
    · intro i
      rw [hdst, List.getElem?_replicate]
      by_cases h16 : i < 16
      · by_cases hl : i < es.length <;> simp [h16, hl]
      · simp [h16, show ¬i < es.length by omega]
  have hidx : groupIndices 0 = List.range' 0 16 := by
    simp [groupIndices, List.range_eq_range']
  obtain ⟨⟨m', hm', hfin⟩, hcur, hsl, hdl⟩ := mig_slots es limit hlim le 16 0 b (by omega) h0
  have hres : (migrateGroup b 0 limit).1 = (migrateSlots (List.range' 0 16) limit b (min 0 es.length)).1 := by
    simp [migrateGroup, hidx]
  obtain ⟨hd, hg⟩ := mig_final _ es m' hm' hfin b.src.slots ⟨lo, le, ho⟩
  refine ⟨by rw [hres]; exact hd, ?_, by rw [hres]; exact hcur, by rw [hres]; exact hsl, by rw [hres]; exact hdl⟩
  simp only [migrateGroup]
  rw [Bool.not_eq_true']
  have : groupIndices 0 = List.range' 0 16 := hidx
  rw [this]
  simpa using hg

theorem lane_preserving_rehash (b : Banks) (es : List Entry) (groups want : Nat) (hsrc : LivePrefix b.src.slots es)
    (hdst : b.dst.slots = List.replicate 16 .empty) (hcur : b.cursor = 0) (hg : 0 < groups) (hw : es.length ≤ want)
    (hw0 : 0 < want) :
    (rehash b groups want).src.slots = b.src.slots ∧ (rehash b groups want).src.lanes = b.dst.lanes ∧
      (rehash b groups want).cursor = -1 ∧ (rehash b groups want).dst.slots = [] := by
  obtain ⟨hd, hdone, hc, hsl, hdl⟩ := lane_preserving_migration b es want hsrc hdst hw
  have hgroups : groupsOf b.src.slots = 1 := by simp [groupsOf, hsrc.1]
  have hloop : rehashLoop 1 b groups want 0 0 =
      {(migrateGroup b 0 want).1 with cursor := nextCursor (migrateGroup b 0 want).1.cursor true} := by
    rw [rehashLoop]
    have hcond : ¬(b.cursor < 0 ∨ groupsOf b.src.slots ≤ b.cursor.toNat ∨ want ≤ 0 ∨ groups ≤ 0) := by
      rw [hgroups, hcur]
      omega
    rw [ite_eq_right hcond]
    simp only [hcur, Int.toNat_zero, Nat.sub_zero]
    rw [ite_eq_left hdone]
    rfl
  have hfinal : groupsOf (migrateGroup b 0 want).1.src.slots ≤
      (nextCursor (migrateGroup b 0 want).1.cursor true).toNat := by
    have hl : (migrateGroup b 0 want).1.src.slots.length = 16 := by
      have := (migrateGroup_preserves b 0 want (fun _ => true))
      simp only [migrateGroup]
      exact (migrateSlots_shape (groupIndices 0) want 0 b).2.1.trans hsrc.1
    simp [groupsOf, hl, nextCursor, hc, hcur]
  unfold rehash
  rw [hgroups, hloop]
  simp only
  rw [ite_eq_left (Or.inl hfinal)]
  simp [swapBanks, hd, hdl, emptyTable]

theorem compaction_preserves (t : Table) (hl : t.slots.length = 16)
    (hk : ∀ (i : Nat) (e : Entry), t.slots[i]? = some (Cell.live e) → i < shortKeep) (hc : CounterConsistent t) :
    (∀ (i : Nat) (e : Entry), (compactTable t).slots[i]? = some (Cell.live e) ↔ t.slots[i]? = some (Cell.live e)) ∧
      (∀ f, weight (liftWeight f) (compactTable t).slots = weight (liftWeight f) t.slots) ∧
      WellPlaced (compactTable t).slots ∧ CounterConsistent (compactTable t) ∧
      (compactTable t).slots.length = 16 ∧ (compactTable t).lanes = shortShrink := by
  have hlen : (compactTable t).slots.length = 16 := by simp [compactTable, shortKeep, hl]
  have hidx : ∀ (i : Nat) (e : Entry), (compactTable t).slots[i]? = some (Cell.live e) ↔ t.slots[i]? = some (Cell.live e) := by
    intro i e
    simp only [compactTable, shortKeep]
    by_cases hi : i < 2
    · rw [List.getElem?_append_left (by simp [hl]; omega), List.getElem?_take_of_lt hi]
    · rw [List.getElem?_append_right (by simp [hl]; omega)]
      simp only [List.getElem?_replicate]
      constructor
      · intro h
        split at h <;> simp at h
      · intro h
        exact absurd (hk i e h) (by simp [shortKeep]; omega)
  have hweight : ∀ f, weight (liftWeight f) (compactTable t).slots = weight (liftWeight f) t.slots := by
    intro f
    have key : ∀ (xs ys : List Cell), (∀ i : Nat, isLive (xs[i]?.getD .empty) = isLive (ys[i]?.getD .empty)) →
        (∀ (i : Nat) (e : Entry), xs[i]? = some (Cell.live e) ↔ ys[i]? = some (Cell.live e)) →
        weight (liftWeight f) xs = weight (liftWeight f) ys := by
      intro xs
      induction xs with
      | nil =>
        intro ys _ hiff
        have : weight (liftWeight f) ys = 0 := by
          apply no_live_weight
          intro i e h
          have := (hiff i e).mpr h
          simp at this
        exact this.symm
      | cons x xs ih =>
        intro ys hlive hiff
        cases ys with
        | nil =>
          have : weight (liftWeight f) (x :: xs) = 0 := by
            apply no_live_weight
            intro i e h
            have := (hiff i e).mp h
            simp at this
          exact this
        | cons y ys =>
          have hrest := ih ys (fun i => by simpa using hlive (i + 1))
            (fun i e => by simpa using hiff (i + 1) e)
          have h0 := hiff 0
          simp only [weight]
          rw [hrest]
          cases x with
          | live a =>
            have := (h0 a).mp (by simp)
            simp at this
            subst this
            rfl
          | empty =>
            cases y with
            | live b => have := (h0 b).mpr (by simp); simp at this
            | empty => rfl
            | deleted => rfl
          | deleted =>
            cases y with
            | live b => have := (h0 b).mpr (by simp); simp at this
            | empty => rfl
            | deleted => rfl
    apply key
    · intro i
      have := hidx i
      cases hx : (compactTable t).slots[i]? with
      | none =>
        cases hy : t.slots[i]? with
        | none => rfl
        | some c =>
          cases c with
          | live e => have := (hidx i e).mpr hy; rw [hx] at this; simp at this
          | empty => rfl
          | deleted => rfl
      | some c =>
        cases c with
        | live e =>
          have := (hidx i e).mp hx
          rw [this]
        | empty =>
          cases hy : t.slots[i]? with
          | none => rfl
          | some d =>
            cases d with
            | live e => have := (hidx i e).mpr hy; rw [hx] at this; simp at this
            | empty => rfl
            | deleted => rfl
        | deleted =>
          cases hy : t.slots[i]? with
          | none => rfl
          | some d =>
            cases d with
            | live e => have := (hidx i e).mpr hy; rw [hx] at this; simp at this
            | empty => rfl
            | deleted => rfl
    · exact hidx
  refine ⟨hidx, hweight, one_group_wellplaced _ hlen, ?_, hlen, rfl⟩
  unfold CounterConsistent at hc ⊢
  have hlw : liftWeight (fun _ => 1) = liveWeight := by funext c; cases c <;> rfl
  have := hweight (fun _ => 1)
  rw [hlw] at this
  simp only [compactTable] at this ⊢
  rw [this, hc]

theorem compaction_lane_bound (t : Table) (hl : t.slots.length = 16)
    (hk : ∀ (i : Nat) (e : Entry), t.slots[i]? = some (Cell.live e) → i < shortKeep) (hd : ∀ i : Nat, t.slots[i]? ≠ some Cell.deleted)
    (hc : CounterConsistent t) : LaneBound (compactTable t) := by
  obtain ⟨hidx, -, -, -, hlen, -⟩ := compaction_preserves t hl hk hc
  refine ⟨hlen, by simp [compactTable, shortShrink], rfl, by simp [compactTable, shortShrink]; omega, ?_⟩
  intro i c hi hne
  simp only [compactTable, shortKeep, shortShrink] at hi ⊢
  by_cases h2 : i < 2
  · rw [List.getElem?_append_left (by simp [hl]; omega), List.getElem?_take_of_lt h2] at hi
    refine ⟨?_, by omega⟩
    intro hdel
    subst hdel
    exact hd i hi
  · rw [List.getElem?_append_right (by simp [hl]; omega), List.getElem?_replicate] at hi
    split at hi
    · simp at hi
      exact absurd hi.symm hne
    · simp at hi

theorem migrateAt_lanes (b : Banks) (i : Nat) :
    (migrateAt b i).1.src.lanes = b.src.lanes ∧ (migrateAt b i).1.dst.lanes = b.dst.lanes := by
  unfold migrateAt
  split
  next =>
    split
    next => simp [moveOne, place]
    next => simp
  next => simp

theorem migrateSlots_lanes (indices : List Nat) (limit moved : Nat) (b : Banks) :
    (migrateSlots indices limit b moved).1.src.lanes = b.src.lanes ∧
      (migrateSlots indices limit b moved).1.dst.lanes = b.dst.lanes := by
  induction indices generalizing b moved with
  | nil => simp [migrateSlots]
  | cons i rest ih =>
    simp only [migrateSlots]
    split
    next =>
      obtain ⟨a, c⟩ := ih (moved + (migrateAt b i).2) (migrateAt b i).1
      obtain ⟨a', c'⟩ := migrateAt_lanes b i
      exact ⟨a.trans a', c.trans c'⟩
    next => simp

theorem rehashLoop_lanes (fuel : Nat) (b : Banks) (maxGroups want moved visited : Nat) (hc : 0 ≤ b.cursor) :
    0 ≤ (rehashLoop fuel b maxGroups want moved visited).cursor ∧
      (rehashLoop fuel b maxGroups want moved visited).src.lanes = b.src.lanes ∧
      (rehashLoop fuel b maxGroups want moved visited).dst.lanes = b.dst.lanes := by
  induction fuel generalizing b moved visited with
  | zero => exact ⟨hc, rfl, rfl⟩
  | succ fuel ih =>
    simp only [rehashLoop]
    split
    next => exact ⟨hc, rfl, rfl⟩
    next =>
      obtain ⟨hcur, -, -⟩ := migrateSlots_shape (groupIndices b.cursor.toNat) (want - moved) 0 b
      obtain ⟨hs, hd⟩ := migrateSlots_lanes (groupIndices b.cursor.toNat) (want - moved) 0 b
      split
      next =>
        obtain ⟨a, c, d⟩ := ih {(migrateGroup b b.cursor.toNat (want - moved)).1 with
            cursor := nextCursor (migrateGroup b b.cursor.toNat (want - moved)).1.cursor true}
          (moved + (migrateGroup b b.cursor.toNat (want - moved)).2.1) (visited + 1)
          (by simp only [nextCursor, migrateGroup]; omega)
        exact ⟨a, c.trans hs, d.trans hd⟩
      next => exact ⟨by rw [migrateGroup, hcur]; exact hc, hs, hd⟩

theorem rehash_lanes (b : Banks) (groups want : Nat) (hc : 0 ≤ b.cursor) :
    (0 ≤ (rehash b groups want).cursor ∧ (rehash b groups want).src.lanes = b.src.lanes ∧
      (rehash b groups want).dst.lanes = b.dst.lanes) ∨
    ((rehash b groups want).cursor = -1 ∧ (rehash b groups want).src.lanes = b.dst.lanes ∧
      (rehash b groups want).dst.lanes = 0) := by
  obtain ⟨a, c, d⟩ := rehashLoop_lanes (groupsOf b.src.slots) b groups want 0 0 hc
  unfold rehash
  simp only
  split
  · exact Or.inr ⟨rfl, by simp [swapBanks, d], rfl⟩
  · exact Or.inl ⟨a, c, d⟩

theorem upsert_lanes (b : Banks) (key hash : Nat) (fresh : Entry) (change : Entry → Entry)
    (b' : Banks) (r : Option Entry) (h : upsert b key hash fresh change = some (b', r)) :
    b'.src.lanes = b.src.lanes ∧ b'.dst.lanes = b.dst.lanes := by
  rcases upsert_cases b key hash fresh change b' r h with ⟨d, i, old, _, hs, rfl⟩ | ⟨_, _, j, hj, rfl⟩ | ⟨_, _, j, hj, rfl⟩
  · cases d <;> simp [writeAt]
  · simp [place]
  · simp [place]

theorem remove_lanes (b : Banks) (key hash : Nat) :
    (remove b key hash).1.src.lanes = b.src.lanes ∧ (remove b key hash).1.dst.lanes = b.dst.lanes := by
  rcases remove_cases b key hash with ⟨_, he⟩ | ⟨d, i, old, _, hs, he⟩
  · rw [he]; exact ⟨rfl, rfl⟩
  · rw [he]
    cases d <;> simp [erase]

end Storage
