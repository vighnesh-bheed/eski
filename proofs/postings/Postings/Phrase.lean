import Postings.Cursor

namespace Postings

def firstAtLeast (L : List Nat) (t : Nat) : Option Nat := L.find? fun x => decide (t ≤ x)

def chainFrom : List (List Nat) → Nat → Option Nat
  | [], prev => some prev
  | L :: Ls, prev =>
    match firstAtLeast L prev with
    | none => none
    | some p => chainFrom Ls p

def gapOk (slop : Int) (k first last : Nat) : Bool := decide (slop < 0) || decide ((last : Int) - first - (k - 1 : Nat) ≤ slop)

def orderedGo (rest : List (List Nat)) (slop : Int) (k : Nat) : List Nat → Bool
  | [] => false
  | first :: fs =>
    match chainFrom rest first with
    | none => false
    | some last => if gapOk slop k first last then true else orderedGo rest slop k fs

def orderedWindow (lists : List (List Nat)) (slop : Int) : Bool :=
  match lists with
  | [] => false
  | L0 :: rest => orderedGo rest slop (rest.length + 1) L0

def ChainOf : List (List Nat) → Nat → Nat → Prop
  | [], prev, last => last = prev
  | L :: Ls, prev, last => ∃ p ∈ L, prev ≤ p ∧ ChainOf Ls p last

def OrderedDef (lists : List (List Nat)) (slop : Int) : Prop :=
  match lists with
  | [] => False
  | L0 :: rest => ∃ first ∈ L0, ∃ last, ChainOf rest first last ∧ gapOk slop (rest.length + 1) first last = true

theorem firstAtLeast_some {L : List Nat} {t p : Nat} (h : firstAtLeast L t = some p) : p ∈ L ∧ t ≤ p := by
  unfold firstAtLeast at h
  exact ⟨List.mem_of_find?_eq_some h, by simpa using List.find?_some h⟩

theorem firstAtLeast_least {L : List Nat} (hs : Sorted L) {t x : Nat} (hx : x ∈ L) (htx : t ≤ x) :
    ∃ p, firstAtLeast L t = some p ∧ p ≤ x := by
  unfold firstAtLeast
  induction L with
  | nil => simp at hx
  | cons y ys ih =>
    simp only [List.find?_cons]
    by_cases hy : t ≤ y
    · simp only [hy, decide_true]
      refine ⟨y, rfl, ?_⟩
      rcases List.mem_cons.1 hx with e | e
      · omega
      · exact (List.pairwise_cons.1 hs).1 x e
    · simp only [hy, decide_false]
      rcases List.mem_cons.1 hx with e | e
      · omega
      · exact ih (List.Pairwise.of_cons hs) e

theorem chainOf_mono : ∀ (Ls : List (List Nat)) {p q last : Nat}, q ≤ p → ChainOf Ls p last → ∃ last', ChainOf Ls q last' ∧ last' ≤ last
  | [], p, q, last, hqp, h => ⟨q, rfl, by simp only [ChainOf] at h; omega⟩
  | L :: Ls, p, q, last, hqp, ⟨r, hr, hpr, hc⟩ => ⟨last, ⟨r, hr, by omega, hc⟩, Nat.le_refl _⟩

theorem chainFrom_sound : ∀ (Ls : List (List Nat)) (prev last : Nat), chainFrom Ls prev = some last → ChainOf Ls prev last
  | [], prev, last, h => by simp [chainFrom] at h; simp [ChainOf, h]
  | L :: Ls, prev, last, h => by
    simp only [chainFrom] at h
    split at h
    · cases h
    · rename_i p hp
      have := firstAtLeast_some hp
      exact ⟨p, this.1, this.2, chainFrom_sound Ls p last h⟩

theorem chainFrom_min : ∀ (Ls : List (List Nat)), (∀ L ∈ Ls, Sorted L) → ∀ (prev last : Nat), ChainOf Ls prev last →
    ∃ last', chainFrom Ls prev = some last' ∧ last' ≤ last
  | [], _, prev, last, h => ⟨prev, rfl, by simp only [ChainOf] at h; omega⟩
  | L :: Ls, hs, prev, last, ⟨r, hr, hpr, hc⟩ => by
    obtain ⟨p, hp, hpr'⟩ := firstAtLeast_least (hs L (by simp)) hr hpr
    obtain ⟨last2, hc2, hle2⟩ := chainOf_mono Ls hpr' hc
    obtain ⟨last3, hc3, hle3⟩ := chainFrom_min Ls (fun L' hL' => hs L' (by simp [hL'])) p last2 hc2
    refine ⟨last3, ?_, by omega⟩
    simp only [chainFrom, hp]
    exact hc3

