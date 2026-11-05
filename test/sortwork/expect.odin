package sortwork

import "core:testing"
import eski "../../src"

reply_text :: proc(got: string) -> string {
	node, used, ok := resp_parse(got)
	if !ok || used != len(got) {
		return got
	}
	return render(node)
}

expect_reply :: proc(t: ^testing.T, s: ^Session, want: string, args: ..string, loc := #caller_location) -> bool {
	got := reply_text(call(s, ..args))
	return testing.expectf(t, got == want, "%v: got %s want %s", args, got, want, loc = loc)
}

expect_reply_on :: proc(t: ^testing.T, c: ^eski.Conn, want: string, args: ..string, loc := #caller_location) -> bool {
	got := reply_text(call_on(c, ..args))
	return testing.expectf(t, got == want, "%v: got %s want %s", args, got, want, loc = loc)
}

expect_bytes :: proc(t: ^testing.T, s: ^Session, want: string, args: ..[]u8, loc := #caller_location) -> bool {
	got := reply_text(call_bytes(s, ..args))
	return testing.expectf(t, got == want, "%v: got %s want %s", args, got, want, loc = loc)
}

expect_events :: proc(t: ^testing.T, s: ^Session, want: string, loc := #caller_location) -> bool {
	got := take_events(s)
	return testing.expectf(t, got == want, "events: got %q want %q", got, want, loc = loc)
}

b :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}
