import Labels.OwnerKeyWrites

namespace Labels

section OwnerKeyPurge
set_option linter.unusedSectionVars false
variable {N V : Type} [DecidableEq N]

inductive OKOp (N V : Type) where
  | write (op : WOp N V)
  | read (q : OQ N)
  | flush (f : FlushCtx)
  | forget (u : List Nat)

structure OKCmd (N V : Type) where
  scope : Scope
  op : OKOp N V

inductive OKOut (N V : Type) where
  | wrote (r : OWRep)
  | read (x : OReply N V)
  | forgot (k : Nat)

def ocstep (c : OKCmd N V) (s : OState N V) : OState N V :=
  match c.op with
  | .write op => (okstep c.scope op s).2
  | .read _ => s
  | .flush f => oflush c.scope f (orecord c.scope s)
  | .forget u => oforget (.user u) s

def ocreply (ord : List TLabel → List TLabel) (c : OKCmd N V) (s : OState N V) : OKOut N V :=
  match c.op with
  | .write op => .wrote (okstep c.scope op s).1
  | .read q => .read (oreply ord q s c.scope)
  | .flush _ => .wrote .ok
  | .forget u => .forgot (s.copies.filter (fun c => c.scope.2 == .user u)).length

def OLocal (c : OKCmd N V) : Prop :=
  match c.op with
  | .write op => NotDecl op
  | .read _ => True
  | .flush f => f.labelTop = false
  | .forget _ => False

theorem orestrict_eq (R : Scope) (s : OState N V) : orestrict R s = ofilter (seesP R) s := rfl

theorem restrict_filter_keeps {P : Scope → Bool} {W : Scope} (h : OKeeps P W) (s : OState N V) :
    orestrict W (ofilter P s) = orestrict W s := by
  unfold orestrict ofilter
  simp only [OState.mk.injEq]
  constructor
  · exact filter_filter_of _ _ (fun c hc => h.2 _ hc) _
  · exact filter_filter_of _ _ (fun p hp => h.2 _ hp) _

theorem oreply_filter (ord : List TLabel → List TLabel) (q : OQ N) {P : Scope → Bool} {W : Scope} (h : OKeeps P W)
    (s : OState N V) : oreply ord q (ofilter P s) W = oreply ord q s W := by
  rw [← oreply_restrict ord q W (ofilter P s), restrict_filter_keeps h, oreply_restrict]

theorem ocstep_local {R : Scope} {c : OKCmd N V} (hl : OLocal c) (hv : seesP R c.scope = false) (s : OState N V) :
    orestrict R (ocstep c s) = orestrict R s := by
  unfold ocstep
  unfold OLocal at hl
  split
  · rename_i op hop
    rw [hop] at hl
    exact okstep_filter_hidden (P := seesP R) hv (fun n t e => by rw [e] at hl; exact hl.elim) s
  · rfl
  · rename_i f hop
    rw [hop] at hl
    rw [orestrict_eq, oflush_filter_hidden (by simp [everything, hl]) ?_, orecord_filter_hidden hv]
    · rfl
    · intro d h1 h2
      rcases h2 with h | h
      · rw [hl] at h; exact absurd h (by decide)
      · rw [show d = c.scope from Prod.ext h h1]; exact hv
  · rename_i u hop
    rw [hop] at hl
    exact hl.elim

theorem ocstep_consistent {R : Scope} {c : OKCmd N V} (hl : OLocal c) (hv : seesP R c.scope = true)
    {s t : OState N V} (he : orestrict R s = orestrict R t) : orestrict R (ocstep c s) = orestrict R (ocstep c t) := by
  unfold ocstep
  unfold OLocal at hl
  split
  · rename_i op _
    have hs := okstep_filter (keeps_restrict hv) op s
    have ht := okstep_filter (keeps_restrict hv) op t
    rw [← orestrict_eq, he] at hs
    rw [← orestrict_eq] at ht
    rw [hs] at ht
    simp only [Prod.mk.injEq] at ht
    exact ht.2
  · exact he
  · rename_i f _
    rw [orestrict_eq, orestrict_eq, ← oflush_filter, ← oflush_filter, ← orecord_filter hv, ← orecord_filter hv,
      ← orestrict_eq, ← orestrict_eq, he]
  · rename_i u hop
    rw [hop] at hl
    exact hl.elim

