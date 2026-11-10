import Labels.Arrival
import Labels.Owner

namespace Labels

def errInvalidOwner : String := "ERR invalid owner"
def errOwnerRequired : String := "ERR this login must name an owner with every command"
def errOwnerContext : String := "ERR the owner differs from the context's owner"
def errOwnerBound : String := "ERR this connection is bound to another owner"

inductive Pick where
  | none
  | text (t : List Nat)
  | shared
deriving DecidableEq, Repr

inductive TokOwner where
  | none
  | shared
  | owner (t : List Nat)
deriving DecidableEq, Repr

structure OConn where
  pinned : Bool
  pin : Owner
  owner : Owner
  wany : Bool
  wmixed : Bool
  wlabel : TLabel
  wowner : Owner
deriving DecidableEq, Repr

def oconnFresh : OConn := ⟨false, .shared, .shared, false, false, tbottom, .shared⟩

structure OEnv where
  rules : List (List Nat × ORules)
  tokens : List (Nat × TokOwner)

structure ODyn where
  conns : List (Nat × OConn)
  ctxs : List (Nat × Owner)

def orulesOf (OE : OEnv) (login : List Nat) : ORules := ((OE.rules.find? (·.1 == login)).map (·.2)).getD noORules

def oconnOf (OD : ODyn) (id : Nat) : OConn := ((OD.conns.find? (·.1 == id)).map (·.2)).getD oconnFresh

def setOConn (OD : ODyn) (id : Nat) (c : OConn) : ODyn :=
  { OD with conns := if OD.conns.any (·.1 == id) then OD.conns.map (fun p => if p.1 == id then (id, c) else p) else OD.conns ++ [(id, c)] }

def ctxOwner (OD : ODyn) (h : Nat) : Owner := ((OD.ctxs.find? (·.1 == h)).map (·.2)).getD .shared

def cmdExists (args : List Arg) : Bool := known args || isCmd args "owners"

def hkO (args : List Arg) : Bool := housekeeping args && (!isCmd args "owners" || argIs args 1 "help")

def ownerTop (args : List Arg) : Bool := topOnly args || (isCmd args "owners" && !argIs args 1 "help")

def implicitOwner (r : ORules) : Option Owner :=
  match r.kind with
  | .none => some .shared
  | .fixed v => some (.user v)
  | .any => none

def tokenOwner (r : ORules) : TokOwner → Except String (Owner × Bool)
  | .none => if r.kind == .any then .error errToken else .ok (.shared, false)
  | .shared => if mayAct r .shared then .ok (.shared, true) else .error errToken
  | .owner t => if textValid t && mayActText r t then .ok (.user t, true) else .error errToken

def explicitOwner (r : ORules) : Pick → Except String Owner
  | .shared => if mayAct r .shared then .ok .shared else .error errInvalidOwner
  | .text t => if textValid t && mayActText r t then .ok (.user t) else .error errInvalidOwner
  | .none => .error errInvalidOwner

def credTok (r : ORules) (ctx : Option Owner) (t : TokOwner) : Except String (Option Owner) :=
  match tokenOwner r t with
  | .error m => .error m
  | .ok (o, true) =>
    match ctx with
    | some co => if o == co then .ok (some o) else .error errToken
    | none => .ok (some o)
  | .ok (_, false) =>
    match ctx with
    | some co => if implicitOwner r == some co then .ok none else .error errToken
    | none => .ok none

def credCtx (r : ORules) (pick : Pick) (co : Owner) : Except String (Option Owner) :=
  if !mayAct r co then .error errContext
  else match pick with
    | .shared => if co == .shared then .ok (some co) else .error errOwnerContext
    | .text t => if co == .user t then .ok (some co) else .error errOwnerContext
    | .none => .ok (some co)

def credPick (r : ORules) : Pick → Except String (Option Owner)
  | .none => .ok none
  | p =>
    match explicitOwner r p with
    | .error m => .error m
    | .ok o => .ok (some o)

def credential (r : ORules) (pick : Pick) (ctx : Option Owner) (tok : Option TokOwner) : Except String (Option Owner) :=
  match tok, ctx with
  | some t, _ => credTok r ctx t
  | none, some co => credCtx r pick co
  | none, none => credPick r pick

def resolveOwner (r : ORules) (oc : OConn) (inMulti : Bool) (inner : List Arg) : Option Owner → Except String Owner
  | some o => .ok o
  | none =>
    if inMulti then .ok oc.owner
    else match r.kind with
      | .none => .ok .shared
      | .fixed v => .ok (.user v)
      | .any =>
        if hkO inner then .ok .shared
        else if r.operator && needsSession inner then .ok .every
        else .error errOwnerRequired

def bindOwner (oc : OConn) (inMulti : Bool) (inner : List Arg) (o : Owner) : OConn :=
  if inMulti then oc
  else { oc with owner := o, pinned := oc.pinned || needsSession inner, pin := if !oc.pinned && needsSession inner then o else oc.pin }

def ownerPhase (r : ORules) (oc : OConn) (inMulti : Bool) (inner : List Arg) (topLabel : Bool)
    (pick : Pick) (ctx : Option Owner) (tok : Option TokOwner) : Except String (Owner × OConn) :=
  if ownerTop inner && !(topLabel && r.operator) then .error errTop
  else
    match credential r pick ctx tok with
    | .error m => .error m
    | .ok named =>
      match resolveOwner r oc inMulti inner named with
      | .error m => .error m
      | .ok o =>
        if named.isSome && oc.pinned && o != oc.pin then .error errOwnerBound
        else if named.isSome && inMulti && o != oc.owner then .error errTransaction
        else .ok (o, bindOwner oc inMulti inner o)

structure PO where
  used : Nat
  label : Option TLabel
  ctx : Option ACtx
  pick : Pick
  tok : Option TokOwner

def tokOf (OE : OEnv) (args : List Arg) : TokOwner :=
  match (args[3]? : Option Arg) with
  | some (Arg.token n) => ((OE.tokens.find? (·.1 == n)).map (·.2)).getD .none
  | _ => .none

def pickAt (args : List Arg) (i : Nat) : Pick × Nat :=
  if decide (i + 2 < args.length) && argIs args i "owner" then (.text ((args[i + 1]?.bind argBytes).getD []), i + 2)
  else if decide (i + 1 < args.length) && argIs args i "shared" then (.shared, i + 1)
  else (.none, i)

def ownerOnlyForm (E : AEnv) (D : ADyn) (c : AConn) (args : List Arg) (pick : Pick) (i : Nat) : Except String PO × ADyn :=
  match args[i]?, args[i + 1]? with
  | some a, some h =>
    if decide (i + 2 < args.length) && isWord a "context" && shaped h then
      if (rulesOf E c.login).requireToken then (.error errTokenOnly, D)
      else
        match tailFind E D c.login h (sessionOf E c) (i + 2) with
        | (.error m, D1) => (.error m, D1)
        | (.ok p, D1) => (.ok ⟨p.used, some p.label, p.ctx, pick, none⟩, D1)
    else (.ok ⟨i, none, none, pick, none⟩, D)
  | _, _ => (.ok ⟨i, none, none, pick, none⟩, D)

