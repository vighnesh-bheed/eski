import Labels

open Labels

def parseNat (s : String) : Except String Nat :=
  match s.toNat? with
  | some n => .ok n
  | none => .error ("invalid natural " ++ s)

def expect {α : Type} : Except String α → IO α
  | .ok a => pure a
  | .error e => throw (IO.userError e)

def hexVal (c : Char) : Except String Nat :=
  if '0' ≤ c ∧ c ≤ '9' then .ok (c.toNat - '0'.toNat)
  else if 'a' ≤ c ∧ c ≤ 'f' then .ok (c.toNat - 'a'.toNat + 10)
  else .error ("invalid hex digit " ++ c.toString)

def unhexAux : List Char → Except String (List Nat)
  | [] => .ok []
  | a :: b :: rest => do return (16 * (← hexVal a) + (← hexVal b)) :: (← unhexAux rest)
  | _ => .error "odd hex length"

def unhex (s : String) : Except String (List Nat) := if s == "-" then .ok [] else unhexAux s.toList

def hexDigit (n : Nat) : Char := if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)

def hex (bs : List Nat) : String :=
  if bs.isEmpty then "-" else String.ofList (bs.flatMap fun b => [hexDigit (b / 16), hexDigit (b % 16)])

def joinOr (xs : List String) : String := if xs.isEmpty then "-" else String.intercalate "," xs

def parseIds (s : String) : Except String (List Nat) :=
  if s == "-" then .ok [] else (s.splitOn ",").mapM parseNat

def parseLabel (s : String) : Except String TLabel :=
  match s.splitOn ":" with
  | [lv, ids, tr] => do return ⟨⟨← parseNat lv, ofIds (← parseIds ids)⟩, ← parseNat tr⟩
  | _ => .error ("invalid label " ++ s)

def showLabel (l : TLabel) : String := s!"{l.sec.level}:{joinOr ((idsOf l.sec.comps compLimit).map toString)}:{l.trust}"

def bit (b : Bool) : String := if b then "1" else "0"

def bits (bs : List Bool) : String := String.ofList (bs.map fun b => if b then '1' else '0')

def cfgErr : CfgErr → String
  | .emptyName => "empty"
  | .nameTooLong => "toolong"
  | .invalidName => "invalid"
  | .duplicateName => "duplicate"
  | .tooManyLevels => "toomanylevels"
  | .tooManyComps => "toomanycomps"
  | .tooManyTrusts => "toomanytrusts"

def pErr : PErr → String
  | .empty => "empty"
  | .tooLong => "toolong"
  | .invalidByte => "invalidbyte"
  | .emptyLevel => "emptylevel"
  | .unknownLevel => "unknownlevel"
  | .badSeparator => "badseparator"
  | .emptyComp => "emptycomp"
  | .unknownComp => "unknowncomp"
  | .dupComp => "dupcomp"
  | .emptyTrust => "emptytrust"
  | .unknownTrust => "unknowntrust"

def dErr : DErr → String
  | .truncated => "truncated"
  | .badMagic => "badmagic"
  | .badVersion => "badversion"
  | .badLevelCount => "badlevelcount"
  | .badCompCount => "badcompcount"
  | .badTrustCount => "badtrustcount"
  | .badName => "badname"
  | .dupName => "dupname"
  | .badLabelCount => "badlabelcount"
  | .badLevel => "badlevel"
  | .badTrust => "badtrust"
  | .badComp => "badcomp"
  | .notBottom => "notbottom"
  | .dupLabel => "duplabel"
  | .trailing => "trailing"

def wv : WV → String
  | .allowed => "allowed"
  | .aboveClearance => "above"
  | .notSession => "notsession"

def mv : MV → String
  | .allowed => "allowed"
  | .notVisible => "hidden"
  | .notSession => "notsession"

def hexWord (n : Nat) : String := String.ofList (Nat.toDigits 16 n)

def showVis (v : Vis) : String := s!"V|{v.built}|{joinOr (v.words.map hexWord)}"

structure St where
  cfg : TConfig := ⟨⟨[], []⟩, []⟩
  table : List TLabel := tableInit
  vis : Vis := build tbottom tableInit
  ctr : Ctr := ctrInit
  subj : Subject := subjectMake tbottom
  aenv : AEnv := ⟨⟨⟨[], []⟩, []⟩, [], 3600, 1000, 0, [], []⟩
  adyn : ADyn := ⟨[], [], 0, []⟩

def cfgCounts (c : TConfig) : String := s!"{c.base.levels.length}|{c.base.comps.length}|{c.trusts.length}"

