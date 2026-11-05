import Storage.Placement

namespace Storage

def groupFloor (groups g : Nat) : Nat :=
  if g = 0 ∨ groups ≤ g then 0 else (g * wordSpan + (groups - 1)) / groups

def homeKeys (xs : List Cell) (groups home g : Nat) : List Nat :=
  (groupIndices g).filterMap fun i => match (xs[i]? : Option Cell) with
    | some (Cell.live e) => if hashHome e.hash groups = home then some e.key else none
    | _ => none

def takePath (xs : List Cell) (groups home : Nat) : List Nat → List Nat
  | [] => []
  | g :: rest => homeKeys xs groups home g ++ (if groupEmpty xs g then [] else takePath xs groups home rest)

def takeHome (xs : List Cell) (home : Nat) : List Nat :=
  takePath xs (groupsOf xs) home (probeGroups (groupsOf xs) home)

def scanRound (b : Banks) (cursor : Nat) : List Nat × Nat :=
  if b.cursor < 0 then
    let home := hashHome cursor (groupsOf b.src.slots)
    (takeHome b.src.slots home, groupFloor (groupsOf b.src.slots) (home + 1))
  else
    let swap := groupsOf b.dst.slots < groupsOf b.src.slots
    let narrow := if swap then b.dst.slots else b.src.slots
    let wide := if swap then b.src.slots else b.dst.slots
    let home := hashHome cursor (groupsOf narrow)
    let next := groupFloor (groupsOf narrow) (home + 1)
    let first := hashHome cursor (groupsOf wide)
    let last := hashHome ((next + wordSpan - 1) % wordSpan) (groupsOf wide)
    (takeHome narrow home ++ (List.range' first (last + 1 - first)).flatMap (takeHome wide), next)

def scanRun : List Banks → Nat → Option (List Nat)
  | [], _ => none
  | b :: rest, cursor =>
    let r := scanRound b cursor
    if r.2 = 0 then some r.1 else (scanRun rest r.2).map (r.1 ++ ·)

def Present (b : Banks) (key hash : Nat) : Prop :=
  ∃ (i : Nat) (e : Entry), e.key = key ∧ e.hash = hash ∧
    (b.src.slots[i]? = some (.live e) ∨ (0 ≤ b.cursor ∧ b.dst.slots[i]? = some (.live e)))

theorem walk_bounded (groups mask : Nat) : ∀ n pos step x, x ∈ walkFrom groups mask n pos step → x < groups := by
  intro n
  induction n with
  | zero => intro pos step x h; simp [walkFrom] at h
  | succ n ih =>
    intro pos step x h
    simp only [walkFrom] at h
    split at h
    next hp =>
      rcases List.mem_cons.mp h with rfl | hx
      · exact hp
      · exact ih _ _ x hx
    next => exact ih _ _ x h

theorem placed_groups_pos (xs : List Cell) (i hash : Nat) (h : Placed xs i hash) : 0 < groupsOf xs := by
  obtain ⟨before, g, after, hp, _, _⟩ := h
  have hm : g ∈ probeOf xs hash := by rw [hp]; simp
  have := walk_bounded _ _ _ _ _ g hm
  omega

theorem hash_home_mono (a h groups : Nat) (hle : a ≤ h) (hw : h < wordSpan) :
    hashHome a groups ≤ hashHome h groups := by
  unfold hashHome
  rw [Nat.mod_eq_of_lt (by omega), Nat.mod_eq_of_lt hw]
  exact Nat.div_le_div_right (Nat.mul_le_mul_right _ hle)

theorem below_group_floor (groups g h : Nat) (hg : 0 < g) (hG : g < groups) (hw : h < wordSpan) :
    h < groupFloor groups g ↔ hashHome h groups < g := by
  have pos : 0 < groups := by omega
  have wpos : 0 < wordSpan := by decide
  unfold groupFloor hashHome
  split
  · omega
  · rw [Nat.mod_eq_of_lt hw, Nat.div_lt_iff_lt_mul wpos]
    constructor
    · intro hl
      have hm := (Nat.le_div_iff_mul_le pos).mp
        (show h + 1 ≤ (g * wordSpan + (groups - 1)) / groups by omega)
      rw [Nat.add_mul, Nat.one_mul] at hm
      omega
    · intro hl
      apply Nat.lt_of_succ_le
      apply (Nat.le_div_iff_mul_le pos).mpr
      rw [Nat.succ_mul]
      omega

theorem group_floor_le (groups g : Nat) (hG : g < groups) : groupFloor groups g ≤ wordSpan := by
  have pos : 0 < groups := by omega
  have wpos : 0 < wordSpan := by decide
  unfold groupFloor
  split
  · exact Nat.zero_le _
  · apply Nat.le_of_lt_succ
    apply (Nat.div_lt_iff_lt_mul pos).mpr
    have hm : (g + 1) * wordSpan ≤ groups * wordSpan := Nat.mul_le_mul_right _ hG
    rw [Nat.add_mul, Nat.one_mul] at hm
    rw [Nat.succ_mul]
    have hw : wordSpan ≤ wordSpan * groups := Nat.le_mul_of_pos_right _ pos
    have hm2 : groups * wordSpan = wordSpan * groups := Nat.mul_comm _ _
    omega

theorem group_floor_pos (groups g : Nat) (hg : 0 < g) (hG : g < groups) : 0 < groupFloor groups g := by
  have pos : 0 < groups := by omega
  have wpos : 0 < wordSpan := by decide
  unfold groupFloor
  split
  · omega
  · apply (Nat.le_div_iff_mul_le pos).mpr
    have : wordSpan ≤ g * wordSpan := Nat.le_mul_of_pos_left _ hg
    omega

theorem group_floor_top (groups g : Nat) (hG : groups ≤ g) : groupFloor groups g = 0 := by
  unfold groupFloor
  split
  · rfl
  · omega

theorem home_keys_offers (xs : List Cell) (groups home g i : Nat) (e : Entry)
    (hi : i ∈ groupIndices g) (hs : xs[i]? = some (.live e)) (hh : hashHome e.hash groups = home) :
    e.key ∈ homeKeys xs groups home g := by
  apply List.mem_filterMap.mpr
  exact ⟨i, hi, by simp [hs, hh]⟩

theorem take_path_offers (xs : List Cell) (groups home i : Nat) (e : Entry) (before after : List Nat) (g : Nat)
    (hi : i ∈ groupIndices g) (hs : xs[i]? = some (.live e)) (hh : hashHome e.hash groups = home)
    (clear : ∀ prior ∈ before, GroupClear xs prior) :
    e.key ∈ takePath xs groups home (before ++ g :: after) := by
  induction before with
  | nil =>
    simp only [List.nil_append, takePath]
    exact List.mem_append_left _ (home_keys_offers xs groups home g i e hi hs hh)
  | cons prior rest ih =>
    simp only [List.cons_append, takePath]
    apply List.mem_append_right
    rw [clear_prevents_stop xs prior (clear prior (by simp))]
    exact ih (fun p hp => clear p (by simp [hp]))

theorem take_home_offers (xs : List Cell) (i : Nat) (e : Entry) (hs : xs[i]? = some (.live e))
    (wp : WellPlaced xs) : e.key ∈ takeHome xs (hashHome e.hash (groupsOf xs)) := by
  obtain ⟨before, g, after, hp, hi, hc⟩ := wp i e hs
  unfold takeHome
  have path : probeGroups (groupsOf xs) (hashHome e.hash (groupsOf xs)) = before ++ g :: after := hp
  rw [path]
  exact take_path_offers xs _ _ i e before after g hi hs rfl hc

theorem round_home (cursor h groups next : Nat) (pos : 0 < groups) (hc : cursor ≤ h) (hw : h < wordSpan)
    (hn : next = groupFloor groups (hashHome cursor groups + 1)) (hu : h < next ∨ next = 0) :
    hashHome h groups = hashHome cursor groups := by
  have lower := hash_home_mono cursor h groups hc hw
  have bound := hash_home_bounded h groups pos
  by_cases top : hashHome cursor groups + 1 < groups
  · have npos := group_floor_pos groups (hashHome cursor groups + 1) (by omega) top
    have hl : h < next := by rcases hu with hu | hu <;> omega
    rw [hn] at hl
    have := (below_group_floor groups _ h (by omega) top hw).mp hl
    omega
  · omega

theorem scan_round_covers (b : Banks) (cursor i : Nat) (e : Entry)
    (wsrc : WellPlaced b.src.slots) (wdst : WellPlaced b.dst.slots)
    (hc : cursor ≤ e.hash) (hw : e.hash < wordSpan)
    (hu : e.hash < (scanRound b cursor).2 ∨ (scanRound b cursor).2 = 0)
    (present : b.src.slots[i]? = some (.live e) ∨ (0 ≤ b.cursor ∧ b.dst.slots[i]? = some (.live e))) :
    e.key ∈ (scanRound b cursor).1 := by
  unfold scanRound at hu ⊢
  by_cases idle : b.cursor < 0
  · simp only [idle, ↓reduceIte] at hu ⊢
    rcases present with hs | ⟨hcur, _⟩
    · have pos := placed_groups_pos _ i e.hash (wsrc i e hs)
      have hh := round_home cursor e.hash (groupsOf b.src.slots) _ pos hc hw rfl hu
      rw [← hh]
      exact take_home_offers _ i e hs wsrc
    · omega
  · simp only [idle, ↓reduceIte] at hu ⊢
    have narrowWide : ∀ narrow wide : List Cell, WellPlaced narrow → WellPlaced wide →
        (narrow[i]? = some (.live e) ∨ wide[i]? = some (.live e)) →
        let home := hashHome cursor (groupsOf narrow)
        let next := groupFloor (groupsOf narrow) (home + 1)
        (e.hash < next ∨ next = 0) →
        e.key ∈ takeHome narrow home ++
          (List.range' (hashHome cursor (groupsOf wide))
            (hashHome ((next + wordSpan - 1) % wordSpan) (groupsOf wide) + 1 -
              hashHome cursor (groupsOf wide))).flatMap (takeHome wide) := by
      intro narrow wide wn ww hp home next hnext
      rcases hp with hs | hs
      · have pos := placed_groups_pos _ i e.hash (wn i e hs)
        have hh := round_home cursor e.hash (groupsOf narrow) next pos hc hw rfl hnext
        apply List.mem_append_left
        show e.key ∈ takeHome narrow (hashHome cursor (groupsOf narrow))
        rw [← hh]
        exact take_home_offers _ i e hs wn
      · apply List.mem_append_right
        have pos := placed_groups_pos _ i e.hash (ww i e hs)
        have upper : e.hash ≤ (next + wordSpan - 1) % wordSpan := by
          by_cases nz : next = 0
          · rw [nz]
            have : (0 + wordSpan - 1) % wordSpan = wordSpan - 1 := by decide
            omega
          · have hl : e.hash < next := by omega
            have narrowPos : 0 < groupsOf narrow := by
              apply Classical.byContradiction
              intro hz
              exact nz (group_floor_top _ _ (by omega))
            have nle : next ≤ wordSpan := by
              by_cases top : hashHome cursor (groupsOf narrow) + 1 < groupsOf narrow
              · exact group_floor_le _ _ top
              · exact absurd (group_floor_top _ _ (by omega)) nz
            have wpos : 0 < wordSpan := by decide
            have : (next + wordSpan - 1) % wordSpan = next - 1 := by
              have e2 : next + wordSpan - 1 = (next - 1) + wordSpan := by omega
              rw [e2, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega)]
            omega
        have upperW : (next + wordSpan - 1) % wordSpan < wordSpan := Nat.mod_lt _ (by decide)
        have lo := hash_home_mono cursor e.hash (groupsOf wide) hc hw
        have hi := hash_home_mono e.hash _ (groupsOf wide) upper upperW
        apply List.mem_flatMap.mpr
        refine ⟨hashHome e.hash (groupsOf wide), ?_, take_home_offers _ i e hs ww⟩
        apply List.mem_range'.mpr
        exact ⟨hashHome e.hash (groupsOf wide) - hashHome cursor (groupsOf wide), by omega, by omega⟩
    have hp : b.src.slots[i]? = some (.live e) ∨ b.dst.slots[i]? = some (.live e) := by
      rcases present with hs | ⟨_, hs⟩
      · exact Or.inl hs
      · exact Or.inr hs
    by_cases hsw : groupsOf b.dst.slots < groupsOf b.src.slots
    · simp only [hsw, ↓reduceIte] at hu ⊢
      exact narrowWide b.dst.slots b.src.slots wdst wsrc hp.symm hu
    · simp only [hsw, ↓reduceIte] at hu ⊢
      exact narrowWide b.src.slots b.dst.slots wsrc wdst hp hu

theorem scan_round_advances (b : Banks) (cursor : Nat) (hw : cursor < wordSpan) :
    (scanRound b cursor).2 = 0 ∨ cursor < (scanRound b cursor).2 := by
  have step : ∀ groups, groupFloor groups (hashHome cursor groups + 1) = 0 ∨
      cursor < groupFloor groups (hashHome cursor groups + 1) := by
    intro groups
    by_cases top : hashHome cursor groups + 1 < groups
    · exact Or.inr ((below_group_floor groups _ cursor (by omega) top hw).mpr (by omega))
    · exact Or.inl (group_floor_top _ _ (by omega))
  unfold scanRound
  split
  · exact step _
  · exact step _

theorem scan_visits_present_keys (states : List Banks) (cursor key hash : Nat) (keys : List Nat)
    (run : scanRun states cursor = some keys) (hc : cursor ≤ hash) (hw : hash < wordSpan)
    (sound : ∀ b ∈ states, WellPlaced b.src.slots ∧ WellPlaced b.dst.slots)
    (present : ∀ b ∈ states, Present b key hash) : key ∈ keys := by
  induction states generalizing cursor keys with
  | nil => simp [scanRun] at run
  | cons b rest ih =>
    obtain ⟨ws, wd⟩ := sound b (by simp)
    obtain ⟨i, e, hk, hh, hp⟩ := present b (by simp)
    subst hk
    subst hh
    simp only [scanRun] at run
    split at run
    next hz =>
      simp only [Option.some.injEq] at run
      subst run
      exact scan_round_covers b cursor i e ws wd hc hw (Or.inr hz) hp
    next hz =>
      obtain ⟨more, hmore, rfl⟩ := Option.map_eq_some_iff.mp run
      by_cases below : e.hash < (scanRound b cursor).2
      · exact List.mem_append_left _ (scan_round_covers b cursor i e ws wd hc hw (Or.inl below) hp)
      · apply List.mem_append_right
        exact ih (scanRound b cursor).2 more hmore (by omega)
          (fun b' hb' => sound b' (by simp [hb']))
          (fun b' hb' => present b' (by simp [hb']))

end Storage