def markingFormO (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) : Except String PO × ADyn :=
  match markingLabel E args with
  | none => (.error errInvalid, D)
  | some l =>
    if !ceilingAdmits (ceilingFor E login) l then (.error errInvalid, D)
    else
      match markingEnd args (contextTail E D login args (pickAt args (if hasTrust args then 5 else 3)).2 l) with
      | (.error m, D1) => (.error m, D1)
      | (.ok p, D1) => (.ok ⟨p.used, some p.label, p.ctx, (pickAt args (if hasTrust args then 5 else 3)).1, none⟩, D1)

def labelAsParseO (E : AEnv) (OE : OEnv) (D : ADyn) (c : AConn) (args : List Arg) : Except String PO × ADyn :=
  if args.length ≤ 2 then (.error errWrongArgs, D)
  else if argIs args 2 "token" && decide (4 < args.length) then
    match tokenForm E D c.login args with
    | (.error m, D1) => (.error m, D1)
    | (.ok p, D1) => (.ok ⟨p.used, some p.label, p.ctx, .none, some (tokOf OE args)⟩, D1)
  else if argIs args 2 "owner" && decide (4 < args.length) then
    ownerOnlyForm E D c args (.text ((args[3]?.bind argBytes).getD [])) 4
  else if argIs args 2 "shared" && decide (3 < args.length) then ownerOnlyForm E D c args .shared 3
  else if (rulesOf E c.login).requireToken then (.error errTokenOnly, D)
  else if argIs args 2 "context" && decide (4 < args.length) && (args[3]?.map shaped).getD false then
    match contextForm E D c.login args with
    | (.error m, D1) => (.error m, D1)
    | (.ok p, D1) => (.ok ⟨p.used, some p.label, p.ctx, .none, none⟩, D1)
  else markingFormO E D c.login args

def ruleRefusal (E : AEnv) (c : AConn) (inner : List Arg) : Option String :=
  if ((rulesOf E c.login).perCommand || (rulesOf E c.login).requireToken) && !c.inMulti && !hkO inner then
    some (if (rulesOf E c.login).requireToken then errTokenOnly else errPerCommand)
  else none

structure LabelStep where
  arrival : Arrival
  dyn : ADyn
  pick : Pick
  tok : Option TokOwner

def labelStepO (E : AEnv) (OE : OEnv) (D : ADyn) (id : Nat) (c : AConn) (args : List Arg) : LabelStep :=
  if isLabelAs args then
    match labelAsParseO E OE D c args with
    | (.error m, D1) => ⟨(refuse D1 id c args m).1, (refuse D1 id c args m).2, .none, none⟩
    | (.ok p, D1) =>
      if nested (args.drop p.used) then ⟨(refuse D1 id c args errNested).1, (refuse D1 id c args errNested).2, .none, none⟩
      else
        match p.label with
        | some l =>
          ⟨(arriveCore E D1 id c (args.drop p.used) l p.ctx true).1, (arriveCore E D1 id c (args.drop p.used) l p.ctx true).2, p.pick, p.tok⟩
        | none =>
          match ruleRefusal E c (args.drop p.used) with
          | some m => ⟨(refuse D1 id c (args.drop p.used) m).1, (refuse D1 id c (args.drop p.used) m).2, .none, none⟩
          | none =>
            ⟨(arriveCore E D1 id c (args.drop p.used) (sessionOf E c) none false).1,
             (arriveCore E D1 id c (args.drop p.used) (sessionOf E c) none false).2, p.pick, none⟩
  else
    match ruleRefusal E c args with
    | some m => ⟨(refuse D id c args m).1, (refuse D id c args m).2, .none, none⟩
    | none => ⟨(arriveCore E D id c args (sessionOf E c) none false).1, (arriveCore E D id c args (sessionOf E c) none false).2, .none, none⟩

inductive ArrivalO where
  | ok (l : TLabel) (o : Owner) (inner : List Arg) (ctx : Option ACtx)
  | refused (msg : String)
deriving DecidableEq, Repr

def mayKill (ownersOn top : Bool) (r : TLabel) (operator : Bool) (o : Owner) (s : TLabel) (so : Owner) : Bool :=
  top || (domT r s && (!ownersOn || operator || o == so))

def oclear (oc : OConn) : OConn := { oc with wany := false, wmixed := false }

def arrivalMsg : Arrival → String
  | .refused m => m
  | .ok _ _ _ => ""

def afterRefusal (OD : ODyn) (id : Nat) (oc : OConn) (m : String) : ODyn :=
  if m.startsWith "EXECABORT" then setOConn OD id (oclear oc) else OD

def topLabelOf (E : AEnv) (l : TLabel) : Bool := domT l (ttop E.cfg.base.levels.length E.cfg.base.comps.length)

def pinIn (D : ADyn) (id : Nat) (c : AConn) (inner : List Arg) (l : TLabel) : ADyn :=
  setConn D id (pinConn ((connOf D id).getD c) inner l)

def arriveO (E : AEnv) (OE : OEnv) (D : ADyn) (OD : ODyn) (id : Nat) (args : List Arg) : ArrivalO × ADyn × ODyn :=
  match connOf D id with
  | none => (.refused "no connection", D, OD)
  | some c =>
    match labelStepO E OE D id c args with
    | ⟨.refused m, D1, _, _⟩ => (.refused m, D1, afterRefusal OD id (oconnOf OD id) m)
    | ⟨.ok l inner ctx, D1, pick, tok⟩ =>
      if !cmdExists inner then (.ok l .shared inner ctx, D1, OD) else
      match ownerPhase (orulesOf OE c.login) (oconnOf OD id) c.inMulti inner (topLabelOf E l) pick
          (ctx.map (fun x => ctxOwner OD x.handle)) tok with
      | .error m =>
        (.refused (arrivalMsg (refuse D1 id ((connOf D1 id).getD c) inner m).1), (refuse D1 id ((connOf D1 id).getD c) inner m).2,
         afterRefusal OD id (oconnOf OD id) (arrivalMsg (refuse D1 id ((connOf D1 id).getD c) inner m).1))
      | .ok (o, oc') => (.ok l o inner ctx, pinIn D1 id c inner l, setOConn OD id oc')

inductive ReplyO where
  | base (r : Reply)
  | info (l : TLabel) (o : Owner)
deriving DecidableEq, Repr

def createOptsO : List Arg → Option (List Nat) → Option (List Nat) → Option Pick →
    Option (Option (List Nat) × Option (List Nat) × Option Pick)
  | [], lv, tr, pk => some (lv, tr, pk)
  | a :: rest, lv, tr, pk =>
    if pk.isNone && isWord a "shared" then createOptsO rest lv tr (some .shared)
    else
      match rest with
      | [] => none
      | v :: rest' =>
        if isWord a "level" && lv.isNone then createOptsO rest' (some ((argBytes v).getD [255])) tr pk
        else if isWord a "trust" && tr.isNone then createOptsO rest' lv (some ((argBytes v).getD [255])) pk
        else if pk.isNone && isWord a "owner" then createOptsO rest' lv tr (some (.text ((argBytes v).getD [])))
        else none

def createLabelFrom (E : AEnv) (l0 : TLabel) : Option (List Nat) × Option (List Nat) → Except String TLabel
  | (some m, tr) =>
    match parseWithTrust E.cfg m tr with
    | none => .error errInvalid
    | some p => .ok (if tr.isNone && !m.contains 59 then { p with trust := l0.trust } else p)
  | (none, some t) =>
    match findName E.cfg.trusts t with
    | none => .error errInvalid
    | some k => .ok { l0 with trust := k }
  | (none, none) => .ok l0

