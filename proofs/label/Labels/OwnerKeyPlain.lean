import Labels.OwnerForget

namespace Labels

section OwnerKeyPlain
set_option linter.unusedSectionVars false
variable {N V : Type} [DecidableEq N]

def embedC (w : Owner) (c : KCopy N V) : OCopy N V := ⟨c.name, (c.label, w), c.val⟩

def embedS (w : Owner) (s : KState N V) : OState N V := ⟨s.copies.map (embedC w), s.parts.map (fun l => (l, w))⟩

def liftRep (w : Owner) : WRep → OWRep
  | .ok => .ok
  | .inuse l => .inuse (l, w)
  | .exists => .exists
  | .count k => .count k
  | .noKey => .noKey
  | .direction => .direction
  | .seen l => .seen (l, w)

theorem embed_seesP (w : Owner) (r l : TLabel) : seesP (r, w) (l, w) = domT r l := by
  simp [seesP, odom_refl]

theorem pair_beq (a b : TLabel) (w : Owner) : ((a, w) == (b, w)) = (a == b) := by
  by_cases h : a = b
  · subst h; rw [beq_self_eq_true, beq_self_eq_true]
  · have : (a, w) ≠ (b, w) := fun e => h (Prod.mk.inj e).1
    rw [beq_eq_false_iff_ne.2 this, beq_eq_false_iff_ne.2 h]

theorem embed_oexact (w : Owner) (s : KState N V) (r : TLabel) (n : N) :
    oexact (embedS w s) (r, w) n = (ownOf s r n).map (embedC w) := by
  unfold oexact embedS ownOf
  simp only
  rw [List.find?_map]
  congr 1
  congr 1
  funext c
  simp [Function.comp, embedC, pair_beq]

theorem embed_oexact_shared {w : Owner} (hw : w ≠ .shared) (s : KState N V) (r : TLabel) (n : N) :
    oexact (embedS w s) (r, .shared) n = none := by
  unfold oexact embedS
  simp only
  rw [List.find?_map]
  simp only [Option.map_eq_none_iff]
  apply List.find?_eq_none.2
  intro c _
  simp [embedC, hw]

theorem embed_ocands (w : Owner) (s : KState N V) (r : TLabel) (n : N) :
    ocands (embedS w s) (r, w) n = (cands s r n).map (embedC w) := by
  unfold ocands embedS cands
  simp only
  rw [List.filter_map]
  congr 1
  apply List.filter_congr
  intro c _
  simp only [Function.comp, embedC, embed_seesP]

theorem embed_obetter (w : Owner) (a b : KCopy N V) : obetter w (embedC w a) (embedC w b) = better a b := by
  rw [Bool.eq_iff_iff]
  simp [obetter, better, embedC]
  exact decide_eq_true_iff

theorem embed_opickFrom (w : Owner) : ∀ (l : List (KCopy N V)) (b : KCopy N V),
    opickFrom w (embedC w b) (l.map (embedC w)) = embedC w (pickFrom b l)
  | [], _ => rfl
  | c :: cs, b => by
    simp only [List.map_cons, opickFrom, pickFrom, embed_obetter]
    split
    · exact embed_opickFrom w cs c
    · exact embed_opickFrom w cs b

theorem embed_opick (w : Owner) (l : List (KCopy N V)) : opick w (l.map (embedC w)) = (pick l).map (embedC w) := by
  cases l with
  | nil => rfl
  | cons c cs =>
    simp only [List.map_cons, opick, pick, Option.map_some]
    rw [embed_opickFrom]

theorem embed_oother (w : Owner) (s : KState N V) (r : TLabel) (n : N) (ho : ownOf s r n = none) :
    oother (embedS w s) (r, w) n = (other s r n).map (embedC w) := by
  unfold oother other
  have hs : oexact (embedS w s) (r, .shared) n = none := by
    by_cases hw : w = .shared
    · subst hw
      rw [embed_oexact, ho]
      rfl
    · exact embed_oexact_shared hw s r n
  rw [hs]
  simp only
  rw [embed_ocands, embed_opick]

theorem embed_oresolve (w : Owner) (s : KState N V) (r : TLabel) (n : N) :
    oresolve (embedS w s) (r, w) n = (resolve s r n).map (embedC w) := by
  unfold oresolve resolve
  rw [embed_oexact]
  cases ho : ownOf s r n with
  | some c => rfl
  | none =>
    simp only [Option.map_none]
    exact embed_oother w s r n ho

