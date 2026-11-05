import Std

namespace Encoding

def machineMax : Int := 9223372036854775807

def bulkRequiredEnd (base payload length : Int) : Option Int :=
  if base < 0 ∨ payload < 0 ∨ length < 0 ∨ payload > machineMax - base then none
  else
    let remaining := machineMax - base - payload
    if remaining < 2 ∨ length > remaining - 2 then none
    else some (payload + length + 2)

def bulkEndSpec (base payload length : Int) : Option Int :=
  if 0 ≤ base ∧ 0 ≤ payload ∧ 0 ≤ length ∧ base + payload + length + 2 ≤ machineMax
    then some (payload + length + 2) else none

theorem bulk_guard_refines (base payload length : Int) :
    bulkRequiredEnd base payload length = bulkEndSpec base payload length := by
  unfold bulkRequiredEnd bulkEndSpec
  split <;> (try split) <;> (try split) <;> simp_all <;> omega

theorem bulk_success_bounds (base payload length finish : Int)
    (h : bulkRequiredEnd base payload length = some finish) :
    0 ≤ base ∧ 0 ≤ payload ∧ 0 ≤ length ∧ finish = payload + length + 2 ∧
      payload ≤ finish - 2 ∧ finish ≤ machineMax - base := by
  rw [bulk_guard_refines] at h
  unfold bulkEndSpec at h
  split at h <;> simp_all <;> omega

theorem bulk_slice_bounds (base payload length finish available : Int)
    (h : bulkRequiredEnd base payload length = some finish) (ha : finish ≤ available) :
    0 ≤ payload ∧ payload ≤ finish - 2 ∧ finish - 2 < available ∧
      finish - 1 < available ∧ finish - 2 - payload = length := by
  obtain ⟨_, hp, hl, he, hle, _⟩ := bulk_success_bounds base payload length finish h
  omega

def fastBulkEnd (base payload length : Int) : Option Int :=
  let frame := machineMax - base
  if base < 0 ∨ length < 0 ∨ payload < 0 ∨ frame < 2 ∨ payload > frame - 2 ∨
      length > frame - 2 - payload then none else some (payload + length + 2)

theorem fast_slow_bulk_equivalent (base payload length : Int) :
    fastBulkEnd base payload length = bulkRequiredEnd base payload length := by
  rw [bulk_guard_refines]
  simp only [fastBulkEnd, bulkEndSpec]
  split <;> split <;> simp_all <;> omega

structure ParseLimits where
  bulkMax : Int := 536870912
  base : Int := 0
  unauthenticated : Bool := false
  arrayMax : Int := 10
  unauthBulkMax : Int := 16384
  deriving Repr, BEq, DecidableEq

structure ParseResult where
  kind : Nat := 0
  fault : Nat := 0
  consumed : Nat := 0
  need : Nat := 0
  payload : Nat := 0
  args : List (List Nat) := []
  errorByte : Nat := 0
  deriving Repr, BEq, DecidableEq

structure HeaderResult where
  complete : Bool := false
  endPos : Nat := 0
  nextPos : Nat := 0
  need : Nat := 0
  unbounded : Bool := false
  deriving Repr, BEq, DecidableEq

def findHeader : List Nat → Nat → HeaderResult
  | [], pos => {need := pos + 1, unbounded := true}
  | byte :: rest, pos =>
    if byte = 0 then {need := pos + rest.length + 2, unbounded := true}
    else if byte = 13 then
      match rest with
      | [] => {need := pos + 2}
      | _ :: _ => {complete := true, endPos := pos, nextPos := pos + 2}
    else findHeader rest (pos + 1)

def headerAt (bytes : List Nat) (offset : Nat) := findHeader (bytes.drop offset) offset

def decimalDigits : List Nat → Option Nat
  | [] => some 0
  | b :: rest =>
    if 48 ≤ b ∧ b ≤ 57 then do
      let remaining ← decimalDigits rest
      return (b - 48) * 10 ^ rest.length + remaining
    else none

