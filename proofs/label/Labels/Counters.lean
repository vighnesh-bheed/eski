import Labels.Visibility
import Labels.Intern

namespace Labels

structure Ctr where
  counts : List Nat
  total : Nat
deriving DecidableEq, Repr

inductive CErr
  | invalid
  | overflow
  | underflow
deriving DecidableEq, Repr

def u64Max : Nat := 2 ^ 64 - 1

def ctrInit : Ctr := ⟨[], 0⟩

def ctrGet (c : Ctr) (id : Nat) : Nat := c.counts.getD id 0

def ctrAdd (c : Ctr) (id delta : Nat) : Except CErr Ctr :=
  if id = idNone then .error .invalid
  else if u64Max - c.total < delta then .error .overflow
  else
    let counts := c.counts ++ List.replicate (id + 1 - c.counts.length) 0
    .ok ⟨counts.modify id (· + delta), c.total + delta⟩

def ctrSub (c : Ctr) (id delta : Nat) : Except CErr Ctr :=
  if id = idNone then .error .invalid
  else if c.counts.length ≤ id then (if delta = 0 then .ok c else .error .underflow)
  else if c.counts.getD id 0 < delta then .error .underflow
  else .ok ⟨c.counts.modify id (· - delta), c.total - delta⟩

def sumBelow (f : Nat → Nat) : Nat → Nat
  | 0 => 0
  | n + 1 => sumBelow f n + f n

def visibleTotal (c : Ctr) (v : Vis) : Nat :=
  sumBelow (fun i => if visible v i then c.counts.getD i 0 else 0) (min c.counts.length v.built)

def dominatedSum (reader : Label) (t : List Label) (c : Ctr) : Nat :=
  sumBelow (fun i => if dom reader (t.getD i bottom) then ctrGet c i else 0) t.length

def CtrOk (c : Ctr) : Prop := c.total = sumBelow (ctrGet c) c.counts.length ∧ c.total ≤ u64Max

theorem sumBelow_congr {f g : Nat → Nat} {n : Nat} (h : ∀ i, i < n → f i = g i) : sumBelow f n = sumBelow g n := by
  induction n with
  | zero => rfl
  | succ n ih =>
    simp only [sumBelow]
    rw [ih (fun i hi => h i (by omega)), h n (by omega)]

theorem sumBelow_le {f g : Nat → Nat} {n : Nat} (h : ∀ i, i < n → f i ≤ g i) : sumBelow f n ≤ sumBelow g n := by
  induction n with
  | zero => exact Nat.le_refl _
  | succ n ih =>
    simp only [sumBelow]
    exact Nat.add_le_add (ih (fun i hi => h i (by omega))) (h n (by omega))

theorem sumBelow_zero_tail {f : Nat → Nat} {n m : Nat} (hm : n ≤ m) (h : ∀ i, n ≤ i → f i = 0) :
    sumBelow f m = sumBelow f n := by
  induction m with
  | zero => rw [Nat.le_zero.1 hm]
  | succ m ih =>
    rcases Nat.lt_or_ge n (m + 1) with hlt | hge
    · simp only [sumBelow]
      rw [ih (by omega), h m (by omega), Nat.add_zero]
    · rw [Nat.le_antisymm hm hge]

theorem sumBelow_update {f g : Nat → Nat} {n id : Nat} (hid : id < n) (h : ∀ j, j ≠ id → g j = f j) :
    sumBelow g n + f id = sumBelow f n + g id := by
  induction n with
  | zero => omega
  | succ n ih =>
    simp only [sumBelow]
    rcases Nat.lt_or_ge id n with hlt | hge
    · have := ih hlt
      rw [h n (by omega)]
      omega
    · have hid' : id = n := by omega
      subst hid'
      rw [sumBelow_congr (fun i hi => h i (by omega))]
      omega

theorem getD_modify_self (l : List Nat) (id : Nat) (g : Nat → Nat) (h : id < l.length) :
    (l.modify id g).getD id 0 = g (l.getD id 0) := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h]

theorem getD_modify_other (l : List Nat) (id j : Nat) (g : Nat → Nat) (h : j ≠ id) :
    (l.modify id g).getD j 0 = l.getD j 0 := by
  simp [List.getD_eq_getElem?_getD, Ne.symm h]

theorem getD_beyond (l : List Nat) (j : Nat) (h : l.length ≤ j) : l.getD j 0 = 0 := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_eq_none h]

theorem init_ctr_ok : CtrOk ctrInit := ⟨rfl, by decide⟩

