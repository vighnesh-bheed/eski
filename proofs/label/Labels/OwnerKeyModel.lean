import Labels.KeyPlain
import Labels.Owner

namespace Labels

section OwnerKeyModel
set_option linter.unusedSectionVars false
variable {N V : Type} [DecidableEq N]

structure OCopy (N V : Type) where
  name : N
  scope : Scope
  val : V

structure OState (N V : Type) where
  copies : List (OCopy N V)
  parts : List Scope

def isUserO : Owner → Bool
  | .user _ => true
  | _ => false

def ownBit (r o : Owner) : Nat := if isUserO r = true ∧ o = r then 1 else 0

def obetter (r : Owner) (c b : OCopy N V) : Bool :=
  decide (0 < rcmp c.scope.1 b.scope.1) ||
    (decide (rcmp c.scope.1 b.scope.1 = 0) && decide (ownBit r b.scope.2 < ownBit r c.scope.2))

theorem obetter_iff (r : Owner) (c b : OCopy N V) :
    obetter r c b = true ↔ 0 < rcmp c.scope.1 b.scope.1 ∨
      (rcmp c.scope.1 b.scope.1 = 0 ∧ ownBit r b.scope.2 < ownBit r c.scope.2) := by
  simp [obetter]

theorem obetter_trans {r : Owner} {a b c : OCopy N V} (h1 : obetter r a b = true) (h2 : obetter r b c = true) :
    obetter r a c = true := by
  rw [obetter_iff] at h1 h2 ⊢
  generalize ownBit r a.scope.2 = x at *
  generalize ownBit r b.scope.2 = y at *
  generalize ownBit r c.scope.2 = z at *
  simp only [rcmp_pos_iff, rcmp_zero_iff] at h1 h2 ⊢
  omega

theorem obetter_of_not {r : Owner} {a b c : OCopy N V} (h1 : obetter r a b = true) (h2 : obetter r c b = false) :
    obetter r a c = true := by
  have h2' : ¬ obetter r c b = true := by simp [h2]
  rw [obetter_iff] at h1 h2' ⊢
  generalize ownBit r a.scope.2 = x at *
  generalize ownBit r b.scope.2 = y at *
  generalize ownBit r c.scope.2 = z at *
  simp only [rcmp_pos_iff, rcmp_zero_iff] at h1 h2' ⊢
  omega

theorem obetter_asymm {r : Owner} {a b : OCopy N V} (h : obetter r a b = true) : obetter r b a = false := by
  have : ¬ obetter r b a = true := by
    intro h'
    rw [obetter_iff] at h h'
    generalize ownBit r a.scope.2 = x at *
    generalize ownBit r b.scope.2 = y at *
    simp only [rcmp_pos_iff, rcmp_zero_iff] at h h'
    omega
  simpa using this

theorem obetter_irrefl (r : Owner) (a : OCopy N V) : obetter r a a = false := by
  simp [obetter, rcmp_refl]

def opickFrom (r : Owner) : OCopy N V → List (OCopy N V) → OCopy N V
  | b, [] => b
  | b, c :: cs => opickFrom r (if obetter r c b then c else b) cs

def opick (r : Owner) : List (OCopy N V) → Option (OCopy N V)
  | [] => none
  | c :: cs => some (opickFrom r c cs)

