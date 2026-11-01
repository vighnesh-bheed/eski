import Storage

open Storage

def nat (s : String) : Except String Nat :=
  match s.toNat? with
  | some n => .ok n
  | none => .error ("invalid natural " ++ s)
def int (s : String) : Except String Int :=
  match s.toInt? with
  | some n => .ok n
  | none => .error ("invalid integer " ++ s)

def expect {α : Type} : Except String α → IO α
  | .ok a => pure a
  | .error e => throw (IO.userError e)

def showCell : Cell → String
  | .empty => "-"
  | .deleted => "x"
  | .live e => s!"{e.key}:{e.value}:{e.expiry}:{e.clock}"

def showTable (t : Table) : String :=
  s!"{t.slots.length},{t.live},{t.tombs},{t.growth};" ++ String.intercalate "," (t.slots.map showCell)

def locate (b : Banks) (key hash : Nat) : Option (Bool × Nat) :=
  match findIndex b.src key hash with
  | some i => some (false, i)
  | none => if b.cursor ≥ 0 then (findIndex b.dst key hash).map (true, ·) else none

def insertEntry (b : Banks) (e : Entry) : Except String (Banks × String) := do
  if let some (dst, i) := locate b e.key e.hash then
    if dst then return ({b with dst := {b.dst with slots := put b.dst.slots i (.live e)}}, "0")
    return ({b with src := {b.src with slots := put b.src.slots i (.live e)}}, "0")
  let target := if b.cursor ≥ 0 then b.dst else b.src
  let some i := claimIndex target.slots e.hash | throw "destination full"
  if b.cursor ≥ 0 then return ({b with dst := place target i e}, "1")
  return ({b with src := place target i e}, "1")

def tableStep (b : Banks) : List String → Except String (Banks × String)
  | ["I", key, hash, value, expiry, clock] => do
    insertEntry b ⟨← nat key, ← nat hash, ← nat value, ← nat expiry, ← nat clock⟩
  | ["D", key, hash] => do
    let key ← nat key
    let hash ← nat hash
    match locate b key hash with
    | none => return (b, "0")
    | some (dst, i) =>
      if dst then return ({b with dst := erase b.dst i}, "1")
      return ({b with src := erase b.src i}, "1")
  | ["Q", key, hash] => do
    let key ← nat key
    let hash ← nat hash
    match locate b key hash with
    | none => return (b, "n")
    | some (dst, i) =>
      return (b, showCell (((if dst then b.dst else b.src).slots[i]?).getD .empty))
  | ["G", cap] => do
    let cap ← nat cap
    if b.cursor ≥ 0 then throw "nested resize"
    return (⟨b.src, emptyTable cap, 0⟩, "0")
  | ["M", groups, want] => do
    let groups ← nat groups
    let want ← nat want
    return (if b.cursor ≥ 0 then rehash b groups want else b, "0")
  | _ => throw "invalid table operation"

def memoryStep (l : Ledger) (limit : Int) (initialized : Bool) : List String → Except String (Ledger × Bool)
  | ["E", id, bytes] => do return reserve l limit initialized (← nat id) (← int bytes)
  | ["P", id, bytes] => do return acquire l limit initialized (← nat id) (← int bytes) true
  | ["L", id] | ["F", id] => do return release l (← nat id)
  | ["N"] | ["W", _] | ["Z", _] => return (l, false)
  | _ => throw "invalid accounting operation"

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "expected trace path")
  let input ← IO.FS.readFile path
  let mut b : Banks := ⟨emptyTable 16, emptyTable 0, -1⟩
  let mut l : Ledger := ⟨0, []⟩
  let mut limit : Int := 0
  let mut initialized := false
  for line in input.splitOn "\n" do
    if line.isEmpty then continue
    match line.splitOn " " with
    | ["R", cap] =>
      let n ← expect (nat cap)
      b := ⟨emptyTable n, emptyTable 0, -1⟩
    | ["A", budget, init] =>
      limit ← expect (int budget)
      initialized := init == "1"
      l := ⟨0, []⟩
    | fields =>
      if fields.head! ∈ ["E", "P", "L", "F", "N", "W", "Z"] then
        let (next, ok) ← expect (memoryStep l limit initialized fields)
        l := next
        IO.println s!"K|{if ok then 1 else 0}|{l.used}"
      else
        let (next, reply) ← expect (tableStep b fields)
        b := next
        IO.println s!"T|{reply}|{b.cursor}|{showTable b.src}|{showTable b.dst}"
