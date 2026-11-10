import Labels.Lattice

namespace Labels

def markingMax : Nat := 32768

def nameMax : Nat := 64

def levelLimit : Nat := 256

def compLimit : Nat := 256

def isWs (b : Nat) : Bool := b == 32 || b == 9

def foldUpper (b : Nat) : Nat := if 97 ≤ b ∧ b ≤ 122 then b - 32 else b

def markingByte (b : Nat) : Bool := b == 9 || (decide (32 ≤ b) && decide (b ≤ 126))

def nameByte (b : Nat) : Bool :=
  (decide (65 ≤ b) && decide (b ≤ 90)) || (decide (48 ≤ b) && decide (b ≤ 57)) || b == 45 || b == 95 || b == 32

def normStep (st : List Nat × Bool) (b : Nat) : List Nat × Bool :=
  if isWs b then (st.1, st.2 || !st.1.isEmpty)
  else (foldUpper b :: (if st.2 then 32 :: st.1 else st.1), false)

def normalise (raw : List Nat) : List Nat := (raw.foldl normStep ([], false)).1.reverse

def noDoubleSpace : List Nat → Bool
  | a :: b :: rest => !(a == 32 && b == 32) && noDoubleSpace (b :: rest)
  | _ => true

def wordStart (b : Nat) : Bool := !(b == 45 || b == 95)

def startsOk : List Nat → Bool
  | a :: b :: rest => (a != 32 || wordStart b) && startsOk (b :: rest)
  | _ => true

def nameCanonical (n : List Nat) : Bool :=
  decide (0 < n.length) && decide (n.length ≤ nameMax) && n.all nameByte &&
    n.head? != some 32 && n.getLast? != some 32 && noDoubleSpace n && wordStart (n.headD 32) && startsOk n

structure Config where
  levels : List (List Nat)
  comps : List (List Nat)
deriving DecidableEq, Repr

inductive CfgErr
  | emptyName
  | nameTooLong
  | invalidName
  | duplicateName
  | tooManyLevels
  | tooManyComps
  | tooManyTrusts
deriving DecidableEq, Repr

def nameCheck (c : Config) (raw : List Nat) : Except CfgErr (List Nat) :=
  let n := normalise raw
  if nameMax < n.length then .error .nameTooLong
  else if n.length = 0 then .error .emptyName
  else if !nameCanonical n then .error .invalidName
  else if decide (n ∈ c.levels) || decide (n ∈ c.comps) then .error .duplicateName
  else .ok n

def addLevel (c : Config) (raw : List Nat) : Except CfgErr Config :=
  if levelLimit ≤ c.levels.length then .error .tooManyLevels
  else match nameCheck c raw with
    | .error e => .error e
    | .ok n => .ok { c with levels := c.levels ++ [n] }

def addComp (c : Config) (raw : List Nat) : Except CfgErr Config :=
  if compLimit ≤ c.comps.length then .error .tooManyComps
  else match nameCheck c raw with
    | .error e => .error e
    | .ok n => .ok { c with comps := c.comps ++ [n] }

def NamesOk (c : Config) : Prop :=
  c.levels.length ≤ levelLimit ∧ c.comps.length ≤ compLimit ∧
    (∀ n ∈ c.levels ++ c.comps, nameCanonical n = true) ∧ (c.levels ++ c.comps).Nodup

def ConfigOk (c : Config) : Prop := NamesOk c ∧ 0 < c.levels.length

def LabelOk (c : Config) (l : Label) : Prop := Valid c.levels.length c.comps.length l

theorem nameByte_not_ws {b : Nat} (h : nameByte b = true) (hs : b ≠ 32) : isWs b = false := by
  unfold nameByte at h; unfold isWs
  simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at h
  simp only [Bool.or_eq_false_iff, beq_eq_false_iff_ne]
  omega

theorem nameByte_fold {b : Nat} (h : nameByte b = true) : foldUpper b = b := by
  unfold nameByte at h; unfold foldUpper
  simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at h
  split <;> omega

theorem nameByte_marking {b : Nat} (h : nameByte b = true) : markingByte b = true := by
  unfold nameByte at h; unfold markingByte
  simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at h ⊢
  omega

theorem nameByte_ne_slash {b : Nat} (h : nameByte b = true) : b ≠ 47 := by
  unfold nameByte at h
  simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at h
  omega

theorem noDouble_tail {a : Nat} {r : List Nat} (h : noDoubleSpace (a :: r) = true) : noDoubleSpace r = true := by
  cases r with
  | nil => rfl
  | cons b r => simp only [noDoubleSpace, Bool.and_eq_true] at h; exact h.2

