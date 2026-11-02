package hyperloglog_test

import "core:testing"
import hll "../../src/hll"

@(test)
error_strings_are_wire_exact :: proc(t: ^testing.T) {
	testing.expect_value(t, hll.HLL_ERR_WRONGTYPE, "WRONGTYPE Key is not a valid HyperLogLog string value.")
	testing.expect_value(t, hll.HLL_ERR_INVALIDOBJ, "INVALIDOBJ Corrupted HLL object detected")
	testing.expect_value(t, hll.HLL_ERR_NO_KEY, "ERR The specified key does not exist")
	testing.expect_value(t, hll.HLL_ERR_NOT_SPARSE, "ERR HLL encoding is not sparse")
	testing.expect_value(t, hll.HLL_ERR_UNKNOWN_SUBCOMMAND_FMT, "ERR Unknown PFDEBUG subcommand '%s'")
	testing.expect_value(t, hll.hll_error_message(.None), "")
	testing.expect_value(t, hll.hll_error_message(.Wrong_Type), hll.HLL_ERR_WRONGTYPE)
	testing.expect_value(t, hll.hll_error_message(.Corrupted), hll.HLL_ERR_INVALIDOBJ)
	testing.expect_value(t, hll.hll_error_message(.Out_Of_Memory), hll.HLL_ERR_OOM)
}

@(test)
observed_error_replies :: proc(t: ^testing.T) {
	m: Model
	model_init(&m)
	defer model_destroy(&m)
	WT :: "-WRONGTYPE Key is not a valid HyperLogLog string value.\r\n"
	GWT :: "-WRONGTYPE Operation against a key holding the wrong kind of value\r\n"
	model_run(&m, "pfadd", "h", "a", "b", "c")
	model_run(&m, "set", "str", "notahll")
	testing.expect_value(t, model_run(&m, "pfcount", "str"), WT)
	testing.expect_value(t, model_run(&m, "pfadd", "str", "x"), WT)
	testing.expect_value(t, model_run(&m, "pfmerge", "dst", "str"), WT)
	testing.expect_value(t, model_run(&m, "exists", "dst"), ":0\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "encoding", "str"), WT)
	testing.expect_value(t, model_run(&m, "pfcount", "h", "str"), WT)
	model_run(&m, "set", "bad", "HYLL\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00")
	testing.expect_value(t, model_run(&m, "pfcount", "bad"), WT)
	model_run(&m, "set", "bad3", "HYLL\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00")
	testing.expect_value(t, model_run(&m, "pfcount", "bad3"), WT)
	model_run(&m, "set", "bad4", "HYLL\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xff")
	testing.expect_value(t, model_run(&m, "pfcount", "bad4"), ":0\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "decode", "bad4"), "$6\r\nv:32,4\r\n")
	testing.expect_value(t, model_run(&m, "pfcount", "bad4", "bad4"), "-INVALIDOBJ Corrupted HLL object detected\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "getreg", "bad4"), "-INVALIDOBJ Corrupted HLL object detected\r\n")
	model_run(&m, "lpush", "lst", "x")
	testing.expect_value(t, model_run(&m, "pfcount", "lst"), GWT)
	testing.expect_value(t, model_run(&m, "pfadd", "lst", "x"), GWT)
	testing.expect_value(t, model_run(&m, "pfmerge", "lst"), GWT)
	testing.expect_value(t, model_run(&m, "pfdebug", "encoding", "lst"), GWT)
	testing.expect_value(t, model_run(&m, "pfadd", "new"), ":1\r\n")
	testing.expect_value(t, model_run(&m, "get", "new"), "$18\r\nHYLL\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x7f\xff\r\n")
	testing.expect_value(t, model_run(&m, "pfmerge", "newm"), "+OK\r\n")
	testing.expect_value(t, model_run(&m, "get", "newm"), "$18\r\nHYLL\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x7f\xff\r\n")
	testing.expect_value(t, model_run(&m, "exists", "new"), ":1\r\n")
	testing.expect_value(t, model_run(&m, "pfcount", "new"), ":0\r\n")
	testing.expect_value(t, model_run(&m, "get", "new"), "$18\r\nHYLL\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x7f\xff\r\n")
	testing.expect_value(t, model_run(&m, "pfadd", "new"), ":0\r\n")
	testing.expect_value(t, model_run(&m, "pfcount", "nokey"), ":0\r\n")
	testing.expect_value(t, model_run(&m, "pfcount"), "-ERR wrong number of arguments for 'pfcount' command\r\n")
	testing.expect_value(t, model_run(&m, "pfadd"), "-ERR wrong number of arguments for 'pfadd' command\r\n")
	testing.expect_value(t, model_run(&m, "pfmerge"), "-ERR wrong number of arguments for 'pfmerge' command\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug"), "-ERR wrong number of arguments for 'pfdebug' command\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "getreg"), "-ERR wrong number of arguments for 'pfdebug' command\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "encoding", "h", "extra"), "-ERR wrong number of arguments for 'pfdebug' command\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "WHAT", "h"), "-ERR Unknown PFDEBUG subcommand 'WHAT'\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "WHAT", "nokey"), "-ERR The specified key does not exist\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "todense", "nokey"), "-ERR The specified key does not exist\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "ToDense", "h"), ":1\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "todense", "h"), ":0\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "decode", "h"), "-ERR HLL encoding is not sparse\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "Encoding", "h"), "+dense\r\n")
	testing.expect_value(t, model_run(&m, "strlen", "h"), ":12304\r\n")
	testing.expect_value(t, model_run(&m, "pfcount", "h"), ":3\r\n")
	testing.expect_value(t, model_run(&m, "pfselftest"), "+OK\r\n")
	testing.expect_value(t, model_run(&m, "pfselftest", "x"), "-ERR wrong number of arguments for 'pfselftest' command\r\n")
	model_run(&m, "pfadd", "s", "a")
	model_run(&m, "append", "s", "xyz")
	testing.expect_value(t, model_run(&m, "pfcount", "s"), "-INVALIDOBJ Corrupted HLL object detected\r\n")
	testing.expect_value(t, model_run(&m, "pfdebug", "decode", "s"), "$36\r\nZ:12711 v:2,1 Z:3672 Z:14458 Z:14849\r\n")
}