theorem gapOk_mono {slop : Int} {k first a b : Nat} (hab : a ≤ b) (h : gapOk slop k first b = true) : gapOk slop k first a = true := by
  unfold gapOk at *
  simp only [Bool.or_eq_true, decide_eq_true_eq] at *
  rcases h with h | h
  · exact Or.inl h
  · right; omega

theorem orderedGo_spec (rest : List (List Nat)) (hs : ∀ L ∈ rest, Sorted L) (slop : Int) (k : Nat) :
    ∀ L0 : List Nat, Sorted L0 →
      (orderedGo rest slop k L0 = true ↔ ∃ first ∈ L0, ∃ last, ChainOf rest first last ∧ gapOk slop k first last = true)
  | [], _ => by simp [orderedGo]
  | first :: fs, h0 => by
    have ih := orderedGo_spec rest hs slop k fs (List.Pairwise.of_cons h0)
    unfold orderedGo
    split
    · rename_i hnone
      simp only [Bool.false_eq_true, false_iff, not_exists, not_and]
      intro f hf last hc _
      obtain ⟨last2, hc2, _⟩ := chainOf_mono rest (show first ≤ f from by
        rcases List.mem_cons.1 hf with e | e
        · omega
        · exact (List.pairwise_cons.1 h0).1 f e) hc
      obtain ⟨last3, hc3, _⟩ := chainFrom_min rest hs first last2 hc2
      rw [hnone] at hc3; cases hc3
    · rename_i last hlast
      split
      · rename_i hgap
        simp only [true_iff]
        exact ⟨first, by simp, last, chainFrom_sound rest first last hlast, hgap⟩
      · rename_i hgap
        rw [ih]
        constructor
        · intro ⟨f, hf, l, hc, hg⟩; exact ⟨f, List.mem_cons_of_mem _ hf, l, hc, hg⟩
        · intro ⟨f, hf, l, hc, hg⟩
          rcases List.mem_cons.1 hf with e | e
          · subst e
            obtain ⟨last3, hc3, hle3⟩ := chainFrom_min rest hs f l hc
            rw [hlast] at hc3
            simp only [Option.some.injEq] at hc3
            subst hc3
            exact absurd (gapOk_mono hle3 hg) (by simpa using hgap)
          · exact ⟨f, e, l, hc, hg⟩

theorem orderedWindow_spec (lists : List (List Nat)) (hs : ∀ L ∈ lists, Sorted L) (slop : Int) :
    orderedWindow lists slop = true ↔ OrderedDef lists slop := by
  cases lists with
  | nil => simp [orderedWindow, OrderedDef]
  | cons L0 rest =>
    unfold orderedWindow OrderedDef
    exact orderedGo_spec rest (fun L hL => hs L (by simp [hL])) slop _ L0 (hs L0 (by simp))

def listMin : List Nat → Nat
  | [] => 0
  | [x] => x
  | x :: y :: rest => min x (listMin (y :: rest))

def listMax : List Nat → Nat
  | [] => 0
  | x :: rest => max x (listMax rest)

def firstIndex (v : Nat) : List Nat → Nat
  | [] => 0
  | x :: rest => if x = v then 0 else firstIndex v rest + 1

def windowHit (slop : Int) (k lo hi : Nat) : Bool :=
  decide (lo < hi) && (decide (slop < 0) || decide ((hi : Int) - lo - (k - 1 : Nat) ≤ slop))

def sweepLoop : Nat → List (List Nat) → Int → Bool
  | 0, _, _ => false
  | f + 1, tails, slop =>
    let vs := tails.map fun t => t.headD 0
    if windowHit slop tails.length (listMin vs) (listMax vs) then true
    else
      match tails[firstIndex (listMin vs) vs]? with
      | some (_ :: rest) => if rest = [] then false else sweepLoop f (tails.set (firstIndex (listMin vs) vs) rest) slop
      | _ => false

