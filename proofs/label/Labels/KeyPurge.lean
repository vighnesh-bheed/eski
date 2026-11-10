import Labels.KeyWrites

namespace Labels

section Unwind
variable {L C S Rp : Type}

def outsK (sees : L → L → Bool) (lab : C → L) (step : C → S → S) (reply : C → S → Rp) (R : L) :
    List C → S → List Rp
  | [], _ => []
  | c :: cs, s =>
    if sees R (lab c) then reply c s :: outsK sees lab step reply R cs (step c s)
    else outsK sees lab step reply R cs (step c s)

def purgeK (sees : L → L → Bool) (lab : C → L) (R : L) (cs : List C) : List C :=
  cs.filter (fun c => sees R (lab c))

theorem unwindingK (sees : L → L → Bool) (lab : C → L) (step : C → S → S) (reply : C → S → Rp) (R : L)
    (allowed : C → Prop) (obs : S → S)
    (hlocal : ∀ c s, allowed c → sees R (lab c) = false → obs (step c s) = obs s)
    (hcons : ∀ c s t, allowed c → obs s = obs t → sees R (lab c) = true → obs (step c s) = obs (step c t))
    (hreply : ∀ c s t, allowed c → obs s = obs t → sees R (lab c) = true → reply c s = reply c t) :
    ∀ (cs : List C), (∀ c ∈ cs, allowed c) → ∀ (s t : S), obs s = obs t →
      outsK sees lab step reply R cs s = outsK sees lab step reply R (purgeK sees lab R cs) t := by
  intro cs
  induction cs with
  | nil => intro _ s t _; rfl
  | cons c cs ih =>
    intro ha s t he
    have hc := ha c List.mem_cons_self
    have hrest : ∀ x ∈ cs, allowed x := fun x hx => ha x (List.mem_cons_of_mem _ hx)
    cases hv : sees R (lab c)
    · have hp : purgeK sees lab R (c :: cs) = purgeK sees lab R cs := by simp [purgeK, hv]
      rw [hp]
      simp only [outsK, hv, Bool.false_eq_true, ↓reduceIte]
      exact ih hrest (step c s) t (by rw [hlocal c s hc hv]; exact he)
    · have hp : purgeK sees lab R (c :: cs) = c :: purgeK sees lab R cs := by simp [purgeK, hv]
      rw [hp]
      simp only [outsK, hv, ↓reduceIte]
      rw [hreply c s t hc he hv]
      congr 1
      exact ih hrest (step c s) (step c t) (hcons c s t hc he hv)

end Unwind

section KeyPurge
set_option linter.unusedSectionVars false
variable {N V : Type} [DecidableEq N]

inductive KOp (N V : Type) where
  | write (op : WOp N V)
  | read (q : KQ N)

structure KCmd (N V : Type) where
  label : TLabel
  op : KOp N V

inductive KOut (N V : Type) where
  | wrote (r : WRep)
  | read (x : KReply N V)

def cstep (c : KCmd N V) (s : KState N V) : KState N V :=
  match c.op with
  | .write op => (kstep c.label op s).2
  | .read _ => s

def creply (ord : List TLabel → List TLabel) (c : KCmd N V) (s : KState N V) : KOut N V :=
  match c.op with
  | .write op => .wrote (kstep c.label op s).1
  | .read q => .read (kreply ord q s c.label)

def Undeclassified (c : KCmd N V) : Prop :=
  match c.op with
  | .write op => NotDecl op
  | .read _ => True

theorem restrict_restrict_of {R W : TLabel} (hw : domT R W = true) (s : KState N V) :
    restrict W (restrict R s) = restrict W s := by
  unfold restrict
  simp only [KState.mk.injEq]
  constructor
  · apply filter_filter_of
    intro c hc
    exact domT_trans hw hc
  · apply filter_filter_of
    intro l hl
    exact domT_trans hw hl

theorem restrict_setOwn_hidden {R W : TLabel} (hw : domT R W = false) (s : KState N V) (n : N) (v : V) :
    restrict R (setOwn s W n v) = restrict R s := by
  unfold restrict setOwn
  split
  · simp only [KState.mk.injEq, and_true]
    apply filter_map_keep
    · intro c hc
      have : c.label ≠ W := fun e => by rw [e, hw] at hc; simp at hc
      have : isAt n W c = false := by simp [isAt, this]
      simp [this]
    · intro c
      by_cases h : isAt n W c = true <;> simp [h]
  · simp only [KState.mk.injEq, List.filter_append]
    constructor
    · simp [hw]
    · split <;> simp [List.filter_append, hw]

theorem restrict_delOwn_hidden {R W : TLabel} (hw : domT R W = false) (s : KState N V) (n : N) :
    restrict R (delOwn s W n) = restrict R s := by
  unfold restrict delOwn
  simp only [KState.mk.injEq, and_true]
  rw [List.filter_filter]
  congr 1
  funext c
  by_cases h : domT R c.label = true
  · have : c.label ≠ W := fun e => by rw [e, hw] at h; simp at h
    simp [h, isAt, this]
  · simp only [Bool.not_eq_true] at h
    simp [h]

