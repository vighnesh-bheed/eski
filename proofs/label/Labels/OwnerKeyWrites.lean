import Labels.OwnerKeyReads
import Labels.OwnerArrival

namespace Labels

section OwnerKeyWrites
set_option linter.unusedSectionVars false
variable {N V : Type} [DecidableEq N]

def oisAt (n : N) (W : Scope) (c : OCopy N V) : Bool := c.name == n && c.scope == W

def osetOwn (s : OState N V) (W : Scope) (n : N) (v : V) : OState N V :=
  match oexact s W n with
  | some _ => { s with copies := s.copies.map (fun c => if oisAt n W c then { c with val := v } else c) }
  | none => ⟨s.copies ++ [⟨n, W, v⟩], if W ∈ s.parts then s.parts else s.parts ++ [W]⟩

def odelOwn (s : OState N V) (W : Scope) (n : N) : OState N V :=
  { s with copies := s.copies.filter (fun c => !oisAt n W c) }

inductive OWRep where
  | ok
  | inuse (l : Scope)
  | exists
  | count (k : Nat)
  | noKey
  | direction
  | seen (l : Scope)
deriving DecidableEq

def oconflict (s : OState N V) (W : Scope) : List (N × Bool) → Option Scope
  | [] => none
  | (n, co) :: rest =>
    if (oexact s W n).isNone && !co then
      match oother s W n with
      | some c => some c.scope
      | none => oconflict s W rest
    else oconflict s W rest

def odelMany (s : OState N V) (W : Scope) : List N → Nat × OState N V
  | [] => (0, s)
  | n :: ns =>
    match oexact s W n with
    | some _ => ((odelMany (odelOwn s W n) W ns).1 + 1, (odelMany (odelOwn s W n) W ns).2)
    | none => odelMany s W ns

def osetMany (s : OState N V) (W : Scope) : List (N × V) → OState N V
  | [] => s
  | p :: ps => osetMany (osetOwn s W p.1 p.2) W ps

def oapplyW (W : Scope) : WOp N V → OState N V → OWRep × OState N V
  | .put n v, s => (.ok, osetOwn s W n v)
  | .del ns, s => (.count (odelMany s W ns).1, (odelMany s W ns).2)
  | .createOnly n v, s => if (oresolve s W n).isSome then (.exists, s) else (.ok, osetOwn s W n v)
  | .createMany kvs, s =>
    if kvs.any (fun p => (oresolve s W p.1).isSome) then (.exists, s) else (.ok, osetMany s W kvs)
  | .renameNx a b, s =>
    match oexact s W a with
    | none => (.noKey, s)
    | some c => if (oresolve s W b).isSome then (.exists, s) else (.ok, osetOwn (odelOwn s W a) W b c.val)
  | .copyNx a b, s =>
    match oresolve s W a with
    | none => (.count 0, s)
    | some c => if (oresolve s W b).isSome then (.exists, s) else (.ok, osetOwn s W b c.val)
  | .declassify n t, s =>
    if t == W.1 || !domT W.1 t then (.direction, s)
    else match oexact s W n with
      | none => (.noKey, s)
      | some c =>
        match oresolve s (t, W.2) n with
        | some d => (.seen d.scope, s)
        | none => (.ok, osetOwn (odelOwn s W n) (t, W.2) n c.val)

def orecord (W : Scope) (s : OState N V) : OState N V :=
  if isUserO W.2 = true ∧ W ∉ s.parts then { s with parts := s.parts ++ [W] } else s

def okstep (W : Scope) (op : WOp N V) (s : OState N V) : OWRep × OState N V :=
  match oconflict s W (checks op) with
  | some l => (.inuse l, s)
  | none => oapplyW W op (orecord W s)

def ofilter (P : Scope → Bool) (s : OState N V) : OState N V :=
  ⟨s.copies.filter (fun c => P c.scope), s.parts.filter P⟩

theorem orecord_copies (W : Scope) (s : OState N V) : (orecord W s).copies = s.copies := by
  unfold orecord
  split <;> rfl

theorem oexact_orecord (W w : Scope) (s : OState N V) (n : N) : oexact (orecord W s) w n = oexact s w n := by
  unfold oexact
  rw [orecord_copies]

theorem oresolve_orecord (W w : Scope) (s : OState N V) (n : N) : oresolve (orecord W s) w n = oresolve s w n :=
  oresolve_copies (orecord_copies W s) w n

theorem orecord_records {W : Scope} (hu : isUserO W.2 = true) (s : OState N V) : W ∈ (orecord W s).parts := by
  unfold orecord
  by_cases hw : W ∈ s.parts <;> simp [hu, hw]

theorem orecord_keeps {W p : Scope} {s : OState N V} (h : p ∈ s.parts) : p ∈ (orecord W s).parts := by
  unfold orecord
  split <;> simp [h]

theorem orecord_shared {W : Scope} (hu : isUserO W.2 = false) (s : OState N V) : orecord W s = s := by
  simp [orecord, hu]