theorem norm_body (n : Nat) : ∀ (rest acc : List Nat) (x : Nat), rest.length ≤ n → acc.head? = some x → x ≠ 32 →
    (∀ b ∈ rest, nameByte b = true) → noDoubleSpace rest = true → rest.getLast? ≠ some 32 →
    rest.foldl normStep (acc, false) = (rest.reverse ++ acc, false) := by
  induction n with
  | zero =>
    intro rest acc x hl _ _ _ _ _
    rw [List.length_eq_zero_iff.1 (Nat.le_zero.1 hl)]
    rfl
  | succ n ih =>
    intro rest acc x hl hacc hx hb hd hlast
    match rest, hl, hb, hd, hlast with
    | [], _, _, _, _ => rfl
    | b :: r, hl, hb, hd, hlast =>
      have hbb : nameByte b = true := hb b (List.mem_cons_self)
      by_cases h32 : b = 32
      · subst h32
        match r, hl, hb, hd, hlast with
        | [], _, _, _, hlast => simp at hlast
        | c :: r', hl, hb, hd, hlast =>
          have hc : nameByte c = true := hb c (List.mem_cons_of_mem _ List.mem_cons_self)
          have hc32 : c ≠ 32 := by
            intro he; subst he; simp [noDoubleSpace] at hd
          have hne : acc ≠ [] := by intro he; subst he; simp at hacc
          have step1 : normStep (acc, false) 32 = (acc, true) := by
            simp [normStep, isWs, hne]
          have step2 : normStep (acc, true) c = (c :: 32 :: acc, false) := by
            simp [normStep, nameByte_not_ws hc hc32, nameByte_fold hc]
          simp only [List.foldl_cons, step1, step2]
          have := ih r' (c :: 32 :: acc) c (by simp at hl; omega) rfl hc32
            (fun b hm => hb b (List.mem_cons_of_mem _ (List.mem_cons_of_mem _ hm)))
            (noDouble_tail (noDouble_tail hd))
            (by
              intro he
              apply hlast
              cases r' with
              | nil => simp at he
              | cons y ys => simpa [List.getLast?_cons_cons] using he)
          rw [this]
          simp
      · have step : normStep (acc, false) b = (b :: acc, false) := by
          simp [normStep, nameByte_not_ws hbb h32, nameByte_fold hbb]
        simp only [List.foldl_cons, step]
        have := ih r (b :: acc) b (by simp at hl; omega) rfl h32
          (fun y hm => hb y (List.mem_cons_of_mem _ hm)) (noDouble_tail hd)
          (by
            intro he
            apply hlast
            cases r with
            | nil => simp at he
            | cons y ys => simpa [List.getLast?_cons_cons] using he)
        rw [this]
        simp

theorem normalise_canonical {n : List Nat} (h : nameCanonical n = true) : normalise n = n := by
  unfold nameCanonical at h
  simp only [Bool.and_eq_true, decide_eq_true_eq, List.all_eq_true, bne_iff_ne, ne_eq] at h
  obtain ⟨⟨⟨⟨⟨⟨⟨hpos, _⟩, hb⟩, hhead⟩, hlast⟩, hd⟩, _⟩, _⟩ := h
  match n, hpos, hb, hhead, hlast, hd with
  | b :: rest, _, hb, hhead, hlast, hd =>
    have hbb : nameByte b = true := hb b List.mem_cons_self
    have h32 : b ≠ 32 := by intro he; apply hhead; simp [he]
    have step : normStep ([], false) b = ([b], false) := by
      simp [normStep, nameByte_not_ws hbb h32, nameByte_fold hbb]
    unfold normalise
    simp only [List.foldl_cons, step]
    rw [norm_body rest.length rest [b] b (Nat.le_refl _) rfl h32 (fun y hm => hb y (List.mem_cons_of_mem _ hm))
      (noDouble_tail hd)
      (by
        intro he
        apply hlast
        cases rest with
        | nil => simp at he
        | cons y ys => simpa [List.getLast?_cons_cons] using he)]
    simp

theorem nameCheck_spec {c : Config} {raw n : List Nat} (h : nameCheck c raw = .ok n) :
    n = normalise raw ∧ nameCanonical n = true ∧ n ∉ c.levels ∧ n ∉ c.comps := by
  unfold nameCheck at h
  simp only at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · split at h
      · simp at h
      · rename_i hc
        split at h
        · simp at h
        · rename_i hd
          simp only [Except.ok.injEq] at h
          subst h
          have hc' : nameCanonical (normalise raw) = true := by
            revert hc; cases nameCanonical (normalise raw) <;> simp
          simp only [Bool.or_eq_true, decide_eq_true_eq, not_or] at hd
          exact ⟨rfl, hc', hd.1, hd.2⟩

