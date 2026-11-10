import Vectors.Graph
import Vectors.Width

namespace Vectors

def noneId : Nat := 2 ^ 32 - 1

def lvlFree : Nat := 255

def lvlReserved : Nat := 254

def lvlTwin : Nat := 253

def levelCap : Nat := 30

structure Ix where
  slots : Nat
  level : Nat → Nat
  next : Nat → Nat
  prev : Nat → Nat
  adj : Nat → Nat → List Nat
  free : List Nat
  twins : Nat
  live : Nat
  entry : Nat
  maxLevel : Nat

def countB (f : Nat → Bool) : Nat → Nat
  | 0 => 0
  | n + 1 => countB f n + (if f n then 1 else 0)

def iter (f : Nat → Nat) : Nat → Nat → Nat
  | 0, x => x
  | k + 1, x => iter f k (f x)

namespace Ix

def present (ix : Ix) (l x : Nat) : Bool :=
  decide (x < ix.slots) && decide (ix.level x ≤ levelCap) && decide (l ≤ ix.level x)

def layer (ix : Ix) (l : Nat) : Graph := ⟨ix.present l, ix.adj l⟩

def isNode (ix : Ix) (x : Nat) : Prop := x < ix.slots ∧ ix.level x ≤ levelCap

def isTwin (ix : Ix) (x : Nat) : Prop := x < ix.slots ∧ ix.level x = lvlTwin

def isLive (ix : Ix) (x : Nat) : Prop := x < ix.slots ∧ ix.level x < lvlReserved

def isReserved (ix : Ix) (x : Nat) : Prop := x < ix.slots ∧ ix.level x = lvlReserved

def nodeCount (ix : Ix) : Nat := countB (fun x => decide (ix.level x ≤ levelCap)) ix.slots

def twinCount (ix : Ix) : Nat := countB (fun x => ix.level x == lvlTwin) ix.slots

def setLevel (ix : Ix) (x b : Nat) : Ix := { ix with level := fun y => if y = x then b else ix.level y }

def setNext (ix : Ix) (x v : Nat) : Ix := { ix with next := fun y => if y = x then v else ix.next y }

def setPrev (ix : Ix) (x v : Nat) : Ix := { ix with prev := fun y => if y = x then v else ix.prev y }

def clearAdj (ix : Ix) (x : Nat) : Ix := { ix with adj := fun l y => if y = x then [] else ix.adj l y }

