import Postings.Svbyte

namespace Postings

def u32Max : Nat := 4294967295

def u64Max : Nat := 18446744073709551615

def idNone : Nat := 65535

inductive SErr where
  | ok
  | overflow
  | underflow
  | invalid
deriving DecidableEq, Repr

structure Ctr where
  counts : List Nat
  total : Nat
deriving Repr

def ctrGet (c : Ctr) (i : Nat) : Nat := c.counts.getD i 0

def ctrAdd (c : Ctr) (id delta : Nat) : Ctr × SErr :=
  if id = idNone then (c, .invalid)
  else if u64Max - c.total < delta then (c, .overflow)
  else (⟨(c.counts ++ List.replicate (id + 1 - c.counts.length) 0).modify id (· + delta), c.total + delta⟩, .ok)

def ctrSub (c : Ctr) (id delta : Nat) : Ctr × SErr :=
  if id = idNone then (c, .invalid)
  else if c.counts.length ≤ id then (c, if delta = 0 then .ok else .underflow)
  else if c.counts.getD id 0 < delta then (c, .underflow)
  else (⟨c.counts.modify id (· - delta), c.total - delta⟩, .ok)

def ctrVisible (c : Ctr) (vis : Nat → Bool) : Nat := sumBelow (fun i => if vis i then ctrGet c i else 0) c.counts.length

abbrev Pairs := List (Nat × Nat)

def tCount : Pairs → Nat → Nat
  | [], _ => 0
  | (l, c) :: rest, id => if l = id then c else tCount rest id

def tSet : Pairs → Nat → Nat → Pairs
  | [], _, _ => []
  | (l, c) :: rest, id, v => if l = id then (l, v) :: rest else (l, c) :: tSet rest id v

def tErase : Pairs → Nat → Pairs
  | [], _ => []
  | (l, c) :: rest, id => if l = id then rest else (l, c) :: tErase rest id

def tHas : Pairs → Nat → Bool
  | [], _ => false
  | (l, _) :: rest, id => l = id || tHas rest id

def termAddP (t : Pairs) (id delta : Nat) : Pairs × SErr :=
  if id = idNone then (t, .invalid)
  else if tHas t id then
    (if u32Max - tCount t id < delta then (t, .overflow) else (tSet t id (tCount t id + delta), .ok))
  else (t ++ [(id, delta)], .ok)

def termRemoveP (t : Pairs) (id delta : Nat) : Pairs × SErr :=
  if tHas t id then
    (if tCount t id < delta then (t, .underflow)
     else if tCount t id - delta = 0 then (tErase t id, .ok) else (tSet t id (tCount t id - delta), .ok))
  else (t, if delta = 0 then .ok else .underflow)

def termTotalP (t : Pairs) : Nat := (t.map Prod.snd).sum

def termVisibleP (t : Pairs) (vis : Nat → Bool) : Nat := (t.map fun p => if vis p.1 then p.2 else 0).sum

structure Stats where
  docs : Ctr
  lens : Ctr
  terms : List Pairs
deriving Repr

def statsInit : Stats := ⟨⟨[], 0⟩, ⟨[], 0⟩, []⟩

def documentAdd (s : Stats) (id len : Nat) : Stats × SErr :=
  if (ctrAdd s.docs id 1).2 ≠ .ok then (s, (ctrAdd s.docs id 1).2)
  else if (ctrAdd s.lens id len).2 ≠ .ok then (s, (ctrAdd s.lens id len).2)
  else ({ s with docs := (ctrAdd s.docs id 1).1, lens := (ctrAdd s.lens id len).1 }, .ok)

def documentRemove (s : Stats) (id len : Nat) : Stats × SErr :=
  if ctrGet s.docs id = 0 ∨ ctrGet s.lens id < len then (s, .underflow)
  else if (ctrSub s.docs id 1).2 ≠ .ok then ({ s with docs := (ctrSub s.docs id 1).1 }, (ctrSub s.docs id 1).2)
  else ({ s with docs := (ctrSub s.docs id 1).1, lens := (ctrSub s.lens id len).1 }, (ctrSub s.lens id len).2)

def termOf (s : Stats) (term : Nat) : Pairs := s.terms.getD term []