def parseInteger (bytes : List Nat) : Option Int := do
  match bytes with
  | [] => none
  | [b] => if 48 ≤ b ∧ b ≤ 57 then some (Int.ofNat (b - 48)) else none
  | first :: rest =>
    let negative := first == 45
    let digits := if negative then rest else bytes
    if digits.length > 19 then none
    else
      match digits with
      | [] => none
      | d :: _ =>
        if d < 49 ∨ d > 57 then none
        else do
          let n ← decimalDigits digits
          if negative then
            if n ≤ 9223372036854775808 then some (-Int.ofNat n) else none
          else if n ≤ 9223372036854775807 then some (Int.ofNat n) else none

def incompleteHeader (header : HeaderResult) (oversized : Bool) (fault : Nat) : ParseResult :=
  if header.unbounded && oversized then {kind := 2, fault}
  else {need := header.need}

def parseBulks (bytes : List Nat) (limits : ParseLimits) : Nat → Nat → List (List Nat) → ParseResult
  | 0, cursor, args => {kind := 1, consumed := cursor, args}
  | remaining + 1, cursor, args =>
    let header := headerAt bytes cursor
    if !header.complete then
      incompleteHeader header (bytes.length - cursor > 65536) 8
    else if bytes[cursor]?.getD 0 != 36 then
      {kind := 2, fault := 5, errorByte := bytes[cursor]?.getD 0}
    else
      match parseInteger ((bytes.drop (cursor + 1)).take (header.endPos - cursor - 1)) with
      | none => {kind := 2, fault := 2}
      | some length =>
        if length < 0 ∨ length > limits.bulkMax then {kind := 2, fault := 2}
        else if limits.unauthenticated && length > limits.unauthBulkMax then
          {kind := 2, fault := 4}
        else
          match bulkRequiredEnd limits.base header.nextPos length with
          | none => {kind := 2, fault := 2}
          | some finish =>
            if finish > bytes.length then {need := finish.toNat, payload := header.nextPos}
            else
              parseBulks bytes limits remaining finish.toNat
                (args ++ [(bytes.drop header.nextPos).take length.toNat])

def parseArray (bytes : List Nat) (limits : ParseLimits) : ParseResult :=
  if bytes.isEmpty then {need := 1}
  else
    let header := headerAt bytes 0
    if !header.complete then incompleteHeader header (bytes.length > 65536) 7
    else if bytes.head! != 42 ∨ header.endPos = 0 then {kind := 2, fault := 1}
    else
      match parseInteger ((bytes.drop 1).take (header.endPos - 1)) with
      | none => {kind := 2, fault := 1}
      | some count =>
        if count > 2147483647 then {kind := 2, fault := 1}
        else if count ≤ 0 then {kind := 1, consumed := header.nextPos}
        else if limits.unauthenticated && count > limits.arrayMax then {kind := 2, fault := 3}
        else parseBulks bytes limits count.toNat header.nextPos []

structure Incremental where
  bytes : List Nat := []
  result : ParseResult := {need := 1}
  deriving Repr, BEq, DecidableEq

def feed (limits : ParseLimits) (state : Incremental) (chunk : List Nat) : Incremental :=
  let bytes := state.bytes ++ chunk
  {bytes, result := parseArray bytes limits}

def feedChunks (limits : ParseLimits) (state : Incremental) (chunks : List (List Nat)) :=
  chunks.foldl (feed limits) state

theorem feed_append (limits : ParseLimits) (state : Incremental) (left right : List Nat) :
    feed limits (feed limits state left) right = feed limits state (left ++ right) := by
  simp [feed, List.append_assoc]

theorem chunks_bytes (limits : ParseLimits) (state : Incremental) (chunks : List (List Nat)) :
    (feedChunks limits state chunks).bytes = state.bytes ++ chunks.flatten := by
  induction chunks generalizing state with
  | nil => simp [feedChunks]
  | cons chunk chunks ih =>
    simp only [feedChunks, List.foldl_cons]
    rw [show (List.foldl (feed limits) (feed limits state chunk) chunks).bytes =
      (feed limits state chunk).bytes ++ chunks.flatten from ih _]
    simp [feed, List.flatten_cons, List.append_assoc]

