import Texts
import Std.Data.HashMap

open Texts

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
  else if 'A' ≤ c ∧ c ≤ 'F' then .ok (c.toNat - 'A'.toNat + 10)
  else .error ("invalid hex digit " ++ c.toString)

def unhexAux : List Char → Except String (List Nat)
  | [] => .ok []
  | a :: b :: rest => do return (16 * (← hexVal a) + (← hexVal b)) :: (← unhexAux rest)
  | _ => .error "odd hex length"

def unhex (s : String) : Except String (List Nat) := if s == "-" then .ok [] else unhexAux s.toList

def parseHexNat (s : String) : Except String Nat :=
  if s.isEmpty then .error "empty hex" else s.toList.foldlM (fun acc c => do return 16 * acc + (← hexVal c)) 0

def hexDigit (n : Nat) : Char := if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)

def hexBytes (bs : List Nat) : String :=
  if bs.isEmpty then "-" else String.ofList (bs.flatMap fun b => [hexDigit (b / 16), hexDigit (b % 16)])

def hexNat (n : Nat) : String := String.ofList (Nat.toDigits 16 n)

def hex16 (n : Nat) : String :=
  let d := Nat.toDigits 16 n
  String.ofList (List.replicate (16 - d.length) '0' ++ d)

def joinOr (xs : List String) : String := if xs.isEmpty then "-" else String.intercalate "," xs

def bit (b : Bool) : String := if b then "1" else "0"

def trimChars (cs : List Char) : List Char :=
  let f := cs.dropWhile fun c => c = ' ' ∨ c = '\t' ∨ c = '\r'
  (f.reverse.dropWhile fun c => c = ' ' ∨ c = '\t' ∨ c = '\r').reverse

def trimStr (s : String) : String := String.ofList (trimChars s.toList)

def loadUnicodeData (text : String) : Except String (Std.HashMap Nat Nat) := do
  let mut m : Std.HashMap Nat Nat := {}
  for line in text.splitOn "\n" do
    if (trimStr line).isEmpty then continue
    let fields := line.splitOn ";"
    if fields.length < 15 then throw s!"unexpected UnicodeData line {line}"
    let lowField := fields.getD 13 ""
    if lowField.isEmpty then continue
    let cp ← parseHexNat (fields.getD 0 "")
    let lo ← parseHexNat lowField
    m := m.insert cp lo
  return m

def loadSpecialCasing (text : String) : Except String (Std.HashMap Nat (List Nat)) := do
  let mut m : Std.HashMap Nat (List Nat) := {}
  for line in text.splitOn "\n" do
    let body := trimStr ((line.splitOn "#").headD "")
    if body.isEmpty then continue
    let fields := (body.splitOn ";").map trimStr
    if fields.length < 4 then throw s!"unexpected SpecialCasing line {line}"
    if fields.length > 4 ∧ !(fields.getD 4 "").isEmpty then continue
    let cp ← parseHexNat (fields.getD 0 "")
    let seq ← ((fields.getD 1 "").splitOn " " |>.filter (· ≠ "")).mapM parseHexNat
    m := m.insert cp seq
  return m

structure Tables where
  simple : Std.HashMap Nat Nat
  special : Std.HashMap Nat (List Nat)

def Tables.low (t : Tables) (cp : Nat) : List Nat :=
  match t.special.get? cp with
  | some l => l
  | none => match t.simple.get? cp with
    | some l => [l]
    | none => [cp]

def stubStem (w : List Nat) : List Nat :=
  if 3 ≤ w.length ∧ w.drop (w.length - 3) = [105, 110, 103] then w.take (w.length - 3)
  else if w.getLast? = some 115 then w.take (w.length - 1)
  else w

structure St where
  stops : Array (Option StopWords) := Array.replicate 8 none
  reported : Array Bool := Array.replicate 8 false
  dict : Std.HashMap (List Nat) (List Nat) := {}

def tokText (t : Tok) : String := s!"{hexBytes t.text}:{t.start}:{t.stop}:{t.tailFrom}"

def termText (t : Term) : String := s!"{hexBytes t.bytes}:{t.position}:{t.start}:{t.stop}:{if t.stem then "s" else "o"}"

def wordList (s : String) : Except String (List (List Nat)) :=
  if s == "-" then .ok [] else (s.splitOn ",").mapM fun w => if w == "." then .ok [] else unhex w

def wordsText (ws : List (List Nat)) : String :=
  joinOr (ws.map fun w => if w.isEmpty then "." else hexBytes w)

def firstsText (n : Nat) : String :=
  String.intercalate "." ((List.range 4).map fun i => hex16 (n / 2 ^ (64 * i) % 2 ^ 64))

