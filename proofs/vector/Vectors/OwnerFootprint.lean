import Vectors.Owner

set_option autoImplicit false

namespace Vectors

structure Books where
  set : Int
  own : Int
  rax : Int
  index : Int
  names : Int
deriving DecidableEq, Repr

structure Block where
  usable : Int
  charge : Int
deriving DecidableEq, Repr

def Block.foot (b : Block) : Int := b.usable + b.charge

def graduateBooks (bk : Books) (compact : Block) (full graph : Int) : Books × Block :=
  let bk₁ := { bk with own := bk.own + full }
  let charge₁ := compact.charge
  let bk₂ := { bk₁ with own := bk₁.own + graph }
  let charge₂ := charge₁ + graph
  let bk₃ := { bk₂ with own := bk₂.own - compact.usable }
  (bk₃, ⟨full, charge₂⟩)

def graduateFailBooks (bk : Books) (compact : Block) (full graph : Int) : Books × Block :=
  let bk₁ := { bk with own := bk.own + full }
  let bk₂ := { bk₁ with own := bk₁.own + graph }
  let bk₃ := { bk₂ with own := bk₂.own - graph }
  let bk₄ := { bk₃ with own := bk₃.own - full }
  (bk₄, compact)

def flattenBooks (bk : Books) (full : Block) (compactUsable graph : Int) : Books × Block :=
  let bk₁ := { bk with own := bk.own + compactUsable }
  let bk₂ := { bk₁ with own := bk₁.own - graph }
  let charge := full.charge - graph
  let bk₃ := { bk₂ with own := bk₂.own - full.usable }
  (bk₃, ⟨compactUsable, charge⟩)

theorem graduate_books (bk : Books) (compact : Block) (full graph : Int) :
    (graduateBooks bk compact full graph).1 =
      { bk with own := bk.own + ((graduateBooks bk compact full graph).2.foot - compact.foot) } := by
  simp only [graduateBooks, Block.foot, Books.mk.injEq, and_true, true_and]
  omega

theorem graduate_fail_books (bk : Books) (compact : Block) (full graph : Int) :
    graduateFailBooks bk compact full graph = (bk, compact) := by
  simp only [graduateFailBooks, Prod.mk.injEq, and_true]
  cases bk
  simp only [Books.mk.injEq, and_true, true_and]
  omega

theorem flatten_books (bk : Books) (full : Block) (compactUsable graph : Int) :
    (flattenBooks bk full compactUsable graph).1 =
      { bk with own := bk.own + ((flattenBooks bk full compactUsable graph).2.foot - full.foot) } := by
  simp only [flattenBooks, Block.foot, Books.mk.injEq, and_true, true_and]
  omega

section Accounts
set_option linter.unusedSectionVars false
variable {L : Type} [DecidableEq L]

structure Acct (L : Type) where
  books : Books
  shared : L → Int
  owned : Nat → L → Int
  overhead : Nat → Int
  lowest : Nat → Option L

def sharedBytes (a : Acct L) (labels : List L) : Int :=
  a.books.set + a.books.names - (labels.map a.shared).sum - a.books.index

def labelMemory (a : Acct L) (l : L) : Int := a.shared l

def ownerMemory (a : Acct L) (labels : List L) (o : Nat) : Int := a.overhead o + (labels.map (a.owned o)).sum

def scopeMemory (a : Acct L) (l : L) (o : Nat) : Int :=
  if o = SHARED then a.shared l else a.owned o l + (if a.lowest o = some l then a.overhead o else 0)

def ownerBytes (a : Acct L) : Int := a.books.own + a.books.rax

def memoryUsage (a : Acct L) : Int := a.books.set + a.books.names + ownerBytes a

def OwnerSum (a : Acct L) (labels : List L) (owners : List Nat) : Prop :=
  ownerBytes a = (owners.map (ownerMemory a labels)).sum

def replaceBlock (a : Acct L) (o : Nat) (l : L) (bk : Books) (foot : Int) : Acct L :=
  { a with books := bk, owned := fun o' l' => if o' = o ∧ l' = l then foot else a.owned o' l' }

def graduateAt (a : Acct L) (o : Nat) (l : L) (compact : Block) (full graph : Int) : Acct L :=
  replaceBlock a o l (graduateBooks a.books compact full graph).1 (graduateBooks a.books compact full graph).2.foot

def flattenAt (a : Acct L) (o : Nat) (l : L) (fullBlock : Block) (compactUsable graph : Int) : Acct L :=
  replaceBlock a o l (flattenBooks a.books fullBlock compactUsable graph).1
    (flattenBooks a.books fullBlock compactUsable graph).2.foot