@(test)
observed_dirty_and_events :: proc(t: ^testing.T) {
	m: Model
	model_init(&m)
	defer model_destroy(&m)
	Step :: struct {
		args:   []string,
		reply:  string,
		dirty:  i64,
		events: int,
		aof:    int,
	}
	steps := [?]Step {
		{{"pfadd", "e", "x"}, ":1\r\n", 2, 1, 0},
		{{"pfadd", "e", "x"}, ":0\r\n", 0, 0, 0},
		{{"pfadd", "e"}, ":0\r\n", 0, 0, 0},
		{{"pfcount", "e"}, ":1\r\n", 1, 0, 1},
		{{"pfcount", "e"}, ":1\r\n", 0, 0, 0},
		{{"pfadd", "e", "y"}, ":1\r\n", 1, 1, 0},
		{{"pfcount", "e", "e"}, ":2\r\n", 0, 0, 0},
		{{"pfcount", "e"}, ":2\r\n", 1, 0, 1},
		{{"pfmerge", "e2", "e"}, "+OK\r\n", 1, 1, 0},
		{{"pfmerge", "e2", "e"}, "+OK\r\n", 1, 1, 0},
		{{"pfmerge", "e3"}, "+OK\r\n", 1, 1, 0},
		{{"pfdebug", "todense", "e"}, ":1\r\n", 1, 0, 0},
		{{"pfdebug", "todense", "e"}, ":0\r\n", 0, 0, 0},
		{{"pfdebug", "getreg", "e2"}, "", 1, 0, 0},
		{{"pfcount", "e2"}, ":2\r\n", 1, 0, 1},
		{{"pfselftest"}, "+OK\r\n", 0, 0, 0},
		{{"pfadd", "fresh"}, ":1\r\n", 1, 1, 0},
		{{"pfcount", "fresh"}, ":0\r\n", 1, 0, 1},
		{{"pfcount", "fresh"}, ":0\r\n", 0, 0, 0},
		{{"pfcount", "nokey"}, ":0\r\n", 0, 0, 0},
		{{"pfcount", "fresh", "e"}, ":2\r\n", 0, 0, 0},
		{{"pfadd", "many", "a", "b", "c", "d", "e"}, ":1\r\n", 6, 1, 0},
		{{"pfadd", "many", "f", "g", "h"}, ":1\r\n", 3, 1, 0},
		{{"pfadd", "many", "a", "b"}, ":0\r\n", 0, 0, 0},
		{{"pfadd", "many", "x", "x", "x"}, ":1\r\n", 1, 1, 0},
		{{"pfadd", "twice", "a", "a"}, ":1\r\n", 2, 1, 0},
		{{"pfcount", "many"}, ":9\r\n", 1, 0, 1},
	}
	for step in steps {
		before := m.dirty
		events_before := len(m.events)
		aof_before := m.aof_records
		reply := model_run(&m, ..step.args)
		if step.reply != "" {
			testing.expectf(t, reply == step.reply, "%v: reply %q want %q", step.args, reply, step.reply)
		}
		testing.expectf(t, m.dirty - before == step.dirty, "%v: dirty +%d want +%d", step.args, m.dirty - before, step.dirty)
		testing.expectf(t, len(m.events) - events_before == step.events, "%v: %d events want %d", step.args, len(m.events) - events_before, step.events)
		testing.expectf(t, m.aof_records - aof_before == step.aof, "%v: %d PFCOUNT records want %d", step.args, m.aof_records - aof_before, step.aof)
	}
	for ev in m.events {
		testing.expect_value(t, ev.event, "pfadd")
	}
	collide := [?][]string{{"pfadd", "z", "a"}, {"pfadd", "z", "a", "a"}, {"pfadd", "z", "b", "a"}, {"pfadd", "z", "a", "b"}}
	want := [?]string{":1\r\n", ":0\r\n", ":1\r\n", ":0\r\n"}
	for args, i in collide {
		testing.expect_value(t, model_run(&m, ..args), want[i])
	}
}

