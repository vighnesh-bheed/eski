import Vectors

open Vectors

def parseNat (s : String) : Except String Nat :=
  match s.toNat? with
  | some n => .ok n
  | none => .error ("invalid natural " ++ s)

def parseInt (s : String) : Except String Int :=
  match s.toInt? with
  | some n => .ok n
  | none => .error ("invalid integer " ++ s)

def expect {α : Type} : Except String α → IO α
  | .ok a => pure a
  | .error e => throw (IO.userError e)

def parseDyadic (s : String) : Except String Rat :=
  match s.splitOn ":" with
  | [n, e] => do return mkRat (← parseInt n) (2 ^ (← parseNat e))
  | _ => .error ("invalid dyadic " ++ s)

def showRat (r : Rat) : String := s!"{r.num}/{r.den}"

def joinOr (xs : List String) : String := if xs.isEmpty then "-" else String.intercalate "," xs

def signRow (n j : Nat) : String :=
  String.ofList ((List.range n).map fun i => if hadamardSign j i = 1 then '+' else '-')

def gramRow (n out : Nat) : List String :=
  (List.range out).flatMap fun j => ((List.range out).drop j).map fun k => toString (gram n j k)

def isPow2 (n : Nat) : Bool := n != 0 && (n &&& (n - 1)) == 0

def showCand (c : Cand) : String := s!"{c.dist}:{c.id}"

def showHeap (h : List Cand) : String := joinOr (h.map showCand)

def contained (v : Visited) : String :=
  joinOr (v.stamps.zipIdx.filterMap fun (s, i) => if s == v.epoch then some (toString i) else none)

def bit (b : Bool) : String := if b then "1" else "0"

def parseX (s : String) : Except String XF :=
  if s == "inf" then .ok (.inf false)
  else if s == "-inf" then .ok (.inf true)
  else if s == "nan" then .ok .nan
  else do return .fin (← parseDyadic s)

def parseCand (s : String) : Except String Cand :=
  match s.splitOn ":" with
  | [d, i] => do return ⟨← parseInt d, ← parseNat i⟩
  | _ => .error ("invalid candidate " ++ s)

def hexWord (n : Nat) : String := String.ofList (Nat.toDigits 16 n)

def showArena (a : Arena) : String :=
  let free := if a.free = nilSlot then "-" else toString a.free
  s!"{a.high}:{a.cap}:{a.live}:{free}|{joinOr ((walkFree a.norms (a.high + 1) a.free).map toString)}|{joinOr (a.norms.map hexWord)}"

def f32BitsNat (r : Nat) : Nat :=
  if r = 0 then 0
  else
    let e := Nat.log2 r
    (e + 127) * 2 ^ 23 + (r - 2 ^ e) * 2 ^ 23 / 2 ^ e

def encodedNormWord (tok : String) : Except String Nat :=
  if tok == "0" || tok == "-0" || tok == "tiny" then .ok 0x3F800000
  else if tok == "huge" then .ok 0x7F800000
  else if tok == "big" then .ok (f32BitsNat (2 ^ 63))
  else do
    let v ← parseInt tok
    if v == 0 || v.natAbs ≥ 2 ^ 12 then throw ("unsupported encode token " ++ tok)
    return f32BitsNat v.natAbs

def pairCloser (a b : Int × Nat) : Bool := decide (a.1 < b.1) || (decide (a.1 = b.1) && decide (a.2 < b.2))

def sortPairs (l : List (Int × Nat)) : List (Int × Nat) := candidatesSort pairCloser (insertionSort pairCloser) l

def ltInt (a b : Int) : Bool := decide (a < b)

structure Eng where
  ix : Ix
  pts : Array (Int × Int)
  m : Nat
  efc : Nat
  coin : Nat
  width : Nat

def Eng.dist (e : Eng) (a b : Nat) : Int :=
  let pa := e.pts.getD a (0, 0)
  let pb := e.pts.getD b (0, 0)
  (pa.1 - pb.1) * (pa.1 - pb.1) + (pa.2 - pb.2) * (pa.2 - pb.2)

def layerCount : Nat := 31

