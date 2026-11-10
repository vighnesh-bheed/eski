namespace Vectors

def freeMark : Nat := 2 ^ 31

def freeNil : Nat := 2 ^ 31 - 1

def nilSlot : Nat := 2 ^ 32 - 1

def arenaSlotLimit : Nat := 2 ^ 31 - 1

def expBits : Nat := 0x7F800000

def fracBits : Nat := 0x7FFFFF

def freeEntry (next : Nat) : Nat := freeMark ||| (if next = nilSlot then freeNil else next)

def freeNext (entry : Nat) : Nat := if entry &&& freeNil = freeNil then nilSlot else entry &&& freeNil

def isFreeEntry (entry : Nat) : Bool := entry &&& freeMark != 0

def isNaNBits (b : Nat) : Bool := b &&& expBits == expBits && b &&& fracBits != 0

def liveNorm (b : Nat) : Nat × Bool :=
  if b &&& freeMark = 0 then (b, true)
  else if isNaNBits b then (b &&& freeNil, true)
  else (b, false)

structure Arena where
  norms : List Nat
  cap : Nat
  free : Nat
  live : Nat
deriving Repr

def Arena.high (a : Arena) : Nat := a.norms.length

def normOf (norms : List Nat) (s : Nat) : Nat := norms[s]?.getD 0

def arenaInit (cap : Nat) : Arena := ⟨[], cap, nilSlot, 0⟩

inductive FreeError where
  | none
  | invalidSlot
  | alreadyFree
deriving DecidableEq, Repr

def arenaFree (a : Arena) (s : Nat) : FreeError × Arena :=
  if a.high ≤ s then (.invalidSlot, a)
  else if isFreeEntry (normOf a.norms s) then (.alreadyFree, a)
  else (.none, ⟨a.norms.set s (freeEntry a.free), a.cap, s, a.live - 1⟩)

def grownArena (cap : Nat) : Nat := min (max 1 (cap * 2)) arenaSlotLimit

def arenaAlloc (a : Arena) : Option (Nat × Arena) :=
  if a.free ≠ nilSlot then
    some (a.free, ⟨a.norms.set a.free 0, a.cap, freeNext (normOf a.norms a.free), a.live + 1⟩)
  else if a.high = a.cap then
    if arenaSlotLimit ≤ a.cap then none
    else some (a.high, ⟨a.norms ++ [0], grownArena a.cap, a.free, a.live + 1⟩)
  else some (a.high, ⟨a.norms ++ [0], a.cap, a.free, a.live + 1⟩)

def arenaSetNorm (a : Arena) (s b : Nat) : Bool × Arena :=
  if (liveNorm b).2 then (true, { a with norms := a.norms.set s (liveNorm b).1 }) else (false, a)

def arenaSetEncoded (a : Arena) (s b : Nat) : Arena := { a with norms := a.norms.set s (liveNorm b).1 }

def arenaIsLive (a : Arena) (s : Nat) : Bool := decide (s < a.high) && !isFreeEntry (normOf a.norms s)

def walkFree (norms : List Nat) : Nat → Nat → List Nat
  | 0, _ => []
  | fuel + 1, s => if s = nilSlot then [] else s :: walkFree norms fuel (freeNext (normOf norms s))

def ChainOk (norms : List Nat) (L : List Nat) : Prop :=
  ∀ i (h : i < L.length), normOf norms L[i] = freeEntry (L[i + 1]?.getD nilSlot)

structure ArenaInv (a : Arena) (L : List Nat) : Prop where
  cap_le : a.cap ≤ arenaSlotLimit
  high_le : a.high ≤ a.cap
  nodup : L.Nodup
  bound : ∀ s ∈ L, s < a.high
  head : a.free = L.headD nilSlot
  chain : ChainOk a.norms L
  live_clear : ∀ s, s < a.high → s ∉ L → normOf a.norms s < freeMark
  live_count : a.live + L.length = a.high

theorem bit31 (b : Nat) (h : b < 2 ^ 32) : b.testBit 31 = decide (2 ^ 31 ≤ b) := by
  rw [Nat.testBit_eq_decide_div_mod_eq]
  apply decide_eq_decide.mpr
  omega

