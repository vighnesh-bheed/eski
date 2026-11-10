import Vectors.Partition
import Vectors.Plain

namespace Vectors

section Unwind
variable {L C S Rp : Type}

def outsC (sees : L → L → Bool) (lab : C → L) (step : C → S → S) (reply : C → S → Rp) (R : L) :
    List C → S → List Rp
  | [], _ => []
  | c :: cs, s =>
    if sees R (lab c) then reply c s :: outsC sees lab step reply R cs (step c s)
    else outsC sees lab step reply R cs (step c s)

def purgeC (sees : L → L → Bool) (lab : C → L) (R : L) (cs : List C) : List C :=
  cs.filter (fun c => sees R (lab c))

theorem unwinding (sees : L → L → Bool) (lab : C → L) (step : C → S → S) (reply : C → S → Rp) (R : L)
    (obs : S → S) (inv : S → Prop)
    (hinv : ∀ c s, inv s → inv (step c s))
    (hlocal : ∀ c s, inv s → sees R (lab c) = false → obs (step c s) = obs s)
    (hcons : ∀ c s t, inv s → inv t → obs s = obs t → sees R (lab c) = true → obs (step c s) = obs (step c t))
    (hreply : ∀ c s t, inv s → inv t → obs s = obs t → sees R (lab c) = true → reply c s = reply c t) :
    ∀ (cs : List C) (s t : S), inv s → inv t → obs s = obs t →
      outsC sees lab step reply R cs s = outsC sees lab step reply R (purgeC sees lab R cs) t := by
  intro cs
  induction cs with
  | nil => intro s t _ _ _; rfl
  | cons c cs ih =>
    intro s t hs ht he
    cases hv : sees R (lab c)
    · have hp : purgeC sees lab R (c :: cs) = purgeC sees lab R cs := by
        simp [purgeC, hv]
      rw [hp]
      simp only [outsC, hv, Bool.false_eq_true, ↓reduceIte]
      exact ih (step c s) t (hinv c s hs) ht (by rw [hlocal c s hs hv]; exact he)
    · have hp : purgeC sees lab R (c :: cs) = c :: purgeC sees lab R cs := by
        simp [purgeC, hv]
      rw [hp]
      simp only [outsC, hv, ↓reduceIte]
      rw [hreply c s t hs ht he hv]
      congr 1
      exact ih (step c s) (step c t) (hinv c s hs) (hinv c t ht) (hcons c s t hs ht he hv)

end Unwind

inductive Tgt (L : Type) where
  | other
  | obj (a : L) (j : Nat)
deriving DecidableEq

structure KState (L N P : Type) where
  copies : List (L × Tgt L)
  objs : L → Nat → LState L N P
  dims : L → Nat → Nat
  made : L → Nat
  str : L → Nat

inductive KOp (N V : Type) where
  | write (op : WOp N V)
  | read (q : Nat)

structure KCmd (L N V : Type) where
  label : L
  op : KOp N V

inductive KView (L N P : Type) where
  | none
  | other (l : L)
  | obj (l : L) (dim : Nat) (o : LState L N P)

inductive WRep (L : Type) where
  | wrongType
  | nameInUse (l : L)
  | created
  | dimMismatch (d : Nat)
  | updated
  | added
  | removed
  | attrSet
  | elemInUse (l : Option L)
  | missing

section Keys
set_option linter.unusedSectionVars false
variable {L N V P Rd : Type} [DecidableEq L] [DecidableEq N]

def blank : LState L N P := ⟨fun _ => none, fun _ => [], fun _ => 0⟩

def normS (o : LState L N P) : LState L N P := { o with stream := fun _ => 0 }

def withStream (o : LState L N P) (st : L → Nat) : LState L N P := { o with stream := st }

def found (sees : L → L → Bool) (gt : L → L → Bool) (w : L) (cs : List (L × Tgt L)) : Option (L × Tgt L) :=
  match resolveL (writerOf sees gt w) (cs.map Prod.fst) with
  | none => none
  | some l => cs.find? (fun c => decide (c.1 = l))

def syncC (w : L) (tg : Tgt L) (present : Bool) (cs : List (L × Tgt L)) : List (L × Tgt L) :=
  if present then (if cs.any (fun c => decide (c.1 = w)) then cs else cs ++ [(w, tg)])
  else cs.filter (fun c => !decide (c.1 = w))

def setObj (s : KState L N P) (a : L) (j : Nat) (o : LState L N P) : L → Nat → LState L N P :=
  fun b k => if b = a ∧ k = j then o else s.objs b k

def dimBad (vdim : V → Nat) (op : WOp N V) (d : Nat) : Bool :=
  match op with
  | .add _ v => decide (vdim v ≠ d)
  | _ => false

