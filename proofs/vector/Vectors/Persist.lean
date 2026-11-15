import Vectors.Partition

namespace Vectors

structure PSlot where
  level : Nat
  prev : Nat
  lists : List (List Nat)
deriving Repr, DecidableEq, Inhabited

structure PState where
  m : Nat
  high : Nat
  uid : Nat
  entry : Nat
  top : Nat
  table : Bool
  free : List Nat
  elems : List (Nat × Nat)
  slots : List PSlot
deriving Repr, DecidableEq, Inhabited

def pFree : Nat := 255
def pTwin : Nat := 253
def pCap : Nat := 30

def listTokens (l : List Nat) : List Nat := l.length :: l

def slotTokens (s : PSlot) : List Nat :=
  if s.level = pTwin then [s.level, s.prev]
  else if s.level ≤ pCap then s.level :: s.lists.flatMap listTokens
  else [s.level]

def pairTokens (e : Nat × Nat) : List Nat := [e.1, e.2]

def encodeP (s : PState) : List Nat :=
  [s.m, s.high, s.uid, s.entry, s.top, if s.table then 1 else 0, s.free.length] ++ s.free ++
    [s.elems.length] ++ s.elems.flatMap pairTokens ++ s.slots.flatMap slotTokens

def takeN : Nat → List Nat → Option (List Nat × List Nat)
  | 0, ts => some ([], ts)
  | _ + 1, [] => none
  | n + 1, t :: ts => (takeN n ts).map (fun r => (t :: r.1, r.2))

def takePairs : Nat → List Nat → Option (List (Nat × Nat) × List Nat)
  | 0, ts => some ([], ts)
  | n + 1, a :: b :: ts => (takePairs n ts).map (fun r => ((a, b) :: r.1, r.2))
  | _ + 1, _ => none

def takeLists : Nat → List Nat → Option (List (List Nat) × List Nat)
  | 0, ts => some ([], ts)
  | _ + 1, [] => none
  | n + 1, c :: ts =>
    match takeN c ts with
    | none => none
    | some (l, r) => (takeLists n r).map (fun q => (l :: q.1, q.2))

def takeSlot : List Nat → Option (PSlot × List Nat)
  | [] => none
  | l :: ts =>
    if l = pTwin then
      match ts with
      | [] => none
      | p :: r => some (⟨l, p, []⟩, r)
    else if l ≤ pCap then (takeLists (l + 1) ts).map (fun q => (⟨l, 0, q.1⟩, q.2))
    else some (⟨l, 0, []⟩, ts)

def takeSlots : Nat → List Nat → Option (List PSlot × List Nat)
  | 0, ts => some ([], ts)
  | n + 1, ts =>
    match takeSlot ts with
    | none => none
    | some (s, r) => (takeSlots n r).map (fun q => (s :: q.1, q.2))

def parseP : List Nat → Option PState
  | m :: high :: uid :: entry :: top :: tb :: nf :: rest =>
    match takeN nf rest with
    | none => none
    | some (free, r1) =>
      match r1 with
      | [] => none
      | ne :: r2 =>
        match takePairs ne r2 with
        | none => none
        | some (elems, r3) =>
          match takeSlots high r3 with
          | none => none
          | some (slots, r4) =>
            if r4 = [] ∧ tb ≤ 1 then some ⟨m, high, uid, entry, top, tb = 1, free, elems, slots⟩ else none
  | _ => none

def slotAt (s : PState) (i : Nat) : PSlot := s.slots.getD i ⟨pFree, 0, []⟩

def levelAt (s : PState) (i : Nat) : Nat := (slotAt s i).level

def isNodeP (s : PState) (i : Nat) : Bool := decide (i < s.high) && decide (levelAt s i ≤ pCap)

def isTwinP (s : PState) (i : Nat) : Bool := decide (i < s.high) && levelAt s i == pTwin

def listAt (s : PState) (i l : Nat) : List Nat := (slotAt s i).lists.getD l []

def canonSlot (x : PSlot) : Bool :=
  (if x.level = pTwin then x.lists.isEmpty else x.prev == 0) &&
  (if x.level ≤ pCap then x.lists.length == x.level + 1 else x.lists.isEmpty)

def okShape (s : PState) : Bool :=
  decide (4 ≤ s.m) && decide (s.m ≤ 4096) && s.slots.length == s.high && !s.elems.isEmpty &&
  s.free.length + s.elems.length == s.high && decide (s.elems.length ≤ s.uid) && decide (s.uid < 2 ^ 63) &&
  s.slots.all canonSlot