theorem ocreply_consistent (ord : List TLabel → List TLabel) {R : Scope} {c : OKCmd N V} (hl : OLocal c)
    (hv : seesP R c.scope = true) {s t : OState N V} (he : orestrict R s = orestrict R t) :
    ocreply ord c s = ocreply ord c t := by
  unfold ocreply
  unfold OLocal at hl
  split
  · rename_i op _
    have hs := okstep_filter (keeps_restrict hv) op s
    have ht := okstep_filter (keeps_restrict hv) op t
    rw [← orestrict_eq, he] at hs
    rw [← orestrict_eq] at ht
    rw [hs] at ht
    simp only [Prod.mk.injEq] at ht
    rw [ht.1]
  · rename_i q _
    rw [← oreply_restrict_of ord q hv s, he, oreply_restrict_of ord q hv t]
  · rfl
  · rename_i u hop
    rw [hop] at hl
    exact hl.elim

theorem ocstep_parts_keep {c : OKCmd N V} (hf : ∀ u, c.op ≠ .forget u) {s : OState N V} {p : Scope}
    (h : p ∈ s.parts) : p ∈ (ocstep c s).parts := by
  unfold ocstep
  split
  · exact okstep_parts_keep _ h
  · exact h
  · exact orecord_keeps h
  · rename_i u hop
    exact absurd hop (hf u)

theorem oflush_records {W : Scope} {f : FlushCtx} (hu : isUserO W.2 = true) (s : OState N V) :
    W ∈ (ocstep ⟨W, .flush f⟩ s).parts :=
  orecord_records hu s

def okouts (ord : List TLabel → List TLabel) (R : Scope) (cs : List (OKCmd N V)) (s : OState N V) : List (OKOut N V) :=
  outsK seesP OKCmd.scope ocstep (ocreply ord) R cs s

def okpurge (R : Scope) (cs : List (OKCmd N V)) : List (OKCmd N V) := purgeK seesP OKCmd.scope R cs

theorem okey_history (ord : List TLabel → List TLabel) (R : Scope) (cs : List (OKCmd N V))
    (hd : ∀ c ∈ cs, OLocal c) (s t : OState N V) (he : orestrict R s = orestrict R t) :
    okouts ord R cs s = okouts ord R (okpurge R cs) t :=
  unwindingK seesP OKCmd.scope ocstep (ocreply ord) R OLocal (orestrict R)
    (fun _ s hc hv => ocstep_local hc hv s)
    (fun _ _ _ hc he hv => ocstep_consistent hc hv he)
    (fun _ _ _ hc he hv => ocreply_consistent ord hc hv he) cs hd s t he

theorem okey_history_purge (ord : List TLabel → List TLabel) (R : Scope) (cs : List (OKCmd N V))
    (hd : ∀ c ∈ cs, OLocal c) (s : OState N V) : okouts ord R cs s = okouts ord R (okpurge R cs) s :=
  okey_history ord R cs hd s s rfl

theorem okey_hidden_insertion (ord : List TLabel → List TLabel) (R : Scope) (cs merge : List (OKCmd N V))
    (hd : ∀ c ∈ cs, OLocal c) (hm : okpurge R merge = okpurge R cs) (hmd : ∀ c ∈ merge, OLocal c) (s : OState N V) :
    okouts ord R merge s = okouts ord R cs s := by
  rw [okey_history ord R merge hmd s s rfl, okey_history ord R cs hd s s rfl, hm]

def dropOwner (v : List Nat) (s : OState N V) : OState N V := oforget (.user v) s

def OwnerAllowed (v : List Nat) (c : OKCmd N V) : Prop :=
  c.scope.2 ≠ .every ∧ ∀ u, c.op = .forget u → u ≠ v ∧ c.scope.2 ≠ .user v

def notOwner (v : List Nat) (_ : Scope) (l : Scope) : Bool := l.2 != .user v

theorem keeps_drop {v : List Nat} {W : Scope} (h1 : W.2 ≠ .user v) (h2 : W.2 ≠ .every) :
    OKeeps (fun d => d.2 != .user v) W := by
  refine ⟨by simpa using h1, fun d hd => ?_⟩
  rcases odom_concrete h2 ((seesP_iff _ _).1 hd).2 with e | e
  · simp [e]
  · simp [e, h1]

theorem drop_local {v : List Nat} {c : OKCmd N V} (ha : OwnerAllowed v c) (hv : notOwner v c.scope c.scope = false)
    (s : OState N V) : dropOwner v (ocstep c s) = dropOwner v s := by
  have hW : c.scope.2 = .user v := by simpa [notOwner] using hv
  unfold dropOwner
  simp only [oforget_as_filter]
  unfold ocstep
  split
  · rename_i op _
    apply okstep_filter_hidden (by simp [hW])
    intro n t _
    simp [hW]
  · rfl
  · rename_i f _
    rw [oflush_filter_hidden (oflush_user_own (by simp [hW, isUserO])) ?_, orecord_filter_hidden (by simp [hW])]
    intro d h1 _
    simp [h1, hW]
  · rename_i u hop
    exact absurd hW (ha.2 u hop).2

