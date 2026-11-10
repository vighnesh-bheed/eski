import Labels.OwnerKeyModel

namespace Labels

section OwnerKeyReads
set_option linter.unusedSectionVars false
variable {N V : Type} [DecidableEq N]

def ovisibleNames (s : OState N V) (w : Scope) : List N :=
  uniq ((s.copies.filter (fun c => seesP w c.scope)).map (·.name))

def isOwn (w : Scope) (c : OCopy N V) : Bool := isUserO w.2 && c.scope.2 == w.2 && domT w.1 c.scope.1

def isSharedVis (w : Scope) (c : OCopy N V) : Bool := c.scope.2 == .shared && domT w.1 c.scope.1

def ownNames (s : OState N V) (w : Scope) : List N := uniq ((s.copies.filter (isOwn w)).map (·.name))

def sharedNames (s : OState N V) (w : Scope) : List N := uniq ((s.copies.filter (isSharedVis w)).map (·.name))

def crossNames (s : OState N V) (w : Scope) : List N := (ownNames s w).filter (fun n => decide (n ∈ sharedNames s w))

def ownOnly (w : Scope) (s : OState N V) : OState N V := ⟨s.copies.filter (fun c => c.scope.2 == w.2), s.parts⟩

def oownResolve (s : OState N V) (w : Scope) (n : N) : Option (OCopy N V) :=
  if isUserO w.2 then oresolve (ownOnly w s) w n else none

def osharedResolve (s : OState N V) (w : Scope) (n : N) : Option (OCopy N V) :=
  oresolve (ownOnly (w.1, .shared) s) (w.1, .shared) n

def hasOwn (s : OState N V) (w : Scope) (n : N) : Bool := s.copies.any (fun c => c.name == n && isOwn w c)

def oownParts (ord : List TLabel → List TLabel) (s : OState N V) (w : Scope) : List TLabel :=
  ord ((s.parts.filter (fun p => isUserO w.2 && p.2 == w.2 && domT w.1 p.1)).map (·.1))

def osharedParts (ord : List TLabel → List TLabel) (s : OState N V) (w : Scope) : List TLabel :=
  ord ((s.parts.filter (fun p => p.2 == .shared && domT w.1 p.1)).map (·.1))

def inPhase0 (ord : List TLabel → List TLabel) (s : OState N V) (w : Scope) (k : Nat) (n : N) : Bool :=
  match oownResolve s w n with
  | some c => decide (c.scope.1 ∈ (oownParts ord s w).drop k)
  | none => false

def inPhase1 (ord : List TLabel → List TLabel) (s : OState N V) (w : Scope) (k : Nat) (n : N) : Bool :=
  !hasOwn s w n &&
    match osharedResolve s w n with
    | some c => decide (c.scope.1 ∈ (osharedParts ord s w).drop k)
    | none => false

def oscan (ord : List TLabel → List TLabel) (s : OState N V) (w : Scope) (ph k : Nat) : List N :=
  if isUserO w.2 then
    if ph = 0 ∧ k < (oownParts ord s w).length then
      (ovisibleNames s w).filter (fun n => inPhase0 ord s w k n || inPhase1 ord s w 0 n)
    else (ovisibleNames s w).filter (inPhase1 ord s w (if ph = 0 then 0 else k))
  else (ovisibleNames s w).filter (inPhase1 ord s w k)

inductive OQ (N : Type) where
  | get (n : N)
  | many (ns : List N)
  | labelOf (n : N)
  | dbsize
  | keys (p : N → Bool)
  | scan (ph k : Nat)

inductive OReply (N V : Type) where
  | copy (c : Option (OCopy N V))
  | copies (cs : List (Option (OCopy N V)))
  | scope (l : Option Scope)
  | size (k : Nat)
  | names (ns : List N)
  | scanned (own shared : Nat) (ns : List N)