def normIx (ix : Ix) : Ix :=
  let n := ix.slots
  let lv := (List.range n).toArray.map ix.level
  let nx := (List.range n).toArray.map ix.next
  let pv := (List.range n).toArray.map ix.prev
  let ad := (List.range layerCount).toArray.map (fun l => (List.range n).toArray.map (ix.adj l))
  { ix with level := fun x => lv.getD x lvlFree, next := fun x => nx.getD x noneId, prev := fun x => pv.getD x 0,
            adj := fun l x => (ad.getD l #[]).getD x [] }

def greedyStep (adj : Nat → List Nat) (dq : Nat → Int) (best : Cand) : Cand × Bool :=
  (adj best.id).foldl (fun (acc : Cand × Bool) x =>
    let c : Cand := ⟨dq x, x⟩
    if closer c acc.1 then (c, true) else acc) (best, false)

def greedy (adj : Nat → List Nat) (dq : Nat → Int) : Cand → Nat → Cand
  | best, 0 => best
  | best, fuel + 1 =>
    let r := greedyStep adj dq best
    if r.2 then greedy adj dq r.1 fuel else r.1

def pushResult (res : List Cand) (c : Cand) (ef : Nat) : List Cand :=
  if res.length < ef then maxPush res c
  else if closer c (heapTop res) then (maxReplaceTop res c).2 else res

def gatherIds (adj : List Nat) (vis : Visited) : Visited × List Nat :=
  adj.foldl (fun (acc : Visited × List Nat) x =>
    let r := visitedMark acc.1 x
    (r.1, if r.2 then acc.2 ++ [x] else acc.2)) (vis, [])

def searchLoop (adj : Nat → List Nat) (dq : Nat → Int) (ef : Nat) : Nat → Visited → List Cand → List Cand → List Cand
  | 0, _, _, res => res
  | fuel + 1, vis, cands, res =>
    if cands.isEmpty then res
    else
      let p := minPop cands
      let c := p.1
      if !res.isEmpty && decide ((heapTop res).dist < c.dist) then res
      else
        let g := gatherIds (adj c.id) vis
        let q := g.2.foldl (fun (acc : List Cand × List Cand) x =>
          let n : Cand := ⟨dq x, x⟩
          if decide (acc.2.length < ef) || closer n (heapTop acc.2) then (minPush acc.1 n, pushResult acc.2 n ef)
          else acc) (p.2, res)
        searchLoop adj dq ef fuel g.1 q.1 q.2

def searchLayer (slots : Nat) (adj : Nat → List Nat) (dq : Nat → Int) (entries : List Cand) (ef : Nat) : List Cand :=
  let vis := visitedBegin visitedInit slots
  let st := entries.foldl (fun (acc : Visited × List Cand × List Cand) c =>
    let r := visitedMark acc.1 c.id
    if r.2 then (r.1, minPush acc.2.1 c, pushResult acc.2.2 c ef) else (r.1, acc.2.1, acc.2.2)) (vis, [], [])
  searchLoop adj dq ef (slots + entries.length + 1) st.1 st.2.1 st.2.2

def drain : Nat → List Cand → List Cand → List Cand
  | 0, _, acc => acc
  | fuel + 1, h, acc => if h.isEmpty then acc else drain fuel (maxPop h).2 ((maxPop h).1 :: acc)

def resultsToWork (res : List Cand) (skip : Option Nat) : List Cand :=
  let w := drain (res.length + 1) res []
  match skip with
  | none => w
  | some s => w.filter (fun c => c.id != s)

def selectNeighbors (dist : Nat → Nat → Int) (work : List Cand) (m : Nat) : List Cand :=
  let r := work.foldl (fun (acc : List Cand × List Cand) c =>
    if m ≤ acc.1.length then acc
    else if acc.1.all (fun r => !(decide (dist c.id r.id < c.dist))) then (acc.1 ++ [c], acc.2)
    else (acc.1, acc.2 ++ [c])) ([], [])
  r.2.foldl (fun s c => if m ≤ s.length then s else s ++ [c]) r.1

def descendTo (ix : Ix) (dq : Nat → Int) (start : Cand) (fromLevel toLevel : Nat) : Cand :=
  ((List.range (fromLevel + 1)).reverse.filter (fun l => toLevel < l)).foldl
    (fun c l => greedy (ix.adj l) dq c (ix.slots + 1)) start

def Eng.insertSlot (e : Eng) (slot lv : Nat) : Eng :=
  let ix := e.ix
  let dq : Nat → Int := fun x => e.dist slot x
  let victim := fun (_ : Nat) (g : Graph) (x : Nat) => shrinkVictim e.dist ltInt sortPairs g x slot (e.dist slot x)
  let guard := fun (_ : Nat) (g : Graph) (v h : Nat) => stranded g v h
  let pick := fun (_ : Nat) => closestPick e.dist
  if ix.entry = noneId then { e with ix := normIx (insertOp e.m ix slot lv none (fun _ => []) victim guard pick) }
  else
    let ep := descendTo ix dq ⟨dq ix.entry, ix.entry⟩ ix.maxLevel lv
    let top := min ix.maxLevel lv
    let r := (List.range (top + 1)).reverse.foldl (fun (acc : List Cand × (Nat → List Cand)) l =>
      let work := resultsToWork (searchLayer ix.slots (ix.adj l) dq acc.1 e.efc) (some slot)
      (work, fun l' => if l' = l then work else acc.2 l')) ([ep], fun _ => [])
    let layered := r.2
    let head := coincidentHead e.coin (dq slot) (fun c => e.dist c c) (layered 0)
    let sel := fun l => (selectNeighbors e.dist (layered l) e.m).map Cand.id
    { e with ix := normIx (insertOp e.m ix slot lv head sel victim guard pick) }

def otherAtLevel (ix : Ix) (n layer : Nat) : Nat :=
  ((List.range ix.slots).find? (fun x => x != n && decide (ix.level x ≤ levelCap) && decide (layer ≤ ix.level x))).getD noneId

def Eng.relinkSel (e : Eng) (ctx : Ix) (layer : Nat) (g : Graph) (n : Nat) : List Nat :=
  let start := if ctx.entry = n then otherAtLevel ctx n layer else ctx.entry
  if start = noneId then []
  else
    let dq : Nat → Int := fun x => e.dist n x
    let ep := descendTo ctx dq ⟨e.dist n start, start⟩ (ctx.level start) layer
    let ents1 : List Cand := if ep.id ≠ n then [ep] else []
    let ents2 : List Cand := if layer + 1 ≤ ctx.level n then (ctx.adj (layer + 1) n).map (fun v => ⟨e.dist n v, v⟩) else []
    let ents := if (ents1 ++ ents2).isEmpty then [⟨e.dist n start, start⟩] else ents1 ++ ents2
    let work := resultsToWork (searchLayer ctx.slots g.adj dq ents e.efc) (some n)
    (selectNeighbors e.dist work e.m).map Cand.id

def Eng.removeSlot (e : Eng) (slot : Nat) : Eng :=
  let ix := e.ix
  let relink := fun (l : Nat) (ctx : Ix) (g : Graph) (n : Nat) =>
    relinkWith (layerCap e.m l) e.dist ltInt sortPairs (fun g' n' => e.relinkSel ctx l g' n')
      (fun _ n' x => e.dist n' x) (fun g' v h => stranded g' v h) (closestPick e.dist) g n
  let repairL := fun l => repairLayer (layerCap e.m l) e.dist ltInt sortPairs true (relink l) (ix.adj l slot)
  { e with ix := normIx (removeOp ix slot repairL) }

def twinWalk (ix : Ix) (dq : Nat → Int) (want : Nat) (c : Cand) : Nat → Nat → List Cand → List Cand
  | 0, _, r => r
  | fuel + 1, t, r =>
    if t = noneId then r
    else if want ≤ r.length && !(decide (c.dist < (heapTop r).dist)) then r
    else twinWalk ix dq want c fuel (ix.next t) (pushResult r ⟨dq t, t⟩ want)

def twinsMerge (ix : Ix) (dq : Nat → Int) (res : List Cand) (want : Nat) : List Cand :=
  let work := resultsToWork res none
  let r := work.foldl (fun (acc : List Cand × Bool) c =>
    if acc.2 then acc
    else if want ≤ acc.1.length && !(closer c (heapTop acc.1)) then (acc.1, true)
    else (twinWalk ix dq want c (ix.twins + 1) (ix.next c.id) (pushResult acc.1 c want), false)) ([], false)
  r.1

def Eng.search (e : Eng) (qx qy : Int) (k ef : Nat) : List Cand :=
  let ix := e.ix
  if ix.entry = noneId ∨ k = 0 then []
  else
    let dq : Nat → Int := fun x =>
      let p := e.pts.getD x (0, 0)
      (p.1 - qx) * (p.1 - qx) + (p.2 - qy) * (p.2 - qy)
    let ep := descendTo ix dq ⟨dq ix.entry, ix.entry⟩ ix.maxLevel 0
    let res := searchLayer ix.slots (ix.adj 0) dq [ep] (max ef k)
    let res := if 0 < ix.twins then twinsMerge ix dq res k else res
    let trimmed := (List.range res.length).foldl (fun h _ => if k < h.length then (maxPop h).2 else h) res
    drain (trimmed.length + 1) trimmed []

def showSlot (ix : Ix) (x : Nat) : String :=
  let lv := ix.level x
  let nx := if ix.next x = noneId then "-" else toString (ix.next x)
  let pv := if lv = lvlTwin then toString (ix.prev x) else "-"
  let lists := if lv ≤ levelCap then
      String.intercalate "/" ((List.range (lv + 1)).map (fun l => joinOr ((ix.adj l x).map toString)))
    else "-"
  s!"{lv}:{nx}:{pv}:{lists}"

def showIx (e : Eng) : String :=
  let ix := e.ix
  let ent := if ix.entry = noneId then "-" else toString ix.entry
  s!"{ent}:{ix.maxLevel}:{ix.live}:{ix.twins}:{e.width}|{joinOr (ix.free.map toString)}|{String.intercalate ";" ((List.range ix.slots).map (showSlot ix))}"

def setPoint (pts : Array (Int × Int)) (s : Nat) (p : Int × Int) : Array (Int × Int) :=
  let pts := if pts.size ≤ s then pts ++ (List.replicate (s + 1 - pts.size) ((0 : Int), (0 : Int))).toArray else pts
  pts.set! s p


structure St where
  heapMax : Bool := false
  heap : List Cand := []
  vis : Visited := visitedInit
  arena : Arena := arenaInit 0
  eng : Option Eng := none
  ztbl : List Lbl := []
  zs : Option ZSession := none


def parseLbl (s : String) : Except String Lbl :=
  match s.splitOn ":" with
  | [a, b, c] => do return ⟨← parseNat a, ← parseNat b, ← parseNat c⟩
  | _ => .error ("invalid label " ++ s)

def parseName (s : String) : List Nat := if s == "~" then [] else s.toList.map Char.toNat

def parseAttrSpec (s : String) : Except String (Option (Option Nat)) :=
  if s == "-" then .ok none
  else if s == "e" then .ok (some none)
  else if s.startsWith "a" then do return some (some (← parseNat (s.drop 1).toString))
  else .error ("invalid attribute " ++ s)

def parseOpt (s : String) : Except String (Option Nat) :=
  if s == "-" then .ok none else do return some (← parseNat (s.drop 1).toString)

def parseBound (s : String) (lower : Bool) : Except String (List Nat → Bool) :=
  if s == "-" then .ok (fun _ => lower)
  else if s == "+" then .ok (fun _ => !lower)
  else
    let v := parseName (s.drop 1).toString
    if s.startsWith "[" then
      .ok (fun n => if lower then nameLe v n else nameLe n v)
    else if s.startsWith "(" then
      .ok (fun n => if lower then nameLt v n else nameLt n v)
    else .error ("invalid bound " ++ s)

def namesText (xs : List SElem) : String := if xs.isEmpty then "-" else String.intercalate "," (xs.map (fun e => showName e.name))

def zsession (st : St) : Except String ZSession :=
  match st.zs with
  | some z => .ok z
  | none => .error "no labelled session"

def zstep (st : St) (fields : List String) : Except String (St × Option String) := do
  match fields with
  | "ZT" :: labels =>
    let tbl ← labels.mapM parseLbl
    return ({ st with ztbl := tbl, zs := none }, some s!"ZT|{tbl.length}")
  | ["ZN", f, s, kind, _] =>
    let f ← parseNat f
    let s ← parseNat s
    let parts : Nat → Option SPart :=
      if kind == "plain" then fun l => if l = 0 then some { mode := .pinned, uid := 0, rng := 0, order := [] } else none
      else fun _ => none
    let z : ZSession := ⟨st.ztbl, f, s, ⟨parts, fun _ => [], streamSeed⟩⟩
    return ({ st with zs := some z }, some "ZN|ok")
  | ["ZA", lab, name, mask, attr] =>
    let z ← zsession st
    let w ← parseNat lab
    let n := parseName name
    let v : SVal := ⟨← parseNat mask, ← parseAttrSpec attr⟩
    let ls := z.st.index n
    if w ∈ ls then
      return ({ st with zs := some (z.write ⟨w, .add n v⟩) }, some "ZA|0|0|0|0|none|-")
    else if visibleOther (simSees z.tbl) w ls then
      return (st, some s!"ZA|0|0|0|0|inuse|{(resolveL (z.reader w) ls).getD 0}")
    else
      let created := (z.st.parts w).isNone
      return ({ st with zs := some (z.write ⟨w, .add n v⟩) }, some s!"ZA|1|{boolBit created}|0|0|none|-")
  | ["ZR", lab, name] =>
    let z ← zsession st
    let w ← parseNat lab
    let n := parseName name
    let ls := z.st.index n
    if w ∈ ls then
      let z' := z.write ⟨w, .rem n⟩
      return ({ st with zs := some z' }, some s!"ZR|1|{boolBit (z'.st.parts w).isNone}|{boolBit z'.allEmpty}|none|-")
    else if visibleOther (simSees z.tbl) w ls then
      return (st, some s!"ZR|0|0|0|inuse|{(resolveL (z.reader w) ls).getD 0}")
    else return (st, some "ZR|0|0|0|none|-")
  | ["ZE", lab, name, attr] =>
    let z ← zsession st
    let w ← parseNat lab
    let n := parseName name
    let ls := z.st.index n
    let v : SVal := ⟨0, ← parseAttrSpec attr⟩
    if w ∈ ls then
      return ({ st with zs := some (z.write ⟨w, .set n v⟩) }, some "ZE|1|none|-")
    else if visibleOther (simSees z.tbl) w ls then
      return (st, some s!"ZE|0|inuse|{(resolveL (z.reader w) ls).getD 0}")
    else return (st, some "ZE|0|none|-")
  | ["ZX", src, tgt, name] =>
    let z ← zsession st
    let a ← parseNat src
    let t ← parseNat tgt
    let n := parseName name
    let ls := z.st.index n
    if a ∉ ls then
      if visibleOther (simSees z.tbl) a ls then
        return (st, some s!"ZX|0|0|inuse|{(resolveL (z.reader a) ls).getD 0}")
      else return (st, some "ZX|0|0|notfound|-")
    else if t ∈ ls then return (st, some s!"ZX|0|0|inuse|{t}")
    else
      let st' := relabelState (simOps z.flat z.shrink) (simMoveOps z.flat) (simSees z.tbl) a t n z.st
      let row := s!"ZX|{boolBit (st'.parts a).isNone}|{boolBit (z.st.parts t).isNone}|none|-"
      return ({ st with zs := some { z with st := st' } }, some row)
  | ["ZB", q, _, _] => return (st, some s!"ZB|{q}|1|1|1")
  | ["ZL", lab] =>
    let z ← zsession st
    let w ← parseNat lab
    let removed := (z.part w).order.length
    let found := (z.st.parts w).isSome && removed > 0
    let z' := z.write ⟨w, .drop⟩
    let removed := if found then removed else 0
    return ({ st with zs := some z' }, some s!"ZL|{removed}|{boolBit found}|{boolBit found}|{boolBit z'.allEmpty}")
  | ["ZC", rd] =>
    let z ← zsession st
    let vo := z.view (← parseNat rd)
    let uid := (vo.labels.map (fun l => (z.part l).uid)).foldl (· + ·) 0
    let parts := vo.labels.map (fun l => let p := z.part l; s!"{l}:{showMode p.mode}:{p.order.length}:{p.uid}")
    return (st, some s!"ZC|{vo.size}|{vo.attrs}|{uid}|{joinOr parts}")
  | ["ZF", rd, name] =>
    let z ← zsession st
    let r := z.reader (← parseNat rd)
    let n := parseName name
    match viewFind r z.st n with
    | none => return (st, some "ZF|-")
    | some l =>
      let e := z.elem l n
      return (st, some s!"ZF|{l}|{showAttr e.attr}|{e.mask}")
  | ["ZG", rd, lo, hi, lim] =>
    let z ← zsession st
    let r := z.reader (← parseInt rd).toNat
    let lower ← parseBound lo true
    let upper ← parseBound hi false
    let limit ← parseInt lim
    if limit == 0 || lo == "+" || hi == "-" then return (st, some "ZG|-")
    let lim := if limit < 0 then none else some limit.toNat
    let hits := viewRange r z.st z.namesU (fun n => lower n && upper n) lim
    return (st, some s!"ZG|{if hits.isEmpty then "-" else String.intercalate "," (hits.map (fun h => showName h.1))}")
  | ["ZQ", rd, kind, arg, count, _, filter, _, eps] =>
    let z ← zsession st
    let rd ← parseNat rd
    let vo := z.view rd
    let count ← parseNat count
    let count := if count = 0 then 10 else count
    let filter ← parseOpt filter
    let eps ← parseOpt eps
    let query : Option Nat ← if kind == "v" then pure (some (← parseNat arg)) else
      match viewFind (z.reader rd) z.st (parseName arg) with
      | none => pure none
      | some l => pure (some (z.elem l (parseName arg)).mask)
    if vo.size = 0 then
      return (st, some (if kind == "e" then "ZQ|notfound" else "ZQ|ok|-"))
    match query with
    | none => return (st, some "ZQ|notfound")
    | some q => return (st, some s!"ZQ|ok|{showHits (viewSearch z vo q count filter eps)}")
  | ["ZM", rd, kind, count] =>
    let z ← zsession st
    let rd ← parseNat rd
    let vo := z.view rd
    let k ← parseNat count
    let s0 := z.st.stream rd
    let (refs, s1) :=
      if kind == "m" then
        if vo.size = 0 then ([], s0) else
        let (j, s') := streamBelow s0 vo.size
        ([viewRefAt z vo j], s')
      else if kind == "d" then randomDistinct z vo k s0
      else randomRepeats z vo k s0
    let z' := { z with st := setStream z.st rd s1 }
    return ({ st with zs := some z' }, some s!"ZM|{namesText refs}")
  | ["ZK", rd, name] =>
    let z ← zsession st
    let rd ← parseNat rd
    let vo := z.view rd
    let n := parseName name
    match viewFind (z.reader rd) z.st n with
    | none => return (st, some "ZK|-")
    | some l =>
      let p := z.part l
      if p.mode != .flat then return (st, some "ZK|graph")
      else return (st, some s!"ZK|{showHits (flatLinks z vo l (z.elem l n))}")
  | "ZO" :: rest =>
    let z ← zsession st
    let p := z.part 0
    let rebuild : SPart → ZSession := fun q =>
      { z with st := { z.st with parts := fun l => if l = 0 then some q else z.st.parts l,
                                  index := fun m => if (simNames q).contains m then [0] else [] } }
    match rest with
    | ["add", name, mask, attr] =>
      let n := parseName name
      let v : SVal := ⟨← parseNat mask, ← parseAttrSpec attr⟩
      let added := !(simNames p).contains n
      let q := plainOp (simOps z.flat z.shrink) simNames (.add n v) p
      return ({ st with zs := some (rebuild q) }, some s!"ZO|add|{boolBit added}")
    | ["rem", name] =>
      let n := parseName name
      let found := (simNames p).contains n
      let q := plainOp (simOps z.flat z.shrink) simNames (.rem n) p
      return ({ st with zs := some (rebuild q) }, some s!"ZO|rem|{boolBit found}|{boolBit (found && q.order.isEmpty)}")
    | ["set", name, attr] =>
      let n := parseName name
      let found := (simNames p).contains n
      let q := plainOp (simOps z.flat z.shrink) simNames (.set n ⟨0, ← parseAttrSpec attr⟩) p
      return ({ st with zs := some (rebuild q) }, some s!"ZO|set|{boolBit found}")
    | ["card"] => return (st, some s!"ZO|card|{p.order.length}")
    | ["info"] => return (st, some s!"ZO|info|{p.order.length}|{simAcc.attrs p}|{p.uid}")
    | ["find", name] =>
      let n := parseName name
      match p.order.find? (fun e => e.name == n) with
      | none => return (st, some "ZO|find|0")
      | some e => return (st, some s!"ZO|find|1|{showAttr e.attr}|{e.mask}")
    | ["range"] =>
      let ns := (simNames p).mergeSort nameLe
      return (st, some s!"ZO|range|{if ns.isEmpty then "-" else String.intercalate "," (ns.map showName)}")
    | ["sim", mask, count, filter] =>
      let count ← parseNat count
      let count := if count = 0 then 10 else count
      return (st, some s!"ZO|sim|{showHits (plainSearch p (← parseNat mask) count (← parseOpt filter))}")
    | _ => throw ("invalid ZO line: " ++ String.intercalate " " rest)
  | _ => throw ("invalid case line: " ++ String.intercalate " " fields)

def step (st : St) (fields : List String) : Except String (St × Option String) := do
  match fields with
  | ["P", a, b] =>
    let input ← parseNat a
    let output ← parseNat b
    if projectionValid input output then
      let rows := (List.range output).map (signRow input)
      return (st, some s!"P|1|{String.intercalate "," rows}|{String.intercalate "," (gramRow input output)}")
    else return (st, some "P|0")
  | "Q" :: rest =>
    let xs ← rest.mapM parseDyadic
    let (range, qs) := quantiseF xs 1
    let decoded := dequantise qs range 1
    return (st, some s!"Q|{showRat range}|{joinOr (qs.map toString)}|{joinOr (decoded.map showRat)}")
  | "QE" :: rest =>
    let xs ← rest.mapM parseDyadic
    if !(xs.all fun x => decide (Rat.abs x ≤ 1 / 2 ^ 75)) then throw "QE needs components whose squares vanish"
    let (range, qs) := quantiseF xs 1
    let decoded := dequantise qs range 1
    return (st, some s!"QE|1/1|{showRat range}|{joinOr (qs.map toString)}|{joinOr (decoded.map showRat)}")
  | ["R", t] => return (st, some s!"R|{q8RoundX (← parseX t)}")
  | "B" :: d :: rest =>
    let dim ← parseNat d
    let xs ← rest.mapM parseDyadic
    if xs.length != dim then throw "binary length mismatch"
    let ws := packBits xs 1 (binWords dim)
    return (st, some s!"B|{joinOr (ws.map toString)}|{bit (binPaddingClear ws dim)}")
  | "H" :: d :: rest =>
    let dim ← parseNat d
    let xs ← (rest.take dim).mapM parseDyadic
    let ys ← (rest.drop dim).mapM parseDyadic
    if xs.length != dim || ys.length != dim then throw "hamming length mismatch"
    let h := hamming (packBits xs 1 (binWords dim)) (packBits ys 1 (binWords dim))
    let score := if isPow2 dim then showRat (scoreBin h dim) else "-"
    return (st, some s!"H|{h}|{score}")
  | "W" :: d :: k :: rest =>
    let dim ← parseNat d
    let k ← parseNat k
    let ws ← rest.mapM parseNat
    if ws.length != 2 * k then throw "word count mismatch"
    let a := ws.take k
    let b := ws.drop k
    return (st, some s!"W|{hamming a b}|{bit (binPaddingClear a dim)}|{bit (binPaddingClear b dim)}")
  | ["HN", kind] => return ({ st with heapMax := kind == "max", heap := [] }, none)
  | ["HP", d, i] =>
    let c : Cand := ⟨← parseInt d, ← parseNat i⟩
    let h := if st.heapMax then maxPush st.heap c else minPush st.heap c
    return ({ st with heap := h }, some s!"HP|{showHeap h}")
  | ["HO"] =>
    if st.heap.isEmpty then throw "pop of empty heap"
    let (top, h) := if st.heapMax then maxPop st.heap else minPop st.heap
    return ({ st with heap := h }, some s!"HO|{showCand top}|{showHeap h}")
  | ["HT"] =>
    if st.heap.isEmpty then throw "top of empty heap"
    return (st, some s!"HT|{showCand (heapTop st.heap)}")
  | ["HR", d, i] =>
    if st.heap.isEmpty || !st.heapMax then throw "replace needs a nonempty max heap"
    let c : Cand := ⟨← parseInt d, ← parseNat i⟩
    let (top, h) := maxReplaceTop st.heap c
    return ({ st with heap := h }, some s!"HR|{showCand top}|{showHeap h}")
  | ["VN"] => return ({ st with vis := visitedInit }, none)
  | ["VB", n] =>
    let v := visitedBegin st.vis (← parseNat n)
    return ({ st with vis := v }, some s!"VB|{v.epoch}|{v.cap}|{contained v}")
  | ["VM", i] =>
    let id ← parseNat i
    if id ≥ st.vis.cap then throw "mark outside the stamp array"
    let (v, r) := visitedMark st.vis id
    return ({ st with vis := v }, some s!"VM|{bit r}|{contained v}")
  | ["VC", i] =>
    let id ← parseNat i
    if id ≥ st.vis.cap then throw "query outside the stamp array"
    return (st, some s!"VC|{bit (visitedContains st.vis id)}")
  | ["VE", e] =>
    let e ← parseNat e
    if e ≥ 2 ^ 8 then throw "epoch outside u8"
    return ({ st with vis := ⟨st.vis.stamps, e⟩ }, some s!"VE|{e}")
  | "CS" :: rest =>
    let cs ← rest.mapM parseCand
    return (st, some s!"CS|{showHeap (insertionSort closer cs)}")
  | ["LW", c] =>
    let c ← parseNat c
    return (st, some s!"LW|{linkWidth c}|{widthNone (linkWidth c)}")
  | ["LN", b] =>
    let b ← parseNat b
    let r := liveNorm b
    return (st, some s!"LN|{hexWord r.1}|{bit r.2}")
  | ["AN", c] =>
    let a := arenaInit (← parseNat c)
    return ({ st with arena := a }, some s!"AN|{showArena a}")
  | ["AA"] =>
    match arenaAlloc st.arena with
    | none => return (st, some s!"AA|-|{showArena st.arena}")
    | some (s, a) => return ({ st with arena := a }, some s!"AA|{s}|{showArena a}")
  | ["AF", s] =>
    let r := arenaFree st.arena (← parseNat s)
    let code := match r.1 with
      | .none => 0
      | .invalidSlot => 1
      | .alreadyFree => 2
    return ({ st with arena := r.2 }, some s!"AF|{code}|{showArena r.2}")
  | ["AS", s, b] =>
    let r := arenaSetNorm st.arena (← parseNat s) (← parseNat b)
    return ({ st with arena := r.2 }, some s!"AS|{bit r.1}|{showArena r.2}")
  | ["AZ", s, b] =>
    let r := arenaSetNorm st.arena (← parseNat s) (← parseNat b)
    return ({ st with arena := r.2 }, some s!"AZ|{bit r.1}|{showArena r.2}")
  | ["AI", b] =>
    let b ← parseNat b
    if !(liveNorm b).2 then return (st, some s!"AI|-|{showArena st.arena}")
    else
      match arenaAlloc st.arena with
      | none => return (st, some s!"AI|-|{showArena st.arena}")
      | some (s, a) =>
        let a := (arenaSetNorm a s b).2
        return ({ st with arena := a }, some s!"AI|{s}|{showArena a}")
  | ["AE", s, t] =>
    let a := arenaSetEncoded st.arena (← parseNat s) (← encodedNormWord t)
    return ({ st with arena := a }, some s!"AE|{showArena a}")
  | ["AL", s] => return (st, some s!"AL|{bit (arenaIsLive st.arena (← parseNat s))}")
  | ["XN", m, efc] =>
    let m ← parseNat m
    let e : Eng := ⟨emptyIx, #[], m, ← parseNat efc, coincidentCount m true, 2⟩
    return ({ st with eng := some e }, some s!"XN|{e.coin}|{e.width}")
  | ["XI", x, y, lv] =>
    let some e := st.eng | throw "no index"
    let (slot, ix) := reserveOp e.ix
    let e := { e with ix := normIx ix, pts := setPoint e.pts slot (← parseInt x, ← parseInt y) }
    let e := e.insertSlot slot (← parseNat lv)
    return ({ st with eng := some e }, some s!"XI|{slot}|0|{showIx e}")
  | ["XR"] =>
    let some e := st.eng | throw "no index"
    let (slot, ix) := reserveOp e.ix
    let e := { e with ix := normIx ix }
    return ({ st with eng := some e }, some s!"XR|{slot}|{showIx e}")
  | ["XF", s] =>
    let some e := st.eng | throw "no index"
    let s ← parseNat s
    if !(s < e.ix.slots && e.ix.level s == lvlReserved) then return (st, some s!"XF|3|{showIx e}")
    let e := { e with ix := normIx (pushFree e.ix s) }
    return ({ st with eng := some e }, some s!"XF|0|{showIx e}")
  | ["XD", s] =>
    let some e := st.eng | throw "no index"
    let s ← parseNat s
    if !(s < e.ix.slots && decide (e.ix.level s < lvlReserved)) then return (st, some s!"XD|4|{showIx e}")
    let e := e.removeSlot s
    return ({ st with eng := some e }, some s!"XD|0|{showIx e}")
  | ["XW", w] =>
    let some e := st.eng | throw "no index"
    let e := { e with width := ← parseNat w }
    return ({ st with eng := some e }, some s!"XW|0|{showIx e}")
  | ["XS", x, y, k, ef] =>
    let some e := st.eng | throw "no index"
    let r := e.search (← parseInt x) (← parseInt y) (← parseNat k) (← parseNat ef)
    return (st, some s!"XS|{showHeap r}")
  | f :: _ => if f.startsWith "Z" then zstep st fields else throw ("invalid case line: " ++ String.intercalate " " fields)
  | [] => throw "empty case line"

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "expected case path")
  let input ← IO.FS.readFile path
  let out ← IO.getStdout
  let mut st : St := {}
  for line in input.splitOn "\n" do
    if line.isEmpty then continue
    let (next, row) ← expect (step st (line.splitOn " "))
    st := next
    if let some r := row then out.putStrLn r