def unorderedWindow (lists : List (List Nat)) (slop : Int) : Bool :=
  if lists = [] then false
  else if lists.length = 1 then decide (lists.headD [] ≠ [])
  else if lists.any (· = []) then false
  else sweepLoop ((lists.map List.length).sum + 1) lists slop

def phraseMatches (lists : List (List Nat)) (slop : Int) (inOrder : Bool) : Bool :=
  if lists.length = 1 ∨ (slop < 0 ∧ inOrder = false) then true
  else if lists.any (· = []) then false
  else if inOrder then orderedWindow lists slop
  else unorderedWindow lists slop

def Choice : List (List Nat) → List Nat → Prop
  | [], [] => True
  | L :: Ls, p :: ps => p ∈ L ∧ Choice Ls ps
  | _, _ => False

def UnorderedDef (lists : List (List Nat)) (slop : Int) : Prop :=
  ∃ ps, Choice lists ps ∧ windowHit slop lists.length (listMin ps) (listMax ps) = true

theorem choice_length : ∀ {lists : List (List Nat)} {ps : List Nat}, Choice lists ps → ps.length = lists.length
  | [], [], _ => rfl
  | _ :: _, _ :: _, ⟨_, h⟩ => by simp [choice_length h]
  | [], _ :: _, h => absurd h (by simp [Choice])
  | _ :: _, [], h => absurd h (by simp [Choice])

theorem choice_heads : ∀ (tails : List (List Nat)), (∀ t ∈ tails, t ≠ []) → Choice tails (tails.map fun t => t.headD 0)
  | [], _ => trivial
  | t :: ts, h => by
    obtain ⟨x, xs, rfl⟩ := List.exists_cons_of_ne_nil (h t (by simp))
    exact ⟨by simp, choice_heads ts (fun t' ht' => h t' (by simp [ht']))⟩

theorem choice_set : ∀ (tails : List (List Nat)) (i : Nat) (rest : List Nat) (ps : List Nat),
    (∀ x ∈ rest, x ∈ tails.getD i []) → Choice (tails.set i rest) ps → Choice tails ps
  | [], _, _, ps, _, h => by simpa using h
  | t :: ts, 0, rest, p :: ps, hsub, ⟨hp, hc⟩ => ⟨hsub p hp, hc⟩
  | t :: ts, i + 1, rest, p :: ps, hsub, ⟨hp, hc⟩ => ⟨hp, choice_set ts i rest ps hsub hc⟩
  | _ :: _, 0, _, [], _, h => absurd h (by simp [Choice])
  | _ :: _, _ + 1, _, [], _, h => absurd h (by simp [Choice])

theorem nonempty_set : ∀ (tails : List (List Nat)) (i : Nat) (rest : List Nat), (∀ t ∈ tails, t ≠ []) → rest ≠ [] →
    ∀ t ∈ tails.set i rest, t ≠ []
  | [], _, _, _, _ => by simp
  | t :: ts, 0, rest, h, hr => by
    intro u hu; simp only [List.set_cons_zero, List.mem_cons] at hu
    rcases hu with e | e
    · rw [e]; exact hr
    · exact h u (by simp [e])
  | t :: ts, i + 1, rest, h, hr => by
    intro u hu; simp only [List.set_cons_succ, List.mem_cons] at hu
    rcases hu with e | e
    · rw [e]; exact h t (by simp)
    · exact nonempty_set ts i rest (fun v hv => h v (by simp [hv])) hr u e

theorem sweep_sound : ∀ (fuel : Nat) (tails : List (List Nat)) (slop : Int), (∀ t ∈ tails, t ≠ []) →
    sweepLoop fuel tails slop = true → ∃ ps, Choice tails ps ∧ windowHit slop tails.length (listMin ps) (listMax ps) = true
  | 0, _, _, _, h => by simp [sweepLoop] at h
  | f + 1, tails, slop, hne, h => by
    unfold sweepLoop at h
    simp only at h
    split at h
    · rename_i hw
      exact ⟨_, choice_heads tails hne, hw⟩
    · split at h
      · rename_i x rest hget
        split at h
        · cases h
        · rename_i hr
          obtain ⟨ps, hc, hw⟩ := sweep_sound f _ slop (nonempty_set tails _ rest hne hr) h
          refine ⟨ps, choice_set tails _ rest ps (fun y hy => ?_) hc, by rw [List.length_set] at hw; exact hw⟩
          rw [List.getD_eq_getElem?_getD, hget]
          simp [hy]
      · cases h

