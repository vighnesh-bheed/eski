import re
import socket
import sys
import time

HOST = "127.0.0.1"
VERSION_RE = re.compile(rb"VERSION [^\r\n]*\r\n")
K250 = b"k" * 250
K251 = b"k" * 251
BIG = b"x" * 2000000


def norm(b):
    return VERSION_RE.sub(b"VERSION <v>\r\n", b)


def drain(s, wait):
    s.settimeout(wait)
    out = b""
    try:
        while True:
            d = s.recv(1 << 20)
            if not d:
                out += b"<EOF>"
                break
            out += d
    except socket.timeout:
        pass
    except ConnectionResetError:
        out += b"<RST>"
    return out


def send(port, parts, gap=0.0, wait=0.3):
    s = socket.create_connection((HOST, port))
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    out = b""
    try:
        for p in parts:
            s.sendall(p)
            if gap:
                time.sleep(gap)
    except (BrokenPipeError, ConnectionResetError):
        out += b"<SENDFAIL>"
    out += drain(s, wait)
    s.close()
    return norm(out)


def chunks(b, n):
    return [b[i:i + n] for i in range(0, len(b), n)]


def show(b):
    if len(b) > 300:
        return repr(b[:200]) + "..." + repr(b[-60:])
    return repr(b)


class Report:
    def __init__(self):
        self.passed = 0
        self.failed = 0

    def check(self, name, ok, detail=""):
        if ok:
            self.passed += 1
            print("PASS " + name)
        else:
            self.failed += 1
            print("FAIL " + name + (" " + detail if detail else ""))


