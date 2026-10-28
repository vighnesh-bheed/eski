package aofwork

import "core:strings"
import "core:sys/linux"
import "core:testing"
import j "../../src"

Record :: struct {
	args: [dynamic]string,
}

decode_records :: proc(data: []u8) -> (out: [dynamic][]string, ok: bool) {
	out.allocator = context.temp_allocator
	i := 0
	for i < len(data) {
		if data[i] == '#' {
			for i < len(data) && data[i] != '\n' {
				i += 1
			}
			i += 1
			continue
		}
		if data[i] != '*' {
			return out, false
		}
		e := i
		for e < len(data) && data[e] != '\r' {
			e += 1
		}
		n, nok := j.parse_i64(data[i + 1:e])
		if !nok || e + 1 >= len(data) {
			return out, false
		}
		i = e + 2
		args := make([]string, int(n), context.temp_allocator)
		for k in 0 ..< int(n) {
			if i >= len(data) || data[i] != '$' {
				return out, false
			}
			e = i
			for e < len(data) && data[e] != '\r' {
				e += 1
			}
			l, lok := j.parse_i64(data[i + 1:e])
			if !lok {
				return out, false
			}
			i = e + 2
			if i + int(l) + 2 > len(data) {
				return out, false
			}
			args[k] = strings.clone(string(data[i:i + int(l)]), context.temp_allocator)
			i += int(l) + 2
		}
		append(&out, args)
	}
	return out, true
}

joined :: proc(rec: []string) -> string {
	return strings.join(rec, " ", context.temp_allocator)
}

token_matches :: proc(want: string, got: string) -> bool {
	switch want {
	case "<n>":
		if len(got) == 0 {
			return false
		}
		for ch, i in got {
			if !(ch >= '0' && ch <= '9') && !(i == 0 && ch == '-') {
				return false
			}
		}
		return true
	case "<id>":
		dash := strings.index_byte(got, '-')
		return dash > 0 && dash < len(got) - 1
	case "<any>":
		return true
	}
	return want == got
}

record_matches :: proc(want: string, got: []string) -> bool {
	parts := strings.split(want, " ", context.temp_allocator)
	if len(parts) != len(got) {
		return false
	}
	for p, i in parts {
		if !token_matches(p, got[i]) {
			return false
		}
	}
	return true
}

feed_path: string

feed_on :: proc(name: string) -> string {
	dir := fresh_dir(name)
	path := path_join({dir, "feed.aof"})
	fd, err := linux.open(cstr(path), {.WRONLY, .CREAT, .TRUNC, .APPEND, .CLOEXEC}, {.IRUSR, .IWUSR})
	if err != .NONE {
		return ""
	}
	j.aof.fd = fd
	j.aof.state = .On
	j.aof.loading = false
	j.aof.selected_db = -1
	j.aof.in_cmd = false
	j.aof.in_tx = false
	clear(&j.aof.buf)
	clear(&j.aof.stage)
	j.aof.stage_count = 0
	j.aof_update_feed()
	feed_path = path
	return path
}

feed_off :: proc() {
	if j.aof.fd >= 0 {
		linux.close(j.aof.fd)
	}
	j.aof.fd = -1
	j.aof.state = .Off
	clear(&j.aof.buf)
	j.aof_update_feed()
}

take_records :: proc(t: ^testing.T) -> [dynamic][]string {
	recs, ok := decode_records(j.aof.buf[:])
	testing.expect(t, ok, "feed buffer is valid RESP")
	clear(&j.aof.buf)
	return recs
}

expect_records :: proc(t: ^testing.T, want: []string, loc := #caller_location) {
	recs := take_records(t)
	if len(recs) != len(want) {
		got := make([dynamic]string, context.temp_allocator)
		for r in recs {
			append(&got, joined(r))
		}
		testing.expectf(t, false, "want %d records %v, got %d: %v", len(want), want, len(recs), got[:], loc = loc)
		return
	}
	for w, i in want {
		testing.expectf(t, record_matches(w, recs[i]), "record %d: want %q got %q", i, w, joined(recs[i]), loc = loc)
	}
}

key_expire :: proc(db: int, key: string) -> i64 {
	exists, at, _ := j.aof_key_state(&j.dbs[db], transmute([]u8)key)
	if !exists {
		return -1
	}
	return at
}

flush_all :: proc() {
	j.db_flush_all()
	clear(&j.aof.buf)
}

sleep_ms :: proc(ms: int) {
	ts := linux.Time_Spec {
		time_sec  = uint(ms / 1000),
		time_nsec = uint((ms % 1000) * 1_000_000),
	}
	linux.nanosleep(&ts, nil)
	j.update_clock()
}