theorem addLevel_ok {c c' : Config} {raw : List Nat} (h : NamesOk c) (hr : addLevel c raw = .ok c') :
    NamesOk c' ∧ c'.comps = c.comps ∧ c'.levels = c.levels ++ [normalise raw] := by
  unfold addLevel at hr
  split at hr
  · simp at hr
  · rename_i hlim
    split at hr
    · simp at hr
    · rename_i n hn
      simp only [Except.ok.injEq] at hr
      subst hr
      obtain ⟨rfl, hcan, hnl, hnc⟩ := nameCheck_spec hn
      obtain ⟨h1, h2, h3, h4⟩ := h
      refine ⟨⟨?_, h2, ?_, ?_⟩, rfl, rfl⟩
      · simp only [List.length_append, List.length_singleton]; unfold levelLimit at *; omega
      · intro m hm
        simp only [List.mem_append, List.mem_singleton] at hm
        rcases hm with (hm | hm) | hm
        · exact h3 m (List.mem_append_left _ hm)
        · subst hm; exact hcan
        · exact h3 m (List.mem_append_right _ hm)
      · show (c.levels ++ [normalise raw] ++ c.comps).Nodup
        rw [List.nodup_append] at h4
        rw [List.nodup_append, List.nodup_append]
        refine ⟨⟨h4.1, List.nodup_cons.2 ⟨by simp, List.nodup_nil⟩, ?_⟩, h4.2.1, ?_⟩
        · intro a ha b hb
          simp only [List.mem_singleton] at hb
          subst hb; intro he; subst he; exact hnl ha
        · intro a ha b hb
          rcases List.mem_append.1 ha with ha | ha
          · exact h4.2.2 a ha b hb
          · simp only [List.mem_singleton] at ha
            subst ha; intro he; subst he; exact hnc hb

theorem addComp_ok {c c' : Config} {raw : List Nat} (h : NamesOk c) (hr : addComp c raw = .ok c') :
    NamesOk c' ∧ c'.levels = c.levels ∧ c'.comps = c.comps ++ [normalise raw] := by
  unfold addComp at hr
  split at hr
  · simp at hr
  · rename_i hlim
    split at hr
    · simp at hr
    · rename_i n hn
      simp only [Except.ok.injEq] at hr
      subst hr
      obtain ⟨rfl, hcan, hnl, hnc⟩ := nameCheck_spec hn
      obtain ⟨h1, h2, h3, h4⟩ := h
      refine ⟨⟨h1, ?_, ?_, ?_⟩, rfl, rfl⟩
      · simp only [List.length_append, List.length_singleton]; unfold compLimit at *; omega
      · intro m hm
        simp only [List.mem_append, List.mem_singleton] at hm
        rcases hm with hm | hm | hm
        · exact h3 m (List.mem_append_left _ hm)
        · exact h3 m (List.mem_append_right _ hm)
        · subst hm; exact hcan
      · show (c.levels ++ (c.comps ++ [normalise raw])).Nodup
        rw [← List.append_assoc, List.nodup_append]
        refine ⟨h4, List.nodup_cons.2 ⟨by simp, List.nodup_nil⟩, ?_⟩
        intro a ha b hb
        simp only [List.mem_singleton] at hb
        subst hb
        intro he
        subst he
        rcases List.mem_append.1 ha with ha | ha
        · exact hnl ha
        · exact hnc ha

theorem empty_names_ok : NamesOk ⟨[], []⟩ :=
  ⟨by decide, by decide, fun n hn => by simp at hn, List.nodup_nil⟩

inductive PErr
  | empty
  | tooLong
  | invalidByte
  | emptyLevel
  | unknownLevel
  | badSeparator
  | emptyComp
  | unknownComp
  | dupComp
  | emptyTrust
  | unknownTrust
deriving DecidableEq, Repr

structure Failure where
  err : PErr
  offset : Nat
  length : Nat
deriving DecidableEq, Repr

def findName (names : List (List Nat)) (raw : List Nat) : Option Nat := names.findIdx? (· == normalise raw)

def trimmed (tok : List Nat) (off : Nat) : Nat × Nat :=
  let lead := (tok.takeWhile isWs).length
  if lead = tok.length then (off, 0)
  else (off + lead, tok.length - lead - (tok.reverse.takeWhile isWs).length)

def splitAux : List Nat → Nat → Nat → List Nat → List (Nat × List Nat)
  | [], start, _, cur => [(start, cur.reverse)]
  | b :: rest, start, pos, cur =>
    if b = 47 then (start, cur.reverse) :: splitAux rest (pos + 1) (pos + 1) []
    else splitAux rest start (pos + 1) (b :: cur)

def compsLoop (c : Config) (lv : Nat) : List (Nat × List Nat) → Nat → Except Failure Label
  | [], acc => .ok ⟨lv, acc⟩
  | (off, tok) :: rest, acc =>
    let tr := trimmed tok off
    if tr.2 = 0 then .error ⟨.emptyComp, tr.1, 0⟩
    else match findName c.comps tok with
      | none => .error ⟨.unknownComp, tr.1, tr.2⟩
      | some k => if acc.testBit k then .error ⟨.dupComp, tr.1, tr.2⟩ else compsLoop c lv rest (acc ||| 2 ^ k)

