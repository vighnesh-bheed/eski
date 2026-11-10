import Vectors.Partition

namespace Vectors

section Plain
set_option linter.unusedSectionVars false
variable {L N V P : Type} [DecidableEq L] [DecidableEq N]

structure PartLaws (ops : PartOps N V P) (names : P → List N) : Prop where
  mem_insert : ∀ p n v m, m ∈ names (ops.insert p n v) ↔ m = n ∨ m ∈ names p
  mem_update : ∀ p n v m, m ∈ names (ops.update p n v) ↔ m ∈ names p
  mem_setAttr : ∀ p n v m, m ∈ names (ops.setAttr p n v) ↔ m ∈ names p
  mem_remove : ∀ p n m, m ∈ names (ops.remove p n) ↔ m ≠ n ∧ m ∈ names p
  empty_iff : ∀ p, ops.empty p = true ↔ names p = []

def plainState (ops : PartOps N V P) (names : P → List N) (bottom : L) (stream : L → Nat) (p : P) :
    LState L N P :=
  { parts := fun l => if l = bottom then (if ops.empty p then none else some p) else none,
    index := fun n => if n ∈ names p then [bottom] else [],
    stream := stream }

def plainOp (ops : PartOps N V P) (names : P → List N) (op : WOp N V) (p : P) : P :=
  match op with
  | .add n v => if n ∈ names p then ops.update p n v else ops.insert p n v
  | .set n v => if n ∈ names p then ops.setAttr p n v else p
  | .rem n => if n ∈ names p then ops.remove p n else p
  | .drop => p
  | .draw _ => p

theorem plain_visibleOther (sees : L → L → Bool) (bottom : L) (ls : List L) (h : ∀ l ∈ ls, l = bottom) :
    visibleOther sees bottom ls = false := by
  unfold visibleOther
  rw [List.any_eq_false]
  intro l hl
  simp [h l hl]