def plain_cases():
    return [
        ("flush", b"flush_all\r\n"),
        ("set get", b"set foo 0 0 3\r\nbar\r\nget foo\r\n"),
        ("set noreply", b"set foo 0 0 3 noreply\r\nbaz\r\nget foo\r\n"),
        ("bad data chunk long", b"set foo 0 0 3\r\nbarx\r\nget foo\r\n"),
        ("bad data chunk short", b"set foo 0 0 3\r\nba\r\n\r\nget foo\r\n"),
        ("bad data chunk extra bytes", b"set foo 0 0 3\r\nbarxyz\r\nget foo\r\n"),
        ("bad data chunk cr", b"set foo 0 0 3\r\nbar\rxget foo\r\n"),
        ("bad data chunk lf", b"set foo 0 0 3\r\nbar\nxget foo\r\n"),
        ("bad data chunk noreply", b"set foo 0 0 3 noreply\r\nbarx\r\nget foo\r\n"),
        ("bad length token", b"set foo 0 0 abc\r\nbar\r\n"),
        ("set too few tokens", b"set foo\r\n"),
        ("set four tokens", b"set foo 0 0\r\n"),
        ("set extra token", b"set foo 0 0 3 x\r\nbar\r\n"),
        ("set noreply not last", b"set foo 0 0 3 noreply extra\r\nbar\r\n"),
        ("set many extra tokens", b"set foo 0 0 3 a b c d e f\r\nbar\r\n"),
        ("flags max", b"set foo 4294967295 0 3\r\nbar\r\ngets foo\r\n"),
        ("flags wrap 2^32", b"set foo 4294967296 0 3\r\nbar\r\ngets foo\r\n"),
        ("flags wrap 2^32+1", b"set foo 4294967297 0 3\r\nbar\r\ngets foo\r\n"),
        ("flags u64 max", b"set foo 18446744073709551615 0 3\r\nbar\r\ngets foo\r\n"),
        ("flags overflow", b"set foo 18446744073709551616 0 3\r\nbar\r\ngets foo\r\n"),
        ("flags negative", b"set foo -1 0 3\r\nbar\r\n"),
        ("flags minus zero", b"set foo -0 0 3\r\nbar\r\ngets foo\r\n"),
        ("flags plus", b"set foo +5 0 3\r\nbar\r\nget foo\r\n"),
        ("flags leading zeros", b"set foo 00000000000000000000000000005 0 3\r\nbar\r\nget foo\r\n"),
        ("flags hex", b"set foo 0x10 0 3\r\nbar\r\nget foo\r\n"),
        ("flags junk", b"set foo 5a 0 3\r\nbar\r\nget foo\r\n"),
        ("length negative", b"set foo 0 0 -1\r\nbar\r\n"),
        ("length int max", b"set foo 0 0 2147483647\r\n"),
        ("length int max minus one", b"set foo 0 0 2147483646\r\n"),
        ("length leading zero", b"set foo 0 0 03\r\nbar\r\nget foo\r\n"),
        ("length long token", b"set foo 0 0 0000000000000000000003\r\nbar\r\n"),
        ("length plus", b"set foo 0 0 +3\r\nbar\r\nget foo\r\n"),
        ("length junk", b"set foo 0 0 3a\r\nbar\r\nget foo\r\n"),
        ("key too long set", b"set " + K251 + b" 0 0 1\r\nx\r\n"),
        ("key 250", b"set " + K250 + b" 0 0 1\r\nx\r\nget " + K250 + b"\r\n"),
        ("exptime negative", b"set foo 0 -1 3\r\nbar\r\nget foo\r\n"),
        ("exptime junk", b"set foo 0 abc 3\r\nbar\r\n"),
        ("exptime plus", b"set foo 0 +5 3\r\nbar\r\nget foo\r\n"),
        ("exptime int32 wrap negative", b"set foo 0 2147483648 3\r\nbar\r\nget foo\r\n"),
        ("exptime int32 max", b"set foo 0 2147483647 3\r\nbar\r\nget foo\r\n"),
        ("exptime wrap zero", b"set foo 0 4294967296 3\r\nbar\r\nget foo\r\n"),
        ("exptime i64 max", b"set foo 0 9223372036854775807 3\r\nbar\r\nget foo\r\n"),
        ("exptime i64 overflow", b"set foo 0 9223372036854775808 3\r\nbar\r\nget foo\r\n"),
        ("exptime wrap positive", b"set foo 0 -2147483649 3\r\nbar\r\nget foo\r\n"),
        ("exptime thirty days relative", b"set foo 0 2592000 3\r\nbar\r\nget foo\r\n"),
        ("exptime thirty days plus one absolute", b"set foo 0 2592001 3\r\nbar\r\nget foo\r\n"),
        ("noreply suppresses errors", b"set foo abc 0 3 noreply\r\nbar\r\n"),
        ("uppercase command", b"SET foo 0 0 3\r\nbar\r\n"),
        ("empty line", b"\r\n"),
        ("single space line", b" \r\n"),
        ("two spaces line", b"  \r\n"),
        ("bare lf", b"\n"),
        ("lone cr line", b"\r\r\n"),
        ("unknown", b"foo\r\n"),
        ("unknown with args", b"boguscommand slkdsldkfjsd\r\n"),
        ("one letter", b"z\r\n"),
        ("two letters", b"zz\r\n"),
        ("leading space command", b" get k\r\n"),
        ("leading space set", b" set k 0 0 1\r\nx\r\n"),
        ("tab is not a separator", b"get\tk\r\n"),
        ("tab in key", b"set a\tb 0 0 1\r\nx\r\nget a\tb\r\n"),
        ("control char in key", b"set a\x01b 0 0 1\r\nx\r\nget a\x01b\r\n"),
        ("get no key", b"get\r\n"),
        ("get blank key", b"get \r\n"),
        ("gets no key", b"gets  \r\n"),
        ("get lf only", b"get foo\n"),
        ("get double space", b"get  foo\r\n"),
        ("get trailing space", b"get foo \r\n"),
        ("get key too long", b"get " + K251 + b"\r\n"),
        ("get noreply is a key", b"get foo noreply\r\n"),
        ("get bad key drops pending replies", b"version\r\nversion\r\nget a " + K251 + b"\r\nversion\r\n"),
        ("gets bad key", b"version\r\ngets x " + K251 + b"\r\n"),
        ("gat bad key", b"version\r\ngat 1 " + K251 + b"\r\n"),
        ("get cr inside key", b"get k\rx\r\n"),
        ("delete with zero", b"delete foo 0\r\n"),
        ("delete with time", b"delete foo 1\r\n"),
        ("delete noreply", b"delete foo noreply\r\nget foo\r\n"),
        ("delete missing", b"delete foo\r\n"),
        ("delete no key", b"delete\r\n"),
        ("delete extra", b"delete foo bar baz\r\n"),
        ("delete noreply not last", b"delete k noreply extra\r\nget zzz\r\n"),
        ("delete key too long", b"delete " + K251 + b"\r\n"),
        ("delete key too long noreply", b"delete " + K251 + b" noreply\r\nget zzz\r\n"),
        ("empty value", b"set foo 0 0 0\r\n\r\nget foo\r\n"),
        ("value at limit", b"set foo 0 0 1048514\r\n" + b"x" * 1048514 + b"\r\nget foo\r\n"),
        ("value over limit", b"set foo 0 0 1048515\r\n" + b"x" * 1048515 + b"\r\nget foo\r\n"),
        ("flags shrink limit", b"set kk 5 0 1048511\r\n" + b"y" * 1048511 + b"\r\n"),
        ("flags shrink limit over", b"set kk 5 0 1048512\r\n" + b"y" * 1048512 + b"\r\n"),
        ("set too large deletes old", b"set foo 0 0 3\r\nbar\r\nset foo 0 0 2000000\r\n" + BIG + b"\r\nget foo\r\n"),
        ("add too large keeps old", b"set foo 0 0 3\r\nbar\r\nadd foo 0 0 2000000\r\n" + BIG + b"\r\nget foo\r\n"),
        ("set too large noreply", b"set foo 0 0 3\r\nbar\r\nset foo 0 0 2000000 noreply\r\n" + BIG + b"\r\nget foo\r\n"),
        ("replace too large", b"set k 0 0 1\r\nx\r\nreplace k 0 0 2000000\r\n" + BIG + b"\r\nget k\r\n"),
        ("cas too large", b"cas k 0 0 2000000 1\r\n" + BIG + b"\r\nget k\r\n"),
        ("prepend too large", b"set k 0 0 1\r\nx\r\nprepend k 0 0 2000000\r\n" + BIG + b"\r\nget k\r\n"),
        ("append data item limit", b"set k 0 0 1\r\nx\r\nappend k 0 0 1048515\r\n" + b"y" * 1048515 + b"\r\n"),
        ("append combined over", b"set k 0 0 1\r\nx\r\nappend k 0 0 1048516\r\n" + b"y" * 1048516 + b"\r\n"),
        ("append data item over", b"set k 0 0 1\r\nx\r\nappend k 0 0 1048517\r\n" + b"y" * 1048517 + b"\r\n"),
        ("append own flags count", b"set k 0 0 1\r\nx\r\nappend k 5 0 1048513\r\n" + b"y" * 1048513 + b"\r\n"),
        ("append keeps old flags at limit", b"set k 9 0 1048400\r\n" + b"x" * 1048400 + b"\r\nappend k 0 0 112\r\n" + b"y" * 112 + b"\r\n"),
        ("append keeps old flags over", b"set k 9 0 1048400\r\n" + b"x" * 1048400 + b"\r\nappend k 0 0 113\r\n" + b"y" * 113 + b"\r\n"),
        ("cas sequence start", b"gets a\r\n"),
        ("cas after set", b"set a 0 0 1\r\n1\r\ngets a\r\n"),
        ("cas second set", b"set b 0 0 1\r\n1\r\ngets b\r\n"),
        ("add", b"add b 0 0 1\r\n2\r\nadd c 0 0 1\r\n2\r\ngets c\r\n"),
        ("replace", b"replace zz 0 0 1\r\n2\r\nreplace c 5 0 1\r\n3\r\ngets c\r\n"),
        ("append keeps flags", b"append c 9 0 1\r\n4\r\ngets c\r\n"),
        ("prepend keeps flags", b"prepend c 9 0 1\r\n0\r\ngets c\r\n"),
        ("append prepend missing", b"append nope 0 0 1\r\n4\r\nprepend nope 0 0 1\r\n4\r\ngets a\r\n"),
        ("append short", b"set k 0 0 1\r\nx\r\nappend k\r\nprepend k 0 0\r\n"),
        ("incr cas", b"incr a 5\r\ngets a\r\n"),
        ("decr cas", b"decr a 3\r\ngets a\r\n"),
        ("touch keeps cas", b"touch a 100\r\ngets a\r\n"),
        ("gat and gats", b"gat 100 a\r\ngats 100 a\r\n"),
        ("cas mismatch", b"cas a 0 0 1 999\r\n9\r\ngets a\r\n"),
        ("cas small mismatch", b"cas a 0 0 1 9\r\n9\r\ngets a\r\n"),
        ("cas missing", b"cas zz 0 0 1 9\r\n9\r\nset d 0 0 1\r\nx\r\ngets d\r\n"),
        ("cas after delete", b"delete d\r\nset d 0 0 1\r\nx\r\ngets d\r\n"),
        ("cas match", b"set m 0 0 1\r\nx\r\ngets m\r\n"),
        ("cas short", b"cas k 0 0 1\r\nx\r\n"),
        ("cas extra tokens", b"cas k 0 0 1 2 3\r\nx\r\n"),
        ("cas noreply short", b"cas k 0 0 1 noreply\r\nx\r\nget zzz\r\n"),
        ("cas negative", b"cas k 0 0 1 -1\r\nx\r\n"),
        ("cas overflow", b"cas k 0 0 1 18446744073709551616\r\nx\r\n"),
        ("cas u64 max", b"cas k 0 0 1 18446744073709551615\r\nx\r\n"),
        ("cas plus", b"cas k 0 0 1 +5\r\nx\r\n"),
        ("cas long token", b"cas k 0 0 1 0000000000000000000000000000001\r\nx\r\n"),
        ("noreply bad chunk then cmd", b"set e 0 0 3 noreply\r\nabcd\r\nset e 0 0 1\r\nx\r\ngets e\r\n"),
        ("incr missing", b"incr zz 1\r\nset b 0 0 1\r\nx\r\ngets b\r\n"),
        ("incr non numeric", b"incr b 1\r\nset b 0 0 1\r\nx\r\ngets b\r\n"),
        ("too large keeps cas", b"set big 0 0 2000000\r\n" + BIG + b"\r\nset b 0 0 1\r\nx\r\ngets b\r\n"),
        ("bad line keeps cas", b"set b 0 abc 1\r\nx\r\nset b 0 0 1\r\nx\r\ngets b\r\n"),
        ("flush keeps cas", b"flush_all\r\nset b 0 0 1\r\nx\r\ngets b\r\n"),
        ("decr pads", b"set n 0 0 2\r\n10\r\ndecr n 1\r\ngets n\r\n"),
        ("incr grows", b"incr n 100\r\ngets n\r\n"),
        ("decr pads three", b"set n 0 0 3\r\n100\r\ndecr n 95\r\nget n\r\n"),
        ("incr whitespace value", b"set n 0 0 4\r\n 12 \r\nincr n 1\r\nget n\r\n"),
        ("incr negative value", b"set n 0 0 3\r\n-12\r\nincr n 1\r\n"),
        ("incr plus value", b"set n 0 0 3\r\n+12\r\nincr n 1\r\n"),
        ("incr junk value", b"set n 0 0 3\r\n12a\r\nincr n 1\r\n"),
        ("incr trailing space value", b"set n 0 0 3\r\n12 \r\nincr n 1\r\n"),
        ("incr empty value", b"set n 0 0 0\r\n\r\nincr n 1\r\n"),
        ("incr 21 digits", b"set n 0 0 21\r\n184467440737095516150\r\nincr n 1\r\n"),
        ("incr 2^64", b"set n 0 0 20\r\n18446744073709551616\r\nincr n 1\r\n"),
        ("incr bad deltas", b"set n 0 0 2\r\n10\r\nincr n abc\r\nincr n -1\r\nincr n 18446744073709551616\r\nincr n\r\nincr n 1 2\r\nincr n 1 noreply\r\nget n\r\n"),
        ("decr floor", b"set n 0 0 2\r\n10\r\ndecr n 18446744073709551615\r\nget n\r\n"),
        ("incr delta plus and zero", b"set n 0 0 2\r\n10\r\nincr n +5\r\nincr n 05\r\nget n\r\n"),
        ("incr leading tab", b"set n 0 0 3\r\n\t12\r\nincr n 1\r\nget n\r\n"),
        ("incr trailing tab", b"set n 0 0 3\r\n12\t\r\nincr n 1\r\nget n\r\n"),
        ("incr trailing nul", b"set n 0 0 3\r\n12\x00\r\nincr n 1\r\nget n\r\n"),
        ("incr zeros", b"set n 0 0 2\r\n00\r\nincr n 1\r\nget n\r\n"),
        ("incr long zeros", b"set n 0 0 26\r\n00000000000000000000000001\r\nincr n 1\r\nget n\r\n"),
        ("incr long spaces", b"set n 0 0 30\r\n                             5\r\nincr n 1\r\nget n\r\n"),
        ("incr minus zero", b"set n 0 0 2\r\n-0\r\nincr n 1\r\nget n\r\n"),
        ("incr minus wrap", b"set n 0 0 20\r\n-9223372036854775809\r\nincr n 1\r\nget n\r\n"),
        ("incr value then junk", b"set n 0 0 4\r\n12 -\r\nincr n 1\r\nget n\r\n"),
        ("incr delta too long", b"set n 0 0 2\r\n10\r\nincr n 000000000000000000000000005\r\nget n\r\n"),
        ("incr delta 22 and 23", b"set n 0 0 2\r\n10\r\nincr n 0000000000000000000005\r\nincr n 00000000000000000000005\r\nget n\r\n"),
        ("incr delta overflow", b"set n 0 0 2\r\n10\r\nincr n 99999999999999999999\r\n"),
        ("incr wraps", b"set n 0 0 20\r\n18446744073709551615\r\nincr n 2\r\nget n\r\n"),
        ("incr wraps big delta", b"set n 0 0 2\r\n10\r\nincr n 18446744073709551615\r\nget n\r\n"),
        ("incr keeps flags", b"set n 5 100 2\r\n10\r\nincr n 1000\r\ngets n\r\n"),
        ("incr bug21", b"set bug21 0 0 19\r\n9223372036854775807\r\nincr bug21 1\r\nincr bug21 1\r\ndecr bug21 1\r\n"),
        ("incr key too long", b"incr " + K251 + b" 1\r\n"),
        ("incr no args", b"incr\r\n"),
        ("decr one arg", b"decr k\r\n"),
        ("touch short", b"touch foo\r\n"),
        ("touch bad exptime", b"touch foo abc\r\n"),
        ("touch missing", b"touch nope 10\r\n"),
        ("touch noreply", b"touch foo 10 noreply\r\n"),
        ("touch extra", b"set k 0 0 1\r\nx\r\ntouch k 1 2\r\n"),
        ("touch negative", b"set k 0 0 1\r\nx\r\ntouch k -5\r\nget k\r\n"),
        ("touch int range", b"set k 0 0 1\r\nx\r\ntouch k 2147483648\r\ntouch k 2147483647\r\ntouch k -2147483649\r\ntouch k 4294967296\r\nget k\r\n"),
        ("touch plus", b"touch k +5\r\n"),
        ("touch long token", b"touch k 000000000001\r\n"),
        ("touch key too long", b"touch " + K251 + b" 1\r\n"),
        ("gat short", b"gat\r\n"),
        ("gat one arg", b"gat 1\r\n"),
        ("gat bad exptime", b"gat x k\r\n"),
        ("gat plus", b"gat +5 k\r\n"),
        ("gat overflow", b"gat 99999999999999999999 k\r\n"),
        ("gat noreply is key", b"gat 10 k noreply\r\n"),
        ("gat negative", b"set k 0 0 1\r\nx\r\ngat -1 k\r\nget k\r\n"),
        ("gats multi", b"set k1 0 0 1\r\nx\r\nset k2 3 0 1\r\ny\r\ngats 100 k1 k2 nope\r\n"),
        ("flush negative", b"flush_all -1\r\n"),
        ("flush noreply", b"flush_all 0 noreply\r\nget zzz\r\n"),
        ("flush extra", b"flush_all 1 2\r\n"),
        ("flush invalid", b"flush_all abc\r\n"),
        ("flush invalid noreply", b"flush_all abc noreply\r\nget zzz\r\n"),
        ("flush plus", b"flush_all +5\r\n"),
        ("flush overflow", b"flush_all 2147483648\r\n"),
        ("flush many", b"flush_all 0 0 0\r\n"),
        ("flush", b"flush_all\r\nget a b c\r\n"),
        ("verbosity short", b"verbosity\r\n"),
        ("verbosity", b"verbosity 1\r\n"),
        ("verbosity extra", b"verbosity 1 2\r\n"),
        ("verbosity junk", b"verbosity abc\r\n"),
        ("verbosity negative", b"verbosity -1\r\n"),
        ("verbosity plus", b"verbosity +1\r\n"),
        ("verbosity u32 max", b"verbosity 4294967295\r\n"),
        ("verbosity overflow", b"verbosity 4294967296\r\n"),
        ("verbosity noreply alone", b"verbosity noreply\r\nget zzz\r\n"),
        ("verbosity noreply", b"verbosity 1 noreply\r\nget zzz\r\n"),
        ("verbosity reset", b"verbosity 0\r\n"),
        ("version", b"version\r\n"),
        ("version extra", b"version x\r\n"),
        ("version junk suffix", b"versionx\r\n"),
        ("quit", b"quit\r\nget a\r\n"),
        ("quit extra", b"quit x\r\n"),
        ("quit flushes earlier replies", b"get a\r\nquit\r\nget a\r\n"),
        ("stats unknown", b"stats foo\r\n"),
        ("stats noreply", b"stats noreply\r\n"),
        ("stats items empty", b"stats items\r\n"),
        ("stats sizes", b"stats sizes\r\n"),
        ("stats reset", b"stats reset\r\n"),
        ("stats reset extra", b"stats reset x\r\n"),
        ("shutdown", b"shutdown\r\n"),
        ("http get closes", b"GET / HTTP/1.0\r\n"),
        ("http put closes", b"PUT /x HTTP/1.1\r\n"),
        ("http delete closes", b"DELETE HTTP/1.1\r\n"),
        ("http lowercase verb closes", b"foo HTTP/1.1\r\n"),
        ("http drops pending", b"get a\r\nGET / HTTP/1.1\r\nget a\r\n"),
        ("http not last token", b"foo HTTP/1.1 bar\r\n"),
        ("http prefix only", b"foo xHTTP/1.1\r\n"),
        ("http alone", b"HTTP/1.1\r\n"),
        ("http get command wins", b"get / HTTP/1.1\r\n"),
        ("http 23 tokens closes", b"foo " + b"a " * 21 + b"HTTP/1.1\r\n"),
        ("http 24 tokens errors", b"foo " + b"a " * 22 + b"HTTP/1.1\r\n"),
        ("GET without http", b"GET foo\r\n"),
        ("meta command unknown", b"mz\r\n"),
        ("unknown noreply", b"foo noreply\r\nfoo a noreply\r\nnoreply\r\n noreply\r\nversion\r\n"),
        ("unknown noreply 23 and 24 tokens", b"foo " + b"a " * 21 + b"noreply\r\nfoo " + b"a " * 22 + b"noreply\r\n"),
        ("http before noreply", b"foo noreply HTTP/1.1\r\n"),
        ("noreply after http", b"foo HTTP/1.1 noreply\r\nversion\r\n"),
        ("shutdown noreply", b"shutdown noreply\r\nversion\r\n"),
        ("stats ignores noreply", b"stats foo noreply\r\n"),
        ("version ignores noreply", b"version noreply\r\n"),
        ("storage noreply bad length still answers", b"set noreply\r\nset k 0 0 noreply\r\nset k 0 0 abc noreply\r\nset k 0 0 2147483646 noreply\r\nset k 0 0 -1 noreply\r\nversion\r\n"),
        ("storage noreply bad fields silent", b"set k abc 0 1 noreply\r\nx\r\ncas k 0 0 1 noreply\r\nx\r\nversion\r\n"),
        ("noreply needs the minimum tokens", b"delete noreply\r\nincr noreply\r\ndecr noreply\r\ntouch noreply\r\nincr k noreply\r\ntouch k noreply\r\nverbosity noreply\r\ngat noreply\r\ncas k noreply\r\nversion\r\n"),
        ("noreply not last is a key", b"incr noreply x\r\n"),
        ("length minus zero", b"set k 0 0 -0\r\n\r\nset k 0 0 -00\r\n\r\nget k\r\n"),
        ("length lone minus", b"set k 0 0 -\r\n\r\nget k\r\n"),
        ("length eleven chars", b"set k 0 0 00000000001\r\nx\r\nset k 0 0 000000000001\r\nx\r\n"),
        ("length minus eleven chars", b"set k 0 0 -0000000000\r\n\r\nset k 0 0 -00000000000\r\n\r\n"),
        ("exptime lone minus", b"set k 0 0 1\r\nx\r\ntouch k -\r\ngat - k\r\nflush_all -\r\nget k\r\n"),
        ("verbosity minus zero", b"verbosity -0\r\nverbosity 00000000001\r\nverbosity 000000000001\r\n"),
        ("delta and cas minus zero", b"set n 0 0 1\r\n5\r\nincr n -0\r\ncas zz 0 0 1 -0\r\nx\r\n"),
    ]


