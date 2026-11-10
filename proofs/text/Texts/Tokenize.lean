import Texts.Classes

namespace Texts

structure Tok where
  text : List Nat
  start : Nat
  stop : Nat
  tailFrom : Nat
deriving Repr, DecidableEq

def scanBody (rs : List Nat) : List Nat × Nat × Bool :=
  match rs with
  | [] => ([], 0, false)
  | b :: rest =>
    if isSep b then ([], 0, false)
    else if b = 0 then ([], 0, true)
    else if isDropped b then
      let r := scanBody rest
      (r.1, r.2.1 + 1, r.2.2)
    else if b = 92 then
      if rest = [] then ([], 1, false)
      else if rest.headD 0 = 0 then ([], 1, true)
      else
        let r := scanBody rest.tail
        ((if isControl (rest.headD 0) then [] else [rest.headD 0]) ++ r.1, r.2.1 + 2, r.2.2)
    else
      let r := scanBody rest
      (b :: r.1, r.2.1 + 1, r.2.2)
termination_by rs.length
decreasing_by all_goals (simp_wf; try (cases rest <;> simp_all <;> omega))

def countSeps : List Nat → Nat
  | b :: rest => if isSep b then countSeps rest + 1 else 0
  | [] => 0

def tokenizeAux : Nat → List Nat → Nat → List Tok
  | 0, _, _ => []
  | f + 1, rs, pos =>
    match rs.drop (countSeps rs) with
    | [] => []
    | b :: rest1 =>
      if b = 0 then []
      else
        let r := scanBody (b :: rest1)
        let p1 := pos + countSeps rs
        let tail := if r.2.2 then [] else tokenizeAux f ((b :: rest1).drop r.2.1) (p1 + r.2.1)
        if r.1 = [] then tail else ⟨r.1, p1, p1 + r.2.1, p1 + r.1.length⟩ :: tail

def tokenize (src : List Nat) : List Tok := tokenizeAux (src.length + 1) src 0

def specAux (rs : List Nat) (cur : List Nat) : List (List Nat) :=
  match rs with
  | [] => [cur]
  | b :: rest =>
    if isSep b then cur :: specAux rest []
    else if b = 0 then [cur]
    else if isDropped b then specAux rest cur
    else if b = 92 then
      if rest = [] then [cur]
      else if rest.headD 0 = 0 then [cur]
      else specAux rest.tail (cur ++ (if isControl (rest.headD 0) then [] else [rest.headD 0]))
    else specAux rest (cur ++ [b])
termination_by rs.length
decreasing_by all_goals (simp_wf; try (cases rest <;> simp_all <;> omega))

def specTexts (src : List Nat) : List (List Nat) := (specAux src []).filter (· ≠ [])

def Bytes (src : List Nat) : Prop := ∀ b ∈ src, b < 256

