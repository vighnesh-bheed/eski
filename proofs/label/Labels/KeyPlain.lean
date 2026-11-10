import Labels.KeyPurge

namespace Labels

section KeyPlain
set_option linter.unusedSectionVars false
variable {N V : Type} [DecidableEq N]

def keysLabelled (levels comps trusts : Nat) : Bool := decide (1 < levels) || decide (0 < comps) || decide (1 < trusts)

theorem single_level_unlabelled {levels comps trusts : Nat} (hl : levels ≤ 1) (hc : comps = 0) (ht : trusts ≤ 1) :
    keysLabelled levels comps trusts = false := by
  simp [keysLabelled]
  omega

theorem single_level_one_label {levels comps trusts : Nat} (hl : levels ≤ 1) (hc : comps = 0) (ht : trusts ≤ 1)
    {l : TLabel} (h : ValidT levels comps trusts l) : l = tbottom := by
  obtain ⟨⟨h1, h2⟩, h3⟩ := h
  subst hc
  simp only [Nat.pow_zero] at h2
  unfold trustCount at h3
  have : l.trust = 0 := by omega
  have hlev : l.sec.level = 0 := by omega
  have hcomp : l.sec.comps = 0 := by omega
  cases l with
  | mk sec trust =>
    cases sec with
    | mk level comps =>
      simp only at this hlev hcomp
      subst this hlev hcomp
      rfl

def AllAt (L : TLabel) (s : KState N V) : Prop := ∀ c ∈ s.copies, c.label = L

def plainOf (s : KState N V) : List (N × V) := s.copies.map (fun c => (c.name, c.val))

def plook (ps : List (N × V)) (n : N) : Option V := (ps.find? (fun p => p.1 == n)).map (·.2)

def pset (ps : List (N × V)) (n : N) (v : V) : List (N × V) :=
  if (plook ps n).isSome then ps.map (fun p => if p.1 == n then (n, v) else p) else ps ++ [(n, v)]

def pdel (ps : List (N × V)) (n : N) : List (N × V) := ps.filter (fun p => p.1 != n)

def pdelMany (ps : List (N × V)) : List N → Nat × List (N × V)
  | [] => (0, ps)
  | n :: ns =>
    if (plook ps n).isSome then ((pdelMany (pdel ps n) ns).1 + 1, (pdelMany (pdel ps n) ns).2)
    else pdelMany ps ns

def psetMany (ps : List (N × V)) : List (N × V) → List (N × V)
  | [] => ps
  | p :: kvs => psetMany (pset ps p.1 p.2) kvs

def pstep : WOp N V → List (N × V) → WRep × List (N × V)
  | .put n v, ps => (.ok, pset ps n v)
  | .del ns, ps => (.count (pdelMany ps ns).1, (pdelMany ps ns).2)
  | .createOnly n v, ps => if (plook ps n).isSome then (.exists, ps) else (.ok, pset ps n v)
  | .createMany kvs, ps => if kvs.any (fun p => (plook ps p.1).isSome) then (.exists, ps) else (.ok, psetMany ps kvs)
  | .renameNx a b, ps =>
    match plook ps a with
    | none => (.noKey, ps)
    | some v => if (plook ps b).isSome then (.exists, ps) else (.ok, pset (pdel ps a) b v)
  | .copyNx a b, ps =>
    match plook ps a with
    | none => (.count 0, ps)
    | some v => if (plook ps b).isSome then (.exists, ps) else (.ok, pset ps b v)
  | .declassify _ _, ps => (.direction, ps)

theorem find_congr_on {α : Type} {p q : α → Bool} : ∀ {l : List α}, (∀ x ∈ l, p x = q x) → l.find? p = l.find? q
  | [], _ => rfl
  | x :: xs, h => by
    have hx := h x List.mem_cons_self
    have ih := find_congr_on (l := xs) (fun y hy => h y (List.mem_cons_of_mem _ hy))
    simp only [List.find?, hx, ih]