theorem plain_write (ops : PartOps N V P) (names : P → List N) (laws : PartLaws ops names)
    (sees : L → L → Bool) (bottom : L) (stream : L → Nat) (p : P) (hne : ops.empty p = false)
    (op : WOp N V) (hop : ∀ n v, op = .add n v → ops.empty (ops.insert p n v) = false ∧ ops.empty (ops.update p n v) = false)
    (hset : ∀ n v, op = .set n v → ops.empty (ops.setAttr p n v) = false)
    (hkind : ∀ k, op ≠ .draw k) (hdrop : op ≠ .drop) :
    wstep ops sees ⟨bottom, op⟩ (plainState ops names bottom stream p) =
      plainState ops names bottom stream (plainOp ops names op p) := by
  have hpb : (plainState ops names bottom stream p).parts bottom = some p := by
    simp [plainState, hne]
  have hidx : ∀ n, (plainState ops names bottom stream p).index n = if n ∈ names p then [bottom] else [] :=
    fun n => rfl
  have hvo : ∀ n, visibleOther sees bottom ((plainState ops names bottom stream p).index n) = false := by
    intro n; apply plain_visibleOther; intro l hl; rw [hidx] at hl; split at hl <;> simp_all
  unfold wstep
  cases op with
  | add n v =>
    have he := hop n v rfl
    simp only
    by_cases hn : n ∈ names p
    · have hm : bottom ∈ (plainState ops names bottom stream p).index n := by rw [hidx]; simp [hn]
      simp only [hm, ↓reduceIte, hpb, plainOp, hn]
      apply state_ext
      · funext l; simp only [setPart, plainState]; split <;> simp_all
      · funext m; simp only [setPart, plainState]
        have := laws.mem_update p n v m
        by_cases h1 : m ∈ names p <;> simp_all
      · rfl
    · have hm : bottom ∉ (plainState ops names bottom stream p).index n := by rw [hidx]; simp [hn]
      simp only [hm, ↓reduceIte, hvo n, hpb, Bool.false_eq_true, plainOp, hn]
      apply state_ext
      · funext l; simp only [setIndex, setPart, plainState]; split <;> simp_all
      · funext m; simp only [setIndex, setPart, plainState]
        have := laws.mem_insert p n v m
        by_cases hmn : m = n
        · subst hmn; simp_all
        · by_cases h1 : m ∈ names p <;> simp_all
      · rfl
  | set n v =>
    have he := hset n v rfl
    simp only
    by_cases hn : n ∈ names p
    · have hm : bottom ∈ (plainState ops names bottom stream p).index n := by rw [hidx]; simp [hn]
      simp only [hm, ↓reduceIte, hpb, plainOp, hn]
      apply state_ext
      · funext l; simp only [setPart, plainState]; split <;> simp_all
      · funext m; simp only [setPart, plainState]
        have := laws.mem_setAttr p n v m
        by_cases h1 : m ∈ names p <;> simp_all
      · rfl
    · have hm : bottom ∉ (plainState ops names bottom stream p).index n := by rw [hidx]; simp [hn]
      simp only [hm, ↓reduceIte, plainOp, hn]
  | rem n =>
    simp only
    by_cases hn : n ∈ names p
    · have hm : bottom ∈ (plainState ops names bottom stream p).index n := by rw [hidx]; simp [hn]
      simp only [hm, ↓reduceIte, hpb, plainOp, hn]
      apply state_ext
      · funext l; simp only [setIndex, setPart, plainState]; split <;> simp_all
      · funext m; simp only [setIndex, setPart, plainState]
        have := laws.mem_remove p n m
        by_cases hmn : m = n
        · subst hmn; simp_all
        · by_cases h1 : m ∈ names p <;> simp_all
      · rfl
    · have hm : bottom ∉ (plainState ops names bottom stream p).index n := by rw [hidx]; simp [hn]
      simp only [hm, ↓reduceIte, plainOp, hn]
  | drop => exact absurd rfl hdrop
  | draw k => exact absurd rfl (hkind k)

theorem filter_eq_single (a : L) : ∀ (l : List L), l.Nodup → a ∈ l → l.filter (fun x => decide (x = a)) = [a] := by
  intro l
  induction l with
  | nil => intro _ h; simp at h
  | cons x xs ih =>
    intro hn hm
    rw [List.nodup_cons] at hn
    by_cases hx : x = a
    · subst hx
      rw [List.filter_cons_of_pos (by simp)]
      have : xs.filter (fun y => decide (y = x)) = [] := by
        rw [List.filter_eq_nil_iff]
        intro y hy e
        simp at e
        exact hn.1 (e ▸ hy)
      rw [this]
    · rw [List.filter_cons_of_neg (by simpa using hx)]
      exact ih hn.2 (by rcases List.mem_cons.mp hm with e | e; exact absurd e.symm hx; exact e)