def okFree (s : PState) : Bool := s.free.all (fun f => decide (f < s.high)) && decide s.free.Nodup

def okSlot (s : PState) : Bool :=
  s.elems.all (fun e => decide (e.1 < s.high) && !(s.free.contains e.1)) && decide (s.elems.map Prod.fst).Nodup

def okSeq (s : PState) : Bool :=
  s.elems.all (fun e => decide (1 ≤ e.2) && decide (e.2 ≤ s.uid)) && decide (s.elems.map Prod.snd).Nodup

def okLevel (s : PState) : Bool :=
  (List.range s.high).all (fun i =>
    let lv := levelAt s i
    (s.free.contains i == (lv == pFree)) && (decide (lv ≤ pCap) || lv == pTwin || lv == pFree))

def okDegree (s : PState) : Bool :=
  (List.range s.high).all (fun i =>
    !isNodeP s i || (List.range (levelAt s i + 1)).all (fun l =>
      decide ((listAt s i l).length ≤ if l = 0 then 2 * s.m else s.m)))

def okLink (s : PState) : Bool :=
  (List.range s.high).all (fun i =>
    !isNodeP s i || (List.range (levelAt s i + 1)).all (fun l =>
      decide (listAt s i l).Nodup && (listAt s i l).all (fun j =>
        decide (j < s.high) && j != i && isNodeP s j && decide (l ≤ levelAt s j))))

def okSym (s : PState) : Bool :=
  (List.range s.high).all (fun i =>
    !isNodeP s i || (List.range (levelAt s i + 1)).all (fun l =>
      (listAt s i l).all (fun j => (listAt s j l).contains i)))

def okEntry (s : PState) : Bool :=
  isNodeP s s.entry && levelAt s s.entry == s.top &&
  (List.range s.high).all (fun i => !isNodeP s i || decide (levelAt s i ≤ s.top))

def twinsP (s : PState) : List Nat := (List.range s.high).filter (isTwinP s)

def prevAt (s : PState) (i : Nat) : Nat := (slotAt s i).prev

def reachesNode (s : PState) : Nat → Nat → Bool
  | 0, _ => false
  | k + 1, t => isNodeP s (prevAt s t) || (isTwinP s (prevAt s t) && reachesNode s k (prevAt s t))

def okTwin (s : PState) : Bool :=
  let ts := twinsP s
  (ts.isEmpty || s.table) &&
  ts.all (fun t => decide (prevAt s t < s.high) && prevAt s t != t && (isNodeP s (prevAt s t) || isTwinP s (prevAt s t)) &&
    reachesNode s ts.length t) &&
  decide (ts.map (prevAt s)).Nodup

inductive Check where
  | shape | free | slot | seq | level | degree | link | sym | entry | twin
deriving Repr, DecidableEq, Inhabited

def Check.all : List Check := [.shape, .free, .slot, .seq, .level, .degree, .link, .sym, .entry, .twin]

def clause (s : PState) : Check → Bool
  | .shape => okShape s
  | .free => okFree s
  | .slot => okSlot s
  | .seq => okSeq s
  | .level => okLevel s
  | .degree => okDegree s
  | .link => okLink s
  | .sym => okSym s
  | .entry => okEntry s
  | .twin => okTwin s

def checkP (s : PState) : Bool := Check.all.all (clause s)

def checkWithout (k : Check) (s : PState) : Bool := (Check.all.filter (· ≠ k)).all (clause s)

def WfP (s : PState) : Prop := checkP s = true

def decodeP (t : List Nat) : Option PState :=
  match parseP t with
  | none => none
  | some s => if checkP s then some s else none

def firstFailure (s : PState) : Option Check := Check.all.find? (fun k => !clause s k)

theorem takeN_append (xs rest : List Nat) : takeN xs.length (xs ++ rest) = some (xs, rest) := by
  induction xs with
  | nil => rfl
  | cons x xs ih => simp [takeN, ih]

theorem takePairs_append (es : List (Nat × Nat)) (rest : List Nat) :
    takePairs es.length (es.flatMap pairTokens ++ rest) = some (es, rest) := by
  induction es with
  | nil => rfl
  | cons e es ih => simp [takePairs, pairTokens, ih]

theorem takeLists_append (ls : List (List Nat)) (rest : List Nat) :
    takeLists ls.length (ls.flatMap listTokens ++ rest) = some (ls, rest) := by
  induction ls with
  | nil => rfl
  | cons l ls ih =>
    simp only [List.flatMap_cons, List.length_cons, listTokens, List.cons_append, List.append_assoc, takeLists]
    rw [takeN_append]
    simp [ih]