theorem embed_oisAt (w : Owner) (n : N) (W : TLabel) (c : KCopy N V) : oisAt n (W, w) (embedC w c) = isAt n W c := by
  simp [oisAt, isAt, embedC, pair_beq]

theorem embed_osetOwn (w : Owner) (s : KState N V) (W : TLabel) (n : N) (v : V) :
    osetOwn (embedS w s) (W, w) n v = embedS w (setOwn s W n v) := by
  unfold osetOwn setOwn
  rw [embed_oexact]
  cases ho : ownOf s W n with
  | some c =>
    simp only [Option.map_some]
    unfold embedS
    simp only [OState.mk.injEq, and_true, List.map_map]
    apply List.map_congr_left
    intro d _
    simp only [Function.comp, embed_oisAt]
    split <;> rfl
  | none =>
    simp only [Option.map_none]
    unfold embedS
    simp only [OState.mk.injEq, List.map_append, List.map_cons, List.map_nil]
    refine ⟨rfl, ?_⟩
    have hm : (W, w) ∈ s.parts.map (fun l => (l, w)) ↔ W ∈ s.parts := by simp
    by_cases h : W ∈ s.parts
    · simp [h]
    · simp [h]

theorem embed_odelOwn (w : Owner) (s : KState N V) (W : TLabel) (n : N) :
    odelOwn (embedS w s) (W, w) n = embedS w (delOwn s W n) := by
  unfold odelOwn delOwn embedS
  simp only [OState.mk.injEq, and_true]
  rw [List.filter_map]
  congr 1
  apply List.filter_congr
  intro c _
  simp only [Function.comp, embed_oisAt]

theorem embed_odelMany (w : Owner) (W : TLabel) : ∀ (ns : List N) (s : KState N V),
    odelMany (embedS w s) (W, w) ns = ((delMany s W ns).1, embedS w (delMany s W ns).2)
  | [], _ => rfl
  | n :: ns, s => by
    unfold odelMany delMany
    rw [embed_oexact]
    cases ho : ownOf s W n with
    | some c =>
      simp only [Option.map_some]
      rw [embed_odelOwn, embed_odelMany w W ns]
    | none =>
      simp only [Option.map_none]
      exact embed_odelMany w W ns s

theorem embed_osetMany (w : Owner) (W : TLabel) : ∀ (kvs : List (N × V)) (s : KState N V),
    osetMany (embedS w s) (W, w) kvs = embedS w (setMany s W kvs)
  | [], _ => rfl
  | p :: ps, s => by
    simp only [osetMany, setMany]
    rw [embed_osetOwn, embed_osetMany w W ps]

theorem embed_oconflict (w : Owner) (s : KState N V) (W : TLabel) :
    ∀ chk : List (N × Bool), oconflict (embedS w s) (W, w) chk = (conflict s W chk).map (fun l => (l, w))
  | [] => rfl
  | (n, co) :: rest => by
    unfold oconflict conflict
    rw [embed_oexact]
    cases ho : ownOf s W n with
    | some c =>
      simp only [Option.map_some, Option.isNone_some, Bool.false_and, Bool.false_eq_true, ↓reduceIte]
      exact embed_oconflict w s W rest
    | none =>
      simp only [Option.map_none, Option.isNone_none, Bool.true_and]
      split
      · rw [embed_oother w s W n ho]
        cases hx : other s W n with
        | some c => rfl
        | none => exact embed_oconflict w s W rest
      · exact embed_oconflict w s W rest

theorem orecord_embed (w : Owner) (W : TLabel) (s : KState N V) (hr : isUserO w = false ∨ W ∈ s.parts) :
    orecord (W, w) (embedS w s) = embedS w s := by
  rcases hr with h | h
  · exact orecord_shared h _
  · exact orecord_present (by unfold embedS; exact List.mem_map.2 ⟨W, h, rfl⟩)

theorem setOwn_parts_keep {W l : TLabel} {s : KState N V} (n : N) (v : V) (h : l ∈ s.parts) :
    l ∈ (setOwn s W n v).parts := by
  unfold setOwn
  split
  · exact h
  · simp only
    split <;> simp [h]

