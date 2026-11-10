import Labels.MarkingTrust
import Labels.Rules

namespace Labels

structure LRules where
  clearTop : Bool
  clear : Option Label
  trustTop : Bool
  trust : Option Nat
  perCommand : Bool
  requireToken : Bool
  keys : List Nat
deriving DecidableEq, Repr

def ceilingOf (tc : TConfig) (r : LRules) : TLabel :=
  ⟨if r.clearTop then top tc.base.levels.length tc.base.comps.length else r.clear.getD bottom,
   if r.trustTop then trustCount tc.trusts.length - 1 else r.trust.getD 0⟩

structure ACtx where
  handle : Nat
  owner : List Nat
  label : TLabel
  last : Nat
deriving DecidableEq, Repr

def expired (idleSecs now : Nat) (x : ACtx) : Bool := decide (idleSecs * 1000 ≤ now - x.last)

def ctxLookup (cs : List ACtx) (h : Nat) : Option ACtx := cs.find? (·.handle == h)

def ctxRemove (cs : List ACtx) (h : Nat) : List ACtx := cs.filter (·.handle != h)

def ctxTouch (cs : List ACtx) (h now : Nat) : List ACtx :=
  cs.map fun x => if x.handle == h then { x with last := now } else x

inductive HRef
  | handle (n : Nat)
  | shaped
  | malformed
deriving DecidableEq, Repr

def ctxFind (idleSecs now : Nat) (cs : List ACtx) (login : List Nat) (ceiling : TLabel) :
    HRef → Option ACtx × List ACtx
  | .malformed => (none, cs)
  | .shaped => (none, cs)
  | .handle h =>
    match ctxLookup cs h with
    | none => (none, cs)
    | some x =>
      if expired idleSecs now x then (none, ctxRemove cs h)
      else if x.owner != login then (none, cs)
      else if !ceilingAdmits ceiling x.label then (none, cs)
      else (some { x with last := now }, ctxTouch cs h now)

def ctxCount (idleSecs now : Nat) (cs : List ACtx) (login : List Nat) : Nat :=
  (cs.filter fun x => x.owner == login && !expired idleSecs now x).length

inductive CreateResult
  | created (h : Nat)
  | invalid
  | full
deriving DecidableEq, Repr

def ctxCreate (idleSecs now cap next : Nat) (cs : List ACtx) (login : List Nat) (ceiling l : TLabel) (valid : Bool) :
    CreateResult × List ACtx × Nat :=
  if !valid || !ceilingAdmits ceiling l then (.invalid, cs, next)
  else if cap ≤ ctxCount idleSecs now cs login then (.full, cs, next)
  else (.created next, cs ++ [⟨next, login, l, now⟩], next + 1)

def ctxSweep (idleSecs now : Nat) (cs : List ACtx) : List ACtx := cs.filter fun x => !expired idleSecs now x

def HandlesFresh (cs : List ACtx) (next : Nat) : Prop := (cs.map (·.handle)).Nodup ∧ ∀ x ∈ cs, x.handle < next

theorem ctxLookup_some {cs : List ACtx} {h : Nat} {x : ACtx} (hl : ctxLookup cs h = some x) : x ∈ cs ∧ x.handle = h := by
  unfold ctxLookup at hl
  have := List.find?_some hl
  exact ⟨List.mem_of_find?_eq_some hl, by simpa using this⟩