theorem add_spec {c c' : Ctr} {id delta : Nat} (h : CtrOk c) (hr : ctrAdd c id delta = .ok c') :
    CtrOk c' ∧ ctrGet c' id = ctrGet c id + delta ∧ ∀ j, j ≠ id → ctrGet c' j = ctrGet c j := by
  unfold ctrAdd at hr
  split at hr
  · simp at hr
  · split at hr
    · simp at hr
    · rename_i hid hov
      simp only [Except.ok.injEq] at hr
      subst hr
      have hlen : id < (c.counts ++ List.replicate (id + 1 - c.counts.length) 0).length := by
        simp only [List.length_append, List.length_replicate]; omega
      have hget : ∀ j, (c.counts ++ List.replicate (id + 1 - c.counts.length) 0).getD j 0 = c.counts.getD j 0 :=
        fun j => getD_append_zeros _ _ _
      have hself : ctrGet ⟨(c.counts ++ List.replicate (id + 1 - c.counts.length) 0).modify id (· + delta), c.total + delta⟩ id
          = ctrGet c id + delta := by
        unfold ctrGet; simp only; rw [getD_modify_self _ _ _ hlen, hget]
      have hother : ∀ j, j ≠ id → ctrGet ⟨(c.counts ++ List.replicate (id + 1 - c.counts.length) 0).modify id (· + delta), c.total + delta⟩ j
          = ctrGet c j := by
        intro j hj; unfold ctrGet; simp only; rw [getD_modify_other _ _ _ _ hj, hget]
      have hcap := h.2
      refine ⟨⟨?_, by show c.total + delta ≤ u64Max; unfold u64Max at *; omega⟩, hself, hother⟩
      simp only [List.length_modify]
      have hsum := sumBelow_update (f := ctrGet c) (n := (c.counts ++ List.replicate (id + 1 - c.counts.length) 0).length)
        hlen (fun j hj => hother j hj)
      rw [hself] at hsum
      have htail : sumBelow (ctrGet c) (c.counts ++ List.replicate (id + 1 - c.counts.length) 0).length =
          sumBelow (ctrGet c) c.counts.length :=
        sumBelow_zero_tail (by simp) (fun i hi => getD_beyond _ _ hi)
      rw [htail, ← h.1] at hsum
      omega

theorem sub_spec {c c' : Ctr} {id delta : Nat} (h : CtrOk c) (hr : ctrSub c id delta = .ok c') :
    CtrOk c' ∧ ctrGet c' id + delta = ctrGet c id ∧ ∀ j, j ≠ id → ctrGet c' j = ctrGet c j := by
  unfold ctrSub at hr
  split at hr
  · simp at hr
  · split at hr
    · rename_i _ hlen
      split at hr
      · rename_i hd
        simp only [Except.ok.injEq] at hr
        subst hr hd
        exact ⟨h, rfl, fun _ _ => rfl⟩
      · simp at hr
    · split at hr
      · simp at hr
      · rename_i _ hlen hge
        simp only [Except.ok.injEq] at hr
        subst hr
        have hl : id < c.counts.length := by omega
        have hself : ctrGet ⟨c.counts.modify id (· - delta), c.total - delta⟩ id + delta = ctrGet c id := by
          unfold ctrGet; simp only; rw [getD_modify_self _ _ _ hl]; omega
        have hother : ∀ j, j ≠ id → ctrGet ⟨c.counts.modify id (· - delta), c.total - delta⟩ j = ctrGet c j := by
          intro j hj; unfold ctrGet; simp only; rw [getD_modify_other _ _ _ _ hj]
        have hcap := h.2
        refine ⟨⟨?_, by show c.total - delta ≤ u64Max; unfold u64Max at *; omega⟩, hself, hother⟩
        simp only [List.length_modify]
        have hsum := sumBelow_update (f := ctrGet c) (n := c.counts.length) hl (fun j hj => hother j hj)
        rw [← h.1] at hsum
        have : ctrGet c id ≤ c.total := by
          rw [h.1]
          have := sumBelow_update (f := ctrGet c) (g := fun j => if j = id then 0 else ctrGet c j) (n := c.counts.length) hl
            (fun j hj => by simp [hj])
          simp at this
          omega
        omega

theorem add_overflow {c : Ctr} {id delta : Nat} (h : CtrOk c) (hid : id ≠ idNone) :
    ctrAdd c id delta = .error .overflow ↔ u64Max < c.total + delta := by
  unfold ctrAdd
  simp only [hid, ↓reduceIte]
  have := h.2
  split
  · simp only [true_iff]; omega
  · simp only [reduceCtorEq, false_iff]; omega