def createOwner (r : ORules) (o0 : Owner) : Option Pick → Except String Owner
  | none => .ok o0
  | some p => explicitOwner r p

def contextCreateO (E : AEnv) (D : ADyn) (OD : ODyn) (c : AConn) (r : ORules) (l0 : TLabel) (o0 : Owner) (opts : List Arg) :
    ReplyO × ADyn × ODyn :=
  match createOptsO opts none none none with
  | none => (.base (.err errSyntax), D, OD)
  | some (lv, tr, pk) =>
    match createLabelFrom E l0 (lv, tr) with
    | .error e => (.base (.err e), D, OD)
    | .ok l =>
      if !labelValidT E.cfg l || !ceilingAdmits (ceilingFor E c.login) l then (.base (.err errInvalid), D, OD)
      else
        match createOwner r o0 pk with
        | .error m => (.base (.err m), D, OD)
        | .ok o =>
          match ctxCreate E.idle E.now E.cap D.next D.ctxs c.login (ceilingFor E c.login) l (labelValidT E.cfg l) with
          | (.created h, cs, n) => (.base (.handle h), { D with ctxs := cs, next := n }, { OD with ctxs := OD.ctxs ++ [(h, o)] })
          | (.invalid, _, _) => (.base (.err errInvalid), D, OD)
          | (.full, _, _) => (.base (.err errCap), D, OD)

def contextUseO (E : AEnv) (D : ADyn) (OD : ODyn) (c : AConn) (inner : List Arg) : ReplyO × ADyn :=
  if inner.length ≠ 3 then (.base (.err (wrongArgs (if argIs inner 1 "info" then "context|info" else "context|drop"))), D)
  else match inner[2]? with
    | none => (.base (.err errContext), D)
    | some h =>
      match findIn E D c.login (hrefOf h) with
      | (none, D1) => (.base (.err errContext), D1)
      | (some x, D1) =>
        if argIs inner 1 "drop" then (.base .ok, { D1 with ctxs := ctxRemove D1.ctxs x.handle })
        else (.info x.label (ctxOwner OD x.handle), D1)

def execReplyO (c : AConn) (oc : OConn) : Reply :=
  if c.dirty then .err errExecDirty
  else if oc.wany && (oc.wmixed || oc.wlabel != c.bound || oc.wowner != oc.owner) then .err errExecWatch
  else if c.cas then .nil
  else .exec

def onote (oc : OConn) (l : TLabel) (o : Owner) : OConn :=
  if !oc.wany then { oc with wany := true, wlabel := l, wowner := o }
  else if oc.wlabel != l || oc.wowner != o then { oc with wmixed := true }
  else oc

def handleO (E : AEnv) (OE : OEnv) (D : ADyn) (OD : ODyn) (id : Nat) (l : TLabel) (o : Owner) (inner : List Arg) :
    ReplyO × ADyn × ODyn :=
  match connOf D id with
  | none => (.base .none, D, OD)
  | some c =>
    if c.inMulti && !immediate inner then (.base .queued, D, OD)
    else if isCmd inner "exec" && c.inMulti then
      (.base (execReplyO c (oconnOf OD id)), setConn D id (endTx c), setOConn OD id (oclear (oconnOf OD id)))
    else if isCmd inner "discard" && c.inMulti then (.base .ok, setConn D id (endTx c), setOConn OD id (oclear (oconnOf OD id)))
    else if isCmd inner "watch" && !c.inMulti then
      (.base .ok, setConn D id (watchConn c l (inner.drop 1)), setOConn OD id (onote (oconnOf OD id) l o))
    else if isCmd inner "unwatch" then (.base .ok, setConn D id (clearWatch c), setOConn OD id (oclear (oconnOf OD id)))
    else if isCmd inner "context" && argIs inner 1 "create" then contextCreateO E D OD c (orulesOf OE c.login) l o (inner.drop 2)
    else if isCmd inner "context" && (argIs inner 1 "info" || argIs inner 1 "drop") then
      ((contextUseO E D OD c inner).1, (contextUseO E D OD c inner).2, OD)
    else (.base (handleCmd E D id l inner).1, (handleCmd E D id l inner).2, OD)

def requestO (E : AEnv) (OE : OEnv) (D : ADyn) (OD : ODyn) (id : Nat) (args : List Arg) : ArrivalO × ReplyO × ADyn × ODyn :=
  match arriveO E OE D OD id args with
  | (.ok l o inner x, D1, OD1) =>
    ((.ok l o inner x), (handleO E OE D1 OD1 id l o inner).1, (handleO E OE D1 OD1 id l o inner).2.1,
     (handleO E OE D1 OD1 id l o inner).2.2)
  | (a, D1, OD1) => (a, .base .none, D1, OD1)

def authO (D : ADyn) (OD : ODyn) (id : Nat) (login : List Nat) : ADyn × ODyn :=
  match connOf D id with
  | none => (D, OD)
  | some c =>
    if c.login == login then (D, OD)
    else (auth D id login, setOConn OD id { oconnOf OD id with pinned := false, pin := .shared })

theorem tokenOwner_named {r : ORules} {t : TokOwner} {o : Owner} (h : tokenOwner r t = .ok (o, true)) :
    mayAct r o = true := by
  cases t with
  | none =>
    simp only [tokenOwner] at h
    split at h <;> simp at h
  | shared =>
    simp only [tokenOwner] at h
    split at h
    · rename_i hs
      simp only [Except.ok.injEq, Prod.mk.injEq] at h
      rw [← h.1]
      exact hs
    · simp at h
  | owner u =>
    simp only [tokenOwner] at h
    split at h
    · rename_i hv
      simp only [Except.ok.injEq, Prod.mk.injEq] at h
      rw [← h.1]
      exact (band_both hv).2
    · simp at h

theorem explicitOwner_within {r : ORules} {p : Pick} {o : Owner} (h : explicitOwner r p = .ok o) : mayAct r o = true := by
  cases p with
  | none => simp [explicitOwner] at h
  | shared =>
    simp only [explicitOwner] at h
    split at h
    · rename_i hs
      simp only [Except.ok.injEq] at h
      rw [← h]
      exact hs
    · simp at h
  | text t =>
    simp only [explicitOwner] at h
    split at h
    · rename_i hv
      simp only [Except.ok.injEq] at h
      rw [← h]
      exact (band_both hv).2
    · simp at h

theorem credTok_some {r : ORules} {ctx : Option Owner} {t : TokOwner} {o : Owner} (h : credTok r ctx t = .ok (some o)) :
    tokenOwner r t = .ok (o, true) := by
  unfold credTok at h
  split at h
  · simp at h
  · rename_i o' ht
    split at h
    · split at h
      · simp only [Except.ok.injEq, Option.some.injEq] at h
        rw [← h]
        exact ht
      · simp at h
    · simp only [Except.ok.injEq, Option.some.injEq] at h
      rw [← h]
      exact ht
  · split at h
    · split at h <;> simp at h
    · simp at h

