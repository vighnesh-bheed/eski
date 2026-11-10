package main

import "base:runtime"
import "core:crypto/ed25519"
import "core:strings"
import "core:testing"
import lb "label"
import ow "owner"

@(private = "file")
Access_Fixture :: struct {
	c:    Conn,
	user: Acl_User,
	peer: Acl_User,
}

@(private = "file")
fixture_open :: proc(t: ^testing.T, f: ^Access_Fixture) {
	access_init()
	lb.config_destroy(&label_scheme)
	lb.table_destroy(&label_table)
	lb.config_init(&label_scheme)
	for name in ([]string{"U", "C", "S", "TOP SECRET"}) {
		testing.expect_value(t, lb.config_add_level(&label_scheme, name), lb.Config_Error.None)
	}
	for name in ([]string{"A", "B"}) {
		testing.expect_value(t, lb.config_add_compartment(&label_scheme, name), lb.Config_Error.None)
	}
	for name in ([]string{"WEB", "VETTED"}) {
		testing.expect_value(t, lb.config_add_trust(&label_scheme, name), lb.Config_Error.None)
	}
	lb.table_init(&label_table)
	access_scheme_changed()
	labels_on = true
	label_scheme_runtime = true
	access = {}
	f.user.username = transmute([]u8)string("app")
	f.peer.username = transmute([]u8)string("peer")
	acl_label_rule(&f.user.labels, transmute([]u8)string("clearance:S//A"))
	acl_label_rule(&f.user.labels, transmute([]u8)string("trust:VETTED"))
	acl_label_rule(&f.peer.labels, transmute([]u8)string("clearance:*"))
	f.c = Conn{fd = -1, resp = 2, wcap = 1 << 16, user = &f.user}
	f.c.wbuf = cast([^]u8)runtime.heap_alloc(f.c.wcap)
}

@(private = "file")
fixture_close :: proc(f: ^Access_Fixture) {
	for len(label_contexts) > 0 {
		label_contexts_drop_login(label_contexts[0].login)
	}
	label_token_cache_clear()
	acl_label_rules_free(&f.user.labels)
	acl_label_rules_free(&f.peer.labels)
	access_conn_closed(&f.c)
	runtime.heap_free(f.c.wbuf)
	access = {}
	labels_on = false
	lb.config_destroy(&label_scheme)
	lb.table_destroy(&label_table)
	lb.config_default(&label_scheme)
	lb.table_init(&label_table)
	access_scheme_changed()
}

@(private = "file")
fixture_reply :: proc(f: ^Access_Fixture) -> string {
	out := strings.clone(string(f.c.wbuf[:f.c.wlen]), context.temp_allocator)
	f.c.wlen = 0
	f.c.wpos = 0
	return out
}

@(private = "file")
words :: proc(args: ..string) -> [][]u8 {
	out := make([][]u8, len(args), context.temp_allocator)
	for a, i in args {
		out[i] = transmute([]u8)a
	}
	return out
}

@(private = "file")
marking :: proc(t: ^testing.T, text: string) -> lb.Label {
	l, f := lb.parse(&label_scheme, text)
	testing.expectf(t, f.error == .None, "%s: %v", text, f.error)
	return l
}

