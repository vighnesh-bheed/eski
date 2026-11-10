namespace Queries

inductive Node where
  | null
  | tok (s : List Nat)
  | pre (s : List Nat)
  | suf (s : List Nat)
  | inf (s : List Nat)
  | union (cs : List Node)
  | inter (cs : List Node)
  | neg (c : Node)
  | opt (c : Node)
deriving Repr, Inhabited

def Node.isNull : Node → Bool
  | .null => true
  | _ => false

def mkAnd (d : Nat) (l r : Node) : Node :=
  if l.isNull then r
  else if r.isNull then l
  else match l with
    | .inter cs => .inter (cs ++ [r])
    | _ => match r with
      | .inter cs => if 2 ≤ d then .inter (cs ++ [l]) else .inter [l, r]
      | _ => .inter [l, r]

def mkOr (d : Nat) (l r : Node) : Node :=
  if l.isNull then r
  else if r.isNull then l
  else match l with
    | .union cs => .union (cs ++ [r])
    | _ => match r with
      | .union cs => if 2 ≤ d then .union (cs ++ [l]) else .union [l, r]
      | _ => .union [l, r]

def mkNot : Node → Node
  | .null => .null
  | .neg c => c
  | c => .neg c

def mkOpt : Node → Node
  | .null => .null
  | c => .opt c

structure Doc where
  has : List Nat → Bool
  hasPre : List Nat → Bool
  hasSuf : List Nat → Bool
  hasInf : List Nat → Bool

mutual
def den (x : Doc) : Node → Bool
  | .null => true
  | .tok s => x.has s
  | .pre s => x.hasPre s
  | .suf s => x.hasSuf s
  | .inf s => x.hasInf s
  | .union cs => denAny x cs
  | .inter cs => denAll x cs
  | .neg c => !den x c
  | .opt _ => true

def denAny (x : Doc) : List Node → Bool
  | [] => false
  | c :: cs => den x c || denAny x cs

def denAll (x : Doc) : List Node → Bool
  | [] => true
  | c :: cs => den x c && denAll x cs
end

theorem denAll_append (x : Doc) : ∀ (cs ds : List Node), denAll x (cs ++ ds) = (denAll x cs && denAll x ds)
  | [], ds => by simp [denAll]
  | c :: cs, ds => by
    simp only [List.cons_append, denAll]
    rw [denAll_append x cs ds, Bool.and_assoc]

theorem denAny_append (x : Doc) : ∀ (cs ds : List Node), denAny x (cs ++ ds) = (denAny x cs || denAny x ds)
  | [], ds => by simp [denAny]
  | c :: cs, ds => by
    simp only [List.cons_append, denAny]
    rw [denAny_append x cs ds, Bool.or_assoc]

theorem mkAnd_null_left (d : Nat) (r : Node) : mkAnd d .null r = r := by simp [mkAnd, Node.isNull]

theorem mkAnd_null_right (d : Nat) (l : Node) : mkAnd d l .null = l := by
  cases l <;> simp [mkAnd, Node.isNull]

theorem mkOr_null_left (d : Nat) (r : Node) : mkOr d .null r = r := by simp [mkOr, Node.isNull]

theorem mkOr_null_right (d : Nat) (l : Node) : mkOr d l .null = l := by
  cases l <;> simp [mkOr, Node.isNull]

theorem mkAnd_den (d : Nat) (x : Doc) (l r : Node) (hl : l.isNull = false) (hr : r.isNull = false) :
    den x (mkAnd d l r) = (den x l && den x r) := by
  unfold mkAnd
  simp only [hl, hr, Bool.false_eq_true, ↓reduceIte]
  split
  · simp only [den, denAll_append, denAll, Bool.and_true]
  · split
    · split
      · simp only [den, denAll_append, denAll, Bool.and_true]
        exact Bool.and_comm _ _
      · simp [den, denAll]
    · simp [den, denAll]

theorem mkOr_den (d : Nat) (x : Doc) (l r : Node) (hl : l.isNull = false) (hr : r.isNull = false) :
    den x (mkOr d l r) = (den x l || den x r) := by
  unfold mkOr
  simp only [hl, hr, Bool.false_eq_true, ↓reduceIte]
  split
  · simp only [den, denAny_append, denAny, Bool.or_false]
  · split
    · split
      · simp only [den, denAny_append, denAny, Bool.or_false]
        exact Bool.or_comm _ _
      · simp [den, denAny]
    · simp [den, denAny]

theorem mkNot_den (x : Doc) (c : Node) (hc : c.isNull = false) : den x (mkNot c) = !den x c := by
  cases c <;> simp_all [mkNot, den, Node.isNull]

theorem mkNot_null (c : Node) : (mkNot c).isNull = c.isNull ∨ ∃ c', c = .neg c' := by
  cases c <;> simp [mkNot, Node.isNull]

theorem mkOpt_den (x : Doc) (c : Node) : den x (mkOpt c) = true := by
  cases c <;> simp [mkOpt, den]

theorem mkAnd_ne_null (d : Nat) (l r : Node) (hl : l.isNull = false) (hr : r.isNull = false) : (mkAnd d l r).isNull = false := by
  unfold mkAnd
  simp only [hl, hr, Bool.false_eq_true, ↓reduceIte]
  split
  · rfl
  · split
    · split <;> rfl
    · rfl

theorem mkOr_ne_null (d : Nat) (l r : Node) (hl : l.isNull = false) (hr : r.isNull = false) : (mkOr d l r).isNull = false := by
  unfold mkOr
  simp only [hl, hr, Bool.false_eq_true, ↓reduceIte]
  split
  · rfl
  · split
    · split <;> rfl
    · rfl

theorem mkAnd_left_flat (d : Nat) (cs : List Node) (r : Node) (hr : r.isNull = false) :
    mkAnd d (.inter cs) r = .inter (cs ++ [r]) := by
  unfold mkAnd
  have h1 : (Node.inter cs).isNull = false := rfl
  rw [h1, hr]
  simp

theorem mkAnd_right_merge_two (d : Nat) (l : Node) (cs : List Node) (hd : 2 ≤ d) (hl : l.isNull = false)
    (hn : ∀ ds, l ≠ .inter ds) : mkAnd d l (.inter cs) = .inter (cs ++ [l]) := by
  cases l with
  | null => simp [Node.isNull] at hl
  | inter ds => exact absurd rfl (hn ds)
  | _ => simp [mkAnd, Node.isNull, hd]

theorem mkAnd_right_nested_one (l : Node) (cs : List Node) (hl : l.isNull = false) (hn : ∀ ds, l ≠ .inter ds) :
    mkAnd 1 l (.inter cs) = .inter [l, .inter cs] := by
  cases l with
  | null => simp [Node.isNull] at hl
  | inter ds => exact absurd rfl (hn ds)
  | _ => simp [mkAnd, Node.isNull]

theorem mkOr_right_merge_two (d : Nat) (l : Node) (cs : List Node) (hd : 2 ≤ d) (hl : l.isNull = false)
    (hn : ∀ ds, l ≠ .union ds) : mkOr d l (.union cs) = .union (cs ++ [l]) := by
  cases l with
  | null => simp [Node.isNull] at hl
  | union ds => exact absurd rfl (hn ds)
  | _ => simp [mkOr, Node.isNull, hd]

end Queries