def kwrite (ops : PartOps N V P) (sees : L → L → Bool) (gt : L → L → Bool) (vdim : V → Nat) (w : L)
    (op : WOp N V) (s : KState L N P) : KState L N P :=
  match found sees gt w s.copies with
  | some (_, .other) => s
  | none =>
    match op with
    | .add n v =>
      let o := wstep ops sees ⟨w, .add n v⟩ (withStream blank s.str)
      { copies := s.copies ++ [(w, .obj w (s.made w))],
        objs := setObj s w (s.made w) (normS o),
        dims := fun b k => if b = w ∧ k = s.made w then vdim v else s.dims b k,
        made := fun b => if b = w then s.made w + 1 else s.made b,
        str := o.stream }
    | _ => s
  | some (_, .obj a j) =>
    if dimBad vdim op (s.dims a j) then s
    else
      let o := wstep ops sees ⟨w, op⟩ (withStream (s.objs a j) s.str)
      { s with copies := syncC w (.obj a j) (o.parts w).isSome s.copies,
               objs := setObj s a j (normS o),
               str := o.stream }

def kview (sees : L → L → Bool) (gt : L → L → Bool) (w : L) (s : KState L N P) : KView L N P × Nat :=
  (match found sees gt w s.copies with
   | none => .none
   | some (l, .other) => .other l
   | some (l, .obj a j) => .obj l (s.dims a j) (restrictTo sees gt w (s.objs a j)), s.str w)

def wreply (sees : L → L → Bool) (gt : L → L → Bool) (vdim : V → Nat) (w : L) (op : WOp N V)
    (s : KState L N P) : WRep L :=
  match found sees gt w s.copies with
  | some (l, .other) => if l = w then .wrongType else .nameInUse l
  | none => match op with
    | .add _ _ => .created
    | _ => .missing
  | some (_, .obj a j) =>
    let o := s.objs a j
    match op with
    | .add n v =>
      if vdim v ≠ s.dims a j then .dimMismatch (s.dims a j)
      else if w ∈ o.index n then .updated
      else if visibleOther sees w (o.index n) then .elemInUse (resolveL (writerOf sees gt w) (o.index n))
      else .added
    | .rem n =>
      if w ∈ o.index n then .removed
      else if visibleOther sees w (o.index n) then .elemInUse (resolveL (writerOf sees gt w) (o.index n))
      else .missing
    | .set n _ =>
      if w ∈ o.index n then .attrSet
      else if visibleOther sees w (o.index n) then .elemInUse (resolveL (writerOf sees gt w) (o.index n))
      else .missing
    | _ => .missing

def kstep (ops : PartOps N V P) (sees : L → L → Bool) (gt : L → L → Bool) (vdim : V → Nat)
    (adv : Nat → KView L N P × Nat → Nat) (c : KCmd L N V) (s : KState L N P) : KState L N P :=
  match c.op with
  | .write op => kwrite ops sees gt vdim c.label op s
  | .read q => { s with str := fun b => if b = c.label then adv q (kview sees gt c.label s) else s.str b }

def kreply (sees : L → L → Bool) (gt : L → L → Bool) (vdim : V → Nat) (rd : Nat → KView L N P × Nat → Rd)
    (c : KCmd L N V) (s : KState L N P) : WRep L ⊕ Rd :=
  match c.op with
  | .write op => .inl (wreply sees gt vdim c.label op s)
  | .read q => .inr (rd q (kview sees gt c.label s))

def restrictK (sees : L → L → Bool) (gt : L → L → Bool) (R : L) (s : KState L N P) : KState L N P :=
  { copies := s.copies.filter (fun c => sees R c.1),
    objs := fun a j => if sees R a then restrictTo sees gt R (s.objs a j) else blank,
    dims := fun a j => if sees R a then s.dims a j else 0,
    made := fun a => if sees R a then s.made a else 0,
    str := fun a => if sees R a then s.str a else 0 }

def KInv (sees : L → L → Bool) (s : KState L N P) : Prop :=
  (∀ c ∈ s.copies, ∀ a j, c.2 = .obj a j → sees c.1 a = true) ∧ (∀ a j, (s.objs a j).stream = fun _ => 0)

theorem find_filter_of {α : Type} (p f : α → Bool) (h : ∀ x, f x = true → p x = true) :
    ∀ (xs : List α), (xs.filter p).find? f = xs.find? f := by
  intro xs
  induction xs with
  | nil => rfl
  | cons x xs ih =>
    cases hf : f x
    · cases hp : p x
      · simp [hp, hf, ih]
      · simp [hp, hf, ih]
    · have hp := h x hf
      simp [hp, hf]