@(test)
access_visibility_cache_is_keyed_by_reader_and_follows_table_growth :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Access_Fixture
	fixture_open(t, &f)
	defer fixture_close(&f)
	reader, _ := access_intern(marking(t, "S//A"))
	low, _ := access_intern(marking(t, "C"))
	vis := access_visibility(reader)
	testing.expect(t, lb.visible(vis, low) && lb.visible(vis, reader) && lb.visible(vis, lb.BOTTOM_ID))
	high, _ := access_intern(marking(t, "S//A/B"))
	trusted, _ := access_intern(marking(t, "C;VETTED"))
	same := access_visibility(reader)
	testing.expect(t, same == vis)
	testing.expect(t, !lb.visible(vis, high) && lb.visible(vis, trusted))
	vetted_reader, _ := access_intern(marking(t, "S//A;VETTED"))
	vv := access_visibility(vetted_reader)
	testing.expect(t, !lb.visible(vv, low) && lb.visible(vv, trusted) && !lb.visible(vv, lb.BOTTOM_ID))
	access.vis = vis
	for level in 0 ..< 4 {
		for comps in 0 ..< 4 {
			for trust in 0 ..< 2 {
				l := lb.Label{level = u8(level), trust = u8(trust)}
				l.compartments[0] = u64(comps)
				id, ok := access_intern(l)
				testing.expect(t, ok)
				r := access_visibility(id)
				for other in 0 ..< lb.table_count(&label_table) {
					ol, _ := lb.table_label(&label_table, lb.Id(other))
					testing.expect_value(t, lb.visible(r, lb.Id(other)), lb.dominates(l, ol))
				}
			}
		}
	}
	testing.expect(t, access_visibility(reader) == vis)
	testing.expect(t, access_compare(high, low) > 0 && access_compare(low, trusted) < 0 && access_compare(reader, reader) == 0)
	testing.expect(t, access_dominates(reader, low) && !access_dominates(low, reader))
	b := make([dynamic]u8, context.temp_allocator)
	testing.expect(t, access_format(&b, trusted))
	testing.expect_value(t, string(b[:]), "C;VETTED")
	clear(&b)
	access_format_marking(&b, marking(t, "TOP SECRET//B;VETTED"))
	testing.expect_value(t, string(b[:]), "TOP SECRET//B")
	_, bad := access_intern(lb.Label{level = 9})
	testing.expect(t, !bad)
}

@(test)
access_ceilings_and_label_rules_round_trip :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Access_Fixture
	fixture_open(t, &f)
	defer fixture_close(&f)
	ceiling := access_ceiling(&f.user)
	testing.expect(t, ceiling == marking(t, "S//A;VETTED"))
	testing.expect(t, access_conn_session(&f.c) == marking(t, "S//A"))
	top := access_ceiling(&f.peer)
	testing.expect(t, top == marking(t, "TOP SECRET//A/B"))
	r: Acl_Label_Rules
	defer acl_label_rules_free(&r)
	key: [32]u8
	priv: ed25519.Private_Key
	seed := [32]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32}
	testing.expect(t, ed25519.private_key_set_bytes(&priv, seed[:]))
	ed25519.private_key_public_bytes(&priv, key[:])
	hex := make([dynamic]u8, context.temp_allocator)
	label_hex_encode(&hex, key[:])
	rules := []string{"clearance:TOP+SECRET//B", "trust:*", "label-per-command", "require-token", strings.concatenate({"token-key:", string(hex[:])}, context.temp_allocator)}
	for rule in rules {
		e, handled := acl_label_rule(&r, transmute([]u8)rule)
		testing.expectf(t, handled && e == .None, "%s: %v %v", rule, handled, e)
	}
	text := make([dynamic]u8, context.temp_allocator)
	acl_label_describe(&text, &r)
	testing.expect_value(t, string(text[:]), strings.concatenate({"clearance:TOP+SECRET//B trust:* label-per-command require-token token-key:", string(hex[:]), " "}, context.temp_allocator))
	back: Acl_Label_Rules
	defer acl_label_rules_free(&back)
	for rule in strings.fields(string(text[:]), context.temp_allocator) {
		e, handled := acl_label_rule(&back, transmute([]u8)rule)
		testing.expect(t, handled && e == .None)
	}
	testing.expect(t, back.clearance == r.clearance && back.trust_top && back.per_command && back.require_token && len(back.keys) == 1)
	for rule in ([]string{"clearance:NOPE", "clearance:S;VETTED", "trust:NOPE", "token-key:00", "clearance:S//A/A"}) {
		e, handled := acl_label_rule(&back, transmute([]u8)rule)
		testing.expectf(t, handled && e == .Bad_Label, "%s: %v", rule, e)
	}
	_, handled := acl_label_rule(&back, transmute([]u8)string("+get"))
	testing.expect(t, !handled)
	labels_on = false
	e, off := acl_label_rule(&back, transmute([]u8)string("trust:*"))
	testing.expect(t, off && e == .Labels_Off)
	labels_on = true
	acl_label_rules_reset(&back)
	testing.expect(t, !back.clearance_set && !back.trust_top && !back.per_command && len(back.keys) == 0)
}