def oreply (ord : List TLabel → List TLabel) (q : OQ N) (s : OState N V) (w : Scope) : OReply N V :=
  match q with
  | .get n => .copy (oresolve s w n)
  | .many ns => .copies (ns.map (oresolve s w))
  | .labelOf n => .scope ((oresolve s w n).map (·.scope))
  | .dbsize => .size (ovisibleNames s w).length
  | .keys p => .names ((ovisibleNames s w).filter p)
  | .scan ph k => .scanned (oownParts ord s w).length (osharedParts ord s w).length (oscan ord s w ph k)

theorem oresolve_copies {s t : OState N V} (h : s.copies = t.copies) (w : Scope) (n : N) :
    oresolve s w n = oresolve t w n := by
  cases s
  cases t
  simp only at h
  subst h
  rfl

theorem seesP_split {w : Scope} (hw : w.2 ≠ .every) (c : OCopy N V) :
    seesP w c.scope = (isOwn w c || isSharedVis w c) := by
  unfold isOwn isSharedVis seesP
  cases hw2 : w.2 with
  | every => exact absurd hw2 hw
  | shared =>
    cases c.scope.2 <;> simp [odom, isUserO, Bool.and_comm]
  | user u =>
    cases hc : c.scope.2 with
    | shared => simp [odom, isUserO]
    | every => simp [odom, isUserO]
    | user v =>
      by_cases h : u = v
      · subst h; simp [odom, isUserO]
      · have this : v ≠ u := fun e => h e.symm
        have e1 : (u == v) = false := by rw [beq_eq_false_iff_ne]; exact h
        have e2 : (Owner.user v == Owner.user u) = false := by
          rw [beq_eq_false_iff_ne]
          intro e
          exact this (Owner.user.inj e)
        have e3 : (Owner.user v == Owner.shared) = false := by rw [beq_eq_false_iff_ne]; simp
        simp only [odom, isUserO, e1, e2, e3, Bool.and_false, Bool.false_and, Bool.or_false]

theorem isOwn_sees {w : Scope} {c : OCopy N V} (h : isOwn w c = true) : seesP w c.scope = true := by
  unfold isOwn at h
  simp only [Bool.and_eq_true, beq_iff_eq] at h
  rw [seesP_iff]
  exact ⟨h.2, by rw [h.1.2]; exact odom_refl _⟩

theorem isSharedVis_sees {w : Scope} {c : OCopy N V} (h : isSharedVis w c = true) : seesP w c.scope = true := by
  unfold isSharedVis at h
  simp only [Bool.and_eq_true, beq_iff_eq] at h
  rw [seesP_iff]
  exact ⟨h.2, by rw [h.1]; exact odom_shared _⟩

theorem mem_names_filter {p : OCopy N V → Bool} {l : List (OCopy N V)} {n : N} :
    n ∈ uniq ((l.filter p).map (·.name)) ↔ ∃ c ∈ l, c.name = n ∧ p c = true := by
  rw [mem_uniq, List.mem_map]
  constructor
  · rintro ⟨c, hc, rfl⟩
    obtain ⟨h1, h2⟩ := List.mem_filter.1 hc
    exact ⟨c, h1, rfl, h2⟩
  · rintro ⟨c, h1, rfl, h2⟩
    exact ⟨c, List.mem_filter.2 ⟨h1, h2⟩, rfl⟩

theorem mem_ovisibleNames {s : OState N V} {w : Scope} {n : N} (hw : w.2 ≠ .every) :
    n ∈ ovisibleNames s w ↔ (oresolve s w n).isSome := by
  unfold ovisibleNames
  rw [mem_names_filter]
  constructor
  · rintro ⟨c, hc, hn, hv⟩
    cases hr : oresolve s w n with
    | some _ => rfl
    | none =>
      have := (oresolve_none hw).1 hr c hc hn
      rw [this] at hv
      simp at hv
  · intro h
    cases hr : oresolve s w n with
    | none => rw [hr] at h; simp at h
    | some c =>
      obtain ⟨h1, h2, h3⟩ := oresolve_visible hr
      exact ⟨c, h1, h2, h3⟩