theorem opickFrom_spec (r : Owner) (l : List (OCopy N V)) : ∀ (b : OCopy N V),
    (opickFrom r b l = b ∧ ∀ d ∈ l, obetter r d b = false) ∨
    ∃ pre post, l = pre ++ opickFrom r b l :: post ∧ obetter r (opickFrom r b l) b = true ∧
      (∀ d ∈ pre, obetter r (opickFrom r b l) d = true) ∧ ∀ d ∈ post, obetter r d (opickFrom r b l) = false := by
  induction l with
  | nil => intro b; exact Or.inl ⟨rfl, by simp⟩
  | cons c cs ih =>
    intro b
    by_cases hc : obetter r c b = true
    · have hp : opickFrom r b (c :: cs) = opickFrom r c cs := by simp [opickFrom, hc]
      rw [hp]
      rcases ih c with ⟨h1, h2⟩ | ⟨pre, post, h1, h2, h3, h4⟩
      · rw [h1]
        exact Or.inr ⟨[], cs, by simp, hc, by simp, h2⟩
      · refine Or.inr ⟨c :: pre, post, by rw [List.cons_append, ← h1], obetter_trans h2 hc, ?_, h4⟩
        intro d hd
        rcases List.mem_cons.1 hd with rfl | hd
        · exact h2
        · exact h3 d hd
    · have hc' : obetter r c b = false := by simpa using hc
      have hp : opickFrom r b (c :: cs) = opickFrom r b cs := by simp [opickFrom, hc']
      rw [hp]
      rcases ih b with ⟨h1, h2⟩ | ⟨pre, post, h1, h2, h3, h4⟩
      · refine Or.inl ⟨h1, ?_⟩
        intro d hd
        rcases List.mem_cons.1 hd with rfl | hd
        · exact hc'
        · exact h2 d hd
      · refine Or.inr ⟨c :: pre, post, by rw [List.cons_append, ← h1], h2, ?_, h4⟩
        intro d hd
        rcases List.mem_cons.1 hd with rfl | hd
        · exact obetter_of_not h2 hc'
        · exact h3 d hd

theorem opick_spec {r : Owner} {l : List (OCopy N V)} {c : OCopy N V} (h : opick r l = some c) :
    ∃ pre post, l = pre ++ c :: post ∧ (∀ d ∈ pre, obetter r c d = true) ∧ ∀ d ∈ post, obetter r d c = false := by
  cases l with
  | nil => simp [opick] at h
  | cons b bs =>
    simp only [opick, Option.some.injEq] at h
    subst h
    rcases opickFrom_spec r bs b with ⟨h1, h2⟩ | ⟨pre, post, h1, h2, h3, h4⟩
    · rw [h1]
      exact ⟨[], bs, by simp, by simp, h2⟩
    · refine ⟨b :: pre, post, by rw [List.cons_append, ← h1], ?_, h4⟩
      intro d hd
      rcases List.mem_cons.1 hd with rfl | hd
      · exact h2
      · exact h3 d hd

theorem opick_none {r : Owner} {l : List (OCopy N V)} : opick r l = none ↔ l = [] := by
  cases l <;> simp [opick]

theorem opick_mem {r : Owner} {l : List (OCopy N V)} {c : OCopy N V} (h : opick r l = some c) : c ∈ l := by
  obtain ⟨pre, post, h1, _, _⟩ := opick_spec h
  rw [h1]
  simp

theorem opick_best {r : Owner} {l : List (OCopy N V)} {c : OCopy N V} (h : opick r l = some c) :
    ∀ d ∈ l, obetter r d c = false := by
  obtain ⟨pre, post, h1, h2, h3⟩ := opick_spec h
  intro d hd
  rw [h1] at hd
  rcases List.mem_append.1 hd with hd | hd
  · exact obetter_asymm (h2 d hd)
  · rcases List.mem_cons.1 hd with rfl | hd
    · exact obetter_irrefl r d
    · exact h3 d hd

theorem opickFrom_congr {r q : Owner} (hb : ∀ (a b : OCopy N V), obetter r a b = obetter q a b) :
    ∀ (l : List (OCopy N V)) (b : OCopy N V), opickFrom r b l = opickFrom q b l
  | [], _ => rfl
  | c :: cs, b => by
    simp only [opickFrom, hb c b]
    exact opickFrom_congr hb cs _

theorem opickFrom_congr_on {r q : Owner} (P : OCopy N V → Prop)
    (hb : ∀ a b, P a → P b → obetter r a b = obetter q a b) :
    ∀ (l : List (OCopy N V)) (b : OCopy N V), P b → (∀ c ∈ l, P c) → opickFrom r b l = opickFrom q b l
  | [], _, _, _ => rfl
  | c :: cs, b, hpb, hl => by
    have hc := hl c List.mem_cons_self
    have hr : ∀ x ∈ cs, P x := fun x hx => hl x (List.mem_cons_of_mem _ hx)
    simp only [opickFrom, hb c b hc hpb]
    apply opickFrom_congr_on P hb cs
    · split <;> assumption
    · exact hr

theorem opick_congr_on {r q : Owner} (P : OCopy N V → Prop) (hb : ∀ a b, P a → P b → obetter r a b = obetter q a b)
    (l : List (OCopy N V)) (hl : ∀ c ∈ l, P c) : opick r l = opick q l := by
  cases l with
  | nil => rfl
  | cons c cs =>
    simp only [opick, Option.some.injEq]
    exact opickFrom_congr_on P hb cs c (hl c List.mem_cons_self) (fun x hx => hl x (List.mem_cons_of_mem _ hx))

def oexact (s : OState N V) (w : Scope) (n : N) : Option (OCopy N V) :=
  s.copies.find? (fun c => c.name == n && c.scope == w)

def ocands (s : OState N V) (w : Scope) (n : N) : List (OCopy N V) :=
  s.copies.filter (fun c => c.name == n && c.scope.1 != w.1 && seesP w c.scope)

def oother (s : OState N V) (w : Scope) (n : N) : Option (OCopy N V) :=
  match oexact s (w.1, .shared) n with
  | some c => some c
  | none => opick w.2 (ocands s w n)

def oresolve (s : OState N V) (w : Scope) (n : N) : Option (OCopy N V) :=
  match oexact s w n with
  | some c => some c
  | none => oother s w n

def orestrict (w : Scope) (s : OState N V) : OState N V :=
  ⟨s.copies.filter (fun c => seesP w c.scope), s.parts.filter (fun p => seesP w p)⟩

theorem oexact_some {s : OState N V} {w : Scope} {n : N} {c : OCopy N V} (h : oexact s w n = some c) :
    c ∈ s.copies ∧ c.name = n ∧ c.scope = w := by
  unfold oexact at h
  have hm := List.mem_of_find?_eq_some h
  have hp := List.find?_some h
  simp only [Bool.and_eq_true, beq_iff_eq] at hp
  exact ⟨hm, hp.1, hp.2⟩

theorem oexact_none {s : OState N V} {w : Scope} {n : N} (h : oexact s w n = none) :
    ∀ c ∈ s.copies, c.name = n → c.scope ≠ w := by
  unfold oexact at h
  intro c hc hn hl
  have := List.find?_eq_none.1 h c hc
  simp [hn, hl] at this

theorem ocands_mem {s : OState N V} {w : Scope} {n : N} {c : OCopy N V} :
    c ∈ ocands s w n ↔ c ∈ s.copies ∧ c.name = n ∧ c.scope.1 ≠ w.1 ∧ seesP w c.scope = true := by
  unfold ocands
  simp [List.mem_filter, and_assoc]

theorem oresolve_own {s : OState N V} {w : Scope} {n : N} {c : OCopy N V} (h : oexact s w n = some c) :
    oresolve s w n = some c := by
  simp [oresolve, h]

theorem oresolve_shared_exact {s : OState N V} {w : Scope} {n : N} {c : OCopy N V} (ho : oexact s w n = none)
    (h : oexact s (w.1, .shared) n = some c) : oresolve s w n = some c := by
  simp [oresolve, ho, oother, h]

theorem oresolve_rank {s : OState N V} {w : Scope} {n : N} (ho : oexact s w n = none)
    (hs : oexact s (w.1, .shared) n = none) : oresolve s w n = opick w.2 (ocands s w n) := by
  simp [oresolve, ho, oother, hs]

theorem oother_visible {s : OState N V} {w : Scope} {n : N} {c : OCopy N V} (h : oother s w n = some c) :
    c ∈ s.copies ∧ c.name = n ∧ seesP w c.scope = true := by
  unfold oother at h
  split at h
  · rename_i c' hc
    simp only [Option.some.injEq] at h
    subst h
    obtain ⟨h1, h2, h3⟩ := oexact_some hc
    refine ⟨h1, h2, ?_⟩
    rw [h3, seesP_iff]
    exact ⟨domT_refl _, odom_shared _⟩
  · obtain ⟨h1, h2, _, h4⟩ := ocands_mem.1 (opick_mem h)
    exact ⟨h1, h2, h4⟩

theorem oresolve_visible {s : OState N V} {w : Scope} {n : N} {c : OCopy N V} (h : oresolve s w n = some c) :
    c ∈ s.copies ∧ c.name = n ∧ seesP w c.scope = true := by
  unfold oresolve at h
  split at h
  · rename_i c' hc
    simp only [Option.some.injEq] at h
    subst h
    obtain ⟨h1, h2, h3⟩ := oexact_some hc
    exact ⟨h1, h2, by rw [h3]; exact seesP_refl w⟩
  · exact oother_visible h

theorem oresolve_best {s : OState N V} {w : Scope} {n : N} {c : OCopy N V} (ho : oexact s w n = none)
    (hs : oexact s (w.1, .shared) n = none) (h : oresolve s w n = some c) :
    c ∈ ocands s w n ∧ ∀ d ∈ s.copies, d.name = n → seesP w d.scope = true → d.scope.1 ≠ w.1 →
      obetter w.2 d c = false := by
  rw [oresolve_rank ho hs] at h
  exact ⟨opick_mem h, fun d hd hn hv hl => opick_best h d (ocands_mem.2 ⟨hd, hn, hl, hv⟩)⟩

theorem oresolve_oldest {s : OState N V} {w : Scope} {n : N} {c : OCopy N V} (ho : oexact s w n = none)
    (hs : oexact s (w.1, .shared) n = none) (h : oresolve s w n = some c) :
    ∃ pre post, ocands s w n = pre ++ c :: post ∧ (∀ d ∈ pre, obetter w.2 c d = true) ∧
      ∀ d ∈ post, obetter w.2 d c = false := by
  rw [oresolve_rank ho hs] at h
  exact opick_spec h

theorem obetter_own_shared (u : List Nat) (c d : OCopy N V) (hc : c.scope.2 = .user u) (hd : d.scope.2 = .shared)
    (hr : rcmp c.scope.1 d.scope.1 = 0) : obetter (.user u) c d = true := by
  rw [obetter_iff]
  refine Or.inr ⟨hr, ?_⟩
  simp [ownBit, hc, hd, isUserO]

theorem obetter_shared_reader (c d : OCopy N V) : obetter .shared c d = decide (0 < rcmp c.scope.1 d.scope.1) := by
  simp [obetter, ownBit, isUserO]

theorem odom_concrete {r b : Owner} (hr : r ≠ .every) (h : odom r b = true) : b = .shared ∨ b = r := by
  cases r with
  | every => exact absurd rfl hr
  | shared => exact Or.inl ((odom_shared_iff b).1 h)
  | user u =>
    rcases (odom_user_iff u b).1 h with h | h
    · exact Or.inl h
    · exact Or.inr h

theorem same_label_exact {w d : Scope} (hw : w.2 ≠ .every) (hv : seesP w d = true) (hl : d.1 = w.1) :
    d = w ∨ d = (w.1, .shared) := by
  have h2 := ((seesP_iff _ _).1 hv).2
  rcases odom_concrete hw h2 with h | h
  · exact Or.inr (Prod.ext hl h)
  · exact Or.inl (Prod.ext hl h)

theorem oresolve_none {s : OState N V} {w : Scope} {n : N} (hw : w.2 ≠ .every) :
    oresolve s w n = none ↔ ∀ c ∈ s.copies, c.name = n → seesP w c.scope = false := by
  constructor
  · intro h c hc hn
    by_cases hv : seesP w c.scope = true
    · exfalso
      unfold oresolve at h
      split at h
      · simp at h
      · rename_i ho
        unfold oother at h
        split at h
        · simp at h
        · rename_i hs
          have hnil := opick_none.1 h
          by_cases hl : c.scope.1 = w.1
          · rcases same_label_exact hw hv hl with e | e
            · exact oexact_none ho c hc hn e
            · exact oexact_none hs c hc hn e
          · have : c ∈ ocands s w n := ocands_mem.2 ⟨hc, hn, hl, hv⟩
            rw [hnil] at this
            simp at this
    · simpa using hv
  · intro h
    have ho : oexact s w n = none := by
      unfold oexact
      apply List.find?_eq_none.2
      intro c hc
      by_cases hn : c.name = n
      · have hv := h c hc hn
        have hl : c.scope ≠ w := fun e => by rw [e, seesP_refl] at hv; simp at hv
        simp [hn, hl]
      · simp [hn]
    have hs : oexact s (w.1, .shared) n = none := by
      unfold oexact
      apply List.find?_eq_none.2
      intro c hc
      by_cases hn : c.name = n
      · have hv := h c hc hn
        have hl : c.scope ≠ (w.1, .shared) := fun e => by
          rw [e, seesP_shared_data, domT_refl] at hv
          simp at hv
        simp [hn, hl]
      · simp [hn]
    rw [oresolve_rank ho hs]
    apply opick_none.2
    apply List.eq_nil_iff_forall_not_mem.2
    intro c hc
    obtain ⟨h1, h2, _, h4⟩ := ocands_mem.1 hc
    rw [h c h1 h2] at h4
    simp at h4

theorem oexact_restrict_of {R w : Scope} (hw : seesP R w = true) (s : OState N V) (n : N) :
    oexact (orestrict R s) w n = oexact s w n := by
  unfold oexact orestrict
  apply find_filter_of
  intro c hc
  simp only [Bool.and_eq_true, beq_iff_eq] at hc
  rw [hc.2]
  exact hw

theorem shared_of_sees {R w : Scope} (hw : seesP R w = true) : seesP R (w.1, .shared) = true := by
  rw [seesP_iff] at hw ⊢
  exact ⟨hw.1, odom_shared _⟩

theorem ocands_restrict_of {R w : Scope} (hw : seesP R w = true) (s : OState N V) (n : N) :
    ocands (orestrict R s) w n = ocands s w n := by
  unfold ocands orestrict
  apply filter_filter_of
  intro c hc
  simp only [Bool.and_eq_true] at hc
  exact seesP_trans hw hc.2

theorem oother_restrict_of {R w : Scope} (hw : seesP R w = true) (s : OState N V) (n : N) :
    oother (orestrict R s) w n = oother s w n := by
  unfold oother
  rw [oexact_restrict_of (shared_of_sees hw), ocands_restrict_of hw]

theorem oresolve_restrict_of {R w : Scope} (hw : seesP R w = true) (s : OState N V) (n : N) :
    oresolve (orestrict R s) w n = oresolve s w n := by
  unfold oresolve
  rw [oexact_restrict_of hw, oother_restrict_of hw]

theorem oresolve_restrict (w : Scope) (s : OState N V) (n : N) : oresolve (orestrict w s) w n = oresolve s w n :=
  oresolve_restrict_of (seesP_refl w) s n

theorem oresolve_congr {w : Scope} {s t : OState N V}
    (h : s.copies.filter (fun c => seesP w c.scope) = t.copies.filter (fun c => seesP w c.scope)) (n : N) :
    oresolve s w n = oresolve t w n := by
  rw [← oresolve_restrict w s n, ← oresolve_restrict w t n]
  unfold orestrict
  rw [h]
  rfl

theorem oresolve_other_owners {u v : List Nat} (huv : u ≠ v) (r : TLabel) (s : OState N V) (n : N) :
    oresolve s (r, .user u) n = oresolve ⟨s.copies.filter (fun c => c.scope.2 != .user v), s.parts⟩ (r, .user u) n := by
  apply oresolve_congr
  simp only [List.filter_filter]
  apply List.filter_congr
  intro c _
  cases hc : seesP (r, .user u) c.scope with
  | false => simp
  | true =>
    have := ((seesP_iff _ _).1 hc).2
    rcases (odom_user_iff u c.scope.2).1 this with h | h <;> simp [h, huv]

theorem oresolve_owner {s : OState N V} {w : Scope} {n : N} {c : OCopy N V} (hw : w.2 ≠ .every)
    (h : oresolve s w n = some c) : c.scope.2 = .shared ∨ c.scope.2 = w.2 :=
  odom_concrete hw ((seesP_iff _ _).1 (oresolve_visible h).2.2).2

theorem ownBit_shared_reader (o : Owner) : ownBit .shared o = 0 := by simp [ownBit, isUserO]

theorem obetter_no_own {u : List Nat} {a b : OCopy N V} (ha : a.scope.2 ≠ .user u) (hb : b.scope.2 ≠ .user u) :
    obetter (.user u) a b = obetter .shared a b := by
  simp [obetter, ownBit, isUserO, ha, hb]

theorem oresolve_no_own {s : OState N V} {u : List Nat} (h : ∀ c ∈ s.copies, c.scope.2 ≠ .user u) (r : TLabel) (n : N) :
    oresolve s (r, .user u) n = oresolve s (r, .shared) n := by
  have ho : oexact s (r, .user u) n = none := by
    unfold oexact
    apply List.find?_eq_none.2
    intro c hc
    have := h c hc
    simp only [Bool.and_eq_true, beq_iff_eq, not_and]
    intro _ e
    rw [e] at this
    exact this rfl
  have hc : ocands s (r, .user u) n = ocands s (r, .shared) n := by
    unfold ocands
    apply List.filter_congr
    intro c hc
    have hne := h c hc
    cases hv : seesP (r, .user u) c.scope with
    | true =>
      have := ((seesP_iff _ _).1 hv)
      rcases (odom_user_iff u c.scope.2).1 this.2 with e | e
      · simp [seesP, e, this.1, odom]
      · exact absurd e hne
    | false =>
      have : seesP (r, .shared) c.scope = false := by
        cases hs : seesP (r, .shared) c.scope with
        | false => rfl
        | true =>
          have h2 := (seesP_iff _ _).1 hs
          have hsh : c.scope.2 = .shared := (odom_shared_iff _).1 h2.2
          have e : seesP (r, .user u) c.scope = domT r c.scope.1 := by
            rw [show c.scope = (c.scope.1, Owner.shared) from Prod.ext rfl hsh]
            exact seesP_shared_data _ _ _
          rw [e] at hv
          simp only at h2
          rw [hv] at h2
          simp at h2
      simp [this]
  unfold oresolve
  rw [ho]
  unfold oother
  simp only
  cases hx : oexact s (r, .shared) n with
  | some c => rfl
  | none =>
    rw [hc]
    apply opick_congr_on (fun c => c.scope.2 ≠ .user u) (fun a b ha hb => obetter_no_own ha hb)
    intro c hc'
    exact h c (ocands_mem.1 hc').1

theorem one_label_own_then_shared {s : OState N V} {l : TLabel} (h : ∀ c ∈ s.copies, c.scope.1 = l) (o : Owner)
    (n : N) : oresolve s (l, o) n = match oexact s (l, o) n with
      | some c => some c
      | none => oexact s (l, .shared) n := by
  have hc : ocands s (l, o) n = [] := by
    apply List.eq_nil_iff_forall_not_mem.2
    intro c hc
    obtain ⟨h1, _, h3, _⟩ := ocands_mem.1 hc
    exact h3 (h c h1)
  unfold oresolve oother
  simp only [hc, opick]
  cases oexact s (l, o) n with
  | some c => rfl
  | none =>
    cases oexact s (l, .shared) n <;> rfl

end OwnerKeyModel

end Labels