def parse (c : Config) (s : List Nat) : Except Failure Label :=
  if markingMax < s.length then .error ⟨.tooLong, markingMax, s.length - markingMax⟩
  else match s.findIdx? (fun b => !markingByte b) with
  | some i => .error ⟨.invalidByte, i, 1⟩
  | none =>
    let tok := s.takeWhile (· != 47)
    let tr := trimmed tok 0
    if tr.2 = 0 then
      (if tok.length = s.length then .error ⟨.empty, 0, 0⟩ else .error ⟨.emptyLevel, tr.1, 0⟩)
    else match findName c.levels tok with
      | none => .error ⟨.unknownLevel, tr.1, tr.2⟩
      | some lv =>
        match s.drop tok.length with
        | [] => .ok ⟨lv, 0⟩
        | _ :: rest =>
          match rest with
          | 47 :: more => compsLoop c lv (splitAux more (tok.length + 2) (tok.length + 2) []) 0
          | _ => .error ⟨.badSeparator, tok.length, 1⟩

def idsOf (m n : Nat) : List Nat := (List.range n).filter (m.testBit ·)

def ofIds (ks : List Nat) : Nat := ks.foldl (fun m k => m ||| 2 ^ k) 0

def labelValid (c : Config) (l : Label) : Bool :=
  decide (l.level < c.levels.length) && decide (l.comps < 2 ^ c.comps.length)

def format (c : Config) (l : Label) : Option (List Nat) :=
  if labelValid c l then
    let ids := idsOf l.comps compLimit
    some (c.levels.getD l.level [] ++
      (if ids = [] then [] else 47 :: 47 :: List.intercalate [47] (ids.map (c.comps.getD · []))))
  else none

theorem findIdx_beq_nodup {α : Type} [BEq α] [LawfulBEq α] {xs : List α} (hn : xs.Nodup) {i : Nat} {x : α}
    (h : xs[i]? = some x) : xs.findIdx? (· == x) = some i := by
  obtain ⟨hi, he⟩ := List.getElem?_eq_some_iff.1 h
  rw [List.findIdx?_eq_some_iff_getElem]
  refine ⟨hi, by simp [he], fun j hj => ?_⟩
  simp only [beq_iff_eq]
  intro hjl
  have : xs[j] = xs[i] := by rw [hjl, he]
  have := (hn.getElem_inj).1 this
  omega

theorem canonical_bytes {n : List Nat} (h : nameCanonical n = true) : ∀ b ∈ n, nameByte b = true := by
  unfold nameCanonical at h
  simp only [Bool.and_eq_true, List.all_eq_true] at h
  exact h.1.1.1.1.1.2

theorem canonical_pos {n : List Nat} (h : nameCanonical n = true) : 0 < n.length := by
  unfold nameCanonical at h
  simp only [Bool.and_eq_true, decide_eq_true_eq] at h
  exact h.1.1.1.1.1.1.1

theorem canonical_len {n : List Nat} (h : nameCanonical n = true) : n.length ≤ nameMax := by
  unfold nameCanonical at h
  simp only [Bool.and_eq_true, decide_eq_true_eq] at h
  exact h.1.1.1.1.1.1.2

theorem canonical_head {n : List Nat} (h : nameCanonical n = true) : n.head? ≠ some 32 := by
  unfold nameCanonical at h
  simp only [Bool.and_eq_true, bne_iff_ne, ne_eq] at h
  exact h.1.1.1.1.2

theorem canonical_last {n : List Nat} (h : nameCanonical n = true) : n.getLast? ≠ some 32 := by
  unfold nameCanonical at h
  simp only [Bool.and_eq_true, bne_iff_ne, ne_eq] at h
  exact h.1.1.1.2

theorem takeWhile_not_ws {l : List Nat} (hb : ∀ b ∈ l, nameByte b = true) (hh : l.head? ≠ some 32) :
    l.takeWhile isWs = [] := by
  cases l with
  | nil => rfl
  | cons b r =>
    have h1 : b ≠ 32 := by intro he; apply hh; simp [he]
    simp [nameByte_not_ws (hb b List.mem_cons_self) h1]

theorem trimmed_canonical {n : List Nat} (h : nameCanonical n = true) (off : Nat) : trimmed n off = (off, n.length) := by
  have hb := canonical_bytes h
  have hpos := canonical_pos h
  unfold trimmed
  simp only
  rw [takeWhile_not_ws hb (canonical_head h)]
  have hrev : n.reverse.takeWhile isWs = [] := by
    apply takeWhile_not_ws (fun b hm => hb b (List.mem_reverse.1 hm))
    rw [List.head?_reverse]
    exact canonical_last h
  rw [hrev]
  simp only [List.length_nil]
  split
  · omega
  · simp