theorem sum_update {α : Type} [DecidableEq α] (f : α → Int) (x₀ : α) (v : Int) : ∀ (xs : List α), xs.Nodup →
    (xs.map (fun x => if x = x₀ then v else f x)).sum = (xs.map f).sum + (if x₀ ∈ xs then v - f x₀ else 0) := by
  intro xs
  induction xs with
  | nil => intro _; simp
  | cons x xs ih =>
    intro hnd
    rw [List.nodup_cons] at hnd
    rw [List.map_cons, List.map_cons, List.sum_cons, List.sum_cons, ih hnd.2]
    by_cases hx : x = x₀
    · subst hx
      simp only [↓reduceIte, List.mem_cons, true_or, hnd.1]
      omega
    · have : (x₀ ∈ x :: xs) ↔ x₀ ∈ xs := by
        simp only [List.mem_cons]
        constructor
        · intro h; rcases h with e | e
          · exact absurd e.symm hx
          · exact e
        · intro h; exact Or.inr h
      simp only [hx, ↓reduceIte, this]
      omega

theorem sum_congr_except {α : Type} [DecidableEq α] (f g : α → Int) (x₀ : α) (δ : Int)
    (hf : ∀ x, x ≠ x₀ → g x = f x) (h₀ : g x₀ = f x₀ + δ) : ∀ (xs : List α), xs.Nodup →
      (xs.map g).sum = (xs.map f).sum + (if x₀ ∈ xs then δ else 0) := by
  intro xs hnd
  have : xs.map g = xs.map (fun x => if x = x₀ then f x₀ + δ else f x) := by
    apply List.map_congr_left
    intro x _
    by_cases hx : x = x₀
    · subst hx; simp [h₀]
    · simp [hx, hf x hx]
  rw [this, sum_update f x₀ (f x₀ + δ) xs hnd]
  split <;> omega