@(private = "file")
signed :: proc(priv: ^ed25519.Private_Key, statement: string) -> []u8 {
	sig: [ed25519.SIGNATURE_SIZE]u8
	ed25519.sign(priv, transmute([]u8)statement, sig[:])
	b := make([dynamic]u8, context.temp_allocator)
	label_hex_encode(&b, transmute([]u8)statement)
	sb_byte(&b, '.')
	label_hex_encode(&b, sig[:])
	return b[:]
}

@(test)
access_label_as_parses_markings_contexts_and_tokens :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Access_Fixture
	fixture_open(t, &f)
	defer fixture_close(&f)
	l: lb.Label
	ctx: ^Label_Context
	used, msg := label_as_parse(&f.c, words("LABEL", "AS", "C", "TRUST", "VETTED", "GET", "k"), &l, &ctx)
	testing.expect(t, used == 5 && msg == "" && l == marking(t, "C;VETTED") && ctx == nil)
	used, msg = label_as_parse(&f.c, words("LABEL", "AS", "S//B", "GET", "k"), &l, &ctx)
	testing.expect_value(t, msg, ERR_LABEL_INVALID)
	used, msg = label_as_parse(&f.c, words("LABEL", "AS", "C;VETTED", "TRUST", "WEB", "GET", "k"), &l, &ctx)
	testing.expect_value(t, msg, ERR_LABEL_INVALID)
	_, msg = label_as_parse(&f.c, words("LABEL", "AS", "C"), &l, &ctx)
	testing.expect(t, strings.has_prefix(msg, "ERR wrong number"))
	saved_now := srv.now_ms
	defer srv.now_ms = saved_now
	srv.now_ms = 1_000_000
	access.label = marking(t, "C")
	cmd_context(&f.c, words("CONTEXT", "CREATE", "TRUST", "VETTED"))
	reply := fixture_reply(&f)
	testing.expect(t, strings.has_prefix(reply, "$32\r\n"))
	handle := reply[5:37]
	used, msg = label_as_parse(&f.c, words("LABEL", "AS", "CONTEXT", handle, "PING"), &l, &ctx)
	testing.expect(t, used == 4 && msg == "" && l == marking(t, "C;VETTED") && ctx != nil)
	used, msg = label_as_parse(&f.c, words("LABEL", "AS", "C", "TRUST", "VETTED", "CONTEXT", handle, "PING"), &l, &ctx)
	testing.expect(t, used == 7 && msg == "")
	_, msg = label_as_parse(&f.c, words("LABEL", "AS", "C", "CONTEXT", handle, "PING"), &l, &ctx)
	testing.expect_value(t, msg, ERR_LABEL_CONTEXT_MISMATCH)
	used, msg = label_as_parse(&f.c, words("LABEL", "AS", "C", "CONTEXT", "CREATE"), &l, &ctx)
	testing.expect(t, used == 3 && msg == "")
	other := f.c
	other.user = &f.peer
	_, msg = label_as_parse(&other, words("LABEL", "AS", "CONTEXT", handle, "PING"), &l, &ctx)
	testing.expect_value(t, msg, ERR_LABEL_CONTEXT)
	srv.now_ms += label_context_idle * 1000
	_, msg = label_as_parse(&f.c, words("LABEL", "AS", "CONTEXT", handle, "PING"), &l, &ctx)
	testing.expect_value(t, msg, ERR_LABEL_CONTEXT)
	testing.expect_value(t, len(label_contexts), 0)
	priv: ed25519.Private_Key
	seed: [32]u8
	seed[0] = 7
	testing.expect(t, ed25519.private_key_set_bytes(&priv, seed[:]))
	key: [32]u8
	ed25519.private_key_public_bytes(&priv, key[:])
	append(&f.user.labels.keys, key)
	saved_audience := label_token_audience
	defer label_token_audience = saved_audience
	label_token_audience = "node"
	good := signed(&priv, "eski-label-token 1\nmarking S//A\ntrust VETTED\nexpires 9999999999999\naudience node")
	used, msg = label_as_parse(&f.c, words("LABEL", "AS", "TOKEN", string(good), "PING"), &l, &ctx)
	testing.expect(t, used == 4 && msg == "" && l == marking(t, "S//A;VETTED"))
	used, msg = label_as_parse(&f.c, words("LABEL", "AS", "TOKEN", string(good), "PING"), &l, &ctx)
	testing.expect(t, used == 4 && msg == "")
	bad := []string {
		"eski-label-token 1\nmarking S//A\nexpires 9999999999999\naudience elsewhere",
		"eski-label-token 1\nmarking S//A\nexpires 1\naudience node",
		"eski-label-token 1\nmarking S//B\nexpires 9999999999999\naudience node",
		"eski-label-token 1\nmarking S//A\nexpires 9999999999999\naudience node\nowner 3",
		"eski-label-token 2\nmarking S//A\nexpires 9999999999999\naudience node",
		"eski-label-token 1\nmarking S//A\nmarking C\nexpires 9999999999999\naudience node",
		"eski-label-token 1\nmarking S//A\naudience node",
	}
	for statement in bad {
		_, msg = label_as_parse(&f.c, words("LABEL", "AS", "TOKEN", string(signed(&priv, statement)), "PING"), &l, &ctx)
		testing.expectf(t, msg == ERR_LABEL_TOKEN, "%q: %s", statement, msg)
	}
	forged := strings.clone(string(good), context.temp_allocator)
	tampered := transmute([]u8)forged
	tampered[len(tampered) - 1] = '0' if tampered[len(tampered) - 1] != '0' else '1'
	_, msg = label_as_parse(&f.c, words("LABEL", "AS", "TOKEN", forged, "PING"), &l, &ctx)
	testing.expect_value(t, msg, ERR_LABEL_TOKEN)
	_, msg = label_as_parse(&other, words("LABEL", "AS", "TOKEN", string(good), "PING"), &l, &ctx)
	testing.expect_value(t, msg, ERR_LABEL_TOKEN)
	f.user.labels.require_token = true
	_, msg = label_as_parse(&f.c, words("LABEL", "AS", "C", "PING"), &l, &ctx)
	testing.expect_value(t, msg, ERR_LABEL_TOKEN_ONLY)
}