theorem resolve_filter_obs (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (R w : L)
    (hw : sees R w = true) (ls : List L) :
    resolveL (writerOf sees gt w) (ls.filter (sees R)) = resolveL (writerOf sees gt w) ls := by
  have hown : (writerOf sees gt w).vis (writerOf sees gt w).own = true := hs.refl w
  rw [resolve_visible _ hown (ls.filter (sees R)), resolve_visible _ hown ls, List.filter_filter]
  congr 1
  apply List.filter_congr
  intro l _
  show (sees w l && sees R l) = sees w l
  cases h : sees w l
  · simp
  · simp [hs.trans R w l hw h]

theorem found_filter (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (R w : L)
    (hw : sees R w = true) (cs : List (L × Tgt L)) :
    found sees gt w (cs.filter (fun c => sees R c.1)) = found sees gt w cs := by
  unfold found
  have hmap : (cs.filter (fun c => sees R c.1)).map Prod.fst = (cs.map Prod.fst).filter (sees R) := by
    rw [List.filter_map]; rfl
  rw [hmap, resolve_filter_obs sees hs gt R w hw]
  cases hr : resolveL (writerOf sees gt w) (cs.map Prod.fst) with
  | none => rfl
  | some l =>
    simp only
    apply find_filter_of
    intro x hx
    have hxl : x.1 = l := by simpa using hx
    rcases (resolve_mem _ _ l hr).2 with e | e
    · rw [hxl]; show sees R l = true; rw [e]; exact hw
    · rw [hxl]; exact hs.trans R w l hw e

theorem found_mem (sees : L → L → Bool) (gt : L → L → Bool) (w : L) (cs : List (L × Tgt L)) (c : L × Tgt L)
    (h : found sees gt w cs = some c) : c ∈ cs ∧ (c.1 = w ∨ sees w c.1 = true) := by
  unfold found at h
  cases hr : resolveL (writerOf sees gt w) (cs.map Prod.fst) with
  | none => rw [hr] at h; cases h
  | some l =>
    rw [hr] at h
    simp only at h
    have hm := List.mem_of_find?_eq_some h
    have hl := List.find?_some h
    have hcl : c.1 = l := by simpa using hl
    rw [hcl]
    exact ⟨hm, (resolve_mem _ _ l hr).2⟩

theorem found_sees (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (w : L) (s : KState L N P)
    (hi : KInv sees s) (l a : L) (j : Nat) (h : found sees gt w s.copies = some (l, .obj a j)) :
    sees w a = true := by
  have ⟨hm, hv⟩ := found_mem sees gt w s.copies _ h
  have hla : sees l a = true := hi.1 _ hm a j rfl
  rcases hv with e | e
  · simp only at e; rw [← e]; exact hla
  · exact hs.trans w l a e hla

theorem restrict_compose (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (R w : L)
    (hw : sees R w = true) (o : LState L N P) :
    restrictTo sees gt w (restrictTo sees gt R o) = restrictTo sees gt w o := by
  unfold restrictTo
  apply restrict_eq_of
  · intro l hl
    have hR : sees R l = true := hs.trans R w l hw hl
    show (if sees R l = true then o.parts l else none) = o.parts l
    simp [hR]
  · intro n
    show ((o.index n).filter (sees R)).filter (sees w) = (o.index n).filter (sees w)
    rw [List.filter_filter]
    apply List.filter_congr
    intro l _
    cases h : sees w l
    · simp
    · simp [hs.trans R w l hw h]
  · intro l hl
    have hR : sees R l = true := hs.trans R w l hw hl
    show (if sees R l = true then o.stream l else 0) = o.stream l
    simp [hR]

theorem kview_restrict (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (R w : L)
    (hw : sees R w = true) (s : KState L N P) (hi : KInv sees s) :
    kview sees gt w (restrictK sees gt R s) = kview sees gt w s := by
  unfold kview
  have hf : found sees gt w (restrictK sees gt R s).copies = found sees gt w s.copies :=
    found_filter sees hs gt R w hw s.copies
  rw [hf]
  have hstr : (restrictK sees gt R s).str w = s.str w := by simp [restrictK, hw]
  rw [hstr]
  cases h : found sees gt w s.copies with
  | none => rfl
  | some c =>
    obtain ⟨l, tg⟩ := c
    cases tg with
    | other => rfl
    | obj a j =>
      have ha : sees R a = true := hs.trans R w a hw (found_sees sees hs gt w s hi l a j h)
      simp only [restrictK, ha, ↓reduceIte, restrict_compose sees hs gt R w hw]

theorem wreply_restrict (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (vdim : V → Nat) (R w : L)
    (hw : sees R w = true) (op : WOp N V) (s : KState L N P) (hi : KInv sees s) :
    wreply sees gt vdim w op (restrictK sees gt R s) = wreply sees gt vdim w op s := by
  unfold wreply
  have hf : found sees gt w (restrictK sees gt R s).copies = found sees gt w s.copies :=
    found_filter sees hs gt R w hw s.copies
  rw [hf]
  cases h : found sees gt w s.copies with
  | none => rfl
  | some c =>
    obtain ⟨l, tg⟩ := c
    cases tg with
    | other => rfl
    | obj a j =>
      have hwa := found_sees sees hs gt w s hi l a j h
      have ha : sees R a = true := hs.trans R w a hw hwa
      have hobj : (restrictK sees gt R s).objs a j = restrictTo sees gt R (s.objs a j) := by
        simp [restrictK, ha]
      have hdim : (restrictK sees gt R s).dims a j = s.dims a j := by simp [restrictK, ha]
      have hmem : ∀ n, (w ∈ (restrictTo sees gt R (s.objs a j)).index n) ↔ w ∈ (s.objs a j).index n := by
        intro n
        show w ∈ ((s.objs a j).index n).filter (sees R) ↔ _
        simp [List.mem_filter, hw]
      have hvo : ∀ n, visibleOther sees w ((restrictTo sees gt R (s.objs a j)).index n) =
          visibleOther sees w ((s.objs a j).index n) :=
        fun n => visibleOther_restrict sees hs R w hw ((s.objs a j).index n)
      have hres : ∀ n, resolveL (writerOf sees gt w) ((restrictTo sees gt R (s.objs a j)).index n) =
          resolveL (writerOf sees gt w) ((s.objs a j).index n) :=
        fun n => resolve_filter_obs sees hs gt R w hw ((s.objs a j).index n)
      simp only [hobj, hdim]
      cases op with
      | add n v => simp only [hmem, hvo, hres]
      | rem n => simp only [hmem, hvo, hres]
      | set n v => simp only [hmem, hvo, hres]
      | drop => rfl
      | draw k => rfl

theorem kreply_restrict (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (vdim : V → Nat)
    (rd : Nat → KView L N P × Nat → Rd) (R : L) (c : KCmd L N V) (hw : sees R c.label = true)
    (s : KState L N P) (hi : KInv sees s) :
    kreply sees gt vdim rd c (restrictK sees gt R s) = kreply sees gt vdim rd c s := by
  unfold kreply
  cases c.op with
  | write op => simp only [wreply_restrict sees hs gt vdim R c.label hw op s hi]
  | read q => simp only [kview_restrict sees hs gt R c.label hw s hi]

theorem reply_confined (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (vdim : V → Nat)
    (rd : Nat → KView L N P × Nat → Rd) (c : KCmd L N V) (s : KState L N P) (hi : KInv sees s) :
    kreply sees gt vdim rd c s = kreply sees gt vdim rd c (restrictK sees gt c.label s) :=
  (kreply_restrict sees hs gt vdim rd c.label c (hs.refl c.label) s hi).symm

theorem kstate_eq (a b : KState L N P) (h1 : a.copies = b.copies) (h2 : a.objs = b.objs) (h3 : a.dims = b.dims)
    (h4 : a.made = b.made) (h5 : a.str = b.str) : a = b := by
  cases a; cases b; simp_all

theorem wstep_stream_other (ops : PartOps N V P) (sees : L → L → Bool) (c : Cmd L N V) (x : LState L N P)
    (l : L) (hl : l ≠ c.label) : (wstep ops sees c x).stream l = x.stream l := by
  obtain ⟨w, op⟩ := c
  simp only at hl
  cases op with
  | add n v =>
    simp only [wstep]
    split
    · split <;> simp [setPart]
    · split
      · rfl
      · split <;> simp [setIndex, setPart, setStream, hl]
  | set n v =>
    simp only [wstep]
    split
    · split <;> simp [setPart]
    · rfl
  | rem n =>
    simp only [wstep]
    split
    · split <;> simp [setIndex, setPart]
    · rfl
  | drop => rfl
  | draw k => simp [wstep, setStream, hl]

theorem normS_withStream (o : LState L N P) (st : L → Nat) (h : o.stream = fun _ => 0) :
    normS (withStream o st) = o := by
  cases o; simp_all [normS, withStream]

theorem normS_stream (o : LState L N P) : (normS o).stream = fun _ => 0 := rfl

theorem restrict_normS (sees : L → L → Bool) (gt : L → L → Bool) (R : L) (a b : LState L N P)
    (h : restrictTo sees gt R a = restrictTo sees gt R b) :
    restrictTo sees gt R (normS a) = restrictTo sees gt R (normS b) := by
  unfold restrictTo at *
  apply restrict_eq_of
  · intro l hl; exact restrict_parts_eq _ a b h l hl
  · intro n; exact restrict_index_eq _ a b h n
  · intro l _; rfl

theorem restrict_withStream (sees : L → L → Bool) (gt : L → L → Bool) (R : L) (a b : LState L N P)
    (sa sb : L → Nat) (h : restrictTo sees gt R a = restrictTo sees gt R b) (hst : ∀ l, sees R l = true → sa l = sb l) :
    restrictTo sees gt R (withStream a sa) = restrictTo sees gt R (withStream b sb) := by
  unfold restrictTo at *
  apply restrict_eq_of
  · intro l hl; exact restrict_parts_eq _ a b h l hl
  · intro n; exact restrict_index_eq _ a b h n
  · intro l hl; exact hst l hl

theorem step_congr (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (R : L)
    (c : Cmd L N V) (hw : sees R c.label = true) (a b : LState L N P)
    (h : restrictTo sees gt R a = restrictTo sees gt R b) :
    restrictTo sees gt R (wstep ops sees c a) = restrictTo sees gt R (wstep ops sees c b) := by
  rw [← step_consistent ops sees hs gt R c a hw, h, step_consistent ops sees hs gt R c b hw]

theorem syncC_mem (w : L) (tg : Tgt L) (b : Bool) (cs : List (L × Tgt L)) (c : L × Tgt L)
    (h : c ∈ syncC w tg b cs) : c ∈ cs ∨ c = (w, tg) := by
  unfold syncC at h
  split at h
  · split at h
    · exact Or.inl h
    · rcases List.mem_append.mp h with e | e
      · exact Or.inl e
      · exact Or.inr (List.mem_singleton.mp e)
  · exact Or.inl (List.mem_filter.mp h).1

theorem syncC_hidden (sees : L → L → Bool) (R w : L) (hw : sees R w = false) (tg : Tgt L) (b : Bool)
    (cs : List (L × Tgt L)) :
    (syncC w tg b cs).filter (fun c => sees R c.1) = cs.filter (fun c => sees R c.1) := by
  unfold syncC
  split
  · split
    · rfl
    · simp [List.filter_append, hw]
  · rw [List.filter_filter]
    apply List.filter_congr
    intro c _
    cases h : sees R c.1
    · simp
    · have hne : c.1 ≠ w := fun e => by rw [e, hw] at h; cases h
      simp [hne]

theorem syncC_visible (sees : L → L → Bool) (R w : L) (hw : sees R w = true) (tg : Tgt L) (b : Bool)
    (cs : List (L × Tgt L)) :
    (syncC w tg b cs).filter (fun c => sees R c.1) = syncC w tg b (cs.filter (fun c => sees R c.1)) := by
  unfold syncC
  split
  · have hany : (cs.filter (fun c => sees R c.1)).any (fun c => decide (c.1 = w)) = cs.any (fun c => decide (c.1 = w)) := by
      apply Bool.eq_iff_iff.mpr
      simp only [List.any_eq_true, List.mem_filter, decide_eq_true_eq]
      constructor
      · intro ⟨c, ⟨hc, _⟩, e⟩; exact ⟨c, hc, e⟩
      · intro ⟨c, hc, e⟩; exact ⟨c, ⟨hc, by rw [e]; exact hw⟩, e⟩
    rw [hany]
    split
    · rfl
    · simp [List.filter_append, hw]
  · rw [List.filter_filter, List.filter_filter]
    apply List.filter_congr
    intro c _
    cases sees R c.1 <;> cases decide (c.1 = w) <;> rfl

theorem kinv_step (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (vdim : V → Nat) (adv : Nat → KView L N P × Nat → Nat) (c : KCmd L N V) (s : KState L N P)
    (hi : KInv sees s) : KInv sees (kstep ops sees gt vdim adv c s) := by
  obtain ⟨w, kop⟩ := c
  cases kop with
  | read q => exact hi
  | write op =>
    simp only [kstep, kwrite]
    cases h : found sees gt w s.copies with
    | none =>
      cases op with
      | add n v =>
        refine ⟨?_, ?_⟩
        · intro c hc a j he
          rcases List.mem_append.mp hc with e | e
          · exact hi.1 c e a j he
          · rw [List.mem_singleton.mp e] at he ⊢
            cases he
            exact hs.refl w
        · intro a j
          simp only [setObj]
          split
          · rfl
          · exact hi.2 a j
      | set n v => exact hi
      | rem n => exact hi
      | drop => exact hi
      | draw k => exact hi
    | some c =>
      obtain ⟨l, tg⟩ := c
      cases tg with
      | other => exact hi
      | obj a j =>
        simp only
        split
        · exact hi
        · refine ⟨?_, ?_⟩
          · intro c hc b k he
            rcases syncC_mem w _ _ s.copies c hc with e | e
            · exact hi.1 c e b k he
            · rw [e] at he ⊢
              cases he
              exact found_sees sees hs gt w s hi l a j h
          · intro b k
            simp only [setObj]
            split
            · rfl
            · exact hi.2 b k

theorem kstep_local (ops : PartOps N V P) (sees : L → L → Bool) (gt : L → L → Bool)
    (vdim : V → Nat) (adv : Nat → KView L N P × Nat → Nat) (R : L) (c : KCmd L N V) (s : KState L N P)
    (hi : KInv sees s) (hid : sees R c.label = false) :
    restrictK sees gt R (kstep ops sees gt vdim adv c s) = restrictK sees gt R s := by
  obtain ⟨w, kop⟩ := c
  simp only at hid
  cases kop with
  | read q =>
    apply kstate_eq <;> try rfl
    funext b
    simp only [restrictK, kstep]
    by_cases hb : b = w
    · subst hb; simp [hid]
    · simp [hb]
  | write op =>
    simp only [kstep, kwrite]
    cases h : found sees gt w s.copies with
    | none =>
      cases op with
      | add n v =>
        apply kstate_eq
        · simp [restrictK, List.filter_append, hid]
        · funext a j
          simp only [restrictK, setObj]
          by_cases ha : a = w
          · subst ha; simp [hid]
          · simp [ha]
        · funext a j
          simp only [restrictK]
          by_cases ha : a = w
          · subst ha; simp [hid]
          · simp [ha]
        · funext a
          simp only [restrictK]
          by_cases ha : a = w
          · subst ha; simp [hid]
          · simp [ha]
        · funext a
          simp only [restrictK]
          by_cases ha : a = w
          · subst ha; simp [hid]
          · have := wstep_stream_other ops sees ⟨w, .add n v⟩ (withStream blank s.str) a ha
            rw [this]; rfl
      | set n v => rfl
      | rem n => rfl
      | drop => rfl
      | draw k => rfl
    | some c =>
      obtain ⟨l, tg⟩ := c
      cases tg with
      | other => rfl
      | obj a j =>
        simp only
        split
        · rfl
        · apply kstate_eq
          · exact syncC_hidden sees R w hid _ _ s.copies
          · funext b k
            simp only [restrictK, setObj]
            by_cases hb : b = a ∧ k = j
            · obtain ⟨rfl, rfl⟩ := hb
              simp only [and_self, ↓reduceIte]
              split
              · have hl := step_local ops sees gt R ⟨w, op⟩ (withStream (s.objs b k) s.str) hid
                have hn := restrict_normS sees gt R _ _ hl
                rw [hn, normS_withStream _ _ (hi.2 b k)]
              · rfl
            · simp [hb]
          · rfl
          · rfl
          · funext b
            simp only [restrictK]
            by_cases hb : b = w
            · subst hb; simp [hid]
            · have := wstep_stream_other ops sees ⟨w, op⟩ (withStream (s.objs a j) s.str) b hb
              rw [this]; rfl

theorem kstep_consistent (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (vdim : V → Nat) (adv : Nat → KView L N P × Nat → Nat) (R : L) (c : KCmd L N V) (s t : KState L N P)
    (hi : KInv sees s) (hj : KInv sees t) (he : restrictK sees gt R s = restrictK sees gt R t)
    (hvis : sees R c.label = true) :
    restrictK sees gt R (kstep ops sees gt vdim adv c s) = restrictK sees gt R (kstep ops sees gt vdim adv c t) := by
  obtain ⟨w, kop⟩ := c
  simp only at hvis
  have hc : s.copies.filter (fun c => sees R c.1) = t.copies.filter (fun c => sees R c.1) := congrArg KState.copies he
  have ho : ∀ a j, sees R a = true → restrictTo sees gt R (s.objs a j) = restrictTo sees gt R (t.objs a j) := by
    intro a j ha
    have := congrFun (congrFun (congrArg KState.objs he) a) j
    simpa [restrictK, ha] using this
  have hd : ∀ a j, sees R a = true → s.dims a j = t.dims a j := by
    intro a j ha
    have := congrFun (congrFun (congrArg KState.dims he) a) j
    simpa [restrictK, ha] using this
  have hm : ∀ a, sees R a = true → s.made a = t.made a := by
    intro a ha
    have := congrFun (congrArg KState.made he) a
    simpa [restrictK, ha] using this
  have hst : ∀ a, sees R a = true → s.str a = t.str a := by
    intro a ha
    have := congrFun (congrArg KState.str he) a
    simpa [restrictK, ha] using this
  have hf : found sees gt w s.copies = found sees gt w t.copies := by
    rw [← found_filter sees hs gt R w hvis s.copies, hc, found_filter sees hs gt R w hvis t.copies]
  have hrs : restrictK sees gt R s = restrictK sees gt R t := he
  cases kop with
  | read q =>
    have hv : kview sees gt w s = kview sees gt w t := by
      rw [← kview_restrict sees hs gt R w hvis s hi, hrs, kview_restrict sees hs gt R w hvis t hj]
    apply kstate_eq
    · exact hc
    · exact (have e := congrArg KState.objs he; e)
    · exact (have e := congrArg KState.dims he; e)
    · exact (have e := congrArg KState.made he; e)
    · funext b
      simp only [restrictK, kstep]
      by_cases hb : b = w
      · subst hb; simp [hvis, hv]
      · cases hrb : sees R b
        · rfl
        · simp [hb, hst b hrb]
  | write op =>
    simp only [kstep, kwrite]
    rw [← hf]
    cases h : found sees gt w s.copies with
    | none =>
      cases op with
      | add n v =>
        have hk : s.made w = t.made w := hm w hvis
        have hx : restrictTo sees gt R (withStream (blank : LState L N P) s.str) =
            restrictTo sees gt R (withStream (blank : LState L N P) t.str) :=
          restrict_withStream sees gt R _ _ _ _ rfl hst
        have hy := step_congr ops sees hs gt R ⟨w, .add n v⟩ hvis _ _ hx
        apply kstate_eq
        · simp [restrictK, List.filter_append, hvis, hk, hc]
        · funext a j
          simp only [restrictK]
          cases hra : sees R a
          · rfl
          · by_cases hb : a = w ∧ j = s.made w
            · obtain ⟨h1, h2⟩ := hb
              have e1 : setObj s w (s.made w) (normS (wstep ops sees ⟨w, .add n v⟩ (withStream blank s.str))) a j =
                  normS (wstep ops sees ⟨w, .add n v⟩ (withStream blank s.str)) := by simp [setObj, h1, h2]
              have e2 : setObj t w (t.made w) (normS (wstep ops sees ⟨w, .add n v⟩ (withStream blank t.str))) a j =
                  normS (wstep ops sees ⟨w, .add n v⟩ (withStream blank t.str)) := by simp [setObj, h1, h2, hk]
              simp only [↓reduceIte]
              rw [e1, e2]
              exact restrict_normS sees gt R _ _ hy
            · have hb' : ¬ (a = w ∧ j = t.made w) := by rw [← hk]; exact hb
              have e1 : setObj s w (s.made w) (normS (wstep ops sees ⟨w, .add n v⟩ (withStream blank s.str))) a j =
                  s.objs a j := by simp only [setObj, hb, ↓reduceIte]
              have e2 : setObj t w (t.made w) (normS (wstep ops sees ⟨w, .add n v⟩ (withStream blank t.str))) a j =
                  t.objs a j := by simp only [setObj, hb', ↓reduceIte]
              simp only [↓reduceIte]
              rw [e1, e2]
              exact ho a j hra
        · funext a j
          simp only [restrictK]
          cases hra : sees R a
          · rfl
          · simp [hk, hd a j hra]
        · funext a
          simp only [restrictK]
          cases hra : sees R a
          · rfl
          · simp [hk, hm a hra]
        · funext a
          simp only [restrictK]
          cases hra : sees R a
          · rfl
          · simp only [↓reduceIte]
            unfold restrictTo at hy
            exact restrict_stream_eq _ _ _ hy a hra
      | set n v => exact he
      | rem n => exact he
      | drop => exact he
      | draw k => exact he
    | some c =>
      obtain ⟨l, tg⟩ := c
      cases tg with
      | other => exact he
      | obj a j =>
        have ha : sees R a = true := hs.trans R w a hvis (found_sees sees hs gt w s hi l a j h)
        have hda : s.dims a j = t.dims a j := hd a j ha
        simp only
        rw [hda]
        split
        · exact he
        · have hx : restrictTo sees gt R (withStream (s.objs a j) s.str) =
              restrictTo sees gt R (withStream (t.objs a j) t.str) :=
            restrict_withStream sees gt R _ _ _ _ (ho a j ha) hst
          have hy := step_congr ops sees hs gt R ⟨w, op⟩ hvis _ _ hx
          have hpw : (wstep ops sees ⟨w, op⟩ (withStream (s.objs a j) s.str)).parts w =
              (wstep ops sees ⟨w, op⟩ (withStream (t.objs a j) t.str)).parts w := by
            unfold restrictTo at hy
            exact restrict_parts_eq _ _ _ hy w hvis
          apply kstate_eq
          · show (syncC w _ _ s.copies).filter _ = (syncC w _ _ t.copies).filter _
            rw [syncC_visible sees R w hvis, syncC_visible sees R w hvis, hc, hpw]
          · funext b k
            simp only [restrictK, setObj]
            cases hrb : sees R b
            · rfl
            · by_cases hb : b = a ∧ k = j
              · simp only [hb, and_self, ↓reduceIte]
                exact restrict_normS sees gt R _ _ hy
              · simp only [hb, ↓reduceIte]
                exact ho b k hrb
          · exact (have e := congrArg KState.dims he; e)
          · exact (have e := congrArg KState.made he; e)
          · funext b
            simp only [restrictK]
            cases hrb : sees R b
            · rfl
            · simp only [↓reduceIte]
              unfold restrictTo at hy
              exact restrict_stream_eq _ _ _ hy b hrb

def kouts (ops : PartOps N V P) (sees : L → L → Bool) (gt : L → L → Bool) (vdim : V → Nat)
    (adv : Nat → KView L N P × Nat → Nat) (rd : Nat → KView L N P × Nat → Rd) (R : L)
    (h : List (KCmd L N V)) (s : KState L N P) : List (WRep L ⊕ Rd) :=
  outsC sees KCmd.label (kstep ops sees gt vdim adv) (kreply sees gt vdim rd) R h s

theorem command_history (ops : PartOps N V P) (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool)
    (vdim : V → Nat) (adv : Nat → KView L N P × Nat → Nat) (rd : Nat → KView L N P × Nat → Rd) (R : L)
    (h : List (KCmd L N V)) (s : KState L N P) (hi : KInv sees s) :
    kouts ops sees gt vdim adv rd R h s = kouts ops sees gt vdim adv rd R (purgeC sees KCmd.label R h) s := by
  unfold kouts
  apply unwinding sees KCmd.label (kstep ops sees gt vdim adv) (kreply sees gt vdim rd) R
    (restrictK sees gt R) (KInv sees)
  · exact fun c s hi => kinv_step ops sees hs gt vdim adv c s hi
  · exact fun c s hi hid => kstep_local ops sees gt vdim adv R c s hi hid
  · exact fun c s t hi hj he hv => kstep_consistent ops sees hs gt vdim adv R c s t hi hj he hv
  · intro c s t hi hj he hv
    rw [← kreply_restrict sees hs gt vdim rd R c hv s hi, he, kreply_restrict sees hs gt vdim rd R c hv t hj]
  · exact hi
  · exact hi
  · rfl

def kempty : KState L N P := ⟨[], fun _ _ => blank, fun _ _ => 0, fun _ => 0, fun _ => 0⟩

theorem kempty_inv (sees : L → L → Bool) (str : L → Nat) : KInv sees { (kempty : KState L N P) with str := str } :=
  ⟨fun _ hc => (by simp [kempty] at hc), fun _ _ => rfl⟩

theorem resolved_copy_visible (sees : L → L → Bool) (hs : Sees sees) (gt : L → L → Bool) (R w : L)
    (hw : sees R w = true) (s t : KState L N P) (hi : KInv sees s) (hj : KInv sees t)
    (he : restrictK sees gt R s = restrictK sees gt R t) :
    found sees gt w s.copies = found sees gt w t.copies ∧ kview sees gt w s = kview sees gt w t := by
  constructor
  · rw [← found_filter sees hs gt R w hw s.copies, ← found_filter sees hs gt R w hw t.copies]
    exact congrArg (found sees gt w) (congrArg KState.copies he)
  · rw [← kview_restrict sees hs gt R w hw s hi, he, kview_restrict sees hs gt R w hw t hj]

def configLabelled (levels comps trusts : Nat) : Bool := decide (1 < levels) || decide (0 < comps) || decide (1 < trusts)

def dispatch {A : Type} (labelsOn : Bool) (plain labelled : A) : A := if labelsOn then labelled else plain

theorem single_level_plain {A : Type} (levels comps trusts : Nat) (hl : levels ≤ 1) (hc : comps = 0) (ht : trusts ≤ 1)
    (plain labelled : A) : dispatch (configLabelled levels comps trusts) plain labelled = plain := by
  have h1 : ¬ (1 < levels) := Nat.not_lt.mpr hl
  have h3 : ¬ (1 < trusts) := Nat.not_lt.mpr ht
  simp [dispatch, configLabelled, h1, hc, h3]

theorem single_label_found (sees : L → L → Bool) (gt : L → L → Bool) (w : L) (cs : List (L × Tgt L))
    (h : ∀ c ∈ cs, c.1 = w) : found sees gt w cs = cs.head? := by
  unfold found
  cases cs with
  | nil => rfl
  | cons c cs =>
    have hw : (writerOf sees gt w).own ∈ (c :: cs).map Prod.fst := by
      rw [← h c (List.mem_cons_self ..)]
      exact List.mem_map_of_mem (List.mem_cons_self ..)
    rw [resolve_own _ _ hw]
    simp [h c (List.mem_cons_self ..), writerOf]

theorem single_label_wreply (sees : L → L → Bool) (gt : L → L → Bool) (vdim : V → Nat) (w : L) (op : WOp N V)
    (s : KState L N P) (hc : ∀ c ∈ s.copies, c.1 = w) (hx : ∀ a j n, ∀ l ∈ (s.objs a j).index n, l = w) :
    (∀ l, wreply sees gt vdim w op s ≠ .nameInUse l) ∧ (∀ x, wreply sees gt vdim w op s ≠ .elemInUse x) := by
  have hvo : ∀ a j n, visibleOther sees w ((s.objs a j).index n) = false :=
    fun a j n => plain_visibleOther sees w _ (hx a j n)
  unfold wreply
  cases h : found sees gt w s.copies with
  | none => cases op <;> simp
  | some c =>
    obtain ⟨l, tg⟩ := c
    have hl : l = w := by
      have := (found_mem sees gt w s.copies _ h).1
      exact hc _ this
    cases tg with
    | other => simp [hl]
    | obj a j =>
      cases op with
      | add n v =>
        simp only [hvo]
        constructor <;> intro x <;> split <;> (try split) <;> simp
      | rem n =>
        simp only [hvo]
        constructor <;> intro x <;> split <;> simp
      | set n v =>
        simp only [hvo]
        constructor <;> intro x <;> split <;> simp
      | drop => simp
      | draw k => simp

end Keys

end Vectors