@(test)
observed_replies_sequence :: proc(t: ^testing.T) {
	m: Model
	model_init(&m)
	defer model_destroy(&m)
	testing.expect_value(t, model_run(&m, "pfadd", "r", "a", "b", "c"), ":1\r\n")
	testing.expect_value(t, model_run(&m, "pfadd", "r", ""), ":1\r\n")
	testing.expect_value(t, model_run(&m, "pfadd", "r", "a", "a", "a"), ":0\r\n")
	got := model_run(&m, "get", "r")
	want := hex_decode("48594c4c01000000000000000000008057318449c08050b1844bfb80425a")
	defer delete(want)
	testing.expect_value(t, got[len("$30\r\n"):len(got) - 2], string(want))
	testing.expect_value(t, model_run(&m, "pfcount", "r"), ":4\r\n")
	model_run(&m, "pfadd", "h5", "1", "2", "3", "4", "5")
	testing.expect_value(t, model_run(&m, "pfcount", "h5"), ":5\r\n")
	model_run(&m, "pfadd", "h5", "6", "7", "8", "8", "9", "10")
	testing.expect_value(t, model_run(&m, "pfcount", "h5"), ":10\r\n")
	got = model_run(&m, "get", "h5")
	want10 := hex_decode("48594c4c010000000a0000000000000041ee844823805351804ce0804092804c3f8042d78042128c40b88015844322")
	defer delete(want10)
	testing.expect_value(t, got[len("$47\r\n"):len(got) - 2], string(want10))
}
