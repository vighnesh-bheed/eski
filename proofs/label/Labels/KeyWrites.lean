import Labels.KeyReads

namespace Labels

section KeyWrites
set_option linter.unusedSectionVars false
variable {N V : Type} [DecidableEq N]

def isAt (n : N) (W : TLabel) (c : KCopy N V) : Bool := c.name == n && c.label == W

def setOwn (s : KState N V) (W : TLabel) (n : N) (v : V) : KState N V :=
  match ownOf s W n with
  | some _ => { s with copies := s.copies.map (fun c => if isAt n W c then { c with val := v } else c) }
  | none => ⟨s.copies ++ [⟨n, W, v⟩], if W ∈ s.parts then s.parts else s.parts ++ [W]⟩

def delOwn (s : KState N V) (W : TLabel) (n : N) : KState N V :=
  { s with copies := s.copies.filter (fun c => !isAt n W c) }

inductive WOp (N V : Type) where
  | put (n : N) (v : V)
  | del (ns : List N)
  | createOnly (n : N) (v : V)
  | createMany (kvs : List (N × V))
  | renameNx (a b : N)
  | copyNx (a b : N)
  | declassify (n : N) (t : TLabel)

inductive WRep where
  | ok
  | inuse (l : TLabel)
  | exists
  | count (k : Nat)
  | noKey
  | direction
  | seen (l : TLabel)
deriving DecidableEq

def checks : WOp N V → List (N × Bool)
  | .put n _ => [(n, false)]
  | .del ns => ns.map (fun n => (n, false))
  | .createOnly n _ => [(n, true)]
  | .createMany kvs => kvs.map (fun p => (p.1, true))
  | .renameNx a b => [(a, false), (b, true)]
  | .copyNx _ _ => []
  | .declassify n _ => [(n, false)]

def conflict (s : KState N V) (W : TLabel) : List (N × Bool) → Option TLabel
  | [] => none
  | (n, co) :: rest =>
    if (ownOf s W n).isNone && !co then
      match other s W n with
      | some c => some c.label
      | none => conflict s W rest
    else conflict s W rest

def delMany (s : KState N V) (W : TLabel) : List N → Nat × KState N V
  | [] => (0, s)
  | n :: ns =>
    match ownOf s W n with
    | some _ => ((delMany (delOwn s W n) W ns).1 + 1, (delMany (delOwn s W n) W ns).2)
    | none => delMany s W ns

def setMany (s : KState N V) (W : TLabel) : List (N × V) → KState N V
  | [] => s
  | p :: ps => setMany (setOwn s W p.1 p.2) W ps

def applyW (W : TLabel) : WOp N V → KState N V → WRep × KState N V
  | .put n v, s => (.ok, setOwn s W n v)
  | .del ns, s => (.count (delMany s W ns).1, (delMany s W ns).2)
  | .createOnly n v, s => if (resolve s W n).isSome then (.exists, s) else (.ok, setOwn s W n v)
  | .createMany kvs, s => if kvs.any (fun p => (resolve s W p.1).isSome) then (.exists, s) else (.ok, setMany s W kvs)
  | .renameNx a b, s =>
    match ownOf s W a with
    | none => (.noKey, s)
    | some c => if (resolve s W b).isSome then (.exists, s) else (.ok, setOwn (delOwn s W a) W b c.val)
  | .copyNx a b, s =>
    match resolve s W a with
    | none => (.count 0, s)
    | some c => if (resolve s W b).isSome then (.exists, s) else (.ok, setOwn s W b c.val)
  | .declassify n t, s =>
    if t == W || !domT W t then (.direction, s)
    else match ownOf s W n with
      | none => (.noKey, s)
      | some c =>
        match resolve s t n with
        | some d => (.seen d.label, s)
        | none => (.ok, setOwn (delOwn s W n) t n c.val)

def kstep (W : TLabel) (op : WOp N V) (s : KState N V) : WRep × KState N V :=
  match conflict s W (checks op) with
  | some l => (.inuse l, s)
  | none => applyW W op s