theorem unordered_sound (lists : List (List Nat)) (slop : Int) (h : unorderedWindow lists slop = true)
    (h2 : 2 ≤ lists.length) : UnorderedDef lists slop := by
  unfold unorderedWindow at h
  have hne : lists ≠ [] := by intro e; rw [e] at h2; simp at h2
  simp only [hne, ↓reduceIte, show ¬ lists.length = 1 from by omega] at h
  split at h
  · cases h
  · rename_i hany
    have hall : ∀ t ∈ lists, t ≠ [] := by
      intro t ht e
      apply hany
      exact List.any_eq_true.2 ⟨t, ht, by simp [e]⟩
    exact sweep_sound _ lists slop hall h

theorem unordered_counterexample :
    unorderedWindow [[5], [5, 6]] 0 = false ∧ Choice [[5], [5, 6]] [5, 6] ∧ windowHit 0 2 (listMin [5, 6]) (listMax [5, 6]) = true := by
  refine ⟨by decide, ⟨by decide, by decide, trivial⟩, by decide⟩

theorem listMin_mem : ∀ {vs : List Nat}, vs ≠ [] → listMin vs ∈ vs
  | [], h => absurd rfl h
  | [x], _ => by simp [listMin]
  | x :: y :: rest, _ => by
    have ih := listMin_mem (vs := y :: rest) (by simp)
    simp only [listMin]
    rcases Nat.le_total x (listMin (y :: rest)) with h | h
    · rw [Nat.min_eq_left h]; simp
    · rw [Nat.min_eq_right h]; exact List.mem_cons_of_mem _ ih

theorem listMin_le : ∀ {vs : List Nat} {v : Nat}, v ∈ vs → listMin vs ≤ v
  | [], _, h => by simp at h
  | [x], v, h => by simp at h; simp [listMin, h]
  | x :: y :: rest, v, h => by
    simp only [listMin]
    rcases List.mem_cons.1 h with e | e
    · subst e; exact Nat.min_le_left _ _
    · exact Nat.le_trans (Nat.min_le_right _ _) (listMin_le e)

theorem le_listMax : ∀ {vs : List Nat} {v : Nat}, v ∈ vs → v ≤ listMax vs
  | [], _, h => by simp at h
  | x :: rest, v, h => by
    simp only [listMax]
    rcases List.mem_cons.1 h with e | e
    · subst e; exact Nat.le_max_left _ _
    · exact Nat.le_trans (le_listMax e) (Nat.le_max_right _ _)

theorem listMax_mem : ∀ {vs : List Nat}, vs ≠ [] → listMax vs ∈ vs
  | [], h => absurd rfl h
  | [x], _ => by simp [listMax]
  | x :: y :: rest, _ => by
    have ih := listMax_mem (vs := y :: rest) (by simp)
    simp only [listMax] at ih ⊢
    rcases Nat.le_total x (max y (listMax rest)) with h | h
    · rw [Nat.max_eq_right h]; exact List.mem_cons_of_mem _ ih
    · rw [Nat.max_eq_left h]; simp

theorem firstIndex_spec : ∀ {vs : List Nat} {v : Nat}, v ∈ vs → firstIndex v vs < vs.length ∧ vs[firstIndex v vs]? = some v
  | [], _, h => by simp at h
  | x :: rest, v, h => by
    simp only [firstIndex]
    split
    · rename_i e; subst e; simp
    · rename_i e
      have hr : v ∈ rest := by rcases List.mem_cons.1 h with e' | e'; exact absurd e'.symm e; exact e'
      have := firstIndex_spec hr
      exact ⟨by simp; omega, by simp [this.2]⟩

theorem listMax_mono : ∀ {vs cs : List Nat}, vs.length = cs.length → (∀ i, i < vs.length → vs.getD i 0 ≤ cs.getD i 0) →
    listMax vs ≤ listMax cs
  | [], [], _, _ => Nat.le_refl _
  | v :: vs, c :: cs, hl, h => by
    simp only [listMax]
    have h0 := h 0 (by simp)
    simp only [List.getD_cons_zero] at h0
    have ih := listMax_mono (vs := vs) (cs := cs) (by simp at hl; exact hl) (fun i hi => by
      have := h (i + 1) (by simp; omega); simpa using this)
    omega
  | [], _ :: _, hl, _ => by simp at hl
  | _ :: _, [], hl, _ => by simp at hl