def withLayer (ix : Ix) (l : Nat) (g : Graph) : Ix := { ix with adj := fun l' => if l' = l then g.adj else ix.adj l' }

end Ix

def GraphWf (m : Nat) (ix : Ix) : Prop := ∀ l, Wf (layerCap m l) (ix.layer l)

structure TwinInv (ix : Ix) : Prop where
  slots_le : ix.slots ≤ hnswSlotLimit
  bytes : ∀ x, x < ix.slots → ix.level x ≤ levelCap ∨ ix.level x = lvlTwin ∨ ix.level x = lvlReserved ∨
    ix.level x = lvlFree
  next_live : ∀ x, ix.next x ≠ noneId → ix.isLive x ∧ ix.isTwin (ix.next x)
  prev_next : ∀ t, ix.isTwin t → ix.next (ix.prev t) = t
  next_prev : ∀ x, ix.next x ≠ noneId → ix.prev (ix.next x) = x
  rank : ∃ r : Nat → Nat, ∀ t, ix.isTwin t → ix.isNode (ix.prev t) ∨ (ix.isTwin (ix.prev t) ∧ r (ix.prev t) < r t)
  free_iff : ∀ x, x ∈ ix.free ↔ x < ix.slots ∧ ix.level x = lvlFree
  free_nodup : ix.free.Nodup
  twins_eq : ix.twins = ix.twinCount
  live_eq : ix.live = ix.nodeCount + ix.twinCount
  entry_live : 0 < ix.live → ix.isNode ix.entry ∧ ix.level ix.entry = ix.maxLevel ∧
    ∀ x, ix.isNode x → ix.level x ≤ ix.maxLevel
  entry_none : ix.live = 0 → ix.entry = noneId

def emptyIx : Ix := ⟨0, fun _ => lvlFree, fun _ => noneId, fun _ => 0, fun _ _ => [], [], 0, 0, noneId, 0⟩

theorem countB_congr (f g : Nat → Bool) : ∀ n, (∀ x, x < n → f x = g x) → countB f n = countB g n := by
  intro n
  induction n with
  | zero => intro _; rfl
  | succ n ih =>
    intro h
    simp only [countB]
    rw [ih (fun x hx => h x (by omega)), h n (by omega)]

theorem countB_update (f : Nat → Bool) (x : Nat) (b : Bool) : ∀ n, x < n →
    countB (fun y => if y = x then b else f y) n + (if f x then 1 else 0) = countB f n + (if b then 1 else 0) := by
  intro n
  induction n with
  | zero => intro h; omega
  | succ n ih =>
    intro hx
    simp only [countB]
    by_cases hn : n = x
    · subst hn
      have : countB (fun y => if y = n then b else f y) n = countB f n :=
        countB_congr _ _ n (fun y hy => by simp [show y ≠ n by omega])
      rw [this]; simp only [ite_true]; omega
    · have := ih (by omega)
      simp only [hn, ite_false]
      omega

theorem countB_pos (f : Nat → Bool) (x : Nat) : ∀ n, x < n → f x = true → 0 < countB f n := by
  intro n
  induction n with
  | zero => intro h; omega
  | succ n ih =>
    intro hx hf
    simp only [countB]
    by_cases hn : n = x
    · subst hn; simp [hf]
    · have := ih (by omega) hf; omega

theorem countB_zero (f : Nat → Bool) : ∀ n, countB f n = 0 → ∀ x, x < n → f x = false := by
  intro n
  induction n with
  | zero => intro _ x hx; omega
  | succ n ih =>
    intro h x hx
    simp only [countB] at h
    by_cases hn : x = n
    · subst hn
      cases hfx : f x
      · rfl
      · simp [hfx] at h
    · exact ih (by omega) x (by omega)

theorem countB_eq_filter (f : Nat → Bool) : ∀ n, countB f n = ((List.range n).filter f).length := by
  intro n
  induction n with
  | zero => rfl
  | succ n ih =>
    simp only [countB, List.range_succ, List.filter_append, List.length_append, ih]
    cases hf : f n <;> simp [List.filter, hf]

theorem countB_bound (f : Nat → Bool) (n : Nat) (L : List Nat) (hL : L.Nodup) (hm : ∀ x ∈ L, x < n ∧ f x = true) :
    L.length ≤ countB f n := by
  rw [countB_eq_filter]
  apply List.Nodup.length_le_of_subset hL
  intro x hx
  obtain ⟨h1, h2⟩ := hm x hx
  exact List.mem_filter.mpr ⟨List.mem_range.mpr h1, h2⟩

theorem iter_succ' (f : Nat → Nat) : ∀ k x, iter f (k + 1) x = f (iter f k x) := by
  intro k
  induction k with
  | zero => intro x; rfl
  | succ k ih => intro x; show iter f (k + 1) (f x) = f (iter f (k + 1) x); rw [ih (f x)]; rfl

section derived

variable {ix : Ix} (h : TwinInv ix)
include h

theorem twin_kinds (x : Nat) (hx : x < ix.slots) :
    (ix.isLive x ↔ ix.isNode x ∨ ix.isTwin x) ∧ ¬ (ix.isNode x ∧ ix.isTwin x) := by
  have hb := h.bytes x hx
  unfold Ix.isLive Ix.isNode Ix.isTwin levelCap lvlTwin lvlReserved lvlFree at *
  omega

theorem twin_free_next (x : Nat) (hk : ix.level x = lvlReserved ∨ ix.level x = lvlFree) :
    ix.next x = noneId := by
  by_cases hn : ix.next x = noneId
  · exact hn
  · have := (h.next_live x hn).1
    unfold Ix.isLive lvlReserved lvlFree at *
    omega

theorem twin_prev_live (t : Nat) (ht : ix.isTwin t) : ix.isLive (ix.prev t) := by
  have := h.prev_next t ht
  have hne : ix.next (ix.prev t) ≠ noneId := by
    rw [this]; have := ht.1; have := h.slots_le; unfold hnswSlotLimit noneId at *; omega
  exact (h.next_live _ hne).1

theorem twin_heads_one (t1 t2 : Nat) (h1 : ix.isTwin t1) (h2 : ix.isTwin t2) (he : ix.prev t1 = ix.prev t2) :
    t1 = t2 := by
  rw [← h.prev_next t1 h1, ← h.prev_next t2 h2, he]

theorem twin_head_reached (t : Nat) (ht : ix.isTwin t) :
    ∃ k, ix.isNode (iter ix.prev k t) ∧ (∀ i, i < k → ix.isTwin (iter ix.prev i t)) ∧ k ≤ ix.twins := by
  obtain ⟨r, hr⟩ := h.rank
  have key : ∀ n t, r t = n → ix.isTwin t → ∃ k, 0 < k ∧ ix.isNode (iter ix.prev k t) ∧
      (∀ i, i < k → ix.isTwin (iter ix.prev i t)) ∧
      List.Pairwise (fun a b => r b < r a) ((List.range k).map (fun i => iter ix.prev i t)) := by
    intro n
    induction n using Nat.strongRecOn with
    | _ n ih =>
      intro t hn ht
      rcases hr t ht with hp | ⟨hp, hlt⟩
      · refine ⟨1, by omega, hp, fun i hi => ?_, by simp⟩
        have : i = 0 := by omega
        subst this; exact ht
      · obtain ⟨k, hk0, hk1, hk2, hk3⟩ := ih (r (ix.prev t)) (by omega) (ix.prev t) rfl hp
        refine ⟨k + 1, by omega, hk1, fun i hi => ?_, ?_⟩
        · cases i with
          | zero => exact ht
          | succ i => exact hk2 i (by omega)
        · rw [List.range_succ_eq_map, List.map_cons, List.map_map]
          refine List.pairwise_cons.mpr ⟨fun a ha => ?_, ?_⟩
          · simp only [List.mem_map, List.mem_range, Function.comp] at ha
            obtain ⟨i, hi, rfl⟩ := ha
            show r (iter ix.prev (i + 1) t) < r (iter ix.prev 0 t)
            have : ∀ j, j < k → r (iter ix.prev j (ix.prev t)) ≤ r (ix.prev t) := by
              intro j hj
              have hpw := hk3
              cases j with
              | zero => exact Nat.le_refl _
              | succ j =>
                have := List.pairwise_iff_getElem.mp hpw 0 (j + 1) (by simp; omega) (by simp; omega) (by omega)
                simp at this
                exact Nat.le_of_lt this
            have := this i hi
            show r (iter ix.prev i (ix.prev t)) < r t
            omega
          · have : (List.map ((fun i => iter ix.prev i t) ∘ fun x => x + 1) (List.range k)) =
                (List.range k).map (fun i => iter ix.prev i (ix.prev t)) := by
              apply List.map_congr_left; intro i _; rfl
            rw [this]; exact hk3
  obtain ⟨k, _, hk1, hk2, hk3⟩ := key (r t) t rfl ht
  refine ⟨k, hk1, hk2, ?_⟩
  have hnd : ((List.range k).map (fun i => iter ix.prev i t)).Nodup :=
    hk3.imp (fun {a b} hab e => by subst e; omega)
  have := countB_bound (fun x => ix.level x == lvlTwin) ix.slots _ hnd (by
    intro x hx
    simp only [List.mem_map, List.mem_range] at hx
    obtain ⟨i, hi, rfl⟩ := hx
    have := hk2 i hi
    exact ⟨this.1, by simp [this.2]⟩)
  rw [h.twins_eq]
  unfold Ix.twinCount
  simpa using this

theorem twin_chain_ends (x : Nat) : ∃ k, k ≤ ix.twins + 1 ∧ iter ix.next k x = noneId := by
  obtain ⟨r, hr⟩ := h.rank
  by_cases hex : ∃ k, k ≤ ix.twins + 1 ∧ iter ix.next k x = noneId
  · exact hex
  exfalso
  have hno := hex
  have hall : ∀ k, k ≤ ix.twins + 1 → iter ix.next k x ≠ noneId := fun k hk e => hno ⟨k, hk, e⟩
  have htw : ∀ k, k ≤ ix.twins → ix.isTwin (iter ix.next (k + 1) x) := by
    intro k hk
    have e : iter ix.next (k + 1) x = ix.next (iter ix.next k x) := iter_succ' ix.next k x
    have hne : ix.next (iter ix.next k x) ≠ noneId := by rw [← e]; exact hall (k + 1) (by omega)
    rw [e]
    exact (h.next_live _ hne).2
  have hrk : ∀ k, k < ix.twins → r (iter ix.next (k + 1) x) < r (iter ix.next (k + 2) x) := by
    intro k hk
    have ht := htw (k + 1) (by omega)
    have e : iter ix.next (k + 2) x = ix.next (iter ix.next (k + 1) x) := iter_succ' ix.next (k + 1) x
    have hp : ix.prev (iter ix.next (k + 2) x) = iter ix.next (k + 1) x := by
      rw [e]
      exact h.next_prev _ (by rw [← e]; exact hall (k + 2) (by omega))
    rcases hr _ ht with hn | ⟨_, hlt⟩
    · rw [hp] at hn
      exact absurd (htw k (by omega)) (fun h2 => (twin_kinds h _ hn.1).2 ⟨hn, h2⟩)
    · rw [hp] at hlt; exact hlt
  have hmono : ∀ i j, i < j → j ≤ ix.twins → r (iter ix.next (i + 1) x) < r (iter ix.next (j + 1) x) := by
    intro i j hij hj
    induction j with
    | zero => omega
    | succ j ih =>
      by_cases he : i = j
      · subst he; exact hrk i (by omega)
      · exact Nat.lt_trans (ih (by omega) (by omega)) (hrk j (by omega))
  have hpw : ((List.range (ix.twins + 1)).map (fun i => iter ix.next (i + 1) x)).Pairwise (fun a b => r a < r b) := by
    rw [List.pairwise_map]
    exact List.pairwise_lt_range.imp_of_mem (fun {a b} _ hb hab => hmono a b hab (by
      have := List.mem_range.mp hb; omega))
  have hnd : ((List.range (ix.twins + 1)).map (fun i => iter ix.next (i + 1) x)).Nodup :=
    hpw.imp (fun {a b} hab e => by subst e; omega)
  have := countB_bound (fun x => ix.level x == lvlTwin) ix.slots _ hnd (by
    intro y hy
    simp only [List.mem_map, List.mem_range] at hy
    obtain ⟨i, hi, rfl⟩ := hy
    have := htw i (by omega)
    exact ⟨this.1, by simp [this.2]⟩)
  rw [← Ix.twinCount, ← h.twins_eq] at this
  simp at this
  omega

theorem twin_node_exists (t : Nat) (ht : ix.isTwin t) : ∃ x, ix.isNode x := by
  obtain ⟨k, hk, _⟩ := twin_head_reached h t ht
  exact ⟨_, hk⟩

theorem node_live_pos (x : Nat) (hx : ix.isNode x) : 0 < ix.live := by
  rw [h.live_eq]
  have := countB_pos (fun y => decide (ix.level y ≤ levelCap)) x ix.slots hx.1 (by simp [hx.2])
  unfold Ix.nodeCount
  omega

theorem entry_ne_none (hl : 0 < ix.live) : ix.entry ≠ noneId := by
  have := (h.entry_live hl).1.1
  have := h.slots_le
  unfold hnswSlotLimit noneId at *
  omega

omit h in
theorem twin_absent (m : Nat) (hw : GraphWf m ix) (t : Nat) (ht : ix.isTwin t) (l : Nat) :
    (ix.layer l).present t = false ∧ ix.adj l t = [] ∧ ∀ a, t ∉ ix.adj l a := by
  have hp : (ix.layer l).present t = false := by
    show ix.present l t = false
    unfold Ix.present
    have := ht.2
    unfold lvlTwin levelCap at *
    simp [this]
  refine ⟨hp, ?_, fun a ha => ?_⟩
  · cases hl : ix.adj l t with
    | nil => rfl
    | cons b rest =>
      have hb : b ∈ (ix.layer l).adj t := by show b ∈ ix.adj l t; rw [hl]; simp
      have := (hw l).closed b t ((hw l).symm t b hb)
      rw [hp] at this; simp at this
  · have := (hw l).closed a t ha
    rw [hp] at this; simp at this

end derived


theorem countB_change (f g : Nat → Bool) (x : Nat) : ∀ n, x < n → (∀ y, y ≠ x → g y = f y) →
    countB g n + (if f x then 1 else 0) = countB f n + (if g x then 1 else 0) := by
  intro n
  induction n with
  | zero => intro h; omega
  | succ n ih =>
    intro hx hfg
    simp only [countB]
    by_cases hn : n = x
    · subst hn
      have : countB g n = countB f n := countB_congr _ _ n (fun y hy => hfg y (by omega))
      rw [this]; omega
    · have := ih (by omega) hfg
      rw [hfg n hn]
      omega

theorem nodeCount_change (ix ix' : Ix) (x : Nat) (hs : ix'.slots = ix.slots) (hx : x < ix.slots)
    (hl : ∀ y, y ≠ x → ix'.level y = ix.level y) :
    ix'.nodeCount + (if ix.level x ≤ levelCap then 1 else 0) = ix.nodeCount + (if ix'.level x ≤ levelCap then 1 else 0) := by
  unfold Ix.nodeCount
  rw [hs]
  have := countB_change (fun y => decide (ix.level y ≤ levelCap)) (fun y => decide (ix'.level y ≤ levelCap)) x ix.slots hx
    (fun y hy => by rw [hl y hy])
  simpa using this

theorem twinCount_change (ix ix' : Ix) (x : Nat) (hs : ix'.slots = ix.slots) (hx : x < ix.slots)
    (hl : ∀ y, y ≠ x → ix'.level y = ix.level y) :
    ix'.twinCount + (if ix.level x = lvlTwin then 1 else 0) = ix.twinCount + (if ix'.level x = lvlTwin then 1 else 0) := by
  unfold Ix.twinCount
  rw [hs]
  have := countB_change (fun y => ix.level y == lvlTwin) (fun y => ix'.level y == lvlTwin) x ix.slots hx
    (fun y hy => by rw [hl y hy])
  simpa using this

theorem counts_congr (ix ix' : Ix) (hs : ix'.slots = ix.slots) (hl : ∀ y, y < ix.slots → ix'.level y = ix.level y) :
    ix'.nodeCount = ix.nodeCount ∧ ix'.twinCount = ix.twinCount := by
  unfold Ix.nodeCount Ix.twinCount
  rw [hs]
  exact ⟨countB_congr _ _ _ (fun y hy => by rw [hl y hy]), countB_congr _ _ _ (fun y hy => by rw [hl y hy])⟩

theorem present_iff (ix : Ix) (l x : Nat) :
    ix.present l x = true ↔ x < ix.slots ∧ ix.level x ≤ levelCap ∧ l ≤ ix.level x := by
  unfold Ix.present; simp [and_assoc]

theorem present_congr (ix ix' : Ix) (x : Nat) (hs : x < ix.slots ↔ x < ix'.slots) (hl : ix'.level x = ix.level x)
    (l : Nat) : ix'.present l x = ix.present l x := by
  unfold Ix.present; rw [hl]; simp only [hs]

theorem absent_of (ix : Ix) (x : Nat) (hx : ix.slots ≤ x ∨ levelCap < ix.level x) (l : Nat) : ix.present l x = false := by
  unfold Ix.present
  rcases hx with h | h
  · simp; omega
  · simp; omega

theorem wf_congr (cap : Nat) (g g' : Graph) (hw : Wf cap g) (hp : ∀ x, g'.present x = g.present x)
    (ha : ∀ x, g'.adj x = g.adj x) : Wf cap g' :=
  ⟨fun a b hb => by rw [ha] at hb ⊢; exact hw.symm a b hb, fun a => by rw [ha]; exact hw.irrefl a,
    fun a => by rw [ha]; exact hw.nodup a, fun a => by rw [ha]; exact hw.bound a,
    fun a b hb => by rw [ha] at hb; rw [hp]; exact hw.closed a b hb⟩

theorem adj_nil_of_absent {cap : Nat} {g : Graph} (hw : Wf cap g) (x : Nat) (hx : g.present x = false) :
    g.adj x = [] := by
  cases hl : g.adj x with
  | nil => rfl
  | cons b rest =>
    have hb : b ∈ g.adj x := by rw [hl]; simp
    have := hw.closed b x (hw.symm x b hb)
    rw [hx] at this; simp at this

theorem absent_not_mem {cap : Nat} {g : Graph} (hw : Wf cap g) (x : Nat) (hx : g.present x = false) (a : Nat) :
    x ∉ g.adj a := fun hm => by have := hw.closed a x hm; rw [hx] at this; simp at this

theorem graphWf_frame (m : Nat) (ix ix' : Ix) (hw : GraphWf m ix)
    (hp : ∀ l x, ix'.present l x = ix.present l x) (ha : ∀ l x, ix'.adj l x = ix.adj l x) : GraphWf m ix' :=
  fun l => wf_congr _ _ _ (hw l) (hp l) (ha l)

theorem twin_absent_level (ix : Ix) (x : Nat) (hx : ix.level x = lvlTwin ∨ ix.level x = lvlReserved ∨ ix.level x = lvlFree)
    (l : Nat) : ix.present l x = false :=
  absent_of ix x (Or.inr (by unfold lvlTwin lvlReserved lvlFree levelCap at *; omega)) l

def pushFree (ix : Ix) (s : Nat) : Ix :=
  { ((ix.setLevel s lvlFree).setNext s noneId).clearAdj s with free := s :: ix.free }


def attach (ix : Ix) (slot head : Nat) : Ix :=
  let first := ix.next head
  let ix1 := ((ix.setNext head slot).setNext slot first).setPrev slot head
  let ix2 := if first = noneId then ix1 else ix1.setPrev first slot
  { (ix2.setLevel slot lvlTwin).clearAdj slot with twins := ix.twins + 1, live := ix.live + 1 }

theorem attach_fields (ix : Ix) (slot head : Nat) :
    (attach ix slot head).slots = ix.slots ∧
    (∀ y, (attach ix slot head).level y = if y = slot then lvlTwin else ix.level y) ∧
    (∀ y, (attach ix slot head).next y = if y = slot then ix.next head else if y = head then slot else ix.next y) ∧
    (∀ y, (attach ix slot head).prev y =
      if ix.next head ≠ noneId ∧ y = ix.next head then slot else if y = slot then head else ix.prev y) ∧
    (∀ l y, (attach ix slot head).adj l y = if y = slot then [] else ix.adj l y) ∧
    (attach ix slot head).free = ix.free ∧ (attach ix slot head).twins = ix.twins + 1 ∧
    (attach ix slot head).live = ix.live + 1 ∧ (attach ix slot head).entry = ix.entry ∧
    (attach ix slot head).maxLevel = ix.maxLevel := by
  by_cases hf : ix.next head = noneId
  · have e : attach ix slot head = { (((((ix.setNext head slot).setNext slot (ix.next head)).setPrev slot head)).setLevel slot lvlTwin).clearAdj slot with twins := ix.twins + 1, live := ix.live + 1 } := by
      simp only [attach, hf, ite_true]
    rw [e]
    refine ⟨rfl, fun y => rfl, fun y => rfl, fun y => ?_, fun l y => rfl, rfl, rfl, rfl, rfl, rfl⟩
    simp [Ix.clearAdj, Ix.setLevel, Ix.setPrev, Ix.setNext, hf]
  · have e : attach ix slot head = { ((((((ix.setNext head slot).setNext slot (ix.next head)).setPrev slot head)).setPrev (ix.next head) slot).setLevel slot lvlTwin).clearAdj slot with twins := ix.twins + 1, live := ix.live + 1 } := by
      simp only [attach, hf, ite_false]
    rw [e]
    refine ⟨rfl, fun y => rfl, fun y => rfl, fun y => ?_, fun l y => rfl, rfl, rfl, rfl, rfl, rfl⟩
    simp only [Ix.clearAdj, Ix.setLevel, Ix.setPrev, Ix.setNext, ne_eq, hf, not_false_eq_true, true_and]
theorem slot_lt_none {ix : Ix} (h : TwinInv ix) (x : Nat) (hx : x < ix.slots) : x ≠ noneId := by
  have := h.slots_le; unfold hnswSlotLimit noneId at *; omega

theorem attach_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (slot head : Nat)
    (hs : ix.isReserved slot) (hh : ix.isNode head) :
    TwinInv (attach ix slot head) ∧ GraphWf m (attach ix slot head) := by
  have hsn : ix.next slot = noneId := twin_free_next h slot (Or.inl hs.2)
  have hsl : slot < ix.slots := hs.1
  have hsh : slot ≠ head := fun e => by have := hh.2; rw [← e, hs.2] at this; simp [lvlReserved, levelCap] at this
  have hhs : head ≠ slot := Ne.symm hsh
  have hfirst : ix.next head ≠ noneId → ix.isTwin (ix.next head) := fun hn => (h.next_live head hn).2
  have hnt : ∀ x, ix.next x ≠ noneId → ix.next x ≠ slot := fun x hx e => by
    have := (h.next_live x hx).2.2; rw [e, hs.2] at this; simp [lvlReserved, lvlTwin] at this
  have hfs : ix.next head ≠ slot := fun e => by
    have hn : ix.next head ≠ noneId := by rw [e]; exact slot_lt_none h slot hsl
    exact hnt head hn e
  have hpt : ∀ t, ix.isTwin t → ix.prev t ≠ slot := fun t ht e => by
    have := h.prev_next t ht; rw [e, hsn] at this; exact slot_lt_none h t ht.1 this.symm
  have htwin : ∀ t, ix.isTwin t → t ≠ slot := fun t ht e => by
    have := ht.2; rw [e, hs.2] at this; simp [lvlReserved, lvlTwin] at this
  have hlive : 0 < ix.live := node_live_pos h head hh
  obtain ⟨e1, e2, e3⟩ := h.entry_live hlive
  have hes : ix.entry ≠ slot := fun e => by have := e1.2; rw [e, hs.2] at this; simp [lvlReserved, levelCap] at this
  obtain ⟨hS, hL, hN, hP, hA, hF, hT, hLv, hE, hM⟩ := attach_fields ix slot head
  have hnc := nodeCount_change ix (attach ix slot head) slot hS hsl (fun y hy => by rw [hL]; simp [hy])
  have htc := twinCount_change ix (attach ix slot head) slot hS hsl (fun y hy => by rw [hL]; simp [hy])
  simp only [hL, ite_true, hs.2, lvlTwin, lvlReserved, levelCap, show ¬ (254 ≤ 30) by decide,
    show ¬ (253 ≤ 30) by decide, show ¬ (254 = 253) by decide, ite_false, Nat.add_zero] at hnc htc
  generalize attach ix slot head = ix' at *
  refine ⟨⟨?_, fun x hx => ?_, fun x hx => ?_, fun t ht => ?_, fun x hx => ?_, ?_, fun x => ?_, ?_, ?_, ?_,
    fun _ => ?_, fun hl0 => ?_⟩, ?_⟩
  · rw [hS]; exact h.slots_le
  · rw [hS] at hx; rw [hL]; split
    · right; left; rfl
    · exact h.bytes x hx
  · simp only [Ix.isLive, Ix.isTwin, hS, hL, hN] at hx ⊢
    by_cases hxs : x = slot
    · simp only [hxs, ite_true] at hx ⊢
      have ht := hfirst hx
      exact ⟨⟨hsl, by simp [lvlTwin, lvlReserved]⟩, ⟨ht.1, by simp [hfs, ht.2]⟩⟩
    · by_cases hxh : x = head
      · simp only [hxh, hhs, ite_false, ite_true]
        exact ⟨⟨hh.1, by have := hh.2; unfold levelCap lvlReserved at *; omega⟩, ⟨hsl, by simp⟩⟩
      · simp only [hxs, hxh, ite_false] at hx ⊢
        obtain ⟨⟨a1, a2⟩, ⟨b1, b2⟩⟩ := h.next_live x hx
        exact ⟨⟨a1, a2⟩, ⟨b1, by simp [hnt x hx, b2]⟩⟩
  · simp only [Ix.isTwin, hS, hL] at ht
    simp only [hP, hN]
    by_cases hts : t = slot
    · simp [hts, Ne.symm hfs, hhs]
    · simp only [hts, ite_false] at ht
      have ht' : ix.isTwin t := ⟨ht.1, ht.2⟩
      by_cases htf : t = ix.next head
      · have hn : ix.next head ≠ noneId := by rw [← htf]; exact slot_lt_none h t ht.1
        simp [hn, htf]
      · have hfne : ¬ (ix.next head ≠ noneId ∧ t = ix.next head) := fun ⟨_, e⟩ => htf e
        have hph : ix.prev t ≠ head := fun e => htf (by rw [← h.prev_next t ht', e])
        simp only [hfne, hts, hpt t ht', hph, ite_false]
        exact h.prev_next t ht'
  · simp only [hN] at hx
    simp only [hN, hP]
    by_cases hxs : x = slot
    · simp only [hxs, ite_true] at hx ⊢
      simp [hx]
    · by_cases hxh : x = head
      · have : ¬ (ix.next head ≠ noneId ∧ slot = ix.next head) := fun ⟨_, e⟩ => hfs e.symm
        simp [hxh, hhs, this]
      · simp only [hxs, hxh, ite_false] at hx ⊢
        have hnf : ¬ (ix.next head ≠ noneId ∧ ix.next x = ix.next head) := fun ⟨hn, e⟩ => by
          have := h.next_prev x hx
          rw [e, h.next_prev head hn] at this
          exact hxh this.symm
        simp only [hnf, hnt x hx, ite_false]
        exact h.next_prev x hx
  · obtain ⟨r, hr⟩ := h.rank
    refine ⟨fun t => if t = slot then 0 else r t + 1, fun t ht => ?_⟩
    simp only [Ix.isTwin, Ix.isNode, hS, hL, hP] at ht ⊢
    by_cases hts : t = slot
    · left; simp [hts, Ne.symm hfs, Ne.symm hsh, hh.1, hh.2]
    · simp only [hts, ite_false] at ht ⊢
      have ht' : ix.isTwin t := ⟨ht.1, ht.2⟩
      by_cases htf : t = ix.next head
      · have hn : ix.next head ≠ noneId := by rw [← htf]; exact slot_lt_none h t ht.1
        right; simp [hn, htf, hsl]
      · have hfne : ¬ (ix.next head ≠ noneId ∧ t = ix.next head) := fun ⟨_, e⟩ => htf e
        simp only [hfne, hpt t ht', ite_false]
        rcases hr t ht' with h1 | ⟨h1, h2⟩
        · left; exact h1
        · right; exact ⟨h1, by omega⟩
  · rw [hF, hS, hL]
    by_cases hxs : x = slot
    · simp only [hxs, ite_true]
      constructor
      · intro hm; have := ((h.free_iff slot).mp hm).2; rw [hs.2] at this; simp [lvlReserved, lvlFree] at this
      · intro ⟨_, e⟩; simp [lvlTwin, lvlFree] at e
    · simp only [hxs, ite_false]; exact h.free_iff x
  · rw [hF]; exact h.free_nodup
  · rw [hT, h.twins_eq]; omega
  · rw [hLv, h.live_eq]; omega
  · simp only [Ix.isNode, hE, hM, hS, hL, hes, ite_false]
    refine ⟨e1, e2, fun x hx => ?_⟩
    by_cases hxs : x = slot
    · simp [hxs, lvlTwin, levelCap] at hx
    · simp only [hxs, ite_false] at hx ⊢; exact e3 x hx
  · rw [hLv] at hl0; omega
  · apply graphWf_frame m ix _ hw
    · intro l x
      by_cases hxs : x = slot
      · rw [hxs, twin_absent_level _ slot (Or.inl (by rw [hL]; simp)), twin_absent_level _ slot (Or.inr (Or.inl hs.2))]
      · exact present_congr _ _ x (by rw [hS]) (by rw [hL, ite_eq_right hxs]) l
    · intro l x
      rw [hA]
      split
      · next hxs =>
        rw [hxs]
        exact (adj_nil_of_absent (hw l) slot (twin_absent_level _ slot (Or.inr (Or.inl hs.2)) l)).symm
      · rfl

theorem pushFree_fields (ix : Ix) (s : Nat) :
    (pushFree ix s).slots = ix.slots ∧ (∀ y, (pushFree ix s).level y = if y = s then lvlFree else ix.level y) ∧
    (∀ y, (pushFree ix s).next y = if y = s then noneId else ix.next y) ∧ (pushFree ix s).prev = ix.prev ∧
    (∀ l y, (pushFree ix s).adj l y = if y = s then [] else ix.adj l y) ∧ (pushFree ix s).free = s :: ix.free ∧
    (pushFree ix s).twins = ix.twins ∧ (pushFree ix s).live = ix.live ∧ (pushFree ix s).entry = ix.entry ∧
    (pushFree ix s).maxLevel = ix.maxLevel := ⟨rfl, fun _ => rfl, fun _ => rfl, rfl, fun _ _ => rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem release_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (s : Nat) (hs : ix.isReserved s) :
    TwinInv (pushFree ix s) ∧ GraphWf m (pushFree ix s) := by
  have hsn : ix.next s = noneId := twin_free_next h s (Or.inl hs.2)
  have hsl : s < ix.slots := hs.1
  have hnt : ∀ x, ix.next x ≠ noneId → ix.next x ≠ s := fun x hx e => by
    have := (h.next_live x hx).2.2; rw [e, hs.2] at this; simp [lvlReserved, lvlTwin] at this
  have hpt : ∀ t, ix.isTwin t → ix.prev t ≠ s := fun t ht e => by
    have := h.prev_next t ht; rw [e, hsn] at this; exact slot_lt_none h t ht.1 this.symm
  have hsf : s ∉ ix.free := fun hm => by have := ((h.free_iff s).mp hm).2; rw [hs.2] at this; simp [lvlReserved, lvlFree] at this
  obtain ⟨hS, hL, hN, hP, hA, hF, hT, hLv, hE, hM⟩ := pushFree_fields ix s
  have hnc := nodeCount_change ix (pushFree ix s) s hS hsl (fun y hy => by rw [hL]; simp [hy])
  have htc := twinCount_change ix (pushFree ix s) s hS hsl (fun y hy => by rw [hL]; simp [hy])
  simp only [hL, ite_true, hs.2, lvlTwin, lvlReserved, lvlFree, levelCap, show ¬ (254 ≤ 30) by decide,
    show ¬ (255 ≤ 30) by decide, show ¬ (254 = 253) by decide, show ¬ (255 = 253) by decide, ite_false,
    Nat.add_zero] at hnc htc
  generalize pushFree ix s = ix' at *
  refine ⟨⟨by rw [hS]; exact h.slots_le, fun x hx => ?_, fun x hx => ?_, fun t ht => ?_, fun x hx => ?_, ?_,
    fun x => ?_, ?_, by rw [hT, h.twins_eq]; omega, by rw [hLv, h.live_eq]; omega, fun hl => ?_,
    fun hl => by rw [hE]; exact h.entry_none (by rw [← hLv]; exact hl)⟩, ?_⟩
  · rw [hS] at hx; rw [hL]; split
    · right; right; right; rfl
    · exact h.bytes x hx
  · simp only [Ix.isLive, Ix.isTwin, hS, hL, hN] at hx ⊢
    by_cases hxs : x = s
    · simp [hxs] at hx
    · simp only [hxs, ite_false] at hx ⊢
      obtain ⟨⟨a1, a2⟩, ⟨b1, b2⟩⟩ := h.next_live x hx
      exact ⟨⟨a1, a2⟩, ⟨b1, by simp [hnt x hx, b2]⟩⟩
  · simp only [Ix.isTwin, hS, hL] at ht
    have hts : t ≠ s := fun e => by simp [e, lvlFree, lvlTwin] at ht
    simp only [hts, ite_false] at ht
    simp only [hP, hN, hpt t ⟨ht.1, ht.2⟩, ite_false]
    exact h.prev_next t ⟨ht.1, ht.2⟩
  · simp only [hN] at hx
    have hxs : x ≠ s := fun e => by simp [e] at hx
    simp only [hxs, ite_false] at hx
    rw [hP, hN, ite_eq_right hxs]; exact h.next_prev x hx
  · obtain ⟨r, hr⟩ := h.rank
    refine ⟨r, fun t ht => ?_⟩
    simp only [Ix.isTwin, Ix.isNode, hS, hL, hP] at ht ⊢
    have hts : t ≠ s := fun e => by simp [e, lvlFree, lvlTwin] at ht
    simp only [hts, ite_false] at ht
    simp only [hpt t ⟨ht.1, ht.2⟩, ite_false]
    exact hr t ⟨ht.1, ht.2⟩
  · rw [hF, hS, hL]
    by_cases hxs : x = s
    · simp [hxs, hsl]
    · simp only [hxs, ite_false, List.mem_cons]
      constructor
      · rintro (e | e)
        · exact e.elim
        · exact (h.free_iff x).mp e
      · intro hx; exact Or.inr ((h.free_iff x).mpr hx)
  · rw [hF]; exact List.nodup_cons.mpr ⟨hsf, h.free_nodup⟩
  · rw [hLv] at hl
    obtain ⟨e1, e2, e3⟩ := h.entry_live hl
    have hes : ix.entry ≠ s := fun e => by have := e1.2; rw [e, hs.2] at this; simp [lvlReserved, levelCap] at this
    simp only [Ix.isNode, hE, hM, hS, hL, hes, ite_false]
    refine ⟨e1, e2, fun x hx => ?_⟩
    by_cases hxs : x = s
    · simp [hxs, lvlFree, levelCap] at hx
    · simp only [hxs, ite_false] at hx ⊢; exact e3 x hx
  · apply graphWf_frame m ix _ hw
    · intro l x
      by_cases hxs : x = s
      · rw [hxs, twin_absent_level _ s (Or.inr (Or.inr (by rw [hL]; simp))), twin_absent_level _ s (Or.inr (Or.inl hs.2))]
      · exact present_congr _ _ x (by rw [hS]) (by rw [hL, ite_eq_right hxs]) l
    · intro l x
      rw [hA]
      split
      · next hxs =>
        rw [hxs]
        exact (adj_nil_of_absent (hw l) s (twin_absent_level _ s (Or.inr (Or.inl hs.2)) l)).symm
      · rfl

def removeTwin (ix : Ix) (slot : Nat) : Ix :=
  let p := ix.prev slot
  let n := ix.next slot
  let ix1 := ix.setNext p n
  let ix2 := if n = noneId then ix1 else ix1.setPrev n p
  let ix3 := { ix2.setNext slot noneId with twins := ix.twins - 1 }
  { pushFree ix3 slot with live := ix.live - 1 }

theorem removeTwin_fields (ix : Ix) (slot : Nat) :
    (removeTwin ix slot).slots = ix.slots ∧
    (∀ y, (removeTwin ix slot).level y = if y = slot then lvlFree else ix.level y) ∧
    (∀ y, (removeTwin ix slot).next y = if y = slot then noneId else if y = ix.prev slot then ix.next slot else ix.next y) ∧
    (∀ y, (removeTwin ix slot).prev y = if ix.next slot ≠ noneId ∧ y = ix.next slot then ix.prev slot else ix.prev y) ∧
    (∀ l y, (removeTwin ix slot).adj l y = if y = slot then [] else ix.adj l y) ∧
    (removeTwin ix slot).free = slot :: ix.free ∧ (removeTwin ix slot).twins = ix.twins - 1 ∧
    (removeTwin ix slot).live = ix.live - 1 ∧ (removeTwin ix slot).entry = ix.entry ∧
    (removeTwin ix slot).maxLevel = ix.maxLevel := by
  by_cases hn : ix.next slot = noneId
  · have e : removeTwin ix slot = { pushFree { (ix.setNext (ix.prev slot) (ix.next slot)).setNext slot noneId with
        twins := ix.twins - 1 } slot with live := ix.live - 1 } := by simp only [removeTwin, hn, ite_true]
    rw [e]
    refine ⟨rfl, fun y => rfl, fun y => ?_, fun y => by simp [pushFree, Ix.clearAdj, Ix.setLevel, Ix.setNext, hn],
      fun l y => rfl, rfl, rfl, rfl, rfl, rfl⟩
    simp only [pushFree, Ix.clearAdj, Ix.setLevel, Ix.setNext]
    split <;> rfl
  · have e : removeTwin ix slot = { pushFree { ((ix.setNext (ix.prev slot) (ix.next slot)).setPrev (ix.next slot)
        (ix.prev slot)).setNext slot noneId with twins := ix.twins - 1 } slot with live := ix.live - 1 } := by
      simp only [removeTwin, hn, ite_false]
    rw [e]
    refine ⟨rfl, fun y => rfl, fun y => ?_, fun y => ?_, fun l y => rfl, rfl, rfl, rfl, rfl, rfl⟩
    · simp only [pushFree, Ix.clearAdj, Ix.setLevel, Ix.setNext, Ix.setPrev]
      split <;> rfl
    · simp [pushFree, Ix.clearAdj, Ix.setLevel, Ix.setNext, Ix.setPrev, hn]


theorem remove_twin_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (slot : Nat) (hs : ix.isTwin slot) :
    TwinInv (removeTwin ix slot) ∧ GraphWf m (removeTwin ix slot) := by
  have hsl : slot < ix.slots := hs.1
  obtain ⟨r, hr⟩ := h.rank
  have hpn : ix.next (ix.prev slot) = slot := h.prev_next slot hs
  have hpl : ix.isLive (ix.prev slot) := twin_prev_live h slot hs
  have hps : ix.prev slot ≠ slot := fun e => by
    rcases hr slot hs with h1 | ⟨_, h2⟩
    · rw [e] at h1; exact (twin_kinds h slot hsl).2 ⟨h1, hs⟩
    · rw [e] at h2; omega
  have hnfacts : ix.next slot ≠ noneId → ix.isTwin (ix.next slot) ∧ ix.prev (ix.next slot) = slot ∧
      ix.next slot ≠ slot ∧ ix.next slot ≠ ix.prev slot := by
    intro hn
    have ht := (h.next_live slot hn).2
    have hp := h.next_prev slot hn
    refine ⟨ht, hp, fun e => by have h0 := hp; rw [e] at h0; exact hps h0, fun e => ?_⟩
    rcases hr slot hs with h1 | ⟨_, h2⟩
    · rw [← e] at h1; exact (twin_kinds h _ ht.1).2 ⟨h1, ht⟩
    · rcases hr _ ht with h3 | ⟨_, h4⟩
      · rw [hp] at h3; exact (twin_kinds h slot hsl).2 ⟨h3, hs⟩
      · rw [hp] at h4; rw [← e] at h2; omega
  have hnt : ∀ x, ix.next x ≠ noneId → x ≠ ix.prev slot → ix.next x ≠ slot := fun x hx hxp e => by
    have := h.next_prev x hx; rw [e] at this; exact hxp this.symm
  have hpt : ∀ t, ix.isTwin t → ¬ (ix.next slot ≠ noneId ∧ t = ix.next slot) → ix.prev t ≠ slot := fun t ht hc e => by
    have := h.prev_next t ht; rw [e] at this
    exact hc ⟨by rw [this]; exact slot_lt_none h t ht.1, this.symm⟩
  have hpp : ∀ t, ix.isTwin t → t ≠ slot → ix.prev t ≠ ix.prev slot := fun t ht hts e => by
    have := h.prev_next t ht; rw [e, hpn] at this; exact hts this.symm
  have hlive : 0 < ix.live := by
    rw [h.live_eq]
    have := countB_pos (fun y => ix.level y == lvlTwin) slot ix.slots hsl (by simp [hs.2])
    unfold Ix.twinCount; omega
  obtain ⟨e1, e2, e3⟩ := h.entry_live hlive
  have hes : ix.entry ≠ slot := fun e => (twin_kinds h slot hsl).2 ⟨e ▸ e1, hs⟩
  obtain ⟨z, hz⟩ := twin_node_exists h slot hs
  have hzs : z ≠ slot := fun e => (twin_kinds h slot hsl).2 ⟨e ▸ hz, hs⟩
  obtain ⟨hS, hL, hN, hP, hA, hF, hT, hLv, hE, hM⟩ := removeTwin_fields ix slot
  have hnc := nodeCount_change ix (removeTwin ix slot) slot hS hsl (fun y hy => by rw [hL]; simp [hy])
  have htc := twinCount_change ix (removeTwin ix slot) slot hS hsl (fun y hy => by rw [hL]; simp [hy])
  simp only [hL, ite_true, hs.2, lvlTwin, lvlFree, levelCap, show ¬ (253 ≤ 30) by decide,
    show ¬ (255 ≤ 30) by decide, show ¬ (255 = 253) by decide, ite_false, Nat.add_zero] at hnc htc
  have hz' : (removeTwin ix slot).isNode z := ⟨by rw [hS]; exact hz.1, by rw [hL, ite_eq_right hzs]; exact hz.2⟩
  have hnc' : 0 < (removeTwin ix slot).nodeCount := by
    have := countB_pos (fun y => decide ((removeTwin ix slot).level y ≤ levelCap)) z (removeTwin ix slot).slots hz'.1
      (by simp [hz'.2])
    unfold Ix.nodeCount; omega
  have htc1 : 0 < ix.twinCount := by
    have := countB_pos (fun y => ix.level y == lvlTwin) slot ix.slots hsl (by simp [hs.2])
    unfold Ix.twinCount; omega
  generalize removeTwin ix slot = ix' at *
  refine ⟨⟨by rw [hS]; exact h.slots_le, fun x hx => ?_, fun x hx => ?_, fun t ht => ?_, fun x hx => ?_, ?_,
    fun x => ?_, ?_, by rw [hT, h.twins_eq]; omega, by rw [hLv, h.live_eq]; omega, fun hl => ?_,
    fun hl => ?_⟩, ?_⟩
  · rw [hS] at hx; rw [hL]; split
    · right; right; right; rfl
    · exact h.bytes x hx
  · simp only [Ix.isLive, Ix.isTwin, hS, hL, hN] at hx ⊢
    by_cases hxs : x = slot
    · simp [hxs] at hx
    · by_cases hxp : x = ix.prev slot
      · simp only [hxp, ite_false, ite_true, hps] at hx ⊢
        obtain ⟨ht, _, hns, _⟩ := hnfacts hx
        exact ⟨⟨hpl.1, hpl.2⟩, ⟨ht.1, by simp [hns, ht.2]⟩⟩
      · simp only [hxs, hxp, ite_false] at hx ⊢
        obtain ⟨⟨a1, a2⟩, ⟨b1, b2⟩⟩ := h.next_live x hx
        exact ⟨⟨a1, a2⟩, ⟨b1, by simp [hnt x hx hxp, b2]⟩⟩
  · simp only [Ix.isTwin, hS, hL] at ht
    have hts : t ≠ slot := fun e => by simp [e, lvlFree, lvlTwin] at ht
    simp only [hts, ite_false] at ht
    have ht' : ix.isTwin t := ⟨ht.1, ht.2⟩
    simp only [hP, hN]
    by_cases hc : ix.next slot ≠ noneId ∧ t = ix.next slot
    · simp [hc, hps]
    · simp only [hc, ite_false, hpt t ht' hc, hpp t ht' hts]
      exact h.prev_next t ht'
  · simp only [hN] at hx
    have hxs : x ≠ slot := fun e => by simp [e] at hx
    simp only [hP, hN, hxs, ite_false] at hx ⊢
    by_cases hxp : x = ix.prev slot
    · simp only [hxp, ite_true] at hx ⊢
      simp [hx]
    · simp only [hxp, ite_false] at hx ⊢
      have hc : ¬ (ix.next slot ≠ noneId ∧ ix.next x = ix.next slot) := fun ⟨hn, e⟩ => by
        have := h.next_prev x hx; rw [e, (hnfacts hn).2.1] at this; exact hxs this.symm
      simp only [hc, ite_false]
      exact h.next_prev x hx
  · refine ⟨r, fun t ht => ?_⟩
    simp only [Ix.isTwin, Ix.isNode, hS, hL, hP] at ht ⊢
    have hts : t ≠ slot := fun e => by simp [e, lvlFree, lvlTwin] at ht
    simp only [hts, ite_false] at ht
    have ht' : ix.isTwin t := ⟨ht.1, ht.2⟩
    by_cases hc : ix.next slot ≠ noneId ∧ t = ix.next slot
    · obtain ⟨hn, htn⟩ := hc
      rw [htn, ite_eq_left (show ix.next slot ≠ noneId ∧ ix.next slot = ix.next slot from ⟨hn, rfl⟩),
        ite_eq_right hps]
      obtain ⟨hnt', hnp, _, _⟩ := hnfacts hn
      rcases hr slot hs with h1 | ⟨h1, h2⟩
      · left; exact h1
      · right; refine ⟨h1, ?_⟩
        rcases hr _ hnt' with h3 | ⟨_, h4⟩
        · rw [hnp] at h3; exact absurd hs (fun h5 => (twin_kinds h slot hsl).2 ⟨h3, h5⟩)
        · rw [hnp] at h4; omega
    · simp only [hc, ite_false, hpt t ht' hc]
      exact hr t ht'
  · rw [hF, hS, hL]
    by_cases hxs : x = slot
    · simp [hxs, hsl]
    · simp only [hxs, ite_false, List.mem_cons]
      constructor
      · rintro (e | e)
        · exact e.elim
        · exact (h.free_iff x).mp e
      · intro hx; exact Or.inr ((h.free_iff x).mpr hx)
  · rw [hF]
    refine List.nodup_cons.mpr ⟨fun hm => ?_, h.free_nodup⟩
    have := ((h.free_iff slot).mp hm).2; rw [hs.2] at this; simp [lvlTwin, lvlFree] at this
  · simp only [Ix.isNode, hE, hM, hS, hL, hes, ite_false]
    refine ⟨e1, e2, fun x hx => ?_⟩
    by_cases hxs : x = slot
    · simp [hxs, lvlFree, levelCap] at hx
    · simp only [hxs, ite_false] at hx ⊢; exact e3 x hx
  · rw [hLv] at hl; rw [h.live_eq] at hl; omega
  · apply graphWf_frame m ix _ hw
    · intro l x
      by_cases hxs : x = slot
      · rw [hxs, twin_absent_level _ slot (Or.inr (Or.inr (by rw [hL]; simp))), twin_absent_level _ slot (Or.inl hs.2)]
      · exact present_congr _ _ x (by rw [hS]) (by rw [hL, ite_eq_right hxs]) l
    · intro l x
      rw [hA]
      split
      · next hxs =>
        rw [hxs]
        exact (adj_nil_of_absent (hw l) slot (twin_absent_level _ slot (Or.inl hs.2) l)).symm
      · rfl


def reserveFree (ix : Ix) (s : Nat) (rest : List Nat) : Ix := { ix.setLevel s lvlReserved with free := rest }

def reserveNew (ix : Ix) : Ix :=
  { ((ix.setLevel ix.slots lvlReserved).setNext ix.slots noneId).clearAdj ix.slots with slots := ix.slots + 1 }

def reserveOp (ix : Ix) : Nat × Ix :=
  match ix.free with
  | s :: rest => (s, reserveFree ix s rest)
  | [] => (ix.slots, reserveNew ix)

theorem reserve_free_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (s : Nat) (rest : List Nat)
    (hf : ix.free = s :: rest) :
    TwinInv (reserveFree ix s rest) ∧ GraphWf m (reserveFree ix s rest) ∧ (reserveFree ix s rest).isReserved s := by
  have hs : s < ix.slots ∧ ix.level s = lvlFree := (h.free_iff s).mp (by rw [hf]; simp)
  have hnd := h.free_nodup
  rw [hf] at hnd
  have hnd' := List.nodup_cons.mp hnd
  have hsn : ix.next s = noneId := twin_free_next h s (Or.inr hs.2)
  have hnt : ∀ x, ix.next x ≠ noneId → ix.next x ≠ s := fun x hx e => by
    have := (h.next_live x hx).2.2; rw [e, hs.2] at this; simp [lvlFree, lvlTwin] at this
  have hpt : ∀ t, ix.isTwin t → ix.prev t ≠ s := fun t ht e => by
    have := h.prev_next t ht; rw [e, hsn] at this; exact slot_lt_none h t ht.1 this.symm
  have hS : (reserveFree ix s rest).slots = ix.slots := rfl
  have hL : ∀ y, (reserveFree ix s rest).level y = if y = s then lvlReserved else ix.level y := fun _ => rfl
  have hnc := nodeCount_change ix (reserveFree ix s rest) s hS hs.1 (fun y hy => by rw [hL]; simp [hy])
  have htc := twinCount_change ix (reserveFree ix s rest) s hS hs.1 (fun y hy => by rw [hL]; simp [hy])
  simp only [hL, ite_true, hs.2, lvlTwin, lvlReserved, lvlFree, levelCap, show ¬ (254 ≤ 30) by decide,
    show ¬ (255 ≤ 30) by decide, show ¬ (254 = 253) by decide, show ¬ (255 = 253) by decide, ite_false,
    Nat.add_zero] at hnc htc
  have hres : (reserveFree ix s rest).isReserved s := ⟨hs.1, by rw [hL]; simp⟩
  have hN : (reserveFree ix s rest).next = ix.next := rfl
  have hP : (reserveFree ix s rest).prev = ix.prev := rfl
  have hA : (reserveFree ix s rest).adj = ix.adj := rfl
  have hF : (reserveFree ix s rest).free = rest := rfl
  have hT : (reserveFree ix s rest).twins = ix.twins := rfl
  have hLv : (reserveFree ix s rest).live = ix.live := rfl
  have hE : (reserveFree ix s rest).entry = ix.entry := rfl
  have hM : (reserveFree ix s rest).maxLevel = ix.maxLevel := rfl
  generalize reserveFree ix s rest = ix' at *
  refine ⟨⟨by rw [hS]; exact h.slots_le, fun x hx => ?_, fun x hx => ?_, fun t ht => ?_,
    fun x hx => by rw [hN] at hx; rw [hP, hN]; exact h.next_prev x hx, ?_, fun x => ?_, by rw [hF]; exact hnd'.2,
    by rw [hT, h.twins_eq]; omega, by rw [hLv, h.live_eq]; omega, fun hl => ?_,
    fun hl => by rw [hE]; exact h.entry_none (by rw [← hLv]; exact hl)⟩, ?_, hres⟩
  · rw [hS] at hx; rw [hL]; split
    · right; right; left; rfl
    · exact h.bytes x hx
  · simp only [Ix.isLive, Ix.isTwin, hS, hL, hN] at hx ⊢
    have hxs : x ≠ s := fun e => hx (e ▸ hsn)
    obtain ⟨⟨a1, a2⟩, ⟨b1, b2⟩⟩ := h.next_live x hx
    exact ⟨⟨a1, by simp [hxs, a2]⟩, ⟨b1, by simp [hnt x hx, b2]⟩⟩
  · simp only [Ix.isTwin, hS, hL] at ht
    have hts : t ≠ s := fun e => by simp [e, lvlReserved, lvlTwin] at ht
    simp only [hts, ite_false] at ht
    rw [hP, hN]; exact h.prev_next t ⟨ht.1, ht.2⟩
  · obtain ⟨r, hr⟩ := h.rank
    refine ⟨r, fun t ht => ?_⟩
    simp only [Ix.isTwin, Ix.isNode, hS, hL, hP] at ht ⊢
    have hts : t ≠ s := fun e => by simp [e, lvlReserved, lvlTwin] at ht
    simp only [hts, ite_false] at ht
    simp only [hpt t ⟨ht.1, ht.2⟩, ite_false]
    exact hr t ⟨ht.1, ht.2⟩
  · rw [hF, hS, hL]
    by_cases hxs : x = s
    · simp only [hxs, ite_true]
      constructor
      · intro hm; exact absurd hm hnd'.1
      · intro ⟨_, e⟩; simp [lvlReserved, lvlFree] at e
    · simp only [hxs, ite_false]
      constructor
      · intro hm; exact (h.free_iff x).mp (by rw [hf]; exact List.mem_cons_of_mem _ hm)
      · intro hx
        have := (h.free_iff x).mpr hx
        rw [hf] at this
        rcases List.mem_cons.mp this with e | e
        · exact absurd e hxs
        · exact e
  · rw [hLv] at hl
    obtain ⟨e1, e2, e3⟩ := h.entry_live hl
    have hes : ix.entry ≠ s := fun e => by have := e1.2; rw [e, hs.2] at this; simp [lvlFree, levelCap] at this
    simp only [Ix.isNode, hE, hM, hS, hL, hes, ite_false]
    refine ⟨e1, e2, fun x hx => ?_⟩
    by_cases hxs : x = s
    · simp [hxs, lvlReserved, levelCap] at hx
    · simp only [hxs, ite_false] at hx ⊢; exact e3 x hx
  · apply graphWf_frame m ix _ hw
    · intro l x
      by_cases hxs : x = s
      · rw [hxs, twin_absent_level _ s (Or.inr (Or.inl (by rw [hL]; simp))), twin_absent_level _ s (Or.inr (Or.inr hs.2))]
      · exact present_congr _ _ x (by rw [hS]) (by rw [hL, ite_eq_right hxs]) l
    · intro l x; rw [hA]

theorem reserve_new_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (hlt : ix.slots < hnswSlotLimit) :
    TwinInv (reserveNew ix) ∧ GraphWf m (reserveNew ix) ∧ (reserveNew ix).isReserved ix.slots := by
  have hS : (reserveNew ix).slots = ix.slots + 1 := rfl
  have hL : ∀ y, (reserveNew ix).level y = if y = ix.slots then lvlReserved else ix.level y := fun _ => rfl
  have hN : ∀ y, (reserveNew ix).next y = if y = ix.slots then noneId else ix.next y := fun _ => rfl
  have hP : (reserveNew ix).prev = ix.prev := rfl
  have hA : ∀ l y, (reserveNew ix).adj l y = if y = ix.slots then [] else ix.adj l y := fun _ _ => rfl
  have hF : (reserveNew ix).free = ix.free := rfl
  have hT : (reserveNew ix).twins = ix.twins := rfl
  have hLv : (reserveNew ix).live = ix.live := rfl
  have hE : (reserveNew ix).entry = ix.entry := rfl
  have hM : (reserveNew ix).maxLevel = ix.maxLevel := rfl
  have hcount : (reserveNew ix).nodeCount = ix.nodeCount ∧ (reserveNew ix).twinCount = ix.twinCount := by
    unfold Ix.nodeCount Ix.twinCount
    rw [hS]
    simp only [countB, hL, ite_true, lvlReserved, levelCap, lvlTwin, show ¬ (254 ≤ 30) by decide,
      show (254 == 253) = false by decide, decide_false, Bool.false_eq_true, ite_false, Nat.add_zero]
    refine ⟨countB_congr _ _ _ (fun y hy => ?_), countB_congr _ _ _ (fun y hy => ?_)⟩
    · have hy' : y ≠ ix.slots := by omega
      simp only [hy', ite_false]
      rfl
    · have hy' : y ≠ ix.slots := by omega
      simp only [hy', ite_false]
  have hlive : ∀ x, ix.next x ≠ noneId → x < ix.slots := fun x hx => (h.next_live x hx).1.1
  generalize reserveNew ix = ix' at *
  refine ⟨⟨by rw [hS]; unfold hnswSlotLimit at *; omega, fun x hx => ?_, fun x hx => ?_, fun t ht => ?_,
    fun x hx => ?_, ?_, fun x => ?_, by rw [hF]; exact h.free_nodup, by rw [hT, h.twins_eq, hcount.2],
    by rw [hLv, h.live_eq, hcount.1, hcount.2], fun hl => ?_,
    fun hl => by rw [hE]; exact h.entry_none (by rw [← hLv]; exact hl)⟩, ?_, ⟨by rw [hS]; omega, by rw [hL]; simp⟩⟩
  · rw [hS] at hx; rw [hL]; split
    · right; right; left; rfl
    · exact h.bytes x (by omega)
  · simp only [Ix.isLive, Ix.isTwin, hS, hL, hN] at hx ⊢
    have hxs : x ≠ ix.slots := fun e => by simp [e] at hx
    simp only [hxs, ite_false] at hx ⊢
    obtain ⟨⟨a1, a2⟩, ⟨b1, b2⟩⟩ := h.next_live x hx
    exact ⟨⟨by omega, a2⟩, ⟨by omega, by simp [show ix.next x ≠ ix.slots by omega, b2]⟩⟩
  · simp only [Ix.isTwin, hS, hL] at ht
    have hts : t ≠ ix.slots := fun e => by simp [e, lvlReserved, lvlTwin] at ht
    simp only [hts, ite_false] at ht
    have hpl := twin_prev_live h t ⟨by omega, ht.2⟩
    rw [hP, hN, ite_eq_right (show ix.prev t ≠ ix.slots by have := hpl.1; omega)]
    exact h.prev_next t ⟨by omega, ht.2⟩
  · rw [hN] at hx
    have hxs : x ≠ ix.slots := fun e => by simp [e] at hx
    rw [ite_eq_right hxs] at hx
    rw [hP, hN, ite_eq_right hxs]; exact h.next_prev x hx
  · obtain ⟨r, hr⟩ := h.rank
    refine ⟨r, fun t ht => ?_⟩
    simp only [Ix.isTwin, Ix.isNode, hS, hL, hP] at ht ⊢
    have hts : t ≠ ix.slots := fun e => by simp [e, lvlReserved, lvlTwin] at ht
    simp only [hts, ite_false] at ht
    have ht' : ix.isTwin t := ⟨by omega, ht.2⟩
    have hpl := twin_prev_live h t ht'
    have hps : ix.prev t ≠ ix.slots := by have := hpl.1; omega
    simp only [hps, ite_false]
    rcases hr t ht' with h1 | ⟨h1, h2⟩
    · left; exact ⟨by have := h1.1; omega, h1.2⟩
    · right; exact ⟨⟨by have := h1.1; omega, h1.2⟩, h2⟩
  · rw [hF, hS, hL]
    by_cases hxs : x = ix.slots
    · simp only [hxs, ite_true]
      constructor
      · intro hm; have := ((h.free_iff _).mp hm).1; omega
      · intro ⟨_, e⟩; simp [lvlReserved, lvlFree] at e
    · simp only [hxs, ite_false]
      rw [h.free_iff x]
      constructor
      · intro ⟨a, b⟩; exact ⟨by omega, b⟩
      · intro ⟨a, b⟩; exact ⟨by omega, b⟩
  · rw [hLv] at hl
    obtain ⟨e1, e2, e3⟩ := h.entry_live hl
    have hes : ix.entry ≠ ix.slots := by have := e1.1; omega
    simp only [Ix.isNode, hE, hM, hS, hL, hes, ite_false]
    refine ⟨⟨by have := e1.1; omega, e1.2⟩, e2, fun x hx => ?_⟩
    by_cases hxs : x = ix.slots
    · simp [hxs, lvlReserved, levelCap] at hx
    · simp only [hxs, ite_false] at hx ⊢; exact e3 x ⟨by omega, hx.2⟩
  · apply graphWf_frame m ix _ hw
    · intro l x
      by_cases hxs : x = ix.slots
      · rw [hxs, twin_absent_level _ ix.slots (Or.inr (Or.inl (by rw [hL]; simp))),
          absent_of ix ix.slots (Or.inl (Nat.le_refl _))]
      · unfold Ix.present
        rw [hS, hL, ite_eq_right hxs]
        by_cases hx2 : x < ix.slots
        · simp [hx2, show x < ix.slots + 1 by omega]
        · simp [hx2, show ¬ (x < ix.slots + 1) by omega]
    · intro l x
      rw [hA]
      split
      · next hxs =>
        rw [hxs]
        exact (adj_nil_of_absent (hw l) ix.slots (absent_of ix ix.slots (Or.inl (Nat.le_refl _)) l)).symm
      · rfl

theorem reserve_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix)
    (hroom : ix.free ≠ [] ∨ ix.slots < hnswSlotLimit) :
    TwinInv (reserveOp ix).2 ∧ GraphWf m (reserveOp ix).2 ∧ (reserveOp ix).2.isReserved (reserveOp ix).1 := by
  unfold reserveOp
  split
  · next s rest hf => exact reserve_free_inv m ix h hw s rest hf
  · next hf =>
    rcases hroom with h1 | h1
    · exact absurd hf h1
    · exact reserve_new_inv m ix h hw h1


def foldLayers (f : Nat → Ix → Graph → Graph) (ix : Ix) (ls : List Nat) : Ix :=
  ls.foldl (fun ix' l => ix'.withLayer l (f l ix' (ix'.layer l))) ix

theorem foldLayers_frame (f : Nat → Ix → Graph → Graph) : ∀ (ls : List Nat) (ix : Ix),
    (foldLayers f ix ls).slots = ix.slots ∧ (foldLayers f ix ls).level = ix.level ∧
    (foldLayers f ix ls).next = ix.next ∧ (foldLayers f ix ls).prev = ix.prev ∧ (foldLayers f ix ls).free = ix.free ∧
    (foldLayers f ix ls).twins = ix.twins ∧ (foldLayers f ix ls).live = ix.live ∧
    (foldLayers f ix ls).entry = ix.entry ∧ (foldLayers f ix ls).maxLevel = ix.maxLevel := by
  intro ls
  induction ls with
  | nil => intro ix; exact ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩
  | cons l ls ih =>
    intro ix
    exact ih (ix.withLayer l (f l ix (ix.layer l)))

theorem foldLayers_present (f : Nat → Ix → Graph → Graph) (ls : List Nat) (ix : Ix) :
    (foldLayers f ix ls).present = ix.present := by
  obtain ⟨h1, h2, _⟩ := foldLayers_frame f ls ix
  unfold Ix.present; rw [h1, h2]

theorem foldLayers_adj (f : Nat → Ix → Graph → Graph) : ∀ (ls : List Nat) (ix : Ix), ls.Nodup →
    (∀ l, l ∉ ls → (foldLayers f ix ls).adj l = ix.adj l) ∧
    (∀ l ∈ ls, ∃ ctx, (foldLayers f ix ls).adj l = (f l ctx (ix.layer l)).adj) := by
  intro ls
  induction ls with
  | nil => intro ix _; exact ⟨fun l _ => rfl, fun l hl => by simp at hl⟩
  | cons l0 ls ih =>
    intro ix hnd
    have hn := List.nodup_cons.mp hnd
    obtain ⟨i1, i2⟩ := ih (ix.withLayer l0 (f l0 ix (ix.layer l0))) hn.2
    have hlay : ∀ l, l ≠ l0 → (ix.withLayer l0 (f l0 ix (ix.layer l0))).layer l = ix.layer l := by
      intro l hl
      simp only [Ix.layer, Ix.withLayer, hl, ite_false]
      rfl
    refine ⟨fun l hl => ?_, fun l hl => ?_⟩
    · have hl0 : l ≠ l0 := fun e => hl (e ▸ List.mem_cons_self)
      have : l ∉ ls := fun e => hl (List.mem_cons_of_mem _ e)
      show (foldLayers f (ix.withLayer l0 (f l0 ix (ix.layer l0))) ls).adj l = ix.adj l
      rw [i1 l this]
      show (if l = l0 then _ else ix.adj l) = ix.adj l
      simp [hl0]
    · show ∃ ctx, (foldLayers f (ix.withLayer l0 (f l0 ix (ix.layer l0))) ls).adj l = (f l ctx (ix.layer l)).adj
      rcases List.mem_cons.mp hl with e | e
      · subst e
        refine ⟨ix, ?_⟩
        rw [i1 l hn.1]
        show (if l = l then _ else ix.adj l) = _
        simp
      · obtain ⟨ctx, hc⟩ := i2 l e
        have hl0 : l ≠ l0 := fun e' => hn.1 (e' ▸ e)
        exact ⟨ctx, by rw [hc, hlay l hl0]⟩

theorem foldLayers_wf (m : Nat) (f : Nat → Ix → Graph → Graph) (ix : Ix) (ls : List Nat) (hnd : ls.Nodup)
    (hw : ∀ l, l ∉ ls → Wf (layerCap m l) (ix.layer l))
    (hf : ∀ l ∈ ls, ∀ ctx, Wf (layerCap m l) (f l ctx (ix.layer l)) ∧ (f l ctx (ix.layer l)).present = (ix.layer l).present) :
    GraphWf m (foldLayers f ix ls) := by
  intro l
  obtain ⟨a1, a2⟩ := foldLayers_adj f ls ix hnd
  have hp := foldLayers_present f ls ix
  by_cases hl : l ∈ ls
  · obtain ⟨ctx, hc⟩ := a2 l hl
    obtain ⟨w1, w2⟩ := hf l hl ctx
    apply wf_congr _ _ _ w1
    · intro x; show (foldLayers f ix ls).present l x = _; rw [hp, w2]; rfl
    · intro x; show (foldLayers f ix ls).adj l x = _; rw [hc]
  · apply wf_congr _ _ _ (hw l hl)
    · intro x; show (foldLayers f ix ls).present l x = _; rw [hp]; rfl
    · intro x; show (foldLayers f ix ls).adj l x = _; rw [a1 l hl]; rfl

theorem twinInv_congr (ix ix' : Ix) (h : TwinInv ix) (hs : ix'.slots = ix.slots) (hl : ix'.level = ix.level)
    (hn : ix'.next = ix.next) (hp : ix'.prev = ix.prev) (hf : ix'.free = ix.free) (ht : ix'.twins = ix.twins)
    (hv : ix'.live = ix.live) (he : ix'.entry = ix.entry) (hm : ix'.maxLevel = ix.maxLevel) : TwinInv ix' := by
  have hc : ix'.nodeCount = ix.nodeCount ∧ ix'.twinCount = ix.twinCount := by
    unfold Ix.nodeCount Ix.twinCount; rw [hs, hl]; exact ⟨rfl, rfl⟩
  have ePr : ∀ x, ix'.isNode x ↔ ix.isNode x := fun x => by unfold Ix.isNode; rw [hs, hl]
  have eTw : ∀ x, ix'.isTwin x ↔ ix.isTwin x := fun x => by unfold Ix.isTwin; rw [hs, hl]
  have eLv : ∀ x, ix'.isLive x ↔ ix.isLive x := fun x => by unfold Ix.isLive; rw [hs, hl]
  obtain ⟨r, hr⟩ := h.rank
  refine ⟨by rw [hs]; exact h.slots_le, fun x hx => by rw [hl]; rw [hs] at hx; exact h.bytes x hx,
    fun x hx => by rw [hn] at hx ⊢; rw [eLv, eTw]; exact h.next_live x hx,
    fun t ht => by rw [eTw] at ht; rw [hn, hp]; exact h.prev_next t ht,
    fun x hx => by rw [hn] at hx; rw [hn, hp]; exact h.next_prev x hx,
    ⟨r, fun t ht => by rw [eTw] at ht; rw [hp, ePr, eTw]; exact hr t ht⟩,
    fun x => by rw [hf, hs, hl]; exact h.free_iff x, by rw [hf]; exact h.free_nodup,
    by rw [ht, hc.2]; exact h.twins_eq, by rw [hv, hc.1, hc.2]; exact h.live_eq,
    fun hl0 => by rw [hv] at hl0; simp only [he, hm, ePr, hl]; exact h.entry_live hl0,
    fun hl0 => by rw [hv] at hl0; rw [he]; exact h.entry_none hl0⟩

def nodePlace (ix : Ix) (slot lv : Nat) : Ix := { (ix.setLevel slot lv).clearAdj slot with live := ix.live + 1 }

theorem place_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (slot lv : Nat) (hs : ix.isReserved slot)
    (hlv : lv ≤ levelCap) :
    (∀ e ml, (nodePlace ix slot lv).isNode e ∧ (nodePlace ix slot lv).level e = ml ∧
      (∀ x, (nodePlace ix slot lv).isNode x → (nodePlace ix slot lv).level x ≤ ml) →
      TwinInv { nodePlace ix slot lv with entry := e, maxLevel := ml }) ∧ GraphWf m (nodePlace ix slot lv) := by
  have hsn : ix.next slot = noneId := twin_free_next h slot (Or.inl hs.2)
  have hsl : slot < ix.slots := hs.1
  have hnt : ∀ x, ix.next x ≠ noneId → ix.next x ≠ slot := fun x hx e' => by
    have := (h.next_live x hx).2.2; rw [e', hs.2] at this; simp [lvlReserved, lvlTwin] at this
  have hpt : ∀ t, ix.isTwin t → ix.prev t ≠ slot := fun t ht e' => by
    have := h.prev_next t ht; rw [e', hsn] at this; exact slot_lt_none h t ht.1 this.symm
  have hS : (nodePlace ix slot lv).slots = ix.slots := rfl
  have hL : ∀ y, (nodePlace ix slot lv).level y = if y = slot then lv else ix.level y := fun _ => rfl
  have hA : ∀ l y, (nodePlace ix slot lv).adj l y = if y = slot then [] else ix.adj l y := fun _ _ => rfl
  have hlvt : lv ≠ lvlTwin := by unfold levelCap lvlTwin at *; omega
  have hlv30 : lv ≤ 30 := hlv
  have hlv253 : ¬ (lv = 253) := by unfold levelCap at hlv; omega
  have hnc := nodeCount_change ix (nodePlace ix slot lv) slot hS hsl (fun y hy => by rw [hL]; simp [hy])
  have htc := twinCount_change ix (nodePlace ix slot lv) slot hS hsl (fun y hy => by rw [hL]; simp [hy])
  simp only [hL, ite_true, hs.2, hlv30, hlv253, lvlTwin, lvlReserved, levelCap, show ¬ (254 ≤ 30) by decide,
    show ¬ (254 = 253) by decide, ite_false, Nat.add_zero] at hnc htc
  have hfin : ∀ e ml, (nodePlace ix slot lv).isNode e ∧ (nodePlace ix slot lv).level e = ml ∧
      (∀ x, (nodePlace ix slot lv).isNode x → (nodePlace ix slot lv).level x ≤ ml) →
      ∀ ix' : Ix, ix'.slots = ix.slots → ix'.level = (nodePlace ix slot lv).level → ix'.next = ix.next →
      ix'.prev = ix.prev → ix'.free = ix.free → ix'.twins = ix.twins → ix'.live = ix.live + 1 → ix'.entry = e →
      ix'.maxLevel = ml → TwinInv ix' := by
    intro e ml he ix' s1 s2 s3 s4 s5 s6 s7 s8 s9
    have hc : ix'.nodeCount = (nodePlace ix slot lv).nodeCount ∧ ix'.twinCount = (nodePlace ix slot lv).twinCount := by
      unfold Ix.nodeCount Ix.twinCount; rw [s1, s2]; exact ⟨rfl, rfl⟩
    have hL' : ∀ y, ix'.level y = if y = slot then lv else ix.level y := fun y => by rw [s2, hL]
    refine ⟨by rw [s1]; exact h.slots_le, fun x hx => ?_, fun x hx => ?_, fun t ht => ?_, fun x hx => ?_, ?_,
      fun x => ?_, by rw [s5]; exact h.free_nodup, by rw [s6, hc.2, h.twins_eq]; omega,
      by rw [s7, hc.1, hc.2, h.live_eq]; omega, fun _ => ?_, fun hl => by rw [s7] at hl; omega⟩
    · rw [s1] at hx; rw [hL']; split
      · left; exact hlv
      · exact h.bytes x hx
    · simp only [Ix.isLive, Ix.isTwin, s1, hL', s3] at hx ⊢
      have hxs : x ≠ slot := fun e' => hx (e' ▸ hsn)
      obtain ⟨⟨a1, a2⟩, ⟨b1, b2⟩⟩ := h.next_live x hx
      exact ⟨⟨a1, by simp [hxs, a2]⟩, ⟨b1, by simp [hnt x hx, b2]⟩⟩
    · simp only [Ix.isTwin, s1, hL'] at ht
      have hts : t ≠ slot := fun e' => by simp [e', hlvt] at ht
      simp only [hts, ite_false] at ht
      rw [s4, s3]; exact h.prev_next t ⟨ht.1, ht.2⟩
    · rw [s3] at hx; rw [s4, s3]; exact h.next_prev x hx
    · obtain ⟨r, hr⟩ := h.rank
      refine ⟨r, fun t ht => ?_⟩
      simp only [Ix.isTwin, Ix.isNode, s1, hL', s4] at ht ⊢
      have hts : t ≠ slot := fun e' => by simp [e', hlvt] at ht
      simp only [hts, ite_false] at ht
      simp only [hpt t ⟨ht.1, ht.2⟩, ite_false]
      exact hr t ⟨ht.1, ht.2⟩
    · rw [s5, s1, hL']
      by_cases hxs : x = slot
      · simp only [hxs, ite_true]
        constructor
        · intro hm; have := ((h.free_iff slot).mp hm).2; rw [hs.2] at this; simp [lvlReserved, lvlFree] at this
        · intro ⟨_, e'⟩; unfold lvlFree levelCap at *; omega
      · simp only [hxs, ite_false]; exact h.free_iff x
    · have : ∀ x, ix'.isNode x ↔ (nodePlace ix slot lv).isNode x := fun x => by unfold Ix.isNode; rw [s1, s2]; rfl
      simp only [s8, s9, this, s2]
      exact he
  refine ⟨fun e ml he => hfin e ml he _ rfl rfl rfl rfl rfl rfl rfl rfl rfl, fun l => ?_⟩
  have hab : (ix.layer l).present slot = false := twin_absent_level ix slot (Or.inr (Or.inl hs.2)) l
  refine ⟨fun a b hb => ?_, fun a => ?_, fun a => ?_, fun a => ?_, fun a b hb => ?_⟩
  · show a ∈ (nodePlace ix slot lv).adj l b
    have hb' : b ∈ (nodePlace ix slot lv).adj l a := hb
    rw [hA] at hb' ⊢
    split at hb'
    · simp at hb'
    · next has =>
      have hbs : b ≠ slot := fun e' => absent_not_mem (hw l) slot hab a (e' ▸ hb')
      rw [ite_eq_right hbs]; exact (hw l).symm a b hb'
  · show a ∉ (nodePlace ix slot lv).adj l a
    rw [hA]; split
    · simp
    · exact (hw l).irrefl a
  · show ((nodePlace ix slot lv).adj l a).Nodup
    rw [hA]; split
    · exact List.nodup_nil
    · exact (hw l).nodup a
  · show ((nodePlace ix slot lv).adj l a).length ≤ layerCap m l
    rw [hA]; split
    · simp
    · exact (hw l).bound a
  · have hb' : b ∈ (nodePlace ix slot lv).adj l a := hb
    rw [hA] at hb'
    split at hb'
    · simp at hb'
    · have hbs : b ≠ slot := fun e' => absent_not_mem (hw l) slot hab a (e' ▸ hb')
      show (nodePlace ix slot lv).present l b = true
      rw [present_congr ix _ b (by rw [hS]) (by rw [hL, ite_eq_right hbs]) l]
      exact (hw l).closed a b hb'


def insertOp (m : Nat) (ix : Ix) (slot lv : Nat) (head : Option Nat) (sel : Nat → List Nat)
    (victim : Nat → Graph → Nat → Nat) (guard : Nat → Graph → Nat → Nat → Bool)
    (pick : Nat → Graph → Nat → List Nat → Option Nat) : Ix :=
  if ix.entry = noneId then { nodePlace ix slot lv with entry := slot, maxLevel := lv }
  else match head with
    | some hd => attach ix slot hd
    | none =>
      let ix2 := foldLayers (fun l _ g => connect (layerCap m l) g slot (sel l) (victim l) (guard l) (pick l))
        (nodePlace ix slot lv) (List.range (min ix.maxLevel lv + 1)).reverse
      if ix.maxLevel < lv then { ix2 with entry := slot, maxLevel := lv } else ix2

theorem insert_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (slot lv : Nat) (hs : ix.isReserved slot)
    (hlv : lv ≤ levelCap) (head : Option Nat) (hhead : ∀ x, head = some x → ix.isNode x)
    (sel : Nat → List Nat) (victim : Nat → Graph → Nat → Nat) (guard : Nat → Graph → Nat → Nat → Bool)
    (pick : Nat → Graph → Nat → List Nat → Option Nat) (hpick : ∀ l, PickOk (pick l))
    (hvict : ∀ l g' e', victim l g' e' ∈ g'.adj e' ∨ victim l g' e' = slot)
    (hsel : ∀ l, l ≤ min ix.maxLevel lv → (sel l).Nodup ∧ slot ∉ sel l ∧ ∀ x ∈ sel l, ix.present l x = true) :
    TwinInv (insertOp m ix slot lv head sel victim guard pick) ∧
      GraphWf m (insertOp m ix slot lv head sel victim guard pick) := by
  have hsl : slot < ix.slots := hs.1
  have hS : (nodePlace ix slot lv).slots = ix.slots := rfl
  have hL : ∀ y, (nodePlace ix slot lv).level y = if y = slot then lv else ix.level y := fun _ => rfl
  have hA : ∀ l y, (nodePlace ix slot lv).adj l y = if y = slot then [] else ix.adj l y := fun _ _ => rfl
  have hns : (nodePlace ix slot lv).isNode slot := ⟨by rw [hS]; exact hsl, by rw [hL]; simp [hlv]⟩
  have hold : ∀ x, (nodePlace ix slot lv).isNode x → x ≠ slot → ix.isNode x := fun x hx hxs =>
    ⟨by rw [← hS]; exact hx.1, by have := hx.2; rw [hL, ite_eq_right hxs] at this; exact this⟩
  unfold insertOp
  split
  · next hen =>
    have hl0 : ix.live = 0 := by
      by_cases hl : 0 < ix.live
      · exact absurd hen (entry_ne_none h hl)
      · omega
    have hnone : ∀ x, ¬ ix.isNode x := fun x hx => by have := node_live_pos h x hx; omega
    obtain ⟨t1, t2⟩ := place_inv m ix h hw slot lv hs hlv
    exact ⟨t1 slot lv ⟨hns, by rw [hL]; simp, fun x hx => by
      by_cases hxs : x = slot
      · rw [hxs, hL]; simp
      · exact absurd (hold x hx hxs) (hnone x)⟩, t2⟩
  · next hen =>
    have hlive : 0 < ix.live := by
      by_cases hl : ix.live = 0
      · exact absurd (h.entry_none hl) hen
      · omega
    cases head with
    | some hd => exact attach_inv m ix h hw slot hd hs (hhead hd rfl)
    | none =>
      obtain ⟨e1, e2, e3⟩ := h.entry_live hlive
      have hes : ix.entry ≠ slot := fun e => by have := e1.2; rw [e, hs.2] at this; simp [lvlReserved, levelCap] at this
      obtain ⟨tP, hwP⟩ := place_inv m ix h hw slot lv hs hlv
      have hent : ∀ e ml, (nodePlace ix slot lv).isNode e ∧ (nodePlace ix slot lv).level e = ml ∧
          (∀ x, (nodePlace ix slot lv).isNode x → (nodePlace ix slot lv).level x ≤ ml) →
          ∀ ix' : Ix, ix'.slots = ix.slots → ix'.level = (nodePlace ix slot lv).level → ix'.next = ix.next →
            ix'.prev = ix.prev → ix'.free = ix.free → ix'.twins = ix.twins → ix'.live = ix.live + 1 →
            ix'.entry = e → ix'.maxLevel = ml → TwinInv ix' := by
        intro e ml he ix' s1 s2 s3 s4 s5 s6 s7 s8 s9
        exact twinInv_congr _ ix' (tP e ml he) s1 s2 s3 s4 s5 s6 s7 s8 s9
      have hnd : ((List.range (min ix.maxLevel lv + 1)).reverse).Nodup := (List.reverse_perm _).nodup_iff.mpr List.nodup_range
      have hgf := foldLayers_wf m (fun l _ g => connect (layerCap m l) g slot (sel l) (victim l) (guard l) (pick l))
        (nodePlace ix slot lv) _ hnd (fun l _ => hwP l) (fun l hl ctx => by
          have hl' : l ≤ min ix.maxLevel lv := by
            have := List.mem_range.mp (List.mem_reverse.mp hl); omega
          obtain ⟨s1, s2, s3⟩ := hsel l hl'
          refine connect_wf (layerCap m l) ((nodePlace ix slot lv).layer l) slot (sel l) (victim l) (guard l) (pick l)
            (hpick l) (hwP l) ?_ (by show (nodePlace ix slot lv).adj l slot = []; rw [hA]; simp) s1 s2 (fun x hx => ?_)
            (hvict l)
          · show (nodePlace ix slot lv).present l slot = true
            rw [present_iff, hS, hL]; simp only [ite_true]; exact ⟨hsl, hlv, by omega⟩
          · have hxs : x ≠ slot := fun e => s2 (e ▸ hx)
            show (nodePlace ix slot lv).present l x = true
            rw [present_congr ix _ x (by rw [hS]) (by rw [hL, ite_eq_right hxs]) l]
            exact s3 x hx)
      obtain ⟨f1, f2, f3, f4, f5, f6, f7, f8, f9⟩ := foldLayers_frame
        (fun l _ g => connect (layerCap m l) g slot (sel l) (victim l) (guard l) (pick l)) ((List.range (min ix.maxLevel lv + 1)).reverse)
        (nodePlace ix slot lv)
      simp only []
      by_cases hmax : ix.maxLevel < lv
      · rw [ite_eq_left hmax]
        refine ⟨hent slot lv ⟨hns, by rw [hL]; simp, fun x hx => ?_⟩ _ f1 f2 f3 f4 f5 f6 f7 rfl rfl,
          graphWf_frame m _ _ hgf (fun l x => rfl) (fun l x => rfl)⟩
        by_cases hxs : x = slot
        · rw [hxs, hL]; simp
        · rw [hL, ite_eq_right hxs]; have := e3 x (hold x hx hxs); omega
      · rw [ite_eq_right hmax]
        refine ⟨hent ix.entry ix.maxLevel ⟨⟨by rw [hS]; exact e1.1, by rw [hL, ite_eq_right hes]; exact e1.2⟩,
          by rw [hL, ite_eq_right hes]; exact e2, fun x hx => ?_⟩ _ f1 f2 f3 f4 f5 f6 f7 f8 f9, hgf⟩
        by_cases hxs : x = slot
        · rw [hxs, hL]; simp; omega
        · rw [hL, ite_eq_right hxs]; exact e3 x (hold x hx hxs)


def renameIn (old new z : Nat) : Nat := if z = old then new else z

def replaceAll (g : Graph) (ys : List Nat) (old new : Nat) : Graph := ys.foldl (fun g' y => listReplace g' y old new) g

theorem map_rename_id (l : List Nat) (old new : Nat) (h : old ∉ l) : l.map (renameIn old new) = l := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    have hx : x ≠ old := fun e => h (e ▸ List.mem_cons_self)
    simp only [List.map_cons, renameIn, hx, ite_false]
    exact congrArg _ (ih (fun e => h (List.mem_cons_of_mem _ e)))

theorem set_idxOf_map : ∀ (l : List Nat) (a b i : Nat), l.Nodup → l.idxOf? a = some i → l.set i b = l.map (renameIn a b) := by
  intro l
  induction l with
  | nil => intro a b i _ h; simp at h
  | cons x xs ih =>
    intro a b i hnd h
    have hn := List.nodup_cons.mp hnd
    rw [List.idxOf?_cons] at h
    by_cases hx : x = a
    · subst hx
      simp only [beq_self_eq_true, ite_true, Option.some.injEq] at h
      subst h
      have : xs.map (renameIn x b) = xs := map_rename_id xs x b hn.1
      simp [renameIn, this]
    · have hxa : (x == a) = false := by simp [hx]
      simp only [hxa, Bool.false_eq_true, ite_false] at h
      cases hj : xs.idxOf? a with
      | none => rw [hj] at h; simp at h
      | some j =>
        rw [hj] at h
        simp only [Option.map_some, Option.some.injEq] at h
        subst h
        simp only [List.set_cons_succ, List.map_cons, renameIn, hx, ite_false]
        exact congrArg _ (ih a b j hn.2 hj)

theorem mem_rename (l : List Nat) (old new b : Nat) :
    b ∈ l.map (renameIn old new) ↔ (old ∈ l ∧ b = new) ∨ (b ∈ l ∧ b ≠ old) := by
  simp only [List.mem_map, renameIn]
  constructor
  · rintro ⟨z, hz, rfl⟩
    by_cases hzo : z = old
    · subst hzo; left; simp [hz]
    · right; simp [hzo, hz]
  · rintro (⟨h1, rfl⟩ | ⟨h1, h2⟩)
    · exact ⟨old, h1, by simp⟩
    · exact ⟨b, h1, by simp [h2]⟩

theorem nodup_rename (l : List Nat) (old new : Nat) (hnd : l.Nodup) (hn : new ∉ l) : (l.map (renameIn old new)).Nodup := by
  induction l with
  | nil => exact List.nodup_nil
  | cons x xs ih =>
    have h1 := List.nodup_cons.mp hnd
    have hnx : new ∉ xs := fun e => hn (List.mem_cons_of_mem _ e)
    refine List.nodup_cons.mpr ⟨fun hm => ?_, ih h1.2 hnx⟩
    rw [mem_rename] at hm
    unfold renameIn at hm
    by_cases hxo : x = old
    · simp only [hxo, ite_true] at hm
      rcases hm with ⟨h2, _⟩ | ⟨h2, _⟩
      · exact h1.1 (hxo ▸ h2)
      · exact hnx h2
    · simp only [hxo, ite_false] at hm
      rcases hm with ⟨h2, h3⟩ | ⟨h2, _⟩
      · exact hn (h3 ▸ List.mem_cons_self)
      · exact h1.1 h2

theorem relabel_wf (cap : Nat) (g g' : Graph) (old new : Nat) (hw : Wf cap g) (hnp : g.present new = false)
    (hon : old ≠ new)
    (hp : ∀ x, g'.present x = if x = old then false else if x = new then g.present old else g.present x)
    (ha : ∀ x, g'.adj x = if x = old then [] else if x = new then g.adj old else (g.adj x).map (renameIn old new)) :
    Wf cap g' := by
  have hnin : ∀ a, new ∉ g.adj a := absent_not_mem hw new hnp
  have hnnil : g.adj new = [] := adj_nil_of_absent hw new hnp
  have hno : new ≠ old := fun e => hon e.symm
  have hm : ∀ a b, b ∈ g'.adj a ↔ a ≠ old ∧ ((a = new ∧ b ∈ g.adj old) ∨
      (a ≠ new ∧ ((old ∈ g.adj a ∧ b = new) ∨ (b ∈ g.adj a ∧ b ≠ old)))) := by
    intro a b
    rw [ha]
    by_cases hao : a = old
    · simp [hao]
    · by_cases han : a = new
      · simp [han, hno]
      · simp only [hao, han, ite_false, mem_rename, ne_eq, not_false_eq_true, true_and, false_and, false_or]
  have symm := hw.symm; have irrefl := hw.irrefl; have closed := hw.closed
  refine ⟨fun a b hb => ?_, fun a => ?_, fun a => ?_, fun a => ?_, fun a b hb => ?_⟩
  · rw [hm] at hb ⊢
    obtain ⟨hao, hb⟩ := hb
    rcases hb with ⟨han, hb⟩ | ⟨han, ⟨hb1, hbn⟩ | ⟨hb1, hb2⟩⟩
    · have hbn : b ≠ new := fun e => hnin old (e ▸ hb)
      have hbo : b ≠ old := fun e => irrefl old (e ▸ hb)
      refine ⟨hbo, Or.inr ⟨hbn, Or.inl ⟨symm old b hb, han⟩⟩⟩
    · exact ⟨by rw [hbn]; exact hno, Or.inl ⟨hbn, symm a old hb1⟩⟩
    · have hbn : b ≠ new := fun e => hnin a (e ▸ hb1)
      refine ⟨hb2, Or.inr ⟨hbn, Or.inr ⟨symm a b hb1, hao⟩⟩⟩
  · rw [hm]
    rintro ⟨hao, (⟨han, h1⟩ | ⟨han, ⟨_, h2⟩ | ⟨h3, _⟩⟩)⟩
    · exact hnin old (han ▸ h1)
    · exact han h2
    · exact irrefl a h3
  · rw [ha]; split
    · exact List.nodup_nil
    · split
      · exact hw.nodup old
      · exact nodup_rename _ _ _ (hw.nodup a) (hnin a)
  · rw [ha]; split
    · simp
    · split
      · exact hw.bound old
      · rw [List.length_map]; exact hw.bound a
  · rw [hm] at hb
    rw [hp]
    obtain ⟨hao, hb⟩ := hb
    rcases hb with ⟨_, hb⟩ | ⟨_, ⟨hb1, hbn⟩ | ⟨hb1, hb2⟩⟩
    · have hbn : b ≠ new := fun e => hnin old (e ▸ hb)
      have hbo : b ≠ old := fun e => irrefl old (e ▸ hb)
      rw [ite_eq_right hbo, ite_eq_right hbn]; exact closed old b hb
    · rw [hbn, ite_eq_right hno, ite_eq_left rfl]; exact closed a old hb1
    · have hbn : b ≠ new := fun e => hnin a (e ▸ hb1)
      rw [ite_eq_right hb2, ite_eq_right hbn]; exact closed a b hb1

theorem replaceAll_spec (old new : Nat) : ∀ (ys : List Nat) (g : Graph), ys.Nodup →
    (∀ y ∈ ys, (g.adj y).Nodup ∧ old ∈ g.adj y) →
    (replaceAll g ys old new).present = g.present ∧
      ∀ x, (replaceAll g ys old new).adj x = if x ∈ ys then (g.adj x).map (renameIn old new) else g.adj x := by
  intro ys
  induction ys with
  | nil => intro g _ _; exact ⟨rfl, fun x => by simp [replaceAll]⟩
  | cons y ys ih =>
    intro g hnd hy
    have hn := List.nodup_cons.mp hnd
    obtain ⟨hy1, hy2⟩ := hy y List.mem_cons_self
    have hrep : (listReplace g y old new).adj y = (g.adj y).map (renameIn old new) := by
      unfold listReplace
      split
      · next h0 => exact absurd hy2 (List.idxOf?_eq_none_iff.mp h0)
      · next i hi => rw [setAdj_adj, ite_eq_left rfl]; exact set_idxOf_map _ _ _ _ hy1 hi
    have hoth : ∀ x, x ≠ y → (listReplace g y old new).adj x = g.adj x := fun x hx => listReplace_other g y old new x hx
    obtain ⟨i1, i2⟩ := ih (listReplace g y old new) hn.2 (fun z hz => by
      have hzy : z ≠ y := fun e => hn.1 (e ▸ hz)
      rw [hoth z hzy]; exact hy z (List.mem_cons_of_mem _ hz))
    have e : replaceAll g (y :: ys) old new = replaceAll (listReplace g y old new) ys old new := rfl
    rw [e]
    refine ⟨by rw [i1, listReplace_present], fun x => ?_⟩
    rw [i2 x]
    by_cases hxy : x = y
    · subst hxy; simp [hn.1, hrep]
    · rw [hoth x hxy]
      by_cases hxs : x ∈ ys
      · simp [hxs]
      · simp [hxs, hxy]


def promoteCopy (ix : Ix) (head : Nat) : Ix :=
  { ix.setLevel (ix.next head) (ix.level head) with
    adj := fun l y => if y = ix.next head then ix.adj l head else ix.adj l y }

def promoteLinks (ix : Ix) (head : Nat) : Ix :=
  foldLayers (fun l _ g => replaceAll g ((promoteCopy ix head).adj l (ix.next head)) head (ix.next head))
    (promoteCopy ix head) (List.range (ix.level head + 1))

def promoteEntry (ix : Ix) (head : Nat) : Nat := if ix.entry = head then ix.next head else ix.entry

def promote (ix : Ix) (head : Nat) : Ix :=
  { pushFree { promoteLinks ix head with twins := ix.twins - 1, entry := promoteEntry ix head } head with
    live := ix.live - 1 }

theorem promote_fields (ix : Ix) (head : Nat) :
    (promote ix head).slots = ix.slots ∧
    (∀ y, (promote ix head).level y = if y = head then lvlFree else (promoteCopy ix head).level y) ∧
    (∀ y, (promote ix head).next y = if y = head then noneId else ix.next y) ∧ (promote ix head).prev = ix.prev ∧
    (∀ l y, (promote ix head).adj l y = if y = head then [] else (promoteLinks ix head).adj l y) ∧
    (promote ix head).free = head :: ix.free ∧ (promote ix head).twins = ix.twins - 1 ∧
    (promote ix head).live = ix.live - 1 ∧
    (promote ix head).entry = promoteEntry ix head ∧
    (promote ix head).maxLevel = ix.maxLevel := by
  obtain ⟨f1, f2, f3, f4, f5, f6, f7, f8, f9⟩ := foldLayers_frame
    (fun l _ g => replaceAll g ((promoteCopy ix head).adj l (ix.next head)) head (ix.next head))
    (List.range (ix.level head + 1)) (promoteCopy ix head)
  refine ⟨f1, fun y => ?_, fun y => ?_, f4, fun l y => rfl, ?_, rfl, rfl, rfl, f9⟩
  · show (if y = head then lvlFree else (promoteLinks ix head).level y) = _
    unfold promoteLinks; rw [f2]
  · show (if y = head then noneId else (promoteLinks ix head).next y) = _
    unfold promoteLinks; rw [f3]; rfl
  · show head :: (promoteLinks ix head).free = _
    unfold promoteLinks; rw [f5]; rfl

theorem promote_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (head : Nat) (hh : ix.isNode head)
    (hn : ix.next head ≠ noneId) : TwinInv (promote ix head) ∧ GraphWf m (promote ix head) := by
  have heirT : ix.isTwin (ix.next head) := (h.next_live head hn).2
  have hpheir : ix.prev (ix.next head) = head := h.next_prev head hn
  have hhl : head < ix.slots := hh.1
  have hhe : head ≠ ix.next head := fun e => (twin_kinds h head hhl).2 ⟨hh, e ▸ heirT⟩
  have heh : ix.next head ≠ head := fun e => hhe e.symm
  obtain ⟨r, hr⟩ := h.rank
  have hS := (promote_fields ix head).1
  have hL := (promote_fields ix head).2.1
  have hN := (promote_fields ix head).2.2.1
  have hP := (promote_fields ix head).2.2.2.1
  have hA := (promote_fields ix head).2.2.2.2.1
  have hF := (promote_fields ix head).2.2.2.2.2.1
  have hT := (promote_fields ix head).2.2.2.2.2.2.1
  have hLv := (promote_fields ix head).2.2.2.2.2.2.2.1
  have hE := (promote_fields ix head).2.2.2.2.2.2.2.2.1
  have hM := (promote_fields ix head).2.2.2.2.2.2.2.2.2
  have hCL : ∀ y, (promoteCopy ix head).level y = if y = ix.next head then ix.level head else ix.level y := fun _ => rfl
  have hLL : ∀ y, (promote ix head).level y =
      if y = head then lvlFree else if y = ix.next head then ix.level head else ix.level y := fun y => by rw [hL, hCL]
  have hnc1 := nodeCount_change ix (promoteCopy ix head) (ix.next head) rfl heirT.1 (fun y hy => by rw [hCL]; simp [hy])
  have htc1 := twinCount_change ix (promoteCopy ix head) (ix.next head) rfl heirT.1 (fun y hy => by rw [hCL]; simp [hy])
  have hnc2 := nodeCount_change (promoteCopy ix head) (promote ix head) head hS hhl (fun y hy => by rw [hL]; simp [hy])
  have htc2 := twinCount_change (promoteCopy ix head) (promote ix head) head hS hhl (fun y hy => by rw [hL]; simp [hy])
  have hlh : ix.level head ≤ 30 := hh.2
  have hlh' : ¬ (ix.level head = 253) := by omega
  simp only [hCL, hL, ite_true, heirT.2, lvlTwin, lvlFree, levelCap, hlh, hlh', hhe, ite_false,
    show ¬ (253 ≤ 30) by decide, show ¬ (255 ≤ 30) by decide, show ¬ (255 = 253) by decide, Nat.add_zero] at hnc1 htc1 hnc2 htc2
  have hnext_ne : ∀ x, ix.next x ≠ noneId → x ≠ head → ix.next x ≠ ix.next head := fun x hx hxh e => by
    have := h.next_prev x hx; rw [e, hpheir] at this; exact hxh this.symm
  have hprev_ne : ∀ t, ix.isTwin t → t ≠ ix.next head → ix.prev t ≠ head := fun t ht hth e => by
    have := h.prev_next t ht; rw [e] at this; exact hth this.symm
  have hlive : 0 < ix.live := node_live_pos h head hh
  obtain ⟨e1, e2, e3⟩ := h.entry_live hlive
  have heirN : (promote ix head).isNode (ix.next head) :=
    ⟨by rw [hS]; exact heirT.1, by rw [hLL, ite_eq_right heh, ite_eq_left rfl]; exact hh.2⟩
  have hentry_ne : ix.entry ≠ ix.next head := fun e => (twin_kinds h _ heirT.1).2 ⟨e ▸ e1, heirT⟩
  have hpos : 0 < (promote ix head).nodeCount := by
    have := countB_pos (fun y => decide ((promote ix head).level y ≤ levelCap)) (ix.next head) (promote ix head).slots
      heirN.1 (by simp [heirN.2])
    unfold Ix.nodeCount; omega
  have htc0 : 0 < ix.twinCount := by
    have := countB_pos (fun y => ix.level y == lvlTwin) (ix.next head) ix.slots heirT.1 (by simp [heirT.2])
    unfold Ix.twinCount; omega
  refine ⟨⟨by rw [hS]; exact h.slots_le, fun x hx => ?_, fun x hx => ?_, fun t ht => ?_, fun x hx => ?_, ?_,
    fun x => ?_, ?_, by rw [hT, h.twins_eq]; omega, by rw [hLv, h.live_eq]; omega, fun _ => ?_,
    fun hl0 => by rw [hLv, h.live_eq] at hl0; omega⟩, fun l => ?_⟩
  · rw [hS] at hx; rw [hLL]; split
    · right; right; right; rfl
    · split
      · left; exact hlh
      · exact h.bytes x hx
  · simp only [Ix.isLive, Ix.isTwin, hS, hLL, hN] at hx ⊢
    have hxh : x ≠ head := fun e => by simp [e] at hx
    simp only [hxh, ite_false] at hx ⊢
    obtain ⟨⟨a1, a2⟩, ⟨b1, b2⟩⟩ := h.next_live x hx
    have hnh : ix.next x ≠ head := fun e => (twin_kinds h head hhl).2 ⟨hh, ⟨hhl, by rw [← e]; exact b2⟩⟩
    refine ⟨⟨a1, ?_⟩, ⟨b1, by simp [hnh, hnext_ne x hx hxh, b2]⟩⟩
    split
    · unfold lvlReserved; omega
    · exact a2
  · simp only [Ix.isTwin, hS, hLL] at ht
    have hth : t ≠ head := fun e => by rw [e, ite_eq_left rfl] at ht; simp [lvlFree, lvlTwin] at ht
    have htn : t ≠ ix.next head := fun e => by rw [e, ite_eq_right heh, ite_eq_left rfl] at ht; exact hlh' ht.2
    simp only [hth, htn, ite_false] at ht
    have ht' : ix.isTwin t := ⟨ht.1, ht.2⟩
    rw [hP, hN, ite_eq_right (hprev_ne t ht' htn)]
    exact h.prev_next t ht'
  · simp only [hN] at hx
    have hxh : x ≠ head := fun e => by simp [e] at hx
    rw [ite_eq_right hxh] at hx
    rw [hP, hN, ite_eq_right hxh]
    exact h.next_prev x hx
  · refine ⟨r, fun t ht => ?_⟩
    simp only [Ix.isTwin, hS, hLL] at ht
    have hth : t ≠ head := fun e => by rw [e, ite_eq_left rfl] at ht; simp [lvlFree, lvlTwin] at ht
    have htn : t ≠ ix.next head := fun e => by rw [e, ite_eq_right heh, ite_eq_left rfl] at ht; exact hlh' ht.2
    simp only [hth, htn, ite_false] at ht
    have ht' : ix.isTwin t := ⟨ht.1, ht.2⟩
    have hph := hprev_ne t ht' htn
    simp only [Ix.isTwin, Ix.isNode, hS, hLL, hP, hph, ite_false]
    rcases hr t ht' with h1 | ⟨h1, h2⟩
    · left
      have hpn : ix.prev t ≠ ix.next head := fun e => (twin_kinds h _ h1.1).2 ⟨h1, e ▸ heirT⟩
      simp only [hpn, ite_false]; exact h1
    · by_cases hpn : ix.prev t = ix.next head
      · left; simp only [hpn, ite_true]; exact ⟨heirT.1, hlh⟩
      · right; simp only [hpn, ite_false]; exact ⟨h1, h2⟩
  · rw [hF, hS, hLL]
    by_cases hxh : x = head
    · rw [hxh, ite_eq_left rfl]; simp [hhl]
    · rw [ite_eq_right hxh, List.mem_cons]
      by_cases hxn : x = ix.next head
      · rw [ite_eq_left hxn]
        constructor
        · rintro (e | e)
          · exact absurd e hxh
          · have := ((h.free_iff _).mp e).2; rw [hxn, heirT.2] at this; simp [lvlTwin, lvlFree] at this
        · intro ⟨_, e⟩; unfold lvlFree at e; omega
      · rw [ite_eq_right hxn]
        constructor
        · rintro (e | e)
          · exact absurd e hxh
          · exact (h.free_iff x).mp e
        · intro hx; exact Or.inr ((h.free_iff x).mpr hx)
  · rw [hF]
    refine List.nodup_cons.mpr ⟨fun hm => ?_, h.free_nodup⟩
    have := ((h.free_iff head).mp hm).2; unfold lvlFree at this; omega
  · rw [hE, hM]
    have key : ∀ x, (promote ix head).isNode x → (promote ix head).level x ≤ ix.maxLevel := by
      intro x hx
      have hx1 := hx.1
      have hx2 := hx.2
      rw [hS] at hx1
      rw [hLL x] at hx2 ⊢
      by_cases hxh : x = head
      · rw [ite_eq_left hxh] at hx2; unfold lvlFree levelCap at hx2; omega
      · rw [ite_eq_right hxh] at hx2 ⊢
        by_cases hxn : x = ix.next head
        · rw [ite_eq_left hxn]; exact e3 head hh
        · rw [ite_eq_right hxn] at hx2 ⊢; exact e3 x ⟨hx1, hx2⟩
    unfold promoteEntry
    by_cases hent : ix.entry = head
    · rw [ite_eq_left hent]
      refine ⟨heirN, ?_, key⟩
      rw [hLL, ite_eq_right heh, ite_eq_left rfl, ← hent]; exact e2
    · rw [ite_eq_right hent]
      refine ⟨⟨by rw [hS]; exact e1.1, ?_⟩, ?_, key⟩
      · rw [hLL, ite_eq_right hent, ite_eq_right hentry_ne]; exact e1.2
      · rw [hLL, ite_eq_right hent, ite_eq_right hentry_ne]; exact e2
  · have hnp : (ix.layer l).present (ix.next head) = false := twin_absent_level ix _ (Or.inl heirT.2) l
    have hcopy : ∀ y, (promoteCopy ix head).adj l y = if y = ix.next head then ix.adj l head else ix.adj l y :=
      fun _ => rfl
    have hnin : ∀ a, ix.next head ∉ ix.adj l a := absent_not_mem (hw l) _ hnp
    refine relabel_wf (layerCap m l) (ix.layer l) ((promote ix head).layer l) head (ix.next head) (hw l) hnp hhe
      (fun x => ?_) (fun x => ?_)
    · show (promote ix head).present l x = _
      by_cases hxh : x = head
      · rw [ite_eq_left hxh, hxh]
        exact absent_of _ head (Or.inr (by rw [hLL, ite_eq_left rfl]; unfold lvlFree levelCap; omega)) l
      · rw [ite_eq_right hxh]
        by_cases hxn : x = ix.next head
        · rw [ite_eq_left hxn, hxn]
          show _ = ix.present l head
          unfold Ix.present
          rw [hS, hLL, ite_eq_right heh, ite_eq_left rfl]
          simp [heirT.1, hhl]
        · rw [ite_eq_right hxn]
          exact present_congr ix _ x (by rw [hS]) (by rw [hLL, ite_eq_right hxh, ite_eq_right hxn]) l
    · show (promote ix head).adj l x = _
      rw [hA]
      by_cases hxh : x = head
      · rw [ite_eq_left hxh, ite_eq_left hxh]
      · rw [ite_eq_right hxh, ite_eq_right hxh]
        have hnd : (List.range (ix.level head + 1)).Nodup := List.nodup_range
        obtain ⟨a1, a2⟩ := foldLayers_adj
          (fun l _ g => replaceAll g ((promoteCopy ix head).adj l (ix.next head)) head (ix.next head))
          _ (promoteCopy ix head) hnd
        have hhx : ∀ y, y ∉ ix.adj l head → head ∉ ix.adj l y := fun y hy hm => hy ((hw l).symm y head hm)
        by_cases hl : l ∈ List.range (ix.level head + 1)
        · obtain ⟨ctx, hc⟩ := a2 l hl
          unfold promoteLinks
          rw [hc]
          show (replaceAll ((promoteCopy ix head).layer l) ((promoteCopy ix head).adj l (ix.next head)) head
            (ix.next head)).adj x = _
          rw [hcopy (ix.next head), ite_eq_left rfl]
          obtain ⟨_, rs⟩ := replaceAll_spec head (ix.next head) (ix.adj l head) ((promoteCopy ix head).layer l)
            ((hw l).nodup head) (fun y hy => by
              have hyn : y ≠ ix.next head := fun e => hnin head (e ▸ hy)
              show ((promoteCopy ix head).adj l y).Nodup ∧ head ∈ (promoteCopy ix head).adj l y
              rw [hcopy y, ite_eq_right hyn]
              exact ⟨(hw l).nodup y, (hw l).symm head y hy⟩)
          rw [rs x]
          show (if x ∈ ix.adj l head then ((promoteCopy ix head).adj l x).map (renameIn head (ix.next head))
            else (promoteCopy ix head).adj l x) = _
          by_cases hxn : x = ix.next head
          · rw [ite_eq_right (show x ∉ ix.adj l head from fun e => hnin head (hxn ▸ e)), ite_eq_left hxn, hcopy x,
              ite_eq_left hxn]
            rfl
          · rw [ite_eq_right hxn, hcopy x, ite_eq_right hxn]
            by_cases hxa : x ∈ ix.adj l head
            · rw [ite_eq_left hxa]; rfl
            · rw [ite_eq_right hxa]
              show ix.adj l x = (ix.adj l x).map (renameIn head (ix.next head))
              rw [map_rename_id _ _ _ (hhx x hxa)]
        · unfold promoteLinks
          rw [a1 l hl, hcopy x]
          have hlh2 : ix.level head < l := by simp at hl; omega
          have hpa : (ix.layer l).present head = false := by
            show ix.present l head = false
            unfold Ix.present; simp; omega
          have hnil : ix.adj l head = [] := adj_nil_of_absent (hw l) head hpa
          have hnot : ∀ a, head ∉ ix.adj l a := absent_not_mem (hw l) head hpa
          by_cases hxn : x = ix.next head
          · rw [ite_eq_left hxn, ite_eq_left hxn]; rfl
          · rw [ite_eq_right hxn, ite_eq_right hxn]
            show ix.adj l x = (ix.adj l x).map (renameIn head (ix.next head))
            rw [map_rename_id _ _ _ (hnot x)]


def unlinkLayer (slot : Nat) (grp : List Nat) (g : Graph) : Graph := grp.foldl (fun g' n => listRemove g' n slot) g

def pickFold (level : Nat → Nat) : Nat → Option (Nat × Nat)
  | 0 => none
  | n + 1 => match pickFold level n with
    | none => if level n ≤ levelCap then some (n, level n) else none
    | some (b, bl) => if level n ≤ levelCap ∧ bl < level n then some (n, level n) else some (b, bl)

def pickEntry (ix : Ix) : Ix :=
  match pickFold ix.level ix.slots with
  | none => { ix with entry := noneId, maxLevel := 0 }
  | some (b, bl) => { ix with entry := b, maxLevel := bl }

def removeUnlink (ix : Ix) (slot : Nat) : Ix :=
  { pushFree (foldLayers (fun l _ g => unlinkLayer slot (ix.adj l slot) g) ix (List.range (ix.level slot + 1))) slot with
    live := ix.live - 1 }

def removePlain (ix : Ix) (slot : Nat) (repairL : Nat → Ix → Graph → Graph) : Ix :=
  if (removeUnlink ix slot).live = 0 then { removeUnlink ix slot with entry := noneId, maxLevel := 0 }
  else foldLayers repairL (if ix.entry = slot then pickEntry (removeUnlink ix slot) else removeUnlink ix slot)
    (List.range (ix.level slot + 1))

def removeOp (ix : Ix) (slot : Nat) (repairL : Nat → Ix → Graph → Graph) : Ix :=
  if ix.level slot = lvlTwin then removeTwin ix slot
  else if ix.next slot ≠ noneId then promote ix slot
  else removePlain ix slot repairL

theorem pickFold_spec (level : Nat → Nat) : ∀ n,
    (pickFold level n = none ↔ ∀ x, x < n → ¬ level x ≤ levelCap) ∧
    (∀ b bl, pickFold level n = some (b, bl) → b < n ∧ level b ≤ levelCap ∧ bl = level b ∧
      ∀ x, x < n → level x ≤ levelCap → level x ≤ bl) := by
  intro n
  induction n with
  | zero => exact ⟨by simp [pickFold], fun b bl h => by simp [pickFold] at h⟩
  | succ n ih =>
    obtain ⟨i1, i2⟩ := ih
    simp only [pickFold]
    cases hp : pickFold level n with
    | none =>
      have hall := i1.mp hp
      simp only
      by_cases hn : level n ≤ levelCap
      · rw [ite_eq_left hn]
        refine ⟨⟨fun h => by simp at h, fun h => absurd hn (h n (by omega))⟩, fun b bl h => ?_⟩
        simp only [Option.some.injEq, Prod.mk.injEq] at h
        obtain ⟨rfl, rfl⟩ := h
        refine ⟨by omega, hn, rfl, fun x hx hl => ?_⟩
        by_cases hxn : x = n
        · rw [hxn]; exact Nat.le_refl _
        · exact absurd hl (hall x (by omega))
      · rw [ite_eq_right hn]
        refine ⟨⟨fun _ x hx => ?_, fun _ => rfl⟩, fun b bl h => by simp at h⟩
        by_cases hxn : x = n
        · rw [hxn]; exact hn
        · exact hall x (by omega)
    | some p =>
      obtain ⟨b0, bl0⟩ := p
      obtain ⟨j1, j2, j3, j4⟩ := i2 b0 bl0 hp
      simp only
      by_cases hn : level n ≤ levelCap ∧ bl0 < level n
      · rw [ite_eq_left hn]
        refine ⟨⟨fun h => by simp at h, fun h => absurd hn.1 (h n (by omega))⟩, fun b bl h => ?_⟩
        simp only [Option.some.injEq, Prod.mk.injEq] at h
        obtain ⟨rfl, rfl⟩ := h
        refine ⟨by omega, hn.1, rfl, fun x hx hl => ?_⟩
        by_cases hxn : x = n
        · rw [hxn]; exact Nat.le_refl _
        · have := j4 x (by omega) hl; omega
      · rw [ite_eq_right hn]
        refine ⟨⟨fun h => by simp at h, fun h => absurd j2 (h b0 (by omega))⟩, fun b bl h => ?_⟩
        simp only [Option.some.injEq, Prod.mk.injEq] at h
        obtain ⟨rfl, rfl⟩ := h
        refine ⟨by omega, j2, j3, fun x hx hl => ?_⟩
        by_cases hxn : x = n
        · rw [hxn] at hl ⊢
          by_cases hc : bl0 < level n
          · exact absurd ⟨hl, hc⟩ hn
          · omega
        · exact j4 x (by omega) hl

theorem removeUnlink_fields (ix : Ix) (slot : Nat) :
    (removeUnlink ix slot).slots = ix.slots ∧
    (∀ y, (removeUnlink ix slot).level y = if y = slot then lvlFree else ix.level y) ∧
    (∀ y, (removeUnlink ix slot).next y = if y = slot then noneId else ix.next y) ∧
    (removeUnlink ix slot).prev = ix.prev ∧
    (∀ l y, (removeUnlink ix slot).adj l y = if y = slot then [] else
      (foldLayers (fun l _ g => unlinkLayer slot (ix.adj l slot) g) ix (List.range (ix.level slot + 1))).adj l y) ∧
    (removeUnlink ix slot).free = slot :: ix.free ∧ (removeUnlink ix slot).twins = ix.twins ∧
    (removeUnlink ix slot).live = ix.live - 1 ∧ (removeUnlink ix slot).entry = ix.entry ∧
    (removeUnlink ix slot).maxLevel = ix.maxLevel := by
  obtain ⟨f1, f2, f3, f4, f5, f6, f7, f8, f9⟩ := foldLayers_frame
    (fun l _ g => unlinkLayer slot (ix.adj l slot) g) (List.range (ix.level slot + 1)) ix
  refine ⟨f1, fun y => ?_, fun y => ?_, f4, fun l y => rfl, ?_, f6, rfl, f8, f9⟩
  · show (if y = slot then lvlFree else _) = _; rw [f2]
  · show (if y = slot then noneId else (foldLayers (fun l _ g => unlinkLayer slot (ix.adj l slot) g) ix
      (List.range (ix.level slot + 1))).next y) = _
    rw [f3]
  · show slot :: _ = _; rw [f5]

theorem countB_exists (f : Nat → Bool) : ∀ n, 0 < countB f n → ∃ x, x < n ∧ f x = true := by
  intro n
  induction n with
  | zero => intro h; simp [countB] at h
  | succ n ih =>
    intro h
    simp only [countB] at h
    by_cases hf : f n = true
    · exact ⟨n, by omega, hf⟩
    · simp [hf] at h
      obtain ⟨x, hx, hfx⟩ := ih h
      exact ⟨x, by omega, hfx⟩

theorem unlinkLayer_present (slot : Nat) : ∀ (grp : List Nat) (g : Graph), (unlinkLayer slot grp g).present = g.present := by
  intro grp
  induction grp with
  | nil => intro g; rfl
  | cons n grp ih =>
    intro g
    show (unlinkLayer slot grp (listRemove g n slot)).present = g.present
    rw [ih, listRemove_present]

theorem remove_unlink_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (slot : Nat) (hs : ix.isNode slot)
    (hn : ix.next slot = noneId) :
    (∀ e ml, (0 < (removeUnlink ix slot).live → (removeUnlink ix slot).isNode e ∧ (removeUnlink ix slot).level e = ml ∧
        ∀ x, (removeUnlink ix slot).isNode x → (removeUnlink ix slot).level x ≤ ml) →
      ((removeUnlink ix slot).live = 0 → e = noneId) →
      TwinInv { removeUnlink ix slot with entry := e, maxLevel := ml }) ∧
    GraphWf m (removeUnlink ix slot) ∧
    (0 < (removeUnlink ix slot).live → ∃ x, (removeUnlink ix slot).isNode x) := by
  have hsl : slot < ix.slots := hs.1
  obtain ⟨hS, hL, hN, hP, hA, hF, hT, hLv, hE, hM⟩ := removeUnlink_fields ix slot
  have hnc := nodeCount_change ix (removeUnlink ix slot) slot hS hsl (fun y hy => by rw [hL]; simp [hy])
  have htc := twinCount_change ix (removeUnlink ix slot) slot hS hsl (fun y hy => by rw [hL]; simp [hy])
  have hl30 : ix.level slot ≤ 30 := hs.2
  have hl253 : ¬ (ix.level slot = 253) := by omega
  simp only [hL, ite_true, hl30, hl253, lvlTwin, lvlFree, levelCap, show ¬ (255 ≤ 30) by decide,
    show ¬ (255 = 253) by decide, ite_false, Nat.add_zero] at hnc htc
  have hnt : ∀ x, ix.next x ≠ noneId → ix.next x ≠ slot := fun x hx e' => by
    have := (h.next_live x hx).2; exact (twin_kinds h slot hsl).2 ⟨hs, e' ▸ this⟩
  have hpt : ∀ t, ix.isTwin t → ix.prev t ≠ slot := fun t ht e' => by
    have := h.prev_next t ht; rw [e', hn] at this; exact slot_lt_none h t ht.1 this.symm
  have hlive : 0 < ix.live := node_live_pos h slot hs
  have hexists : 0 < (removeUnlink ix slot).live → ∃ x, (removeUnlink ix slot).isNode x := by
    intro hl
    rw [hLv, h.live_eq] at hl
    by_cases hnc0 : 0 < (removeUnlink ix slot).nodeCount
    · obtain ⟨x, hx, hfx⟩ := countB_exists _ _ hnc0
      exact ⟨x, hx, by simpa using hfx⟩
    · have htc0 : 0 < (removeUnlink ix slot).twinCount := by omega
      obtain ⟨t, ht, hft⟩ := countB_exists _ _ htc0
      have ht2 : (removeUnlink ix slot).level t = lvlTwin := by simpa using hft
      have hts : t ≠ slot := fun e' => by rw [e', hL, ite_eq_left rfl] at ht2; simp [lvlFree, lvlTwin] at ht2
      have ht' : ix.isTwin t := ⟨by rw [← hS]; exact ht, by rw [hL, ite_eq_right hts] at ht2; exact ht2⟩
      obtain ⟨k, hk1, hk2, _⟩ := twin_head_reached h t ht'
      have hzs : iter ix.prev k t ≠ slot := fun e' => by
        cases k with
        | zero => exact hts e'
        | succ k =>
          rw [iter_succ'] at e'
          have := h.prev_next _ (hk2 k (by omega))
          rw [e', hn] at this
          exact slot_lt_none h _ (hk2 k (by omega)).1 this.symm
      exact ⟨iter ix.prev k t, by rw [hS]; exact hk1.1, by rw [hL, ite_eq_right hzs]; exact hk1.2⟩
  refine ⟨fun e ml he1 he2 => ?_, fun l => ?_, hexists⟩
  · refine ⟨by show (removeUnlink ix slot).slots ≤ _; rw [hS]; exact h.slots_le, fun x hx => ?_, fun x hx => ?_, fun t ht => ?_,
      fun x hx => ?_, ?_, fun x => ?_, ?_, ?_, ?_, he1, he2⟩
    · show (removeUnlink ix slot).level x ≤ _ ∨ _
      rw [hL]; split
      · right; right; right; rfl
      · exact h.bytes x (by rw [← hS]; exact hx)
    · simp only [Ix.isLive, Ix.isTwin] at hx ⊢
      show ((removeUnlink ix slot).slots > x ∧ _) ∧ _
      have hx' : (removeUnlink ix slot).next x ≠ noneId := hx
      rw [hN] at hx'
      have hxs : x ≠ slot := fun e' => by simp [e'] at hx'
      rw [ite_eq_right hxs] at hx'
      obtain ⟨⟨a1, a2⟩, ⟨b1, b2⟩⟩ := h.next_live x hx'
      refine ⟨⟨by rw [hS]; exact a1, by rw [hL, ite_eq_right hxs]; exact a2⟩, ?_⟩
      show (removeUnlink ix slot).next x < (removeUnlink ix slot).slots ∧
        (removeUnlink ix slot).level ((removeUnlink ix slot).next x) = lvlTwin
      rw [hN, ite_eq_right hxs, hS, hL, ite_eq_right (hnt x hx')]
      exact ⟨b1, b2⟩
    · have ht1 : t < ix.slots := by have := ht.1; rw [hS] at this; exact this
      have ht2 : (removeUnlink ix slot).level t = lvlTwin := ht.2
      have hts : t ≠ slot := fun e' => by rw [e', hL, ite_eq_left rfl] at ht2; simp [lvlFree, lvlTwin] at ht2
      rw [hL, ite_eq_right hts] at ht2
      show (removeUnlink ix slot).next ((removeUnlink ix slot).prev t) = t
      rw [hP, hN, ite_eq_right (hpt t ⟨ht1, ht2⟩)]
      exact h.prev_next t ⟨ht1, ht2⟩
    · have hx' : (removeUnlink ix slot).next x ≠ noneId := hx
      rw [hN] at hx'
      have hxs : x ≠ slot := fun e' => by simp [e'] at hx'
      rw [ite_eq_right hxs] at hx'
      show (removeUnlink ix slot).prev ((removeUnlink ix slot).next x) = x
      rw [hP, hN, ite_eq_right hxs]
      exact h.next_prev x hx'
    · obtain ⟨r, hr⟩ := h.rank
      refine ⟨r, fun t ht => ?_⟩
      have ht1 : t < ix.slots := by have := ht.1; rw [hS] at this; exact this
      have ht2 : (removeUnlink ix slot).level t = lvlTwin := ht.2
      have hts : t ≠ slot := fun e' => by rw [e', hL, ite_eq_left rfl] at ht2; simp [lvlFree, lvlTwin] at ht2
      rw [hL, ite_eq_right hts] at ht2
      have hps := hpt t ⟨ht1, ht2⟩
      show ((removeUnlink ix slot).prev t < (removeUnlink ix slot).slots ∧ _) ∨ _
      simp only [Ix.isTwin, hP, hS, hL, hps, ite_false]
      exact hr t ⟨ht1, ht2⟩
    · show x ∈ (removeUnlink ix slot).free ↔ x < (removeUnlink ix slot).slots ∧ (removeUnlink ix slot).level x = lvlFree
      rw [hF, hS, hL]
      by_cases hxs : x = slot
      · rw [hxs, ite_eq_left rfl]; simp [hsl]
      · rw [ite_eq_right hxs, List.mem_cons]
        constructor
        · rintro (e' | e')
          · exact absurd e' hxs
          · exact (h.free_iff x).mp e'
        · intro hx; exact Or.inr ((h.free_iff x).mpr hx)
    · show (removeUnlink ix slot).free.Nodup
      rw [hF]
      refine List.nodup_cons.mpr ⟨fun hm => ?_, h.free_nodup⟩
      have := ((h.free_iff slot).mp hm).2; unfold lvlFree at this; omega
    · show (removeUnlink ix slot).twins = (removeUnlink ix slot).twinCount
      rw [hT, h.twins_eq]; omega
    · show (removeUnlink ix slot).live = (removeUnlink ix slot).nodeCount + (removeUnlink ix slot).twinCount
      rw [hLv, h.live_eq]; omega
  · have hspec := removeLinks_spec (layerCap m l) (ix.layer l) slot (hw l)
    obtain ⟨a1, a2⟩ := foldLayers_adj (fun l _ g => unlinkLayer slot (ix.adj l slot) g)
      (List.range (ix.level slot + 1)) ix List.nodup_range
    apply wf_congr _ _ _ hspec.1
    · intro x
      show (removeUnlink ix slot).present l x = _
      by_cases hxs : x = slot
      · rw [hxs, hspec.2.1]
        exact absent_of _ slot (Or.inr (by rw [hL, ite_eq_left rfl]; unfold lvlFree levelCap; omega)) l
      · rw [hspec.2.2.1 x hxs]
        exact present_congr ix _ x (by rw [hS]) (by rw [hL, ite_eq_right hxs]) l
    · intro x
      show (removeUnlink ix slot).adj l x = (removeLinks (ix.layer l) slot).adj x
      rw [hA]
      unfold removeLinks
      simp only []
      by_cases hxs : x = slot
      · rw [ite_eq_left hxs, ite_eq_left hxs]
      · rw [ite_eq_right hxs, ite_eq_right hxs]
        by_cases hl : l ∈ List.range (ix.level slot + 1)
        · obtain ⟨ctx, hc⟩ := a2 l hl
          rw [hc]; rfl
        · rw [a1 l hl]
          have hlh2 : ix.level slot < l := by simp at hl; omega
          have hpa : (ix.layer l).present slot = false := by
            show ix.present l slot = false
            unfold Ix.present; simp; omega
          have hnil : (ix.layer l).adj slot = [] := adj_nil_of_absent (hw l) slot hpa
          rw [hnil]; rfl


theorem pickEntry_spec (ix : Ix) (hx : ∃ x, ix.isNode x) :
    ∃ e ml, pickEntry ix = { ix with entry := e, maxLevel := ml } ∧ ix.isNode e ∧ ix.level e = ml ∧
      ∀ x, ix.isNode x → ix.level x ≤ ml := by
  obtain ⟨p1, p2⟩ := pickFold_spec ix.level ix.slots
  unfold pickEntry
  cases hp : pickFold ix.level ix.slots with
  | none =>
    obtain ⟨x, hx1, hx2⟩ := hx
    exact absurd hx2 (p1.mp hp x hx1)
  | some q =>
    obtain ⟨b, bl⟩ := q
    obtain ⟨q1, q2, q3, q4⟩ := p2 b bl hp
    exact ⟨b, bl, rfl, ⟨q1, q2⟩, q3.symm, fun x hx => q4 x hx.1 hx.2⟩

theorem remove_plain_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (slot : Nat) (hs : ix.isNode slot)
    (hn : ix.next slot = noneId) (repairL : Nat → Ix → Graph → Graph)
    (hrep : ∀ l ctx g, Wf (layerCap m l) g → (∀ c ∈ ix.adj l slot, g.present c = true) →
      Wf (layerCap m l) (repairL l ctx g) ∧ (repairL l ctx g).present = g.present) :
    TwinInv (removePlain ix slot repairL) ∧ GraphWf m (removePlain ix slot repairL) := by
  obtain ⟨tU, wU, eU⟩ := remove_unlink_inv m ix h hw slot hs hn
  obtain ⟨hS, hL, hN, hP, hA, hF, hT, hLv, hE, hM⟩ := removeUnlink_fields ix slot
  have hsl : slot < ix.slots := hs.1
  unfold removePlain
  by_cases hl0 : (removeUnlink ix slot).live = 0
  · rw [ite_eq_left hl0]
    exact ⟨tU noneId 0 (fun hp => by omega) (fun _ => rfl), graphWf_frame m _ _ wU (fun _ _ => rfl) (fun _ _ => rfl)⟩
  · rw [ite_eq_right hl0]
    have hpos : 0 < (removeUnlink ix slot).live := by omega
    have hctx : ∃ e ml, (if ix.entry = slot then pickEntry (removeUnlink ix slot) else removeUnlink ix slot) =
        { removeUnlink ix slot with entry := e, maxLevel := ml } ∧
        TwinInv { removeUnlink ix slot with entry := e, maxLevel := ml } := by
      by_cases hent : ix.entry = slot
      · rw [ite_eq_left hent]
        obtain ⟨e, ml, he, h1, h2, h3⟩ := pickEntry_spec _ (eU hpos)
        exact ⟨e, ml, he, tU e ml (fun _ => ⟨h1, h2, h3⟩) (fun hz => absurd hz hl0)⟩
      · rw [ite_eq_right hent]
        have hlive : 0 < ix.live := node_live_pos h slot hs
        obtain ⟨e1, e2, e3⟩ := h.entry_live hlive
        refine ⟨ix.entry, ix.maxLevel, by rw [← hE, ← hM], tU ix.entry ix.maxLevel (fun _ => ⟨⟨by rw [hS]; exact e1.1,
          by rw [hL, ite_eq_right hent]; exact e1.2⟩, by rw [hL, ite_eq_right hent]; exact e2, fun x hx => ?_⟩)
          (fun hz => absurd hz hl0)⟩
        have hxs : x ≠ slot := fun e' => by
          have := hx.2; rw [e', hL, ite_eq_left rfl] at this; unfold lvlFree levelCap at this; omega
        rw [hL, ite_eq_right hxs]
        exact e3 x ⟨by rw [← hS]; exact hx.1, by have := hx.2; rw [hL, ite_eq_right hxs] at this; exact this⟩
    obtain ⟨e, ml, hce, htc⟩ := hctx
    rw [hce]
    obtain ⟨f1, f2, f3, f4, f5, f6, f7, f8, f9⟩ := foldLayers_frame repairL (List.range (ix.level slot + 1))
      { removeUnlink ix slot with entry := e, maxLevel := ml }
    refine ⟨twinInv_congr _ _ htc f1 f2 f3 f4 f5 f6 f7 f8 f9, ?_⟩
    have wU' : GraphWf m { removeUnlink ix slot with entry := e, maxLevel := ml } :=
      graphWf_frame m _ _ wU (fun _ _ => rfl) (fun _ _ => rfl)
    refine foldLayers_wf m repairL { removeUnlink ix slot with entry := e, maxLevel := ml } _ List.nodup_range
      (fun l _ => wU' l) (fun l _ ctx => ?_)
    refine hrep l ctx _ (wU' l) (fun c hc => ?_)
    have hcs : c ≠ slot := fun e' => (hw l).irrefl slot (e' ▸ hc)
    show (removeUnlink ix slot).present l c = true
    rw [present_congr ix _ c (by rw [hS]) (by rw [hL, ite_eq_right hcs]) l]
    exact (hw l).closed slot c hc

theorem remove_inv (m : Nat) (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (slot : Nat) (hs : ix.isLive slot)
    (repairL : Nat → Ix → Graph → Graph)
    (hrep : ∀ l ctx g, Wf (layerCap m l) g → (∀ c ∈ ix.adj l slot, g.present c = true) →
      Wf (layerCap m l) (repairL l ctx g) ∧ (repairL l ctx g).present = g.present) :
    TwinInv (removeOp ix slot repairL) ∧ GraphWf m (removeOp ix slot repairL) := by
  have hk := (twin_kinds h slot hs.1).1.mp hs
  unfold removeOp
  by_cases ht : ix.level slot = lvlTwin
  · rw [ite_eq_left ht]; exact remove_twin_inv m ix h hw slot ⟨hs.1, ht⟩
  · rw [ite_eq_right ht]
    have hnode : ix.isNode slot := hk.resolve_right (fun e => ht e.2)
    by_cases hn : ix.next slot ≠ noneId
    · rw [ite_eq_left hn]; exact promote_inv m ix h hw slot hnode hn
    · rw [ite_eq_right hn]
      exact remove_plain_inv m ix h hw slot hnode (by simpa using hn) repairL hrep


def repairLayer {D : Type} (cap : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (keepPruned : Bool) (relink : Ix → Graph → Nat → Graph)
    (grp : List Nat) : Ix → Graph → Graph :=
  fun ctx g => grp.foldl (fun g' n => repair cap dist lt sort keepPruned (relink ctx) g' n grp) g

theorem repairLayer_wf {D : Type} (cap : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (hsort : ∀ l, (sort l).Perm l) (keepPruned : Bool)
    (relink : Ix → Graph → Nat → Graph) (hrelink : ∀ ctx, RelinkOk cap (relink ctx)) (grp : List Nat)
    (hgrp : grp.Nodup) (ctx : Ix) (g : Graph) (hw : Wf cap g) (hp : ∀ c ∈ grp, g.present c = true) :
    Wf cap (repairLayer cap dist lt sort keepPruned relink grp ctx g) ∧
      (repairLayer cap dist lt sort keepPruned relink grp ctx g).present = g.present := by
  unfold repairLayer
  have key : ∀ (L : List Nat) (g' : Graph), (∀ x ∈ L, x ∈ grp) → Wf cap g' → g'.present = g.present →
      Wf cap (L.foldl (fun g'' n => repair cap dist lt sort keepPruned (relink ctx) g'' n grp) g') ∧
        (L.foldl (fun g'' n => repair cap dist lt sort keepPruned (relink ctx) g'' n grp) g').present = g.present := by
    intro L
    induction L with
    | nil => intro g' _ hw' hp'; exact ⟨hw', hp'⟩
    | cons n L ih =>
      intro g' hL hw' hp'
      simp only [List.foldl_cons]
      have hn : g'.present n = true := by rw [hp']; exact hp n (hL n List.mem_cons_self)
      obtain ⟨a1, a2⟩ := repair_wf cap dist lt sort hsort keepPruned (relink ctx) (hrelink ctx) g' n grp hw' hn
        (fun c hc => by rw [hp']; exact hp c hc) hgrp
      exact ih _ (fun x hx => hL x (List.mem_cons_of_mem _ hx)) a1 (by rw [a2, hp'])
  exact key grp g (fun x hx => hx) hw rfl

theorem remove_keeps {D : Type} (m : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (hsort : ∀ l, (sort l).Perm l) (keepPruned : Bool)
    (relink : Nat → Ix → Graph → Nat → Graph) (hrelink : ∀ l ctx, RelinkOk (layerCap m l) (relink l ctx))
    (ix : Ix) (h : TwinInv ix) (hw : GraphWf m ix) (slot : Nat) (hs : ix.isLive slot) :
    TwinInv (removeOp ix slot (fun l => repairLayer (layerCap m l) dist lt sort keepPruned (relink l) (ix.adj l slot))) ∧
      GraphWf m (removeOp ix slot (fun l => repairLayer (layerCap m l) dist lt sort keepPruned (relink l) (ix.adj l slot))) :=
  remove_inv m ix h hw slot hs _ (fun l ctx g hg hp =>
    repairLayer_wf (layerCap m l) dist lt sort hsort keepPruned (relink l) (hrelink l) (ix.adj l slot)
      ((hw l).nodup slot) ctx g hg hp)

theorem insert_keeps {D : Type} [Inhabited D] (m : Nat) (dist : Nat → Nat → D) (lt : D → D → Bool)
    (sort : List (D × Nat) → List (D × Nat)) (hsort : ∀ l, (sort l).Perm l) (ix : Ix) (h : TwinInv ix)
    (hw : GraphWf m ix) (slot lv : Nat) (hs : ix.isReserved slot) (hlv : lv ≤ levelCap) (head : Option Nat)
    (hhead : ∀ x, head = some x → ix.isNode x) (sel : Nat → List Nat) (dq : Nat → Nat → D)
    (guard : Nat → Graph → Nat → Nat → Bool) (pick : Nat → Graph → Nat → List Nat → Option Nat)
    (hpick : ∀ l, PickOk (pick l))
    (hsel : ∀ l, l ≤ min ix.maxLevel lv → (sel l).Nodup ∧ slot ∉ sel l ∧ ∀ x ∈ sel l, ix.present l x = true) :
    TwinInv (insertOp m ix slot lv head sel (fun l g' e => shrinkVictim dist lt sort g' e slot (dq l e)) guard pick) ∧
      GraphWf m (insertOp m ix slot lv head sel (fun l g' e => shrinkVictim dist lt sort g' e slot (dq l e)) guard pick) :=
  insert_inv m ix h hw slot lv hs hlv head hhead sel _ guard pick hpick
    (fun l g' e => shrinkVictim_mem dist lt sort hsort g' e slot (dq l e)) hsel


def coincidentMax : Nat := 2

def coincidentCount (m : Nat) (twinsOn : Bool) : Nat := if twinsOn then min (max (m / 2) 1) coincidentMax else 0

def coincidentScan (t : Nat) (tie : Int) (dself : Nat → Int) : List Cand → Option Nat → Nat → Option Nat
  | [], _, _ => none
  | c :: rest, head, found =>
    if c.dist ≠ tie then none
    else if tie ≤ dself c.id then
      if found + 1 = t then some ((head.getD c.id))
      else coincidentScan t tie dself rest (some (head.getD c.id)) (found + 1)
    else coincidentScan t tie dself rest head found

def coincidentHead (t : Nat) (dqq : Int) (dself : Nat → Int) (work : List Cand) : Option Nat :=
  if t = 0 ∨ work.length < t then none
  else if (work.getD (t - 1) default).dist ≠ (work.headD default).dist ∨ ¬ ((work.headD default).dist ≤ dqq) then none
  else coincidentScan t (work.headD default).dist dself work none 0

theorem coincidentScan_mem (t : Nat) (tie : Int) (dself : Nat → Int) : ∀ (work : List Cand) (head : Option Nat)
    (found : Nat) (h : Nat), (∀ x, head = some x → x ∈ work.map Cand.id ∨ True) →
    coincidentScan t tie dself work head found = some h → (head = some h ∨ h ∈ work.map Cand.id) := by
  intro work
  induction work with
  | nil => intro head found h _ hs; simp [coincidentScan] at hs
  | cons c rest ih =>
    intro head found h _ hs
    unfold coincidentScan at hs
    split at hs
    · simp at hs
    · split at hs
      · split at hs
        · simp only [Option.some.injEq] at hs
          cases head with
          | none => right; simp at hs; simp [hs]
          | some x => left; simp at hs; rw [hs]
        · rcases ih _ _ h (fun _ _ => Or.inr trivial) hs with h1 | h1
          · cases head with
            | none => right; simp at h1; simp [h1]
            | some x => left; simp at h1; rw [h1]
          · right; simp at h1 ⊢; exact Or.inr h1
      · rcases ih head found h (fun _ _ => Or.inr trivial) hs with h1 | h1
        · left; exact h1
        · right; simp at h1 ⊢; exact Or.inr h1

theorem coincident_mem (t : Nat) (dqq : Int) (dself : Nat → Int) (work : List Cand) (h : Nat)
    (hc : coincidentHead t dqq dself work = some h) : h ∈ work.map Cand.id := by
  unfold coincidentHead at hc
  split at hc
  · simp at hc
  · split at hc
    · simp at hc
    · rcases coincidentScan_mem t _ dself work none 0 h (fun _ _ => Or.inr trivial) hc with h1 | h1
      · simp at h1
      · exact h1

theorem coincident_tie (t : Nat) (dqq : Int) (dself : Nat → Int) (work : List Cand) (h : Nat)
    (hc : coincidentHead t dqq dself work = some h) :
    0 < t ∧ t ≤ work.length ∧ (work.getD (t - 1) default).dist = (work.headD default).dist ∧
      (work.headD default).dist ≤ dqq := by
  unfold coincidentHead at hc
  split at hc
  · simp at hc
  · next h1 =>
    split at hc
    · simp at hc
    · next h2 =>
      refine ⟨by omega, by omega, ?_, ?_⟩
      · by_cases e : (work.getD (t - 1) default).dist = (work.headD default).dist
        · exact e
        · exact absurd (Or.inl e) h2
      · by_cases e : (work.headD default).dist ≤ dqq
        · exact e
        · exact absurd (Or.inr e) h2


theorem empty_inv (m : Nat) : TwinInv emptyIx ∧ GraphWf m emptyIx := by
  refine ⟨⟨by decide, fun x hx => by simp [emptyIx] at hx, fun x hx => by simp [emptyIx] at hx,
    fun t ht => by simp [Ix.isTwin, emptyIx] at ht, fun x hx => by simp [emptyIx] at hx,
    ⟨fun _ => 0, fun t ht => by simp [Ix.isTwin, emptyIx] at ht⟩, fun x => by simp [emptyIx],
    List.nodup_nil, rfl, rfl, fun hl => by simp [emptyIx] at hl, fun _ => rfl⟩, fun l => ?_⟩
  refine ⟨fun a b hb => by simp [Ix.layer, emptyIx] at hb, fun a => by simp [Ix.layer, emptyIx],
    fun a => by simp [Ix.layer, emptyIx], fun a => by simp [Ix.layer, emptyIx],
    fun a b hb => by simp [Ix.layer, emptyIx] at hb⟩

end Vectors
