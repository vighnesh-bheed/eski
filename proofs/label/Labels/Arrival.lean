import Labels.Contexts

namespace Labels

def errInvalid : String := "ERR invalid label"
def errContext : String := "ERR invalid context"
def errToken : String := "ERR invalid label token"
def errPerCommand : String := "ERR this login must send every command through LABEL AS"
def errTokenOnly : String := "ERR this login must send every command through LABEL AS TOKEN"
def errSessionNeeded : String := "ERR this command needs a session label set with LABEL SESSION"
def errSessionDenied : String := "ERR LABEL SESSION is not available to this login"
def errTransaction : String := "ERR the command's label differs from the transaction's label"
def errNested : String := "ERR LABEL AS cannot wrap LABEL AS or LABEL SESSION"
def errMismatch : String := "ERR the label differs from the context's label"
def errTop : String := "ERR this command needs a label that dominates the whole label scheme"
def errPersistence : String := "ERR persistence is off while a label scheme is configured"
def wrongArgs (name : String) : String := "ERR wrong number of arguments for '" ++ name ++ "' command"
def errWrongArgs : String := wrongArgs "label|as"
def errSyntax : String := "ERR syntax error"
def errCap : String := "ERR this login already holds the maximum number of contexts"
def errNestedMulti : String := "ERR MULTI calls can not be nested"
def errExecWithout : String := "ERR EXEC without MULTI"
def errDiscardWithout : String := "ERR DISCARD without MULTI"
def errExecDirty : String := "EXECABORT Transaction discarded because of previous errors."
def errWatchInMulti : String := "ERR WATCH inside MULTI is not allowed"

inductive Arg
  | lit (b : List Nat)
  | handle (n : Nat)
  | token (n : Nat)
deriving DecidableEq, Repr

def lowerByte (b : Nat) : Nat := if 65 ≤ b ∧ b ≤ 90 then b + 32 else b

def word (s : String) : List Nat := s.toList.map Char.toNat

def isWord (a : Arg) (w : String) : Bool :=
  match a with
  | .lit b => b.map lowerByte == word w
  | _ => false

def hexDigit (b : Nat) : Bool := (48 ≤ b && b ≤ 57) || (97 ≤ b && b ≤ 102) || (65 ≤ b && b ≤ 70)

def shaped (a : Arg) : Bool :=
  match a with
  | .lit b => b.length == 32 && b.all hexDigit
  | .handle _ => true
  | .token _ => false

def hrefOf (a : Arg) : HRef :=
  match a with
  | .handle n => .handle n
  | a => if shaped a then .shaped else .malformed

def argBytes (a : Arg) : Option (List Nat) :=
  match a with
  | .lit b => some b
  | _ => none

def nameOf (args : List Arg) : List Nat :=
  match args.head? with
  | some (.lit b) => b.map lowerByte
  | _ => []

def knownCommands : List String :=
  ["get", "set", "ping", "echo", "select", "auth", "hello", "quit", "reset", "client", "label", "context", "multi", "exec",
   "discard", "watch", "unwatch", "subscribe", "psubscribe", "ssubscribe", "save", "bgsave", "bgrewriteaof", "dump", "restore",
   "migrate", "debug", "monitor", "swapdb", "latency", "memory", "slowlog", "config", "shutdown", "eval", "publish",
   "script", "function"]

def isCmd (args : List Arg) (w : String) : Bool := nameOf args == word w

def known (args : List Arg) : Bool := knownCommands.any (isCmd args)

def argIs (args : List Arg) (i : Nat) (w : String) : Bool :=
  match args[i]? with
  | some a => isWord a w
  | none => false

def housekeeping (args : List Arg) : Bool :=
  !known args ||
    ["auth", "hello", "ping", "quit", "reset", "echo", "select"].any (isCmd args) ||
    (isCmd args "label" && (argIs args 1 "whoami" || argIs args 1 "help" || argIs args 1 "session")) ||
    (isCmd args "context" && argIs args 1 "help") ||
    (isCmd args "client" && (argIs args 1 "setname" || argIs args 1 "setinfo" || argIs args 1 "id"))

def needsSession (args : List Arg) : Bool :=
  ["subscribe", "psubscribe", "ssubscribe"].any (isCmd args) ||
    (isCmd args "client" && argIs args 1 "tracking" && argIs args 2 "on")

def topOnly (args : List Arg) : Bool :=
  ["monitor", "swapdb", "debug", "latency"].any (isCmd args) ||
    (isCmd args "client" && (argIs args 1 "pause" || argIs args 1 "unpause")) ||
    (isCmd args "memory" && (argIs args 1 "stats" || argIs args 1 "doctor" || argIs args 1 "malloc-stats" ||
      argIs args 1 "purge")) ||
    (isCmd args "slowlog" && argIs args 1 "reset") ||
    (isCmd args "config" && argIs args 1 "resetstat")

def persistenceRefused (args : List Arg) : Bool :=
  ["save", "bgsave", "bgrewriteaof", "dump", "restore", "migrate"].any (isCmd args) ||
    (isCmd args "debug" && (argIs args 1 "reload" || argIs args 1 "loadaof")) ||
    (isCmd args "shutdown" && (args.drop 1).any (isWord · "save"))

def scriptDenied (args : List Arg) : Bool :=
  (isCmd args "label" && !(argIs args 1 "whoami" || argIs args 1 "help")) ||
    (isCmd args "context" && !argIs args 1 "help")

def immediate (args : List Arg) : Bool :=
  ["exec", "discard", "multi", "watch", "quit", "reset"].any (isCmd args)

structure TokSpec where
  secret : Nat
  marking : Option (List Nat)
  trust : Option (List Nat)
  expires : List Nat
  audience : Option (List Nat)
  ctx : Option HRef
  flaw : Nat
deriving DecidableEq, Repr

structure TokEntry where
  label : TLabel
  expires : Int
  ctx : Option HRef
deriving DecidableEq, Repr

structure WSum where
  any : Bool
  mixed : Bool
  label : TLabel
deriving DecidableEq, Repr

def wsEmpty : WSum := ⟨false, false, tbottom⟩

def wnote (s : WSum) (l : TLabel) : WSum :=
  if !s.any then ⟨true, false, l⟩ else if s.label != l then { s with mixed := true } else s

def wdiffers (s : WSum) (b : TLabel) : Bool := s.any && (s.mixed || s.label != b)

def wclear (s : WSum) : WSum := { s with any := false, mixed := false }

structure AConn where
  login : List Nat
  explicit : Bool
  session : TLabel
  inMulti : Bool
  dirty : Bool
  bound : TLabel
  boundPrefixed : Bool
  cas : Bool
  ws : WSum
  watched : List (List Nat × TLabel)
deriving DecidableEq, Repr

def clearWatch (c : AConn) : AConn := { c with cas := false, watched := [], ws := wclear c.ws }

def endTx (c : AConn) : AConn := clearWatch { c with inMulti := false, dirty := false }

def addWatch (ws : List (List Nat × TLabel)) (l : TLabel) : List Arg → List (List Nat × TLabel)
  | [] => ws
  | a :: rest =>
    match a with
    | .lit k => if ws.any (·.1 == k) then addWatch ws l rest else addWatch (ws ++ [(k, l)]) l rest
    | _ => addWatch ws l rest

def watchConn (c : AConn) (l : TLabel) (keys : List Arg) : AConn :=
  { c with ws := wnote c.ws l, watched := addWatch c.watched l keys }

def touchConn (k : List Nat) (w : TLabel) (c : AConn) : AConn :=
  if c.watched.any (fun e => e.1 == k && domT e.2 w) then { c with cas := true } else c

def authConn (c : AConn) (login : List Nat) : AConn :=
  if c.login == login then c else { c with login := login, explicit := false, session := tbottom }

structure AEnv where
  cfg : TConfig
  audience : List Nat
  idle : Nat
  cap : Nat
  now : Nat
  users : List (List Nat × LRules)
  tokens : List (Nat × TokSpec)
  acl : List (List Nat × List (List Nat))

structure ADyn where
  conns : List (Nat × AConn)
  ctxs : List ACtx
  next : Nat
  cache : List ((List Nat × TokSpec) × TokEntry)

def noRules : LRules := ⟨false, none, false, none, false, false, []⟩

def rulesOf (E : AEnv) (login : List Nat) : LRules := ((E.users.find? (·.1 == login)).map (·.2)).getD noRules

def ceilingFor (E : AEnv) (login : List Nat) : TLabel := ceilingOf E.cfg (rulesOf E login)

def sessionOf (E : AEnv) (c : AConn) : TLabel :=
  if c.explicit then c.session else ceilingSession (ceilingFor E c.login)

def digitsValue (body : List Nat) : Nat := body.foldl (fun acc b => acc * 10 + (b - 48)) 0

def parseI64 (s : List Nat) : Option Int :=
  if s = [48] then some 0
  else
    let neg := s.head? = some 45
    let body := if neg then s.drop 1 else s
    if body.length = 0 ∨ 19 < body.length ∨ body.head? = some 48 ∨ !body.all (fun b => 48 ≤ b && b ≤ 57) then none
    else if neg then (if digitsValue body ≤ 9223372036854775808 then some (-((digitsValue body : Nat) : Int)) else none)
    else (if digitsValue body ≤ 9223372036854775807 then some ((digitsValue body : Nat) : Int) else none)

def parseWithTrust (tc : TConfig) (marking : List Nat) (trust : Option (List Nat)) : Option TLabel :=
  match parseT tc marking with
  | .error _ => none
  | .ok l =>
    match trust with
    | none => some l
    | some t =>
      if marking.contains 59 then none
      else match findName tc.trusts t with
        | none => none
        | some k => some { l with trust := k }

def tokenCheck (E : AEnv) (r : LRules) (sp : TokSpec) : Option TokEntry :=
  if r.keys.isEmpty || E.audience.isEmpty || sp.flaw == 9 then none
  else if sp.flaw == 5 || sp.flaw == 6 || sp.flaw == 7 then none
  else if !r.keys.contains sp.secret || sp.flaw == 1 then none
  else if sp.flaw == 2 || sp.flaw == 3 || sp.flaw == 4 || sp.flaw == 8 then none
  else match sp.marking, sp.audience with
    | some m, some a =>
      if a != E.audience then none
      else match parseI64 sp.expires, parseWithTrust E.cfg m sp.trust with
        | some e, some l => if sp.ctx == some .malformed then none else some ⟨l, e, sp.ctx⟩
        | _, _ => none
    | _, _ => none

def findIn (E : AEnv) (D : ADyn) (login : List Nat) (h : HRef) : Option ACtx × ADyn :=
  ((ctxFind E.idle E.now D.ctxs login (ceilingFor E login) h).1,
   { D with ctxs := (ctxFind E.idle E.now D.ctxs login (ceilingFor E login) h).2 })

def tokenEntry (E : AEnv) (D : ADyn) (login : List Nat) (sp : TokSpec) : Option TokEntry × ADyn :=
  match (D.cache.find? (·.1 == (login, sp))).map (·.2) with
  | some e => (some e, D)
  | none =>
    match tokenCheck E (rulesOf E login) sp with
    | none => (none, D)
    | some e => (some e, { D with cache := D.cache ++ [((login, sp), e)] })

def tokenCtx (E : AEnv) (D : ADyn) (login : List Nat) (l : TLabel) : Option HRef → Option (TLabel × Option ACtx) × ADyn
  | none => (some (l, none), D)
  | some h =>
    match findIn E D login h with
    | (none, D2) => (none, D2)
    | (some x, D2) => if x.label != l then (none, D2) else (some (l, some x), D2)

def tokenVerify (E : AEnv) (D : ADyn) (login : List Nat) (sp : TokSpec) : Option (TLabel × Option ACtx) × ADyn :=
  match tokenEntry E D login sp with
  | (none, D1) => (none, D1)
  | (some e, D1) =>
    if e.expires ≤ (E.now : Int) then (none, { D1 with cache := D1.cache.filter (·.1 != (login, sp)) })
    else if !labelValidT E.cfg e.label || !ceilingAdmits (ceilingFor E login) e.label then (none, D1)
    else tokenCtx E D1 login e.label e.ctx

structure Parsed where
  used : Nat
  label : TLabel
  ctx : Option ACtx
deriving DecidableEq, Repr

def specOf (E : AEnv) (a : Arg) : Option TokSpec :=
  match a with
  | .token n => (E.tokens.find? (·.1 == n)).map (·.2)
  | _ => none

def tailFind (E : AEnv) (D : ADyn) (login : List Nat) (h : Arg) (l : TLabel) (used : Nat) : Except String Parsed × ADyn :=
  match findIn E D login (hrefOf h) with
  | (none, D1) => (.error errContext, D1)
  | (some x, D1) => if x.label != l then (.error errMismatch, D1) else (.ok ⟨used, l, some x⟩, D1)

def contextTail (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) (i : Nat) (l : TLabel) :
    Except String Parsed × ADyn :=
  match args[i]?, args[i + 1]? with
  | some a, some h =>
    if decide (i + 2 < args.length) && isWord a "context" && shaped h then tailFind E D login h l (i + 2)
    else (.ok ⟨i, l, none⟩, D)
  | _, _ => (.ok ⟨i, l, none⟩, D)

def hasTrust (args : List Arg) : Bool := decide (5 < args.length) && argIs args 3 "trust"

def markingLabel (E : AEnv) (args : List Arg) : Option TLabel :=
  match args[2]?.bind argBytes with
  | none => none
  | some m =>
    if hasTrust args then
      match args[4]?.bind argBytes with
      | none => none
      | some t => parseWithTrust E.cfg m (some t)
    else parseWithTrust E.cfg m none

def markingEnd (args : List Arg) : Except String Parsed × ADyn → Except String Parsed × ADyn
  | (.ok p, D1) => if args.length ≤ p.used then (.error errWrongArgs, D1) else (.ok p, D1)
  | r => r

def markingForm (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) : Except String Parsed × ADyn :=
  match markingLabel E args with
  | none => (.error errInvalid, D)
  | some l =>
    if !ceilingAdmits (ceilingFor E login) l then (.error errInvalid, D)
    else markingEnd args (contextTail E D login args (if hasTrust args then 5 else 3) l)

def tokenForm (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) : Except String Parsed × ADyn :=
  match args[3]?.bind (specOf E) with
  | none => (.error errToken, D)
  | some sp =>
    match tokenVerify E D login sp with
    | (none, D1) => (.error errToken, D1)
    | (some (l, x), D1) => (.ok ⟨4, l, x⟩, D1)

def contextForm (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) : Except String Parsed × ADyn :=
  match args[3]? with
  | none => (.error errContext, D)
  | some h =>
    match findIn E D login (hrefOf h) with
    | (none, D1) => (.error errContext, D1)
    | (some x, D1) => (.ok ⟨4, x.label, some x⟩, D1)

def labelAsParse (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) : Except String Parsed × ADyn :=
  if args.length ≤ 2 then (.error errWrongArgs, D)
  else if argIs args 2 "token" && decide (4 < args.length) then tokenForm E D login args
  else if (rulesOf E login).requireToken then (.error errTokenOnly, D)
  else if argIs args 2 "context" && decide (4 < args.length) && (args[3]?.map shaped).getD false then
    contextForm E D login args
  else markingForm E D login args