theorem allAt_isAt {L : TLabel} {s : KState N V} (h : AllAt L s) (n : N) :
    ∀ c ∈ s.copies, isAt n L c = (c.name == n) := by
  intro c hc
  simp [isAt, h c hc]

theorem ownOf_allAt {L : TLabel} {s : KState N V} (h : AllAt L s) (n : N) :
    (ownOf s L n).map (·.val) = plook (plainOf s) n := by
  unfold ownOf plook plainOf
  rw [List.find?_map]
  have : s.copies.find? (fun c => c.name == n && c.label == L) =
      s.copies.find? ((fun p : N × V => p.1 == n) ∘ fun c => (c.name, c.val)) := by
    apply find_congr_on
    intro c hc
    simp [h c hc]
  rw [this]
  cases s.copies.find? ((fun p : N × V => p.1 == n) ∘ fun c => (c.name, c.val)) <;> rfl

theorem cands_allAt {L : TLabel} {s : KState N V} (h : AllAt L s) (n : N) : cands s L n = [] := by
  unfold cands
  apply List.eq_nil_iff_forall_not_mem.2
  intro c hc
  have := (List.mem_filter.1 hc)
  simp [h c this.1] at this

theorem resolve_allAt {L : TLabel} {s : KState N V} (h : AllAt L s) (n : N) : resolve s L n = ownOf s L n := by
  unfold resolve other
  rw [cands_allAt h]
  cases ownOf s L n <;> rfl

theorem conflict_allAt {L : TLabel} {s : KState N V} (h : AllAt L s) :
    ∀ chk : List (N × Bool), conflict s L chk = none
  | [] => rfl
  | (n, co) :: rest => by
    unfold conflict
    have ho : other s L n = none := by unfold other; rw [cands_allAt h]; rfl
    rw [ho, conflict_allAt h rest]
    split <;> rfl

theorem setOwn_allAt {L : TLabel} {s : KState N V} (h : AllAt L s) (n : N) (v : V) : AllAt L (setOwn s L n v) := by
  unfold setOwn AllAt
  split
  · intro c hc
    obtain ⟨d, hd, rfl⟩ := List.mem_map.1 hc
    split <;> exact h d hd
  · intro c hc
    rcases List.mem_append.1 hc with hc | hc
    · exact h c hc
    · simp at hc
      rw [hc]

theorem delOwn_allAt {L : TLabel} {s : KState N V} (h : AllAt L s) (n : N) : AllAt L (delOwn s L n) := by
  intro c hc
  exact h c (List.mem_filter.1 hc).1

theorem plook_isSome {L : TLabel} {s : KState N V} (h : AllAt L s) (n : N) :
    (ownOf s L n).isSome = (plook (plainOf s) n).isSome := by
  rw [← ownOf_allAt h n]
  cases ownOf s L n <;> rfl

theorem setOwn_plain {L : TLabel} {s : KState N V} (h : AllAt L s) (n : N) (v : V) :
    plainOf (setOwn s L n v) = pset (plainOf s) n v := by
  unfold setOwn pset
  have hs := plook_isSome h n
  split
  · rename_i c hc
    have : (plook (plainOf s) n).isSome = true := by rw [← hs, hc]; rfl
    simp only [this, ↓reduceIte]
    unfold plainOf
    simp only [List.map_map]
    apply List.map_congr_left
    intro d hd
    simp only [Function.comp]
    rw [allAt_isAt h n d hd]
    by_cases hn : d.name = n
    · simp [hn]
    · simp [hn]
  · rename_i hc
    have : ¬(plook (plainOf s) n).isSome = true := by rw [← hs, hc]; simp
    simp only [this, Bool.false_eq_true, ↓reduceIte]
    simp [plainOf]

theorem delOwn_plain {L : TLabel} {s : KState N V} (h : AllAt L s) (n : N) :
    plainOf (delOwn s L n) = pdel (plainOf s) n := by
  unfold delOwn pdel plainOf
  simp only
  rw [List.filter_map]
  congr 1
  apply List.filter_congr
  intro c hc
  simp only [Function.comp]
  rw [allAt_isAt h n c hc]
  simp [bne]

