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

def keyLength : Nat := 7

def showCell : Cell → String
  | .empty => "-"
  | .deleted => "x"
  | .live e =>
    s!"{e.key}:{e.value}:{e.clock}:" ++ (if e.cell.timed then s!"t{e.cell.deadline}" else "u")

def showTable (t : Table) : String :=
  s!"{t.slots.length},{t.live},{t.tombs},{t.growth};" ++ String.intercalate "," (t.slots.map showCell)

def startAt (k : Keyspace) (cap : Nat) : Except String (Keyspace × String) := do
  if 0 ≤ k.banks.cursor then throw "nested resize"
  return (ksStart k cap, "0")

def tableStep (k : Keyspace) : List String → Except String (Keyspace × String)
  | ["I", key, hash, value, deadline, clock] => do
    let some (next, created) := ksUpsert k (← nat key) (← nat hash) (← nat value) (← nat deadline) (← nat clock)
      keyLength | throw "destination full"
    return (next, if created then "1" else "0")
  | ["D", key, hash] => do
    let (next, removed) := ksRemove k (← nat key) (← nat hash)
    return (next, if removed then "1" else "0")
  | ["Q", key, hash] => do
    let key ← nat key
    let hash ← nat hash
    match locate k.banks key hash with
    | none => return (k, "n")
    | some (d, i) => return (k, showCell (((bankOf k.banks d).slots[i]?).getD .empty))
  | ["G", cap] => do startAt k (← nat cap)
  | ["U"] =>
    let cap := k.banks.src.slots.length
    startAt k (if k.banks.src.live > (cap * 7 / 16 : Nat) then growCap cap else cap)
  | ["V"] => startAt k (roundCap (k.banks.src.live.toNat * 2))
  | ["M", groups, want] => do return (ksMigrate k (← nat groups) (← nat want), "0")
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
  let mut k : Keyspace := ksReset 16
  let mut l : Ledger := ⟨0, []⟩
  let mut limit : Int := 0
  let mut initialized := false
  for line in input.splitOn "\n" do
    if line.isEmpty then continue
    match line.splitOn " " with
    | ["R", cap] =>
      k := ksReset (← expect (nat cap))
    | ["A", budget, init] =>
      limit ← expect (int budget)
      initialized := init == "1"
      l := ⟨0, []⟩
    | ["S", cursor] =>
      let (keys, next) := scanRound k.banks (← expect (nat cursor))
      IO.println s!"S|{String.intercalate "," (keys.map toString)}|{next}"
    | fields =>
      if fields.head! ∈ ["E", "P", "L", "F", "N", "W", "Z"] then
        let (next, ok) ← expect (memoryStep l limit initialized fields)
        l := next
        IO.println s!"K|{if ok then 1 else 0}|{l.used}"
      else
        let (next, reply) ← expect (tableStep k fields)
        k := next
        IO.println s!"T|{reply}|{k.banks.cursor}|{k.expires},{k.cells},{k.tables}|{showTable k.banks.src}|{showTable k.banks.dst}"