theorem credCtx_owner {r : ORules} {pick : Pick} {co : Owner} {n : Option Owner} (h : credCtx r pick co = .ok n) :
    n = some co ∧ mayAct r co = true := by
  unfold credCtx at h
  split at h
  · simp at h
  · rename_i hm
    have hco : mayAct r co = true := by simpa using hm
    split at h
    · split at h
      · simp only [Except.ok.injEq] at h
        exact ⟨h.symm, hco⟩
      · simp at h
    · split at h
      · simp only [Except.ok.injEq] at h
        exact ⟨h.symm, hco⟩
      · simp at h
    · simp only [Except.ok.injEq] at h
      exact ⟨h.symm, hco⟩

theorem credPick_some {r : ORules} {p : Pick} {o : Owner} (h : credPick r p = .ok (some o)) : explicitOwner r p = .ok o := by
  unfold credPick at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · rename_i o' he
      simp only [Except.ok.injEq, Option.some.injEq] at h
      rw [← h]
      exact he

theorem credential_within {r : ORules} {pick : Pick} {ctx : Option Owner} {tok : Option TokOwner} {o : Owner}
    (h : credential r pick ctx tok = .ok (some o)) : mayAct r o = true := by
  unfold credential at h
  split at h
  · exact tokenOwner_named (credTok_some h)
  · obtain ⟨h1, h2⟩ := credCtx_owner h
    simp only [Option.some.injEq] at h1
    rw [h1]
    exact h2
  · exact explicitOwner_within (credPick_some h)

theorem resolve_free {r : ORules} {oc : OConn} {inner : List Arg} {o : Owner}
    (h : resolveOwner r oc false inner none = .ok o) :
    mayAct r o = true ∨ (o = .shared ∧ r.kind = .any ∧ hkO inner = true) ∨
      (o = .every ∧ r.operator = true ∧ r.kind = .any ∧ needsSession inner = true) := by
  simp only [resolveOwner, Bool.false_eq_true, ↓reduceIte] at h
  split at h
  · rename_i hk
    simp at h
    subst h
    left
    simp [mayAct, hk]
  · rename_i v hk
    simp at h
    subst h
    left
    simp [mayAct, mayActText, hk]
  · rename_i hk
    split at h
    · rename_i hh
      simp at h
      subst h
      exact Or.inr (Or.inl ⟨rfl, hk, hh⟩)
    · split at h
      · rename_i hs
        simp at h
        subst h
        obtain ⟨h1, h2⟩ := band_both hs
        exact Or.inr (Or.inr ⟨rfl, h1, hk, h2⟩)
      · simp at h

theorem resolve_multi {r : ORules} {oc : OConn} {inner : List Arg} {o : Owner}
    (h : resolveOwner r oc true inner none = .ok o) : o = oc.owner := by
  simp [resolveOwner] at h
  exact h.symm

