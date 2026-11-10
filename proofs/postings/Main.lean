import Postings

open Postings

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

def hexVal (c : Char) : Except String Nat :=
  if '0' ≤ c ∧ c ≤ '9' then .ok (c.toNat - '0'.toNat)
  else if 'a' ≤ c ∧ c ≤ 'f' then .ok (c.toNat - 'a'.toNat + 10)
  else .error ("invalid hex digit " ++ c.toString)

def unhexAux : List Char → Except String (List Nat)
  | [] => .ok []
  | a :: b :: rest => do return (16 * (← hexVal a) + (← hexVal b)) :: (← unhexAux rest)
  | _ => .error "odd hex length"

def unhex (s : String) : Except String (List Nat) := if s == "-" then .ok [] else unhexAux s.toList

def parseHexNat (s : String) : Except String Nat :=
  s.toList.foldlM (fun acc c => do return 16 * acc + (← hexVal c)) 0

def hexDigit (n : Nat) : Char := if n < 10 then Char.ofNat (48 + n) else Char.ofNat (87 + n)

def hexBytes (bs : List Nat) : String :=
  if bs.isEmpty then "-" else String.ofList (bs.flatMap fun b => [hexDigit (b / 16), hexDigit (b % 16)])

def hexNat (n : Nat) : String := String.ofList (Nat.toDigits 16 n)

def hex16 (n : Nat) : String :=
  let d := Nat.toDigits 16 n
  String.ofList (List.replicate (16 - d.length) '0' ++ d)

def fbits (x : Float) : String := hex16 x.toBits.toNat

def joinOr (xs : List String) : String := if xs.isEmpty then "-" else String.intercalate "," xs

def natsText (xs : List Nat) : String := joinOr (xs.map toString)

def parseNats (s : String) : Except String (List Nat) :=
  if s == "-" then .ok [] else (s.splitOn ",").mapM parseNat

def bit (b : Bool) : String := if b then "1" else "0"

def kindText : Con → String
  | .arr vs => s!"a:{vs.length}"
  | .bits vs => s!"b:{vs.length}"
  | .runs rs => s!"r{rs.length}:{(expandRuns rs).length}"

def layoutText (b : Bitmap) : String :=
  if b.isEmpty then "-" else String.intercalate "," (b.map fun p => s!"{p.1}:{kindText p.2}")

def checksumOf (xs : List Nat) : Nat :=
  let p := 2 ^ 61 - 1
  (xs.zipIdx.foldl (fun acc q => (acc + (q.2 + 1) * q.1 % p) % p) 0)

def describe (b : Bitmap) : String :=
  let c := contents b
  let lo := match c.head? with | some x => toString x | none => "-"
  let hi := match c.getLast? with | some x => toString x | none => "-"
  s!"{layoutText b}|{c.length}|{lo}|{hi}|{checksumOf c}"

def bmEqual (a b : Bitmap) : Bool :=
  keys a == keys b && (a.map fun p => p.2.card) == (b.map fun p => p.2.card) && contents a == contents b

def iterRun (vals : List Nat) (ops : List String) : Except String String := do
  let mut pos : Nat := 0
  let mut started := false
  let mut done := false
  let mut out : List String := []
  for o in ops do
    if done then
      out := out ++ ["-"]
    else if o == "n" then
      if !started then
        started := true
        if vals.isEmpty then
          done := true
          out := out ++ ["-"]
        else
          pos := 0
          out := out ++ [toString (vals.getD 0 0)]
      else if pos + 1 < vals.length then
        pos := pos + 1
        out := out ++ [toString (vals.getD pos 0)]
      else
        done := true
        out := out ++ ["-"]
    else
      let t ← parseNat o
      if started && vals.getD pos 0 ≥ t then
        out := out ++ [toString (vals.getD pos 0)]
      else
        started := true
        match vals.findIdx? (fun x => x ≥ t) with
        | some i =>
          pos := i
          out := out ++ [toString (vals.getD i 0)]
        | none =>
          done := true
          out := out ++ ["-"]
  return joinOr out

structure Posting where
  doc : Nat
  freq : Nat
  mask : Nat
  counts : List Nat
  positions : List Nat

