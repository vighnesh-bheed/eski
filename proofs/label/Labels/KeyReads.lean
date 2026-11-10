import Labels.KeyModel

namespace Labels

section KeyReads
set_option linter.unusedSectionVars false
variable {N V : Type} [DecidableEq N]

def uniq : List N → List N
  | [] => []
  | x :: xs => if x ∈ uniq xs then uniq xs else x :: uniq xs

theorem mem_uniq {x : N} : ∀ {l : List N}, x ∈ uniq l ↔ x ∈ l
  | [] => by simp [uniq]
  | y :: ys => by
    have ih := @mem_uniq x ys
    by_cases h : y ∈ uniq ys
    · simp only [uniq, h, ↓reduceIte, List.mem_cons]
      constructor
      · intro hx; exact Or.inr (ih.1 hx)
      · rintro (rfl | hx)
        · exact h
        · exact ih.2 hx
    · simp only [uniq, h, ↓reduceIte, List.mem_cons]
      rw [ih]

theorem uniq_nodup : ∀ (l : List N), (uniq l).Nodup
  | [] => List.nodup_nil
  | y :: ys => by
    by_cases h : y ∈ uniq ys
    · simp only [uniq, h, ↓reduceIte]
      exact uniq_nodup ys
    · simp only [uniq, h, ↓reduceIte]
      exact List.nodup_cons.2 ⟨h, uniq_nodup ys⟩

def visibleNames (s : KState N V) (R : TLabel) : List N :=
  uniq ((s.copies.filter (fun c => domT R c.label)).map (·.name))

def visParts (s : KState N V) (R : TLabel) : List TLabel := s.parts.filter (fun l => domT R l)

inductive KQ (N : Type) where
  | get (n : N)
  | many (ns : List N)
  | labelOf (n : N)
  | dbsize
  | keys (p : N → Bool)
  | scan (k : Nat)

inductive KReply (N V : Type) where
  | copy (c : Option (KCopy N V))
  | copies (cs : List (Option (KCopy N V)))
  | label (l : Option TLabel)
  | size (k : Nat)
  | names (ns : List N)
  | scanned (bound : Nat) (ns : List N)

def inParts (ord : List TLabel → List TLabel) (s : KState N V) (R : TLabel) (k : Nat) (n : N) : Bool :=
  match resolve s R n with
  | some c => decide (c.label ∈ (ord (visParts s R)).drop k)
  | none => false

def kreply (ord : List TLabel → List TLabel) (q : KQ N) (s : KState N V) (R : TLabel) : KReply N V :=
  match q with
  | .get n => .copy (resolve s R n)
  | .many ns => .copies (ns.map (resolve s R))
  | .labelOf n => .label ((resolve s R n).map (·.label))
  | .dbsize => .size (visibleNames s R).length
  | .keys p => .names ((visibleNames s R).filter p)
  | .scan k => .scanned (ord (visParts s R)).length ((visibleNames s R).filter (inParts ord s R k))

theorem restrict_copies_filter (R : TLabel) (s : KState N V) :
    (restrict R s).copies.filter (fun c => domT R c.label) = s.copies.filter (fun c => domT R c.label) := by
  unfold restrict
  simp [List.filter_filter]

theorem visibleNames_restrict (R : TLabel) (s : KState N V) : visibleNames (restrict R s) R = visibleNames s R := by
  unfold visibleNames
  rw [restrict_copies_filter]

theorem visParts_restrict (R : TLabel) (s : KState N V) : visParts (restrict R s) R = visParts s R := by
  unfold visParts restrict
  simp [List.filter_filter]

theorem inParts_restrict (ord : List TLabel → List TLabel) (R : TLabel) (s : KState N V) (k : Nat) :
    inParts ord (restrict R s) R k = inParts ord s R k := by
  funext n
  unfold inParts
  rw [resolve_restrict, visParts_restrict]

theorem kreply_restrict (ord : List TLabel → List TLabel) (q : KQ N) (R : TLabel) (s : KState N V) :
    kreply ord q (restrict R s) R = kreply ord q s R := by
  cases q with
  | get n => simp only [kreply, resolve_restrict]
  | many ns => simp only [kreply]; congr 1; apply List.map_congr_left; intro n _; exact resolve_restrict R s n
  | labelOf n => simp only [kreply, resolve_restrict]
  | dbsize => simp only [kreply, visibleNames_restrict]
  | keys p => simp only [kreply, visibleNames_restrict]
  | scan k => simp only [kreply, visibleNames_restrict, visParts_restrict, inParts_restrict]

theorem mem_visibleNames {s : KState N V} {R : TLabel} {n : N} :
    n ∈ visibleNames s R ↔ (resolve s R n).isSome := by
  unfold visibleNames
  rw [mem_uniq]
  constructor
  · intro h
    obtain ⟨c, hc, rfl⟩ := List.mem_map.1 h
    obtain ⟨hm, hv⟩ := List.mem_filter.1 hc
    cases hr : resolve s R c.name with
    | some _ => rfl
    | none =>
      have := resolve_none.1 hr c hm rfl
      rw [this] at hv
      simp at hv
  · intro h
    cases hr : resolve s R n with
    | none => rw [hr] at h; simp at h
    | some c =>
      obtain ⟨h1, h2, h3⟩ := resolve_visible hr
      exact List.mem_map.2 ⟨c, List.mem_filter.2 ⟨h1, h3⟩, h2⟩