theorem mark_zero_iff (b : Nat) (h : b < 2 ^ 32) : b &&& freeMark = 0 ↔ b < freeMark := by
  unfold freeMark
  constructor
  · intro hb
    have h1 := congrArg (fun x => Nat.testBit x 31) hb
    simp only [Nat.testBit_and, Nat.testBit_two_pow_self, Bool.and_true, Nat.zero_testBit] at h1
    rw [bit31 b h] at h1
    simpa using h1
  · intro hb
    apply Nat.eq_of_testBit_eq
    intro i
    rw [Nat.testBit_and, Nat.testBit_two_pow, Nat.zero_testBit]
    by_cases hi : 31 = i
    · subst hi; rw [Nat.testBit_lt_two_pow hb]; rfl
    · simp [hi]

theorem and_freeNil (b : Nat) : b &&& freeNil = b % 2 ^ 31 := Nat.and_two_pow_sub_one_eq_mod b 31

theorem isFree_iff (b : Nat) (h : b < 2 ^ 32) : isFreeEntry b = true ↔ freeMark ≤ b := by
  unfold isFreeEntry
  have := mark_zero_iff b h
  by_cases hb : b < freeMark
  · simp [this.mpr hb]; omega
  · have : b &&& freeMark ≠ 0 := fun e => hb (this.mp e)
    simp [this]; omega

theorem freeEntry_eq (n : Nat) (hn : n < freeNil ∨ n = nilSlot) :
    freeEntry n = freeMark + (if n = nilSlot then freeNil else n) := by
  unfold freeEntry
  have hlt : (if n = nilSlot then freeNil else n) < 2 ^ 31 := by
    unfold freeNil nilSlot at *; split <;> omega
  unfold freeMark
  rw [Nat.or_comm, Nat.or_two_pow_eq_add_of_lt hlt]
  omega

theorem freeEntry_spec (n : Nat) (hn : n < freeNil ∨ n = nilSlot) :
    freeEntry n < 2 ^ 32 ∧ isFreeEntry (freeEntry n) = true ∧ freeNext (freeEntry n) = n := by
  have he := freeEntry_eq n hn
  have hlt : freeEntry n < 2 ^ 32 := by
    rw [he]; unfold freeMark freeNil nilSlot at *; split <;> omega
  refine ⟨hlt, (isFree_iff _ hlt).mpr (by rw [he]; omega), ?_⟩
  unfold freeNext
  rw [and_freeNil, he]
  unfold freeMark freeNil nilSlot at *
  split
  · next h1 => subst h1; decide
  · next h1 =>
    have : (2 ^ 31 + n) % 2 ^ 31 = n := by omega
    rw [this]
    have : n ≠ 2 ^ 31 - 1 := by omega
    simp [this]

theorem liveNorm_lt (b : Nat) (hb : b < 2 ^ 32) : (liveNorm b).1 < 2 ^ 32 := by
  unfold liveNorm
  split
  · exact hb
  · split
    · rw [and_freeNil]; omega
    · exact hb

theorem liveNorm_clear (b : Nat) (hb : b < 2 ^ 32) :
    ((liveNorm b).2 = true ↔ b < freeMark ∨ isNaNBits b = true) ∧
      ((liveNorm b).2 = true → (liveNorm b).1 < freeMark) ∧ (b < freeMark → liveNorm b = (b, true)) := by
  have hz := mark_zero_iff b hb
  unfold liveNorm
  by_cases h1 : b < freeMark
  · simp [hz.mpr h1, h1]
  · have h2 : b &&& freeMark ≠ 0 := fun e => h1 (hz.mp e)
    simp only [h2, ite_false, h1, false_or, false_implies, and_true]
    split
    · next h3 => refine ⟨by simp [h3], fun _ => ?_⟩; rw [and_freeNil]; unfold freeMark; omega
    · next h3 => simp [h3]

theorem live_never_free (b : Nat) (hb : b < 2 ^ 32) (h : (liveNorm b).2 = true) :
    isFreeEntry (liveNorm b).1 = false := by
  have := (liveNorm_clear b hb).2.1 h
  cases hf : isFreeEntry (liveNorm b).1
  · rfl
  · have := (isFree_iff _ (liveNorm_lt b hb)).mp hf; omega