theorem scanBody_cons (b : Nat) (rest : List Nat) : scanBody (b :: rest) =
    if isSep b then ([], 0, false)
    else if b = 0 then ([], 0, true)
    else if isDropped b then ((scanBody rest).1, (scanBody rest).2.1 + 1, (scanBody rest).2.2)
    else if b = 92 then
      (match rest with
        | [] => ([], 1, false)
        | e :: rest' => if e = 0 then ([], 1, true)
            else ((if isControl e then [] else [e]) ++ (scanBody rest').1, (scanBody rest').2.1 + 2, (scanBody rest').2.2))
    else (b :: (scanBody rest).1, (scanBody rest).2.1 + 1, (scanBody rest).2.2) := by
  rw [scanBody.eq_2]
  cases rest <;> simp

theorem specAux_cons (b : Nat) (rest cur : List Nat) : specAux (b :: rest) cur =
    if isSep b then cur :: specAux rest []
    else if b = 0 then [cur]
    else if isDropped b then specAux rest cur
    else if b = 92 then
      (match rest with
        | [] => [cur]
        | e :: rest' => if e = 0 then [cur] else specAux rest' (cur ++ (if isControl e then [] else [e])))
    else specAux rest (cur ++ [b]) := by
  rw [specAux.eq_2]
  cases rest <;> simp

theorem scanBody_consumed : ∀ rs : List Nat, (scanBody rs).2.1 ≤ rs.length
  | [] => by simp [scanBody.eq_1]
  | b :: rest => by
    rw [scanBody_cons]
    have h1 := scanBody_consumed rest
    split
    · simp
    · split
      · simp
      · split
        · simp; omega
        · split
          · cases rest with
            | nil => simp
            | cons e rest' =>
              have h2 := scanBody_consumed rest'
              simp only
              split
              · simp
              · simp; omega
          · simp; omega

theorem scanBody_pos (b : Nat) (rest : List Nat) (hs : isSep b = false) (h0 : b ≠ 0) : 1 ≤ (scanBody (b :: rest)).2.1 := by
  rw [scanBody_cons]
  simp only [hs, Bool.false_eq_true, ↓reduceIte, h0]
  split
  · simp
  · split
    · cases rest with
      | nil => simp
      | cons e rest' => simp only; split <;> simp
    · simp

theorem specAux_body : ∀ (rs cur : List Nat),
    specAux rs cur = if (scanBody rs).2.2 then [cur ++ (scanBody rs).1]
      else specAux (rs.drop (scanBody rs).2.1) (cur ++ (scanBody rs).1)
  | [], cur => by simp [scanBody.eq_1]
  | b :: rest, cur => by
    rw [scanBody_cons, specAux_cons]
    by_cases hs : isSep b = true
    · simp [hs, specAux_cons]
    · simp only [Bool.not_eq_true] at hs
      simp only [hs, Bool.false_eq_true, ↓reduceIte]
      by_cases h0 : b = 0
      · simp [h0]
      · simp only [h0, ↓reduceIte]
        by_cases hd : isDropped b = true
        · simp only [hd, ↓reduceIte, List.drop_succ_cons]
          exact specAux_body rest cur
        · simp only [Bool.not_eq_true] at hd
          simp only [hd, Bool.false_eq_true, ↓reduceIte]
          by_cases he : b = 92
          · simp only [he, ↓reduceIte]
            cases rest with
            | nil => simp [specAux.eq_1]
            | cons e rest' =>
              simp only
              by_cases he0 : e = 0
              · simp [he0]
              · simp only [he0, ↓reduceIte, List.drop_succ_cons]
                rw [specAux_body rest' (cur ++ if isControl e = true then [] else [e])]
                simp [List.append_assoc]
          · simp only [he, ↓reduceIte, List.drop_succ_cons]
            rw [specAux_body rest (cur ++ [b])]
            simp [List.append_assoc]

theorem scanBody_stop : ∀ rs : List Nat, (scanBody rs).2.2 = false →
    rs.drop (scanBody rs).2.1 = [] ∨ ∃ s rest, rs.drop (scanBody rs).2.1 = s :: rest ∧ isSep s = true
  | [], _ => by simp [scanBody.eq_1]
  | b :: rest, h => by
    rw [scanBody_cons] at h ⊢
    by_cases hs : isSep b = true
    · right; exact ⟨b, rest, by simp [hs], hs⟩
    · simp only [Bool.not_eq_true] at hs
      simp only [hs, Bool.false_eq_true, ↓reduceIte] at h ⊢
      by_cases h0 : b = 0
      · simp [h0] at h
      · simp only [h0, ↓reduceIte] at h ⊢
        by_cases hd : isDropped b = true
        · simp only [hd, ↓reduceIte, List.drop_succ_cons] at h ⊢
          exact scanBody_stop rest h
        · simp only [Bool.not_eq_true] at hd
          simp only [hd, Bool.false_eq_true, ↓reduceIte] at h ⊢
          by_cases he : b = 92
          · simp only [he, ↓reduceIte] at h ⊢
            cases rest with
            | nil => left; simp
            | cons e rest' =>
              simp only at h ⊢
              by_cases he0 : e = 0
              · simp [he0] at h
              · simp only [he0, ↓reduceIte, List.drop_succ_cons] at h ⊢
                exact scanBody_stop rest' h
          · simp only [he, ↓reduceIte, List.drop_succ_cons] at h ⊢
            exact scanBody_stop rest h

theorem specAux_seps : ∀ (rs : List Nat), (specAux rs []).filter (· ≠ []) = (specAux (rs.drop (countSeps rs)) []).filter (· ≠ [])
  | [] => by simp [countSeps]
  | b :: rest => by
    by_cases hs : isSep b = true
    · simp only [countSeps, hs, ↓reduceIte, List.drop_succ_cons]
      rw [specAux_cons]
      simp only [hs, ↓reduceIte]
      rw [List.filter_cons]
      simp only [ne_eq, not_true_eq_false, decide_false, Bool.false_eq_true, ↓reduceIte]
      exact specAux_seps rest
    · simp only [Bool.not_eq_true] at hs
      simp [countSeps, hs]

theorem drop_countSeps_head : ∀ (rs : List Nat) (b : Nat) (rest : List Nat), rs.drop (countSeps rs) = b :: rest → isSep b = false
  | [], _, _, h => by simp [countSeps] at h
  | x :: xs, b, rest, h => by
    by_cases hx : isSep x = true
    · simp only [countSeps, hx, ↓reduceIte, List.drop_succ_cons] at h
      exact drop_countSeps_head xs b rest h
    · simp only [Bool.not_eq_true] at hx
      simp only [countSeps, hx, Bool.false_eq_true, ↓reduceIte, List.drop_zero, List.cons.injEq] at h
      rw [← h.1]; exact hx

theorem tokenize_spec_aux : ∀ (fuel : Nat) (rs : List Nat) (pos : Nat), rs.length < fuel →
    (tokenizeAux fuel rs pos).map Tok.text = (specAux rs []).filter (· ≠ [])
  | 0, _, _, h => absurd h (Nat.not_lt_zero _)
  | f + 1, rs, pos, h => by
    rw [specAux_seps]
    unfold tokenizeAux
    have hdrop : (rs.drop (countSeps rs)).length ≤ rs.length := by simp
    split
    · rename_i hnil
      rw [hnil]; simp [specAux.eq_1]
    · rename_i b rest1 hcons
      rw [hcons]
      have hs := drop_countSeps_head rs b rest1 hcons
      by_cases h0 : b = 0
      · subst h0; rw [specAux_cons]; simp [hs]
      · simp only [h0, ↓reduceIte]
        have hlen : (b :: rest1).length ≤ rs.length := by rw [← hcons]; exact hdrop
        have hpos := scanBody_pos b rest1 hs h0
        have hcons_le := scanBody_consumed (b :: rest1)
        rw [specAux_body (b :: rest1) []]
        simp only [List.nil_append]
        by_cases hn : (scanBody (b :: rest1)).2.2 = true
        · simp only [hn, ↓reduceIte]
          by_cases he : (scanBody (b :: rest1)).1 = []
          · simp [he]
          · simp [he]
        · simp only [Bool.not_eq_true] at hn
          simp only [hn, Bool.false_eq_true, ↓reduceIte]
          have hl2 : ((b :: rest1).drop (scanBody (b :: rest1)).2.1).length < f := by
            rw [List.length_drop]; omega
          have ih := tokenize_spec_aux f ((b :: rest1).drop (scanBody (b :: rest1)).2.1)
            (pos + countSeps rs + (scanBody (b :: rest1)).2.1) hl2
          rcases scanBody_stop (b :: rest1) hn with hstop | ⟨s, rest2, hstop, hsep⟩
          · rw [hstop] at ih ⊢
            simp only [specAux.eq_1] at ih ⊢
            by_cases he : (scanBody (b :: rest1)).1 = []
            · simp only [he, ↓reduceIte]; simp at ih ⊢; exact ih
            · simp only [he, ↓reduceIte, List.map_cons]; rw [ih]; simp [he]
          · rw [hstop] at ih ⊢
            rw [specAux_cons] at ih ⊢
            simp only [hsep, ↓reduceIte] at ih ⊢
            rw [List.filter_cons] at ih ⊢
            simp only [ne_eq, not_true_eq_false, decide_false, Bool.false_eq_true, ↓reduceIte] at ih
            by_cases he : (scanBody (b :: rest1)).1 = []
            · simp only [he, ↓reduceIte]; simp; exact ih
            · simp only [he, ↓reduceIte, List.map_cons]; rw [ih]; simp [he]

theorem tokenize_spec (src : List Nat) : (tokenize src).map Tok.text = specTexts src :=
  tokenize_spec_aux (src.length + 1) src 0 (Nat.lt_succ_self _)

theorem scanBody_clean : ∀ rs : List Nat, Bytes rs → ∀ x ∈ (scanBody rs).1, isControl x = false ∧ x < 256
  | [], _ => by simp [scanBody.eq_1]
  | b :: rest, hb => by
    have hb0 := hb b (by simp)
    have hrest : Bytes rest := fun x hx => hb x (by simp [hx])
    intro x hx
    rw [scanBody_cons] at hx
    by_cases hs : isSep b = true
    · simp [hs] at hx
    · simp only [Bool.not_eq_true] at hs
      simp only [hs, Bool.false_eq_true, ↓reduceIte] at hx
      by_cases h0 : b = 0
      · simp [h0] at hx
      · simp only [h0, ↓reduceIte] at hx
        by_cases hd : isDropped b = true
        · simp only [hd, ↓reduceIte] at hx
          exact scanBody_clean rest hrest x hx
        · simp only [Bool.not_eq_true] at hd
          simp only [hd, Bool.false_eq_true, ↓reduceIte] at hx
          by_cases he : b = 92
          · simp only [he, ↓reduceIte] at hx
            cases rest with
            | nil => simp at hx
            | cons e rest' =>
              have he256 := hrest e (by simp)
              have hrest' : Bytes rest' := fun y hy => hrest y (by simp [hy])
              simp only at hx
              by_cases he0 : e = 0
              · simp [he0] at hx
              · simp only [he0, ↓reduceIte, List.mem_append] at hx
                rcases hx with hx | hx
                · by_cases hc : isControl e = true
                  · simp [hc] at hx
                  · simp only [hc, Bool.false_eq_true, ↓reduceIte, List.mem_singleton] at hx
                    subst hx; exact ⟨by simpa using hc, he256⟩
                · exact scanBody_clean rest' hrest' x hx
          · simp only [he, ↓reduceIte, List.mem_cons] at hx
            rcases hx with hx | hx
            · subst hx
              have hsp : isSpecial x = false := by simp [isSpecial, hs, hd, isEnd, isEscape, h0, he]
              exact ⟨plain_not_control x hb0 hsp, hb0⟩
            · exact scanBody_clean rest hrest x hx

theorem tokenize_clean : ∀ (fuel : Nat) (rs : List Nat) (pos : Nat), Bytes rs →
    ∀ t ∈ tokenizeAux fuel rs pos, t.text ≠ [] ∧ ∀ x ∈ t.text, isControl x = false ∧ x < 256
  | 0, _, _, _ => by simp [tokenizeAux]
  | f + 1, rs, pos, hb => by
    intro t ht
    unfold tokenizeAux at ht
    split at ht
    · simp at ht
    · rename_i b rest1 hcons
      have hb1 : Bytes (b :: rest1) := fun x hx => hb x (by
        have : x ∈ rs.drop (countSeps rs) := by rw [hcons]; exact hx
        exact List.mem_of_mem_drop this)
      split at ht
      · simp at ht
      · simp only at ht
        have htail : ∀ u ∈ (if (scanBody (b :: rest1)).2.2 = true then []
            else tokenizeAux f ((b :: rest1).drop (scanBody (b :: rest1)).2.1) (pos + countSeps rs + (scanBody (b :: rest1)).2.1)),
            u.text ≠ [] ∧ ∀ x ∈ u.text, isControl x = false ∧ x < 256 := by
          intro u hu
          split at hu
          · simp at hu
          · exact tokenize_clean f _ _ (fun x hx => hb1 x (List.mem_of_mem_drop hx)) u hu
        split at ht
        · exact htail t ht
        · rename_i hne
          rcases List.mem_cons.1 ht with e | e
          · subst e; exact ⟨hne, scanBody_clean _ hb1⟩
          · exact htail t e

end Texts