theorem min_lt_max {vs : List Nat} (hl : 2 ≤ vs.length) (hd : vs.Nodup) : listMin vs < listMax vs := by
  obtain ⟨a, b, rest, rfl⟩ : ∃ a b rest, vs = a :: b :: rest := by
    rcases vs with _ | ⟨a, _ | ⟨b, rest⟩⟩ <;> simp at hl
    exact ⟨a, b, rest, rfl⟩
  have hab : a ≠ b := by
    intro e; subst e; simp at hd
  have h1 := listMin_le (vs := a :: b :: rest) (v := a) (by simp)
  have h2 := listMin_le (vs := a :: b :: rest) (v := b) (by simp)
  have h3 := le_listMax (vs := a :: b :: rest) (v := a) (by simp)
  have h4 := le_listMax (vs := a :: b :: rest) (v := b) (by simp)
  omega

theorem getD_mem_or_nil (l : List (List Nat)) (i : Nat) : l.getD i [] ∈ l ∨ l.getD i [] = [] := by
  rw [List.getD_eq_getElem?_getD]
  cases h : l[i]? with
  | none => right; rfl
  | some v => left; simp only [Option.getD_some]; exact List.mem_of_getElem? h

def PairDisjoint (tails : List (List Nat)) : Prop := List.Pairwise (fun a b => ∀ x ∈ a, x ∉ b) tails

theorem choice_mem : ∀ {tails : List (List Nat)} {cs : List Nat} {i : Nat}, Choice tails cs → i < tails.length →
    cs.getD i 0 ∈ tails.getD i []
  | [], [], _, _, h => by simp at h
  | t :: ts, c :: cs, 0, ⟨hc, _⟩, _ => by simpa using hc
  | t :: ts, c :: cs, i + 1, ⟨_, hc⟩, h => by simpa using choice_mem hc (by simp at h; omega)
  | [], _ :: _, _, h, _ => absurd h (by simp [Choice])
  | _ :: _, [], _, h, _ => absurd h (by simp [Choice])

theorem choice_set_mem : ∀ {tails : List (List Nat)} {cs : List Nat} {i : Nat} {rest : List Nat}, Choice tails cs →
    cs.getD i 0 ∈ rest → Choice (tails.set i rest) cs
  | [], [], _, _, h, _ => by simpa using h
  | t :: ts, c :: cs, 0, rest, ⟨_, hc⟩, hm => ⟨by simpa using hm, hc⟩
  | t :: ts, c :: cs, i + 1, rest, ⟨h1, hc⟩, hm => ⟨h1, choice_set_mem hc (by simpa using hm)⟩
  | [], _ :: _, _, _, h, _ => absurd h (by simp [Choice])
  | _ :: _, [], _, _, h, _ => absurd h (by simp [Choice])

theorem sorted_set : ∀ (tails : List (List Nat)) (i : Nat) (rest : List Nat), (∀ t ∈ tails, Sorted t) → Sorted rest →
    ∀ t ∈ tails.set i rest, Sorted t
  | [], _, _, _, _ => by simp
  | t :: ts, 0, rest, h, hr => by
    intro u hu; simp only [List.set_cons_zero, List.mem_cons] at hu
    rcases hu with e | e
    · rw [e]; exact hr
    · exact h u (by simp [e])
  | t :: ts, i + 1, rest, h, hr => by
    intro u hu; simp only [List.set_cons_succ, List.mem_cons] at hu
    rcases hu with e | e
    · rw [e]; exact h t (by simp)
    · exact sorted_set ts i rest (fun v hv => h v (by simp [hv])) hr u e