def setTerm (s : Stats) (term : Nat) (t : Pairs) : Stats :=
  { s with terms := (s.terms ++ List.replicate (term + 1 - s.terms.length) []).set term t }

def termAdd (s : Stats) (term id delta : Nat) : Stats × SErr :=
  if id = idNone then (s, .invalid)
  else
    match termAddP (termOf s term) id delta with
    | (t, .ok) => (setTerm s term t, .ok)
    | (_, e) => (s, e)

def termRemove (s : Stats) (term id delta : Nat) : Stats × SErr :=
  match termRemoveP (termOf s term) id delta with
  | (t, .ok) => (if term < s.terms.length then setTerm s term t else s, .ok)
  | (_, e) => (s, e)

def termForget (s : Stats) (term : Nat) : Stats := if term < s.terms.length then setTerm s term [] else s

def termVisible (s : Stats) (term : Nat) (vis : Nat → Bool) : Nat := termVisibleP (termOf s term) vis

def termCount (s : Stats) (term id : Nat) : Nat := tCount (termOf s term) id

def visibleTotals (s : Stats) (vis : Nat → Bool) : Nat × Nat := (ctrVisible s.docs vis, ctrVisible s.lens vis)

theorem tCount_tSet (t : Pairs) (id v x : Nat) : tCount (tSet t id v) x = if x = id ∧ tHas t id then v else tCount t x := by
  induction t with
  | nil => simp [tSet, tCount, tHas]
  | cons p rest ih =>
    obtain ⟨l, c⟩ := p
    simp only [tSet, tHas]
    by_cases h : l = id
    · subst h; simp [tCount]; by_cases e : l = x <;> simp [e]; omega
    · simp only [h, ↓reduceIte, tCount, Bool.false_or, decide_false]
      rw [ih]
      by_cases e : l = x
      · subst e; simp [h, Ne.symm h]
      · simp [e]

