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

def parseLabel (s : String) : Except String Label :=
  match s.splitOn ":" with
  | [lv, ids] => do return ⟨← parseNat lv, ofIds (← parseIds ids)⟩
  | _ => .error ("invalid label " ++ s)

def showLabel (l : Label) : String := s!"{l.level}:{joinOr ((idsOf l.comps compLimit).map toString)}"

def bit (b : Bool) : String := if b then "1" else "0"

def bits (bs : List Bool) : String := String.ofList (bs.map fun b => if b then '1' else '0')

def cfgErr : CfgErr → String
  | .emptyName => "empty"
  | .nameTooLong => "toolong"
  | .invalidName => "invalid"
  | .duplicateName => "duplicate"
  | .tooManyLevels => "toomanylevels"
  | .tooManyComps => "toomanycomps"

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

def dErr : DErr → String
  | .truncated => "truncated"
  | .badMagic => "badmagic"
  | .badVersion => "badversion"
  | .badLevelCount => "badlevelcount"
  | .badCompCount => "badcompcount"
  | .badName => "badname"
  | .dupName => "dupname"
  | .badLabelCount => "badlabelcount"
  | .badLevel => "badlevel"
  | .badComp => "badcomp"
  | .notBottom => "notbottom"
  | .dupLabel => "duplabel"
  | .trailing => "trailing"

def wv : WV → String
  | .allowed => "allowed"
  | .aboveClearance => "above"
  | .writeDown => "down"

def mv : MV → String
  | .allowed => "allowed"
  | .notVisible => "hidden"
  | .writeDown => "down"

def hexWord (n : Nat) : String := String.ofList (Nat.toDigits 16 n)

def showVis (v : Vis) : String := s!"V|{v.built}|{joinOr (v.words.map hexWord)}"

structure St where
  cfg : Config := ⟨[], []⟩
  table : List Label := tableInit
  vis : Vis := build bottom tableInit
  ctr : Ctr := ctrInit
  subj : Subject := subjectMake bottom

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

def step (st : St) (f : List String) : Except String (St × String) := do
  match f with
  | ["CR"] => return ({ st with cfg := ⟨[], []⟩ }, "CR")
  | ["CL", h] =>
    match addLevel st.cfg (← unhex h) with
    | .ok c => return ({ st with cfg := c }, s!"CL|ok|{c.levels.length}|{c.comps.length}|{hex (c.levels.getLast?.getD [])}")
    | .error e => return (st, s!"CL|{cfgErr e}|{st.cfg.levels.length}|{st.cfg.comps.length}|-")
  | ["CC", h] =>
    match addComp st.cfg (← unhex h) with
    | .ok c => return ({ st with cfg := c }, s!"CC|ok|{c.levels.length}|{c.comps.length}|{hex (c.comps.getLast?.getD [])}")
    | .error e => return (st, s!"CC|{cfgErr e}|{st.cfg.levels.length}|{st.cfg.comps.length}|-")
  | ["M", h] =>
    match parse st.cfg (← unhex h) with
    | .ok l =>
      match format st.cfg l with
      | some s => return (st, s!"M|ok|{showLabel l}|{hex s}")
      | none => return (st, s!"M|ok|{showLabel l}|unformattable")
    | .error e => return (st, s!"M|{pErr e.err}|{e.offset}|{e.length}")
  | ["F", l] =>
    match format st.cfg (← parseLabel l) with
    | some s => return (st, s!"F|{hex s}")
    | none => return (st, "F|invalid")
  | ["L", a, b] =>
    let a ← parseLabel a
    let b ← parseLabel b
    return (st, s!"L|{bit (dom a b)}|{bit (dom b a)}|{showLabel (join a b)}|{showLabel (meet a b)}")
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
    | .ok (c, t) => return (st, s!"D|ok|{c.levels.length}|{c.comps.length}|{t.length}|{hex (encode c t)}")
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
