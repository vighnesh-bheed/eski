import Std

namespace Storage

structure Token where
  id : Nat
  charge : Int
  deriving DecidableEq, Repr

structure Ledger where
  used : Int
  tokens : List Token
  deriving Repr

def outstanding : List Token → Int
  | [] => 0
  | t :: ts => t.charge + outstanding ts

def Valid (l : Ledger) (limit : Int) : Prop :=
  l.used = outstanding l.tokens ∧ 0 ≤ l.used ∧ l.used ≤ limit ∧ limit ≤ 9223372036854775807 ∧
  (∀ t ∈ l.tokens, 0 ≤ t.charge) ∧ (l.tokens.map Token.id).Nodup

def reserve (l : Ledger) (limit : Int) (initialized : Bool) (id : Nat) (bytes : Int) : Ledger × Bool :=
  if initialized ∧ 0 ≤ bytes ∧ bytes ≤ limit ∧ l.used ≤ limit - bytes ∧
      id ∉ l.tokens.map Token.id then
    (⟨l.used + bytes, ⟨id, bytes⟩ :: l.tokens⟩, true)
  else (l, false)

def removeToken (id : Nat) : List Token → Option (Token × List Token)
  | [] => none
  | t :: ts => if t.id = id then some (t, ts) else
    match removeToken id ts with
    | none => none
    | some (found, rest) => some (found, t :: rest)

def release (l : Ledger) (id : Nat) : Ledger × Bool :=
  match removeToken id l.tokens with
  | none => (l, false)
  | some (t, rest) => (⟨l.used - t.charge, rest⟩, true)

def acquire (l : Ledger) (limit : Int) (initialized : Bool) (id : Nat) (size : Int)
    (heapOK : Bool) : Ledger × Bool :=
  if size ≤ 0 ∨ size > 9223372036854775807 - 32 then (l, false) else
    let admitted := reserve l limit initialized id (size + 32)
    if admitted.2 then
      if heapOK then admitted else ((release admitted.1 id).1, false)
    else (l, false)

theorem admission_arithmetic (used bytes limit : Int) (hu : 0 ≤ used) (_hb : 0 ≤ bytes)
    (_hl : limit ≤ 9223372036854775807) :
    (bytes ≤ limit ∧ used ≤ limit - bytes) ↔ used + bytes ≤ limit := by omega

theorem reserve_failed_preserves (l : Ledger) (limit bytes : Int) (init : Bool) (id : Nat)
    (h : (reserve l limit init id bytes).2 = false) :
    (reserve l limit init id bytes).1 = l := by
  unfold reserve at h
  split at h
  next hc => simp at h
  next hc => simp only [reserve, ite_eq_right hc]

theorem reserve_refines (l : Ledger) (limit bytes : Int) (init : Bool) (id : Nat)
    (h : Valid l limit) : Valid (reserve l limit init id bytes).1 limit := by
  unfold reserve
  split
  next ok =>
    rcases h with ⟨he, hu, hl, hm, ht, hn⟩
    rcases ok with ⟨_, hb, _, ha, hf⟩
    refine ⟨?_, ?_, ?_, hm, ?_, ?_⟩
    · simp [outstanding, he, Int.add_comm]
    · change 0 ≤ l.used + bytes; omega
    · change l.used + bytes ≤ limit; omega
    · intro t hh
      simp only [List.mem_cons] at hh
      rcases hh with hh | hh
      · subst t; exact hb
      · exact ht t hh
    · simpa using And.intro hf hn
  next => exact h

theorem remove_conserves (id : Nat) (ts : List Token) (t : Token) (rest : List Token)
    (h : removeToken id ts = some (t, rest)) :
    outstanding ts = t.charge + outstanding rest ∧ t ∈ ts ∧ ∀ a ∈ rest, a ∈ ts := by
  induction ts generalizing rest with
  | nil => simp [removeToken] at h
  | cons a ts ih =>
    simp only [removeToken] at h
    split at h
    next he =>
      cases h
      refine ⟨rfl, by simp, ?_⟩
      intro a ha
      exact List.mem_cons_of_mem t ha
    next he =>
      split at h
      next hh => simp at h
      next found tail hh =>
        cases h
        obtain ⟨hs, hm, hr⟩ := ih tail hh
        refine ⟨?_, by simp [hm], ?_⟩
        · simp only [outstanding]; omega
        · intro x hx
          simp only [List.mem_cons] at hx ⊢
          exact hx.elim Or.inl (fun hh => Or.inr (hr x hh))

theorem release_refines_sum (l : Ledger) (id : Nat)
    (h : l.used = outstanding l.tokens) :
    (release l id).1.used = outstanding (release l id).1.tokens := by
  unfold release
  split
  next => exact h
  next t rest hr =>
    have hc := (remove_conserves id l.tokens t rest hr).1
    simp only
    omega

