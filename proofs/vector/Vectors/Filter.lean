namespace Vectors

inductive FOp
  | push | load | not | pow | mul | div | mod | add | sub | gt | ge | lt | le | eq | ne | inOp | and | or
deriving DecidableEq, Repr

structure Instr where
  op : FOp
  arg : Nat
deriving DecidableEq, Repr

structure Program (V F : Type) where
  code : List Instr
  constants : List V
  fields : List F
  depth : Nat
  constant : Bool
  result : Bool

structure Semantics (V F B : Type) where
  truthy : V → Bool
  boolValue : Bool → V
  apply : FOp → V → V → V
  lookup : B → F → Option V
  dflt : V
  dfltField : F

inductive Outcome (V : Type)
  | missing
  | fault
  | done (stack : List V)

def arity : FOp → Nat
  | .push => 0
  | .load => 0
  | .not => 1
  | _ => 2

def emitDepth : List Instr → Nat → Option Nat
  | [], d => some d
  | i :: rest, d => if d < arity i.op then none else emitDepth rest (d + 1 - arity i.op)

def maxDepth : List Instr → Nat → Nat
  | [], d => d
  | i :: rest, d => max d (maxDepth rest (d + 1 - arity i.op))

def parserAccepts (code : List Instr) : Prop := emitDepth code 0 = some 1

def stackCap {V F : Type} (p : Program V F) : Nat := if p.depth ≤ 64 then 64 else p.depth

section machine

variable {V F B : Type} (S : Semantics V F B) (p : Program V F) (blob : B) (cap : Nat)

def stepO (stack : List V) (ins : Instr) : Outcome V :=
  match ins.op with
  | .push => if stack.length < cap then .done ((p.constants[ins.arg]?.getD S.dflt) :: stack) else .fault
  | .load =>
    match S.lookup blob (p.fields[ins.arg]?.getD S.dfltField) with
    | none => .missing
    | some v => if stack.length < cap then .done (v :: stack) else .fault
  | .not =>
    match stack with
    | v :: rest => .done (S.boolValue (!S.truthy v) :: rest)
    | [] => .fault
  | op =>
    match stack with
    | b :: a :: rest => .done (S.apply op a b :: rest)
    | _ => .fault

def runO : List Instr → List V → Outcome V
  | [], st => .done st
  | i :: rest, st =>
    match stepO S p blob cap st i with
    | .done st' => runO rest st'
    | o => o

def execute : Bool :=
  match runO S p blob (stackCap p) p.code [] with
  | .done st => S.truthy (st.getLast?.getD S.dflt)
  | _ => false

def programRun (alloc : Bool) : Bool :=
  if p.code = [] ∨ p.depth = 0 then false
  else if p.depth ≤ 64 then execute S p blob
  else alloc && execute S p blob

end machine

def evaluate {V F B : Type} (S : Semantics V F B) (p : Program V F) (attr : Option B) (alloc : Bool) : Bool :=
  match attr with
  | none => false
  | some blob => if p.constant then p.result && !p.code.isEmpty else programRun S p blob alloc

def finishCompile {V F B : Type} (S : Semantics V F B) (nilBlob : B) (code : List Instr) (constants : List V)
    (fields : List F) (alloc : Bool) : Program V F :=
  let p : Program V F := ⟨code, constants, fields, maxDepth code 0, fields.isEmpty, false⟩
  if p.constant then { p with result := programRun S p nilBlob alloc } else p

def LoadsInRange {V F : Type} (p : Program V F) : Prop := ∀ i ∈ p.code, i.op = .load → i.arg < p.fields.length

def ReadsMissing {V F B : Type} (S : Semantics V F B) (p : Program V F) (blob : B) : Prop :=
  ∃ i ∈ p.code, i.op = .load ∧ S.lookup blob (p.fields[i.arg]?.getD S.dfltField) = none

theorem emit_step {i : Instr} {rest : List Instr} {d e : Nat} (h : emitDepth (i :: rest) d = some e) :
    arity i.op ≤ d ∧ emitDepth rest (d + 1 - arity i.op) = some e := by
  unfold emitDepth at h
  split at h
  · simp at h
  · exact ⟨by omega, h⟩

theorem maxDepth_ge (code : List Instr) (d : Nat) : d ≤ maxDepth code d := by
  cases code with
  | nil => simp [maxDepth]
  | cons i rest => simp only [maxDepth]; omega