theorem chunks_semantics (limits : ParseLimits) (state : Incremental) (chunks : List (List Nat))
    (valid : state.result = parseArray state.bytes limits) :
    (feedChunks limits state chunks).result = parseArray (state.bytes ++ chunks.flatten) limits := by
  induction chunks generalizing state with
  | nil => simpa [feedChunks] using valid
  | cons chunk chunks ih =>
    simp only [feedChunks, List.foldl_cons]
    have hi := ih (feed limits state chunk) rfl
    simpa [feedChunks, feed, List.flatten_cons, List.append_assoc] using hi

theorem fragmentation_invariant (limits : ParseLimits) (left right : List (List Nat))
    (same : left.flatten = right.flatten) :
    (feedChunks limits {} left).result = (feedChunks limits {} right).result := by
  rw [chunks_semantics limits {} left rfl, chunks_semantics limits {} right rfl, same]

theorem parser_nil_array : (parseArray [42, 45, 49, 13, 10] {}).kind = 1 ∧
    (parseArray [42, 45, 49, 13, 10] {}).args = [] := by decide

theorem parser_nil_bulk : (parseArray [42, 49, 13, 10, 36, 45, 49, 13, 10] {}).fault = 2 := by decide

theorem parser_incomplete_bulk :
    parseArray [42, 49, 13, 10, 36, 51, 13, 10, 0] {} = {need := 13, payload := 8} := by decide

theorem parser_binary_success :
    parseArray [42, 49, 13, 10, 36, 51, 13, 10, 0, 255, 13, 13, 10] {} =
      {kind := 1, consumed := 13, args := [[0, 255, 13]]} := by decide

theorem header_complete_bounds (bytes : List Nat) (offset : Nat)
    (h : (findHeader bytes offset).complete = true) :
    offset ≤ (findHeader bytes offset).endPos ∧
      (findHeader bytes offset).nextPos = (findHeader bytes offset).endPos + 2 ∧
      (findHeader bytes offset).nextPos ≤ offset + bytes.length := by
  induction bytes generalizing offset with
  | nil => simp [findHeader] at h
  | cons byte rest ih =>
    by_cases hz : byte = 0
    · subst byte; simp [findHeader] at h
    · by_cases hr : byte = 13
      · subst byte
        cases rest with
        | nil => simp [findHeader] at h
        | cons next rest => simp [findHeader]
      · simp [findHeader, hz, hr] at h ⊢
        have hb := ih (offset + 1) h
        omega

def ArgumentSpan (bytes arg : List Nat) (limit : Nat) : Prop :=
  ∃ start length, start + length + 2 ≤ limit ∧ arg = (bytes.drop start).take length ∧ arg.length = length

theorem incomplete_not_success (header : HeaderResult) (oversized : Bool) (fault : Nat) :
    (incompleteHeader header oversized fault).kind ≠ 1 := by
  unfold incompleteHeader
  split <;> simp

