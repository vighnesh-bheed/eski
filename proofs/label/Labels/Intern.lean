import Labels.Lattice

namespace Labels

def labelLimit : Nat := 65535

def idNone : Nat := 65535

inductive IErr
  | full
deriving DecidableEq, Repr

def find (t : List Label) (l : Label) : Option Nat := t.findIdx? (· == l)

def intern (t : List Label) (l : Label) : List Label × Except IErr Nat :=
  match find t l with
  | some i => (t, .ok i)
  | none => if labelLimit ≤ t.length then (t, .error .full) else (t ++ [l], .ok t.length)

def tableInit : List Label := [bottom]

def TableOk (t : List Label) : Prop := t[0]? = some bottom ∧ t.Nodup ∧ t.length ≤ labelLimit

def internAll : List Label → List Label → List Label × List (Except IErr Nat)
  | t, [] => (t, [])
  | t, l :: ls =>
    let r := intern t l
    let rest := internAll r.1 ls
    (rest.1, r.2 :: rest.2)

theorem find_some {t : List Label} {l : Label} {i : Nat} (h : find t l = some i) : t[i]? = some l := by
  unfold find at h
  obtain ⟨hi, hp, _⟩ := List.findIdx?_eq_some_iff_getElem.1 h
  rw [List.getElem?_eq_getElem hi]
  simpa using hp

theorem find_none {t : List Label} {l : Label} : find t l = none ↔ l ∉ t := by
  unfold find
  rw [List.findIdx?_eq_none_iff]
  constructor
  · intro h hm
    have := h l hm
    simp at this
  · intro h x hx
    simp only [beq_eq_false_iff_ne]
    intro he
    subst he
    exact h hx

theorem find_nodup {t : List Label} (hn : t.Nodup) {i : Nat} {l : Label} (h : t[i]? = some l) : find t l = some i := by
  unfold find
  obtain ⟨hi, he⟩ := List.getElem?_eq_some_iff.1 h
  rw [List.findIdx?_eq_some_iff_getElem]
  refine ⟨hi, by simp [he], fun j hj => ?_⟩
  simp only [beq_iff_eq]
  intro hjl
  have : t[j] = t[i] := by rw [hjl, he]
  have := (hn.getElem_inj).1 this
  omega

theorem find_iff {t : List Label} (hn : t.Nodup) (l : Label) (i : Nat) : find t l = some i ↔ t[i]? = some l :=
  ⟨find_some, find_nodup hn⟩

theorem intern_get {t t' : List Label} {l : Label} {i : Nat} (h : intern t l = (t', .ok i)) : t'[i]? = some l := by
  unfold intern at h
  split at h
  · rename_i j hj
    simp only [Prod.mk.injEq, Except.ok.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    exact find_some hj
  · split at h
    · simp at h
    · simp only [Prod.mk.injEq, Except.ok.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      simp

theorem intern_prefix (t : List Label) (l : Label) : t <+: (intern t l).1 := by
  unfold intern
  split
  · exact List.prefix_refl t
  · split
    · exact List.prefix_refl t
    · exact List.prefix_append t [l]

theorem intern_stable (t : List Label) (l : Label) {i : Nat} (hi : i < t.length) :
    (intern t l).1[i]? = t[i]? := by
  obtain ⟨u, hu⟩ := intern_prefix t l
  rw [← hu, List.getElem?_append_left hi]

theorem intern_ok {t : List Label} (h : TableOk t) (l : Label) : TableOk (intern t l).1 := by
  obtain ⟨h0, hn, hl⟩ := h
  unfold intern
  split
  · exact ⟨h0, hn, hl⟩
  · rename_i hf
    split
    · exact ⟨h0, hn, hl⟩
    · rename_i hlim
      refine ⟨?_, ?_, ?_⟩
      · have : 0 < t.length := by
          cases t with
          | nil => simp at h0
          | cons _ _ => simp
        rw [List.getElem?_append_left this, h0]
      · rw [List.nodup_append]
        refine ⟨hn, List.nodup_cons.2 ⟨by simp, List.nodup_nil⟩, fun a ha b hb => ?_⟩
        simp only [List.mem_singleton] at hb
        subst hb
        intro he
        subst he
        exact (find_none.1 hf) ha
      · simp only [List.length_append, List.length_singleton]
        omega

theorem intern_id_lt {t t' : List Label} {l : Label} {i : Nat} (h : TableOk t) (hr : intern t l = (t', .ok i)) :
    i < labelLimit := by
  have hok := intern_ok h l
  rw [hr] at hok
  have hg := intern_get hr
  exact Nat.lt_of_lt_of_le (List.getElem?_eq_some_iff.1 hg).1 hok.2.2

theorem intern_id_ne_none {t t' : List Label} {l : Label} {i : Nat} (h : TableOk t) (hr : intern t l = (t', .ok i)) :
    i ≠ idNone := by
  have := intern_id_lt h hr
  unfold idNone labelLimit at *
  omega

