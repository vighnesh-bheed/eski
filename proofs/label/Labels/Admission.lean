import Labels.Visibility
import Labels.Rules

namespace Labels

def gateAccept (v : Vis) (labels : List Nat) (slot : Nat) : Bool :=
  match labels[slot]? with
  | none => false
  | some id => visible v id

structure FilterGate (A : Type) where
  program : Option (Option A → Bool)
  lookup : Option (Nat → Option A)

def filterPasses {A : Type} (f : FilterGate A) (slot : Nat) : Bool :=
  match f.program with
  | none => true
  | some eval =>
    match f.lookup with
    | none => false
    | some attr => eval (attr slot)

def filterAccept {A : Type} (v : Vis) (labels : List Nat) (f : FilterGate A) (slot : Nat) : Bool :=
  if !gateAccept v labels slot then false
  else match f.program with
    | none => true
    | some eval =>
      match f.lookup with
      | none => false
      | some attr => eval (attr slot)

theorem gate_sound {v : Vis} {labels : List Nat} {slot : Nat} (h : gateAccept v labels slot = true) :
    ∃ id, labels[slot]? = some id ∧ visible v id = true := by
  unfold gateAccept at h
  split at h
  · simp at h
  · rename_i id hid; exact ⟨id, hid, h⟩

theorem gate_range {v : Vis} {labels : List Nat} {slot : Nat} (h : labels.length ≤ slot) :
    gateAccept v labels slot = false := by
  unfold gateAccept
  rw [List.getElem?_eq_none h]

theorem gate_exact {t : List TLabel} {v : Vis} (hv : VisOk t v) (labels : List Nat) (slot : Nat) :
    gateAccept v labels slot = true ↔
      ∃ id, labels[slot]? = some id ∧ id < t.length ∧ domT v.reader (t.getD id tbottom) = true := by
  unfold gateAccept
  split
  · rename_i hn; simp [hn]
  · rename_i id hid
    rw [visible_spec hv]
    simp only [hid, Option.some.injEq, Bool.and_eq_true, decide_eq_true_eq]
    constructor
    · intro ⟨h1, h2⟩; exact ⟨id, rfl, h1, h2⟩
    · intro ⟨_, he, h1, h2⟩; subst he; exact ⟨h1, h2⟩

theorem gate_dominated {t : List TLabel} {v : Vis} (hv : VisOk t v) {labels : List Nat} {slot : Nat}
    (h : gateAccept v labels slot = true) :
    ∃ id, labels[slot]? = some id ∧ id < t.length ∧ domT v.reader (t.getD id tbottom) = true :=
  (gate_exact hv labels slot).1 h

theorem filter_exact {A : Type} (v : Vis) (labels : List Nat) (f : FilterGate A) (slot : Nat) :
    filterAccept v labels f slot = (gateAccept v labels slot && filterPasses f slot) := by
  unfold filterAccept filterPasses
  cases gateAccept v labels slot <;> rfl

theorem filter_sound {A : Type} {v : Vis} {labels : List Nat} {f : FilterGate A} {slot : Nat}
    (h : filterAccept v labels f slot = true) :
    gateAccept v labels slot = true ∧
      (f.program = none ∨ ∃ eval attr, f.program = some eval ∧ f.lookup = some attr ∧ eval (attr slot) = true) := by
  rw [filter_exact, Bool.and_eq_true] at h
  refine ⟨h.1, ?_⟩
  have h2 := h.2
  unfold filterPasses at h2
  cases hp : f.program with
  | none => exact Or.inl rfl
  | some eval =>
    rw [hp] at h2
    cases ha : f.lookup with
    | none => rw [ha] at h2; simp at h2
    | some attr => rw [ha] at h2; exact Or.inr ⟨eval, attr, rfl, rfl, h2⟩

theorem filter_blind {A : Type} (v : Vis) (labels : List Nat) (eval : Option A → Bool) (slot : Nat) :
    filterAccept v labels (⟨some eval, none⟩ : FilterGate A) slot = false := by
  rw [filter_exact]
  simp [filterPasses]

theorem filter_open {A : Type} (v : Vis) (labels : List Nat) (slot : Nat) :
    filterAccept v labels (⟨none, none⟩ : FilterGate A) slot = gateAccept v labels slot := by
  rw [filter_exact]
  simp [filterPasses]

theorem gate_subject {t : List TLabel} {s : Subject} (hs : SubjectOk s) {labels : List Nat} {slot : Nat}
    (h : gateAccept (build (reader s) t) labels slot = true) :
    ∃ id, labels[slot]? = some id ∧ id < t.length ∧ mayRead s (t.getD id tbottom) = true ∧
      dom s.clearance.sec (t.getD id tbottom).sec = true := by
  obtain ⟨id, hid, hlt, hd⟩ := gate_dominated (build_ok (reader s) t) h
  have hr : (build (reader s) t).reader = reader s := by unfold build; rw [refresh_reader]
  rw [hr] at hd
  have hread : mayRead s (t.getD id tbottom) = true := (read_iff hs _).2 hd
  exact ⟨id, hid, hlt, hread, read_clearance hread⟩

end Labels
