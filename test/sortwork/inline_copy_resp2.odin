package sortwork

INLINE_COPY_RESP2 :: `# COPY observations, Redis 7.4.11, protocol 2, keyspace events KEA

## basics
SET s hello => +OK
    events: __keyspace@0__:s set | __keyevent@0__:set s
COPY s s2 => :1
    events: __keyspace@0__:s2 copy_to | __keyevent@0__:copy_to s2
GET s2 => "hello"
COPY s s2 => :0
SET s changed => +OK
    events: __keyspace@0__:s set | __keyevent@0__:set s
GET s2 => "hello"
COPY s s2 REPLACE => :1
    events: __keyspace@0__:s2 copy_to | __keyevent@0__:copy_to s2
GET s2 => "changed"
COPY s s2 replace => :1
    events: __keyspace@0__:s2 copy_to | __keyevent@0__:copy_to s2
COPY missing x => :0
EXISTS x => :0
COPY missing s2 => :0
GET s2 => "changed"
COPY missing s2 REPLACE => :0
GET s2 => "changed"
COPY s s => -ERR source and destination objects are the same
COPY s s REPLACE => -ERR source and destination objects are the same
COPY missing missing => -ERR source and destination objects are the same
COPY s s3 BOGUS => -ERR syntax error
COPY s s3 REPLACE REPLACE => :1
    events: __keyspace@0__:s3 copy_to | __keyevent@0__:copy_to s3
COPY s s3 DB => -ERR syntax error
COPY s s3 DB abc => -ERR value is not an integer or out of range
COPY s s3 DB -1 => -ERR DB index is out of range
COPY s s3 DB 16 => -ERR DB index is out of range
COPY s s3 DB 9223372036854775807 => -ERR value is out of range, value must between -2147483648 and 2147483647
COPY s s3 DB 9223372036854775808 => -ERR value is not an integer or out of range
COPY s s3 DB 1 DB 2 => :1
    events: __keyspace@2__:s3 copy_to | __keyevent@2__:copy_to s3
COPY s s3 DB 1 BOGUS => -ERR syntax error
COPY s s3 BOGUS DB abc => -ERR syntax error
COPY s s3 DB abc BOGUS => -ERR value is not an integer or out of range
COPY s => -ERR wrong number of arguments for 'copy' command
COPY => -ERR wrong number of arguments for 'copy' command
EXISTS s3 => :1
COPY missing s3 DB abc => -ERR value is not an integer or out of range
COPY missing s3 DB 99 => -ERR DB index is out of range
COPY missing s3 BOGUS => -ERR syntax error
COPY missing missing DB 1 => :0

## databases
COPY s s DB 1 => :1
    events: __keyspace@1__:s copy_to | __keyevent@1__:copy_to s
SELECT 1 => +OK
GET s => "changed"
COPY s s DB 1 => -ERR source and destination objects are the same
COPY s s DB 0 => :0
COPY s back DB 0 => :1
    events: __keyspace@0__:back copy_to | __keyevent@0__:copy_to back
SELECT 0 => +OK
GET back => "changed"
COPY s s DB 0 => -ERR source and destination objects are the same
COPY s s DB 0 REPLACE => -ERR source and destination objects are the same
COPY s s DB 1 REPLACE => :1
    events: __keyspace@1__:s copy_to | __keyevent@1__:copy_to s
SELECT 1 => +OK
GET s => "changed"
SELECT 0 => +OK
COPY s tgt DB 15 => :1
    events: __keyspace@15__:tgt copy_to | __keyevent@15__:copy_to tgt
SELECT 15 => +OK
GET tgt => "changed"
SELECT 0 => +OK
COPY s tgt DB 15 => :0
COPY s tgt DB 15 REPLACE => :1
    events: __keyspace@15__:tgt copy_to | __keyevent@15__:copy_to tgt

## expiry and access clock
SET e v EX 100 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e | __keyspace@0__:e expire | __keyevent@0__:expire e
COPY e e2 => :1
    events: __keyspace@0__:e2 copy_to | __keyevent@0__:copy_to e2
TTL e2 => integer within [98, 100]
TTL e => integer within [98, 100]
SET ne v => +OK
    events: __keyspace@0__:ne set | __keyevent@0__:set ne
COPY ne e2 REPLACE => :1
    events: __keyspace@0__:e2 copy_to | __keyevent@0__:copy_to e2
TTL e2 => :-1
SET e3 v PX 1 => +OK
    events: __keyspace@0__:e3 set | __keyevent@0__:set e3 | __keyspace@0__:e3 expire | __keyevent@0__:expire e3 | __keyspace@0__:e3 expired | __keyevent@0__:expired e3
COPY e3 e4 => :0
EXISTS e4 => :0
EXISTS e3 => :0
SET idle v => +OK
    events: __keyspace@0__:idle set | __keyevent@0__:set idle
OBJECT IDLETIME idle => :0
OBJECT FREQ idle => -ERR An LFU maxmemory policy is not selected, access frequency not tracked. Please note that when switching between policies at runtime LRU and LFU data will take some time to adjust.
COPY idle idle2 => :1
    events: __keyspace@0__:idle2 copy_to | __keyevent@0__:copy_to idle2
OBJECT IDLETIME idle2 => :0
CONFIG SET maxmemory-policy allkeys-lfu => +OK
SET lfu v => +OK
    events: __keyspace@0__:lfu set | __keyevent@0__:set lfu
GET lfu => "v"
GET lfu => "v"
GET lfu => "v"
OBJECT FREQ lfu => :6
COPY lfu lfu2 => :1
    events: __keyspace@0__:lfu2 copy_to | __keyevent@0__:copy_to lfu2
OBJECT FREQ lfu2 => :5
CONFIG SET maxmemory-policy noeviction => +OK

## types
RPUSH l a b c => :3
    events: __keyspace@0__:l rpush | __keyevent@0__:rpush l
COPY l l2 => :1
    events: __keyspace@0__:l2 copy_to | __keyevent@0__:copy_to l2
LRANGE l2 0 -1 => ["a", "b", "c"]
OBJECT ENCODING l2 => "listpack"
RPUSH l d => :4
    events: __keyspace@0__:l rpush | __keyevent@0__:rpush l
LRANGE l2 0 -1 => ["a", "b", "c"]
RPUSH lbig {0..299} => :300
    events: __keyspace@0__:lbig rpush | __keyevent@0__:rpush lbig
OBJECT ENCODING lbig => "listpack"
COPY lbig lbig2 => :1
    events: __keyspace@0__:lbig2 copy_to | __keyevent@0__:copy_to lbig2
OBJECT ENCODING lbig2 => "listpack"
LLEN lbig2 => :300
LINDEX lbig2 299 => "299"
SADD st a b => :2
    events: __keyspace@0__:st sadd | __keyevent@0__:sadd st
COPY st st2 => :1
    events: __keyspace@0__:st2 copy_to | __keyevent@0__:copy_to st2
SMEMBERS st2 => ["a", "b"]
OBJECT ENCODING st2 => "listpack"
SADD sti 1 2 => :2
    events: __keyspace@0__:sti sadd | __keyevent@0__:sadd sti
COPY sti sti2 => :1
    events: __keyspace@0__:sti2 copy_to | __keyevent@0__:copy_to sti2
OBJECT ENCODING sti2 => "intset"
SMEMBERS sti2 => ["1", "2"]
SADD sbig m{0..599} => :600
    events: __keyspace@0__:sbig sadd | __keyevent@0__:sadd sbig
OBJECT ENCODING sbig => "hashtable"
COPY sbig sbig2 => :1
    events: __keyspace@0__:sbig2 copy_to | __keyevent@0__:copy_to sbig2
OBJECT ENCODING sbig2 => "hashtable"
SCARD sbig2 => :600
SISMEMBER sbig2 m599 => :1
ZADD z 1 a 2 b => :2
    events: __keyspace@0__:z zadd | __keyevent@0__:zadd z
COPY z z2 => :1
    events: __keyspace@0__:z2 copy_to | __keyevent@0__:copy_to z2
ZRANGE z2 0 -1 WITHSCORES => ["a", "1", "b", "2"]
OBJECT ENCODING z2 => "listpack"
ZADD zbig {0..299}~m{0..299} => :300
    events: __keyspace@0__:zbig zadd | __keyevent@0__:zadd zbig
OBJECT ENCODING zbig => "skiplist"
COPY zbig zbig2 => :1
    events: __keyspace@0__:zbig2 copy_to | __keyevent@0__:copy_to zbig2
OBJECT ENCODING zbig2 => "skiplist"
ZCARD zbig2 => :300
ZSCORE zbig2 m299 => "299"
ZRANK zbig2 m150 => :150
HSET h f v g w => :2
    events: __keyspace@0__:h hset | __keyevent@0__:hset h
COPY h h2 => :1
    events: __keyspace@0__:h2 copy_to | __keyevent@0__:copy_to h2
HGETALL h2 => ["f", "v", "g", "w"]
OBJECT ENCODING h2 => "listpack"
HSET hbig f{0..599}~v{0..599} => :600
    events: __keyspace@0__:hbig hset | __keyevent@0__:hset hbig
OBJECT ENCODING hbig => "hashtable"
COPY hbig hbig2 => :1
    events: __keyspace@0__:hbig2 copy_to | __keyevent@0__:copy_to hbig2
OBJECT ENCODING hbig2 => "hashtable"
HLEN hbig2 => :600
HGET hbig2 f599 => "v599"
HSET hx a 1 b 2 => :2
    events: __keyspace@0__:hx hset | __keyevent@0__:hset hx
HPEXPIRE hx 100000 FIELDS 1 a => [:1]
    events: __keyspace@0__:hx hexpire | __keyevent@0__:hexpire hx
OBJECT ENCODING hx => "listpackex"
COPY hx hx2 => :1
    events: __keyspace@0__:hx2 copy_to | __keyevent@0__:copy_to hx2
OBJECT ENCODING hx2 => "listpackex"
HPTTL hx2 FIELDS 1 a => [:99837]    ; expected within [1, 2]
HPTTL hx2 FIELDS 2 a b => [:99797, :-1]
HGETALL hx2 => ["a", "1", "b", "2"]
HSET hx a 1 b 2 => :0
    events: __keyspace@0__:hx hset | __keyevent@0__:hset hx
HPEXPIRE hx 1 FIELDS 1 a => [:1]
    events: __keyspace@0__:hx hexpire | __keyevent@0__:hexpire hx
COPY hx hx3 => :1
    events: __keyspace@0__:hx3 copy_to | __keyevent@0__:copy_to hx3 | __keyspace@0__:hx hexpired | __keyevent@0__:hexpired hx | __keyspace@0__:hx3 hexpired | __keyevent@0__:hexpired hx3
HGETALL hx3 => ["b", "2"]
HSET hxb f{0..599}~v{0..599} => :600
    events: __keyspace@0__:hxb hset | __keyevent@0__:hset hxb
HEXPIRE hxb 1000 FIELDS 2 f1 f2 => [:1, :1]
    events: __keyspace@0__:hxb hexpire | __keyevent@0__:hexpire hxb
OBJECT ENCODING hxb => "hashtable"
COPY hxb hxb2 => :1
    events: __keyspace@0__:hxb2 copy_to | __keyevent@0__:copy_to hxb2
HTTL hxb2 FIELDS 3 f1 f2 f3 => [:1000, :1000, :-1]
HLEN hxb2 => :600
SETBIT bm 100 1 => :0
    events: __keyspace@0__:bm setbit | __keyevent@0__:setbit bm
COPY bm bm2 => :1
    events: __keyspace@0__:bm2 copy_to | __keyevent@0__:copy_to bm2
BITCOUNT bm2 => :1
STRLEN bm2 => :13
PFADD hll a b c => :1
    events: __keyspace@0__:hll pfadd | __keyevent@0__:pfadd hll
COPY hll hll2 => :1
    events: __keyspace@0__:hll2 copy_to | __keyevent@0__:copy_to hll2
PFCOUNT hll2 => :3
PFADD hll2 d => :1
    events: __keyspace@0__:hll2 pfadd | __keyevent@0__:pfadd hll2
PFCOUNT hll => :3
PFCOUNT hll2 => :4
GEOADD geo 13.361389 38.115556 Palermo => :1
    events: __keyspace@0__:geo zadd | __keyevent@0__:zadd geo
COPY geo geo2 => :1
    events: __keyspace@0__:geo2 copy_to | __keyevent@0__:copy_to geo2
GEOPOS geo2 Palermo => [["13.36138933897018433", "38.11555639549629859"]]
SET int 12345 => +OK
    events: __keyspace@0__:int set | __keyevent@0__:set int
OBJECT ENCODING int => "int"
COPY int int2 => :1
    events: __keyspace@0__:int2 copy_to | __keyevent@0__:copy_to int2
OBJECT ENCODING int2 => "int"
GET int2 => "12345"
INCR int2 => :12346
    events: __keyspace@0__:int2 incrby | __keyevent@0__:incrby int2
GET int => "12345"
SET raw xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx => +OK
    events: __keyspace@0__:raw set | __keyevent@0__:set raw
OBJECT ENCODING raw => "raw"
COPY raw raw2 => :1
    events: __keyspace@0__:raw2 copy_to | __keyevent@0__:copy_to raw2
OBJECT ENCODING raw2 => "raw"
STRLEN raw2 => :100
APPEND raw2 y => :101
    events: __keyspace@0__:raw2 append | __keyevent@0__:append raw2
STRLEN raw => :100

## streams
XADD x 1-1 f v => "1-1"
    events: __keyspace@0__:x xadd | __keyevent@0__:xadd x
XADD x 2-1 f w => "2-1"
    events: __keyspace@0__:x xadd | __keyevent@0__:xadd x
XADD x 3-1 f u => "3-1"
    events: __keyspace@0__:x xadd | __keyevent@0__:xadd x
XGROUP CREATE x g1 0 => +OK
    events: __keyspace@0__:x xgroup-create | __keyevent@0__:xgroup-create x
XREADGROUP GROUP g1 alice COUNT 2 STREAMS x > => [["x", [["1-1", ["f", "v"]], ["2-1", ["f", "w"]]]]]
    events: __keyspace@0__:x xgroup-createconsumer | __keyevent@0__:xgroup-createconsumer x
XGROUP CREATE x g2 $ => +OK
    events: __keyspace@0__:x xgroup-create | __keyevent@0__:xgroup-create x
XGROUP CREATECONSUMER x g2 bob => :1
    events: __keyspace@0__:x xgroup-createconsumer | __keyevent@0__:xgroup-createconsumer x
XSETID x 3-1 ENTRIESADDED 10 MAXDELETEDID 0-5 => +OK
    events: __keyspace@0__:x xsetid | __keyevent@0__:xsetid x
XDEL x 2-1 => :1
    events: __keyspace@0__:x xdel | __keyevent@0__:xdel x
COPY x x2 => :1
    events: __keyspace@0__:x2 copy_to | __keyevent@0__:copy_to x2
XRANGE x2 - + => [["1-1", ["f", "v"]], ["3-1", ["f", "u"]]]
XLEN x2 => :2
XINFO STREAM x2 => ["length", :2, "radix-tree-keys", :1, "radix-tree-nodes", :2, "last-generated-id", "3-1", "max-deleted-entry-id", "2-1", "entries-added", :10, "recorded-first-entry-id", "1-1", "groups", :2, "first-entry", ["1-1", ["f", "v"]], "last-entry", ["3-1", ["f", "u"]]]
XINFO GROUPS x2 => [["name", "g1", "consumers", :1, "pending", :2, "last-delivered-id", "2-1", "entries-read", :2, "lag", nil], ["name", "g2", "consumers", :1, "pending", :0, "last-delivered-id", "3-1", "entries-read", nil, "lag", :0]]
XINFO CONSUMERS x2 g1 => [["name", "alice", "pending", :2, "idle", :408, "inactive", :408]]
XINFO CONSUMERS x2 g2 => [["name", "bob", "pending", :0, "idle", :368, "inactive", :-1]]
XPENDING x2 g1 => [:2, "1-1", "2-1", [["alice", "2"]]]
XPENDING x2 g1 - + 10 => [["1-1", "alice", :531, :1], ["2-1", "alice", :531, :1]]
XPENDING x g1 - + 10 => [["1-1", "alice", :571, :1], ["2-1", "alice", :571, :1]]
XACK x2 g1 1-1 => :1
XPENDING x g1 => [:2, "1-1", "2-1", [["alice", "2"]]]
XPENDING x2 g1 => [:1, "2-1", "2-1", [["alice", "1"]]]
XADD x2 4-1 f z => "4-1"
    events: __keyspace@0__:x2 xadd | __keyevent@0__:xadd x2
XLEN x => :2
XLEN x2 => :3
XREADGROUP GROUP g1 carol STREAMS x2 > => [["x2", [["3-1", ["f", "u"]], ["4-1", ["f", "z"]]]]]
    events: __keyspace@0__:x2 xgroup-createconsumer | __keyevent@0__:xgroup-createconsumer x2
XINFO CONSUMERS x g1 => [["name", "alice", "pending", :2, "idle", :896, "inactive", :896]]
XINFO STREAM x FULL => ["length", :2, "radix-tree-keys", :1, "radix-tree-nodes", :2, "last-generated-id", "3-1", "max-deleted-entry-id", "2-1", "entries-added", :10, "recorded-first-entry-id", "1-1", "entries", [["1-1", ["f", "v"]], ["3-1", ["f", "u"]]], "groups", [["name", "g1", "last-delivered-id", "2-1", "entries-read", :2, "lag", nil, "pel-count", :2, "pending", [["1-1", "alice", :1793177742754, :1], ["2-1", "alice", :1793177742754, :1]], "consumers", [["name", "alice", "seen-time", :1793177742754, "active-time", :1793177742754, "pel-count", :2, "pending", [["1-1", :1793177742754, :1], ["2-1", :1793177742754, :1]]]]], ["name", "g2", "last-delivered-id", "3-1", "entries-read", nil, "lag", :0, "pel-count", :0, "pending", [], "consumers", [["name", "bob", "seen-time", :1793177742835, "active-time", :-1, "pel-count", :0, "pending", []]]]]]
XINFO STREAM x2 FULL => ["length", :3, "radix-tree-keys", :1, "radix-tree-nodes", :2, "last-generated-id", "4-1", "max-deleted-entry-id", "2-1", "entries-added", :11, "recorded-first-entry-id", "1-1", "entries", [["1-1", ["f", "v"]], ["3-1", ["f", "u"]], ["4-1", ["f", "z"]]], "groups", [["name", "g1", "last-delivered-id", "4-1", "entries-read", :11, "lag", :0, "pel-count", :3, "pending", [["2-1", "alice", :1793177742754, :1], ["3-1", "carol", :1793177743609, :1], ["4-1", "carol", :1793177743609, :1]], "consumers", [["name", "alice", "seen-time", :1793177742754, "active-time", :1793177742754, "pel-count", :1, "pending", [["2-1", :1793177742754, :1]]], ["name", "carol", "seen-time", :1793177743609, "active-time", :1793177743609, "pel-count", :2, "pending", [["3-1", :1793177743609, :1], ["4-1", :1793177743609, :1]]]]], ["name", "g2", "last-delivered-id", "3-1", "entries-read", nil, "lag", nil, "pel-count", :0, "pending", [], "consumers", [["name", "bob", "seen-time", :1793177742835, "active-time", :-1, "pel-count", :0, "pending", []]]]]]
XADD xe MAXLEN 0 * f v => "1793177743773-0"
    events: __keyspace@0__:xe xadd | __keyevent@0__:xadd xe | __keyspace@0__:xe xtrim | __keyevent@0__:xtrim xe
XLEN xe => :0
COPY xe xe2 => :1
    events: __keyspace@0__:xe2 copy_to | __keyevent@0__:copy_to xe2
XLEN xe2 => :0
XINFO STREAM xe2 => ["length", :0, "radix-tree-keys", :0, "radix-tree-nodes", :1, "last-generated-id", "1793177743773-0", "max-deleted-entry-id", "0-0", "entries-added", :1, "recorded-first-entry-id", "0-0", "groups", :0, "first-entry", nil, "last-entry", nil]
XADD xb * f v => "1793177743977-0"
    events: __keyspace@0__:xb xadd | __keyevent@0__:xadd xb
XGROUP CREATE xb g 0 => +OK
    events: __keyspace@0__:xb xgroup-create | __keyevent@0__:xgroup-create xb
COPY xb xb2 => :1
    events: __keyspace@0__:xb2 copy_to | __keyevent@0__:copy_to xb2
XINFO GROUPS xb2 => [["name", "g", "consumers", :0, "pending", :0, "last-delivered-id", "0-0", "entries-read", nil, "lag", :1]]
DEL x2 xb2 xe2 => :3
    events: __keyspace@0__:x2 del | __keyevent@0__:del x2 | __keyspace@0__:xb2 del | __keyevent@0__:del xb2 | __keyspace@0__:xe2 del | __keyevent@0__:del xe2
COPY x x2 REPLACE => :1
    events: __keyspace@0__:x2 copy_to | __keyevent@0__:copy_to x2
XINFO GROUPS x2 => [["name", "g1", "consumers", :1, "pending", :2, "last-delivered-id", "2-1", "entries-read", :2, "lag", nil], ["name", "g2", "consumers", :1, "pending", :0, "last-delivered-id", "3-1", "entries-read", nil, "lag", :0]]

## replace semantics and notifications
SET a 1 => +OK
    events: __keyspace@0__:a set | __keyevent@0__:set a
RPUSH b x => :1
    events: __keyspace@0__:b rpush | __keyevent@0__:rpush b
COPY a b => :0
COPY a b REPLACE => :1
    events: __keyspace@0__:b copy_to | __keyevent@0__:copy_to b
TYPE b => +string
GET b => "1"
SET c v EX 100 => +OK
    events: __keyspace@0__:c set | __keyevent@0__:set c | __keyspace@0__:c expire | __keyevent@0__:expire c
COPY a c REPLACE => :1
    events: __keyspace@0__:c copy_to | __keyevent@0__:copy_to c
TTL c => :-1
COPY l l3 => :1
    events: __keyspace@0__:l3 copy_to | __keyevent@0__:copy_to l3
COPY l l3 REPLACE => :1
    events: __keyspace@0__:l3 copy_to | __keyevent@0__:copy_to l3
COPY l l3 DB 2 => :1
    events: __keyspace@2__:l3 copy_to | __keyevent@2__:copy_to l3
COPY l l3 DB 2 REPLACE => :1
    events: __keyspace@2__:l3 copy_to | __keyevent@2__:copy_to l3
SELECT 2 => +OK
LRANGE l3 0 -1 => ["a", "b", "c", "d"]
SELECT 0 => +OK
DBSIZE => :52
SWAPDB 0 3 => +OK
DBSIZE => :0
SWAPDB 0 3 => +OK
DBSIZE => :52
COPY a a2 DB 0 => :1
    events: __keyspace@0__:a2 copy_to | __keyevent@0__:copy_to a2
COPY a a DB 0 => -ERR source and destination objects are the same
WATCH wk => +OK
COPY a wk => :1
    events: __keyspace@0__:wk copy_to | __keyevent@0__:copy_to wk
MULTI => +OK
COPY a wk2 => +QUEUED
EXEC => nil
UNWATCH => +OK
MULTI => +OK
COPY a wk3 => +QUEUED
COPY a wk3 => +QUEUED
COPY a a => +QUEUED
EXEC => [:1, :0, -ERR source and destination objects are the same]
    events: __keyspace@0__:wk3 copy_to | __keyevent@0__:copy_to wk3
MULTI => +OK
COPY a x4 BOGUS => +QUEUED
EXEC => [-ERR syntax error]

## memory and maxmemory
CONFIG SET maxmemory 1 => +OK
COPY a mm => -OOM command not allowed when used memory > 'maxmemory'.
EXISTS mm => :0
CONFIG SET maxmemory 0 => +OK
COPY a mm => :1
    events: __keyspace@0__:mm copy_to | __keyevent@0__:copy_to mm
DBSIZE => :56
`