theorem orecord_present {W : Scope} {s : OState N V} (hw : W ∈ s.parts) : orecord W s = s := by
  simp [orecord, hw]

theorem orecord_filter {P : Scope → Bool} {W : Scope} (hp : P W = true) (s : OState N V) :
    orecord W (ofilter P s) = ofilter P (orecord W s) := by
  unfold orecord ofilter
  have hm : (W ∈ s.parts.filter P) ↔ W ∈ s.parts := by simp [List.mem_filter, hp]
  by_cases hu : isUserO W.2 = true
  · by_cases hw : W ∈ s.parts
    · have : W ∈ s.parts.filter P := hm.2 hw
      simp [hu, hw, this]
    · have : W ∉ s.parts.filter P := fun e => hw (hm.1 e)
      simp [hu, hw, this, List.filter_append, hp]
  · simp [hu]

theorem orecord_filter_hidden {P : Scope → Bool} {W : Scope} (hp : P W = false) (s : OState N V) :
    ofilter P (orecord W s) = ofilter P s := by
  unfold orecord ofilter
  split
  · simp [List.filter_append, hp]
  · rfl

def oothers (W : Scope) (s : OState N V) : List (OCopy N V) := s.copies.filter (fun c => c.scope != W)

def OKeeps (P : Scope → Bool) (W : Scope) : Prop := P W = true ∧ ∀ d, seesP W d = true → P d = true

theorem keeps_restrict {R W : Scope} (hw : seesP R W = true) : OKeeps (seesP R) W :=
  ⟨hw, fun _ hd => seesP_trans hw hd⟩

theorem keeps_shared {P : Scope → Bool} {W : Scope} (h : OKeeps P W) : OKeeps P (W.1, .shared) := by
  refine ⟨h.2 _ (by rw [seesP_iff]; exact ⟨domT_refl _, odom_shared _⟩), fun d hd => h.2 d ?_⟩
  exact seesP_trans (by rw [seesP_iff]; exact ⟨domT_refl _, odom_shared _⟩) hd

theorem keeps_below {P : Scope → Bool} {W : Scope} {t : TLabel} (h : OKeeps P W) (ht : domT W.1 t = true) :
    OKeeps P (t, W.2) := by
  have hs : seesP W (t, W.2) = true := by rw [seesP_iff]; exact ⟨ht, odom_refl _⟩
  exact ⟨h.2 _ hs, fun d hd => h.2 d (seesP_trans hs hd)⟩

theorem oexact_filter {P : Scope → Bool} {W : Scope} (hp : P W = true) (s : OState N V) (n : N) :
    oexact (ofilter P s) W n = oexact s W n := by
  unfold oexact ofilter
  apply find_filter_of
  intro c hc
  simp only [Bool.and_eq_true, beq_iff_eq] at hc
  rw [hc.2]
  exact hp

theorem ocands_filter {P : Scope → Bool} {W : Scope} (h : OKeeps P W) (s : OState N V) (n : N) :
    ocands (ofilter P s) W n = ocands s W n := by
  unfold ocands ofilter
  apply filter_filter_of
  intro c hc
  simp only [Bool.and_eq_true] at hc
  exact h.2 _ hc.2

theorem oother_filter {P : Scope → Bool} {W : Scope} (h : OKeeps P W) (s : OState N V) (n : N) :
    oother (ofilter P s) W n = oother s W n := by
  unfold oother
  rw [oexact_filter (keeps_shared h).1, ocands_filter h]

theorem oresolve_filter {P : Scope → Bool} {W : Scope} (h : OKeeps P W) (s : OState N V) (n : N) :
    oresolve (ofilter P s) W n = oresolve s W n := by
  unfold oresolve
  rw [oexact_filter h.1, oother_filter h]

theorem oconflict_filter {P : Scope → Bool} {W : Scope} (h : OKeeps P W) (s : OState N V) :
    ∀ chk : List (N × Bool), oconflict (ofilter P s) W chk = oconflict s W chk
  | [] => rfl
  | (n, co) :: rest => by
    unfold oconflict
    rw [oexact_filter h.1, oother_filter h, oconflict_filter h s rest]