theorem delMany_parts_keep {W l : TLabel} : ∀ (ns : List N) (s : KState N V), l ∈ s.parts → l ∈ (delMany s W ns).2.parts
  | [], _, h => h
  | n :: ns, s, h => by
    unfold delMany
    split
    · exact delMany_parts_keep ns _ h
    · exact delMany_parts_keep ns s h

theorem setMany_parts_keep {W l : TLabel} : ∀ (kvs : List (N × V)) (s : KState N V), l ∈ s.parts →
    l ∈ (setMany s W kvs).parts
  | [], _, h => h
  | q :: qs, s, h => by
    simp only [setMany]
    exact setMany_parts_keep qs _ (setOwn_parts_keep _ _ h)

theorem kstep_parts_keep {W l : TLabel} (op : WOp N V) {s : KState N V} (h : l ∈ s.parts) :
    l ∈ (kstep W op s).2.parts := by
  unfold kstep
  split
  · exact h
  · cases op with
    | put n v => exact setOwn_parts_keep n v h
    | del ns => exact delMany_parts_keep ns s h
    | createOnly n v =>
      simp only [applyW]
      split
      · exact h
      · exact setOwn_parts_keep n v h
    | createMany kvs =>
      simp only [applyW]
      split
      · exact h
      · exact setMany_parts_keep kvs s h
    | renameNx a b =>
      simp only [applyW]
      split
      · exact h
      · split
        · exact h
        · exact setOwn_parts_keep _ _ h
    | copyNx a b =>
      simp only [applyW]
      split
      · exact h
      · split
        · exact h
        · exact setOwn_parts_keep _ _ h
    | declassify n t =>
      simp only [applyW]
      split
      · exact h
      · split
        · exact h
        · split
          · exact h
          · exact setOwn_parts_keep _ _ h

theorem cstep_parts_keep {l : TLabel} (c : KCmd N V) {s : KState N V} (h : l ∈ s.parts) : l ∈ (cstep c s).parts := by
  unfold cstep
  split
  · exact kstep_parts_keep _ h
  · exact h

theorem embed_okstep (w : Owner) (W : TLabel) (op : WOp N V) (s : KState N V) (hr : isUserO w = false ∨ W ∈ s.parts) :
    okstep (W, w) op (embedS w s) = (liftRep w (kstep W op s).1, embedS w (kstep W op s).2) := by
  unfold okstep kstep
  rw [embed_oconflict]
  cases hc : conflict s W (checks op) with
  | some l => rfl
  | none =>
    simp only [Option.map_none]
    rw [orecord_embed w W s hr]
    cases op with
    | put n v => simp only [oapplyW, applyW, embed_osetOwn, liftRep]
    | del ns => simp only [oapplyW, applyW, embed_odelMany, liftRep]
    | createOnly n v =>
      simp only [oapplyW, applyW, embed_oresolve, Option.isSome_map]
      split <;> simp [embed_osetOwn, liftRep]
    | createMany kvs =>
      simp only [oapplyW, applyW, embed_oresolve, Option.isSome_map]
      split <;> simp [embed_osetMany, liftRep]
    | renameNx a b =>
      simp only [oapplyW, applyW, embed_oexact, embed_oresolve, Option.isSome_map]
      cases ownOf s W a with
      | none => rfl
      | some c =>
        simp only [Option.map_some]
        split <;> simp [embed_osetOwn, embed_odelOwn, liftRep, embedC]
    | copyNx a b =>
      simp only [oapplyW, applyW, embed_oresolve, Option.isSome_map]
      cases resolve s W a with
      | none => rfl
      | some c =>
        simp only [Option.map_some]
        split <;> simp [embed_osetOwn, liftRep, embedC]
    | declassify n t =>
      simp only [oapplyW, applyW]
      split
      · rfl
      · rw [embed_oexact]
        cases ownOf s W n with
        | none => rfl
        | some c =>
          simp only [Option.map_some]
          rw [embed_oresolve]
          cases resolve s t n with
          | some d => rfl
          | none =>
            simp only [Option.map_none]
            rw [embed_odelOwn, embed_osetOwn]
            rfl

theorem embed_ovisibleNames (w : Owner) (s : KState N V) (r : TLabel) :
    ovisibleNames (embedS w s) (r, w) = visibleNames s r := by
  unfold ovisibleNames visibleNames embedS
  simp only
  rw [List.filter_map, List.map_map]
  congr 2
  apply List.filter_congr
  intro c _
  simp [embedC, embed_seesP]

