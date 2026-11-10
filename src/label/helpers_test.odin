package label

import "core:fmt"
import "core:strings"
import "core:testing"

Rng :: struct {
	state: u64,
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E37_79B9_7F4A_7C15
	z := r.state
	z = (z ~ z >> 30) * 0xBF58_476D_1CE4_E5B9
	z = (z ~ z >> 27) * 0x94D0_49BB_1331_11EB
	return z ~ z >> 31
}

rng_below :: proc(r: ^Rng, n: int) -> int {
	return int(rng_next(r) % u64(n))
}

random_label :: proc(r: ^Rng, levels, compartments: int, density := 4, trusts := 1) -> (l: Label) {
	l.level = u8(rng_below(r, levels))
	if trusts > 1 {
		l.trust = u8(rng_below(r, trusts))
	}
	if compartments == 0 {
		return l
	}
	picks := rng_below(r, density + 1)
	for _ in 0 ..< picks {
		compartment_add(&l, rng_below(r, compartments))
	}
	return l
}

small_label :: proc(index: int) -> (l: Label) {
	l.level = u8(index >> 4 & 3)
	l.trust = u8(index >> 6)
	for c in 0 ..< 4 {
		if index >> uint(c) & 1 != 0 {
			compartment_add(&l, c)
		}
	}
	return l
}

SMALL_LABELS :: 64

SMALL_TRUSTED_LABELS :: 192

US_LEVELS := [?]string{"UNCLASSIFIED", "CONFIDENTIAL", "SECRET", "TOP SECRET"}

US_COMPARTMENTS := [?]string{"SI", "TK", "HCS", "G", "NOFORN"}

US_TRUSTS := [?]string{"WEB", "VETTED", "TRUSTED"}

us_config :: proc(t: ^testing.T, c: ^Config) {
	config_init(c)
	for name in US_LEVELS {
		testing.expect_value(t, config_add_level(c, name), Config_Error.None)
	}
	for name in US_COMPARTMENTS {
		testing.expect_value(t, config_add_compartment(c, name), Config_Error.None)
	}
	for name in US_TRUSTS {
		testing.expect_value(t, config_add_trust(c, name), Config_Error.None)
	}
}

wide_config :: proc(t: ^testing.T, c: ^Config, levels, compartments: int, trusts := 0) {
	config_init(c)
	for i in 0 ..< levels {
		name := fmt.tprintf("L%d", i)
		testing.expect_value(t, config_add_level(c, name), Config_Error.None)
	}
	for i in 0 ..< compartments {
		name := fmt.tprintf("C%d", i)
		testing.expect_value(t, config_add_compartment(c, name), Config_Error.None)
	}
	for i in 0 ..< trusts {
		name := fmt.tprintf("T%d", i)
		testing.expect_value(t, config_add_trust(c, name), Config_Error.None)
	}
}

label_text :: proc(c: ^Config, l: Label) -> string {
	b := strings.builder_make(context.temp_allocator)
	if !format_builder(&b, c, l) {
		return "<invalid>"
	}
	return strings.to_string(b)
}