def filterSpec (c : Char) : Option Bool :=
  if c == 'p' then some true else if c == 'n' then none else some false

def gateRow (v : Vis) (labels : List Nat) (spec : List Char) : String :=
  let slots := List.range (labels.length + 3)
  let lookup : Nat → Option Bool := fun s => (spec[s]?).bind filterSpec
  let eval : Option Bool → Bool := fun a => a.getD false
  let fg : FilterGate Bool := ⟨some eval, some lookup⟩
  let blind : FilterGate Bool := ⟨some eval, none⟩
  let opn : FilterGate Bool := ⟨none, none⟩
  s!"G|{bits (slots.map (gateAccept v labels))}|{bits (slots.map (filterAccept v labels fg))}|" ++
    s!"{bits (slots.map (filterAccept v labels blind))}|{bits (slots.map (filterAccept v labels opn))}"

def parseInt (s : String) : Except String Int :=
  match s.toInt? with
  | some n => .ok n
  | none => .error ("invalid integer " ++ s)

def bruteRow (v : Vis) (k : Nat) (q : Int) (points : List Int) (labels : List Nat) : String :=
  let dist : Nat → Int := fun s => (points.getD s 0 - q) * (points.getD s 0 - q)
  let res := bruteForce points.length (fun _ => true) (gateAccept v labels) dist k
  s!"B|{joinOr (res.map fun c => s!"{c.id}:{c.d}")}"

def nameList (s : String) : Except String (List (List Nat)) :=
  if s == "-" then .ok [] else (s.splitOn ",").mapM unhex

def optHex (s : String) : Except String (Option (List Nat)) :=
  if s == "-" then .ok none else do return some (← unhex s)

def fixedHandle : List Nat := word "0123456789abcdef0123456789abcdef"

def parseArg (s : String) : Except String Arg :=
  match s.splitOn ":" with
  | ["x", h] => do return .lit (← unhex h)
  | ["h", n] => do return .handle (← parseNat n)
  | ["H", n] => do return .handle (← parseNat n)
  | ["t", n] => do return .token (← parseNat n)
  | ["o"] => .ok (.lit fixedHandle)
  | _ => .error ("invalid argument " ++ s)

def parseHRef (s : String) : Except String (Option HRef) :=
  match s.splitOn ":" with
  | ["-"] => .ok none
  | ["s"] => .ok (some .shaped)
  | ["m"] => .ok (some .malformed)
  | ["h", n] => do return some (.handle (← parseNat n))
  | _ => .error ("invalid context reference " ++ s)

def buildCfg (levels comps trusts : List (List Nat)) : Except String TConfig := do
  let mut base : Config := ⟨[], []⟩
  for n in levels do
    match addLevel base n with
    | .ok c => base := c
    | .error _ => throw "level rejected"
  for n in comps do
    match addComp base n with
    | .ok c => base := c
    | .error _ => throw "compartment rejected"
  let mut tc : TConfig := ⟨base, []⟩
  for n in trusts do
    match addTrust tc n with
    | .ok c => tc := c
    | .error _ => throw "trust rejected"
  return tc

def ctxText : Option ACtx → String
  | some x => s!"h{x.handle}"
  | none => "-"

def arrivalText : Arrival → String
  | .ok l inner x => s!"ok:{showLabel l}:{inner.length}:{ctxText x}"
  | .refused m => s!"no:{m}"

def replyText (tc : TConfig) : Reply → String
  | .ok => "OK"
  | .err m => m
  | .handle n => s!"h{n}"
  | .info l => s!"info:{hex ((format tc.base l.sec).getD [])}:{hex (tc.trusts.getD l.trust [])}"
  | .queued => "queued"
  | .exec => "exec"
  | .none => "-"

def connText (D : ADyn) (id : Nat) : String :=
  match connOf D id with
  | none => "-"
  | some c => s!"{bit c.inMulti}{bit c.dirty}{bit c.explicit}:{if c.explicit then showLabel c.session else "-"}:{showLabel c.bound}"

def ruleClear (s : String) : Except String (Bool × Option Label) :=
  if s == "*" then .ok (true, none) else if s == "-" then .ok (false, none) else do return (false, some (← parseLabel s).sec)

def ruleTrust (s : String) : Except String (Bool × Option Nat) :=
  if s == "*" then .ok (true, none) else if s == "-" then .ok (false, none) else do return (false, some (← parseNat s))