theorem encoded_norm_clear (b : Nat) (hb : b < 2 ^ 32) (h : b < freeMark ∨ isNaNBits b = true) :
    isFreeEntry (liveNorm b).1 = false :=
  live_never_free b hb ((liveNorm_clear b hb).1.mpr h)

theorem negative_zero_counterexample :
    (liveNorm 0x80000000).2 = false ∧ isFreeEntry (liveNorm 0x80000000).1 = true ∧
      (liveNorm 0xFFC00001).2 = true ∧ (liveNorm 0xFFC00001).1 = 0x7FC00001 := by decide

theorem normOf_set (norms : List Nat) (s v x : Nat) (hs : s < norms.length) :
    normOf (norms.set s v) x = if x = s then v else normOf norms x := by
  unfold normOf
  rw [List.getElem?_set]
  by_cases h : s = x
  · subst h; simp [hs]
  · simp [h, Ne.symm h]

theorem normOf_append (norms : List Nat) (x : Nat) (hx : x < norms.length) :
    normOf (norms ++ [0]) x = normOf norms x := by
  unfold normOf
  rw [List.getElem?_append_left hx]

theorem normOf_last (norms : List Nat) : normOf (norms ++ [0]) norms.length = 0 := by
  unfold normOf; simp

theorem chain_slot_lt {a : Arena} {L : List Nat} (h : ArenaInv a L) (s : Nat) (hs : s ∈ L) : s < freeNil := by
  have := h.bound s hs
  have := h.high_le
  have := h.cap_le
  unfold Arena.high at *
  unfold arenaSlotLimit freeNil at *
  omega

theorem arena_init_inv (c : Nat) (hc : c ≤ arenaSlotLimit) : ArenaInv (arenaInit c) [] := by
  refine ⟨hc, by simp [arenaInit, Arena.high], List.nodup_nil, by simp, rfl, fun i h => by simp at h,
    fun s hs => by simp [arenaInit, Arena.high] at hs, by simp [arenaInit, Arena.high]⟩

theorem arena_free_invalid (a : Arena) (s : Nat) (hs : a.high ≤ s) : arenaFree a s = (.invalidSlot, a) := by
  unfold arenaFree; simp [hs]

theorem chain_member_free {a : Arena} {L : List Nat} (h : ArenaInv a L) (s : Nat) (hs : s ∈ L) :
    isFreeEntry (normOf a.norms s) = true := by
  obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem hs
  rw [h.chain i hi]
  have : (L[i + 1]?.getD nilSlot) < freeNil ∨ (L[i + 1]?.getD nilSlot) = nilSlot := by
    cases hn : L[i + 1]? with
    | none => right; rfl
    | some y => left; exact chain_slot_lt h y (List.mem_of_getElem? hn)
  exact (freeEntry_spec _ this).2.1

theorem arena_free_already (a : Arena) (L : List Nat) (h : ArenaInv a L) (s : Nat) (hs : s ∈ L) :
    arenaFree a s = (.alreadyFree, a) := by
  have hlt := h.bound s hs
  have hf := chain_member_free h s hs
  unfold arenaFree
  simp only [show ¬ (a.high ≤ s) by omega, ite_false, hf, ite_true]

theorem norm_word_lt {a : Arena} {L : List Nat} (h : ArenaInv a L) (s : Nat) (hs : s < a.high) :
    normOf a.norms s < 2 ^ 32 := by
  by_cases hm : s ∈ L
  · obtain ⟨i, hi, rfl⟩ := List.getElem_of_mem hm
    rw [h.chain i hi]
    have : (L[i + 1]?.getD nilSlot) < freeNil ∨ (L[i + 1]?.getD nilSlot) = nilSlot := by
      cases hn : L[i + 1]? with
      | none => right; rfl
      | some y => left; exact chain_slot_lt h y (List.mem_of_getElem? hn)
    exact (freeEntry_spec _ this).1
  · have := h.live_clear s hs hm; unfold freeMark at this; omega

