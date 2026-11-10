import Vectors.LabelSim
import Vectors.OwnerPartition

set_option autoImplicit false

namespace Vectors

def scopeSeed (l o : Nat) : Nat := streamSeed (l + 4096 * o)

def scopeOrderLess (tbl : List Lbl) (x y : Nat × Nat) : Bool :=
  let lx := labelOf tbl x.1
  let ly := labelOf tbl y.1
  if rankGt lx ly then true
  else if rankGt ly lx then false
  else if x.2 != y.2 then x.2 != SHARED
  else labelOrderLess tbl x.1 y.1

def scopeOrderLe (tbl : List Lbl) (x y : Nat × Nat) : Bool := scopeOrderLess tbl x y || decide (x = y)

structure YSession where
  tbl : List Lbl
  flat : Nat
  shrink : Nat
  owners : Nat
  st : LState (Nat × Nat) (List Nat) SPart

def YSession.scopesU (y : YSession) : List (Nat × Nat) :=
  (List.range (y.owners + 1)).flatMap (fun o => (List.range y.tbl.length).map (fun l => (l, o)))

def YSession.namesU (y : YSession) : List (List Nat) :=
  let all := y.scopesU.flatMap (fun x => ((y.st.parts x).map simNames).getD [])
  (all.foldl (fun acc n => if acc.contains n then acc else acc ++ [n]) []).mergeSort nameLe

def YSession.reader (y : YSession) (w : Nat × Nat) : ReaderOf (Nat × Nat) := readerP (simSees y.tbl) (simGt y.tbl) w

def YSession.view (y : YSession) (w : Nat × Nat) : ViewObj (Nat × Nat) (List Nat) :=
  viewOpen simAcc (scopeOrderLe y.tbl) y.scopesU y.namesU (y.reader w) y.st

def YSession.part (y : YSession) (x : Nat × Nat) : SPart := (y.st.parts x).getD default

def YSession.elem (y : YSession) (x : Nat × Nat) (n : List Nat) : SElem :=
  ((y.part x).order.find? (fun e => e.name == n)).getD default

def YSession.write (y : YSession) (c : Cmd (Nat × Nat) (List Nat) SVal) : YSession :=
  { y with st := wstep (simOps y.flat y.shrink) (seesP (simSees y.tbl)) c y.st }

def YSession.forget (y : YSession) (o : Nat) : YSession :=
  if o = SHARED then y else { y with st := forgetOwner o y.st }

def YSession.allEmpty (y : YSession) : Bool := y.scopesU.all (fun x => (y.st.parts x).isNone)

def YSession.ownerLabels (y : YSession) (o : Nat) : List Nat :=
  if o = SHARED then [] else (List.range y.tbl.length).filter (fun l => (y.st.parts (l, o)).isSome)

def YSession.ownerCard (y : YSession) (o : Nat) : Nat :=
  ((y.ownerLabels o).map (fun l => (y.part (l, o)).order.length)).foldl (· + ·) 0

def YSession.ownerCount (y : YSession) : Nat :=
  ((List.range y.owners).map (· + 1)).countP (fun o => !(y.ownerLabels o).isEmpty)

def YSession.top (y : YSession) (w : Nat × Nat) : Option (Nat × Nat) :=
  if (y.st.parts w).isSome then some w
  else if (w.2 != SHARED) && (y.st.parts (w.1, SHARED)).isSome then some (w.1, SHARED)
  else (y.view w).labels.head?

def showScope (x : Nat × Nat) : String := s!"{x.1}:{x.2}"

def modeFlag (before after : Option SPart) : String :=
  match before.map SPart.mode, after.map SPart.mode with
  | some PMode.flat, some PMode.graph => "g"
  | some PMode.graph, some PMode.flat => "f"
  | _, _ => "-"

def accountFlags (w : Nat × Nat) (fresh gone : Bool) (gm : String) : String :=
  let sh := if w.2 = SHARED then "-" else "1"
  let ix := if (w.2 != SHARED) && (fresh || gone) then "-" else "1"
  s!"{gm}|{sh}|1|{ix}|1"

end Vectors