theorem findName_canonical {names : List (List Nat)} (hn : names.Nodup) {i : Nat} {x : List Nat}
    (h : names[i]? = some x) (hc : nameCanonical x = true) : findName names x = some i := by
  unfold findName
  rw [normalise_canonical hc]
  exact findIdx_beq_nodup hn h

theorem splitAux_noslash (x rest : List Nat) (start pos : Nat) (cur : List Nat) (hx : ∀ b ∈ x, b ≠ 47) :
    splitAux (x ++ rest) start pos cur = splitAux rest start (pos + x.length) (x.reverse ++ cur) := by
  induction x generalizing pos cur with
  | nil => simp
  | cons b x ih =>
    have hb : ¬ b = 47 := hx b List.mem_cons_self
    simp only [List.cons_append, splitAux, hb, ↓reduceIte]
    rw [ih _ _ (fun y hy => hx y (List.mem_cons_of_mem _ hy))]
    simp [Nat.add_assoc, Nat.add_comm 1]

theorem splitAux_intercalate (xs : List (List Nat)) (hne : xs ≠ []) (hx : ∀ x ∈ xs, ∀ b ∈ x, b ≠ 47) (start : Nat) :
    (splitAux (List.intercalate [47] xs) start start []).map Prod.snd = xs := by
  induction xs generalizing start with
  | nil => exact absurd rfl hne
  | cons x rest ih =>
    cases rest with
    | nil =>
      simp only [List.intercalate_singleton]
      have := splitAux_noslash x [] start start [] (hx x List.mem_cons_self)
      rw [List.append_nil] at this
      rw [this]
      simp [splitAux]
    | cons y ys =>
      rw [List.intercalate_cons_cons, List.append_assoc]
      rw [splitAux_noslash x _ start start [] (hx x List.mem_cons_self)]
      simp only [List.singleton_append, splitAux, ↓reduceIte, List.append_nil, List.reverse_reverse, List.map_cons]
      rw [ih (by simp) (fun z hz => hx z (List.mem_cons_of_mem _ hz))]

theorem foldl_or_testBit (ks : List Nat) (acc i : Nat) :
    (ks.foldl (fun m k => m ||| 2 ^ k) acc).testBit i = (acc.testBit i || decide (i ∈ ks)) := by
  induction ks generalizing acc with
  | nil => simp
  | cons k ks ih =>
    simp only [List.foldl_cons]
    rw [ih, Nat.testBit_or, Nat.testBit_two_pow]
    apply Bool.eq_iff_iff.2
    simp only [Bool.or_eq_true, decide_eq_true_eq, List.mem_cons]
    constructor
    · rintro ((h | h) | h)
      · exact Or.inl h
      · exact Or.inr (Or.inl h.symm)
      · exact Or.inr (Or.inr h)
    · rintro (h | h | h)
      · exact Or.inl (Or.inl h)
      · exact Or.inl (Or.inr h.symm)
      · exact Or.inr h

theorem mem_idsOf {m n i : Nat} : i ∈ idsOf m n ↔ i < n ∧ m.testBit i = true := by
  unfold idsOf
  simp [List.mem_filter, List.mem_range]

theorem testBit_below {m n i : Nat} (hm : m < 2 ^ n) (h : m.testBit i = true) : i < n := by
  rcases Nat.lt_or_ge i n with hl | hg
  · exact hl
  · rw [Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le hm (Nat.pow_le_pow_right (by decide) hg))] at h
    exact absurd h (by decide)

theorem ofIds_idsOf {m n : Nat} (hm : m < 2 ^ n) : ofIds (idsOf m n) = m := by
  apply Nat.eq_of_testBit_eq
  intro i
  unfold ofIds
  rw [foldl_or_testBit, Nat.zero_testBit, Bool.false_or]
  cases h : m.testBit i
  · apply decide_eq_false
    rw [mem_idsOf]
    intro ⟨_, h2⟩
    rw [h] at h2
    exact absurd h2 (by decide)
  · exact decide_eq_true (mem_idsOf.2 ⟨testBit_below hm h, h⟩)

theorem idsOf_nodup (m n : Nat) : (idsOf m n).Nodup := by
  unfold idsOf
  exact (List.nodup_range).filter _

theorem idsOf_length (m n : Nat) : (idsOf m n).length ≤ n := by
  unfold idsOf
  exact Nat.le_trans (List.length_filter_le _ _) (by simp)