theorem plain_viewOpen (ops : PartOps N V P) (names : P → List N) (acc : PartAcc N P)
    (le : L → L → Bool) (labelsU : List L) (namesU : List N) (r : ReaderOf L) (bottom : L)
    (stream : L → Nat) (p : P) (hne : ops.empty p = false) (hv : r.vis bottom = true)
    (hl : labelsU.Nodup) (hb : bottom ∈ labelsU) :
    viewOpen acc le labelsU namesU r (plainState ops names bottom stream p) =
      { labels := [bottom], shadows := [], size := acc.count p, attrs := acc.attrs p } := by
  have hvl : visibleLabels le labelsU r (plainState ops names bottom stream p) = [bottom] := by
    unfold visibleLabels
    have : labelsU.filter (inView r (plainState ops names bottom stream p)) =
        labelsU.filter (fun x => decide (x = bottom)) := by
      apply List.filter_congr
      intro l _
      simp only [inView, present, plainState]
      by_cases h : l = bottom
      · subst h; simp [hne, hv]
      · simp [h]
    rw [this, filter_eq_single bottom labelsU hl hb]
    exact List.mergeSort_of_pairwise (List.pairwise_singleton _ _)
  have hsh : ∀ n, shadowsOf r (plainState ops names bottom stream p) n = [] := by
    intro n
    unfold shadowsOf
    have : ((plainState ops names bottom stream p).index n).length ≤ 1 := by
      simp only [plainState]; split <;> simp
    have : ¬ 2 ≤ ((plainState ops names bottom stream p).index n).length := by omega
    simp only [this, ↓reduceIte]
  have hfm : namesU.flatMap (shadowsOf r (plainState ops names bottom stream p)) = [] := by
    rw [List.flatMap_eq_nil_iff]
    intro n _
    exact hsh n
  have hc : partCount acc (plainState ops names bottom stream p) bottom = acc.count p := by
    simp [partCount, plainState, hne]
  have ha : partAttrs acc (plainState ops names bottom stream p) bottom = acc.attrs p := by
    simp [partAttrs, plainState, hne]
  unfold viewOpen
  simp only
  rw [hvl, hfm]
  simp [hc, ha]

theorem plain_viewFind (ops : PartOps N V P) (names : P → List N) (r : ReaderOf L) (bottom : L)
    (stream : L → Nat) (p : P) (hne : ops.empty p = false) (hv : r.vis bottom = true) (n : N) :
    viewFind r (plainState ops names bottom stream p) n = if n ∈ names p then some bottom else none := by
  unfold viewFind
  by_cases hn : n ∈ names p
  · have hres : resolveL r ((plainState ops names bottom stream p).index n) = some bottom := by
      simp only [plainState, hn, ↓reduceIte]
      unfold resolveL resolveFrom
      by_cases ho : bottom = r.own
      · simp [ho]
      · simp [ho, hv]; rfl
    rw [hres]
    simp [inView, present, plainState, hne, hv, hn]
  · have hres : resolveL r ((plainState ops names bottom stream p).index n) = none := by
      simp only [plainState, hn, ↓reduceIte]; rfl
    rw [hres]
    simp [hn]

theorem filterMap_eq_map_of {α β : Type} (g : α → Option β) (f : α → β) :
    ∀ (xs : List α), (∀ x ∈ xs, g x = some (f x)) → xs.filterMap g = xs.map f := by
  intro xs
  induction xs with
  | nil => intro _; rfl
  | cons x xs ih =>
    intro h
    rw [List.filterMap_cons, h x (List.mem_cons_self ..), List.map_cons]
    simp only
    rw [ih (fun y hy => h y (List.mem_cons_of_mem x hy))]

theorem plain_viewRange (ops : PartOps N V P) (names : P → List N) (r : ReaderOf L) (bottom : L)
    (stream : L → Nat) (p : P) (hne : ops.empty p = false) (hv : r.vis bottom = true)
    (namesU : List N) (inRange : N → Bool) (limit : Option Nat) :
    viewRange r (plainState ops names bottom stream p) namesU inRange limit =
      (match limit with
       | some k => ((namesU.filter (fun n => inRange n && decide (n ∈ names p))).map (fun n => (n, bottom))).take k
       | none => (namesU.filter (fun n => inRange n && decide (n ∈ names p))).map (fun n => (n, bottom))) := by
  have key : (namesU.filter (fun n => inRange n && !((plainState ops names bottom stream p).index n).isEmpty)).filterMap
      (fun n => (viewFind r (plainState ops names bottom stream p) n).map (fun l => (n, l))) =
      (namesU.filter (fun n => inRange n && decide (n ∈ names p))).map (fun n => (n, bottom)) := by
    have hf : namesU.filter (fun n => inRange n && !((plainState ops names bottom stream p).index n).isEmpty) =
        namesU.filter (fun n => inRange n && decide (n ∈ names p)) := by
      apply List.filter_congr
      intro n _
      simp only [plainState]
      by_cases hn : n ∈ names p <;> simp [hn]
    rw [hf]
    apply filterMap_eq_map_of
    intro n hn
    rw [List.mem_filter] at hn
    have hm : n ∈ names p := by
      have := hn.2
      simp only [Bool.and_eq_true, decide_eq_true_eq] at this
      exact this.2
    rw [plain_viewFind ops names r bottom stream p hne hv n]
    simp [hm]
  unfold viewRange
  simp only
  rw [key]
  cases limit <;> rfl

