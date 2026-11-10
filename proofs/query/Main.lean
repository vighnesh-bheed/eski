import Queries

open Queries

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

def text (bs : List Nat) : String := String.ofList (bs.map Char.ofNat)

def indent (n : Nat) : String := String.join (List.replicate n "  ")

mutual
def explainNode (depth : Nat) : Node → List String
  | .null => [indent depth ++ "<empty>"]
  | .tok s => [indent depth ++ text s]
  | .pre s => [indent depth ++ "PREFIX{" ++ text s ++ "*}"]
  | .suf s => [indent depth ++ "SUFFIX{*" ++ text s ++ "}"]
  | .inf s => [indent depth ++ "INFIX{*" ++ text s ++ "*}"]
  | .union cs => (indent depth ++ "UNION {") :: explainList (depth + 1) cs ++ [indent depth ++ "}"]
  | .inter cs => (indent depth ++ "INTERSECT {") :: explainList (depth + 1) cs ++ [indent depth ++ "}"]
  | .neg c => (indent depth ++ "NOT{") :: explainNode (depth + 1) c ++ [indent depth ++ "}"]
  | .opt c => (indent depth ++ "OPTIONAL{") :: explainNode (depth + 1) c ++ [indent depth ++ "}"]

def explainList (depth : Nat) : List Node → List String
  | [] => []
  | c :: cs => explainNode depth c ++ explainList depth cs
end

def outcomeText : Outcome → String
  | .tree n => "ok|" ++ String.join ((explainNode 0 n).map (· ++ "/"))
  | .failure e => s!"err|SEARCH_SYNTAX Syntax error at offset {e.pos} near {text e.near}"
  | .unsupported => "unsupported"

def kindName : Kind → String
  | .finish => "End"
  | .term => "Term"
  | .stop => "Stopword"
  | .pre => "Prefix"
  | .suf => "Suffix"
  | .inf => "Infix"
  | .orK => "Or"
  | .minus => "Minus"
  | .tilde => "Tilde"
  | .lp => "Lp"
  | .rp => "Rp"
  | .unsupported => "Unsupported"

def tokText (t : Tk) : String := s!"{kindName t.kind}:{t.pos}:{text t.text}:{text t.near}"

def step : List String → Except String String
  | ["QL", _, q] => do
    let q ← unhex q
    return "QL|" ++ String.intercalate "," ((lex q).map tokText)
  | ["QP", d, q] => do
    let d ← parseNat d
    let q ← unhex q
    return "QP|" ++ outcomeText (parseQuery d q)
  | ["QR", d, q] => do
    let d ← parseNat d
    let q ← unhex q
    return "QR|" ++ outcomeText (parseQuery d q)
  | other => .error s!"unknown case {String.intercalate " " other}"

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "expected case path")
  let input ← IO.FS.readFile path
  let out ← IO.getStdout
  for line in input.splitOn "\n" do
    if line.isEmpty then continue
    out.putStrLn (← expect (step (line.splitOn " ")))