theorem compsLoop_ok (c : Config) (lv : Nat) (hn : c.comps.Nodup) (hcan : ∀ n ∈ c.comps, nameCanonical n = true) :
    ∀ (ks : List Nat) (toks : List (Nat × List Nat)) (acc : Nat),
      toks.map Prod.snd = ks.map (c.comps.getD · []) → (∀ k ∈ ks, k < c.comps.length) → ks.Nodup →
      (∀ k ∈ ks, acc.testBit k = false) →
      compsLoop c lv toks acc = .ok ⟨lv, ks.foldl (fun m k => m ||| 2 ^ k) acc⟩ := by
  intro ks
  induction ks with
  | nil =>
    intro toks acc ht _ _ _
    simp only [List.map_nil, List.map_eq_nil_iff] at ht
    subst ht
    rfl
  | cons k ks ih =>
    intro toks acc ht hk hnd hacc
    match toks, ht with
    | (off, tok) :: toks', ht =>
      simp only [List.map_cons, List.cons.injEq] at ht
      obtain ⟨htok, hrest⟩ := ht
      have hkl : k < c.comps.length := hk k List.mem_cons_self
      have hget : c.comps[k]? = some tok := by
        rw [htok, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hkl]; rfl
      have htc : nameCanonical tok = true := hcan tok (List.mem_of_getElem? hget)
      have hne : ¬ tok.length = 0 := Nat.ne_of_gt (canonical_pos htc)
      simp only [compsLoop, trimmed_canonical htc, hne, ↓reduceIte, findName_canonical hn hget htc,
        hacc k List.mem_cons_self, Bool.false_eq_true, List.foldl_cons]
      apply ih toks' (acc ||| 2 ^ k) hrest (fun j hj => hk j (List.mem_cons_of_mem _ hj)) (List.nodup_cons.1 hnd).2
      intro j hj
      rw [Nat.testBit_or, hacc j (List.mem_cons_of_mem _ hj), Nat.testBit_two_pow]
      have : k ≠ j := fun he => (List.nodup_cons.1 hnd).1 (he ▸ hj)
      simp [this]

theorem intercalate_mem {xs : List (List Nat)} {b : Nat} (h : b ∈ List.intercalate [47] xs) :
    b = 47 ∨ ∃ x ∈ xs, b ∈ x := by
  induction xs with
  | nil => simp at h
  | cons x rest ih =>
    cases rest with
    | nil =>
      simp only [List.intercalate_singleton] at h
      exact Or.inr ⟨x, List.mem_cons_self, h⟩
    | cons y ys =>
      rw [List.intercalate_cons_cons] at h
      simp only [List.mem_append, List.mem_singleton] at h
      rcases h with (h | h) | h
      · exact Or.inr ⟨x, List.mem_cons_self, h⟩
      · exact Or.inl h
      · rcases ih h with h | ⟨z, hz, hb⟩
        · exact Or.inl h
        · exact Or.inr ⟨z, List.mem_cons_of_mem _ hz, hb⟩

theorem intercalate_length_le {xs : List (List Nat)} (h : ∀ x ∈ xs, x.length ≤ nameMax) :
    (List.intercalate [47] xs).length ≤ (nameMax + 1) * xs.length := by
  induction xs with
  | nil => simp
  | cons x rest ih =>
    have hx := h x List.mem_cons_self
    cases rest with
    | nil => simp only [List.intercalate_singleton, List.length_singleton]; omega
    | cons y ys =>
      rw [List.intercalate_cons_cons]
      have := ih (fun z hz => h z (List.mem_cons_of_mem _ hz))
      simp only [List.length_append, List.length_cons, List.length_nil] at this ⊢
      unfold nameMax at *
      omega

theorem names_canonical {c : Config} (hc : ConfigOk c) : ∀ n ∈ c.levels ++ c.comps, nameCanonical n = true :=
  hc.1.2.2.1

theorem levels_nodup {c : Config} (hc : ConfigOk c) : c.levels.Nodup :=
  (List.nodup_append.1 hc.1.2.2.2).1

theorem comps_nodup {c : Config} (hc : ConfigOk c) : c.comps.Nodup :=
  (List.nodup_append.1 hc.1.2.2.2).2.1

theorem labelValid_iff (c : Config) (l : Label) : labelValid c l = true ↔ LabelOk c l := by
  unfold labelValid LabelOk Valid
  simp [Bool.and_eq_true, decide_eq_true_eq]

theorem format_isSome {c : Config} {l : Label} (hl : LabelOk c l) : (format c l).isSome = true := by
  unfold format
  rw [(labelValid_iff c l).2 hl]
  rfl

theorem format_valid {c : Config} {l : Label} {s : List Nat} (h : format c l = some s) : LabelOk c l := by
  unfold format at h
  split at h
  · rename_i hv; exact (labelValid_iff c l).1 hv
  · simp at h

theorem takeWhile_name {x rest : List Nat} (hx : ∀ b ∈ x, b ≠ 47) (hr : rest = [] ∨ rest.head? = some 47) :
    (x ++ rest).takeWhile (· != 47) = x := by
  rw [List.takeWhile_append_of_pos (fun b hb => by simpa using hx b hb)]
  rcases hr with hr | hr
  · subst hr; simp
  · cases rest with
    | nil => simp
    | cons b r =>
      simp only [List.head?_cons, Option.some.injEq] at hr
      subst hr
      simp