def staged_cases():
    mix = (b"set a 5 0 3\r\nabc\r\nget a\r\nappend a 0 0 2\r\nde\r\ngets a\r\nincr a 1\r\nset n 0 0 2\r\n10\r\n"
           b"decr n 3\r\nget n\r\nprepend a 0 0 1\r\nz\r\ndelete a\r\nget a b n\r\nset x 0 0 5 noreply\r\nhello\r\n"
           b"get x\r\ntouch x 100\r\ngat 0 x\r\ngats 0 x n\r\nbogus\r\nset y 0 0 3\r\nabcde\r\nget y\r\n")
    big = b"B" * 300000
    return [
        ("staged flush", [b"flush_all\r\n"]),
        ("pipeline whole", [mix]),
        ("split 1 byte", chunks(mix, 1)),
        ("split 2 bytes", chunks(mix, 2)),
        ("split 3 bytes", chunks(mix, 3)),
        ("split 7 bytes", chunks(mix, 7)),
        ("split 13 bytes", chunks(mix, 13)),
        ("big value split", [b"set big 0 0 300000\r\n"] + chunks(big + b"\r\n", 65536) + [b"get big\r\n"]),
        ("value split per byte", chunks(b"set big2 0 0 10\r\n0123456789\r\nget big2\r\n", 1)),
        ("too large swallowed across reads", [b"set tl 0 0 1\r\nx\r\nset tl 0 0 2000000\r\n"] + chunks(b"y" * 2000002, 300000) + [b"get tl\r\n"]),
        ("too large header split", chunks(b"set tl 0 0 2000000\r\n", 3) + [b"y" * 2000002, b"get tl\r\n"]),
        ("bad line swallowed across reads", [b"set q abc 0 5\r\n", b"12", b"345\r\nget q\r\n"]),
        ("bad chunk split", [b"set q 0 0 3\r\nab", b"cd", b"\r\nget q\r\n"]),
        ("noreply pipeline", [b"set a 0 0 1 noreply\r\n1\r\nadd a 0 0 1 noreply\r\n2\r\nreplace a 0 0 1 noreply\r\n3\r\nappend a 0 0 1 noreply\r\n4\r\nprepend a 0 0 1 noreply\r\n5\r\nincr a 1 noreply\r\ndecr a 2 noreply\r\ntouch a 10 noreply\r\nget a\r\ndelete a noreply\r\nget a\r\nflush_all noreply\r\nverbosity 1 noreply\r\nget a\r\n"]),
        ("long incr line closes", [b"incr " + b" " * 2100 + b"k 1"]),
        ("long line drops pending", [b"get a\r\n" + b"x" * 3000]),
        ("long get line allowed", [b"get " + b" " * 2100 + b"manyspaces", b"\r\n"]),
        ("long gets line allowed", [b"gets " + b" " * 5000 + b"k", b"\r\n"]),
        ("long gat line closes", [b"gat 1 " + b" " * 3000 + b"k"]),
        ("2048 bytes waits", [b"x" * 2048, b"\r\n"]),
        ("2049 bytes closes", [b"x" * 2049]),
        ("multiget 3000 keys", [b"set foobarbaz 0 0 2\r\nhi\r\n", b"get " + b"foobarbaz " * 3000 + b"\r\n"]),
        ("multiget split", [b"set foobarbaz 0 0 2\r\nhi\r\n"] + chunks(b"get " + b"foobarbaz " * 3000 + b"\r\n", 4000)),
        ("crlf split", [b"get foobarbaz\r", b"\nget foobarbaz\r\n"]),
        ("lf terminated lines", [b"set lf 0 0 2\nab\r\nget lf\n"]),
        ("data block lf only", [b"set lf 0 0 2\r\nab\n\nget lf\r\n"]),
        ("format error waits for the swallowed data", [b"set k abc 0 5\r\n", b"12", b"345\r\nversion\r\n"]),
        ("too large error waits for the swallowed data", [b"set k 0 0 2000000\r\n", b"y" * 1000000, b"y" * 1000002 + b"version\r\n"]),
        ("swallow spans later commands", [b"cas num 65535  0 41\r\n", b"\r\n", b"gats 100000 key:2\r\n", b"gets a\r\n", b"add " + b"z" * 250 + b" abc 0 3 noreply\r\nabc\r\n"]),
        ("swallow exact length", [b"cas num 65535  0 41\r\n", b"y" * 43 + b"version\r\n"]),
    ]