def isLabelAs (args : List Arg) : Bool := isCmd args "label" && decide (2 ≤ args.length) && argIs args 1 "as"

def nested (inner : List Arg) : Bool :=
  isCmd inner "label" && decide (2 ≤ inner.length) && (argIs inner 1 "as" || argIs inner 1 "session")

def stripErr (m : String) : String := if m.startsWith "ERR " then String.ofList (m.toList.drop 4) else m

def errExecWatch : String := "EXECABORT Transaction discarded because of: " ++ stripErr errTransaction

inductive Arrival
  | ok (l : TLabel) (inner : List Arg) (ctx : Option ACtx)
  | refused (msg : String)
deriving DecidableEq, Repr

def setConn (D : ADyn) (id : Nat) (c : AConn) : ADyn :=
  { D with conns := D.conns.map fun p => if p.1 == id then (id, c) else p }

def refuse (D : ADyn) (id : Nat) (c : AConn) (slotArgs : List Arg) (msg : String) : Arrival × ADyn :=
  if isCmd slotArgs "exec" && c.inMulti then
    (.refused ("EXECABORT Transaction discarded because of: " ++ stripErr msg), setConn D id (endTx c))
  else (.refused msg, setConn D id { c with dirty := c.dirty || c.inMulti })

def finishLabel (c : AConn) (l0 : TLabel) : TLabel := if c.inMulti then c.bound else l0

def finishConn (c : AConn) (inner : List Arg) (l : TLabel) (prefixed : Bool) : AConn :=
  if !c.inMulti && isCmd inner "multi" then { c with bound := l, boundPrefixed := prefixed } else c

def pinConn (c : AConn) (inner : List Arg) (l : TLabel) : AConn :=
  if !c.inMulti && needsSession inner && !c.explicit then { c with explicit := true, session := l } else c

def sessionKept (E : AEnv) (c : AConn) (prefixed : Bool) : Bool :=
  prefixed || (c.inMulti && c.boundPrefixed) || (rulesOf E c.login).perCommand || (rulesOf E c.login).requireToken

def aclTarget (args : List Arg) : List Nat :=
  if isCmd args "client" then
    match (args[1]? : Option Arg) with
    | some (.lit b) => nameOf args ++ [124] ++ b.map lowerByte
    | _ => nameOf args
  else nameOf args

def deniedOf (E : AEnv) (login : List Nat) : List (List Nat) := ((E.acl.find? (·.1 == login)).map (·.2)).getD []

def aclDenies (E : AEnv) (login : List Nat) (args : List Arg) : Bool := (deniedOf E login).contains (aclTarget args)

def textOf (b : List Nat) : String := String.ofList (b.map Char.ofNat)

def errNoperm (login target : List Nat) : String :=
  "NOPERM User " ++ textOf login ++ " has no permissions to run the '" ++ textOf target ++ "' command"

def sessionNeededAt (E : AEnv) (c : AConn) (inner : List Arg) (prefixed : Bool) : Bool :=
  needsSession inner && !c.explicit && sessionKept E c prefixed

def gate (E : AEnv) (c : AConn) (inner : List Arg) (l : TLabel) (prefixed : Bool) : Option String :=
  if !ceilingAdmits (ceilingFor E c.login) l || !labelValidT E.cfg l then some errInvalid
  else if !known inner then none
  else if sessionNeededAt E c inner prefixed then some errSessionNeeded
  else if aclDenies E c.login inner then some (errNoperm c.login (aclTarget inner))
  else if persistenceRefused inner then some errPersistence
  else if topOnly inner && !domT l (ttop E.cfg.base.levels.length E.cfg.base.comps.length) then some errTop
  else none

def arriveFinish (E : AEnv) (D : ADyn) (id : Nat) (c : AConn) (inner : List Arg) (l0 : TLabel) (ctx : Option ACtx)
    (prefixed : Bool) : Arrival × ADyn :=
  if c.inMulti && prefixed && l0 != c.bound then refuse D id c inner errTransaction
  else match gate E c inner (finishLabel c l0) prefixed with
    | some m => refuse (setConn D id (finishConn c inner (finishLabel c l0) prefixed)) id
        (finishConn c inner (finishLabel c l0) prefixed) inner m
    | none => (.ok (finishLabel c l0) inner ctx,
        setConn D id (pinConn (finishConn c inner (finishLabel c l0) prefixed) inner (finishLabel c l0)))

def arriveCore (E : AEnv) (D : ADyn) (id : Nat) (c : AConn) (inner : List Arg) (l0 : TLabel) (ctx : Option ACtx)
    (prefixed : Bool) : Arrival × ADyn :=
  if c.inMulti && prefixed && l0 != c.bound then refuse D id c inner errTransaction
  else match gate E c inner (finishLabel c l0) prefixed with
    | some m => refuse (setConn D id (finishConn c inner (finishLabel c l0) prefixed)) id
        (finishConn c inner (finishLabel c l0) prefixed) inner m
    | none => (.ok (finishLabel c l0) inner ctx, setConn D id (finishConn c inner (finishLabel c l0) prefixed))

def connOf (D : ADyn) (id : Nat) : Option AConn := (D.conns.find? (·.1 == id)).map (·.2)

def arrive (E : AEnv) (D : ADyn) (id : Nat) (args : List Arg) : Arrival × ADyn :=
  match connOf D id with
  | none => (.refused "no connection", D)
  | some c =>
    if isLabelAs args then
      match labelAsParse E D c.login args with
      | (.error m, D1) => refuse D1 id c args m
      | (.ok p, D1) =>
        if nested (args.drop p.used) then refuse D1 id c args errNested
        else arriveFinish E D1 id c (args.drop p.used) p.label p.ctx true
    else if ((rulesOf E c.login).perCommand || (rulesOf E c.login).requireToken) && !c.inMulti && !housekeeping args then
      refuse D id c args (if (rulesOf E c.login).requireToken then errTokenOnly else errPerCommand)
    else arriveFinish E D id c args (sessionOf E c) none false

inductive Reply
  | ok
  | err (m : String)
  | handle (n : Nat)
  | info (l : TLabel)
  | queued
  | exec
  | nil
  | none
deriving DecidableEq, Repr

def sessionLabel (E : AEnv) (inner : List Arg) : Except String TLabel :=
  if inner.length = 3 then
    match (inner[2]?.bind argBytes).bind (parseWithTrust E.cfg · none) with
    | none => .error errInvalid
    | some l => .ok l
  else if inner.length = 5 && argIs inner 3 "trust" then
    match (inner[2]?.bind argBytes).bind (fun m => (inner[4]?.bind argBytes).bind (fun t => parseWithTrust E.cfg m (some t))) with
    | none => .error errInvalid
    | some l => .ok l
  else .error errSyntax

def sessionHandler (E : AEnv) (D : ADyn) (id : Nat) (c : AConn) (inner : List Arg) : Reply × ADyn :=
  if inner.length < 3 then (.err (wrongArgs "label|session"), D)
  else if (rulesOf E c.login).perCommand || (rulesOf E c.login).requireToken then (.err errSessionDenied, D)
  else match sessionLabel E inner with
    | .error m => (.err m, D)
    | .ok l =>
      if !ceilingAdmits (ceilingFor E c.login) l || !labelValidT E.cfg l then (.err errInvalid, D)
      else (.ok, setConn D id { c with explicit := true, session := l })

def createOpts : List Arg → Option (List Nat) → Option (List Nat) → Option (Option (List Nat) × Option (List Nat))
  | [], lv, tr => some (lv, tr)
  | [_], _, _ => none
  | a :: v :: rest, lv, tr =>
    if isWord a "level" && lv.isNone then createOpts rest (some ((argBytes v).getD [255])) tr
    else if isWord a "trust" && tr.isNone then createOpts rest lv (some ((argBytes v).getD [255]))
    else none

def createLabel (E : AEnv) (l0 : TLabel) (opts : List Arg) : Except String TLabel :=
  match createOpts opts none none with
  | none => .error errSyntax
  | some (some m, tr) =>
    match parseWithTrust E.cfg m tr with
    | none => .error errInvalid
    | some p => .ok (if tr.isNone && !m.contains 59 then { p with trust := l0.trust } else p)
  | some (none, some t) =>
    match findName E.cfg.trusts t with
    | none => .error errInvalid
    | some k => .ok { l0 with trust := k }
  | some (none, none) => .ok l0

def contextCreate (E : AEnv) (D : ADyn) (c : AConn) (l0 : TLabel) (opts : List Arg) : Reply × ADyn :=
  match createLabel E l0 opts with
  | .error e => (.err e, D)
  | .ok l =>
    match ctxCreate E.idle E.now E.cap D.next D.ctxs c.login (ceilingFor E c.login) l (labelValidT E.cfg l) with
    | (.created h, cs, n) => (.handle h, { D with ctxs := cs, next := n })
    | (.invalid, _, _) => (.err errInvalid, D)
    | (.full, _, _) => (.err errCap, D)

def contextUse (E : AEnv) (D : ADyn) (c : AConn) (inner : List Arg) : Reply × ADyn :=
  if inner.length ≠ 3 then (.err (wrongArgs (if argIs inner 1 "info" then "context|info" else "context|drop")), D)
  else match inner[2]? with
    | none => (.err errContext, D)
    | some h =>
      match findIn E D c.login (hrefOf h) with
      | (none, D1) => (.err errContext, D1)
      | (some x, D1) =>
        if argIs inner 1 "drop" then (.ok, { D1 with ctxs := ctxRemove D1.ctxs x.handle }) else (.info x.label, D1)

def contextHandler (E : AEnv) (D : ADyn) (c : AConn) (l0 : TLabel) (inner : List Arg) : Reply × ADyn :=
  if argIs inner 1 "create" then contextCreate E D c l0 (inner.drop 2)
  else if argIs inner 1 "info" || argIs inner 1 "drop" then contextUse E D c inner
  else (.none, D)

def execReply (c : AConn) : Reply :=
  if c.dirty then .err errExecDirty
  else if wdiffers c.ws c.bound then .err errExecWatch
  else if c.cas then .nil
  else .exec

def handleCmd (E : AEnv) (D : ADyn) (id : Nat) (l : TLabel) (inner : List Arg) : Reply × ADyn :=
  match connOf D id with
  | none => (.none, D)
  | some c =>
    if c.inMulti && !immediate inner then (.queued, D)
    else if isCmd inner "multi" then
      (if c.inMulti then (.err errNestedMulti, D) else (.ok, setConn D id { c with inMulti := true, dirty := false }))
    else if isCmd inner "exec" then
      (if !c.inMulti then (.err errExecWithout, D) else (execReply c, setConn D id (endTx c)))
    else if isCmd inner "discard" then
      (if !c.inMulti then (.err errDiscardWithout, D) else (.ok, setConn D id (endTx c)))
    else if isCmd inner "watch" then
      (if c.inMulti then (.err errWatchInMulti, D) else (.ok, setConn D id (watchConn c l (inner.drop 1))))
    else if isCmd inner "unwatch" then (.ok, setConn D id (clearWatch c))
    else if isCmd inner "label" && argIs inner 1 "session" then sessionHandler E D id c inner
    else if isCmd inner "context" then contextHandler E D c l inner
    else (.none, D)

def touch (D : ADyn) (k : List Nat) (w : TLabel) : ADyn :=
  { D with conns := D.conns.map fun p => (p.1, touchConn k w p.2) }

def auth (D : ADyn) (id : Nat) (login : List Nat) : ADyn :=
  match connOf D id with
  | none => D
  | some c => setConn D id (authConn c login)

def request (E : AEnv) (D : ADyn) (id : Nat) (args : List Arg) : Arrival × Reply × ADyn :=
  match arrive E D id args with
  | (.ok l inner x, D1) => (.ok l inner x, (handleCmd E D1 id l inner).1, (handleCmd E D1 id l inner).2)
  | (a, D1) => (a, .none, D1)

def requests (E : AEnv) : ADyn → List (Nat × List Arg) → ADyn
  | D, [] => D
  | D, (id, args) :: rest => requests E (request E D id args).2.2 rest

theorem band_both {a b : Bool} (h : (a && b) = true) : a = true ∧ b = true := by
  cases a <;> cases b <;> simp_all

theorem or_false_both {a b : Bool} (h : ¬((a || b) = true)) : a = false ∧ b = false := by
  cases a <;> cases b <;> simp_all

theorem or_not_false {a b : Bool} (h : ¬((!a || !b) = true)) : a = true ∧ b = true := by
  cases a <;> cases b <;> simp_all