theorem disjoint_set : ∀ (tails : List (List Nat)) (i : Nat) (rest : List Nat), PairDisjoint tails →
    (∀ x ∈ rest, x ∈ tails.getD i []) → PairDisjoint (tails.set i rest)
  | [], _, _, h, _ => by simpa using h
  | t :: ts, 0, rest, h, hsub => by
    unfold PairDisjoint at *
    simp only [List.set_cons_zero, List.pairwise_cons] at h ⊢
    refine ⟨fun b hb x hx => h.1 b hb x (by simpa using hsub x hx), h.2⟩
  | t :: ts, i + 1, rest, h, hsub => by
    unfold PairDisjoint at *
    simp only [List.set_cons_succ, List.pairwise_cons] at h ⊢
    refine ⟨fun b hb x hx hxb => ?_, disjoint_set ts i rest h.2 (by simpa using hsub)⟩
    rcases List.mem_or_eq_of_mem_set hb with e | e
    · exact h.1 b e x hx hxb
    · subst e
      have hx2 : x ∈ ts.getD i [] := by simpa using hsub x hxb
      rcases getD_mem_or_nil ts i with hm | hm
      · exact h.1 _ hm x hx hx2
      · rw [hm] at hx2; simp at hx2

theorem heads_nodup : ∀ (tails : List (List Nat)), PairDisjoint tails → (∀ t ∈ tails, t ≠ []) → (tails.map fun t => t.headD 0).Nodup
  | [], _, _ => List.nodup_nil
  | t :: ts, hd, hne => by
    unfold PairDisjoint at hd
    rw [List.pairwise_cons] at hd
    simp only [List.map_cons, List.nodup_cons, List.mem_map, not_exists, not_and]
    refine ⟨fun u hu he => ?_, heads_nodup ts hd.2 (fun u hu => hne u (by simp [hu]))⟩
    obtain ⟨x, xs, rfl⟩ := List.exists_cons_of_ne_nil (hne t (by simp))
    obtain ⟨y, ys, rfl⟩ := List.exists_cons_of_ne_nil (hne u (by simp [hu]))
    simp at he
    exact hd.1 (y :: ys) hu x (by simp) (by rw [← he]; simp)

theorem sum_set_tail (tails : List (List Nat)) (i : Nat) (x : Nat) (rest : List Nat) (h : tails[i]? = some (x :: rest)) :
    ((tails.set i rest).map List.length).sum + 1 = (tails.map List.length).sum := by
  induction tails generalizing i with
  | nil => simp at h
  | cons t ts ih =>
    cases i with
    | zero => simp at h; subst h; simp; omega
    | succ i =>
      simp only [List.getElem?_cons_succ] at h
      simp only [List.set_cons_succ, List.map_cons, List.sum_cons]
      have := ih i h; omega

