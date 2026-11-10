import Queries.Tree
import Queries.Lexer

namespace Queries

inductive Rule where
  | none
  | orR
  | andR
  | notR
  | optR
deriving Repr

def rulePower (d : Nat) : Rule → Nat
  | .none => 0
  | .orR => if d < 2 then 40 else 10
  | .andR => if d < 2 then 30 else 20
  | .notR => 20
  | .optR => if d < 2 then 10 else 20

def tokPower (d : Nat) : Kind → Nat
  | .tilde => if d < 2 then 10 else 20
  | .minus => 20
  | .term => if d < 2 then 30 else 20
  | .stop => if d < 2 then 30 else 20
  | .lp => if d < 2 then 30 else 20
  | .pre => 30
  | .suf => 30
  | .inf => 30
  | .orK => if d < 2 then 40 else 10
  | _ => 0

def endTk : Tk := ⟨.finish, 0, [], []⟩

def peek (ts : List Tk) : Tk := ts.headD endTk

def adv : List Tk → List Tk
  | t :: rest => if t.kind = .finish then t :: rest else rest
  | [] => []

structure Err where
  pos : Nat
  near : List Nat
deriving Repr

abbrev R := Except Err (Node × List Tk)

def errAt (t : Tk) : Err := ⟨t.pos, t.near⟩

def termRun : List Tk → List Node × List Tk
  | t :: rest => if t.kind = .term then ((termRun rest).1.cons (.tok t.text), (termRun rest).2) else ([], t :: rest)
  | [] => ([], [])

mutual
def expr (d : Nat) : Nat → Rule → List Tk → R
  | 0, _, ts => .error (errAt (peek ts))
  | f + 1, rule, ts =>
    match unary d f ts with
    | .error e => .error e
    | .ok (left, ts') => loop d f (rulePower d rule) left ts'

def loop (d : Nat) : Nat → Nat → Node → List Tk → R
  | 0, _, _, ts => .error (errAt (peek ts))
  | f + 1, rbp, left, ts =>
    if tokPower d (peek ts).kind ≤ rbp then .ok (left, ts)
    else if (peek ts).kind = .orK then
      if 2 ≤ d then
        match chain d f left (adv ts) with
        | .error e => .error e
        | .ok (l, ts') => loop d f rbp l ts'
      else
        match expr d f .orR (adv ts) with
        | .error e => .error e
        | .ok (right, ts') => loop d f rbp (mkOr d left right) ts'
    else
      match expr d f .andR ts with
      | .error e => .error e
      | .ok (right, ts') => loop d f rbp (mkAnd d left right) ts'

def chain (d : Nat) : Nat → Node → List Tk → R
  | 0, _, ts => .error (errAt (peek ts))
  | f + 1, first, ts =>
    match expr d f .orR ts with
    | .error e => .error e
    | .ok (second, ts') => chainRest d f (mkOr d first second) ts'

def chainRest (d : Nat) : Nat → Node → List Tk → R
  | 0, _, ts => .error (errAt (peek ts))
  | f + 1, result, ts =>
    if (peek ts).kind = .orK then
      match expr d f .orR (adv ts) with
      | .error e => .error e
      | .ok (next, ts') => chainRest d f (mkOr d result next) ts'
    else .ok (result, ts)

def unary (d : Nat) : Nat → List Tk → R
  | 0, ts => .error (errAt (peek ts))
  | f + 1, ts =>
    match (peek ts).kind with
    | .minus =>
      match expr d f .notR (adv ts) with
      | .error e => .error e
      | .ok (c, ts') => .ok (mkNot c, ts')
    | .tilde =>
      match expr d f .optR (adv ts) with
      | .error e => .error e
      | .ok (c, ts') => .ok (mkOpt c, ts')
    | .lp =>
      match expr d f .none (adv ts) with
      | .error e => .error e
      | .ok (inner, ts') => if (peek ts').kind = .rp then .ok (inner, adv ts') else .error (errAt (peek ts'))
    | .term =>
      if d < 2 ∧ (peek (adv ts)).kind = .term then
        .ok (.inter (.tok (peek ts).text :: (termRun (adv ts)).1), (termRun (adv ts)).2)
      else .ok (.tok (peek ts).text, adv ts)
    | .stop => .ok (.null, adv ts)
    | .pre => .ok (.pre (peek ts).text, adv ts)
    | .suf => .ok (.suf (peek ts).text, adv ts)
    | .inf => .ok (.inf (peek ts).text, adv ts)
    | _ => .error (errAt (peek ts))
end

def parseTokens (d : Nat) (ts : List Tk) : Except Err Node :=
  if (peek ts).kind = .finish then .ok .null
  else match expr d (4 * ts.length + 8) .none ts with
    | .error e => .error e
    | .ok (root, rest) => if (peek rest).kind = .finish then .ok root else .error (errAt (peek rest))

inductive Outcome where
  | tree (n : Node)
  | failure (e : Err)
  | unsupported
deriving Repr

def parseQuery (d : Nat) (q : List Nat) : Outcome :=
  if (lex q).any (·.kind = .unsupported) then .unsupported
  else match parseTokens d (lex q) with
    | .ok n => .tree n
    | .error e => .failure e

def treeOf : Outcome → Option Node
  | .tree n => some n
  | _ => none

def errOf : Outcome → Option Err
  | .failure e => some e
  | _ => none

theorem rulePower_none (d : Nat) (k : Kind) : rulePower d .none ≤ tokPower d k := Nat.zero_le _

theorem or_weakest_two (d : Nat) (hd : 2 ≤ d) (k : Kind) (hk : k ≠ .finish ∧ k ≠ .rp ∧ k ≠ .unsupported) :
    tokPower d .orK ≤ tokPower d k := by
  cases k <;> simp [tokPower, Nat.not_lt.mpr hd] at hk ⊢

theorem or_strongest_one (d : Nat) (hd : d < 2) (k : Kind) : tokPower d k ≤ tokPower d .orK := by
  cases k <;> simp [tokPower, hd]

theorem patterns_bind_tighter_two (d : Nat) (hd : 2 ≤ d) :
    rulePower d .andR < tokPower d .pre ∧ rulePower d .andR < tokPower d .suf ∧ rulePower d .andR < tokPower d .inf ∧
      tokPower d .term ≤ rulePower d .andR := by
  simp [rulePower, tokPower, Nat.not_lt.mpr hd]

theorem negation_scope_one (d : Nat) (hd : d < 2) : rulePower d .notR < tokPower d .term ∧ rulePower d .optR < tokPower d .minus := by
  simp [rulePower, tokPower, hd]

end Queries