theorem refuse_not_ok {D D' : ADyn} {id : Nat} {c : AConn} {a : List Arg} {m : String} {l : TLabel} {inner : List Arg}
    {x : Option ACtx} (h : refuse D id c a m = (.ok l inner x, D')) : False := by
  unfold refuse at h
  split at h <;> simp at h

theorem findIn_spec {E : AEnv} {D D' : ADyn} {login : List Nat} {r : HRef} {x : ACtx}
    (h : findIn E D login r = (some x, D')) : x.owner = login ∧ ceilingAdmits (ceilingFor E login) x.label = true := by
  have h1 : (ctxFind E.idle E.now D.ctxs login (ceilingFor E login) r).1 = some x := congrArg Prod.fst h
  have hp : ctxFind E.idle E.now D.ctxs login (ceilingFor E login) r =
      (some x, (ctxFind E.idle E.now D.ctxs login (ceilingFor E login) r).2) := Prod.ext h1 rfl
  exact ⟨find_owner hp, find_within_ceiling hp⟩

theorem gate_none {E : AEnv} {c : AConn} {inner : List Arg} {l : TLabel} {p : Bool} (h : gate E c inner l p = none) :
    ceilingAdmits (ceilingFor E c.login) l = true ∧ labelValidT E.cfg l = true := by
  unfold gate at h
  by_cases h1 : ceilingAdmits (ceilingFor E c.login) l = true <;> by_cases h2 : labelValidT E.cfg l = true <;> simp_all

theorem finish_spec {E : AEnv} {D D' : ADyn} {id : Nat} {c : AConn} {inner inner' : List Arg} {l0 l : TLabel}
    {ctx ctx' : Option ACtx} {p : Bool} (h : arriveFinish E D id c inner l0 ctx p = (.ok l inner' ctx', D')) :
    ceilingAdmits (ceilingFor E c.login) l = true ∧ labelValidT E.cfg l = true ∧ inner' = inner ∧ ctx' = ctx ∧
      l = finishLabel c l0 ∧ (c.inMulti = true → p = true → l0 = c.bound) ∧
      D' = setConn D id (pinConn (finishConn c inner l p) inner l) := by
  unfold arriveFinish at h
  split at h
  · exact (refuse_not_ok h).elim
  · rename_i hm
    split at h
    · exact (refuse_not_ok h).elim
    · rename_i hg
      simp only [Prod.mk.injEq, Arrival.ok.injEq] at h
      obtain ⟨⟨rfl, rfl, rfl⟩, rfl⟩ := h
      obtain ⟨g1, g2⟩ := gate_none hg
      refine ⟨g1, g2, rfl, rfl, rfl, fun h1 h2 => ?_, rfl⟩
      simp only [h1, h2, Bool.true_and, bne_iff_ne, ne_eq, Decidable.not_not] at hm
      exact hm

theorem core_spec {E : AEnv} {D D' : ADyn} {id : Nat} {c : AConn} {inner inner' : List Arg} {l0 l : TLabel}
    {ctx ctx' : Option ACtx} {p : Bool} (h : arriveCore E D id c inner l0 ctx p = (.ok l inner' ctx', D')) :
    ceilingAdmits (ceilingFor E c.login) l = true ∧ labelValidT E.cfg l = true ∧ inner' = inner ∧ ctx' = ctx ∧
      l = finishLabel c l0 ∧ (c.inMulti = true → p = true → l0 = c.bound) ∧
      D' = setConn D id (finishConn c inner l p) ∧ gate E c inner l p = none := by
  unfold arriveCore at h
  split at h
  · exact (refuse_not_ok h).elim
  · rename_i hm
    split at h
    · exact (refuse_not_ok h).elim
    · rename_i hg
      simp only [Prod.mk.injEq, Arrival.ok.injEq] at h
      obtain ⟨⟨rfl, rfl, rfl⟩, rfl⟩ := h
      obtain ⟨g1, g2⟩ := gate_none hg
      refine ⟨g1, g2, rfl, rfl, rfl, fun h1 h2 => ?_, rfl, hg⟩
      simp only [h1, h2, Bool.true_and, bne_iff_ne, ne_eq, Decidable.not_not] at hm
      exact hm

theorem tokenCtx_spec {E : AEnv} {D D' : ADyn} {login : List Nat} {l l' : TLabel} {r : Option HRef} {x : Option ACtx}
    (h : tokenCtx E D login l r = (some (l', x), D')) : l' = l ∧ ∀ y, x = some y → y.owner = login ∧ y.label = l := by
  cases r with
  | none =>
    simp only [tokenCtx, Prod.mk.injEq, Option.some.injEq] at h
    obtain ⟨⟨rfl, rfl⟩, _⟩ := h
    exact ⟨rfl, fun y hy => by simp at hy⟩
  | some r =>
    simp only [tokenCtx] at h
    split at h
    · simp at h
    · rename_i z D2 hf
      split at h
      · simp at h
      · rename_i hl
        simp only [Prod.mk.injEq, Option.some.injEq] at h
        obtain ⟨⟨rfl, rfl⟩, _⟩ := h
        refine ⟨rfl, fun y hy => ?_⟩
        cases hy
        exact ⟨(findIn_spec hf).1, by simpa using hl⟩

theorem tokenVerify_spec {E : AEnv} {D D' : ADyn} {login : List Nat} {sp : TokSpec} {l : TLabel} {x : Option ACtx}
    (h : tokenVerify E D login sp = (some (l, x), D')) :
    ∃ e, (tokenEntry E D login sp).1 = some e ∧ e.label = l ∧ (E.now : Int) < e.expires ∧
      ceilingAdmits (ceilingFor E login) l = true ∧ (∀ y, x = some y → y.owner = login ∧ y.label = l) := by
  unfold tokenVerify at h
  split at h
  · simp at h
  · rename_i e D1 he
    split at h
    · simp at h
    · rename_i hexp
      split at h
      · simp at h
      · rename_i hc
        obtain ⟨_, c2⟩ := or_not_false hc
        obtain ⟨t1, t2⟩ := tokenCtx_spec h
        subst t1
        exact ⟨e, by rw [he], rfl, by omega, c2, t2⟩

theorem tokenEntry_spec {E : AEnv} {D D' : ADyn} {login : List Nat} {sp : TokSpec} {e : TokEntry}
    (h : tokenEntry E D login sp = (some e, D')) :
    (D.cache.find? (·.1 == (login, sp))).map (·.2) = some e ∨ tokenCheck E (rulesOf E login) sp = some e := by
  unfold tokenEntry at h
  split at h
  · rename_i e' he
    simp only [Prod.mk.injEq, Option.some.injEq] at h
    obtain ⟨rfl, _⟩ := h
    exact Or.inl he
  · split at h
    · simp at h
    · rename_i e' he
      simp only [Prod.mk.injEq, Option.some.injEq] at h
      obtain ⟨rfl, _⟩ := h
      exact Or.inr he

theorem tailFind_spec {E : AEnv} {D D' : ADyn} {login : List Nat} {a : Arg} {l : TLabel} {u : Nat} {p : Parsed}
    (h : tailFind E D login a l u = (.ok p, D')) :
    p.used = u ∧ p.label = l ∧ ∃ x, p.ctx = some x ∧ x.owner = login ∧ x.label = l := by
  unfold tailFind at h
  split at h
  · simp at h
  · rename_i x D1 hf
    split at h
    · simp at h
    · rename_i hl
      simp only [Prod.mk.injEq, Except.ok.injEq] at h
      obtain ⟨rfl, _⟩ := h
      exact ⟨rfl, rfl, x, rfl, (findIn_spec hf).1, by simpa using hl⟩

theorem contextTail_spec {E : AEnv} {D D' : ADyn} {login : List Nat} {args : List Arg} {i : Nat} {l : TLabel} {p : Parsed}
    (h : contextTail E D login args i l = (.ok p, D')) :
    p.label = l ∧ (p.used = i ∨ p.used = i + 2) ∧ ∀ x, p.ctx = some x → x.owner = login ∧ x.label = l := by
  unfold contextTail at h
  split at h
  · split at h
    · obtain ⟨h1, h2, x, h3, h4, h5⟩ := tailFind_spec h
      exact ⟨h2, Or.inr h1, fun y hy => by rw [h3] at hy; cases hy; exact ⟨h4, h5⟩⟩
    · simp only [Prod.mk.injEq, Except.ok.injEq] at h
      obtain ⟨rfl, _⟩ := h
      exact ⟨rfl, Or.inl rfl, fun y hy => by simp at hy⟩
  · simp only [Prod.mk.injEq, Except.ok.injEq] at h
    obtain ⟨rfl, _⟩ := h
    exact ⟨rfl, Or.inl rfl, fun y hy => by simp at hy⟩

theorem markingEnd_spec {args : List Arg} {r : Except String Parsed × ADyn} {p : Parsed} {D' : ADyn}
    (h : markingEnd args r = (.ok p, D')) : r = (.ok p, D') ∧ p.used < args.length := by
  match r, h with
  | (.ok q, D1), h =>
    by_cases hu : args.length ≤ q.used
    · simp [markingEnd, hu] at h
    · simp only [markingEnd, hu, ↓reduceIte, Prod.mk.injEq, Except.ok.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      exact ⟨rfl, by omega⟩
  | (.error m, D1), h => simp [markingEnd] at h

theorem markingForm_spec {E : AEnv} {D D' : ADyn} {login : List Nat} {args : List Arg} {p : Parsed}
    (h : markingForm E D login args = (.ok p, D')) :
    ceilingAdmits (ceilingFor E login) p.label = true ∧ p.used < args.length ∧
      ∀ x, p.ctx = some x → x.owner = login ∧ x.label = p.label := by
  unfold markingForm at h
  split at h
  · simp at h
  · rename_i l _
    split at h
    · simp at h
    · rename_i hc
      obtain ⟨h1, h2⟩ := markingEnd_spec h
      obtain ⟨t1, _, t3⟩ := contextTail_spec h1
      refine ⟨?_, h2, ?_⟩
      · rw [t1]; simpa using hc
      · rw [t1]; exact t3

theorem tokenForm_spec {E : AEnv} {D D' : ADyn} {login : List Nat} {args : List Arg} {p : Parsed}
    (h : tokenForm E D login args = (.ok p, D')) :
    p.used = 4 ∧ ceilingAdmits (ceilingFor E login) p.label = true ∧
      (∀ x, p.ctx = some x → x.owner = login ∧ x.label = p.label) ∧
      ∃ sp e, args[3]?.bind (specOf E) = some sp ∧ (tokenEntry E D login sp).1 = some e ∧ e.label = p.label ∧
        (E.now : Int) < e.expires := by
  unfold tokenForm at h
  split at h
  · simp at h
  · rename_i sp hsp
    split at h
    · simp at h
    · rename_i l x D1 hv
      simp only [Prod.mk.injEq, Except.ok.injEq] at h
      obtain ⟨rfl, _⟩ := h
      obtain ⟨e, he, hl, hexp, hc, hctx⟩ := tokenVerify_spec hv
      exact ⟨rfl, hc, hctx, sp, e, hsp, he, hl, hexp⟩

theorem contextForm_spec {E : AEnv} {D D' : ADyn} {login : List Nat} {args : List Arg} {p : Parsed}
    (h : contextForm E D login args = (.ok p, D')) :
    p.used = 4 ∧ ceilingAdmits (ceilingFor E login) p.label = true ∧
      ∃ x, p.ctx = some x ∧ x.owner = login ∧ x.label = p.label := by
  unfold contextForm at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · rename_i x D1 hf
      simp only [Prod.mk.injEq, Except.ok.injEq] at h
      obtain ⟨rfl, _⟩ := h
      obtain ⟨o, c⟩ := findIn_spec hf
      exact ⟨rfl, c, x, rfl, o, rfl⟩

theorem labelAsParse_spec {E : AEnv} {D D' : ADyn} {login : List Nat} {args : List Arg} {p : Parsed}
    (h : labelAsParse E D login args = (.ok p, D')) :
    ceilingAdmits (ceilingFor E login) p.label = true ∧ p.used < args.length ∧
      (∀ y, p.ctx = some y → y.owner = login ∧ y.label = p.label) ∧
      ((rulesOf E login).requireToken = true → argIs args 2 "token" = true) := by
  unfold labelAsParse at h
  split at h
  · simp at h
  · split at h
    · rename_i ht
      obtain ⟨t1, t2⟩ := band_both ht
      obtain ⟨u, c, x, _⟩ := tokenForm_spec h
      have := of_decide_eq_true t2
      exact ⟨c, by omega, x, fun _ => t1⟩
    · split at h
      · simp at h
      · rename_i hrt
        have hr : (rulesOf E login).requireToken = true → argIs args 2 "token" = true := fun e => absurd e hrt
        split at h
        · rename_i hcf
          obtain ⟨hab, _⟩ := band_both hcf
          obtain ⟨_, h4⟩ := band_both hab
          have := of_decide_eq_true h4
          obtain ⟨u, c, x, hx, o, e⟩ := contextForm_spec h
          refine ⟨c, by omega, fun y hy => ?_, hr⟩
          rw [hx] at hy
          cases hy
          exact ⟨o, e⟩
        · obtain ⟨a, b, c⟩ := markingForm_spec h
          exact ⟨a, b, c, hr⟩

theorem arrive_spec {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel} {ctx : Option ACtx}
    (h : arrive E D id args = (.ok l inner ctx, D')) :
    ∃ c, connOf D id = some c ∧ ceilingAdmits (ceilingFor E c.login) l = true ∧ labelValidT E.cfg l = true ∧
      (c.inMulti = true → l = c.bound) ∧ (∀ x, ctx = some x → x.owner = c.login ∧ x.label = l) := by
  unfold arrive at h
  split at h
  · simp at h
  · rename_i c hc
    refine ⟨c, hc, ?_⟩
    split at h
    · split at h
      · exact (refuse_not_ok h).elim
      · rename_i p D1 hpar
        split at h
        · exact (refuse_not_ok h).elim
        · obtain ⟨h1, h2, _, h4, h5, h6, _⟩ := finish_spec h
          obtain ⟨_, _, hctx, _⟩ := labelAsParse_spec hpar
          refine ⟨h1, h2, fun hm => by rw [h5]; simp [finishLabel, hm], fun x hx => ?_⟩
          rw [h4] at hx
          obtain ⟨o1, o2⟩ := hctx x hx
          refine ⟨o1, ?_⟩
          rw [h5, o2]
          unfold finishLabel
          split
          · rename_i hm
            exact h6 hm rfl
          · rfl
    · split at h
      · exact (refuse_not_ok h).elim
      · obtain ⟨h1, h2, _, h4, h5, _⟩ := finish_spec h
        refine ⟨h1, h2, fun hm => by rw [h5]; simp [finishLabel, hm], fun x hx => ?_⟩
        rw [h4] at hx
        simp at hx

theorem arrive_within {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel} {ctx : Option ACtx}
    {c : AConn} (hc : connOf D id = some c) (h : arrive E D id args = (.ok l inner ctx, D')) :
    ceilingAdmits (ceilingFor E c.login) l = true ∧ labelValidT E.cfg l = true := by
  obtain ⟨c', hc', h1, h2, _⟩ := arrive_spec h
  rw [hc] at hc'
  cases hc'
  exact ⟨h1, h2⟩

theorem arrive_within_parts {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel}
    {ctx : Option ACtx} {c : AConn} (hc : connOf D id = some c) (h : arrive E D id args = (.ok l inner ctx, D')) :
    dom (ceilingFor E c.login).sec l.sec = true ∧ l.trust ≤ (ceilingFor E c.login).trust := by
  have := (arrive_within hc h).1
  unfold ceilingAdmits at this
  obtain ⟨a, b⟩ := band_both this
  exact ⟨a, of_decide_eq_true b⟩

theorem arrive_write_exact {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel}
    {ctx : Option ACtx} {c : AConn} (hc : connOf D id = some c) (h : arrive E D id args = (.ok l inner ctx, D'))
    (w : TLabel) : SubjectOk ⟨ceilingFor E c.login, l⟩ ∧ (mayWrite ⟨ceilingFor E c.login, l⟩ w = .allowed ↔ w = l) := by
  have hw := (arrive_within hc h).1
  refine ⟨hw, ?_⟩
  rw [write_iff]
  constructor
  · intro ⟨_, e⟩
    exact e
  · intro e
    subst e
    exact ⟨hw, rfl⟩

theorem arrive_context_label {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel} {x : ACtx}
    {c : AConn} (hc : connOf D id = some c) (h : arrive E D id args = (.ok l inner (some x), D')) :
    x.owner = c.login ∧ x.label = l ∧ ceilingAdmits (ceilingFor E c.login) x.label = true := by
  obtain ⟨c', hc', h1, _, _, h5⟩ := arrive_spec h
  rw [hc] at hc'
  cases hc'
  obtain ⟨o, e⟩ := h5 x rfl
  exact ⟨o, e, by rw [e]; exact h1⟩

theorem arrive_multi_bound {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel}
    {ctx : Option ACtx} {c : AConn} (hc : connOf D id = some c) (hm : c.inMulti = true)
    (h : arrive E D id args = (.ok l inner ctx, D')) : l = c.bound := by
  obtain ⟨c', hc', _, _, h4, _⟩ := arrive_spec h
  rw [hc] at hc'
  cases hc'
  exact h4 hm

theorem arrive_prefixed {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel} {ctx : Option ACtx}
    {c : AConn} (hc : connOf D id = some c) (hp : isLabelAs args = true) (h : arrive E D id args = (.ok l inner ctx, D')) :
    ∃ p D1, labelAsParse E D c.login args = (.ok p, D1) ∧ inner = args.drop p.used ∧ nested inner = false ∧ ctx = p.ctx ∧
      (c.inMulti = false → l = p.label) ∧ (c.inMulti = true → p.label = c.bound ∧ l = c.bound) := by
  unfold arrive at h
  rw [hc] at h
  simp only [hp, ↓reduceIte] at h
  split at h
  · exact (refuse_not_ok h).elim
  · rename_i p D1 hpar
    split at h
    · exact (refuse_not_ok h).elim
    · rename_i hn
      obtain ⟨_, _, h3, h4, h5, h6, _⟩ := finish_spec h
      refine ⟨p, D1, hpar, h3, ?_, h4, fun hm => by rw [h5]; simp [finishLabel, hm],
        fun hm => ⟨h6 hm rfl, by rw [h5]; simp [finishLabel, hm]⟩⟩
      rw [h3]
      simpa using hn

theorem arrive_unprefixed {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel} {ctx : Option ACtx}
    {c : AConn} (hc : connOf D id = some c) (hp : isLabelAs args = false) (h : arrive E D id args = (.ok l inner ctx, D')) :
    l = finishLabel c (sessionOf E c) ∧ inner = args ∧ ctx = none := by
  unfold arrive at h
  rw [hc] at h
  simp only [hp, Bool.false_eq_true, ↓reduceIte] at h
  split at h
  · exact (refuse_not_ok h).elim
  · obtain ⟨_, _, h3, h4, h5, _⟩ := finish_spec h
    exact ⟨h5, h3, h4⟩

theorem arrive_session_label {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel}
    {ctx : Option ACtx} {c : AConn} (hc : connOf D id = some c) (hp : isLabelAs args = false) (hm : c.inMulti = false)
    (h : arrive E D id args = (.ok l inner ctx, D')) : l = sessionOf E c := by
  have := (arrive_unprefixed hc hp h).1
  simpa [finishLabel, hm] using this

theorem arrive_rules_refuse {E : AEnv} {D : ADyn} {id : Nat} {args : List Arg} {c : AConn}
    (hc : connOf D id = some c) (hp : isLabelAs args = false) (hm : c.inMulti = false) (hh : housekeeping args = false)
    (hr : (rulesOf E c.login).perCommand = true ∨ (rulesOf E c.login).requireToken = true) :
    (arrive E D id args).1 = .refused (if (rulesOf E c.login).requireToken then errTokenOnly else errPerCommand) := by
  unfold arrive
  rw [hc]
  have hor : ((rulesOf E c.login).perCommand || (rulesOf E c.login).requireToken) = true := by
    rcases hr with hr | hr <;> simp [hr]
  simp only [hp, Bool.false_eq_true, ↓reduceIte, hor, hm, hh, Bool.not_false, Bool.and_self]
  unfold refuse
  have hx : (isCmd args "exec" && c.inMulti) = false := by simp [hm]
  simp [hx]

theorem arrive_require_token {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel}
    {ctx : Option ACtx} {c : AConn} (hc : connOf D id = some c) (hr : (rulesOf E c.login).requireToken = true)
    (hp : isLabelAs args = true) (h : arrive E D id args = (.ok l inner ctx, D')) : argIs args 2 "token" = true := by
  obtain ⟨p, D1, hpar, _⟩ := arrive_prefixed hc hp h
  exact (labelAsParse_spec hpar).2.2.2 hr

theorem arrive_token_live {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel} {ctx : Option ACtx}
    {c : AConn} (hc : connOf D id = some c) (hp : isLabelAs args = true) (ht : argIs args 2 "token" = true)
    (h4 : 4 < args.length) (h : arrive E D id args = (.ok l inner ctx, D')) :
    ∃ sp e, args[3]?.bind (specOf E) = some sp ∧ (tokenEntry E D c.login sp).1 = some e ∧ (E.now : Int) < e.expires ∧
      (c.inMulti = false → l = e.label) := by
  obtain ⟨p, D1, hpar, _, _, _, h5, _⟩ := arrive_prefixed hc hp h
  unfold labelAsParse at hpar
  have hlen : ¬args.length ≤ 2 := by omega
  simp only [hlen, ht, Bool.true_and, h4, decide_true, ↓reduceIte] at hpar
  obtain ⟨_, _, _, sp, e, hsp, he, hl, hexp⟩ := tokenForm_spec hpar
  exact ⟨sp, e, hsp, he, hexp, fun hm => by rw [h5 hm, hl]⟩

theorem session_within {E : AEnv} {D D' : ADyn} {id : Nat} {c : AConn} {inner : List Arg}
    (h : sessionHandler E D id c inner = (.ok, D')) :
    (rulesOf E c.login).perCommand = false ∧ (rulesOf E c.login).requireToken = false ∧
      ∃ l, ceilingAdmits (ceilingFor E c.login) l = true ∧ D' = setConn D id { c with explicit := true, session := l } := by
  unfold sessionHandler at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · rename_i hr
      split at h
      · simp at h
      · rename_i l _
        split at h
        · simp at h
        · rename_i hc
          simp only [Prod.mk.injEq] at h
          obtain ⟨r1, r2⟩ := or_false_both hr
          exact ⟨r1, r2, l, (or_not_false hc).1, h.2.symm⟩

theorem session_denied {E : AEnv} {D : ADyn} {id : Nat} {c : AConn} {inner : List Arg} (hl : 3 ≤ inner.length)
    (hr : (rulesOf E c.login).perCommand = true ∨ (rulesOf E c.login).requireToken = true) :
    sessionHandler E D id c inner = (.err errSessionDenied, D) := by
  unfold sessionHandler
  have : ((rulesOf E c.login).perCommand || (rulesOf E c.login).requireToken) = true := by
    rcases hr with hr | hr <;> simp [hr]
  have hn : ¬inner.length < 3 := by omega
  simp [this, hn]

theorem create_within {E : AEnv} {D D' : ADyn} {c : AConn} {l0 : TLabel} {opts : List Arg} {n : Nat}
    (h : contextCreate E D c l0 opts = (.handle n, D')) :
    ∃ l, ceilingAdmits (ceilingFor E c.login) l = true ∧ n = D.next ∧
      D'.ctxs = D.ctxs ++ [⟨D.next, c.login, l, E.now⟩] ∧ D'.next = D.next + 1 := by
  unfold contextCreate at h
  split at h
  · simp at h
  · rename_i l _
    split at h
    · rename_i h' cs nx hcr
      simp only [Prod.mk.injEq, Reply.handle.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      obtain ⟨c1, c2, c3, c4⟩ := create_owner_label hcr
      exact ⟨l, c1, c2, c4, c3⟩
    · simp at h
    · simp at h

theorem contextUse_no_handle (E : AEnv) (D : ADyn) (c : AConn) (inner : List Arg) (n : Nat) :
    (contextUse E D c inner).1 ≠ .handle n := by
  unfold contextUse
  split
  · simp
  · split
    · simp
    · split
      · simp
      · split <;> simp

theorem context_handle_created {E : AEnv} {D D' : ADyn} {c : AConn} {l0 : TLabel} {inner : List Arg} {n : Nat}
    (h : contextHandler E D c l0 inner = (.handle n, D')) : contextCreate E D c l0 (inner.drop 2) = (.handle n, D') := by
  unfold contextHandler at h
  split at h
  · exact h
  · split at h
    · exact absurd (congrArg Prod.fst h) (contextUse_no_handle E D c inner n)
    · simp at h

theorem script_denies_arrival :
    scriptDenied [.lit (word "label"), .lit (word "as"), .lit (word "S"), .lit (word "get")] = true ∧
    scriptDenied [.lit (word "LABEL"), .lit (word "session"), .lit (word "S")] = true ∧
    scriptDenied [.lit (word "context"), .lit (word "create")] = true ∧
    scriptDenied [.lit (word "context"), .lit (word "info"), .lit (word "x")] = true ∧
    scriptDenied [.lit (word "label"), .lit (word "WHOAMI")] = false ∧
    scriptDenied [.lit (word "context"), .lit (word "help")] = false ∧
    scriptDenied [.lit (word "get"), .lit (word "k")] = false := by
  decide

theorem script_denied_label {args : List Arg} (h : isCmd args "label" = true)
    (hw : argIs args 1 "whoami" = false) (hh : argIs args 1 "help" = false) : scriptDenied args = true := by
  simp [scriptDenied, h, hw, hh]

theorem script_denied_context {args : List Arg} (h : isCmd args "context" = true) (hh : argIs args 1 "help" = false) :
    scriptDenied args = true := by
  simp [scriptDenied, h, hh]

def Keeps (D D' : ADyn) : Prop :=
  D'.next = D.next ∧ ∀ x ∈ D'.ctxs, ∃ y ∈ D.ctxs, y.handle = x.handle ∧ y.owner = x.owner ∧ y.label = x.label

def Grows (E : AEnv) (D D' : ADyn) : Prop :=
  D.next ≤ D'.next ∧ D'.next ≤ D.next + 1 ∧ ∀ x ∈ D'.ctxs,
    (∃ y ∈ D.ctxs, y.handle = x.handle ∧ y.owner = x.owner ∧ y.label = x.label) ∨
    (x.handle = D.next ∧ D'.next = D.next + 1 ∧ ceilingAdmits (ceilingFor E x.owner) x.label = true)

theorem keeps_refl (D : ADyn) : Keeps D D := ⟨rfl, fun x hx => ⟨x, hx, rfl, rfl, rfl⟩⟩

theorem keeps_ctxs {D D' : ADyn} (hn : D'.next = D.next) (hc : D'.ctxs = D.ctxs) : Keeps D D' :=
  ⟨hn, fun x hx => ⟨x, by rw [← hc]; exact hx, rfl, rfl, rfl⟩⟩

theorem keeps_trans {D1 D2 D3 : ADyn} (a : Keeps D1 D2) (b : Keeps D2 D3) : Keeps D1 D3 :=
  ⟨b.1.trans a.1, fun x hx => by
    obtain ⟨y, hy, h1, h2, h3⟩ := b.2 x hx
    obtain ⟨z, hz, g1, g2, g3⟩ := a.2 y hy
    exact ⟨z, hz, g1.trans h1, g2.trans h2, g3.trans h3⟩⟩

theorem remove_keeps (D : ADyn) (h : Nat) : Keeps D { D with ctxs := ctxRemove D.ctxs h } :=
  ⟨rfl, fun x hx => ⟨x, (mem_remove hx).1, rfl, rfl, rfl⟩⟩

theorem setConn_keeps (D : ADyn) (id : Nat) (c : AConn) : Keeps D (setConn D id c) := keeps_ctxs rfl rfl

theorem findIn_keeps {E : AEnv} {D D' : ADyn} {login : List Nat} {r : HRef} {o : Option ACtx}
    (h : findIn E D login r = (o, D')) : Keeps D D' := by
  unfold findIn at h
  simp only [Prod.mk.injEq] at h
  obtain ⟨_, rfl⟩ := h
  exact ⟨rfl, find_preserves (o := (ctxFind E.idle E.now D.ctxs login (ceilingFor E login) r).1) rfl⟩

theorem tokenEntry_keeps {E : AEnv} {D D' : ADyn} {login : List Nat} {sp : TokSpec} {o : Option TokEntry}
    (h : tokenEntry E D login sp = (o, D')) : Keeps D D' := by
  unfold tokenEntry at h
  split at h
  · simp only [Prod.mk.injEq] at h
    obtain ⟨_, rfl⟩ := h
    exact keeps_refl D
  · split at h
    · simp only [Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      exact keeps_refl D
    · simp only [Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      exact keeps_ctxs rfl rfl

theorem tokenCtx_keeps {E : AEnv} {D D' : ADyn} {login : List Nat} {l : TLabel} {r : Option HRef}
    {o : Option (TLabel × Option ACtx)} (h : tokenCtx E D login l r = (o, D')) : Keeps D D' := by
  cases r with
  | none =>
    simp only [tokenCtx, Prod.mk.injEq] at h
    obtain ⟨_, rfl⟩ := h
    exact keeps_refl D
  | some r =>
    simp only [tokenCtx] at h
    split at h
    · rename_i D2 hf
      simp only [Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      exact findIn_keeps hf
    · rename_i x D2 hf
      split at h
      · simp only [Prod.mk.injEq] at h
        obtain ⟨_, rfl⟩ := h
        exact findIn_keeps hf
      · simp only [Prod.mk.injEq] at h
        obtain ⟨_, rfl⟩ := h
        exact findIn_keeps hf

theorem tokenVerify_keeps {E : AEnv} {D D' : ADyn} {login : List Nat} {sp : TokSpec}
    {o : Option (TLabel × Option ACtx)} (h : tokenVerify E D login sp = (o, D')) : Keeps D D' := by
  unfold tokenVerify at h
  split at h
  · rename_i D1 he
    simp only [Prod.mk.injEq] at h
    obtain ⟨_, rfl⟩ := h
    exact tokenEntry_keeps he
  · rename_i e D1 he
    have k := tokenEntry_keeps he
    split at h
    · simp only [Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      exact keeps_trans k (keeps_ctxs rfl rfl)
    · split at h
      · simp only [Prod.mk.injEq] at h
        obtain ⟨_, rfl⟩ := h
        exact k
      · exact keeps_trans k (tokenCtx_keeps h)

theorem tailFind_keeps (E : AEnv) (D : ADyn) (login : List Nat) (a : Arg) (l : TLabel) (u : Nat) :
    Keeps D (tailFind E D login a l u).2 := by
  unfold tailFind
  split
  · rename_i D1 hf
    exact findIn_keeps hf
  · rename_i x D1 hf
    split
    · exact findIn_keeps hf
    · exact findIn_keeps hf

theorem contextTail_keeps (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) (i : Nat) (l : TLabel) :
    Keeps D (contextTail E D login args i l).2 := by
  unfold contextTail
  split
  · split
    · exact tailFind_keeps ..
    · exact keeps_refl D
  · exact keeps_refl D

theorem markingEnd_snd (args : List Arg) (r : Except String Parsed × ADyn) : (markingEnd args r).2 = r.2 := by
  match r with
  | (.ok p, D1) =>
    by_cases hu : args.length ≤ p.used <;> simp [markingEnd, hu]
  | (.error m, D1) => rfl

theorem markingForm_keeps (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    Keeps D (markingForm E D login args).2 := by
  unfold markingForm
  split
  · exact keeps_refl D
  · split
    · exact keeps_refl D
    · rw [markingEnd_snd]
      exact contextTail_keeps ..

theorem tokenForm_keeps (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    Keeps D (tokenForm E D login args).2 := by
  unfold tokenForm
  split
  · exact keeps_refl D
  · split
    · rename_i D1 hv
      exact tokenVerify_keeps hv
    · rename_i l x D1 hv
      exact tokenVerify_keeps hv

theorem contextForm_keeps (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    Keeps D (contextForm E D login args).2 := by
  unfold contextForm
  split
  · exact keeps_refl D
  · split
    · rename_i D1 hf
      exact findIn_keeps hf
    · rename_i x D1 hf
      exact findIn_keeps hf

theorem labelAsParse_keeps (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    Keeps D (labelAsParse E D login args).2 := by
  unfold labelAsParse
  split
  · exact keeps_refl D
  · split
    · exact tokenForm_keeps ..
    · split
      · exact keeps_refl D
      · split
        · exact contextForm_keeps ..
        · exact markingForm_keeps ..

theorem refuse_keeps (D : ADyn) (id : Nat) (c : AConn) (a : List Arg) (m : String) : Keeps D (refuse D id c a m).2 := by
  unfold refuse
  split
  · exact keeps_ctxs rfl rfl
  · exact keeps_ctxs rfl rfl

theorem arriveFinish_keeps (E : AEnv) (D : ADyn) (id : Nat) (c : AConn) (inner : List Arg) (l0 : TLabel)
    (ctx : Option ACtx) (p : Bool) : Keeps D (arriveFinish E D id c inner l0 ctx p).2 := by
  unfold arriveFinish
  split
  · exact refuse_keeps ..
  · split
    · exact keeps_trans (setConn_keeps ..) (refuse_keeps ..)
    · exact setConn_keeps ..

theorem arrive_keeps (E : AEnv) (D : ADyn) (id : Nat) (args : List Arg) : Keeps D (arrive E D id args).2 := by
  unfold arrive
  split
  · exact keeps_refl D
  · rename_i c _
    split
    · have k := labelAsParse_keeps E D c.login args
      split
      · rename_i m D1 hp
        rw [hp] at k
        exact keeps_trans k (refuse_keeps ..)
      · rename_i p D1 hp
        rw [hp] at k
        split
        · exact keeps_trans k (refuse_keeps ..)
        · exact keeps_trans k (arriveFinish_keeps ..)
    · split
      · exact refuse_keeps ..
      · exact arriveFinish_keeps ..

theorem keeps_grows {E : AEnv} {D D' : ADyn} (k : Keeps D D') : Grows E D D' :=
  ⟨by have := k.1; omega, by have := k.1; omega, fun x hx => Or.inl (k.2 x hx)⟩

theorem keeps_then_grows {E : AEnv} {D1 D2 D3 : ADyn} (a : Keeps D1 D2) (b : Grows E D2 D3) : Grows E D1 D3 := by
  obtain ⟨b1, b2, b3⟩ := b
  rw [a.1] at b1 b2
  refine ⟨b1, b2, fun x hx => ?_⟩
  rcases b3 x hx with ⟨y, hy, h1, h2, h3⟩ | ⟨h1, h2, h3⟩
  · obtain ⟨z, hz, g1, g2, g3⟩ := a.2 y hy
    exact Or.inl ⟨z, hz, g1.trans h1, g2.trans h2, g3.trans h3⟩
  · rw [a.1] at h1 h2
    exact Or.inr ⟨h1, h2, h3⟩

theorem sessionHandler_keeps {E : AEnv} {D D' : ADyn} {id : Nat} {c : AConn} {inner : List Arg} {r : Reply}
    (h : sessionHandler E D id c inner = (r, D')) : Keeps D D' := by
  unfold sessionHandler at h
  repeat' split at h
  all_goals
    simp only [Prod.mk.injEq] at h
    obtain ⟨_, rfl⟩ := h
    exact keeps_ctxs rfl rfl

theorem contextUse_keeps {E : AEnv} {D D' : ADyn} {c : AConn} {inner : List Arg} {r : Reply}
    (h : contextUse E D c inner = (r, D')) : Keeps D D' := by
  unfold contextUse at h
  split at h
  · simp only [Prod.mk.injEq] at h
    obtain ⟨_, rfl⟩ := h
    exact keeps_refl D
  · split at h
    · simp only [Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      exact keeps_refl D
    · split at h
      · rename_i D1 hf
        simp only [Prod.mk.injEq] at h
        obtain ⟨_, rfl⟩ := h
        exact findIn_keeps hf
      · rename_i x D1 hf
        split at h
        · simp only [Prod.mk.injEq] at h
          obtain ⟨_, rfl⟩ := h
          exact keeps_trans (findIn_keeps hf) (remove_keeps D1 x.handle)
        · simp only [Prod.mk.injEq] at h
          obtain ⟨_, rfl⟩ := h
          exact findIn_keeps hf

theorem contextCreate_grows {E : AEnv} {D D' : ADyn} {c : AConn} {l0 : TLabel} {opts : List Arg} {r : Reply}
    (h : contextCreate E D c l0 opts = (r, D')) : Grows E D D' := by
  unfold contextCreate at h
  split at h
  · simp only [Prod.mk.injEq] at h
    obtain ⟨_, rfl⟩ := h
    exact keeps_grows (keeps_refl D)
  · rename_i l _
    split at h
    · rename_i h' cs n hcr
      simp only [Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      obtain ⟨c1, _, rfl, rfl⟩ := create_owner_label hcr
      refine ⟨by simp, by simp, fun x hx => ?_⟩
      rcases List.mem_append.1 hx with hx | hx
      · exact Or.inl ⟨x, hx, rfl, rfl, rfl⟩
      · simp only [List.mem_singleton] at hx
        subst hx
        exact Or.inr ⟨rfl, rfl, c1⟩
    · simp only [Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      exact keeps_grows (keeps_refl D)
    · simp only [Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      exact keeps_grows (keeps_refl D)

theorem contextHandler_grows {E : AEnv} {D D' : ADyn} {c : AConn} {l0 : TLabel} {inner : List Arg} {r : Reply}
    (h : contextHandler E D c l0 inner = (r, D')) : Grows E D D' := by
  unfold contextHandler at h
  split at h
  · exact contextCreate_grows h
  · split at h
    · exact keeps_grows (contextUse_keeps h)
    · simp only [Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      exact keeps_grows (keeps_refl D)

theorem handleCmd_grows {E : AEnv} {D D' : ADyn} {id : Nat} {l : TLabel} {inner : List Arg} {r : Reply}
    (h : handleCmd E D id l inner = (r, D')) : Grows E D D' := by
  unfold handleCmd at h
  repeat' split at h
  all_goals first
    | exact keeps_grows (sessionHandler_keeps h)
    | exact contextHandler_grows h
    | (simp only [Prod.mk.injEq] at h
       obtain ⟨_, rfl⟩ := h
       exact keeps_grows (keeps_ctxs rfl rfl))

theorem request_grows (E : AEnv) (D : ADyn) (id : Nat) (args : List Arg) : Grows E D (request E D id args).2.2 := by
  unfold request
  have k := arrive_keeps E D id args
  split
  · rename_i l inner x D1 ha
    rw [ha] at k
    exact keeps_then_grows k (handleCmd_grows (r := (handleCmd E D1 id l inner).1) rfl)
  · rename_i a D1 _ ha
    rw [ha] at k
    exact keeps_grows k

theorem request_label_fixed {E : AEnv} {D : ADyn} {id : Nat} {args : List Arg} {x : ACtx}
    (hx : x ∈ (request E D id args).2.2.ctxs) (hold : x.handle < D.next) :
    ∃ y ∈ D.ctxs, y.handle = x.handle ∧ y.owner = x.owner ∧ y.label = x.label := by
  rcases (request_grows E D id args).2.2 x hx with h | ⟨h1, _, _⟩
  · exact h
  · omega

theorem request_new_within {E : AEnv} {D : ADyn} {id : Nat} {args : List Arg} {x : ACtx}
    (hx : x ∈ (request E D id args).2.2.ctxs) (hnew : ∀ y ∈ D.ctxs, y.handle ≠ x.handle) :
    x.handle = D.next ∧ ceilingAdmits (ceilingFor E x.owner) x.label = true := by
  rcases (request_grows E D id args).2.2 x hx with ⟨y, hy, h1, _, _⟩ | ⟨h1, _, h3⟩
  · exact absurd h1 (hnew y hy)
  · exact ⟨h1, h3⟩

theorem requests_next (E : AEnv) : ∀ (reqs : List (Nat × List Arg)) (D : ADyn), D.next ≤ (requests E D reqs).next
  | [], _ => Nat.le_refl _
  | (id, args) :: rest, D => Nat.le_trans (request_grows E D id args).1 (requests_next E rest _)

theorem requests_label_fixed (E : AEnv) : ∀ (reqs : List (Nat × List Arg)) (D : ADyn) (x : ACtx),
    x ∈ (requests E D reqs).ctxs → x.handle < D.next →
    ∃ y ∈ D.ctxs, y.handle = x.handle ∧ y.owner = x.owner ∧ y.label = x.label
  | [], D, x, hx, _ => ⟨x, hx, rfl, rfl, rfl⟩
  | (id, args) :: rest, D, x, hx, hlt => by
    have hle := (request_grows E D id args).1
    obtain ⟨y, hy, h1, h2, h3⟩ := requests_label_fixed E rest _ x hx (by omega)
    obtain ⟨z, hz, g1, g2, g3⟩ := request_label_fixed hy (by omega)
    exact ⟨z, hz, g1.trans h1, g2.trans h2, g3.trans h3⟩

theorem requests_within (E : AEnv) : ∀ (reqs : List (Nat × List Arg)) (D : ADyn),
    (∀ y ∈ D.ctxs, ceilingAdmits (ceilingFor E y.owner) y.label = true) →
    ∀ x ∈ (requests E D reqs).ctxs, ceilingAdmits (ceilingFor E x.owner) x.label = true
  | [], _, h0 => h0
  | (id, args) :: rest, D, h0 => by
    apply requests_within E rest
    intro y hy
    rcases (request_grows E D id args).2.2 y hy with ⟨z, hz, _, h2, h3⟩ | ⟨_, _, h3⟩
    · rw [← h2, ← h3]
      exact h0 z hz
    · exact h3

theorem isCmd_other {args : List Arg} {w v : String} (h : isCmd args w = true) (hne : (word w == word v) = false) :
    isCmd args v = false := by
  unfold isCmd at *
  rw [beq_iff_eq] at h
  rw [h]
  exact hne

theorem wnote_any (s : WSum) (l : TLabel) : (wnote s l).any = true := by
  unfold wnote
  split
  · rfl
  · split
    · simp_all
    · simp_all

theorem wnote_fold_any (h : TLabel) : ∀ (m : Bool) (ls : List TLabel),
    ls.foldl wnote ⟨true, m, h⟩ = ⟨true, m || ls.any (fun y => y != h), h⟩
  | m, [] => by simp
  | m, x :: xs => by
    have step : wnote ⟨true, m, h⟩ x = ⟨true, m || (x != h), h⟩ := by
      by_cases hx : x = h
      · subst hx
        simp [wnote]
      · have hb : (h != x) = true := bne_iff_ne.2 (Ne.symm hx)
        have hb' : (x != h) = true := bne_iff_ne.2 hx
        simp [wnote, hb, hb']
    rw [List.foldl_cons, step, wnote_fold_any h (m || (x != h)) xs, List.any_cons, Bool.or_assoc]

theorem wdiffers_fold (s : WSum) (hs : s.any = false) (b : TLabel) : ∀ ls : List TLabel,
    wdiffers (ls.foldl wnote s) b = true ↔ ∃ x ∈ ls, x ≠ b
  | [] => by simp [wdiffers, hs]
  | x :: xs => by
    have h1 : wnote s x = ⟨true, false, x⟩ := by simp [wnote, hs]
    rw [List.foldl_cons, h1, wnote_fold_any, Bool.false_or]
    simp only [wdiffers, Bool.true_and, Bool.or_eq_true, List.any_eq_true, bne_iff_ne, ne_eq, List.mem_cons]
    constructor
    · rintro (⟨y, hy, hyx⟩ | hxb)
      · by_cases hyb : y = b
        · exact ⟨x, Or.inl rfl, fun hxb => hyx (hyb.trans hxb.symm)⟩
        · exact ⟨y, Or.inr hy, hyb⟩
      · exact ⟨x, Or.inl rfl, hxb⟩
    · rintro ⟨y, hy, hyb⟩
      by_cases hxb : x = b
      · rcases hy with rfl | hy
        · exact absurd hxb hyb
        · exact Or.inl ⟨y, hy, fun hyx => hyb (hyx.trans hxb)⟩
      · exact Or.inr hxb

theorem wclear_any (s : WSum) : (wclear s).any = false := rfl

theorem handle_exec {E : AEnv} {D : ADyn} {id : Nat} {l : TLabel} {inner : List Arg} {c : AConn}
    (hc : connOf D id = some c) (hx : isCmd inner "exec" = true) (hm : c.inMulti = true) :
    handleCmd E D id l inner = (execReply c, setConn D id (endTx c)) := by
  have hmulti : isCmd inner "multi" = false := isCmd_other hx (by decide)
  have himm : immediate inner = true := by simp [immediate, hx]
  unfold handleCmd
  simp [hc, hm, himm, hmulti, hx]

theorem exec_watch_refused {E : AEnv} {D : ADyn} {id : Nat} {l : TLabel} {inner : List Arg} {c : AConn}
    (hc : connOf D id = some c) (hx : isCmd inner "exec" = true) (hm : c.inMulti = true) (hd : c.dirty = false)
    (hw : wdiffers c.ws c.bound = true) :
    handleCmd E D id l inner = (.err errExecWatch, setConn D id (endTx c)) ∧ (endTx c).ws.any = false ∧
      (endTx c).watched = [] ∧ (endTx c).cas = false ∧ (endTx c).inMulti = false := by
  rw [handle_exec hc hx hm]
  simp [execReply, hd, hw, endTx, clearWatch, wclear]

theorem exec_watch_data_free {c : AConn} (hd : c.dirty = false) (hw : wdiffers c.ws c.bound = true)
    (cas : Bool) (w : List (List Nat × TLabel)) :
    execReply { c with cas := cas, watched := w } = execReply c ∧ endTx { c with cas := cas, watched := w } = endTx c := by
  simp [execReply, hd, hw, endTx, clearWatch]

theorem exec_same_label {c : AConn} (hd : c.dirty = false) (hw : wdiffers c.ws c.bound = false) :
    execReply c = if c.cas then .nil else .exec := by
  simp [execReply, hd, hw]

theorem handle_watch {E : AEnv} {D : ADyn} {id : Nat} {l : TLabel} {inner : List Arg} {c : AConn}
    (hc : connOf D id = some c) (hw : isCmd inner "watch" = true) (hm : c.inMulti = false) :
    handleCmd E D id l inner = (.ok, setConn D id (watchConn c l (inner.drop 1))) ∧
      (watchConn c l (inner.drop 1)).ws = wnote c.ws l ∧ (watchConn c l (inner.drop 1)).cas = c.cas ∧
      (watchConn c l (inner.drop 1)).bound = c.bound ∧ (watchConn c l (inner.drop 1)).inMulti = false := by
  have h1 : isCmd inner "multi" = false := isCmd_other hw (by decide)
  have h2 : isCmd inner "exec" = false := isCmd_other hw (by decide)
  have h3 : isCmd inner "discard" = false := isCmd_other hw (by decide)
  refine ⟨?_, rfl, rfl, rfl, hm⟩
  unfold handleCmd
  simp [hc, hm, h1, h2, h3, hw]

theorem watch_in_multi {E : AEnv} {D : ADyn} {id : Nat} {l : TLabel} {inner : List Arg} {c : AConn}
    (hc : connOf D id = some c) (hw : isCmd inner "watch" = true) (hm : c.inMulti = true) :
    handleCmd E D id l inner = (.err errWatchInMulti, D) := by
  have h1 : isCmd inner "multi" = false := isCmd_other hw (by decide)
  have h2 : isCmd inner "exec" = false := isCmd_other hw (by decide)
  have h3 : isCmd inner "discard" = false := isCmd_other hw (by decide)
  have himm : immediate inner = true := by simp [immediate, hw]
  unfold handleCmd
  simp [hc, hm, himm, h1, h2, h3, hw]

theorem touch_keeps_labels (k : List Nat) (w : TLabel) (c : AConn) :
    (touchConn k w c).ws = c.ws ∧ (touchConn k w c).bound = c.bound ∧ (touchConn k w c).inMulti = c.inMulti ∧
      (touchConn k w c).dirty = c.dirty ∧ (touchConn k w c).login = c.login ∧ (touchConn k w c).session = c.session := by
  unfold touchConn
  split <;> simp

def WInv (c : AConn) : Prop := ∀ e ∈ c.watched, c.ws.any = true ∧ (c.ws.mixed = true ∨ e.2 = c.ws.label)

theorem clearWatch_inv (c : AConn) : WInv (clearWatch c) := by
  intro e he
  simp [clearWatch] at he

theorem endTx_inv (c : AConn) : WInv (endTx c) := clearWatch_inv _

theorem addWatch_mem {ws : List (List Nat × TLabel)} {l : TLabel} : ∀ {keys : List Arg} {e : List Nat × TLabel},
    e ∈ addWatch ws l keys → e ∈ ws ∨ e.2 = l
  | [], _, h => Or.inl h
  | a :: rest, e, h => by
    cases a with
    | lit k =>
      simp only [addWatch] at h
      split at h
      · exact addWatch_mem h
      · rcases addWatch_mem h with h | h
        · rcases List.mem_append.1 h with h | h
          · exact Or.inl h
          · simp only [List.mem_singleton] at h
            exact Or.inr (by rw [h])
        · exact Or.inr h
    | handle n =>
      simp only [addWatch] at h
      exact addWatch_mem h
    | token n =>
      simp only [addWatch] at h
      exact addWatch_mem h

theorem wnote_covers {s : WSum} {l x : TLabel} (h : s.any = true ∧ (s.mixed = true ∨ x = s.label)) :
    (wnote s l).any = true ∧ ((wnote s l).mixed = true ∨ x = (wnote s l).label) := by
  refine ⟨wnote_any s l, ?_⟩
  unfold wnote
  split
  · rename_i hn
    simp [h.1] at hn
  · split
    · exact Or.inl rfl
    · exact h.2

theorem wnote_covers_new (s : WSum) (l : TLabel) : (wnote s l).mixed = true ∨ l = (wnote s l).label := by
  unfold wnote
  split
  · exact Or.inr rfl
  · split
    · exact Or.inl rfl
    · rename_i hne
      simp only [bne_iff_ne, ne_eq, Decidable.not_not] at hne
      exact Or.inr hne.symm

theorem watchConn_inv {c : AConn} (h : WInv c) (l : TLabel) (keys : List Arg) : WInv (watchConn c l keys) := by
  intro e he
  rcases addWatch_mem he with he | he
  · exact wnote_covers (h e he)
  · exact ⟨wnote_any c.ws l, he ▸ wnote_covers_new c.ws l⟩

theorem touchConn_inv {c : AConn} (h : WInv c) (k : List Nat) (w : TLabel) : WInv (touchConn k w c) := by
  unfold touchConn
  split
  · exact h
  · exact h

theorem authConn_inv {c : AConn} (h : WInv c) (login : List Nat) : WInv (authConn c login) := by
  unfold authConn
  split
  · exact h
  · exact h

theorem touch_marks_only_seen {c : AConn} {b : TLabel} (h : WInv c) (hw : wdiffers c.ws b = false)
    {k : List Nat} {w : TLabel} (hc : c.cas = false) (ht : (touchConn k w c).cas = true) : domT b w = true := by
  unfold touchConn at ht
  split at ht
  · rename_i hany
    obtain ⟨e, he, hk⟩ := List.any_eq_true.1 hany
    obtain ⟨_, hd⟩ := band_both hk
    obtain ⟨ha, hl⟩ := h e he
    simp only [wdiffers, ha, Bool.true_and, Bool.or_eq_false_iff, bne_eq_false_iff_eq] at hw
    rcases hl with hm | hl
    · rw [hw.1] at hm
      exact absurd hm (by decide)
    · rw [hl, hw.2] at hd
      exact hd
  · rw [hc] at ht
    exact absurd ht (by decide)

theorem findIn_conns {E : AEnv} {D D' : ADyn} {login : List Nat} {r : HRef} {o : Option ACtx}
    (h : findIn E D login r = (o, D')) : D'.conns = D.conns := by
  unfold findIn at h
  simp only [Prod.mk.injEq] at h
  obtain ⟨_, rfl⟩ := h
  rfl

theorem tokenEntry_conns {E : AEnv} {D D' : ADyn} {login : List Nat} {sp : TokSpec} {o : Option TokEntry}
    (h : tokenEntry E D login sp = (o, D')) : D'.conns = D.conns := by
  unfold tokenEntry at h
  repeat' split at h
  all_goals
    simp only [Prod.mk.injEq] at h
    obtain ⟨_, rfl⟩ := h
    rfl

theorem tokenCtx_conns {E : AEnv} {D D' : ADyn} {login : List Nat} {l : TLabel} {r : Option HRef}
    {o : Option (TLabel × Option ACtx)} (h : tokenCtx E D login l r = (o, D')) : D'.conns = D.conns := by
  cases r with
  | none =>
    simp only [tokenCtx, Prod.mk.injEq] at h
    obtain ⟨_, rfl⟩ := h
    rfl
  | some r =>
    simp only [tokenCtx] at h
    split at h
    · rename_i D2 hf
      simp only [Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      exact findIn_conns hf
    · rename_i x D2 hf
      split at h
      · simp only [Prod.mk.injEq] at h
        obtain ⟨_, rfl⟩ := h
        exact findIn_conns hf
      · simp only [Prod.mk.injEq] at h
        obtain ⟨_, rfl⟩ := h
        exact findIn_conns hf

theorem tokenVerify_conns {E : AEnv} {D D' : ADyn} {login : List Nat} {sp : TokSpec}
    {o : Option (TLabel × Option ACtx)} (h : tokenVerify E D login sp = (o, D')) : D'.conns = D.conns := by
  unfold tokenVerify at h
  split at h
  · rename_i D1 he
    simp only [Prod.mk.injEq] at h
    obtain ⟨_, rfl⟩ := h
    exact tokenEntry_conns he
  · rename_i e D1 he
    have k := tokenEntry_conns he
    split at h
    · simp only [Prod.mk.injEq] at h
      obtain ⟨_, rfl⟩ := h
      exact k
    · split at h
      · simp only [Prod.mk.injEq] at h
        obtain ⟨_, rfl⟩ := h
        exact k
      · exact (tokenCtx_conns h).trans k

theorem tailFind_conns (E : AEnv) (D : ADyn) (login : List Nat) (a : Arg) (l : TLabel) (u : Nat) :
    (tailFind E D login a l u).2.conns = D.conns := by
  unfold tailFind
  split
  · rename_i D1 hf
    exact findIn_conns hf
  · rename_i x D1 hf
    split
    · exact findIn_conns hf
    · exact findIn_conns hf

theorem contextTail_conns (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) (i : Nat) (l : TLabel) :
    (contextTail E D login args i l).2.conns = D.conns := by
  unfold contextTail
  split
  · split
    · exact tailFind_conns ..
    · rfl
  · rfl

theorem labelAsParse_conns (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    (labelAsParse E D login args).2.conns = D.conns := by
  unfold labelAsParse
  split
  · rfl
  · split
    · unfold tokenForm
      split
      · rfl
      · split
        · rename_i D1 hv
          exact tokenVerify_conns hv
        · rename_i l x D1 hv
          exact tokenVerify_conns hv
    · split
      · rfl
      · split
        · unfold contextForm
          split
          · rfl
          · split
            · rename_i D1 hf
              exact findIn_conns hf
            · rename_i x D1 hf
              exact findIn_conns hf
        · unfold markingForm
          split
          · rfl
          · split
            · rfl
            · rw [markingEnd_snd]
              exact contextTail_conns ..

def AllInv (D : ADyn) : Prop := ∀ p ∈ D.conns, WInv p.2

theorem allInv_conns {D D' : ADyn} (h : AllInv D) (e : D'.conns = D.conns) : AllInv D' := by
  intro p hp
  rw [e] at hp
  exact h p hp

theorem setConn_inv {D : ADyn} (h : AllInv D) (id : Nat) {c : AConn} (hc : WInv c) : AllInv (setConn D id c) := by
  intro p hp
  simp only [setConn, List.mem_map] at hp
  obtain ⟨q, hq, rfl⟩ := hp
  split
  · exact hc
  · exact h q hq

theorem connOf_inv {D : ADyn} (h : AllInv D) {id : Nat} {c : AConn} (hc : connOf D id = some c) : WInv c := by
  unfold connOf at hc
  cases hf : D.conns.find? (·.1 == id) with
  | none =>
    rw [hf] at hc
    simp at hc
  | some p =>
    rw [hf] at hc
    simp only [Option.map_some, Option.some.injEq] at hc
    subst hc
    exact h p (List.mem_of_find?_eq_some hf)

theorem winv_same {c c' : AConn} (h : WInv c) (h1 : c'.watched = c.watched) (h2 : c'.ws = c.ws) : WInv c' := by
  intro e he
  rw [h1] at he
  rw [h2]
  exact h e he

theorem fresh_inv (login : List Nat) : WInv ⟨login, false, tbottom, false, false, tbottom, false, false, wsEmpty, []⟩ := by
  intro e he
  simp at he

theorem refuse_inv {D : ADyn} (h : AllInv D) (id : Nat) {c : AConn} (hc : WInv c) (a : List Arg) (m : String) :
    AllInv (refuse D id c a m).2 := by
  unfold refuse
  split
  · exact setConn_inv h id (endTx_inv c)
  · exact setConn_inv h id (winv_same hc rfl rfl)

theorem finishConn_inv {c : AConn} (hc : WInv c) (inner : List Arg) (l : TLabel) (p : Bool) :
    WInv (finishConn c inner l p) := by
  unfold finishConn
  split
  · exact winv_same hc rfl rfl
  · exact hc

theorem pinConn_inv {c : AConn} (hc : WInv c) (inner : List Arg) (l : TLabel) : WInv (pinConn c inner l) := by
  unfold pinConn
  split
  · exact winv_same hc rfl rfl
  · exact hc

theorem arriveFinish_inv {E : AEnv} {D : ADyn} {id : Nat} {c : AConn} {inner : List Arg} {l0 : TLabel}
    {ctx : Option ACtx} {p : Bool} (h : AllInv D) (hc : WInv c) : AllInv (arriveFinish E D id c inner l0 ctx p).2 := by
  unfold arriveFinish
  split
  · exact refuse_inv h id hc _ _
  · split
    · exact refuse_inv (setConn_inv h id (finishConn_inv hc _ _ _)) id (finishConn_inv hc _ _ _) _ _
    · exact setConn_inv h id (pinConn_inv (finishConn_inv hc _ _ _) _ _)

theorem arrive_inv {E : AEnv} {D : ADyn} {id : Nat} {args : List Arg} (h : AllInv D) : AllInv (arrive E D id args).2 := by
  unfold arrive
  split
  · exact h
  · rename_i c hc
    have hci := connOf_inv h hc
    split
    · have e := labelAsParse_conns E D c.login args
      split
      · rename_i m D1 hp
        rw [hp] at e
        exact refuse_inv (allInv_conns h e) id hci _ _
      · rename_i p D1 hp
        rw [hp] at e
        split
        · exact refuse_inv (allInv_conns h e) id hci _ _
        · exact arriveFinish_inv (allInv_conns h e) hci
    · split
      · exact refuse_inv h id hci _ _
      · exact arriveFinish_inv h hci

theorem sessionHandler_inv {E : AEnv} {D : ADyn} {id : Nat} {c : AConn} {inner : List Arg} (h : AllInv D)
    (hc : WInv c) : AllInv (sessionHandler E D id c inner).2 := by
  unfold sessionHandler
  repeat' split
  all_goals first
    | exact h
    | exact setConn_inv h id (winv_same hc rfl rfl)

theorem contextHandler_conns (E : AEnv) (D : ADyn) (c : AConn) (l0 : TLabel) (inner : List Arg) :
    (contextHandler E D c l0 inner).2.conns = D.conns := by
  unfold contextHandler
  split
  · unfold contextCreate
    repeat' split
    all_goals rfl
  · split
    · unfold contextUse
      split
      · rfl
      · split
        · rfl
        · split
          · rename_i D1 hf
            exact findIn_conns hf
          · rename_i x D1 hf
            split
            · exact (show D1.conns = D.conns from findIn_conns hf)
            · exact findIn_conns hf
    · rfl

theorem handleCmd_inv {E : AEnv} {D : ADyn} {id : Nat} {l : TLabel} {inner : List Arg} (h : AllInv D) :
    AllInv (handleCmd E D id l inner).2 := by
  unfold handleCmd
  split
  · exact h
  · rename_i c hc
    have hci := connOf_inv h hc
    repeat' split
    all_goals first
      | exact h
      | exact setConn_inv h id (endTx_inv _)
      | exact setConn_inv h id (watchConn_inv hci _ _)
      | exact setConn_inv h id (clearWatch_inv _)
      | exact setConn_inv h id (winv_same hci rfl rfl)
      | exact sessionHandler_inv h hci
      | exact allInv_conns h (contextHandler_conns ..)

theorem request_inv {E : AEnv} {D : ADyn} {id : Nat} {args : List Arg} (h : AllInv D) :
    AllInv (request E D id args).2.2 := by
  unfold request
  have ha := arrive_inv (E := E) (id := id) (args := args) h
  split
  · rename_i l inner x D1 hr
    rw [hr] at ha
    exact handleCmd_inv ha
  · rename_i a D1 _ hr
    rw [hr] at ha
    exact ha

theorem touch_inv {D : ADyn} (h : AllInv D) (k : List Nat) (w : TLabel) : AllInv (touch D k w) := by
  intro p hp
  simp only [touch, List.mem_map] at hp
  obtain ⟨q, hq, rfl⟩ := hp
  exact touchConn_inv (h q hq) k w

theorem auth_inv {D : ADyn} (h : AllInv D) (id : Nat) (login : List Nat) : AllInv (auth D id login) := by
  unfold auth
  split
  · exact h
  · rename_i c hc
    exact setConn_inv h id (authConn_inv (connOf_inv h hc) login)

inductive AEv
  | req (id : Nat) (args : List Arg)
  | touch (k : List Nat) (w : TLabel)
  | auth (id : Nat) (login : List Nat)

def evStep (E : AEnv) (D : ADyn) : AEv → ADyn
  | .req id args => (request E D id args).2.2
  | .touch k w => touch D k w
  | .auth id login => auth D id login

def evRun (E : AEnv) : ADyn → List AEv → ADyn
  | D, [] => D
  | D, e :: rest => evRun E (evStep E D e) rest

theorem evRun_inv (E : AEnv) : ∀ (evs : List AEv) (D : ADyn), AllInv D → AllInv (evRun E D evs)
  | [], _, h => h
  | e :: rest, D, h => by
    apply evRun_inv E rest
    cases e with
    | req id args => exact request_inv h
    | touch k w => exact touch_inv h k w
    | auth id login => exact auth_inv h id login

theorem watch_rule_reachable (E : AEnv) (evs : List AEv) (D : ADyn) (h0 : AllInv D) {id : Nat} {c : AConn}
    (hc : connOf (evRun E D evs) id = some c) :
    (∀ b k w, wdiffers c.ws b = false → c.cas = false → (touchConn k w c).cas = true → domT b w = true) ∧
    (c.dirty = false → wdiffers c.ws c.bound = true →
      ∀ cas ws, execReply { c with cas := cas, watched := ws } = .err errExecWatch ∧
        endTx { c with cas := cas, watched := ws } = endTx c) := by
  have hi := connOf_inv (evRun_inv E evs D h0) hc
  refine ⟨fun b k w hw hcas ht => touch_marks_only_seen hi hw hcas ht, fun hd hw cas ws => ?_⟩
  obtain ⟨h1, h2⟩ := exec_watch_data_free hd hw cas ws
  rw [h1]
  exact ⟨by simp [execReply, hd, hw], h2⟩

def unmark (c : AConn) : AConn := { c with cas := false }

def unmarkAll (D : ADyn) : ADyn := { D with conns := D.conns.map fun p => (p.1, unmark p.2) }

def quiet : List AEv → List AEv
  | [] => []
  | .req id args :: rest => .req id args :: quiet rest
  | .touch _ _ :: rest => quiet rest
  | .auth id login :: rest => .auth id login :: quiet rest

theorem touchConn_watched (k : List Nat) (w : TLabel) (c : AConn) : (touchConn k w c).watched = c.watched := by
  unfold touchConn
  split <;> rfl

theorem touchConn_unmark (k : List Nat) (w : TLabel) (c : AConn) : unmark (touchConn k w c) = unmark c := by
  unfold touchConn
  split <;> rfl

theorem watchConn_mark_free (c : AConn) (l : TLabel) (keys : List Arg) (b : Bool) :
    watchConn { c with cas := b } l keys = { watchConn c l keys with cas := b } := rfl

theorem touch_unmarkAll (D : ADyn) (k : List Nat) (w : TLabel) : unmarkAll (touch D k w) = unmarkAll D := by
  simp only [unmarkAll, touch, List.map_map]
  congr 1
  apply List.map_congr_left
  intro p _
  simp [touchConn_unmark]

theorem connOf_unmarkAll (D : ADyn) (id : Nat) : connOf (unmarkAll D) id = (connOf D id).map unmark := by
  simp only [connOf, unmarkAll, List.find?_map, Option.map_map]
  rfl

theorem setConn_unmarkAll (D : ADyn) (id : Nat) (c : AConn) :
    setConn (unmarkAll D) id (unmark c) = unmarkAll (setConn D id c) := by
  simp only [setConn, unmarkAll, List.map_map]
  congr 1
  apply List.map_congr_left
  intro p _
  by_cases h : p.1 = id <;> simp [h]

theorem findIn_unmarkAll (E : AEnv) (D : ADyn) (login : List Nat) (h : HRef) :
    findIn E (unmarkAll D) login h = ((findIn E D login h).1, unmarkAll (findIn E D login h).2) := rfl

theorem tokenEntry_unmarkAll (E : AEnv) (D : ADyn) (login : List Nat) (sp : TokSpec) :
    tokenEntry E (unmarkAll D) login sp = ((tokenEntry E D login sp).1, unmarkAll (tokenEntry E D login sp).2) := by
  unfold tokenEntry
  cases h1 : (D.cache.find? (·.1 == (login, sp))).map (·.2) with
  | some e => simp [unmarkAll, h1]
  | none => rcases tokenCheck E (rulesOf E login) sp with _ | e <;> simp [unmarkAll, h1]

theorem tokenCtx_unmarkAll (E : AEnv) (D : ADyn) (login : List Nat) (l : TLabel) (r : Option HRef) :
    tokenCtx E (unmarkAll D) login l r = ((tokenCtx E D login l r).1, unmarkAll (tokenCtx E D login l r).2) := by
  cases r with
  | none => rfl
  | some r =>
    simp only [tokenCtx, findIn_unmarkAll]
    rcases findIn E D login r with ⟨_ | x, D2⟩
    · rfl
    · by_cases hx : (x.label != l) = true <;> simp [hx]

theorem tokenVerify_unmarkAll (E : AEnv) (D : ADyn) (login : List Nat) (sp : TokSpec) :
    tokenVerify E (unmarkAll D) login sp = ((tokenVerify E D login sp).1, unmarkAll (tokenVerify E D login sp).2) := by
  simp only [tokenVerify, tokenEntry_unmarkAll]
  rcases tokenEntry E D login sp with ⟨_ | e, D1⟩
  · rfl
  · by_cases h1 : e.expires ≤ (E.now : Int)
    · simp [h1, unmarkAll]
    · by_cases h2 : (!labelValidT E.cfg e.label || !ceilingAdmits (ceilingFor E login) e.label) = true
      · simp [h1, h2]
      · simp only [h1, h2, ↓reduceIte]
        exact tokenCtx_unmarkAll ..

theorem tailFind_unmarkAll (E : AEnv) (D : ADyn) (login : List Nat) (a : Arg) (l : TLabel) (u : Nat) :
    tailFind E (unmarkAll D) login a l u = ((tailFind E D login a l u).1, unmarkAll (tailFind E D login a l u).2) := by
  simp only [tailFind, findIn_unmarkAll]
  rcases findIn E D login (hrefOf a) with ⟨_ | x, D1⟩
  · rfl
  · by_cases hx : (x.label != l) = true <;> simp [hx]

theorem contextTail_unmarkAll (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) (i : Nat) (l : TLabel) :
    contextTail E (unmarkAll D) login args i l =
      ((contextTail E D login args i l).1, unmarkAll (contextTail E D login args i l).2) := by
  unfold contextTail
  rcases args[i]? with _ | a <;> rcases args[i + 1]? with _ | h
  · rfl
  · rfl
  · rfl
  · by_cases hc : (decide (i + 2 < args.length) && isWord a "context" && shaped h) = true
    · simp only [hc, ↓reduceIte]
      exact tailFind_unmarkAll ..
    · simp [hc]

theorem markingEnd_unmarkAll (args : List Arg) (r : Except String Parsed × ADyn) :
    markingEnd args (r.1, unmarkAll r.2) = ((markingEnd args r).1, unmarkAll (markingEnd args r).2) := by
  match r with
  | (.ok p, D1) => by_cases hu : args.length ≤ p.used <;> simp [markingEnd, hu]
  | (.error m, D1) => rfl

theorem markingForm_unmarkAll (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    markingForm E (unmarkAll D) login args = ((markingForm E D login args).1, unmarkAll (markingForm E D login args).2) := by
  unfold markingForm
  rcases markingLabel E args with _ | l
  · rfl
  · by_cases hc : (!ceilingAdmits (ceilingFor E login) l) = true
    · simp [hc]
    · simp only [hc, Bool.false_eq_true, ↓reduceIte, contextTail_unmarkAll]
      exact markingEnd_unmarkAll ..

theorem tokenForm_unmarkAll (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    tokenForm E (unmarkAll D) login args = ((tokenForm E D login args).1, unmarkAll (tokenForm E D login args).2) := by
  unfold tokenForm
  rcases args[3]?.bind (specOf E) with _ | sp
  · rfl
  · simp only [tokenVerify_unmarkAll]
    rcases tokenVerify E D login sp with ⟨_ | ⟨l, x⟩, D1⟩ <;> rfl

theorem contextForm_unmarkAll (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    contextForm E (unmarkAll D) login args = ((contextForm E D login args).1, unmarkAll (contextForm E D login args).2) := by
  unfold contextForm
  rcases args[3]? with _ | h
  · rfl
  · simp only [findIn_unmarkAll]
    rcases findIn E D login (hrefOf h) with ⟨_ | x, D1⟩ <;> rfl

theorem labelAsParse_unmarkAll (E : AEnv) (D : ADyn) (login : List Nat) (args : List Arg) :
    labelAsParse E (unmarkAll D) login args = ((labelAsParse E D login args).1, unmarkAll (labelAsParse E D login args).2) := by
  unfold labelAsParse
  by_cases h1 : args.length ≤ 2
  · simp [h1]
  · by_cases h2 : (argIs args 2 "token" && decide (4 < args.length)) = true
    · simp only [h1, h2, ↓reduceIte]
      exact tokenForm_unmarkAll ..
    · by_cases h3 : (rulesOf E login).requireToken = true
      · simp [h1, h2, h3]
      · by_cases h4 : (argIs args 2 "context" && decide (4 < args.length) && (args[3]?.map shaped).getD false) = true
        · simp only [h1, h2, h3, h4, ↓reduceIte]
          exact contextForm_unmarkAll ..
        · simp only [h1, h2, h3, h4, ↓reduceIte, Bool.false_eq_true]
          exact markingForm_unmarkAll ..

theorem unmark_login (c : AConn) : (unmark c).login = c.login := rfl

theorem unmark_explicit (c : AConn) : (unmark c).explicit = c.explicit := rfl

theorem unmark_inMulti (c : AConn) : (unmark c).inMulti = c.inMulti := rfl

theorem unmark_bound (c : AConn) : (unmark c).bound = c.bound := rfl

theorem unmarkAll_ctxs (D : ADyn) : (unmarkAll D).ctxs = D.ctxs := rfl

theorem unmarkAll_next (D : ADyn) : (unmarkAll D).next = D.next := rfl

theorem gate_unmark (E : AEnv) (c : AConn) (inner : List Arg) (l : TLabel) (p : Bool) :
    gate E (unmark c) inner l p = gate E c inner l p := rfl

theorem sessionOf_unmark (E : AEnv) (c : AConn) : sessionOf E (unmark c) = sessionOf E c := rfl

theorem finishLabel_unmark (c : AConn) (l0 : TLabel) : finishLabel (unmark c) l0 = finishLabel c l0 := rfl

theorem endTx_unmark (c : AConn) : endTx (unmark c) = unmark (endTx c) := rfl

theorem finishConn_unmark (c : AConn) (inner : List Arg) (l : TLabel) (p : Bool) :
    finishConn (unmark c) inner l p = unmark (finishConn c inner l p) := by
  unfold finishConn
  by_cases h : (!c.inMulti && isCmd inner "multi") = true
  · simp only [unmark_inMulti, h, ↓reduceIte]
    rfl
  · simp only [unmark_inMulti, h, ↓reduceIte, Bool.false_eq_true]

theorem pinConn_unmark (c : AConn) (inner : List Arg) (l : TLabel) :
    pinConn (unmark c) inner l = unmark (pinConn c inner l) := by
  unfold pinConn
  by_cases h : (!c.inMulti && needsSession inner && !c.explicit) = true
  · simp only [unmark_inMulti, unmark_explicit, h, ↓reduceIte]
    rfl
  · simp only [unmark_inMulti, unmark_explicit, h, ↓reduceIte, Bool.false_eq_true]

theorem refuse_unmarkAll (D : ADyn) (id : Nat) (c : AConn) (a : List Arg) (m : String) :
    refuse (unmarkAll D) id (unmark c) a m = ((refuse D id c a m).1, unmarkAll (refuse D id c a m).2) := by
  unfold refuse
  by_cases h : (isCmd a "exec" && c.inMulti) = true
  · simp only [unmark_inMulti, h, ↓reduceIte, endTx_unmark, setConn_unmarkAll]
  · simp only [unmark_inMulti, h, ↓reduceIte, Bool.false_eq_true]
    rw [← setConn_unmarkAll]
    rfl

theorem arriveFinish_unmarkAll (E : AEnv) (D : ADyn) (id : Nat) (c : AConn) (inner : List Arg) (l0 : TLabel)
    (ctx : Option ACtx) (p : Bool) :
    arriveFinish E (unmarkAll D) id (unmark c) inner l0 ctx p =
      ((arriveFinish E D id c inner l0 ctx p).1, unmarkAll (arriveFinish E D id c inner l0 ctx p).2) := by
  unfold arriveFinish
  by_cases h : (c.inMulti && p && l0 != c.bound) = true
  · simp only [unmark_inMulti, unmark_bound, h, ↓reduceIte]
    exact refuse_unmarkAll ..
  · simp only [unmark_inMulti, unmark_bound, h, ↓reduceIte, Bool.false_eq_true, gate_unmark, finishLabel_unmark]
    rcases gate E c inner (finishLabel c l0) p with _ | m
    · simp only [finishConn_unmark, pinConn_unmark, setConn_unmarkAll]
    · simp only [finishConn_unmark, setConn_unmarkAll]
      exact refuse_unmarkAll ..

theorem arrive_unmarkAll (E : AEnv) (D : ADyn) (id : Nat) (args : List Arg) :
    arrive E (unmarkAll D) id args = ((arrive E D id args).1, unmarkAll (arrive E D id args).2) := by
  unfold arrive
  rw [connOf_unmarkAll]
  rcases connOf D id with _ | c
  · rfl
  · simp only [Option.map_some, unmark_login, unmark_inMulti, sessionOf_unmark]
    by_cases hl : isLabelAs args = true
    · simp only [hl, ↓reduceIte, labelAsParse_unmarkAll]
      rcases labelAsParse E D c.login args with ⟨_ | p, D1⟩
      · exact refuse_unmarkAll ..
      · by_cases hn : nested (args.drop p.used) = true
        · simp only [hn, ↓reduceIte]
          exact refuse_unmarkAll ..
        · simp only [hn, ↓reduceIte, Bool.false_eq_true]
          exact arriveFinish_unmarkAll ..
    · by_cases hr : (((rulesOf E c.login).perCommand || (rulesOf E c.login).requireToken) && !c.inMulti &&
          !housekeeping args) = true
      · simp only [hl, hr, ↓reduceIte, Bool.false_eq_true]
        exact refuse_unmarkAll ..
      · simp only [hl, hr, ↓reduceIte, Bool.false_eq_true]
        exact arriveFinish_unmarkAll ..

theorem sessionHandler_unmarkAll (E : AEnv) (D : ADyn) (id : Nat) (c : AConn) (inner : List Arg) :
    sessionHandler E (unmarkAll D) id (unmark c) inner =
      ((sessionHandler E D id c inner).1, unmarkAll (sessionHandler E D id c inner).2) := by
  unfold sessionHandler
  simp only [unmark_login]
  by_cases h1 : inner.length < 3
  · simp [h1]
  · by_cases h2 : ((rulesOf E c.login).perCommand || (rulesOf E c.login).requireToken) = true
    · simp [h1, h2]
    · simp only [h1, h2, ↓reduceIte, Bool.false_eq_true]
      rcases sessionLabel E inner with m | l
      · rfl
      · by_cases h3 : (!ceilingAdmits (ceilingFor E c.login) l || !labelValidT E.cfg l) = true
        · simp [h3]
        · simp only [h3, ↓reduceIte, Bool.false_eq_true]
          rw [← setConn_unmarkAll]
          rfl

theorem contextCreate_unmarkAll (E : AEnv) (D : ADyn) (c : AConn) (l0 : TLabel) (opts : List Arg) :
    contextCreate E (unmarkAll D) (unmark c) l0 opts =
      ((contextCreate E D c l0 opts).1, unmarkAll (contextCreate E D c l0 opts).2) := by
  unfold contextCreate
  simp only [unmark_login, unmarkAll_ctxs, unmarkAll_next]
  rcases createLabel E l0 opts with e | l
  · rfl
  · dsimp only
    rcases ctxCreate E.idle E.now E.cap D.next D.ctxs c.login (ceilingFor E c.login) l (labelValidT E.cfg l) with
      ⟨_ | _ | _, cs, n⟩ <;> rfl

theorem contextUse_unmarkAll (E : AEnv) (D : ADyn) (c : AConn) (inner : List Arg) :
    contextUse E (unmarkAll D) (unmark c) inner = ((contextUse E D c inner).1, unmarkAll (contextUse E D c inner).2) := by
  unfold contextUse
  simp only [unmark_login]
  by_cases h1 : inner.length ≠ 3
  · simp [h1]
  · simp only [h1, ↓reduceIte]
    rcases inner[2]? with _ | h
    · rfl
    · simp only [findIn_unmarkAll]
      rcases findIn E D c.login (hrefOf h) with ⟨_ | x, D1⟩
      · rfl
      · by_cases h2 : argIs inner 1 "drop" = true
        · simp only [h2, ↓reduceIte]
          rfl
        · simp only [h2, ↓reduceIte, Bool.false_eq_true]

theorem contextHandler_unmarkAll (E : AEnv) (D : ADyn) (c : AConn) (l0 : TLabel) (inner : List Arg) :
    contextHandler E (unmarkAll D) (unmark c) l0 inner =
      ((contextHandler E D c l0 inner).1, unmarkAll (contextHandler E D c l0 inner).2) := by
  unfold contextHandler
  by_cases h1 : argIs inner 1 "create" = true
  · simp only [h1, ↓reduceIte]
    exact contextCreate_unmarkAll ..
  · by_cases h2 : (argIs inner 1 "info" || argIs inner 1 "drop") = true
    · simp only [h1, h2, ↓reduceIte, Bool.false_eq_true]
      exact contextUse_unmarkAll ..
    · simp only [h1, h2, ↓reduceIte, Bool.false_eq_true]

theorem handleCmd_unmarkAll (E : AEnv) (D : ADyn) (id : Nat) (l : TLabel) (inner : List Arg) :
    (handleCmd E (unmarkAll D) id l inner).2 = unmarkAll (handleCmd E D id l inner).2 := by
  unfold handleCmd
  rw [connOf_unmarkAll]
  rcases connOf D id with _ | c
  · rfl
  · simp only [Option.map_some, unmark_inMulti]
    by_cases h0 : (c.inMulti && !immediate inner) = true
    · simp [h0]
    · simp only [h0, ↓reduceIte, Bool.false_eq_true]
      by_cases h1 : isCmd inner "multi" = true
      · by_cases hm : c.inMulti = true
        · simp [h1, hm]
        · simp only [h1, hm, ↓reduceIte, Bool.false_eq_true]
          rw [← setConn_unmarkAll]
          rfl
      · by_cases h2 : isCmd inner "exec" = true
        · by_cases hm : c.inMulti = true
          · simp only [h1, h2, hm, ↓reduceIte, Bool.false_eq_true, Bool.not_true, endTx_unmark, setConn_unmarkAll]
          · simp [h1, h2, hm]
        · by_cases h3 : isCmd inner "discard" = true
          · by_cases hm : c.inMulti = true
            · simp only [h1, h2, h3, hm, ↓reduceIte, Bool.false_eq_true, Bool.not_true, endTx_unmark,
                setConn_unmarkAll]
            · simp [h1, h2, h3, hm]
          · by_cases h4 : isCmd inner "watch" = true
            · by_cases hm : c.inMulti = true
              · simp [h1, h2, h3, h4, hm]
              · simp only [h1, h2, h3, h4, hm, ↓reduceIte, Bool.false_eq_true]
                rw [← setConn_unmarkAll]
                rfl
            · by_cases h5 : isCmd inner "unwatch" = true
              · simp only [h1, h2, h3, h4, h5, ↓reduceIte, Bool.false_eq_true]
                rw [← setConn_unmarkAll]
                rfl
              · by_cases h6 : (isCmd inner "label" && argIs inner 1 "session") = true
                · simp only [h1, h2, h3, h4, h5, h6, ↓reduceIte, Bool.false_eq_true, sessionHandler_unmarkAll]
                · by_cases h7 : isCmd inner "context" = true
                  · simp only [h1, h2, h3, h4, h5, h6, h7, ↓reduceIte, Bool.false_eq_true, contextHandler_unmarkAll]
                  · simp [h1, h2, h3, h4, h5, h6, h7]

theorem request_unmarkAll (E : AEnv) (D : ADyn) (id : Nat) (args : List Arg) :
    (request E (unmarkAll D) id args).1 = (request E D id args).1 ∧
      (request E (unmarkAll D) id args).2.2 = unmarkAll (request E D id args).2.2 := by
  unfold request
  rw [arrive_unmarkAll]
  rcases arrive E D id args with ⟨a, D1⟩
  cases a with
  | ok l inner x => exact ⟨rfl, handleCmd_unmarkAll ..⟩
  | refused m => exact ⟨rfl, rfl⟩

theorem auth_unmarkAll (D : ADyn) (id : Nat) (login : List Nat) : auth (unmarkAll D) id login = unmarkAll (auth D id login) := by
  unfold auth
  rw [connOf_unmarkAll]
  rcases connOf D id with _ | c
  · rfl
  · simp only [Option.map_some]
    rw [← setConn_unmarkAll]
    unfold authConn
    by_cases h : (c.login == login) = true
    · simp only [unmark_login, h, ↓reduceIte]
    · simp only [unmark_login, h, ↓reduceIte, Bool.false_eq_true]
      rfl

theorem quiet_unmarkAll (E : AEnv) : ∀ (evs : List AEv) (D D' : ADyn), unmarkAll D = unmarkAll D' →
    unmarkAll (evRun E D evs) = unmarkAll (evRun E D' (quiet evs))
  | [], _, _, h => h
  | .req id args :: rest, D, D', h => by
    simp only [evRun, evStep, quiet]
    apply quiet_unmarkAll E rest
    rw [← (request_unmarkAll E D id args).2, h, (request_unmarkAll E D' id args).2]
  | .touch k w :: rest, D, D', h => by
    simp only [evRun, evStep, quiet]
    apply quiet_unmarkAll E rest
    rw [touch_unmarkAll, h]
  | .auth id login :: rest, D, D', h => by
    simp only [evRun, evStep, quiet]
    apply quiet_unmarkAll E rest
    rw [← auth_unmarkAll, h, auth_unmarkAll]

theorem writes_change_only_marks (E : AEnv) (evs : List AEv) (D : ADyn) :
    unmarkAll (evRun E D evs) = unmarkAll (evRun E D (quiet evs)) :=
  quiet_unmarkAll E evs D D rfl

theorem watch_count_write_free (E : AEnv) (evs : List AEv) (D : ADyn) (id : Nat) :
    (connOf (evRun E D evs) id).map (·.watched) = (connOf (evRun E D (quiet evs)) id).map (·.watched) ∧
      (connOf (evRun E D evs) id).map (·.watched.length) =
        (connOf (evRun E D (quiet evs)) id).map (·.watched.length) := by
  have h := congrArg (fun X => connOf X id) (writes_change_only_marks E evs D)
  simp only [connOf_unmarkAll] at h
  have hw := congrArg (Option.map (·.watched)) h
  simp only [Option.map_map] at hw
  refine ⟨hw, ?_⟩
  have hl := congrArg (Option.map List.length) hw
  simp only [Option.map_map] at hl
  exact hl

theorem gate_acl {E : AEnv} {c : AConn} {inner : List Arg} {l : TLabel} {p : Bool}
    (h1 : ceilingAdmits (ceilingFor E c.login) l = true) (h2 : labelValidT E.cfg l = true) (hk : known inner = true)
    (hs : sessionNeededAt E c inner p = false) (ha : aclDenies E c.login inner = true) :
    gate E c inner l p = some (errNoperm c.login (aclTarget inner)) := by
  simp [gate, h1, h2, hk, hs, ha]

theorem gate_none_acl {E : AEnv} {c : AConn} {inner : List Arg} {l : TLabel} {p : Bool}
    (h : gate E c inner l p = none) (hk : known inner = true) : aclDenies E c.login inner = false := by
  cases ha : aclDenies E c.login inner
  · rfl
  · exfalso
    unfold gate at h
    split at h
    · simp at h
    · split at h
      · rename_i hn
        simp [hk] at hn
      · split at h
        · simp at h
        · simp at h

def sessOf (c : AConn) : Bool × TLabel := (c.explicit, c.session)

theorem find_map_same {α : Type} {l : List (Nat × α)} {id : Nat} {p : Nat × α} (v : α)
    (h : l.find? (·.1 == id) = some p) :
    (l.map fun q => if q.1 == id then (id, v) else q).find? (·.1 == id) = some (id, v) := by
  induction l with
  | nil => simp at h
  | cons q rest ih =>
    by_cases hq : q.1 = id
    · simp [hq]
    · have h' : rest.find? (·.1 == id) = some p := by simpa [List.find?_cons, hq] using h
      simpa [List.find?_cons, hq] using ih h'

theorem connOf_setConn {D : ADyn} {id : Nat} {c : AConn} (hc : connOf D id = some c) (c' : AConn) :
    connOf (setConn D id c') id = some c' := by
  unfold connOf at hc ⊢
  unfold setConn
  cases hf : D.conns.find? (·.1 == id) with
  | none =>
    rw [hf] at hc
    simp at hc
  | some q => simp only [find_map_same c' hf, Option.map_some]

theorem connOf_of_conns {D D' : ADyn} (h : D'.conns = D.conns) (id : Nat) : connOf D' id = connOf D id := by
  unfold connOf
  rw [h]

theorem sessOf_finishConn (c : AConn) (inner : List Arg) (l : TLabel) (p : Bool) :
    sessOf (finishConn c inner l p) = sessOf c := by
  unfold finishConn
  split <;> rfl

theorem refuse_sess {D : ADyn} {id : Nat} {c c0 : AConn} (hc : connOf D id = some c0) (a : List Arg) (m : String) :
    ∃ c', connOf (refuse D id c a m).2 id = some c' ∧ sessOf c' = sessOf c := by
  unfold refuse
  split
  · exact ⟨_, connOf_setConn hc _, rfl⟩
  · exact ⟨_, connOf_setConn hc _, rfl⟩

theorem core_refused_sess {E : AEnv} {D : ADyn} {id : Nat} {c c0 : AConn} {inner : List Arg} {l0 : TLabel}
    {ctx : Option ACtx} {p : Bool} {m : String} (hc : connOf D id = some c0)
    (h : (arriveCore E D id c inner l0 ctx p).1 = .refused m) :
    ∃ c', connOf (arriveCore E D id c inner l0 ctx p).2 id = some c' ∧ sessOf c' = sessOf c := by
  unfold arriveCore at h ⊢
  split
  · exact refuse_sess hc _ _
  · rename_i hm
    split
    · obtain ⟨c', h1, h2⟩ := refuse_sess (connOf_setConn hc (finishConn c inner (finishLabel c l0) p)) inner _
      exact ⟨c', h1, by rw [h2, sessOf_finishConn]⟩
    · rename_i hg
      simp [hm, hg] at h

theorem finish_refused_sess {E : AEnv} {D : ADyn} {id : Nat} {c c0 : AConn} {inner : List Arg} {l0 : TLabel}
    {ctx : Option ACtx} {p : Bool} {m : String} (hc : connOf D id = some c0)
    (h : (arriveFinish E D id c inner l0 ctx p).1 = .refused m) :
    ∃ c', connOf (arriveFinish E D id c inner l0 ctx p).2 id = some c' ∧ sessOf c' = sessOf c := by
  unfold arriveFinish at h ⊢
  split
  · exact refuse_sess hc _ _
  · rename_i hm
    split
    · obtain ⟨c', h1, h2⟩ := refuse_sess (connOf_setConn hc (finishConn c inner (finishLabel c l0) p)) inner _
      exact ⟨c', h1, by rw [h2, sessOf_finishConn]⟩
    · rename_i hg
      simp [hm, hg] at h

theorem arrive_refused_keeps_session {E : AEnv} {D : ADyn} {id : Nat} {args : List Arg} {m : String} {c : AConn}
    (hc : connOf D id = some c) (h : (arrive E D id args).1 = .refused m) :
    ∃ c', connOf (arrive E D id args).2 id = some c' ∧ sessOf c' = sessOf c := by
  unfold arrive at h ⊢
  rw [hc] at h ⊢
  simp only at h ⊢
  split
  · rename_i hl
    simp only [hl, ↓reduceIte] at h
    split
    · rename_i mm D1 hp
      have hc1 : connOf D1 id = some c := by
        have e := labelAsParse_conns E D c.login args
        rw [hp] at e
        rw [connOf_of_conns e]
        exact hc
      exact refuse_sess hc1 _ _
    · rename_i pp D1 hp
      have hc1 : connOf D1 id = some c := by
        have e := labelAsParse_conns E D c.login args
        rw [hp] at e
        rw [connOf_of_conns e]
        exact hc
      simp only [hp] at h
      split
      · exact refuse_sess hc1 _ _
      · rename_i hn
        simp only [hn, Bool.false_eq_true, ↓reduceIte] at h
        exact finish_refused_sess hc1 h
  · rename_i hl
    simp only [hl, Bool.false_eq_true, ↓reduceIte] at h
    split
    · exact refuse_sess hc _ _
    · rename_i hr
      simp only [hr, Bool.false_eq_true, ↓reduceIte] at h
      exact finish_refused_sess hc h

theorem arrive_ok_acl {E : AEnv} {D D' : ADyn} {id : Nat} {args inner : List Arg} {l : TLabel} {ctx : Option ACtx}
    {c : AConn} (hc : connOf D id = some c) (hk : known inner = true) (h : arrive E D id args = (.ok l inner ctx, D')) :
    aclDenies E c.login inner = false := by
  unfold arrive at h
  rw [hc] at h
  simp only at h
  split at h
  · split at h
    · exact (refuse_not_ok h).elim
    · split at h
      · exact (refuse_not_ok h).elim
      · unfold arriveFinish at h
        split at h
        · exact (refuse_not_ok h).elim
        · split at h
          · exact (refuse_not_ok h).elim
          · rename_i hg
            simp only [Prod.mk.injEq, Arrival.ok.injEq] at h
            obtain ⟨⟨_, rfl, _⟩, _⟩ := h
            exact gate_none_acl hg hk
  · split at h
    · exact (refuse_not_ok h).elim
    · unfold arriveFinish at h
      split at h
      · exact (refuse_not_ok h).elim
      · split at h
        · exact (refuse_not_ok h).elim
        · rename_i hg
          simp only [Prod.mk.injEq, Arrival.ok.injEq] at h
          obtain ⟨⟨_, rfl, _⟩, _⟩ := h
          exact gate_none_acl hg hk

theorem session_change_needs_admission {E : AEnv} {D : ADyn} {id : Nat} {args : List Arg} {c c' : AConn}
    (hc : connOf D id = some c) (hc' : connOf (arrive E D id args).2 id = some c') (hs : sessOf c' ≠ sessOf c) :
    ∃ l inner ctx, (arrive E D id args).1 = .ok l inner ctx ∧ (known inner = true → aclDenies E c.login inner = false) := by
  cases ha : (arrive E D id args).1 with
  | refused m =>
    obtain ⟨c2, h1, h2⟩ := arrive_refused_keeps_session hc ha
    rw [hc'] at h1
    cases h1
    exact absurd h2 hs
  | ok l inner ctx =>
    refine ⟨l, inner, ctx, rfl, fun hk => ?_⟩
    exact arrive_ok_acl hc hk (Prod.ext ha rfl)

end Labels