theorem parse_format {c : Config} (hc : ConfigOk c) {l : Label} {s : List Nat} (h : format c l = some s) :
    parse c s = .ok l := by
  have hl := format_valid h
  obtain ⟨hlv, hlc⟩ := hl
  have hcan := names_canonical hc
  have hCle : c.comps.length ≤ compLimit := hc.1.2.1
  have hlvget : c.levels[l.level]? = some (c.levels.getD l.level []) := by
    rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hlv]; rfl
  have hname := hcan _ (List.mem_append_left _ (List.mem_of_getElem? hlvget))
  have hnb := canonical_bytes hname
  have hnslash : ∀ b ∈ c.levels.getD l.level [], b ≠ 47 := fun b hb => nameByte_ne_slash (hnb b hb)
  have hids_lt : ∀ k ∈ idsOf l.comps compLimit, k < c.comps.length := fun k hk =>
    testBit_below hlc (mem_idsOf.1 hk).2
  have hcompget : ∀ k ∈ idsOf l.comps compLimit, c.comps[k]? = some (c.comps.getD k []) := fun k hk => by
    rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem (hids_lt k hk)]; rfl
  have hcompcan : ∀ x ∈ (idsOf l.comps compLimit).map (c.comps.getD · []), nameCanonical x = true := by
    intro x hx
    obtain ⟨k, hk, rfl⟩ := List.mem_map.1 hx
    exact hcan _ (List.mem_append_right _ (List.mem_of_getElem? (hcompget k hk)))
  have hcompb : ∀ x ∈ (idsOf l.comps compLimit).map (c.comps.getD · []), ∀ b ∈ x, nameByte b = true :=
    fun x hx => canonical_bytes (hcompcan x hx)
  have hlc' : l.comps < 2 ^ compLimit :=
    Nat.lt_of_lt_of_le hlc (Nat.pow_le_pow_right (by decide) hCle)
  unfold format at h
  rw [(labelValid_iff c l).2 ⟨hlv, hlc⟩] at h
  simp only [↓reduceIte, Option.some.injEq] at h
  subst h
  generalize hn : c.levels.getD l.level [] = name at *
  generalize hids : idsOf l.comps compLimit = ids at *
  have hbytes : ∀ b ∈ name ++ (if ids = [] then [] else 47 :: 47 :: List.intercalate [47] (ids.map (c.comps.getD · []))),
      markingByte b = true := by
    intro b hb
    rcases List.mem_append.1 hb with hb | hb
    · exact nameByte_marking (hnb b hb)
    · split at hb
      · simp at hb
      · simp only [List.mem_cons] at hb
        rcases hb with hb | hb | hb
        · subst hb; rfl
        · subst hb; rfl
        · rcases intercalate_mem hb with hb | ⟨x, hx, hbx⟩
          · subst hb; rfl
          · exact nameByte_marking (hcompb x hx b hbx)
  have hlen : ¬ markingMax < (name ++ (if ids = [] then [] else
      47 :: 47 :: List.intercalate [47] (ids.map (c.comps.getD · [])))).length := by
    have h1 : name.length ≤ nameMax := canonical_len hname
    have h2 := intercalate_length_le (xs := ids.map (c.comps.getD · []))
      (fun x hx => canonical_len (hcompcan x hx))
    have h3 : ids.length ≤ compLimit := hids ▸ idsOf_length _ _
    simp only [List.length_map] at h2
    rw [List.length_append]
    split
    · unfold markingMax nameMax at *; simp; omega
    · simp only [List.length_cons]
      unfold markingMax nameMax compLimit at *
      have : (64 + 1) * ids.length ≤ 65 * 256 := Nat.mul_le_mul_left _ h3
      omega
  have hfind : (name ++ (if ids = [] then [] else
      47 :: 47 :: List.intercalate [47] (ids.map (c.comps.getD · [])))).findIdx? (fun b => !markingByte b) = none := by
    rw [List.findIdx?_eq_none_iff]
    intro b hb
    simp [hbytes b hb]
  have htake : (name ++ (if ids = [] then [] else
      47 :: 47 :: List.intercalate [47] (ids.map (c.comps.getD · [])))).takeWhile (· != 47) = name := by
    apply takeWhile_name hnslash
    split
    · exact Or.inl rfl
    · exact Or.inr rfl
  have htrim : trimmed name 0 = (0, name.length) := trimmed_canonical hname 0
  have hpos : ¬ name.length = 0 := Nat.ne_of_gt (canonical_pos hname)
  have hfl : findName c.levels name = some l.level := findName_canonical (levels_nodup hc) hlvget hname
  have hdrop : (name ++ (if ids = [] then [] else
      47 :: 47 :: List.intercalate [47] (ids.map (c.comps.getD · [])))).drop name.length =
      (if ids = [] then [] else 47 :: 47 :: List.intercalate [47] (ids.map (c.comps.getD · []))) := by
    simp
  unfold parse
  simp only [hlen, ↓reduceIte, hfind, htake, htrim, hpos, hfl, hdrop]
  split
  · rename_i hnil
    split at hnil
    · rename_i he
      have : l.comps = 0 := by
        have := ofIds_idsOf hlc'
        rw [hids, he] at this
        exact this.symm
      cases l
      simp only at this
      subst this
      rfl
    · simp at hnil
  · rename_i y rest hcons
    split at hcons
    · simp at hcons
    · rename_i hne
      simp only [List.cons.injEq] at hcons
      obtain ⟨_, rfl⟩ := hcons
      simp only
      have hsplit := splitAux_intercalate (ids.map (c.comps.getD · [])) (by simpa using hne)
        (fun x hx b hb => nameByte_ne_slash (hcompb x hx b hb)) (name.length + 2)
      rw [compsLoop_ok c l.level (comps_nodup hc) (fun n hn => hcan n (List.mem_append_right _ hn)) ids _ 0 hsplit
        (hids ▸ hids_lt) (hids ▸ idsOf_nodup _ _) (fun k _ => Nat.zero_testBit k)]
      have := ofIds_idsOf hlc'
      rw [hids] at this
      unfold ofIds at this
      rw [this]