def NotDecl : WOp N V → Prop
  | .declassify _ _ => False
  | _ => True

theorem filter_map_keep {α : Type} (f : α → α) (p : α → Bool) (hp : ∀ x, p x = true → f x = x)
    (hf : ∀ x, p (f x) = p x) (l : List α) : (l.map f).filter p = l.filter p := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    by_cases h : p x = true
    · simp [List.filter, h, hp x h, ih]
    · have h' : p x = false := by simpa using h
      simp [List.filter, hf x, h', ih]

def others (W : TLabel) (s : KState N V) : List (KCopy N V) := s.copies.filter (fun c => c.label != W)

theorem setOwn_others (s : KState N V) (W : TLabel) (n : N) (v : V) : others W (setOwn s W n v) = others W s := by
  unfold others setOwn
  split
  · simp only
    apply filter_map_keep
    · intro c hc
      have : isAt n W c = false := by
        simp only [bne_iff_ne, ne_eq] at hc
        simp [isAt, hc]
      simp [this]
    · intro c
      by_cases h : isAt n W c = true <;> simp [h]
  · simp [List.filter_append]

theorem delOwn_others (s : KState N V) (W : TLabel) (n : N) : others W (delOwn s W n) = others W s := by
  unfold others delOwn
  simp only [List.filter_filter]
  congr 1
  funext c
  by_cases h : c.label = W
  · simp [h]
  · simp [isAt, h]

theorem delMany_others (W : TLabel) : ∀ (ns : List N) (s : KState N V), others W (delMany s W ns).2 = others W s
  | [], _ => rfl
  | n :: ns, s => by
    unfold delMany
    split
    · simp only
      rw [delMany_others W ns, delOwn_others]
    · exact delMany_others W ns s

theorem setMany_others (W : TLabel) : ∀ (kvs : List (N × V)) (s : KState N V), others W (setMany s W kvs) = others W s
  | [], _ => rfl
  | p :: ps, s => by
    simp only [setMany]
    rw [setMany_others W ps, setOwn_others]

theorem kstep_others {W : TLabel} {op : WOp N V} (hd : NotDecl op) (s : KState N V) :
    others W (kstep W op s).2 = others W s := by
  unfold kstep
  split
  · rfl
  · cases op with
    | put n v => exact setOwn_others s W n v
    | del ns => exact delMany_others W ns s
    | createOnly n v =>
      simp only [applyW]
      split
      · rfl
      · exact setOwn_others s W n v
    | createMany kvs =>
      simp only [applyW]
      split
      · rfl
      · exact setMany_others W kvs s
    | renameNx a b =>
      simp only [applyW]
      split
      · rfl
      · split
        · rfl
        · simp only
          rw [setOwn_others, delOwn_others]
    | copyNx a b =>
      simp only [applyW]
      split
      · rfl
      · split
        · rfl
        · exact setOwn_others s W b _
    | declassify n t => exact hd.elim

theorem applyW_not_inuse (W : TLabel) (op : WOp N V) (s : KState N V) (l : TLabel) : (applyW W op s).1 ≠ .inuse l := by
  cases op with
  | put n v => simp [applyW]
  | del ns => simp [applyW]
  | createOnly n v =>
    simp only [applyW]
    split <;> simp
  | createMany kvs =>
    simp only [applyW]
    split <;> simp
  | renameNx a b =>
    simp only [applyW]
    split
    · simp
    · split <;> simp
  | copyNx a b =>
    simp only [applyW]
    split
    · simp
    · split <;> simp
  | declassify n t =>
    simp only [applyW]
    split
    · simp
    · split
      · simp
      · split <;> simp

theorem ownOf_setOwn (s : KState N V) (W : TLabel) (n : N) (v : V) : ownOf (setOwn s W n v) W n = some ⟨n, W, v⟩ := by
  unfold setOwn
  split
  · rename_i c hc
    obtain ⟨hm, hn, hl⟩ := ownOf_some hc
    unfold ownOf at hc ⊢
    simp only
    rw [List.find?_map]
    have : ((fun c => c.name == n && c.label == W) ∘ fun c => if isAt n W c then { c with val := v } else c) =
        fun c => c.name == n && c.label == W := by
      funext d
      simp only [Function.comp]
      by_cases h : isAt n W d = true
      · simp [h]
      · simp [h]
    rw [this, hc]
    simp only [Option.map_some, Option.some.injEq]
    have h1 : isAt n W c = true := by simp [isAt, hn, hl]
    simp only [h1, ↓reduceIte]
    rw [← hn, ← hl]
  · rename_i hc
    unfold ownOf at hc ⊢
    simp only
    rw [List.find?_append, hc]
    simp

theorem ownOf_delOwn (s : KState N V) (W : TLabel) (n : N) : ownOf (delOwn s W n) W n = none := by
  unfold ownOf delOwn
  apply List.find?_eq_none.2
  intro c hc
  have := (List.mem_filter.1 hc).2
  simp only [isAt, Bool.not_and, Bool.or_eq_true, Bool.not_eq_true', beq_eq_false_iff_ne, ne_eq] at this
  simp only [Bool.and_eq_true, beq_iff_eq, not_and]
  intro hn hl
  rcases this with h | h
  · exact h hn
  · exact h hl

theorem conflict_spec {s : KState N V} {W : TLabel} :
    ∀ {chk : List (N × Bool)} {l : TLabel}, conflict s W chk = some l →
      ∃ n c, (n, false) ∈ chk ∧ ownOf s W n = none ∧ other s W n = some c ∧ c.label = l
  | [], _, h => by simp [conflict] at h
  | (n, co) :: rest, l, h => by
    unfold conflict at h
    split at h
    · rename_i hc
      simp only [Bool.and_eq_true, Option.isNone_iff_eq_none, Bool.not_eq_true'] at hc
      split at h
      · rename_i c hoc
        simp only [Option.some.injEq] at h
        refine ⟨n, c, ?_, hc.1, hoc, h⟩
        rw [← hc.2]
        exact List.mem_cons_self
      · obtain ⟨m, c, h1, h2, h3, h4⟩ := conflict_spec h
        exact ⟨m, c, List.mem_cons_of_mem _ h1, h2, h3, h4⟩
    · obtain ⟨m, c, h1, h2, h3, h4⟩ := conflict_spec h
      exact ⟨m, c, List.mem_cons_of_mem _ h1, h2, h3, h4⟩

theorem inuse_visible {W l : TLabel} {op : WOp N V} {s s' : KState N V} (h : kstep W op s = (.inuse l, s')) :
    s' = s ∧ ∃ n c, (n, false) ∈ checks op ∧ ownOf s W n = none ∧ c ∈ s.copies ∧ c.name = n ∧ c.label = l ∧
      c.label ≠ W ∧ domT W c.label = true := by
  unfold kstep at h
  split at h
  · rename_i l' hc
    simp only [Prod.mk.injEq, WRep.inuse.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    obtain ⟨n, c, h1, h2, h3, h4⟩ := conflict_spec hc
    obtain ⟨m1, m2, m3, m4⟩ := cands_mem.1 (pick_mem h3)
    exact ⟨rfl, n, c, h1, h2, m1, m2, h4, m3, m4⟩
  · exact absurd (congrArg Prod.fst h) (applyW_not_inuse W op s l)

theorem inuse_names_best {W l : TLabel} {op : WOp N V} {s s' : KState N V} (h : kstep W op s = (.inuse l, s')) :
    ∃ n c, (n, false) ∈ checks op ∧ ownOf s W n = none ∧ resolve s W n = some c ∧ c.label = l := by
  unfold kstep at h
  split at h
  · rename_i l' hc
    simp only [Prod.mk.injEq, WRep.inuse.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    obtain ⟨n, c, h1, h2, h3, h4⟩ := conflict_spec hc
    exact ⟨n, c, h1, h2, by rw [resolve_other h2]; exact h3, h4⟩
  · exact absurd (congrArg Prod.fst h) (applyW_not_inuse W op s l)

theorem put_lands {W : TLabel} {n : N} {v : V} {s s' : KState N V} (h : kstep W (.put n v) s = (.ok, s')) :
    ownOf s' W n = some ⟨n, W, v⟩ ∧ others W s' = others W s := by
  unfold kstep at h
  split at h
  · simp at h
  · simp only [applyW, Prod.mk.injEq, true_and] at h
    subst h
    exact ⟨ownOf_setOwn s W n v, setOwn_others s W n v⟩

theorem put_refused_or_lands (W : TLabel) (n : N) (v : V) (s : KState N V) :
    (∃ l, kstep W (.put n v) s = (.inuse l, s)) ∨ kstep W (.put n v) s = (.ok, setOwn s W n v) := by
  unfold kstep
  split
  · rename_i l _
    exact Or.inl ⟨l, rfl⟩
  · exact Or.inr rfl

theorem put_inuse_iff (W : TLabel) (n : N) (v : V) (s : KState N V) :
    (∃ l, kstep W (.put n v) s = (.inuse l, s)) ↔ ownOf s W n = none ∧ (other s W n).isSome := by
  unfold kstep checks conflict conflict
  cases ho : ownOf s W n with
  | some c => simp [applyW]
  | none =>
    cases hc : other s W n with
    | some c => simp
    | none => simp [applyW]

theorem delMany_gone (W : TLabel) : ∀ (ns : List N) (s : KState N V), ∀ n ∈ ns, ownOf (delMany s W ns).2 W n = none
  | [], _, n, hn => by simp at hn
  | m :: ms, s, n, hn => by
    unfold delMany
    split
    · simp only
      by_cases h : n = m
      · subst h
        by_cases hm : n ∈ ms
        · exact delMany_gone W ms _ n hm
        · exact delMany_keep W ms _ n hm (ownOf_delOwn s W n)
      · exact delMany_gone W ms _ n (List.mem_of_ne_of_mem h hn)
    · rename_i ho
      by_cases h : n = m
      · subst h
        by_cases hm : n ∈ ms
        · exact delMany_gone W ms _ n hm
        · exact delMany_keep W ms _ n hm ho
      · exact delMany_gone W ms _ n (List.mem_of_ne_of_mem h hn)
termination_by ns => ns.length
where
  delMany_keep (W : TLabel) : ∀ (ns : List N) (s : KState N V) (n : N), n ∉ ns → ownOf s W n = none →
      ownOf (delMany s W ns).2 W n = none
    | [], _, _, _, h => h
    | m :: ms, s, n, hn, h => by
      unfold delMany
      have hne : n ≠ m := fun e => hn (e ▸ List.mem_cons_self)
      have hms : n ∉ ms := fun e => hn (List.mem_cons_of_mem _ e)
      split
      · simp only
        apply delMany_keep W ms _ n hms
        unfold ownOf delOwn at *
        apply List.find?_eq_none.2
        intro c hc
        exact List.find?_eq_none.1 h c (List.mem_filter.1 hc).1
      · exact delMany_keep W ms _ n hms h

theorem del_lands {W : TLabel} {ns : List N} {k : Nat} {s s' : KState N V} (h : kstep W (.del ns) s = (.count k, s')) :
    (∀ n ∈ ns, ownOf s' W n = none) ∧ others W s' = others W s := by
  unfold kstep at h
  split at h
  · simp at h
  · simp only [applyW, Prod.mk.injEq] at h
    obtain ⟨_, rfl⟩ := h
    exact ⟨delMany_gone W ns s, delMany_others W ns s⟩

theorem createOnly_exists {W : TLabel} {n : N} {v : V} {s : KState N V} (h : (resolve s W n).isSome = true) :
    kstep W (.createOnly n v) s = (.exists, s) := by
  simp [kstep, checks, conflict, applyW, h]

theorem createOnly_creates {W : TLabel} {n : N} {v : V} {s : KState N V} (h : resolve s W n = none) :
    kstep W (.createOnly n v) s = (.ok, setOwn s W n v) ∧ ownOf (setOwn s W n v) W n = some ⟨n, W, v⟩ := by
  refine ⟨?_, ownOf_setOwn s W n v⟩
  simp [kstep, checks, conflict, applyW, h]

theorem createOnly_never_inuse (W : TLabel) (n : N) (v : V) (s : KState N V) (l : TLabel) :
    kstep W (.createOnly n v) s ≠ (.inuse l, s) := by
  intro h
  obtain ⟨_, m, _, h1, _, _⟩ := inuse_visible h
  simp [checks] at h1

theorem conflict_create_only (s : KState N V) (W : TLabel) :
    ∀ (ns : List N), conflict s W (ns.map (fun n => (n, true))) = none
  | [] => rfl
  | n :: ns => by
    simp only [List.map_cons, conflict, Bool.not_true, Bool.and_false, Bool.false_eq_true, ↓reduceIte]
    exact conflict_create_only s W ns

theorem createMany_exists {W : TLabel} {kvs : List (N × V)} {s : KState N V}
    (h : kvs.any (fun p => (resolve s W p.1).isSome) = true) : kstep W (.createMany kvs) s = (.exists, s) := by
  have hc : conflict s W (checks (WOp.createMany kvs : WOp N V)) = none := by
    have := conflict_create_only s W (kvs.map (·.1))
    simp only [List.map_map] at this
    exact this
  simp [kstep, hc, applyW, h]

theorem createMany_creates {W : TLabel} {kvs : List (N × V)} {s : KState N V}
    (h : kvs.any (fun p => (resolve s W p.1).isSome) = false) : kstep W (.createMany kvs) s = (.ok, setMany s W kvs) := by
  have hc : conflict s W (checks (WOp.createMany kvs : WOp N V)) = none := by
    have := conflict_create_only s W (kvs.map (·.1))
    simp only [List.map_map] at this
    exact this
  simp [kstep, hc, applyW, h]

theorem renameNx_exists {W : TLabel} {a b : N} {s : KState N V} {c : KCopy N V} (ha : ownOf s W a = some c)
    (hb : (resolve s W b).isSome = true) : kstep W (.renameNx a b) s = (.exists, s) := by
  simp [kstep, checks, conflict, ha, applyW, hb]

theorem copyNx_exists {W : TLabel} {a b : N} {s : KState N V} {c : KCopy N V} (ha : resolve s W a = some c)
    (hb : (resolve s W b).isSome = true) : kstep W (.copyNx a b) s = (.exists, s) := by
  simp [kstep, checks, conflict, ha, applyW, hb]

theorem copyNx_reads_visible {W : TLabel} {a b : N} {s s' : KState N V} (h : kstep W (.copyNx a b) s = (.ok, s')) :
    ∃ c, resolve s W a = some c ∧ domT W c.label = true ∧ resolve s W b = none ∧ s' = setOwn s W b c.val := by
  simp only [kstep, checks, conflict, applyW] at h
  split at h
  · simp at h
  · rename_i c hc
    split at h
    · simp at h
    · rename_i hb
      simp only [Prod.mk.injEq, true_and] at h
      refine ⟨c, hc, (resolve_visible hc).2.2, ?_, h.symm⟩
      cases hr : resolve s W b with
      | none => rfl
      | some _ => rw [hr] at hb; simp at hb

theorem other_delOwn_none {s : KState N V} {W t : TLabel} {n : N} (h : other s t n = none) :
    other (delOwn s W n) t n = none := by
  unfold other at *
  apply pick_none.2
  have hnil := pick_none.1 h
  unfold cands delOwn at *
  simp only at *
  apply List.eq_nil_iff_forall_not_mem.2
  intro c hc
  have hm := List.mem_filter.1 hc
  have hm1 := (List.mem_filter.1 hm.1).1
  have : c ∈ s.copies.filter (fun c => c.name == n && c.label != t && domT t c.label) :=
    List.mem_filter.2 ⟨hm1, hm.2⟩
  rw [hnil] at this
  simp at this

theorem ownOf_delOwn_none {s : KState N V} {W t : TLabel} {n : N} (h : ownOf s t n = none) :
    ownOf (delOwn s W n) t n = none := by
  unfold ownOf delOwn at *
  apply List.find?_eq_none.2
  intro c hc
  exact List.find?_eq_none.1 h c (List.mem_filter.1 hc).1

theorem declassify_atomic {W t : TLabel} {n : N} {s s' : KState N V} (h : kstep W (.declassify n t) s = (.ok, s')) :
    ∃ c, ownOf s W n = some c ∧ t ≠ W ∧ domT W t = true ∧ resolve s t n = none ∧
      s' = setOwn (delOwn s W n) t n c.val ∧ kstep t (.put n c.val) (delOwn s W n) = (.ok, s') ∧
      ownOf s' W n = none ∧ ownOf s' t n = some ⟨n, t, c.val⟩ := by
  unfold kstep at h
  split at h
  · simp at h
  · simp only [applyW] at h
    split at h
    · simp at h
    · rename_i hdir
      simp only [Bool.or_eq_true, beq_iff_eq, Bool.not_eq_true', not_or, Bool.not_eq_false] at hdir
      split at h
      · simp at h
      · rename_i c hc
        split at h
        · simp at h
        · rename_i hr
          simp only [Prod.mk.injEq, true_and] at h
          subst h
          have hown : ownOf s t n = none := by
            unfold resolve at hr
            split at hr
            · simp at hr
            · assumption
          have hoth : other s t n = none := by
            rw [resolve_other hown] at hr
            exact hr
          have hput : kstep t (.put n c.val) (delOwn s W n) = (.ok, setOwn (delOwn s W n) t n c.val) := by
            simp [kstep, checks, conflict, ownOf_delOwn_none hown, other_delOwn_none hoth, applyW]
          refine ⟨c, hc, hdir.1, hdir.2, hr, rfl, hput, ?_, ownOf_setOwn _ t n c.val⟩
          unfold setOwn
          rw [ownOf_delOwn_none (W := W) hown]
          unfold ownOf delOwn
          simp only
          rw [List.find?_append]
          have hgone := ownOf_delOwn s W n
          unfold ownOf delOwn at hgone
          rw [hgone]
          have : t ≠ W := hdir.1
          simp [this]

theorem declassify_target_sees {W t : TLabel} {n : N} {s s' : KState N V} {l : TLabel}
    (h : kstep W (.declassify n t) s = (.seen l, s')) :
    s' = s ∧ ∃ c, resolve s t n = some c ∧ c.label = l ∧ domT t c.label = true := by
  unfold kstep at h
  split at h
  · simp at h
  · simp only [applyW] at h
    split at h
    · simp at h
    · split at h
      · simp at h
      · split at h
        · rename_i d hd
          simp only [Prod.mk.injEq, WRep.seen.injEq] at h
          obtain ⟨rfl, rfl⟩ := h
          exact ⟨rfl, d, hd, rfl, (resolve_visible hd).2.2⟩
        · simp at h

theorem declassify_direction {W t : TLabel} {n : N} {s : KState N V}
    (hc : conflict s W (checks (WOp.declassify n t : WOp N V)) = none) (hd : t = W ∨ domT W t = false) :
    kstep W (.declassify n t) s = (.direction, s) := by
  have : (t == W || !domT W t) = true := by
    rcases hd with rfl | hd
    · simp
    · simp [hd]
  simp [kstep, hc, applyW, this]

end KeyWrites

end Labels