theorem ord_nil {ord : List TLabel → List TLabel} (hord : ∀ L l, l ∈ ord L ↔ l ∈ L) : ord [] = [] :=
  List.eq_nil_iff_forall_not_mem.2 (fun l h => by simpa using (hord [] l).1 h)

theorem embed_parts_own {w : Owner} (hu : isUserO w = true) (ord : List TLabel → List TLabel) (s : KState N V)
    (r : TLabel) : oownParts ord (embedS w s) (r, w) = ord (visParts s r) := by
  unfold oownParts embedS visParts
  simp only
  rw [List.filter_map, List.map_map]
  congr 1
  have : (List.map ((fun p : Scope => p.1) ∘ fun l => (l, w)) (List.filter ((fun p : Scope => isUserO w && p.2 == w &&
      domT r p.1) ∘ fun l => (l, w)) s.parts)) = s.parts.filter (fun l => domT r l) := by
    rw [show ((fun p : Scope => p.1) ∘ fun l => (l, w)) = id from rfl, List.map_id]
    apply List.filter_congr
    intro l _
    simp [hu]
  exact this

theorem embed_parts_shared_none {w : Owner} (hw : w ≠ .shared) {ord : List TLabel → List TLabel}
    (hord : ∀ L l, l ∈ ord L ↔ l ∈ L) (s : KState N V) (r : TLabel) : osharedParts ord (embedS w s) (r, w) = [] := by
  unfold osharedParts embedS
  simp only
  have : (s.parts.map (fun l => (l, w))).filter (fun p => p.2 == .shared && domT r p.1) = [] := by
    apply List.eq_nil_iff_forall_not_mem.2
    intro p hp
    obtain ⟨hm, hq⟩ := List.mem_filter.1 hp
    obtain ⟨l, _, rfl⟩ := List.mem_map.1 hm
    simp [hw] at hq
  rw [this]
  exact ord_nil hord

theorem embed_parts_shared (ord : List TLabel → List TLabel) (s : KState N V) (r : TLabel) :
    osharedParts ord (embedS .shared s) (r, .shared) = ord (visParts s r) := by
  unfold osharedParts embedS visParts
  simp only
  rw [List.filter_map, List.map_map]
  congr 1
  rw [show ((fun p : Scope => p.1) ∘ fun l => (l, Owner.shared)) = id from rfl, List.map_id]
  apply List.filter_congr
  intro l _
  simp

theorem embed_parts_own_none {ord : List TLabel → List TLabel} (hord : ∀ L l, l ∈ ord L ↔ l ∈ L)
    (s : KState N V) (r : TLabel) : oownParts ord (embedS .shared s) (r, .shared) = [] := by
  unfold oownParts
  have : (embedS Owner.shared s).parts.filter (fun p => isUserO Owner.shared && p.2 == Owner.shared && domT r p.1) = [] := by
    apply List.eq_nil_iff_forall_not_mem.2
    intro p hp
    simp [isUserO] at hp
  simp only
  rw [this]
  exact ord_nil hord

theorem embed_hasOwn_user {u : List Nat} (s : KState N V) (r : TLabel) (n : N) :
    hasOwn (embedS (.user u) s) (r, .user u) n = (resolve s r n).isSome := by
  have hv : ovisibleNames (embedS (.user u) s) (r, .user u) = visibleNames s r := embed_ovisibleNames _ s r
  cases hr : resolve s r n with
  | none =>
    have hall := resolve_none.1 hr
    unfold hasOwn
    apply List.any_eq_false.2
    intro c hc
    obtain ⟨d, hd, rfl⟩ := List.mem_map.1 hc
    simp only [embedC, isOwn, isUserO, Bool.and_eq_true, beq_iff_eq, Bool.true_and, Bool.not_eq_true]
    by_cases hn : d.name = n
    · simp [hn, hall d hd hn]
    · simp [hn]
  | some c =>
    obtain ⟨h1, h2, h3⟩ := resolve_visible hr
    unfold hasOwn
    apply List.any_eq_true.2
    exact ⟨embedC (.user u) c, List.mem_map.2 ⟨c, h1, rfl⟩, by simp [embedC, isOwn, isUserO, h2, h3]⟩

