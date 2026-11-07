import Effects

open Effects

def parseNat (s : String) : Except String Nat :=
  match s.toNat? with
  | none => .error ("invalid natural: " ++ s)
  | some n => .ok n

def condition : String → Except String Condition
  | "ANY" => pure .any
  | "NX" => pure .nx
  | "XX" => pure .xx
  | "GT" => pure .gt
  | "LT" => pure .lt
  | _ => throw "invalid condition"

def parseOperation : List String → Except String Operation
  | ["W", f, v] => return .write (← parseNat f) v
  | ["F", f, v, d] => do
    let deadline ← parseNat d
    return .finalFloat (← parseNat f) v (if deadline = 0 then none else some deadline)
  | ["X", f, d, c] => return .expire (← parseNat f) (← parseNat d) (← condition c)
  | ["P", f] => return .persist (← parseNat f)
  | ["D", f] => return .remove (← parseNat f)
  | ["G", f] => return .read (← parseNat f)
  | _ => throw "invalid operation"

@[noinline] def freeze (s : Hash) : Array (Option Field) :=
  (List.range 8).map s |>.toArray

def showHash (s : Hash) : String :=
  String.join ((List.range 8).filterMap fun f =>
    (s f).map fun entry => s!"{f}={entry.value}@{entry.deadline.getD 0},")

def showReplay : Replay → String
  | .hset f v => s!"W,{f},{v}"
  | .hpexpireat f deadline => s!"X,{f},{deadline}"
  | .hpersist f => s!"P,{f}"
  | .hdel f => s!"D,{f}"

def originalRecords : Records := fun id =>
  if id = 0 then ⟨0, true, 71, false, false, true, 9000, 1, 0, true, 123⟩
  else ⟨1, true, 72, true, true, false, 10000, 2, 0, false, 456⟩

def modifiedRecord (r : Record) (v : Nat) : Record :=
  {r with value := v, present := true, changed := true, valueChanged := true, stringCopy := false, expires := 0, encoding := 2, hashMinimum := 0}

def rollbackWork : Records :=
  let s := putRecord originalRecords 0 (modifiedRecord (originalRecords 0) 2)
  let s := putRecord s 1 (modifiedRecord (s 1) 3)
  putRecord s 0 (modifiedRecord (s 0) 4)

def showRecord (r : Record) : String :=
  let v := match r.value with
    | 0 => "old0"
    | 1 => "old1"
    | 2 => "a"
    | 3 => "b"
    | _ => "c"
  s!"{v}:{r.present}:{r.clock}:{r.changed}:{r.valueChanged}:{r.stringCopy}:{r.expires}:{r.encoding}:{r.kind}:{r.touched}:{r.hashMinimum}"

def rollbackFixtures : IO Unit := do
  for mode in List.range 3 do
    let visible : Visible := {dirty := 3, events := [0, 1, 2, 3, 4, 5], poststates := [0, 1]}
    let outcome := if mode = 1 then Outcome.internalFailure else .success
    let complete := if mode = 0 then finish originalRecords originalRecords [] {} .success
      else finish originalRecords rollbackWork [0, 1, 0] visible outcome
    IO.println s!"K{mode}|{mode != 2}|{complete.rolledBack}|{showRecord (complete.records 0)};{showRecord (complete.records 1)}|{complete.visible.dirty}|{complete.visible.events.length}|{complete.visible.poststates.length}"
  let original : Records := fun _ => {(default : Record) with value := 9, clock := 19, hashMinimum := 777, expires := 8888}
  let work : Records := fun _ => {(default : Record) with value := 10}
  let complete := finish original work [0, 0] {dirty := 1, events := [0]} .internalFailure
  if complete.records 0 != original 0 ∨ complete.visible != {} then throw (IO.userError "object snapshot model failure")
  IO.println "OBJECT|restored|aliases|metadata|balanced"

def keyFixtureOperation (mode : Nat) : KeyOperation :=
  match mode with
  | 0 => .setRelative "final" 250
  | 1 => .setRelative "final" 1
  | 2 | 3 => .setKeepTTL "final"
  | 4 => .expireAbsolute 1250
  | 5 => .expireAbsolute 1000
  | 6 => .persist
  | 7 => .delete
  | 8 => .setAbsolute "final" 1000
  | _ => .setAbsolute "final" 1001

def keyFixtureBefore (mode : Nat) : KeyState :=
  some ⟨"final", if mode = 3 then none else some 5000⟩

def showKeyReplay : KeyReplay → String
  | .setPXAT v d => s!"KS,{v},{d}"
  | .setKeepTTL v => s!"KK,{v}"
  | .pexpireat d => s!"KX,{d}"
  | .persist => "KP"
  | .del => "KD"

def keyFixtures : IO Unit := do
  for mode in List.range 10 do
    let op := keyFixtureOperation mode
    IO.println s!"KEY{mode}|{showKeyReplay (translateKey 1000 (keyFixtureBefore mode) op)}"

def commandErrorFixture : IO Unit := do
  let completion := finish originalRecords originalRecords [] {} .commandError
  if completion.rolledBack ∨ completion.records 0 != originalRecords 0 ∨ completion.visible.dirty != 0 then
    throw (IO.userError "command error model failure")
  IO.println "COMMAND_ERROR|ERR|value-preserved|deadline-preserved|dirty:0"

def exactNowFixtures : IO Unit := do
  let existing : Hash := fun _ => some ⟨"value", some 100⟩
  let kept := logicalLive 100 existing 0
  let persisted := applyOperation 100 existing (.persist 0) 0
  let removed := activeSweep 100 existing 0
  if kept.isNone ∨ persisted != some ⟨"value", none⟩ ∨ removed.isSome then
    throw (IO.userError "exact-now model boundary failure")
  for table in List.range 2 do
    IO.println s!"BOUNDARY{table}|live|persist|stale-min|active-removed|ttl:{pttlReply 100 existing 0}"

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "expected trace path")
  rollbackFixtures
  keyFixtures
  commandErrorFixture
  exactNowFixtures
  let input ← IO.FS.readFile path
  let mut s : Hash := fun _ => none
  let mut now := 1000
  for line in input.splitOn "\n" do
    if line.isEmpty then continue
    match line.splitOn " " with
    | ["R", _, time] =>
      s := fun _ => none
      now ← match parseNat time with
        | .ok n => pure n
        | .error e => throw (IO.userError e)
    | ["T", time] =>
      now ← match parseNat time with
        | .ok n => pure n
        | .error e => throw (IO.userError e)
    | "B" :: time :: cond :: fields =>
      let deadline ← match parseNat time with
        | .ok n => pure n
        | .error e => throw (IO.userError e)
      let c ← match condition cond with
        | .ok n => pure n
        | .error e => throw (IO.userError e)
      let mut emitted := []
      for field in fields do
        let f ← match parseNat field with
          | .ok n => pure n
          | .error e => throw (IO.userError e)
        let op := Operation.expire f deadline c
        emitted := emitted ++ translate now s op
        let snapshot := freeze (applyOperation now s op)
        s := fun f => (snapshot[f]?).join
      IO.println s!"{showHash s}|{String.intercalate ";" (emitted.map showReplay)}|{showHash (logicalLive now s)}"
    | fields =>
      let op ← match parseOperation fields with
        | .error e => throw (IO.userError e)
        | .ok op => pure op
      let emitted := translate now s op
      let snapshot := freeze (applyOperation now s op)
      s := fun f => (snapshot[f]?).join
      IO.println s!"{showHash s}|{String.intercalate ";" (emitted.map showReplay)}|{showHash (logicalLive now s)}"
