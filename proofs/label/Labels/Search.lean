import Labels.Admission

namespace Labels

structure Cand where
  d : Int
  id : Nat
deriving DecidableEq, Repr

def closer (a b : Cand) : Bool := decide (a.d < b.d) || (decide (a.d = b.d) && decide (a.id < b.id))

def insertSorted (c : Cand) : List Cand → List Cand
  | [] => [c]
  | x :: xs => if closer c x then c :: x :: xs else x :: insertSorted c xs

def topR (res : List Cand) : Cand := res.getLast?.getD ⟨0, 0⟩

def pushResult (ef : Nat) (res : List Cand) (c : Cand) : List Cand :=
  if res.length < ef then insertSorted c res
  else if closer c (topR res) then insertSorted c res.dropLast
  else res

structure Env where
  adj : Nat → List Nat
  dist : Nat → Int
  twin : Nat → Option Nat
  twins : Bool
  accept : Nat → Bool
  ef : Nat
  budget : Nat
  bound : Option Int
  chain : Nat

structure SState where
  cands : List Cand
  results : List Cand
  visited : List Nat
  inspected : Nat

def above (E : Env) (d : Int) : Bool :=
  match E.bound with
  | none => false
  | some b => decide (b < d)

def exhausted (E : Env) (st : SState) : Bool := decide (0 < E.budget) && decide (E.budget ≤ st.inspected)

def mark (st : SState) (x : Nat) : Bool × SState :=
  if x ∈ st.visited then (false, st) else (true, { st with visited := x :: st.visited })

def pushCand (st : SState) (c : Cand) : SState := { st with cands := insertSorted c st.cands }

def inspect (E : Env) (st : SState) (c : Cand) : SState :=
  let st := { st with inspected := st.inspected + 1 }
  if E.accept c.id then { st with results := pushResult E.ef st.results c } else st

def twinsAccept (E : Env) (c : Cand) : Nat → Option Nat → SState → Bool × SState
  | 0, _, st => (true, st)
  | _ + 1, none, st => (true, st)
  | fuel + 1, some t, st =>
    if decide (E.ef ≤ st.results.length) && !decide (c.d < (topR st.results).d) then (true, st)
    else if exhausted E st then (false, st)
    else twinsAccept E c fuel (E.twin t) (inspect E st ⟨E.dist t, t⟩)

def entryStep (E : Env) (st : SState) (e : Cand) : SState :=
  let m := mark st e.id
  if !m.1 then m.2
  else
    let st := pushCand m.2 e
    if above E e.d || exhausted E st then st
    else
      let st := inspect E st e
      if E.twins then (twinsAccept E e E.chain (E.twin e.id) st).2 else st

def gather (st : SState) : List Nat → List Nat × SState
  | [] => ([], st)
  | e :: rest =>
    let m := mark st e
    let g := gather m.2 rest
    if m.1 then (e :: g.1, g.2) else g

def batchStep (E : Env) (st : SState) (e : Nat) : SState :=
  let n : Cand := ⟨E.dist e, e⟩
  if decide (st.results.length < E.ef) || closer n (topR st.results) then
    let st := pushCand st n
    if above E n.d then st
    else
      let st := inspect E st n
      if E.twins then (twinsAccept E n E.chain (E.twin e) st).2 else st
  else st

def carefulLoop (E : Env) : List Nat → SState → Bool × SState
  | [], st => (false, st)
  | e :: rest, st =>
    let m := mark st e
    if !m.1 then carefulLoop E rest m.2
    else
      let st := m.2
      let n : Cand := ⟨E.dist e, e⟩
      if decide (st.results.length < E.ef) || closer n (topR st.results) then
        if above E n.d then carefulLoop E rest (pushCand st n)
        else if exhausted E st then (true, st)
        else
          let st := inspect E (pushCand st n) n
          if E.twins then
            let r := twinsAccept E n E.chain (E.twin e) st
            if !r.1 then (true, r.2) else carefulLoop E rest r.2
          else carefulLoop E rest st
      else carefulLoop E rest st