def stats_map(port, arg=b""):
    out = send(port, [b"stats" + arg + b"\r\n"])
    names, vals = [], {}
    for line in out.split(b"\r\n"):
        p = line.split(b" ")
        if len(p) == 3 and p[0] == b"STAT":
            names.append(p[1].decode())
            vals[p[1].decode()] = p[2].decode()
    return names, vals


def subseq(small, big):
    it = iter(big)
    return all(x in it for x in small)


def run_compare(jport, rport):
    r = Report()
    for name, payload in plain_cases():
        a = send(jport, [payload])
        b = send(rport, [payload])
        r.check("mc " + name, a == b, "eski=" + show(a) + " ref=" + show(b))
    for name, parts in staged_cases():
        a = send(jport, parts, gap=0.02, wait=0.4)
        b = send(rport, parts, gap=0.02, wait=0.4)
        r.check("mc " + name, a == b, "eski=" + show(a) + " ref=" + show(b))
    for port in (jport, rport):
        send(port, [b"flush_all\r\nstats reset\r\n"])
    seq = [b"get a b c\r\n", b"set a 0 0 1\r\n1\r\n", b"set a 7 0 2\r\n12\r\n", b"get a a b\r\n", b"gets a\r\n",
           b"add a 0 0 1\r\n1\r\n", b"replace zz 0 0 1\r\n1\r\n", b"append a 0 0 1\r\n1\r\n", b"append zz 0 0 1\r\n1\r\n",
           b"cas zz 0 0 1 1\r\n1\r\n", b"cas a 0 0 1 1\r\n1\r\n", b"touch a 100\r\n", b"touch zz 100\r\n", b"gat 100 a zz\r\n",
           b"gats 100 a\r\n", b"incr a 1\r\n", b"incr zz 1\r\n", b"decr a 1\r\n", b"decr zz 1\r\n", b"set t 0 0 1\r\nx\r\nincr t 1\r\n",
           b"delete a\r\n", b"delete a\r\n", b"set big 0 0 2000000\r\n" + BIG + b"\r\n", b"set q 0 0 1\r\nxx\r\n",
           b"set e 0 -1 1\r\nx\r\n", b"get e\r\n", b"set n 0 0 1\r\n9\r\nincr n 1\r\n", b"incr n 1\r\n", b"set g 3 100 5\r\nhello\r\n"]
    for port in (jport, rport):
        for c in seq:
            send(port, [c], wait=0.15)
    jn, jv = stats_map(jport)
    rn, rv = stats_map(rport)
    for k in ["cmd_get", "cmd_set", "cmd_flush", "cmd_touch", "get_hits", "get_misses", "delete_misses", "delete_hits",
              "incr_misses", "incr_hits", "decr_misses", "decr_hits", "cas_misses", "cas_hits", "cas_badval", "touch_hits",
              "touch_misses", "store_too_large", "store_no_memory", "auth_cmds", "auth_errors", "curr_items", "total_items",
              "bytes", "evictions", "pointer_size", "accepting_conns", "rejected_connections", "conn_yields", "get_flushed"]:
        r.check("mc stats " + k, jv.get(k) == rv.get(k), "eski=%s ref=%s" % (jv.get(k), rv.get(k)))
    for k in ["pid", "uptime", "time", "version", "rusage_user", "rusage_system", "curr_connections", "total_connections",
              "bytes_read", "bytes_written", "limit_maxbytes", "threads", "listen_disabled_num", "reclaimed"]:
        r.check("mc stats has " + k, k in jv and k in rv)
    r.check("mc stats names follow the reference order", subseq(jn, rn), str([n for n in jn if n not in rn]))
    sn, sv = stats_map(jport, b" settings")
    srn, srv = stats_map(rport, b" settings")
    r.check("mc stats settings names follow the reference order", subseq(sn, srn), str([n for n in sn if n not in srn]))
    for k in ["item_size_max", "cas_enabled", "client_flags_size", "udpport", "verbosity", "auth_enabled_sasl",
              "auth_enabled_ascii", "shutdown_command", "domain_socket", "detail_enabled", "flush_enabled", "tcp_backlog"]:
        r.check("mc stats settings " + k, sv.get(k) == srv.get(k), "eski=%s ref=%s" % (sv.get(k), srv.get(k)))
    for port in (jport, rport):
        send(port, [b"flush_all\r\n"])
    a = send(jport, [b"stats reset\r\nstats\r\n"])
    r.check("mc stats reset zeroes counters", b"STAT cmd_get 0\r\n" in a and b"STAT total_items 0\r\n" in a, show(a))
    now = int(time.time())
    timed = [
        ("ttl set", b"set e1 0 3 1\r\nx\r\nset e2 0 100 1\r\ny\r\nset t1 0 0 1\r\nz\r\ntouch t1 3\r\nset g1 0 0 1\r\nw\r\ngat 3 g1\r\nget e1 e2 t1 g1\r\n"),
        ("ttl absolute", b"set abs 0 %d 1\r\na\r\nset absp 0 %d 1\r\nb\r\nget abs absp\r\n" % (now + 3, now - 5)),
        ("flush delayed", b"set f1 0 0 2\r\nf1\r\nflush_all 5\r\nget f1\r\nset f2 0 0 2\r\nf2\r\nget f1 f2\r\n"),
    ]
    for name, payload in timed:
        a = send(jport, [payload])
        b = send(rport, [payload])
        r.check("mc timed " + name, a == b, "eski=" + show(a) + " ref=" + show(b))
    time.sleep(6.5)
    after = [
        ("ttl expired", b"get e1 e2 t1 g1 abs\r\n"),
        ("flush delayed fired", b"get f1 f2\r\nset f4 0 0 2\r\nf4\r\nget f4\r\n"),
        ("flush far future", b"set x 0 0 1\r\nx\r\nflush_all 86400\r\nget x\r\nset x2 0 0 1\r\ny\r\nget x x2\r\n"),
        ("flush now cancels", b"flush_all 0\r\nget x x2\r\n"),
        ("flush absolute past", b"set y 0 0 1\r\ny\r\nflush_all %d\r\nget y\r\n" % (now - 100000000)),
        ("flush absolute future", b"set y 0 0 1\r\ny\r\nflush_all %d\r\nget y\r\n" % (now + 100)),
        ("flush now", b"flush_all\r\nget y\r\n"),
    ]
    for name, payload in after:
        a = send(jport, [payload])
        b = send(rport, [payload])
        r.check("mc timed " + name, a == b, "eski=" + show(a) + " ref=" + show(b))
    return r