theorem delMany_plain {L : TLabel} : ∀ (ns : List N) (s : KState N V), AllAt L s →
    (delMany s L ns).1 = (pdelMany (plainOf s) ns).1 ∧ plainOf (delMany s L ns).2 = (pdelMany (plainOf s) ns).2 ∧
      AllAt L (delMany s L ns).2
  | [], _, h => ⟨rfl, rfl, h⟩
  | n :: ns, s, h => by
    unfold delMany pdelMany
    have hs := plook_isSome h n
    split
    · rename_i c hc
      have : (plook (plainOf s) n).isSome = true := by rw [← hs, hc]; rfl
      simp only [this, ↓reduceIte]
      obtain ⟨i1, i2, i3⟩ := delMany_plain ns (delOwn s L n) (delOwn_allAt h n)
      rw [delOwn_plain h n] at i1 i2
      exact ⟨by rw [i1], i2, i3⟩
    · rename_i hc
      have : ¬(plook (plainOf s) n).isSome = true := by rw [← hs, hc]; simp
      simp only [this, Bool.false_eq_true, ↓reduceIte]
      exact delMany_plain ns s h

theorem setMany_plain {L : TLabel} : ∀ (kvs : List (N × V)) (s : KState N V), AllAt L s →
    plainOf (setMany s L kvs) = psetMany (plainOf s) kvs ∧ AllAt L (setMany s L kvs)
  | [], _, h => ⟨rfl, h⟩
  | p :: ps, s, h => by
    simp only [setMany, psetMany]
    have := setMany_plain ps (setOwn s L p.1 p.2) (setOwn_allAt h p.1 p.2)
    rw [setOwn_plain h] at this
    exact this

theorem resolve_val_plain {L : TLabel} {s : KState N V} (h : AllAt L s) (n : N) :
    (resolve s L n).isSome = (plook (plainOf s) n).isSome := by
  rw [resolve_allAt h n, plook_isSome h n]

theorem plain_step {L : TLabel} {s : KState N V} (h : AllAt L s) {op : WOp N V} (hd : NotDecl op) :
    (kstep L op s).1 = (pstep op (plainOf s)).1 ∧ plainOf (kstep L op s).2 = (pstep op (plainOf s)).2 ∧
      AllAt L (kstep L op s).2 := by
  unfold kstep
  rw [conflict_allAt h]
  simp only
  cases op with
  | put n v => exact ⟨rfl, setOwn_plain h n v, setOwn_allAt h n v⟩
  | del ns =>
    obtain ⟨i1, i2, i3⟩ := delMany_plain ns s h
    exact ⟨by simp only [applyW, pstep]; rw [i1], i2, i3⟩
  | createOnly n v =>
    simp only [applyW, pstep]
    rw [resolve_allAt h n, plook_isSome h n]
    split
    · exact ⟨rfl, rfl, h⟩
    · exact ⟨rfl, setOwn_plain h n v, setOwn_allAt h n v⟩
  | createMany kvs =>
    simp only [applyW, pstep]
    have hany : kvs.any (fun p => (resolve s L p.1).isSome) = kvs.any (fun p => (plook (plainOf s) p.1).isSome) := by
      congr 1
      funext p
      exact resolve_val_plain h p.1
    rw [hany]
    split
    · exact ⟨rfl, rfl, h⟩
    · obtain ⟨i1, i2⟩ := setMany_plain kvs s h
      exact ⟨rfl, i1, i2⟩
  | renameNx a b =>
    simp only [applyW, pstep]
    have ha := ownOf_allAt h a
    cases ho : ownOf s L a with
    | none =>
      rw [ho] at ha
      simp only [Option.map_none] at ha
      rw [← ha]
      exact ⟨rfl, rfl, h⟩
    | some c =>
      rw [ho] at ha
      simp only [Option.map_some] at ha
      rw [← ha]
      simp only
      rw [resolve_val_plain h b]
      split
      · exact ⟨rfl, rfl, h⟩
      · refine ⟨rfl, ?_, setOwn_allAt (delOwn_allAt h a) b c.val⟩
        rw [setOwn_plain (delOwn_allAt h a), delOwn_plain h a]
  | copyNx a b =>
    simp only [applyW, pstep]
    have ha : (resolve s L a).map (·.val) = plook (plainOf s) a := by rw [resolve_allAt h a, ownOf_allAt h a]
    cases hr : resolve s L a with
    | none =>
      rw [hr] at ha
      simp only [Option.map_none] at ha
      rw [← ha]
      exact ⟨rfl, rfl, h⟩
    | some c =>
      rw [hr] at ha
      simp only [Option.map_some] at ha
      rw [← ha]
      simp only
      rw [resolve_val_plain h b]
      split
      · exact ⟨rfl, rfl, h⟩
      · exact ⟨rfl, setOwn_plain h b c.val, setOwn_allAt h b c.val⟩
  | declassify n t => exact hd.elim

