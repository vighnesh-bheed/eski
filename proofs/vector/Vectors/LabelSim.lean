import Vectors.Plain

namespace Vectors

def goldenGamma : Nat := 0x9E3779B97F4A7C15

def wrap64 (v : Nat) : Nat := v % 2 ^ 64

def mix64 (v : Nat) : Nat :=
  let z := wrap64 v
  let z := wrap64 ((z ^^^ (z >>> 30)) * 0xBF58476D1CE4E5B9)
  let z := wrap64 ((z ^^^ (z >>> 27)) * 0x94D049BB133111EB)
  z ^^^ (z >>> 31)

def streamSeed (id : Nat) : Nat := mix64 (wrap64 (0xBB67AE8584CAA73B + id * goldenGamma)) ||| 1

def streamAdvance (st : Nat) : Nat := wrap64 (st + goldenGamma)

def streamBelowFuel : Nat → Nat → Nat → Nat × Nat
  | 0, st, _ => (0, st)
  | fuel + 1, st, n =>
    let st' := streamAdvance st
    let v := mix64 st'
    if (2 ^ 64 - n) % n ≤ v then (v % n, st') else streamBelowFuel fuel st' n

def streamBelow (st n : Nat) : Nat × Nat := if n ≤ 1 then (0, st) else streamBelowFuel 4096 st n

structure SElem where
  name : List Nat
  mask : Nat
  attr : Option (Option Nat)
  seq : Nat
deriving Repr, Inhabited, DecidableEq

structure SPart where
  mode : PMode
  uid : Nat
  rng : Nat
  order : List SElem
deriving Repr, Inhabited

structure SVal where
  mask : Nat
  attr : Option (Option Nat)
deriving Repr, Inhabited

def swapRemove (l : List SElem) (n : List Nat) : List SElem :=
  match l.findIdx? (fun e => e.name == n) with
  | none => l
  | some i =>
    let last := l.length - 1
    if i = last then l.take last else (l.set i (l.getD last default)).take last

def simOps (flat shrink : Nat) : PartOps (List Nat) SVal SPart where
  create := fun seed => { mode := .flat, uid := 0, rng := seed, order := [] }
  insert := fun p n v =>
    let uid := p.uid + 1
    { p with uid := uid, order := p.order ++ [⟨n, v.mask, v.attr, uid⟩],
             mode := modeAfterInsert flat p.mode (p.order.length + 1) }
  update := fun p n v =>
    let uid := p.uid + 1
    { p with uid := uid, order := p.order.map (fun e => if e.name = n then
        { e with mask := v.mask, seq := uid, attr := match v.attr with
          | none => e.attr
          | some none => none
          | some (some a) => some (some a) } else e) }
  setAttr := fun p n v =>
    { p with order := p.order.map (fun e => if e.name = n then
        { e with attr := match v.attr with
          | some (some a) => some (some a)
          | _ => none } else e) }
  remove := fun p n =>
    let o := swapRemove p.order n
    { p with order := o, mode := modeAfterRemove shrink p.mode o.length }
  empty := fun p => p.order.isEmpty
  advance := streamAdvance
  output := fun st => mix64 st ||| 1

def simNames (p : SPart) : List (List Nat) := p.order.map (·.name)

def simAcc : PartAcc (List Nat) SPart where
  count := fun p => p.order.length
  attrs := fun p => (p.order.filter (fun e => e.attr.isSome)).length
  hasAttr := fun p n => (p.order.find? (fun e => e.name == n)).any (fun e => e.attr.isSome)

def labelOf (tbl : List Lbl) (id : Nat) : Lbl := tbl.getD id default

def simSees (tbl : List Lbl) (r d : Nat) : Bool := dominates (labelOf tbl r) (labelOf tbl d)

def simGt (tbl : List Lbl) (x y : Nat) : Bool := rankGt (labelOf tbl x) (labelOf tbl y)

def labelOrderLess (tbl : List Lbl) (x y : Nat) : Bool :=
  let lx := labelOf tbl x
  let ly := labelOf tbl y
  if rankGt lx ly then true
  else if rankGt ly lx then false
  else if lx.comps != ly.comps then decide (lx.comps > ly.comps)
  else decide (x < y)

def labelOrderLe (tbl : List Lbl) (x y : Nat) : Bool := labelOrderLess tbl x y || decide (x = y)

def nameLe (a b : List Nat) : Bool := nameLt a b || decide (a = b)

structure ZSession where
  tbl : List Lbl
  flat : Nat
  shrink : Nat
  st : LState Nat (List Nat) SPart

def ZSession.labelsU (z : ZSession) : List Nat := List.range z.tbl.length

def ZSession.namesU (z : ZSession) : List (List Nat) :=
  let all := z.labelsU.flatMap (fun l => ((z.st.parts l).map simNames).getD [])
  (all.foldl (fun acc n => if acc.contains n then acc else acc ++ [n]) []).mergeSort nameLe

def ZSession.reader (z : ZSession) (rd : Nat) : ReaderOf Nat := ⟨rd, simSees z.tbl rd, simGt z.tbl⟩

def ZSession.view (z : ZSession) (rd : Nat) : ViewObj Nat (List Nat) :=
  viewOpen simAcc (labelOrderLe z.tbl) z.labelsU z.namesU (z.reader rd) z.st

def ZSession.part (z : ZSession) (l : Nat) : SPart := (z.st.parts l).getD default

def ZSession.elem (z : ZSession) (l : Nat) (n : List Nat) : SElem :=
  ((z.part l).order.find? (fun e => e.name == n)).getD default

def ZSession.write (z : ZSession) (c : Cmd Nat (List Nat) SVal) : ZSession :=
  { z with st := wstep (simOps z.flat z.shrink) (simSees z.tbl) c z.st }

def ZSession.allEmpty (z : ZSession) : Bool := z.labelsU.all (fun l => (z.st.parts l).isNone)

def scoreOf (a b : Nat) : Int := 64 - (popcount (a ^^^ b) : Int)

def shadowNames (vo : ViewObj Nat (List Nat)) (l : Nat) : List (List Nat) :=
  (vo.shadows.filter (fun e => e.1 == l)).map (·.2)

def visibleOrder (z : ZSession) (vo : ViewObj Nat (List Nat)) (l : Nat) : List SElem :=
  (z.part l).order.filter (fun e => !(shadowNames vo l).contains e.name)

def shadowPositions (z : ZSession) (vo : ViewObj Nat (List Nat)) (l : Nat) : List Nat :=
  ((List.range (z.part l).order.length).filter (fun i =>
    (shadowNames vo l).contains ((z.part l).order.getD i default).name)).mergeSort (fun a b => decide (a ≤ b))

def viewBases (z : ZSession) (vo : ViewObj Nat (List Nat)) : List (Nat × Nat × Nat) :=
  let rec go : List Nat → Nat → List (Nat × Nat × Nat)
    | [], _ => []
    | l :: ls, b =>
      let size := (z.part l).order.length - (shadowNames vo l).length
      (l, b, size) :: go ls (b + size)
  go vo.labels 0

def viewRefAt (z : ZSession) (vo : ViewObj Nat (List Nat)) (j : Nat) : SElem :=
  let bases := viewBases z vo
  let cand := bases.filter (fun e => decide (e.2.1 ≤ j))
  match cand.getLast? with
  | none => default
  | some (l, b, _) =>
    let x := skipShadows (shadowPositions z vo l) (j - b)
    (z.part l).order.getD x default

def acceptFilter (filter : Option Nat) (e : SElem) : Bool :=
  match filter with
  | none => true
  | some t => match e.attr with
    | some (some a) => decide (t ≤ a)
    | _ => false

def ownResult (z : ZSession) (vo : ViewObj Nat (List Nat)) (q : Nat) (count : Nat) (filter : Option Nat)
    (l : Nat) : List (Option Int × List Nat) :=
  let p := z.part l
  let hits := (visibleOrder z vo l).filter (acceptFilter filter) |>.map (fun e => (some (scoreOf q e.mask), e.name))
  topk hitLe (min count p.order.length) hits

def viewSearch (z : ZSession) (vo : ViewObj Nat (List Nat)) (q : Nat) (count : Nat) (filter : Option Nat)
    (eps : Option Nat) : List (Option Int × List Nat) :=
  let merged := mergeTop hitLe count (vo.labels.map (ownResult z vo q count filter))
  match eps with
  | none => merged
  | some k => merged.filter (fun h => decide ((64 - (k : Int)) ≤ (h.1.getD 0)))

def showName (n : List Nat) : String := if n.isEmpty then "~" else String.ofList (n.map Char.ofNat)

def showHits (hs : List (Option Int × List Nat)) : String :=
  joinOrDash (hs.map (fun h => s!"{showName h.2}:{(h.1.getD 0)}"))
where joinOrDash (xs : List String) : String := if xs.isEmpty then "-" else String.intercalate "," xs

def showAttr (a : Option (Option Nat)) : String :=
  match a with
  | none => "-"
  | some none => "e"
  | some (some v) => s!"a{v}"

def showMode (m : PMode) : String :=
  match m with
  | .pinned => "pinned"
  | .flat => "flat"
  | .graph => "graph"

def boolBit (b : Bool) : String := if b then "1" else "0"

def randomDistinct (z : ZSession) (vo : ViewObj Nat (List Nat)) (count : Nat) (st : Nat) :
    List SElem × Nat :=
  let n := vo.size
  if n = 0 ∨ count = 0 then ([], st) else
  let shuffle : List SElem → Nat → List SElem × Nat := fun refs st =>
    let arr := refs.toArray
    let rec go : Nat → Array SElem → Nat → Array SElem × Nat
      | 0, a, s => (a, s)
      | i + 1, a, s =>
        let (j, s') := streamBelow s (i + 2)
        let a' := a.swapIfInBounds (i + 1) j
        go i a' s'
    let (a, s) := go (refs.length - 1) arr st
    (a.toList, s)
  if n ≤ count then
    shuffle ((List.range n).map (viewRefAt z vo)) st
  else if count * 4 ≤ n then
    let rec floyd : Nat → Nat → List Nat → List SElem → Nat → List SElem × Nat
      | 0, _, _, acc, s => (acc, s)
      | fuel + 1, j, picks, acc, s =>
        if j < n then
          let (t, s') := streamBelow s (j + 1)
          if picks.contains t then floyd fuel (j + 1) (j :: picks) (acc ++ [viewRefAt z vo j]) s'
          else floyd fuel (j + 1) (t :: picks) (acc ++ [viewRefAt z vo t]) s'
        else (acc, s)
    let (refs, s) := floyd count (n - count) [] [] st
    shuffle refs s
  else
    let rec pool : Nat → Nat → Array Nat → Nat → Array Nat × Nat
      | 0, _, a, s => (a, s)
      | fuel + 1, i, a, s =>
        if i < count then
          let (r, s') := streamBelow s (n - i)
          pool fuel (i + 1) (a.swapIfInBounds i (i + r)) s'
        else (a, s)
    let (a, s) := pool count 0 (List.range n).toArray st
    ((a.toList.take count).map (viewRefAt z vo), s)

def randomRepeats (z : ZSession) (vo : ViewObj Nat (List Nat)) (count : Nat) (st : Nat) : List SElem × Nat :=
  let rec go : Nat → List SElem → Nat → List SElem × Nat
    | 0, acc, s => (acc, s)
    | k + 1, acc, s =>
      let (j, s') := streamBelow s vo.size
      go k (acc ++ [viewRefAt z vo j]) s'
  if vo.size = 0 then ([], st) else go count [] st

def flatLinks (z : ZSession) (vo : ViewObj Nat (List Nat)) (l : Nat) (self : SElem) : List (Option Int × List Nat) :=
  let others := (visibleOrder z vo l).filter (fun e => e.name != self.name)
  topk hitLe 32 (others.map (fun e => (some (scoreOf self.mask e.mask), e.name)))

def plainHits (p : SPart) (q : Nat) (filter : Option Nat) : List PlainHit :=
  (p.order.filter (acceptFilter filter)).map (fun e => ⟨some (scoreOf q e.mask), e.name, e.seq⟩)

def plainSearch (p : SPart) (q : Nat) (count : Nat) (filter : Option Nat) : List (Option Int × List Nat) :=
  (topk plainSeq (min count p.order.length) (plainHits p q filter)).map (fun h => (h.score, h.name))

end Vectors