theorem replace_isolates (a : Acct L) (o : Nat) (l : L) (foot : Int) (labels : List L) (owners : List Nat)
    (hl : labels.Nodup) (hlm : l ∈ labels) (hon : owners.Nodup) (hom : o ∈ owners)
    (bk : Books) (hbk : bk = { a.books with own := a.books.own + (foot - a.owned o l) }) :
    sharedBytes (replaceBlock a o l bk foot) labels = sharedBytes a labels ∧
    (∀ l', labelMemory (replaceBlock a o l bk foot) l' = labelMemory a l') ∧
    (replaceBlock a o l bk foot).books.index = a.books.index ∧
    (∀ o', o' ≠ o → ownerMemory (replaceBlock a o l bk foot) labels o' = ownerMemory a labels o') ∧
    (∀ l' o', (l', o') ≠ (l, o) → scopeMemory (replaceBlock a o l bk foot) l' o' = scopeMemory a l' o') ∧
    ownerMemory (replaceBlock a o l bk foot) labels o = ownerMemory a labels o + (foot - a.owned o l) ∧
    ownerBytes (replaceBlock a o l bk foot) = ownerBytes a + (foot - a.owned o l) ∧
    (OwnerSum a labels owners → OwnerSum (replaceBlock a o l bk foot) labels owners) := by
  subst hbk
  have hom' : ∀ o', o' ≠ o → ownerMemory (replaceBlock a o l { a.books with own := a.books.own + (foot - a.owned o l) } foot) labels o' =
      ownerMemory a labels o' := by
    intro o' ho'
    simp [ownerMemory, replaceBlock, ho']
  have hoo : ownerMemory (replaceBlock a o l { a.books with own := a.books.own + (foot - a.owned o l) } foot) labels o =
      ownerMemory a labels o + (foot - a.owned o l) := by
    simp only [ownerMemory, replaceBlock, true_and]
    rw [sum_update (a.owned o) l foot labels hl]
    simp only [hlm, ↓reduceIte]
    omega
  refine ⟨?_, ?_, ?_, hom', ?_, hoo, ?_, ?_⟩
  · simp [sharedBytes, replaceBlock]
  · intro l'; rfl
  · rfl
  · intro l' o' hne
    simp only [scopeMemory, replaceBlock]
    by_cases hs : o' = SHARED
    · simp [hs]
    · have : ¬(o' = o ∧ l' = l) := fun h => hne (by rw [h.1, h.2])
      simp only [hs, ↓reduceIte, this]
      rfl
  · simp only [ownerBytes, replaceBlock]
    omega
  · intro hsum
    unfold OwnerSum at hsum ⊢
    rw [sum_congr_except (ownerMemory a labels) _ o (foot - a.owned o l) hom' hoo owners hon]
    simp only [hom, ↓reduceIte]
    simp only [ownerBytes, replaceBlock] at hsum ⊢
    omega

theorem graduate_isolates (a : Acct L) (o : Nat) (l : L) (compact : Block) (full graph : Int) (labels : List L)
    (owners : List Nat) (hl : labels.Nodup) (hlm : l ∈ labels) (hon : owners.Nodup) (hom : o ∈ owners)
    (hfoot : a.owned o l = compact.foot) :
    sharedBytes (graduateAt a o l compact full graph) labels = sharedBytes a labels ∧
    (∀ l', labelMemory (graduateAt a o l compact full graph) l' = labelMemory a l') ∧
    (graduateAt a o l compact full graph).books.index = a.books.index ∧
    (∀ o', o' ≠ o → ownerMemory (graduateAt a o l compact full graph) labels o' = ownerMemory a labels o') ∧
    (∀ l' o', (l', o') ≠ (l, o) → scopeMemory (graduateAt a o l compact full graph) l' o' = scopeMemory a l' o') ∧
    ownerMemory (graduateAt a o l compact full graph) labels o =
      ownerMemory a labels o + ((graduateBooks a.books compact full graph).2.foot - compact.foot) ∧
    ownerBytes (graduateAt a o l compact full graph) =
      ownerBytes a + ((graduateBooks a.books compact full graph).2.foot - compact.foot) ∧
    (OwnerSum a labels owners → OwnerSum (graduateAt a o l compact full graph) labels owners) := by
  have h := replace_isolates a o l (graduateBooks a.books compact full graph).2.foot labels owners hl hlm hon hom
    (graduateBooks a.books compact full graph).1 (by rw [graduate_books, hfoot])
  rw [hfoot] at h
  exact h

theorem graduate_fail_unchanged (a : Acct L) (compact : Block) (full graph : Int) :
    (graduateFailBooks a.books compact full graph).1 = a.books ∧ (graduateFailBooks a.books compact full graph).2 = compact := by
  rw [graduate_fail_books]
  exact ⟨rfl, rfl⟩

theorem flatten_isolates (a : Acct L) (o : Nat) (l : L) (fullBlock : Block) (compactUsable graph : Int)
    (labels : List L) (owners : List Nat) (hl : labels.Nodup) (hlm : l ∈ labels) (hon : owners.Nodup)
    (hom : o ∈ owners) (hfoot : a.owned o l = fullBlock.foot) :
    sharedBytes (flattenAt a o l fullBlock compactUsable graph) labels = sharedBytes a labels ∧
    (∀ l', labelMemory (flattenAt a o l fullBlock compactUsable graph) l' = labelMemory a l') ∧
    (flattenAt a o l fullBlock compactUsable graph).books.index = a.books.index ∧
    (∀ o', o' ≠ o → ownerMemory (flattenAt a o l fullBlock compactUsable graph) labels o' = ownerMemory a labels o') ∧
    (∀ l' o', (l', o') ≠ (l, o) →
      scopeMemory (flattenAt a o l fullBlock compactUsable graph) l' o' = scopeMemory a l' o') ∧
    ownerMemory (flattenAt a o l fullBlock compactUsable graph) labels o =
      ownerMemory a labels o + ((flattenBooks a.books fullBlock compactUsable graph).2.foot - fullBlock.foot) ∧
    ownerBytes (flattenAt a o l fullBlock compactUsable graph) =
      ownerBytes a + ((flattenBooks a.books fullBlock compactUsable graph).2.foot - fullBlock.foot) ∧
    (OwnerSum a labels owners → OwnerSum (flattenAt a o l fullBlock compactUsable graph) labels owners) := by
  have h := replace_isolates a o l (flattenBooks a.books fullBlock compactUsable graph).2.foot labels owners hl hlm hon hom
    (flattenBooks a.books fullBlock compactUsable graph).1 (by rw [flatten_books, hfoot])
  rw [hfoot] at h
  exact h

theorem graduate_footprint (compact : Block) (bk : Books) (full graph : Int) :
    (graduateBooks bk compact full graph).2.foot = full + compact.charge + graph := by
  simp only [graduateBooks, Block.foot]
  omega

theorem flatten_footprint (fullBlock : Block) (bk : Books) (compactUsable graph : Int) :
    (flattenBooks bk fullBlock compactUsable graph).2.foot = compactUsable + fullBlock.charge - graph := by
  simp only [flattenBooks, Block.foot]
  omega

theorem memory_identity (a : Acct L) (labels : List L) :
    memoryUsage a = sharedBytes a labels + (labels.map (labelMemory a)).sum + a.books.index + ownerBytes a := by
  have : labels.map (labelMemory a) = labels.map a.shared := rfl
  rw [this]
  simp only [memoryUsage, sharedBytes]
  omega

end Accounts

end Vectors