theorem drop_consistent {v : List Nat} {c : OKCmd N V} (ha : OwnerAllowed v c)
    (hv : notOwner v c.scope c.scope = true) {s t : OState N V} (he : dropOwner v s = dropOwner v t) :
    dropOwner v (ocstep c s) = dropOwner v (ocstep c t) := by
  have hW : c.scope.2 ≠ .user v := by simpa [notOwner] using hv
  have hk := keeps_drop hW ha.1
  unfold dropOwner at *
  simp only [oforget_as_filter] at he ⊢
  unfold ocstep
  split
  · rename_i op _
    have hs := okstep_filter hk op s
    have ht := okstep_filter hk op t
    rw [he] at hs
    rw [hs] at ht
    simp only [Prod.mk.injEq] at ht
    exact ht.2
  · exact he
  · rename_i f _
    rw [← oflush_filter, ← oflush_filter, ← orecord_filter hk.1, ← orecord_filter hk.1, he]
  · rename_i u _
    rw [← oforget_filter, ← oforget_filter, he]

theorem drop_reply (ord : List TLabel → List TLabel) {v : List Nat} {c : OKCmd N V} (ha : OwnerAllowed v c)
    (hv : notOwner v c.scope c.scope = true) {s t : OState N V} (he : dropOwner v s = dropOwner v t) :
    ocreply ord c s = ocreply ord c t := by
  have hW : c.scope.2 ≠ .user v := by simpa [notOwner] using hv
  have hk := keeps_drop hW ha.1
  unfold dropOwner at he
  simp only [oforget_as_filter] at he
  unfold ocreply
  split
  · rename_i op _
    have hs := okstep_filter hk op s
    have ht := okstep_filter hk op t
    rw [he] at hs
    rw [hs] at ht
    simp only [Prod.mk.injEq] at ht
    rw [ht.1]
  · rename_i q _
    rw [← oreply_filter ord q hk s, he, oreply_filter ord q hk t]
  · rfl
  · rename_i u hop
    have huv := (ha.2 u hop).1
    have key : ∀ x : OState N V, (x.copies.filter (fun c => c.scope.2 == .user u)).length =
        ((ofilter (fun d => d.2 != .user v) x).copies.filter (fun c => c.scope.2 == .user u)).length := by
      intro x
      unfold ofilter
      simp only
      rw [List.filter_filter]
      congr 1
      apply List.filter_congr
      intro c _
      cases h : c.scope.2 == .user u with
      | false => simp
      | true =>
        have e : c.scope.2 = .user u := by simpa using h
        have : (c.scope.2 != .user v) = true := by
          rw [e]
          simp only [bne_iff_ne, ne_eq, Owner.user.injEq]
          exact huv
        simp [this]
    rw [key s, key t, he]

theorem owner_isolation_history (ord : List TLabel → List TLabel) (v : List Nat) (R : Scope) (cs : List (OKCmd N V))
    (ha : ∀ c ∈ cs, OwnerAllowed v c) (s t : OState N V) (he : dropOwner v s = dropOwner v t) :
    outsK (notOwner v) OKCmd.scope ocstep (ocreply ord) R cs s =
      outsK (notOwner v) OKCmd.scope ocstep (ocreply ord) R (purgeK (notOwner v) OKCmd.scope R cs) t :=
  unwindingK (notOwner v) OKCmd.scope ocstep (ocreply ord) R (OwnerAllowed v) (dropOwner v)
    (fun c s hc hv => drop_local (c := c) hc (by simpa [notOwner] using hv) s)
    (fun c _ _ hc he hv => drop_consistent (c := c) hc (by simpa [notOwner] using hv) he)
    (fun c _ _ hc he hv => drop_reply ord (c := c) hc (by simpa [notOwner] using hv) he) cs ha s t he

theorem owner_isolation_purge (ord : List TLabel → List TLabel) (v : List Nat) (R : Scope) (cs : List (OKCmd N V))
    (ha : ∀ c ∈ cs, OwnerAllowed v c) (s : OState N V) :
    outsK (notOwner v) OKCmd.scope ocstep (ocreply ord) R cs s =
      outsK (notOwner v) OKCmd.scope ocstep (ocreply ord) R (cs.filter (fun c => c.scope.2 != .user v)) s :=
  owner_isolation_history ord v R cs ha s s rfl

theorem owner_isolation_state {u v : List Nat} (huv : u ≠ v) (r : TLabel) (s : OState N V) :
    orestrict (r, .user u) (dropOwner v s) = orestrict (r, .user u) s := by
  unfold dropOwner
  rw [oforget_as_filter]
  exact restrict_filter_keeps (keeps_drop (by simpa using huv) (by simp)) s

end OwnerKeyPurge

end Labels