theorem embed_ownOnly (w : Owner) (r : TLabel) (s : KState N V) : ownOnly (r, w) (embedS w s) = embedS w s := by
  unfold ownOnly embedS
  simp only [OState.mk.injEq, and_true]
  apply List.filter_eq_self.2
  intro c hc
  obtain ⟨d, _, rfl⟩ := List.mem_map.1 hc
  simp [embedC]

def liftQ : KQ N → OQ N
  | .get n => .get n
  | .many ns => .many ns
  | .labelOf n => .labelOf n
  | .dbsize => .dbsize
  | .keys p => .keys p
  | .scan k => .scan 0 k

def liftReply (w : Owner) : KReply N V → OReply N V
  | .copy c => .copy (c.map (embedC w))
  | .copies cs => .copies (cs.map (·.map (embedC w)))
  | .label l => .scope (l.map (·, w))
  | .size k => .size k
  | .names ns => .names ns
  | .scanned b ns => if isUserO w then .scanned b 0 ns else .scanned 0 b ns

theorem embed_inPhase0 {u : List Nat} (ord : List TLabel → List TLabel) (s : KState N V) (r : TLabel) (k : Nat) (n : N) :
    inPhase0 ord (embedS (.user u) s) (r, .user u) k n = inParts ord s r k n := by
  unfold inPhase0 inParts oownResolve
  simp only [isUserO, ↓reduceIte]
  rw [embed_ownOnly, embed_oresolve, embed_parts_own (by rfl)]
  cases resolve s r n <;> rfl

theorem embed_inPhase1_user {u : List Nat} (ord : List TLabel → List TLabel) (s : KState N V) (r : TLabel) (k : Nat)
    (n : N) (hn : n ∈ visibleNames s r) : inPhase1 ord (embedS (.user u) s) (r, .user u) k n = false := by
  unfold inPhase1
  rw [embed_hasOwn_user, (mem_visibleNames).1 hn]
  rfl

theorem embed_inPhase1_shared (ord : List TLabel → List TLabel) (s : KState N V) (r : TLabel) (k : Nat) (n : N) :
    inPhase1 ord (embedS .shared s) (r, .shared) k n = inParts ord s r k n := by
  unfold inPhase1 inParts
  have ho : hasOwn (embedS .shared s) (r, .shared) n = false := by
    unfold hasOwn
    apply List.any_eq_false.2
    intro c _
    simp [isOwn, isUserO]
  rw [ho]
  simp only [Bool.not_false, Bool.true_and]
  unfold osharedResolve
  rw [embed_ownOnly, embed_oresolve, embed_parts_shared]
  cases resolve s r n <;> rfl

theorem embed_oscan_user {u : List Nat} {ord : List TLabel → List TLabel} (s : KState N V) (r : TLabel) (k : Nat) :
    oscan ord (embedS (.user u) s) (r, .user u) 0 k = (visibleNames s r).filter (inParts ord s r k) := by
  unfold oscan
  simp only [isUserO, ↓reduceIte, true_and]
  rw [embed_ovisibleNames]
  split
  · apply List.filter_congr
    intro n hn
    rw [embed_inPhase0, embed_inPhase1_user ord s r 0 n hn, Bool.or_false]
  · rename_i hk
    rw [embed_parts_own (by rfl)] at hk
    have hnil : (ord (visParts s r)).drop k = [] := List.drop_eq_nil_of_le (by omega)
    rw [List.filter_eq_nil_iff.2, List.filter_eq_nil_iff.2]
    · intro n hn
      unfold inParts
      cases resolve s r n <;> simp [hnil]
    · intro n hn
      simp [embed_inPhase1_user ord s r 0 n hn]

theorem embed_oscan_shared {ord : List TLabel → List TLabel} (s : KState N V) (r : TLabel) (k : Nat) :
    oscan ord (embedS .shared s) (r, .shared) 0 k = (visibleNames s r).filter (inParts ord s r k) := by
  unfold oscan
  simp only [isUserO, Bool.false_eq_true, ↓reduceIte]
  rw [embed_ovisibleNames]
  apply List.filter_congr
  intro n _
  rw [embed_inPhase1_shared]