theorem takeSlot_encode (x : PSlot) (rest : List Nat) (hc : canonSlot x = true) :
    takeSlot (slotTokens x ++ rest) = some (x, rest) := by
  obtain ⟨level, prev, lists⟩ := x
  simp only [canonSlot, Bool.and_eq_true] at hc
  obtain ⟨h1, h2⟩ := hc
  by_cases ht : level = pTwin
  · subst ht
    simp only [↓reduceIte, List.isEmpty_iff] at h1
    subst h1
    simp [slotTokens, takeSlot]
  · simp only [ht, ↓reduceIte, beq_iff_eq] at h1
    subst h1
    by_cases hl : level ≤ pCap
    · simp only [hl, ↓reduceIte, beq_iff_eq] at h2
      have := takeLists_append lists rest
      rw [h2] at this
      simp [slotTokens, takeSlot, ht, hl, this]
    · simp only [hl, ↓reduceIte, List.isEmpty_iff] at h2
      subst h2
      simp [slotTokens, takeSlot, ht, hl]

theorem takeSlots_append (xs : List PSlot) (rest : List Nat) (hc : xs.all canonSlot = true) :
    takeSlots xs.length (xs.flatMap slotTokens ++ rest) = some (xs, rest) := by
  induction xs with
  | nil => rfl
  | cons x xs ih =>
    simp only [List.all_cons, Bool.and_eq_true] at hc
    simp only [List.flatMap_cons, List.length_cons, List.append_assoc, takeSlots]
    rw [takeSlot_encode x _ hc.1]
    simp [ih hc.2]

theorem parse_encode (s : PState) (hlen : s.slots.length = s.high) (hc : s.slots.all canonSlot = true) :
    parseP (encodeP s) = some s := by
  obtain ⟨m, high, uid, entry, top, table, free, elems, slots⟩ := s
  simp only at hlen hc
  subst hlen
  simp only [encodeP, List.cons_append, List.nil_append, parseP, List.append_assoc]
  rw [takeN_append]
  dsimp only
  rw [takePairs_append]
  have := takeSlots_append slots [] hc
  rw [List.append_nil] at this
  simp only [this]
  cases table <;> simp

theorem wf_shape (s : PState) (h : WfP s) : okShape s = true := by
  unfold WfP checkP at h
  simpa [Check.all, clause] using (List.all_eq_true.mp h) .shape (by simp [Check.all])

theorem wf_clause (s : PState) (h : WfP s) (k : Check) : clause s k = true :=
  (List.all_eq_true.mp h) k (by cases k <;> simp [Check.all])

