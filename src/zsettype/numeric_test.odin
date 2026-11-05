package zsettype

import "core:testing"

@(test)
score_parsing_and_formatting :: proc(t: ^testing.T) {
	{
		s := []u8{}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{43}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{43}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{43}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{45}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{45}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{45}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{46}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{46}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{46}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{43, 46}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{43, 46}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{43, 46}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{45, 46}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{45, 46}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{45, 46}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{101, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{101, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{101, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{112, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{112, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{112, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == true)
	}
	{
		s := []u8{48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{45, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 2 && erange == false)
	}
	{
		s := []u8{45, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && ok == true)
	}
	{
		s := []u8{45, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{43, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 2 && erange == false)
	}
	{
		s := []u8{43, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == true)
	}
	{
		s := []u8{43, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 2 && erange == false)
	}
	{
		s := []u8{48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == true)
	}
	{
		s := []u8{48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 2 && erange == false)
	}
	{
		s := []u8{48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{45, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xbff0000000000000 && consumed == 2 && erange == false)
	}
	{
		s := []u8{45, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0xbff0000000000000 && ok == true)
	}
	{
		s := []u8{45, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xbff0000000000000)
	}
	{
		s := []u8{49, 50, 51}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x405ec00000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 50, 51}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x405ec00000000000 && ok == true)
	}
	{
		s := []u8{49, 50, 51}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x405ec00000000000)
	}
	{
		s := []u8{49, 46}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 2 && erange == false)
	}
	{
		s := []u8{49, 46}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{49, 46}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{46, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000 && consumed == 2 && erange == false)
	}
	{
		s := []u8{46, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000 && ok == true)
	}
	{
		s := []u8{46, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000)
	}
	{
		s := []u8{43, 46, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{43, 46, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000 && ok == true)
	}
	{
		s := []u8{43, 46, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000)
	}
	{
		s := []u8{45, 46, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xbfe0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{45, 46, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0xbfe0000000000000 && ok == true)
	}
	{
		s := []u8{45, 46, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xbfe0000000000000)
	}
	{
		s := []u8{49, 46, 50, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff4000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{49, 46, 50, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff4000000000000 && ok == true)
	}
	{
		s := []u8{49, 46, 50, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff4000000000000)
	}
	{
		s := []u8{49, 101, 50}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4059000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 101, 50}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x4059000000000000 && ok == true)
	}
	{
		s := []u8{49, 101, 50}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4059000000000000)
	}
	{
		s := []u8{49, 69, 45, 50}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3f847ae147ae147b && consumed == 4 && erange == false)
	}
	{
		s := []u8{49, 69, 45, 50}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3f847ae147ae147b && ok == true)
	}
	{
		s := []u8{49, 69, 45, 50}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3f847ae147ae147b)
	}
	{
		s := []u8{49, 101, 43}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{49, 101, 43}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 101, 43}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{49, 101, 45}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{49, 101, 45}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 101, 45}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{49, 101}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{49, 101}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 101}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{49, 101, 50, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4059000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 101, 50, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 101, 50, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4059000000000000)
	}
	{
		s := []u8{49, 50, 51, 97, 98, 99}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x405ec00000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 50, 51, 97, 98, 99}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 50, 51, 97, 98, 99}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x405ec00000000000)
	}
	{
		s := []u8{46, 49, 120}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3fb999999999999a && consumed == 2 && erange == false)
	}
	{
		s := []u8{46, 49, 120}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{46, 49, 120}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3fb999999999999a)
	}
	{
		s := []u8{49, 46, 50, 46, 51}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff3333333333333 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 46, 50, 46, 51}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 46, 50, 46, 51}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff3333333333333)
	}
	{
		s := []u8{49, 95, 48, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{49, 95, 48, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 95, 48, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{49, 44, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{49, 44, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 44, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{45, 45, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{45, 45, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{45, 45, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{43, 43, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{43, 43, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{43, 43, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{43, 45, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{43, 45, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{43, 45, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 43, 50}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{49, 43, 50}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 43, 50}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{32, 49, 46, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{32, 49, 46, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{32, 49, 46, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{49, 46, 53, 32}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 46, 53, 32}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 46, 53, 32}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{32, 45, 48, 32}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{32, 45, 48, 32}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{32, 45, 48, 32}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{32}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{32}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{32}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{9, 49, 46, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{9, 49, 46, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{9, 49, 46, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{49, 46, 53, 9}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 46, 53, 9}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 46, 53, 9}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{9, 45, 48, 9}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{9, 45, 48, 9}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{9, 45, 48, 9}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{9}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{9}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{9}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{10, 49, 46, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{10, 49, 46, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{10, 49, 46, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{49, 46, 53, 10}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 46, 53, 10}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 46, 53, 10}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{10, 45, 48, 10}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{10, 45, 48, 10}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{10, 45, 48, 10}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{10}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{10}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{10}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{13, 49, 46, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{13, 49, 46, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{13, 49, 46, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{49, 46, 53, 13}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 46, 53, 13}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 46, 53, 13}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{13, 45, 48, 13}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{13, 45, 48, 13}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{13, 45, 48, 13}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{13}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{13}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{13}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{11, 49, 46, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{11, 49, 46, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{11, 49, 46, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{49, 46, 53, 11}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 46, 53, 11}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 46, 53, 11}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{11, 45, 48, 11}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{11, 45, 48, 11}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{11, 45, 48, 11}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{11}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{11}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{11}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{12, 49, 46, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{12, 49, 46, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{12, 49, 46, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{49, 46, 53, 12}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 46, 53, 12}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 46, 53, 12}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{12, 45, 48, 12}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{12, 45, 48, 12}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{12, 45, 48, 12}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{12}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{12}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{12}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{32, 9, 10, 49, 46, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 6 && erange == false)
	}
	{
		s := []u8{32, 9, 10, 49, 46, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{32, 9, 10, 49, 46, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{49, 46, 53, 32, 9, 10}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 46, 53, 32, 9, 10}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 46, 53, 32, 9, 10}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{32, 9, 10, 45, 48, 32, 9, 10}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 5 && erange == false)
	}
	{
		s := []u8{32, 9, 10, 45, 48, 32, 9, 10}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{32, 9, 10, 45, 48, 32, 9, 10}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{32, 9, 10}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{32, 9, 10}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{32, 9, 10}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{0}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{0}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{0}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 0}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{49, 0}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 0}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{49, 0, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{49, 0, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 0, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{0, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{0, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{0, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 46, 53, 0, 0}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{49, 46, 53, 0, 0}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 46, 53, 0, 0}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff8000000000000)
	}
	{
		s := []u8{105, 110, 102, 0, 116, 97, 105, 108}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{105, 110, 102, 0, 116, 97, 105, 108}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{105, 110, 102, 0, 116, 97, 105, 108}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{110, 97, 110, 0, 116, 97, 105, 108}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 0, 116, 97, 105, 108}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 0, 116, 97, 105, 108}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{255, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 0 && erange == false)
	}
	{
		s := []u8{255, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{255, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 255}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{49, 255}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 255}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{48, 120, 49, 112, 50, 0, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4010000000000000 && consumed == 5 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 112, 50, 0, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 49, 112, 50, 0, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4010000000000000)
	}
	{
		s := []u8{32, 49, 0}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 2 && erange == false)
	}
	{
		s := []u8{32, 49, 0}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{32, 49, 0}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{45, 49, 0, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xbff0000000000000 && consumed == 2 && erange == false)
	}
	{
		s := []u8{45, 49, 0, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{45, 49, 0, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xbff0000000000000)
	}
	{
		s := []u8{49, 13, 10, 88}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{49, 13, 10, 88}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 13, 10, 88}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{105, 110, 102}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{105, 110, 102}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && ok == true)
	}
	{
		s := []u8{105, 110, 102}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{73, 78, 70}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{73, 78, 70}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && ok == true)
	}
	{
		s := []u8{73, 78, 70}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{73, 110, 102}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{73, 110, 102}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && ok == true)
	}
	{
		s := []u8{73, 110, 102}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{105, 110, 102, 105, 110, 105, 116, 121}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 8 && erange == false)
	}
	{
		s := []u8{105, 110, 102, 105, 110, 105, 116, 121}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && ok == true)
	}
	{
		s := []u8{105, 110, 102, 105, 110, 105, 116, 121}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{73, 78, 70, 73, 78, 73, 84, 89}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 8 && erange == false)
	}
	{
		s := []u8{73, 78, 70, 73, 78, 73, 84, 89}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && ok == true)
	}
	{
		s := []u8{73, 78, 70, 73, 78, 73, 84, 89}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{43, 105, 110, 102}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{43, 105, 110, 102}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && ok == true)
	}
	{
		s := []u8{43, 105, 110, 102}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{45, 105, 110, 102}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xfff0000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{45, 105, 110, 102}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0xfff0000000000000 && ok == true)
	}
	{
		s := []u8{45, 105, 110, 102}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xfff0000000000000)
	}
	{
		s := []u8{43, 73, 110, 102, 105, 110, 105, 116, 121}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 9 && erange == false)
	}
	{
		s := []u8{43, 73, 110, 102, 105, 110, 105, 116, 121}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && ok == true)
	}
	{
		s := []u8{43, 73, 110, 102, 105, 110, 105, 116, 121}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{45, 73, 78, 70, 73, 78, 73, 84, 89}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xfff0000000000000 && consumed == 9 && erange == false)
	}
	{
		s := []u8{45, 73, 78, 70, 73, 78, 73, 84, 89}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0xfff0000000000000 && ok == true)
	}
	{
		s := []u8{45, 73, 78, 70, 73, 78, 73, 84, 89}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xfff0000000000000)
	}
	{
		s := []u8{105, 110, 102, 105}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{105, 110, 102, 105}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{105, 110, 102, 105}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{105, 110, 102, 105, 110, 105, 116}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{105, 110, 102, 105, 110, 105, 116}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{105, 110, 102, 105, 110, 105, 116}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{105, 110, 102, 105, 110, 105, 116, 121, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 8 && erange == false)
	}
	{
		s := []u8{105, 110, 102, 105, 110, 105, 116, 121, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{105, 110, 102, 105, 110, 105, 116, 121, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{110, 97, 110}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{110, 97, 110}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{78, 65, 78}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{78, 65, 78}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{78, 65, 78}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{78, 97, 78}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{78, 97, 78}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{78, 97, 78}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{43, 110, 97, 110}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{43, 110, 97, 110}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{43, 110, 97, 110}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{45, 110, 97, 110}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{45, 110, 97, 110}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{45, 110, 97, 110}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{110, 97, 110, 40, 41}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 5 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 40, 41}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 40, 41}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{110, 97, 110, 40, 97, 41}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 6 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 40, 97, 41}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 40, 97, 41}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{110, 97, 110, 40, 102, 111, 111, 95, 98, 97, 114, 49, 50, 51, 41}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 15 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 40, 102, 111, 111, 95, 98, 97, 114, 49, 50, 51, 41}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 40, 102, 111, 111, 95, 98, 97, 114, 49, 50, 51, 41}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{110, 97, 110, 40, 48, 120, 49, 50, 51, 52, 41}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 11 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 40, 48, 120, 49, 50, 51, 52, 41}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 40, 48, 120, 49, 50, 51, 52, 41}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{45, 78, 97, 78, 40, 80, 65, 89, 76, 79, 65, 68, 41}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 13 && erange == false)
	}
	{
		s := []u8{45, 78, 97, 78, 40, 80, 65, 89, 76, 79, 65, 68, 41}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{45, 78, 97, 78, 40, 80, 65, 89, 76, 79, 65, 68, 41}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{110, 97, 110, 40, 110, 111, 45, 99, 108, 111, 115, 101}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 40, 110, 111, 45, 99, 108, 111, 115, 101}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 40, 110, 111, 45, 99, 108, 111, 115, 101}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{110, 97, 110, 40, 120, 45, 121, 41}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 40, 120, 45, 121, 41}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 40, 120, 45, 121, 41}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{110, 97, 110, 40, 255, 41}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 40, 255, 41}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 40, 255, 41}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{110, 97, 110, 40, 41, 116, 97, 105, 108}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 5 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 40, 41, 116, 97, 105, 108}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 40, 41, 116, 97, 105, 108}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{110, 97, 110, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{73, 110, 102, 105, 110, 105, 116, 89, 116}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 8 && erange == false)
	}
	{
		s := []u8{73, 110, 102, 105, 110, 105, 116, 89, 116}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{73, 110, 102, 105, 110, 105, 116, 89, 116}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{48, 120, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{48, 120, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{48, 120, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{48, 120, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{48, 88, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{48, 88, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{48, 88, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{48, 120}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{48, 120}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{48, 120, 46}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{48, 120, 46}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 46}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{48, 120, 49, 46}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 46}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 49, 46}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{48, 120, 46, 56}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{48, 120, 46, 56}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 46, 56}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000)
	}
	{
		s := []u8{48, 120, 49, 112, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 5 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 112, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 49, 112, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{48, 120, 49, 112, 43, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4000000000000000 && consumed == 6 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 112, 43, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x4000000000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 49, 112, 43, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4000000000000000)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000 && consumed == 6 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3fe0000000000000)
	}
	{
		s := []u8{45, 48, 120, 49, 46, 56, 112, 50}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xc018000000000000 && consumed == 8 && erange == false)
	}
	{
		s := []u8{45, 48, 120, 49, 46, 56, 112, 50}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0xc018000000000000 && ok == true)
	}
	{
		s := []u8{45, 48, 120, 49, 46, 56, 112, 50}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xc018000000000000)
	}
	{
		s := []u8{43, 48, 88, 65, 98, 46, 67, 68, 112, 45, 52}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x402579a000000000 && consumed == 11 && erange == false)
	}
	{
		s := []u8{43, 48, 88, 65, 98, 46, 67, 68, 112, 45, 52}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x402579a000000000 && ok == true)
	}
	{
		s := []u8{43, 48, 88, 65, 98, 46, 67, 68, 112, 45, 52}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x402579a000000000)
	}
	{
		s := []u8{48, 120, 49, 112}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 112}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 49, 112}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{48, 120, 49, 112, 43}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 112, 43}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 49, 112, 43}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{48, 120, 49, 112, 45}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 112, 45}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 49, 112, 45}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{48, 120, 49, 112, 50, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4010000000000000 && consumed == 5 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 112, 50, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 49, 112, 50, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4010000000000000)
	}
	{
		s := []u8{48, 120, 49, 46, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 112, 49, 48, 50, 51}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7fefffffffffffff && consumed == 22 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 46, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 112, 49, 48, 50, 51}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x7fefffffffffffff && ok == true)
	}
	{
		s := []u8{48, 120, 49, 46, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 112, 49, 48, 50, 51}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7fefffffffffffff)
	}
	{
		s := []u8{48, 120, 49, 112, 49, 48, 50, 52}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 8 && erange == true)
	}
	{
		s := []u8{48, 120, 49, 112, 49, 48, 50, 52}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 49, 112, 49, 48, 50, 52}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49, 48, 55, 52}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001 && consumed == 9 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49, 48, 55, 52}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001 && ok == true)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49, 48, 55, 52}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49, 48, 55, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 9 && erange == true)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49, 48, 55, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49, 48, 55, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{48, 120, 51, 112, 45, 49, 48, 55, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000002 && consumed == 9 && erange == false)
	}
	{
		s := []u8{48, 120, 51, 112, 45, 49, 48, 55, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000002 && ok == true)
	}
	{
		s := []u8{48, 120, 51, 112, 45, 49, 48, 55, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000002)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49, 48, 50, 50}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && consumed == 9 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49, 48, 50, 50}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 49, 48, 50, 50}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000)
	}
	{
		s := []u8{48, 120, 48, 46, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 112, 45, 49, 48, 50, 50}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x000fffffffffffff && consumed == 23 && erange == false)
	}
	{
		s := []u8{48, 120, 48, 46, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 112, 45, 49, 48, 50, 50}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x000fffffffffffff && ok == true)
	}
	{
		s := []u8{48, 120, 48, 46, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 112, 45, 49, 48, 50, 50}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x000fffffffffffff)
	}
	{
		s := []u8{48, 120, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 56, 112, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 20 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 56, 112, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 56, 112, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{48, 120, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 56, 112, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000002 && consumed == 20 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 56, 112, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000002 && ok == true)
	}
	{
		s := []u8{48, 120, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 56, 112, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000002)
	}
	{
		s := []u8{48, 120, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 112, 45, 54, 52}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 23 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 112, 45, 54, 52}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 112, 45, 54, 52}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{48, 120, 49, 101, 50}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x407e200000000000 && consumed == 5 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 101, 50}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x407e200000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 49, 101, 50}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x407e200000000000)
	}
	{
		s := []u8{48, 120, 49, 101, 43, 50}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x403e000000000000 && consumed == 4 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 101, 43, 50}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 49, 101, 43, 50}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x403e000000000000)
	}
	{
		s := []u8{48, 120, 103}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 1 && erange == false)
	}
	{
		s := []u8{48, 120, 103}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 103}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{45, 48, 120, 48, 112, 43, 57, 57, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 12 && erange == false)
	}
	{
		s := []u8{45, 48, 120, 48, 112, 43, 57, 57, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && ok == true)
	}
	{
		s := []u8{45, 48, 120, 48, 112, 43, 57, 57, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 57, 57, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 11 && erange == true)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 57, 57, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 57, 57, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 101, 51, 48, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 5 && erange == true)
	}
	{
		s := []u8{49, 101, 51, 48, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 101, 51, 48, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{45, 49, 101, 51, 48, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xfff0000000000000 && consumed == 6 && erange == true)
	}
	{
		s := []u8{45, 49, 101, 51, 48, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{45, 49, 101, 51, 48, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xfff0000000000000)
	}
	{
		s := []u8{49, 101, 51, 48, 56}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7fe1ccf385ebc8a0 && consumed == 5 && erange == false)
	}
	{
		s := []u8{49, 101, 51, 48, 56}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x7fe1ccf385ebc8a0 && ok == true)
	}
	{
		s := []u8{49, 101, 51, 48, 56}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7fe1ccf385ebc8a0)
	}
	{
		s := []u8{49, 101, 57, 57, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 8 && erange == true)
	}
	{
		s := []u8{49, 101, 57, 57, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 101, 57, 57, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{45, 49, 101, 57, 57, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xfff0000000000000 && consumed == 9 && erange == true)
	}
	{
		s := []u8{45, 49, 101, 57, 57, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{45, 49, 101, 57, 57, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xfff0000000000000)
	}
	{
		s := []u8{48, 101, 57, 57, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 8 && erange == false)
	}
	{
		s := []u8{48, 101, 57, 57, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == true)
	}
	{
		s := []u8{48, 101, 57, 57, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{45, 48, 101, 57, 57, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 9 && erange == false)
	}
	{
		s := []u8{45, 48, 101, 57, 57, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && ok == true)
	}
	{
		s := []u8{45, 48, 101, 57, 57, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{49, 101, 45, 57, 57, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 9 && erange == true)
	}
	{
		s := []u8{49, 101, 45, 57, 57, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 101, 45, 57, 57, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{45, 49, 101, 45, 57, 57, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 10 && erange == true)
	}
	{
		s := []u8{45, 49, 101, 45, 57, 57, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{45, 49, 101, 45, 57, 57, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{48, 101, 45, 57, 57, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 9 && erange == false)
	}
	{
		s := []u8{48, 101, 45, 57, 57, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == true)
	}
	{
		s := []u8{48, 101, 45, 57, 57, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 55, 101, 51, 48, 56}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7fefffffffffffff && consumed == 22 && erange == false)
	}
	{
		s := []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 55, 101, 51, 48, 56}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x7fefffffffffffff && ok == true)
	}
	{
		s := []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 55, 101, 51, 48, 56}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7fefffffffffffff)
	}
	{
		s := []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 56, 101, 51, 48, 56}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7fefffffffffffff && consumed == 22 && erange == false)
	}
	{
		s := []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 56, 101, 51, 48, 56}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x7fefffffffffffff && ok == true)
	}
	{
		s := []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 56, 101, 51, 48, 56}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7fefffffffffffff)
	}
	{
		s := []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 57, 101, 51, 48, 56}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 22 && erange == true)
	}
	{
		s := []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 57, 101, 51, 48, 56}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 57, 101, 51, 48, 56}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 52, 101, 45, 51, 48, 56}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && consumed == 23 && erange == false)
	}
	{
		s := []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 52, 101, 45, 51, 48, 56}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && ok == true)
	}
	{
		s := []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 52, 101, 45, 51, 48, 56}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000)
	}
	{
		s := []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 51, 101, 45, 51, 48, 56}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && consumed == 23 && erange == false)
	}
	{
		s := []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 51, 101, 45, 51, 48, 56}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && ok == true)
	}
	{
		s := []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 51, 101, 45, 51, 48, 56}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000)
	}
	{
		s := []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 50, 101, 45, 51, 48, 56}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && consumed == 23 && erange == false)
	}
	{
		s := []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 50, 101, 45, 51, 48, 56}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && ok == true)
	}
	{
		s := []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 50, 101, 45, 51, 48, 56}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000)
	}
	{
		s := []u8{52, 46, 57, 52, 48, 54, 53, 54, 52, 53, 56, 52, 49, 50, 52, 54, 53, 52, 101, 45, 51, 50, 52}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001 && consumed == 23 && erange == false)
	}
	{
		s := []u8{52, 46, 57, 52, 48, 54, 53, 54, 52, 53, 56, 52, 49, 50, 52, 54, 53, 52, 101, 45, 51, 50, 52}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001 && ok == true)
	}
	{
		s := []u8{52, 46, 57, 52, 48, 54, 53, 54, 52, 53, 56, 52, 49, 50, 52, 54, 53, 52, 101, 45, 51, 50, 52}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001)
	}
	{
		s := []u8{52, 46, 57, 52, 48, 54, 53, 54, 52, 53, 56, 52, 49, 50, 52, 54, 53, 51, 101, 45, 51, 50, 52}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001 && consumed == 23 && erange == false)
	}
	{
		s := []u8{52, 46, 57, 52, 48, 54, 53, 54, 52, 53, 56, 52, 49, 50, 52, 54, 53, 51, 101, 45, 51, 50, 52}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001 && ok == true)
	}
	{
		s := []u8{52, 46, 57, 52, 48, 54, 53, 54, 52, 53, 56, 52, 49, 50, 52, 54, 53, 51, 101, 45, 51, 50, 52}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001)
	}
	{
		s := []u8{50, 46, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 101, 45, 51, 50, 52}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 23 && erange == true)
	}
	{
		s := []u8{50, 46, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 101, 45, 51, 50, 52}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{50, 46, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 101, 45, 51, 50, 52}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{50, 46, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 56, 101, 45, 51, 50, 52}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001 && consumed == 23 && erange == false)
	}
	{
		s := []u8{50, 46, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 56, 101, 45, 51, 50, 52}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001 && ok == true)
	}
	{
		s := []u8{50, 46, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 56, 101, 45, 51, 50, 52}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x433fffffffffffff && consumed == 16 && erange == false)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x433fffffffffffff && ok == true)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x433fffffffffffff)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 50}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000000 && consumed == 16 && erange == false)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 50}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000000 && ok == true)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 50}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000000)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 51}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000000 && consumed == 16 && erange == false)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 51}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000000 && ok == true)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 51}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000000)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 52}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000001 && consumed == 16 && erange == false)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 52}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000001 && ok == true)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 52}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000001)
	}
	{
		s := []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 55}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x43e0000000000000 && consumed == 19 && erange == false)
	}
	{
		s := []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 55}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x43e0000000000000 && ok == true)
	}
	{
		s := []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 55}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x43e0000000000000)
	}
	{
		s := []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 56}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x43e0000000000000 && consumed == 19 && erange == false)
	}
	{
		s := []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 56}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x43e0000000000000 && ok == true)
	}
	{
		s := []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 56}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x43e0000000000000)
	}
	{
		s := []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 56}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xc3e0000000000000 && consumed == 20 && erange == false)
	}
	{
		s := []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 56}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0xc3e0000000000000 && ok == true)
	}
	{
		s := []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 56}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xc3e0000000000000)
	}
	{
		s := []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xc3e0000000000000 && consumed == 20 && erange == false)
	}
	{
		s := []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0xc3e0000000000000 && ok == true)
	}
	{
		s := []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 48, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xc3e0000000000000)
	}
	{
		s := []u8{49, 56, 52, 52, 54, 55, 52, 52, 48, 55, 51, 55, 48, 57, 53, 53, 49, 54, 49, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x43f0000000000000 && consumed == 20 && erange == false)
	}
	{
		s := []u8{49, 56, 52, 52, 54, 55, 52, 52, 48, 55, 51, 55, 48, 57, 53, 53, 49, 54, 49, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x43f0000000000000 && ok == true)
	}
	{
		s := []u8{49, 56, 52, 52, 54, 55, 52, 52, 48, 55, 51, 55, 48, 57, 53, 53, 49, 54, 49, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x43f0000000000000)
	}
	{
		s := []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 55 && erange == false)
	}
	{
		s := []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 52, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 59 && erange == false)
	}
	{
		s := []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 52, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 52, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 53, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000001 && consumed == 59 && erange == false)
	}
	{
		s := []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 53, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000001 && ok == true)
	}
	{
		s := []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 53, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000001)
	}
	{
		s := []u8{45, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xbff0000000000000 && consumed == 56 && erange == false)
	}
	{
		s := []u8{45, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0xbff0000000000000 && ok == true)
	}
	{
		s := []u8{45, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 49, 49, 48, 50, 50, 51, 48, 50, 52, 54, 50, 53, 49, 53, 54, 53, 52, 48, 52, 50, 51, 54, 51, 49, 54, 54, 56, 48, 57, 48, 56, 50, 48, 51, 49, 50, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xbff0000000000000)
	}
	{
		s := []u8{48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 56 && erange == false)
	}
	{
		s := []u8{48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 52, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3fefffffffffffff && consumed == 60 && erange == false)
	}
	{
		s := []u8{48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 52, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3fefffffffffffff && ok == true)
	}
	{
		s := []u8{48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 52, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3fefffffffffffff)
	}
	{
		s := []u8{48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 53, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 60 && erange == false)
	}
	{
		s := []u8{48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 53, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 53, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000)
	}
	{
		s := []u8{45, 48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xbff0000000000000 && consumed == 57 && erange == false)
	}
	{
		s := []u8{45, 48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0xbff0000000000000 && ok == true)
	}
	{
		s := []u8{45, 48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 52, 52, 52, 56, 56, 56, 52, 56, 55, 54, 56, 55, 52, 50, 49, 55, 50, 57, 55, 56, 56, 49, 56, 52, 49, 54, 53, 57, 53, 52, 53, 56, 57, 56, 52, 51, 55, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xbff0000000000000)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 50, 46, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000000 && consumed == 21 && erange == false)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 50, 46, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000000 && ok == true)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 50, 46, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000000)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 51, 46, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000001 && consumed == 21 && erange == false)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 51, 46, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000001 && ok == true)
	}
	{
		s := []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 51, 46, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4340000000000001)
	}
	{
		s := []u8{45, 57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 51}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0xc340000000000000 && consumed == 17 && erange == false)
	}
	{
		s := []u8{45, 57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 51}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0xc340000000000000 && ok == true)
	}
	{
		s := []u8{45, 57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 51}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0xc340000000000000)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 1077 && erange == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 52, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 1081 && erange == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 52, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 52, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 53, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001 && consumed == 1081 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 53, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000001 && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 53, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{45, 48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000 && consumed == 1078 && erange == true)
	}
	{
		s := []u8{45, 48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{45, 48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 52, 55, 48, 51, 50, 56, 50, 50, 57, 50, 48, 54, 50, 51, 50, 55, 50, 48, 56, 56, 50, 56, 52, 51, 57, 54, 52, 51, 52, 49, 49, 48, 54, 56, 54, 49, 56, 50, 53, 50, 57, 57, 48, 49, 51, 48, 55, 49, 54, 50, 51, 56, 50, 50, 49, 50, 55, 57, 50, 56, 52, 49, 50, 53, 48, 51, 51, 55, 55, 53, 51, 54, 51, 53, 49, 48, 52, 51, 55, 53, 57, 51, 50, 54, 52, 57, 57, 49, 56, 49, 56, 48, 56, 49, 55, 57, 57, 54, 49, 56, 57, 56, 57, 56, 50, 56, 50, 51, 52, 55, 55, 50, 50, 56, 53, 56, 56, 54, 53, 52, 54, 51, 51, 50, 56, 51, 53, 53, 49, 55, 55, 57, 54, 57, 56, 57, 56, 49, 57, 57, 51, 56, 55, 51, 57, 56, 48, 48, 53, 51, 57, 48, 57, 51, 57, 48, 54, 51, 49, 53, 48, 51, 53, 54, 53, 57, 53, 49, 53, 53, 55, 48, 50, 50, 54, 51, 57, 50, 50, 57, 48, 56, 53, 56, 51, 57, 50, 52, 52, 57, 49, 48, 53, 49, 56, 52, 52, 51, 53, 57, 51, 49, 56, 48, 50, 56, 52, 57, 57, 51, 54, 53, 51, 54, 49, 53, 50, 53, 48, 48, 51, 49, 57, 51, 55, 48, 52, 53, 55, 54, 55, 56, 50, 52, 57, 50, 49, 57, 51, 54, 53, 54, 50, 51, 54, 54, 57, 56, 54, 51, 54, 53, 56, 52, 56, 48, 55, 53, 55, 48, 48, 49, 53, 56, 53, 55, 54, 57, 50, 54, 57, 57, 48, 51, 55, 48, 54, 51, 49, 49, 57, 50, 56, 50, 55, 57, 53, 53, 56, 53, 53, 49, 51, 51, 50, 57, 50, 55, 56, 51, 52, 51, 51, 56, 52, 48, 57, 51, 53, 49, 57, 55, 56, 48, 49, 53, 53, 51, 49, 50, 52, 54, 53, 57, 55, 50, 54, 51, 53, 55, 57, 53, 55, 52, 54, 50, 50, 55, 54, 54, 52, 54, 53, 50, 55, 50, 56, 50, 55, 50, 50, 48, 48, 53, 54, 51, 55, 52, 48, 48, 54, 52, 56, 53, 52, 57, 57, 57, 55, 55, 48, 57, 54, 53, 57, 57, 52, 55, 48, 52, 53, 52, 48, 50, 48, 56, 50, 56, 49, 54, 54, 50, 50, 54, 50, 51, 55, 56, 53, 55, 51, 57, 51, 52, 53, 48, 55, 51, 54, 51, 51, 57, 48, 48, 55, 57, 54, 55, 55, 54, 49, 57, 51, 48, 53, 55, 55, 53, 48, 54, 55, 52, 48, 49, 55, 54, 51, 50, 52, 54, 55, 51, 54, 48, 48, 57, 54, 56, 57, 53, 49, 51, 52, 48, 53, 51, 53, 53, 51, 55, 52, 53, 56, 53, 49, 54, 54, 54, 49, 49, 51, 52, 50, 50, 51, 55, 54, 54, 54, 55, 56, 54, 48, 52, 49, 54, 50, 49, 53, 57, 54, 56, 48, 52, 54, 49, 57, 49, 52, 52, 54, 55, 50, 57, 49, 56, 52, 48, 51, 48, 48, 53, 51, 48, 48, 53, 55, 53, 51, 48, 56, 52, 57, 48, 52, 56, 55, 54, 53, 51, 57, 49, 55, 49, 49, 51, 56, 54, 53, 57, 49, 54, 52, 54, 50, 51, 57, 53, 50, 52, 57, 49, 50, 54, 50, 51, 54, 53, 51, 56, 56, 49, 56, 55, 57, 54, 51, 54, 50, 51, 57, 51, 55, 51, 50, 56, 48, 52, 50, 51, 56, 57, 49, 48, 49, 56, 54, 55, 50, 51, 52, 56, 52, 57, 55, 54, 54, 56, 50, 51, 53, 48, 56, 57, 56, 54, 51, 51, 56, 56, 53, 56, 55, 57, 50, 53, 54, 50, 56, 51, 48, 50, 55, 53, 53, 57, 57, 53, 54, 53, 55, 53, 50, 52, 52, 53, 53, 53, 48, 55, 50, 53, 53, 49, 56, 57, 51, 49, 51, 54, 57, 48, 56, 51, 54, 50, 53, 52, 55, 55, 57, 49, 56, 54, 57, 52, 56, 54, 54, 55, 57, 57, 52, 57, 54, 56, 51, 50, 52, 48, 52, 57, 55, 48, 53, 56, 50, 49, 48, 50, 56, 53, 49, 51, 49, 56, 53, 52, 53, 49, 51, 57, 54, 50, 49, 51, 56, 51, 55, 55, 50, 50, 56, 50, 54, 49, 52, 53, 52, 51, 55, 54, 57, 51, 52, 49, 50, 53, 51, 50, 48, 57, 56, 53, 57, 49, 51, 50, 55, 54, 54, 55, 50, 51, 54, 51, 50, 56, 49, 50, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && consumed == 1077 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 52, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x000fffffffffffff && consumed == 1081 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 52, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x000fffffffffffff && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 52, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 53, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && consumed == 1081 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 53, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0010000000000000 && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 53, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{45, 48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 53}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x8010000000000000 && consumed == 1078 && erange == false)
	}
	{
		s := []u8{45, 48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 53}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x8010000000000000 && ok == true)
	}
	{
		s := []u8{45, 48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 49, 51, 54, 48, 53, 55, 52, 48, 57, 55, 57, 54, 55, 48, 57, 49, 51, 49, 57, 55, 53, 57, 51, 52, 56, 49, 57, 53, 52, 54, 51, 53, 49, 54, 52, 53, 54, 52, 56, 48, 50, 51, 52, 50, 54, 49, 48, 57, 55, 50, 52, 56, 50, 50, 50, 50, 50, 48, 50, 49, 48, 55, 54, 57, 52, 53, 53, 49, 54, 53, 50, 57, 53, 50, 51, 57, 48, 56, 49, 51, 53, 48, 56, 55, 57, 49, 52, 49, 52, 57, 49, 53, 56, 57, 49, 51, 48, 51, 57, 54, 50, 49, 49, 48, 54, 56, 55, 48, 48, 56, 54, 52, 51, 56, 54, 57, 52, 53, 57, 52, 54, 52, 53, 53, 50, 55, 54, 53, 55, 50, 48, 55, 52, 48, 55, 56, 50, 48, 54, 50, 49, 55, 52, 51, 51, 55, 57, 57, 56, 56, 49, 52, 49, 48, 54, 51, 50, 54, 55, 51, 50, 57, 50, 53, 51, 53, 53, 50, 50, 56, 54, 56, 56, 49, 51, 55, 50, 49, 52, 57, 48, 49, 50, 57, 56, 49, 49, 50, 50, 52, 53, 49, 52, 53, 49, 56, 56, 57, 56, 52, 57, 48, 53, 55, 50, 50, 50, 51, 48, 55, 50, 56, 53, 50, 53, 53, 49, 51, 51, 49, 53, 53, 55, 53, 53, 48, 49, 53, 57, 49, 52, 51, 57, 55, 52, 55, 54, 51, 57, 55, 57, 56, 51, 52, 49, 49, 56, 48, 49, 57, 57, 57, 51, 50, 51, 57, 54, 50, 53, 52, 56, 50, 56, 57, 48, 49, 55, 49, 48, 55, 48, 56, 49, 56, 53, 48, 54, 57, 48, 54, 51, 48, 54, 54, 54, 54, 53, 53, 57, 57, 52, 57, 51, 56, 50, 55, 53, 55, 55, 50, 53, 55, 50, 48, 49, 53, 55, 54, 51, 48, 54, 50, 54, 57, 48, 54, 54, 51, 51, 51, 50, 54, 52, 55, 53, 54, 53, 51, 48, 48, 48, 48, 57, 50, 52, 53, 56, 56, 56, 51, 49, 54, 52, 51, 51, 48, 51, 55, 55, 55, 57, 55, 57, 49, 56, 54, 57, 54, 49, 50, 48, 52, 57, 52, 57, 55, 51, 57, 48, 51, 55, 55, 56, 50, 57, 55, 48, 52, 57, 48, 53, 48, 53, 49, 48, 56, 48, 54, 48, 57, 57, 52, 48, 55, 51, 48, 50, 54, 50, 57, 51, 55, 49, 50, 56, 57, 53, 56, 57, 53, 48, 48, 48, 51, 53, 56, 51, 55, 57, 57, 57, 54, 55, 50, 48, 55, 50, 53, 52, 51, 48, 52, 51, 54, 48, 50, 56, 52, 48, 55, 56, 56, 57, 53, 55, 55, 49, 55, 57, 54, 49, 53, 48, 57, 52, 53, 53, 49, 54, 55, 52, 56, 50, 52, 51, 52, 55, 49, 48, 51, 48, 55, 48, 50, 54, 48, 57, 49, 52, 52, 54, 50, 49, 53, 55, 50, 50, 56, 57, 56, 56, 48, 50, 53, 56, 49, 56, 50, 53, 52, 53, 49, 56, 48, 51, 50, 53, 55, 48, 55, 48, 49, 56, 56, 54, 48, 56, 55, 50, 49, 49, 51, 49, 50, 56, 48, 55, 57, 53, 49, 50, 50, 51, 51, 52, 50, 54, 50, 56, 56, 51, 54, 56, 54, 50, 50, 51, 50, 49, 53, 48, 51, 55, 55, 53, 54, 54, 54, 54, 50, 50, 53, 48, 51, 57, 56, 50, 53, 51, 52, 51, 51, 53, 57, 55, 52, 53, 54, 56, 56, 56, 52, 52, 50, 51, 57, 48, 48, 50, 54, 53, 52, 57, 56, 49, 57, 56, 51, 56, 53, 52, 56, 55, 57, 52, 56, 50, 57, 50, 50, 48, 54, 56, 57, 52, 55, 50, 49, 54, 56, 57, 56, 51, 49, 48, 57, 57, 54, 57, 56, 51, 54, 53, 56, 52, 54, 56, 49, 52, 48, 50, 50, 56, 53, 52, 50, 52, 51, 51, 51, 48, 54, 54, 48, 51, 51, 57, 56, 53, 48, 56, 56, 54, 52, 52, 53, 56, 48, 52, 48, 48, 49, 48, 51, 52, 57, 51, 51, 57, 55, 48, 52, 50, 55, 53, 54, 55, 49, 56, 54, 52, 52, 51, 51, 56, 51, 55, 55, 48, 52, 56, 54, 48, 51, 55, 56, 54, 49, 54, 50, 50, 55, 55, 49, 55, 51, 56, 53, 52, 53, 54, 50, 51, 48, 54, 53, 56, 55, 52, 54, 55, 57, 48, 49, 52, 48, 56, 54, 55, 50, 51, 51, 50, 55, 54, 51, 54, 55, 49, 56, 55, 53}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x8000000000000000)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x5a4d8ba7f519c84f && consumed == 128 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x5a4d8ba7f519c84f && ok == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x25262e6d72d6dfb0 && consumed == 131 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x25262e6d72d6dfb0 && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x5a827748f9301d32 && consumed == 129 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x5a827748f9301d32 && ok == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x24f1bebdf578b2f4 && consumed == 132 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x24f1bebdf578b2f4 && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x74e10cb132c2ff63 && consumed == 256 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x74e10cb132c2ff63 && ok == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0a9338205089f29c && consumed == 259 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0a9338205089f29c && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 1024 && erange == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 1027 && erange == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 2048 && erange == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 2051 && erange == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 50, 52}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 1031 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 50, 52}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 50, 52}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 101, 45, 49, 48, 50, 51}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4024000000000000 && consumed == 1030 && erange == false)
	}
	{
		s := []u8{57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 101, 45, 49, 48, 50, 51}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x4024000000000000 && ok == true)
	}
	{
		s := []u8{57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 101, 45, 49, 48, 50, 51}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a4d8ba7f519c84f)
	}
	{
		s := []u8{110, 97, 110, 40, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 41}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 261 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 40, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 41}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 40, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 97, 41}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{49, 101, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000 && consumed == 258 && erange == true)
	}
	{
		s := []u8{49, 101, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 101, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff0000000000000)
	}
	{
		s := []u8{48, 120, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 112, 45, 49, 48, 50, 52}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && consumed == 264 && erange == false)
	}
	{
		s := []u8{48, 120, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 112, 45, 49, 48, 50, 52}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x3ff0000000000000 && ok == true)
	}
	{
		s := []u8{48, 120, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 102, 112, 45, 49, 48, 50, 52}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5f30000000000000)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && consumed == 261 && erange == true)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 49, 112, 45, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		v := f64(0h0000000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == true)
	}
	{
		v := f64(0h0000000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 1 && member_eq(buf[:n], []u8{48}))
	}
	{
		v := f64(0h0000000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 1 && member_eq(buf[:n], []u8{48}))
	}
	{
		v := f64(0h8000000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == true)
	}
	{
		v := f64(0h8000000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 2 && member_eq(buf[:n], []u8{45, 48}))
	}
	{
		v := f64(0h8000000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 2 && member_eq(buf[:n], []u8{45, 48}))
	}
	{
		v := f64(0h3ff0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 1 && ok == true)
	}
	{
		v := f64(0h3ff0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 1 && member_eq(buf[:n], []u8{49}))
	}
	{
		v := f64(0h3ff0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 1 && member_eq(buf[:n], []u8{49}))
	}
	{
		v := f64(0hbff0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -1 && ok == true)
	}
	{
		v := f64(0hbff0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 2 && member_eq(buf[:n], []u8{45, 49}))
	}
	{
		v := f64(0hbff0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 2 && member_eq(buf[:n], []u8{45, 49}))
	}
	{
		v := f64(0h4000000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 2 && ok == true)
	}
	{
		v := f64(0h4000000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 1 && member_eq(buf[:n], []u8{50}))
	}
	{
		v := f64(0h4000000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 1 && member_eq(buf[:n], []u8{50}))
	}
	{
		v := f64(0hc000000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -2 && ok == true)
	}
	{
		v := f64(0hc000000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 2 && member_eq(buf[:n], []u8{45, 50}))
	}
	{
		v := f64(0hc000000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 2 && member_eq(buf[:n], []u8{45, 50}))
	}
	{
		v := f64(0h3fe0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3fe0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{48, 46, 53}))
	}
	{
		v := f64(0h3fe0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{48, 46, 53}))
	}
	{
		v := f64(0hbfe0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbfe0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{45, 48, 46, 53}))
	}
	{
		v := f64(0hbfe0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{45, 48, 46, 53}))
	}
	{
		v := f64(0h3fb999999999999a)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3fb999999999999a)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{48, 46, 49}))
	}
	{
		v := f64(0h3fb999999999999a)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{48, 46, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}))
	}
	{
		v := f64(0hbfb999999999999a)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbfb999999999999a)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{45, 48, 46, 49}))
	}
	{
		v := f64(0hbfb999999999999a)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 48, 46, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}))
	}
	{
		v := f64(0h3ff8000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3ff8000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{49, 46, 53}))
	}
	{
		v := f64(0h3ff8000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{49, 46, 53}))
	}
	{
		v := f64(0hbff8000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbff8000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{45, 49, 46, 53}))
	}
	{
		v := f64(0hbff8000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{45, 49, 46, 53}))
	}
	{
		v := f64(0h3ff199999999999a)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3ff199999999999a)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{49, 46, 49}))
	}
	{
		v := f64(0h3ff199999999999a)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 18 && member_eq(buf[:n], []u8{49, 46, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}))
	}
	{
		v := f64(0hbff199999999999a)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbff199999999999a)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{45, 49, 46, 49}))
	}
	{
		v := f64(0hbff199999999999a)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{45, 49, 46, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}))
	}
	{
		v := f64(0h4022000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 9 && ok == true)
	}
	{
		v := f64(0h4022000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 1 && member_eq(buf[:n], []u8{57}))
	}
	{
		v := f64(0h4022000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 1 && member_eq(buf[:n], []u8{57}))
	}
	{
		v := f64(0hc022000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -9 && ok == true)
	}
	{
		v := f64(0hc022000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 2 && member_eq(buf[:n], []u8{45, 57}))
	}
	{
		v := f64(0hc022000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 2 && member_eq(buf[:n], []u8{45, 57}))
	}
	{
		v := f64(0h4024000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 10 && ok == true)
	}
	{
		v := f64(0h4024000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 2 && member_eq(buf[:n], []u8{49, 48}))
	}
	{
		v := f64(0h4024000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 2 && member_eq(buf[:n], []u8{49, 48}))
	}
	{
		v := f64(0hc024000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -10 && ok == true)
	}
	{
		v := f64(0hc024000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{45, 49, 48}))
	}
	{
		v := f64(0hc024000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{45, 49, 48}))
	}
	{
		v := f64(0h4059000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 100 && ok == true)
	}
	{
		v := f64(0h4059000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{49, 48, 48}))
	}
	{
		v := f64(0h4059000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{49, 48, 48}))
	}
	{
		v := f64(0hc059000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -100 && ok == true)
	}
	{
		v := f64(0hc059000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{45, 49, 48, 48}))
	}
	{
		v := f64(0hc059000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{45, 49, 48, 48}))
	}
	{
		v := f64(0h40dfffc000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 32767 && ok == true)
	}
	{
		v := f64(0h40dfffc000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{51, 50, 55, 54, 55}))
	}
	{
		v := f64(0h40dfffc000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{51, 50, 55, 54, 55}))
	}
	{
		v := f64(0hc0dfffc000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -32767 && ok == true)
	}
	{
		v := f64(0hc0dfffc000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 51, 50, 55, 54, 55}))
	}
	{
		v := f64(0hc0dfffc000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 51, 50, 55, 54, 55}))
	}
	{
		v := f64(0h40e0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 32768 && ok == true)
	}
	{
		v := f64(0h40e0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{51, 50, 55, 54, 56}))
	}
	{
		v := f64(0h40e0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{51, 50, 55, 54, 56}))
	}
	{
		v := f64(0hc0e0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -32768 && ok == true)
	}
	{
		v := f64(0hc0e0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 51, 50, 55, 54, 56}))
	}
	{
		v := f64(0hc0e0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 51, 50, 55, 54, 56}))
	}
	{
		v := f64(0h40efffe000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 65535 && ok == true)
	}
	{
		v := f64(0h40efffe000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{54, 53, 53, 51, 53}))
	}
	{
		v := f64(0h40efffe000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{54, 53, 53, 51, 53}))
	}
	{
		v := f64(0hc0efffe000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -65535 && ok == true)
	}
	{
		v := f64(0hc0efffe000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 54, 53, 53, 51, 53}))
	}
	{
		v := f64(0hc0efffe000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 54, 53, 53, 51, 53}))
	}
	{
		v := f64(0h41dfffffffc00000)
		n, ok := double2ll(v)
		testing.expect(t, n == 2147483647 && ok == true)
	}
	{
		v := f64(0h41dfffffffc00000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 10 && member_eq(buf[:n], []u8{50, 49, 52, 55, 52, 56, 51, 54, 52, 55}))
	}
	{
		v := f64(0h41dfffffffc00000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 10 && member_eq(buf[:n], []u8{50, 49, 52, 55, 52, 56, 51, 54, 52, 55}))
	}
	{
		v := f64(0hc1dfffffffc00000)
		n, ok := double2ll(v)
		testing.expect(t, n == -2147483647 && ok == true)
	}
	{
		v := f64(0hc1dfffffffc00000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 11 && member_eq(buf[:n], []u8{45, 50, 49, 52, 55, 52, 56, 51, 54, 52, 55}))
	}
	{
		v := f64(0hc1dfffffffc00000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 11 && member_eq(buf[:n], []u8{45, 50, 49, 52, 55, 52, 56, 51, 54, 52, 55}))
	}
	{
		v := f64(0h41e0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 2147483648 && ok == true)
	}
	{
		v := f64(0h41e0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 10 && member_eq(buf[:n], []u8{50, 49, 52, 55, 52, 56, 51, 54, 52, 56}))
	}
	{
		v := f64(0h41e0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 10 && member_eq(buf[:n], []u8{50, 49, 52, 55, 52, 56, 51, 54, 52, 56}))
	}
	{
		v := f64(0hc1e0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -2147483648 && ok == true)
	}
	{
		v := f64(0hc1e0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 11 && member_eq(buf[:n], []u8{45, 50, 49, 52, 55, 52, 56, 51, 54, 52, 56}))
	}
	{
		v := f64(0hc1e0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 11 && member_eq(buf[:n], []u8{45, 50, 49, 52, 55, 52, 56, 51, 54, 52, 56}))
	}
	{
		v := f64(0h41f0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4294967296 && ok == true)
	}
	{
		v := f64(0h41f0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 10 && member_eq(buf[:n], []u8{52, 50, 57, 52, 57, 54, 55, 50, 57, 54}))
	}
	{
		v := f64(0h41f0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 10 && member_eq(buf[:n], []u8{52, 50, 57, 52, 57, 54, 55, 50, 57, 54}))
	}
	{
		v := f64(0hc1f0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -4294967296 && ok == true)
	}
	{
		v := f64(0hc1f0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 11 && member_eq(buf[:n], []u8{45, 52, 50, 57, 52, 57, 54, 55, 50, 57, 54}))
	}
	{
		v := f64(0hc1f0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 11 && member_eq(buf[:n], []u8{45, 52, 50, 57, 52, 57, 54, 55, 50, 57, 54}))
	}
	{
		v := f64(0h432ffffffffffffe)
		n, ok := double2ll(v)
		testing.expect(t, n == 4503599627370495 && ok == true)
	}
	{
		v := f64(0h432ffffffffffffe)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{52, 53, 48, 51, 53, 57, 57, 54, 50, 55, 51, 55, 48, 52, 57, 53}))
	}
	{
		v := f64(0h432ffffffffffffe)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{52, 53, 48, 51, 53, 57, 57, 54, 50, 55, 51, 55, 48, 52, 57, 53}))
	}
	{
		v := f64(0hc32ffffffffffffe)
		n, ok := double2ll(v)
		testing.expect(t, n == -4503599627370495 && ok == true)
	}
	{
		v := f64(0hc32ffffffffffffe)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 52, 53, 48, 51, 53, 57, 57, 54, 50, 55, 51, 55, 48, 52, 57, 53}))
	}
	{
		v := f64(0hc32ffffffffffffe)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 52, 53, 48, 51, 53, 57, 57, 54, 50, 55, 51, 55, 48, 52, 57, 53}))
	}
	{
		v := f64(0h4330000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4503599627370496 && ok == true)
	}
	{
		v := f64(0h4330000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{52, 53, 48, 51, 53, 57, 57, 54, 50, 55, 51, 55, 48, 52, 57, 54}))
	}
	{
		v := f64(0h4330000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{52, 53, 48, 51, 53, 57, 57, 54, 50, 55, 51, 55, 48, 52, 57, 54}))
	}
	{
		v := f64(0hc330000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -4503599627370496 && ok == true)
	}
	{
		v := f64(0hc330000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 52, 53, 48, 51, 53, 57, 57, 54, 50, 55, 51, 55, 48, 52, 57, 54}))
	}
	{
		v := f64(0hc330000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 52, 53, 48, 51, 53, 57, 57, 54, 50, 55, 51, 55, 48, 52, 57, 54}))
	}
	{
		v := f64(0h433fffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == 9007199254740991 && ok == true)
	}
	{
		v := f64(0h433fffffffffffff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 49}))
	}
	{
		v := f64(0h433fffffffffffff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 49}))
	}
	{
		v := f64(0hc33fffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == -9007199254740991 && ok == true)
	}
	{
		v := f64(0hc33fffffffffffff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 49}))
	}
	{
		v := f64(0hc33fffffffffffff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 49}))
	}
	{
		v := f64(0h4340000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 9007199254740992 && ok == true)
	}
	{
		v := f64(0h4340000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 50}))
	}
	{
		v := f64(0h4340000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 50}))
	}
	{
		v := f64(0hc340000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -9007199254740992 && ok == true)
	}
	{
		v := f64(0hc340000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 50}))
	}
	{
		v := f64(0hc340000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 50}))
	}
	{
		v := f64(0h4340000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == 9007199254740994 && ok == true)
	}
	{
		v := f64(0h4340000000000001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 52}))
	}
	{
		v := f64(0h4340000000000001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 52}))
	}
	{
		v := f64(0hc340000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == -9007199254740994 && ok == true)
	}
	{
		v := f64(0hc340000000000001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 52}))
	}
	{
		v := f64(0hc340000000000001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 57, 48, 48, 55, 49, 57, 57, 50, 53, 52, 55, 52, 48, 57, 57, 52}))
	}
	{
		v := f64(0h43dfffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43dfffffffffffff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 48, 48, 48}))
	}
	{
		v := f64(0h43dfffffffffffff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 52, 56, 101, 43, 49, 56}))
	}
	{
		v := f64(0hc3dfffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3dfffffffffffff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 48, 48, 48}))
	}
	{
		v := f64(0hc3dfffffffffffff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 52, 56, 101, 43, 49, 56}))
	}
	{
		v := f64(0h43e0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43e0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 54, 48, 48, 48}))
	}
	{
		v := f64(0h43e0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 101, 43, 49, 56}))
	}
	{
		v := f64(0hc3e0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3e0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 54, 48, 48, 48}))
	}
	{
		v := f64(0hc3e0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 53, 56, 101, 43, 49, 56}))
	}
	{
		v := f64(0hc3e0000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3e0000000000001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 56, 48, 48, 48}))
	}
	{
		v := f64(0hc3e0000000000001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 55, 57, 101, 43, 49, 56}))
	}
	{
		v := f64(0h43e0000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43e0000000000001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 56, 48, 48, 48}))
	}
	{
		v := f64(0h43e0000000000001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 55, 57, 101, 43, 49, 56}))
	}
	{
		v := f64(0hbe45798ee2308c3a)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbe45798ee2308c3a)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{45, 49, 101, 45, 56}))
	}
	{
		v := f64(0hbe45798ee2308c3a)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 49, 101, 45, 48, 56}))
	}
	{
		v := f64(0h3e45798ee2308c3a)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3e45798ee2308c3a)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{49, 101, 45, 56}))
	}
	{
		v := f64(0h3e45798ee2308c3a)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{49, 101, 45, 48, 56}))
	}
	{
		v := f64(0hbe7ad7f29abcaf48)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbe7ad7f29abcaf48)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{45, 49, 101, 45, 55}))
	}
	{
		v := f64(0hbe7ad7f29abcaf48)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 57, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 53, 101, 45, 48, 56}))
	}
	{
		v := f64(0h3e7ad7f29abcaf48)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3e7ad7f29abcaf48)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{49, 101, 45, 55}))
	}
	{
		v := f64(0h3e7ad7f29abcaf48)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 53, 101, 45, 48, 56}))
	}
	{
		v := f64(0hbeb0c6f7a0b5ed8d)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbeb0c6f7a0b5ed8d)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 9 && member_eq(buf[:n], []u8{45, 48, 46, 48, 48, 48, 48, 48, 49}))
	}
	{
		v := f64(0hbeb0c6f7a0b5ed8d)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 57, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 53, 101, 45, 48, 55}))
	}
	{
		v := f64(0h3eb0c6f7a0b5ed8d)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3eb0c6f7a0b5ed8d)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 8 && member_eq(buf[:n], []u8{48, 46, 48, 48, 48, 48, 48, 49}))
	}
	{
		v := f64(0h3eb0c6f7a0b5ed8d)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 53, 101, 45, 48, 55}))
	}
	{
		v := f64(0hbee4f8b588e368f1)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbee4f8b588e368f1)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 8 && member_eq(buf[:n], []u8{45, 48, 46, 48, 48, 48, 48, 49}))
	}
	{
		v := f64(0hbee4f8b588e368f1)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 101, 45, 48, 53}))
	}
	{
		v := f64(0h3ee4f8b588e368f1)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3ee4f8b588e368f1)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 7 && member_eq(buf[:n], []u8{48, 46, 48, 48, 48, 48, 49}))
	}
	{
		v := f64(0h3ee4f8b588e368f1)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49, 101, 45, 48, 53}))
	}
	{
		v := f64(0hbf1a36e2eb1c432d)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbf1a36e2eb1c432d)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 7 && member_eq(buf[:n], []u8{45, 48, 46, 48, 48, 48, 49}))
	}
	{
		v := f64(0hbf1a36e2eb1c432d)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 7 && member_eq(buf[:n], []u8{45, 48, 46, 48, 48, 48, 49}))
	}
	{
		v := f64(0h3f1a36e2eb1c432d)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3f1a36e2eb1c432d)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{48, 46, 48, 48, 48, 49}))
	}
	{
		v := f64(0h3f1a36e2eb1c432d)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{48, 46, 48, 48, 48, 49}))
	}
	{
		v := f64(0hbf50624dd2f1a9fc)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbf50624dd2f1a9fc)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 48, 46, 48, 48, 49}))
	}
	{
		v := f64(0hbf50624dd2f1a9fc)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 48, 46, 48, 48, 49}))
	}
	{
		v := f64(0h3f50624dd2f1a9fc)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3f50624dd2f1a9fc)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{48, 46, 48, 48, 49}))
	}
	{
		v := f64(0h3f50624dd2f1a9fc)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{48, 46, 48, 48, 49}))
	}
	{
		v := f64(0hc2d6bcc41e900000)
		n, ok := double2ll(v)
		testing.expect(t, n == -100000000000000 && ok == true)
	}
	{
		v := f64(0hc2d6bcc41e900000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{45, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0hc2d6bcc41e900000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{45, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0h42d6bcc41e900000)
		n, ok := double2ll(v)
		testing.expect(t, n == 100000000000000 && ok == true)
	}
	{
		v := f64(0h42d6bcc41e900000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 15 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0h42d6bcc41e900000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 15 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0hc30c6bf526340000)
		n, ok := double2ll(v)
		testing.expect(t, n == -1000000000000000 && ok == true)
	}
	{
		v := f64(0hc30c6bf526340000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0hc30c6bf526340000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{45, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0h430c6bf526340000)
		n, ok := double2ll(v)
		testing.expect(t, n == 1000000000000000 && ok == true)
	}
	{
		v := f64(0h430c6bf526340000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0h430c6bf526340000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0hc341c37937e08000)
		n, ok := double2ll(v)
		testing.expect(t, n == -10000000000000000 && ok == true)
	}
	{
		v := f64(0hc341c37937e08000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 18 && member_eq(buf[:n], []u8{45, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0hc341c37937e08000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 18 && member_eq(buf[:n], []u8{45, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0h4341c37937e08000)
		n, ok := double2ll(v)
		testing.expect(t, n == 10000000000000000 && ok == true)
	}
	{
		v := f64(0h4341c37937e08000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0h4341c37937e08000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0hc376345785d8a000)
		n, ok := double2ll(v)
		testing.expect(t, n == -100000000000000000 && ok == true)
	}
	{
		v := f64(0hc376345785d8a000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{45, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0hc376345785d8a000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 49, 101, 43, 49, 55}))
	}
	{
		v := f64(0h4376345785d8a000)
		n, ok := double2ll(v)
		testing.expect(t, n == 100000000000000000 && ok == true)
	}
	{
		v := f64(0h4376345785d8a000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 18 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0h4376345785d8a000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{49, 101, 43, 49, 55}))
	}
	{
		v := f64(0hc3abc16d674ec800)
		n, ok := double2ll(v)
		testing.expect(t, n == -1000000000000000000 && ok == true)
	}
	{
		v := f64(0hc3abc16d674ec800)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0hc3abc16d674ec800)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 49, 101, 43, 49, 56}))
	}
	{
		v := f64(0h43abc16d674ec800)
		n, ok := double2ll(v)
		testing.expect(t, n == 1000000000000000000 && ok == true)
	}
	{
		v := f64(0h43abc16d674ec800)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0h43abc16d674ec800)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{49, 101, 43, 49, 56}))
	}
	{
		v := f64(0hc3e158e460913d00)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3e158e460913d00)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 49, 101, 43, 49, 57}))
	}
	{
		v := f64(0hc3e158e460913d00)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 49, 101, 43, 49, 57}))
	}
	{
		v := f64(0h43e158e460913d00)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43e158e460913d00)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{49, 101, 43, 49, 57}))
	}
	{
		v := f64(0h43e158e460913d00)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{49, 101, 43, 49, 57}))
	}
	{
		v := f64(0hc415af1d78b58c40)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc415af1d78b58c40)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 49, 101, 43, 50, 48}))
	}
	{
		v := f64(0hc415af1d78b58c40)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 49, 101, 43, 50, 48}))
	}
	{
		v := f64(0h4415af1d78b58c40)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h4415af1d78b58c40)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{49, 101, 43, 50, 48}))
	}
	{
		v := f64(0h4415af1d78b58c40)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{49, 101, 43, 50, 48}))
	}
	{
		v := f64(0hc44b1ae4d6e2ef50)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc44b1ae4d6e2ef50)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 49, 101, 43, 50, 49}))
	}
	{
		v := f64(0hc44b1ae4d6e2ef50)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 49, 101, 43, 50, 49}))
	}
	{
		v := f64(0h444b1ae4d6e2ef50)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h444b1ae4d6e2ef50)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{49, 101, 43, 50, 49}))
	}
	{
		v := f64(0h444b1ae4d6e2ef50)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{49, 101, 43, 50, 49}))
	}
	{
		v := f64(0hc480f0cf064dd592)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc480f0cf064dd592)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 49, 101, 43, 50, 50}))
	}
	{
		v := f64(0hc480f0cf064dd592)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{45, 49, 101, 43, 50, 50}))
	}
	{
		v := f64(0h4480f0cf064dd592)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h4480f0cf064dd592)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{49, 101, 43, 50, 50}))
	}
	{
		v := f64(0h4480f0cf064dd592)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 5 && member_eq(buf[:n], []u8{49, 101, 43, 50, 50}))
	}
	{
		v := f64(0hc4b52d02c7e14af6)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc4b52d02c7e14af6)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 24 && member_eq(buf[:n], []u8{45, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0hc4b52d02c7e14af6)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 57, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 50, 101, 43, 50, 50}))
	}
	{
		v := f64(0h44b52d02c7e14af6)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h44b52d02c7e14af6)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 48, 48, 48, 48, 48, 48, 48}))
	}
	{
		v := f64(0h44b52d02c7e14af6)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 50, 101, 43, 50, 50}))
	}
	{
		v := f64(0h8000000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h8000000000000001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 7 && member_eq(buf[:n], []u8{45, 53, 101, 45, 51, 50, 52}))
	}
	{
		v := f64(0h8000000000000001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 24 && member_eq(buf[:n], []u8{45, 52, 46, 57, 52, 48, 54, 53, 54, 52, 53, 56, 52, 49, 50, 52, 54, 53, 52, 101, 45, 51, 50, 52}))
	}
	{
		v := f64(0h0000000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h0000000000000001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 6 && member_eq(buf[:n], []u8{53, 101, 45, 51, 50, 52}))
	}
	{
		v := f64(0h0000000000000001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{52, 46, 57, 52, 48, 54, 53, 54, 52, 53, 56, 52, 49, 50, 52, 54, 53, 52, 101, 45, 51, 50, 52}))
	}
	{
		v := f64(0h3fefffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3fefffffffffffff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 18 && member_eq(buf[:n], []u8{48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57}))
	}
	{
		v := f64(0h3fefffffffffffff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 56, 57}))
	}
	{
		v := f64(0h3ff0000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3ff0000000000001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 18 && member_eq(buf[:n], []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50}))
	}
	{
		v := f64(0h3ff0000000000001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 18 && member_eq(buf[:n], []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50}))
	}
	{
		v := f64(0hbff0000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbff0000000000001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{45, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50}))
	}
	{
		v := f64(0hbff0000000000001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{45, 49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50}))
	}
	{
		v := f64(0hbfefffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hbfefffffffffffff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{45, 48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57}))
	}
	{
		v := f64(0hbfefffffffffffff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 48, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 56, 57}))
	}
	{
		v := f64(0h3fb9999999999999)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3fb9999999999999)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{48, 46, 48, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57}))
	}
	{
		v := f64(0h3fb9999999999999)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{48, 46, 48, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 50}))
	}
	{
		v := f64(0h3fb999999999999b)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3fb999999999999b)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{48, 46, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50}))
	}
	{
		v := f64(0h3fb999999999999b)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{48, 46, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50}))
	}
	{
		v := f64(0h3f1a36e2eb1c432c)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3f1a36e2eb1c432c)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{57, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 101, 45, 53}))
	}
	{
		v := f64(0h3f1a36e2eb1c432c)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 49, 101, 45, 48, 53}))
	}
	{
		v := f64(0h3f1a36e2eb1c432e)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3f1a36e2eb1c432e)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 21 && member_eq(buf[:n], []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 101, 45, 52}))
	}
	{
		v := f64(0h3f1a36e2eb1c432e)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{48, 46, 48, 48, 48, 49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50}))
	}
	{
		v := f64(0h3ee4f8b588e368f0)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3ee4f8b588e368f0)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{57, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 101, 45, 54}))
	}
	{
		v := f64(0h3ee4f8b588e368f0)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 49, 101, 45, 48, 54}))
	}
	{
		v := f64(0h3ee4f8b588e368f2)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h3ee4f8b588e368f2)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 21 && member_eq(buf[:n], []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 51, 101, 45, 53}))
	}
	{
		v := f64(0h3ee4f8b588e368f2)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 51, 101, 45, 48, 53}))
	}
	{
		v := f64(0h430c6bf52633ffff)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h430c6bf52633ffff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 46, 57}))
	}
	{
		v := f64(0h430c6bf52633ffff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 18 && member_eq(buf[:n], []u8{57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 46, 56, 56}))
	}
	{
		v := f64(0h430c6bf526340001)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h430c6bf526340001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 18 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 46, 49}))
	}
	{
		v := f64(0h430c6bf526340001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 18 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 46, 49}))
	}
	{
		v := f64(0h4341c37937e07fff)
		n, ok := double2ll(v)
		testing.expect(t, n == 9999999999999998 && ok == true)
	}
	{
		v := f64(0h4341c37937e07fff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 56}))
	}
	{
		v := f64(0h4341c37937e07fff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 16 && member_eq(buf[:n], []u8{57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 56}))
	}
	{
		v := f64(0h4341c37937e08001)
		n, ok := double2ll(v)
		testing.expect(t, n == 10000000000000002 && ok == true)
	}
	{
		v := f64(0h4341c37937e08001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50}))
	}
	{
		v := f64(0h4341c37937e08001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 17 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50}))
	}
	{
		v := f64(0h4415af1d78b58c3f)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h4415af1d78b58c3f)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 56, 48, 48, 48, 48}))
	}
	{
		v := f64(0h4415af1d78b58c3f)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 57, 56, 52, 101, 43, 49, 57}))
	}
	{
		v := f64(0h4415af1d78b58c41)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h4415af1d78b58c41)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 21 && member_eq(buf[:n], []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 48, 48, 48, 48}))
	}
	{
		v := f64(0h4415af1d78b58c41)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{49, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 50, 101, 43, 50, 48}))
	}
	{
		v := f64(0h0010000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h0010000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 52, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0h0010000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 52, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0h000fffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h000fffffffffffff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0h000fffffffffffff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 48, 57, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0h0010000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h0010000000000001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 50, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0h0010000000000001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 57, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0h7fefffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h7fefffffffffffff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 55, 101, 43, 51, 48, 56}))
	}
	{
		v := f64(0h7fefffffffffffff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 55, 101, 43, 51, 48, 56}))
	}
	{
		v := f64(0h7feffffffffffffe)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h7feffffffffffffe)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 53, 101, 43, 51, 48, 56}))
	}
	{
		v := f64(0h7feffffffffffffe)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 53, 101, 43, 51, 48, 56}))
	}
	{
		v := f64(0h7ff0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h7ff0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{105, 110, 102}))
	}
	{
		v := f64(0h7ff0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{105, 110, 102}))
	}
	{
		v := f64(0h800fffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h800fffffffffffff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0h800fffffffffffff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 24 && member_eq(buf[:n], []u8{45, 50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 48, 57, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0h8010000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h8010000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 24 && member_eq(buf[:n], []u8{45, 50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 52, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0h8010000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 24 && member_eq(buf[:n], []u8{45, 50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 52, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0h8010000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h8010000000000001)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 50, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0h8010000000000001)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 24 && member_eq(buf[:n], []u8{45, 50, 46, 50, 50, 53, 48, 55, 51, 56, 53, 56, 53, 48, 55, 50, 48, 49, 57, 101, 45, 51, 48, 56}))
	}
	{
		v := f64(0hffefffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hffefffffffffffff)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 24 && member_eq(buf[:n], []u8{45, 49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 55, 101, 43, 51, 48, 56}))
	}
	{
		v := f64(0hffefffffffffffff)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 24 && member_eq(buf[:n], []u8{45, 49, 46, 55, 57, 55, 54, 57, 51, 49, 51, 52, 56, 54, 50, 51, 49, 53, 55, 101, 43, 51, 48, 56}))
	}
	{
		v := f64(0hfff0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hfff0000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{45, 105, 110, 102}))
	}
	{
		v := f64(0hfff0000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 4 && member_eq(buf[:n], []u8{45, 105, 110, 102}))
	}
	{
		v := f64(0h7ff8000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h7ff8000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{110, 97, 110}))
	}
	{
		v := f64(0h7ff8000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{110, 97, 110}))
	}
	{
		v := f64(0hfff8000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hfff8000000000000)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{110, 97, 110}))
	}
	{
		v := f64(0hfff8000000000000)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{110, 97, 110}))
	}
	{
		v := f64(0h7ff8000000001234)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h7ff8000000001234)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{110, 97, 110}))
	}
	{
		v := f64(0h7ff8000000001234)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 3 && member_eq(buf[:n], []u8{110, 97, 110}))
	}
	{
		v := f64(0h43dffffffffffffc)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43dffffffffffffc)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 50, 48, 48, 48}))
	}
	{
		v := f64(0h43dffffffffffffc)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 49, 55, 101, 43, 49, 56}))
	}
	{
		v := f64(0h43dffffffffffffd)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43dffffffffffffd)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 51, 48, 48, 48}))
	}
	{
		v := f64(0h43dffffffffffffd)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 50, 55, 101, 43, 49, 56}))
	}
	{
		v := f64(0h43dffffffffffffe)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43dffffffffffffe)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 52, 48, 48, 48}))
	}
	{
		v := f64(0h43dffffffffffffe)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 51, 56, 101, 43, 49, 56}))
	}
	{
		v := f64(0h43e0000000000002)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43e0000000000002)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 56, 48, 48, 48, 48}))
	}
	{
		v := f64(0h43e0000000000002)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 57, 57, 101, 43, 49, 56}))
	}
	{
		v := f64(0h43e0000000000003)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43e0000000000003)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 56, 50, 48, 48, 48}))
	}
	{
		v := f64(0h43e0000000000003)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 21 && member_eq(buf[:n], []u8{57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 56, 50, 101, 43, 49, 56}))
	}
	{
		v := f64(0h43e0000000000004)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43e0000000000004)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 19 && member_eq(buf[:n], []u8{57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 56, 52, 48, 48, 48}))
	}
	{
		v := f64(0h43e0000000000004)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 21 && member_eq(buf[:n], []u8{57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 56, 52, 101, 43, 49, 56}))
	}
	{
		v := f64(0hc3dffffffffffffc)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3dffffffffffffc)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 50, 48, 48, 48}))
	}
	{
		v := f64(0hc3dffffffffffffc)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 49, 55, 101, 43, 49, 56}))
	}
	{
		v := f64(0hc3dffffffffffffd)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3dffffffffffffd)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 51, 48, 48, 48}))
	}
	{
		v := f64(0hc3dffffffffffffd)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 50, 55, 101, 43, 49, 56}))
	}
	{
		v := f64(0hc3dffffffffffffe)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3dffffffffffffe)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 52, 48, 48, 48}))
	}
	{
		v := f64(0hc3dffffffffffffe)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 51, 56, 101, 43, 49, 56}))
	}
	{
		v := f64(0hc3e0000000000002)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3e0000000000002)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 56, 48, 48, 48, 48}))
	}
	{
		v := f64(0hc3e0000000000002)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 23 && member_eq(buf[:n], []u8{45, 57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 55, 57, 57, 101, 43, 49, 56}))
	}
	{
		v := f64(0hc3e0000000000003)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3e0000000000003)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 56, 50, 48, 48, 48}))
	}
	{
		v := f64(0hc3e0000000000003)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{45, 57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 56, 50, 101, 43, 49, 56}))
	}
	{
		v := f64(0hc3e0000000000004)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3e0000000000004)
		buf: [64]u8
		n := d2string(buf[:], v)
		testing.expect(t, n == 20 && member_eq(buf[:n], []u8{45, 57, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 56, 52, 48, 48, 48}))
	}
	{
		v := f64(0hc3e0000000000004)
		buf: [64]u8
		n := format_g17(buf[:], v)
		testing.expect(t, n == 22 && member_eq(buf[:n], []u8{45, 57, 46, 50, 50, 51, 51, 55, 50, 48, 51, 54, 56, 53, 52, 55, 56, 52, 101, 43, 49, 56}))
	}
	{
		v := f64(0h4390000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 288230376151711744 && ok == true)
	}
	{
		v := f64(0h43b8000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 1729382256910270464 && ok == true)
	}
	{
		v := f64(0h43cc000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4035225266123964416 && ok == true)
	}
	{
		v := f64(0h43d6000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d1000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43ce800000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4395513236313604096 && ok == true)
	}
	{
		v := f64(0h43cfc00000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4575657221408423936 && ok == true)
	}
	{
		v := f64(0h43d0600000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0100000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cfe80000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4598175219545276416 && ok == true)
	}
	{
		v := f64(0h43cffc0000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4609434218613702656 && ok == true)
	}
	{
		v := f64(0h43d0060000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0010000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cffe8000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4610841593497255936 && ok == true)
	}
	{
		v := f64(0h43cfffc000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611545280939032576 && ok == true)
	}
	{
		v := f64(0h43d0006000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0001000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cfffe800000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611633241869254656 && ok == true)
	}
	{
		v := f64(0h43cffffc00000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611677222334365696 && ok == true)
	}
	{
		v := f64(0h43d0000600000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0000100000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cffffe80000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611682719892504576 && ok == true)
	}
	{
		v := f64(0h43cfffffc0000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611685468671574016 && ok == true)
	}
	{
		v := f64(0h43d0000060000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0000010000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cfffffe8000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611685812268957696 && ok == true)
	}
	{
		v := f64(0h43cffffffc000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611685984067649536 && ok == true)
	}
	{
		v := f64(0h43d0000006000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0000001000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cffffffe800000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686005542486016 && ok == true)
	}
	{
		v := f64(0h43cfffffffc00000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686016279904256 && ok == true)
	}
	{
		v := f64(0h43d0000000600000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0000000100000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cfffffffe80000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686017622081536 && ok == true)
	}
	{
		v := f64(0h43cffffffffc0000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018293170176 && ok == true)
	}
	{
		v := f64(0h43d0000000060000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0000000010000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cffffffffe8000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018377056256 && ok == true)
	}
	{
		v := f64(0h43cfffffffffc000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018418999296 && ok == true)
	}
	{
		v := f64(0h43d0000000006000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0000000001000)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cfffffffffe800)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018424242176 && ok == true)
	}
	{
		v := f64(0h43cffffffffffc00)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018426863616 && ok == true)
	}
	{
		v := f64(0h43d0000000000600)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0000000000100)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cffffffffffe80)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018427191296 && ok == true)
	}
	{
		v := f64(0h43cfffffffffffc0)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018427355136 && ok == true)
	}
	{
		v := f64(0h43d0000000000060)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0000000000010)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cfffffffffffe8)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018427375616 && ok == true)
	}
	{
		v := f64(0h43cffffffffffffc)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018427385856 && ok == true)
	}
	{
		v := f64(0h43d0000000000006)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43d0000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0h43cffffffffffffe)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018427386880 && ok == true)
	}
	{
		v := f64(0h43cfffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018427387392 && ok == true)
	}
	{
		v := f64(0h43d0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == 4611686018427387904 && ok == true)
	}
	{
		v := f64(0h43d0000000000002)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3cffffffffffffe)
		n, ok := double2ll(v)
		testing.expect(t, n == -4611686018427386880 && ok == true)
	}
	{
		v := f64(0hc3cfffffffffffff)
		n, ok := double2ll(v)
		testing.expect(t, n == -4611686018427387392 && ok == true)
	}
	{
		v := f64(0hc3d0000000000000)
		n, ok := double2ll(v)
		testing.expect(t, n == -4611686018427387904 && ok == true)
	}
	{
		v := f64(0hc3d0000000000001)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		v := f64(0hc3d0000000000002)
		n, ok := double2ll(v)
		testing.expect(t, n == 0 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x44b52d02c7e14af6 && consumed == 129 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x44b52d02c7e14af6 && ok == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x59435ceaeb2d28c1)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x2665275ed8d8f36c && consumed == 125 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x2665275ed8d8f36c && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x2665275ed8d8f36c)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x59783425a5f872f1 && consumed == 124 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x59783425a5f872f1)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x59783425a5f872f1 && consumed == 124 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x59783425a5f872f1)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x44ea784379d99db4 && consumed == 130 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x44ea784379d99db4 && ok == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x59ae412f0f768fad)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x2630ec4be0ad8f89 && consumed == 126 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x2630ec4be0ad8f89 && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x2630ec4be0ad8f89)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x59ae412f0f768fad && consumed == 125 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x59ae412f0f768fad)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x59ae412f0f768fad && consumed == 125 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x59ae412f0f768fad)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x45208b2a2c280291 && consumed == 131 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x45208b2a2c280291 && ok == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x59e2e8bd69aa19cc)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x25fb13ac9aaf4c0f && consumed == 127 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x25fb13ac9aaf4c0f && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x25fb13ac9aaf4c0f)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x59e2e8bd69aa19cc && consumed == 126 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x59e2e8bd69aa19cc)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x59e2e8bd69aa19cc && consumed == 126 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x59e2e8bd69aa19cc)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4554adf4b7320335 && consumed == 132 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x4554adf4b7320335 && ok == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x25c5a956e225d672 && consumed == 128 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x25c5a956e225d672 && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f && consumed == 127 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f && consumed == 127 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4589d971e4fe8402 && consumed == 133 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x4589d971e4fe8402 && ok == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x2591544581b7dec2 && consumed == 129 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x2591544581b7dec2 && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x5a4d8ba7f519c84f && consumed == 128 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x5a4d8ba7f519c84f && consumed == 128 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x45c027e72f1f1281 && consumed == 134 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x45c027e72f1f1281 && ok == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x255bba08cf8c979d && consumed == 130 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x255bba08cf8c979d && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x5a827748f9301d32 && consumed == 129 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x5a827748f9301d32 && consumed == 129 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x45f431e0fae6d721 && consumed == 135 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x45f431e0fae6d721 && ok == true)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 101, 45, 49, 48, 48}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x25262e6d72d6dfb0 && consumed == 131 && erange == false)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x25262e6d72d6dfb0 && ok == true)
	}
	{
		s := []u8{48, 46, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 49}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x5ab7151b377c247e && consumed == 130 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x5ab7151b377c247e && consumed == 130 && erange == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 48, 0, 101, 57, 57}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x5a17a2ecc414a03f)
	}
	{
		s := []u8{49, 50, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4028000000000000 && consumed == 2 && erange == false)
	}
	{
		s := []u8{49, 50, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 50, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4028000000000000)
	}
	{
		s := []u8{32, 49, 50, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4028000000000000 && consumed == 3 && erange == false)
	}
	{
		s := []u8{32, 49, 50, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{32, 49, 50, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4028000000000000)
	}
	{
		s := []u8{49, 50, 101, 43}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4028000000000000 && consumed == 2 && erange == false)
	}
	{
		s := []u8{49, 50, 101, 43}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{49, 50, 101, 43}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4028000000000000)
	}
	{
		s := []u8{110, 97, 110, 40, 112, 97, 121, 108, 111, 97, 100, 41, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000 && consumed == 12 && erange == false)
	}
	{
		s := []u8{110, 97, 110, 40, 112, 97, 121, 108, 111, 97, 100, 41, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{110, 97, 110, 40, 112, 97, 121, 108, 111, 97, 100, 41, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x7ff8000000000000)
	}
	{
		s := []u8{48, 120, 49, 46, 56, 112, 50, 106, 117, 110, 107}
		v, consumed, erange := strtod(s)
		testing.expect(t, transmute(u64)v == 0x4018000000000000 && consumed == 7 && erange == false)
	}
	{
		s := []u8{48, 120, 49, 46, 56, 112, 50, 106, 117, 110, 107}
		v, ok := parse_score(s)
		testing.expect(t, transmute(u64)v == 0x0000000000000000 && ok == false)
	}
	{
		s := []u8{48, 120, 49, 46, 56, 112, 50, 106, 117, 110, 107}
		v := score_from_lp_string(s)
		testing.expect(t, transmute(u64)v == 0x4018000000000000)
	}
}
