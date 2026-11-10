import Labels.Trust

namespace Labels

inductive Owner where
  | shared
  | user (id : List Nat)
  | every
deriving DecidableEq, Repr

def odom : Owner → Owner → Bool
  | .every, _ => true
  | _, .shared => true
  | .user a, .user b => a == b
  | _, _ => false

theorem odom_refl (o : Owner) : odom o o = true := by
  cases o <;> simp [odom]

theorem odom_shared (o : Owner) : odom o .shared = true := by
  cases o <;> simp [odom]

theorem odom_every (o : Owner) : odom .every o = true := by
  cases o <;> simp [odom]

theorem odom_shared_iff (o : Owner) : odom .shared o = true ↔ o = .shared := by
  cases o <;> simp [odom]

theorem odom_to_every_iff (o : Owner) : odom o .every = true ↔ o = .every := by
  cases o <;> simp [odom]

theorem odom_users (a b : List Nat) : odom (.user a) (.user b) = true ↔ a = b := by
  simp [odom]

theorem odom_trans {a b c : Owner} (h1 : odom a b = true) (h2 : odom b c = true) : odom a c = true := by
  cases a <;> cases b <;> cases c <;> simp_all [odom]

theorem odom_antisymm {a b : Owner} (h1 : odom a b = true) (h2 : odom b a = true) : a = b := by
  cases a <;> cases b <;> simp_all [odom]

theorem odom_user_iff (u : List Nat) (o : Owner) : odom (.user u) o = true ↔ o = .shared ∨ o = .user u := by
  cases o with
  | shared => simp [odom]
  | user v =>
    simp only [odom, beq_iff_eq, Owner.user.injEq, reduceCtorEq, false_or]
    exact ⟨fun h => h.symm, fun h => h.symm⟩
  | every => simp [odom]

theorem users_incomparable {a b : List Nat} (h : a ≠ b) : odom (.user a) (.user b) = false ∧ odom (.user b) (.user a) = false := by
  simp only [odom, beq_eq_false_iff_ne, ne_eq]
  exact ⟨h, fun e => h e.symm⟩

abbrev Scope := TLabel × Owner

def seesP (r d : Scope) : Bool := domT r.1 d.1 && odom r.2 d.2

theorem seesP_iff (r d : Scope) : seesP r d = true ↔ domT r.1 d.1 = true ∧ odom r.2 d.2 = true := by
  simp [seesP]

theorem seesP_refl (s : Scope) : seesP s s = true := by
  rw [seesP_iff]
  exact ⟨domT_refl _, odom_refl _⟩

theorem seesP_trans {a b c : Scope} (h1 : seesP a b = true) (h2 : seesP b c = true) : seesP a c = true := by
  rw [seesP_iff] at h1 h2 ⊢
  exact ⟨domT_trans h1.1 h2.1, odom_trans h1.2 h2.2⟩

theorem seesP_antisymm {a b : Scope} (h1 : seesP a b = true) (h2 : seesP b a = true) : a = b := by
  rw [seesP_iff] at h1 h2
  exact Prod.ext (domT_antisymm h1.1 h2.1) (odom_antisymm h1.2 h2.2)

theorem seesP_user_iff (r d : TLabel) (u : List Nat) (w : Owner) :
    seesP (r, .user u) (d, w) = true ↔ domT r d = true ∧ (w = .shared ∨ w = .user u) := by
  rw [seesP_iff]
  simp only
  rw [odom_user_iff]

theorem seesP_shared_data (r d : TLabel) (o : Owner) : seesP (r, o) (d, .shared) = domT r d := by
  simp [seesP, odom_shared]

theorem seesP_plain (r d : TLabel) : seesP (r, .shared) (d, .shared) = domT r d := seesP_shared_data r d .shared

theorem owner_isolation {u v : List Nat} (h : u ≠ v) (r d : TLabel) :
    seesP (r, .user u) (d, .user v) = false ∧ seesP (d, .user v) (r, .user u) = false := by
  obtain ⟨h1, h2⟩ := users_incomparable h
  simp [seesP, h1, h2]

theorem shared_reader_sees_only_shared (r d : TLabel) (w : Owner) : seesP (r, .shared) (d, w) = true → w = .shared := by
  intro h
  rw [seesP_iff] at h
  exact (odom_shared_iff w).1 h.2

def orank (r a b : Owner) : Int :=
  match r with
  | .user u =>
    if a = b then 0
    else if a = .user u ∧ b = .shared then 1
    else if b = .user u ∧ a = .shared then -1
    else 0
  | _ => 0

def scmp (r : Owner) (a b : Scope) : Int := if rcmp a.1 b.1 ≠ 0 then rcmp a.1 b.1 else orank r a.2 b.2