theorem restrict_delMany_hidden {R W : TLabel} (hw : domT R W = false) :
    ∀ (ns : List N) (s : KState N V), restrict R (delMany s W ns).2 = restrict R s
  | [], _ => rfl
  | n :: ns, s => by
    unfold delMany
    split
    · simp only
      rw [restrict_delMany_hidden hw ns, restrict_delOwn_hidden hw]
    · exact restrict_delMany_hidden hw ns s

theorem restrict_setMany_hidden {R W : TLabel} (hw : domT R W = false) :
    ∀ (kvs : List (N × V)) (s : KState N V), restrict R (setMany s W kvs) = restrict R s
  | [], _ => rfl
  | p :: ps, s => by
    simp only [setMany]
    rw [restrict_setMany_hidden hw ps, restrict_setOwn_hidden hw]

theorem kstep_hidden {R W : TLabel} (hw : domT R W = false) {op : WOp N V} (hd : NotDecl op) (s : KState N V) :
    restrict R (kstep W op s).2 = restrict R s := by
  unfold kstep
  split
  · rfl
  · cases op with
    | put n v => exact restrict_setOwn_hidden hw s n v
    | del ns => exact restrict_delMany_hidden hw ns s
    | createOnly n v =>
      simp only [applyW]
      split
      · rfl
      · exact restrict_setOwn_hidden hw s n v
    | createMany kvs =>
      simp only [applyW]
      split
      · rfl
      · exact restrict_setMany_hidden hw kvs s
    | renameNx a b =>
      simp only [applyW]
      split
      · rfl
      · split
        · rfl
        · simp only
          rw [restrict_setOwn_hidden hw, restrict_delOwn_hidden hw]
    | copyNx a b =>
      simp only [applyW]
      split
      · rfl
      · split
        · rfl
        · exact restrict_setOwn_hidden hw s b _
    | declassify n t => exact hd.elim