def walk (E : Env) : Nat → SState → SState
  | 0, st => st
  | fuel + 1, st =>
    match st.cands with
    | [] => st
    | c :: rest =>
      let st := { st with cands := rest }
      if decide (E.ef ≤ st.results.length) && decide ((topR st.results).d < c.d) then st
      else
        let l := E.adj c.id
        if decide (E.budget = 0) || (!E.twins && decide ((l.length : Int) ≤ (E.budget : Int) - st.inspected)) then
          let g := gather st l
          walk E fuel (g.1.foldl (batchStep E) g.2)
        else
          let r := carefulLoop E l st
          if r.1 then r.2 else walk E fuel r.2

def searchLayerFiltered (E : Env) (entries : List Cand) (fuel : Nat) : SState :=
  walk E fuel (entries.foldl (entryStep E) ⟨[], [], [], 0⟩)

def searchFiltered (E : Env) (ep : Cand) (k fuel : Nat) : List Cand :=
  ((searchLayerFiltered { E with ef := max E.ef k } [ep] fuel).results).take k

def bruteForce (n : Nat) (live accept : Nat → Bool) (dist : Nat → Int) (want : Nat) : List Cand :=
  ((List.range n).foldl (fun res s => if live s && accept s then pushResult want res ⟨dist s, s⟩ else res) []).take want

def Good (accept : Nat → Bool) (res : List Cand) : Prop := ∀ r ∈ res, accept r.id = true

theorem insertSorted_mem {c x : Cand} {l : List Cand} (h : x ∈ insertSorted c l) : x ∈ l ∨ x = c := by
  induction l with
  | nil => simp [insertSorted] at h; exact Or.inr h
  | cons y ys ih =>
    simp only [insertSorted] at h
    split at h
    · simp only [List.mem_cons] at h
      rcases h with h | h | h
      · exact Or.inr h
      · exact Or.inl (List.mem_cons.2 (Or.inl h))
      · exact Or.inl (List.mem_cons.2 (Or.inr h))
    · simp only [List.mem_cons] at h
      rcases h with h | h
      · exact Or.inl (List.mem_cons.2 (Or.inl h))
      · rcases ih h with h | h
        · exact Or.inl (List.mem_cons.2 (Or.inr h))
        · exact Or.inr h

theorem pushResult_mem {ef : Nat} {res : List Cand} {c x : Cand} (h : x ∈ pushResult ef res c) : x ∈ res ∨ x = c := by
  unfold pushResult at h
  split at h
  · exact insertSorted_mem h
  · split at h
    · rcases insertSorted_mem h with h | h
      · exact Or.inl (List.dropLast_subset _ h)
      · exact Or.inr h
    · exact Or.inl h

theorem good_push {accept : Nat → Bool} {ef : Nat} {res : List Cand} {c : Cand} (h : Good accept res)
    (hc : accept c.id = true) : Good accept (pushResult ef res c) := by
  intro r hr
  rcases pushResult_mem hr with hr | hr
  · exact h r hr
  · rw [hr]; exact hc

theorem inspect_good {E : Env} {st : SState} {c : Cand} (h : Good E.accept st.results) :
    Good E.accept (inspect E st c).results := by
  unfold inspect
  split
  · rename_i ha; exact good_push h ha
  · exact h

theorem mark_results (st : SState) (x : Nat) : (mark st x).2.results = st.results := by
  unfold mark; split <;> rfl

theorem twinsAccept_good (E : Env) (c : Cand) (fuel : Nat) (t : Option Nat) (st : SState)
    (h : Good E.accept st.results) : Good E.accept (twinsAccept E c fuel t st).2.results := by
  induction fuel generalizing t st with
  | zero => exact h
  | succ fuel ih =>
    cases t with
    | none => exact h
    | some t =>
      simp only [twinsAccept]
      split
      · exact h
      · split
        · exact h
        · exact ih _ _ (inspect_good h)

theorem entryStep_good (E : Env) (st : SState) (e : Cand) (h : Good E.accept st.results) :
    Good E.accept (entryStep E st e).results := by
  have hm : Good E.accept (mark st e.id).2.results := by rw [mark_results]; exact h
  unfold entryStep
  dsimp only
  split
  · exact hm
  · split
    · exact hm
    · split
      · exact twinsAccept_good _ _ _ _ _ (inspect_good hm)
      · exact inspect_good hm

theorem entries_good (E : Env) (es : List Cand) (st : SState) (h : Good E.accept st.results) :
    Good E.accept (es.foldl (entryStep E) st).results := by
  induction es generalizing st with
  | nil => exact h
  | cons e es ih => exact ih _ (entryStep_good E st e h)

