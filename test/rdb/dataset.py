import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen
import resp

T = 4102444800000


def build(c):
    c.check("FLUSHALL")
    c.check("DEBUG", "QUICKLIST-PACKED-THRESHOLD", "0")
    c.check("SELECT", 0)
    strings = {
        "s:int:shared": b"42",
        "s:int:small": b"-7",
        "s:int:32": b"2147483647",
        "s:int:33": b"2147483648",
        "s:int:64": b"9223372036854775807",
        "s:int:min": b"-9223372036854775808",
        "s:lead0": b"007",
        "s:embstr": b"hello world",
        "s:44": b"e" * 44,
        "s:45": gen.gen("text", 45, 45),
        "s:21": b"z" * 21,
        "s:20": b"y" * 20,
        "s:raw": gen.gen("mixed", 3, 100),
        "s:lzf:run": b"a" * 500,
        "s:lzf:text": gen.gen("text", 11, 2000),
        "s:lzf:mixed": gen.gen("mixed", 12, 20000),
        "s:rand": gen.gen("rand", 13, 300),
        "s:big": gen.gen("period", 14, 300000),
        "s:empty": b"",
        "s:bin": bytes(range(256)),
        b"\x00\xffbinary\r\nkey": b"binary key",
        "12345": b"numeric key",
        "k" * 100: b"long compressible key",
    }
    for k, v in strings.items():
        c.check("SET", k, v)
    c.check("SET", "s:append", "12")
    c.check("APPEND", "s:append", "34")
    c.check("SET", "s:setrange", "abc")
    c.check("SETRANGE", "s:setrange", 10, "xyz")
    c.check("SET", "s:incr", "10")
    c.check("INCRBY", "s:incr", 5000000000)
    for i, k in enumerate(["s:int:shared", "s:embstr", "s:lzf:text", "s:rand"]):
        c.check("SET", k + ":ttl", strings[k])
        c.check("PEXPIREAT", k + ":ttl", T + i)
    c.check("RPUSH", "l:lp", "a", "b", "1", "2", "-3", "hello", "4294967296")
    c.check("RPUSH", "l:lp:ttl", "x", "y", "z")
    c.check("PEXPIREAT", "l:lp:ttl", T + 10)
    c.check("RPUSH", "l:ql", *[str(i) for i in range(2000)])
    c.check("RPUSH", "l:ql:strings", *[("member-%d-" % i) * 3 for i in range(1500)])
    c.check("RPUSH", "l:ql:big", *[gen.gen("text", i, 100) for i in range(400)])
    c.check("RPUSH", "l:ql:trim", *[str(i * 7) for i in range(3000)])
    c.check("LTRIM", "l:ql:trim", 100, 2500)
    c.check("LREM", "l:ql:trim", 0, "700")
    c.check("LPUSH", "l:ql:lpush", *[("v%d" % i) for i in range(1000)])
    c.check("RPUSH", "l:ql:ttl", *[str(i) for i in range(1000)])
    c.check("PEXPIREAT", "l:ql:ttl", T + 11)
    c.check("DEBUG", "QUICKLIST-PACKED-THRESHOLD", "100")
    c.check("RPUSH", "l:plain", "small", gen.gen("text", 99, 200), "tiny", gen.gen("rand", 98, 150), gen.gen("run", 1, 5000), "last")
    c.check("RPUSH", "l:plain:only", gen.gen("text", 97, 300))
    c.check("DEBUG", "QUICKLIST-PACKED-THRESHOLD", "0")
    c.check("SADD", "set:intset", *[str(i) for i in range(-50, 50)])
    c.check("SADD", "set:intset32", "70000", "-70000", "1")
    c.check("SADD", "set:intset64", "5000000000", "-5000000000", "1")
    c.check("SADD", "set:intset:ttl", "1", "2", "3")
    c.check("PEXPIREAT", "set:intset:ttl", T + 20)
    c.check("SADD", "set:lp", "a", "b", "c", "1", "2")
    c.check("SADD", "set:lp:ttl", "x", "y")
    c.check("PEXPIREAT", "set:lp:ttl", T + 21)
    c.check("SADD", "set:ht:many", *[("m%d" % i) for i in range(300)])
    c.check("SADD", "set:ht:long", "short", "L" * 100)
    c.check("SADD", "set:ht:ints", *[str(i) for i in range(600)])
    c.check("SADD", "set:ht:ttl", *[("t%d" % i) for i in range(200)])
    c.check("PEXPIREAT", "set:ht:ttl", T + 22)
    c.check("ZADD", "z:lp", 1, "a", 2.5, "b", -3, "c", 100, "d", 0.1, "e")
    c.check("ZADD", "z:lp:inf", "inf", "pinf", "-inf", "ninf", 0, "zero", 1e300, "huge", -1e-300, "tiny")
    c.check("ZADD", "z:lp:ints", 1, "1", 2, "2", 3, "300000")
    c.check("ZADD", "z:lp:ttl", 1, "a", 2, "b")
    c.check("PEXPIREAT", "z:lp:ttl", T + 30)
    args = []
    for i in range(300):
        args += [i * 0.5 - 17, "member:%d" % i]
    c.check("ZADD", "z:sl:many", *args)
    c.check("ZADD", "z:sl:long", 1, "short", 2, "S" * 100)
    c.check("ZADD", "z:sl:scores", "inf", "pinf", "-inf", "ninf", 0.1, "a", 1e-300, "b", 123456789.123, "c", *[x for i in range(130) for x in (i, "f%d" % i)])
    c.check("ZADD", "z:sl:ttl", *[x for i in range(200) for x in (i, "t%d" % i)])
    c.check("PEXPIREAT", "z:sl:ttl", T + 31)
    c.check("HSET", "h:lp", "f1", "v1", "f2", "v2", "n", "123", "neg", "-5")
    c.check("HSET", "h:lp:ttl", "a", "1")
    c.check("PEXPIREAT", "h:lp:ttl", T + 40)
    c.check("HSET", "h:lpex", "f1", "v1", "f2", "v2", "f3", "v3", "f4", "4", "f5", "v5")
    c.check("HPEXPIREAT", "h:lpex", T + 41, "FIELDS", 2, "f4", "f2")
    c.check("HPEXPIREAT", "h:lpex", T + 42, "FIELDS", 1, "f1")
    c.check("HSET", "h:lpex:none", "a", "1", "b", "2")
    c.check("HPEXPIREAT", "h:lpex:none", T + 43, "FIELDS", 1, "a")
    c.check("HPERSIST", "h:lpex:none", "FIELDS", 1, "a")
    c.check("HSET", "h:lpex:ttl", "a", "1", "b", "2")
    c.check("HPEXPIREAT", "h:lpex:ttl", T + 44, "FIELDS", 1, "b")
    c.check("PEXPIREAT", "h:lpex:ttl", T + 45)
    c.check("HSET", "h:ht:many", *[x for i in range(600) for x in ("field:%d" % i, "value:%d" % i)])
    c.check("HSET", "h:ht:long", "short", "1", "long", "V" * 100)
    c.check("HSET", "h:ht:ttl", *[x for i in range(100) for x in ("k%d" % i, gen.gen("text", i, 80))])
    c.check("PEXPIREAT", "h:ht:ttl", T + 46)
    c.check("HSET", "h:ht:ex", *[x for i in range(600) for x in ("e%d" % i, str(i))])
    c.check("HPEXPIREAT", "h:ht:ex", T + 47, "FIELDS", 3, "e1", "e2", "e3")
    c.check("HPEXPIREAT", "h:ht:ex", T + 500000, "FIELDS", 1, "e500")
    c.check("HSET", "h:ht:ex:long", "a", "1", "b", "B" * 100)
    c.check("HPEXPIREAT", "h:ht:ex:long", T + 48, "FIELDS", 1, "b")
    c.check("HSET", "h:ht:ex:persisted", *[x for i in range(600) for x in ("p%d" % i, str(i))])
    c.check("HPEXPIREAT", "h:ht:ex:persisted", T + 49, "FIELDS", 1, "p1")
    c.check("HPERSIST", "h:ht:ex:persisted", "FIELDS", 1, "p1")
    for i in range(1, 251):
        c.check("XADD", "st:nodes", "%d-%d" % (i, i % 3), "f", "v%d" % i, "g", str(i))
    c.check("XADD", "st:nodes", "300-0", "other", "layout", "third", "x")
    for i in range(40):
        c.check("XADD", "st:big", "%d-1" % (1000 + i), "payload", gen.gen("text", 500 + i, 300), "n", str(i))
    for i in range(1, 21):
        c.check("XADD", "st:groups", "%d-0" % i, "k", "v%d" % i)
    c.check("XDEL", "st:groups", "5-0", "6-0")
    c.check("XGROUP", "CREATE", "st:groups", "readers", "0")
    c.check("XGROUP", "CREATE", "st:groups", "late", "$")
    c.check("XGROUP", "CREATE", "st:groups", "counted", "10-0", "ENTRIESREAD", "8")
    c.check("XGROUP", "CREATE", "st:groups", "g" * 40, "0")
    c.check("XREADGROUP", "GROUP", "readers", "alice", "COUNT", "4", "STREAMS", "st:groups", ">")
    c.check("XREADGROUP", "GROUP", "readers", "bob", "COUNT", "3", "STREAMS", "st:groups", ">")
    c.check("XREADGROUP", "GROUP", "counted", "carol" * 10, "COUNT", "2", "STREAMS", "st:groups", ">")
    c.check("XACK", "st:groups", "readers", "1-0")
    c.check("XCLAIM", "st:groups", "readers", "bob", "0", "2-0", "TIME", "4102444800000", "RETRYCOUNT", "7")
    c.check("XGROUP", "CREATECONSUMER", "st:groups", "readers", "idle")
    c.check("XADD", "st:empty", "1-1", "a", "1")
    c.check("XDEL", "st:empty", "1-1")
    c.check("XGROUP", "CREATE", "st:empty", "g", "$")
    for i in range(30):
        c.check("XADD", "st:trim", "%d-0" % (100 + i), "a", str(i))
    c.check("XTRIM", "st:trim", "MAXLEN", "10")
    c.check("XADD", "st:ttl", "5-5", "a", "b")
    c.check("PEXPIREAT", "st:ttl", T + 60)
    c.check("SELECT", 1)
    c.check("XADD", "db1:st", "1-1", "x", "y")
    c.check("XGROUP", "CREATE", "db1:st", "g", "0")
    c.check("XREADGROUP", "GROUP", "g", "c", "STREAMS", "db1:st", ">")
    c.check("SET", "db1:s", "string in db 1")
    c.check("PEXPIREAT", "db1:s", T + 100)
    c.check("RPUSH", "db1:l", "a", "b")
    c.check("SADD", "db1:set", "1", "2")
    c.check("ZADD", "db1:z", 1, "a")
    c.check("HSET", "db1:h", "f", "v")
    c.check("HPEXPIREAT", "db1:h", T + 101, "FIELDS", 1, "f")
    c.check("SELECT", 5)
    c.check("SET", "db5:s", gen.gen("text", 5, 1000))
    c.check("HSET", "db5:h", *[x for i in range(700) for x in ("x%d" % i, "y%d" % i)])
    c.check("PEXPIREAT", "db5:h", T + 102)
    c.check("SELECT", 15)
    c.check("SET", "db15:only", "last db")
    c.check("SELECT", 0)


if __name__ == "__main__":
    client = resp.Client(int(sys.argv[1]))
    build(client)
    print("dataset built on port %s" % sys.argv[1])