theorem findName_lt {names : List (List Nat)} {raw : List Nat} {i : Nat} (h : findName names raw = some i) :
    i < names.length := by
  unfold findName at h
  exact (List.findIdx?_eq_some_iff_getElem.1 h).1

theorem compsLoop_valid {c : Config} {lv : Nat} :
    ∀ {toks : List (Nat × List Nat)} {acc : Nat} {l : Label}, compsLoop c lv toks acc = .ok l →
      acc < 2 ^ c.comps.length → l.level = lv ∧ l.comps < 2 ^ c.comps.length := by
  intro toks
  induction toks with
  | nil =>
    intro acc l h hacc
    simp only [compsLoop, Except.ok.injEq] at h
    subst h
    exact ⟨rfl, hacc⟩
  | cons tk rest ih =>
    intro acc l h hacc
    obtain ⟨off, tok⟩ := tk
    simp only [compsLoop] at h
    split at h
    · simp at h
    · split at h
      · simp at h
      · rename_i k hk
        split at h
        · simp at h
        · apply ih h
          apply Nat.or_lt_two_pow hacc
          exact Nat.pow_lt_pow_right (by decide) (findName_lt hk)

theorem parse_valid {c : Config} {s : List Nat} {l : Label} (h : parse c s = .ok l) : LabelOk c l := by
  unfold parse at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · simp only at h
      split at h
      · split at h <;> simp at h
      · split at h
        · simp at h
        · rename_i lv hlv
          have hlt := findName_lt hlv
          split at h
          · simp only [Except.ok.injEq] at h
            subst h
            exact ⟨hlt, Nat.two_pow_pos _⟩
          · split at h
            · have := compsLoop_valid h (Nat.two_pow_pos _)
              exact ⟨this.1 ▸ hlt, this.2⟩
            · simp at h

theorem format_parse {c : Config} (hc : ConfigOk c) {s : List Nat} {l : Label} (h : parse c s = .ok l) :
    ∃ s', format c l = some s' ∧ parse c s' = .ok l := by
  have hv := parse_valid h
  have hs := format_isSome hv
  cases hf : format c l with
  | none => rw [hf] at hs; simp at hs
  | some s' => exact ⟨s', rfl, parse_format hc hf⟩

theorem format_injective {c : Config} (hc : ConfigOk c) {l1 l2 : Label} {s : List Nat}
    (h1 : format c l1 = some s) (h2 : format c l2 = some s) : l1 = l2 := by
  have a := parse_format hc h1
  have b := parse_format hc h2
  rw [a] at b
  exact Except.ok.inj b

theorem canonical_roundtrip {c : Config} (hc : ConfigOk c) {l : Label} {s : List Nat} (h : format c l = some s) :
    ∃ l', parse c s = .ok l' ∧ format c l' = some s :=
  ⟨l, parse_format hc h, h⟩

theorem format_length {c : Config} (hc : ConfigOk c) {l : Label} {s : List Nat} (h : format c l = some s) :
    s.length ≤ markingMax := by
  have hp := parse_format hc h
  unfold parse at hp
  split at hp
  · simp at hp
  · rename_i hlen
    exact Nat.le_of_not_lt hlen

theorem format_total {c : Config} {l : Label} (hl : LabelOk c l) : ∃ s, format c l = some s := by
  have := format_isSome hl
  cases hf : format c l with
  | none => rw [hf] at this; simp at this
  | some s => exact ⟨s, rfl⟩

end Labels
