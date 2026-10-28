package hashtype

import "core:testing"

@(test)
expiry_observed_malformed_argument_errors :: proc(t: ^testing.T) {
	Case :: struct {
		args: []string,
		expiry: bool,
		seconds: bool,
		relative: bool,
		error: Error,
	}
	cases := []Case{
		{[]string{"HEXPIRE", "missing", "bad", "FIELDS", "1", "a"}, true, true, true, .Value_Not_Integer},
		{[]string{"HEXPIRE", "missing", "-1", "FIELDS", "1", "a"}, true, true, true, .Invalid_Expire_Negative},
		{[]string{"HEXPIRE", "missing", "999999999999999999", "FIELDS", "1", "a"}, true, true, true, .Invalid_Expire_Time},
		{[]string{"HEXPIRE", "missing", "10", "WHATEVER", "1", "a"}, true, true, true, .Fields_Missing},
		{[]string{"HEXPIRE", "missing", "10", "NX", "XX", "1", "a"}, true, true, true, .Fields_Missing},
		{[]string{"HEXPIRE", "missing", "10", "FIELDS", "0", "a"}, true, true, true, .Numfields_Expire},
		{[]string{"HEXPIRE", "missing", "10", "FIELDS", "-1", "a"}, true, true, true, .Numfields_Expire},
		{[]string{"HEXPIRE", "missing", "10", "FIELDS", "bad", "a"}, true, true, true, .Numfields_Expire},
		{[]string{"HEXPIRE", "missing", "10", "FIELDS", "2", "a"}, true, true, true, .Numfields_Mismatch},
		{[]string{"HEXPIRE", "missing", "10", "NX", "FIELDS", "1"}, true, true, true, .Numfields_Mismatch},
		{[]string{"HEXPIRE", "missing", "10", "NX", "FIELDS", "bad", "a"}, true, true, true, .Numfields_Expire},
		{[]string{"HEXPIRE", "missing", "10", "NX", "FIELDS", "0", "a"}, true, true, true, .Numfields_Expire},
		{[]string{"HEXPIRE", "missing", "10", "NX", "FIELDS", "1", "a", "extra"}, true, true, true, .Numfields_Mismatch},
		{[]string{"HPEXPIRE", "missing", "bad", "FIELDS", "1", "a"}, true, false, true, .Value_Not_Integer},
		{[]string{"HPEXPIRE", "missing", "-1", "FIELDS", "1", "a"}, true, false, true, .Invalid_Expire_Negative},
		{[]string{"HPEXPIRE", "missing", "999999999999999999", "FIELDS", "1", "a"}, true, false, true, .Invalid_Expire_Time},
		{[]string{"HPEXPIRE", "missing", "10", "WHATEVER", "1", "a"}, true, false, true, .Fields_Missing},
		{[]string{"HPEXPIRE", "missing", "10", "NX", "XX", "1", "a"}, true, false, true, .Fields_Missing},
		{[]string{"HPEXPIRE", "missing", "10", "FIELDS", "0", "a"}, true, false, true, .Numfields_Expire},
		{[]string{"HPEXPIRE", "missing", "10", "FIELDS", "-1", "a"}, true, false, true, .Numfields_Expire},
		{[]string{"HPEXPIRE", "missing", "10", "FIELDS", "bad", "a"}, true, false, true, .Numfields_Expire},
		{[]string{"HPEXPIRE", "missing", "10", "FIELDS", "2", "a"}, true, false, true, .Numfields_Mismatch},
		{[]string{"HPEXPIRE", "missing", "10", "NX", "FIELDS", "1"}, true, false, true, .Numfields_Mismatch},
		{[]string{"HPEXPIRE", "missing", "10", "NX", "FIELDS", "bad", "a"}, true, false, true, .Numfields_Expire},
		{[]string{"HPEXPIRE", "missing", "10", "NX", "FIELDS", "0", "a"}, true, false, true, .Numfields_Expire},
		{[]string{"HPEXPIRE", "missing", "10", "NX", "FIELDS", "1", "a", "extra"}, true, false, true, .Numfields_Mismatch},
		{[]string{"HEXPIREAT", "missing", "bad", "FIELDS", "1", "a"}, true, true, false, .Value_Not_Integer},
		{[]string{"HEXPIREAT", "missing", "-1", "FIELDS", "1", "a"}, true, true, false, .Invalid_Expire_Negative},
		{[]string{"HEXPIREAT", "missing", "999999999999999999", "FIELDS", "1", "a"}, true, true, false, .Invalid_Expire_Time},
		{[]string{"HEXPIREAT", "missing", "10", "WHATEVER", "1", "a"}, true, true, false, .Fields_Missing},
		{[]string{"HEXPIREAT", "missing", "10", "NX", "XX", "1", "a"}, true, true, false, .Fields_Missing},
		{[]string{"HEXPIREAT", "missing", "10", "FIELDS", "0", "a"}, true, true, false, .Numfields_Expire},
		{[]string{"HEXPIREAT", "missing", "10", "FIELDS", "-1", "a"}, true, true, false, .Numfields_Expire},
		{[]string{"HEXPIREAT", "missing", "10", "FIELDS", "bad", "a"}, true, true, false, .Numfields_Expire},
		{[]string{"HEXPIREAT", "missing", "10", "FIELDS", "2", "a"}, true, true, false, .Numfields_Mismatch},
		{[]string{"HEXPIREAT", "missing", "10", "NX", "FIELDS", "1"}, true, true, false, .Numfields_Mismatch},
		{[]string{"HEXPIREAT", "missing", "10", "NX", "FIELDS", "bad", "a"}, true, true, false, .Numfields_Expire},
		{[]string{"HEXPIREAT", "missing", "10", "NX", "FIELDS", "0", "a"}, true, true, false, .Numfields_Expire},
		{[]string{"HEXPIREAT", "missing", "10", "NX", "FIELDS", "1", "a", "extra"}, true, true, false, .Numfields_Mismatch},
		{[]string{"HPEXPIREAT", "missing", "bad", "FIELDS", "1", "a"}, true, false, false, .Value_Not_Integer},
		{[]string{"HPEXPIREAT", "missing", "-1", "FIELDS", "1", "a"}, true, false, false, .Invalid_Expire_Negative},
		{[]string{"HPEXPIREAT", "missing", "999999999999999999", "FIELDS", "1", "a"}, true, false, false, .Invalid_Expire_Time},
		{[]string{"HPEXPIREAT", "missing", "10", "WHATEVER", "1", "a"}, true, false, false, .Fields_Missing},
		{[]string{"HPEXPIREAT", "missing", "10", "NX", "XX", "1", "a"}, true, false, false, .Fields_Missing},
		{[]string{"HPEXPIREAT", "missing", "10", "FIELDS", "0", "a"}, true, false, false, .Numfields_Expire},
		{[]string{"HPEXPIREAT", "missing", "10", "FIELDS", "-1", "a"}, true, false, false, .Numfields_Expire},
		{[]string{"HPEXPIREAT", "missing", "10", "FIELDS", "bad", "a"}, true, false, false, .Numfields_Expire},
		{[]string{"HPEXPIREAT", "missing", "10", "FIELDS", "2", "a"}, true, false, false, .Numfields_Mismatch},
		{[]string{"HPEXPIREAT", "missing", "10", "NX", "FIELDS", "1"}, true, false, false, .Numfields_Mismatch},
		{[]string{"HPEXPIREAT", "missing", "10", "NX", "FIELDS", "bad", "a"}, true, false, false, .Numfields_Expire},
		{[]string{"HPEXPIREAT", "missing", "10", "NX", "FIELDS", "0", "a"}, true, false, false, .Numfields_Expire},
		{[]string{"HPEXPIREAT", "missing", "10", "NX", "FIELDS", "1", "a", "extra"}, true, false, false, .Numfields_Mismatch},
		{[]string{"HTTL", "missing", "FIELDS", "0", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HTTL", "missing", "FIELDS", "-1", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HTTL", "missing", "FIELDS", "bad", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HTTL", "missing", "FIELDS", "2", "a"}, false, false, false, .Numfields_Mismatch},
		{[]string{"HTTL", "missing", "bad", "1", "a"}, false, false, false, .Fields_Missing},
		{[]string{"HTTL", "missing", "FIELDS", "1", "a", "extra"}, false, false, false, .Numfields_Mismatch},
		{[]string{"HPTTL", "missing", "FIELDS", "0", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HPTTL", "missing", "FIELDS", "-1", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HPTTL", "missing", "FIELDS", "bad", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HPTTL", "missing", "FIELDS", "2", "a"}, false, false, false, .Numfields_Mismatch},
		{[]string{"HPTTL", "missing", "bad", "1", "a"}, false, false, false, .Fields_Missing},
		{[]string{"HPTTL", "missing", "FIELDS", "1", "a", "extra"}, false, false, false, .Numfields_Mismatch},
		{[]string{"HEXPIRETIME", "missing", "FIELDS", "0", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HEXPIRETIME", "missing", "FIELDS", "-1", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HEXPIRETIME", "missing", "FIELDS", "bad", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HEXPIRETIME", "missing", "FIELDS", "2", "a"}, false, false, false, .Numfields_Mismatch},
		{[]string{"HEXPIRETIME", "missing", "bad", "1", "a"}, false, false, false, .Fields_Missing},
		{[]string{"HEXPIRETIME", "missing", "FIELDS", "1", "a", "extra"}, false, false, false, .Numfields_Mismatch},
		{[]string{"HPEXPIRETIME", "missing", "FIELDS", "0", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HPEXPIRETIME", "missing", "FIELDS", "-1", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HPEXPIRETIME", "missing", "FIELDS", "bad", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HPEXPIRETIME", "missing", "FIELDS", "2", "a"}, false, false, false, .Numfields_Mismatch},
		{[]string{"HPEXPIRETIME", "missing", "bad", "1", "a"}, false, false, false, .Fields_Missing},
		{[]string{"HPEXPIRETIME", "missing", "FIELDS", "1", "a", "extra"}, false, false, false, .Numfields_Mismatch},
		{[]string{"HPERSIST", "missing", "FIELDS", "0", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HPERSIST", "missing", "FIELDS", "-1", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HPERSIST", "missing", "FIELDS", "bad", "a"}, false, false, false, .Numfields_Positive},
		{[]string{"HPERSIST", "missing", "FIELDS", "2", "a"}, false, false, false, .Numfields_Mismatch},
		{[]string{"HPERSIST", "missing", "bad", "1", "a"}, false, false, false, .Fields_Missing},
		{[]string{"HPERSIST", "missing", "FIELDS", "1", "a", "extra"}, false, false, false, .Numfields_Mismatch},
	}
	for item in cases {
		argv := make([][]u8, len(item.args))
		for value, i in item.args {
			argv[i] = ordinary_bytes(value)
		}
		err: Error
		if item.expiry {
			base := u64(0)
			if item.relative {
				base = 1000
			}
			_, err = parse_expire_args(argv, item.seconds, base)
		} else {
			_, err = parse_fields_args(argv)
		}
		testing.expect_value(t, err, item.error)
		delete(argv)
	}
}
