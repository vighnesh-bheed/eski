import Texts.Tokenize
import Texts.Fold
import Texts.Stop

namespace Texts

structure Term where
  bytes : List Nat
  position : Nat
  start : Nat
  stop : Nat
  stem : Bool
deriving Repr, DecidableEq

structure Word where
  folded : List Nat
  start : Nat
  stop : Nat
deriving Repr, DecidableEq

def keep (stop : List Nat → Bool) (w : Word) : Bool := w.folded = [] || !stop w.folded

def stemmed (stem : Option (List Nat → List Nat)) (minStem : Nat) (f : List Nat) : Option (List Nat) :=
  match stem with
  | none => none
  | some g => if minStem ≤ f.length ∧ g f ≠ f then some (g f) else none

def block (stem : Option (List Nat → List Nat)) (minStem : Nat) (w : Word) (p : Nat) : List Term :=
  ⟨w.folded, p, w.start, w.stop, false⟩ ::
    match stemmed stem minStem w.folded with
    | none => []
    | some s => [⟨43 :: s, p, w.start, w.stop, true⟩]

def step (stop : List Nat → Bool) (stem : Option (List Nat → List Nat)) (minStem : Nat) : List Word → Nat → List Term × Nat
  | [], pos => ([], pos)
  | w :: rest, pos =>
    if keep stop w then
      let r := step stop stem minStem rest (pos + 1)
      (block stem minStem w (pos + 1) ++ r.1, r.2)
    else step stop stem minStem rest pos

def words (low : Nat → List Nat) (text : List Nat) : List Word :=
  (tokenize text).map fun t => ⟨fold low t.text (text.drop t.tailFrom), t.start, t.stop⟩

def analyze (low : Nat → List Nat) (sw : Option StopWords) (stem : Option (List Nat → List Nat)) (minStem base : Nat)
    (text : List Nat) : List Term × Nat :=
  step (match sw with | none => fun _ => false | some s => isStop s) stem minStem (words low text) base

theorem step_spec (stop : List Nat → Bool) (stem : Option (List Nat → List Nat)) (minStem : Nat) :
    ∀ (ws : List Word) (base : Nat), step stop stem minStem ws base =
      (((ws.filter (keep stop)).zipIdx (base + 1)).flatMap (fun p => block stem minStem p.1 p.2),
        base + (ws.filter (keep stop)).length)
  | [], base => by simp [step]
  | w :: rest, base => by
    simp only [step]
    split
    · rename_i hk
      rw [step_spec stop stem minStem rest (base + 1)]
      simp only [List.filter_cons, hk, ↓reduceIte, List.zipIdx_cons, List.flatMap_cons, List.length_cons]
      refine Prod.ext rfl ?_
      simp only
      omega
    · rename_i hk
      rw [step_spec stop stem minStem rest base]
      simp [List.filter_cons, hk]

theorem last_spec (stop : List Nat → Bool) (stem : Option (List Nat → List Nat)) (minStem base : Nat) (ws : List Word) :
    (step stop stem minStem ws base).2 = base + (ws.filter (keep stop)).length := by
  rw [step_spec]

theorem originals_flatMap (stem : Option (List Nat → List Nat)) (minStem : Nat) :
    ∀ (ps : List (Word × Nat)),
      ((ps.flatMap fun p => block stem minStem p.1 p.2).filter fun t => !t.stem) = ps.map fun p => ⟨p.1.folded, p.2, p.1.start, p.1.stop, false⟩
  | [] => by simp
  | p :: rest => by
    simp only [List.flatMap_cons, List.filter_append, List.map_cons]
    rw [originals_flatMap stem minStem rest]
    simp only [block, List.filter_cons, Bool.not_false, ↓reduceIte]
    split <;> simp

theorem originals_spec (stop : List Nat → Bool) (stem : Option (List Nat → List Nat)) (minStem base : Nat) (ws : List Word) :
    ((step stop stem minStem ws base).1.filter fun t => !t.stem) =
      ((ws.filter (keep stop)).zipIdx (base + 1)).map fun p => ⟨p.1.folded, p.2, p.1.start, p.1.stop, false⟩ := by
  rw [step_spec]
  exact originals_flatMap stem minStem _