theorem find_owner {idle now : Nat} {cs cs' : List ACtx} {login : List Nat} {ceiling : TLabel} {r : HRef} {x : ACtx}
    (h : ctxFind idle now cs login ceiling r = (some x, cs')) : x.owner = login := by
  cases r with
  | malformed => simp [ctxFind] at h
  | shaped => simp [ctxFind] at h
  | handle n =>
    simp only [ctxFind] at h
    split at h
    · simp at h
    · rename_i y _
      split at h
      · simp at h
      · split at h
        · simp at h
        · rename_i hown
          split at h
          · simp at h
          · simp only [Prod.mk.injEq, Option.some.injEq] at h
            obtain ⟨rfl, _⟩ := h
            simpa using hown

theorem find_within_ceiling {idle now : Nat} {cs cs' : List ACtx} {login : List Nat} {ceiling : TLabel} {r : HRef}
    {x : ACtx} (h : ctxFind idle now cs login ceiling r = (some x, cs')) : ceilingAdmits ceiling x.label = true := by
  cases r with
  | malformed => simp [ctxFind] at h
  | shaped => simp [ctxFind] at h
  | handle n =>
    simp only [ctxFind] at h
    split at h
    · simp at h
    · split at h
      · simp at h
      · split at h
        · simp at h
        · split at h
          · simp at h
          · rename_i hc
            simp only [Prod.mk.injEq, Option.some.injEq] at h
            obtain ⟨rfl, _⟩ := h
            simpa using hc

theorem find_fresh {idle now : Nat} {cs cs' : List ACtx} {login : List Nat} {ceiling : TLabel} {n : Nat} {x : ACtx}
    (h : ctxFind idle now cs login ceiling (.handle n) = (some x, cs')) :
    ∃ y ∈ cs, y.handle = n ∧ expired idle now y = false ∧ x = { y with last := now } ∧ cs' = ctxTouch cs n now := by
  simp only [ctxFind] at h
  split at h
  · simp at h
  · rename_i y hy
    obtain ⟨hm, hh⟩ := ctxLookup_some hy
    split at h
    · simp at h
    · rename_i he
      split at h
      · simp at h
      · split at h
        · simp at h
        · simp only [Prod.mk.injEq, Option.some.injEq] at h
          obtain ⟨rfl, rfl⟩ := h
          exact ⟨y, hm, hh, by simpa using he, rfl, rfl⟩

theorem find_label_fixed {idle now : Nat} {cs cs' : List ACtx} {login : List Nat} {ceiling : TLabel} {n : Nat} {x : ACtx}
    (h : ctxFind idle now cs login ceiling (.handle n) = (some x, cs')) : ∃ y ∈ cs, y.handle = n ∧ x.label = y.label := by
  obtain ⟨y, hm, hh, _, rfl, _⟩ := find_fresh h
  exact ⟨y, hm, hh, rfl⟩

theorem find_expired {idle now : Nat} {cs : List ACtx} {login : List Nat} {ceiling : TLabel} {n : Nat} {y : ACtx}
    (hl : ctxLookup cs n = some y) (he : expired idle now y = true) :
    ctxFind idle now cs login ceiling (.handle n) = (none, ctxRemove cs n) := by
  simp [ctxFind, hl, he]

theorem find_other_login {idle now : Nat} {cs : List ACtx} {login : List Nat} {ceiling : TLabel} {n : Nat} {y : ACtx}
    (hl : ctxLookup cs n = some y) (ho : y.owner ≠ login) : (ctxFind idle now cs login ceiling (.handle n)).1 = none := by
  simp only [ctxFind, hl]
  split
  · rfl
  · have : (y.owner != login) = true := by simpa using ho
    simp [this]

theorem find_outside_ceiling {idle now : Nat} {cs : List ACtx} {login : List Nat} {ceiling : TLabel} {n : Nat} {y : ACtx}
    (hl : ctxLookup cs n = some y) (hc : ceilingAdmits ceiling y.label = false) :
    (ctxFind idle now cs login ceiling (.handle n)).1 = none := by
  simp only [ctxFind, hl]
  split
  · rfl
  · split
    · rfl
    · simp [hc]

theorem find_unknown {idle now : Nat} {cs : List ACtx} {login : List Nat} {ceiling : TLabel} {n : Nat}
    (hl : ctxLookup cs n = none) : ctxFind idle now cs login ceiling (.handle n) = (none, cs) := by
  simp [ctxFind, hl]

theorem touch_labels (cs : List ACtx) (n now : Nat) : (ctxTouch cs n now).map (·.label) = cs.map (·.label) := by
  unfold ctxTouch
  rw [List.map_map]
  congr 1
  funext x
  simp only [Function.comp]
  split <;> rfl

theorem touch_handles (cs : List ACtx) (n now : Nat) : (ctxTouch cs n now).map (·.handle) = cs.map (·.handle) := by
  unfold ctxTouch
  rw [List.map_map]
  congr 1
  funext x
  simp only [Function.comp]
  split <;> rfl

theorem touch_owners (cs : List ACtx) (n now : Nat) : (ctxTouch cs n now).map (·.owner) = cs.map (·.owner) := by
  unfold ctxTouch
  rw [List.map_map]
  congr 1
  funext x
  simp only [Function.comp]
  split <;> rfl

theorem mem_touch {cs : List ACtx} {n now : Nat} {x : ACtx} (h : x ∈ ctxTouch cs n now) :
    ∃ y ∈ cs, y.handle = x.handle ∧ y.owner = x.owner ∧ y.label = x.label := by
  unfold ctxTouch at h
  obtain ⟨y, hy, rfl⟩ := List.mem_map.1 h
  refine ⟨y, hy, ?_⟩
  split <;> simp

theorem mem_remove {cs : List ACtx} {n : Nat} {x : ACtx} (h : x ∈ ctxRemove cs n) : x ∈ cs ∧ x.handle ≠ n := by
  unfold ctxRemove at h
  have := List.mem_filter.1 h
  exact ⟨this.1, by simpa using this.2⟩

theorem find_preserves {idle now : Nat} {cs cs' : List ACtx} {login : List Nat} {ceiling : TLabel} {r : HRef}
    {o : Option ACtx} (h : ctxFind idle now cs login ceiling r = (o, cs')) :
    ∀ x ∈ cs', ∃ y ∈ cs, y.handle = x.handle ∧ y.owner = x.owner ∧ y.label = x.label := by
  intro x hx
  cases r with
  | malformed => simp only [ctxFind, Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h; exact ⟨x, hx, rfl, rfl, rfl⟩
  | shaped => simp only [ctxFind, Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h; exact ⟨x, hx, rfl, rfl, rfl⟩
  | handle n =>
    simp only [ctxFind] at h
    split at h
    · simp only [Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h; exact ⟨x, hx, rfl, rfl, rfl⟩
    · split at h
      · simp only [Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h
        exact ⟨x, (mem_remove hx).1, rfl, rfl, rfl⟩
      · split at h
        · simp only [Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h; exact ⟨x, hx, rfl, rfl, rfl⟩
        · split at h
          · simp only [Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h; exact ⟨x, hx, rfl, rfl, rfl⟩
          · simp only [Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h; exact mem_touch hx

theorem create_owner_label {idle now cap next next' : Nat} {cs cs' : List ACtx} {login : List Nat} {ceiling l : TLabel}
    {valid : Bool} {h : Nat} (hc : ctxCreate idle now cap next cs login ceiling l valid = (.created h, cs', next')) :
    ceilingAdmits ceiling l = true ∧ h = next ∧ next' = next + 1 ∧ cs' = cs ++ [⟨next, login, l, now⟩] := by
  unfold ctxCreate at hc
  split at hc
  · simp at hc
  · rename_i hv
    split at hc
    · simp at hc
    · simp only [Prod.mk.injEq, CreateResult.created.injEq] at hc
      obtain ⟨rfl, rfl, rfl⟩ := hc
      simp only [Bool.or_eq_true, Bool.not_eq_true', not_or] at hv
      exact ⟨by simpa using hv.2, rfl, rfl, rfl⟩

theorem create_cap {idle now cap next : Nat} {cs : List ACtx} {login : List Nat} {ceiling l : TLabel}
    (hv : ceilingAdmits ceiling l = true) (hn : cap ≤ ctxCount idle now cs login) :
    (ctxCreate idle now cap next cs login ceiling l true).1 = .full := by
  simp [ctxCreate, hv, hn]

theorem create_outside {idle now cap next : Nat} {cs : List ACtx} {login : List Nat} {ceiling l : TLabel} {valid : Bool}
    (hv : ceilingAdmits ceiling l = false) : (ctxCreate idle now cap next cs login ceiling l valid).1 = .invalid := by
  simp [ctxCreate, hv]

theorem create_fresh {idle now cap next next' h : Nat} {cs cs' : List ACtx} {login : List Nat} {ceiling l : TLabel}
    {valid : Bool} (hf : HandlesFresh cs next) (hc : ctxCreate idle now cap next cs login ceiling l valid = (.created h, cs', next')) :
    HandlesFresh cs' next' := by
  obtain ⟨_, rfl, rfl, rfl⟩ := create_owner_label hc
  refine ⟨?_, ?_⟩
  · simp only [List.map_append, List.map_cons, List.map_nil]
    rw [List.nodup_append]
    refine ⟨hf.1, List.nodup_cons.2 ⟨by simp, List.nodup_nil⟩, ?_⟩
    intro a ha b hb
    simp only [List.mem_singleton] at hb
    subst hb
    obtain ⟨y, hy, rfl⟩ := List.mem_map.1 ha
    have := hf.2 y hy
    omega
  · intro x hx
    rcases List.mem_append.1 hx with hx | hx
    · have := hf.2 x hx; omega
    · simp only [List.mem_singleton] at hx; subst hx; simp

theorem find_keeps_fresh {idle now next : Nat} {cs cs' : List ACtx} {login : List Nat} {ceiling : TLabel} {r : HRef}
    {o : Option ACtx} (hf : HandlesFresh cs next) (h : ctxFind idle now cs login ceiling r = (o, cs')) :
    HandlesFresh cs' next := by
  cases r with
  | malformed => simp only [ctxFind, Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h; exact hf
  | shaped => simp only [ctxFind, Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h; exact hf
  | handle n =>
    simp only [ctxFind] at h
    split at h
    · simp only [Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h; exact hf
    · split at h
      · simp only [Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h
        refine ⟨?_, fun x hx => hf.2 x (mem_remove hx).1⟩
        unfold ctxRemove
        exact List.Nodup.sublist ((List.filter_sublist (l := cs)).map _) hf.1
      · split at h
        · simp only [Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h; exact hf
        · split at h
          · simp only [Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h; exact hf
          · simp only [Prod.mk.injEq] at h; obtain ⟨_, rfl⟩ := h
            refine ⟨by rw [touch_handles]; exact hf.1, fun x hx => ?_⟩
            obtain ⟨y, hy, hh, _, _⟩ := mem_touch hx
            rw [← hh]; exact hf.2 y hy

theorem sweep_unexpired {idle now : Nat} (cs : List ACtx) : ∀ x ∈ ctxSweep idle now cs, expired idle now x = false := by
  intro x hx
  unfold ctxSweep at hx
  simpa using (List.mem_filter.1 hx).2

theorem sweep_sub {idle now : Nat} (cs : List ACtx) : ∀ x ∈ ctxSweep idle now cs, x ∈ cs := by
  intro x hx
  exact (List.mem_filter.1 hx).1

theorem expiry_total {idle now : Nat} {x : ACtx} (h : x.last + idle * 1000 ≤ now) : expired idle now x = true := by
  unfold expired
  simp only [decide_eq_true_eq]
  omega

end Labels
