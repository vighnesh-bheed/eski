import Labels.Trust

namespace Labels

structure TConfig where
  base : Config
  trusts : List (List Nat)
deriving DecidableEq, Repr

def trustCheck (tc : TConfig) (raw : List Nat) : Except CfgErr (List Nat) :=
  let n := normalise raw
  if nameMax < n.length then .error .nameTooLong
  else if n.length = 0 then .error .emptyName
  else if !nameCanonical n then .error .invalidName
  else if decide (n ∈ tc.trusts) then .error .duplicateName
  else .ok n

def addTrust (tc : TConfig) (raw : List Nat) : Except CfgErr TConfig :=
  if trustLimit ≤ tc.trusts.length then .error .tooManyTrusts
  else match trustCheck tc raw with
    | .error e => .error e
    | .ok n => .ok { tc with trusts := tc.trusts ++ [n] }

def TrustsOk (tc : TConfig) : Prop :=
  tc.trusts.length ≤ trustLimit ∧ (∀ n ∈ tc.trusts, nameCanonical n = true) ∧ tc.trusts.Nodup

def TConfigOk (tc : TConfig) : Prop := ConfigOk tc.base ∧ TrustsOk tc

def LabelOkT (tc : TConfig) (l : TLabel) : Prop :=
  ValidT tc.base.levels.length tc.base.comps.length tc.trusts.length l

def labelValidT (tc : TConfig) (l : TLabel) : Bool :=
  labelValid tc.base l.sec && decide (l.trust < trustCount tc.trusts.length)

def parseT (tc : TConfig) (s : List Nat) : Except Failure TLabel :=
  if markingMax < s.length then .error ⟨.tooLong, markingMax, s.length - markingMax⟩
  else match s.findIdx? (fun b => !markingByte b) with
  | some i => .error ⟨.invalidByte, i, 1⟩
  | none =>
    match parse tc.base (s.takeWhile (· != 59)) with
    | .error f =>
      .error (if f.err = .empty ∧ (s.takeWhile (· != 59)).length < s.length then { f with err := .emptyLevel } else f)
    | .ok l =>
      match s.drop (s.takeWhile (· != 59)).length with
      | [] => .ok ⟨l, 0⟩
      | _ :: rest =>
        if (trimmed rest ((s.takeWhile (· != 59)).length + 1)).2 = 0 then
          .error ⟨.emptyTrust, (trimmed rest ((s.takeWhile (· != 59)).length + 1)).1, 0⟩
        else match findName tc.trusts rest with
          | none => .error ⟨.unknownTrust, (trimmed rest ((s.takeWhile (· != 59)).length + 1)).1,
              (trimmed rest ((s.takeWhile (· != 59)).length + 1)).2⟩
          | some t => .ok ⟨l, t⟩

def trustSuffix (tc : TConfig) (t : Nat) : List Nat := if t = 0 then [] else 59 :: tc.trusts.getD t []

def formatT (tc : TConfig) (l : TLabel) : Option (List Nat) :=
  if l.trust < trustCount tc.trusts.length then
    match format tc.base l.sec with
    | none => none
    | some s => some (s ++ trustSuffix tc l.trust)
  else none

theorem trustCheck_spec {tc : TConfig} {raw n : List Nat} (h : trustCheck tc raw = .ok n) :
    n = normalise raw ∧ nameCanonical n = true ∧ n ∉ tc.trusts := by
  unfold trustCheck at h
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
          simp only [decide_eq_true_eq] at hd
          exact ⟨rfl, hc', hd⟩