@(test)
access_info_redaction_keeps_shape_and_hides_counters :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Access_Fixture
	fixture_open(t, &f)
	defer fixture_close(&f)
	access.label = marking(t, "C")
	b := make([dynamic]u8, context.temp_allocator)
	sb_str(&b, "# Server\r\nredis_version:7.4.11\r\nuptime_in_seconds:12\r\n\r\n# Clients\r\nconnected_clients:9\r\nmaxclients:10000\r\n\r\n# Memory\r\nused_memory:123456\r\nused_memory_human:120.56K\r\nmem_fragmentation_ratio:1.25\r\nmaxmemory_policy:noeviction\r\nallocator_frag_ratio:4.5%\r\n\r\n# Commandstats\r\ncmdstat_get:calls=3,usec=1\r\n\r\n# Keyspace\r\ndb0:keys=4,expires=0,avg_ttl=0\r\n")
	info_redact(&b)
	want := "# Server\r\nredis_version:7.4.11\r\nuptime_in_seconds:12\r\n\r\n# Clients\r\nconnected_clients:0\r\nmaxclients:0\r\n\r\n# Memory\r\nused_memory:0\r\nused_memory_human:0B\r\nmem_fragmentation_ratio:0.00\r\nmaxmemory_policy:noeviction\r\nallocator_frag_ratio:0.00%\r\n\r\n# Commandstats\r\n\r\n# Keyspace\r\ndb0:keys=4,expires=0,avg_ttl=0\r\n"
	testing.expect_value(t, string(b[:]), want)
}