theorem filter_map_comm {α : Type} (f : α → α) (p : α → Bool) (hf : ∀ x, p (f x) = p x) (l : List α) :
    (l.map f).filter p = (l.filter p).map f := by
  induction l with
  | nil => rfl
  | cons x xs ih =>
    by_cases hx : p x = true
    · simp [List.filter, hf x, hx, ih]
    · have hx' : p x = false := by simpa using hx
      simp [List.filter, hf x, hx', ih]

theorem osetOwn_filter {P : Scope → Bool} {W : Scope} (hp : P W = true) (s : OState N V) (n : N) (v : V) :
    osetOwn (ofilter P s) W n v = ofilter P (osetOwn s W n v) := by
  unfold osetOwn
  rw [oexact_filter hp]
  split
  · unfold ofilter
    simp only [OState.mk.injEq, and_true]
    rw [filter_map_comm]
    intro c
    by_cases h : oisAt n W c = true <;> simp [h]
  · unfold ofilter
    simp only [OState.mk.injEq, List.filter_append]
    constructor
    · simp [hp]
    · have hmem : (W ∈ s.parts.filter P) ↔ W ∈ s.parts := by simp [List.mem_filter, hp]
      by_cases hw : W ∈ s.parts
      · have : W ∈ s.parts.filter P := hmem.2 hw
        simp [hw, this]
      · have : W ∉ s.parts.filter P := fun e => hw (hmem.1 e)
        simp [hw, this, List.filter_append, hp]

theorem osetOwn_filter_hidden {P : Scope → Bool} {W : Scope} (hp : P W = false) (s : OState N V) (n : N) (v : V) :
    ofilter P (osetOwn s W n v) = ofilter P s := by
  unfold osetOwn ofilter
  split
  · simp only [OState.mk.injEq, and_true]
    apply filter_map_keep
    · intro c hc
      have : c.scope ≠ W := fun e => by rw [e, hp] at hc; simp at hc
      have : oisAt n W c = false := by simp [oisAt, this]
      simp [this]
    · intro c
      by_cases h : oisAt n W c = true <;> simp [h]
  · simp only [OState.mk.injEq, List.filter_append]
    constructor
    · simp [hp]
    · split <;> simp [List.filter_append, hp]

theorem odelOwn_filter (P : Scope → Bool) (W : Scope) (s : OState N V) (n : N) :
    odelOwn (ofilter P s) W n = ofilter P (odelOwn s W n) := by
  unfold odelOwn ofilter
  simp only [OState.mk.injEq, and_true]
  rw [List.filter_filter, List.filter_filter]
  congr 1
  funext c
  exact Bool.and_comm _ _

theorem odelOwn_filter_hidden {P : Scope → Bool} {W : Scope} (hp : P W = false) (s : OState N V) (n : N) :
    ofilter P (odelOwn s W n) = ofilter P s := by
  unfold odelOwn ofilter
  simp only [OState.mk.injEq, and_true]
  rw [List.filter_filter]
  congr 1
  funext c
  by_cases h : P c.scope = true
  · have : c.scope ≠ W := fun e => by rw [e, hp] at h; simp at h
    simp [h, oisAt, this]
  · simp only [Bool.not_eq_true] at h
    simp [h]

theorem odelMany_filter {P : Scope → Bool} {W : Scope} (hp : P W = true) :
    ∀ (ns : List N) (s : OState N V),
      odelMany (ofilter P s) W ns = ((odelMany s W ns).1, ofilter P (odelMany s W ns).2)
  | [], _ => rfl
  | n :: ns, s => by
    unfold odelMany
    rw [oexact_filter hp]
    split
    · have ih := odelMany_filter hp ns (odelOwn s W n)
      rw [← odelOwn_filter] at ih
      simp only [ih]
    · exact odelMany_filter hp ns s

theorem odelMany_filter_hidden {P : Scope → Bool} {W : Scope} (hp : P W = false) :
    ∀ (ns : List N) (s : OState N V), ofilter P (odelMany s W ns).2 = ofilter P s
  | [], _ => rfl
  | n :: ns, s => by
    unfold odelMany
    split
    · simp only
      rw [odelMany_filter_hidden hp ns, odelOwn_filter_hidden hp]
    · exact odelMany_filter_hidden hp ns s

theorem osetMany_filter {P : Scope → Bool} {W : Scope} (hp : P W = true) :
    ∀ (kvs : List (N × V)) (s : OState N V), osetMany (ofilter P s) W kvs = ofilter P (osetMany s W kvs)
  | [], _ => rfl
  | p :: ps, s => by
    simp only [osetMany]
    rw [osetOwn_filter hp, osetMany_filter hp ps]

theorem osetMany_filter_hidden {P : Scope → Bool} {W : Scope} (hp : P W = false) :
    ∀ (kvs : List (N × V)) (s : OState N V), ofilter P (osetMany s W kvs) = ofilter P s
  | [], _ => rfl
  | p :: ps, s => by
    simp only [osetMany]
    rw [osetMany_filter_hidden hp ps, osetOwn_filter_hidden hp]

theorem oapplyW_filter {P : Scope → Bool} {W : Scope} (h : OKeeps P W) (op : WOp N V) (s : OState N V) :
    oapplyW W op (ofilter P s) = ((oapplyW W op s).1, ofilter P (oapplyW W op s).2) := by
    cases op with
    | put n v => simp only [oapplyW, osetOwn_filter h.1]
    | del ns =>
      simp only [oapplyW]
      rw [odelMany_filter h.1]
    | createOnly n v =>
      simp only [oapplyW, oresolve_filter h]
      split
      · rfl
      · simp only [osetOwn_filter h.1]
    | createMany kvs =>
      simp only [oapplyW, oresolve_filter h]
      split
      · rfl
      · simp only [osetMany_filter h.1]
    | renameNx a b =>
      simp only [oapplyW, oexact_filter h.1, oresolve_filter h]
      split
      · rfl
      · split
        · rfl
        · simp only [osetOwn_filter h.1, odelOwn_filter]
    | copyNx a b =>
      simp only [oapplyW, oresolve_filter h]
      split
      · rfl
      · split
        · rfl
        · simp only [osetOwn_filter h.1]
    | declassify n t =>
      simp only [oapplyW]
      split
      · rfl
      · rename_i hdir
        have ht : domT W.1 t = true := by
          simp only [Bool.or_eq_true, beq_iff_eq, Bool.not_eq_true', not_or, Bool.not_eq_false] at hdir
          exact hdir.2
        have hk := keeps_below h ht
        rw [oexact_filter h.1, oresolve_filter hk]
        split
        · rfl
        · split
          · rfl
          · simp only [osetOwn_filter hk.1, odelOwn_filter]

theorem oapplyW_filter_hidden {P : Scope → Bool} {W : Scope} (hp : P W = false) {op : WOp N V}
    (hd : ∀ n t, op = .declassify n t → P (t, W.2) = false) (s : OState N V) :
    ofilter P (oapplyW W op s).2 = ofilter P s := by
    cases op with
    | put n v => exact osetOwn_filter_hidden hp s n v
    | del ns => exact odelMany_filter_hidden hp ns s
    | createOnly n v =>
      simp only [oapplyW]
      split
      · rfl
      · exact osetOwn_filter_hidden hp s n v
    | createMany kvs =>
      simp only [oapplyW]
      split
      · rfl
      · exact osetMany_filter_hidden hp kvs s
    | renameNx a b =>
      simp only [oapplyW]
      split
      · rfl
      · split
        · rfl
        · simp only
          rw [osetOwn_filter_hidden hp, odelOwn_filter_hidden hp]
    | copyNx a b =>
      simp only [oapplyW]
      split
      · rfl
      · split
        · rfl
        · exact osetOwn_filter_hidden hp s b _
    | declassify n t =>
      simp only [oapplyW]
      split
      · rfl
      · split
        · rfl
        · split
          · rfl
          · simp only
            rw [osetOwn_filter_hidden (hd n t rfl), odelOwn_filter_hidden hp]

theorem okstep_filter {P : Scope → Bool} {W : Scope} (h : OKeeps P W) (op : WOp N V) (s : OState N V) :
    okstep W op (ofilter P s) = ((okstep W op s).1, ofilter P (okstep W op s).2) := by
  unfold okstep
  rw [oconflict_filter h]
  split
  · rfl
  · rw [orecord_filter h.1, oapplyW_filter h]

theorem okstep_filter_hidden {P : Scope → Bool} {W : Scope} (hp : P W = false) {op : WOp N V}
    (hd : ∀ n t, op = .declassify n t → P (t, W.2) = false) (s : OState N V) :
    ofilter P (okstep W op s).2 = ofilter P s := by
  unfold okstep
  split
  · rfl
  · rw [oapplyW_filter_hidden hp hd, orecord_filter_hidden hp]

theorem okstep_others {W : Scope} {op : WOp N V} (hd : NotDecl op) (s : OState N V) :
    oothers W (okstep W op s).2 = oothers W s := by
  have := okstep_filter_hidden (P := fun d => d != W) (W := W) (by simp)
    (fun n t e => by rw [e] at hd; exact hd.elim) s (op := op)
  unfold ofilter at this
  unfold oothers
  exact congrArg OState.copies this

theorem oexact_osetOwn (s : OState N V) (W : Scope) (n : N) (v : V) :
    oexact (osetOwn s W n v) W n = some ⟨n, W, v⟩ := by
  unfold osetOwn
  split
  · rename_i c hc
    obtain ⟨_, hn, hl⟩ := oexact_some hc
    unfold oexact at hc ⊢
    simp only
    rw [List.find?_map]
    have : ((fun c => c.name == n && c.scope == W) ∘ fun c => if oisAt n W c then { c with val := v } else c) =
        fun c => c.name == n && c.scope == W := by
      funext d
      simp only [Function.comp]
      by_cases h : oisAt n W d = true
      · simp [h]
      · simp [h]
    rw [this, hc]
    simp only [Option.map_some, Option.some.injEq]
    have h1 : oisAt n W c = true := by simp [oisAt, hn, hl]
    simp only [h1, ↓reduceIte]
    rw [← hn, ← hl]
  · rename_i hc
    unfold oexact at hc ⊢
    simp only
    rw [List.find?_append, hc]
    simp

theorem oput_lands {W : Scope} {n : N} {v : V} {s s' : OState N V} (h : okstep W (.put n v) s = (.ok, s')) :
    oexact s' W n = some ⟨n, W, v⟩ ∧ oothers W s' = oothers W s := by
  have ho := okstep_others (W := W) (op := .put n v) trivial s
  rw [h] at ho
  unfold okstep at h
  split at h
  · simp at h
  · simp only [oapplyW, Prod.mk.injEq, true_and] at h
    subst h
    exact ⟨oexact_osetOwn _ W n v, ho⟩

theorem oexact_odelOwn (s : OState N V) (W : Scope) (n : N) : oexact (odelOwn s W n) W n = none := by
  unfold oexact odelOwn
  apply List.find?_eq_none.2
  intro c hc
  have := (List.mem_filter.1 hc).2
  simp only [oisAt, Bool.not_and, Bool.or_eq_true, Bool.not_eq_true', beq_eq_false_iff_ne, ne_eq] at this
  simp only [Bool.and_eq_true, beq_iff_eq, not_and]
  intro hn hl
  rcases this with h | h
  · exact h hn
  · exact h hl

theorem odel_lands {W : Scope} {n : N} {s : OState N V} (hs : (oexact s W n).isSome) :
    (okstep W (.del [n]) s).1 = .count 1 ∧ oexact (okstep W (.del [n]) s).2 W n = none := by
  unfold okstep
  have : oconflict s W (checks (WOp.del [n] : WOp N V)) = none := by
    simp only [checks, List.map_cons, List.map_nil, oconflict]
    cases hx : oexact s W n with
    | none => rw [hx] at hs; simp at hs
    | some _ => simp
  rw [this]
  simp only [oapplyW, odelMany, oexact_orecord]
  cases hx : oexact s W n with
  | none => rw [hx] at hs; simp at hs
  | some _ => exact ⟨rfl, oexact_odelOwn _ W n⟩

theorem oother_ne {s : OState N V} {W : Scope} {n : N} {c : OCopy N V} (ho : oexact s W n = none)
    (h : oother s W n = some c) : c.scope ≠ W ∧ c ∈ s.copies ∧ c.name = n ∧ seesP W c.scope = true := by
  obtain ⟨h1, h2, h3⟩ := oother_visible h
  refine ⟨fun e => oexact_none ho c h1 h2 e, h1, h2, h3⟩

theorem oconflict_spec {s : OState N V} {W : Scope} :
    ∀ {chk : List (N × Bool)} {l : Scope}, oconflict s W chk = some l →
      ∃ n c, (n, false) ∈ chk ∧ oexact s W n = none ∧ oother s W n = some c ∧ c.scope = l
  | [], _, h => by simp [oconflict] at h
  | (n, co) :: rest, l, h => by
    unfold oconflict at h
    split at h
    · rename_i hc
      simp only [Bool.and_eq_true, Option.isNone_iff_eq_none, Bool.not_eq_true'] at hc
      split at h
      · rename_i c hoc
        simp only [Option.some.injEq] at h
        refine ⟨n, c, ?_, hc.1, hoc, h⟩
        rw [← hc.2]
        exact List.mem_cons_self
      · obtain ⟨m, c, h1, h2, h3, h4⟩ := oconflict_spec h
        exact ⟨m, c, List.mem_cons_of_mem _ h1, h2, h3, h4⟩
    · obtain ⟨m, c, h1, h2, h3, h4⟩ := oconflict_spec h
      exact ⟨m, c, List.mem_cons_of_mem _ h1, h2, h3, h4⟩

theorem oapplyW_not_inuse (W : Scope) (op : WOp N V) (s : OState N V) (l : Scope) : (oapplyW W op s).1 ≠ .inuse l := by
  cases op with
  | put n v => simp [oapplyW]
  | del ns => simp [oapplyW]
  | createOnly n v => simp only [oapplyW]; split <;> simp
  | createMany kvs => simp only [oapplyW]; split <;> simp
  | renameNx a b =>
    simp only [oapplyW]
    split
    · simp
    · split <;> simp
  | copyNx a b =>
    simp only [oapplyW]
    split
    · simp
    · split <;> simp
  | declassify n t =>
    simp only [oapplyW]
    split
    · simp
    · split
      · simp
      · split <;> simp

theorem oinuse_visible {W l : Scope} {op : WOp N V} {s s' : OState N V} (h : okstep W op s = (.inuse l, s')) :
    s' = s ∧ ∃ n c, (n, false) ∈ checks op ∧ oexact s W n = none ∧ c ∈ s.copies ∧ c.name = n ∧ c.scope = l ∧
      l ≠ W ∧ seesP W l = true := by
  unfold okstep at h
  split at h
  · rename_i l' hc
    simp only [Prod.mk.injEq, OWRep.inuse.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    obtain ⟨n, c, h1, h2, h3, h4⟩ := oconflict_spec hc
    obtain ⟨m1, m2, m3, m4⟩ := oother_ne h2 h3
    refine ⟨rfl, n, c, h1, h2, m2, m3, h4, h4 ▸ m1, h4 ▸ m4⟩
  · exact absurd (congrArg Prod.fst h) (oapplyW_not_inuse W op _ l)

theorem oinuse_names_resolved {W l : Scope} {op : WOp N V} {s s' : OState N V} (h : okstep W op s = (.inuse l, s')) :
    ∃ n c, (n, false) ∈ checks op ∧ oexact s W n = none ∧ oresolve s W n = some c ∧ c.scope = l := by
  unfold okstep at h
  split at h
  · rename_i l' hc
    simp only [Prod.mk.injEq, OWRep.inuse.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    obtain ⟨n, c, h1, h2, h3, h4⟩ := oconflict_spec hc
    exact ⟨n, c, h1, h2, by simp [oresolve, h2, h3], h4⟩
  · exact absurd (congrArg Prod.fst h) (oapplyW_not_inuse W op _ l)

theorem oinuse_owner {W l : Scope} {op : WOp N V} {s s' : OState N V} (hw : W.2 ≠ .every)
    (h : okstep W op s = (.inuse l, s')) : l.2 = .shared ∨ l.2 = W.2 := by
  obtain ⟨_, _, _, _, _, _, _, _, _, hv⟩ := oinuse_visible h
  exact odom_concrete hw ((seesP_iff _ _).1 hv).2

theorem shared_writer_blind {W l : Scope} {op : WOp N V} {s s' : OState N V} (hw : W.2 = .shared)
    (h : okstep W op s = (.inuse l, s')) : l.2 = .shared := by
  rcases oinuse_owner (by rw [hw]; simp) h with e | e
  · exact e
  · rw [e, hw]

theorem shared_reader_blind {s : OState N V} {r : TLabel} {n : N} {c : OCopy N V}
    (h : oresolve s (r, .shared) n = some c) : c.scope.2 = .shared := by
  rcases oresolve_owner (by simp) h with e | e <;> exact e

theorem ocreateOnly_exists {W : Scope} {n : N} {v : V} {s : OState N V} (h : (oresolve s W n).isSome = true) :
    okstep W (.createOnly n v) s = (.exists, orecord W s) := by
  simp [okstep, checks, oconflict, oapplyW, oresolve_orecord, h]

theorem ocreateOnly_creates {W : Scope} {n : N} {v : V} {s : OState N V} (h : oresolve s W n = none) :
    okstep W (.createOnly n v) s = (.ok, osetOwn (orecord W s) W n v) := by
  simp [okstep, checks, oconflict, oapplyW, oresolve_orecord, h]

theorem ocreateOnly_never_inuse (W : Scope) (n : N) (v : V) (s : OState N V) (l : Scope) :
    okstep W (.createOnly n v) s ≠ (.inuse l, s) := by
  intro h
  obtain ⟨_, m, _, h1, _, _⟩ := oinuse_visible h
  simp [checks] at h1

theorem odeclassify_keeps_owner {W : Scope} {n : N} {t : TLabel} {s s' : OState N V}
    (h : okstep W (.declassify n t) s = (.ok, s')) :
    ∃ c, oexact s W n = some c ∧ t ≠ W.1 ∧ domT W.1 t = true ∧ oresolve s (t, W.2) n = none ∧
      s' = osetOwn (odelOwn (orecord W s) W n) (t, W.2) n c.val := by
  unfold okstep at h
  split at h
  · simp at h
  · simp only [oapplyW] at h
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
          rw [oexact_orecord] at hc
          rw [oresolve_orecord] at hr
          exact ⟨c, hc, hdir.1, hdir.2, hr, h.symm⟩

theorem osetOwn_parts_keep {W p : Scope} {s : OState N V} (n : N) (v : V) (h : p ∈ s.parts) :
    p ∈ (osetOwn s W n v).parts := by
  unfold osetOwn
  split
  · exact h
  · simp only
    split <;> simp [h]

theorem odelMany_parts_keep {W p : Scope} : ∀ (ns : List N) (s : OState N V), p ∈ s.parts → p ∈ (odelMany s W ns).2.parts
  | [], _, h => h
  | n :: ns, s, h => by
    unfold odelMany
    split
    · exact odelMany_parts_keep ns _ h
    · exact odelMany_parts_keep ns s h

theorem osetMany_parts_keep {W p : Scope} : ∀ (kvs : List (N × V)) (s : OState N V), p ∈ s.parts →
    p ∈ (osetMany s W kvs).parts
  | [], _, h => h
  | q :: qs, s, h => by
    simp only [osetMany]
    exact osetMany_parts_keep qs _ (osetOwn_parts_keep _ _ h)

theorem oapplyW_parts_keep {W p : Scope} (op : WOp N V) {s : OState N V} (h : p ∈ s.parts) :
    p ∈ (oapplyW W op s).2.parts := by
  cases op with
  | put n v => exact osetOwn_parts_keep n v h
  | del ns => exact odelMany_parts_keep ns s h
  | createOnly n v =>
    simp only [oapplyW]
    split
    · exact h
    · exact osetOwn_parts_keep n v h
  | createMany kvs =>
    simp only [oapplyW]
    split
    · exact h
    · exact osetMany_parts_keep kvs s h
  | renameNx a b =>
    simp only [oapplyW]
    split
    · exact h
    · split
      · exact h
      · exact osetOwn_parts_keep _ _ h
  | copyNx a b =>
    simp only [oapplyW]
    split
    · exact h
    · split
      · exact h
      · exact osetOwn_parts_keep _ _ h
  | declassify n t =>
    simp only [oapplyW]
    split
    · exact h
    · split
      · exact h
      · split
        · exact h
        · exact osetOwn_parts_keep _ _ h

theorem okstep_parts_keep {W p : Scope} (op : WOp N V) {s : OState N V} (h : p ∈ s.parts) :
    p ∈ (okstep W op s).2.parts := by
  unfold okstep
  split
  · exact h
  · exact oapplyW_parts_keep op (orecord_keeps h)

theorem okstep_records {W : Scope} {op : WOp N V} {s : OState N V} (hc : oconflict s W (checks op) = none)
    (hu : isUserO W.2 = true) : W ∈ (okstep W op s).2.parts := by
  unfold okstep
  rw [hc]
  exact oapplyW_parts_keep op (orecord_records hu s)

structure FlushCtx where
  labelTop : Bool
  operator : Bool
  named : Bool

def everything (W : Scope) (f : FlushCtx) : Bool := f.labelTop && f.operator && !isUserO W.2 && !f.named

def flushHits (W : Scope) (f : FlushCtx) (d : Scope) : Bool :=
  everything W f || (d.2 == W.2 && (f.labelTop || d.1 == W.1))

def oflush (W : Scope) (f : FlushCtx) (s : OState N V) : OState N V :=
  { s with copies := s.copies.filter (fun c => !flushHits W f c.scope) }

theorem oflush_mem {W : Scope} {f : FlushCtx} {s : OState N V} {c : OCopy N V} :
    c ∈ (oflush W f s).copies ↔ c ∈ s.copies ∧ flushHits W f c.scope = false := by
  simp [oflush, List.mem_filter]

theorem oflush_within {W : Scope} {f : FlushCtx} {s : OState N V} {c : OCopy N V} (he : everything W f = false)
    (hc : c ∈ s.copies) (hr : c ∉ (oflush W f s).copies) :
    c.scope.2 = W.2 ∧ (f.labelTop = true ∨ c.scope.1 = W.1) := by
  have : flushHits W f c.scope = true := by
    cases hh : flushHits W f c.scope with
    | true => rfl
    | false => exact absurd (oflush_mem.2 ⟨hc, hh⟩) hr
  simp only [flushHits, he, Bool.false_or, Bool.and_eq_true, beq_iff_eq, Bool.or_eq_true] at this
  exact this

theorem oflush_seen {W : Scope} {f : FlushCtx} {s : OState N V} {c : OCopy N V}
    (htop : f.labelTop = true → domT W.1 c.scope.1 = true) (he : everything W f = false)
    (hc : c ∈ s.copies) (hr : c ∉ (oflush W f s).copies) : seesP W c.scope = true := by
  obtain ⟨h1, h2⟩ := oflush_within he hc hr
  rw [seesP_iff, h1]
  refine ⟨?_, odom_refl _⟩
  rcases h2 with h | h
  · exact htop h
  · rw [h]; exact domT_refl _

theorem oflush_other_owner {W : Scope} {f : FlushCtx} {s : OState N V} {c : OCopy N V} (hc : c ∈ s.copies)
    (hr : c ∉ (oflush W f s).copies) (ho : c.scope.2 ≠ W.2) :
    f.labelTop = true ∧ f.operator = true ∧ isUserO W.2 = false ∧ f.named = false := by
  cases he : everything W f with
  | false => exact absurd (oflush_within he hc hr).1 ho
  | true =>
    simp only [everything, Bool.and_eq_true, Bool.not_eq_true'] at he
    exact ⟨he.1.1.1, he.1.1.2, he.1.2, he.2⟩

theorem oflush_named_narrows {W : Scope} {f : FlushCtx} (h : f.named = true) : everything W f = false := by
  simp [everything, h]

theorem oflush_user_own {W : Scope} {f : FlushCtx} (h : isUserO W.2 = true) : everything W f = false := by
  simp [everything, h]

theorem oflush_below_top {W : Scope} {f : FlushCtx} {s : OState N V} {c : OCopy N V} (ht : f.labelTop = false)
    (hc : c ∈ s.copies) (hr : c ∉ (oflush W f s).copies) : c.scope = W := by
  have he : everything W f = false := by simp [everything, ht]
  obtain ⟨h1, h2⟩ := oflush_within he hc hr
  rcases h2 with h | h
  · rw [ht] at h; exact absurd h (by decide)
  · exact Prod.ext h h1

theorem oflush_everything {W : Scope} {f : FlushCtx} (s : OState N V) (h : everything W f = true) :
    (oflush W f s).copies = [] := by
  simp [oflush, flushHits, h]

theorem oflush_keeps {W : Scope} {f : FlushCtx} {s : OState N V} {c : OCopy N V} (hc : c ∈ s.copies)
    (hk : flushHits W f c.scope = false) : c ∈ (oflush W f s).copies :=
  oflush_mem.2 ⟨hc, hk⟩

theorem oflush_filter (P : Scope → Bool) (W : Scope) (f : FlushCtx) (s : OState N V) :
    oflush W f (ofilter P s) = ofilter P (oflush W f s) := by
  unfold oflush ofilter
  simp only [OState.mk.injEq, and_true]
  rw [List.filter_filter, List.filter_filter]
  congr 1
  funext c
  exact Bool.and_comm _ _

theorem oflush_filter_hidden {P : Scope → Bool} {W : Scope} {f : FlushCtx} (he : everything W f = false)
    (hp : ∀ d, d.2 = W.2 → (f.labelTop = true ∨ d.1 = W.1) → P d = false) (s : OState N V) :
    ofilter P (oflush W f s) = ofilter P s := by
  unfold oflush ofilter
  simp only [OState.mk.injEq, and_true]
  rw [List.filter_filter]
  congr 1
  funext c
  cases hc : P c.scope with
  | false => simp
  | true =>
    have : flushHits W f c.scope = false := by
      cases hh : flushHits W f c.scope with
      | false => rfl
      | true =>
        simp only [flushHits, he, Bool.false_or, Bool.and_eq_true, beq_iff_eq, Bool.or_eq_true] at hh
        rw [hp c.scope hh.1 hh.2] at hc
        exact absurd hc (by decide)
    simp [this]

def oforget (o : Owner) (s : OState N V) : OState N V :=
  ⟨s.copies.filter (fun c => c.scope.2 != o), s.parts.filter (fun p => p.2 != o)⟩

theorem oforget_filter (P : Scope → Bool) (o : Owner) (s : OState N V) :
    oforget o (ofilter P s) = ofilter P (oforget o s) := by
  unfold oforget ofilter
  simp only [OState.mk.injEq]
  constructor <;> rw [List.filter_filter, List.filter_filter] <;> congr 1 <;> funext x <;> exact Bool.and_comm _ _

theorem oforget_as_filter (o : Owner) (s : OState N V) : oforget o s = ofilter (fun d => d.2 != o) s := rfl

theorem arrival_flush_everything_iff (t op n : Bool) (l : TLabel) (o : Owner) :
    everything (l, o) ⟨t, op, n⟩ = true ↔ t = true ∧ op = true ∧ isUserO o = false ∧ n = false := by
  simp [everything, and_assoc]

theorem arrival_named_flush_narrows {r : ORules} {oc oc' : OConn} {m : Bool} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {tok : Option TokOwner} {o x : Owner}
    (h : ownerPhase r oc m inner t pick ctx tok = .ok (o, oc')) (hc : credential r pick ctx tok = .ok (some x))
    (l : TLabel) : everything (l, o) ⟨t, r.operator, oc'.named⟩ = false :=
  oflush_named_narrows (named_of_credential h hc)

theorem arrival_user_flush_own (t op n : Bool) (l : TLabel) (u : List Nat) :
    everything (l, .user u) ⟨t, op, n⟩ = false :=
  oflush_user_own rfl

theorem arrival_multi_named_narrows {r : ORules} {oc oc' : OConn} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {tok : Option TokOwner} {o : Owner}
    (h : ownerPhase r oc true inner t pick ctx tok = .ok (o, oc')) (hn : oc.named = true) (l : TLabel) :
    everything (l, o) ⟨t, r.operator, oc'.named⟩ = false :=
  oflush_named_narrows (named_sticky_in_multi h hn)

theorem token_operator_flush_everything {r : ORules} {oc oc' : OConn} {inner : List Arg} {pick : Pick}
    {ctx : Option Owner} {o : Owner} (h : ownerPhase r oc false inner true pick ctx (some .none) = .ok (o, oc'))
    (hk : r.kind = .none) (hop : r.operator = true) (l : TLabel) :
    everything (l, o) ⟨true, r.operator, oc'.named⟩ = true := by
  obtain ⟨_, named, hc, hr, _, _, _⟩ := ownerPhase_ok h
  have hn : named = none := credTok_none (by simpa [credential] using hc)
  subst hn
  have ho : o = .shared := by
    simp only [resolveOwner, Bool.false_eq_true, ↓reduceIte, hk] at hr
    simp only [Except.ok.injEq] at hr
    exact hr.symm
  subst ho
  rw [arrival_flush_everything_iff]
  exact ⟨rfl, hop, rfl, token_without_owner_unnamed h⟩

theorem implicit_operator_flush_everything {r : ORules} {oc oc' : OConn} {inner : List Arg} {o : Owner}
    (h : ownerPhase r oc false inner true .none none none = .ok (o, oc')) (hk : r.kind = .none)
    (hop : r.operator = true) (l : TLabel) : everything (l, o) ⟨true, r.operator, oc'.named⟩ = true := by
  obtain ⟨_, named, hc, hr, _, _, _⟩ := ownerPhase_ok h
  have hn : named = none := by simpa [credential, credPick] using hc.symm
  subst hn
  have ho : o = .shared := by
    simp only [resolveOwner, Bool.false_eq_true, ↓reduceIte, hk] at hr
    simp only [Except.ok.injEq] at hr
    exact hr.symm
  subst ho
  rw [arrival_flush_everything_iff]
  exact ⟨rfl, hop, rfl, implicit_owner_unnamed h⟩

end OwnerKeyWrites

end Labels