def resp(args):
    out = b"*%d\r\n" % len(args)
    for a in args:
        if isinstance(a, str):
            a = a.encode()
        out += b"$%d\r\n%s\r\n" % (len(a), a)
    return out


class Redis:
    def __init__(self, port):
        self.s = socket.create_connection((HOST, port))
        self.f = self.s.makefile("rb")

    def cmd(self, *args):
        self.s.sendall(resp(args))
        return self.read()

    def read(self):
        line = self.f.readline()
        t, rest = line[:1], line[1:-2]
        if t in (b"+", b"-"):
            return rest.decode()
        if t == b":":
            return int(rest)
        if t == b"$":
            n = int(rest)
            if n < 0:
                return None
            d = self.f.read(n + 2)
            return d[:-2]
        if t == b"*":
            n = int(rest)
            if n < 0:
                return None
            return [self.read() for _ in range(n)]
        return line


def run_cross(rport, mport):
    r = Report()
    red = Redis(rport)
    mc = lambda payload: send(mport, [payload])
    red.cmd("SELECT", "0")
    mc(b"flush_all\r\n")
    red.cmd("SET", "rk", "hello")
    r.check("cross redis write reads through memcached with zero flags", mc(b"get rk\r\n") == b"VALUE rk 0 5\r\nhello\r\nEND\r\n")
    a = mc(b"gets rk\r\n")
    b = mc(b"gets rk\r\n")
    m = re.match(rb"VALUE rk 0 5 (\d+)\r\nhello\r\nEND\r\n", a)
    r.check("cross redis write gets a cas value that stays stable", m is not None and a == b, show(a) + " " + show(b))
    if m:
        cas = m.group(1)
        r.check("cross cas on redis written value", mc(b"cas rk 4 0 3 " + cas + b"\r\nnew\r\nget rk\r\n") == b"STORED\r\nVALUE rk 4 3\r\nnew\r\nEND\r\n")
    r.check("cross memcached write reads through redis", mc(b"set mk 42 100 5\r\nworld\r\n") == b"STORED\r\n" and red.cmd("GET", "mk") == b"world")
    ttl = red.cmd("TTL", "mk")
    r.check("cross memcached exptime is the redis ttl", ttl in (99, 100), str(ttl))
    r.check("cross flags round trip", mc(b"get mk\r\n") == b"VALUE mk 42 5\r\nworld\r\nEND\r\n")
    red.cmd("EXPIRE", "mk", "500")
    r.check("cross redis expire keeps flags", mc(b"get mk\r\n") == b"VALUE mk 42 5\r\nworld\r\nEND\r\n")
    r.check("cross memcached touch sets the redis ttl", mc(b"touch mk 200\r\n") == b"TOUCHED\r\n" and red.cmd("TTL", "mk") in (199, 200))
    r.check("cross gat sets the redis ttl", mc(b"gat 300 mk\r\n") == b"VALUE mk 42 5\r\nworld\r\nEND\r\n" and red.cmd("TTL", "mk") in (299, 300))
    r.check("cross touch zero clears the redis ttl", mc(b"touch mk 0\r\n") == b"TOUCHED\r\n" and red.cmd("TTL", "mk") == -1)
    red.cmd("PERSIST", "mk")
    a = mc(b"gets mk\r\n")
    m = re.match(rb"VALUE mk 42 5 (\d+)\r\n", a)
    red.cmd("SET", "mk", "redis")
    r.check("cross redis overwrite resets flags", mc(b"get mk\r\n") == b"VALUE mk 0 5\r\nredis\r\nEND\r\n")
    if m:
        r.check("cross redis overwrite invalidates cas", mc(b"cas mk 0 0 1 " + m.group(1) + b"\r\nx\r\n") == b"EXISTS\r\n")
    mc(b"set ak 7 0 2\r\nab\r\n")
    red.cmd("APPEND", "ak", "cd")
    r.check("cross redis append resets flags", mc(b"get ak\r\n") == b"VALUE ak 0 4\r\nabcd\r\nEND\r\n")
    mc(b"set ak 7 0 2\r\nab\r\n")
    red.cmd("SETRANGE", "ak", "0", "z")
    r.check("cross redis setrange resets flags", mc(b"get ak\r\n") == b"VALUE ak 0 2\r\nzb\r\nEND\r\n")
    mc(b"set ak 7 0 2\r\nab\r\n")
    red.cmd("GET", "ak")
    red.cmd("STRLEN", "ak")
    r.check("cross redis reads keep flags", mc(b"get ak\r\n") == b"VALUE ak 7 2\r\nab\r\nEND\r\n")
    mc(b"set n 3 0 2\r\n10\r\n")
    r.check("cross redis incr on memcached value", red.cmd("INCR", "n") == 11 and mc(b"get n\r\n") == b"VALUE n 0 2\r\n11\r\nEND\r\n")
    red.cmd("SET", "rn", "41")
    r.check("cross memcached incr on redis value", mc(b"incr rn 1\r\n") == b"42\r\n" and red.cmd("GET", "rn") == b"42")
    red.cmd("SET", "rn", "abc")
    r.check("cross memcached incr on redis text", mc(b"incr rn 1\r\n") == b"CLIENT_ERROR cannot increment or decrement non-numeric value\r\n")
    red.cmd("SET", "rn", "-5")
    r.check("cross memcached incr rejects negative redis value", mc(b"decr rn 1\r\n") == b"CLIENT_ERROR cannot increment or decrement non-numeric value\r\n")
    red.cmd("DEL", "lst")
    red.cmd("RPUSH", "lst", "a", "b")
    r.check("cross non string key reads as a miss", mc(b"get lst\r\n") == b"END\r\n")
    r.check("cross add on non string key is not stored", mc(b"add lst 0 0 1\r\nx\r\n") == b"NOT_STORED\r\n")
    r.check("cross incr on non string key", mc(b"incr lst 1\r\n") == b"CLIENT_ERROR cannot increment or decrement non-numeric value\r\n")
    r.check("cross set replaces a non string key", mc(b"set lst 0 0 1\r\nx\r\n") == b"STORED\r\n" and red.cmd("TYPE", "lst") == "string")
    r.check("cross memcached delete is seen by redis", mc(b"delete lst\r\n") == b"DELETED\r\n" and red.cmd("EXISTS", "lst") == 0)
    red.cmd("SET", "dk", "v")
    r.check("cross redis delete is seen by memcached", red.cmd("DEL", "dk") == 1 and mc(b"get dk\r\n") == b"END\r\n")
    red.cmd("SET", "pk", "v", "PX", "300")
    first = mc(b"get pk\r\n")
    time.sleep(0.5)
    r.check("cross redis px expiry is seen by memcached", first == b"VALUE pk 0 1\r\nv\r\nEND\r\n" and mc(b"get pk\r\n") == b"END\r\n")
    mc(b"set sk 0 1 1\r\nx\r\n")
    time.sleep(1.3)
    r.check("cross memcached expiry is seen by redis", red.cmd("EXISTS", "sk") == 0)
    mc(b"set rnk 9 0 1\r\nv\r\n")
    red.cmd("RENAME", "rnk", "rnk2")
    r.check("cross rename resets flags", mc(b"get rnk rnk2\r\n") == b"VALUE rnk2 0 1\r\nv\r\nEND\r\n")
    red.cmd("SELECT", "1")
    red.cmd("SET", "db1key", "x")
    red.cmd("SELECT", "0")
    mc(b"set m1 0 0 1\r\nx\r\n")
    r.check("cross flush_all empties database 0 only", mc(b"flush_all\r\n") == b"OK\r\n" and red.cmd("DBSIZE") == 0)
    red.cmd("SELECT", "1")
    r.check("cross flush_all leaves database 1", red.cmd("GET", "db1key") == b"x")
    red.cmd("DEL", "db1key")
    red.cmd("SELECT", "0")
    mc(b"set fl 0 0 1\r\nx\r\n")
    red.cmd("SET", "rf", "y")
    mc(b"flush_all 100\r\n")
    t1 = red.cmd("TTL", "fl")
    t2 = red.cmd("TTL", "rf")
    r.check("cross delayed flush_all caps the redis ttl", t1 in (99, 100) and t2 in (99, 100), "%s %s" % (t1, t2))
    mc(b"flush_all\r\n")
    r.check("cross memcached set over a redis key with ttl clears the ttl", red.cmd("SET", "tk", "v", "EX", "100") == "OK" and mc(b"set tk 0 0 1\r\nw\r\n") == b"STORED\r\n" and red.cmd("TTL", "tk") == -1)
    r.check("cross memcached commands do not change the redis port", red.cmd("PING") == "PONG")
    info = red.cmd("INFO", "stats")
    r.check("cross memcached gets count in redis keyspace stats", isinstance(info, bytes) and b"keyspace_hits:" in info)
    a = send(mport, [b"stats\r\n"])
    r.check("cross memcached curr_items counts redis keys", b"STAT curr_items 1\r\n" in a, show(a))
    r.check("cross config get memcached-port", red.cmd("CONFIG", "GET", "memcached-port") == [b"memcached-port", str(mport).encode()])
    r.check("cross config get memcached-max-item-size", red.cmd("CONFIG", "GET", "memcached-max-item-size") == [b"memcached-max-item-size", b"1048576"])
    r.check("cross config set memcached-port is refused", red.cmd("CONFIG", "SET", "memcached-port", "1").startswith("ERR CONFIG SET failed"))
    mc(b"flush_all\r\n")
    run_events(r, red, rport, mport)
    return r


