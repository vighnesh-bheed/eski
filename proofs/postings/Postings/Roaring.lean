import Postings.Sorted
import Postings.Svbyte

namespace Postings

def arrayMax : Nat := 4096

def chunk : Nat := 65536

inductive Con where
  | arr (vs : List Nat)
  | bits (vs : List Nat)
  | runs (rs : List (Nat × Nat))
deriving DecidableEq, Repr

def expandRun (s l : Nat) : List Nat := (List.range (l + 1)).map (s + ·)

def expandRuns : List (Nat × Nat) → List Nat
  | [] => []
  | (s, l) :: rs => expandRun s l ++ expandRuns rs

def Con.elems : Con → List Nat
  | .arr vs => vs
  | .bits vs => vs
  | .runs rs => expandRuns rs

def Con.card (c : Con) : Nat := c.elems.length

def Con.isRun : Con → Bool
  | .runs _ => true
  | _ => false

def fromSet (vs : List Nat) : Con := if arrayMax < vs.length then .bits vs else .arr vs

def flatten : Con → Con
  | .runs rs => fromSet (expandRuns rs)
  | c => c

def sortedInsert (x : Nat) : List Nat → List Nat
  | [] => [x]
  | y :: ys => if x < y then x :: y :: ys else if x = y then y :: ys else y :: sortedInsert x ys

def conAdd (c : Con) (x : Nat) : Con × Bool :=
  match flatten c with
  | .arr vs =>
    if x ∈ vs then (.arr vs, false)
    else if arrayMax ≤ vs.length then (.bits (sortedInsert x vs), true)
    else (.arr (sortedInsert x vs), true)
  | .bits vs => if x ∈ vs then (.bits vs, false) else (.bits (sortedInsert x vs), true)
  | .runs rs => (.runs rs, false)

def conRemove (c : Con) (x : Nat) : Con × Bool :=
  if x ∈ c.elems then
    match flatten c with
    | .arr vs => (.arr (vs.erase x), true)
    | .bits vs => (if (vs.erase x).length ≤ arrayMax then .arr (vs.erase x) else .bits (vs.erase x), true)
    | .runs rs => (.runs rs, true)
  else (c, false)

abbrev Bitmap := List (Nat × Con)

def contents (b : Bitmap) : List Nat := b.flatMap fun p => p.2.elems.map (p.1 * chunk + ·)

def keys (b : Bitmap) : List Nat := b.map Prod.fst