theorem plain_never_inuse {L : TLabel} {s : KState N V} (h : AllAt L s) (op : WOp N V) (l : TLabel) :
    (kstep L op s).1 ≠ .inuse l := by
  intro he
  have : kstep L op s = (.inuse l, (kstep L op s).2) := Prod.ext he rfl
  obtain ⟨_, n, c, _, _, hm, hn, _, hne, _⟩ := inuse_visible this
  exact hne (h c hm)

theorem plain_get {L : TLabel} {s : KState N V} (h : AllAt L s) (n : N) :
    (resolve s L n).map (·.val) = plook (plainOf s) n := by
  rw [resolve_allAt h n, ownOf_allAt h n]

theorem plain_names {L : TLabel} {s : KState N V} (h : AllAt L s) :
    visibleNames s L = uniq ((plainOf s).map (·.1)) := by
  unfold visibleNames plainOf
  congr 1
  rw [List.filter_eq_self.2]
  · simp [List.map_map, Function.comp_def]
  · intro c hc
    rw [h c hc]
    exact domT_refl L

inductive POut (N V : Type) where
  | wrote (r : WRep)
  | value (v : Option V)
  | values (vs : List (Option V))
  | size (k : Nat)
  | names (ns : List N)

def forget : KOut N V → POut N V
  | .wrote r => .wrote r
  | .read (.copy c) => .value (c.map (·.val))
  | .read (.copies cs) => .values (cs.map (fun c => c.map (·.val)))
  | .read (.label _) => .value none
  | .read (.size k) => .size k
  | .read (.names ns) => .names ns
  | .read (.scanned _ ns) => .names ns

def preply : KQ N → List (N × V) → POut N V
  | .get n, ps => .value (plook ps n)
  | .many ns, ps => .values (ns.map (plook ps))
  | .labelOf _, _ => .value none
  | .dbsize, ps => .size (uniq (ps.map (·.1))).length
  | .keys p, ps => .names ((uniq (ps.map (·.1))).filter p)
  | .scan k, ps => .names (if k = 0 then uniq (ps.map (·.1)) else [])

def pout : KOp N V → List (N × V) → POut N V
  | .write w, ps => .wrote (pstep w ps).1
  | .read q, ps => preply q ps

def pnext : KOp N V → List (N × V) → List (N × V)
  | .write w, ps => (pstep w ps).2
  | .read _, ps => ps

def plainOuts : List (KOp N V) → List (N × V) → List (POut N V)
  | [], _ => []
  | o :: os, ps => pout o ps :: plainOuts os (pnext o ps)

def labelledOuts (ord : List TLabel → List TLabel) (L : TLabel) : List (KOp N V) → KState N V → List (KOut N V)
  | [], _ => []
  | o :: os, s => creply ord ⟨L, o⟩ s :: labelledOuts ord L os (cstep ⟨L, o⟩ s)

