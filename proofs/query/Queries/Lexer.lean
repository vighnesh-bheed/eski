namespace Queries

inductive Kind where
  | finish
  | term
  | stop
  | pre
  | suf
  | inf
  | orK
  | minus
  | tilde
  | lp
  | rp
  | unsupported
deriving DecidableEq, Repr, Inhabited

structure Tk where
  kind : Kind
  pos : Nat
  text : List Nat
  near : List Nat
deriving DecidableEq, Repr, Inhabited

def isLower (c : Nat) : Bool := 97 ≤ c && c ≤ 122

def wordLen (q : List Nat) (i : Nat) : Nat := ((q.drop i).takeWhile isLower).length

def slice (q : List Nat) (a b : Nat) : List Nat := (q.drop a).take (b - a)

def stopWords : List (List Nat) :=
  [[97], [105, 115], [116, 104, 101], [97, 110], [97, 110, 100], [97, 114, 101], [97, 115], [97, 116], [98, 101], [98, 117, 116], [98, 121], [102, 111, 114], [105, 102], [105, 110], [105, 110, 116, 111], [105, 116], [110, 111], [110, 111, 116], [111, 102], [111, 110], [111, 114], [115, 117, 99, 104], [116, 104, 97, 116], [116, 104, 101, 105, 114], [116, 104, 101, 110], [116, 104, 101, 114, 101], [116, 104, 101, 115, 101], [116, 104, 101, 121], [116, 104, 105, 115], [116, 111], [119, 97, 115], [119, 105, 108, 108], [119, 105, 116, 104]]

def missingWord : List Nat := [105, 115, 109, 105, 115, 115, 105, 110, 103]

def outside (raw : List Nat) : Bool := raw.take 3 == [105, 110, 102] || raw == missingWord

inductive Step where
  | skip
  | emit (t : Tk) (next : Nat) (near : List Nat)
  | stop (t : Tk)

def starStep (q : List Nat) (i : Nat) (near : List Nat) (w : Nat) : Step :=
  if w = 0 then .stop ⟨.unsupported, i, [], near⟩
  else if i + 1 + w < q.length ∧ q.getD (i + 1 + w) 0 = 42 then
    .emit ⟨.inf, i, slice q (i + 1) (i + 1 + w), slice q (i + 1) (i + 1 + w)⟩ (i + 2 + w) (slice q (i + 1) (i + 1 + w))
  else .emit ⟨.suf, i, slice q (i + 1) (i + 1 + w), slice q (i + 1) (i + 1 + w)⟩ (i + 1 + w) (slice q (i + 1) (i + 1 + w))

def wordStep (q : List Nat) (i : Nat) (w : Nat) : Step :=
  if outside (slice q i (i + w)) then .stop ⟨.unsupported, i, slice q i (i + w), slice q i (i + w)⟩
  else if i + w < q.length ∧ q.getD (i + w) 0 = 42 then
    .emit ⟨.pre, i, slice q i (i + w), slice q i (i + w)⟩ (i + w + 1) (slice q i (i + w))
  else if stopWords.contains (slice q i (i + w)) then
    .emit ⟨.stop, i, slice q i (i + w), slice q i (i + w)⟩ (i + w) (slice q i (i + w))
  else .emit ⟨.term, i, slice q i (i + w), slice q i (i + w)⟩ (i + w) (slice q i (i + w))

def charStep (q : List Nat) (i : Nat) (near : List Nat) (c : Nat) : Step :=
  if c = 32 ∨ c = 44 then .skip
  else if c = 40 then .emit ⟨.lp, i, [], near⟩ (i + 1) near
  else if c = 41 then .emit ⟨.rp, i, [], near⟩ (i + 1) near
  else if c = 124 then .emit ⟨.orK, i, [], near⟩ (i + 1) near
  else if c = 126 then .emit ⟨.tilde, i, [], near⟩ (i + 1) near
  else if c = 45 then .emit ⟨.minus, i, [], near⟩ (i + 1) near
  else if c = 42 then starStep q i near (wordLen q (i + 1))
  else if isLower c then wordStep q i (wordLen q i)
  else .stop ⟨.unsupported, i, [], near⟩

def lexStep (q : List Nat) (i : Nat) (near : List Nat) : Step := charStep q i near (q.getD i 0)

def lexAux : Nat → List Nat → Nat → List Nat → Nat → List Tk
  | 0, _, _, near, last => [⟨.unsupported, last, [], near⟩]
  | f + 1, q, i, near, last =>
    if q.length ≤ i then [⟨.finish, last, [], near⟩]
    else match lexStep q i near with
      | .skip => lexAux f q (i + 1) near last
      | .emit t n near' => t :: lexAux f q n near' t.pos
      | .stop t => [t]

def lex (q : List Nat) : List Tk := lexAux (q.length + 1) q 0 [] 0

def Tk.closing (t : Tk) : Bool := t.kind = .finish || t.kind = .unsupported

theorem isLower_pos (q : List Nat) (i : Nat) (h : isLower (q.getD i 0) = true) (hi : i < q.length) : 0 < wordLen q i := by
  unfold wordLen
  rw [List.drop_eq_getElem_cons hi, List.takeWhile_cons]
  have : q.getD i 0 = q[i] := by simp [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hi]
  rw [this] at h
  simp [h]

