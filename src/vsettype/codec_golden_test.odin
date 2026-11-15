package vsettype

import "core:fmt"
import "core:os"
import "core:testing"
import lbl "../label"

GOLDEN_DIR :: "test/vectorset/fixtures/"

golden_read :: proc(t: ^testing.T, file: string) -> []u8 {
	data, err := os.read_entire_file(fmt.tprintf("%s%s", GOLDEN_DIR, file), context.allocator)
	testing.expectf(t, err == nil, "the fixture %s is read from the repository root, got %v", file, err)
	return data
}

Golden :: struct {
	name:  string,
	file:  string,
	mode:  u8,
	width: int,
}

GOLDEN_CORE := [?]Golden {
	{"graph q8", "v2-graph-q8.bin", 0, 2},
	{"graph bin", "v2-graph-bin.bin", 0, 2},
	{"graph reduce", "v2-graph-reduce.bin", 0, 2},
	{"graph padded", "v2-graph-padded.bin", 0, 2},
	{"view flat", "v2-view-flat.bin", 1, 2},
}

Golden_Part :: struct {
	label: lbl.Id,
	owner: Owner,
	file:  string,
}

GOLDEN_PARTS := [?]Golden_Part {
	{0, 0, "v2-part-0-0.bin"},
	{0, 3, "v2-part-0-3.bin"},
	{0, 5, "v2-part-0-5.bin"},
	{1, 0, "v2-part-1-0.bin"},
	{1, 3, "v2-part-1-3.bin"},
	{1, 5, "v2-part-1-5.bin"},
	{2, 0, "v2-part-2-0.bin"},
	{2, 3, "v2-part-2-3.bin"},
	{2, 5, "v2-part-2-5.bin"},
	{3, 0, "v2-part-3-0.bin"},
	{3, 3, "v2-part-3-3.bin"},
	{3, 5, "v2-part-3-5.bin"},
	{4, 0, "v2-part-4-0.bin"},
	{4, 3, "v2-part-4-3.bin"},
	{4, 5, "v2-part-4-5.bin"},
}

GOLDEN_V1 := [?]string {
	"v1-dump-q8.bin",
	"v1-dump-fp32.bin",
	"v1-dump-bin.bin",
	"v1-dump-reduce.bin",
}

dump_len :: proc(b: []u8, at: ^int) -> u64 {
	x := b[at^]
	switch x >> 6 {
	case 0:
		at^ += 1
		return u64(x & 0x3F)
	case 1:
		v := u64(x & 0x3F) << 8 | u64(b[at^ + 1])
		at^ += 2
		return v
	}
	n := 4 if x == 0x80 else 8
	v: u64
	for i in 0 ..< n {
		v = v << 8 | u64(b[at^ + 1 + i])
	}
	at^ += 1 + n
	return v
}

dump_module_payload :: proc(b: []u8) -> (id: u64, payload: []u8) {
	at := 1
	id = dump_len(b, &at)
	dump_len(b, &at)
	n := int(dump_len(b, &at))
	return id, b[at:][:n]
}

@(test)
golden_payloads_keep_their_bytes :: proc(t: ^testing.T) {
	sc: Scratch
	scratch_init(&sc)
	defer scratch_destroy(&sc)
	golden := GOLDEN_CORE
	for &g in golden {
		data := golden_read(t, g.file)
		defer delete(data)
		if len(data) < 6 {
			continue
		}
		testing.expectf(t, string(data[:4]) == "EVS\x02", "%s: version 2 signature", g.name)
		c := craft_parse(data)
		testing.expectf(t, c.mode == g.mode && c.width == g.width, "%s: mode %d width %d", g.name, c.mode, c.width)
		craft_destroy(&c)
		s, err := deserialize(data, &sc, 0x60D)
		if !testing.expectf(t, err == .None, "%s: decoding the fixture gave %v", g.name, err) {
			continue
		}
		testing.expect(t, check_invariants(t, s))
		if g.mode == 0 {
			again := g_bytes(s)
			testing.expectf(t, string(again) == string(data), "%s: the fixture no longer encodes to its own bytes", g.name)
			delete(again)
		}
		destroy(s)
	}
	w: Scoped_World
	world_init(&w)
	defer world_destroy(&w)
	parts := make([dynamic]Saved_Part)
	for p in GOLDEN_PARTS {
		append(&parts, Saved_Part{scope = Scope{label = p.label, owner = p.owner}, data = golden_read(t, p.file)})
	}
	defer {
		for p in parts {
			delete(p.data)
		}
		delete(parts)
	}
	s, err := load_parts(t, parts[:])
	if testing.expectf(t, err == .None, "the partition fixtures load, got %v", err) {
		ctx: Save_Context
		again: [dynamic]Saved_Part
		save_parts(s, &ctx, &again)
		save_context_destroy(&ctx)
		testing.expect_value(t, len(again), len(parts))
		for p in again {
			for q in parts {
				if q.scope == p.scope {
					testing.expectf(t, string(p.data) == string(q.data), "partition %v no longer encodes to its fixture", p.scope)
				}
			}
		}
		saved_destroy(&again)
		flat, graph := world_modes(s)
		testing.expect(t, flat > 0 && graph > 0)
		destroy(s)
	}
	v1 := GOLDEN_V1
	for file in v1 {
		dump := golden_read(t, file)
		defer delete(dump)
		if len(dump) < 20 {
			continue
		}
		id, payload := dump_module_payload(dump)
		testing.expect_value(t, id, u64(0x7ac922fafb1eb401))
		testing.expect_value(t, payload[3], CODEC_VERSION_V1)
		back, derr := deserialize(payload, &sc, 0x60D)
		if !testing.expectf(t, derr == .None, "a version 1 fixture decodes, got %v", derr) {
			continue
		}
		testing.expect(t, check_invariants(t, back))
		again, _ := serialize_v1_bytes(back)
		testing.expect(t, string(again) == string(payload), "a version 1 fixture keeps every element, sequence and attribute")
		delete(again)
		destroy(back)
	}
	free_all(context.temp_allocator)
}