def lookup : Bitmap → Nat → Option Con
  | [], _ => none
  | (k', c) :: rest, k => if k = k' then some c else lookup rest k

def bmAdd : Bitmap → Nat → Nat → Bitmap × Bool
  | [], k, lo => ([(k, .arr [lo])], true)
  | (k', c) :: rest, k, lo =>
    if k < k' then ((k, .arr [lo]) :: (k', c) :: rest, true)
    else if k = k' then ((k', (conAdd c lo).1) :: rest, (conAdd c lo).2)
    else ((k', c) :: (bmAdd rest k lo).1, (bmAdd rest k lo).2)

def add (b : Bitmap) (x : Nat) : Bitmap × Bool := bmAdd b (x / chunk) (x % chunk)

def bmRemove : Bitmap → Nat → Nat → Bitmap × Bool
  | [], _, _ => ([], false)
  | (k', c) :: rest, k, lo =>
    if k = k' then
      (if (conRemove c lo).1.card = 0 then rest else (k', (conRemove c lo).1) :: rest, (conRemove c lo).2)
    else if k < k' then ((k', c) :: rest, false)
    else ((k', c) :: (bmRemove rest k lo).1, (bmRemove rest k lo).2)

def remove (b : Bitmap) (x : Nat) : Bitmap × Bool := bmRemove b (x / chunk) (x % chunk)

def contains (b : Bitmap) (x : Nat) : Bool :=
  match lookup b (x / chunk) with
  | some c => decide (x % chunk ∈ c.elems)
  | none => false

def cardinality (b : Bitmap) : Nat := (b.map fun p => p.2.card).sum

inductive Op where
  | and
  | or
  | andnot
deriving DecidableEq, Repr

def setOp : Op → List Nat → List Nat → List Nat
  | .and, a, b => a.filter fun x => decide (x ∈ b)
  | .or, a, b => unionMerge a b
  | .andnot, a, b => a.filter fun x => decide (x ∉ b)

def opSem : Op → Bool → Bool → Bool
  | .and, p, q => p && q
  | .or, p, q => p || q
  | .andnot, p, q => p && !q

def conOp (op : Op) (a b : Con) : Con :=
  match a, b with
  | .arr x, .arr y => if arrayMax < (setOp op x y).length then .bits (setOp op x y) else .arr (setOp op x y)
  | _, _ =>
    match op with
    | .and =>
      match a with
      | .arr x => .arr (x.filter fun v => decide (v ∈ b.elems))
      | _ =>
        match b with
        | .arr y => .arr (y.filter fun v => decide (v ∈ a.elems))
        | _ => fromSet (a.elems.filter fun v => decide (v ∈ b.elems))
    | .or => fromSet (unionMerge a.elems b.elems)
    | .andnot =>
      match a with
      | .arr x => .arr (x.filter fun v => decide (v ∉ b.elems))
      | _ => fromSet (a.elems.filter fun v => decide (v ∉ b.elems))

def keep (k : Nat) (c : Con) : Bitmap := if c.card = 0 then [] else [(k, c)]

def combine (op : Op) : Bitmap → Bitmap → Bitmap
  | [], [] => []
  | (ka, ca) :: ra, [] => if op = .and then [] else (ka, ca) :: combine op ra []
  | [], (kb, cb) :: rb => if op = .or then (kb, cb) :: combine op [] rb else []
  | (ka, ca) :: ra, (kb, cb) :: rb =>
    if ka < kb then (if op = .and then [] else [(ka, ca)]) ++ combine op ra ((kb, cb) :: rb)
    else if kb < ka then (if op = .or then [(kb, cb)] else []) ++ combine op ((ka, ca) :: ra) rb
    else keep ka (conOp op ca cb) ++ combine op ra rb
termination_by a b => a.length + b.length

def andCardinality (a b : Bitmap) : Nat := cardinality (combine .and a b)

def maxRuns : List Nat → List (Nat × Nat)
  | [] => []
  | x :: xs =>
    match maxRuns xs with
    | (s, l) :: rs => if s = x + 1 then (x, l + 1) :: rs else (x, 0) :: (s, l) :: rs
    | [] => [(x, 0)]

def runCount (c : Con) : Nat :=
  match c with
  | .runs rs => rs.length
  | _ => (maxRuns c.elems).length

def optimizeCon (c : Con) : Con × Bool :=
  match c with
  | .runs rs =>
    let flat := if (expandRuns rs).length ≤ arrayMax then 2 * (expandRuns rs).length else 8192
    if flat ≤ 2 + 4 * rs.length then (fromSet (expandRuns rs), true) else (c, false)
  | .arr vs => if 2 + 4 * (maxRuns vs).length < 2 * vs.length then (.runs (maxRuns vs), true) else (c, false)
  | .bits vs => if 2 + 4 * (maxRuns vs).length < 8192 then (.runs (maxRuns vs), true) else (c, false)

def runOptimize (b : Bitmap) : Bitmap × Bool :=
  (b.map fun p => (p.1, (optimizeCon p.2).1), b.any fun p => (optimizeCon p.2).2)

def RunsOk : Nat → List (Nat × Nat) → Prop
  | _, [] => True
  | free, (s, l) :: rs => free ≤ s ∧ s + l < chunk ∧ RunsOk (s + l + 1) rs

def ConOk : Con → Prop
  | .arr vs => Strict vs ∧ (∀ v ∈ vs, v < chunk) ∧ vs ≠ [] ∧ vs.length ≤ arrayMax
  | .bits vs => Strict vs ∧ (∀ v ∈ vs, v < chunk) ∧ arrayMax < vs.length
  | .runs rs => RunsOk 0 rs ∧ rs ≠ [] ∧ rs.length < chunk

def WF (b : Bitmap) : Prop := Strict (keys b) ∧ ∀ p ∈ b, p.1 < chunk ∧ ConOk p.2

theorem mem_expandRun {s l x : Nat} : x ∈ expandRun s l ↔ s ≤ x ∧ x ≤ s + l := by
  unfold expandRun
  simp only [List.mem_map, List.mem_range]
  constructor
  · rintro ⟨i, hi, rfl⟩; omega
  · intro h; exact ⟨x - s, by omega, by omega⟩

theorem strict_expandRun (s l : Nat) : Strict (expandRun s l) := by
  unfold expandRun Strict
  rw [List.pairwise_map]
  exact List.Pairwise.imp (fun h => by omega) (List.pairwise_lt_range)

theorem runsOk_mono : ∀ {free free' : Nat} {rs : List (Nat × Nat)}, free' ≤ free → RunsOk free rs → RunsOk free' rs
  | _, _, [], _, _ => trivial
  | _, _, (s, l) :: rs, h, ⟨h1, h2, h3⟩ => ⟨by omega, h2, h3⟩

theorem expandRuns_bound : ∀ {free : Nat} {rs : List (Nat × Nat)}, RunsOk free rs →
    ∀ x ∈ expandRuns rs, free ≤ x ∧ x < chunk
  | _, [], _ => by simp [expandRuns]
  | free, (s, l) :: rs, ⟨h1, h2, h3⟩ => by
    intro x hx
    simp only [expandRuns, List.mem_append] at hx
    rcases hx with hx | hx
    · rw [mem_expandRun] at hx; omega
    · have := expandRuns_bound h3 x hx; omega

theorem strict_expandRuns : ∀ {free : Nat} {rs : List (Nat × Nat)}, RunsOk free rs → Strict (expandRuns rs)
  | _, [], _ => List.Pairwise.nil
  | free, (s, l) :: rs, ⟨h1, h2, h3⟩ => by
    simp only [expandRuns, Strict]
    rw [List.pairwise_append]
    refine ⟨strict_expandRun s l, strict_expandRuns h3, fun a ha b hb => ?_⟩
    rw [mem_expandRun] at ha
    have := expandRuns_bound h3 b hb
    omega

theorem conOk_elems {c : Con} (h : ConOk c) : Strict c.elems ∧ (∀ v ∈ c.elems, v < chunk) ∧ c.elems ≠ [] := by
  cases c with
  | arr vs => exact ⟨h.1, h.2.1, h.2.2.1⟩
  | bits vs =>
    refine ⟨h.1, h.2.1, fun e => ?_⟩
    have e' : vs = [] := e
    have := h.2.2; rw [e'] at this; simp [arrayMax] at this
  | runs rs =>
    refine ⟨strict_expandRuns h.1, fun v hv => (expandRuns_bound h.1 v hv).2, fun e => ?_⟩
    obtain ⟨⟨s, l⟩, rs', hr⟩ := List.exists_cons_of_ne_nil h.2.1
    subst hr
    simp [Con.elems, expandRuns, expandRun] at e

theorem conOk_card {c : Con} (h : ConOk c) : 0 < c.card := by
  have := (conOk_elems h).2.2
  unfold Con.card
  exact List.length_pos_iff.2 this

theorem lookup_mem_keys : ∀ {b : Bitmap} {k : Nat} {c : Con}, lookup b k = some c → k ∈ keys b
  | [], _, _, h => by simp [lookup] at h
  | (k', c') :: rest, k, c, h => by
    simp only [lookup] at h
    split at h
    · rename_i he; simp [keys, he]
    · simp only [keys, List.map_cons, List.mem_cons]; right; exact lookup_mem_keys h

theorem mem_contents (b : Bitmap) (hb : ∀ p ∈ b, ∀ v ∈ p.2.elems, v < chunk) (hk : Strict (keys b)) (y : Nat) :
    y ∈ contents b ↔ ∃ c, lookup b (y / chunk) = some c ∧ y % chunk ∈ c.elems := by
  induction b with
  | nil => simp [contents, lookup]
  | cons p rest ih =>
    obtain ⟨k, c⟩ := p
    have ih' := ih (fun q hq => hb q (by simp [hq])) (strict_cons hk)
    simp only [contents, List.flatMap_cons, List.mem_append] at ih' ⊢
    rw [ih']
    simp only [lookup]
    have hkr : ∀ k' ∈ keys rest, k < k' := strict_head hk
    constructor
    · rintro (h | ⟨c', hl, hm⟩)
      · simp only [List.mem_map] at h
        obtain ⟨v, hv, rfl⟩ := h
        have hvb := hb (k, c) (by simp) v hv
        have e1 : (k * chunk + v) / chunk = k := by unfold chunk at *; omega
        have e2 : (k * chunk + v) % chunk = v := by unfold chunk at *; omega
        rw [e1, e2]; simp [hv]
      · split
        · rename_i he
          exfalso
          have := hkr _ (lookup_mem_keys hl); omega
        · exact ⟨c', hl, hm⟩
    · intro ⟨c', hl, hm⟩
      split at hl
      · rename_i he
        simp only [Option.some.injEq] at hl
        subst hl
        left
        simp only [List.mem_map]
        refine ⟨y % chunk, hm, ?_⟩
        rw [← he]; unfold chunk; omega
      · right; exact ⟨c', hl, hm⟩

theorem keys_bound {b : Bitmap} (h : WF b) : ∀ p ∈ b, ∀ v ∈ p.2.elems, v < chunk :=
  fun p hp v hv => (conOk_elems (h.2 p hp).2).2.1 v hv

theorem lookup_ok {b : Bitmap} (h : WF b) {k : Nat} {c : Con} (hl : lookup b k = some c) : ConOk c ∧ k < chunk := by
  induction b with
  | nil => simp [lookup] at hl
  | cons p rest ih =>
    obtain ⟨k', c'⟩ := p
    simp only [lookup] at hl
    split at hl
    · rename_i he; simp only [Option.some.injEq] at hl; subst hl
      have := h.2 (k', c') (by simp); rw [he]; exact ⟨this.2, this.1⟩
    · exact ih ⟨strict_cons h.1, fun q hq => h.2 q (by simp [hq])⟩ hl

theorem contents_strict {b : Bitmap} (h : WF b) : Strict (contents b) := by
  induction b with
  | nil => exact List.Pairwise.nil
  | cons p rest ih =>
    obtain ⟨k, c⟩ := p
    have hrest : WF rest := ⟨strict_cons h.1, fun q hq => h.2 q (by simp [hq])⟩
    have hc := conOk_elems (h.2 (k, c) (by simp)).2
    have hkr : ∀ k' ∈ keys rest, k < k' := strict_head h.1
    simp only [contents, List.flatMap_cons, Strict]
    rw [List.pairwise_append]
    refine ⟨?_, ih hrest, fun a ha z hz => ?_⟩
    · rw [List.pairwise_map]; exact List.Pairwise.imp (fun h => by omega) hc.1
    · simp only [List.mem_map] at ha
      obtain ⟨v, hv, rfl⟩ := ha
      have hvb := hc.2.1 v hv
      have hz' : z ∈ contents rest := hz
      rw [mem_contents rest (keys_bound hrest) hrest.1] at hz'
      obtain ⟨c', hl, _⟩ := hz'
      have := hkr _ (lookup_mem_keys hl)
      have : (k + 1) * chunk ≤ z := by
        have := Nat.div_add_mod z chunk
        unfold chunk at *; omega
      unfold chunk at *; omega

theorem contents_ext {a b : Bitmap} (ha : WF a) (hb : WF b) (h : ∀ y, y ∈ contents a ↔ y ∈ contents b) :
    contents a = contents b := strict_ext _ _ (contents_strict ha) (contents_strict hb) h

theorem contains_spec {b : Bitmap} (h : WF b) (x : Nat) : contains b x = decide (x ∈ contents b) := by
  have hm := mem_contents b (keys_bound h) h.1 x
  unfold contains
  by_cases hx : x ∈ contents b
  · obtain ⟨c, hl, hc⟩ := hm.1 hx
    simp [hl, hc, hx]
  · simp only [hx, decide_false]
    split
    · rename_i c hl
      simp only [decide_eq_false_iff_not]
      exact fun hc => hx (hm.2 ⟨c, hl, hc⟩)
    · rfl

theorem cardinality_spec (b : Bitmap) : cardinality b = (contents b).length := by
  induction b with
  | nil => rfl
  | cons p rest ih =>
    simp only [cardinality, contents, List.map_cons, List.sum_cons, List.flatMap_cons, List.length_append,
      List.length_map] at ih ⊢
    rw [ih]; rfl

theorem strict_nodup {l : List Nat} (h : Strict l) : l.Nodup := List.Pairwise.imp (fun h => Nat.ne_of_lt h) h

theorem fromSet_ok {vs : List Nat} (hs : Strict vs) (hb : ∀ v ∈ vs, v < chunk) (hn : vs ≠ []) :
    ConOk (fromSet vs) ∧ (fromSet vs).elems = vs := by
  unfold fromSet
  split
  · exact ⟨⟨hs, hb, by assumption⟩, rfl⟩
  · exact ⟨⟨hs, hb, hn, by omega⟩, rfl⟩

theorem flatten_ok {c : Con} (h : ConOk c) : ConOk (flatten c) ∧ (flatten c).elems = c.elems ∧ (flatten c).isRun = false := by
  cases c with
  | arr vs => exact ⟨h, rfl, rfl⟩
  | bits vs => exact ⟨h, rfl, rfl⟩
  | runs rs =>
    have he := conOk_elems h
    have hf := fromSet_ok he.1 he.2.1 he.2.2
    refine ⟨hf.1, hf.2, ?_⟩
    simp only [flatten, fromSet]; split <;> rfl

theorem sortedInsert_spec (x : Nat) : ∀ vs : List Nat, Strict vs →
    Strict (sortedInsert x vs) ∧ (∀ y, y ∈ sortedInsert x vs ↔ y = x ∨ y ∈ vs) ∧
      (x ∉ vs → (sortedInsert x vs).length = vs.length + 1)
  | [], _ => by simp [sortedInsert, Strict]
  | y :: ys, h => by
    unfold sortedInsert
    split
    · rename_i hxy
      refine ⟨List.pairwise_cons.2 ⟨fun z hz => ?_, h⟩, fun z => by simp, fun _ => by simp⟩
      rcases List.mem_cons.1 hz with e | e
      · omega
      · have := strict_head h z e; omega
    · split
      · rename_i _ hxy
        subst hxy
        exact ⟨h, fun z => by simp, fun hn => absurd (by simp) hn⟩
      · rename_i h1 h2
        have ih := sortedInsert_spec x ys (strict_cons h)
        refine ⟨List.pairwise_cons.2 ⟨fun z hz => ?_, ih.1⟩, fun z => ?_, fun hn => ?_⟩
        · rcases (ih.2.1 z).1 hz with e | e
          · omega
          · exact strict_head h z e
        · simp only [List.mem_cons, ih.2.1 z]; grind
        · simp only [List.length_cons]
          rw [ih.2.2 (fun hm => hn (List.mem_cons_of_mem _ hm))]

theorem conAdd_spec {c : Con} (h : ConOk c) {x : Nat} (hx : x < chunk) :
    ConOk (conAdd c x).1 ∧ (∀ y, y ∈ (conAdd c x).1.elems ↔ y = x ∨ y ∈ c.elems) ∧
      ((conAdd c x).2 = true ↔ x ∉ c.elems) := by
  have hf := flatten_ok h
  unfold conAdd
  split
  · rename_i vs hv
    rw [hv] at hf
    have hvs : vs = c.elems := hf.2.1
    have hok : ConOk (Con.arr vs) := hf.1
    have hsi := sortedInsert_spec x vs hok.1
    split
    · rename_i hm
      refine ⟨hok, fun y => ?_, by simp [← hvs, hm]⟩
      show y ∈ vs ↔ y = x ∨ y ∈ c.elems
      rw [← hvs]
      exact ⟨fun hy => Or.inr hy, fun hy => hy.elim (fun e => e ▸ hm) id⟩
    · rename_i hm
      split
      · rename_i hl
        refine ⟨⟨hsi.1, fun v hv' => ?_, ?_⟩, fun y => ?_, by simp [← hvs, hm]⟩
        · rcases (hsi.2.1 v).1 hv' with e | e
          · omega
          · exact hok.2.1 v e
        · rw [hsi.2.2 hm]; omega
        · show y ∈ sortedInsert x vs ↔ _; rw [hsi.2.1 y, hvs]
      · rename_i hl
        refine ⟨⟨hsi.1, fun v hv' => ?_, ?_, ?_⟩, fun y => ?_, by simp [← hvs, hm]⟩
        · rcases (hsi.2.1 v).1 hv' with e | e
          · omega
          · exact hok.2.1 v e
        · intro e; have := (hsi.2.1 x).2 (Or.inl rfl); rw [e] at this; simp at this
        · rw [hsi.2.2 hm]; unfold arrayMax at *; omega
        · show y ∈ sortedInsert x vs ↔ _; rw [hsi.2.1 y, hvs]
  · rename_i vs hv
    rw [hv] at hf
    have hvs : vs = c.elems := hf.2.1
    have hok : ConOk (Con.bits vs) := hf.1
    have hsi := sortedInsert_spec x vs hok.1
    split
    · rename_i hm
      refine ⟨hok, fun y => ?_, by simp [← hvs, hm]⟩
      show y ∈ vs ↔ y = x ∨ y ∈ c.elems
      rw [← hvs]
      exact ⟨fun hy => Or.inr hy, fun hy => hy.elim (fun e => e ▸ hm) id⟩
    · rename_i hm
      refine ⟨⟨hsi.1, fun v hv' => ?_, ?_⟩, fun y => ?_, by simp [← hvs, hm]⟩
      · rcases (hsi.2.1 v).1 hv' with e | e
        · omega
        · exact hok.2.1 v e
      · rw [hsi.2.2 hm]; have := hok.2.2; omega
      · show y ∈ sortedInsert x vs ↔ _; rw [hsi.2.1 y, hvs]
  · rename_i rs hv
    rw [hv] at hf
    simp [Con.isRun] at hf

theorem conRemove_spec {c : Con} (h : ConOk c) (x : Nat) :
    ((conRemove c x).1.card = 0 ∨ ConOk (conRemove c x).1) ∧ (∀ y, y ∈ (conRemove c x).1.elems ↔ y ≠ x ∧ y ∈ c.elems) ∧
      ((conRemove c x).2 = true ↔ x ∈ c.elems) := by
  unfold conRemove
  split
  · rename_i hm
    have hf := flatten_ok h
    split
    · rename_i vs hv
      rw [hv] at hf
      have hvs : vs = c.elems := hf.2.1
      have hok : ConOk (Con.arr vs) := hf.1
      have hnd := strict_nodup hok.1
      have hmv : x ∈ vs := by rw [hvs]; exact hm
      refine ⟨?_, fun y => by show y ∈ vs.erase x ↔ _; rw [List.Nodup.mem_erase_iff hnd, hvs], by simp [hm]⟩
      by_cases he : vs.erase x = []
      · left; simp [Con.card, Con.elems, he]
      · right
        refine ⟨List.Pairwise.sublist List.erase_sublist hok.1, fun v hv' => hok.2.1 v (List.erase_sublist.subset hv'), he, ?_⟩
        rw [List.length_erase_of_mem hmv]; have := hok.2.2.2; omega
    · rename_i vs hv
      rw [hv] at hf
      have hvs : vs = c.elems := hf.2.1
      have hok : ConOk (Con.bits vs) := hf.1
      have hnd := strict_nodup hok.1
      have hmv : x ∈ vs := by rw [hvs]; exact hm
      have hlen := List.length_erase_of_mem hmv
      have hs' : Strict (vs.erase x) := List.Pairwise.sublist List.erase_sublist hok.1
      have hb' : ∀ v ∈ vs.erase x, v < chunk := fun v hv' => hok.2.1 v (List.erase_sublist.subset hv')
      refine ⟨Or.inr ?_, fun y => ?_, by simp [hm]⟩
      · split
        · rename_i hle
          refine ⟨hs', hb', fun e => ?_, hle⟩
          rw [e] at hlen; simp at hlen; have := hok.2.2; unfold arrayMax at *; omega
        · rename_i hle
          exact ⟨hs', hb', by omega⟩
      · have : y ∈ vs.erase x ↔ y ≠ x ∧ y ∈ c.elems := by rw [List.Nodup.mem_erase_iff hnd, hvs]
        split <;> exact this
    · rename_i rs hv
      rw [hv] at hf
      simp [Con.isRun] at hf
  · rename_i hm
    refine ⟨Or.inr h, fun y => ⟨fun hy => ⟨fun e => hm (e ▸ hy), hy⟩, fun hy => hy.2⟩, by simp [hm]⟩

theorem lookup_none_of_lt : ∀ {b : Bitmap} {k : Nat}, (∀ k' ∈ keys b, k < k') → lookup b k = none
  | [], _, _ => rfl
  | (k', c) :: rest, k, h => by
    simp only [lookup]
    have := h k' (by simp [keys])
    simp only [show ¬ k = k' from by omega, ↓reduceIte]
    exact lookup_none_of_lt (fun k2 hk2 => h k2 (by simp [keys] at hk2 ⊢; right; exact hk2))

def newCon (b : Bitmap) (k lo : Nat) : Con :=
  match lookup b k with
  | none => Con.arr [lo]
  | some c => (conAdd c lo).1

def addFlag (b : Bitmap) (k lo : Nat) : Bool :=
  match lookup b k with
  | none => true
  | some c => (conAdd c lo).2

theorem lookup_cons_self (k : Nat) (c : Con) (rest : Bitmap) : lookup ((k, c) :: rest) k = some c := by
  simp [lookup]

theorem lookup_cons_ne {k k' : Nat} (c : Con) (rest : Bitmap) (h : k' ≠ k) : lookup ((k, c) :: rest) k' = lookup rest k' := by
  simp [lookup, h]

theorem singleton_ok {k lo : Nat} (hk : k < chunk) (hlo : lo < chunk) : k < chunk ∧ ConOk (Con.arr [lo]) :=
  ⟨hk, List.pairwise_singleton _ _, by simp [hlo], by simp, by simp [arrayMax]⟩

theorem bmAdd_spec : ∀ (b : Bitmap) (k lo : Nat), WF b → k < chunk → lo < chunk →
    WF (bmAdd b k lo).1 ∧ keys (bmAdd b k lo).1 = sortedInsert k (keys b) ∧
      lookup (bmAdd b k lo).1 k = some (newCon b k lo) ∧
      (∀ k', k' ≠ k → lookup (bmAdd b k lo).1 k' = lookup b k') ∧
      (bmAdd b k lo).2 = addFlag b k lo
  | [], k, lo, _, hk, hlo => by
    refine ⟨⟨List.pairwise_singleton _ _, fun p hp => ?_⟩, rfl, ?_, fun k' hk' => ?_, rfl⟩
    · simp only [bmAdd, List.mem_singleton] at hp; subst hp; exact singleton_ok hk hlo
    · simp [bmAdd, lookup, newCon]
    · simp [bmAdd, lookup, hk']
  | (k1, c1) :: rest, k, lo, hw, hk, hlo => by
    have hrest : WF rest := ⟨strict_cons hw.1, fun q hq => hw.2 q (by simp [hq])⟩
    have hkr : ∀ k' ∈ keys rest, k1 < k' := strict_head hw.1
    have hc1 := hw.2 (k1, c1) (by simp)
    unfold bmAdd
    split
    · rename_i hlt
      have hnone : lookup ((k1, c1) :: rest) k = none := lookup_none_of_lt (fun k' hk' => by
        simp only [keys, List.map_cons, List.mem_cons] at hk'
        rcases hk' with e | e
        · omega
        · have := hkr k' e; omega)
      refine ⟨⟨?_, fun p hp => ?_⟩, ?_, ?_, fun k' hk' => ?_, ?_⟩
      · show Strict (k :: k1 :: keys rest)
        refine List.pairwise_cons.2 ⟨fun z hz => ?_, hw.1⟩
        rcases List.mem_cons.1 hz with e | e
        · omega
        · have := hkr z e; omega
      · rcases List.mem_cons.1 hp with e | e
        · subst e; exact singleton_ok hk hlo
        · exact hw.2 p e
      · show k :: k1 :: keys rest = sortedInsert k (k1 :: keys rest)
        simp [sortedInsert, hlt]
      · rw [lookup_cons_self]; simp [newCon, hnone]
      · rw [lookup_cons_ne _ _ hk']
      · simp [addFlag, hnone]
    · split
      · rename_i hge he
        subst he
        have ha := conAdd_spec hc1.2 hlo
        refine ⟨⟨hw.1, fun p hp => ?_⟩, by simp [keys, sortedInsert], ?_, fun k' hk' => ?_, ?_⟩
        · rcases List.mem_cons.1 hp with e | e
          · subst e; exact ⟨hc1.1, ha.1⟩
          · exact hw.2 p (List.mem_cons_of_mem _ e)
        · rw [lookup_cons_self]; simp [newCon, lookup_cons_self]
        · rw [lookup_cons_ne _ _ hk', lookup_cons_ne _ _ hk']
        · simp [addFlag, lookup_cons_self]
      · rename_i hge hne
        have ih := bmAdd_spec rest k lo hrest hk hlo
        have hlook : lookup ((k1, c1) :: rest) k = lookup rest k := lookup_cons_ne _ _ hne
        refine ⟨⟨?_, fun p hp => ?_⟩, ?_, ?_, fun k' hk' => ?_, ?_⟩
        · show Strict (k1 :: keys (bmAdd rest k lo).1)
          rw [ih.2.1]
          refine List.pairwise_cons.2 ⟨fun z hz => ?_, (sortedInsert_spec k (keys rest) hrest.1).1⟩
          rcases ((sortedInsert_spec k (keys rest) hrest.1).2.1 z).1 hz with e | e
          · omega
          · exact hkr z e
        · rcases List.mem_cons.1 hp with e | e
          · subst e; exact hc1
          · exact ih.1.2 p e
        · show k1 :: keys (bmAdd rest k lo).1 = sortedInsert k (k1 :: keys rest)
          rw [ih.2.1]
          simp only [sortedInsert, show ¬ k < k1 from by omega, show ¬ k = k1 from by omega, ↓reduceIte]
        · rw [lookup_cons_ne _ _ hne, ih.2.2.1]
          simp [newCon, hlook]
        · by_cases e : k' = k1
          · subst e; rw [lookup_cons_self, lookup_cons_self]
          · rw [lookup_cons_ne _ _ e, lookup_cons_ne _ _ e, ih.2.2.2.1 k' hk']
        · rw [ih.2.2.2.2]; simp [addFlag, hlook]

theorem lookup_of_wf_mem {b : Bitmap} (h : WF b) {k : Nat} {c : Con} (hm : (k, c) ∈ b) : lookup b k = some c := by
  induction b with
  | nil => simp at hm
  | cons p rest ih =>
    obtain ⟨k1, c1⟩ := p
    simp only [lookup]
    rcases List.mem_cons.1 hm with e | e
    · simp only [Prod.mk.injEq] at e; obtain ⟨rfl, rfl⟩ := e; simp
    · have hk : k ∈ keys rest := by simp only [keys, List.mem_map]; exact ⟨(k, c), e, rfl⟩
      have := strict_head h.1 k hk
      rw [ite_eq_right (by omega)]
      exact ih ⟨strict_cons h.1, fun q hq => h.2 q (by simp [hq])⟩ e

theorem add_spec (b : Bitmap) (x : Nat) (h : WF b) (hx : x < 2 ^ 32) :
    WF (add b x).1 ∧ (∀ y, y ∈ contents (add b x).1 ↔ y = x ∨ y ∈ contents b) ∧
      ((add b x).2 = true ↔ x ∉ contents b) := by
  have hk : x / chunk < chunk := by unfold chunk; omega
  have hlo : x % chunk < chunk := Nat.mod_lt _ (by decide)
  have hs := bmAdd_spec b (x / chunk) (x % chunk) h hk hlo
  have hxm := mem_contents b (keys_bound h) h.1 x
  unfold add
  refine ⟨hs.1, fun y => ?_, ?_⟩
  · rw [mem_contents _ (keys_bound hs.1) hs.1.1, mem_contents b (keys_bound h) h.1]
    by_cases hy : y / chunk = x / chunk
    · rw [hy, hs.2.2.1]
      have hyx : y = x ↔ y % chunk = x % chunk := by
        constructor
        · intro e; rw [e]
        · intro e; have := Nat.div_add_mod y chunk; have := Nat.div_add_mod x chunk; rw [hy] at *; omega
      unfold newCon
      split
      · rename_i hn
        simp only [Option.some.injEq, exists_eq_left', Con.elems, List.mem_singleton, hn, reduceCtorEq, false_and,
          exists_false, or_false]
        exact hyx.symm
      · rename_i c hc
        have hca := conAdd_spec (lookup_ok h hc).1 hlo
        simp only [Option.some.injEq, exists_eq_left', hc]
        rw [hca.2.1, hyx]
    · rw [hs.2.2.2.1 _ hy]
      constructor
      · intro hm; right; exact hm
      · intro hm
        rcases hm with e | e
        · exact absurd (by rw [e]) hy
        · exact e
  · rw [hs.2.2.2.2, hxm]
    unfold addFlag
    split
    · rename_i hn; simp [hn]
    · rename_i c hc
      have hca := conAdd_spec (lookup_ok h hc).1 hlo
      rw [hca.2.2]; simp [hc]

def remCon (b : Bitmap) (k lo : Nat) : Option Con :=
  match lookup b k with
  | none => none
  | some c => if (conRemove c lo).1.card = 0 then none else some (conRemove c lo).1

def remFlag (b : Bitmap) (k lo : Nat) : Bool :=
  match lookup b k with
  | none => false
  | some c => (conRemove c lo).2

theorem lookup_not_mem : ∀ {b : Bitmap} {k : Nat}, k ∉ keys b → lookup b k = none
  | [], _, _ => rfl
  | (k', c) :: rest, k, h => by
    simp only [keys, List.map_cons, List.mem_cons, not_or] at h
    rw [lookup_cons_ne _ _ h.1]
    exact lookup_not_mem h.2

theorem bmRemove_spec : ∀ (b : Bitmap) (k lo : Nat), WF b →
    WF (bmRemove b k lo).1 ∧ (keys (bmRemove b k lo).1).Sublist (keys b) ∧
      lookup (bmRemove b k lo).1 k = remCon b k lo ∧
      (∀ k', k' ≠ k → lookup (bmRemove b k lo).1 k' = lookup b k') ∧
      (bmRemove b k lo).2 = remFlag b k lo
  | [], k, lo, _ => by
    refine ⟨⟨List.Pairwise.nil, fun p hp => by simp [bmRemove] at hp⟩, by simp [bmRemove, keys], rfl, fun _ _ => rfl, rfl⟩
  | (k1, c1) :: rest, k, lo, hw => by
    have hrest : WF rest := ⟨strict_cons hw.1, fun q hq => hw.2 q (by simp [hq])⟩
    have hkr : ∀ k' ∈ keys rest, k1 < k' := strict_head hw.1
    have hc1 := hw.2 (k1, c1) (by simp)
    unfold bmRemove
    split
    · rename_i he
      subst he
      have hr := conRemove_spec hc1.2 lo
      have hnone : lookup rest k = none := lookup_not_mem (fun hm => by have := hkr k hm; omega)
      split
      · rename_i hz
        refine ⟨hrest, List.Sublist.cons _ (List.Sublist.refl _), ?_, fun k' hk' => ?_, ?_⟩
        · simp [hnone, remCon, lookup_cons_self, hz]
        · rw [lookup_cons_ne _ _ hk']
        · simp [remFlag, lookup_cons_self]
      · rename_i hz
        have hok : ConOk (conRemove c1 lo).1 := by
          rcases hr.1 with h0 | h0
          · exact absurd h0 hz
          · exact h0
        refine ⟨⟨hw.1, fun p hp => ?_⟩, List.Sublist.refl _, ?_, fun k' hk' => ?_, ?_⟩
        · rcases List.mem_cons.1 hp with e | e
          · subst e; exact ⟨hc1.1, hok⟩
          · exact hw.2 p (List.mem_cons_of_mem _ e)
        · simp [remCon, lookup_cons_self, hz]
        · rw [lookup_cons_ne _ _ hk', lookup_cons_ne _ _ hk']
        · simp [remFlag, lookup_cons_self]
    · split
      · rename_i hne hlt
        have hnone : lookup ((k1, c1) :: rest) k = none := lookup_none_of_lt (fun k' hk' => by
          simp only [keys, List.map_cons, List.mem_cons] at hk'
          rcases hk' with e | e
          · omega
          · have := hkr k' e; omega)
        refine ⟨hw, List.Sublist.refl _, ?_, fun k' _ => rfl, ?_⟩
        · rw [hnone]; simp [remCon, hnone]
        · simp [remFlag, hnone]
      · rename_i hne hlt
        have ih := bmRemove_spec rest k lo hrest
        have hlook : lookup ((k1, c1) :: rest) k = lookup rest k := lookup_cons_ne _ _ hne
        refine ⟨⟨?_, fun p hp => ?_⟩, ?_, ?_, fun k' hk' => ?_, ?_⟩
        · show Strict (k1 :: keys (bmRemove rest k lo).1)
          refine List.pairwise_cons.2 ⟨fun z hz => hkr z (ih.2.1.subset hz), ih.1.1⟩
        · rcases List.mem_cons.1 hp with e | e
          · subst e; exact hc1
          · exact ih.1.2 p e
        · exact List.Sublist.cons_cons _ ih.2.1
        · rw [lookup_cons_ne _ _ hne, ih.2.2.1]; simp [remCon, hlook]
        · by_cases e : k' = k1
          · subst e; rw [lookup_cons_self, lookup_cons_self]
          · rw [lookup_cons_ne _ _ e, lookup_cons_ne _ _ e, ih.2.2.2.1 k' hk']
        · rw [ih.2.2.2.2]; simp [remFlag, hlook]

theorem remove_spec (b : Bitmap) (x : Nat) (h : WF b) :
    WF (remove b x).1 ∧ (∀ y, y ∈ contents (remove b x).1 ↔ y ≠ x ∧ y ∈ contents b) ∧
      ((remove b x).2 = true ↔ x ∈ contents b) := by
  have hs := bmRemove_spec b (x / chunk) (x % chunk) h
  have hxm := mem_contents b (keys_bound h) h.1 x
  unfold remove
  refine ⟨hs.1, fun y => ?_, ?_⟩
  · rw [mem_contents _ (keys_bound hs.1) hs.1.1, mem_contents b (keys_bound h) h.1]
    by_cases hy : y / chunk = x / chunk
    · rw [hy, hs.2.2.1]
      have hyx : y = x ↔ y % chunk = x % chunk := by
        constructor
        · intro e; rw [e]
        · intro e; have := Nat.div_add_mod y chunk; have := Nat.div_add_mod x chunk; rw [hy] at *; omega
      unfold remCon
      split
      · rename_i hn
        simp [hn]
      · rename_i c hc
        have hr := conRemove_spec (lookup_ok h hc).1 (x % chunk)
        split
        · rename_i hz
          simp only [reduceCtorEq, false_and, exists_false, false_iff, not_and, hc, Option.some.injEq, exists_eq_left']
          intro hne hm
          have : y % chunk ∈ (conRemove c (x % chunk)).1.elems := (hr.2.1 _).2 ⟨fun e => hne (hyx.2 e), hm⟩
          unfold Con.card at hz
          rw [List.length_eq_zero_iff] at hz
          rw [hz] at this; simp at this
        · simp only [Option.some.injEq, exists_eq_left', hc]
          rw [hr.2.1]
          exact ⟨fun hh => ⟨fun e => hh.1 (hyx.1 e), hh.2⟩, fun hh => ⟨fun e => hh.1 (hyx.2 e), hh.2⟩⟩
    · rw [hs.2.2.2.1 _ hy]
      constructor
      · intro hm; exact ⟨fun e => hy (by rw [e]), hm⟩
      · intro hm; exact hm.2
  · rw [hs.2.2.2.2, hxm]
    unfold remFlag
    split
    · rename_i hn; simp [hn]
    · rename_i c hc
      have hr := conRemove_spec (lookup_ok h hc).1 (x % chunk)
      rw [hr.2.2]; simp [hc]

def opProp : Op → Prop → Prop → Prop
  | .and, p, q => p ∧ q
  | .or, p, q => p ∨ q
  | .andnot, p, q => p ∧ ¬ q

theorem setOp_spec (op : Op) {x y : List Nat} (hx : Strict x) (hy : Strict y) :
    Strict (setOp op x y) ∧ (∀ v, v ∈ setOp op x y ↔ opProp op (v ∈ x) (v ∈ y)) := by
  cases op with
  | and => exact ⟨strict_filter hx _, fun v => by simp [setOp, opProp, List.mem_filter]⟩
  | or => have := unionMerge_spec x y hx hy; exact ⟨this.1, fun v => by rw [setOp, this.2 v]; rfl⟩
  | andnot => exact ⟨strict_filter hx _, fun v => by simp [setOp, opProp, List.mem_filter]⟩

theorem conOp_spec (op : Op) {a b : Con} (ha : ConOk a) (hb : ConOk b) :
    (∀ v, v ∈ (conOp op a b).elems ↔ opProp op (v ∈ a.elems) (v ∈ b.elems)) ∧
      ((conOp op a b).card = 0 ∨ ConOk (conOp op a b)) := by
  have ea := conOk_elems ha
  have eb := conOk_elems hb
  have bound : ∀ l : List Nat, (∀ v, v ∈ l → opProp op (v ∈ a.elems) (v ∈ b.elems)) → ∀ v ∈ l, v < chunk := by
    intro l hl v hv
    have := hl v hv
    cases op with
    | and => exact ea.2.1 v this.1
    | or => rcases this with h | h; exact ea.2.1 v h; exact eb.2.1 v h
    | andnot => exact ea.2.1 v this.1
  have finish : ∀ c : Con, (∀ v, v ∈ c.elems ↔ opProp op (v ∈ a.elems) (v ∈ b.elems)) → Strict c.elems →
      (∀ vs, c = .arr vs → vs.length ≤ arrayMax) → (∀ vs, c = .bits vs → arrayMax < vs.length) → (∀ rs, c ≠ .runs rs) →
      (∀ v, v ∈ c.elems ↔ opProp op (v ∈ a.elems) (v ∈ b.elems)) ∧ (c.card = 0 ∨ ConOk c) := by
    intro c hm hs harr hbits hrun
    refine ⟨hm, ?_⟩
    by_cases hz : c.card = 0
    · exact Or.inl hz
    · right
      have hne : c.elems ≠ [] := by intro e; apply hz; unfold Con.card; rw [e]; rfl
      have hbd := bound c.elems (fun v hv => (hm v).1 hv)
      cases c with
      | arr vs => exact ⟨hs, hbd, hne, harr vs rfl⟩
      | bits vs => exact ⟨hs, hbd, hbits vs rfl⟩
      | runs rs => exact absurd rfl (hrun rs)
  unfold conOp
  split
  · rename_i x y
    have hso := setOp_spec op ea.1 eb.1
    split
    · rename_i hl
      exact finish _ hso.2 hso.1 (fun _ e => by cases e) (fun _ e => by cases e; exact hl) (fun _ e => by cases e)
    · rename_i hl
      exact finish _ hso.2 hso.1 (fun _ e => by cases e; omega) (fun _ e => by cases e) (fun _ e => by cases e)
  · rename_i hnot
    cases op with
    | and =>
      simp only
      split
      · rename_i x
        have hle : (x.filter fun v => decide (v ∈ b.elems)).length ≤ arrayMax := by
          have := List.length_filter_le (fun v => decide (v ∈ b.elems)) x; have := ha.2.2.2; omega
        exact finish _ (fun v => by simp [Con.elems.eq_1, Con.elems.eq_2, Con.elems.eq_3, opProp, List.mem_filter]) (strict_filter ea.1 _)
          (fun _ e => by cases e; exact hle) (fun _ e => by cases e) (fun _ e => by cases e)
      · rename_i ha'
        split
        · rename_i y
          have hle : (y.filter fun v => decide (v ∈ a.elems)).length ≤ arrayMax := by
            have := List.length_filter_le (fun v => decide (v ∈ a.elems)) y; have := hb.2.2.2; omega
          exact finish _ (fun v => by simp [Con.elems.eq_1, Con.elems.eq_2, Con.elems.eq_3, opProp, List.mem_filter, And.comm]) (strict_filter eb.1 _)
            (fun _ e => by cases e; exact hle) (fun _ e => by cases e) (fun _ e => by cases e)
        · unfold fromSet
          split
          · rename_i hl
            exact finish _ (fun v => by simp [Con.elems.eq_1, Con.elems.eq_2, Con.elems.eq_3, opProp, List.mem_filter]) (strict_filter ea.1 _)
              (fun _ e => by cases e) (fun _ e => by cases e; exact hl) (fun _ e => by cases e)
          · rename_i hl
            exact finish _ (fun v => by simp [Con.elems.eq_1, Con.elems.eq_2, Con.elems.eq_3, opProp, List.mem_filter]) (strict_filter ea.1 _)
              (fun _ e => by cases e; omega) (fun _ e => by cases e) (fun _ e => by cases e)
    | or =>
      simp only
      have hu := unionMerge_spec a.elems b.elems ea.1 eb.1
      unfold fromSet
      split
      · rename_i hl
        exact finish _ (fun v => by rw [Con.elems, hu.2 v]; rfl) hu.1
          (fun _ e => by cases e) (fun _ e => by cases e; exact hl) (fun _ e => by cases e)
      · rename_i hl
        exact finish _ (fun v => by rw [Con.elems, hu.2 v]; rfl) hu.1
          (fun _ e => by cases e; omega) (fun _ e => by cases e) (fun _ e => by cases e)
    | andnot =>
      simp only
      split
      · rename_i x
        have hle : (x.filter fun v => decide (v ∉ b.elems)).length ≤ arrayMax := by
          have := List.length_filter_le (fun v => decide (v ∉ b.elems)) x; have := ha.2.2.2; omega
        exact finish _ (fun v => by simp [Con.elems.eq_1, Con.elems.eq_2, Con.elems.eq_3, opProp, List.mem_filter]) (strict_filter ea.1 _)
          (fun _ e => by cases e; exact hle) (fun _ e => by cases e) (fun _ e => by cases e)
      · unfold fromSet
        split
        · rename_i hl
          exact finish _ (fun v => by simp [Con.elems.eq_1, Con.elems.eq_2, Con.elems.eq_3, opProp, List.mem_filter]) (strict_filter ea.1 _)
            (fun _ e => by cases e) (fun _ e => by cases e; exact hl) (fun _ e => by cases e)
        · rename_i hl
          exact finish _ (fun v => by simp [Con.elems.eq_1, Con.elems.eq_2, Con.elems.eq_3, opProp, List.mem_filter]) (strict_filter ea.1 _)
            (fun _ e => by cases e; omega) (fun _ e => by cases e) (fun _ e => by cases e)

def combLookup (op : Op) : Option Con → Option Con → Option Con
  | some ca, some cb => if (conOp op ca cb).card = 0 then none else some (conOp op ca cb)
  | some ca, none => if op = .and then none else some ca
  | none, some cb => if op = .or then some cb else none
  | none, none => none

theorem unionMerge_nil_right : ∀ l : List Nat, unionMerge l [] = l
  | [] => by simp [unionMerge]
  | _ :: _ => by simp [unionMerge]

theorem combine_keys (op : Op) : ∀ a b : Bitmap, (keys (combine op a b)).Sublist (unionMerge (keys a) (keys b))
  | [], [] => by simp [combine, keys, unionMerge]
  | (ka, ca) :: ra, [] => by
    rw [combine]
    split
    · exact List.nil_sublist _
    · have ih := combine_keys op ra []
      simp only [keys, List.map_cons, List.map_nil, unionMerge_nil_right] at ih ⊢
      exact List.Sublist.cons_cons _ ih
  | [], (kb, cb) :: rb => by
    rw [combine]
    split
    · have ih := combine_keys op [] rb
      simp only [keys, List.map_cons, List.map_nil, unionMerge] at ih ⊢
      exact List.Sublist.cons_cons _ ih
    · exact List.nil_sublist _
  | (ka, ca) :: ra, (kb, cb) :: rb => by
    rw [combine]
    split
    · rename_i hlt
      have ih := combine_keys op ra ((kb, cb) :: rb)
      simp only [keys, List.map_cons, unionMerge, hlt, ↓reduceIte] at ih ⊢
      split
      · simp only [List.nil_append]; exact List.Sublist.cons _ ih
      · simp only [List.cons_append, List.nil_append, List.map_cons]; exact List.Sublist.cons_cons _ ih
    · split
      · rename_i hge hlt
        have ih := combine_keys op ((ka, ca) :: ra) rb
        simp only [keys, List.map_cons, unionMerge, hge, hlt, ↓reduceIte] at ih ⊢
        split
        · simp only [List.cons_append, List.nil_append, List.map_cons]; exact List.Sublist.cons_cons _ ih
        · simp only [List.nil_append]; exact List.Sublist.cons _ ih
      · rename_i hge hle
        have e : ka = kb := by omega
        subst e
        have ih := combine_keys op ra rb
        simp only [keys, List.map_cons, unionMerge, Nat.lt_irrefl, ↓reduceIte] at ih ⊢
        unfold keep
        split
        · simp only [List.nil_append]; exact List.Sublist.cons _ ih
        · simp only [List.cons_append, List.nil_append, List.map_cons]; exact List.Sublist.cons_cons _ ih
termination_by a b => a.length + b.length

theorem combine_keys_strict (op : Op) {a b : Bitmap} (ha : Strict (keys a)) (hb : Strict (keys b)) :
    Strict (keys (combine op a b)) :=
  List.Pairwise.sublist (combine_keys op a b) (unionMerge_spec _ _ ha hb).1

theorem combine_not_mem (op : Op) {a b : Bitmap} (ha : Strict (keys a)) (hb : Strict (keys b)) {k : Nat}
    (h1 : k ∉ keys a) (h2 : k ∉ keys b) : lookup (combine op a b) k = none := by
  apply lookup_not_mem
  intro hm
  have := ((unionMerge_spec _ _ ha hb).2 k).1 ((combine_keys op a b).subset hm)
  rcases this with h | h
  · exact h1 h
  · exact h2 h

theorem lookup_combine (op : Op) : ∀ a b : Bitmap, Strict (keys a) → Strict (keys b) →
    ∀ k, lookup (combine op a b) k = combLookup op (lookup a k) (lookup b k)
  | [], [], _, _, k => by simp [combine, lookup, combLookup]
  | (ka, ca) :: ra, [], ha, hb, k => by
    rw [combine]
    split
    · rename_i hop
      subst hop
      show none = combLookup .and (lookup ((ka, ca) :: ra) k) none
      cases lookup ((ka, ca) :: ra) k <;> rfl
    · rename_i hop
      have ih := lookup_combine op ra [] (strict_cons ha) hb
      by_cases e : k = ka
      · subst e
        rw [lookup_cons_self, lookup_cons_self]
        simp [lookup, combLookup, hop]
      · rw [lookup_cons_ne _ _ e, lookup_cons_ne _ _ e, ih k]
  | [], (kb, cb) :: rb, ha, hb, k => by
    rw [combine]
    split
    · rename_i hop
      have ih := lookup_combine op [] rb ha (strict_cons hb)
      by_cases e : k = kb
      · subst e
        rw [lookup_cons_self, lookup_cons_self]
        simp [lookup, combLookup, hop]
      · rw [lookup_cons_ne _ _ e, lookup_cons_ne _ _ e, ih k]
    · rename_i hop
      show none = combLookup op none (lookup ((kb, cb) :: rb) k)
      cases lookup ((kb, cb) :: rb) k <;> simp [combLookup, hop]
  | (ka, ca) :: ra, (kb, cb) :: rb, ha, hb, k => by
    have hra := strict_cons ha
    have hrb := strict_cons hb
    have har : ∀ k' ∈ keys ra, ka < k' := strict_head ha
    have hbr : ∀ k' ∈ keys rb, kb < k' := strict_head hb
    rw [combine]
    split
    · rename_i hlt
      have ih := lookup_combine op ra ((kb, cb) :: rb) hra hb
      by_cases e : k = ka
      · subst e
        have hnb : lookup ((kb, cb) :: rb) k = none := lookup_none_of_lt (fun k' hk' => by
          simp only [keys, List.map_cons, List.mem_cons] at hk'
          rcases hk' with h | h
          · omega
          · have := hbr k' h; omega)
        rw [lookup_cons_self, hnb]
        split
        · rename_i hop
          subst hop
          simp only [List.nil_append]
          rw [combine_not_mem _ hra hb (fun hm => by have := har k hm; omega) (fun hm => by
            simp only [keys, List.map_cons, List.mem_cons] at hm
            rcases hm with h | h
            · omega
            · have := hbr k h; omega)]
          simp [combLookup]
        · rename_i hop
          simp [lookup, combLookup, hop]
      · rw [lookup_cons_ne _ _ e]
        split
        · simp only [List.nil_append]; exact ih k
        · simp only [List.cons_append, List.nil_append]; rw [lookup_cons_ne _ _ e]; exact ih k
    · split
      · rename_i hge hlt
        have ih := lookup_combine op ((ka, ca) :: ra) rb ha hrb
        by_cases e : k = kb
        · subst e
          have hna : lookup ((ka, ca) :: ra) k = none := lookup_none_of_lt (fun k' hk' => by
            simp only [keys, List.map_cons, List.mem_cons] at hk'
            rcases hk' with h | h
            · omega
            · have := har k' h; omega)
          rw [lookup_cons_self, hna]
          split
          · rename_i hop
            simp [lookup, combLookup, hop]
          · rename_i hop
            simp only [List.nil_append]
            rw [combine_not_mem _ ha hrb (fun hm => by
              simp only [keys, List.map_cons, List.mem_cons] at hm
              rcases hm with h | h
              · omega
              · have := har k h; omega) (fun hm => by have := hbr k hm; omega)]
            cases op <;> simp_all [combLookup]
        · rw [lookup_cons_ne _ _ e]
          split
          · simp only [List.cons_append, List.nil_append]; rw [lookup_cons_ne _ _ e]; exact ih k
          · simp only [List.nil_append]; exact ih k
      · rename_i hge hle
        have e0 : ka = kb := by omega
        subst e0
        have ih := lookup_combine op ra rb hra hrb
        by_cases e : k = ka
        · subst e
          rw [lookup_cons_self, lookup_cons_self]
          unfold keep
          split
          · rename_i hz
            simp only [List.nil_append]
            rw [combine_not_mem _ hra hrb (fun hm => by have := har k hm; omega) (fun hm => by have := hbr k hm; omega)]
            simp [combLookup, hz]
          · rename_i hz
            simp [lookup, combLookup, hz]
        · rw [lookup_cons_ne _ _ e, lookup_cons_ne _ _ e]
          unfold keep
          split
          · simp only [List.nil_append]; exact ih k
          · simp only [List.cons_append, List.nil_append]; rw [lookup_cons_ne _ _ e]; exact ih k
termination_by a b => a.length + b.length

theorem combine_ok (op : Op) : ∀ a b : Bitmap, WF a → WF b → ∀ p ∈ combine op a b, p.1 < chunk ∧ ConOk p.2
  | [], [], _, _ => by simp [combine]
  | (ka, ca) :: ra, [], ha, hb => by
    rw [combine]
    split
    · simp
    · intro p hp
      rcases List.mem_cons.1 hp with e | e
      · subst e; exact ha.2 _ (by simp)
      · exact combine_ok op ra [] ⟨strict_cons ha.1, fun q hq => ha.2 q (by simp [hq])⟩ hb p e
  | [], (kb, cb) :: rb, ha, hb => by
    rw [combine]
    split
    · intro p hp
      rcases List.mem_cons.1 hp with e | e
      · subst e; exact hb.2 _ (by simp)
      · exact combine_ok op [] rb ha ⟨strict_cons hb.1, fun q hq => hb.2 q (by simp [hq])⟩ p e
    · simp
  | (ka, ca) :: ra, (kb, cb) :: rb, ha, hb => by
    have hra : WF ra := ⟨strict_cons ha.1, fun q hq => ha.2 q (by simp [hq])⟩
    have hrb : WF rb := ⟨strict_cons hb.1, fun q hq => hb.2 q (by simp [hq])⟩
    rw [combine]
    split
    · intro p hp
      rcases List.mem_append.1 hp with e | e
      · split at e
        · simp at e
        · simp at e; subst e; exact ha.2 _ (by simp)
      · exact combine_ok op ra _ hra hb p e
    · split
      · intro p hp
        rcases List.mem_append.1 hp with e | e
        · split at e
          · simp at e; subst e; exact hb.2 _ (by simp)
          · simp at e
        · exact combine_ok op _ rb ha hrb p e
      · intro p hp
        rcases List.mem_append.1 hp with e | e
        · unfold keep at e
          split at e
          · simp at e
          · rename_i hz
            simp at e; subst e
            have h1 := ha.2 (ka, ca) (by simp)
            have h2 := hb.2 (kb, cb) (by simp)
            refine ⟨h1.1, ?_⟩
            rcases (conOp_spec op h1.2 h2.2).2 with h0 | h0
            · exact absurd h0 hz
            · exact h0
        · exact combine_ok op ra rb hra hrb p e
termination_by a b => a.length + b.length

theorem combine_spec (op : Op) (a b : Bitmap) (ha : WF a) (hb : WF b) :
    WF (combine op a b) ∧ ∀ y, y ∈ contents (combine op a b) ↔ opProp op (y ∈ contents a) (y ∈ contents b) := by
  have hw : WF (combine op a b) := ⟨combine_keys_strict op ha.1 hb.1, combine_ok op a b ha hb⟩
  refine ⟨hw, fun y => ?_⟩
  rw [mem_contents _ (keys_bound hw) hw.1, mem_contents a (keys_bound ha) ha.1, mem_contents b (keys_bound hb) hb.1,
    lookup_combine op a b ha.1 hb.1]
  cases hla : lookup a (y / chunk) with
  | none =>
    cases hlb : lookup b (y / chunk) with
    | none => cases op <;> simp [combLookup, opProp]
    | some cb => cases op <;> simp [combLookup, opProp]
  | some ca =>
    have hca := (lookup_ok ha hla).1
    cases hlb : lookup b (y / chunk) with
    | none => cases op <;> simp [combLookup, opProp]
    | some cb =>
      have hcb := (lookup_ok hb hlb).1
      have hs := conOp_spec op hca hcb
      simp only [combLookup, Option.some.injEq, exists_eq_left']
      split
      · rename_i hz
        have hempty : (conOp op ca cb).elems = [] := by unfold Con.card at hz; exact List.length_eq_zero_iff.1 hz
        simp only [reduceCtorEq, false_and, exists_false, false_iff]
        intro hp
        have hmem := (hs.1 (y % chunk)).2 hp
        rw [hempty] at hmem
        exact absurd hmem List.not_mem_nil
      · simp only [Option.some.injEq, exists_eq_left']
        exact hs.1 (y % chunk)

theorem combine_contents (op : Op) (a b : Bitmap) (ha : WF a) (hb : WF b) :
    contents (combine op a b) = setOp op (contents a) (contents b) := by
  have hc := combine_spec op a b ha hb
  have hs := setOp_spec op (contents_strict ha) (contents_strict hb)
  exact strict_ext _ _ (contents_strict hc.1) hs.1 (fun y => by rw [hc.2 y, hs.2 y])

theorem andCardinality_spec (a b : Bitmap) (ha : WF a) (hb : WF b) :
    andCardinality a b = ((contents a).filter fun x => decide (x ∈ contents b)).length := by
  unfold andCardinality
  rw [cardinality_spec, combine_contents .and a b ha hb]
  rfl

def RunsGap : Nat → List (Nat × Nat) → Prop
  | _, [] => True
  | free, (s, l) :: rs => free ≤ s ∧ s + l < chunk ∧ RunsGap (s + l + 2) rs

theorem runsGap_ok : ∀ {free : Nat} {rs : List (Nat × Nat)}, RunsGap free rs → RunsOk free rs
  | _, [], _ => trivial
  | _, (s, l) :: rs, ⟨h1, h2, h3⟩ => ⟨h1, h2, runsOk_mono (by omega) (runsGap_ok h3)⟩

theorem runsGap_length : ∀ {free : Nat} {rs : List (Nat × Nat)}, RunsGap free rs → 2 * rs.length ≤ chunk + 1 - free + (if rs = [] then chunk + 1 else 0)
  | _, [], _ => by simp
  | free, (s, l) :: rs, ⟨h1, h2, h3⟩ => by
    have ih := runsGap_length h3
    simp only [List.length_cons, reduceCtorEq, ↓reduceIte, Nat.add_zero]
    split at ih
    · rename_i he; subst he; simp; omega
    · omega

theorem maxRuns_spec : ∀ vs : List Nat, Strict vs → (∀ v ∈ vs, v < chunk) → vs ≠ [] →
    RunsGap 0 (maxRuns vs) ∧ expandRuns (maxRuns vs) = vs ∧ maxRuns vs ≠ [] ∧
      (∀ s l rs, maxRuns vs = (s, l) :: rs → vs.head? = some s)
  | [], _, _, h => absurd rfl h
  | [x], _, hb, _ => by
    have := hb x (by simp)
    refine ⟨⟨Nat.zero_le _, by omega, trivial⟩, by simp [maxRuns, expandRuns, expandRun], by simp [maxRuns], fun s l rs e => ?_⟩
    simp [maxRuns] at e; simp [e.1]
  | x :: y :: ys, hs, hb, _ => by
    have ih := maxRuns_spec (y :: ys) (strict_cons hs) (fun v hv => hb v (List.mem_cons_of_mem _ hv)) (by simp)
    have hxy : x < y := strict_head hs y (by simp)
    have hx := hb x (by simp)
    obtain ⟨⟨s, l⟩, rs, hm⟩ := List.exists_cons_of_ne_nil ih.2.2.1
    have hsy : s = y := by have := ih.2.2.2 s l rs hm; simp at this; exact this.symm
    rw [hm] at ih
    have hgap := ih.1
    simp only [RunsGap] at hgap
    unfold maxRuns
    rw [hm]
    simp only
    split
    · rename_i he
      refine ⟨⟨Nat.zero_le _, by omega, by rw [show x + (l + 1) + 2 = s + l + 2 by omega]; exact hgap.2.2⟩, ?_, by simp, fun s' l' rs' e => ?_⟩
      · have e2 := ih.2.1
        simp only [expandRuns] at e2 ⊢
        rw [← e2]
        unfold expandRun
        rw [List.range_succ_eq_map]
        simp only [List.map_cons, List.map_map, Nat.add_zero, List.cons_append]
        congr 1
        congr 1
        · apply List.map_congr_left; intro i _; simp only [Function.comp]; omega
      · simp at e; simp [e.1]
    · rename_i he
      refine ⟨⟨Nat.zero_le _, by omega, ⟨by omega, hgap.2.1, hgap.2.2⟩⟩, ?_, by simp, fun s' l' rs' e => ?_⟩
      · have e2 := ih.2.1
        simp only [expandRuns] at e2 ⊢
        rw [e2]; simp [expandRun]
      · simp at e; simp [e.1]

theorem optimizeCon_spec {c : Con} (h : ConOk c) : ConOk (optimizeCon c).1 ∧ (optimizeCon c).1.elems = c.elems := by
  have he := conOk_elems h
  have runs_ok : ∀ vs : List Nat, Strict vs → (∀ v ∈ vs, v < chunk) → vs ≠ [] →
      ConOk (Con.runs (maxRuns vs)) ∧ (Con.runs (maxRuns vs)).elems = vs := by
    intro vs hs hb hn
    have hm := maxRuns_spec vs hs hb hn
    have hl := runsGap_length hm.1
    simp only [hm.2.2.1, ↓reduceIte, Nat.add_zero] at hl
    exact ⟨⟨runsGap_ok hm.1, hm.2.2.1, by unfold chunk at *; omega⟩, hm.2.1⟩
  cases c with
  | runs rs =>
    simp only [optimizeCon]
    split <;> split
    all_goals first | exact fromSet_ok he.1 he.2.1 he.2.2 | exact ⟨h, rfl⟩
  | arr vs =>
    simp only [optimizeCon]
    split
    · exact runs_ok vs he.1 he.2.1 he.2.2
    · exact ⟨h, rfl⟩
  | bits vs =>
    simp only [optimizeCon]
    split
    · exact runs_ok vs he.1 he.2.1 he.2.2
    · exact ⟨h, rfl⟩

theorem runOptimize_spec (b : Bitmap) (h : WF b) : WF (runOptimize b).1 ∧ contents (runOptimize b).1 = contents b := by
  have hk : keys (runOptimize b).1 = keys b := by simp [runOptimize, keys, List.map_map, Function.comp_def]
  refine ⟨⟨by rw [hk]; exact h.1, fun p hp => ?_⟩, ?_⟩
  · simp only [runOptimize, List.mem_map] at hp
    obtain ⟨q, hq, rfl⟩ := hp
    exact ⟨(h.2 q hq).1, (optimizeCon_spec (h.2 q hq).2).1⟩
  · simp only [runOptimize, contents]
    have hall : ∀ q ∈ b, ConOk q.2 := fun q hq => (h.2 q hq).2
    clear hk h
    induction b with
    | nil => rfl
    | cons q qs ih =>
      simp only [List.map_cons, List.flatMap_cons]
      rw [(optimizeCon_spec (hall q (by simp))).2, ih (fun r hr => hall r (by simp [hr]))]

def u16le (x : Nat) : List Nat := [x % 256, x / 256 % 256]

def u32le (x : Nat) : List Nat := [x % 256, x / 256 % 256, x / 65536 % 256, x / 16777216 % 256]

def getU16 (d : List Nat) (i : Nat) : Nat := d.getD i 0 + 256 * d.getD (i + 1) 0

def getU32 (d : List Nat) (i : Nat) : Nat := getU16 d i + 65536 * getU16 d (i + 2)

def cookieNoRuns : Nat := 12346

def cookieRuns : Nat := 12347

def bitsVal (f : Nat → Bool) : Nat → Nat
  | 0 => 0
  | n + 1 => (if f 0 then 1 else 0) + 2 * bitsVal (fun k => f (k + 1)) n

def hasRuns (b : Bitmap) : Bool := b.any fun p => p.2.isRun

def flags (b : Bitmap) : List Nat :=
  (List.range ((b.length + 7) / 8)).map fun j =>
    bitsVal (fun k => match b[8 * j + k]? with
      | some p => p.2.isRun
      | none => false) 8

def bitsetBytesAux : List Nat → Nat → Nat → List Nat
  | _, _, 0 => []
  | vs, j, m + 1 =>
    bitsVal (fun k => decide (8 * j + k ∈ vs.takeWhile (· < 8 * (j + 1)))) 8 ::
      bitsetBytesAux (vs.dropWhile (· < 8 * (j + 1))) (j + 1) m

def bitsetBytes (vs : List Nat) : List Nat := bitsetBytesAux vs 0 8192

def bitsOfBytesAux : List Nat → Nat → List Nat
  | [], _ => []
  | b :: bs, j => ((List.range 8).filter fun k => b / 2 ^ k % 2 = 1).map (8 * j + ·) ++ bitsOfBytesAux bs (j + 1)

def bitsOfBytes (bytes : List Nat) : List Nat := bitsOfBytesAux bytes 0

def payloadBytes (c : Con) : List Nat :=
  match c with
  | .runs rs => u16le rs.length ++ rs.flatMap fun r => u16le r.1 ++ u16le r.2
  | _ => if arrayMax < c.card then bitsetBytes c.elems else c.elems.flatMap u16le

def cookieBytes (b : Bitmap) : List Nat :=
  if hasRuns b then u32le (cookieRuns + (b.length - 1) * 65536) ++ flags b else u32le cookieNoRuns ++ u32le b.length

def tableBytes (b : Bitmap) : List Nat := b.flatMap fun p => u16le p.1 ++ u16le (p.2.card - 1)

def headerBytes (b : Bitmap) : List Nat := cookieBytes b ++ tableBytes b

def hasOffsets (b : Bitmap) : Bool := !hasRuns b || decide (4 ≤ b.length)

def offsetList : Nat → List Con → List Nat
  | _, [] => []
  | start, c :: cs => start :: offsetList (start + (payloadBytes c).length) cs

def serialize (b : Bitmap) : List Nat :=
  headerBytes b ++
    (if hasOffsets b then (offsetList ((headerBytes b).length + 4 * b.length) (b.map Prod.snd)).flatMap u32le else []) ++
    b.flatMap fun p => payloadBytes p.2

def readArray (d : List Nat) (card : Nat) : Option (Con × Nat) :=
  if d.length < 2 * card then none
  else if isStrict ((List.range card).map fun i => getU16 d (2 * i)) then
    some (.arr ((List.range card).map fun i => getU16 d (2 * i)), 2 * card)
  else none

def readBitset (d : List Nat) (card : Nat) : Option (Con × Nat) :=
  if d.length < 8192 then none
  else if (bitsOfBytes (d.take 8192)).length = card then some (.bits (bitsOfBytes (d.take 8192)), 8192)
  else none

def runsValid : Nat → List (Nat × Nat) → Bool
  | _, [] => true
  | free, (s, l) :: rs => decide (free ≤ s) && decide (s + l ≤ 65535) && runsValid (s + l + 1) rs

def readRuns (d : List Nat) (card : Nat) : Option (Con × Nat) :=
  if d.length < 2 then none
  else if getU16 d 0 = 0 ∨ d.length < 2 + 4 * getU16 d 0 then none
  else
    let rs := (List.range (getU16 d 0)).map fun r => (getU16 d (2 + 4 * r), getU16 d (4 + 4 * r))
    if runsValid 0 rs ∧ (rs.map fun r => r.2 + 1).sum = card then some (.runs rs, 2 + 4 * getU16 d 0) else none

def readCon (d : List Nat) (card : Nat) (isRun : Bool) : Option (Con × Nat) :=
  if isRun then readRuns d card else if arrayMax < card then readBitset d card else readArray d card

def above : Option Nat → Nat → Bool
  | none, _ => true
  | some p, k => decide (p < k)

def readAll (data : List Nat) : List (Nat × Nat × Bool) → Nat → Option Nat → Option (Bitmap × Nat)
  | [], pos, _ => some ([], pos)
  | (key, card, run) :: rest, pos, prev =>
    if above prev key then
      match readCon (data.drop pos) card run with
      | none => none
      | some (c, used) =>
        match readAll data rest (pos + used) (some key) with
        | none => none
        | some (b, fin) => some ((key, c) :: b, fin)
    else none

def entriesOf (data : List Nat) (runs : Bool) (n at0 : Nat) : List (Nat × Nat × Bool) :=
  (List.range n).map fun i =>
    (getU16 data (at0 + 4 * i), getU16 data (at0 + 4 * i + 2) + 1, runs && decide (data.getD (4 + i / 8) 0 / 2 ^ (i % 8) % 2 = 1))

def deserializeFrom (data : List Nat) (runs : Bool) (n at0 : Nat) : Option (Bitmap × Nat) :=
  if 65536 < n ∨ data.length < at0 + 4 * n then none
  else if (!runs || decide (4 ≤ n)) ∧ data.length < at0 + 8 * n then none
  else readAll data (entriesOf data runs n at0) (if !runs || decide (4 ≤ n) then at0 + 8 * n else at0 + 4 * n) none

def deserialize (data : List Nat) : Option (Bitmap × Nat) :=
  if data.length < 4 then none
  else if getU32 data 0 % 65536 = cookieRuns then
    deserializeFrom data true (getU32 data 0 / 65536 + 1) (4 + (getU32 data 0 / 65536 + 1 + 7) / 8)
  else if getU32 data 0 = cookieNoRuns then
    (if data.length < 8 then none else deserializeFrom data false (getU32 data 4) 8)
  else none

theorem bitsVal_bit (f : Nat → Bool) : ∀ n k, k < n → bitsVal f n / 2 ^ k % 2 = if f k then 1 else 0
  | 0, _, h => absurd h (Nat.not_lt_zero _)
  | n + 1, 0, _ => by simp only [bitsVal, Nat.pow_zero, Nat.div_one]; split <;> omega
  | n + 1, k + 1, h => by
    have ih := bitsVal_bit (fun j => f (j + 1)) n k (by omega)
    simp only [bitsVal]
    rw [Nat.pow_succ', ← Nat.div_div_eq_div_mul]
    have : ((if f 0 = true then 1 else 0) + 2 * bitsVal (fun k => f (k + 1)) n) / 2 = bitsVal (fun k => f (k + 1)) n := by
      split <;> omega
    rw [this, ih]

theorem bitsVal_lt (f : Nat → Bool) : ∀ n, bitsVal f n < 2 ^ n
  | 0 => by simp [bitsVal]
  | n + 1 => by
    have := bitsVal_lt (fun k => f (k + 1)) n
    simp only [bitsVal, Nat.pow_succ]
    split <;> omega

theorem getD_append_len (P X : List Nat) (j : Nat) : (P ++ X).getD (P.length + j) 0 = X.getD j 0 := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_append_right]

theorem getD_append_lt (P X : List Nat) (j : Nat) (h : j < P.length) : (P ++ X).getD j 0 = P.getD j 0 := by
  simp [List.getD_eq_getElem?_getD, List.getElem?_append_left h]

theorem getU16_u16le (x : Nat) (rest : List Nat) (h : x < 65536) : getU16 (u16le x ++ rest) 0 = x := by
  simp [getU16, u16le]; omega

theorem getU16_u16le_self (x : Nat) (h : x < 65536) : getU16 (u16le x) 0 = x := by
  simp [getU16, u16le]; omega

theorem getU16_append (P X : List Nat) (j : Nat) : getU16 (P ++ X) (P.length + j) = getU16 X j := by
  unfold getU16
  rw [getD_append_len, show P.length + j + 1 = P.length + (j + 1) by omega, getD_append_len]

theorem getU16_flatMap (vs rest : List Nat) (i : Nat) (hi : i < vs.length) (hb : ∀ v ∈ vs, v < 65536) :
    getU16 (vs.flatMap u16le ++ rest) (2 * i) = vs.getD i 0 := by
  induction vs generalizing i with
  | nil => simp at hi
  | cons v vs ih =>
    simp only [List.flatMap_cons, List.append_assoc]
    rcases i with _ | i
    · rw [getU16_u16le _ _ (hb v (by simp))]; rfl
    · have hlen : (u16le v).length = 2 := rfl
      rw [show 2 * (i + 1) = (u16le v).length + 2 * i by rw [hlen]; omega, getU16_append,
        ih i (by simp at hi; omega) (fun x hx => hb x (by simp [hx]))]
      rfl

theorem bitsVal_congr {f g : Nat → Bool} : ∀ n, (∀ k, k < n → f k = g k) → bitsVal f n = bitsVal g n
  | 0, _ => rfl
  | n + 1, h => by
    simp only [bitsVal]
    rw [h 0 (by omega), bitsVal_congr n (fun k hk => h (k + 1) (by omega))]

theorem length_bitsetBytesAux : ∀ (vs : List Nat) (j m : Nat), (bitsetBytesAux vs j m).length = m
  | _, _, 0 => rfl
  | vs, j, m + 1 => by simp [bitsetBytesAux, length_bitsetBytesAux]

theorem mem_takeWhile_lt {vs : List Nat} (h : Strict vs) {x t : Nat} (hx : x < t) :
    x ∈ vs.takeWhile (· < t) ↔ x ∈ vs := by
  induction vs with
  | nil => simp
  | cons v vs ih =>
    rw [List.takeWhile_cons]
    split
    · rename_i hv
      simp only [List.mem_cons, ih (strict_cons h)]
    · rename_i hv
      simp only [decide_eq_true_eq, Nat.not_lt] at hv
      simp only [List.not_mem_nil, false_iff]
      intro hm
      rcases List.mem_cons.1 hm with e | e
      · omega
      · have := strict_head h x e; omega

theorem bitsetBytesAux_get : ∀ (m : Nat) (vs : List Nat) (j i : Nat), Strict vs → (∀ v ∈ vs, 8 * j ≤ v) → i < m →
    (bitsetBytesAux vs j m).getD i 0 = bitsVal (fun k => decide (8 * (j + i) + k ∈ vs)) 8
  | 0, _, _, _, _, _, h => absurd h (Nat.not_lt_zero _)
  | m + 1, vs, j, 0, hs, hlo, _ => by
    simp only [bitsetBytesAux, List.getD_cons_zero, Nat.add_zero]
    apply bitsVal_congr
    intro k hk
    simp only [mem_takeWhile_lt hs (show 8 * j + k < 8 * (j + 1) by omega)]
  | m + 1, vs, j, i + 1, hs, hlo, hi => by
    simp only [bitsetBytesAux, List.getD_cons_succ]
    have hd := dropWhile_lt (8 * (j + 1)) vs hs
    rw [bitsetBytesAux_get m _ (j + 1) i hd.1 hd.2.1 (by omega)]
    apply bitsVal_congr
    intro k hk
    rw [show 8 * (j + 1 + i) + k = 8 * (j + (i + 1)) + k by omega]
    simp only [← hd.2.2.1 (8 * (j + (i + 1)) + k) (by omega)]

theorem bitsOfBytesAux_spec : ∀ (bytes : List Nat) (j : Nat),
    Strict (bitsOfBytesAux bytes j) ∧ (∀ x ∈ bitsOfBytesAux bytes j, 8 * j ≤ x) ∧
      ∀ x, x ∈ bitsOfBytesAux bytes j ↔ 8 * j ≤ x ∧ x < 8 * (j + bytes.length) ∧ bytes.getD (x / 8 - j) 0 / 2 ^ (x % 8) % 2 = 1
  | [], j => ⟨List.Pairwise.nil, by simp [bitsOfBytesAux], fun x => by simp [bitsOfBytesAux]⟩
  | b :: bs, j => by
    have ih := bitsOfBytesAux_spec bs (j + 1)
    have hfirst : ∀ x, x ∈ ((List.range 8).filter fun k => b / 2 ^ k % 2 = 1).map (8 * j + ·) ↔
        8 * j ≤ x ∧ x < 8 * j + 8 ∧ b / 2 ^ (x % 8) % 2 = 1 := by
      intro x
      simp only [List.mem_map, List.mem_filter, List.mem_range, decide_eq_true_eq]
      constructor
      · rintro ⟨k, ⟨hk, hb⟩, rfl⟩
        refine ⟨by omega, by omega, ?_⟩
        rw [show (8 * j + k) % 8 = k by omega]; exact hb
      · intro ⟨h1, h2, h3⟩
        exact ⟨x % 8, ⟨Nat.mod_lt _ (by decide), h3⟩, by omega⟩
    refine ⟨?_, fun x hx => ?_, fun x => ?_⟩
    · simp only [bitsOfBytesAux, Strict]
      rw [List.pairwise_append]
      refine ⟨?_, ih.1, fun a ha c hc => ?_⟩
      · rw [List.pairwise_map]
        exact List.Pairwise.imp (fun h => by omega) (List.Pairwise.filter _ List.pairwise_lt_range)
      · have := ((hfirst a).1 ha).2.1
        have := ih.2.1 c hc
        omega
    · simp only [bitsOfBytesAux, List.mem_append] at hx
      rcases hx with hx | hx
      · exact ((hfirst x).1 hx).1
      · have := ih.2.1 x hx; omega
    · simp only [bitsOfBytesAux, List.mem_append, List.length_cons]
      rw [hfirst x, ih.2.2 x]
      constructor
      · rintro (⟨h1, h2, h3⟩ | ⟨h1, h2, h3⟩)
        · refine ⟨h1, by omega, ?_⟩
          rw [show x / 8 - j = 0 by omega]; exact h3
        · refine ⟨by omega, by omega, ?_⟩
          rw [show x / 8 - j = (x / 8 - (j + 1)) + 1 by omega, List.getD_cons_succ]; exact h3
      · intro ⟨h1, h2, h3⟩
        by_cases hx : x < 8 * j + 8
        · left
          refine ⟨h1, hx, ?_⟩
          rw [show x / 8 - j = 0 by omega] at h3; exact h3
        · right
          refine ⟨by omega, by omega, ?_⟩
          rw [show x / 8 - j = (x / 8 - (j + 1)) + 1 by omega, List.getD_cons_succ] at h3; exact h3

theorem bitsOfBytes_bitsetBytes {vs : List Nat} (hs : Strict vs) (hb : ∀ v ∈ vs, v < chunk) :
    bitsOfBytes (bitsetBytes vs) = vs := by
  have hspec := bitsOfBytesAux_spec (bitsetBytes vs) 0
  apply strict_ext _ _ hspec.1 hs
  intro x
  rw [hspec.2.2 x]
  simp only [Nat.mul_zero, Nat.zero_le, true_and, Nat.zero_add, Nat.sub_zero]
  unfold bitsetBytes
  rw [length_bitsetBytesAux]
  constructor
  · intro ⟨h1, h2⟩
    rw [bitsetBytesAux_get 8192 vs 0 (x / 8) hs (fun v _ => Nat.zero_le _) (by omega),
      bitsVal_bit _ 8 (x % 8) (Nat.mod_lt _ (by decide))] at h2
    split at h2
    · rename_i hm
      simp only [decide_eq_true_eq, Nat.zero_add] at hm
      rw [show 8 * (x / 8) + x % 8 = x by omega] at hm; exact hm
    · omega
  · intro hm
    have hx := hb x hm
    refine ⟨by unfold chunk at hx; omega, ?_⟩
    rw [bitsetBytesAux_get 8192 vs 0 (x / 8) hs (fun v _ => Nat.zero_le _) (by unfold chunk at hx; omega),
      bitsVal_bit _ 8 (x % 8) (Nat.mod_lt _ (by decide))]
    simp only [Nat.zero_add, show 8 * (x / 8) + x % 8 = x by omega, hm, decide_true, ↓reduceIte]

theorem length_bitsetBytes (vs : List Nat) : (bitsetBytes vs).length = 8192 := length_bitsetBytesAux _ _ _

theorem getU16_append_left (P X : List Nat) (o : Nat) (h : o + 1 < P.length) : getU16 (P ++ X) o = getU16 P o := by
  unfold getU16
  rw [getD_append_lt _ _ _ (by omega), getD_append_lt _ _ _ h]

theorem getU16_blocks {α : Type} (f : α → List Nat) (w : Nat) (hw : ∀ a, (f a).length = w) :
    ∀ (l : List α) (rest : List Nat) (i o : Nat) (hi : i < l.length), o + 1 < w →
      getU16 (l.flatMap f ++ rest) (w * i + o) = getU16 (f l[i]) o
  | [], _, _, _, hi, _ => absurd hi (by simp)
  | a :: l, rest, 0, o, _, ho => by
    simp only [List.flatMap_cons, List.append_assoc, Nat.mul_zero, Nat.zero_add, List.getElem_cons_zero]
    exact getU16_append_left _ _ _ (by rw [hw]; exact ho)
  | a :: l, rest, i + 1, o, hi, ho => by
    simp only [List.flatMap_cons, List.append_assoc, List.getElem_cons_succ]
    rw [show w * (i + 1) + o = (f a).length + (w * i + o) by rw [hw, Nat.mul_succ]; omega, getU16_append]
    exact getU16_blocks f w hw l rest i o (by simp at hi; omega) ho

theorem length_flatMap_const {α : Type} (f : α → List Nat) (w : Nat) (hw : ∀ a, (f a).length = w) :
    ∀ l : List α, (l.flatMap f).length = w * l.length
  | [] => by simp
  | a :: l => by simp only [List.flatMap_cons, List.length_append, hw, length_flatMap_const f w hw l, List.length_cons, Nat.mul_succ]; omega

theorem readArray_payload {vs : List Nat} (hok : ConOk (.arr vs)) (rest : List Nat) :
    readArray (vs.flatMap u16le ++ rest) vs.length = some (.arr vs, 2 * vs.length) := by
  have hl := length_flatMap_const u16le 2 (fun _ => rfl) vs
  have hb : ∀ v ∈ vs, v < 65536 := fun v hv => hok.2.1 v hv
  have hmap : ((List.range vs.length).map fun i => getU16 (vs.flatMap u16le ++ rest) (2 * i)) = vs := by
    apply List.ext_getElem (by simp)
    intro i h1 h2
    simp only [List.getElem_map, List.getElem_range]
    rw [getU16_flatMap vs rest i h2 hb, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h2]
    rfl
  unfold readArray
  rw [hmap]
  simp only [List.length_append, hl, show ¬ (2 * vs.length + rest.length < 2 * vs.length) from by omega, ↓reduceIte,
    (isStrict_spec vs).2 hok.1]

theorem readBitset_payload {vs : List Nat} (hok : ConOk (.bits vs)) (rest : List Nat) :
    readBitset (bitsetBytes vs ++ rest) vs.length = some (.bits vs, 8192) := by
  have hl := length_bitsetBytes vs
  have ht : (bitsetBytes vs ++ rest).take 8192 = bitsetBytes vs := by
    rw [← hl, List.take_left]
  unfold readBitset
  rw [ht, bitsOfBytes_bitsetBytes hok.1 hok.2.1]
  simp [hl]

theorem runsValid_iff : ∀ (free : Nat) (rs : List (Nat × Nat)), runsValid free rs = true ↔ RunsOk free rs
  | _, [] => by simp [runsValid, RunsOk]
  | free, (s, l) :: rs => by
    simp only [runsValid, Bool.and_eq_true, decide_eq_true_eq, RunsOk, runsValid_iff (s + l + 1) rs]
    unfold chunk
    constructor
    · intro ⟨⟨a, b⟩, c⟩; exact ⟨a, by omega, c⟩
    · intro ⟨a, b, c⟩; exact ⟨⟨a, by omega⟩, c⟩

theorem expandRuns_length : ∀ rs : List (Nat × Nat), (expandRuns rs).length = (rs.map fun r => r.2 + 1).sum
  | [] => rfl
  | (s, l) :: rs => by simp [expandRuns, expandRun, expandRuns_length rs]

theorem runs_bound : ∀ {free : Nat} {rs : List (Nat × Nat)}, RunsOk free rs → ∀ r ∈ rs, r.1 < 65536 ∧ r.2 < 65536
  | _, [], _ => by simp
  | _, (s, l) :: rs, ⟨h1, h2, h3⟩ => by
    intro r hr
    rcases List.mem_cons.1 hr with e | e
    · subst e; unfold chunk at h2; exact ⟨by omega, by omega⟩
    · exact runs_bound h3 r e

theorem readRuns_payload {rs : List (Nat × Nat)} (hok : ConOk (.runs rs)) (rest : List Nat) :
    readRuns (payloadBytes (.runs rs) ++ rest) (Con.runs rs).card = some (.runs rs, (payloadBytes (.runs rs)).length) := by
  have hcount : rs.length < 65536 := hok.2.2
  have hbl := length_flatMap_const (fun r : Nat × Nat => u16le r.1 ++ u16le r.2) 4 (fun _ => rfl) rs
  have hplen : (payloadBytes (.runs rs)).length = 2 + 4 * rs.length := by
    simp only [payloadBytes, List.length_append, hbl]; rfl
  have hd : payloadBytes (.runs rs) ++ rest = u16le rs.length ++ ((rs.flatMap fun r => u16le r.1 ++ u16le r.2) ++ rest) := by
    simp [payloadBytes, List.append_assoc]
  have h0 : getU16 (payloadBytes (.runs rs) ++ rest) 0 = rs.length := by rw [hd]; exact getU16_u16le _ _ hcount
  have hrb := runs_bound hok.1
  have hmap : ((List.range rs.length).map fun r => (getU16 (payloadBytes (.runs rs) ++ rest) (2 + 4 * r),
      getU16 (payloadBytes (.runs rs) ++ rest) (4 + 4 * r))) = rs := by
    apply List.ext_getElem (by simp)
    intro i h1 h2
    simp only [List.getElem_map, List.getElem_range]
    have hb := hrb rs[i] (List.getElem_mem h2)
    rw [hd]
    have e1 : 2 + 4 * i = (u16le rs.length).length + (4 * i + 0) := by simp only [u16le, List.length_cons, List.length_nil]; omega
    have e2 : 4 + 4 * i = (u16le rs.length).length + (4 * i + 2) := by simp only [u16le, List.length_cons, List.length_nil]; omega
    rw [e1, e2, getU16_append, getU16_append,
      getU16_blocks (fun r : Nat × Nat => u16le r.1 ++ u16le r.2) 4 (fun _ => rfl) rs rest i 0 h2 (by omega),
      getU16_blocks (fun r : Nat × Nat => u16le r.1 ++ u16le r.2) 4 (fun _ => rfl) rs rest i 2 h2 (by omega)]
    rw [getU16_append_left _ _ _ (by simp [u16le]), getU16_u16le_self _ hb.1]
    have : getU16 (u16le rs[i].1 ++ u16le rs[i].2) 2 = rs[i].2 := by
      rw [show (2 : Nat) = (u16le rs[i].1).length + 0 by simp [u16le], getU16_append, getU16_u16le_self _ hb.2]
    rw [this]
  unfold readRuns
  rw [h0, hmap]
  have hne : rs ≠ [] := hok.2.1
  have hpos : 0 < rs.length := List.length_pos_iff.2 hne
  simp only [List.length_append, hplen, show ¬ (2 + 4 * rs.length + rest.length < 2) from by omega,
    show ¬ (rs.length = 0 ∨ 2 + 4 * rs.length + rest.length < 2 + 4 * rs.length) from by omega, ↓reduceIte]
  rw [ite_eq_left ⟨(runsValid_iff 0 rs).2 hok.1, by rw [Con.card, Con.elems, expandRuns_length]⟩]

theorem readCon_payload {c : Con} (hok : ConOk c) (rest : List Nat) :
    readCon (payloadBytes c ++ rest) c.card c.isRun = some (c, (payloadBytes c).length) := by
  cases c with
  | runs rs => exact readRuns_payload hok rest
  | bits vs =>
    have hgt : arrayMax < vs.length := hok.2.2
    have hp : payloadBytes (.bits vs) = bitsetBytes vs := by simp [payloadBytes, Con.card, Con.elems, hgt]
    simp only [readCon, Con.isRun, Bool.false_eq_true, ↓reduceIte]
    rw [hp, show (Con.bits vs).card = vs.length from rfl]
    simp only [hgt, ↓reduceIte]
    rw [readBitset_payload hok rest, length_bitsetBytes]
  | arr vs =>
    have hle : ¬ arrayMax < vs.length := by have := hok.2.2.2; omega
    have hp : payloadBytes (.arr vs) = vs.flatMap u16le := by simp [payloadBytes, Con.card, Con.elems, hle]
    simp only [readCon, Con.isRun, Bool.false_eq_true, ↓reduceIte]
    rw [hp, show (Con.arr vs).card = vs.length from rfl]
    simp only [hle, ↓reduceIte]
    rw [readArray_payload hok rest, length_flatMap_const u16le 2 (fun _ => rfl)]

def entryOf (p : Nat × Con) : Nat × Nat × Bool := (p.1, p.2.card, p.2.isRun)

def payloads (b : Bitmap) : List Nat := b.flatMap fun p => payloadBytes p.2

theorem readAll_payloads : ∀ (b : Bitmap) (P rest : List Nat) (prev : Option Nat), WF b →
    (∀ k ∈ keys b, above prev k = true) →
    readAll (P ++ payloads b ++ rest) (b.map entryOf) P.length prev = some (b, P.length + (payloads b).length)
  | [], P, rest, prev, _, _ => by simp [readAll, payloads]
  | (k, c) :: b, P, rest, prev, hw, hab => by
    have hrest : WF b := ⟨strict_cons hw.1, fun q hq => hw.2 q (by simp [hq])⟩
    have hok := (hw.2 (k, c) (by simp)).2
    have hk := hab k (by simp [keys])
    simp only [List.map_cons, entryOf, readAll, hk, ↓reduceIte]
    have hd : (P ++ payloads ((k, c) :: b) ++ rest).drop P.length = payloadBytes c ++ (payloads b ++ rest) := by
      simp [payloads, List.append_assoc]
    rw [hd, readCon_payload hok]
    simp only
    have e : P ++ payloads ((k, c) :: b) ++ rest = (P ++ payloadBytes c) ++ payloads b ++ rest := by
      simp [payloads, List.append_assoc]
    rw [e]
    have hlen : P.length + (payloadBytes c).length = (P ++ payloadBytes c).length := by simp
    rw [hlen, readAll_payloads b (P ++ payloadBytes c) rest (some k) hrest (fun k' hk' => by
      simp only [above, decide_eq_true_eq]; exact strict_head hw.1 k' hk')]
    simp [payloads, Nat.add_assoc]

theorem strict_length_le : ∀ {l : List Nat} {lo hi : Nat}, Strict l → (∀ x ∈ l, lo ≤ x ∧ x < hi) → l.length ≤ hi - lo
  | [], _, _, _, _ => Nat.zero_le _
  | x :: xs, lo, hi, hs, hb => by
    have hx := hb x (by simp)
    have := strict_length_le (lo := x + 1) (hi := hi) (strict_cons hs) (fun y hy => by
      have := strict_head hs y hy; have := hb y (by simp [hy]); omega)
    simp only [List.length_cons]; omega

theorem wf_length {b : Bitmap} (h : WF b) : b.length ≤ 65536 := by
  have := strict_length_le (lo := 0) (hi := 65536) h.1 (fun x hx => by
    simp only [keys, List.mem_map] at hx
    obtain ⟨p, hp, rfl⟩ := hx
    exact ⟨Nat.zero_le _, (h.2 p hp).1⟩)
  simp [keys] at this; exact this

theorem getU32_u32le (x : Nat) (rest : List Nat) (h : x < 4294967296) : getU32 (u32le x ++ rest) 0 = x := by
  simp [getU32, getU16, u32le]; omega

theorem length_offsetList : ∀ (start : Nat) (cs : List Con), (offsetList start cs).length = cs.length
  | _, [] => rfl
  | _, _ :: cs => by simp [offsetList, length_offsetList _ cs]

theorem length_flags (b : Bitmap) : (flags b).length = (b.length + 7) / 8 := by simp [flags]

theorem length_cookie (b : Bitmap) : (cookieBytes b).length = if hasRuns b then 4 + (b.length + 7) / 8 else 8 := by
  unfold cookieBytes; split <;> simp [u32le, length_flags] <;> omega

theorem flags_bit (b : Bitmap) (i : Nat) (hi : i < b.length) :
    (flags b).getD (i / 8) 0 / 2 ^ (i % 8) % 2 = 1 ↔ b[i].2.isRun = true := by
  have hj : i / 8 < (b.length + 7) / 8 := by omega
  rw [List.getD_eq_getElem?_getD]
  simp only [flags, List.getElem?_map, List.getElem?_range hj, Option.map_some, Option.getD_some]
  rw [bitsVal_bit _ 8 (i % 8) (Nat.mod_lt _ (by decide)), show 8 * (i / 8) + i % 8 = i by omega,
    List.getElem?_eq_getElem hi]
  simp only
  split <;> simp_all

theorem entries_serialize (b : Bitmap) (h : WF b) (rest : List Nat) :
    entriesOf (serialize b ++ rest) (hasRuns b) b.length (cookieBytes b).length = b.map entryOf := by
  apply List.ext_getElem (by simp [entriesOf])
  intro i h1 h2
  simp only [List.length_map] at h2
  simp only [entriesOf, List.getElem_map, List.getElem_range, entryOf]
  have hp := h.2 b[i] (List.getElem_mem h2)
  have hcard := conOk_card hp.2
  have hcard2 : b[i].2.card ≤ 65536 := by
    have he := conOk_elems hp.2
    unfold Con.card
    have := strict_length_le (lo := 0) (hi := 65536) he.1 (fun x hx => ⟨Nat.zero_le _, he.2.1 x hx⟩)
    omega
  have hd : serialize b ++ rest = cookieBytes b ++ (tableBytes b ++ ((if hasOffsets b then
      (offsetList ((headerBytes b).length + 4 * b.length) (b.map Prod.snd)).flatMap u32le else []) ++ payloads b ++ rest)) := by
    simp [serialize, headerBytes, payloads, List.append_assoc]
  have hw4 : ∀ p : Nat × Con, (u16le p.1 ++ u16le (p.2.card - 1)).length = 4 := fun _ => rfl
  have k0 : getU16 (serialize b ++ rest) ((cookieBytes b).length + 4 * i) = b[i].1 := by
    rw [hd, getU16_append, show 4 * i = 4 * i + 0 by rfl]
    unfold tableBytes
    rw [getU16_blocks _ 4 hw4 b _ i 0 h2 (by omega), getU16_append_left _ _ _ (by simp [u16le]),
      show u16le b[i].1 = u16le b[i].1 ++ [] by simp, getU16_u16le _ _ (hp.1)]
  have k2 : getU16 (serialize b ++ rest) ((cookieBytes b).length + 4 * i + 2) = b[i].2.card - 1 := by
    rw [hd, Nat.add_assoc, getU16_append]
    unfold tableBytes
    rw [getU16_blocks _ 4 hw4 b _ i 2 h2 (by omega), show (2 : Nat) = (u16le b[i].1).length + 0 by simp [u16le],
      getU16_append, show u16le (b[i].2.card - 1) = u16le (b[i].2.card - 1) ++ [] by simp, getU16_u16le _ _ (by omega)]
  rw [k0, k2, show b[i].2.card - 1 + 1 = b[i].2.card by omega]
  simp only [Prod.mk.injEq, true_and]
  cases hr : hasRuns b with
  | false =>
    simp only [Bool.false_and]
    have : ¬ (b[i].2.isRun = true) := by
      intro hi'
      have : hasRuns b = true := List.any_eq_true.2 ⟨b[i], List.getElem_mem h2, hi'⟩
      rw [hr] at this; cases this
    cases hh : b[i].2.isRun <;> simp_all
  | true =>
    simp only [Bool.true_and]
    have hg : (serialize b ++ rest).getD (4 + i / 8) 0 = (flags b).getD (i / 8) 0 := by
      rw [hd]
      unfold cookieBytes
      simp only [hr, ↓reduceIte, List.append_assoc]
      rw [show 4 + i / 8 = (u32le (cookieRuns + (b.length - 1) * 65536)).length + i / 8 by simp [u32le], getD_append_len,
        getD_append_lt _ _ _ (by rw [length_flags]; omega)]
    rw [hg]
    have := flags_bit b i h2
    cases hh : b[i].2.isRun <;> simp_all

theorem getU32_append (P X : List Nat) (j : Nat) : getU32 (P ++ X) (P.length + j) = getU32 X j := by
  unfold getU32
  rw [getU16_append, show P.length + j + 2 = P.length + (j + 2) by omega, getU16_append]

theorem length_offsets (b : Bitmap) (start : Nat) : ((offsetList start (b.map Prod.snd)).flatMap u32le).length = 4 * b.length := by
  rw [length_flatMap_const u32le 4 (fun _ => rfl), length_offsetList, List.length_map]

theorem length_header (b : Bitmap) : (headerBytes b).length = (cookieBytes b).length + 4 * b.length := by
  simp only [headerBytes, List.length_append, tableBytes]
  rw [length_flatMap_const _ 4 (fun _ => rfl)]

theorem deserialize_serialize (b : Bitmap) (h : WF b) (rest : List Nat) :
    deserialize (serialize b ++ rest) = some (b, (serialize b).length) := by
  have hn := wf_length h
  have hent := entries_serialize b h rest
  obtain ⟨O, hO⟩ : ∃ O, O = (if hasOffsets b then (offsetList ((headerBytes b).length + 4 * b.length) (b.map Prod.snd)).flatMap u32le
      else []) := ⟨_, rfl⟩
  have hser : serialize b = (headerBytes b ++ O) ++ payloads b := by rw [hO]; simp [serialize, payloads]
  have hread := readAll_payloads b (headerBytes b ++ O) rest none h (fun _ _ => rfl)
  rw [← hser] at hread
  have hlenser : (serialize b).length = (headerBytes b ++ O).length + (payloads b).length := by rw [hser, List.length_append]
  have hlh := length_header b
  have hlc := length_cookie b
  have hOlen : O.length = if hasOffsets b then 4 * b.length else 0 := by
    rw [hO]; split
    · exact length_offsets b _
    · rfl
  have hdl : (serialize b ++ rest).length = (headerBytes b).length + O.length + (payloads b).length + rest.length := by
    rw [List.length_append, hlenser, List.length_append]
  cases hr : hasRuns b with
  | true =>
    have hne : b ≠ [] := by
      intro e; rw [e] at hr; simp [hasRuns] at hr
    have hpos : 1 ≤ b.length := List.length_pos_iff.2 hne
    have hcb : cookieBytes b = u32le (cookieRuns + (b.length - 1) * 65536) ++ flags b := by simp [cookieBytes, hr]
    have hc : getU32 (serialize b ++ rest) 0 = cookieRuns + (b.length - 1) * 65536 := by
      rw [hser, List.append_assoc, List.append_assoc, headerBytes, hcb, List.append_assoc]
      exact getU32_u32le _ _ (by unfold cookieRuns; omega)
    simp only [hr, ↓reduceIte] at hlc
    have hm : (cookieRuns + (b.length - 1) * 65536) % 65536 = cookieRuns := by unfold cookieRuns; omega
    have hq : (cookieRuns + (b.length - 1) * 65536) / 65536 + 1 = b.length := by unfold cookieRuns; omega
    unfold deserialize
    rw [hc, hm, hq]
    simp only [show ¬ ((serialize b ++ rest).length < 4) from by rw [hdl, hlh, hlc]; omega, ↓reduceIte]
    unfold deserializeFrom
    rw [hr, hlc] at hent
    rw [hent]
    have hoff : hasOffsets b = decide (4 ≤ b.length) := by simp [hasOffsets, hr]
    simp only [Bool.not_true, Bool.false_or]
    by_cases h4 : 4 ≤ b.length
    · simp only [hoff, h4, decide_true, ↓reduceIte] at hOlen
      simp only [h4, decide_true, show ¬ (65536 < b.length ∨ (serialize b ++ rest).length < 4 + (b.length + 7) / 8 + 4 * b.length) from by
        rw [hdl, hlh, hlc]; omega, ↓reduceIte, true_and,
        show ¬ ((serialize b ++ rest).length < 4 + (b.length + 7) / 8 + 8 * b.length) from by rw [hdl, hlh, hlc]; omega]
      rw [show 4 + (b.length + 7) / 8 + 8 * b.length = (headerBytes b ++ O).length by rw [List.length_append, hlh, hlc]; omega,
        hread, hlenser]
    · simp only [hoff, h4, decide_false, Bool.false_eq_true, ↓reduceIte] at hOlen
      simp only [h4, decide_false, Bool.false_eq_true, false_and, ↓reduceIte,
        show ¬ (65536 < b.length ∨ (serialize b ++ rest).length < 4 + (b.length + 7) / 8 + 4 * b.length) from by
        rw [hdl, hlh, hlc]; omega]
      rw [show 4 + (b.length + 7) / 8 + 4 * b.length = (headerBytes b ++ O).length by rw [List.length_append, hlh, hlc]; omega,
        hread, hlenser]
  | false =>
    have hcb : cookieBytes b = u32le cookieNoRuns ++ u32le b.length := by simp [cookieBytes, hr]
    have hd : serialize b ++ rest = u32le cookieNoRuns ++ (u32le b.length ++ (tableBytes b ++ O ++ payloads b ++ rest)) := by
      rw [hser, headerBytes, hcb]; simp [List.append_assoc]
    have hc : getU32 (serialize b ++ rest) 0 = cookieNoRuns := by rw [hd]; exact getU32_u32le _ _ (by decide)
    have hc4 : getU32 (serialize b ++ rest) 4 = b.length := by
      rw [hd, show (4 : Nat) = (u32le cookieNoRuns).length + 0 by rfl, getU32_append, getU32_u32le _ _ (by omega)]
    simp only [hr, Bool.false_eq_true, ↓reduceIte] at hlc
    have hoff : hasOffsets b = true := by simp [hasOffsets, hr]
    simp only [hoff, ↓reduceIte] at hOlen
    unfold deserialize
    rw [hc, hc4]
    simp only [show ¬ ((serialize b ++ rest).length < 4) from by rw [hdl, hlh, hlc]; omega, ↓reduceIte,
      show ¬ (cookieNoRuns % 65536 = cookieRuns) from by decide,
      show ¬ ((serialize b ++ rest).length < 8) from by rw [hdl, hlh, hlc]; omega]
    unfold deserializeFrom
    rw [hr, hlc] at hent
    rw [hent]
    simp only [Bool.not_false, Bool.true_or, ↓reduceIte, true_and,
      show ¬ (65536 < b.length ∨ (serialize b ++ rest).length < 8 + 4 * b.length) from by rw [hdl, hlh, hlc]; omega,
      show ¬ ((serialize b ++ rest).length < 8 + 8 * b.length) from by rw [hdl, hlh, hlc]; omega]
    rw [show 8 + 8 * b.length = (headerBytes b ++ O).length by rw [List.length_append, hlh, hlc]; omega, hread,
      hlenser]

theorem offsets_ignored :
    deserialize [58, 48, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 5, 0] = some ([(0, .arr [5])], 18) ∧
    deserialize [58, 48, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 5, 0] = some ([(0, .arr [5])], 18) ∧
    serialize [(0, .arr [5])] = [58, 48, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 5, 0] := by
  refine ⟨by decide, by decide, by decide⟩

theorem getD_byte {d : List Nat} (h : Bytes d) (i : Nat) : d.getD i 0 < 256 := by
  rw [List.getD_eq_getElem?_getD]
  cases hi : d[i]? with
  | none => simp
  | some v => simp only [Option.getD_some]; exact h v (List.mem_of_getElem? hi)

theorem getU16_lt {d : List Nat} (h : Bytes d) (i : Nat) : getU16 d i < 65536 := by
  have := getD_byte h i; have := getD_byte h (i + 1); unfold getU16; omega

theorem bytes_drop {d : List Nat} (h : Bytes d) (n : Nat) : Bytes (d.drop n) := fun b hb => h b (List.mem_of_mem_drop hb)

theorem readCon_ok {d : List Nat} (hd : Bytes d) {card : Nat} {run : Bool} {c : Con} {used : Nat} (hc : 1 ≤ card)
    (h : readCon d card run = some (c, used)) : ConOk c := by
  unfold readCon at h
  split at h
  · unfold readRuns at h
    split at h
    · cases h
    · split at h
      · cases h
      · rename_i h1 h2
        dsimp only at h
        split at h
        · rename_i h3
          simp only [Option.some.injEq, Prod.mk.injEq] at h
          obtain ⟨rfl, _⟩ := h
          refine ⟨(runsValid_iff 0 _).1 h3.1, ?_, by simp; exact getU16_lt hd 0⟩
          intro e
          have : (List.range (getU16 d 0)).length = 0 := by rw [← List.length_map (f := fun r => (getU16 d (2 + 4 * r), getU16 d (4 + 4 * r))), e]; rfl
          simp at this; omega
        · cases h
  · split at h
    · rename_i hgt
      unfold readBitset at h
      split at h
      · cases h
      · split at h
        · rename_i hl
          simp only [Option.some.injEq, Prod.mk.injEq] at h
          obtain ⟨rfl, _⟩ := h
          have hs := bitsOfBytesAux_spec (d.take 8192) 0
          refine ⟨hs.1, fun v hv => ?_, by unfold bitsOfBytes at hl ⊢; rw [hl]; exact hgt⟩
          have := ((hs.2.2 v).1 hv).2.1
          simp only [List.length_take] at this
          unfold chunk; omega
        · cases h
    · rename_i hle
      unfold readArray at h
      split at h
      · cases h
      · split at h
        · rename_i hst
          simp only [Option.some.injEq, Prod.mk.injEq] at h
          obtain ⟨rfl, _⟩ := h
          refine ⟨(isStrict_spec _).1 hst, fun v hv => ?_, ?_, by simp; omega⟩
          · simp only [List.mem_map] at hv
            obtain ⟨i, _, rfl⟩ := hv
            exact getU16_lt hd _
          · intro e
            have : (List.range card).length = 0 := by rw [← List.length_map (f := fun i => getU16 d (2 * i)), e]; rfl
            simp at this; omega
        · cases h

theorem readAll_ok {data : List Nat} (hd : Bytes data) :
    ∀ (entries : List (Nat × Nat × Bool)) (pos : Nat) (prev : Option Nat) (b : Bitmap) (fin : Nat),
      (∀ e ∈ entries, e.1 < chunk ∧ 1 ≤ e.2.1) → readAll data entries pos prev = some (b, fin) →
        WF b ∧ ∀ k ∈ keys b, above prev k = true
  | [], pos, prev, b, fin, _, h => by
    simp only [readAll, Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, _⟩ := h
    exact ⟨⟨List.Pairwise.nil, by simp⟩, by simp [keys]⟩
  | (key, card, run) :: rest, pos, prev, b, fin, he, h => by
    simp only [readAll] at h
    split at h
    · rename_i hab
      split at h
      · cases h
      · rename_i c used hrc
        split at h
        · cases h
        · rename_i b' fin' hra
          simp only [Option.some.injEq, Prod.mk.injEq] at h
          obtain ⟨rfl, _⟩ := h
          have hk := he (key, card, run) (by simp)
          have ih := readAll_ok hd rest (pos + used) (some key) b' fin' (fun e he' => he e (by simp [he'])) hra
          have hc := readCon_ok (bytes_drop hd pos) hk.2 hrc
          refine ⟨⟨List.pairwise_cons.2 ⟨fun k' hk' => ?_, ih.1.1⟩, fun p hp => ?_⟩, fun k' hk' => ?_⟩
          · have := ih.2 k' hk'; simp [above] at this; exact this
          · rcases List.mem_cons.1 hp with e | e
            · subst e; exact ⟨hk.1, hc⟩
            · exact ih.1.2 p e
          · simp only [keys, List.map_cons, List.mem_cons] at hk'
            rcases hk' with e | e
            · subst e; exact hab
            · have h1 := ih.2 k' e
              simp only [above, decide_eq_true_eq] at h1
              cases prev with
              | none => rfl
              | some p => simp only [above, decide_eq_true_eq] at hab ⊢; omega
    · cases h

theorem deserialize_wf {data : List Nat} (hd : Bytes data) {b : Bitmap} {used : Nat}
    (h : deserialize data = some (b, used)) : WF b := by
  have hent : ∀ runs n at0, ∀ e ∈ entriesOf data runs n at0, e.1 < chunk ∧ 1 ≤ e.2.1 := by
    intro runs n at0 e he
    simp only [entriesOf, List.mem_map, List.mem_range] at he
    obtain ⟨i, _, rfl⟩ := he
    exact ⟨getU16_lt hd _, Nat.succ_le_succ (Nat.zero_le _)⟩
  have from_ok : ∀ runs n at0, deserializeFrom data runs n at0 = some (b, used) → WF b := by
    intro runs n at0 hf
    unfold deserializeFrom at hf
    split at hf
    · cases hf
    · split at hf
      · cases hf
      · exact (readAll_ok hd _ _ _ _ _ (hent runs n at0) hf).1
  unfold deserialize at h
  split at h
  · cases h
  · split at h
    · exact from_ok _ _ _ h
    · split at h
      · split at h
        · cases h
        · exact from_ok _ _ _ h
      · cases h

theorem reencode_stable {data : List Nat} (hd : Bytes data) {b : Bitmap} {used : Nat}
    (h : deserialize data = some (b, used)) : deserialize (serialize b) = some (b, (serialize b).length) := by
  have := deserialize_serialize b (deserialize_wf hd h) []
  rwa [List.append_nil] at this

end Postings