theorem release_preserves_budget (l : Ledger) (limit : Int) (id : Nat) (h : Valid l limit) :
    0 ≤ (release l id).1.used ∧ (release l id).1.used ≤ limit := by
  unfold release
  split
  next => exact ⟨h.2.1, h.2.2.1⟩
  next t rest hr =>
    obtain ⟨hs, hm, hrest⟩ := remove_conserves id l.tokens t rest hr
    have ht := h.2.2.2.2.1 t hm
    have nonneg : ∀ ts : List Token, (∀ a ∈ ts, 0 ≤ a.charge) → 0 ≤ outstanding ts := by
      intro ts
      induction ts with
      | nil => simp [outstanding]
      | cons a ts ih =>
        intro hp
        have ha := hp a (by simp)
        have hb := ih (fun a hh => hp a (by simp [hh]))
        simp only [outstanding]
        omega
    have hn := nonneg rest (fun a ha => h.2.2.2.2.1 a (hrest a ha))
    have he := h.1
    have hu := h.2.2.1
    simp only
    omega

theorem release_missing_preserves (l : Ledger) (id : Nat) (h : removeToken id l.tokens = none) :
    release l id = (l, false) := by simp [release, h]

theorem reserve_release_inverse (l : Ledger) (limit bytes : Int) (init : Bool) (id : Nat)
    (h : (reserve l limit init id bytes).2 = true) :
    (release (reserve l limit init id bytes).1 id).1 = l := by
  unfold reserve at h
  split at h
  next ok =>
    rw [reserve, ite_eq_left ok]
    simp [release, removeToken]
  next => simp at h

theorem removal_preserves_ownership (id : Nat) (ts : List Token) (t : Token) (rest : List Token)
    (h : removeToken id ts = some (t, rest)) (unique : (ts.map Token.id).Nodup) :
    (rest.map Token.id).Nodup ∧ id ∉ rest.map Token.id := by
  induction ts generalizing rest with
  | nil => simp [removeToken] at h
  | cons a ts ih =>
    have hu := List.nodup_cons.mp unique
    simp only [removeToken] at h
    split at h
    next he =>
      cases h
      exact ⟨hu.2, by simpa [he] using hu.1⟩
    next he =>
      split at h
      next => simp at h
      next found tail hr =>
        cases h
        obtain ⟨hn, ha⟩ := ih tail hr hu.2
        have hs := (remove_conserves id ts t tail hr).2.2
        constructor
        · apply List.nodup_cons.mpr
          refine ⟨?_, hn⟩
          intro hm
          obtain ⟨v, hv, hid⟩ := List.mem_map.mp hm
          exact hu.1 (List.mem_map.mpr ⟨v, hs v hv, hid⟩)
        · simp [ha, Ne.symm he]

theorem release_refines (l : Ledger) (limit : Int) (id : Nat) (h : Valid l limit) :
    Valid (release l id).1 limit := by
  have hsum := release_refines_sum l id h.1
  have hbudget := release_preserves_budget l limit id h
  unfold release
  split
  next => exact h
  next t rest hr =>
    obtain ⟨_, _, hs⟩ := remove_conserves id l.tokens t rest hr
    have hu := removal_preserves_ownership id l.tokens t rest hr h.2.2.2.2.2
    have hsumeq := hsum
    have hbound := hbudget
    simp only [release, hr] at hsumeq hbound
    refine ⟨hsumeq, hbound.1, hbound.2, h.2.2.2.1, ?_, hu.1⟩
    intro a ha
    exact h.2.2.2.2.1 a (hs a ha)

theorem heap_failure_rolls_back (l : Ledger) (limit : Int) (init : Bool) (id : Nat) (size : Int) :
    acquire l limit init id size false = (l, false) := by
  unfold acquire
  split
  next => rfl
  next =>
    dsimp only
    split
    next ha => simp only [Bool.false_eq_true, ↓reduceIte, reserve_release_inverse l limit (size + 32) init id ha]
    next => rfl

theorem acquire_refines (l : Ledger) (limit : Int) (init : Bool) (id : Nat) (size : Int)
    (heapOK : Bool) (h : Valid l limit) : Valid (acquire l limit init id size heapOK).1 limit := by
  cases heapOK with
  | false => rw [heap_failure_rolls_back]; exact h
  | true =>
    unfold acquire
    split
    next => exact h
    next =>
      dsimp only
      split
      next => exact reserve_refines l limit (size + 32) init id h
      next => exact h

theorem zero_reservation_preserves_balance (l : Ledger) (limit : Int) (id : Nat) :
    (reserve l limit true id 0).1.used = l.used := by
  unfold reserve
  split <;> simp

theorem machine_charge_bounds (size : Int) (h : 0 < size ∧ size ≤ 9223372036854775807 - 32) :
    0 < size + 32 ∧ size + 32 ≤ 9223372036854775807 := by omega

end Storage
