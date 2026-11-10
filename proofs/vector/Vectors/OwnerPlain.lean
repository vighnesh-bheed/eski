import Vectors.Owner

set_option autoImplicit false

namespace Vectors

section Embed
set_option linter.unusedSectionVars false
variable {L N V P : Type} [DecidableEq L] [DecidableEq N]

def atOwner (w : Nat) (l : L) : L × Nat := (l, w)

def embedS (w : Nat) (other : L × Nat → Nat) (s : LState L N P) : LState (L × Nat) N P :=
  { parts := fun x => if x.2 = w then s.parts x.1 else none,
    index := fun n => (s.index n).map (atOwner w),
    stream := fun x => if x.2 = w then s.stream x.1 else other x }

def embedC (w : Nat) (c : Cmd L N V) : Cmd (L × Nat) N V := ⟨(c.label, w), c.op⟩

def embedView (w : Nat) (vo : ViewObj L N) : ViewObj (L × Nat) N :=
  { labels := vo.labels.map (atOwner w), shadows := vo.shadows.map (fun e => ((e.1, w), e.2)),
    size := vo.size, attrs := vo.attrs }

theorem mem_map_atOwner (w : Nat) (l : L) (ls : List L) : (l, w) ∈ ls.map (atOwner w) ↔ l ∈ ls := by
  simp [atOwner]

theorem erase_map_atOwner (w : Nat) (l : L) : ∀ (ls : List L),
    (ls.erase l).map (atOwner w) = (ls.map (atOwner w)).erase (l, w) := by
  intro ls
  induction ls with
  | nil => rfl
  | cons x xs ih =>
    by_cases hx : x = l
    · subst hx
      simp [atOwner, List.erase_cons_head]
    · have h1 : (x == l) = false := by simpa using hx
      have h2 : ((x, w) == (l, w)) = false := by simpa using hx
      rw [List.erase_cons_tail (by simpa using h1), List.map_cons, List.map_cons]
      simp only [atOwner] at ih ⊢
      rw [List.erase_cons_tail (by simpa using h2), ih]

theorem map_append_one (w : Nat) (l : L) (ls : List L) :
    (ls ++ [l]).map (atOwner w) = ls.map (atOwner w) ++ [(l, w)] := by
  simp [atOwner]

theorem visibleOther_embed (sees : L → L → Bool) (w : Nat) (l : L) (ls : List L) :
    visibleOther (seesP sees) (l, w) (ls.map (atOwner w)) = visibleOther sees l ls := by
  unfold visibleOther
  rw [List.any_map]
  congr 1
  funext x
  simp [atOwner, seesP, ownerSees]