theorem gather_results (st : SState) (l : List Nat) : (gather st l).2.results = st.results := by
  induction l generalizing st with
  | nil => rfl
  | cons e rest ih =>
    simp only [gather]
    split
    · rw [ih, mark_results]
    · rw [ih, mark_results]

theorem batchStep_good (E : Env) (st : SState) (e : Nat) (h : Good E.accept st.results) :
    Good E.accept (batchStep E st e).results := by
  unfold batchStep
  dsimp only
  split
  · split
    · exact h
    · split
      · exact twinsAccept_good _ _ _ _ _ (inspect_good h)
      · exact inspect_good h
  · exact h

theorem batch_good (E : Env) (ids : List Nat) (st : SState) (h : Good E.accept st.results) :
    Good E.accept (ids.foldl (batchStep E) st).results := by
  induction ids generalizing st with
  | nil => exact h
  | cons e es ih => exact ih _ (batchStep_good E st e h)

theorem carefulLoop_good (E : Env) (l : List Nat) (st : SState) (h : Good E.accept st.results) :
    Good E.accept (carefulLoop E l st).2.results := by
  induction l generalizing st with
  | nil => exact h
  | cons e rest ih =>
    have hm : Good E.accept (mark st e).2.results := by rw [mark_results]; exact h
    simp only [carefulLoop]
    split
    · exact ih _ hm
    · split
      · split
        · exact ih _ hm
        · split
          · exact hm
          · have hi := inspect_good (E := E) (st := pushCand (mark st e).2 ⟨E.dist e, e⟩) (c := ⟨E.dist e, e⟩) hm
            split
            · have ht := twinsAccept_good E ⟨E.dist e, e⟩ E.chain (E.twin e) _ hi
              split
              · exact ht
              · exact ih _ ht
            · exact ih _ hi
      · exact ih _ hm

theorem walk_good (E : Env) (fuel : Nat) (st : SState) (h : Good E.accept st.results) :
    Good E.accept (walk E fuel st).results := by
  induction fuel generalizing st with
  | zero => exact h
  | succ fuel ih =>
    simp only [walk]
    split
    · exact h
    · rename_i c rest _
      have h' : Good E.accept ({ st with cands := rest } : SState).results := h
      split
      · exact h'
      · split
        · apply ih
          apply batch_good
          rw [gather_results]
          exact h'
        · have hc := carefulLoop_good E (E.adj c.id) { st with cands := rest } h'
          split
          · exact hc
          · exact ih _ hc

theorem searchLayerFiltered_sound (E : Env) (entries : List Cand) (fuel : Nat) :
    Good E.accept (searchLayerFiltered E entries fuel).results :=
  walk_good E fuel _ (entries_good E entries _ (fun r hr => by simp at hr))

theorem searchFiltered_sound (E : Env) (ep : Cand) (k fuel : Nat) :
    ∀ r ∈ searchFiltered E ep k fuel, E.accept r.id = true := by
  intro r hr
  have := searchLayerFiltered_sound { E with ef := max E.ef k } [ep] fuel r (List.mem_of_mem_take hr)
  exact this

theorem bruteForce_sound (n : Nat) (live accept : Nat → Bool) (dist : Nat → Int) (want : Nat) :
    ∀ r ∈ bruteForce n live accept dist want, live r.id = true ∧ accept r.id = true := by
  have key : ∀ (ss : List Nat) (res : List Cand), (∀ r ∈ res, live r.id = true ∧ accept r.id = true) →
      ∀ r ∈ ss.foldl (fun res s => if live s && accept s then pushResult want res ⟨dist s, s⟩ else res) res,
        live r.id = true ∧ accept r.id = true := by
    intro ss
    induction ss with
    | nil => intro res h; exact h
    | cons s rest ih =>
      intro res h
      apply ih
      intro r hr
      simp only at hr
      split at hr
      · rename_i hs
        rcases pushResult_mem hr with hr | hr
        · exact h r hr
        · rw [hr]; simpa using hs
      · exact h r hr
  intro r hr
  exact key _ [] (fun r hr => by simp at hr) r (List.mem_of_mem_take hr)