@(test)
access_persistence_and_top_rules_are_central :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Access_Fixture
	fixture_open(t, &f)
	defer fixture_close(&f)
	save := lookup_command(transmute([]u8)string("save"))
	debug := lookup_command(transmute([]u8)string("debug"))
	get := lookup_command(transmute([]u8)string("get"))
	shutdown := lookup_command(transmute([]u8)string("shutdown"))
	testing.expect(t, access_persistence_refuses(save, words("SAVE")))
	testing.expect(t, access_persistence_refuses(debug, words("DEBUG", "RELOAD")))
	testing.expect(t, !access_persistence_refuses(debug, words("DEBUG", "SLEEP", "0")))
	testing.expect(t, access_persistence_refuses(shutdown, words("SHUTDOWN", "SAVE")))
	testing.expect(t, !access_persistence_refuses(shutdown, words("SHUTDOWN", "NOSAVE")))
	testing.expect(t, !access_persistence_refuses(get, words("GET", "k")))
	access.top = false
	testing.expect_value(t, access_command_refusal(debug, words("DEBUG", "SLEEP", "0")), ERR_LABEL_TOP)
	testing.expect_value(t, access_command_refusal(get, words("GET", "k")), "")
	access.top = true
	testing.expect_value(t, access_command_refusal(debug, words("DEBUG", "SLEEP", "0")), "")
	testing.expect_value(t, access_command_refusal(save, words("SAVE")), ERR_LABEL_PERSISTENCE)
	testing.expect(t, access_persistence_off())
	labels_on = false
	testing.expect(t, !access_persistence_refuses(save, words("SAVE")))
	labels_on = true
}

@(test)
access_label_state_counts_in_client_memory_and_busy_rules :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Access_Fixture
	fixture_open(t, &f)
	defer fixture_close(&f)
	before := client_metadata_total
	testing.expect_value(t, client_metadata_memory(&f.c), 0)
	access_conn(&f.c)
	testing.expect_value(t, client_metadata_memory(&f.c), size_of(Access_Conn))
	testing.expect_value(t, client_metadata_total - before, size_of(Access_Conn))
	access_conn(&f.c)
	testing.expect_value(t, client_metadata_total - before, size_of(Access_Conn))
	access_conn_closed(&f.c)
	testing.expect_value(t, client_metadata_total, before)
	saved := access
	defer access = saved
	access_busy_script = {}
	access_busy_script.label = marking(t, "S//A")
	access.label = marking(t, "C")
	access.top = false
	testing.expect(t, !access_busy_sees_script())
	access.label = marking(t, "S//A/B")
	testing.expect(t, access_busy_sees_script())
	access.label = marking(t, "S//A;VETTED")
	testing.expect(t, !access_busy_sees_script())
	access.label = marking(t, "C")
	access.top = true
	testing.expect(t, access_busy_sees_script())
	access.top = false
	labels_on = false
	testing.expect(t, access_busy_sees_script())
	labels_on = true
}