theorem sorted_keys_eq {E K : Type} (le₁ le₂ : E → E → Bool) (kle : K → K → Bool) (hk : TotalLe kle)
    (score : E → K) (h₁ : ∀ a b, le₁ a b = true → kle (score a) (score b) = true)
    (h₂ : ∀ a b, le₂ a b = true → kle (score a) (score b) = true)
    (tr₁ : ∀ a b c, le₁ a b = true → le₁ b c = true → le₁ a c = true) (to₁ : ∀ a b, (le₁ a b || le₁ b a) = true)
    (tr₂ : ∀ a b c, le₂ a b = true → le₂ b c = true → le₂ a c = true) (to₂ : ∀ a b, (le₂ a b || le₂ b a) = true)
    (l : List E) : (l.mergeSort le₁).map score = (l.mergeSort le₂).map score := by
  have s₁ : ((l.mergeSort le₁).map score).Pairwise (fun a b => kle a b = true) := by
    rw [List.pairwise_map]
    exact (List.pairwise_mergeSort (fun a b c hab hbc => tr₁ a b c hab hbc) (fun a b => to₁ a b) l).imp
      (fun hab => h₁ _ _ hab)
  have s₂ : ((l.mergeSort le₂).map score).Pairwise (fun a b => kle a b = true) := by
    rw [List.pairwise_map]
    exact (List.pairwise_mergeSort (fun a b c hab hbc => tr₂ a b c hab hbc) (fun a b => to₂ a b) l).imp
      (fun hab => h₂ _ _ hab)
  have p : ((l.mergeSort le₁).map score).Perm ((l.mergeSort le₂).map score) :=
    ((List.mergeSort_perm l le₁).trans (List.mergeSort_perm l le₂).symm).map score
  exact List.Perm.eq_of_pairwise (fun a b _ _ hab hba => hk.antisymm a b hab hba) s₁ s₂ p

theorem plain_topk_scores {E K : Type} (le₁ le₂ : E → E → Bool) (kle : K → K → Bool) (hk : TotalLe kle)
    (score : E → K) (h₁ : ∀ a b, le₁ a b = true → kle (score a) (score b) = true)
    (h₂ : ∀ a b, le₂ a b = true → kle (score a) (score b) = true)
    (tr₁ : ∀ a b c, le₁ a b = true → le₁ b c = true → le₁ a c = true) (to₁ : ∀ a b, (le₁ a b || le₁ b a) = true)
    (tr₂ : ∀ a b c, le₂ a b = true → le₂ b c = true → le₂ a c = true) (to₂ : ∀ a b, (le₂ a b || le₂ b a) = true)
    (k : Nat) (l : List E) : (topk le₁ k l).map score = (topk le₂ k l).map score := by
  unfold topk
  rw [List.map_take, List.map_take, sorted_keys_eq le₁ le₂ kle hk score h₁ h₂ tr₁ to₁ tr₂ to₂ l]

end Plain

def scoreLe (a b : Option Int) : Bool := scoreBefore a b || decide (a = b)

