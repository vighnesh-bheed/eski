package vsettype

import "base:runtime"
import "core:strconv"
import lbl "../label"
import "../vfilter"

Error :: enum u8 {
	None,
	Quantization_Mismatch,
	M_Mismatch,
	Projection_Not_Allowed,
	Dimension_Mismatch,
	Projection_Input_Mismatch,
	Element_Not_Found,
	Filter_Syntax,
	Invalid_Parameter,
	Out_Of_Memory,
	Name_In_Use,
}

Failure :: struct {
	err:      Error,
	got:      int,
	expected: int,
	near:     string,
	label:    lbl.Id,
	owner:    Owner,
}

ERR_QUANTIZATION_MISMATCH :: "ERR asked quantization mismatch with existing vector set"
ERR_M_MISMATCH :: "ERR asked M value mismatch with existing vector set"
ERR_PROJECTION_NOT_ALLOWED :: "ERR cannot add projection to existing set without projection"
ERR_ELEMENT_NOT_FOUND :: "ERR element not found in set"
ERR_INVALID_PARAMETER :: "ERR invalid vector specification"
ERR_OUT_OF_MEMORY :: "ERR out of memory"
ERR_NAME_IN_USE :: "ERR name in use"
ERR_NAME_IN_USE_AT :: "ERR name in use at "

failure :: #force_inline proc "contextless" (err: Error, got := 0, expected := 0) -> Failure {
	return Failure{err = err, got = got, expected = expected}
}

failure_text :: proc(f: Failure, allocator := context.allocator) -> (text: string, err: runtime.Allocator_Error) {
	switch f.err {
	case .None:
		return "", nil
	case .Quantization_Mismatch:
		return ERR_QUANTIZATION_MISMATCH, nil
	case .M_Mismatch:
		return ERR_M_MISMATCH, nil
	case .Projection_Not_Allowed:
		return ERR_PROJECTION_NOT_ALLOWED, nil
	case .Element_Not_Found:
		return ERR_ELEMENT_NOT_FOUND, nil
	case .Invalid_Parameter:
		return ERR_INVALID_PARAMETER, nil
	case .Out_Of_Memory:
		return ERR_OUT_OF_MEMORY, nil
	case .Name_In_Use:
		return ERR_NAME_IN_USE, nil
	case .Filter_Syntax:
		return vfilter.error_text(f.near, allocator)
	case .Dimension_Mismatch:
		return numbered_text("ERR Vector dimension mismatch - got ", f.got, " but set has ", f.expected, allocator)
	case .Projection_Input_Mismatch:
		return numbered_text("ERR Input dimension mismatch for projection - got ", f.got, " but projection expects ", f.expected, allocator)
	}
	return "", nil
}

numbered_text :: proc(head: string, a: int, middle: string, b: int, allocator: runtime.Allocator) -> (text: string, err: runtime.Allocator_Error) {
	abuf, bbuf: [32]u8
	as := strconv.write_int(abuf[:], i64(a), 10)
	bs := strconv.write_int(bbuf[:], i64(b), 10)
	out := make([]u8, len(head) + len(as) + len(middle) + len(bs), allocator) or_return
	n := copy(out, head)
	n += copy(out[n:], as)
	n += copy(out[n:], middle)
	copy(out[n:], bs)
	return string(out), nil
}
