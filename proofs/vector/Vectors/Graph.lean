import Vectors.Heap

namespace Vectors

structure Graph where
  present : Nat → Bool
  adj : Nat → List Nat

def Graph.setAdj (g : Graph) (a : Nat) (l : List Nat) : Graph :=
  ⟨g.present, fun x => if x = a then l else g.adj x⟩

def listAppend (cap : Nat) (g : Graph) (a id : Nat) : Graph :=
  if (g.adj a).length ≥ cap then g else g.setAdj a (g.adj a ++ [id])

def removeAt (l : List Nat) (i : Nat) : List Nat := (l.set i (l.getLastD 0)).dropLast

def listRemove (g : Graph) (a id : Nat) : Graph :=
  match (g.adj a).idxOf? id with
  | none => g
  | some i => g.setAdj a (removeAt (g.adj a) i)

def listReplace (g : Graph) (a old new : Nat) : Graph :=
  match (g.adj a).idxOf? old with
  | none => g
  | some i => g.setAdj a ((g.adj a).set i new)

def linkPair (cap : Nat) (g : Graph) (a b : Nat) : Graph := listAppend cap (listAppend cap g a b) b a

theorem split_at (l : List Nat) (i : Nat) (hi : i < l.length) :
    ∃ A x B, l = A ++ x :: B ∧ A.length = i := by
  refine ⟨l.take i, l[i], l.drop (i + 1), ?_, by simp; omega⟩
  conv => lhs; rw [← List.take_append_drop i l]
  rw [List.drop_eq_getElem_cons hi]

theorem removeAt_perm (l : List Nat) (i : Nat) (hi : i < l.length) : (removeAt l i).Perm (l.eraseIdx i) := by
  obtain ⟨A, x, B, rfl, hA⟩ := split_at l i hi
  unfold removeAt
  have he : (A ++ x :: B).eraseIdx i = A ++ B := by
    rw [List.eraseIdx_append_of_length_le (by omega), hA, Nat.sub_self]; rfl
  rw [he]
  rcases List.eq_nil_or_concat B with hB | ⟨B', z, hB⟩
  · subst hB
    simp only [List.getLastD_eq_getLast?, List.getLast?_append, List.getLast?_singleton]
    rw [List.set_append_right _ _ (by omega), hA, Nat.sub_self]
    simp
  · subst hB
    simp only [List.concat_eq_append]
    have hl : (A ++ x :: (B' ++ [z])).getLastD 0 = z := by
      rw [List.getLastD_eq_getLast?]
      have : A ++ x :: (B' ++ [z]) = (A ++ x :: B') ++ [z] := by simp
      rw [this, List.getLast?_append]; simp
    rw [hl, List.set_append_right _ _ (by omega), hA, Nat.sub_self]
    have : A ++ (x :: (B' ++ [z])).set 0 z = (A ++ z :: B') ++ [z] := by simp
    rw [this, List.dropLast_concat]
    exact List.Perm.append_left A (List.perm_append_singleton z B').symm

theorem set_perm (l : List Nat) (i : Nat) (hi : i < l.length) (y : Nat) : (l.set i y).Perm (y :: l.eraseIdx i) := by
  obtain ⟨A, x, B, rfl, hA⟩ := split_at l i hi
  have he : (A ++ x :: B).eraseIdx i = A ++ B := by
    rw [List.eraseIdx_append_of_length_le (by omega), hA, Nat.sub_self]; rfl
  rw [he, List.set_append_right _ _ (by omega), hA, Nat.sub_self]
  exact List.perm_middle

theorem idxOf_some {l : List Nat} {a i : Nat} (h : l.idxOf? a = some i) : i < l.length ∧ l.erase a = l.eraseIdx i := by
  obtain ⟨hi, _, _⟩ := List.idxOf?_eq_some_iff.mp h
  refine ⟨hi, ?_⟩
  rw [List.erase_eq_eraseIdx, h]

theorem setAdj_adj (g : Graph) (a : Nat) (l : List Nat) (x : Nat) :
    (g.setAdj a l).adj x = if x = a then l else g.adj x := rfl

theorem setAdj_present (g : Graph) (a : Nat) (l : List Nat) : (g.setAdj a l).present = g.present := rfl

theorem listRemove_present (g : Graph) (a id : Nat) : (listRemove g a id).present = g.present := by
  unfold listRemove; split <;> rfl

theorem listRemove_adj (g : Graph) (a id : Nat) : ((listRemove g a id).adj a).Perm ((g.adj a).erase id) := by
  unfold listRemove
  split
  · next h =>
    rw [List.erase_of_not_mem (List.idxOf?_eq_none_iff.mp h)]
  · next i h =>
    obtain ⟨hi, he⟩ := idxOf_some h
    rw [setAdj_adj, ite_eq_left rfl, he]
    exact removeAt_perm _ _ hi

theorem listRemove_other (g : Graph) (a id x : Nat) (hx : x ≠ a) : (listRemove g a id).adj x = g.adj x := by
  unfold listRemove; split
  · rfl
  · rw [setAdj_adj, ite_eq_right hx]

theorem listReplace_present (g : Graph) (a old new : Nat) : (listReplace g a old new).present = g.present := by
  unfold listReplace; split <;> rfl

theorem listReplace_adj (g : Graph) (a old new : Nat) (h : old ∈ g.adj a) :
    ((listReplace g a old new).adj a).Perm (new :: (g.adj a).erase old) := by
  unfold listReplace
  split
  · next hn => exact absurd h (List.idxOf?_eq_none_iff.mp hn)
  · next i hs =>
    obtain ⟨hi, he⟩ := idxOf_some hs
    rw [setAdj_adj, ite_eq_left rfl, he]
    exact set_perm _ _ hi _

theorem listReplace_other (g : Graph) (a old new x : Nat) (hx : x ≠ a) :
    (listReplace g a old new).adj x = g.adj x := by
  unfold listReplace; split
  · rfl
  · rw [setAdj_adj, ite_eq_right hx]

theorem listAppend_present (cap : Nat) (g : Graph) (a id : Nat) : (listAppend cap g a id).present = g.present := by
  unfold listAppend; split <;> rfl

theorem listAppend_adj (cap : Nat) (g : Graph) (a id : Nat) (h : (g.adj a).length < cap) :
    (listAppend cap g a id).adj a = g.adj a ++ [id] := by
  unfold listAppend
  rw [ite_eq_right (by omega), setAdj_adj, ite_eq_left rfl]

theorem listAppend_other (cap : Nat) (g : Graph) (a id x : Nat) (hx : x ≠ a) :
    (listAppend cap g a id).adj x = g.adj x := by
  unfold listAppend; split
  · rfl
  · rw [setAdj_adj, ite_eq_right hx]

theorem linkPair_adj (cap : Nat) (g : Graph) (a b : Nat) (hab : a ≠ b) (ha : (g.adj a).length < cap)
    (hb : (g.adj b).length < cap) (x : Nat) :
    (linkPair cap g a b).adj x = if x = a then g.adj a ++ [b] else if x = b then g.adj b ++ [a] else g.adj x := by
  have hba : b ≠ a := fun e => hab e.symm
  unfold linkPair
  by_cases hxb : x = b
  · rw [hxb]
    rw [listAppend_adj cap _ b a (by rw [listAppend_other cap g a b b hba]; exact hb),
      listAppend_other cap g a b b hba]
    simp [hba]
  · rw [listAppend_other cap _ b a x hxb]
    by_cases hxa : x = a
    · rw [hxa, listAppend_adj cap g a b ha]; simp
    · rw [listAppend_other cap g a b x hxa]; simp [hxa, hxb]

theorem linkPair_present (cap : Nat) (g : Graph) (a b : Nat) : (linkPair cap g a b).present = g.present := by
  unfold linkPair; rw [listAppend_present, listAppend_present]

structure Wf (cap : Nat) (g : Graph) : Prop where
  symm : ∀ a b, b ∈ g.adj a → a ∈ g.adj b
  irrefl : ∀ a, a ∉ g.adj a
  nodup : ∀ a, (g.adj a).Nodup
  bound : ∀ a, (g.adj a).length ≤ cap
  closed : ∀ a b, b ∈ g.adj a → g.present b = true

def adoptCands (cap : Nat) (g : Graph) (orphan hub : Nat) : List Nat :=
  (g.adj hub).filter fun y => y != orphan && decide ((g.adj y).length < cap) && !(g.adj y).contains orphan &&
    !(g.adj orphan).contains y

def PickOk (pick : Graph → Nat → List Nat → Option Nat) : Prop := ∀ g o L y, pick g o L = some y → y ∈ L

def adopt (cap : Nat) (pick : Graph → Nat → List Nat → Option Nat) (g : Graph) (orphan hub : Nat) : Graph :=
  match pick g orphan (adoptCands cap g orphan hub) with
  | some y => linkPair cap g orphan y
  | none => g

def connectStep (cap q : Nat) (victim : Graph → Nat → Nat) (guard : Graph → Nat → Nat → Bool)
    (pick : Graph → Nat → List Nat → Option Nat) (g : Graph) (e : Nat) : Graph :=
  if (g.adj e).length < cap then listAppend cap g e q
  else
    let v := victim g e
    let g1 := if v = q then listRemove g q e else listRemove (listReplace g e v q) v e
    if (g1.adj v).length = 0 || (v != q && guard g1 v e) then adopt cap pick g1 v e else g1

def connect (cap : Nat) (g : Graph) (q : Nat) (selected : List Nat) (victim : Graph → Nat → Nat)
    (guard : Graph → Nat → Nat → Bool) (pick : Graph → Nat → List Nat → Option Nat) : Graph :=
  (selected.take cap).foldl (connectStep cap q victim guard pick) (g.setAdj q (selected.take cap))

structure ConnInv (cap : Nat) (P : Nat → Bool) (q : Nat) (g : Graph) (R : List Nat) : Prop where
  pres : g.present = P
  symm : ∀ a b, b ∈ g.adj a → a ∈ g.adj b ∨ (a = q ∧ b ∈ R)
  pend : ∀ x ∈ R, x ∈ g.adj q ∧ q ∉ g.adj x
  irrefl : ∀ a, a ∉ g.adj a
  nodup : ∀ a, (g.adj a).Nodup
  bound : ∀ a, (g.adj a).length ≤ cap
  closed : ∀ a b, b ∈ g.adj a → P b = true
  rnodup : R.Nodup
  rq : q ∉ R
  pq : P q = true

theorem mem_erase_nodup {l : List Nat} {a b : Nat} (h : l.Nodup) : b ∈ l.erase a ↔ b ∈ l ∧ b ≠ a := by
  rw [List.Nodup.mem_erase_iff h]; exact ⟨fun ⟨x, y⟩ => ⟨y, x⟩, fun ⟨x, y⟩ => ⟨y, x⟩⟩

theorem connA {cap P q g e R} (h : ConnInv cap P q g (e :: R)) (hlt : (g.adj e).length < cap) :
    ConnInv cap P q (listAppend cap g e q) R := by
  have hpe := h.pend e (by simp)
  have heq : e ≠ q := fun h' => h.rq (h' ▸ by simp)
  have hR : e ∉ R := (List.nodup_cons.mp h.rnodup).1
  have hadj : ∀ x, (listAppend cap g e q).adj x = if x = e then g.adj e ++ [q] else g.adj x := by
    intro x; by_cases hx : x = e
    · subst hx; rw [listAppend_adj cap g x q hlt, ite_eq_left rfl]
    · rw [listAppend_other cap g e q x hx, ite_eq_right hx]
  have hm : ∀ x b, b ∈ (listAppend cap g e q).adj x ↔ (x = e ∧ b = q) ∨ b ∈ g.adj x := by
    intro x b; rw [hadj]; by_cases hx : x = e
    · subst hx; simp only [ite_true, List.mem_append, List.mem_singleton]; grind
    · simp only [hx, ite_false]; grind
  have symm := h.symm; have pend := h.pend; have irrefl := h.irrefl; have closed := h.closed
  have hqR := h.rq
  have hPq : P q = true := h.pq
  refine ⟨by rw [listAppend_present]; exact h.pres, ?_, ?_, ?_, ?_, ?_, ?_, (List.nodup_cons.mp h.rnodup).2,
    fun hq => h.rq (by simp [hq]), h.pq⟩
  · intro a b hb; simp only [hm] at hb ⊢; grind
  · intro x hx; simp only [hm]; grind
  · intro a; simp only [hm]; grind
  · intro a; rw [hadj]; split
    · next ha => subst ha; exact List.nodup_append.mpr ⟨h.nodup a, by simp, by grind⟩
    · exact h.nodup a
  · intro a; rw [hadj]; split
    · next ha => subst ha; simp; omega
    · exact h.bound a
  · intro a b hb; simp only [hm] at hb; grind

theorem connB {cap P q g e R} (h : ConnInv cap P q g (e :: R)) :
    ConnInv cap P q (listRemove g q e) R := by
  have hpe := h.pend e (by simp)
  have heq : e ≠ q := fun h' => h.rq (h' ▸ by simp)
  have hR : e ∉ R := (List.nodup_cons.mp h.rnodup).1
  have hperm := listRemove_adj g q e
  have hm : ∀ x b, b ∈ (listRemove g q e).adj x ↔ b ∈ g.adj x ∧ ¬(x = q ∧ b = e) := by
    intro x b; by_cases hx : x = q
    · subst hx; rw [hperm.mem_iff, mem_erase_nodup (h.nodup x)]; grind
    · rw [listRemove_other g q e x hx]; grind
  have symm := h.symm; have pend := h.pend; have irrefl := h.irrefl; have closed := h.closed
  have hqR := h.rq
  refine ⟨by rw [listRemove_present]; exact h.pres, ?_, ?_, ?_, ?_, ?_, ?_, (List.nodup_cons.mp h.rnodup).2,
    fun hq => h.rq (by simp [hq]), h.pq⟩
  · intro a b hb; simp only [hm] at hb ⊢; grind
  · intro x hx; simp only [hm]; grind
  · intro a; simp only [hm]; grind
  · intro a; by_cases ha : a = q
    · subst ha; exact (List.Nodup.erase e (h.nodup a)).perm hperm.symm
    · rw [listRemove_other g q e a ha]; exact h.nodup a
  · intro a; by_cases ha : a = q
    · subst ha; rw [hperm.length_eq]
      exact Nat.le_trans (List.length_erase_le) (h.bound a)
    · rw [listRemove_other g q e a ha]; exact h.bound a
  · intro a b hb; simp only [hm] at hb; grind

theorem connC {cap P q g e R v} (h : ConnInv cap P q g (e :: R)) (hv : v ∈ g.adj e) (hvq : v ≠ q) :
    ConnInv cap P q (listRemove (listReplace g e v q) v e) R := by
  have hpe := h.pend e (by simp)
  have heq : e ≠ q := fun h' => h.rq (h' ▸ by simp)
  have hR : e ∉ R := (List.nodup_cons.mp h.rnodup).1
  have hve : v ≠ e := fun h' => h.irrefl e (h' ▸ hv)
  have hp1 := listReplace_adj g e v q hv
  have hp2 := listRemove_adj (listReplace g e v q) v e
  have hrv : (listReplace g e v q).adj v = g.adj v := listReplace_other g e v q v hve
  have hev : e ∈ g.adj v := by have := h.symm e v hv; grind
  have hqe : q ∉ g.adj e := hpe.2
  have hm : ∀ x b, b ∈ (listRemove (listReplace g e v q) v e).adj x ↔
      (b ∈ g.adj x ∧ ¬(x = e ∧ b = v) ∧ ¬(x = v ∧ b = e)) ∨ (x = e ∧ b = q) := by
    intro x b
    by_cases hx : x = v
    · subst hx; rw [hp2.mem_iff, hrv, mem_erase_nodup (h.nodup x)]; grind
    · rw [listRemove_other _ v e x hx]
      by_cases hxe : x = e
      · subst hxe; rw [hp1.mem_iff, List.mem_cons, mem_erase_nodup (h.nodup x)]; grind
      · rw [listReplace_other g e v q x hxe]; grind
  have symm := h.symm; have pend := h.pend; have irrefl := h.irrefl; have closed := h.closed
  have hqR := h.rq
  have hPq : P q = true := h.pq
  have hpres : (listRemove (listReplace g e v q) v e).present = P := by
    rw [listRemove_present, listReplace_present]; exact h.pres
  refine ⟨hpres, ?_, ?_, ?_, ?_, ?_, ?_, (List.nodup_cons.mp h.rnodup).2, fun hq => h.rq (by simp [hq]), h.pq⟩
  · intro a b hb; simp only [hm] at hb ⊢; grind
  · intro x hx; simp only [hm]; grind
  · intro a; simp only [hm]; grind
  · intro a
    by_cases ha : a = v
    · subst ha; rw [hp2.nodup_iff, hrv]; exact List.Nodup.erase e (h.nodup a)
    · rw [listRemove_other _ v e a ha]
      by_cases hae : a = e
      · subst hae; rw [hp1.nodup_iff]
        exact List.nodup_cons.mpr ⟨fun hm' => hqe (List.mem_of_mem_erase hm'), List.Nodup.erase v (h.nodup a)⟩
      · rw [listReplace_other g e v q a hae]; exact h.nodup a
  · intro a
    by_cases ha : a = v
    · subst ha; rw [hp2.length_eq, hrv]; exact Nat.le_trans (List.length_erase_le) (h.bound a)
    · rw [listRemove_other _ v e a ha]
      by_cases hae : a = e
      · subst hae; rw [hp1.length_eq, List.length_cons, List.length_erase_of_mem hv]
        have := h.bound a
        have : 0 < (g.adj a).length := List.length_pos_of_mem hv
        omega
      · rw [listReplace_other g e v q a hae]; exact h.bound a
  · intro a b hb; simp only [hm] at hb; grind