theorem foldl_congr {α β : Type} {f g : α → β → α} (l : List β) (init : α)
    (h : ∀ a b, b ∈ l → f a b = g a b) : l.foldl f init = l.foldl g init := by
  induction l generalizing init with
  | nil => rfl
  | cons b rest ih =>
    simp only [List.foldl_cons]
    rw [h init b (List.mem_cons_self), ih _ (fun a b hb => h a b (List.mem_cons_of_mem _ hb))]

theorem bruteForce_noninterference (n : Nat) (live live' accept : Nat → Bool) (dist dist' : Nat → Int) (want : Nat)
    (hl : ∀ s, accept s = true → live s = live' s) (hd : ∀ s, accept s = true → dist s = dist' s) :
    bruteForce n live accept dist want = bruteForce n live' accept dist' want := by
  unfold bruteForce
  congr 1
  apply foldl_congr
  intro res s _
  cases ha : accept s
  · simp
  · rw [hl s ha, hd s ha]

theorem search_dominated {t : List Label} (reader : Label) (labels : List Nat) (E : Env)
    (he : E.accept = gateAccept (build reader t) labels) (ep : Cand) (k fuel : Nat) :
    ∀ r ∈ searchFiltered E ep k fuel,
      ∃ id, labels[r.id]? = some id ∧ id < t.length ∧ dom reader (t.getD id bottom) = true := by
  intro r hr
  have ha := searchFiltered_sound E ep k fuel r hr
  rw [he] at ha
  obtain ⟨id, h1, h2, h3⟩ := gate_dominated (build_ok reader t) ha
  have hr' : (build reader t).reader = reader := by unfold build; rw [refresh_reader]
  rw [hr'] at h3
  exact ⟨id, h1, h2, h3⟩

theorem search_filter_dominated {A : Type} {t : List Label} (reader : Label) (labels : List Nat) (f : FilterGate A)
    (E : Env) (he : E.accept = filterAccept (build reader t) labels f) (ep : Cand) (k fuel : Nat) :
    ∀ r ∈ searchFiltered E ep k fuel,
      (∃ id, labels[r.id]? = some id ∧ id < t.length ∧ dom reader (t.getD id bottom) = true) ∧
        filterPasses f r.id = true := by
  intro r hr
  have ha := searchFiltered_sound E ep k fuel r hr
  rw [he, filter_exact, Bool.and_eq_true] at ha
  obtain ⟨id, h1, h2, h3⟩ := gate_dominated (build_ok reader t) ha.1
  have hr' : (build reader t).reader = reader := by unfold build; rw [refresh_reader]
  rw [hr'] at h3
  exact ⟨⟨id, h1, h2, h3⟩, ha.2⟩

theorem search_within_clearance {t : List Label} (s : Subject) (labels : List Nat) (E : Env)
    (he : E.accept = gateAccept (build (reader s) t) labels) (ep : Cand) (k fuel : Nat) :
    ∀ r ∈ searchFiltered E ep k fuel,
      ∃ id, labels[r.id]? = some id ∧ id < t.length ∧ dom s.clearance (t.getD id bottom) = true := by
  intro r hr
  obtain ⟨id, h1, h2, h3⟩ := search_dominated (reader s) labels E he ep k fuel r hr
  exact ⟨id, h1, h2, read_clearance h3⟩

def demoAdj : Nat → List Nat
  | 0 => [1, 2]
  | 1 => [0]
  | 2 => [0, 3]
  | 3 => [2]
  | _ => []

def demoAccept (x : Nat) : Bool := x == 1 || x == 3

def demoDist (hidden : Int) : Nat → Int
  | 0 => 10
  | 1 => 5
  | 2 => hidden
  | 3 => 1
  | _ => 100

def demoEnv (hidden : Int) : Env :=
  ⟨demoAdj, demoDist hidden, fun _ => none, false, demoAccept, 1, 0, none, 4⟩

theorem graph_search_interference :
    (∀ x, demoAccept x = true → demoDist 2 x = demoDist 8 x) ∧
      searchFiltered (demoEnv 2) ⟨10, 0⟩ 1 10 = [⟨1, 3⟩] ∧
      searchFiltered (demoEnv 8) ⟨10, 0⟩ 1 10 = [⟨5, 1⟩] := by
  refine ⟨fun x hx => ?_, by decide, by decide⟩
  unfold demoAccept at hx
  rcases x with _ | _ | _ | _ | x
  · simp at hx
  · rfl
  · simp at hx
  · rfl
  · rfl

end Labels
