package aofwork

import "base:runtime"
import "core:testing"

@(test)
float_increment_retained_field_deadline_is_journaled_atomically :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	env_init(t)
	flush_all()
	feed_on("float-field-deadline")
	defer feed_off()
	c := new_client(0)
	limits := [2]string{"512", "0"}
	for limit in limits {
		run(c, "DEL", "float-expiring")
		run(c, "CONFIG", "SET", "hash-max-listpack-entries", limit)
		run(c, "HSET", "float-expiring", "field", "1")
		run(c, "HPEXPIREAT", "float-expiring", "1893456000000", "FIELDS", "1", "field")
		take_records(t)
		testing.expect_value(t, run(c, "HINCRBYFLOAT", "float-expiring", "field", ".5"), "$3\r\n1.5\r\n")
		expect_records(t, {"MULTI", "HSET float-expiring field 1.5", "HPEXPIREAT float-expiring 1893456000000 FIELDS 1 field", "EXEC"})
		testing.expect_value(t, run(c, "HPEXPIRETIME", "float-expiring", "FIELDS", "1", "field"), "*1\r\n:1893456000000\r\n")
	}
}
