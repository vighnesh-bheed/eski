import Labels.OwnerKeyPurge

namespace Labels

section OwnerForget
set_option linter.unusedSectionVars false
variable {N V : Type} [DecidableEq N]

theorem forget_gone (o : Owner) (s : OState N V) :
    (∀ c ∈ (oforget o s).copies, c.scope.2 ≠ o) ∧ ∀ p ∈ (oforget o s).parts, p.2 ≠ o := by
  unfold oforget
  constructor
  · intro c hc
    simpa using (List.mem_filter.1 hc).2
  · intro p hp
    simpa using (List.mem_filter.1 hp).2

theorem forget_keeps (o : Owner) (s : OState N V) (c : OCopy N V) :
    c ∈ (oforget o s).copies ↔ c ∈ s.copies ∧ c.scope.2 ≠ o := by
  unfold oforget
  simp [List.mem_filter]

theorem forget_keeps_parts (o : Owner) (s : OState N V) (p : Scope) :
    p ∈ (oforget o s).parts ↔ p ∈ s.parts ∧ p.2 ≠ o := by
  unfold oforget
  simp [List.mem_filter]

theorem forget_order (o : Owner) (s : OState N V) :
    (oforget o s).copies = s.copies.filter (fun c => c.scope.2 != o) := rfl

theorem forget_purgeable {u : List Nat} {R : Scope} (h1 : R.2 ≠ .user u) (h2 : R.2 ≠ .every) (s : OState N V) :
    orestrict R (oforget (.user u) s) = orestrict R s := by
  rw [oforget_as_filter]
  exact restrict_filter_keeps (keeps_drop h1 h2) s

theorem forget_reply (ord : List TLabel → List TLabel) (q : OQ N) {u : List Nat} {R : Scope} (h1 : R.2 ≠ .user u)
    (h2 : R.2 ≠ .every) (s : OState N V) : oreply ord q (oforget (.user u) s) R = oreply ord q s R := by
  rw [← oreply_restrict ord q R (oforget (.user u) s), forget_purgeable h1 h2, oreply_restrict]

def isForget (u : List Nat) (c : OKCmd N V) : Bool :=
  match c.op with
  | .forget v => v == u
  | _ => false

def fseen (R l : Scope × Bool) : Bool := seesP R.1 l.1 && !l.2

def flab (u : List Nat) (c : OKCmd N V) : Scope × Bool := (c.scope, isForget u c)

def FAllowed (u : List Nat) (c : OKCmd N V) : Prop := OLocal c ∨ isForget u c = true

theorem forget_history (ord : List TLabel → List TLabel) (u : List Nat) (R : Scope) (h1 : R.2 ≠ .user u)
    (h2 : R.2 ≠ .every) (cs : List (OKCmd N V)) (hd : ∀ c ∈ cs, FAllowed u c) (s t : OState N V)
    (he : orestrict R s = orestrict R t) :
    outsK fseen (flab u) ocstep (ocreply ord) (R, false) cs s =
      outsK fseen (flab u) ocstep (ocreply ord) (R, false) (purgeK fseen (flab u) (R, false) cs) t := by
  apply unwindingK fseen (flab u) ocstep (ocreply ord) (R, false) (FAllowed u) (orestrict R)
  · intro c s hc hv
    cases hf : isForget u c with
    | true =>
      unfold isForget at hf
      unfold ocstep
      split
      · rename_i op hop; simp [hop] at hf
      · rename_i q hop; simp [hop] at hf
      · rename_i f hop; simp [hop] at hf
      · rename_i v hop
        rw [hop] at hf
        have : v = u := by simpa using hf
        subst this
        exact forget_purgeable h1 h2 s
    | false =>
      have hl : OLocal c := by
        rcases hc with hc | hc
        · exact hc
        · rw [hf] at hc; exact absurd hc (by decide)
      have hv' : seesP R c.scope = false := by simpa [fseen, flab, hf] using hv
      exact ocstep_local hl hv' s
  · intro c s t hc he hv
    have hf : isForget u c = false := by
      cases h : isForget u c with
      | false => rfl
      | true => simp [fseen, flab, h] at hv
    have hl : OLocal c := by
      rcases hc with hc | hc
      · exact hc
      · rw [hf] at hc; exact absurd hc (by decide)
    have hv' : seesP R c.scope = true := by simpa [fseen, flab, hf] using hv
    exact ocstep_consistent hl hv' he
  · intro c s t hc he hv
    have hf : isForget u c = false := by
      cases h : isForget u c with
      | false => rfl
      | true => simp [fseen, flab, h] at hv
    have hl : OLocal c := by
      rcases hc with hc | hc
      · exact hc
      · rw [hf] at hc; exact absurd hc (by decide)
    have hv' : seesP R c.scope = true := by simpa [fseen, flab, hf] using hv
    exact ocreply_consistent ord hl hv' he
  · exact hd
  · exact he