theorem addTrust_ok {tc tc' : TConfig} {raw : List Nat} (h : TrustsOk tc) (hr : addTrust tc raw = .ok tc') :
    TrustsOk tc' ∧ tc'.base = tc.base ∧ tc'.trusts = tc.trusts ++ [normalise raw] := by
  unfold addTrust at hr
  split at hr
  · simp at hr
  · rename_i hlim
    split at hr
    · simp at hr
    · rename_i n hn
      simp only [Except.ok.injEq] at hr
      subst hr
      obtain ⟨rfl, hcan, hnt⟩ := trustCheck_spec hn
      obtain ⟨h1, h2, h3⟩ := h
      refine ⟨⟨?_, ?_, ?_⟩, rfl, rfl⟩
      · simp only [List.length_append, List.length_singleton]; unfold trustLimit at *; omega
      · intro m hm
        simp only [List.mem_append, List.mem_singleton] at hm
        rcases hm with hm | hm
        · exact h2 m hm
        · subst hm; exact hcan
      · rw [List.nodup_append]
        refine ⟨h3, List.nodup_cons.2 ⟨by simp, List.nodup_nil⟩, ?_⟩
        intro a ha b hb
        simp only [List.mem_singleton] at hb
        subst hb
        intro he
        subst he
        exact hnt ha

theorem getD_mem_or_nil (xs : List (List Nat)) (i : Nat) : xs.getD i [] ∈ xs ∨ xs.getD i [] = [] := by
  rw [List.getD_eq_getElem?_getD]
  cases h : xs[i]? with
  | none => right; rfl
  | some x => left; exact List.mem_of_getElem? h

theorem getD_canonical {xs : List (List Nat)} (hx : ∀ n ∈ xs, nameCanonical n = true) (i : Nat) :
    ∀ b ∈ xs.getD i [], nameByte b = true := by
  intro b hb
  rcases getD_mem_or_nil xs i with hm | hn
  · exact canonical_bytes (hx _ hm) b hb
  · rw [hn] at hb; simp at hb

theorem getD_length {xs : List (List Nat)} (hx : ∀ n ∈ xs, nameCanonical n = true) (i : Nat) :
    (xs.getD i []).length ≤ nameMax := by
  rcases getD_mem_or_nil xs i with hm | hn
  · exact canonical_len (hx _ hm)
  · rw [hn]; simp

theorem format_bytes {c : Config} (hc : ConfigOk c) {l : Label} {s : List Nat} (h : format c l = some s) :
    ∀ b ∈ s, nameByte b = true ∨ b = 47 := by
  have hcan := names_canonical hc
  have hlev := getD_canonical (xs := c.levels) (fun n hn => hcan n (List.mem_append_left _ hn))
  have hcomp := getD_canonical (xs := c.comps) (fun n hn => hcan n (List.mem_append_right _ hn))
  unfold format at h
  split at h
  · simp only [Option.some.injEq] at h
    subst h
    intro b hb
    rcases List.mem_append.1 hb with hb | hb
    · exact Or.inl (hlev l.level b hb)
    · split at hb
      · simp at hb
      · simp only [List.mem_cons] at hb
        rcases hb with hb | hb | hb
        · exact Or.inr hb
        · exact Or.inr hb
        · rcases intercalate_mem hb with hb | ⟨x, hx, hbx⟩
          · exact Or.inr hb
          · obtain ⟨k, _, rfl⟩ := List.mem_map.1 hx
            exact Or.inl (hcomp k b hbx)
  · simp at h

theorem format_short {c : Config} (hc : ConfigOk c) {l : Label} {s : List Nat} (h : format c l = some s) :
    s.length ≤ nameMax + 2 + (nameMax + 1) * compLimit := by
  have hcan := names_canonical hc
  unfold format at h
  split at h
  · simp only [Option.some.injEq] at h
    subst h
    have h1 := getD_length (xs := c.levels) (fun n hn => hcan n (List.mem_append_left _ hn)) l.level
    have h2 := intercalate_length_le (xs := (idsOf l.comps compLimit).map (c.comps.getD · []))
      (fun x hx => by
        obtain ⟨k, _, rfl⟩ := List.mem_map.1 hx
        exact getD_length (fun n hn => hcan n (List.mem_append_right _ hn)) k)
    have h3 : (idsOf l.comps compLimit).length ≤ compLimit := idsOf_length _ _
    have h4 : (nameMax + 1) * (idsOf l.comps compLimit).length ≤ (nameMax + 1) * compLimit := Nat.mul_le_mul_left _ h3
    simp only [List.length_map] at h2
    generalize c.levels.getD l.level [] = name at *
    generalize idsOf l.comps compLimit = ids at *
    rw [List.length_append]
    split
    · simp only [List.length_nil]; omega
    · simp only [List.length_cons]
      omega
  · simp at h