theorem restrict_setOwn_visible {R W : TLabel} (hw : domT R W = true) (s : KState N V) (n : N) (v : V) :
    restrict R (setOwn s W n v) = setOwn (restrict R s) W n v := by
  unfold setOwn
  rw [ownOf_restrict_of hw]
  split
  · unfold restrict
    simp only [KState.mk.injEq, and_true]
    rw [List.filter_map]
    congr 1
    · congr 1
      funext c
      simp only [Function.comp]
      by_cases h : isAt n W c = true <;> simp [h]
  · unfold restrict
    simp only [KState.mk.injEq, List.filter_append]
    constructor
    · simp [hw]
    · have hmem : (W ∈ s.parts.filter (fun l => domT R l)) ↔ W ∈ s.parts := by
        simp [List.mem_filter, hw]
      by_cases h : W ∈ s.parts
      · have h' : W ∈ s.parts.filter (fun l => domT R l) := hmem.2 h
        simp [h, h']
      · have h' : W ∉ s.parts.filter (fun l => domT R l) := fun e => h (hmem.1 e)
        simp [h, h', List.filter_append, hw]

theorem restrict_delOwn_visible (R W : TLabel) (s : KState N V) (n : N) :
    restrict R (delOwn s W n) = delOwn (restrict R s) W n := by
  unfold restrict delOwn
  simp only [KState.mk.injEq, and_true]
  rw [List.filter_filter, List.filter_filter]
  congr 1
  funext c
  exact Bool.and_comm _ _

theorem delMany_restrict_visible {R W : TLabel} (hw : domT R W = true) :
    ∀ (ns : List N) (s : KState N V),
      ((delMany (restrict R s) W ns).1, (delMany (restrict R s) W ns).2) =
        ((delMany s W ns).1, restrict R (delMany s W ns).2)
  | [], _ => rfl
  | n :: ns, s => by
    unfold delMany
    rw [ownOf_restrict_of hw]
    split
    · simp only [Prod.mk.injEq]
      have ih := delMany_restrict_visible hw ns (delOwn s W n)
      rw [restrict_delOwn_visible] at ih
      simp only [Prod.mk.injEq] at ih
      exact ⟨by rw [ih.1], ih.2⟩
    · exact delMany_restrict_visible hw ns s

theorem restrict_setMany_visible {R W : TLabel} (hw : domT R W = true) :
    ∀ (kvs : List (N × V)) (s : KState N V), restrict R (setMany s W kvs) = setMany (restrict R s) W kvs
  | [], _ => rfl
  | p :: ps, s => by
    simp only [setMany]
    rw [restrict_setMany_visible hw ps, restrict_setOwn_visible hw]

theorem conflict_restrict_of {R W : TLabel} (hw : domT R W = true) (s : KState N V) :
    ∀ chk : List (N × Bool), conflict (restrict R s) W chk = conflict s W chk
  | [] => rfl
  | (n, co) :: rest => by
    unfold conflict
    rw [ownOf_restrict_of hw, other_restrict_of hw, conflict_restrict_of hw s rest]

theorem kstep_visible {R W : TLabel} (hw : domT R W = true) {op : WOp N V} (hd : NotDecl op) (s : KState N V) :
    kstep W op (restrict R s) = ((kstep W op s).1, restrict R (kstep W op s).2) := by
  unfold kstep
  rw [conflict_restrict_of hw]
  split
  · rfl
  · cases op with
    | put n v => simp only [applyW, restrict_setOwn_visible hw]
    | del ns =>
      simp only [applyW]
      have := delMany_restrict_visible hw ns s
      simp only [Prod.mk.injEq] at this
      rw [this.1, this.2]
    | createOnly n v =>
      simp only [applyW]
      rw [resolve_restrict_of hw]
      split
      · rfl
      · simp only [restrict_setOwn_visible hw]
    | createMany kvs =>
      simp only [applyW, resolve_restrict_of hw]
      split
      · rfl
      · simp only [restrict_setMany_visible hw]
    | renameNx a b =>
      simp only [applyW, ownOf_restrict_of hw, resolve_restrict_of hw]
      split
      · rfl
      · split
        · rfl
        · simp only [restrict_setOwn_visible hw, restrict_delOwn_visible]
    | copyNx a b =>
      simp only [applyW, resolve_restrict_of hw]
      split
      · rfl
      · split
        · rfl
        · simp only [restrict_setOwn_visible hw]
    | declassify n t => exact hd.elim

theorem cstep_local {R : TLabel} {c : KCmd N V} (hd : Undeclassified c) (hv : domT R c.label = false)
    (s : KState N V) : restrict R (cstep c s) = restrict R s := by
  unfold cstep
  unfold Undeclassified at hd
  split
  · rename_i op hop
    rw [hop] at hd
    exact kstep_hidden hv hd s
  · rfl

theorem cstep_consistent {R : TLabel} {c : KCmd N V} (hd : Undeclassified c) (hv : domT R c.label = true)
    {s t : KState N V} (he : restrict R s = restrict R t) : restrict R (cstep c s) = restrict R (cstep c t) := by
  unfold cstep
  unfold Undeclassified at hd
  split
  · rename_i op hop
    rw [hop] at hd
    have hs := kstep_visible hv hd s
    have ht := kstep_visible hv hd t
    rw [he] at hs
    rw [hs] at ht
    simp only [Prod.mk.injEq] at ht
    exact ht.2
  · exact he

theorem creply_consistent (ord : List TLabel → List TLabel) {R : TLabel} {c : KCmd N V} (hd : Undeclassified c)
    (hv : domT R c.label = true) {s t : KState N V} (he : restrict R s = restrict R t) :
    creply ord c s = creply ord c t := by
  unfold creply
  unfold Undeclassified at hd
  split
  · rename_i op hop
    rw [hop] at hd
    have hs := kstep_visible hv hd s
    have ht := kstep_visible hv hd t
    rw [he] at hs
    rw [hs] at ht
    simp only [Prod.mk.injEq] at ht
    rw [ht.1]
  · have hs := kreply_restrict ord ‹KQ N› c.label (restrict R s)
    have ht := kreply_restrict ord ‹KQ N› c.label (restrict R t)
    rw [restrict_restrict_of hv] at hs ht
    rw [← kreply_restrict ord _ c.label s, ← kreply_restrict ord _ c.label t]
    rw [← restrict_restrict_of hv s, ← restrict_restrict_of hv t, he]

def kouts (ord : List TLabel → List TLabel) (R : TLabel) (cs : List (KCmd N V)) (s : KState N V) : List (KOut N V) :=
  outsK (fun r l => domT r l) KCmd.label cstep (creply ord) R cs s

def kpurge (R : TLabel) (cs : List (KCmd N V)) : List (KCmd N V) := purgeK (fun r l => domT r l) KCmd.label R cs

theorem key_history (ord : List TLabel → List TLabel) (R : TLabel) (cs : List (KCmd N V))
    (hd : ∀ c ∈ cs, Undeclassified c) (s t : KState N V) (he : restrict R s = restrict R t) :
    kouts ord R cs s = kouts ord R (kpurge R cs) t :=
  unwindingK (fun r l => domT r l) KCmd.label cstep (creply ord) R Undeclassified (restrict R)
    (fun _ s hc hv => cstep_local hc hv s)
    (fun _ _ _ hc he hv => cstep_consistent hc hv he)
    (fun _ _ _ hc he hv => creply_consistent ord hc hv he) cs hd s t he

theorem key_history_purge (ord : List TLabel → List TLabel) (R : TLabel) (cs : List (KCmd N V))
    (hd : ∀ c ∈ cs, Undeclassified c) (s : KState N V) :
    kouts ord R cs s = kouts ord R (kpurge R cs) s :=
  key_history ord R cs hd s s rfl

theorem hidden_insertion (ord : List TLabel → List TLabel) (R : TLabel) (cs merge : List (KCmd N V))
    (hd : ∀ c ∈ cs, Undeclassified c) (hm : kpurge R merge = kpurge R cs) (hmd : ∀ c ∈ merge, Undeclassified c)
    (s : KState N V) : kouts ord R merge s = kouts ord R cs s := by
  rw [key_history ord R merge hmd s s rfl, key_history ord R cs hd s s rfl, hm]

end KeyPurge

end Labels