theorem stepO_safe {V F B : Type} (S : Semantics V F B) (p : Program V F) (blob : B) (cap : Nat) (st : List V)
    (i : Instr) (ha : arity i.op ≤ st.length) (hc : st.length + 1 - arity i.op ≤ cap) :
    stepO S p blob cap st i = .missing ∨
      ∃ st', stepO S p blob cap st i = .done st' ∧ st'.length = st.length + 1 - arity i.op := by
  unfold stepO
  cases hop : i.op <;> simp only [arity, hop] at ha hc ⊢
  · rw [ite_eq_left (by omega)]; exact Or.inr ⟨_, rfl, by simp⟩
  · cases S.lookup blob (p.fields[i.arg]?.getD S.dfltField) with
    | none => exact Or.inl rfl
    | some v => simp only; rw [ite_eq_left (by omega)]; exact Or.inr ⟨_, rfl, by simp⟩
  · cases st with
    | nil => simp at ha
    | cons v tl => exact Or.inr ⟨_, rfl, by simp⟩
  all_goals
    cases st with
    | nil => simp at ha
    | cons b tl =>
      cases tl with
      | nil => simp at ha
      | cons a tl => exact Or.inr ⟨_, rfl, by simp⟩

theorem runO_safe {V F B : Type} (S : Semantics V F B) (p : Program V F) (blob : B) (cap : Nat) :
    ∀ (code : List Instr) (st : List V) (e : Nat), emitDepth code st.length = some e → maxDepth code st.length ≤ cap →
      (runO S p blob cap code st = .missing ∨ ∃ st', runO S p blob cap code st = .done st' ∧ st'.length = e) := by
  intro code
  induction code with
  | nil =>
    intro st e he _
    simp only [emitDepth, Option.some.injEq] at he
    exact Or.inr ⟨st, rfl, he⟩
  | cons i rest ih =>
    intro st e he hm
    obtain ⟨ha, hr⟩ := emit_step he
    simp only [maxDepth] at hm
    have hd := maxDepth_ge rest (st.length + 1 - arity i.op)
    unfold runO
    rcases stepO_safe S p blob cap st i ha (by omega) with h | ⟨st', h, hl⟩
    · rw [h]; exact Or.inl rfl
    · rw [h]
      simp only
      exact ih st' e (by rw [hl]; exact hr) (by rw [hl]; omega)

theorem accepted_never_faults {V F B : Type} (S : Semantics V F B) (p : Program V F) (blob : B)
    (hacc : parserAccepts p.code) (hdepth : p.depth = maxDepth p.code 0) :
    runO S p blob (stackCap p) p.code [] = .missing ∨
      ∃ st, runO S p blob (stackCap p) p.code [] = .done st ∧ st.length = 1 := by
  apply runO_safe S p blob (stackCap p) p.code [] 1 hacc
  show maxDepth p.code 0 ≤ stackCap p
  unfold stackCap
  split <;> omega

theorem runO_missing {V F B : Type} (S : Semantics V F B) (p : Program V F) (blob : B) (cap : Nat) :
    ∀ (code : List Instr) (st : List V),
      (∃ i ∈ code, i.op = .load ∧ S.lookup blob (p.fields[i.arg]?.getD S.dfltField) = none) →
      runO S p blob cap code st = .missing ∨ runO S p blob cap code st = .fault := by
  intro code
  induction code with
  | nil => intro st h; simp at h
  | cons i rest ih =>
    intro st h
    obtain ⟨j, hj, hl, hn⟩ := h
    unfold runO
    rcases List.mem_cons.mp hj with hj | hj
    · subst hj
      have : stepO S p blob cap st j = .missing := by unfold stepO; simp [hl, hn]
      rw [this]; exact Or.inl rfl
    · cases hs : stepO S p blob cap st i with
      | done st' => exact ih st' ⟨j, hj, hl, hn⟩
      | missing => exact Or.inl rfl
      | fault => exact Or.inr rfl

theorem missing_field_fails {V F B : Type} (S : Semantics V F B) (p : Program V F) (blob : B)
    (hmiss : ReadsMissing S p blob) : execute S p blob = false := by
  unfold execute
  rcases runO_missing S p blob (stackCap p) p.code [] hmiss with h | h <;> rw [h]

theorem missing_field_run {V F B : Type} (S : Semantics V F B) (p : Program V F) (blob : B) (alloc : Bool)
    (hmiss : ReadsMissing S p blob) : programRun S p blob alloc = false := by
  unfold programRun
  rw [missing_field_fails S p blob hmiss]
  split
  · rfl
  · split <;> simp

theorem missing_field_evaluate {V F B : Type} (S : Semantics V F B) (p : Program V F) (blob : B) (alloc : Bool)
    (hloads : LoadsInRange p) (hconst : p.constant = p.fields.isEmpty) (hmiss : ReadsMissing S p blob) :
    evaluate S p (some blob) alloc = false := by
  obtain ⟨i, hi, hl, _⟩ := hmiss
  have hf : p.fields ≠ [] := fun he => by have := hloads i hi hl; rw [he] at this; simp at this
  have hc : p.constant = false := by rw [hconst]; cases hfs : p.fields with
    | nil => exact absurd hfs hf
    | cons _ _ => rfl
  unfold evaluate
  simp only [hc, Bool.false_eq_true, ite_false]
  exact missing_field_run S p blob alloc ⟨i, hi, hl, by assumption⟩

theorem runO_blob_free {V F B : Type} (S : Semantics V F B) (p : Program V F) (b1 b2 : B) (cap : Nat) :
    ∀ (code : List Instr) (st : List V), (∀ i ∈ code, i.op ≠ .load) →
      runO S p b1 cap code st = runO S p b2 cap code st := by
  intro code
  induction code with
  | nil => intro st _; rfl
  | cons i rest ih =>
    intro st h
    have hi : i.op ≠ .load := h i (by simp)
    have hr : ∀ j ∈ rest, j.op ≠ .load := fun j hj => h j (by simp [hj])
    have hs : stepO S p b1 cap st i = stepO S p b2 cap st i := by
      unfold stepO
      cases hop : i.op <;> simp_all
    unfold runO
    rw [hs]
    cases stepO S p b2 cap st i with
    | done st' => exact ih st' hr
    | missing => rfl
    | fault => rfl

theorem runO_congr {V F B : Type} (S : Semantics V F B) (p1 p2 : Program V F) (b : B) (cap : Nat)
    (hc : p1.constants = p2.constants) (hf : p1.fields = p2.fields) :
    ∀ (code : List Instr) (st : List V), runO S p1 b cap code st = runO S p2 b cap code st := by
  intro code
  induction code with
  | nil => intro st; rfl
  | cons i rest ih =>
    intro st
    have hs : stepO S p1 b cap st i = stepO S p2 b cap st i := by unfold stepO; rw [hc, hf]
    unfold runO
    rw [hs]
    cases stepO S p2 b cap st i with
    | done st' => exact ih st'
    | missing => rfl
    | fault => rfl

theorem execute_congr {V F B : Type} (S : Semantics V F B) (p1 p2 : Program V F) (b : B)
    (hcode : p1.code = p2.code) (hc : p1.constants = p2.constants) (hf : p1.fields = p2.fields)
    (hd : p1.depth = p2.depth) : execute S p1 b = execute S p2 b := by
  unfold execute
  have hcap : stackCap p1 = stackCap p2 := by unfold stackCap; rw [hd]
  rw [hcap, hcode, runO_congr S p1 p2 b (stackCap p2) hc hf p2.code []]

theorem execute_blob_free {V F B : Type} (S : Semantics V F B) (p : Program V F) (b1 b2 : B)
    (h : ∀ i ∈ p.code, i.op ≠ .load) : execute S p b1 = execute S p b2 := by
  unfold execute
  rw [runO_blob_free S p b1 b2 (stackCap p) p.code [] h]

theorem programRun_congr {V F B : Type} (S : Semantics V F B) (p1 p2 : Program V F) (b : B) (alloc : Bool)
    (hcode : p1.code = p2.code) (hc : p1.constants = p2.constants) (hf : p1.fields = p2.fields)
    (hd : p1.depth = p2.depth) : programRun S p1 b alloc = programRun S p2 b alloc := by
  unfold programRun
  rw [execute_congr S p1 p2 b hcode hc hf hd, hcode, hd]

theorem constant_agrees {V F B : Type} (S : Semantics V F B) (nilBlob : B) (code : List Instr) (constants : List V)
    (fields : List F) (allocC : Bool) (blob : B) (allocR : Bool)
    (hloads : LoadsInRange (finishCompile S nilBlob code constants fields allocC))
    (halloc : maxDepth code 0 ≤ 64 ∨ allocC = allocR) :
    evaluate S (finishCompile S nilBlob code constants fields allocC) (some blob) allocR =
      programRun S (finishCompile S nilBlob code constants fields allocC) blob allocR := by
  unfold evaluate finishCompile
  cases hf : fields.isEmpty with
  | false => simp
  | true =>
    simp only [ite_true]
    have hnil : fields = [] := List.isEmpty_iff.mp hf
    have hnl : ∀ i ∈ code, i.op ≠ .load := by
      intro i hi hl
      have := hloads i (by unfold finishCompile; simp [hf, hi]) hl
      unfold finishCompile at this; simp [hnil] at this
    let p0 : Program V F := ⟨code, constants, fields, maxDepth code 0, true, false⟩
    have hx := execute_blob_free S p0 nilBlob blob hnl
    rw [programRun_congr S ⟨code, constants, fields, maxDepth code 0, true, programRun S p0 nilBlob allocC⟩ p0 blob
      allocR rfl rfl rfl rfl]
    show (programRun S p0 nilBlob allocC && !code.isEmpty) = programRun S p0 blob allocR
    unfold programRun
    rw [hx]
    by_cases hc : p0.code = [] ∨ p0.depth = 0
    · simp [hc]
    · have hne : code ≠ [] := fun e => hc (Or.inl e)
      have hcode : (!code.isEmpty) = true := by simp [hne]
      simp only [hc, ite_false]
      split
      · simp [hcode]
      · next hd =>
        rcases halloc with h | h
        · exact absurd h hd
        · rw [h]; simp [hcode]

end Vectors