def collect_events(sub):
    sub.settimeout(0.15)
    data = b""
    try:
        while True:
            d = sub.recv(65536)
            if not d:
                break
            data += d
    except socket.timeout:
        pass
    events = []
    for part in data.split(b"*4\r\n")[1:]:
        f = part.split(b"\r\n")
        if len(f) > 7:
            events.append((f[5].decode().split(":")[-1], f[7].decode()))
    return events


def run_events(r, red, rport, mport):
    mc = lambda payload: send(mport, [payload])
    old_flags = red.cmd("CONFIG", "GET", "notify-keyspace-events")[1]
    red.cmd("CONFIG", "SET", "notify-keyspace-events", "KEAm")
    sub = socket.create_connection((HOST, rport))
    sub.sendall(resp(["PSUBSCRIBE", "__keyevent@0__:*"]))
    collect_events(sub)
    cases = [
        ("set new", b"set ek 0 0 1\r\nx\r\n", [("set", "ek")]),
        ("set with exptime", b"set ek 0 100 1\r\nx\r\n", [("set", "ek"), ("expire", "ek")]),
        ("set with negative exptime", b"set ek 0 -1 1\r\nx\r\n", [("set", "ek"), ("expire", "ek"), ("expired", "ek")]),
        ("add new", b"add ek 0 0 1\r\nx\r\n", [("set", "ek")]),
        ("add existing", b"add ek 0 0 1\r\ny\r\n", []),
        ("replace", b"replace ek 0 0 2\r\n10\r\n", [("set", "ek")]),
        ("replace missing", b"replace nokey 0 0 1\r\nx\r\n", []),
        ("append", b"append ek 0 0 1\r\n0\r\n", [("append", "ek")]),
        ("prepend", b"prepend ek 0 0 1\r\n1\r\n", [("append", "ek")]),
        ("incr", b"incr ek 5\r\n", [("incrby", "ek")]),
        ("decr", b"decr ek 5\r\n", [("incrby", "ek")]),
        ("touch", b"touch ek 100\r\n", [("expire", "ek")]),
        ("touch zero persists", b"touch ek 0\r\n", [("persist", "ek")]),
        ("touch zero without ttl", b"touch ek 0\r\n", []),
        ("gat", b"gat 100 ek\r\n", [("expire", "ek")]),
        ("get miss", b"get nokey\r\n", [("keymiss", "nokey")]),
        ("touch negative", b"touch ek -1\r\n", [("del", "ek")]),
        ("delete", b"set ek 0 0 1\r\nx\r\ndelete ek\r\n", [("set", "ek"), ("del", "ek")]),
        ("delete missing", b"delete ek\r\n", []),
        ("flush_all", b"set ek 0 0 1\r\nx\r\nflush_all\r\n", [("set", "ek")]),
    ]
    for name, payload, want in cases:
        mc(payload)
        got = collect_events(sub)
        r.check("events " + name, got == want, "want=%r got=%r" % (want, got))
    mc(b"set ck 0 0 1\r\nx\r\ngets ck\r\n")
    m = re.search(rb"VALUE ck 0 1 (\d+)", mc(b"gets ck\r\n"))
    if m:
        mc(b"cas ck 0 0 1 " + m.group(1) + b"\r\ny\r\n")
        collect_events(sub)
        mc(b"set ck 0 0 1\r\nx\r\n")
        m2 = re.search(rb"VALUE ck 0 1 (\d+)", mc(b"gets ck\r\n"))
        collect_events(sub)
        mc(b"cas ck 0 0 1 " + m2.group(1) + b"\r\nz\r\n")
        got = collect_events(sub)
        r.check("events cas", got == [("set", "ck")], repr(got))
    sub.close()
    red.cmd("CONFIG", "SET", "notify-keyspace-events", old_flags.decode() if isinstance(old_flags, bytes) else old_flags)
    trk = socket.create_connection((HOST, rport))
    trk.sendall(resp(["HELLO", "3"]))
    drain(trk, 0.2)
    trk.sendall(resp(["CLIENT", "TRACKING", "ON"]))
    drain(trk, 0.2)
    mc(b"set tk 0 0 1\r\nx\r\n")
    trk.sendall(resp(["GET", "tk"]))
    drain(trk, 0.2)
    mc(b"set tk 0 0 1\r\ny\r\n")
    pushed = drain(trk, 0.3)
    r.check("tracking invalidates on memcached set", b"invalidate" in pushed and b"tk" in pushed, show(pushed))
    trk.sendall(resp(["GET", "tk"]))
    drain(trk, 0.2)
    mc(b"delete tk\r\n")
    pushed = drain(trk, 0.3)
    r.check("tracking invalidates on memcached delete", b"invalidate" in pushed and b"tk" in pushed, show(pushed))
    trk.sendall(resp(["SET", "tk", "v"]))
    drain(trk, 0.2)
    trk.sendall(resp(["GET", "tk"]))
    drain(trk, 0.2)
    mc(b"flush_all\r\n")
    pushed = drain(trk, 0.3)
    r.check("tracking invalidates on memcached flush_all", b"invalidate" in pushed, show(pushed))
    trk.close()
    for name, payload in [("set", b"set wk 0 0 1\r\ny\r\n"), ("touch", b"touch wk 50\r\n"), ("incr", b"incr wk 1\r\n"), ("delete", b"delete wk\r\n"), ("flush_all", b"flush_all\r\n")]:
        mc(b"set wk 0 0 1\r\n1\r\n")
        w = Redis(rport)
        w.cmd("WATCH", "wk")
        w.cmd("MULTI")
        w.cmd("SET", "other", "1")
        mc(payload)
        r.check("watch aborts on memcached " + name, w.cmd("EXEC") is None)
        w.s.close()
    w = Redis(rport)
    mc(b"set wk 0 0 1\r\n1\r\n")
    w.cmd("WATCH", "wk")
    w.cmd("MULTI")
    w.cmd("SET", "other", "1")
    mc(b"get wk\r\n")
    r.check("watch survives a memcached get", w.cmd("EXEC") == ["OK"])
    w.s.close()
    red.cmd("DEL", "other")
    mc(b"flush_all\r\n")


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "compare":
        rep = run_compare(int(sys.argv[2]), int(sys.argv[3]))
    else:
        rep = run_cross(int(sys.argv[2]), int(sys.argv[3]))
    print("passed: %d failed: %d" % (rep.passed, rep.failed))