theorem tHas_iff (t : Pairs) (id : Nat) : tHas t id = true ↔ ∃ c, (id, c) ∈ t := by
  induction t with
  | nil => simp [tHas]
  | cons p rest ih =>
    obtain ⟨l, c⟩ := p
    simp only [tHas, Bool.or_eq_true, decide_eq_true_eq, ih, List.mem_cons, Prod.mk.injEq]
    constructor
    · rintro (h | ⟨c', h⟩)
      · exact ⟨c, Or.inl ⟨h.symm, rfl⟩⟩
      · exact ⟨c', Or.inr h⟩
    · rintro ⟨c', h | h⟩
      · exact Or.inl h.1.symm
      · exact Or.inr ⟨c', h⟩

theorem tCount_absent (t : Pairs) (id : Nat) (h : tHas t id = false) : tCount t id = 0 := by
  induction t with
  | nil => rfl
  | cons p rest ih =>
    obtain ⟨l, c⟩ := p
    simp only [tHas, Bool.or_eq_false_iff, decide_eq_false_iff_not] at h
    simp [tCount, h.1, ih h.2]

def LabelsOk (t : Pairs) : Prop := (t.map Prod.fst).Nodup ∧ ∀ p ∈ t, p.1 ≠ idNone

theorem tCount_append (t : Pairs) (id delta x : Nat) (h : tHas t id = false) :
    tCount (t ++ [(id, delta)]) x = if x = id then delta else tCount t x := by
  induction t with
  | nil => simp [tCount]; by_cases e : id = x <;> simp [e]; intro h'; exact absurd h'.symm e
  | cons p rest ih =>
    obtain ⟨l, c⟩ := p
    simp only [tHas, Bool.or_eq_false_iff, decide_eq_false_iff_not] at h
    simp only [List.cons_append, tCount]
    rw [ih h.2]
    by_cases e : l = x
    · subst e; simp [h.1]
    · simp [e]

theorem tCount_tErase (t : Pairs) (hl : (t.map Prod.fst).Nodup) (id x : Nat) :
    tCount (tErase t id) x = if x = id then 0 else tCount t x := by
  induction t with
  | nil => simp [tErase, tCount]
  | cons p rest ih =>
    obtain ⟨l, c⟩ := p
    simp only [List.map_cons, List.nodup_cons] at hl
    simp only [tErase]
    by_cases h : l = id
    · subst h
      simp only [↓reduceIte, tCount]
      by_cases e : x = l
      · subst e
        simp only [↓reduceIte]
        apply tCount_absent
        cases hh : tHas rest x with
        | false => rfl
        | true =>
          obtain ⟨c', hc'⟩ := (tHas_iff rest x).1 hh
          exact absurd (List.mem_map_of_mem (f := Prod.fst) hc') hl.1
      · simp [e, Ne.symm e]
    · simp only [h, ↓reduceIte, tCount]
      rw [ih hl.2]
      by_cases e : l = x
      · subst e; simp [Ne.symm h, h]
      · simp [e]

theorem termAddP_count (t : Pairs) (id delta x : Nat) (h : (termAddP t id delta).2 = .ok) :
    tCount (termAddP t id delta).1 x = if x = id then tCount t id + delta else tCount t x := by
  unfold termAddP at h ⊢
  by_cases h1 : id = idNone
  · simp [h1] at h
  · simp only [h1, ↓reduceIte] at h ⊢
    by_cases hh : tHas t id = true
    · simp only [hh, ↓reduceIte] at h ⊢
      by_cases ho : u32Max - tCount t id < delta
      · simp [ho] at h
      · simp only [ho, ↓reduceIte]; rw [tCount_tSet]; simp [hh]
    · have hh' : tHas t id = false := by simpa using hh
      simp only [hh', Bool.false_eq_true, ↓reduceIte]
      rw [tCount_append t id delta x hh', tCount_absent t id hh', Nat.zero_add]

theorem termAddP_err (t : Pairs) (id delta : Nat) (h : (termAddP t id delta).2 ≠ .ok) : (termAddP t id delta).1 = t := by
  unfold termAddP at h ⊢
  by_cases h1 : id = idNone
  · simp [h1]
  · simp only [h1, ↓reduceIte] at h ⊢
    by_cases hh : tHas t id = true
    · simp only [hh, ↓reduceIte] at h ⊢
      by_cases ho : u32Max - tCount t id < delta
      · simp [ho]
      · simp [ho] at h
    · have hh' : tHas t id = false := by simpa using hh
      simp [hh'] at h

theorem termRemoveP_count (t : Pairs) (hl : (t.map Prod.fst).Nodup) (id delta x : Nat) (h : (termRemoveP t id delta).2 = .ok) :
    tCount (termRemoveP t id delta).1 x = if x = id then tCount t id - delta else tCount t x := by
  unfold termRemoveP at h ⊢
  by_cases hh : tHas t id = true
  · simp only [hh, ↓reduceIte] at h ⊢
    by_cases hu : tCount t id < delta
    · simp [hu] at h
    · simp only [hu, ↓reduceIte]
      by_cases hz : tCount t id - delta = 0
      · simp only [hz, ↓reduceIte]
        rw [tCount_tErase t hl]
      · simp only [hz, ↓reduceIte]
        rw [tCount_tSet]; simp [hh]
  · have hh' : tHas t id = false := by simpa using hh
    simp only [hh', Bool.false_eq_true, ↓reduceIte] at h ⊢
    by_cases e : x = id
    · subst e; simp [tCount_absent t x hh']
    · simp [e]

theorem termRemoveP_err (t : Pairs) (id delta : Nat) (h : (termRemoveP t id delta).2 ≠ .ok) : (termRemoveP t id delta).1 = t := by
  unfold termRemoveP at h ⊢
  by_cases hh : tHas t id = true
  · simp only [hh, ↓reduceIte] at h ⊢
    by_cases hu : tCount t id < delta
    · simp [hu]
    · simp only [hu, ↓reduceIte] at h
      by_cases hz : tCount t id - delta = 0 <;> simp [hz] at h
  · have hh' : tHas t id = false := by simpa using hh
    simp [hh']

theorem termVisibleP_univ (vis : Nat → Bool) (U : List Nat) (hU : U.Nodup) :
    ∀ t : Pairs, (t.map Prod.fst).Nodup → (∀ p ∈ t, p.1 ∈ U) →
      termVisibleP t vis = (U.map fun l => if vis l then tCount t l else 0).sum := by
  intro t
  induction t with
  | nil =>
    intro _ _
    simp only [termVisibleP, List.map_nil, List.sum_nil]
    symm
    induction U with
    | nil => rfl
    | cons u us ih =>
      rw [List.map_cons, List.sum_cons, ih (List.nodup_cons.1 hU).2 (by simp)]
      simp [tCount]
  | cons p rest ih =>
    intro hn hin
    obtain ⟨l0, c0⟩ := p
    simp only [List.map_cons, List.nodup_cons] at hn
    have ihr := ih hn.2 (fun q hq => hin q (by simp [hq]))
    simp only [termVisibleP, List.map_cons, List.sum_cons] at ihr ⊢
    rw [ihr]
    have hl0 : l0 ∈ U := hin (l0, c0) (by simp)
    have habs : tCount rest l0 = 0 := by
      apply tCount_absent
      cases hh : tHas rest l0 with
      | false => rfl
      | true => obtain ⟨c', hc'⟩ := (tHas_iff rest l0).1 hh; exact absurd (List.mem_map_of_mem (f := Prod.fst) hc') hn.1
    have key : ∀ (V : List Nat), V.Nodup → (U.Nodup → True) →
        (V.map fun l => if vis l then tCount ((l0, c0) :: rest) l else 0).sum =
          (if l0 ∈ V ∧ vis l0 then c0 else 0) + (V.map fun l => if vis l then tCount rest l else 0).sum := by
      intro V hV _
      induction V with
      | nil => simp
      | cons v vs ihv =>
        have hV' := List.nodup_cons.1 hV
        rw [List.map_cons, List.sum_cons, List.map_cons, List.sum_cons, ihv hV'.2]
        by_cases e : l0 = v
        · subst e
          have hnv : l0 ∉ vs := hV'.1
          simp only [tCount, ↓reduceIte, List.mem_cons, true_or, true_and, habs, hnv, false_and]
          cases vis l0 <;> simp
        · have e' : ¬ (l0 = v ∨ l0 ∈ vs) ↔ ¬ l0 ∈ vs := by simp [e]
          simp only [tCount, e, ↓reduceIte, List.mem_cons]
          by_cases hm : l0 ∈ vs <;> simp [hm, e] <;> omega
    rw [key U hU (fun _ => trivial)]
    simp [hl0]

def labelUniv : List Nat := List.range 65536

def LabelsIn (t : Pairs) : Prop := (t.map Prod.fst).Nodup ∧ ∀ p ∈ t, p.1 < 65536

theorem termVisible_spec (vis : Nat → Bool) (t : Pairs) (h : LabelsIn t) :
    termVisibleP t vis = (labelUniv.map fun l => if vis l then tCount t l else 0).sum :=
  termVisibleP_univ vis labelUniv List.nodup_range t h.1 (fun p hp => List.mem_range.2 (h.2 p hp))

theorem sum_map_congr {U : List Nat} {f g : Nat → Nat} (h : ∀ l ∈ U, f l = g l) : (U.map f).sum = (U.map g).sum := by
  rw [List.map_congr_left h]

theorem visible_noninterference (vis : Nat → Bool) (t1 t2 : Pairs) (h1 : LabelsIn t1) (h2 : LabelsIn t2)
    (hagree : ∀ l, vis l = true → tCount t1 l = tCount t2 l) : termVisibleP t1 vis = termVisibleP t2 vis := by
  rw [termVisible_spec vis t1 h1, termVisible_spec vis t2 h2]
  apply sum_map_congr
  intro l _
  cases hv : vis l
  · rfl
  · simp [hagree l hv]

theorem tHas_tSet (t : Pairs) (id v x : Nat) : tHas (tSet t id v) x = tHas t x := by
  induction t with
  | nil => rfl
  | cons p rest ih =>
    obtain ⟨l, c⟩ := p
    simp only [tSet]
    split <;> simp [tHas, ih]

theorem map_fst_tSet (t : Pairs) (id v : Nat) : (tSet t id v).map Prod.fst = t.map Prod.fst := by
  induction t with
  | nil => rfl
  | cons p rest ih =>
    obtain ⟨l, c⟩ := p
    simp only [tSet]
    split <;> simp [ih]

theorem map_fst_tErase_sub (t : Pairs) (id : Nat) : ((tErase t id).map Prod.fst).Sublist (t.map Prod.fst) := by
  induction t with
  | nil => simp [tErase]
  | cons p rest ih =>
    obtain ⟨l, c⟩ := p
    simp only [tErase]
    split
    · exact List.Sublist.cons _ (List.Sublist.refl _)
    · exact List.Sublist.cons_cons _ ih

theorem termAddP_labels (t : Pairs) (h : LabelsIn t) (id delta : Nat) (hid : id < 65536) : LabelsIn (termAddP t id delta).1 := by
  unfold termAddP
  split
  · exact h
  · split
    · split
      · exact h
      · exact ⟨by rw [map_fst_tSet]; exact h.1, fun p hp => by
          have : p.1 ∈ (tSet t id (tCount t id + delta)).map Prod.fst := List.mem_map_of_mem hp
          rw [map_fst_tSet] at this
          obtain ⟨q, hq, he⟩ := List.mem_map.1 this
          rw [← he]; exact h.2 q hq⟩
    · rename_i hh
      simp only [Bool.not_eq_true] at hh
      refine ⟨?_, fun p hp => ?_⟩
      · rw [List.map_append, List.nodup_append]
        refine ⟨h.1, by simp, ?_⟩
        intro a ha b hb e
        simp at hb; subst hb; subst e
        obtain ⟨q, hq, hqe⟩ := List.mem_map.1 ha
        have : tHas t q.1 = true := (tHas_iff t q.1).2 ⟨q.2, by simpa using hq⟩
        rw [hqe, hh] at this; cases this
      · rcases List.mem_append.1 hp with e | e
        · exact h.2 p e
        · simp at e; rw [e]; exact hid

theorem termRemoveP_labels (t : Pairs) (h : LabelsIn t) (id delta : Nat) : LabelsIn (termRemoveP t id delta).1 := by
  unfold termRemoveP
  split
  · split
    · exact h
    · split
      · exact ⟨List.Nodup.sublist (map_fst_tErase_sub t id) h.1, fun p hp => by
          have : p.1 ∈ (tErase t id).map Prod.fst := List.mem_map_of_mem hp
          obtain ⟨q, hq, he⟩ := List.mem_map.1 ((map_fst_tErase_sub t id).subset this)
          rw [← he]; exact h.2 q hq⟩
      · exact ⟨by rw [map_fst_tSet]; exact h.1, fun p hp => by
          have : p.1 ∈ (tSet t id (tCount t id - delta)).map Prod.fst := List.mem_map_of_mem hp
          rw [map_fst_tSet] at this
          obtain ⟨q, hq, he⟩ := List.mem_map.1 this
          rw [← he]; exact h.2 q hq⟩
  · exact h

theorem hidden_termAdd (vis : Nat → Bool) (t : Pairs) (h : LabelsIn t) (id delta : Nat) (hid : id < 65536)
    (hv : vis id = false) : termVisibleP (termAddP t id delta).1 vis = termVisibleP t vis := by
  cases he : (termAddP t id delta).2 with
  | ok =>
    apply visible_noninterference vis _ _ (termAddP_labels t h id delta hid) h
    intro l hl
    rw [termAddP_count t id delta l he]
    have : l ≠ id := fun e => by rw [e, hv] at hl; cases hl
    simp [this]
  | _ => rw [termAddP_err t id delta (by rw [he]; simp)]

theorem hidden_termRemove (vis : Nat → Bool) (t : Pairs) (h : LabelsIn t) (id delta : Nat)
    (hv : vis id = false) : termVisibleP (termRemoveP t id delta).1 vis = termVisibleP t vis := by
  cases he : (termRemoveP t id delta).2 with
  | ok =>
    apply visible_noninterference vis _ _ (termRemoveP_labels t h id delta) h
    intro l hl
    rw [termRemoveP_count t h.1 id delta l he]
    have : l ≠ id := fun e => by rw [e, hv] at hl; cases hl
    simp [this]
  | _ => rw [termRemoveP_err t id delta (by rw [he]; simp)]

theorem getD_replicate_zero : ∀ (k i : Nat), (List.replicate k 0).getD i 0 = 0
  | 0, _ => rfl
  | k + 1, 0 => rfl
  | k + 1, i + 1 => by simp only [List.replicate_succ, List.getD_cons_succ]; exact getD_replicate_zero k i

theorem getD_append_zeros : ∀ (l : List Nat) (k i : Nat), (l ++ List.replicate k 0).getD i 0 = l.getD i 0
  | [], k, i => by rw [List.nil_append, getD_replicate_zero]; rfl
  | x :: xs, k, 0 => rfl
  | x :: xs, k, i + 1 => by simp only [List.cons_append, List.getD_cons_succ]; exact getD_append_zeros xs k i

theorem getD_modify : ∀ (l : List Nat) (f : Nat → Nat) (id i : Nat),
    (l.modify id f).getD i 0 = if i = id ∧ id < l.length then f (l.getD i 0) else l.getD i 0
  | [], f, id, i => by simp [List.modify_nil]
  | x :: xs, f, 0, 0 => by simp [List.modify_zero_cons]
  | x :: xs, f, 0, i + 1 => by simp [List.modify_zero_cons]
  | x :: xs, f, id + 1, 0 => by simp [List.modify_succ_cons]
  | x :: xs, f, id + 1, i + 1 => by
    rw [List.modify_succ_cons, List.getD_cons_succ, getD_modify xs f id i, List.getD_cons_succ]
    simp

theorem sumBelow_ext {f g : Nat → Nat} {n : Nat} (h : ∀ i, i < n → f i = g i) : sumBelow f n = sumBelow g n := by
  induction n with
  | zero => rfl
  | succ n ih => simp only [sumBelow]; rw [ih (fun i hi => h i (by omega)), h n (by omega)]

theorem sumBelow_tail {f : Nat → Nat} {n : Nat} (h : ∀ i, n ≤ i → f i = 0) : ∀ k, sumBelow f (n + k) = sumBelow f n
  | 0 => rfl
  | k + 1 => by rw [← Nat.add_assoc]; simp only [sumBelow]; rw [sumBelow_tail h k, h (n + k) (by omega)]; rfl

theorem ctrVisible_univ (c : Ctr) (vis : Nat → Bool) (N : Nat) (hN : c.counts.length ≤ N) :
    ctrVisible c vis = sumBelow (fun i => if vis i then ctrGet c i else 0) N := by
  unfold ctrVisible
  have := sumBelow_tail (f := fun i => if vis i then ctrGet c i else 0) (n := c.counts.length) (fun i hi => by
    simp only [ctrGet, List.getD_eq_getElem?_getD, List.getElem?_eq_none hi, Option.getD_none, ite_self]) (N - c.counts.length)
  rw [Nat.add_sub_cancel' hN] at this
  exact this.symm

theorem hidden_ctrAdd (vis : Nat → Bool) (c : Ctr) (id delta : Nat) (hv : vis id = false) :
    ctrVisible (ctrAdd c id delta).1 vis = ctrVisible c vis := by
  unfold ctrAdd
  split
  · rfl
  · split
    · rfl
    · simp only
      have hlen : ((c.counts ++ List.replicate (id + 1 - c.counts.length) 0).modify id (· + delta)).length =
          c.counts.length + (id + 1 - c.counts.length) := by simp
      have e1 := ctrVisible_univ ⟨(c.counts ++ List.replicate (id + 1 - c.counts.length) 0).modify id (fun x => x + delta),
        c.total + delta⟩ vis (c.counts.length + (id + 1 - c.counts.length)) (Nat.le_of_eq hlen)
      rw [e1, ctrVisible_univ c vis (c.counts.length + (id + 1 - c.counts.length)) (by omega)]
      apply sumBelow_ext
      intro i _
      simp only [ctrGet, getD_modify, getD_append_zeros]
      by_cases e : i = id
      · subst e; simp [hv]
      · simp [e]

theorem hidden_ctrSub (vis : Nat → Bool) (c : Ctr) (id delta : Nat) (hv : vis id = false) :
    ctrVisible (ctrSub c id delta).1 vis = ctrVisible c vis := by
  unfold ctrSub
  split
  · rfl
  · split
    · rfl
    · split
      · rfl
      · simp only
        rw [ctrVisible_univ ⟨_, _⟩ vis c.counts.length (by simp), ctrVisible_univ c vis c.counts.length (Nat.le_refl _)]
        apply sumBelow_ext
        intro i _
        simp only [ctrGet, getD_modify]
        by_cases e : i = id
        · subst e; simp [hv]
        · simp [e]

theorem hidden_documentAdd (vis : Nat → Bool) (s : Stats) (id len : Nat) (hv : vis id = false) :
    visibleTotals (documentAdd s id len).1 vis = visibleTotals s vis := by
  have h1 := hidden_ctrAdd vis s.docs id 1 hv
  have h2 := hidden_ctrAdd vis s.lens id len hv
  unfold documentAdd visibleTotals
  split
  · rfl
  · split
    · rfl
    · simp only [h1, h2]

theorem hidden_documentRemove (vis : Nat → Bool) (s : Stats) (id len : Nat) (hv : vis id = false) :
    visibleTotals (documentRemove s id len).1 vis = visibleTotals s vis := by
  have h1 := hidden_ctrSub vis s.docs id 1 hv
  have h2 := hidden_ctrSub vis s.lens id len hv
  unfold documentRemove visibleTotals
  split
  · rfl
  · split
    · simp only [h1]
    · simp only [h1, h2]

theorem termOf_setTerm (s : Stats) (term : Nat) (u : Pairs) (q : Nat) :
    termOf (setTerm s term u) q = if q = term then u else termOf s q := by
  unfold termOf setTerm
  simp only [List.getD_eq_getElem?_getD]
  by_cases e : q = term
  · subst e
    rw [List.getElem?_set_self (by simp; omega)]
    simp
  · rw [List.getElem?_set_ne (Ne.symm e)]
    simp only [e, ↓reduceIte]
    by_cases hlt : q < s.terms.length
    · rw [List.getElem?_append_left hlt]
    · rw [List.getElem?_append_right (by omega), List.getElem?_replicate, List.getElem?_eq_none (l := s.terms) (by omega)]
      split <;> rfl

theorem hidden_termOps (vis : Nat → Bool) (s : Stats) (term id delta : Nat) (hv : vis id = false) (hid : id < 65536)
    (hl : ∀ t ∈ s.terms, LabelsIn t) (q : Nat) :
    termVisible (termAdd s term id delta).1 q vis = termVisible s q vis ∧
      termVisible (termRemove s term id delta).1 q vis = termVisible s q vis := by
  have hq : ∀ (u : Pairs), LabelsIn (termOf s term) → termVisibleP u vis = termVisibleP (termOf s term) vis →
      termVisible (setTerm s term u) q vis = termVisible s q vis := by
    intro u _ hu
    unfold termVisible
    rw [termOf_setTerm]
    by_cases e : q = term
    · subst e; simp only [↓reduceIte]; exact hu
    · simp [e]
  have hlab : LabelsIn (termOf s term) := by
    unfold termOf
    rw [List.getD_eq_getElem?_getD]
    cases h : s.terms[term]? with
    | none => exact ⟨List.nodup_nil, by simp⟩
    | some t => exact hl t (List.mem_of_getElem? h)
  constructor
  · unfold termAdd
    split
    · rfl
    · split
      · rename_i t ht
        apply hq t hlab
        have := hidden_termAdd vis (termOf s term) hlab id delta hid hv
        rw [ht] at this; exact this
      · rfl
  · unfold termRemove
    split
    · rename_i t ht
      split
      · apply hq t hlab
        have := hidden_termRemove vis (termOf s term) hlab id delta hv
        rw [ht] at this; exact this
      · rfl
    · rfl

theorem hidden_overflow_interference :
    (ctrAdd ⟨[0, u64Max - 1], u64Max - 1⟩ 0 2).2 = .overflow ∧ (ctrAdd ⟨[0, 0], 0⟩ 0 2).2 = .ok := by
  refine ⟨by decide, by decide⟩

end Postings