def ltRow (tab : Tables) (block : Nat) : String :=
  let entries := (List.range 256).filterMap fun k =>
    let cp := block * 256 + k
    let seq := tab.low cp
    if seq = [cp] then none else some s!"{hexNat cp}:{String.intercalate "." (seq.map hexNat)}"
  s!"LT|{block}|{joinOr entries}"

def stopAt (st : St) (reg : String) : Except String (Option StopWords) :=
  if reg == "-" then .ok none
  else do
    let r ← parseNat reg
    match st.stops.getD r none with
    | some sw => .ok (some sw)
    | none => .error s!"stop register {reg} is empty"

def step (tab : Tables) (st : St) : List String → Except String (St × String)
  | ["BC", b] => do
    let b ← parseNat b
    return (st, s!"BC|{b}|{classBits b}|{bit (isControl b)}")
  | ["TK", src] => do
    let src ← unhex src
    let toks := tokenize src
    return (st, s!"TK|{toks.length}|{joinOr (toks.map tokText)}")
  | ["FO", text, tail] => do
    let text ← unhex text
    let tail ← unhex tail
    return (st, s!"FO|{hexBytes (fold tab.low text tail)}")
  | ["LT", block] => do
    let block ← parseNat block
    return (st, ltRow tab block)
  | ["EU", cp] => do
    let cp ← parseNat cp
    let enc := encodeUnit cp
    let dec := decodeUnit enc [] 0
    return (st, s!"EU|{hexBytes enc}|{dec.1}|{dec.2}")
  | ["TF", term] => do
    let term ← unhex term
    let r := trieForm term
    let units := (trieUnits term (term.length + 1) 0 false).1
    return (st, s!"TF|{hexBytes r.1}|{bit r.2}|{units}")
  | ["SB", reg, mode] => do
    let r ← parseNat reg
    let (sw, reported) ← (if mode == "d" then .ok (buildStop defaultStop, false)
      else if mode == "n" then .ok (buildStop [], true) else .error s!"unknown stop mode {mode}" : Except String (StopWords × Bool))
    let st := { st with stops := st.stops.set! r (some sw), reported := st.reported.set! r reported }
    return (st, s!"SB|{r}|{wordsText sw.words}|{sw.size}|{String.intercalate "," (sw.slots.map toString)}|{hex16 sw.lengths}|{firstsText sw.firsts}|{bit reported}")
  | ["SB", reg, "c", words] => do
    let r ← parseNat reg
    let ws ← wordList words
    let sw := buildStop (ws.map fun w => fold tab.low w [])
    let st := { st with stops := st.stops.set! r (some sw), reported := st.reported.set! r true }
    return (st, s!"SB|{r}|{wordsText sw.words}|{sw.size}|{String.intercalate "," (sw.slots.map toString)}|{hex16 sw.lengths}|{firstsText sw.firsts}|1")
  | ["SQ", reg, term] => do
    let some sw ← stopAt st reg | .error "SQ needs a stop register"
    let term ← unhex term
    return (st, s!"SQ|{bit (isStop sw term)}|{bit (queryDrops sw term true false)}|{bit (queryDrops sw term true true)}|{bit (queryDrops sw term false false)}")
  | ["SM", word, stem] => do
    let w ← unhex word
    let s ← unhex stem
    return ({ st with dict := st.dict.insert w s }, s!"SM|{hexBytes w}|{hexBytes s}")
  | ["AN", reg, mode, minStem, base, text] => do
    let sw ← stopAt st reg
    let minStem ← parseNat minStem
    let base ← parseNat base
    let text ← unhex text
    let dict := st.dict
    let stem : Option (List Nat → List Nat) ←
      (if mode == "-" then .ok none
        else if mode == "e" then .ok (some fun f => (dict.get? f).getD [63, 63, 63])
        else if mode == "s" then .ok (some stubStem) else .error s!"unknown stem mode {mode}" : Except String _)
    let r := analyze tab.low sw stem minStem base text
    return (st, s!"AN|{r.2}|{joinOr (r.1.map termText)}")
  | other => .error s!"unknown case {String.intercalate " " other}"

def main (args : List String) : IO Unit := do
  let [path, unicodeData, specialCasing] := args | throw (IO.userError "expected case path, UnicodeData.txt and SpecialCasing.txt")
  let simple ← expect (loadUnicodeData (← IO.FS.readFile unicodeData))
  let special ← expect (loadSpecialCasing (← IO.FS.readFile specialCasing))
  let tab : Tables := ⟨simple, special⟩
  let input ← IO.FS.readFile path
  let out ← IO.getStdout
  let mut st : St := {}
  for line in input.splitOn "\n" do
    if line.isEmpty then continue
    let (next, row) ← expect (step tab st (line.splitOn " "))
    st := next
    out.putStrLn row