def step (st : St) (f : List String) : Except String (St × String) := do
  match f with
  | ["CR"] => return ({ st with cfg := ⟨⟨[], []⟩, []⟩ }, "CR")
  | ["CL", h] =>
    match addLevel st.cfg.base (← unhex h) with
    | .ok c =>
      let n := { st.cfg with base := c }
      return ({ st with cfg := n }, s!"CL|ok|{cfgCounts n}|{hex (c.levels.getLast?.getD [])}")
    | .error e => return (st, s!"CL|{cfgErr e}|{cfgCounts st.cfg}|-")
  | ["CC", h] =>
    match addComp st.cfg.base (← unhex h) with
    | .ok c =>
      let n := { st.cfg with base := c }
      return ({ st with cfg := n }, s!"CC|ok|{cfgCounts n}|{hex (c.comps.getLast?.getD [])}")
    | .error e => return (st, s!"CC|{cfgErr e}|{cfgCounts st.cfg}|-")
  | ["CT", h] =>
    match addTrust st.cfg (← unhex h) with
    | .ok c => return ({ st with cfg := c }, s!"CT|ok|{cfgCounts c}|{hex (c.trusts.getLast?.getD [])}")
    | .error e => return (st, s!"CT|{cfgErr e}|{cfgCounts st.cfg}|-")
  | ["M", h] =>
    match parseT st.cfg (← unhex h) with
    | .ok l =>
      match formatT st.cfg l with
      | some s => return (st, s!"M|ok|{showLabel l}|{hex s}")
      | none => return (st, s!"M|ok|{showLabel l}|unformattable")
    | .error e => return (st, s!"M|{pErr e.err}|{e.offset}|{e.length}")
  | ["F", l] =>
    match formatT st.cfg (← parseLabel l) with
    | some s => return (st, s!"F|{hex s}")
    | none => return (st, "F|invalid")
  | ["L", a, b] =>
    let a ← parseLabel a
    let b ← parseLabel b
    return (st, s!"L|{bit (domT a b)}|{bit (domT b a)}|{showLabel (joinT a b)}|{showLabel (meetT a b)}|" ++
      s!"{bit (ceilingAdmits a b)}|{bit (ceilingAdmits b a)}|{rcmp a b}")
  | ["TR"] => return ({ st with table := tableInit }, "TR|1")
  | ["TI", l] =>
    let l ← parseLabel l
    let r := intern st.table l
    match r.2 with
    | .ok i => return ({ st with table := r.1 }, s!"TI|ok|{i}|{r.1.length}")
    | .error _ => return ({ st with table := r.1 }, s!"TI|full|-|{r.1.length}")
  | ["TF", l] =>
    match find st.table (← parseLabel l) with
    | some i => return (st, s!"TF|{i}")
    | none => return (st, "TF|-")
  | ["E"] =>
    match encodeChecked st.cfg st.table with
    | some bs => return (st, s!"E|{hex bs}")
    | none => return (st, "E|invalid")
  | ["D", h] =>
    match decode (← unhex h) with
    | .ok (c, t) => return (st, s!"D|ok|{cfgCounts c}|{t.length}|{hex (encode c t)}")
    | .error e => return (st, s!"D|{dErr e}")
  | ["V", l] =>
    let v := build (← parseLabel l) st.table
    return ({ st with vis := v }, showVis v)
  | ["VR"] =>
    let v := refresh st.table st.vis
    return ({ st with vis := v }, showVis v)
  | ["G", ids, spec] =>
    let labels ← parseIds ids
    return (st, gateRow st.vis labels (if spec == "-" then [] else spec.toList))
  | ["B", k, q, pts, ids] =>
    let points ← (if pts == "-" then pure [] else (pts.splitOn ",").mapM parseInt)
    return (st, bruteRow st.vis (← parseNat k) (← parseInt q) points (← parseIds ids))
  | ["SU", c, s] =>
    let base := subjectMake (← parseLabel c)
    match setSession base (← parseLabel s) with
    | some s' => return ({ st with subj := s' }, s!"SU|1|{showLabel (reader s')}")
    | none => return ({ st with subj := base }, s!"SU|0|{showLabel (reader base)}")
  | ["SR", l] => return (st, s!"SR|{bit (mayRead st.subj (← parseLabel l))}")
  | ["SW", l] => return (st, s!"SW|{wv (mayWrite st.subj (← parseLabel l))}")
  | ["SM", l] => return (st, s!"SM|{mv (mayModify st.subj (← parseLabel l))}")
  | ["SD"] => return (st, s!"SD|{showLabel (writeLabel st.subj)}|{wv (mayWrite st.subj (writeLabel st.subj))}")
  | ["NR"] => return ({ st with ctr := ctrInit }, "NR")
  | ["NA", id, d] =>
    match ctrAdd st.ctr (← parseNat id) (← parseNat d) with
    | .ok c => return ({ st with ctr := c }, s!"NA|ok|{c.total}")
    | .error .overflow => return (st, s!"NA|overflow|{st.ctr.total}")
    | .error .invalid => return (st, s!"NA|invalid|{st.ctr.total}")
    | .error .underflow => return (st, s!"NA|underflow|{st.ctr.total}")
  | ["NS", id, d] =>
    match ctrSub st.ctr (← parseNat id) (← parseNat d) with
    | .ok c => return ({ st with ctr := c }, s!"NS|ok|{c.total}")
    | .error .overflow => return (st, s!"NS|overflow|{st.ctr.total}")
    | .error .invalid => return (st, s!"NS|invalid|{st.ctr.total}")
    | .error .underflow => return (st, s!"NS|underflow|{st.ctr.total}")
  | ["NV"] => return (st, s!"NV|{visibleTotal st.ctr st.vis}|{joinOr (st.ctr.counts.map toString)}")
  | ["AX", lv, cm, tr, aud, idle, cap] =>
    let tc ← buildCfg (← nameList lv) (← nameList cm) (← nameList tr)
    let e : AEnv := ⟨tc, ← unhex aud, ← parseNat idle, ← parseNat cap, st.aenv.now, [], []⟩
    return ({ st with aenv := e, adyn := ⟨[], [], 0, []⟩ }, s!"AX|{cfgCounts tc}")
  | ["AU", login, clr, tr, pc, rt, keys, _] =>
    let login ← unhex login
    let (ct, cl) ← ruleClear clr
    let (tt, tl) ← ruleTrust tr
    let r : LRules := ⟨ct, cl, tt, tl, pc == "1", rt == "1", ← parseIds keys⟩
    let e := { st.aenv with users := (login, r) :: st.aenv.users.filter (·.1 != login) }
    return ({ st with aenv := e, adyn := { st.adyn with cache := [] } },
      s!"AU|{showLabel (ceilingFor e login)}|{bit r.perCommand}|{bit r.requireToken}|{r.keys.length}")
  | ["AC", id, login] =>
    let c : AConn := ⟨← unhex login, false, tbottom, false, false, tbottom⟩
    return ({ st with adyn := { st.adyn with conns := st.adyn.conns ++ [(← parseNat id, c)] } }, s!"AC|{id}")
  | ["AT", now] => return ({ st with aenv := { st.aenv with now := ← parseNat now } }, s!"AT|{now}")
  | ["AO", n, secret, marking, trust, expires, aud, ctx, flaw] =>
    let sp : TokSpec := ⟨← parseNat secret, ← optHex marking, ← optHex trust, ← unhex expires, ← optHex aud,
      ← parseHRef ctx, ← parseNat flaw⟩
    return ({ st with aenv := { st.aenv with tokens := st.aenv.tokens ++ [(← parseNat n, sp)] } }, s!"AO|{n}")
  | ["AW"] =>
    let cs := ctxSweep st.aenv.idle st.aenv.now st.adyn.ctxs
    return ({ st with adyn := { st.adyn with ctxs := cs } }, s!"AW|{cs.length}")
  | ["AQ", id, a] =>
    let a ← parseArg a
    match connOf st.adyn (← parseNat id) with
    | none => throw "unknown connection"
    | some c =>
      let (x, D) := findIn st.aenv st.adyn c.login (hrefOf a)
      return ({ st with adyn := D }, s!"AQ|{ctxText x}|{D.ctxs.length}")
  | "AS" :: args => return (st, s!"AS|{bit (scriptDenied (← args.mapM parseArg))}")
  | kind :: id :: args =>
    if kind == "AR" || kind == "AH" then do
      let id ← parseNat id
      let (a, r, D) := request st.aenv st.adyn id (← args.mapM parseArg)
      return ({ st with adyn := D }, s!"{kind}|{arrivalText a}|{replyText st.aenv.cfg r}|{connText D id}|{D.ctxs.length}")
    else throw ("unknown case " ++ String.intercalate " " f)
  | _ => throw ("unknown case " ++ String.intercalate " " f)

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "expected case path")
  let input ← IO.FS.readFile path
  let out ← IO.getStdout
  let mut st : St := {}
  for line in input.splitOn "\n" do
    if line.isEmpty then continue
    let (next, row) ← expect (step st (line.splitOn " "))
    st := next
    out.putStrLn row