theorem nameByte_ne_semicolon {b : Nat} (h : nameByte b = true) : b ≠ 59 := by
  unfold nameByte at h
  simp only [Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at h
  omega

theorem trust_lt_of_ne {tc : TConfig} {t : Nat} (h : t < trustCount tc.trusts.length) (h0 : t ≠ 0) :
    t < tc.trusts.length := by
  unfold trustCount at h
  omega

theorem formatT_parts {tc : TConfig} {l : TLabel} {s : List Nat} (h : formatT tc l = some s) :
    l.trust < trustCount tc.trusts.length ∧ ∃ sec, format tc.base l.sec = some sec ∧ s = sec ++ trustSuffix tc l.trust := by
  unfold formatT at h
  split at h
  · rename_i ht
    split at h
    · simp at h
    · rename_i sec hsec
      simp only [Option.some.injEq] at h
      exact ⟨ht, sec, hsec, h.symm⟩
  · simp at h

theorem parseT_formatT {tc : TConfig} (hc : TConfigOk tc) {l : TLabel} {s : List Nat} (h : formatT tc l = some s) :
    parseT tc s = .ok l := by
  obtain ⟨ht, sec, hsec, rfl⟩ := formatT_parts h
  have hb := format_bytes hc.1 hsec
  have hshort := format_short hc.1 hsec
  have hp := parse_format hc.1 hsec
  have hsemi : ∀ b ∈ sec, b ≠ 59 := fun b hm => by
    rcases hb b hm with hn | hs
    · exact nameByte_ne_semicolon hn
    · omega
  have hsecm : ∀ b ∈ sec, markingByte b = true := fun b hm => by
    rcases hb b hm with hn | hs
    · exact nameByte_marking hn
    · subst hs; rfl
  have htake : (sec ++ trustSuffix tc l.trust).takeWhile (· != 59) = sec := by
    rw [List.takeWhile_append_of_pos (fun b hm => by simpa using hsemi b hm)]
    unfold trustSuffix
    split
    · simp
    · simp
  have hdrop : (sec ++ trustSuffix tc l.trust).drop sec.length = trustSuffix tc l.trust := by simp
  unfold parseT
  by_cases h0 : l.trust = 0
  · have hsuf : trustSuffix tc l.trust = [] := by simp [trustSuffix, h0]
    rw [hsuf] at htake hdrop ⊢
    have hlen : ¬ markingMax < (sec ++ []).length := by
      simp only [List.append_nil]; unfold markingMax nameMax compLimit at *; omega
    have hfind : (sec ++ []).findIdx? (fun b => !markingByte b) = none := by
      rw [List.findIdx?_eq_none_iff]
      intro b hm
      simp [hsecm b (by simpa using hm)]
    simp only [hlen, ↓reduceIte, hfind, htake, hp, hdrop]
    exact congrArg Except.ok (tlabel_ext rfl h0.symm)
  · have hlt := trust_lt_of_ne ht h0
    have hget : tc.trusts[l.trust]? = some (tc.trusts.getD l.trust []) := by
      rw [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hlt]; rfl
    have hname : nameCanonical (tc.trusts.getD l.trust []) = true :=
      hc.2.2.1 _ (List.mem_of_getElem? hget)
    have hsuf : trustSuffix tc l.trust = 59 :: tc.trusts.getD l.trust [] := by simp [trustSuffix, h0]
    rw [hsuf] at htake hdrop ⊢
    generalize hn : tc.trusts.getD l.trust [] = name at *
    have hlen : ¬ markingMax < (sec ++ 59 :: name).length := by
      have := canonical_len hname
      simp only [List.length_append, List.length_cons]
      unfold markingMax nameMax compLimit at *; omega
    have hfind : (sec ++ 59 :: name).findIdx? (fun b => !markingByte b) = none := by
      rw [List.findIdx?_eq_none_iff]
      intro b hm
      rcases List.mem_append.1 hm with hm | hm
      · simp [hsecm b hm]
      · simp only [List.mem_cons] at hm
        rcases hm with hm | hm
        · subst hm; rfl
        · simp [nameByte_marking (canonical_bytes hname b hm)]
    have htrim : trimmed name (sec.length + 1) = (sec.length + 1, name.length) := trimmed_canonical hname _
    have hpos : ¬ name.length = 0 := Nat.ne_of_gt (canonical_pos hname)
    have hfl : findName tc.trusts name = some l.trust := findName_canonical hc.2.2.2 hget hname
    simp only [hlen, ↓reduceIte, hfind, htake, hp, hdrop, htrim, hpos, hfl]

theorem parseT_valid {tc : TConfig} {s : List Nat} {l : TLabel} (h : parseT tc s = .ok l) : LabelOkT tc l := by
  unfold parseT at h
  split at h
  · simp at h
  · split at h
    · simp at h
    · split at h
      · simp at h
      · rename_i sl hsl
        have hv := parse_valid hsl
        split at h
        · simp only [Except.ok.injEq] at h
          subst h
          exact ⟨hv, by unfold trustCount; simp; omega⟩
        · split at h
          · simp at h
          · split at h
            · simp at h
            · rename_i t ht
              simp only [Except.ok.injEq] at h
              subst h
              have := findName_lt ht
              exact ⟨hv, by unfold trustCount; simp only; omega⟩

theorem labelValidT_iff (tc : TConfig) (l : TLabel) : labelValidT tc l = true ↔ LabelOkT tc l := by
  unfold labelValidT LabelOkT ValidT
  rw [Bool.and_eq_true, labelValid_iff, decide_eq_true_iff]
  rfl

theorem formatT_total {tc : TConfig} {l : TLabel} (hl : LabelOkT tc l) : ∃ s, formatT tc l = some s := by
  obtain ⟨sec, hsec⟩ := format_total hl.1
  exact ⟨sec ++ trustSuffix tc l.trust, by unfold formatT; simp [hl.2, hsec]⟩

theorem formatT_parseT {tc : TConfig} (hc : TConfigOk tc) {s : List Nat} {l : TLabel} (h : parseT tc s = .ok l) :
    ∃ s', formatT tc l = some s' ∧ parseT tc s' = .ok l := by
  obtain ⟨s', hs'⟩ := formatT_total (parseT_valid h)
  exact ⟨s', hs', parseT_formatT hc hs'⟩

theorem formatT_injective {tc : TConfig} (hc : TConfigOk tc) {l1 l2 : TLabel} {s : List Nat}
    (h1 : formatT tc l1 = some s) (h2 : formatT tc l2 = some s) : l1 = l2 := by
  have a := parseT_formatT hc h1
  have b := parseT_formatT hc h2
  rw [a] at b
  exact Except.ok.inj b

theorem formatT_length {tc : TConfig} (hc : TConfigOk tc) {l : TLabel} {s : List Nat} (h : formatT tc l = some s) :
    s.length ≤ markingMax := by
  have hp := parseT_formatT hc h
  unfold parseT at hp
  split at hp
  · simp at hp
  · rename_i hlen
    exact Nat.le_of_not_lt hlen

theorem formatT_secrecy {tc : TConfig} {l : TLabel} (h0 : l.trust = 0) {s : List Nat} :
    formatT tc l = some s ↔ format tc.base l.sec = some s := by
  unfold formatT
  have h1 : 0 < trustCount tc.trusts.length := by unfold trustCount; omega
  simp only [h0, h1, ↓reduceIte, trustSuffix]
  cases format tc.base l.sec <;> simp

end Labels