@(test)
access_owner_rules_table_and_dominance :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Access_Fixture
	fixture_open(t, &f)
	defer fixture_close(&f)
	r: Acl_Label_Rules
	defer acl_label_rules_free(&r)
	e, handled := acl_label_rule(&r, transmute([]u8)string("owners:*"))
	testing.expect(t, handled && e == .Owners_Off)
	owners_on = true
	defer owners_on = false
	for rule in ([]string{"owners:*", "owner-shared", "owner-operator"}) {
		e, handled = acl_label_rule(&r, transmute([]u8)rule)
		testing.expectf(t, handled && e == .None, "%s: %v", rule, e)
	}
	text := make([dynamic]u8, context.temp_allocator)
	acl_label_describe(&text, &r)
	testing.expect_value(t, string(text[:]), "owners:* owner-shared owner-operator ")
	testing.expect_value(t, acl_label_flag_count(&r), 2)
	e, handled = acl_label_rule(&r, transmute([]u8)string("owner:auth0|5f3c"))
	testing.expect(t, handled && e == .None && r.owners == .Fixed && string(access_fixed_id(&r)) == "auth0|5f3c")
	for rule in ([]string{"owners:x", "owners:", "owner:", "owner:a b"}) {
		e, handled = acl_label_rule(&r, transmute([]u8)rule)
		testing.expectf(t, handled && e == .Bad_Owner, "%s: %v", rule, e)
	}
	_, handled = acl_label_rule(&r, transmute([]u8)string("ownerx"))
	testing.expect(t, !handled)
	mine, err := owner_intern(transmute([]u8)string("auth0|5f3c"))
	testing.expect(t, err == .None && mine != nil)
	other, err2 := owner_intern(transmute([]u8)string("someone-else"))
	testing.expect(t, err2 == .None && other.number != mine.number)
	testing.expect(t, access_may_act(&r, mine.number) && !access_may_act(&r, other.number) && access_may_act(&r, ow.SHARED))
	testing.expect(t, !access_may_act(&r, ow.EVERY) && !access_may_pin(&r, ow.EVERY))
	r.owners = .Any
	testing.expect(t, access_may_act(&r, other.number) && access_may_pin(&r, ow.EVERY))
	plain: Acl_Label_Rules
	testing.expect(t, access_may_act(&plain, ow.SHARED) && !access_may_act(&plain, mine.number))
	testing.expect(t, owner_lookup(transmute([]u8)string("someone-else")) == other)
	text_back, known := owner_text(other.number)
	testing.expect(t, known && text_back == "someone-else")
	number := other.number
	testing.expect(t, owner_drop(number) && owner_entry(number) == nil && owner_lookup(transmute([]u8)string("someone-else")) == nil)
	again, err3 := owner_intern(transmute([]u8)string("someone-else"))
	testing.expect(t, err3 == .None && again.number != number)
	high := marking(t, "S//A")
	low := marking(t, "C")
	hid, _ := access_intern(high)
	lid, _ := access_intern(low)
	testing.expect(t, scope_sees(ow.Scope{hid, mine.number}, ow.Scope{lid, ow.SHARED}))
	testing.expect(t, !scope_sees(ow.Scope{hid, mine.number}, ow.Scope{lid, again.number}))
	testing.expect(t, scope_sees(ow.Scope{hid, ow.EVERY}, ow.Scope{lid, again.number}))
	testing.expect(t, !scope_sees(ow.Scope{lid, mine.number}, ow.Scope{hid, mine.number}))
	testing.expect(t, scope_compare(mine.number, ow.Scope{lid, mine.number}, ow.Scope{lid, ow.SHARED}) > 0)
	testing.expect(t, scope_compare(mine.number, ow.Scope{lid, mine.number}, ow.Scope{hid, ow.SHARED}) < 0)
	b := make([dynamic]u8, context.temp_allocator)
	scope_format(&b, ow.Scope{lid, mine.number})
	testing.expect_value(t, string(b[:]), " OWNER auth0|5f3c")
	clear(&b)
	scope_format(&b, ow.Scope{lid, ow.SHARED})
	testing.expect_value(t, string(b[:]), " SHARED")
}