theorem ovisibleNames_nodup (s : OState N V) (w : Scope) : (ovisibleNames s w).Nodup := uniq_nodup _

theorem len_split {α : Type} (p : α → Bool) : ∀ (l : List α),
    l.length = (l.filter p).length + (l.filter (fun x => !p x)).length
  | [] => rfl
  | x :: xs => by
    have ih := len_split p xs
    cases hx : p x <;> simp [List.filter, hx] <;> omega

theorem union_count {α : Type} [DecidableEq α] (V A B : List α) (hV : V.Nodup) (hA : A.Nodup) (hB : B.Nodup)
    (hm : ∀ x, x ∈ V ↔ x ∈ A ∨ x ∈ B) :
    V.length + (B.filter (fun x => decide (x ∈ A))).length = A.length + B.length := by
  have hB' : (B.filter (fun x => !decide (x ∈ A))).Nodup := List.Nodup.sublist List.filter_sublist hB
  have hAB : (A ++ B.filter (fun x => !decide (x ∈ A))).Nodup := by
    refine List.nodup_append.2 ⟨hA, hB', ?_⟩
    intro a ha b hb e
    subst e
    have := (List.mem_filter.1 hb).2
    simp [ha] at this
  have hmem : ∀ x, x ∈ V ↔ x ∈ A ++ B.filter (fun x => !decide (x ∈ A)) := by
    intro x
    rw [hm, List.mem_append, List.mem_filter]
    by_cases hx : x ∈ A <;> simp [hx]
  have h1 := ((List.perm_ext_iff_of_nodup hV hAB).2 hmem).length_eq
  rw [List.length_append] at h1
  have h2 := len_split (fun x => decide (x ∈ A)) B
  omega

theorem odbsize_cross {w : Scope} (hw : w.2 ≠ .every) (s : OState N V) :
    (ovisibleNames s w).length + (crossNames s w).length = (sharedNames s w).length + (ownNames s w).length := by
  apply union_count _ _ _ (ovisibleNames_nodup s w) (uniq_nodup _) (uniq_nodup _)
  intro n
  unfold ovisibleNames
  rw [mem_names_filter, mem_names_filter, mem_names_filter]
  constructor
  · rintro ⟨c, hc, hn, hv⟩
    rw [seesP_split hw] at hv
    rcases Bool.or_eq_true_iff.1 hv with h | h
    · exact Or.inr ⟨c, hc, hn, h⟩
    · exact Or.inl ⟨c, hc, hn, h⟩
  · rintro (⟨c, hc, hn, h⟩ | ⟨c, hc, hn, h⟩)
    · exact ⟨c, hc, hn, isSharedVis_sees h⟩
    · exact ⟨c, hc, hn, isOwn_sees h⟩

theorem filter_seesP_restrict_of {R w : Scope} (hw : seesP R w = true) (l : List (OCopy N V)) :
    (l.filter (fun c => seesP R c.scope)).filter (fun c => seesP w c.scope) = l.filter (fun c => seesP w c.scope) :=
  filter_filter_of _ _ (fun c hc => seesP_trans hw hc) l

theorem orestrict_restrict_of {R w : Scope} (hw : seesP R w = true) (s : OState N V) :
    orestrict w (orestrict R s) = orestrict w s := by
  unfold orestrict
  simp only [OState.mk.injEq]
  exact ⟨filter_seesP_restrict_of hw _, filter_filter_of _ _ (fun p hp => seesP_trans hw hp) _⟩

theorem ovisibleNames_restrict_of {R w : Scope} (hw : seesP R w = true) (s : OState N V) :
    ovisibleNames (orestrict R s) w = ovisibleNames s w := by
  unfold ovisibleNames orestrict
  simp only
  rw [filter_seesP_restrict_of hw]

theorem hasOwn_restrict_of {R w : Scope} (hw : seesP R w = true) (s : OState N V) (n : N) :
    hasOwn (orestrict R s) w n = hasOwn s w n := by
  unfold hasOwn orestrict
  simp only
  rw [List.any_filter]
  congr 1
  funext c
  cases ho : isOwn w c with
  | false => simp
  | true => simp [seesP_trans hw (isOwn_sees ho)]