theorem intern_full {t : List Label} {l : Label} (hl : t.length = labelLimit) (hm : l ∉ t) :
    intern t l = (t, .error .full) := by
  unfold intern
  rw [find_none.2 hm]
  simp [hl]

theorem intern_existing {t : List Label} {l : Label} {i : Nat} (h : TableOk t) (hi : t[i]? = some l) :
    intern t l = (t, .ok i) := by
  unfold intern
  rw [find_nodup h.2.1 hi]

theorem intern_fresh {t : List Label} {l : Label} (hm : l ∉ t) (hl : t.length < labelLimit) :
    intern t l = (t ++ [l], .ok t.length) := by
  unfold intern
  rw [find_none.2 hm]
  simp [Nat.not_le.2 hl]

theorem ids_injective {t : List Label} (h : TableOk t) {i j : Nat} {l : Label} (hi : t[i]? = some l)
    (hj : t[j]? = some l) : i = j := by
  have a := find_nodup h.2.1 hi
  have b := find_nodup h.2.1 hj
  rw [a] at b
  exact Option.some.inj b

theorem intern_error {t t' : List Label} {l : Label} {e : IErr} (hr : intern t l = (t', .error e)) : t' = t := by
  unfold intern at hr
  split at hr
  · simp at hr
  · split at hr
    · exact (Prod.mk.inj hr).1.symm
    · simp at hr

theorem intern_idempotent {t : List Label} (h : TableOk t) (l : Label) :
    intern (intern t l).1 l = intern t l := by
  cases hr : intern t l with
  | mk t' r =>
    cases r with
    | ok i =>
      have hg := intern_get hr
      have hok := intern_ok h l
      rw [hr] at hok
      exact intern_existing hok hg
    | error e =>
      have := intern_error hr
      subst this
      exact hr

theorem init_ok : TableOk tableInit := ⟨rfl, List.nodup_cons.2 ⟨by simp, List.nodup_nil⟩, by decide⟩

theorem init_bottom : find tableInit bottom = some 0 := rfl

theorem internAll_prefix (t : List Label) (ls : List Label) : t <+: (internAll t ls).1 := by
  induction ls generalizing t with
  | nil => exact List.prefix_refl t
  | cons l ls ih => exact (intern_prefix t l).trans (ih _)

theorem internAll_ok {t : List Label} (h : TableOk t) (ls : List Label) : TableOk (internAll t ls).1 := by
  induction ls generalizing t with
  | nil => exact h
  | cons l ls ih => exact ih (intern_ok h l)

theorem internAll_length (t : List Label) (ls : List Label) : (internAll t ls).2.length = ls.length := by
  induction ls generalizing t with
  | nil => rfl
  | cons l ls ih => simp [internAll, ih]

theorem internAll_ids {t : List Label} (ls : List Label) {k i : Nat} (hk : (internAll t ls).2[k]? = some (.ok i)) :
    (internAll t ls).1[i]? = ls[k]? := by
  induction ls generalizing t k with
  | nil => simp [internAll] at hk
  | cons l ls ih =>
    cases k with
    | zero =>
      simp only [internAll, List.getElem?_cons_zero, Option.some.injEq] at hk
      have hg := intern_get (t := t) (l := l) (t' := (intern t l).1) (i := i) (by rw [← hk])
      obtain ⟨u, hu⟩ := internAll_prefix (intern t l).1 ls
      simp only [internAll, List.getElem?_cons_zero]
      rw [← hu, List.getElem?_append_left (List.getElem?_eq_some_iff.1 hg).1, hg]
    | succ k =>
      simp only [internAll, List.getElem?_cons_succ] at hk ⊢
      exact ih hk

theorem internAll_keeps (t : List Label) (ls : List Label) {i : Nat} (hi : i < t.length) :
    (internAll t ls).1[i]? = t[i]? := by
  obtain ⟨u, hu⟩ := internAll_prefix t ls
  rw [← hu, List.getElem?_append_left hi]

end Labels