structure PList where
  words : Nat
  pos : Bool
  items : List Posting

def popcount (n : Nat) : Nat := ((List.range 128).filter fun i => n.testBit i).length

def validate (l : PList) (p : Posting) : String :=
  if p.doc = 0 ∨ p.doc > 4294967294 then "invalid"
  else if !l.items.isEmpty ∧ p.doc ≤ (l.items.getLast?.map (·.doc)).getD 0 then "order"
  else if l.words < 4 ∧ p.mask >>> (32 * l.words) ≠ 0 then "invalid"
  else if !l.pos then (if !p.positions.isEmpty ∨ !p.counts.isEmpty then "invalid" else "ok")
  else if p.counts.length ≠ popcount p.mask then "invalid"
  else if p.counts.sum ≠ p.positions.length then "invalid"
  else if !isStrict p.positions then "invalid"
  else "ok"

inductive QNode where
  | arr (k w : Nat)
  | term (k w : Nat)
  | inter (kids : List QNode)
  | uni (first : Bool) (kids : List QNode)
  | diff (a b : QNode)
  | phrase (slop : Int) (inOrder : Bool) (kids : List QNode)

structure St where
  bitmaps : Array Bitmap := Array.replicate 4 []
  lists : Array PList := Array.replicate 16 ⟨1, true, []⟩
  arrays : Array (List Nat) := Array.replicate 16 []
  deleted : List Nat := []
  required : Nat := 0
  weights : List Float := [1.0]
  table : List (Nat × List Nat) := [(0, [])]
  reader : Nat × List Nat := (0, [])
  built : Nat := 1
  stats : Stats := statsInit

def readNum (cs : List Char) : Int × List Char :=
  let neg := cs.head? == some '-'
  let cs := if neg then cs.drop 1 else cs
  let ds := cs.takeWhile Char.isDigit
  let v : Nat := ds.foldl (fun acc c => 10 * acc + (c.toNat - '0'.toNat)) 0
  ((if neg then -(v : Int) else v), cs.drop ds.length)