theorem parse_bulks_success_bounds (bytes : List Nat) (limits : ParseLimits) (remaining cursor : Nat)
    (args : List (List Nat)) (hc : cursor ≤ bytes.length)
    (ha : ∀ arg ∈ args, ArgumentSpan bytes arg cursor)
    (hs : (parseBulks bytes limits remaining cursor args).kind = 1) :
    cursor ≤ (parseBulks bytes limits remaining cursor args).consumed ∧
      (parseBulks bytes limits remaining cursor args).consumed ≤ bytes.length ∧
      ∀ arg ∈ (parseBulks bytes limits remaining cursor args).args,
        ArgumentSpan bytes arg (parseBulks bytes limits remaining cursor args).consumed := by
  induction remaining generalizing cursor args with
  | zero => simpa [parseBulks] using And.intro (Nat.le_refl cursor) (And.intro hc ha)
  | succ remaining ih =>
    by_cases hh : (headerAt bytes cursor).complete = true
    · by_cases hm : bytes[cursor]?.getD 0 = 36
      · cases hl : parseInteger ((bytes.drop (cursor + 1)).take ((headerAt bytes cursor).endPos - cursor - 1)) with
        | none => simp [parseBulks, hh, hm, hl] at hs
        | some length =>
          by_cases hr : length < 0 ∨ length > limits.bulkMax
          · simp [parseBulks, hh, hm, hl, hr] at hs
          · by_cases hu : limits.unauthenticated && length > limits.unauthBulkMax
            · simp [parseBulks, hh, hm, hl, hr, hu] at hs
            · cases he : bulkRequiredEnd limits.base (headerAt bytes cursor).nextPos length with
              | none => simp [parseBulks, hh, hm, hl, hr, hu, he] at hs
              | some finish =>
                by_cases hf : finish > bytes.length
                · simp [parseBulks, hh, hm, hl, hr, hu, he, hf] at hs
                · simp [parseBulks, hh, hm, hl, hr, hu, he, hf] at hs ⊢
                  have hg := bulk_success_bounds limits.base (headerAt bytes cursor).nextPos length finish he
                  have hb := header_complete_bounds (bytes.drop cursor) cursor hh
                  have hn : finish.toNat ≤ bytes.length := by omega
                  have hc' : cursor ≤ finish.toNat := by
                    unfold headerAt at hg
                    omega
                  have ha' : ∀ arg ∈ args ++ [(bytes.drop (headerAt bytes cursor).nextPos).take length.toNat],
                      ArgumentSpan bytes arg finish.toNat := by
                    intro arg hmem
                    simp only [List.mem_append, List.mem_singleton] at hmem
                    rcases hmem with hmem | rfl
                    · obtain ⟨start, n, hbound, heq, hlen⟩ := ha arg hmem
                      exact ⟨start, n, by omega, heq, hlen⟩
                    · refine ⟨(headerAt bytes cursor).nextPos, length.toNat, ?_, rfl, ?_⟩
                      · omega
                      · simp only [List.length_take, List.length_drop]
                        omega
                  have hi := ih finish.toNat _ hn ha' hs
                  exact ⟨Nat.le_trans hc' hi.1, hi.2⟩
      · simp [parseBulks, hh, hm] at hs
    · have hfalse : (headerAt bytes cursor).complete = false := by cases h : (headerAt bytes cursor).complete <;> simp_all
      have hi := incomplete_not_success (headerAt bytes cursor) (bytes.length - cursor > 65536) 8
      simp [parseBulks, hfalse] at hs
      exact False.elim (hi hs)

theorem parse_array_success_bounds (bytes : List Nat) (limits : ParseLimits)
    (hs : (parseArray bytes limits).kind = 1) :
    (parseArray bytes limits).consumed ≤ bytes.length ∧
      ∀ arg ∈ (parseArray bytes limits).args, ArgumentSpan bytes arg (parseArray bytes limits).consumed := by
  by_cases he : bytes.isEmpty = true
  · simp [parseArray, he] at hs
  · by_cases hh : (headerAt bytes 0).complete = true
    · have hb := header_complete_bounds bytes 0 (by simpa [headerAt] using hh)
      have hn : (headerAt bytes 0).nextPos ≤ bytes.length := by simpa [headerAt] using hb.2.2
      by_cases hm : bytes.head! ≠ 42 ∨ (headerAt bytes 0).endPos = 0
      · simp [parseArray, he, hh, hm] at hs
      · cases hl : parseInteger (bytes.tail.take ((headerAt bytes 0).endPos - 1)) with
        | none => simp [parseArray, he, hh, hm, hl] at hs
        | some count =>
          by_cases hr : count > 2147483647
          · simp [parseArray, he, hh, hm, hl, hr] at hs
          · by_cases hz : count ≤ 0
            · simpa [parseArray, he, hh, hm, hl, hr, hz] using hn
            · by_cases hu : limits.unauthenticated = true ∧ count > limits.arrayMax
              · simp [parseArray, he, hh, hm, hl, hr, hz, hu] at hs
              · simp [parseArray, he, hh, hm, hl, hr, hz, hu] at hs ⊢
                exact (parse_bulks_success_bounds bytes limits count.toNat (headerAt bytes 0).nextPos [] hn (by simp) hs).2
    · have hfalse : (headerAt bytes 0).complete = false := by cases h : (headerAt bytes 0).complete <;> simp_all
      have hi := incomplete_not_success (headerAt bytes 0) (bytes.length > 65536) 7
      simp [parseArray, he, hfalse] at hs
      exact False.elim (hi hs)

end Encoding