theorem sweep_complete : ∀ (fuel : Nat) (tails : List (List Nat)) (slop : Int) (cs : List Nat),
    (∀ t ∈ tails, Sorted t) → (∀ t ∈ tails, t ≠ []) → PairDisjoint tails → 2 ≤ tails.length → Choice tails cs →
    (slop < 0 ∨ (listMax cs : Int) - listMin cs - (tails.length - 1 : Nat) ≤ slop) →
    (tails.map List.length).sum < fuel → sweepLoop fuel tails slop = true
  | 0, _, _, _, _, _, _, _, _, _, hf => absurd hf (Nat.not_lt_zero _)
  | f + 1, tails, slop, cs, hs, hne, hd, hl, hc, hgap, hf => by
    have hlen := choice_length hc
    unfold sweepLoop
    simp only
    split
    · rfl
    · rename_i hw
      have hvne : tails.map (fun t => t.headD 0) ≠ [] := by intro e; simp at e; subst e; simp at hl
      have hlo := listMin_mem hvne
      have hfi := firstIndex_spec hlo
      have hat : firstIndex (listMin (tails.map fun t => t.headD 0)) (tails.map fun t => t.headD 0) < tails.length := by
        simpa using hfi.1
      obtain ⟨x, rest, hget⟩ : ∃ x rest, tails[firstIndex (listMin (tails.map fun t => t.headD 0)) (tails.map fun t => t.headD 0)]? = some (x :: rest) := by
        have hmem := List.getElem_mem hat
        obtain ⟨x, rest, he⟩ := List.exists_cons_of_ne_nil (hne _ hmem)
        exact ⟨x, rest, by rw [List.getElem?_eq_getElem hat, he]⟩
      have hxlo : x = listMin (tails.map fun t => t.headD 0) := by
        have := hfi.2
        simp only [List.getElem?_map, hget, Option.map_some, List.headD_cons, Option.some.injEq] at this
        exact this
      set_option linter.unusedVariables false in
      have hcmem := choice_mem hc hat
      rw [List.getD_eq_getElem?_getD, hget] at hcmem
      simp only [Option.getD_some] at hcmem
      have hsorted : Sorted (x :: rest) := hs _ (List.mem_of_getElem? hget)
      have hpoint : ∀ i, i < tails.length → (tails.map fun t => t.headD 0).getD i 0 ≤ cs.getD i 0 := by
        intro i hi
        have hm := choice_mem hc hi
        have hsi := hs _ (List.getElem_mem hi)
        rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hi] at hm
        simp only [List.getD_eq_getElem?_getD, List.getElem?_map, List.getElem?_eq_getElem hi, Option.map_some,
          Option.getD_some] at hm ⊢
        obtain ⟨y, ys, hy⟩ := List.exists_cons_of_ne_nil (hne _ (List.getElem_mem hi))
        rw [hy] at hm hsi ⊢
        simp only [List.headD_cons]
        rcases List.mem_cons.1 hm with e | e
        · omega
        · exact (List.pairwise_cons.1 hsi).1 _ e
      have hcne : cs.getD (firstIndex (listMin (tails.map fun t => t.headD 0)) (tails.map fun t => t.headD 0)) 0 ≠ x := by
        intro e
        apply hw
        have hmax := listMax_mono (vs := tails.map fun t => t.headD 0) (cs := cs) (by simp [hlen]) (by simpa using hpoint)
        have hmin : listMin cs ≤ listMin (tails.map fun t => t.headD 0) := by
          rw [← hxlo, ← e]
          apply listMin_le
          rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem (by rw [hlen]; exact hat)]
          simp
        have hlt := min_lt_max (vs := tails.map fun t => t.headD 0) (by simpa using hl) (heads_nodup tails hd hne)
        unfold windowHit
        simp only [hlt, decide_true, Bool.true_and, Bool.or_eq_true, decide_eq_true_eq, List.length_map]
        rcases hgap with g | g
        · exact Or.inl g
        · right; omega
      have hcr : cs.getD (firstIndex (listMin (tails.map fun t => t.headD 0)) (tails.map fun t => t.headD 0)) 0 ∈ rest := by
        rcases List.mem_cons.1 hcmem with e | e
        · exact absurd e hcne
        · exact e
      rw [hget]
      simp only
      have hrne : rest ≠ [] := by intro e; rw [e] at hcr; simp at hcr
      simp only [hrne, ↓reduceIte]
      apply sweep_complete f _ slop cs
      · exact sorted_set tails _ rest hs (List.Pairwise.of_cons hsorted)
      · exact nonempty_set tails _ rest hne hrne
      · apply disjoint_set tails _ rest hd
        intro y hy
        rw [List.getD_eq_getElem?_getD, hget]; simp [hy]
      · simpa using hl
      · exact choice_set_mem hc hcr
      · simpa using hgap
      · have := sum_set_tail tails _ x rest hget; omega

theorem unordered_complete (lists : List (List Nat)) (slop : Int) (hs : ∀ L ∈ lists, Sorted L) (hd : PairDisjoint lists)
    (h2 : 2 ≤ lists.length) (cs : List Nat) (hc : Choice lists cs)
    (hgap : slop < 0 ∨ (listMax cs : Int) - listMin cs - (lists.length - 1 : Nat) ≤ slop) : unorderedWindow lists slop = true := by
  have hne : lists ≠ [] := by intro e; rw [e] at h2; simp at h2
  have hall : ∀ t ∈ lists, t ≠ [] := by
    intro t ht e
    obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem ht
    have := choice_mem hc hi
    rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hi, e] at this
    simp at this
  unfold unorderedWindow
  simp only [hne, ↓reduceIte, show ¬ lists.length = 1 from by omega]
  have hany : ¬ (lists.any fun t => decide (t = [])) = true := by
    intro h; obtain ⟨t, ht, he⟩ := List.any_eq_true.1 h; simp at he; exact hall t ht he
  simp only [hany, Bool.false_eq_true, ↓reduceIte]
  exact sweep_complete _ lists slop cs hs hall hd h2 hc hgap (by omega)

end Postings