theorem scoreLe_total : TotalLe scoreLe := by
  refine ⟨?_, ?_, ?_⟩
  · intro a b c hab hbc
    simp only [scoreLe, Bool.or_eq_true, decide_eq_true_eq] at hab hbc ⊢
    rcases hab with h1 | h1 <;> rcases hbc with h2 | h2
    · left; exact scoreBefore_trans _ _ _ h1 h2
    · left; rw [← h2]; exact h1
    · left; rw [h1]; exact h2
    · right; exact h1.trans h2
  · intro a b
    simp only [scoreLe, Bool.or_eq_true, decide_eq_true_eq]
    by_cases h : a = b
    · left; right; exact h
    · rcases scoreBefore_total a b h with e | e
      · left; left; exact e
      · right; left; exact e
  · intro a b hab hba
    simp only [scoreLe, Bool.or_eq_true, decide_eq_true_eq] at hab hba
    rcases hab with h1 | h1
    · rcases hba with h2 | h2
      · have := scoreBefore_trans _ _ _ h1 h2
        rw [scoreBefore_irrefl] at this
        exact absurd this (by decide)
      · exact h2.symm
    · exact h1

def seqLe (a b : Option Int × Nat) : Bool :=
  scoreBefore a.1 b.1 || (decide (a.1 = b.1) && decide (a.2 ≤ b.2))

theorem seqLe_total : TotalLe seqLe := by
  refine ⟨?_, ?_, ?_⟩
  · intro a b c hab hbc
    simp only [seqLe, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hab hbc ⊢
    rcases hab with h1 | ⟨h1, h2⟩ <;> rcases hbc with h3 | ⟨h3, h4⟩
    · left; exact scoreBefore_trans _ _ _ h1 h3
    · left; rw [← h3]; exact h1
    · left; rw [h1]; exact h3
    · right; exact ⟨h1.trans h3, by omega⟩
  · intro a b
    simp only [seqLe, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
    by_cases h : a.1 = b.1
    · by_cases h2 : a.2 ≤ b.2
      · left; right; exact ⟨h, h2⟩
      · right; right; exact ⟨h.symm, by omega⟩
    · rcases scoreBefore_total a.1 b.1 h with e | e
      · left; left; exact e
      · right; left; exact e
  · intro a b hab hba
    simp only [seqLe, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hab hba
    rcases hab with h1 | ⟨h1, h2⟩
    · rcases hba with h3 | ⟨h3, _⟩
      · have := scoreBefore_trans _ _ _ h1 h3
        rw [scoreBefore_irrefl] at this
        exact absurd this (by decide)
      · rw [h3, scoreBefore_irrefl] at h1
        exact absurd h1 (by decide)
    · rcases hba with h3 | ⟨_, h4⟩
      · rw [h1, scoreBefore_irrefl] at h3
        exact absurd h3 (by decide)
      · exact Prod.ext h1 (by omega)

structure PlainHit where
  score : Option Int
  name : List Nat
  seq : Nat
deriving DecidableEq, Repr

def plainNamed (a b : PlainHit) : Bool := hitLe (a.score, a.name) (b.score, b.name)

def plainSeq (a b : PlainHit) : Bool := seqLe (a.score, a.seq) (b.score, b.seq)

theorem plain_tie_orders_agree_on_scores (k : Nat) (l : List PlainHit) :
    (topk plainSeq k l).map PlainHit.score = (topk plainNamed k l).map PlainHit.score := by
  apply plain_topk_scores plainSeq plainNamed scoreLe scoreLe_total PlainHit.score
  · intro a b h
    simp only [plainSeq, seqLe, scoreLe, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at h ⊢
    rcases h with h | ⟨h, _⟩
    · left; exact h
    · right; exact h
  · intro a b h
    simp only [plainNamed, hitLe, scoreLe, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at h ⊢
    rcases h with h | ⟨h, _⟩
    · left; exact h
    · right; exact h
  · intro a b c hab hbc; exact seqLe_total.trans _ _ _ hab hbc
  · intro a b; exact seqLe_total.total _ _
  · intro a b c hab hbc; exact hitLe_total_order.trans _ _ _ hab hbc
  · intro a b; exact hitLe_total_order.total _ _

end Vectors