theorem forget_view_shared (u : List Nat) (r : TLabel) (s : OState N V) :
    (orestrict (r, .user u) (oforget (.user u) s)).copies = (orestrict (r, .shared) s).copies := by
  unfold orestrict oforget
  simp only [List.filter_filter]
  apply List.filter_congr
  intro c _
  cases hc : c.scope with
  | mk d w =>
    cases w with
    | shared => simp [seesP, odom]
    | every => simp [seesP, odom]
    | user v =>
      by_cases h : v = u
      · subst h; simp [seesP, odom]
      · have h' : u ≠ v := fun e => h e.symm
        simp [seesP, odom, h, h']

theorem forget_no_own (u : List Nat) (s : OState N V) : ∀ c ∈ (oforget (.user u) s).copies, c.scope.2 ≠ .user u :=
  (forget_gone (.user u) s).1

theorem forget_resolve_shared (u : List Nat) (r : TLabel) (s : OState N V) (n : N) :
    oresolve (oforget (.user u) s) (r, .user u) n = oresolve s (r, .shared) n := by
  rw [oresolve_no_own (forget_no_own u s) r n, ← oresolve_restrict (r, .shared) (oforget (.user u) s),
    forget_purgeable (by simp) (by simp), oresolve_restrict]

theorem forget_names_shared (u : List Nat) (r : TLabel) (s : OState N V) :
    ovisibleNames (oforget (.user u) s) (r, .user u) = ovisibleNames s (r, .shared) := by
  have := forget_view_shared u r s
  unfold orestrict at this
  simp only at this
  unfold ovisibleNames
  rw [this]

theorem forget_dbsize_shared (ord : List TLabel → List TLabel) (u : List Nat) (r : TLabel) (s : OState N V) :
    oreply ord .dbsize (oforget (.user u) s) (r, .user u) = oreply ord .dbsize s (r, .shared) := by
  simp only [oreply, forget_names_shared]

theorem forget_scan_shared {ord : List TLabel → List TLabel} (hord : ∀ L l, l ∈ ord L ↔ l ∈ L) (u : List Nat)
    (r : TLabel) (s : OState N V) (k : Nat) :
    oscan ord (oforget (.user u) s) (r, .user u) 0 k = oscan ord s (r, .shared) 0 0 := by
  have hnil : oownParts ord (oforget (.user u) s) (r, .user u) = [] := by
    apply List.eq_nil_iff_forall_not_mem.2
    intro l hl
    unfold oownParts at hl
    rw [hord, List.mem_map] at hl
    obtain ⟨p, hp, _⟩ := hl
    have hm := List.mem_filter.1 hp
    have hg := (forget_gone (.user u) s).2 p hm.1
    simp only [Bool.and_eq_true, beq_iff_eq] at hm
    exact hg hm.2.1.2
  have hown : ∀ n, hasOwn (oforget (.user u) s) (r, .user u) n = false := by
    intro n
    unfold hasOwn
    apply List.any_eq_false.2
    intro c hc
    have := forget_no_own u s c hc
    simp [isOwn, this]
  have hshown : ∀ n, hasOwn s (r, .shared) n = false := by
    intro n
    unfold hasOwn
    apply List.any_eq_false.2
    intro c _
    simp [isOwn, isUserO]
  have hsr : ∀ n, osharedResolve (oforget (.user u) s) (r, .user u) n = osharedResolve s (r, .shared) n := by
    intro n
    unfold osharedResolve
    apply oresolve_copies
    unfold ownOnly oforget
    simp only [List.filter_filter]
    apply List.filter_congr
    intro c _
    cases h : c.scope.2 == Owner.shared with
    | false => simp
    | true =>
      have e : c.scope.2 = .shared := by simpa using h
      simp [e]
  have hsp : osharedParts ord (oforget (.user u) s) (r, .user u) = osharedParts ord s (r, .shared) := by
    unfold osharedParts oforget
    simp only [List.filter_filter]
    congr 2
    apply List.filter_congr
    intro p _
    cases h : p.2 == Owner.shared with
    | false => simp
    | true =>
      have e : p.2 = .shared := by simpa using h
      simp [e]
  have hp1 : inPhase1 ord (oforget (.user u) s) (r, .user u) 0 = inPhase1 ord s (r, .shared) 0 := by
    funext n
    unfold inPhase1
    rw [hown, hshown, hsr, hsp]
  unfold oscan
  simp only [isUserO, ↓reduceIte, hnil, List.length_nil, Bool.false_eq_true]
  rw [forget_names_shared, hp1]
  simp

end OwnerForget

end Labels