def PlainOp : KOp N V → Prop
  | .write w => NotDecl w
  | .read (.labelOf _) => False
  | .read _ => True

def SingleAt (L : TLabel) (s : KState N V) : Prop :=
  AllAt L s ∧ (∀ l ∈ s.parts, l = L) ∧ s.parts.Nodup ∧ PartsCover s

theorem setOwn_single {L : TLabel} {s : KState N V} (h : SingleAt L s) (n : N) (v : V) : SingleAt L (setOwn s L n v) := by
  obtain ⟨h1, h2, h3, h4⟩ := h
  refine ⟨setOwn_allAt h1 n v, ?_, ?_, ?_⟩
  · unfold setOwn
    split
    · exact h2
    · simp only
      split
      · exact h2
      · intro l hl
        rcases List.mem_append.1 hl with hl | hl
        · exact h2 l hl
        · simpa using hl
  · unfold setOwn
    split
    · exact h3
    · simp only
      split
      · exact h3
      · rename_i hn
        exact List.nodup_append.2 ⟨h3, List.nodup_cons.2 ⟨by simp, List.nodup_nil⟩, by
          intro a ha b hb
          simp only [List.mem_singleton] at hb
          subst hb
          intro e
          subst e
          exact hn ha⟩
  · unfold setOwn PartsCover
    split
    · intro c hc
      obtain ⟨d, hd, rfl⟩ := List.mem_map.1 hc
      split <;> exact h4 d hd
    · simp only
      intro c hc
      rcases List.mem_append.1 hc with hc | hc
      · have := h4 c hc
        split
        · exact this
        · exact List.mem_append_left _ this
      · simp only [List.mem_singleton] at hc
        subst hc
        split
        · assumption
        · simp

theorem delOwn_single {L : TLabel} {s : KState N V} (h : SingleAt L s) (n : N) : SingleAt L (delOwn s L n) := by
  obtain ⟨h1, h2, h3, h4⟩ := h
  exact ⟨delOwn_allAt h1 n, h2, h3, fun c hc => h4 c (List.mem_filter.1 hc).1⟩

theorem delMany_single {L : TLabel} : ∀ (ns : List N) (s : KState N V), SingleAt L s → SingleAt L (delMany s L ns).2
  | [], _, h => h
  | n :: ns, s, h => by
    unfold delMany
    split
    · exact delMany_single ns _ (delOwn_single h n)
    · exact delMany_single ns s h

theorem setMany_single {L : TLabel} : ∀ (kvs : List (N × V)) (s : KState N V), SingleAt L s → SingleAt L (setMany s L kvs)
  | [], _, h => h
  | p :: ps, s, h => by
    simp only [setMany]
    exact setMany_single ps _ (setOwn_single h p.1 p.2)

theorem kstep_single {L : TLabel} {s : KState N V} (h : SingleAt L s) {op : WOp N V} (hd : NotDecl op) :
    SingleAt L (kstep L op s).2 := by
  unfold kstep
  rw [conflict_allAt h.1]
  simp only
  cases op with
  | put n v => exact setOwn_single h n v
  | del ns => exact delMany_single ns s h
  | createOnly n v =>
    simp only [applyW]
    split
    · exact h
    · exact setOwn_single h n v
  | createMany kvs =>
    simp only [applyW]
    split
    · exact h
    · exact setMany_single kvs s h
  | renameNx a b =>
    simp only [applyW]
    split
    · exact h
    · split
      · exact h
      · exact setOwn_single (delOwn_single h a) b _
  | copyNx a b =>
    simp only [applyW]
    split
    · exact h
    · split
      · exact h
      · exact setOwn_single h b _
  | declassify n t => exact hd.elim