theorem embed_step (ops : PartOps N V P) (sees : L → L → Bool) (w : Nat) (other : L × Nat → Nat)
    (c : Cmd L N V) (s : LState L N P) :
    wstep ops (seesP sees) (embedC w c) (embedS w other s) = embedS w other (wstep ops sees c s) := by
  have hp : ∀ l, (embedS w other s).parts (l, w) = s.parts l := by intro l; simp [embedS]
  have hst : ∀ l, (embedS w other s).stream (l, w) = s.stream l := by intro l; simp [embedS]
  have hi : ∀ n, (embedS w other s).index n = (s.index n).map (atOwner w) := fun n => rfl
  have pext : ∀ (l : L) (q : Option P), setPart (embedS w other s) (l, w) q = embedS w other (setPart s l q) := by
    intro l q
    apply state_ext
    · funext x; simp only [setPart, embedS]
      by_cases h2 : x.2 = w
      · by_cases h1 : x.1 = l
        · have : x = (l, w) := Prod.ext h1 h2
          subst this; simp
        · have : x ≠ (l, w) := fun e => h1 (by rw [e])
          simp [this, h1, h2]
      · have : x ≠ (l, w) := fun e => h2 (by rw [e])
        simp [this, h2]
    · rfl
    · rfl
  have iext : ∀ (a : LState L N P) (n : N) (ls : List L),
      setIndex (embedS w other a) n (ls.map (atOwner w)) = embedS w other (setIndex a n ls) := by
    intro a n ls
    apply state_ext
    · rfl
    · funext m; simp only [setIndex, embedS]; split <;> rfl
    · rfl
  have sext : ∀ (a : LState L N P) (l : L) (v : Nat),
      setStream (embedS w other a) (l, w) v = embedS w other (setStream a l v) := by
    intro a l v
    apply state_ext
    · rfl
    · rfl
    · funext x; simp only [setStream, embedS]
      by_cases h2 : x.2 = w
      · by_cases h1 : x.1 = l
        · have : x = (l, w) := Prod.ext h1 h2
          subst this; simp
        · have : x ≠ (l, w) := fun e => h1 (by rw [e])
          simp [this, h1, h2]
      · have : x ≠ (l, w) := fun e => h2 (by rw [e])
        simp [this, h2]
  have pext' : ∀ (a : LState L N P) (l : L) (q : Option P),
      setPart (embedS w other a) (l, w) q = embedS w other (setPart a l q) := by
    intro a l q
    apply state_ext
    · funext x; simp only [setPart, embedS]
      by_cases h2 : x.2 = w
      · by_cases h1 : x.1 = l
        · have : x = (l, w) := Prod.ext h1 h2
          subst this; simp
        · have : x ≠ (l, w) := fun e => h1 (by rw [e])
          simp [this, h1, h2]
      · have : x ≠ (l, w) := fun e => h2 (by rw [e])
        simp [this, h2]
    · rfl
    · rfl
  unfold wstep embedC
  simp only
  cases c.op with
  | add n v =>
    simp only [hi, mem_map_atOwner, visibleOther_embed, hp]
    by_cases hm : c.label ∈ s.index n
    · simp only [hm, ↓reduceIte]
      split
      · exact pext _ _
      · rfl
    · simp only [hm, ↓reduceIte]
      split
      · rfl
      · split
        · rw [pext, ← map_append_one, iext]
        · rw [hst, sext, pext', ← map_append_one, iext]
  | set n v =>
    simp only [hi, mem_map_atOwner, hp]
    split
    · split
      · exact pext _ _
      · rfl
    · rfl
  | rem n =>
    simp only [hi, mem_map_atOwner, hp]
    split
    · split
      · rw [pext, ← erase_map_atOwner, iext]
      · rfl
    · rfl
  | drop =>
    apply state_ext
    · funext x; simp only [embedS]
      by_cases h2 : x.2 = w
      · by_cases h1 : x.1 = c.label
        · have : x = (c.label, w) := Prod.ext h1 h2
          subst this; simp
        · have : x ≠ (c.label, w) := fun e => h1 (by rw [e])
          simp [this, h1, h2]
      · have : x ≠ (c.label, w) := fun e => h2 (by rw [e])
        simp [this, h2]
    · funext n; simp only [embedS]; rw [erase_map_atOwner]
    · rfl
  | draw k =>
    simp only [hst, sext]

theorem embed_run (ops : PartOps N V P) (sees : L → L → Bool) (w : Nat) (other : L × Nat → Nat) :
    ∀ (cs : List (Cmd L N V)) (s : LState L N P),
      wrun ops (seesP sees) (cs.map (embedC w)) (embedS w other s) = embedS w other (wrun ops sees cs s) := by
  intro cs
  induction cs with
  | nil => intro s; rfl
  | cons c cs ih =>
    intro s
    rw [List.map_cons, wrun, wrun, embed_step]
    exact ih _

theorem resolveFrom_embed (sees gt : L → L → Bool) (r : L) (w : Nat) : ∀ (ls : List L) (b : Option L),
    (∀ x, b = some x → x ≠ r) →
    resolveFrom (readerP sees gt (r, w)) (ls.map (atOwner w)) (b.map (atOwner w)) =
      (resolveFrom ⟨r, sees r, gt⟩ ls b).map (atOwner w) := by
  have hvis : ∀ c, seesP sees (r, w) (c, w) = sees r c := by
    intro c; simp [seesP, ownerSees]
  have hgt : ∀ c x, c ≠ r → x ≠ r → gtX gt (r, w) (c, w) (x, w) = gt c x := by
    intro c x hc hx
    have h1 : (x, w) ≠ (r, SHARED) := fun e => hx (Prod.mk.inj e).1
    have h2 : (c, w) ≠ (r, SHARED) := fun e => hc (Prod.mk.inj e).1
    by_cases h : w = SHARED <;> simp [gtX, gtP, h1, h2, h, hx, hc]
  intro ls
  induction ls with
  | nil => intro b _; rfl
  | cons c cs ih =>
    intro b hb
    rw [List.map_cons]
    by_cases hc : c = r
    · subst hc
      simp [resolveFrom, readerP, atOwner]
    · have hc' : (atOwner w c) ≠ (readerP sees gt (r, w)).own := by
        simp only [readerP, atOwner, ne_eq, Prod.mk.injEq, and_true]; exact hc
      by_cases hv : sees r c = true
      · cases b with
        | none =>
          simp only [resolveFrom, hc', ↓reduceIte, hc]
          simp only [readerP, atOwner, hvis, hv, ↓reduceIte]
          exact ih (some c) (fun y hy => by cases hy; exact hc)
        | some x =>
          have hx := hb x rfl
          by_cases hg : gt c x = true
          · simp only [resolveFrom, hc', ↓reduceIte, hc, Option.map_some]
            simp only [readerP, atOwner, hvis, hv, hgt c x hc hx, hg, ↓reduceIte]
            exact ih (some c) (fun y hy => by cases hy; exact hc)
          · simp only [resolveFrom, hc', ↓reduceIte, hc, Option.map_some]
            simp only [readerP, atOwner, hvis, hv, hgt c x hc hx, hg, ↓reduceIte, Bool.false_eq_true]
            exact ih (some x) (fun y hy => by cases hy; exact hx)
      · have hf : sees r c = false := by simpa using hv
        simp only [resolveFrom, hc', ↓reduceIte, hc]
        simp only [readerP, atOwner, hvis, hf, ↓reduceIte, Bool.false_eq_true]
        exact ih b hb

theorem embed_resolve (sees gt : L → L → Bool) (r : L) (w : Nat) (ls : List L) :
    resolveL (readerP sees gt (r, w)) (ls.map (atOwner w)) = (resolveL ⟨r, sees r, gt⟩ ls).map (atOwner w) :=
  resolveFrom_embed sees gt r w ls none (fun x hx => by cases hx)

theorem embed_inView (sees gt : L → L → Bool) (r : L) (w : Nat) (other : L × Nat → Nat) (s : LState L N P) (l : L) :
    inView (readerP sees gt (r, w)) (embedS w other s) (l, w) = inView ⟨r, sees r, gt⟩ s l := by
  simp [inView, present, embedS, readerP, seesP, ownerSees]

theorem embed_inView_other (sees gt : L → L → Bool) (r : L) (w : Nat) (other : L × Nat → Nat) (s : LState L N P)
    (x : L × Nat) (hx : x.2 ≠ w) : inView (readerP sees gt (r, w)) (embedS w other s) x = false := by
  simp [inView, present, embedS, hx]

theorem embed_viewFind (sees gt : L → L → Bool) (r : L) (w : Nat) (other : L × Nat → Nat) (s : LState L N P) (n : N) :
    viewFind (readerP sees gt (r, w)) (embedS w other s) n = (viewFind ⟨r, sees r, gt⟩ s n).map (atOwner w) := by
  unfold viewFind
  have hi : (embedS w other s).index n = (s.index n).map (atOwner w) := rfl
  rw [hi, embed_resolve]
  cases resolveL ⟨r, sees r, gt⟩ (s.index n) with
  | none => rfl
  | some l =>
    simp only [Option.map_some]
    show (if inView (readerP sees gt (r, w)) (embedS w other s) (l, w) = true then some (l, w) else none) = _
    rw [embed_inView]
    split <;> rfl

theorem embed_viewRange (sees gt : L → L → Bool) (r : L) (w : Nat) (other : L × Nat → Nat) (s : LState L N P)
    (namesU : List N) (inRange : N → Bool) (limit : Option Nat) :
    viewRange (readerP sees gt (r, w)) (embedS w other s) namesU inRange limit =
      (viewRange ⟨r, sees r, gt⟩ s namesU inRange limit).map (fun e => (e.1, (e.2, w))) := by
  unfold viewRange
  have hi : ∀ n, (embedS w other s).index n = (s.index n).map (atOwner w) := fun n => rfl
  have hf : namesU.filter (fun n => inRange n && !((embedS w other s).index n).isEmpty) =
      namesU.filter (fun n => inRange n && !(s.index n).isEmpty) := by
    apply List.filter_congr
    intro n _
    rw [hi]
    cases s.index n <;> rfl
  rw [hf]
  have hfm : ∀ (xs : List N),
      xs.filterMap (fun n => (viewFind (readerP sees gt (r, w)) (embedS w other s) n).map (fun l => (n, l))) =
        (xs.filterMap (fun n => (viewFind ⟨r, sees r, gt⟩ s n).map (fun l => (n, l)))).map (fun e => (e.1, (e.2, w))) := by
    intro xs
    induction xs with
    | nil => rfl
    | cons x xs ih =>
      rw [List.filterMap_cons, List.filterMap_cons, embed_viewFind]
      cases viewFind ⟨r, sees r, gt⟩ s x with
      | none => simp only [Option.map_none]; exact ih
      | some l => simp only [Option.map_some, List.map_cons]; rw [ih]; rfl
  simp only
  rw [hfm]
  cases limit with
  | none => rfl
  | some k => simp only; rw [List.map_take]

theorem embed_visibleLabels (sees gt : L → L → Bool) (le : L → L → Bool) (leP : L × Nat → L × Nat → Bool)
    (w : Nat) (hle : ∀ a b, leP (a, w) (b, w) = le a b) (labelsU : List L) (r : L) (other : L × Nat → Nat)
    (s : LState L N P) :
    visibleLabels leP (labelsU.map (atOwner w)) (readerP sees gt (r, w)) (embedS w other s) =
      (visibleLabels le labelsU ⟨r, sees r, gt⟩ s).map (atOwner w) := by
  unfold visibleLabels
  rw [List.filter_map]
  have : (inView (readerP sees gt (r, w)) (embedS w other s) ∘ atOwner w) = inView ⟨r, sees r, gt⟩ s := by
    funext l
    exact embed_inView sees gt r w other s l
  rw [this]
  rw [List.map_mergeSort]
  intro a _ b _
  exact (hle a b).symm

theorem embed_shadowsOf (sees gt : L → L → Bool) (r : L) (w : Nat) (other : L × Nat → Nat) (s : LState L N P) (n : N) :
    shadowsOf (readerP sees gt (r, w)) (embedS w other s) n =
      (shadowsOf ⟨r, sees r, gt⟩ s n).map (fun e => ((e.1, w), e.2)) := by
  unfold shadowsOf
  have hi : (embedS w other s).index n = (s.index n).map (atOwner w) := rfl
  have hv : ((s.index n).map (atOwner w)).filter (inView (readerP sees gt (r, w)) (embedS w other s)) =
      ((s.index n).filter (inView ⟨r, sees r, gt⟩ s)).map (atOwner w) := by
    rw [List.filter_map]
    congr 1
    apply List.filter_congr
    intro l _
    exact embed_inView sees gt r w other s l
  simp only
  rw [hi, hv, List.length_map, List.length_map, embed_resolve]
  split
  · split
    · rw [List.filter_map, List.map_map, List.map_map]
      congr 1
      · apply List.filter_congr
        intro l _
        simp only [Function.comp, atOwner]
        cases resolveL ⟨r, sees r, gt⟩ (s.index n) with
        | none => simp
        | some x => simp [atOwner]
    · rfl
  · rfl

theorem embed_viewOpen (sees gt : L → L → Bool) (acc : PartAcc N P) (le : L → L → Bool)
    (leP : L × Nat → L × Nat → Bool) (w : Nat) (hle : ∀ a b, leP (a, w) (b, w) = le a b) (labelsU : List L)
    (namesU : List N) (r : L) (other : L × Nat → Nat) (s : LState L N P) :
    viewOpen acc leP (labelsU.map (atOwner w)) namesU (readerP sees gt (r, w)) (embedS w other s) =
      embedView w (viewOpen acc le labelsU namesU ⟨r, sees r, gt⟩ s) := by
  unfold viewOpen embedView
  rw [embed_visibleLabels sees gt le leP w hle labelsU r other s]
  have hsh : namesU.flatMap (shadowsOf (readerP sees gt (r, w)) (embedS w other s)) =
      (namesU.flatMap (shadowsOf ⟨r, sees r, gt⟩ s)).map (fun e => ((e.1, w), e.2)) := by
    rw [List.map_flatMap]
    congr 1
    funext n
    exact embed_shadowsOf sees gt r w other s n
  rw [hsh]
  have hc : ∀ l, partCount acc (embedS w other s) (l, w) = partCount acc s l := by
    intro l; simp [partCount, embedS]
  have ha : ∀ l, partAttrs acc (embedS w other s) (l, w) = partAttrs acc s l := by
    intro l; simp [partAttrs, embedS]
  have hsa : ∀ (e : L × N), shadowAttr acc (embedS w other s) ((e.1, w), e.2) = shadowAttr acc s e := by
    intro e; simp [shadowAttr, embedS]
  simp only [List.map_map, List.length_map]
  have e1 : ((visibleLabels le labelsU ⟨r, sees r, gt⟩ s).map (partCount acc (embedS w other s) ∘ atOwner w)) =
      (visibleLabels le labelsU ⟨r, sees r, gt⟩ s).map (partCount acc s) := by
    apply List.map_congr_left; intro l _; exact hc l
  have e2 : ((visibleLabels le labelsU ⟨r, sees r, gt⟩ s).map (partAttrs acc (embedS w other s) ∘ atOwner w)) =
      (visibleLabels le labelsU ⟨r, sees r, gt⟩ s).map (partAttrs acc s) := by
    apply List.map_congr_left; intro l _; exact ha l
  have e3 : ((namesU.flatMap (shadowsOf ⟨r, sees r, gt⟩ s)).map (fun e => ((e.1, w), e.2))).filter
      (shadowAttr acc (embedS w other s)) =
      ((namesU.flatMap (shadowsOf ⟨r, sees r, gt⟩ s)).filter (shadowAttr acc s)).map (fun e => ((e.1, w), e.2)) := by
    rw [List.filter_map]
    congr 1
    apply List.filter_congr
    intro e _
    exact hsa e
  rw [e1, e2, e3, List.length_map]

theorem owners_off_run (ops : PartOps N V P) (sees : L → L → Bool) (other : L × Nat → Nat)
    (cs : List (Cmd L N V)) (s : LState L N P) :
    wrun ops (seesP sees) (cs.map (embedC SHARED)) (embedS SHARED other s) =
      embedS SHARED other (wrun ops sees cs s) :=
  embed_run ops sees SHARED other cs s

theorem owners_off_view (ops : PartOps N V P) (sees gt : L → L → Bool) (acc : PartAcc N P) (le : L → L → Bool)
    (leP : L × Nat → L × Nat → Bool) (hle : ∀ a b, leP (a, SHARED) (b, SHARED) = le a b) (labelsU : List L)
    (namesU : List N) (r : L) (other : L × Nat → Nat) (cs : List (Cmd L N V)) (s : LState L N P) :
    viewOpen acc leP (labelsU.map (atOwner SHARED)) namesU (readerP sees gt (r, SHARED))
        (wrun ops (seesP sees) (cs.map (embedC SHARED)) (embedS SHARED other s)) =
      embedView SHARED (viewOpen acc le labelsU namesU ⟨r, sees r, gt⟩ (wrun ops sees cs s)) := by
  rw [owners_off_run, embed_viewOpen sees gt acc le leP SHARED hle]

theorem single_owner_view (ops : PartOps N V P) (sees gt : L → L → Bool) (acc : PartAcc N P) (le : L → L → Bool)
    (u : Nat) (leP : L × Nat → L × Nat → Bool) (hle : ∀ a b, leP (a, u) (b, u) = le a b) (labelsU : List L)
    (namesU : List N) (r : L) (other : L × Nat → Nat) (cs : List (Cmd L N V)) (s : LState L N P) :
    viewOpen acc leP (labelsU.map (atOwner u)) namesU (readerP sees gt (r, u))
        (wrun ops (seesP sees) (cs.map (embedC u)) (embedS u other s)) =
      embedView u (viewOpen acc le labelsU namesU ⟨r, sees r, gt⟩ (wrun ops sees cs s)) := by
  rw [embed_run, embed_viewOpen sees gt acc le leP u hle]

theorem single_owner_find (ops : PartOps N V P) (sees gt : L → L → Bool) (u : Nat) (r : L)
    (other : L × Nat → Nat) (cs : List (Cmd L N V)) (s : LState L N P) (n : N) :
    viewFind (readerP sees gt (r, u)) (wrun ops (seesP sees) (cs.map (embedC u)) (embedS u other s)) n =
      (viewFind ⟨r, sees r, gt⟩ (wrun ops sees cs s) n).map (atOwner u) := by
  rw [embed_run, embed_viewFind]

theorem single_owner_range (ops : PartOps N V P) (sees gt : L → L → Bool) (u : Nat) (r : L)
    (other : L × Nat → Nat) (cs : List (Cmd L N V)) (s : LState L N P) (namesU : List N) (inRange : N → Bool)
    (limit : Option Nat) :
    viewRange (readerP sees gt (r, u)) (wrun ops (seesP sees) (cs.map (embedC u)) (embedS u other s)) namesU
        inRange limit =
      (viewRange ⟨r, sees r, gt⟩ (wrun ops sees cs s) namesU inRange limit).map (fun e => (e.1, (e.2, u))) := by
  rw [embed_run, embed_viewRange]

end Embed

end Vectors