theorem payload_decode_encode (s : PState) (h : WfP s) : decodeP (encodeP s) = some s := by
  have hs := wf_shape s h
  simp only [okShape, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hs
  unfold decodeP
  rw [parse_encode s hs.1.1.1.1.1.2 hs.2]
  unfold WfP at h
  simp [h]

theorem decode_wf (t : List Nat) (s : PState) (h : decodeP t = some s) : WfP s := by
  unfold decodeP at h
  split at h
  · cases h
  · rename_i s' _
    by_cases hc : checkP s' = true
    · simp only [hc, ↓reduceIte, Option.some.injEq] at h
      subst h
      exact hc
    · simp [hc] at h

theorem decode_encode_decode (t : List Nat) (s : PState) (h : decodeP t = some s) : decodeP (encodeP s) = some s :=
  payload_decode_encode s (decode_wf t s h)

theorem decode_rejects_failure (s : PState) (hlen : s.slots.length = s.high) (hc : s.slots.all canonSlot = true)
    (k : Check) (hk : clause s k = false) : decodeP (encodeP s) = none := by
  unfold decodeP
  rw [parse_encode s hlen hc]
  have : checkP s = false := by
    unfold checkP
    rw [List.all_eq_false]
    exact ⟨k, by cases k <;> simp [Check.all], by simp [hk]⟩
  simp [this]

theorem wf_free (s : PState) (h : WfP s) : (∀ f ∈ s.free, f < s.high) ∧ s.free.Nodup := by
  have hf := wf_clause s h .free
  simp only [clause, okFree, Bool.and_eq_true, List.all_eq_true, decide_eq_true_eq] at hf
  exact hf

theorem wf_elements (s : PState) (h : WfP s) : (∀ e ∈ s.elems, e.1 < s.high ∧ e.1 ∉ s.free) ∧ (s.elems.map Prod.fst).Nodup := by
  have hs := wf_clause s h .slot
  simp only [clause, okSlot, Bool.and_eq_true, List.all_eq_true, decide_eq_true_eq, Bool.not_eq_true'] at hs
  refine ⟨fun e he => ⟨(hs.1 e he).1, fun hm => ?_⟩, hs.2⟩
  have h2 := (hs.1 e he).2
  rw [List.contains_iff_mem.mpr hm] at h2
  exact Bool.noConfusion h2

theorem wf_sequences (s : PState) (h : WfP s) : (∀ e ∈ s.elems, 1 ≤ e.2 ∧ e.2 ≤ s.uid) ∧ (s.elems.map Prod.snd).Nodup := by
  have hs := wf_clause s h .seq
  simp only [clause, okSeq, Bool.and_eq_true, List.all_eq_true, decide_eq_true_eq] at hs
  exact hs

theorem wf_link_target (s : PState) (h : WfP s) (i l j : Nat) (hi : i < s.high) (hn : isNodeP s i = true)
    (hl : l ≤ levelAt s i) (hj : j ∈ listAt s i l) : j < s.high ∧ j ≠ i ∧ isNodeP s j = true ∧ l ≤ levelAt s j := by
  have hk := wf_clause s h .link
  simp only [clause, okLink, List.all_eq_true, List.mem_range, Bool.or_eq_true, Bool.not_eq_true',
    Bool.and_eq_true, decide_eq_true_eq, bne_iff_ne, ne_eq] at hk
  rcases hk i hi with hx | hx
  · simp [hn] at hx
  · have := (hx l (by omega)).2 j hj
    exact ⟨this.1.1.1, this.1.1.2, this.1.2, this.2⟩

theorem wf_list_nodup (s : PState) (h : WfP s) (i l : Nat) (hi : i < s.high) (hn : isNodeP s i = true)
    (hl : l ≤ levelAt s i) : (listAt s i l).Nodup := by
  have hk := wf_clause s h .link
  simp only [clause, okLink, List.all_eq_true, List.mem_range, Bool.or_eq_true, Bool.not_eq_true',
    Bool.and_eq_true, decide_eq_true_eq] at hk
  rcases hk i hi with hx | hx
  · simp [hn] at hx
  · exact (hx l (by omega)).1

theorem wf_symmetric (s : PState) (h : WfP s) (i l j : Nat) (hi : i < s.high) (hn : isNodeP s i = true)
    (hl : l ≤ levelAt s i) (hj : j ∈ listAt s i l) : i ∈ listAt s j l := by
  have hk := wf_clause s h .sym
  simp only [clause, okSym, List.all_eq_true, List.mem_range, Bool.or_eq_true, Bool.not_eq_true',
    List.contains_iff_mem] at hk
  rcases hk i hi with hx | hx
  · simp [hn] at hx
  · simpa using hx l (by omega) j hj

theorem wf_entry (s : PState) (h : WfP s) :
    isNodeP s s.entry = true ∧ levelAt s s.entry = s.top ∧ ∀ i, i < s.high → isNodeP s i = true → levelAt s i ≤ s.top := by
  have hk := wf_clause s h .entry
  simp only [clause, okEntry, Bool.and_eq_true, beq_iff_eq, List.all_eq_true, List.mem_range, Bool.or_eq_true,
    Bool.not_eq_true', decide_eq_true_eq] at hk
  refine ⟨hk.1.1, hk.1.2, fun i hi hn => ?_⟩
  rcases hk.2 i hi with hx | hx
  · simp [hn] at hx
  · exact hx

theorem wf_twins (s : PState) (h : WfP s) (t : Nat) (ht : t ∈ twinsP s) :
    prevAt s t < s.high ∧ prevAt s t ≠ t ∧ (isNodeP s (prevAt s t) = true ∨ isTwinP s (prevAt s t) = true) ∧
      reachesNode s (twinsP s).length t = true := by
  have hk := wf_clause s h .twin
  simp only [clause, okTwin, Bool.and_eq_true, List.all_eq_true, decide_eq_true_eq, bne_iff_ne, ne_eq,
    Bool.or_eq_true] at hk
  have := hk.1.2 t ht
  exact ⟨this.1.1.1, this.1.1.2, this.1.2, this.2⟩

theorem wf_twin_prev_distinct (s : PState) (h : WfP s) : ((twinsP s).map (prevAt s)).Nodup := by
  have hk := wf_clause s h .twin
  simp only [clause, okTwin, Bool.and_eq_true, decide_eq_true_eq] at hk
  exact hk.2

theorem slotAt_canon (s : PState) (h : WfP s) (i : Nat) : canonSlot (slotAt s i) = true := by
  have hs := wf_shape s h
  simp only [okShape, Bool.and_eq_true, List.all_eq_true] at hs
  unfold slotAt
  rw [List.getD_eq_getElem?_getD]
  cases hx : s.slots[i]? with
  | none => simp [canonSlot, pFree, pTwin, pCap]
  | some x => exact hs.2 x (List.mem_of_getElem? hx)

theorem listAt_occupied (s : PState) (h : WfP s) (i l x : Nat) (hx : x ∈ listAt s i l) :
    i < s.high ∧ isNodeP s i = true ∧ l ≤ levelAt s i := by
  have hs := wf_shape s h
  simp only [okShape, Bool.and_eq_true, beq_iff_eq] at hs
  have hc := slotAt_canon s h i
  have hlv : levelAt s i = (slotAt s i).level := rfl
  unfold listAt at hx
  generalize hy : slotAt s i = y at hx hc hlv
  have hlt : i < s.high := by
    rw [← hs.1.1.1.1.1.2]
    by_cases hge : i < s.slots.length
    · exact hge
    · exfalso
      have hd : slotAt s i = ⟨pFree, 0, []⟩ := by
        unfold slotAt
        rw [List.getD_eq_getElem?_getD, List.getElem?_eq_none (by omega)]
        rfl
      rw [hd] at hy
      subst hy
      simp at hx
  rw [List.getD_eq_getElem?_getD] at hx
  generalize hz : y.lists[l]? = o at hx
  cases o with
  | none => simp at hx
  | some z =>
    have hll : l < y.lists.length := (List.getElem?_eq_some_iff.mp hz).1
    simp only [canonSlot, Bool.and_eq_true] at hc
    by_cases hcap : y.level ≤ pCap
    · simp only [hcap, ↓reduceIte, beq_iff_eq] at hc
      refine ⟨hlt, ?_, by rw [hlv]; omega⟩
      simp [isNodeP, hlt, hlv, hcap]
    · simp only [hcap, ↓reduceIte, List.isEmpty_iff] at hc
      rw [hc.2] at hll
      simp at hll

def unlinkedList (s : PState) (x i l : Nat) : List Nat :=
  if i = x then [] else if i ∈ listAt s x l then (listAt s i l).erase x else listAt s i l

theorem unlink_leaves_no_reference (s : PState) (h : WfP s) (x i l : Nat) : x ∉ unlinkedList s x i l := by
  unfold unlinkedList
  by_cases hix : i = x
  · simp [hix]
  · simp only [hix, ↓reduceIte]
    by_cases hm : i ∈ listAt s x l
    · simp only [hm, ↓reduceIte]
      intro hx
      have hocc := listAt_occupied s h i l x (List.mem_of_mem_erase hx)
      have hnd := wf_list_nodup s h i l hocc.1 hocc.2.1 hocc.2.2
      exact ((List.Nodup.mem_erase_iff hnd).mp hx).1 rfl
    · simp only [hm, ↓reduceIte]
      intro hx
      have hocc := listAt_occupied s h i l x hx
      exact hm (wf_symmetric s h i l x hocc.1 hocc.2.1 hocc.2.2 hx)

def exNode (link : List Nat) : PSlot := ⟨0, 0, [link]⟩

def exBase : PState := ⟨4, 3, 3, 0, 0, false, [], [(0, 1), (1, 2), (2, 3)], [exNode [1], exNode [0], exNode []]⟩

theorem example_base : checkP exBase = true := by decide

def exShape : PState := { exBase with m := 3 }
def exCounter : PState := { exBase with uid := 2 ^ 63 }
def exFree : PState := { exBase with free := [5], elems := [(0, 1), (1, 2)] }
def exSlot : PState := { exBase with elems := [(0, 1), (0, 2), (2, 3)] }
def exSeq : PState := { exBase with elems := [(0, 1), (1, 1), (2, 3)] }
def exLevel : PState := { exBase with free := [2], elems := [(0, 1), (1, 2)], slots := [exNode [1], exNode [0], ⟨40, 0, []⟩] }
def exDegree : PState :=
  ⟨4, 10, 10, 0, 0, false, [], (List.range 10).map (fun j => (j, j + 1)),
    exNode (List.range' 1 9) :: (List.range 9).map (fun _ => exNode [0])⟩
def exLink : PState := { exBase with slots := [exNode [1, 0], exNode [0], exNode []] }
def exSym : PState := { exBase with slots := [exNode [1], exNode [], exNode []] }
def exEntry : PState := { exBase with top := 1 }
def exTwin : PState := { exBase with table := true, slots := [exNode [1], exNode [0], ⟨pTwin, 2, []⟩] }

theorem necessary_shape : checkWithout .shape exShape = true ∧ checkP exShape = false := by decide
theorem necessary_counter_bound : checkWithout .shape exCounter = true ∧ checkP exCounter = false := by decide
theorem necessary_free : checkWithout .free exFree = true ∧ checkP exFree = false := by decide
theorem necessary_slot : checkWithout .slot exSlot = true ∧ checkP exSlot = false := by decide
theorem necessary_seq : checkWithout .seq exSeq = true ∧ checkP exSeq = false := by decide
theorem necessary_level : checkWithout .level exLevel = true ∧ checkP exLevel = false := by decide
theorem necessary_degree : checkWithout .degree exDegree = true ∧ checkP exDegree = false := by decide
theorem necessary_link : checkWithout .link exLink = true ∧ checkP exLink = false := by decide
theorem necessary_sym : checkWithout .sym exSym = true ∧ checkP exSym = false := by decide
theorem necessary_entry : checkWithout .entry exEntry = true ∧ checkP exEntry = false := by decide
theorem necessary_twin : checkWithout .twin exTwin = true ∧ checkP exTwin = false := by decide

def restoreOrder {α : Type} (got : List (Nat × α)) : List α :=
  (got.mergeSort (fun a b => decide (a.1 ≤ b.1))).map Prod.snd

theorem rank_key_unique {α : Type} : ∀ (l : List (Nat × α)), l.Pairwise (fun a b => a.1 < b.1) →
    ∀ a b, a ∈ l → b ∈ l → a.1 = b.1 → a = b
  | [], _, a, _, ha, _, _ => by simp at ha
  | x :: xs, hp, a, b, ha, hb, he => by
    rw [List.pairwise_cons] at hp
    simp only [List.mem_cons] at ha hb
    rcases ha with rfl | ha <;> rcases hb with rfl | hb
    · rfl
    · have := hp.1 b hb; omega
    · have := hp.1 a ha; omega
    · exact rank_key_unique xs hp.2 a b ha hb he

theorem rank_restore {α : Type} (orig got : List (Nat × α)) (hs : orig.Pairwise (fun a b => a.1 < b.1))
    (keep : Nat × α → Bool) (hg : got.Perm (orig.filter keep)) :
    restoreOrder got = (orig.filter keep).map Prod.snd := by
  unfold restoreOrder
  congr 1
  have hf : (orig.filter keep).Pairwise (fun a b => a.1 < b.1) := hs.sublist (List.filter_sublist)
  have hm := List.pairwise_mergeSort (le := fun a b : Nat × α => decide (a.1 ≤ b.1))
    (fun a b c h1 h2 => by simp only [decide_eq_true_eq] at *; omega)
    (fun a b => by simp only [Bool.or_eq_true, decide_eq_true_eq]; omega) got
  apply List.Perm.eq_of_pairwise (le := fun a b : Nat × α => decide (a.1 ≤ b.1))
  · intro a b ha hb h1 h2
    simp only [decide_eq_true_eq] at h1 h2
    have ha' : a ∈ orig.filter keep := hg.subset ((List.mergeSort_perm got _).subset ha)
    exact rank_key_unique _ hf a b ha' hb (by omega)
  · exact hm
  · exact hf.imp (fun h => by simp only [decide_eq_true_eq]; omega)
  · exact (List.mergeSort_perm got _).trans hg

theorem stream_moves_only_by_draw {L N V P : Type} [DecidableEq L] [DecidableEq N] (ops : PartOps N V P)
    (sees : L → L → Bool) (c : Cmd L N V) (s : LState L N P) (h : ∀ k, c.op ≠ .draw k) :
    (wstep ops sees c s).stream = s.stream := by
  unfold wstep
  cases hop : c.op with
  | add n v =>
    simp only
    split
    · split <;> rfl
    · split
      · rfl
      · split <;> rfl
  | set n v =>
    simp only
    split
    · split <;> rfl
    · rfl
  | rem n =>
    simp only
    split
    · split <;> rfl
    · rfl
  | drop => rfl
  | draw k => exact absurd hop (h k)

end Vectors