theorem linkPair_conn {cap P q g R} (h : ConnInv cap P q g R) (o y : Nat) (hoy : o ≠ y) (hyo : y ∉ g.adj o)
    (hoy' : o ∉ g.adj y) (ho : (g.adj o).length < cap) (hy : (g.adj y).length < cap) (po : P o = true)
    (py : P y = true) (h1 : ¬ (o ∈ R ∧ y = q)) (h2 : ¬ (y ∈ R ∧ o = q)) :
    ConnInv cap P q (linkPair cap g o y) R := by
  have hadj := linkPair_adj cap g o y hoy ho hy
  have hyo' : y ≠ o := fun e => hoy e.symm
  have hm : ∀ x b, b ∈ (linkPair cap g o y).adj x ↔ b ∈ g.adj x ∨ (x = o ∧ b = y) ∨ (x = y ∧ b = o) := by
    intro x b; rw [hadj]
    by_cases hxo : x = o
    · rw [hxo]; simp [hoy] <;> grind
    · by_cases hxy : x = y
      · rw [hxy]; simp [hyo'] <;> grind
      · simp [hxo, hxy]
  have symm := h.symm; have pend := h.pend; have irrefl := h.irrefl; have closed := h.closed
  refine ⟨by rw [linkPair_present]; exact h.pres, ?_, ?_, ?_, ?_, ?_, ?_, h.rnodup, h.rq, h.pq⟩
  · intro a b hb; simp only [hm] at hb ⊢; grind
  · intro x hx; simp only [hm]; grind
  · intro a; simp only [hm]; grind
  · intro x; rw [hadj]; split
    · next hx => subst hx; exact List.nodup_append.mpr ⟨h.nodup x, by simp, by grind⟩
    · split
      · next hx => subst hx; exact List.nodup_append.mpr ⟨h.nodup x, by simp, by grind⟩
      · exact h.nodup x
  · intro x; rw [hadj]; split
    · next hx => subst hx; simp; omega
    · split
      · next hx => subst hx; simp; omega
      · exact h.bound x
  · intro a b hb; simp only [hm] at hb; grind

theorem adopt_conn {cap P q g R} (pick : Graph → Nat → List Nat → Option Nat) (hpick : PickOk pick)
    (h : ConnInv cap P q g R) (o hub : Nat) (ho : (g.adj o).length < cap) (po : P o = true)
    (hq : o = q → R = []) : ConnInv cap P q (adopt cap pick g o hub) R := by
  unfold adopt
  split
  · next y hy =>
    have hmem := hpick _ _ _ _ hy
    unfold adoptCands at hmem
    rw [List.mem_filter] at hmem
    obtain ⟨hyh, hf⟩ := hmem
    simp only [Bool.and_eq_true, bne_iff_ne, ne_eq, decide_eq_true_eq, Bool.not_eq_eq_eq_not, Bool.not_true,
      List.contains_eq_mem, decide_eq_false_iff_not] at hf
    obtain ⟨⟨⟨hyo, hyc⟩, hoy⟩, hyo'⟩ := hf
    refine linkPair_conn h o y (fun e => hyo e.symm) hyo' hoy ho hyc po (h.closed hub y hyh) ?_ ?_
    · rintro ⟨hoR, rfl⟩; exact hoy (h.pend o hoR).1
    · rintro ⟨hyR, rfl⟩; rw [hq rfl] at hyR; simp at hyR
  · exact h

theorem connectStep_inv {cap P q g e R} (victim : Graph → Nat → Nat) (guard : Graph → Nat → Nat → Bool)
    (pick : Graph → Nat → List Nat → Option Nat) (hpick : PickOk pick)
    (hvict : ∀ g' e', victim g' e' ∈ g'.adj e' ∨ victim g' e' = q) (h : ConnInv cap P q g (e :: R)) :
    ConnInv cap P q (connectStep cap q victim guard pick g e) R := by
  have hpe := h.pend e (by simp)
  have hcap : 0 < cap := by have := h.bound q; have := List.length_pos_of_mem hpe.1; omega
  unfold connectStep
  split
  · next hlt => exact connA h hlt
  · next hge =>
    simp only
    by_cases hv : victim g e = q
    · have h1 := connB h
      simp only [hv, ite_true, bne_self_eq_false, Bool.false_and, Bool.or_false]
      split
      · next h0 =>
        have h0' : ((listRemove g q e).adj q).length = 0 := by simpa using h0
        refine adopt_conn pick hpick h1 q e (by omega) h.pq (fun _ => ?_)
        cases hR : R with
        | nil => rfl
        | cons x xs =>
          have := (h1.pend x (by rw [hR]; simp)).1
          rw [List.eq_nil_of_length_eq_zero h0'] at this
          simp at this
      · exact h1
    · rcases hvict g e with hvm | hvm
      · have h1 := connC h hvm hv
        simp only [hv, ite_false]
        generalize hv' : victim g e = v at hvm hv h1 ⊢
        have hve : e ∈ g.adj v := by
          have := h.symm e v hvm
          rcases this with h' | ⟨h', _⟩
          · exact h'
          · exact absurd h' (fun e' => h.rq (e' ▸ by simp))
        have hroom : ((listRemove (listReplace g e v q) v e).adj v).length < cap := by
          have hp := listRemove_adj (listReplace g e v q) v e
          have hve' : v ≠ e := fun e' => h.irrefl e (e' ▸ hvm)
          rw [hp.length_eq, listReplace_other g e v q v hve', List.length_erase_of_mem hve]
          have := h.bound v
          have := List.length_pos_of_mem hve
          omega
        split
        · exact adopt_conn pick hpick h1 v e hroom (h.closed e v hvm) (fun e' => absurd e' hv)
        · exact h1
      · exact absurd hvm hv

theorem connect_fold {cap P q} (victim : Graph → Nat → Nat) (guard : Graph → Nat → Nat → Bool)
    (pick : Graph → Nat → List Nat → Option Nat) (hpick : PickOk pick)
    (hvict : ∀ g' e', victim g' e' ∈ g'.adj e' ∨ victim g' e' = q) :
    ∀ (R : List Nat) g, ConnInv cap P q g R → ConnInv cap P q (R.foldl (connectStep cap q victim guard pick) g) [] := by
  intro R
  induction R with
  | nil => intro g h; exact h
  | cons e R ih => intro g h; exact ih _ (connectStep_inv victim guard pick hpick hvict h)

theorem connect_wf (cap : Nat) (g : Graph) (q : Nat) (selected : List Nat) (victim : Graph → Nat → Nat)
    (guard : Graph → Nat → Nat → Bool) (pick : Graph → Nat → List Nat → Option Nat) (hpick : PickOk pick)
    (hw : Wf cap g) (hq : g.present q = true) (hempty : g.adj q = []) (hsel : selected.Nodup)
    (hqs : q ∉ selected) (hpres : ∀ x ∈ selected, g.present x = true)
    (hvict : ∀ g' e', victim g' e' ∈ g'.adj e' ∨ victim g' e' = q) :
    Wf cap (connect cap g q selected victim guard pick) ∧ (connect cap g q selected victim guard pick).present = g.present := by
  have hT : (selected.take cap).Nodup := hsel.sublist (List.take_sublist _ _)
  have hTq : q ∉ selected.take cap := fun h => hqs (List.mem_of_mem_take h)
  have hTp : ∀ x ∈ selected.take cap, g.present x = true := fun x hx => hpres x (List.mem_of_mem_take hx)
  have hnone : ∀ x, q ∉ g.adj x := fun x hx => by have := hw.symm x q hx; rw [hempty] at this; simp at this
  have hm : ∀ x b, b ∈ (g.setAdj q (selected.take cap)).adj x ↔ if x = q then b ∈ selected.take cap else b ∈ g.adj x := by
    intro x b; rw [setAdj_adj]; split <;> rfl
  have symm := hw.symm; have irrefl := hw.irrefl; have closed := hw.closed
  have h0 : ConnInv cap g.present q (g.setAdj q (selected.take cap)) (selected.take cap) := by
    refine ⟨rfl, ?_, ?_, ?_, ?_, ?_, ?_, hT, hTq, hq⟩
    · intro a b hb; simp only [hm] at hb ⊢
      by_cases ha : a = q
      · subst ha; simp only [ite_true] at hb; exact Or.inr ⟨rfl, hb⟩
      · simp only [ha, ite_false] at hb
        have hbq : b ≠ q := fun e => hnone a (e ▸ hb)
        left; simp only [hbq, ite_false]; exact symm a b hb
    · intro x hx; simp only [hm]
      have hxq : x ≠ q := fun e => hTq (e ▸ hx)
      simp only [ite_true, hxq, ite_false]; exact ⟨hx, hnone x⟩
    · intro a; simp only [hm]; split
      · next ha => subst ha; exact hTq
      · exact irrefl a
    · intro a; rw [setAdj_adj]; split
      · exact hT
      · exact hw.nodup a
    · intro a; rw [setAdj_adj]; split
      · exact List.length_take_le _ _
      · exact hw.bound a
    · intro a b hb; simp only [hm] at hb; split at hb
      · exact hTp b hb
      · exact closed a b hb
  have hf := connect_fold victim guard pick hpick hvict (selected.take cap) _ h0
  unfold connect
  refine ⟨⟨fun a b hb => ?_, hf.irrefl, hf.nodup, hf.bound, fun a b hb => by rw [hf.pres]; exact hf.closed a b hb⟩, hf.pres⟩
  rcases hf.symm a b hb with h | ⟨_, h⟩
  · exact h
  · simp at h

def shrinkSplit {D : Type} (dist : Nat → Nat → D) (lt : D → D → Bool) :
    List (D × Nat) → List (D × Nat) × List (D × Nat) × List Nat → List (D × Nat) × List (D × Nat) × List Nat
  | [], acc => acc
  | c :: rest, (kept, dropped, blockers) =>
    match kept.find? (fun r => lt (dist c.2 r.2) c.1) with
    | none => shrinkSplit dist lt rest (kept ++ [c], dropped, blockers)
    | some r => shrinkSplit dist lt rest (kept, dropped ++ [c], blockers ++ [r.2])

def shrinkVictim {D : Type} [Inhabited D] (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (g : Graph) (e q : Nat) (dq : D) : Nat :=
  let shrink := sort ((g.adj e).map (fun y => (dist e y, y)) ++ [(dq, q)])
  let split := shrinkSplit dist lt shrink ([], [], [])
  let kept := split.1
  let dropped := split.2.1
  let blockers := split.2.2
  match (List.range dropped.length).reverse.find? (fun i =>
      decide (i < blockers.length) && decide ((g.adj dropped[i]!.2).length > 1) &&
        (g.adj dropped[i]!.2).contains blockers[i]!) with
  | some i => dropped[i]!.2
  | none =>
    if dropped.any (fun c => c.2 == q) && decide ((g.adj q).length > 1) then q
    else match dropped.reverse.find? (fun c => decide ((g.adj c.2).length > 1)) with
      | some c => c.2
      | none => match kept.reverse.find? (fun c => decide ((g.adj c.2).length > 1)) with
        | some c => c.2
        | none => (shrink.getLast?.map Prod.snd).getD q

theorem shrinkSplit_mem {D : Type} (dist : Nat → Nat → D) (lt : D → D → Bool) (S : List (D × Nat)) :
    ∀ (xs : List (D × Nat)) (acc : List (D × Nat) × List (D × Nat) × List Nat),
      (∀ c ∈ xs, c ∈ S) → (∀ c ∈ acc.1, c ∈ S) → (∀ c ∈ acc.2.1, c ∈ S) →
      (∀ c ∈ (shrinkSplit dist lt xs acc).1, c ∈ S) ∧ (∀ c ∈ (shrinkSplit dist lt xs acc).2.1, c ∈ S) := by
  intro xs
  induction xs with
  | nil => intro acc _ h1 h2; exact ⟨h1, h2⟩
  | cons c rest ih =>
    intro acc hx h1 h2
    obtain ⟨kept, dropped, blockers⟩ := acc
    unfold shrinkSplit
    have hc : c ∈ S := hx c (by simp)
    have hr : ∀ c ∈ rest, c ∈ S := fun c' h => hx c' (by simp [h])
    split
    · apply ih _ hr
      · intro c' h; simp only [List.mem_append, List.mem_singleton] at h
        rcases h with h | h
        · exact h1 c' h
        · subst h; exact hc
      · exact h2
    · next r _ =>
      apply ih (kept, dropped ++ [c], blockers ++ [r.2]) hr h1
      intro c' h; simp only [List.mem_append, List.mem_singleton] at h
      rcases h with h | h
      · exact h2 c' h
      · subst h; exact hc

theorem getElem!_mem {α : Type} [Inhabited α] (l : List α) (i : Nat) (h : i < l.length) : l[i]! ∈ l := by
  rw [List.getElem!_eq_getElem?_getD, List.getElem?_eq_getElem h, Option.getD_some]
  exact List.getElem_mem h

theorem shrinkVictim_mem {D : Type} [Inhabited D] (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (hsort : ∀ l, (sort l).Perm l) (g : Graph) (e q : Nat) (dq : D) :
    shrinkVictim dist lt sort g e q dq ∈ g.adj e ∨ shrinkVictim dist lt sort g e q dq = q := by
  have base : ∀ c ∈ sort ((g.adj e).map (fun y => (dist e y, y)) ++ [(dq, q)]), c.2 ∈ g.adj e ∨ c.2 = q := by
    intro c hc
    rw [(hsort _).mem_iff] at hc
    simp only [List.mem_append, List.mem_map, List.mem_singleton] at hc
    rcases hc with ⟨y, hy, rfl⟩ | rfl
    · exact Or.inl hy
    · exact Or.inr rfl
  have hs := shrinkSplit_mem dist lt (sort ((g.adj e).map (fun y => (dist e y, y)) ++ [(dq, q)]))
    (sort ((g.adj e).map (fun y => (dist e y, y)) ++ [(dq, q)])) ([], [], []) (fun c h => h) (by simp) (by simp)
  unfold shrinkVictim
  simp only
  generalize shrinkSplit dist lt (sort ((g.adj e).map (fun y => (dist e y, y)) ++ [(dq, q)])) ([], [], []) = sp at hs
  obtain ⟨hk, hd⟩ := hs
  split
  · next i hi =>
    have hmem := List.mem_of_find?_eq_some hi
    simp only [List.mem_reverse, List.mem_range] at hmem
    exact base _ (hd _ (getElem!_mem _ _ hmem))
  · split
    · exact Or.inr rfl
    · split
      · next c hc => exact base _ (hd _ (List.mem_reverse.mp (List.mem_of_find?_eq_some hc)))
      · split
        · next c hc => exact base _ (hk _ (List.mem_reverse.mp (List.mem_of_find?_eq_some hc)))
        · cases hl : (sort ((g.adj e).map (fun y => (dist e y, y)) ++ [(dq, q)])).getLast? with
          | none => exact Or.inr rfl
          | some c => exact base _ (List.mem_of_getLast? hl)

theorem shrinkSplit_cover {D : Type} (dist : Nat → Nat → D) (lt : D → D → Bool) :
    ∀ (xs : List (D × Nat)) (acc : List (D × Nat) × List (D × Nat) × List Nat) (c : D × Nat),
      (c ∈ xs ∨ c ∈ acc.1 ∨ c ∈ acc.2.1) →
        c ∈ (shrinkSplit dist lt xs acc).1 ∨ c ∈ (shrinkSplit dist lt xs acc).2.1 := by
  intro xs
  induction xs with
  | nil => intro acc c h; simpa [shrinkSplit] using h
  | cons x rest ih =>
    intro acc c h
    obtain ⟨kept, dropped, blockers⟩ := acc
    unfold shrinkSplit
    split
    · apply ih; simp only [List.mem_cons, List.mem_append] at h ⊢; grind
    · apply ih; simp only [List.mem_cons, List.mem_append] at h ⊢; grind

theorem shrinkVictim_spares {D : Type} [Inhabited D] (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (hsort : ∀ l, (sort l).Perm l) (g : Graph) (e q : Nat) (dq : D) :
    (g.adj (shrinkVictim dist lt sort g e q dq)).length > 1 ∨
      ∀ y, (y ∈ g.adj e ∨ y = q) → (g.adj y).length ≤ 1 := by
  have base : ∀ y, (y ∈ g.adj e ∨ y = q) →
      ∃ c ∈ sort ((g.adj e).map (fun y => (dist e y, y)) ++ [(dq, q)]), c.2 = y := by
    intro y hy
    rcases hy with hy | rfl
    · exact ⟨(dist e y, y), by rw [(hsort _).mem_iff]; simp [hy], rfl⟩
    · exact ⟨(dq, y), by rw [(hsort _).mem_iff]; simp, rfl⟩
  have hc := shrinkSplit_cover dist lt (sort ((g.adj e).map (fun y => (dist e y, y)) ++ [(dq, q)])) ([], [], [])
  unfold shrinkVictim
  simp only
  generalize shrinkSplit dist lt (sort ((g.adj e).map (fun y => (dist e y, y)) ++ [(dq, q)])) ([], [], []) = sp at hc
  split
  · next i hi =>
    have := List.find?_some hi
    simp only [Bool.and_eq_true, decide_eq_true_eq] at this
    exact Or.inl this.1.2
  · split
    · next hb =>
      simp only [Bool.and_eq_true, decide_eq_true_eq] at hb
      exact Or.inl hb.2
    · split
      · next c hc' =>
        have := List.find?_some hc'
        simp only [decide_eq_true_eq] at this
        exact Or.inl this
      · next hn1 =>
        split
        · next c hc' =>
          have := List.find?_some hc'
          simp only [decide_eq_true_eq] at this
          exact Or.inl this
        · next hn2 =>
          refine Or.inr fun y hy => ?_
          obtain ⟨c, hcm, rfl⟩ := base y hy
          rcases hc c (Or.inl hcm) with h | h
          · have := List.find?_eq_none.mp hn2 c (List.mem_reverse.mpr h)
            simpa using this
          · have := List.find?_eq_none.mp hn1 c (List.mem_reverse.mpr h)
            simpa using this

def removeLinks (g : Graph) (slot : Nat) : Graph :=
  let g' := (g.adj slot).foldl (fun g n => listRemove g n slot) g
  ⟨fun x => if x = slot then false else g'.present x, fun x => if x = slot then [] else g'.adj x⟩

theorem removeFold_spec (slot : Nat) : ∀ (L : List Nat) (g : Graph), (∀ x, (g.adj x).Nodup) →
    let g' := L.foldl (fun g n => listRemove g n slot) g
    g'.present = g.present ∧ (∀ x, (g'.adj x).Nodup) ∧ (∀ x, (g'.adj x).length ≤ (g.adj x).length) ∧
      ∀ x b, b ∈ g'.adj x ↔ b ∈ g.adj x ∧ ¬(x ∈ L ∧ b = slot) := by
  intro L
  induction L with
  | nil => intro g h; exact ⟨rfl, h, fun x => Nat.le_refl _, fun x b => by simp⟩
  | cons n L ih =>
    intro g h
    simp only [List.foldl_cons]
    have hperm := listRemove_adj g n slot
    have h1 : ∀ x, ((listRemove g n slot).adj x).Nodup := by
      intro x; by_cases hx : x = n
      · subst hx; exact (List.Nodup.erase slot (h x)).perm hperm.symm
      · rw [listRemove_other g n slot x hx]; exact h x
    obtain ⟨p, nd, len, mem⟩ := ih (listRemove g n slot) h1
    refine ⟨by rw [p, listRemove_present], nd, fun x => ?_, fun x b => ?_⟩
    · refine Nat.le_trans (len x) ?_
      by_cases hx : x = n
      · subst hx; rw [hperm.length_eq]; exact List.length_erase_le
      · rw [listRemove_other g n slot x hx]; exact Nat.le_refl _
    · rw [mem x b]
      by_cases hx : x = n
      · subst hx; rw [hperm.mem_iff, mem_erase_nodup (h x)]
        simp only [List.mem_cons]
        constructor
        · rintro ⟨⟨h1, h2⟩, _⟩; exact ⟨h1, fun ⟨_, h4⟩ => h2 h4⟩
        · rintro ⟨h1, h2⟩; exact ⟨⟨h1, fun h4 => h2 ⟨Or.inl trivial, h4⟩⟩, fun ⟨_, h4⟩ => h2 ⟨Or.inl trivial, h4⟩⟩
      · rw [listRemove_other g n slot x hx]
        simp only [List.mem_cons]
        constructor
        · rintro ⟨h1, h2⟩; exact ⟨h1, fun ⟨h3, h4⟩ => h2 ⟨h3.resolve_left hx, h4⟩⟩
        · rintro ⟨h1, h2⟩; exact ⟨h1, fun ⟨h3, h4⟩ => h2 ⟨Or.inr h3, h4⟩⟩

theorem removeLinks_spec (cap : Nat) (g : Graph) (slot : Nat) (hw : Wf cap g) :
    Wf cap (removeLinks g slot) ∧ (removeLinks g slot).present slot = false ∧
      (∀ x, x ≠ slot → (removeLinks g slot).present x = g.present x) ∧
      (∀ x b, b ∈ (removeLinks g slot).adj x ↔ x ≠ slot ∧ b ∈ g.adj x ∧ b ≠ slot) := by
  obtain ⟨p, nd, len, mem⟩ := removeFold_spec slot (g.adj slot) g hw.nodup
  have hm : ∀ x b, b ∈ (removeLinks g slot).adj x ↔ x ≠ slot ∧ b ∈ g.adj x ∧ b ≠ slot := by
    intro x b
    unfold removeLinks
    simp only
    by_cases hx : x = slot
    · simp [hx]
    · simp only [hx, ite_false, mem x b, ne_eq, not_false_eq_true, true_and]
      have := hw.symm x b
      constructor
      · rintro ⟨h1, h2⟩; exact ⟨h1, fun e => h2 ⟨by subst e; exact this h1, e⟩⟩
      · rintro ⟨h1, h2⟩; exact ⟨h1, fun ⟨_, e⟩ => h2 e⟩
  have hpres : ∀ x, x ≠ slot → (removeLinks g slot).present x = g.present x := by
    intro x hx; unfold removeLinks; simp only [hx, ite_false]; rw [p]
  have symm := hw.symm; have irrefl := hw.irrefl; have closed := hw.closed
  refine ⟨⟨?_, ?_, ?_, ?_, ?_⟩, by unfold removeLinks; simp, hpres, hm⟩
  · intro a b hb; simp only [hm] at hb ⊢; grind
  · intro a; simp only [hm]; grind
  · intro a; unfold removeLinks; simp only; split
    · exact List.nodup_nil
    · exact nd a
  · intro a; unfold removeLinks; simp only; split
    · simp
    · exact Nat.le_trans (len a) (hw.bound a)
  · intro a b hb; rw [hm] at hb; rw [hpres b hb.2.2]; exact closed a b hb.2.1

theorem linkPair_spec (cap : Nat) (g : Graph) (a b : Nat) (hw : Wf cap g) (hab : a ≠ b) (hnb : b ∉ g.adj a)
    (ha : (g.adj a).length < cap) (hb : (g.adj b).length < cap) (pa : g.present a = true)
    (pb : g.present b = true) :
    Wf cap (linkPair cap g a b) ∧ (linkPair cap g a b).present = g.present ∧
      ∀ x y, y ∈ (linkPair cap g a b).adj x ↔ y ∈ g.adj x ∨ (x = a ∧ y = b) ∨ (x = b ∧ y = a) := by
  have hna : a ∉ g.adj b := fun h => hnb (hw.symm b a h)
  have hba : b ≠ a := fun e => hab e.symm
  have hadj : ∀ x, (linkPair cap g a b).adj x =
      if x = a then g.adj a ++ [b] else if x = b then g.adj b ++ [a] else g.adj x := by
    intro x
    unfold linkPair
    by_cases hxb : x = b
    · rw [hxb]
      rw [listAppend_adj cap _ b a (by rw [listAppend_other cap g a b b hba]; exact hb),
        listAppend_other cap g a b b hba]
      simp [hba]
    · rw [listAppend_other cap _ b a x hxb]
      by_cases hxa : x = a
      · rw [hxa, listAppend_adj cap g a b ha]; simp
      · rw [listAppend_other cap g a b x hxa]; simp [hxa, hxb]
  have hm : ∀ x y, y ∈ (linkPair cap g a b).adj x ↔ y ∈ g.adj x ∨ (x = a ∧ y = b) ∨ (x = b ∧ y = a) := by
    intro x y; rw [hadj]
    by_cases hxa : x = a
    · rw [hxa]; simp [hab] <;> grind
    · by_cases hxb : x = b
      · rw [hxb]; simp [hba] <;> grind
      · simp [hxa, hxb]
  have hp : (linkPair cap g a b).present = g.present := by
    unfold linkPair; rw [listAppend_present, listAppend_present]
  have symm := hw.symm; have irrefl := hw.irrefl; have closed := hw.closed
  refine ⟨⟨?_, ?_, ?_, ?_, ?_⟩, hp, hm⟩
  · intro x y hy; simp only [hm] at hy ⊢; grind
  · intro x; simp only [hm]; grind
  · intro x; rw [hadj]; split
    · next hx => subst hx; exact List.nodup_append.mpr ⟨hw.nodup x, by simp, by grind⟩
    · split
      · next hx => subst hx; exact List.nodup_append.mpr ⟨hw.nodup x, by simp, by grind⟩
      · exact hw.nodup x
  · intro x; rw [hadj]; split
    · next hx => subst hx; simp; omega
    · split
      · next hx => subst hx; simp; omega
      · exact hw.bound x
  · intro x y hy; rw [hp]; simp only [hm] at hy; grind

def isGood {D : Type} (dist : Nat → Nat → D) (lt : D → D → Bool) (g : Graph) (n : Nat) (c : D × Nat) : Bool :=
  (g.adj n).all (fun r => !lt (dist c.2 r) c.1)

def repairPass {D : Type} (cap : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool) (n : Nat) :
    Graph → List (D × Nat) → Graph × List (D × Nat)
  | g, [] => (g, [])
  | g, c :: rest =>
    if (g.adj n).length ≥ cap then (g, [])
    else if (g.adj c.2).length ≥ cap then repairPass cap dist lt n g rest
    else if isGood dist lt g n c then repairPass cap dist lt n (linkPair cap g n c.2) rest
    else ((repairPass cap dist lt n g rest).1, c :: (repairPass cap dist lt n g rest).2)

def linkPass {D : Type} (cap n : Nat) : Graph → List (D × Nat) → Graph
  | g, [] => g
  | g, c :: rest =>
    if (g.adj n).length ≥ cap then g
    else if (g.adj c.2).length ≥ cap then linkPass cap n g rest
    else linkPass cap n (linkPair cap g n c.2) rest

def repair {D : Type} (cap : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (keepPruned : Bool) (relink : Graph → Nat → Graph)
    (g : Graph) (n : Nat) (group : List Nat) : Graph :=
  if (g.adj n).length ≥ cap then g
  else
    let work := sort ((group.filter (fun c => c != n && !(g.adj n).contains c)).map (fun c => (dist n c, c)))
    let r := repairPass cap dist lt n g work
    let g1 := if keepPruned then linkPass cap n r.1 r.2 else r.1
    if (g1.adj n).length = 0 then relink g1 n else g1

def removeNode {D : Type} (cap : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (keepPruned : Bool) (relink : Graph → Nat → Graph)
    (g : Graph) (slot : Nat) : Graph :=
  (g.adj slot).foldl (fun g' n => repair cap dist lt sort keepPruned relink g' n (g.adj slot)) (removeLinks g slot)

def PassPre {D : Type} (g : Graph) (n : Nat) (work : List (D × Nat)) : Prop :=
  (work.map Prod.snd).Nodup ∧ n ∉ work.map Prod.snd ∧ ∀ c ∈ work.map Prod.snd, g.present c = true ∧ c ∉ g.adj n

theorem repairPass_spec {D : Type} (cap : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool) (n : Nat) :
    ∀ (work : List (D × Nat)) (g : Graph), Wf cap g → g.present n = true → PassPre g n work →
      Wf cap (repairPass cap dist lt n g work).1 ∧ (repairPass cap dist lt n g work).1.present = g.present ∧
      (∀ y ∈ (repairPass cap dist lt n g work).1.adj n, y ∈ g.adj n ∨ y ∈ work.map Prod.snd) ∧
      ((repairPass cap dist lt n g work).2.map Prod.snd).Sublist (work.map Prod.snd) ∧
      ∀ c ∈ (repairPass cap dist lt n g work).2.map Prod.snd, c ∉ (repairPass cap dist lt n g work).1.adj n := by
  intro work
  induction work with
  | nil =>
    intro g hw _ _
    simp only [repairPass]
    exact ⟨hw, trivial, fun y hy => Or.inl hy, List.Sublist.slnil, fun c h => by simp at h⟩
  | cons c rest ih =>
    intro g hw hn hpre
    obtain ⟨hnd, hnn, hall⟩ := hpre
    simp only [List.map_cons, List.nodup_cons, List.mem_cons, not_or] at hnd hnn hall
    have hc := hall c.2 (Or.inl rfl)
    have hrest : PassPre g n rest := ⟨hnd.2, hnn.2, fun x hx => hall x (Or.inr hx)⟩
    unfold repairPass
    split
    · exact ⟨hw, rfl, fun y hy => Or.inl hy, List.nil_sublist _, fun c h => by simp at h⟩
    · next hcap =>
      split
      · obtain ⟨r1, r2, r3, r4, r5⟩ := ih g hw hn hrest
        exact ⟨r1, r2, fun y hy => (r3 y hy).elim Or.inl (fun h => Or.inr (by simp [h])),
          r4.trans (List.sublist_cons_self _ _), r5⟩
      · next hcap2 =>
        split
        · have hne : n ≠ c.2 := fun e => hnn.1 e
          obtain ⟨l1, l2, l3⟩ := linkPair_spec cap g n c.2 hw hne hc.2 (by omega) (by omega) hn hc.1
          have hrest' : PassPre (linkPair cap g n c.2) n rest := by
            refine ⟨hnd.2, hnn.2, fun x hx => ⟨by rw [l2]; exact (hall x (Or.inr hx)).1, fun hm => ?_⟩⟩
            rw [l3] at hm
            have hxc : x ≠ c.2 := fun e => hnd.1 (e ▸ hx)
            have hxn : x ≠ n := fun e => hnn.2 (e ▸ hx)
            rcases hm with hm | ⟨_, hm⟩ | ⟨hm, _⟩
            · exact (hall x (Or.inr hx)).2 hm
            · exact hxc hm
            · exact hne hm
          obtain ⟨r1, r2, r3, r4, r5⟩ := ih _ l1 (by rw [l2]; exact hn) hrest'
          refine ⟨r1, by rw [r2, l2], fun y hy => ?_, r4.trans (List.sublist_cons_self _ _), r5⟩
          rcases r3 y hy with h | h
          · rw [l3] at h
            rcases h with h | ⟨_, h⟩ | ⟨h, _⟩
            · exact Or.inl h
            · exact Or.inr (by simp [h])
            · exact absurd h hne
          · exact Or.inr (by simp [h])
        · obtain ⟨r1, r2, r3, r4, r5⟩ := ih g hw hn hrest
          refine ⟨r1, r2, fun y hy => (r3 y hy).elim Or.inl (fun h => Or.inr (by simp [h])),
            by simp only [List.map_cons]; exact r4.cons_cons _, fun x hx => ?_⟩
          simp only [List.map_cons, List.mem_cons] at hx
          rcases hx with hx | hx
          · subst hx
            intro hm
            rcases r3 _ hm with h | h
            · exact hc.2 h
            · exact hnd.1 h
          · exact r5 x hx

theorem linkPass_spec {D : Type} (cap n : Nat) :
    ∀ (work : List (D × Nat)) (g : Graph), Wf cap g → g.present n = true → PassPre g n work →
      Wf cap (linkPass cap n g work) ∧ (linkPass cap n g work).present = g.present := by
  intro work
  induction work with
  | nil => intro g hw _ _; exact ⟨hw, rfl⟩
  | cons c rest ih =>
    intro g hw hn hpre
    obtain ⟨hnd, hnn, hall⟩ := hpre
    simp only [List.map_cons, List.nodup_cons, List.mem_cons, not_or] at hnd hnn hall
    have hc := hall c.2 (Or.inl rfl)
    unfold linkPass
    split
    · exact ⟨hw, rfl⟩
    · split
      · exact ih g hw hn ⟨hnd.2, hnn.2, fun x hx => hall x (Or.inr hx)⟩
      · have hne : n ≠ c.2 := fun e => hnn.1 e
        obtain ⟨l1, l2, l3⟩ := linkPair_spec cap g n c.2 hw hne hc.2 (by omega) (by omega) hn hc.1
        have hrest' : PassPre (linkPair cap g n c.2) n rest := by
          refine ⟨hnd.2, hnn.2, fun x hx => ⟨by rw [l2]; exact (hall x (Or.inr hx)).1, fun hm => ?_⟩⟩
          rw [l3] at hm
          have hxc : x ≠ c.2 := fun e => hnd.1 (e ▸ hx)
          rcases hm with hm | ⟨_, hm⟩ | ⟨hm, _⟩
          · exact (hall x (Or.inr hx)).2 hm
          · exact hxc hm
          · exact hne hm
        obtain ⟨r1, r2⟩ := ih _ l1 (by rw [l2]; exact hn) hrest'
        exact ⟨r1, by rw [r2, l2]⟩

def RelinkOk (cap : Nat) (relink : Graph → Nat → Graph) : Prop :=
  ∀ g m, Wf cap g → g.present m = true → g.adj m = [] → Wf cap (relink g m) ∧ (relink g m).present = g.present

theorem repair_wf {D : Type} (cap : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (hsort : ∀ l, (sort l).Perm l) (keepPruned : Bool)
    (relink : Graph → Nat → Graph) (hrelink : RelinkOk cap relink) (g : Graph) (n : Nat) (group : List Nat)
    (hw : Wf cap g) (hn : g.present n = true) (hgroup : ∀ c ∈ group, g.present c = true) (hgn : group.Nodup) :
    Wf cap (repair cap dist lt sort keepPruned relink g n group) ∧
      (repair cap dist lt sort keepPruned relink g n group).present = g.present := by
  unfold repair
  split
  · exact ⟨hw, rfl⟩
  · simp only
    generalize hwk : sort ((group.filter (fun c => c != n && !(g.adj n).contains c)).map (fun c => (dist n c, c))) = work
    have hperm : (work.map Prod.snd).Perm (group.filter (fun c => c != n && !(g.adj n).contains c)) := by
      rw [← hwk]
      have := (hsort ((group.filter (fun c => c != n && !(g.adj n).contains c)).map (fun c => (dist n c, c)))).map Prod.snd
      have e : ∀ L : List Nat, List.map Prod.snd (List.map (fun c => (dist n c, c)) L) = L := by
        intro L; induction L with
        | nil => rfl
        | cons x L ih => simp [ih]
      rw [e] at this
      exact this
    have hpre : PassPre g n work := by
      refine ⟨hperm.nodup_iff.mpr (hgn.filter _), fun h => ?_, fun c hc => ?_⟩
      · rw [hperm.mem_iff, List.mem_filter] at h; simp at h
      · rw [hperm.mem_iff, List.mem_filter] at hc
        have hc' : c ∈ group ∧ c ≠ n ∧ c ∉ g.adj n := by simpa using hc
        exact ⟨hgroup c hc'.1, hc'.2.2⟩
    obtain ⟨r1, r2, _, r4, r5⟩ := repairPass_spec cap dist lt n work g hw hn hpre
    have hg1 : Wf cap (if keepPruned then linkPass cap n (repairPass cap dist lt n g work).1 (repairPass cap dist lt n g work).2
        else (repairPass cap dist lt n g work).1) ∧
        (if keepPruned then linkPass cap n (repairPass cap dist lt n g work).1 (repairPass cap dist lt n g work).2
          else (repairPass cap dist lt n g work).1).present = g.present := by
      split
      · have hpre2 : PassPre (repairPass cap dist lt n g work).1 n (repairPass cap dist lt n g work).2 := by
          refine ⟨hpre.1.sublist r4, fun h => hpre.2.1 (r4.subset h), fun c hc => ⟨?_, r5 c hc⟩⟩
          rw [r2]; exact (hpre.2.2 c (r4.subset hc)).1
        obtain ⟨l1, l2⟩ := linkPass_spec cap n _ _ r1 (by rw [r2]; exact hn) hpre2
        exact ⟨l1, by rw [l2, r2]⟩
      · exact ⟨r1, r2⟩
    generalize (if keepPruned then linkPass cap n (repairPass cap dist lt n g work).1 (repairPass cap dist lt n g work).2
        else (repairPass cap dist lt n g work).1) = g1 at hg1
    split
    · next h0 =>
      obtain ⟨w1, p1⟩ := hg1
      obtain ⟨q1, q2⟩ := hrelink g1 n w1 (by rw [p1]; exact hn) (List.eq_nil_of_length_eq_zero h0)
      exact ⟨q1, by rw [q2, p1]⟩
    · exact hg1

theorem removeNode_wf {D : Type} (cap : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (hsort : ∀ l, (sort l).Perm l) (keepPruned : Bool)
    (relink : Graph → Nat → Graph) (hrelink : RelinkOk cap relink) (g : Graph) (slot : Nat) (hw : Wf cap g) :
    Wf cap (removeNode cap dist lt sort keepPruned relink g slot) ∧
      (removeNode cap dist lt sort keepPruned relink g slot).present slot = false ∧
      (∀ a, slot ∉ (removeNode cap dist lt sort keepPruned relink g slot).adj a) := by
  obtain ⟨w0, p0, px, _⟩ := removeLinks_spec cap g slot hw
  have hgrp : ∀ c ∈ g.adj slot, (removeLinks g slot).present c = true := by
    intro c hc
    have hcs : c ≠ slot := fun e => hw.irrefl slot (e ▸ hc)
    rw [px c hcs]; exact hw.closed slot c hc
  have key : ∀ (L : List Nat) (g' : Graph), (∀ x ∈ L, x ∈ g.adj slot) → Wf cap g' →
      g'.present = (removeLinks g slot).present →
      Wf cap (L.foldl (fun g'' n => repair cap dist lt sort keepPruned relink g'' n (g.adj slot)) g') ∧
        (L.foldl (fun g'' n => repair cap dist lt sort keepPruned relink g'' n (g.adj slot)) g').present =
          (removeLinks g slot).present := by
    intro L
    induction L with
    | nil => intro g' _ hw' hp'; exact ⟨hw', hp'⟩
    | cons n L ih =>
      intro g' hL hw' hp'
      simp only [List.foldl_cons]
      have hnin := hL n (by simp)
      obtain ⟨a1, a2⟩ := repair_wf cap dist lt sort hsort keepPruned relink hrelink g' n (g.adj slot) hw'
        (by rw [hp']; exact hgrp n hnin) (fun c hc => by rw [hp']; exact hgrp c hc) (hw.nodup slot)
      exact ih _ (fun x hx => hL x (by simp [hx])) a1 (by rw [a2, hp'])
  obtain ⟨k1, k2⟩ := key (g.adj slot) (removeLinks g slot) (fun x hx => hx) w0 rfl
  unfold removeNode
  refine ⟨k1, by rw [k2]; exact p0, fun a ha => ?_⟩
  have := k1.closed a slot ha
  rw [k2, p0] at this
  exact absurd this (by simp)

def insertNode (cap : Nat) (g : Graph) (q : Nat) (selected : List Nat) (victim : Graph → Nat → Nat)
    (guard : Graph → Nat → Nat → Bool) (pick : Graph → Nat → List Nat → Option Nat) : Graph :=
  connect cap ⟨fun x => if x = q then true else g.present x, fun x => if x = q then [] else g.adj x⟩ q selected victim
    guard pick

theorem insertNode_wf (cap : Nat) (g : Graph) (q : Nat) (selected : List Nat) (victim : Graph → Nat → Nat)
    (guard : Graph → Nat → Nat → Bool) (pick : Graph → Nat → List Nat → Option Nat) (hpick : PickOk pick)
    (hw : Wf cap g) (hq : g.present q = false) (hsel : selected.Nodup) (hqs : q ∉ selected)
    (hpres : ∀ x ∈ selected, g.present x = true)
    (hvict : ∀ g' e', victim g' e' ∈ g'.adj e' ∨ victim g' e' = q) :
    Wf cap (insertNode cap g q selected victim guard pick) ∧ (insertNode cap g q selected victim guard pick).present q = true := by
  have hnone : ∀ x, q ∉ g.adj x := fun x hx => by have := hw.closed x q hx; rw [hq] at this; simp at this
  have hqe : g.adj q = [] := by
    cases hl : g.adj q with
    | nil => rfl
    | cons b t =>
      have : b ∈ g.adj q := by rw [hl]; simp
      exact absurd (hw.symm q b this) (hnone b)
  let g0 : Graph := ⟨fun x => if x = q then true else g.present x, fun x => if x = q then [] else g.adj x⟩
  have hadj0 : ∀ x, g0.adj x = g.adj x := by
    intro x; show (if x = q then [] else g.adj x) = g.adj x
    split
    · next h => subst h; exact hqe.symm
    · rfl
  have hw0 : Wf cap g0 := by
    refine ⟨fun a b hb => ?_, fun a => ?_, fun a => ?_, fun a => ?_, fun a b hb => ?_⟩
    · rw [hadj0] at hb ⊢; exact hw.symm a b hb
    · rw [hadj0]; exact hw.irrefl a
    · rw [hadj0]; exact hw.nodup a
    · rw [hadj0]; exact hw.bound a
    · rw [hadj0] at hb
      show (if b = q then true else g.present b) = true
      split
      · rfl
      · exact hw.closed a b hb
  have hsel0 : ∀ x ∈ selected, g0.present x = true := by
    intro x hx; show (if x = q then true else g.present x) = true
    split
    · rfl
    · exact hpres x hx
  obtain ⟨c1, c2⟩ := connect_wf cap g0 q selected victim guard pick hpick hw0
    (by show (if q = q then true else _) = true; simp) (by show (if q = q then [] else g.adj q) = []; simp)
    hsel hqs hsel0 hvict
  refine ⟨c1, ?_⟩
  unfold insertNode
  rw [c2]; show (if q = q then true else g.present q) = true; simp

def relinkWith {D : Type} [Inhabited D] (cap : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (sel : Graph → Nat → List Nat) (dq : Graph → Nat → Nat → D)
    (guard : Graph → Nat → Nat → Bool) (pick : Graph → Nat → List Nat → Option Nat) : Graph → Nat → Graph :=
  fun g n => connect cap g n (sel g n) (fun g' e => shrinkVictim dist lt sort g' e n (dq g n e)) guard pick

theorem relinkWith_ok {D : Type} [Inhabited D] (cap : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (hsort : ∀ l, (sort l).Perm l) (sel : Graph → Nat → List Nat)
    (dq : Graph → Nat → Nat → D) (guard : Graph → Nat → Nat → Bool) (pick : Graph → Nat → List Nat → Option Nat)
    (hpick : PickOk pick)
    (hsel : ∀ g n, (sel g n).Nodup ∧ n ∉ sel g n ∧ ∀ x ∈ sel g n, g.present x = true) :
    RelinkOk cap (relinkWith cap dist lt sort sel dq guard pick) := by
  intro g m hw hm he
  obtain ⟨s1, s2, s3⟩ := hsel g m
  exact connect_wf cap g m (sel g m) _ guard pick hpick hw hm he s1 s2 s3
    (fun g' e => shrinkVictim_mem dist lt sort hsort g' e m (dq g m e))

def layerCap (m layer : Nat) : Nat := if layer = 0 then 2 * m else m

theorem insert_layer_wf {D : Type} [Inhabited D] (m layer : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (hsort : ∀ l, (sort l).Perm l) (guard : Graph → Nat → Nat → Bool)
    (pick : Graph → Nat → List Nat → Option Nat) (hpick : PickOk pick) (g : Graph) (q : Nat)
    (selected : List Nat) (dq : Nat → D) (hw : Wf (layerCap m layer) g) (hq : g.present q = false)
    (hsel : selected.Nodup) (hqs : q ∉ selected) (hpres : ∀ x ∈ selected, g.present x = true) :
    Wf (layerCap m layer)
      (insertNode (layerCap m layer) g q selected (fun g' e => shrinkVictim dist lt sort g' e q (dq e)) guard pick) :=
  (insertNode_wf _ g q selected _ guard pick hpick hw hq hsel hqs hpres
    (fun g' e => shrinkVictim_mem dist lt sort hsort g' e q (dq e))).1

theorem remove_layer_wf {D : Type} [Inhabited D] (m layer : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (hsort : ∀ l, (sort l).Perm l) (keepPruned : Bool)
    (sel : Graph → Nat → List Nat) (dq : Graph → Nat → Nat → D) (guard : Graph → Nat → Nat → Bool)
    (pick : Graph → Nat → List Nat → Option Nat) (hpick : PickOk pick)
    (hsel : ∀ g n, (sel g n).Nodup ∧ n ∉ sel g n ∧ ∀ x ∈ sel g n, g.present x = true)
    (g : Graph) (slot : Nat) (hw : Wf (layerCap m layer) g) :
    Wf (layerCap m layer) (removeNode (layerCap m layer) dist lt sort keepPruned
        (relinkWith (layerCap m layer) dist lt sort sel dq guard pick) g slot) ∧
      ∀ a, slot ∉ (removeNode (layerCap m layer) dist lt sort keepPruned
        (relinkWith (layerCap m layer) dist lt sort sel dq guard pick) g slot).adj a := by
  have := removeNode_wf (layerCap m layer) dist lt sort hsort keepPruned _
    (relinkWith_ok _ dist lt sort hsort sel dq guard pick hpick hsel) g slot hw
  exact ⟨this.1, this.2.2⟩

theorem layer_cap_fits (m layer : Nat) (hm : m ≤ 32767) : layerCap m layer < 2 ^ 16 := by
  unfold layerCap; split <;> omega

theorem adopt_grows (cap : Nat) (pick : Graph → Nat → List Nat → Option Nat) (hpick : PickOk pick)
    (htotal : ∀ g o L, L ≠ [] → pick g o L ≠ none) (g : Graph) (o hub : Nat) (ho : (g.adj o).length < cap) :
    (g.adj o).length ≤ ((adopt cap pick g o hub).adj o).length ∧
      (adoptCands cap g o hub ≠ [] → ((adopt cap pick g o hub).adj o).length = (g.adj o).length + 1) := by
  unfold adopt
  split
  · next y hy =>
    have hmem := hpick _ _ _ _ hy
    unfold adoptCands at hmem
    rw [List.mem_filter] at hmem
    obtain ⟨_, hf⟩ := hmem
    simp only [Bool.and_eq_true, bne_iff_ne, ne_eq, decide_eq_true_eq, Bool.not_eq_eq_eq_not, Bool.not_true,
      List.contains_eq_mem, decide_eq_false_iff_not] at hf
    obtain ⟨⟨⟨hyo, hyc⟩, _⟩, _⟩ := hf
    rw [linkPair_adj cap g o y (fun e => hyo e.symm) ho hyc, ite_eq_left rfl]
    simp
  · next hn => exact ⟨Nat.le_refl _, fun hne => absurd hn (htotal _ _ _ hne)⟩

theorem exists_ne_of_two (l : List Nat) (hl : l.Nodup) (h2 : 2 ≤ l.length) (v : Nat) : ∃ y ∈ l, y ≠ v := by
  match l, hl, h2 with
  | a :: b :: rest, hl, _ =>
    have hab : a ≠ b := fun e => (List.nodup_cons.mp hl).1 (e ▸ by simp)
    by_cases hav : a = v
    · exact ⟨b, by simp, fun e => hab (hav.trans e.symm)⟩
    · exact ⟨a, by simp, hav⟩

theorem evict_never_isolates {cap P q g e R} (victim : Graph → Nat → Nat) (guard : Graph → Nat → Nat → Bool)
    (pick : Graph → Nat → List Nat → Option Nat) (hpick : PickOk pick)
    (htotal : ∀ g o L, L ≠ [] → pick g o L ≠ none) (hcap : 2 ≤ cap) (h : ConnInv cap P q g (e :: R))
    (hfull : cap ≤ (g.adj e).length) (hv : victim g e ∈ g.adj e ∨ victim g e = q)
    (hspare : 1 < (g.adj (victim g e)).length ∨ ∀ y, (y ∈ g.adj e ∨ y = q) → (g.adj y).length ≤ 1) :
    0 < ((connectStep cap q victim guard pick g e).adj (victim g e)).length := by
  have hpe := h.pend e (by simp)
  have heq : e ≠ q := fun h' => h.rq (h' ▸ by simp)
  have hsymm : ∀ y ∈ g.adj e, e ∈ g.adj y := by
    intro y hy
    rcases h.symm e y hy with h' | ⟨h', _⟩
    · exact h'
    · exact absurd h' heq
  have hone : ∀ y ∈ g.adj e, (g.adj y).length ≤ 1 → g.adj y = [e] := by
    intro y hy hl
    have hm := hsymm y hy
    match hg : g.adj y, hl with
    | [], _ => rw [hg] at hm; simp at hm
    | [a], _ => rw [hg] at hm; simp at hm; rw [hm]
    | a :: b :: t, hl => simp at hl
  unfold connectStep
  rw [ite_eq_right (by omega)]
  simp only
  by_cases hvq : victim g e = q
  · simp only [hvq, ite_true, bne_self_eq_false, Bool.false_and, Bool.or_false]
    have hperm := listRemove_adj g q e
    have hlen : ((listRemove g q e).adj q).length = (g.adj q).length - 1 := by
      rw [hperm.length_eq, List.length_erase_of_mem hpe.1]
    have hroom : ((listRemove g q e).adj q).length < cap := by
      have := h.bound q; rw [hlen]; omega
    have hgrow := adopt_grows cap pick hpick htotal (listRemove g q e) q e hroom
    by_cases h1 : 1 < (g.adj q).length
    · have hpos : 0 < ((listRemove g q e).adj q).length := by rw [hlen]; omega
      split
      · exact Nat.lt_of_lt_of_le hpos hgrow.1
      · exact hpos
    · have hfb : ∀ y, (y ∈ g.adj e ∨ y = q) → (g.adj y).length ≤ 1 := by
        rcases hspare with hs | hs
        · rw [hvq] at hs; exact absurd hs h1
        · exact hs
      have h0 : ((listRemove g q e).adj q).length = 0 := by
        rw [hlen]; have := List.length_pos_of_mem hpe.1; omega
      rw [ite_eq_left (by simp [h0])]
      obtain ⟨y, hy, _⟩ := exists_ne_of_two (g.adj e) (h.nodup e) (by omega) q
      have hyq : y ≠ q := fun e' => hpe.2 (e' ▸ hy)
      have hyc : y ∈ adoptCands cap (listRemove g q e) q e := by
        unfold adoptCands
        rw [List.mem_filter, listRemove_other g q e e heq]
        refine ⟨hy, ?_⟩
        have hya := hone y hy (hfb y (Or.inl hy))
        have hry : (listRemove g q e).adj y = [e] := by rw [listRemove_other g q e y hyq, hya]
        rw [hry, List.eq_nil_of_length_eq_zero h0]
        have hc1 : 1 < cap := by omega
        simp [hyq, Ne.symm heq, hc1]
      have := hgrow.2 (List.ne_nil_of_mem hyc)
      omega
  · rcases hv with hvm | hvm
    · simp only [hvq, ite_false]
      generalize hv' : victim g e = v at hvm hvq hspare ⊢
      have hve : e ∈ g.adj v := hsymm v hvm
      have hve' : v ≠ e := fun e' => h.irrefl e (e' ▸ hvm)
      have hp := listRemove_adj (listReplace g e v q) v e
      have hlen : ((listRemove (listReplace g e v q) v e).adj v).length = (g.adj v).length - 1 := by
        rw [hp.length_eq, listReplace_other g e v q v hve', List.length_erase_of_mem hve]
      have hroom : ((listRemove (listReplace g e v q) v e).adj v).length < cap := by
        have := h.bound v; rw [hlen]; omega
      have hgrow := adopt_grows cap pick hpick htotal (listRemove (listReplace g e v q) v e) v e hroom
      by_cases h1 : 1 < (g.adj v).length
      · have hpos : 0 < ((listRemove (listReplace g e v q) v e).adj v).length := by rw [hlen]; omega
        split
        · exact Nat.lt_of_lt_of_le hpos hgrow.1
        · exact hpos
      · have hfb : ∀ y, (y ∈ g.adj e ∨ y = q) → (g.adj y).length ≤ 1 := by
          rcases hspare with hs | hs
          · exact absurd hs h1
          · exact hs
        have h0 : ((listRemove (listReplace g e v q) v e).adj v).length = 0 := by
          rw [hlen]; have := List.length_pos_of_mem hve; omega
        rw [ite_eq_left (by simp [h0])]
        obtain ⟨y, hy, hyv⟩ := exists_ne_of_two (g.adj e) (h.nodup e) (by omega) v
        have hye : y ≠ e := fun e' => h.irrefl e (e' ▸ hy)
        have hyc : y ∈ adoptCands cap (listRemove (listReplace g e v q) v e) v e := by
          unfold adoptCands
          rw [List.mem_filter, listRemove_other _ v e e (Ne.symm hve')]
          have hpe1 := listReplace_adj g e v q hvm
          refine ⟨by rw [hpe1.mem_iff, List.mem_cons, mem_erase_nodup (h.nodup e)]; exact Or.inr ⟨hy, hyv⟩, ?_⟩
          have hya := hone y hy (hfb y (Or.inl hy))
          have hry : (listRemove (listReplace g e v q) v e).adj y = [e] := by
            rw [listRemove_other _ v e y hyv, listReplace_other g e v q y hye, hya]
          rw [hry, List.eq_nil_of_length_eq_zero h0]
          have hc1 : 1 < cap := by omega
          simp [hyv, hve', hc1]
        have := hgrow.2 (List.ne_nil_of_mem hyc)
        omega
    · exact absurd hvm hvq

def closestPick (dist : Nat → Nat → Int) : Graph → Nat → List Nat → Option Nat :=
  fun _ o L => L.foldl (fun best y => match best with
    | none => some y
    | some b => if closer ⟨dist o y, y⟩ ⟨dist o b, b⟩ then some y else some b) none

theorem closestFold_mem (dist : Nat → Nat → Int) (o : Nat) (S : List Nat) :
    ∀ (L : List Nat) (acc : Option Nat), (∀ b, acc = some b → b ∈ S) → (∀ y ∈ L, y ∈ S) →
      ∀ b, L.foldl (fun best y => match best with
        | none => some y
        | some b => if closer ⟨dist o y, y⟩ ⟨dist o b, b⟩ then some y else some b) acc = some b → b ∈ S := by
  intro L
  induction L with
  | nil => intro acc ha _ b hb; exact ha b hb
  | cons y ys ih =>
    intro acc ha hL b hb
    simp only [List.foldl_cons] at hb
    refine ih _ ?_ (fun z hz => hL z (by simp [hz])) b hb
    intro c hc
    cases acc with
    | none =>
      have : y = c := by simpa using hc
      rw [← this]; exact hL y (by simp)
    | some a =>
      simp only at hc
      split at hc
      · have : y = c := by simpa using hc
        rw [← this]; exact hL y (by simp)
      · have : a = c := by simpa using hc
        rw [← this]; exact ha a rfl

theorem closestFold_some (dist : Nat → Nat → Int) (o : Nat) :
    ∀ (L : List Nat) (acc : Option Nat), (acc ≠ none ∨ L ≠ []) →
      L.foldl (fun best y => match best with
        | none => some y
        | some b => if closer ⟨dist o y, y⟩ ⟨dist o b, b⟩ then some y else some b) acc ≠ none := by
  intro L
  induction L with
  | nil => intro acc h; simpa using h
  | cons y ys ih =>
    intro acc _
    simp only [List.foldl_cons]
    apply ih
    left
    cases acc with
    | none => simp
    | some a => simp only; split <;> simp

theorem closestPick_ok (dist : Nat → Nat → Int) : PickOk (closestPick dist) := by
  intro g o L y hy
  exact closestFold_mem dist o L L none (by simp) (fun z hz => hz) y hy

theorem closestPick_total (dist : Nat → Nat → Int) : ∀ g o L, L ≠ [] → closestPick dist g o L ≠ none := by
  intro g o L hL
  exact closestFold_some dist o L none (Or.inr hL)

def islandLimit : Nat := 64

def islandScan (g : Graph) (hub : Nat) : List Nat → List Nat → Option (List Nat)
  | [], trail => some trail
  | y :: ys, trail =>
    if y = hub then none
    else if y ∈ trail then islandScan g hub ys trail
    else if trail.length = islandLimit then none
    else islandScan g hub ys (trail ++ [y])

def islandWalk (g : Graph) (hub : Nat) : Nat → List Nat → Nat → Bool
  | 0, _, _ => true
  | fuel + 1, trail, head =>
    if trail.length ≤ head then true
    else match islandScan g hub (g.adj (trail[head]?.getD 0)) trail with
      | none => false
      | some t => islandWalk g hub fuel t (head + 1)

def stranded (g : Graph) (src hub : Nat) : Bool := islandWalk g hub (islandLimit + 1) [src] 0

def insertRev {α : Type} (lt : α → α → Bool) (v : α) : List α → List α
  | [] => [v]
  | x :: xs => if lt v x then x :: insertRev lt v xs else v :: x :: xs

def insertionSort {α : Type} (lt : α → α → Bool) (l : List α) : List α :=
  (l.foldl (fun acc v => insertRev lt v acc) []).reverse

def sortSmall : Nat := 48

def candidatesSort {α : Type} (lt : α → α → Bool) (big : List α → List α) (l : List α) : List α :=
  if sortSmall < l.length then big l else insertionSort lt l

theorem insertRev_perm {α : Type} (lt : α → α → Bool) (v : α) : ∀ l : List α, (insertRev lt v l).Perm (v :: l) := by
  intro l
  induction l with
  | nil => exact List.Perm.refl _
  | cons x xs ih =>
    unfold insertRev
    split
    · exact ((ih.cons x).trans (List.Perm.swap v x xs))
    · exact List.Perm.refl _

theorem insertFold_perm {α : Type} (lt : α → α → Bool) :
    ∀ (l acc : List α), (l.foldl (fun acc v => insertRev lt v acc) acc).Perm (l.reverse ++ acc) := by
  intro l
  induction l with
  | nil => intro acc; simp
  | cons x xs ih =>
    intro acc
    simp only [List.foldl_cons, List.reverse_cons, List.append_assoc, List.singleton_append]
    exact (ih _).trans (List.Perm.append_left _ (insertRev_perm lt x acc))

theorem insertionSort_perm {α : Type} (lt : α → α → Bool) (l : List α) : (insertionSort lt l).Perm l := by
  unfold insertionSort
  have := insertFold_perm lt l []
  rw [List.append_nil] at this
  exact (List.reverse_perm _).trans (this.trans (List.reverse_perm l))

theorem candidatesSort_perm {α : Type} (lt : α → α → Bool) (big : List α → List α) (hbig : ∀ l, (big l).Perm l) :
    ∀ l, (candidatesSort lt big l).Perm l := by
  intro l
  unfold candidatesSort
  split
  · exact hbig l
  · exact insertionSort_perm lt l

theorem insertRev_sorted (v : Cand) : ∀ l : List Cand, l.Pairwise (fun a b => closer a b = false) →
    (insertRev closer v l).Pairwise (fun a b => closer a b = false) := by
  intro l
  induction l with
  | nil => intro _; simp [insertRev]
  | cons x xs ih =>
    intro hl
    have hx := List.pairwise_cons.mp hl
    unfold insertRev
    split
    · next hvx =>
      refine List.pairwise_cons.mpr ⟨fun y hy => ?_, ih hx.2⟩
      rw [(insertRev_perm closer v xs).mem_iff] at hy
      rcases List.mem_cons.mp hy with rfl | hy
      · exact closer_strict.asymm' hvx
      · exact hx.1 y hy
    · next hvx =>
      have hvx' : closer v x = false := by simpa using hvx
      refine List.pairwise_cons.mpr ⟨fun y hy => ?_, hl⟩
      rcases List.mem_cons.mp hy with rfl | hy
      · exact hvx'
      · exact closer_strict.le_trans' (hx.1 y hy) hvx'

theorem insertionSort_sorted (l : List Cand) : (insertionSort closer l).Pairwise (fun a b => closer b a = false) := by
  unfold insertionSort
  rw [List.pairwise_reverse]
  have : ∀ (l acc : List Cand), acc.Pairwise (fun a b => closer a b = false) →
      (l.foldl (fun acc v => insertRev closer v acc) acc).Pairwise (fun a b => closer a b = false) := by
    intro l
    induction l with
    | nil => intro acc h; exact h
    | cons x xs ih => intro acc h; exact ih _ (insertRev_sorted x acc h)
  exact this l [] List.Pairwise.nil

def searchAll (srch : Nat → (Nat → List Nat) → List Nat → List Nat) (A : Nat → Nat → List Nat) :
    List Nat → List Nat → List (Nat × List Nat)
  | [], _ => []
  | l :: ls, e => (l, srch l (A l) e) :: searchAll srch A ls (srch l (A l) e)

def linkInterleaved (srch : Nat → (Nat → List Nat) → List Nat → List Nat)
    (lnk : Nat → (Nat → Nat → List Nat) → List Nat → (Nat → Nat → List Nat)) :
    (Nat → Nat → List Nat) → List Nat → List Nat → (Nat → Nat → List Nat)
  | A, [], _ => A
  | A, l :: ls, e => linkInterleaved srch lnk (lnk l A (srch l (A l) e)) ls (srch l (A l) e)

def linkSearchFirst (srch : Nat → (Nat → List Nat) → List Nat → List Nat)
    (lnk : Nat → (Nat → Nat → List Nat) → List Nat → (Nat → Nat → List Nat))
    (A : Nat → Nat → List Nat) (layers e0 : List Nat) : Nat → Nat → List Nat :=
  (searchAll srch A layers e0).foldl (fun A' p => lnk p.1 A' p.2) A

theorem searchAll_congr (srch : Nat → (Nat → List Nat) → List Nat → List Nat) :
    ∀ (ls : List Nat) (A B : Nat → Nat → List Nat) (e : List Nat), (∀ l ∈ ls, A l = B l) →
      searchAll srch A ls e = searchAll srch B ls e := by
  intro ls
  induction ls with
  | nil => intro A B e _; rfl
  | cons l ls ih =>
    intro A B e h
    simp only [searchAll]
    rw [h l (by simp), ih A B _ (fun l' hl' => h l' (by simp [hl']))]

theorem insert_search_first (srch : Nat → (Nat → List Nat) → List Nat → List Nat)
    (lnk : Nat → (Nat → Nat → List Nat) → List Nat → (Nat → Nat → List Nat))
    (hloc : ∀ l A r k, k ≠ l → lnk l A r k = A k) :
    ∀ (layers : List Nat) (A : Nat → Nat → List Nat) (e0 : List Nat), layers.Nodup →
      linkInterleaved srch lnk A layers e0 = linkSearchFirst srch lnk A layers e0 := by
  intro layers
  induction layers with
  | nil => intro A e0 _; rfl
  | cons l ls ih =>
    intro A e0 hnd
    have hn := List.nodup_cons.mp hnd
    simp only [linkInterleaved, linkSearchFirst, searchAll, List.foldl_cons]
    rw [ih _ _ hn.2]
    unfold linkSearchFirst
    rw [searchAll_congr srch ls (lnk l A (srch l (A l) e0)) A _
      (fun l' hl' => hloc l A _ l' (fun e => hn.1 (e ▸ hl')))]

end Vectors