partial def parseNode (cs : List Char) : Except String (QNode × List Char) := do
  match cs with
  | c :: rest =>
    if c == 'a' || c == 't' then
      let (k, r1) := readNum rest
      let r1 := r1.drop 1
      let (w, r2) := readNum r1
      return (if c == 'a' then .arr k.toNat w.toNat else .term k.toNat w.toNat, r2)
    else
      let mut r := rest
      let mut slop : Int := 0
      let mut ord := false
      if c == 'p' then
        let (s, r1) := readNum r
        let (o, r2) := readNum (r1.drop 1)
        slop := s
        ord := o == 1
        r := r2
      r := r.drop 1
      let mut kids : List QNode := []
      let mut fin := false
      while !fin do
        let (k, r') ← parseNode r
        kids := kids ++ [k]
        match r' with
        | ']' :: r'' => r := r''; fin := true
        | ',' :: r'' => r := r''
        | _ => throw "bad tree"
      match c with
      | 'i' | 'l' | 'k' => return (.inter kids, r)
      | 'u' => return (.uni false kids, r)
      | 'f' => return (.uni true kids, r)
      | 'd' => return (.diff (kids.getD 0 (.arr 0 0)) (kids.getD 1 (.arr 0 0)), r)
      | 'p' => return (.phrase slop ord kids, r)
      | _ => throw "bad node"
  | [] => throw "empty tree"

def leafDocs (st : St) : QNode → List Nat
  | .arr k _ => (st.arrays.getD k []).filter fun d => d ≠ 0 ∧ d ∉ st.deleted
  | .term k _ => ((st.lists.getD k ⟨1, true, []⟩).items.filter fun p =>
      p.doc ∉ st.deleted ∧ (st.required = 0 ∨ p.mask &&& st.required ≠ 0)).map (·.doc)
  | _ => []

def posting (st : St) (k d : Nat) : Option Posting := (st.lists.getD k ⟨1, true, []⟩).items.find? (·.doc == d)

inductive ANode where
  | leaf (isTerm : Bool) (k w : Nat) (set : List Nat) (cost : Nat)
  | inter (kids : List ANode) (set : List Nat) (cost : Nat)
  | uni (first : Bool) (kids : List ANode) (set : List Nat) (cost : Nat)
  | diff (a b : ANode) (set : List Nat) (cost : Nat)
  | phrase (slop : Int) (inOrder : Bool) (kids : List ANode) (set : List Nat) (cost : Nat)

instance : Inhabited ANode := ⟨.leaf false 0 0 [] 0⟩

def ANode.set : ANode → List Nat
  | .leaf _ _ _ s _ | .inter _ s _ | .uni _ _ s _ | .diff _ _ s _ | .phrase _ _ _ s _ => s

def ANode.cost : ANode → Nat
  | .leaf _ _ _ _ c | .inter _ _ c | .uni _ _ _ c | .diff _ _ _ c | .phrase _ _ _ _ c => c

def ANode.has (n : ANode) (d : Nat) : Bool := n.set.contains d

partial def positionsAt (st : St) (n : ANode) (d : Nat) : Option (List Nat) :=
  match n with
  | .leaf true k _ s _ => if s.contains d then (posting st k d).map (·.positions) else none
  | .uni _ kids _ _ =>
    let m := kids.filter (·.has d)
    let got := m.filterMap fun c => positionsAt st c d
    if got.isEmpty then none
    else if m.length > 1 then some ((got.foldl (fun acc l => acc ++ l) []).mergeSort (· ≤ ·) |>.eraseDups)
    else some (got.foldl (fun acc l => acc ++ l) [])
  | .diff a _ _ _ => positionsAt st a d
  | _ => none

partial def annotate (st : St) (n : QNode) : ANode :=
  match n with
  | .arr k w => .leaf false k w (leafDocs st n) (st.arrays.getD k []).length
  | .term k w => .leaf true k w (leafDocs st n) (st.lists.getD k ⟨1, true, []⟩).items.length
  | .inter kids =>
    let ks := kids.map (annotate st)
    let set := match ks with
      | [] => []
      | k :: rest => k.set.filter fun d => rest.all (·.has d)
    .inter ks set ((ks.map (·.cost)).foldl min ((ks.head?.map (·.cost)).getD 0))
  | .uni first kids =>
    let ks := kids.map (annotate st)
    .uni first ks (ks.foldl (fun acc c => unionMerge acc c.set) []) (ks.map (·.cost)).sum
  | .diff a b =>
    let ka := annotate st a
    let kb := annotate st b
    .diff ka kb (ka.set.filter fun d => !kb.has d) ka.cost
  | .phrase slop ord kids =>
    let ks := kids.map (annotate st)
    let base := match ks with
      | [] => []
      | k :: rest => k.set.filter fun d => rest.all (·.has d)
    let set := base.filter fun d => phraseMatches (ks.map fun c => (positionsAt st c d).getD []) slop ord
    .phrase slop ord ks set ((ks.map (·.cost)).foldl min ((ks.head?.map (·.cost)).getD 0))

def k1F : Float := Float.ofBits 0x3FF3333340000000

def bF : Float := 0.75

def idfF (documents containing : Nat) : Float :=
  let n := containing.toFloat
  let total := (max documents containing).toFloat
  Float.log (1 + (total - n + 0.5) / (n + 0.5))

def contribF (avg w prepared : Float) (f dl : Nat) : Float :=
  let ff := f.toFloat
  let d := dl.toFloat
  w * prepared * ff * (k1F + 1) / (ff + k1F * (1 - bF + bF * d / avg))

def docLength (d : Nat) : Nat := d * 7 % 13 + 1

def docScore (d : Nat) : Float := [1.0, 0.5, 0.75, 2.0].getD (d % 4) 1.0

def foldScores : List Float → Float
  | [] => 0
  | x :: xs => xs.foldl (· + ·) x

partial def scoreAt (st : St) (N : Nat) (avg : Float) (n : ANode) (d : Nat) : Float :=
  match n with
  | .leaf false _ w _ c => contribF avg (st.weights.getD w 1.0) (idfF N c) 1 (docLength d)
  | .leaf true k w _ c =>
    let f := ((posting st k d).map (·.freq)).getD 0
    contribF avg (st.weights.getD w 1.0) (idfF N c) f (docLength d)
  | .inter kids _ _ =>
    let sorted := kids.mergeSort fun a b => a.cost ≤ b.cost
    1.0 * foldScores ((sorted.filter (·.has d)).map fun c => scoreAt st N avg c d)
  | .uni first kids _ _ =>
    let m := kids.filter (·.has d)
    if m.isEmpty then 0
    else if first then 1.0 * scoreAt st N avg (m.getD 0 (.leaf false 0 0 [] 0)) d
    else 1.0 * foldScores (m.map fun c => scoreAt st N avg c d)
  | .diff a _ _ _ => scoreAt st N avg a d
  | .phrase _ _ kids _ _ => 1.0 * foldScores (kids.map fun c => scoreAt st N avg c d)

def domLabel (a b : Nat × List Nat) : Bool := b.1 ≤ a.1 && b.2.all (a.2.contains ·)

def visOf (st : St) (i : Nat) : Bool := i < st.built && domLabel st.reader (st.table.getD i (0, []))

def errText : SErr → String
  | .ok => "ok"
  | .overflow => "overflow"
  | .underflow => "underflow"
  | .invalid => "invalid"

def canonLabel (lv : Nat) (cs : List Nat) : Nat × List Nat := (lv, (cs.mergeSort (· ≤ ·)).eraseDups)

def rrfF (c : Float) (window : Int) (branches : List (List Nat)) : List (Nat × Float) :=
  let parts : List (Nat × Nat × Float) := branches.zipIdx.flatMap fun (b, bi) =>
    let n := if window ≤ 0 then b.length else min b.length window.toNat
    (b.take n).zipIdx.map fun (d, r) => (d, bi, 1.0 / (c + (r + 1).toFloat))
  let sorted := parts.mergeSort fun x y => x.1 < y.1 || (x.1 == y.1 && x.2.1 ≤ y.2.1)
  let docs := (sorted.map (·.1)).eraseDups
  let fused := docs.map fun d => (d, foldScores ((sorted.filter (·.1 == d)).map (·.2.2)))
  fused.mergeSort fun x y => x.2 > y.2 || (x.2 == y.2 && x.1 ≤ y.1)

def topK (k : Int) (items : List (Nat × Float)) : List (Nat × Float) × Float :=
  if k ≤ 0 then ([], Float.ofBits 0x7FF0000000000000)
  else
    let sorted := items.mergeSort fun x y => x.2 > y.2 || (x.2 == y.2 && x.1 ≤ y.1)
    let best := sorted.take k.toNat
    let thr := if best.length < k.toNat then Float.ofBits 0xFFF0000000000000 else (best.getLast?.map (·.2)).getD 0
    (best, thr)

def rankedText (xs : List (Nat × Float)) : String := joinOr (xs.map fun p => s!"{p.1}:{fbits p.2}")

def step (st : St) (f : List String) : Except String (St × String) := do
  match f with
  | ["SE", v] =>
    let vs ← parseNats v
    let enc := encode vs
    let lenText := match encodedLength enc vs.length with | some n => toString n | none => "-1"
    let r := decode (enc ++ List.replicate 16 0) vs.length
    return (st, s!"SE|{hexBytes enc}|{enc.length}|{lenText}|{natsText r.1}|{natsText r.1}|{r.2}|{r.2}")
  | ["SD", p, v] =>
    let prev ← parseNat p
    let vs ← parseNats v
    let enc := encodeDelta vs prev
    let r := decodeDelta (enc ++ List.replicate 16 0) vs.length prev
    return (st, s!"SD|{hexBytes enc}|{enc.length}|{natsText r.1}|{natsText r.1}|{r.2}|{r.2}")
  | ["SX", n, h] =>
    let n ← parseNat n
    let data ← unhex h
    let lenText := match encodedLength data n with | some k => toString k | none => "-1"
    let r := decode data n
    return (st, s!"SX|{lenText}|{natsText r.1}|{natsText r.1}|{r.2}|{r.2}")
  | ["SW", v] =>
    let vs ← parseNats v
    return (st, s!"SW|{hexBytes (encode vs)}|{(encode vs).length}")
  | ["QA", a, b] =>
    let x ← parseNats a
    let y ← parseNats b
    return (st, s!"QA|{natsText (intersectRef x y)}|{natsText (intersectMerge x y)}|{natsText (intersectGallop x y)}|" ++
      s!"{natsText (intersectGallop y x)}|{natsText (intersect x y)}|{natsText (intersectMerge x y)}|{intersectCount x y}|" ++
      s!"{natsText (unionMerge x y)}|{natsText (differenceMerge x y)}|{bit (isStrict x)}")
  | ["QB", a, t, fr] =>
    let x ← parseNats a
    let t ← parseNat t
    let fr ← parseNat fr
    return (st, s!"QB|{lowerBound x t}|{upperBound x t}|{gallop x fr t}")
  | ["RX", r] =>
    let r ← parseNat r
    return ({ st with bitmaps := st.bitmaps.set! r [] }, "RX")
  | ["RA", r, x] =>
    let r ← parseNat r
    let res := add (st.bitmaps.getD r []) (← parseNat x)
    return ({ st with bitmaps := st.bitmaps.set! r res.1 }, s!"RA|{bit res.2}")
  | ["RR", r, x] =>
    let r ← parseNat r
    let res := remove (st.bitmaps.getD r []) (← parseNat x)
    return ({ st with bitmaps := st.bitmaps.set! r res.1 }, s!"RR|{bit res.2}")
  | ["RC", r, x] =>
    let r ← parseNat r
    return (st, s!"RC|{bit (contains (st.bitmaps.getD r []) (← parseNat x))}")
  | ["RF", r, s, c, d] =>
    let r ← parseNat r
    let s ← parseNat s
    let c ← parseNat c
    let d ← parseNat d
    let b := (List.range c).foldl (fun acc i => (add acc (s + i * d)).1) (st.bitmaps.getD r [])
    return ({ st with bitmaps := st.bitmaps.set! r b }, s!"RF|{cardinality b}")
  | ["RO", o, a, b, out] =>
    let op : Op := if o == "or" then .or else if o == "andnot" then .andnot else .and
    let res := combine op (st.bitmaps.getD (← parseNat a) []) (st.bitmaps.getD (← parseNat b) [])
    let out ← parseNat out
    return ({ st with bitmaps := st.bitmaps.set! out res }, s!"RO|{describe res}")
  | ["RN", a, b] =>
    return (st, s!"RN|{andCardinality (st.bitmaps.getD (← parseNat a) []) (st.bitmaps.getD (← parseNat b) [])}")
  | ["RP", r] =>
    let r ← parseNat r
    let res := runOptimize (st.bitmaps.getD r [])
    return ({ st with bitmaps := st.bitmaps.set! r res.1 }, s!"RP|{bit res.2}|{describe res.1}")
  | ["RS", r] => return (st, s!"RS|{hexBytes (serialize (st.bitmaps.getD (← parseNat r) []))}")
  | ["RD", h] =>
    match deserialize (← unhex h) with
    | some (b, used) => return (st, s!"RD|{used}|{describe b}")
    | none => return (st, "RD|invalid")
  | ["RL", r] => return (st, s!"RL|{describe (st.bitmaps.getD (← parseNat r) [])}")
  | ["RE", a, b] => return (st, s!"RE|{bit (bmEqual (st.bitmaps.getD (← parseNat a) []) (st.bitmaps.getD (← parseNat b) []))}")
  | ["RT", r, ops] => return (st, s!"RT|{← iterRun (contents (st.bitmaps.getD (← parseNat r) [])) (ops.splitOn ",")}")
  | ["AR", k, v] => return ({ st with arrays := st.arrays.set! (← parseNat k) (← parseNats v) }, "AR")
  | ["DL", v] => return ({ st with deleted := ← parseNats v }, "DL")
  | ["RQ", h] => return ({ st with required := ← parseHexNat h }, "RQ")
  | ["WT", v] =>
    let ws ← (v.splitOn ",").mapM fun x => do return Float.ofBits (← parseHexNat x).toUInt64
    return ({ st with weights := ws }, "WT")
  | ["PL", k, t, p] =>
    let k ← parseNat k
    let t ← parseNat t
    let words := min 4 (max 1 ((t + 31) / 32))
    return ({ st with lists := st.lists.set! k ⟨words, p == "1", []⟩ }, s!"PL|{words}")
  | ["PA", k, d, fr, m, c, p] =>
    let k ← parseNat k
    let l := st.lists.getD k ⟨1, true, []⟩
    let post : Posting := ⟨← parseNat d, ← parseNat fr, ← parseHexNat m, ← parseNats c, ← parseNats p⟩
    let e := validate l post
    let l' := if e == "ok" then { l with items := l.items ++ [post] } else l
    let n := l'.items.length
    return ({ st with lists := st.lists.set! k l' }, s!"PA|{e}|{n}|{n / 128}|{n % 128}")
  | ["PC", k] =>
    let l := st.lists.getD (← parseNat k) ⟨1, true, []⟩
    let acc := l.items.filter fun p => p.doc ∉ st.deleted ∧ (st.required = 0 ∨ p.mask &&& st.required ≠ 0)
    let rows := acc.map fun p => s!"{p.doc}:{p.freq}:{hexNat p.mask}:{natsText (if l.pos then p.positions else [])}"
    return (st, s!"PC|{if rows.isEmpty then "-" else String.intercalate ";" rows}")
  | ["PV", k, ts] =>
    let l := st.lists.getD (← parseNat k) ⟨1, true, []⟩
    let docs := (l.items.filter fun p => p.doc ∉ st.deleted ∧ (st.required = 0 ∨ p.mask &&& st.required ≠ 0)).map (·.doc)
    let targets ← parseNats ts
    let mut cur : Nat := 0
    let mut out : List String := []
    for t in targets do
      if cur ≠ 0 ∧ cur ≥ t then out := out ++ [if cur == endDoc then "-" else toString cur]
      else
        cur := ((docs.find? (· ≥ t)).getD endDoc)
        out := out ++ [if cur == endDoc then "-" else toString cur]
    return (st, s!"PV|{joinOr out}")
  | ["PK", k] =>
    let k ← parseNat k
    let l := st.lists.getD k ⟨1, true, []⟩
    let gone := l.items.filter fun p => p.doc ∈ st.deleted
    let kept := l.items.filter fun p => p.doc ∉ st.deleted
    return ({ st with lists := st.lists.set! k { l with items := kept } },
      s!"PK|{gone.length}|{natsText (gone.map (·.doc))}|{kept.length}")
  | ["PW", _, s, g] =>
    let slop ← parseInt s
    let lists ← (g.splitOn ";").mapM parseNats
    return (st, s!"PW|{bit (orderedWindow lists slop)}|{bit (unorderedWindow lists slop)}")
  | ["T", t] =>
    let (n, _) ← parseNode t.toList
    return (st, s!"T|{natsText (annotate st n).set}")
  | ["TP", t] =>
    let (n, _) ← parseNode t.toList
    return (st, s!"TP|{natsText (annotate st n).set}")
  | ["TA", t, ts] =>
    let (n, _) ← parseNode t.toList
    let docs := (annotate st n).set
    let targets ← parseNats ts
    let mut cur : Nat := 0
    let mut out : List String := []
    for t in targets do
      if cur ≠ 0 ∧ cur ≥ t then out := out ++ [if cur == endDoc then "-" else toString cur]
      else
        cur := ((docs.find? (· ≥ t)).getD endDoc)
        out := out ++ [if cur == endDoc then "-" else toString cur]
    return (st, s!"TA|{joinOr out}")
  | ["TS", N, tl, t] =>
    let N ← parseNat N
    let tl ← parseNat tl
    let (n, _) ← parseNode t.toList
    let avg : Float := if N > 0 then tl.toFloat / N.toFloat else 0
    let a := annotate st n
    let rows := a.set.map fun d => s!"{d}:{fbits (scoreAt st N avg a d * docScore d)}"
    return (st, s!"TS|{joinOr rows}")
  | ["LB", lv, cs] =>
    let l := canonLabel (← parseNat lv) (← parseNats cs)
    match st.table.findIdx? (· == l) with
    | some i => return (st, s!"LB|{i}")
    | none => return ({ st with table := st.table ++ [l] }, s!"LB|{st.table.length}")
  | ["LV", lv, cs] =>
    let l := canonLabel (← parseNat lv) (← parseNats cs)
    return ({ st with reader := l, built := st.table.length }, s!"LV|{st.table.length}")
  | ["SA", t, l, d] =>
    let t ← parseNat t
    let l ← parseNat l
    let r := termAdd st.stats t l (← parseNat d)
    return ({ st with stats := r.1 }, s!"SA|{errText r.2}|{termTotalP (termOf r.1 t)}|{termCount r.1 t l}")
  | ["SR", t, l, d] =>
    let t ← parseNat t
    let l ← parseNat l
    let r := termRemove st.stats t l (← parseNat d)
    return ({ st with stats := r.1 }, s!"SR|{errText r.2}|{termTotalP (termOf r.1 t)}|{termCount r.1 t l}")
  | ["SF", t] =>
    let t ← parseNat t
    let s := termForget st.stats t
    return ({ st with stats := s }, s!"SF|{termTotalP (termOf s t)}")
  | ["DA", l, n] =>
    let r := documentAdd st.stats (← parseNat l) (← parseNat n)
    return ({ st with stats := r.1 }, s!"DA|{errText r.2}|{r.1.docs.total}|{r.1.lens.total}")
  | ["DX", l, n] =>
    let r := documentRemove st.stats (← parseNat l) (← parseNat n)
    return ({ st with stats := r.1 }, s!"DX|{errText r.2}|{r.1.docs.total}|{r.1.lens.total}")
  | ["SV", t] =>
    let t ← parseNat t
    return (st, s!"SV|{termVisible st.stats t (visOf st)}|{termTotalP (termOf st.stats t)}")
  | ["ST"] =>
    let v := visibleTotals st.stats (visOf st)
    return (st, s!"ST|{v.1}|{v.2}|{st.stats.docs.total}|{st.stats.lens.total}")
  | ["BI", N, n] => return (st, s!"BI|{fbits (idfF (← parseNat N) (← parseNat n))}")
  | ["BM", N, tl, n, w, fr, dl, sc] =>
    let N ← parseNat N
    let tl ← parseNat tl
    let prepared := idfF N (← parseNat n)
    let avg : Float := if N > 0 then tl.toFloat / N.toFloat else 0
    let c := contribF avg (Float.ofBits (← parseHexNat w).toUInt64) prepared (← parseNat fr) (← parseNat dl)
    let final := c * Float.ofBits (← parseHexNat sc).toUInt64
    return (st, s!"BM|{fbits prepared}|{fbits avg}|{fbits c}|{fbits final}")
  | ["FU", c, w, g] =>
    let branches ← (g.splitOn ";").mapM parseNats
    return (st, s!"FU|{rankedText (rrfF (Float.ofBits (← parseHexNat c).toUInt64) (← parseInt w) branches)}")
  | ["TK", k, items] =>
    let k ← parseInt k
    let its ← (if items == "-" then pure [] else (items.splitOn ",").mapM fun it => do
      match it.splitOn ":" with
      | [d, b] => return ((← parseNat d), Float.ofBits (← parseHexNat b).toUInt64)
      | _ => throw "bad item")
    let r := topK k its
    return (st, s!"TK|{its.length}|{rankedText r.1}|{fbits r.2}")
  | _ => throw ("unknown case " ++ String.intercalate " " f)

def main (args : List String) : IO Unit := do
  let [path] := args | throw (IO.userError "expected case path")
  let input ← IO.FS.readFile path
  let out ← IO.getStdout
  let mut st : St := {}
  for line in input.splitOn "\n" do
    if line.isEmpty then continue
    let (next, row) ← expect (step st (line.splitOn " "))
    st := next
    out.putStrLn row