theorem arena_live_iff (a : Arena) (L : List Nat) (h : ArenaInv a L) (s : Nat) :
    arenaIsLive a s = true ↔ s < a.high ∧ s ∉ L := by
  unfold arenaIsLive
  by_cases hs : s < a.high
  · simp only [hs, decide_true, Bool.true_and, Bool.not_eq_eq_eq_not, Bool.not_true, true_and]
    constructor
    · intro hf hm; rw [chain_member_free h s hm] at hf; exact absurd hf (by simp)
    · intro hm
      have := h.live_clear s hs hm
      cases hf : isFreeEntry (normOf a.norms s)
      · rfl
      · have := (isFree_iff _ (norm_word_lt h s hs)).mp hf; omega
  · simp [hs]

theorem headD_spec (L : List Nat) (y : Nat) : L.headD y = (L[0]?.getD y) := by
  cases L <;> rfl

theorem arena_free_spec (a : Arena) (L : List Nat) (h : ArenaInv a L) (s : Nat) (hs : s < a.high) (hm : s ∉ L) :
    (arenaFree a s).1 = .none ∧ ArenaInv (arenaFree a s).2 (s :: L) := by
  have hnf : isFreeEntry (normOf a.norms s) = false := by
    have := (arena_live_iff a L h s).mpr ⟨hs, hm⟩
    unfold arenaIsLive at this
    simpa [hs] using this
  have hfree : arenaFree a s = (.none, ⟨a.norms.set s (freeEntry a.free), a.cap, s, a.live - 1⟩) := by
    unfold arenaFree; simp [show ¬ (a.high ≤ s) by omega, hnf]
  rw [hfree]
  have hlen : (a.norms.set s (freeEntry a.free)).length = a.high := by simp [Arena.high]
  refine ⟨rfl, ⟨h.cap_le, ?_, ?_, ?_, rfl, ?_, ?_, ?_⟩⟩
  · show (a.norms.set s (freeEntry a.free)).length ≤ a.cap
    rw [hlen]; exact h.high_le
  · exact List.nodup_cons.mpr ⟨hm, h.nodup⟩
  · intro x hx
    show x < (a.norms.set s (freeEntry a.free)).length
    rw [hlen]
    rcases List.mem_cons.mp hx with rfl | hx
    · exact hs
    · exact h.bound x hx
  · intro i hi
    show normOf (a.norms.set s (freeEntry a.free)) (s :: L)[i] = freeEntry ((s :: L)[i + 1]?.getD nilSlot)
    rw [normOf_set _ _ _ _ hs]
    cases i with
    | zero =>
      simp only [List.getElem_cons_zero, ite_true, List.getElem?_cons_succ]
      rw [h.head, headD_spec]
    | succ i =>
      simp only [List.getElem_cons_succ, List.getElem?_cons_succ]
      have hi' : i < L.length := by simp at hi; omega
      have hne : L[i] ≠ s := fun e => hm (e ▸ List.getElem_mem hi')
      rw [ite_eq_right hne, h.chain i hi']
  · intro x hx hxm
    have hx' : x < a.high := by
      have h2 : x < (a.norms.set s (freeEntry a.free)).length := hx
      rwa [hlen] at h2
    have hxs : x ≠ s := fun e => hxm (e ▸ List.mem_cons_self)
    rw [normOf_set _ _ _ _ hs, ite_eq_right hxs]
    exact h.live_clear x hx' (fun e => hxm (List.mem_cons_of_mem _ e))
  · show a.live - 1 + (L.length + 1) = (a.norms.set s (freeEntry a.free)).length
    rw [hlen]
    have := h.live_count
    have : L.length < a.high := by
      have hsub : (s :: L).Nodup := List.nodup_cons.mpr ⟨hm, h.nodup⟩
      have hb : ∀ x ∈ s :: L, x < a.high := by
        intro x hx; rcases List.mem_cons.mp hx with rfl | hx
        · exact hs
        · exact h.bound x hx
      have := List.Nodup.length_le_of_subset (l₂ := List.range a.high) hsub (fun x hx => List.mem_range.mpr (hb x hx))
      simp at this; omega
    omega

theorem double_free_detected (a : Arena) (L : List Nat) (h : ArenaInv a L) (s : Nat) (hs : s < a.high) (hm : s ∉ L) :
    arenaFree (arenaFree a s).2 s = (.alreadyFree, (arenaFree a s).2) := by
  obtain ⟨_, h2⟩ := arena_free_spec a L h s hs hm
  exact arena_free_already _ _ h2 s List.mem_cons_self

theorem arena_alloc_spec (a : Arena) (L : List Nat) (h : ArenaInv a L) (s : Nat) (a' : Arena)
    (ha : arenaAlloc a = some (s, a')) :
    ArenaInv a' L.tail ∧ ((L ≠ [] ∧ L.head? = some s) ∨ (L = [] ∧ s = a.high)) ∧
      arenaIsLive a s = false ∧ arenaIsLive a' s = true := by
  have hdead : arenaIsLive a s = false → arenaIsLive a s = false := id
  cases L with
  | cons x rest =>
    have hfx : a.free = x := h.head
    have hxn : x ≠ nilSlot := by have := chain_slot_lt h x List.mem_cons_self; unfold nilSlot freeNil at *; omega
    unfold arenaAlloc at ha
    rw [ite_eq_left (by rw [hfx]; exact hxn)] at ha
    simp only [Option.some.injEq, Prod.mk.injEq] at ha
    obtain ⟨hs, ha'⟩ := ha
    rw [hfx] at hs ha'
    subst hs ha'
    have hxl : x < a.high := h.bound x List.mem_cons_self
    have hlen : (a.norms.set x 0).length = a.high := by simp [Arena.high]
    have hnd := List.nodup_cons.mp h.nodup
    have hnext : freeNext (normOf a.norms x) = rest.headD nilSlot := by
      have := h.chain 0 (by simp)
      simp only [List.getElem_cons_zero, List.getElem?_cons_succ] at this
      rw [this, headD_spec]
      have : (rest[0]?.getD nilSlot) < freeNil ∨ (rest[0]?.getD nilSlot) = nilSlot := by
        cases hn : rest[0]? with
        | none => right; rfl
        | some y => left; exact chain_slot_lt h y (List.mem_cons_of_mem _ (List.mem_of_getElem? hn))
      exact (freeEntry_spec _ this).2.2
    refine ⟨⟨h.cap_le, ?_, hnd.2, ?_, ?_, ?_, ?_, ?_⟩, Or.inl ⟨by simp, rfl⟩, ?_, ?_⟩
    · show (a.norms.set x 0).length ≤ a.cap
      rw [hlen]; exact h.high_le
    · intro y hy
      show y < (a.norms.set x 0).length
      rw [hlen]; exact h.bound y (List.mem_cons_of_mem _ hy)
    · exact hnext
    · intro i hi
      have hi2 : i < rest.length := by simpa using hi
      show normOf (a.norms.set x 0) rest[i] = freeEntry (rest[i + 1]?.getD nilSlot)
      have hne : rest[i] ≠ x := fun e => hnd.1 (e ▸ List.getElem_mem hi2)
      rw [normOf_set _ _ _ _ hxl, ite_eq_right hne]
      have := h.chain (i + 1) (by simp only [List.length_cons]; omega)
      simpa using this
    · intro y hy hym
      have hy' : y < a.high := by
        have h2 : y < (a.norms.set x 0).length := hy
        rwa [hlen] at h2
      rw [normOf_set _ _ _ _ hxl]
      split
      · unfold freeMark; omega
      · next hyx => exact h.live_clear y hy' (fun e => by rcases List.mem_cons.mp e with e | e; exact hyx e; exact hym e)
    · show a.live + 1 + rest.length = (a.norms.set x 0).length
      rw [hlen]; have := h.live_count; simp at this; omega
    · cases hl : arenaIsLive a x
      · rfl
      · have := ((arena_live_iff a _ h x).mp hl).2; exact absurd List.mem_cons_self this
    · unfold arenaIsLive
      simp only [show x < (⟨a.norms.set x 0, a.cap, freeNext (normOf a.norms x), a.live + 1⟩ : Arena).high from
        by show x < (a.norms.set x 0).length; rw [hlen]; exact hxl, decide_true, Bool.true_and]
      show (!isFreeEntry (normOf (a.norms.set x 0) x)) = true
      rw [normOf_set _ _ _ _ hxl, ite_eq_left rfl]; decide
  | nil =>
    have hfn : a.free = nilSlot := h.head
    unfold arenaAlloc at ha
    rw [ite_eq_right (by rw [hfn]; exact fun e => e rfl)] at ha
    have hcommon : ∀ c, a.high < c → c ≤ arenaSlotLimit → ArenaInv ⟨a.norms ++ [0], c, a.free, a.live + 1⟩ [] ∧
        arenaIsLive ⟨a.norms ++ [0], c, a.free, a.live + 1⟩ a.high = true := by
      intro c hc1 hc2
      have hlen : (a.norms ++ [0]).length = a.high + 1 := by simp [Arena.high]
      refine ⟨⟨hc2, ?_, List.nodup_nil, by simp, h.head, fun i hi => by simp at hi, ?_, ?_⟩, ?_⟩
      · show (a.norms ++ [0]).length ≤ c
        rw [hlen]; omega
      · intro y hy _
        have hy' : y < a.high + 1 := by
          have h2 : y < (a.norms ++ [0]).length := hy
          rwa [hlen] at h2
        by_cases hyl : y < a.high
        · rw [normOf_append _ _ hyl]; exact h.live_clear y hyl (by simp)
        · have : y = a.norms.length := by unfold Arena.high at hyl hy'; omega
          rw [this, normOf_last]; unfold freeMark; omega
      · show a.live + 1 + 0 = (a.norms ++ [0]).length
        rw [hlen]; have := h.live_count; simp at this; omega
      · unfold arenaIsLive
        simp only [show a.high < (⟨a.norms ++ [0], c, a.free, a.live + 1⟩ : Arena).high from
          by show a.high < (a.norms ++ [0]).length; rw [hlen]; omega, decide_true, Bool.true_and]
        show (!isFreeEntry (normOf (a.norms ++ [0]) a.norms.length)) = true
        rw [normOf_last]; decide
    have hdead' : arenaIsLive a a.high = false := by unfold arenaIsLive; simp
    split at ha
    · next hfull =>
      split at ha
      · exact absurd ha (by simp)
      · next hlim =>
        simp only [Option.some.injEq, Prod.mk.injEq] at ha
        obtain ⟨rfl, rfl⟩ := ha
        have hg : a.high < grownArena a.cap ∧ grownArena a.cap ≤ arenaSlotLimit := by
          unfold grownArena; omega
        obtain ⟨i1, i2⟩ := hcommon _ hg.1 hg.2
        exact ⟨i1, Or.inr ⟨rfl, rfl⟩, hdead', i2⟩
    · next hnot =>
      simp only [Option.some.injEq, Prod.mk.injEq] at ha
      obtain ⟨rfl, rfl⟩ := ha
      have : a.high < a.cap := by have := h.high_le; omega
      obtain ⟨i1, i2⟩ := hcommon _ this h.cap_le
      exact ⟨i1, Or.inr ⟨rfl, rfl⟩, hdead', i2⟩

theorem arena_alloc_none (a : Arena) (L : List Nat) (h : ArenaInv a L) :
    arenaAlloc a = none ↔ L = [] ∧ a.high = a.cap ∧ arenaSlotLimit ≤ a.cap := by
  cases L with
  | cons x rest =>
    have hfx : a.free = x := h.head
    have hxn : x ≠ nilSlot := by have := chain_slot_lt h x List.mem_cons_self; unfold nilSlot freeNil at *; omega
    unfold arenaAlloc
    rw [ite_eq_left (by rw [hfx]; exact hxn)]
    simp
  | nil =>
    have hfn : a.free = nilSlot := h.head
    unfold arenaAlloc
    rw [ite_eq_right (by rw [hfn]; exact fun e => e rfl)]
    by_cases h1 : a.high = a.cap
    · by_cases h2 : arenaSlotLimit ≤ a.cap <;> simp [h1, h2]
    · simp [h1]

theorem inv_set_live (a : Arena) (L : List Nat) (h : ArenaInv a L) (s v : Nat) (hs : s < a.high) (hm : s ∉ L)
    (hv : v < freeMark) : ArenaInv { a with norms := a.norms.set s v } L := by
  have hlen : (a.norms.set s v).length = a.high := by simp [Arena.high]
  refine ⟨h.cap_le, ?_, h.nodup, ?_, h.head, ?_, ?_, ?_⟩
  · show (a.norms.set s v).length ≤ a.cap
    rw [hlen]; exact h.high_le
  · intro x hx
    show x < (a.norms.set s v).length
    rw [hlen]; exact h.bound x hx
  · intro i hi
    have hne : L[i] ≠ s := fun e => hm (e ▸ List.getElem_mem hi)
    show normOf (a.norms.set s v) L[i] = _
    rw [normOf_set _ _ _ _ hs, ite_eq_right hne]; exact h.chain i hi
  · intro x hx hxm
    have hx' : x < a.high := by
      have h2 : x < (a.norms.set s v).length := hx
      rwa [hlen] at h2
    show normOf (a.norms.set s v) x < freeMark
    rw [normOf_set _ _ _ _ hs]
    split
    · exact hv
    · exact h.live_clear x hx' hxm
  · show a.live + L.length = (a.norms.set s v).length
    rw [hlen]; exact h.live_count

theorem arena_set_spec (a : Arena) (L : List Nat) (h : ArenaInv a L) (s b : Nat) (hs : s < a.high) (hm : s ∉ L)
    (hb : b < 2 ^ 32) :
    ArenaInv (arenaSetNorm a s b).2 L ∧ ((arenaSetNorm a s b).1 = true ↔ b < freeMark ∨ isNaNBits b = true) := by
  obtain ⟨c1, c2, _⟩ := liveNorm_clear b hb
  unfold arenaSetNorm
  split
  · next hok => exact ⟨inv_set_live a L h s _ hs hm (c2 hok), by simp only [true_iff]; exact c1.mp hok⟩
  · next hok => exact ⟨h, by simp only [Bool.false_eq_true, false_iff]; intro e; exact hok (c1.mpr e)⟩

theorem arena_set_encoded_spec (a : Arena) (L : List Nat) (h : ArenaInv a L) (s b : Nat) (hs : s < a.high)
    (hm : s ∉ L) (hb : b < 2 ^ 32) (hpos : b < freeMark ∨ isNaNBits b = true) :
    ArenaInv (arenaSetEncoded a s b) L := by
  exact inv_set_live a L h s _ hs hm ((liveNorm_clear b hb).2.1 ((liveNorm_clear b hb).1.mpr hpos))

theorem walk_chain (norms : List Nat) : ∀ (L : List Nat) (fuel : Nat), ChainOk norms L → (∀ x ∈ L, x < freeNil) →
    L.length < fuel → walkFree norms fuel (L.headD nilSlot) = L := by
  intro L
  induction L with
  | nil =>
    intro fuel _ _ hf
    cases fuel with
    | zero => omega
    | succ f => simp [walkFree, List.headD]
  | cons x rest ih =>
    intro fuel hc hb hf
    cases fuel with
    | zero => simp at hf
    | succ f =>
      have hx := hb x List.mem_cons_self
      have hxn : x ≠ nilSlot := by unfold nilSlot freeNil at *; omega
      simp only [walkFree, List.headD, hxn, ite_false]
      have h0 := hc 0 (by simp)
      simp only [List.getElem_cons_zero, List.getElem?_cons_succ] at h0
      have hn : (rest[0]?.getD nilSlot) < freeNil ∨ (rest[0]?.getD nilSlot) = nilSlot := by
        cases hr : rest[0]? with
        | none => right; rfl
        | some y => left; exact hb y (List.mem_cons_of_mem _ (List.mem_of_getElem? hr))
      rw [h0, (freeEntry_spec _ hn).2.2, ← headD_spec]
      have hc' : ChainOk norms rest := by
        intro i hi
        have := hc (i + 1) (by simp; omega)
        simpa using this
      rw [ih f hc' (fun y hy => hb y (List.mem_cons_of_mem _ hy)) (by simp at hf; omega)]

theorem free_walk (a : Arena) (L : List Nat) (h : ArenaInv a L) : walkFree a.norms (a.high + 1) a.free = L := by
  rw [h.head]
  have hlen : L.length ≤ a.high := by
    have := List.Nodup.length_le_of_subset (l₂ := List.range a.high) h.nodup (fun x hx => List.mem_range.mpr (h.bound x hx))
    simpa using this
  exact walk_chain a.norms L (a.high + 1) h.chain (fun x hx => chain_slot_lt h x hx) (by omega)

end Vectors