theorem sumBelow_mono {f : Nat → Nat} {n m : Nat} (h : n ≤ m) : sumBelow f n ≤ sumBelow f m := by
  induction m with
  | zero => rw [Nat.le_zero.1 h]; exact Nat.le_refl _
  | succ m ih =>
    rcases Nat.lt_or_ge n (m + 1) with hlt | hge
    · simp only [sumBelow]; have := ih (by omega); omega
    · rw [Nat.le_antisymm h hge]; exact Nat.le_refl _

theorem visibleTotal_le {c : Ctr} (h : CtrOk c) (v : Vis) : visibleTotal c v ≤ c.total := by
  unfold visibleTotal
  rw [h.1]
  calc sumBelow (fun i => if visible v i then c.counts.getD i 0 else 0) (min c.counts.length v.built)
      ≤ sumBelow (ctrGet c) (min c.counts.length v.built) :=
        sumBelow_le (fun i _ => by unfold ctrGet; split <;> omega)
    _ ≤ sumBelow (ctrGet c) c.counts.length := sumBelow_mono (Nat.min_le_left _ _)

theorem build_reader (reader : Label) (t : List Label) : (build reader t).reader = reader := by
  unfold build; rw [refresh_reader]

theorem visibleTotal_spec {t : List Label} {v : Vis} {c : Ctr} (hv : VisOk t v) (hl : c.counts.length ≤ t.length) :
    visibleTotal c v = dominatedSum v.reader t c := by
  unfold visibleTotal dominatedSum
  rw [hv.1, Nat.min_eq_left hl]
  rw [sumBelow_zero_tail (n := c.counts.length) hl (fun i hi => by
    unfold ctrGet; rw [getD_beyond _ _ hi]; split <;> rfl)]
  apply sumBelow_congr
  intro i hi
  rw [visible_spec hv]
  have : i < t.length := by omega
  simp only [decide_eq_true this, Bool.true_and, ctrGet]

theorem visibleTotal_build {t : List Label} {c : Ctr} (reader : Label) (hl : c.counts.length ≤ t.length) :
    visibleTotal c (build reader t) = dominatedSum reader t c := by
  rw [visibleTotal_spec (build_ok reader t) hl, build_reader]

theorem visibleTotal_noninterference {t : List Label} {v : Vis} {c c' : Ctr} (hv : VisOk t v)
    (hl : c.counts.length ≤ t.length) (hl' : c'.counts.length ≤ t.length)
    (hagree : ∀ i, i < t.length → dom v.reader (t.getD i bottom) = true → ctrGet c i = ctrGet c' i) :
    visibleTotal c v = visibleTotal c' v := by
  rw [visibleTotal_spec hv hl, visibleTotal_spec hv hl']
  unfold dominatedSum
  apply sumBelow_congr
  intro i hi
  split
  · rename_i hd; exact hagree i hi hd
  · rfl

theorem visibleTotal_mono {t : List Label} {c : Ctr} {r1 r2 : Label} (hr : dom r1 r2 = true)
    (hl : c.counts.length ≤ t.length) : visibleTotal c (build r2 t) ≤ visibleTotal c (build r1 t) := by
  rw [visibleTotal_build r1 hl, visibleTotal_build r2 hl]
  unfold dominatedSum
  apply sumBelow_le
  intro i _
  cases h2 : dom r2 (t.getD i bottom)
  · simp only [Bool.false_eq_true, ↓reduceIte]; exact Nat.zero_le _
  · rw [dom_trans hr h2]; simp

theorem visibleTotal_top {t : List Label} {c : Ctr} {reader : Label} (h : CtrOk c) (hl : c.counts.length ≤ t.length)
    (hall : ∀ i, i < t.length → dom reader (t.getD i bottom) = true) : visibleTotal c (build reader t) = c.total := by
  rw [visibleTotal_build reader hl, h.1]
  unfold dominatedSum
  rw [← sumBelow_zero_tail (f := ctrGet c) (n := c.counts.length) hl (fun i hi => getD_beyond _ _ hi)]
  apply sumBelow_congr
  intro i hi
  rw [hall i hi]
  rfl

theorem visibleTotal_fits {c : Ctr} (h : CtrOk c) (v : Vis) : visibleTotal c v ≤ u64Max :=
  Nat.le_trans (visibleTotal_le h v) h.2

end Labels