theorem zipIdx_snd (l : List Word) (n : Nat) : (l.zipIdx n).map Prod.snd = List.range' n l.length := by
  induction l generalizing n with
  | nil => simp
  | cons a rest ih => simp [List.zipIdx_cons, ih, List.range'_succ]

theorem positions_consecutive (stop : List Nat → Bool) (stem : Option (List Nat → List Nat)) (minStem base : Nat) (ws : List Word) :
    ((step stop stem minStem ws base).1.filter fun t => !t.stem).map Term.position =
      List.range' (base + 1) ((step stop stem minStem ws base).2 - base) := by
  rw [originals_spec, last_spec, List.map_map]
  have : (Term.position ∘ fun p : Word × Nat => (⟨p.1.folded, p.2, p.1.start, p.1.stop, false⟩ : Term)) = Prod.snd := by
    funext p; rfl
  rw [this, zipIdx_snd]
  congr 1
  omega

theorem stemmed_some (stem : Option (List Nat → List Nat)) (minStem : Nat) (f s : List Nat) :
    stemmed stem minStem f = some s ↔ ∃ g, stem = some g ∧ minStem ≤ f.length ∧ g f ≠ f ∧ s = g f := by
  cases stem with
  | none => simp [stemmed]
  | some g =>
    by_cases h : minStem ≤ f.length ∧ g f ≠ f
    · have e : stemmed (some g) minStem f = some (g f) := by simp [stemmed, h.1, h.2]
      rw [e]
      constructor
      · intro e'; exact ⟨g, rfl, h.1, h.2, (Option.some.inj e').symm⟩
      · rintro ⟨g', hg, -, -, e'⟩; cases hg; rw [e']
    · have e : stemmed (some g) minStem f = none := by
        simp only [stemmed]
        split
        · rename_i h'; exact absurd h' h
        · rfl
      rw [e]
      simp only [reduceCtorEq, false_iff, not_exists, not_and]
      intro g' hg hl hne _
      cases hg
      exact h ⟨hl, hne⟩

theorem block_stem_rule (stem : Option (List Nat → List Nat)) (minStem : Nat) (w : Word) (p : Nat) (t : Term)
    (ht : t ∈ block stem minStem w p) (hs : t.stem = true) :
    ∃ g, stem = some g ∧ minStem ≤ w.folded.length ∧ g w.folded ≠ w.folded ∧
      t = ⟨43 :: g w.folded, p, w.start, w.stop, true⟩ := by
  unfold block at ht
  simp only [List.mem_cons] at ht
  rcases ht with ht | ht
  · subst ht; cases hs
  · split at ht
    · cases ht
    · rename_i s hsome
      simp only [List.mem_singleton] at ht
      obtain ⟨g, hg, hl, hne, e⟩ := (stemmed_some stem minStem w.folded s).1 hsome
      exact ⟨g, hg, hl, hne, by rw [ht, e]⟩

theorem stem_rule (stop : List Nat → Bool) (stem : Option (List Nat → List Nat)) (minStem base : Nat) (ws : List Word)
    (t : Term) (ht : t ∈ (step stop stem minStem ws base).1) (hs : t.stem = true) :
    ∃ w ∈ ws, keep stop w = true ∧ ∃ g, stem = some g ∧ minStem ≤ w.folded.length ∧ g w.folded ≠ w.folded ∧
      t.bytes = 43 :: g w.folded ∧ t.start = w.start ∧ t.stop = w.stop ∧
      ⟨w.folded, t.position, w.start, w.stop, false⟩ ∈ (step stop stem minStem ws base).1 := by
  rw [step_spec] at ht ⊢
  simp only [List.mem_flatMap] at ht
  obtain ⟨⟨w, p⟩, hp, hb⟩ := ht
  obtain ⟨g, hg, hl, hne, e⟩ := block_stem_rule stem minStem w p t hb hs
  have hw : w ∈ ws.filter (keep stop) := List.fst_mem_of_mem_zipIdx hp
  refine ⟨w, (List.mem_filter.1 hw).1, (List.mem_filter.1 hw).2, g, hg, hl, hne, by rw [e], by rw [e], by rw [e], ?_⟩
  simp only [List.mem_flatMap]
  refine ⟨⟨w, p⟩, hp, ?_⟩
  rw [e]
  simp [block]

theorem stem_present (stop : List Nat → Bool) (g : List Nat → List Nat) (minStem base : Nat) (ws : List Word)
    (w : Word) (p : Nat) (hp : (w, p) ∈ (ws.filter (keep stop)).zipIdx (base + 1)) (hl : minStem ≤ w.folded.length)
    (hne : g w.folded ≠ w.folded) :
    ⟨43 :: g w.folded, p, w.start, w.stop, true⟩ ∈ (step stop (some g) minStem ws base).1 := by
  rw [step_spec]
  simp only [List.mem_flatMap]
  refine ⟨(w, p), hp, ?_⟩
  simp [block, stemmed, hl, hne]

theorem empty_kept (stop : List Nat → Bool) (w : Word) (h : w.folded = []) : keep stop w = true := by
  simp [keep, h]

theorem stop_dropped (stop : List Nat → Bool) (w : Word) (h : w.folded ≠ []) (hs : stop w.folded = true) : keep stop w = false := by
  simp [keep, h, hs]

theorem no_stop_all (stem : Option (List Nat → List Nat)) (minStem base : Nat) (ws : List Word) :
    (step (fun _ => false) stem minStem ws base).2 = base + ws.length := by
  rw [last_spec]
  congr 2
  exact List.filter_eq_self.2 fun w _ => by simp [keep]

theorem short_unstemmed (stop : List Nat → Bool) (stem : Option (List Nat → List Nat)) (minStem base : Nat) (ws : List Word)
    (t : Term) (ht : t ∈ (step stop stem minStem ws base).1) (hs : t.stem = true) :
    ∃ w ∈ ws, minStem ≤ w.folded.length := by
  obtain ⟨w, hw, -, -, -, hl, -⟩ := stem_rule stop stem minStem base ws t ht hs
  exact ⟨w, hw, hl⟩

theorem words_spec (low : Nat → List Nat) (text : List Nat) : (words low text).length = (specTexts text).length := by
  rw [words, List.length_map, ← tokenize_spec, List.length_map]

theorem analyze_last (low : Nat → List Nat) (stem : Option (List Nat → List Nat)) (minStem base : Nat) (text : List Nat) :
    (analyze low none stem minStem base text).2 = base + (specTexts text).length := by
  simp only [analyze]
  rw [no_stop_all, words_spec]

theorem fold_nonempty_ascii (low : Nat → List Nat) (text tail : List Nat) (hne : text ≠ []) (h : ∀ b ∈ text, 0 < b ∧ b < 128) :
    fold low text tail ≠ [] := by
  rw [fold_ascii low text tail h]
  simpa using hne

theorem overlong_nul_empty : fold (fun c => [c]) [192, 128] [] = [] := by decide

end Texts