theorem ownOnly_restrict_copies {R w : Scope} (hw : seesP R w = true) (s : OState N V) :
    (orestrict w (ownOnly w (orestrict R s))).copies = (orestrict w (ownOnly w s)).copies := by
  unfold ownOnly orestrict
  simp only [List.filter_filter]
  apply List.filter_congr
  intro c _
  cases hv : seesP w c.scope with
  | false => simp
  | true => simp [seesP_trans hw hv]

theorem oownResolve_restrict_of {R w : Scope} (hw : seesP R w = true) (s : OState N V) (n : N) :
    oownResolve (orestrict R s) w n = oownResolve s w n := by
  unfold oownResolve
  split
  · rw [← oresolve_restrict w (ownOnly w (orestrict R s)), oresolve_copies (ownOnly_restrict_copies hw s),
      oresolve_restrict]
  · rfl

theorem osharedResolve_restrict_of {R w : Scope} (hw : seesP R w = true) (s : OState N V) (n : N) :
    osharedResolve (orestrict R s) w n = osharedResolve s w n := by
  unfold osharedResolve
  have hw' : seesP R (w.1, .shared) = true := shared_of_sees hw
  rw [← oresolve_restrict (w.1, .shared) (ownOnly (w.1, .shared) (orestrict R s)),
    oresolve_copies (ownOnly_restrict_copies hw' s), oresolve_restrict]

theorem oownParts_restrict_of (ord : List TLabel → List TLabel) {R w : Scope} (hw : seesP R w = true)
    (s : OState N V) : oownParts ord (orestrict R s) w = oownParts ord s w := by
  unfold oownParts orestrict
  simp only
  rw [filter_filter_of]
  intro p hp
  simp only [Bool.and_eq_true, beq_iff_eq] at hp
  apply seesP_trans hw
  rw [seesP_iff]
  exact ⟨hp.2, by rw [hp.1.2]; exact odom_refl _⟩

theorem osharedParts_restrict_of (ord : List TLabel → List TLabel) {R w : Scope} (hw : seesP R w = true)
    (s : OState N V) : osharedParts ord (orestrict R s) w = osharedParts ord s w := by
  unfold osharedParts orestrict
  simp only
  rw [filter_filter_of]
  intro p hp
  simp only [Bool.and_eq_true, beq_iff_eq] at hp
  apply seesP_trans hw
  rw [seesP_iff]
  exact ⟨hp.2, by rw [hp.1]; exact odom_shared _⟩

theorem inPhase0_restrict_of (ord : List TLabel → List TLabel) {R w : Scope} (hw : seesP R w = true)
    (s : OState N V) (k : Nat) : inPhase0 ord (orestrict R s) w k = inPhase0 ord s w k := by
  funext n
  unfold inPhase0
  rw [oownResolve_restrict_of hw, oownParts_restrict_of ord hw]

theorem inPhase1_restrict_of (ord : List TLabel → List TLabel) {R w : Scope} (hw : seesP R w = true)
    (s : OState N V) (k : Nat) : inPhase1 ord (orestrict R s) w k = inPhase1 ord s w k := by
  funext n
  unfold inPhase1
  rw [hasOwn_restrict_of hw, osharedResolve_restrict_of hw, osharedParts_restrict_of ord hw]

theorem oscan_restrict_of (ord : List TLabel → List TLabel) {R w : Scope} (hw : seesP R w = true)
    (s : OState N V) (ph k : Nat) : oscan ord (orestrict R s) w ph k = oscan ord s w ph k := by
  unfold oscan
  rw [ovisibleNames_restrict_of hw, oownParts_restrict_of ord hw, inPhase0_restrict_of ord hw,
    inPhase1_restrict_of ord hw, inPhase1_restrict_of ord hw, inPhase1_restrict_of ord hw]

theorem oreply_restrict_of (ord : List TLabel → List TLabel) (q : OQ N) {R w : Scope} (hw : seesP R w = true)
    (s : OState N V) : oreply ord q (orestrict R s) w = oreply ord q s w := by
  cases q with
  | get n => simp only [oreply, oresolve_restrict_of hw]
  | many ns =>
    simp only [oreply]
    congr 1
    apply List.map_congr_left
    intro n _
    exact oresolve_restrict_of hw s n
  | labelOf n => simp only [oreply, oresolve_restrict_of hw]
  | dbsize => simp only [oreply, ovisibleNames_restrict_of hw]
  | keys p => simp only [oreply, ovisibleNames_restrict_of hw]
  | scan ph k =>
    simp only [oreply, oownParts_restrict_of ord hw, osharedParts_restrict_of ord hw, oscan_restrict_of ord hw]

theorem oreply_restrict (ord : List TLabel → List TLabel) (q : OQ N) (w : Scope) (s : OState N V) :
    oreply ord q (orestrict w s) w = oreply ord q s w :=
  oreply_restrict_of ord q (seesP_refl w) s

theorem olabelOf_suffix {ord : List TLabel → List TLabel} {s : OState N V} {w : Scope} {n : N} {sc : Scope}
    (hw : w.2 ≠ .every) (h : oreply ord (.labelOf n) s w = .scope (some sc)) :
    seesP w sc = true ∧ (sc.2 = .shared ∨ sc.2 = w.2) := by
  simp only [oreply, OReply.scope.injEq] at h
  cases hr : oresolve s w n with
  | none => rw [hr] at h; simp at h
  | some c =>
    rw [hr] at h
    simp only [Option.map_some, Option.some.injEq] at h
    subst h
    exact ⟨(oresolve_visible hr).2.2, oresolve_owner hw hr⟩

theorem odbsize_spec (ord : List TLabel → List TLabel) (s : OState N V) {w : Scope} (hw : w.2 ≠ .every) :
    ∃ ns : List N, ns.Nodup ∧ (∀ n, n ∈ ns ↔ (oresolve s w n).isSome) ∧ oreply ord .dbsize s w = .size ns.length :=
  ⟨ovisibleNames s w, ovisibleNames_nodup s w, fun _ => mem_ovisibleNames hw, rfl⟩

theorem okeys_spec {ord : List TLabel → List TLabel} {s : OState N V} {w : Scope} {p : N → Bool} {ns : List N}
    (hw : w.2 ≠ .every) (h : oreply ord (.keys p) s w = .names ns) :
    ns.Nodup ∧ ∀ n, n ∈ ns ↔ p n = true ∧ (oresolve s w n).isSome := by
  simp only [oreply, OReply.names.injEq] at h
  subst h
  refine ⟨(ovisibleNames_nodup s w).filter p, fun n => ?_⟩
  rw [List.mem_filter, mem_ovisibleNames hw]
  exact and_comm

theorem oownResolve_own {s : OState N V} {w : Scope} {n : N} {c : OCopy N V} (h : oownResolve s w n = some c) :
    c ∈ s.copies ∧ c.name = n ∧ isOwn w c = true := by
  unfold oownResolve at h
  split at h
  · rename_i hu
    obtain ⟨h1, h2, h3⟩ := oresolve_visible h
    have hm := (List.mem_filter.1 h1)
    have he : c.scope.2 = w.2 := by simpa using hm.2
    refine ⟨hm.1, h2, ?_⟩
    unfold isOwn
    rw [hu, he]
    simp only [Bool.true_and, beq_self_eq_true]
    exact ((seesP_iff _ _).1 h3).1
  · simp at h

theorem oscan_disjoint (ord : List TLabel → List TLabel) (s : OState N V) (w : Scope) (k j : Nat) (n : N)
    (h : inPhase0 ord s w k n = true) : inPhase1 ord s w j n = false := by
  unfold inPhase0 at h
  split at h
  · rename_i c hc
    obtain ⟨h1, h2, h3⟩ := oownResolve_own hc
    have : hasOwn s w n = true := List.any_eq_true.2 ⟨c, h1, by simp [h2, h3]⟩
    simp [inPhase1, this]
  · simp at h

theorem oscan_visible {ord : List TLabel → List TLabel} {s : OState N V} {w : Scope} {ph k : Nat} {n : N}
    (hw : w.2 ≠ .every) (h : n ∈ oscan ord s w ph k) : (oresolve s w n).isSome := by
  unfold oscan at h
  split at h
  · split at h <;> exact (mem_ovisibleNames hw).1 (List.mem_filter.1 h).1
  · exact (mem_ovisibleNames hw).1 (List.mem_filter.1 h).1

def OCover (s : OState N V) : Prop := ∀ c ∈ s.copies, c.scope ∈ s.parts

theorem oownResolve_some {s : OState N V} {w : Scope} {n : N} (hw : w.2 ≠ .every) (hu : isUserO w.2 = true)
    (h : hasOwn s w n = true) : (oownResolve s w n).isSome := by
  obtain ⟨c, hc, hp⟩ := List.any_eq_true.1 h
  simp only [Bool.and_eq_true, beq_iff_eq] at hp
  unfold oownResolve
  rw [hu]
  simp only [↓reduceIte]
  cases hr : oresolve (ownOnly w s) w n with
  | some _ => rfl
  | none =>
    have hown := hp.2
    unfold isOwn at hown
    simp only [Bool.and_eq_true, beq_iff_eq] at hown
    have hm : c ∈ (ownOnly w s).copies := List.mem_filter.2 ⟨hc, by simp [hown.1.2]⟩
    have hf := (oresolve_none hw).1 hr c hm hp.1
    have ht : seesP w c.scope = true := by
      rw [seesP_iff]
      exact ⟨hown.2, by rw [hown.1.2]; exact odom_refl _⟩
    rw [ht] at hf
    exact absurd hf (by decide)

theorem oscan_complete {ord : List TLabel → List TLabel} (hord : ∀ L l, l ∈ ord L ↔ l ∈ L) {s : OState N V}
    (hc : OCover s) {w : Scope} (hw : w.2 ≠ .every) : oscan ord s w 0 0 = ovisibleNames s w := by
  have phase1 : ∀ n, n ∈ ovisibleNames s w → hasOwn s w n = false → inPhase1 ord s w 0 n = true := by
    intro n hn ho
    unfold inPhase1
    rw [ho]
    simp only [Bool.not_false, Bool.true_and]
    obtain ⟨c, hcm, hcn, hv⟩ := mem_names_filter.1 hn
    rw [seesP_split hw] at hv
    have hs : isSharedVis w c = true := by
      rcases Bool.or_eq_true_iff.1 hv with h | h
      · have : hasOwn s w n = true := List.any_eq_true.2 ⟨c, hcm, by simp [hcn, h]⟩
        rw [ho] at this
        exact absurd this (by decide)
      · exact h
    unfold isSharedVis at hs
    simp only [Bool.and_eq_true, beq_iff_eq] at hs
    cases hr : osharedResolve s w n with
    | none =>
      exfalso
      have hm : c ∈ (ownOnly (w.1, .shared) s).copies := List.mem_filter.2 ⟨hcm, by simp [hs.1]⟩
      have := (oresolve_none (w := (w.1, .shared)) (by simp)).1 hr c hm hcn
      rw [show c.scope = (c.scope.1, Owner.shared) from Prod.ext rfl hs.1, seesP_shared_data] at this
      rw [hs.2] at this
      exact absurd this (by decide)
    | some d =>
      obtain ⟨d1, _, d3⟩ := oresolve_visible hr
      have dm := List.mem_filter.1 d1
      have dsh : d.scope.2 = .shared := by simpa using dm.2
      simp only [List.drop_zero, decide_eq_true_eq]
      unfold osharedParts
      rw [hord, List.mem_map]
      refine ⟨d.scope, List.mem_filter.2 ⟨hc d dm.1, ?_⟩, rfl⟩
      rw [show d.scope = (d.scope.1, Owner.shared) from Prod.ext rfl dsh, seesP_shared_data] at d3
      simp [dsh, d3]
  have phase0 : ∀ n, n ∈ ovisibleNames s w → hasOwn s w n = true → inPhase0 ord s w 0 n = true := by
    intro n _ ho
    have hu : isUserO w.2 = true := by
      obtain ⟨c, _, hp⟩ := List.any_eq_true.1 ho
      simp only [Bool.and_eq_true] at hp
      unfold isOwn at hp
      simp only [Bool.and_eq_true] at hp
      exact hp.2.1.1
    unfold inPhase0
    cases hr : oownResolve s w n with
    | none =>
      have := oownResolve_some hw hu ho
      rw [hr] at this
      simp at this
    | some c =>
      obtain ⟨h1, _, h3⟩ := oownResolve_own hr
      unfold isOwn at h3
      simp only [Bool.and_eq_true, beq_iff_eq] at h3
      simp only [List.drop_zero, decide_eq_true_eq]
      unfold oownParts
      rw [hord, List.mem_map]
      exact ⟨c.scope, List.mem_filter.2 ⟨hc c h1, by simp [h3.1.1, h3.1.2, h3.2]⟩, rfl⟩
  have ownlen : ∀ n, n ∈ ovisibleNames s w → hasOwn s w n = true → 0 < (oownParts ord s w).length := by
    intro n hn ho
    have h0 := phase0 n hn ho
    unfold inPhase0 at h0
    split at h0
    · simp only [List.drop_zero, decide_eq_true_eq] at h0
      exact List.length_pos_of_mem h0
    · simp at h0
  unfold oscan
  split
  · rename_i hu
    split
    · apply List.filter_eq_self.2
      intro n hn
      cases ho : hasOwn s w n with
      | true => simp [phase0 n hn ho]
      | false => simp [phase1 n hn ho]
    · rename_i hk
      apply List.filter_eq_self.2
      intro n hn
      cases ho : hasOwn s w n with
      | true =>
        exfalso
        exact hk ⟨rfl, ownlen n hn ho⟩
      | false => simpa using phase1 n hn ho
  · rename_i hu
    apply List.filter_eq_self.2
    intro n hn
    have ho : hasOwn s w n = false := by
      unfold hasOwn
      apply List.any_eq_false.2
      intro c _
      simp [isOwn, hu]
    exact phase1 n hn ho

theorem orandom_visible (pickN : List N → Option N) (hp : ∀ l x, pickN l = some x → x ∈ l)
    (hn : ∀ l, pickN l = none → l = []) (s : OState N V) {w : Scope} (hw : w.2 ≠ .every) :
    (∀ x, pickN (ovisibleNames s w) = some x → ∃ c, oresolve s w x = some c ∧ seesP w c.scope = true) ∧
    (pickN (ovisibleNames s w) = none → ∀ n, oresolve s w n = none) := by
  constructor
  · intro x hx
    have hs := (mem_ovisibleNames hw).1 (hp _ x hx)
    cases hr : oresolve s w x with
    | none => rw [hr] at hs; simp at hs
    | some c => exact ⟨c, rfl, (oresolve_visible hr).2.2⟩
  · intro hnone n
    have hnil := hn _ hnone
    cases hr : oresolve s w n with
    | none => rfl
    | some c =>
      have : n ∈ ovisibleNames s w := (mem_ovisibleNames hw).2 (by rw [hr]; rfl)
      rw [hnil] at this
      simp at this

theorem orandom_restrict_of (pickN : List N → Option N) {R w : Scope} (hw : seesP R w = true) (s : OState N V) :
    pickN (ovisibleNames (orestrict R s) w) = pickN (ovisibleNames s w) := by
  rw [ovisibleNames_restrict_of hw]

end OwnerKeyReads

end Labels