theorem embed_oscan {w : Owner} (hw : w ≠ .every) {ord : List TLabel → List TLabel} (s : KState N V) (r : TLabel)
    (k : Nat) : oscan ord (embedS w s) (r, w) 0 k = (visibleNames s r).filter (inParts ord s r k) := by
  cases w with
  | every => exact absurd rfl hw
  | shared => exact embed_oscan_shared s r k
  | user u => exact embed_oscan_user s r k

theorem embed_oreply {w : Owner} (hw : w ≠ .every) {ord : List TLabel → List TLabel} (hord : ∀ L l, l ∈ ord L ↔ l ∈ L)
    (q : KQ N) (s : KState N V) (r : TLabel) :
    oreply ord (liftQ q) (embedS w s) (r, w) = liftReply w (kreply ord q s r) := by
  cases q with
  | get n => simp only [liftQ, oreply, kreply, liftReply, embed_oresolve]
  | many ns =>
    simp only [liftQ, oreply, kreply, liftReply, List.map_map]
    congr 1
    apply List.map_congr_left
    intro n _
    simp only [Function.comp, embed_oresolve]
  | labelOf n =>
    simp only [liftQ, oreply, kreply, liftReply, embed_oresolve, Option.map_map]
    rfl
  | dbsize => simp only [liftQ, oreply, kreply, liftReply, embed_ovisibleNames]
  | keys p => simp only [liftQ, oreply, kreply, liftReply, embed_ovisibleNames]
  | scan k =>
    simp only [liftQ, oreply, kreply, liftReply]
    rw [embed_oscan hw]
    cases w with
    | every => exact absurd rfl hw
    | shared =>
      simp only [isUserO, Bool.false_eq_true, ↓reduceIte]
      rw [embed_parts_own_none hord, embed_parts_shared]
      rfl
    | user u =>
      simp only [isUserO, ↓reduceIte]
      rw [embed_parts_own (by rfl), embed_parts_shared_none (by simp) hord]
      rfl

def liftOp : KOp N V → OKOp N V
  | .write op => .write op
  | .read q => .read (liftQ q)

def liftCmd (w : Owner) (c : KCmd N V) : OKCmd N V := ⟨(c.label, w), liftOp c.op⟩

def liftOut (w : Owner) : KOut N V → OKOut N V
  | .wrote r => .wrote (liftRep w r)
  | .read x => .read (liftReply w x)

theorem embed_ocstep (w : Owner) (c : KCmd N V) (s : KState N V) (hr : isUserO w = false ∨ c.label ∈ s.parts) :
    ocstep (liftCmd w c) (embedS w s) = embedS w (cstep c s) := by
  unfold liftCmd ocstep cstep
  cases c with
  | mk l op =>
    cases op with
    | write op => simp only [liftOp, embed_okstep w l op s hr]
    | read q => rfl

theorem embed_ocreply {w : Owner} (hw : w ≠ .every) {ord : List TLabel → List TLabel} (hord : ∀ L l, l ∈ ord L ↔ l ∈ L)
    (c : KCmd N V) (s : KState N V) (hr : isUserO w = false ∨ c.label ∈ s.parts) :
    ocreply ord (liftCmd w c) (embedS w s) = liftOut w (creply ord c s) := by
  unfold liftCmd ocreply creply
  cases c with
  | mk l op =>
    cases op with
    | write op => simp only [liftOp, embed_okstep w l op s hr, liftOut]
    | read q => simp only [liftOp, liftOut, embed_oreply hw hord]

theorem embed_history {w : Owner} (hw : w ≠ .every) {ord : List TLabel → List TLabel} (hord : ∀ L l, l ∈ ord L ↔ l ∈ L)
    (R : TLabel) : ∀ (cs : List (KCmd N V)) (s : KState N V), (isUserO w = false ∨ ∀ c ∈ cs, c.label ∈ s.parts) →
      okouts ord (R, w) (cs.map (liftCmd w)) (embedS w s) = (kouts ord R cs s).map (liftOut w)
  | [], _, _ => rfl
  | c :: cs, s, hr => by
    have hc : isUserO w = false ∨ c.label ∈ s.parts := by
      rcases hr with h | h
      · exact Or.inl h
      · exact Or.inr (h c List.mem_cons_self)
    have hr' : isUserO w = false ∨ ∀ x ∈ cs, x.label ∈ (cstep c s).parts := by
      rcases hr with h | h
      · exact Or.inl h
      · exact Or.inr (fun x hx => cstep_parts_keep c (h x (List.mem_cons_of_mem _ hx)))
    unfold okouts kouts
    simp only [List.map_cons, outsK]
    rw [show (liftCmd w c).scope = (c.label, w) from rfl, embed_seesP]
    rw [embed_ocstep w c s hc]
    have ih := embed_history hw hord R cs (cstep c s) hr'
    unfold okouts kouts at ih
    split
    · simp only [List.map_cons]
      rw [embed_ocreply hw hord c s hc, ih]
    · exact ih

