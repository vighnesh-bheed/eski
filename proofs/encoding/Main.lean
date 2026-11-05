import Encoding

open Encoding

def natField (s : String) : Except String Nat := match s.toNat? with | some n => .ok n | none => .error ("invalid natural: " ++ s)
def intField (s : String) : Except String Int := match s.toInt? with | some n => .ok n | none => .error ("invalid integer: " ++ s)

def bytesField (s : String) : Except String (List Nat) := do
  if s = "-" ∨ s = "~" then return []
  (s.splitOn ",").mapM fun part => do
    let byte ← natField part
    if byte > 255 then throw "invalid byte"
    return byte

def showBytes (bytes : List Nat) : String :=
  if bytes.isEmpty then "-" else String.intercalate "," (bytes.map toString)

def showArgs (args : List (List Nat)) : String :=
  if args.isEmpty then "-"
  else String.intercalate "/" (args.map fun arg => if arg.isEmpty then "~" else showBytes arg)

def showResult (r : ParseResult) : String :=
  s!"{r.kind},{r.fault},{r.consumed},{r.need},{r.payload},{r.errorByte}:{showArgs r.args}"

def showBody (data : List Nat) (offset : Nat) : String :=
  match decodeBody data offset with
  | none => "0|0|0|-"
  | some body => s!"1|{body.bytes}|{body.value}|{match body.payload with | none => "n" | some bytes => if bytes.isEmpty then "~" else showBytes bytes}"

def showExtent (body : List Nat) : String :=
  let encoded := body ++ backEncode body.length
  match decodeExtent encoded 0 encoded.length with
  | none => "0"
  | some finish => toString finish

def walkPack (data : List Nat) (limit : Nat) : Nat → Nat → List Nat → Option (List Nat)
  | 0, cursor, offsets => if cursor = limit then some offsets else none
  | fuel + 1, cursor, offsets =>
    if cursor = limit then some offsets
    else if cursor > limit then none
    else do
      let finish ← decodeExtent data cursor limit
      walkPack data limit fuel finish (offsets ++ [cursor])

def showPack (data : List Nat) : String := Id.run do
  if data.length < 7 then return "L|0|0|0|-|-"
  let total := number 256 (data.take 4)
  let count := number 256 ((data.drop 4).take 2)
  if total ≠ data.length ∨ data[total - 1]?.getD 0 ≠ 255 then return "L|0|0|0|-|-"
  match walkPack data (data.length - 1) data.length 6 [] with
  | none => return "L|1|0|0|-|-"
  | some offsets =>
    if count ≠ 65535 ∧ count ≠ offsets.length then return "L|1|0|0|-|-"
    return s!"L|1|1|{offsets.length}|{showBytes offsets}|{showBytes offsets.reverse}"

def evalLine (line : String) : Except String String := do
  match line.splitOn " " with
  | ["G", b, p, l] =>
    let base ← intField b
    let payload ← intField p
    let length ← intField l
    match bulkRequiredEnd base payload length with
    | none => return "G|0|0"
    | some finish => return s!"G|1|{finish}"
  | ["I", s] =>
    let value ← intField s
    let body := encodeInteger value
    return s!"I|{body.length}|{showBytes body}|{showBody body 0}|{showExtent body}"
  | ["S", s] =>
    let value ← bytesField s
    let body := encodeString value
    return s!"S|{body.length}|{showBytes body}|{showBody body 0}|{showExtent body}"
  | ["B", s] =>
    let length ← natField s
    if length ≥ 2 ^ 32 then return "B|0|-|0|0|0"
    let bytes := backEncode length
    match readBack bytes (bytes.length - 1) 0 with
    | none => return s!"B|{bytes.length}|{showBytes bytes}|0|0|0"
    | some (value, width) => return s!"B|{bytes.length}|{showBytes bytes}|{value}|{width}|1"
  | ["R", s, last, lower] =>
    let bytes ← bytesField s
    let last ← natField last
    let lower ← natField lower
    match readBack bytes last lower with
    | none => return "R|0|0|0"
    | some (value, width) => return s!"R|1|{value}|{width}"
  | ["D", s, offset] =>
    let bytes ← bytesField s
    let offset ← natField offset
    return "D|" ++ showBody bytes offset
  | ["L", s] => return showPack (← bytesField s)
  | ["P", base, bulk, unauth, arrayMax, unauthBulk, data, sizes] =>
    let limits : ParseLimits := {
      base := ← intField base
      bulkMax := ← intField bulk
      unauthenticated := unauth == "1"
      arrayMax := ← intField arrayMax
      unauthBulkMax := ← intField unauthBulk
    }
    let bytes ← bytesField data
    let sizes ← (sizes.splitOn ",").mapM natField
    let (_, _, results) ← sizes.foldlM (fun (state, cursor, results) size => do
      if cursor + size > bytes.length then throw "invalid fragment size"
      let state := feed limits state ((bytes.drop cursor).take size)
      pure (state, cursor + size, results ++ [showResult state.result])) (({} : Incremental), 0, [])
    if sizes.foldl (· + ·) 0 ≠ bytes.length then throw "incomplete fragments"
    return "P|" ++ String.intercalate ";" results
  | _ => throw ("invalid trace: " ++ line)

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "expected trace path")
  let input ← IO.FS.readFile path
  for line in input.splitOn "\n" do
    if line.isEmpty then continue
    match evalLine line with
    | .ok output => IO.println output
    | .error message => throw (IO.userError message)