theorem ownerPhase_ok {r : ORules} {oc oc' : OConn} {m : Bool} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {tok : Option TokOwner} {o : Owner}
    (h : ownerPhase r oc m inner t pick ctx tok = .ok (o, oc')) :
    (ownerTop inner = true → t = true ∧ r.operator = true) ∧
    ∃ named, credential r pick ctx tok = .ok named ∧ resolveOwner r oc m inner named = .ok o ∧
      (named.isSome = true → oc.pinned = true → o = oc.pin) ∧
      (named.isSome = true → m = true → o = oc.owner) ∧ oc' = bindOwner oc m inner o := by
  unfold ownerPhase at h
  split at h
  · simp at h
  · rename_i htop
    split at h
    · simp at h
    · rename_i named hc
      split at h
      · simp at h
      · rename_i o' hr
        split at h
        · simp at h
        · rename_i hb
          split at h
          · simp at h
          · rename_i hm
            simp only [Except.ok.injEq, Prod.mk.injEq] at h
            obtain ⟨rfl, rfl⟩ := h
            refine ⟨fun ho => ?_, named, hc, hr, fun hn hp => ?_, fun hn hmm => ?_, rfl⟩
            · by_cases h1 : t = true
              · by_cases h2 : r.operator = true
                · exact ⟨h1, h2⟩
                · exfalso
                  apply htop
                  simp [ho, h1, h2]
              · exfalso
                apply htop
                simp [ho, h1]
            · simp only [hn, hp, Bool.true_and, bne_iff_ne, ne_eq, Decidable.not_not] at hb
              exact hb
            · simp only [hn, hmm, Bool.true_and, bne_iff_ne, ne_eq, Decidable.not_not] at hm
              exact hm

theorem owner_arrival_within {r : ORules} {oc oc' : OConn} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {tok : Option TokOwner} {o : Owner}
    (h : ownerPhase r oc false inner t pick ctx tok = .ok (o, oc')) :
    mayAct r o = true ∨ (o = .shared ∧ r.kind = .any ∧ hkO inner = true) ∨
      (o = .every ∧ r.operator = true ∧ r.kind = .any ∧ needsSession inner = true) := by
  obtain ⟨_, named, hc, hr, _, _, _⟩ := ownerPhase_ok h
  cases named with
  | none => exact resolve_free hr
  | some o' =>
    simp [resolveOwner] at hr
    subst hr
    exact Or.inl (credential_within hc)

theorem owner_required {r : ORules} {oc : OConn} {inner : List Arg} {t : Bool}
    (hk : r.kind = .any) (hh : hkO inner = false) (hs : (r.operator && needsSession inner) = false)
    (ht : (ownerTop inner && !(t && r.operator)) = false) :
    ownerPhase r oc false inner t .none none none = .error errOwnerRequired := by
  unfold ownerPhase
  rw [ht]
  simp [credential, credPick, resolveOwner, hk, hh, hs]

theorem tokenOwner_owner {r : ORules} {u : List Nat} {o : Owner} {b : Bool} (h : tokenOwner r (.owner u) = .ok (o, b)) :
    o = .user u ∧ b = true := by
  simp only [tokenOwner] at h
  split at h
  · simp only [Except.ok.injEq, Prod.mk.injEq] at h
    exact ⟨h.1.symm, h.2.symm⟩
  · simp at h

theorem tokenOwner_shared {r : ORules} {o : Owner} {b : Bool} (h : tokenOwner r .shared = .ok (o, b)) :
    o = .shared ∧ b = true := by
  simp only [tokenOwner] at h
  split at h
  · simp only [Except.ok.injEq, Prod.mk.injEq] at h
    exact ⟨h.1.symm, h.2.symm⟩
  · simp at h

theorem credTok_named {r : ORules} {ctx : Option Owner} {t : TokOwner} {n : Option Owner} {o : Owner}
    (hn : ∀ o' b, tokenOwner r t = .ok (o', b) → o' = o ∧ b = true) (h : credTok r ctx t = .ok n) : n = some o := by
  unfold credTok at h
  split at h
  · simp at h
  · rename_i o' ht
    obtain ⟨rfl, _⟩ := hn _ _ ht
    split at h
    · split at h
      · simp only [Except.ok.injEq] at h
        exact h.symm
      · simp at h
    · simp only [Except.ok.injEq] at h
      exact h.symm
  · rename_i o' ht
    have := (hn _ _ ht).2
    simp at this

theorem owner_of_context {r : ORules} {oc oc' : OConn} {m : Bool} {inner : List Arg} {t : Bool} {pick : Pick}
    {co o : Owner} (h : ownerPhase r oc m inner t pick (some co) none = .ok (o, oc')) : o = co := by
  obtain ⟨_, named, hc, hr, _, _, _⟩ := ownerPhase_ok h
  simp only [credential] at hc
  obtain ⟨rfl, _⟩ := credCtx_owner hc
  simp [resolveOwner] at hr
  exact hr.symm

theorem owner_of_token {r : ORules} {oc oc' : OConn} {m : Bool} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {u : List Nat} {o : Owner}
    (h : ownerPhase r oc m inner t pick ctx (some (.owner u)) = .ok (o, oc')) : o = .user u := by
  obtain ⟨_, named, hc, hr, _, _, _⟩ := ownerPhase_ok h
  simp only [credential] at hc
  have := credTok_named (fun o' b ht => tokenOwner_owner ht) hc
  subst this
  simp [resolveOwner] at hr
  exact hr.symm

theorem owner_of_shared_token {r : ORules} {oc oc' : OConn} {m : Bool} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {o : Owner}
    (h : ownerPhase r oc m inner t pick ctx (some .shared) = .ok (o, oc')) : o = .shared := by
  obtain ⟨_, named, hc, hr, _, _, _⟩ := ownerPhase_ok h
  simp only [credential] at hc
  have := credTok_named (fun o' b ht => tokenOwner_shared ht) hc
  subst this
  simp [resolveOwner] at hr
  exact hr.symm

theorem pinned_owner_fixed {r : ORules} {oc oc' : OConn} {m : Bool} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {tok : Option TokOwner} {o o' : Owner} (hp : oc.pinned = true)
    (hn : credential r pick ctx tok = .ok (some o')) (h : ownerPhase r oc m inner t pick ctx tok = .ok (o, oc')) :
    o = oc.pin ∧ oc'.pinned = true ∧ oc'.pin = oc.pin := by
  obtain ⟨_, named, hc, _, hpin, _, hb⟩ := ownerPhase_ok h
  rw [hn] at hc
  simp at hc
  subst hc
  refine ⟨hpin rfl hp, ?_⟩
  subst hb
  unfold bindOwner
  split <;> simp [hp]

theorem pin_stable {r : ORules} {oc oc' : OConn} {m : Bool} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {tok : Option TokOwner} {o : Owner} (hp : oc.pinned = true)
    (h : ownerPhase r oc m inner t pick ctx tok = .ok (o, oc')) : oc'.pinned = true ∧ oc'.pin = oc.pin := by
  obtain ⟨_, _, _, _, _, _, hb⟩ := ownerPhase_ok h
  subst hb
  unfold bindOwner
  split <;> simp [hp]

theorem push_pins_owner {r : ORules} {oc oc' : OConn} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {tok : Option TokOwner} {o : Owner} (hs : needsSession inner = true)
    (h : ownerPhase r oc false inner t pick ctx tok = .ok (o, oc')) :
    oc'.pinned = true ∧ (oc.pinned = false → oc'.pin = o) ∧ oc'.owner = o := by
  obtain ⟨_, _, _, _, _, _, hb⟩ := ownerPhase_ok h
  subst hb
  refine ⟨by simp [bindOwner, hs], fun hp => by simp [bindOwner, hs, hp], by simp [bindOwner]⟩

theorem multi_binds_owner {r : ORules} {oc oc' : OConn} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {tok : Option TokOwner} {o : Owner}
    (h : ownerPhase r oc true inner t pick ctx tok = .ok (o, oc')) : o = oc.owner ∧ oc' = oc := by
  obtain ⟨_, named, _, hr, _, hm, hb⟩ := ownerPhase_ok h
  refine ⟨?_, by rw [hb]; simp [bindOwner]⟩
  cases named with
  | none => exact resolve_multi hr
  | some _ => exact hm rfl rfl

theorem owner_top_needs_operator {r : ORules} {oc oc' : OConn} {m : Bool} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {tok : Option TokOwner} {o : Owner} (ho : ownerTop inner = true)
    (h : ownerPhase r oc m inner t pick ctx tok = .ok (o, oc')) : t = true ∧ r.operator = true :=
  (ownerPhase_ok h).1 ho

theorem never_every_unless_operator_pin {r : ORules} {oc oc' : OConn} {inner : List Arg} {t : Bool} {pick : Pick}
    {ctx : Option Owner} {tok : Option TokOwner} (h : ownerPhase r oc false inner t pick ctx tok = .ok (.every, oc')) :
    r.operator = true ∧ r.kind = .any ∧ needsSession inner = true := by
  rcases owner_arrival_within h with h1 | ⟨h2, _⟩ | ⟨_, h3, h4, h5⟩
  · simp [mayAct] at h1
  · cases h2
  · exact ⟨h3, h4, h5⟩

theorem exec_owner_watch_refused {c : AConn} {oc : OConn} (hd : c.dirty = false) (hw : oc.wany = true)
    (ho : oc.wowner ≠ oc.owner) : execReplyO c oc = .err errExecWatch := by
  simp [execReplyO, hd, hw, ho]

theorem exec_owner_watch_data_free {c : AConn} {oc : OConn} (hd : c.dirty = false)
    (hw : (oc.wany && (oc.wmixed || oc.wlabel != c.bound || oc.wowner != oc.owner)) = true) (b : Bool) :
    execReplyO c oc = .err errExecWatch ∧ execReplyO { c with cas := b } oc = .err errExecWatch := by
  simp only [execReplyO, hd, hw]
  simp

theorem exec_same_scope {c : AConn} {oc : OConn} (hd : c.dirty = false)
    (hw : (oc.wany && (oc.wmixed || oc.wlabel != c.bound || oc.wowner != oc.owner)) = false) :
    execReplyO c oc = if c.cas then .nil else .exec := by
  simp [execReplyO, hd, hw]

theorem onote_scope (oc : OConn) (l : TLabel) (o : Owner) :
    (onote oc l o).wany = true ∧ ((onote oc l o).wmixed = true ∨ ((onote oc l o).wlabel = l ∧ (onote oc l o).wowner = o)) := by
  unfold onote
  split
  · simp
  · split
    · rename_i h1 _
      have hw : oc.wany = true := by simpa using h1
      simp [hw]
    · rename_i h1 h2
      have hw : oc.wany = true := by simpa using h1
      simp only [Bool.or_eq_true, bne_iff_ne, ne_eq, not_or, Decidable.not_not] at h2
      exact ⟨hw, Or.inr ⟨h2.1, h2.2⟩⟩

theorem onote_mixed_owner {oc : OConn} {l : TLabel} {o : Owner} (hw : oc.wany = true) (ho : oc.wowner ≠ o) :
    (onote oc l o).wmixed = true := by
  simp [onote, hw, ho]

theorem script_denies_owner_prefix {args : List Arg} (h1 : isCmd args "label" = true) (h2 : argIs args 1 "as" = true) :
    scriptDenied args = true := by
  unfold scriptDenied
  have hw : argIs args 1 "whoami" = false := by
    unfold argIs at h2 ⊢
    split at h2
    · rename_i a _
      cases a with
      | lit b =>
        simp only [isWord] at h2 ⊢
        rw [beq_iff_eq] at h2
        rw [h2]
        decide
      | handle _ => simp [isWord] at h2
      | token _ => simp [isWord] at h2
    · simp at h2
  have hh : argIs args 1 "help" = false := by
    unfold argIs at h2 ⊢
    split at h2
    · rename_i a _
      cases a with
      | lit b =>
        simp only [isWord] at h2 ⊢
        rw [beq_iff_eq] at h2
        rw [h2]
        decide
      | handle _ => simp [isWord] at h2
      | token _ => simp [isWord] at h2
    · simp at h2
  simp [h1, hw, hh]

theorem refuse_arrival_not_ok {D : ADyn} {id : Nat} {c : AConn} {a : List Arg} {m : String} {l : TLabel} {inner : List Arg}
    {x : Option ACtx} (h : (refuse D id c a m).1 = .ok l inner x) : False := by
  unfold refuse at h
  split at h <;> simp at h

theorem core_arrival_within {E : AEnv} {D : ADyn} {id : Nat} {c : AConn} {inner inner' : List Arg} {l0 l : TLabel}
    {ctx ctx' : Option ACtx} {p : Bool} (h : (arriveCore E D id c inner l0 ctx p).1 = .ok l inner' ctx') :
    ceilingAdmits (ceilingFor E c.login) l = true ∧ labelValidT E.cfg l = true := by
  have h' : arriveCore E D id c inner l0 ctx p = (.ok l inner' ctx', (arriveCore E D id c inner l0 ctx p).2) :=
    Prod.ext h rfl
  obtain ⟨h1, h2, _⟩ := core_spec h'
  exact ⟨h1, h2⟩

theorem labelStepO_within {E : AEnv} {OE : OEnv} {D : ADyn} {id : Nat} {c : AConn} {args inner : List Arg} {l : TLabel}
    {ctx : Option ACtx} (h : (labelStepO E OE D id c args).arrival = .ok l inner ctx) :
    ceilingAdmits (ceilingFor E c.login) l = true ∧ labelValidT E.cfg l = true := by
  unfold labelStepO at h
  split at h
  · split at h
    · exact (refuse_arrival_not_ok h).elim
    · split at h
      · exact (refuse_arrival_not_ok h).elim
      · split at h
        · exact core_arrival_within h
        · split at h
          · exact (refuse_arrival_not_ok h).elim
          · exact core_arrival_within h
  · split at h
    · exact (refuse_arrival_not_ok h).elim
    · exact core_arrival_within h

theorem arriveO_ok {E : AEnv} {OE : OEnv} {D D' : ADyn} {OD OD' : ODyn} {id : Nat} {args inner : List Arg} {l : TLabel}
    {o : Owner} {ctx : Option ACtx} (h : arriveO E OE D OD id args = (.ok l o inner ctx, D', OD')) :
    ∃ c, connOf D id = some c ∧ (labelStepO E OE D id c args).arrival = .ok l inner ctx ∧
      ((cmdExists inner = false ∧ o = .shared ∧ OD' = OD) ∨
       (cmdExists inner = true ∧ ∃ pick tok oc', ownerPhase (orulesOf OE c.login) (oconnOf OD id) c.inMulti inner (topLabelOf E l)
        pick (ctx.map (fun x => ctxOwner OD x.handle)) tok = .ok (o, oc') ∧ OD' = setOConn OD id oc')) := by
  unfold arriveO at h
  split at h
  · simp at h
  · rename_i c hc
    refine ⟨c, hc, ?_⟩
    split at h
    · simp at h
    · rename_i l1 inner1 ctx1 D1 pick tok hs
      split at h
      · rename_i hx
        simp only [Prod.mk.injEq, ArrivalO.ok.injEq] at h
        obtain ⟨⟨rfl, rfl, rfl, rfl⟩, rfl, rfl⟩ := h
        exact ⟨by rw [hs], Or.inl ⟨by simpa using hx, rfl, rfl⟩⟩
      · rename_i hx
        split at h
        · simp at h
        · rename_i o1 oc1 hp
          simp only [Prod.mk.injEq, ArrivalO.ok.injEq] at h
          obtain ⟨⟨rfl, rfl, rfl, rfl⟩, rfl, rfl⟩ := h
          exact ⟨by rw [hs], Or.inr ⟨by simpa using hx, pick, tok, oc1, hp, rfl⟩⟩

theorem arriveO_label_within {E : AEnv} {OE : OEnv} {D D' : ADyn} {OD OD' : ODyn} {id : Nat} {args inner : List Arg}
    {l : TLabel} {o : Owner} {ctx : Option ACtx} {c : AConn} (hc : connOf D id = some c)
    (h : arriveO E OE D OD id args = (.ok l o inner ctx, D', OD')) :
    ceilingAdmits (ceilingFor E c.login) l = true ∧ labelValidT E.cfg l = true := by
  obtain ⟨c', hc', hs, _⟩ := arriveO_ok h
  rw [hc] at hc'
  cases hc'
  exact labelStepO_within hs

theorem arriveO_owner_within {E : AEnv} {OE : OEnv} {D D' : ADyn} {OD OD' : ODyn} {id : Nat} {args inner : List Arg}
    {l : TLabel} {o : Owner} {ctx : Option ACtx} {c : AConn} (hc : connOf D id = some c) (hm : c.inMulti = false)
    (he : cmdExists inner = true) (h : arriveO E OE D OD id args = (.ok l o inner ctx, D', OD')) :
    mayAct (orulesOf OE c.login) o = true ∨ (o = .shared ∧ (orulesOf OE c.login).kind = .any ∧ hkO inner = true) ∨
      (o = .every ∧ (orulesOf OE c.login).operator = true ∧ (orulesOf OE c.login).kind = .any ∧ needsSession inner = true) := by
  obtain ⟨c', hc', _, hx⟩ := arriveO_ok h
  rw [hc] at hc'
  cases hc'
  rcases hx with ⟨hn, _, _⟩ | ⟨_, pick, tok, oc', hp, _⟩
  · rw [he] at hn
    cases hn
  · rw [hm] at hp
    exact owner_arrival_within hp

theorem arriveO_multi_owner {E : AEnv} {OE : OEnv} {D D' : ADyn} {OD OD' : ODyn} {id : Nat} {args inner : List Arg}
    {l : TLabel} {o : Owner} {ctx : Option ACtx} {c : AConn} (hc : connOf D id = some c) (hm : c.inMulti = true)
    (he : cmdExists inner = true) (h : arriveO E OE D OD id args = (.ok l o inner ctx, D', OD')) : o = (oconnOf OD id).owner := by
  obtain ⟨c', hc', _, hx⟩ := arriveO_ok h
  rw [hc] at hc'
  cases hc'
  rcases hx with ⟨hn, _, _⟩ | ⟨_, pick, tok, oc', hp, _⟩
  · rw [he] at hn
    cases hn
  · rw [hm] at hp
    exact (multi_binds_owner hp).1

theorem arriveO_context_owner {E : AEnv} {OE : OEnv} {D D' : ADyn} {OD OD' : ODyn} {id : Nat} {args inner : List Arg}
    {l : TLabel} {o : Owner} {x : ACtx} (he : cmdExists inner = true) (h : arriveO E OE D OD id args = (.ok l o inner (some x), D', OD'))
    (hn : ∀ c, connOf D id = some c → ∀ pick tok oc', ownerPhase (orulesOf OE c.login) (oconnOf OD id) c.inMulti inner
      (topLabelOf E l) pick (some (ctxOwner OD x.handle)) tok = .ok (o, oc') → tok = none) :
    o = ctxOwner OD x.handle := by
  obtain ⟨c, hc, _, hx⟩ := arriveO_ok h
  rcases hx with ⟨hn', _, _⟩ | ⟨_, pick, tok, oc', hp, _⟩
  · rw [he] at hn'
    cases hn'
  · have ht := hn c hc pick tok oc' hp
    subst ht
    exact owner_of_context hp

theorem kill_owners_off (t : Bool) (r s : TLabel) (op : Bool) (o so : Owner) :
    mayKill false t r op o s so = (t || domT r s) := by
  simp [mayKill]

theorem kill_needs_label {b op : Bool} {r s : TLabel} {o so : Owner} (h : mayKill b false r op o s so = true) :
    domT r s = true := by
  simp [mayKill] at h
  exact h.1

theorem kill_user_shared_refused (r s : TLabel) (u : List Nat) :
    mayKill true false r false (.user u) s .shared = false := by
  simp [mayKill]

theorem kill_other_user_refused {u v : List Nat} (h : u ≠ v) (r s : TLabel) :
    mayKill true false r false (.user u) s (.user v) = false := by
  simp [mayKill, h]

theorem kill_same_owner {b t op : Bool} {r s : TLabel} {o : Owner} (h : domT r s = true) : mayKill b t r op o s o = true := by
  simp [mayKill, h]

theorem kill_operator {b t : Bool} {r s : TLabel} {o so : Owner} (h : domT r s = true) : mayKill b t r true o s so = true := by
  simp [mayKill, h]

theorem kill_within_dominance {t op : Bool} {r s : TLabel} {o so : Owner} (h : mayKill true t r op o s so = true) :
    t = true ∨ seesP (r, if op then .every else o) (s, so) = true := by
  cases ht : t
  · right
    simp only [mayKill, ht, Bool.false_or, Bool.and_eq_true, Bool.not_true, Bool.false_or, Bool.or_eq_true,
      beq_iff_eq] at h
    obtain ⟨hd, hrest⟩ := h
    cases hop : op
    · simp only [hop, Bool.false_eq_true, false_or] at hrest
      subst hrest
      simp [seesP, hd, odom_refl]
    · simp [seesP, hd, odom_every]
  · exact Or.inl rfl

theorem kill_stronger_than_dominance (r : TLabel) (u : List Nat) :
    seesP (r, .user u) (r, .shared) = true ∧ mayKill true false r false (.user u) r .shared = false :=
  ⟨by simp [seesP, domT_refl, odom], kill_user_shared_refused r r u⟩

theorem conns_of_eq {α : Type} {x : α × ADyn} {r : α} {D1 D : ADyn} (hf : x = (r, D1)) (hx : x.2.conns = D.conns) :
    D1.conns = D.conns := by
  rw [hf] at hx
  exact hx

theorem tokenForm_conns (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    (tokenForm E D login args).2.conns = D.conns := by
  unfold tokenForm
  split
  · rfl
  · split
    · rename_i D1 hv
      exact tokenVerify_conns hv
    · rename_i l x D1 hv
      exact tokenVerify_conns hv

theorem contextForm_conns (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    (contextForm E D login args).2.conns = D.conns := by
  unfold contextForm
  split
  · rfl
  · split
    · rename_i D1 hf
      exact findIn_conns hf
    · rename_i x D1 hf
      exact findIn_conns hf

theorem ownerOnlyForm_conns (E : AEnv) (D : ADyn) (c : AConn) (args : List Arg) (pick : Pick) (i : Nat) :
    (ownerOnlyForm E D c args pick i).2.conns = D.conns := by
  unfold ownerOnlyForm
  split
  · split
    · split
      · rfl
      · split
        · rename_i _ _ m D1 hf
          exact conns_of_eq hf (tailFind_conns ..)
        · rename_i _ _ pp D1 hf
          exact conns_of_eq hf (tailFind_conns ..)
    · rfl
  · rfl

theorem markingFormO_conns (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    (markingFormO E D login args).2.conns = D.conns := by
  unfold markingFormO
  split
  · rfl
  · split
    · rfl
    · split
      · rename_i m D1 hf
        exact conns_of_eq hf (by rw [markingEnd_snd]; exact contextTail_conns ..)
      · rename_i pp D1 hf
        exact conns_of_eq hf (by rw [markingEnd_snd]; exact contextTail_conns ..)

theorem labelAsParseO_conns (E : AEnv) (OE : OEnv) (D : ADyn) (c : AConn) (args : List Arg) :
    (labelAsParseO E OE D c args).2.conns = D.conns := by
  unfold labelAsParseO
  split
  · rfl
  · split
    · split
      · rename_i m D1 hf
        have e := tokenForm_conns E D c.login args
        rw [hf] at e
        exact e
      · rename_i pp D1 hf
        have e := tokenForm_conns E D c.login args
        rw [hf] at e
        exact e
    · split
      · exact ownerOnlyForm_conns ..
      · split
        · exact ownerOnlyForm_conns ..
        · split
          · rfl
          · split
            · split
              · rename_i m D1 hf
                have e := contextForm_conns E D c.login args
                rw [hf] at e
                exact e
              · rename_i pp D1 hf
                have e := contextForm_conns E D c.login args
                rw [hf] at e
                exact e
            · exact markingFormO_conns ..

def StepConn (id : Nat) (c : AConn) (a : Arrival) (D : ADyn) : Prop :=
  ∃ c', connOf D id = some c' ∧ sessOf c' = sessOf c ∧ ∀ l inner ctx, a = .ok l inner ctx → c'.inMulti = c.inMulti

theorem refuse_step {D : ADyn} {id : Nat} {c c0 : AConn} (hc : connOf D id = some c0) (a : List Arg) (m : String) :
    StepConn id c (refuse D id c a m).1 (refuse D id c a m).2 := by
  obtain ⟨c', h1, h2⟩ := refuse_sess hc a m (c := c)
  exact ⟨c', h1, h2, fun _ _ _ h => (refuse_arrival_not_ok h).elim⟩

theorem core_step {E : AEnv} {D : ADyn} {id : Nat} {c c0 : AConn} {inner : List Arg} {l0 : TLabel}
    {ctx : Option ACtx} {p : Bool} (hc : connOf D id = some c0) :
    StepConn id c (arriveCore E D id c inner l0 ctx p).1 (arriveCore E D id c inner l0 ctx p).2 := by
  cases ha : (arriveCore E D id c inner l0 ctx p).1 with
  | refused m =>
    obtain ⟨c', h1, h2⟩ := core_refused_sess hc ha
    exact ⟨c', h1, h2, fun _ _ _ h => by cases h⟩
  | ok l inner' ctx' =>
    have h' : arriveCore E D id c inner l0 ctx p = (.ok l inner' ctx', (arriveCore E D id c inner l0 ctx p).2) :=
      Prod.ext ha rfl
    obtain ⟨_, _, _, _, _, _, hd, _⟩ := core_spec h'
    rw [hd]
    refine ⟨_, connOf_setConn hc _, sessOf_finishConn .., fun _ _ _ _ => ?_⟩
    unfold finishConn
    split <;> rfl

theorem labelStepO_step {E : AEnv} {OE : OEnv} {D : ADyn} {id : Nat} {c : AConn} {args : List Arg}
    (hc : connOf D id = some c) :
    StepConn id c (labelStepO E OE D id c args).arrival (labelStepO E OE D id c args).dyn := by
  unfold labelStepO
  split
  · split
    · rename_i m D1 hp
      have e := labelAsParseO_conns E OE D c args
      rw [hp] at e
      exact refuse_step (by rw [connOf_of_conns e]; exact hc) _ _
    · rename_i pp D1 hp
      have e := labelAsParseO_conns E OE D c args
      rw [hp] at e
      have hc1 : connOf D1 id = some c := by
        rw [connOf_of_conns e]
        exact hc
      split
      · exact refuse_step hc1 _ _
      · split
        · exact core_step hc1
        · split
          · exact refuse_step hc1 _ _
          · exact core_step hc1
  · split
    · exact refuse_step hc _ _
    · exact core_step hc

theorem labelStepO_sess {E : AEnv} {OE : OEnv} {D : ADyn} {id : Nat} {c : AConn} {args : List Arg}
    (hc : connOf D id = some c) :
    ∃ c', connOf (labelStepO E OE D id c args).dyn id = some c' ∧ sessOf c' = sessOf c := by
  obtain ⟨c', h1, h2, _⟩ := labelStepO_step (E := E) (OE := OE) (args := args) hc
  exact ⟨c', h1, h2⟩

theorem oconnOf_setOConn (OD : ODyn) (id : Nat) (oc : OConn) : oconnOf (setOConn OD id oc) id = oc := by
  unfold oconnOf setOConn
  split
  · rename_i hany
    cases hf : OD.conns.find? (·.1 == id) with
    | none =>
      rw [List.find?_eq_none] at hf
      obtain ⟨q, hq, hq1⟩ := List.any_eq_true.mp hany
      exact absurd hq1 (hf q hq)
    | some q =>
      rw [find_map_same oc hf]
      rfl
  · rename_i hany
    have hf : OD.conns.find? (·.1 == id) = none := by
      rw [List.find?_eq_none]
      intro q hq hq1
      exact hany (List.any_eq_true.mpr ⟨q, hq, hq1⟩)
    simp [List.find?_append, hf]

theorem afterRefusal_pin (OD : ODyn) (id : Nat) (m : String) :
    (oconnOf (afterRefusal OD id (oconnOf OD id) m) id).pinned = (oconnOf OD id).pinned ∧
      (oconnOf (afterRefusal OD id (oconnOf OD id) m) id).pin = (oconnOf OD id).pin := by
  unfold afterRefusal
  split
  · rw [oconnOf_setOConn]
    exact ⟨rfl, rfl⟩
  · exact ⟨rfl, rfl⟩

theorem arriveO_refused_keeps_pins {E : AEnv} {OE : OEnv} {D D' : ADyn} {OD OD' : ODyn} {id : Nat} {args : List Arg}
    {m : String} {c : AConn} (hc : connOf D id = some c) (h : arriveO E OE D OD id args = (.refused m, D', OD')) :
    (∃ c', connOf D' id = some c' ∧ sessOf c' = sessOf c) ∧
      (oconnOf OD' id).pinned = (oconnOf OD id).pinned ∧ (oconnOf OD' id).pin = (oconnOf OD id).pin := by
  obtain ⟨c1, hc1, hs1⟩ := labelStepO_sess (E := E) (OE := OE) (args := args) hc
  unfold arriveO at h
  rw [hc] at h
  simp only at h
  split at h
  · rename_i mm D1 pick tok hls
    simp only [Prod.mk.injEq] at h
    obtain ⟨_, rfl, rfl⟩ := h
    rw [hls] at hc1
    exact ⟨⟨c1, hc1, hs1⟩, afterRefusal_pin OD id mm⟩
  · rename_i l inner ctx D1 pick tok hls
    rw [hls] at hc1
    simp only at hc1
    split at h
    · simp at h
    · split at h
      · rename_i mm hp
        simp only [Prod.mk.injEq] at h
        obtain ⟨_, rfl, rfl⟩ := h
        obtain ⟨c2, h2, h3⟩ := refuse_sess hc1 inner mm (c := (connOf D1 id).getD c)
        rw [hc1] at h3
        exact ⟨⟨c2, h2, by rw [h3]; exact hs1⟩, afterRefusal_pin OD id _⟩
      · simp at h

theorem labelStepO_ok_conn {E : AEnv} {OE : OEnv} {D : ADyn} {id : Nat} {c : AConn} {args inner : List Arg}
    {l : TLabel} {ctx : Option ACtx} (hc : connOf D id = some c) (h : (labelStepO E OE D id c args).arrival = .ok l inner ctx) :
    ∃ c', connOf (labelStepO E OE D id c args).dyn id = some c' ∧ c'.explicit = c.explicit ∧ c'.inMulti = c.inMulti := by
  obtain ⟨c', h1, h2, h3⟩ := labelStepO_step (E := E) (OE := OE) (args := args) hc
  refine ⟨c', h1, ?_, h3 l inner ctx h⟩
  have := congrArg Prod.fst h2
  exact this

theorem arriveO_pins_push {E : AEnv} {OE : OEnv} {D D' : ADyn} {OD OD' : ODyn} {id : Nat} {args inner : List Arg}
    {l : TLabel} {o : Owner} {ctx : Option ACtx} {c : AConn} (hc : connOf D id = some c) (hm : c.inMulti = false)
    (hx : c.explicit = false) (hs : needsSession inner = true) (h : arriveO E OE D OD id args = (.ok l o inner ctx, D', OD')) :
    ∃ c', connOf D' id = some c' ∧ c'.explicit = true ∧ c'.session = l := by
  unfold arriveO at h
  rw [hc] at h
  simp only at h
  split at h
  · simp at h
  · rename_i l1 inner1 ctx1 D1 pick tok hls
    have hk : (labelStepO E OE D id c args).arrival = .ok l1 inner1 ctx1 := by rw [hls]
    obtain ⟨c1, hc1, he, hmm⟩ := labelStepO_ok_conn hc hk
    rw [hls] at hc1
    simp only at hc1
    split at h
    · rename_i hx'
      have : needsSession inner1 = false := by
        unfold needsSession
        cases hn : (["subscribe", "psubscribe", "ssubscribe"].any (isCmd inner1)) <;> simp_all [cmdExists, known, knownCommands]
      simp only [Prod.mk.injEq, ArrivalO.ok.injEq] at h
      obtain ⟨⟨_, _, rfl, _⟩, _, _⟩ := h
      rw [this] at hs
      cases hs
    · split at h
      · simp at h
      · simp only [Prod.mk.injEq, ArrivalO.ok.injEq] at h
        obtain ⟨⟨rfl, _, rfl, _⟩, rfl, _⟩ := h
        refine ⟨pinConn c1 inner1 l1, ?_, ?_, ?_⟩
        · unfold pinIn
          rw [hc1]
          exact connOf_setConn hc1 _
        · simp [pinConn, hmm, hm, hs, he, hx]
        · simp [pinConn, hmm, hm, hs, he, hx]

end Labels