theorem owners_off_history {ord : List TLabel → List TLabel} (hord : ∀ L l, l ∈ ord L ↔ l ∈ L) (R : TLabel)
    (cs : List (KCmd N V)) (s : KState N V) :
    okouts ord (R, .shared) (cs.map (liftCmd .shared)) (embedS .shared s) = (kouts ord R cs s).map (liftOut .shared) :=
  embed_history (by simp) hord R cs s (Or.inl rfl)

def dropC (c : OCopy N V) : KCopy N V := ⟨c.name, c.scope.1, c.val⟩

def lowerReply : OReply N V → KReply N V
  | .copy c => .copy (c.map dropC)
  | .copies cs => .copies (cs.map (·.map dropC))
  | .scope l => .label (l.map (·.1))
  | .size k => .size k
  | .names ns => .names ns
  | .scanned a b ns => .scanned (a + b) ns

def lowerRep : OWRep → WRep
  | .ok => .ok
  | .inuse l => .inuse l.1
  | .exists => .exists
  | .count k => .count k
  | .noKey => .noKey
  | .direction => .direction
  | .seen l => .seen l.1

def lowerOut : OKOut N V → KOut N V
  | .wrote r => .wrote (lowerRep r)
  | .read x => .read (lowerReply x)
  | .forgot k => .read (.size k)

theorem lower_lift (w : Owner) (o : KOut N V) : lowerOut (liftOut w o) = o := by
  cases o with
  | wrote r => cases r <;> rfl
  | read x =>
    cases x with
    | copy c => cases c <;> rfl
    | copies cs =>
      simp only [liftOut, liftReply, lowerOut, lowerReply, List.map_map]
      congr 2
      conv => rhs; rw [← List.map_id cs]
      apply List.map_congr_left
      intro c _
      cases c <;> rfl
    | label l => cases l <;> rfl
    | size k => rfl
    | names ns => rfl
    | scanned b ns =>
      simp only [liftOut, liftReply, lowerOut]
      split <;> simp [lowerReply]

theorem kouts_single (ord : List TLabel → List TLabel) (L : TLabel) :
    ∀ (ops : List (KOp N V)) (s : KState N V),
      kouts ord L (ops.map (fun o => ⟨L, o⟩)) s = labelledOuts ord L ops s
  | [], _ => rfl
  | o :: os, s => by
    unfold kouts at *
    simp only [List.map_cons, outsK, domT_refl, ↓reduceIte, labelledOuts]
    congr 1
    exact kouts_single ord L os _

theorem one_user_plain {ord : List TLabel → List TLabel} (hord : ∀ L l, l ∈ ord L ↔ l ∈ L) (hsing : ∀ L, ord [L] = [L])
    (u : List Nat) (L : TLabel) (ops : List (KOp N V)) (hp : ∀ o ∈ ops, PlainOp o) (s : KState N V)
    (h : SingleAt L s) (hL : L ∈ s.parts) :
    ((okouts ord (L, .user u) ((ops.map (fun o => (⟨L, o⟩ : KCmd N V))).map (liftCmd (.user u)))
      (embedS (.user u) s)).map lowerOut).map forget = plainOuts ops (plainOf s) := by
  rw [embed_history (by simp) hord L _ s (Or.inr (fun c hc => by
    obtain ⟨o, _, rfl⟩ := List.mem_map.1 hc
    exact hL)), List.map_map, List.map_map]
  have : ((forget ∘ lowerOut) ∘ liftOut (.user u) : KOut N V → POut N V) = forget := by
    funext o
    simp only [Function.comp, lower_lift]
  rw [this, kouts_single]
  exact plain_history ord L (hsing L) ops hp s h

end OwnerKeyPlain

end Labels