theorem starStep_emit (q : List Nat) (i : Nat) (near : List Nat) (w : Nat) (t : Tk) (n : Nat) (near' : List Nat)
    (h : starStep q i near w = .emit t n near') : t.pos = i ∧ i < n ∧ t.closing = false := by
  unfold starStep at h
  split at h
  · cases h
  · split at h
    · cases h; simp [Tk.closing]; omega
    · cases h; simp [Tk.closing]; omega

theorem wordStep_emit (q : List Nat) (i : Nat) (w : Nat) (t : Tk) (n : Nat) (near' : List Nat) (hw : 0 < w)
    (h : wordStep q i w = .emit t n near') : t.pos = i ∧ i < n ∧ t.closing = false := by
  unfold wordStep at h
  split at h
  · cases h
  · split at h
    · cases h; simp [Tk.closing]; omega
    · split at h
      · cases h; simp [Tk.closing]; omega
      · cases h; simp [Tk.closing]; omega

theorem lexStep_emit (q : List Nat) (i : Nat) (near : List Nat) (t : Tk) (n : Nat) (near' : List Nat)
    (hi : i < q.length) (h : lexStep q i near = .emit t n near') : t.pos = i ∧ i < n ∧ t.closing = false := by
  unfold lexStep charStep at h
  split at h
  · cases h
  split at h
  · cases h; simp [Tk.closing]
  split at h
  · cases h; simp [Tk.closing]
  split at h
  · cases h; simp [Tk.closing]
  split at h
  · cases h; simp [Tk.closing]
  split at h
  · cases h; simp [Tk.closing]
  split at h
  · exact starStep_emit q i near _ t n near' h
  split at h
  · rename_i hl
    exact wordStep_emit q i _ t n near' (isLower_pos q i hl hi) h
  · cases h

theorem lexStep_stop (q : List Nat) (i : Nat) (near : List Nat) (t : Tk) (h : lexStep q i near = .stop t) :
    t.kind = .unsupported := by
  unfold lexStep charStep at h
  split at h
  · cases h
  split at h
  · cases h
  split at h
  · cases h
  split at h
  · cases h
  split at h
  · cases h
  split at h
  · cases h
  split at h
  · unfold starStep at h
    split at h
    · cases h; rfl
    · split at h <;> cases h
  split at h
  · unfold wordStep at h
    split at h
    · cases h; rfl
    · split at h
      · cases h
      · split at h <;> cases h
  · cases h; rfl

theorem lexAux_last : ∀ (f : Nat) (q : List Nat) (i : Nat) (near : List Nat) (last : Nat),
    ∃ t, (lexAux f q i near last).getLast? = some t ∧ t.closing = true
  | 0, q, i, near, last => ⟨_, rfl, rfl⟩
  | f + 1, q, i, near, last => by
    unfold lexAux
    split
    · exact ⟨_, rfl, rfl⟩
    · split
      · exact lexAux_last f q _ _ _
      · obtain ⟨t', ht', hc⟩ := lexAux_last f q _ _ _
        refine ⟨t', ?_, hc⟩
        rw [List.getLast?_cons, ht']
        rfl
      · rename_i t hs
        exact ⟨t, rfl, by simp [Tk.closing, lexStep_stop q i near t hs]⟩

theorem lexAux_ne_nil (f : Nat) (q : List Nat) (i : Nat) (near : List Nat) (last : Nat) : lexAux f q i near last ≠ [] := by
  intro h
  obtain ⟨t, ht, -⟩ := lexAux_last f q i near last
  rw [h] at ht
  cases ht

theorem lexAux_body : ∀ (f : Nat) (q : List Nat) (i : Nat) (near : List Nat) (last : Nat),
    ∀ t ∈ (lexAux f q i near last).dropLast, t.closing = false ∧ i ≤ t.pos
  | 0, q, i, near, last => by simp [lexAux]
  | f + 1, q, i, near, last => by
    unfold lexAux
    split
    · simp
    · rename_i hle
      split
      · intro t ht
        have := lexAux_body f q (i + 1) near last t ht
        exact ⟨this.1, by omega⟩
      · rename_i t0 n near' hs
        have he := lexStep_emit q i near t0 n near' (by omega) hs
        intro t ht
        rw [List.dropLast_cons_of_ne_nil (lexAux_ne_nil f q n near' t0.pos)] at ht
        simp only [List.mem_cons] at ht
        rcases ht with ht | ht
        · subst ht; exact ⟨he.2.2, by omega⟩
        · have := lexAux_body f q n near' t0.pos t ht
          exact ⟨this.1, by omega⟩
      · simp

theorem lex_shape (q : List Nat) : ∃ t, (lex q).getLast? = some t ∧ t.closing = true ∧
    ∀ u ∈ (lex q).dropLast, u.closing = false := by
  obtain ⟨t, ht, hc⟩ := lexAux_last (q.length + 1) q 0 [] 0
  exact ⟨t, ht, hc, fun u hu => (lexAux_body _ q 0 [] 0 u hu).1⟩

end Queries