theorem orank_antisymm (r a b : Owner) : orank r a b = - orank r b a := by
  cases r with
  | user u =>
    simp only [orank]
    by_cases h1 : a = b
    · subst h1
      simp
    · have h1' : ¬ b = a := fun e => h1 e.symm
      by_cases h2 : a = .user u ∧ b = .shared
      · obtain ⟨rfl, rfl⟩ := h2
        simp
      · by_cases h3 : b = .user u ∧ a = .shared
        · obtain ⟨rfl, rfl⟩ := h3
          simp
        · simp [h1, h1', h2, h3]
  | shared => simp [orank]
  | every => simp [orank]

theorem orank_visible {r a b : Owner} (h : orank r a b ≠ 0) : odom r a = true ∧ odom r b = true := by
  cases r with
  | user u =>
    simp only [orank] at h
    by_cases h1 : a = b
    · simp [h1] at h
    · by_cases h2 : a = .user u ∧ b = .shared
      · obtain ⟨rfl, rfl⟩ := h2
        simp [odom]
      · by_cases h3 : b = .user u ∧ a = .shared
        · obtain ⟨rfl, rfl⟩ := h3
          simp [odom]
        · simp [h1, h2, h3] at h
  | shared => simp [orank] at h
  | every => simp [orank] at h

theorem scmp_antisymm (r : Owner) (a b : Scope) : scmp r a b = - scmp r b a := by
  unfold scmp
  have hr := rcmp_antisymm a.1 b.1
  by_cases h : rcmp a.1 b.1 = 0
  · have h' : rcmp b.1 a.1 = 0 := by omega
    simp [h, h', orank_antisymm r a.2 b.2]
  · have h' : rcmp b.1 a.1 ≠ 0 := by omega
    simp [h', hr]

theorem scmp_label_first (r : Owner) (a b : Scope) (h : rcmp a.1 b.1 ≠ 0) : scmp r a b = rcmp a.1 b.1 := by
  simp [scmp, h]

theorem scmp_own_before_shared (u : List Nat) (l m : TLabel) (h : rcmp l m = 0) :
    scmp (.user u) (l, .user u) (m, .shared) = 1 := by
  simp [scmp, h, orank]

theorem scmp_shared_reader (a b : Scope) : scmp .shared a b = rcmp a.1 b.1 := by
  unfold scmp
  by_cases h : rcmp a.1 b.1 = 0 <;> simp [h, orank]

theorem scmp_all_shared (r : Owner) (l m : TLabel) : scmp r (l, .shared) (m, .shared) = rcmp l m := by
  unfold scmp
  by_cases h : rcmp l m = 0
  · cases r <;> simp [h, orank]
  · simp [h]

theorem scmp_tie_visible {r : Owner} {a b : Scope} (h1 : rcmp a.1 b.1 = 0) (h2 : scmp r a b ≠ 0) :
    odom r a.2 = true ∧ odom r b.2 = true := by
  simp only [scmp, h1, ne_eq, not_true_eq_false, ↓reduceIte] at h2
  exact orank_visible h2

inductive OKind where
  | none
  | any
  | fixed (id : List Nat)
deriving DecidableEq, Repr

structure ORules where
  kind : OKind
  shared : Bool
  operator : Bool
deriving DecidableEq, Repr

def noORules : ORules := ⟨.none, false, false⟩

def textValid (t : List Nat) : Bool := decide (0 < t.length) && decide (t.length ≤ 128) && t.all (fun b => decide (33 ≤ b) && decide (b ≤ 126))

def mayActText (r : ORules) (t : List Nat) : Bool :=
  match r.kind with
  | .any => true
  | .fixed v => t == v
  | .none => false

def mayAct (r : ORules) : Owner → Bool
  | .every => false
  | .shared => r.kind == .none || r.shared
  | .user u => mayActText r u

def mayPin (r : ORules) : Owner → Bool
  | .every => r.operator && r.kind == .any
  | o => mayAct r o

theorem mayAct_never_every (r : ORules) : mayAct r .every = false := rfl

theorem mayAct_no_rule (o : Owner) : mayAct noORules o = true ↔ o = .shared := by
  cases o <;> simp [mayAct, mayActText, noORules]

theorem mayAct_fixed (v : List Nat) (s op : Bool) (o : Owner) :
    mayAct ⟨.fixed v, s, op⟩ o = true ↔ o = .user v ∨ (o = .shared ∧ s = true) := by
  cases o with
  | shared => simp [mayAct]
  | user u => simp [mayAct, mayActText]
  | every => simp [mayAct]

theorem mayAct_any_users (s op : Bool) (u : List Nat) : mayAct ⟨.any, s, op⟩ (.user u) = true := rfl

theorem mayPin_every_iff (r : ORules) : mayPin r .every = true ↔ r.operator = true ∧ r.kind = .any := by
  simp [mayPin]

theorem mayPin_of_mayAct {r : ORules} {o : Owner} (h : mayAct r o = true) : mayPin r o = true := by
  cases o with
  | every => simp [mayAct] at h
  | shared => simpa [mayPin] using h
  | user u => simpa [mayPin] using h

end Labels
