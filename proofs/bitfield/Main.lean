import Bitfield

open Bitfield

def parseNat (s : String) : Except String Nat :=
  match s.toNat? with
  | none => .error ("invalid natural: " ++ s)
  | some n => .ok n

def parseInt (s : String) : Except String Int :=
  match s.toInt? with
  | none => .error ("invalid integer: " ++ s)
  | some n => .ok n

def parseOps : List String → Except String (List Op)
  | [] => pure []
  | code :: signed :: bits :: offset :: arg :: mode :: rest => do
    let opcode ← match code with
      | "G" => pure Opcode.get
      | "S" => pure Opcode.set
      | "I" => pure Opcode.incr
      | _ => throw "invalid opcode"
    let sign ← match signed with
      | "0" => pure false
      | "1" => pure true
      | _ => throw "invalid signedness"
    let overflow ← match mode with
      | "W" => pure Overflow.wrap
      | "S" => pure Overflow.sat
      | "F" => pure Overflow.fail
      | _ => throw "invalid mode"
    let width ← parseNat bits
    let index ← parseNat offset
    let value ← parseInt arg
    if width = 0 ∨ width > (if sign then 64 else 63) then throw "invalid width"
    if index > 4096 then throw "bridge offset limit"
    if value < -(2 : Int) ^ 63 ∨ value ≥ (2 : Int) ^ 63 then throw "invalid i64"
    return {opcode, signed := sign, bits := width, offset := index, arg := value, overflow} :: (← parseOps rest)
  | _ => throw "incomplete operation"

def parseBytes (s : String) : Except String Buffer := do
  if s = "-" then return #[]
  let xs ← s.splitOn "," |>.mapM fun s => do
    let n ← parseNat s
    if n > 255 then throw "invalid byte"
    return BitVec.ofNat 8 n
  return xs.toArray

def showBytes (buf : Buffer) : String :=
  if buf.isEmpty then "-" else String.intercalate "," (buf.toList.map (fun b => toString b.toNat))

def showReply : Option Int → String
  | none => "n"
  | some n => toString n

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "expected trace path")
  let input ← IO.FS.readFile path
  let mut buf : Buffer := #[]
  for line in input.splitOn "\n" do
    if line.isEmpty then continue
    match line.splitOn " " with
    | ["R", data] =>
      match parseBytes data with
      | .error e => throw (IO.userError e)
      | .ok next => buf := next
    | "P" :: fields =>
      let ops ← match parseOps fields with
        | .error e => throw (IO.userError e)
        | .ok ops => pure ops
      let result := execute buf ops
      buf := result.buf
      IO.println s!"{result.changes}|{showBytes buf}|{String.intercalate "," (result.replies.map showReply)}"
    | _ => throw (IO.userError "invalid trace line")