theorem scan_single (ord : List TLabel → List TLabel) {L : TLabel} (hord : ord [L] = [L])
    {s : KState N V} (h : SingleAt L s) (k : Nat) :
    (visibleNames s L).filter (inParts ord s L k) = if k = 0 then visibleNames s L else [] := by
  obtain ⟨h1, h2, h3, h4⟩ := h
  have hvis : visParts s L = s.parts := by
    unfold visParts
    apply List.filter_eq_self.2
    intro l hl
    rw [h2 l hl]
    exact domT_refl L
  by_cases hp : L ∈ s.parts
  · have hparts : s.parts = [L] := by
      match hq : s.parts, hp, h2, h3 with
      | [], hp, _, _ => simp at hp
      | [a], _, h2, _ => rw [h2 a (by simp)]
      | a :: b :: rest, _, h2, h3 =>
        have ha := h2 a (by simp)
        have hb := h2 b (by simp)
        have := (List.nodup_cons.1 h3).1
        rw [ha, hb] at this
        simp at this
    split
    · rename_i hk
      subst hk
      apply List.filter_eq_self.2
      intro n hn
      have hs := mem_visibleNames.1 hn
      unfold inParts
      cases hr : resolve s L n with
      | none => rw [hr] at hs; simp at hs
      | some c =>
        have hc := resolve_visible hr
        simp only [hvis, hparts, hord, List.drop_zero, decide_eq_true_eq]
        rw [h1 c hc.1]
        simp
    · rename_i hk
      apply List.eq_nil_iff_forall_not_mem.2
      intro n hn
      have hp' := (List.mem_filter.1 hn).2
      unfold inParts at hp'
      rw [hvis, hparts, hord] at hp'
      have : ([L] : List TLabel).drop k = [] := by
        cases k with
        | zero => exact absurd rfl hk
        | succ k => simp
      split at hp' <;> simp [this] at hp'
  · have hnil : visibleNames s L = [] := by
      apply List.eq_nil_iff_forall_not_mem.2
      intro n hn
      have hs := mem_visibleNames.1 hn
      cases hr : resolve s L n with
      | none => rw [hr] at hs; simp at hs
      | some c =>
        have hc := resolve_visible hr
        have := h4 c hc.1
        rw [h1 c hc.1] at this
        exact hp this
    rw [hnil]
    split <;> rfl

theorem plain_history (ord : List TLabel → List TLabel) (L : TLabel) (hord : ord [L] = [L]) :
    ∀ (ops : List (KOp N V)), (∀ o ∈ ops, PlainOp o) → ∀ s : KState N V, SingleAt L s →
      (labelledOuts ord L ops s).map forget = plainOuts ops (plainOf s)
  | [], _, _, _ => rfl
  | o :: os, hp, s, h => by
    have ho := hp o List.mem_cons_self
    have hrest : ∀ x ∈ os, PlainOp x := fun x hx => hp x (List.mem_cons_of_mem _ hx)
    simp only [labelledOuts, plainOuts, List.map_cons, List.cons.injEq]
    cases o with
    | write w =>
      have hw : NotDecl w := ho
      obtain ⟨p1, p2, _⟩ := plain_step h.1 hw
      refine ⟨?_, ?_⟩
      · simp only [creply, forget, pout, p1]
      · have ih := plain_history ord L hord os hrest (cstep ⟨L, .write w⟩ s) (kstep_single h hw)
        rw [ih]
        simp only [cstep, pnext, p2]
    | read q =>
      refine ⟨?_, ?_⟩
      · cases q with
        | get n => simp only [creply, kreply, forget, pout, preply, plain_get h.1 n]
        | many ns =>
          simp only [creply, kreply, forget, pout, preply, List.map_map]
          congr 1
          apply List.map_congr_left
          intro n _
          simp only [Function.comp]
          exact plain_get h.1 n
        | labelOf n => exact absurd ho id
        | dbsize => simp only [creply, kreply, forget, pout, preply, plain_names h.1]
        | keys p => simp only [creply, kreply, forget, pout, preply, plain_names h.1]
        | scan k =>
          simp only [creply, kreply, forget, pout, preply]
          rw [scan_single ord hord h k, plain_names h.1]
      · exact plain_history ord L hord os hrest s h

end KeyPlain

end Labels