theorem visibleNames_nodup (s : KState N V) (R : TLabel) : (visibleNames s R).Nodup := uniq_nodup _

theorem get_visible {ord : List TLabel → List TLabel} {s : KState N V} {R : TLabel} {n : N} {c : KCopy N V}
    (h : kreply ord (.get n) s R = .copy (some c)) : c ∈ s.copies ∧ c.name = n ∧ domT R c.label = true := by
  simp only [kreply, KReply.copy.injEq] at h
  exact resolve_visible h

theorem labelOf_visible {ord : List TLabel → List TLabel} {s : KState N V} {R : TLabel} {n : N} {l : TLabel}
    (h : kreply ord (.labelOf n) s R = .label (some l)) :
    ∃ c ∈ s.copies, c.name = n ∧ c.label = l ∧ domT R l = true := by
  simp only [kreply, KReply.label.injEq] at h
  cases hr : resolve s R n with
  | none => rw [hr] at h; simp at h
  | some c =>
    rw [hr] at h
    simp only [Option.map_some, Option.some.injEq] at h
    obtain ⟨h1, h2, h3⟩ := resolve_visible hr
    exact ⟨c, h1, h2, h, h ▸ h3⟩

theorem dbsize_spec (ord : List TLabel → List TLabel) (s : KState N V) (R : TLabel) :
    ∃ ns : List N, ns.Nodup ∧ (∀ n, n ∈ ns ↔ (resolve s R n).isSome) ∧ kreply ord .dbsize s R = .size ns.length :=
  ⟨visibleNames s R, visibleNames_nodup s R, fun _ => mem_visibleNames, rfl⟩

theorem keys_spec {ord : List TLabel → List TLabel} {s : KState N V} {R : TLabel} {p : N → Bool} {ns : List N}
    (h : kreply ord (.keys p) s R = .names ns) : ns.Nodup ∧ ∀ n, n ∈ ns ↔ p n = true ∧ (resolve s R n).isSome := by
  simp only [kreply, KReply.names.injEq] at h
  subst h
  refine ⟨(visibleNames_nodup s R).filter p, fun n => ?_⟩
  rw [List.mem_filter, mem_visibleNames]
  exact and_comm

def PartsCover (s : KState N V) : Prop := ∀ c ∈ s.copies, c.label ∈ s.parts

theorem scan_complete {ord : List TLabel → List TLabel} (hord : ∀ L l, l ∈ ord L ↔ l ∈ L)
    {s : KState N V} (hc : PartsCover s) (R : TLabel) :
    kreply ord (.scan 0) s R = .scanned (ord (visParts s R)).length (visibleNames s R) := by
  simp only [kreply, KReply.scanned.injEq, true_and]
  apply List.filter_eq_self.2
  intro n hn
  have hs := mem_visibleNames.1 hn
  unfold inParts
  cases hr : resolve s R n with
  | none => rw [hr] at hs; simp at hs
  | some c =>
    obtain ⟨h1, _, h3⟩ := resolve_visible hr
    simp only [List.drop_zero, decide_eq_true_eq]
    rw [hord]
    exact List.mem_filter.2 ⟨hc c h1, h3⟩

theorem scan_part {ord : List TLabel → List TLabel} {s : KState N V} {R : TLabel} {k : Nat} {b : Nat}
    {ns : List N} (h : kreply ord (.scan k) s R = .scanned b ns) :
    ∀ n ∈ ns, ∃ c, resolve s R n = some c ∧ c.label ∈ (ord (visParts s R)).drop k := by
  simp only [kreply, KReply.scanned.injEq] at h
  obtain ⟨_, rfl⟩ := h
  intro n hn
  have hp := (List.mem_filter.1 hn).2
  unfold inParts at hp
  cases hr : resolve s R n with
  | none => rw [hr] at hp; simp at hp
  | some c => rw [hr] at hp; exact ⟨c, rfl, by simpa using hp⟩

theorem random_visible (pickN : List N → Option N) (hp : ∀ l x, pickN l = some x → x ∈ l)
    (hn : ∀ l, pickN l = none → l = []) (s : KState N V) (R : TLabel) :
    (∀ x, pickN (visibleNames s R) = some x → ∃ c, resolve s R x = some c ∧ domT R c.label = true) ∧
    (pickN (visibleNames s R) = none → ∀ n, resolve s R n = none) := by
  constructor
  · intro x hx
    have hs := mem_visibleNames.1 (hp _ x hx)
    cases hr : resolve s R x with
    | none => rw [hr] at hs; simp at hs
    | some c => exact ⟨c, rfl, (resolve_visible hr).2.2⟩
  · intro hnone n
    have hnil := hn _ hnone
    cases hr : resolve s R n with
    | none => rfl
    | some c =>
      have : n ∈ visibleNames s R := mem_visibleNames.2 (by rw [hr]; rfl)
      rw [hnil] at this
      simp at this

theorem random_restrict (pickN : List N → Option N) (s : KState N V) (R : TLabel) :
    pickN (visibleNames (restrict R s) R) = pickN (visibleNames s R) := by
  rw [visibleNames_restrict]

end KeyReads

end Labels
