package stringwork

INLINE_STRING_CASES := `

## SET and GET basics
SET k v => +OK
    events: __keyspace@0__:k set | __keyevent@0__:set k
GET k => "v"
GET missing => nil
SET k "" => +OK
    events: __keyspace@0__:k set | __keyevent@0__:set k
GET k => ""
STRLEN k => :0
SET k "with space and	tab" => +OK
    events: __keyspace@0__:k set | __keyevent@0__:set k
GET k => hex[18]=7769746820737061636520616e6409746162
RPUSH l a => :1
    events: __keyspace@0__:l rpush | __keyevent@0__:rpush l
GET l => -WRONGTYPE Operation against a key holding the wrong kind of value
SET l v => +OK
    events: __keyspace@0__:l set | __keyevent@0__:set l
TYPE l => +string
GET l => "v"
SET => -ERR wrong number of arguments for 'set' command
SET k => -ERR wrong number of arguments for 'set' command
GET => -ERR wrong number of arguments for 'get' command
GET a b => -ERR wrong number of arguments for 'get' command

## SET conditions and GET option
DEL k => :1
    events: __keyspace@0__:k del | __keyevent@0__:del k
SET k v1 NX => +OK
    events: __keyspace@0__:k set | __keyevent@0__:set k
SET k v2 NX => nil
GET k => "v1"
SET k v3 XX => +OK
    events: __keyspace@0__:k set | __keyevent@0__:set k
GET k => "v3"
SET nokey v XX => nil
EXISTS nokey => :0
SET k v4 GET => "v3"
    events: __keyspace@0__:k set | __keyevent@0__:set k
SET nokey v GET => nil
    events: __keyspace@0__:nokey set | __keyevent@0__:set nokey
GET nokey => "v"
SET k v5 NX GET => "v4"
GET k => "v4"
SET nokey2 v NX GET => nil
    events: __keyspace@0__:nokey2 set | __keyevent@0__:set nokey2
GET nokey2 => "v"
SET k v6 XX GET => "v4"
    events: __keyspace@0__:k set | __keyevent@0__:set k
SET nokey3 v XX GET => nil
EXISTS nokey3 => :0
RPUSH l2 a => :1
    events: __keyspace@0__:l2 rpush | __keyevent@0__:rpush l2
SET l2 v GET => -WRONGTYPE Operation against a key holding the wrong kind of value
SET l2 v NX GET => -WRONGTYPE Operation against a key holding the wrong kind of value
TYPE l2 => +list
SET k v NX XX => -ERR syntax error
SET k v XX NX => -ERR syntax error
SET k v nx => nil
SET k v Get => "v6"
    events: __keyspace@0__:k set | __keyevent@0__:set k
SET k v BOGUS => -ERR syntax error
SET k v GET GET => "v"
    events: __keyspace@0__:k set | __keyevent@0__:set k
SET k v NX NX => nil

## SET expiry options
SET e v EX 100 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e | __keyspace@0__:e expire | __keyevent@0__:expire e
TTL e => integer within [99, 100]
SET e v PX 100000 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e | __keyspace@0__:e expire | __keyevent@0__:expire e
PTTL e => integer within [99000, 100000]
SET e v EXAT @+200 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e | __keyspace@0__:e expire | __keyevent@0__:expire e
TTL e => integer within [198, 200]
SET e v PXAT @+300000 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e | __keyspace@0__:e expire | __keyevent@0__:expire e
PTTL e => integer within [298000, 300000]
SET e v2 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e
TTL e => :-1
SET e v EX 100 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e | __keyspace@0__:e expire | __keyevent@0__:expire e
SET e v3 KEEPTTL => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e
TTL e => integer within [98, 100]
GET e => "v3"
SET e v4 KEEPTTL GET => "v3"
    events: __keyspace@0__:e set | __keyevent@0__:set e
TTL e => integer within [98, 100]
SET e v EX 0 => -ERR invalid expire time in 'set' command
SET e v EX -1 => -ERR invalid expire time in 'set' command
SET e v PX 0 => -ERR invalid expire time in 'set' command
SET e v EX abc => -ERR value is not an integer or out of range
SET e v EX 1.5 => -ERR value is not an integer or out of range
SET e v EX 9223372036854775807 => -ERR invalid expire time in 'set' command
SET e v EX 9223372036854775808 => -ERR value is not an integer or out of range
SET e v EX 9223372036854775 => -ERR invalid expire time in 'set' command
SET e v EX 9223372036854776 => -ERR invalid expire time in 'set' command
SET e v PX 9223372036854775807 => -ERR invalid expire time in 'set' command
SET e v EXAT 0 => -ERR invalid expire time in 'set' command
SET e v EXAT -5 => -ERR invalid expire time in 'set' command
SET e v PXAT 9223372036854775807 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e | __keyspace@0__:e expire | __keyevent@0__:expire e
SET e v EXAT 9223372036854775807 => -ERR invalid expire time in 'set' command
SET e v EX => -ERR syntax error
SET e v EX 10 PX 100 => -ERR syntax error
SET e v EX 10 EXAT 100 => -ERR syntax error
SET e v EX 10 KEEPTTL => -ERR syntax error
SET e v KEEPTTL PX 100 => -ERR syntax error
SET e v EX 10 EX 20 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e | __keyspace@0__:e expire | __keyevent@0__:expire e
SET e v ex 10 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e | __keyspace@0__:e expire | __keyevent@0__:expire e
TTL e => integer within [9, 10]
SET past v EXAT 1 => +OK
    events: __keyspace@0__:past set | __keyevent@0__:set past | __keyspace@0__:past expire | __keyevent@0__:expire past
EXISTS past => :0
    events: __keyspace@0__:past expired | __keyevent@0__:expired past
SET past v PXAT @-5000 => +OK
    events: __keyspace@0__:past set | __keyevent@0__:set past | __keyspace@0__:past expire | __keyevent@0__:expire past
EXISTS past => :0
    events: __keyspace@0__:past expired | __keyevent@0__:expired past
SET past v => +OK
    events: __keyspace@0__:past set | __keyevent@0__:set past
SET past v2 PXAT @-5000 GET => "v"
    events: __keyspace@0__:past set | __keyevent@0__:set past | __keyspace@0__:past expire | __keyevent@0__:expire past
EXISTS past => :0
    events: __keyspace@0__:past expired | __keyevent@0__:expired past
SET past v EX 10 GET => nil
    events: __keyspace@0__:past set | __keyevent@0__:set past | __keyspace@0__:past expire | __keyevent@0__:expire past
SET past v EX 0 GET => -ERR invalid expire time in 'set' command
SET past v NX EX 0 => -ERR invalid expire time in 'set' command
SET past v EX abc NX XX => -ERR syntax error
SET past v BOGUS EX abc => -ERR syntax error
SET past v EX abc BOGUS => -ERR syntax error
SET past v EX 0 BOGUS => -ERR syntax error
SET past v NX XX EX 0 => -ERR syntax error
RPUSH l3 a => :1
    events: __keyspace@0__:l3 rpush | __keyevent@0__:rpush l3
SET l3 v EX 0 => -ERR invalid expire time in 'set' command
SET l3 v EX 10 GET => -WRONGTYPE Operation against a key holding the wrong kind of value
TYPE l3 => +list

## GETEX
SET g v => +OK
    events: __keyspace@0__:g set | __keyevent@0__:set g
GETEX g => "v"
TTL g => :-1
GETEX g EX 100 => "v"
    events: __keyspace@0__:g expire | __keyevent@0__:expire g
TTL g => integer within [99, 100]
GETEX g PX 200000 => "v"
    events: __keyspace@0__:g expire | __keyevent@0__:expire g
PTTL g => integer within [199000, 200000]
GETEX g EXAT @+300 => "v"
    events: __keyspace@0__:g expire | __keyevent@0__:expire g
TTL g => integer within [298, 300]
GETEX g PXAT @+400000 => "v"
    events: __keyspace@0__:g expire | __keyevent@0__:expire g
PTTL g => integer within [398000, 400000]
GETEX g PERSIST => "v"
    events: __keyspace@0__:g persist | __keyevent@0__:persist g
TTL g => :-1
GETEX g PERSIST => "v"
GETEX g EX 0 => -ERR invalid expire time in 'getex' command
GETEX g EX -1 => -ERR invalid expire time in 'getex' command
GETEX g EX abc => -ERR value is not an integer or out of range
GETEX g EX 9223372036854775807 => -ERR invalid expire time in 'getex' command
GETEX g EX 9223372036854775 => -ERR invalid expire time in 'getex' command
GETEX g EX 9223372036854776 => -ERR invalid expire time in 'getex' command
GETEX g PX 9223372036854775807 => -ERR invalid expire time in 'getex' command
GETEX g EXAT 9223372036854775807 => -ERR invalid expire time in 'getex' command
GETEX g EX => -ERR syntax error
GETEX g EX 10 PX 100 => -ERR syntax error
GETEX g EX 10 PERSIST => -ERR syntax error
GETEX g PERSIST EX 10 => -ERR syntax error
GETEX g BOGUS => -ERR syntax error
GETEX g NX => -ERR syntax error
GETEX g KEEPTTL => -ERR syntax error
GETEX g ex 50 => "v"
    events: __keyspace@0__:g expire | __keyevent@0__:expire g
TTL g => integer within [49, 50]
GETEX g EX 10 EX 20 => "v"
    events: __keyspace@0__:g expire | __keyevent@0__:expire g
TTL g => integer within [19, 20]
GETEX missing => nil
GETEX missing EX 10 => nil
EXISTS missing => :0
GETEX missing EX abc => nil
GETEX missing BOGUS => -ERR syntax error
RPUSH gl a => :1
    events: __keyspace@0__:gl rpush | __keyevent@0__:rpush gl
GETEX gl => -WRONGTYPE Operation against a key holding the wrong kind of value
GETEX gl EX 10 => -WRONGTYPE Operation against a key holding the wrong kind of value
GETEX gl EX abc => -WRONGTYPE Operation against a key holding the wrong kind of value
GETEX gl BOGUS => -ERR syntax error
GETEX g EXAT 1 => "v"
    events: __keyspace@0__:g del | __keyevent@0__:del g
EXISTS g => :0
SET g v => +OK
    events: __keyspace@0__:g set | __keyevent@0__:set g
GETEX g PXAT @-1000 => "v"
    events: __keyspace@0__:g del | __keyevent@0__:del g
EXISTS g => :0
SET g v EX 100 => +OK
    events: __keyspace@0__:g set | __keyevent@0__:set g | __keyspace@0__:g expire | __keyevent@0__:expire g
GETEX g EX 0 => -ERR invalid expire time in 'getex' command
TTL g => integer within [98, 100]
GETEX => -ERR wrong number of arguments for 'getex' command
GETEX g EX 10 EXAT 10 => -ERR syntax error

## GETDEL GETSET SETNX SETEX PSETEX
SET d v EX 100 => +OK
    events: __keyspace@0__:d set | __keyevent@0__:set d | __keyspace@0__:d expire | __keyevent@0__:expire d
GETDEL d => "v"
    events: __keyspace@0__:d del | __keyevent@0__:del d
EXISTS d => :0
GETDEL d => nil
RPUSH dl a => :1
    events: __keyspace@0__:dl rpush | __keyevent@0__:rpush dl
GETDEL dl => -WRONGTYPE Operation against a key holding the wrong kind of value
GETDEL => -ERR wrong number of arguments for 'getdel' command
GETDEL a b => -ERR wrong number of arguments for 'getdel' command
SET s old EX 100 => +OK
    events: __keyspace@0__:s set | __keyevent@0__:set s | __keyspace@0__:s expire | __keyevent@0__:expire s
GETSET s new => "old"
    events: __keyspace@0__:s set | __keyevent@0__:set s
TTL s => :-1
GET s => "new"
GETSET smissing v => nil
    events: __keyspace@0__:smissing set | __keyevent@0__:set smissing
GET smissing => "v"
GETSET dl v => -WRONGTYPE Operation against a key holding the wrong kind of value
GETSET s => -ERR wrong number of arguments for 'getset' command
SETNX n v => :1
    events: __keyspace@0__:n set | __keyevent@0__:set n
SETNX n v2 => :0
GET n => "v"
SETNX dl v => :0
SET n v EX 100 => +OK
    events: __keyspace@0__:n set | __keyevent@0__:set n | __keyspace@0__:n expire | __keyevent@0__:expire n
SETNX n v2 => :0
TTL n => integer within [98, 100]
SETNX n => -ERR wrong number of arguments for 'setnx' command
SETEX x 100 v => +OK
    events: __keyspace@0__:x set | __keyevent@0__:set x | __keyspace@0__:x expire | __keyevent@0__:expire x
TTL x => integer within [99, 100]
GET x => "v"
SETEX x 0 v => -ERR invalid expire time in 'setex' command
SETEX x -1 v => -ERR invalid expire time in 'setex' command
SETEX x abc v => -ERR value is not an integer or out of range
SETEX x 9223372036854775807 v => -ERR invalid expire time in 'setex' command
SETEX x 9223372036854775 v => -ERR invalid expire time in 'setex' command
SETEX x 9223372036854776 v => -ERR invalid expire time in 'setex' command
SETEX dl 10 v => +OK
    events: __keyspace@0__:dl set | __keyevent@0__:set dl | __keyspace@0__:dl expire | __keyevent@0__:expire dl
TYPE dl => +string
SETEX x 10 => -ERR wrong number of arguments for 'setex' command
SETEX x 10 v extra => -ERR wrong number of arguments for 'setex' command
PSETEX y 100000 v => +OK
    events: __keyspace@0__:y set | __keyevent@0__:set y | __keyspace@0__:y expire | __keyevent@0__:expire y
PTTL y => integer within [99000, 100000]
PSETEX y 0 v => -ERR invalid expire time in 'psetex' command
PSETEX y -1 v => -ERR invalid expire time in 'psetex' command
PSETEX y abc v => -ERR value is not an integer or out of range
PSETEX y 9223372036854775807 v => -ERR invalid expire time in 'psetex' command
PSETEX y 10 => -ERR wrong number of arguments for 'psetex' command

## MGET MSET MSETNX
MSET m1 a m2 b => +OK
    events: __keyspace@0__:m1 set | __keyevent@0__:set m1 | __keyspace@0__:m2 set | __keyevent@0__:set m2
MGET m1 m2 m3 dl => ["a", "b", nil, "v"]
MGET => -ERR wrong number of arguments for 'mget' command
MGET m1 => ["a"]
MSET => -ERR wrong number of arguments for 'mset' command
MSET m1 => -ERR wrong number of arguments for 'mset' command
MSET m1 a m2 => -ERR wrong number of arguments for 'mset' command
MSET m1 x m1 y => +OK
    events: __keyspace@0__:m1 set | __keyevent@0__:set m1 | __keyspace@0__:m1 set | __keyevent@0__:set m1
GET m1 => "y"
SET m1 v EX 100 => +OK
    events: __keyspace@0__:m1 set | __keyevent@0__:set m1 | __keyspace@0__:m1 expire | __keyevent@0__:expire m1
MSET m1 z => +OK
    events: __keyspace@0__:m1 set | __keyevent@0__:set m1
TTL m1 => :-1
MSET dl v => +OK
    events: __keyspace@0__:dl set | __keyevent@0__:set dl
TYPE dl => +string
MSETNX mn1 a mn2 b => :1
    events: __keyspace@0__:mn1 set | __keyevent@0__:set mn1 | __keyspace@0__:mn2 set | __keyevent@0__:set mn2
MSETNX mn1 c mn3 d => :0
MGET mn1 mn2 mn3 => ["a", "b", nil]
MSETNX mn4 x mn4 y => :1
    events: __keyspace@0__:mn4 set | __keyevent@0__:set mn4 | __keyspace@0__:mn4 set | __keyevent@0__:set mn4
GET mn4 => "y"
MSETNX mn5 => -ERR wrong number of arguments for 'msetnx' command
MSETNX mn5 a mn6 => -ERR wrong number of arguments for 'msetnx' command
MSETNX => -ERR wrong number of arguments for 'msetnx' command
SET mn7 v EX 100 => +OK
    events: __keyspace@0__:mn7 set | __keyevent@0__:set mn7 | __keyspace@0__:mn7 expire | __keyevent@0__:expire mn7
MSETNX mn7 z => :0
DEL mn7 => :1
    events: __keyspace@0__:mn7 del | __keyevent@0__:del mn7
MSETNX mn7 z => :1
    events: __keyspace@0__:mn7 set | __keyevent@0__:set mn7
TTL mn7 => :-1

## APPEND STRLEN
DEL a => :0
APPEND a hello => :5
    events: __keyspace@0__:a append | __keyevent@0__:append a
APPEND a " world" => :11
    events: __keyspace@0__:a append | __keyevent@0__:append a
GET a => "hello world"
APPEND a "" => :11
    events: __keyspace@0__:a append | __keyevent@0__:append a
STRLEN a => :11
STRLEN missing => :0
STRLEN dl => :1
APPEND dl x => :2
    events: __keyspace@0__:dl append | __keyevent@0__:append dl
SET a v EX 100 => +OK
    events: __keyspace@0__:a set | __keyevent@0__:set a | __keyspace@0__:a expire | __keyevent@0__:expire a
APPEND a w => :2
    events: __keyspace@0__:a append | __keyevent@0__:append a
TTL a => integer within [98, 100]
SET ai 123 => +OK
    events: __keyspace@0__:ai set | __keyevent@0__:set ai
OBJECT ENCODING ai => "int"
APPEND ai 4 => :4
    events: __keyspace@0__:ai append | __keyevent@0__:append ai
OBJECT ENCODING ai => "raw"
GET ai => "1234"
APPEND a => -ERR wrong number of arguments for 'append' command
APPEND a b c => -ERR wrong number of arguments for 'append' command
STRLEN => -ERR wrong number of arguments for 'strlen' command
STRLEN a b => -ERR wrong number of arguments for 'strlen' command
APPEND missing2 "" => :0
    events: __keyspace@0__:missing2 append | __keyevent@0__:append missing2
EXISTS missing2 => :1
GET missing2 => ""
STRLEN missing2 => :0

## SETRANGE
DEL r => :0
SETRANGE r 0 "" => :0
EXISTS r => :0
SETRANGE r 5 "" => :0
EXISTS r => :0
SETRANGE r 5 abc => :8
    events: __keyspace@0__:r setrange | __keyevent@0__:setrange r
GET r => hex[8]=0000000000616263
SETRANGE r 0 xy => :8
    events: __keyspace@0__:r setrange | __keyevent@0__:setrange r
GET r => hex[8]=7879000000616263
SETRANGE r 7 ZZZZ => :11
    events: __keyspace@0__:r setrange | __keyevent@0__:setrange r
GET r => hex[11]=787900000061625a5a5a5a
SETRANGE r -1 x => -ERR offset is out of range
SETRANGE r abc x => -ERR value is not an integer or out of range
SETRANGE r 536870911 x => :536870912
    events: __keyspace@0__:r setrange | __keyevent@0__:setrange r
SETRANGE r 536870912 x => -ERR string exceeds maximum allowed size (proto-max-bulk-len)
SETRANGE r 536870911 "" => :536870912
SETRANGE r 536870908 xxxxx => -ERR string exceeds maximum allowed size (proto-max-bulk-len)
SETRANGE r 9223372036854775807 x => -ERR string exceeds maximum allowed size (proto-max-bulk-len)
SETRANGE r 9223372036854775808 x => -ERR value is not an integer or out of range
SETRANGE r -9223372036854775808 x => -ERR offset is out of range
SETRANGE dl 0 x => :2
    events: __keyspace@0__:dl setrange | __keyevent@0__:setrange dl
SETRANGE dl -1 x => -ERR offset is out of range
SETRANGE dl abc x => -ERR value is not an integer or out of range
SETRANGE dl 0 "" => :2
SETRANGE r 0 => -ERR wrong number of arguments for 'setrange' command
SET r v EX 100 => +OK
    events: __keyspace@0__:r set | __keyevent@0__:set r | __keyspace@0__:r expire | __keyevent@0__:expire r
SETRANGE r 0 w => :1
    events: __keyspace@0__:r setrange | __keyevent@0__:setrange r
TTL r => integer within [98, 100]
SET ri 12345 => +OK
    events: __keyspace@0__:ri set | __keyevent@0__:set ri
SETRANGE ri 1 x => :5
    events: __keyspace@0__:ri setrange | __keyevent@0__:setrange ri
GET ri => "1x345"
OBJECT ENCODING ri => "raw"
SET ri 12345 => +OK
    events: __keyspace@0__:ri set | __keyevent@0__:set ri
SETRANGE ri 0 "" => :5
OBJECT ENCODING ri => "int"
SETRANGE ri 10 "" => :5
OBJECT ENCODING ri => "int"
GET ri => "12345"
CONFIG SET proto-max-bulk-len 1000 => -ERR CONFIG SET failed (possibly related to argument 'proto-max-bulk-len') - argument must be between 1048576 and 9223372036854775807 inclusive
SET big xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx => +OK
    events: __keyspace@0__:big set | __keyevent@0__:set big
SETRANGE big 995 abcdef => :1001
    events: __keyspace@0__:big setrange | __keyevent@0__:setrange big
SETRANGE big 995 abcde => :1001
    events: __keyspace@0__:big setrange | __keyevent@0__:setrange big
STRLEN big => :1001
APPEND big z => :1002
    events: __keyspace@0__:big append | __keyevent@0__:append big
APPEND big "" => :1002
    events: __keyspace@0__:big append | __keyevent@0__:append big
SETRANGE big 1000 "" => :1002
SETRANGE big 1001 "" => :1002
SETRANGE big 1000 x => :1002
    events: __keyspace@0__:big setrange | __keyevent@0__:setrange big
SETRANGE newbig 999 x => :1000
    events: __keyspace@0__:newbig setrange | __keyevent@0__:setrange newbig
SETRANGE newbig2 999 xy => :1001
    events: __keyspace@0__:newbig2 setrange | __keyevent@0__:setrange newbig2
SETRANGE newbig3 1000 x => :1001
    events: __keyspace@0__:newbig3 setrange | __keyevent@0__:setrange newbig3
CONFIG SET proto-max-bulk-len 536870912 => +OK

## GETRANGE SUBSTR
SET gr "This is a string" => +OK
    events: __keyspace@0__:gr set | __keyevent@0__:set gr
GETRANGE gr 0 3 => "This"
GETRANGE gr -3 -1 => "ing"
GETRANGE gr 0 -1 => "This is a string"
GETRANGE gr 10 100 => "string"
GETRANGE gr -100 3 => "This"
GETRANGE gr 5 3 => ""
GETRANGE gr -1 -3 => ""
GETRANGE gr 100 200 => ""
GETRANGE gr -100 -50 => "T"
GETRANGE gr 0 0 => "T"
GETRANGE gr -1 -1 => "g"
GETRANGE gr -16 0 => "T"
GETRANGE gr -17 0 => "T"
GETRANGE gr 15 15 => "g"
GETRANGE gr 16 16 => ""
    events: __keyspace@0__:e expired | __keyevent@0__:expired e
GETRANGE gr -100 -100 => "T"
GETRANGE gr -100 -17 => "T"
GETRANGE gr -100 -16 => "T"
GETRANGE gr -1 0 => ""
GETRANGE gr -1 -2 => ""
GETRANGE gr 0 -17 => "T"
GETRANGE gr 0 -16 => "T"
GETRANGE gr 0 -18 => "T"
GETRANGE gr 3 -14 => ""
GETRANGE gr 3 -13 => "s"
GETRANGE gr abc 1 => -ERR value is not an integer or out of range
GETRANGE gr 0 abc => -ERR value is not an integer or out of range
    events: __keyspace@0__:past expired | __keyevent@0__:expired past
GETRANGE gr 9223372036854775807 9223372036854775807 => ""
GETRANGE gr -9223372036854775808 9223372036854775807 => "This is a string"
GETRANGE gr -9223372036854775808 -9223372036854775808 => "T"
GETRANGE gr 0 9223372036854775808 => -ERR value is not an integer or out of range
GETRANGE missing 0 -1 => ""
GETRANGE missing 5 3 => ""
GETRANGE missing abc 1 => -ERR value is not an integer or out of range
GETRANGE dl 0 -1 => "xx"
GETRANGE dl abc 1 => -ERR value is not an integer or out of range
GETRANGE dl 5 3 => ""
GETRANGE gr 0 => -ERR wrong number of arguments for 'getrange' command
GETRANGE gr 0 1 2 => -ERR wrong number of arguments for 'getrange' command
SET gi -12345 => +OK
    events: __keyspace@0__:gi set | __keyevent@0__:set gi
GETRANGE gi 0 2 => "-12"
GETRANGE gi -2 -1 => "45"
SUBSTR gr 0 3 => "This"
SUBSTR gr 5 3 => ""
SUBSTR gr abc 3 => -ERR value is not an integer or out of range
SUBSTR missing 0 3 => ""
SUBSTR gr 0 => -ERR wrong number of arguments for 'substr' command
SET empty "" => +OK
    events: __keyspace@0__:empty set | __keyevent@0__:set empty
GETRANGE empty 0 -1 => ""
GETRANGE empty 0 0 => ""
GETRANGE empty -1 -1 => ""

## INCR DECR INCRBY DECRBY
DEL i => :0
INCR i => :1
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
INCR i => :2
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
DECR i => :1
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
INCRBY i 10 => :11
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
DECRBY i 3 => :8
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
INCRBY i -20 => :-12
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
DECRBY i -5 => :-7
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
GET i => "-7"
OBJECT ENCODING i => "int"
SET i 9223372036854775807 => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
INCR i => -ERR increment or decrement would overflow
INCRBY i 1 => -ERR increment or decrement would overflow
INCRBY i 0 => :9223372036854775807
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
DECR i => :9223372036854775806
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
SET i -9223372036854775808 => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
DECR i => -ERR increment or decrement would overflow
DECRBY i 1 => -ERR increment or decrement would overflow
INCRBY i -1 => -ERR increment or decrement would overflow
INCR i => :-9223372036854775807
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
SET i 0 => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
DECRBY i -9223372036854775808 => -ERR decrement would overflow
INCRBY i -9223372036854775808 => :-9223372036854775808
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
GET i => "-9223372036854775808"
DECRBY i -9223372036854775808 => -ERR decrement would overflow
INCRBY i 9223372036854775808 => -ERR value is not an integer or out of range
INCRBY i abc => -ERR value is not an integer or out of range
INCRBY i 1.5 => -ERR value is not an integer or out of range
INCRBY i "" => -ERR value is not an integer or out of range
INCRBY i " 1" => -ERR value is not an integer or out of range
INCRBY i "1 " => -ERR value is not an integer or out of range
INCRBY i +1 => -ERR value is not an integer or out of range
INCRBY i -0 => -ERR value is not an integer or out of range
INCRBY i 01 => -ERR value is not an integer or out of range
INCRBY i 0x10 => -ERR value is not an integer or out of range
SET i abc => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
INCR i => -ERR value is not an integer or out of range
SET i 1.5 => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
INCR i => -ERR value is not an integer or out of range
SET i " 1" => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
INCR i => -ERR value is not an integer or out of range
SET i "1 " => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
INCR i => -ERR value is not an integer or out of range
SET i +1 => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
INCR i => -ERR value is not an integer or out of range
SET i 01 => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
INCR i => -ERR value is not an integer or out of range
SET i -0 => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
INCR i => -ERR value is not an integer or out of range
SET i "" => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
INCR i => -ERR value is not an integer or out of range
SET i 9223372036854775808 => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
INCR i => -ERR value is not an integer or out of range
SET i -9223372036854775809 => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
DECR i => -ERR value is not an integer or out of range
INCR dl => -ERR value is not an integer or out of range
DECR dl => -ERR value is not an integer or out of range
INCRBY dl 1 => -ERR value is not an integer or out of range
INCRBY dl abc => -ERR value is not an integer or out of range
DECRBY dl abc => -ERR value is not an integer or out of range
INCR => -ERR wrong number of arguments for 'incr' command
INCR i j => -ERR wrong number of arguments for 'incr' command
INCRBY i => -ERR wrong number of arguments for 'incrby' command
INCRBY i 1 2 => -ERR wrong number of arguments for 'incrby' command
DECRBY i => -ERR wrong number of arguments for 'decrby' command
SET i 5 EX 100 => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i | __keyspace@0__:i expire | __keyevent@0__:expire i
INCR i => :6
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
TTL i => integer within [98, 100]
SET i 5 => +OK
    events: __keyspace@0__:i set | __keyevent@0__:set i
INCRBY i 0 => :5
    events: __keyspace@0__:i incrby | __keyevent@0__:incrby i
SET inc2 100 => +OK
    events: __keyspace@0__:inc2 set | __keyevent@0__:set inc2
OBJECT ENCODING inc2 => "int"
SET inc3 100000000000000000000 => +OK
    events: __keyspace@0__:inc3 set | __keyevent@0__:set inc3
OBJECT ENCODING inc3 => "embstr"
INCR inc3 => -ERR value is not an integer or out of range

## INCRBYFLOAT
DEL f => :0
INCRBYFLOAT f 10.5 => "10.5"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 0.1 => "10.6"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f -5 => "5.6"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
GET f => "5.6"
OBJECT ENCODING f => "embstr"
SET f 10 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1.5 => "11.5"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f -1.5 => "10"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
GET f => "10"
OBJECT ENCODING f => "embstr"
INCRBYFLOAT f 5.0e3 => "5010"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f -5.0e3 => "10"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 5.0e3 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 200 => "5200"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1e20 => "100000000000000000000"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1 => "100000000000000000000"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1e17 => "100000000000000000"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1e16 => "110000000000000000"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 0.000001 => "110000000000000000"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0.0000001 => "0.0000001"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1e-10 => "0.0000001001"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 3.0 => "3"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 0.30000000000000004 => "3.30000000000000004"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1.1 => "1.1"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1.1 => "2.2"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1.1 => "3.3"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 123456789012345678 => "123456789012345678"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 0.5 => "123456789012345678.5"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1e400 => "10000000000000000000281880683947586514586453433629052038625910693539685534008629862039363994848324160522094053927317616200295822777259255734023828976593340661017797447434546173917862448116674971723778943824391593338047470675026246684401359237513603830343735485505244955964979021825038280091068414947402456898653040951017512658092615827588920183472511643316591362664138176309734806343732497430221946880"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f -1e400 => "0"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1.7976931348623157e308 => "179769313486231569995921046774104434048386446944329178485314420765176628523124396354701868608387085564428793419425520689308708363451136055357897278026477617073498977686288394835618163294045594434929537447290627480669417384648879122776218333598953852832103282504751611691208117720159985926376802466863339536384"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1.7976931348623157e308 => "359538626972463139991842093548208868096772893888658356970628841530353257046248792709403737216774171128857586838851041378617416726902272110715794556052955234146997955372576789671236326588091188869859074894581254961338834769297758245552436667197907705664206565009503223382416235440319971852753604933726679072768"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f inf => -ERR increment would produce NaN or Infinity
INCRBYFLOAT f +inf => -ERR increment would produce NaN or Infinity
INCRBYFLOAT f -inf => -ERR increment would produce NaN or Infinity
INCRBYFLOAT f nan => -ERR value is not a valid float
INCRBYFLOAT f abc => -ERR value is not a valid float
INCRBYFLOAT f "" => -ERR value is not a valid float
INCRBYFLOAT f " 1" => -ERR value is not a valid float
INCRBYFLOAT f "1 " => -ERR value is not a valid float
INCRBYFLOAT f +1 => "1"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f .5 => "1.5"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 5. => "6.5"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1e => -ERR value is not a valid float
INCRBYFLOAT f 0x10 => "22.5"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1,5 => -ERR value is not a valid float
INCRBYFLOAT f -0 => "22.5"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
GET f => "22.5"
SET f -0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0 => "0"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0.0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0 => "0"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f abc => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1 => -ERR value is not a valid float
SET f " 1" => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1 => -ERR value is not a valid float
SET f "1 " => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1 => -ERR value is not a valid float
SET f inf => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1 => -ERR increment would produce NaN or Infinity
SET f "" => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1 => -ERR value is not a valid float
SET f 1e400 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1 => "10000000000000000000281880683947586514586453433629052038625910693539685534008629862039363994848324160522094053927317616200295822777259255734023828976593340661017797447434546173917862448116674971723778943824391593338047470675026246684401359237513603830343735485505244955964979021825038280091068414947402456898653040951017512658092615827588920183472511643316591362664138176309734806343732497430221946880"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT dl 1 => -ERR value is not a valid float
INCRBYFLOAT dl abc => -ERR value is not a valid float
RPUSH fl a => :1
    events: __keyspace@0__:fl rpush | __keyevent@0__:rpush fl
INCRBYFLOAT fl abc => -WRONGTYPE Operation against a key holding the wrong kind of value
INCRBYFLOAT fl 1 => -WRONGTYPE Operation against a key holding the wrong kind of value
INCRBYFLOAT fl "" => -WRONGTYPE Operation against a key holding the wrong kind of value
INCRBYFLOAT nofl abc => -ERR value is not a valid float
INCRBY fl abc => -ERR value is not an integer or out of range
DECRBY fl abc => -ERR value is not an integer or out of range
DEL fl => :1
    events: __keyspace@0__:fl del | __keyevent@0__:del fl
INCRBYFLOAT f => -ERR wrong number of arguments for 'incrbyfloat' command
INCRBYFLOAT f 1 2 => -ERR wrong number of arguments for 'incrbyfloat' command
SET f 1 EX 100 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f | __keyspace@0__:f expire | __keyevent@0__:expire f
INCRBYFLOAT f 1 => "2"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
TTL f => integer within [98, 100]
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0.1 => "0.1"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 0.2 => "0.3"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1234567890.1234567890 => "1234567890.12345678894780576"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 2.5e-5 => "0.000025"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1e21 => "1000000000000000000000"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 123456789012345678901234567890 => "123456789012345678899921813504"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0.1234567890123456789 => "0.12345678901234568"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f -0.0 => "0"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1e-7 => "0.0000001"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f -1e-7 => "0"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 99999999999999999 => "99999999999999999"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0.5e1 => "5"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1E2 => "105"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1e+2 => "205"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1e-2 => "205.01"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f -1 => "-1"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0.1e-5 => "0.000001"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 0 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 1e15 => "1000000000000000"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1e16 => "11000000000000000"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1e17 => "111000000000000000"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
INCRBYFLOAT f 1e18 => "1111000000000000000"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 3.14159265358979323846 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0 => "3.14159265358979324"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 1234567890123456789 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0 => "1234567890123456789"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 12345678901234567 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0 => "12345678901234567"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 9007199254740993 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0 => "9007199254740993"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 5e-324 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0 => "0"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f
SET f 1e-320 => +OK
    events: __keyspace@0__:f set | __keyevent@0__:set f
INCRBYFLOAT f 0 => "0"
    events: __keyspace@0__:f incrbyfloat | __keyevent@0__:incrbyfloat f

## LCS
SET key1 ohmytext => +OK
    events: __keyspace@0__:key1 set | __keyevent@0__:set key1
SET key2 mynewtext => +OK
    events: __keyspace@0__:key2 set | __keyevent@0__:set key2
LCS key1 key2 => "mytext"
LCS key1 key2 LEN => :6
2| LCS key1 key2 IDX => ["matches", [[[:4, :7], [:5, :8]], [[:2, :3], [:0, :1]]], "len", :6]
3| LCS key1 key2 IDX => %{"matches": [[[:4, :7], [:5, :8]], [[:2, :3], [:0, :1]]], "len": :6}
2| LCS key1 key2 IDX WITHMATCHLEN => ["matches", [[[:4, :7], [:5, :8], :4], [[:2, :3], [:0, :1], :2]], "len", :6]
3| LCS key1 key2 IDX WITHMATCHLEN => %{"matches": [[[:4, :7], [:5, :8], :4], [[:2, :3], [:0, :1], :2]], "len": :6}
2| LCS key1 key2 IDX MINMATCHLEN 4 => ["matches", [[[:4, :7], [:5, :8]]], "len", :6]
3| LCS key1 key2 IDX MINMATCHLEN 4 => %{"matches": [[[:4, :7], [:5, :8]]], "len": :6}
2| LCS key1 key2 IDX MINMATCHLEN 4 WITHMATCHLEN => ["matches", [[[:4, :7], [:5, :8], :4]], "len", :6]
3| LCS key1 key2 IDX MINMATCHLEN 4 WITHMATCHLEN => %{"matches": [[[:4, :7], [:5, :8], :4]], "len": :6}
2| LCS key1 key2 IDX MINMATCHLEN 0 => ["matches", [[[:4, :7], [:5, :8]], [[:2, :3], [:0, :1]]], "len", :6]
3| LCS key1 key2 IDX MINMATCHLEN 0 => %{"matches": [[[:4, :7], [:5, :8]], [[:2, :3], [:0, :1]]], "len": :6}
2| LCS key1 key2 IDX MINMATCHLEN -1 => ["matches", [[[:4, :7], [:5, :8]], [[:2, :3], [:0, :1]]], "len", :6]
3| LCS key1 key2 IDX MINMATCHLEN -1 => %{"matches": [[[:4, :7], [:5, :8]], [[:2, :3], [:0, :1]]], "len": :6}
2| LCS key1 key2 IDX MINMATCHLEN 100 => ["matches", [], "len", :6]
3| LCS key1 key2 IDX MINMATCHLEN 100 => %{"matches": [], "len": :6}
LCS key1 key2 IDX MINMATCHLEN abc => -ERR value is not an integer or out of range
LCS key1 key2 IDX MINMATCHLEN => -ERR syntax error
LCS key1 key2 MINMATCHLEN 4 => "mytext"
LCS key1 key2 WITHMATCHLEN => "mytext"
LCS key1 key2 LEN IDX => -ERR If you want both the length and indexes, please just use IDX.
LCS key1 key2 IDX LEN => -ERR If you want both the length and indexes, please just use IDX.
LCS key1 key2 LEN LEN => :6
2| LCS key1 key2 IDX IDX => ["matches", [[[:4, :7], [:5, :8]], [[:2, :3], [:0, :1]]], "len", :6]
3| LCS key1 key2 IDX IDX => %{"matches": [[[:4, :7], [:5, :8]], [[:2, :3], [:0, :1]]], "len": :6}
LCS key1 key2 BOGUS => -ERR syntax error
LCS key1 key2 len => :6
2| LCS key1 key2 idx withmatchlen minmatchlen 2 => ["matches", [[[:4, :7], [:5, :8], :4], [[:2, :3], [:0, :1], :2]], "len", :6]
3| LCS key1 key2 idx withmatchlen minmatchlen 2 => %{"matches": [[[:4, :7], [:5, :8], :4], [[:2, :3], [:0, :1], :2]], "len": :6}
LCS key1 key2 LEN MINMATCHLEN 4 => :6
LCS key1 key2 LEN WITHMATCHLEN => :6
2| LCS key1 key2 IDX MINMATCHLEN 9223372036854775807 => ["matches", [], "len", :6]
3| LCS key1 key2 IDX MINMATCHLEN 9223372036854775807 => %{"matches": [], "len": :6}
2| LCS key1 key2 IDX MINMATCHLEN -9223372036854775808 => ["matches", [[[:4, :7], [:5, :8]], [[:2, :3], [:0, :1]]], "len", :6]
3| LCS key1 key2 IDX MINMATCHLEN -9223372036854775808 => %{"matches": [[[:4, :7], [:5, :8]], [[:2, :3], [:0, :1]]], "len": :6}
LCS key1 key2 IDX MINMATCHLEN 9223372036854775808 => -ERR value is not an integer or out of range
LCS key1 missing => ""
LCS missing key2 => ""
LCS missing missing2 => ""
LCS missing missing2 LEN => :0
2| LCS missing missing2 IDX => ["matches", [], "len", :0]
3| LCS missing missing2 IDX => %{"matches": [], "len": :0}
LCS key1 dl => "x"
LCS dl key1 => "x"
LCS dl dl => "xx"
LCS key1 key1 => "ohmytext"
2| LCS key1 key1 IDX => ["matches", [[[:0, :7], [:0, :7]]], "len", :8]
3| LCS key1 key1 IDX => %{"matches": [[[:0, :7], [:0, :7]]], "len": :8}
LCS key1 => -ERR wrong number of arguments for 'lcs' command
LCS key1 key2 IDX MINMATCHLEN 2 BOGUS => -ERR syntax error
SET e1 "" => +OK
    events: __keyspace@0__:e1 set | __keyevent@0__:set e1
SET e2 "" => +OK
    events: __keyspace@0__:e2 set | __keyevent@0__:set e2
LCS e1 e2 => ""
LCS e1 e2 LEN => :0
2| LCS e1 e2 IDX => ["matches", [], "len", :0]
3| LCS e1 e2 IDX => %{"matches": [], "len": :0}
LCS e1 key1 => ""
2| LCS key1 e1 IDX => ["matches", [], "len", :0]
3| LCS key1 e1 IDX => %{"matches": [], "len": :0}
SET a1 abcdef => +OK
    events: __keyspace@0__:a1 set | __keyevent@0__:set a1
SET a2 abcdef => +OK
    events: __keyspace@0__:a2 set | __keyevent@0__:set a2
LCS a1 a2 => "abcdef"
2| LCS a1 a2 IDX => ["matches", [[[:0, :5], [:0, :5]]], "len", :6]
3| LCS a1 a2 IDX => %{"matches": [[[:0, :5], [:0, :5]]], "len": :6}
2| LCS a1 a2 IDX WITHMATCHLEN => ["matches", [[[:0, :5], [:0, :5], :6]], "len", :6]
3| LCS a1 a2 IDX WITHMATCHLEN => %{"matches": [[[:0, :5], [:0, :5], :6]], "len": :6}
SET b1 abc => +OK
    events: __keyspace@0__:b1 set | __keyevent@0__:set b1
SET b2 xyz => +OK
    events: __keyspace@0__:b2 set | __keyevent@0__:set b2
LCS b1 b2 => ""
LCS b1 b2 LEN => :0
2| LCS b1 b2 IDX => ["matches", [], "len", :0]
3| LCS b1 b2 IDX => %{"matches": [], "len": :0}
SET c1 aXbXcXd => +OK
    events: __keyspace@0__:c1 set | __keyevent@0__:set c1
SET c2 abcd => +OK
    events: __keyspace@0__:c2 set | __keyevent@0__:set c2
LCS c1 c2 => "abcd"
2| LCS c1 c2 IDX => ["matches", [[[:6, :6], [:3, :3]], [[:4, :4], [:2, :2]], [[:2, :2], [:1, :1]], [[:0, :0], [:0, :0]]], "len", :4]
3| LCS c1 c2 IDX => %{"matches": [[[:6, :6], [:3, :3]], [[:4, :4], [:2, :2]], [[:2, :2], [:1, :1]], [[:0, :0], [:0, :0]]], "len": :4}
2| LCS c1 c2 IDX WITHMATCHLEN => ["matches", [[[:6, :6], [:3, :3], :1], [[:4, :4], [:2, :2], :1], [[:2, :2], [:1, :1], :1], [[:0, :0], [:0, :0], :1]], "len", :4]
3| LCS c1 c2 IDX WITHMATCHLEN => %{"matches": [[[:6, :6], [:3, :3], :1], [[:4, :4], [:2, :2], :1], [[:2, :2], [:1, :1], :1], [[:0, :0], [:0, :0], :1]], "len": :4}
2| LCS c1 c2 IDX MINMATCHLEN 2 => ["matches", [], "len", :4]
3| LCS c1 c2 IDX MINMATCHLEN 2 => %{"matches": [], "len": :4}
2| LCS c2 c1 IDX WITHMATCHLEN => ["matches", [[[:3, :3], [:6, :6], :1], [[:2, :2], [:4, :4], :1], [[:1, :1], [:2, :2], :1], [[:0, :0], [:0, :0], :1]], "len", :4]
3| LCS c2 c1 IDX WITHMATCHLEN => %{"matches": [[[:3, :3], [:6, :6], :1], [[:2, :2], [:4, :4], :1], [[:1, :1], [:2, :2], :1], [[:0, :0], [:0, :0], :1]], "len": :4}
SET d1 abcabc => +OK
    events: __keyspace@0__:d1 set | __keyevent@0__:set d1
SET d2 bcabca => +OK
    events: __keyspace@0__:d2 set | __keyevent@0__:set d2
LCS d1 d2 => "bcabc"
2| LCS d1 d2 IDX WITHMATCHLEN => ["matches", [[[:1, :5], [:0, :4], :5]], "len", :5]
3| LCS d1 d2 IDX WITHMATCHLEN => %{"matches": [[[:1, :5], [:0, :4], :5]], "len": :5}
SET f1 ABCBDAB => +OK
    events: __keyspace@0__:f1 set | __keyevent@0__:set f1
SET f2 BDCABA => +OK
    events: __keyspace@0__:f2 set | __keyevent@0__:set f2
LCS f1 f2 => "BDAB"
2| LCS f1 f2 IDX WITHMATCHLEN => ["matches", [[[:5, :6], [:3, :4], :2], [[:3, :4], [:0, :1], :2]], "len", :4]
3| LCS f1 f2 IDX WITHMATCHLEN => %{"matches": [[[:5, :6], [:3, :4], :2], [[:3, :4], [:0, :1], :2]], "len": :4}
LCS f2 f1 => "BCBA"
2| LCS f2 f1 IDX WITHMATCHLEN => ["matches", [[[:5, :5], [:5, :5], :1], [[:4, :4], [:3, :3], :1], [[:2, :2], [:2, :2], :1], [[:0, :0], [:1, :1], :1]], "len", :4]
3| LCS f2 f1 IDX WITHMATCHLEN => %{"matches": [[[:5, :5], [:5, :5], :1], [[:4, :4], [:3, :3], :1], [[:2, :2], [:2, :2], :1], [[:0, :0], [:1, :1], :1]], "len": :4}
SET g1 aaaa => +OK
    events: __keyspace@0__:g1 set | __keyevent@0__:set g1
SET g2 aa => +OK
    events: __keyspace@0__:g2 set | __keyevent@0__:set g2
LCS g1 g2 => "aa"
2| LCS g1 g2 IDX => ["matches", [[[:2, :3], [:0, :1]]], "len", :2]
3| LCS g1 g2 IDX => %{"matches": [[[:2, :3], [:0, :1]]], "len": :2}
2| LCS g2 g1 IDX => ["matches", [[[:0, :1], [:2, :3]]], "len", :2]
3| LCS g2 g1 IDX => %{"matches": [[[:0, :1], [:2, :3]]], "len": :2}
SET h1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaabbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb => +OK
    events: __keyspace@0__:h1 set | __keyevent@0__:set h1
SET h2 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa => +OK
    events: __keyspace@0__:h2 set | __keyevent@0__:set h2
LCS h1 h2 LEN => :300
2| LCS h1 h2 IDX MINMATCHLEN 299 => ["matches", [[[:300, :599], [:0, :299]]], "len", :300]
3| LCS h1 h2 IDX MINMATCHLEN 299 => %{"matches": [[[:300, :599], [:0, :299]]], "len": :300}
SET bin1 hex[4]=0001ff00 => +OK
    events: __keyspace@0__:bin1 set | __keyevent@0__:set bin1
SET bin2 hex[3]=ff0001 => +OK
    events: __keyspace@0__:bin2 set | __keyevent@0__:set bin2
LCS bin1 bin2 => hex[2]=ff00
2| LCS bin1 bin2 IDX WITHMATCHLEN => ["matches", [[[:2, :3], [:0, :1], :2]], "len", :2]
3| LCS bin1 bin2 IDX WITHMATCHLEN => %{"matches": [[[:2, :3], [:0, :1], :2]], "len": :2}
SET n1 12345 => +OK
    events: __keyspace@0__:n1 set | __keyevent@0__:set n1
SET n2 34512 => +OK
    events: __keyspace@0__:n2 set | __keyevent@0__:set n2
OBJECT ENCODING n1 => "int"
LCS n1 n2 => "345"
2| LCS n1 n2 IDX WITHMATCHLEN => ["matches", [[[:2, :4], [:0, :2], :3]], "len", :3]
3| LCS n1 n2 IDX WITHMATCHLEN => %{"matches": [[[:2, :4], [:0, :2], :3]], "len": :3}
SET u1 thequickbrownfoxjumpsoverthelazydog => +OK
    events: __keyspace@0__:u1 set | __keyevent@0__:set u1
SET u2 thelazydogjumpsoverthequickbrownfox => +OK
    events: __keyspace@0__:u2 set | __keyevent@0__:set u2
LCS u1 u2 => "theojumpsovertheo"
2| LCS u1 u2 IDX WITHMATCHLEN => ["matches", [[[:33, :33], [:29, :29], :1], [[:16, :27], [:10, :21], :12], [[:14, :14], [:8, :8], :1], [[:0, :2], [:0, :2], :3]], "len", :17]
3| LCS u1 u2 IDX WITHMATCHLEN => %{"matches": [[[:33, :33], [:29, :29], :1], [[:16, :27], [:10, :21], :12], [[:14, :14], [:8, :8], :1], [[:0, :2], [:0, :2], :3]], "len": :17}
2| LCS u1 u2 IDX MINMATCHLEN 5 WITHMATCHLEN => ["matches", [[[:16, :27], [:10, :21], :12]], "len", :17]
3| LCS u1 u2 IDX MINMATCHLEN 5 WITHMATCHLEN => %{"matches": [[[:16, :27], [:10, :21], :12]], "len": :17}

## DEBUG and encodings
SET enc1 12345 => +OK
    events: __keyspace@0__:enc1 set | __keyevent@0__:set enc1
OBJECT ENCODING enc1 => "int"
SET enc2 xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx => +OK
    events: __keyspace@0__:enc2 set | __keyevent@0__:set enc2
OBJECT ENCODING enc2 => "embstr"
SET enc3 xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx => +OK
    events: __keyspace@0__:enc3 set | __keyevent@0__:set enc3
OBJECT ENCODING enc3 => "raw"
SET enc4 -9223372036854775808 => +OK
    events: __keyspace@0__:enc4 set | __keyevent@0__:set enc4
OBJECT ENCODING enc4 => "int"
SET enc5 9223372036854775808 => +OK
    events: __keyspace@0__:enc5 set | __keyevent@0__:set enc5
OBJECT ENCODING enc5 => "embstr"
SET enc6 007 => +OK
    events: __keyspace@0__:enc6 set | __keyevent@0__:set enc6
OBJECT ENCODING enc6 => "embstr"
SET enc7 -0 => +OK
    events: __keyspace@0__:enc7 set | __keyevent@0__:set enc7
OBJECT ENCODING enc7 => "embstr"
SET enc8 +7 => +OK
    events: __keyspace@0__:enc8 set | __keyevent@0__:set enc8
OBJECT ENCODING enc8 => "embstr"
SET enc9 0 => +OK
    events: __keyspace@0__:enc9 set | __keyevent@0__:set enc9
OBJECT ENCODING enc9 => "int"
SET enc10 1.5 => +OK
    events: __keyspace@0__:enc10 set | __keyevent@0__:set enc10
OBJECT ENCODING enc10 => "embstr"
SETRANGE enc9 0 5 => :1
    events: __keyspace@0__:enc9 setrange | __keyevent@0__:setrange enc9
OBJECT ENCODING enc9 => "raw"
GET enc9 => "5"
APPEND enc1 "" => :5
    events: __keyspace@0__:enc1 append | __keyevent@0__:append enc1
OBJECT ENCODING enc1 => "raw"
INCR enc6 => -ERR value is not an integer or out of range
GET enc6 => "007"
OBJECT ENCODING enc6 => "embstr"
SET enc11 abc => +OK
    events: __keyspace@0__:enc11 set | __keyevent@0__:set enc11
GETEX enc11 EX 10 => "abc"
    events: __keyspace@0__:enc11 expire | __keyevent@0__:expire enc11
DBSIZE => :71
`

INLINE_IFEQ_CASES := `

## IFEQ
SET k v1 => +OK
    events: __keyspace@0__:k set | __keyevent@0__:set k
SET k v2 IFEQ v1 => +OK
    events: __keyspace@0__:k set | __keyevent@0__:set k
GET k => "v2"
SET k v3 IFEQ v1 => nil
GET k => "v2"
SET missing v IFEQ x => nil
EXISTS missing => :0
SET missing v IFEQ "" => nil
SET k v4 IFEQ v2 GET => "v2"
    events: __keyspace@0__:k set | __keyevent@0__:set k
GET k => "v4"
SET k v5 IFEQ wrong GET => "v4"
GET k => "v4"
SET missing v IFEQ x GET => nil
SET k v6 GET IFEQ v4 => "v4"
    events: __keyspace@0__:k set | __keyevent@0__:set k
GET k => "v6"
SET k v7 IFEQ v6 EX 100 => +OK
    events: __keyspace@0__:k set | __keyevent@0__:set k | __keyspace@0__:k expire | __keyevent@0__:expire k
TTL k => integer within [99, 100]
SET k v8 IFEQ v7 KEEPTTL => +OK
    events: __keyspace@0__:k set | __keyevent@0__:set k
TTL k => integer within [98, 100]
SET k v9 IFEQ v8 => +OK
    events: __keyspace@0__:k set | __keyevent@0__:set k
TTL k => :-1
SET k v10 IFEQ v9 NX => -ERR syntax error
SET k v10 IFEQ v9 XX => -ERR syntax error
SET k v10 NX IFEQ v9 => -ERR syntax error
SET k v10 XX IFEQ v9 => -ERR syntax error
SET k v10 IFEQ v9 IFEQ v9 => -ERR syntax error
SET k v10 IFEQ => -ERR syntax error
SET k v10 ifeq v9 => +OK
    events: __keyspace@0__:k set | __keyevent@0__:set k
GET k => "v10"
SET k v11 IFEQ v10 EX 0 => -ERR invalid expire time in 'set' command
SET k v11 IFEQ wrong EX 0 => -ERR invalid expire time in 'set' command
SET k v11 IFEQ v10 BOGUS => -ERR syntax error
SET k v11 IFEQ wrong BOGUS => -ERR syntax error
RPUSH l a => :1
    events: __keyspace@0__:l rpush | __keyevent@0__:rpush l
SET l v IFEQ a => -WRONGTYPE Operation against a key holding the wrong kind of value
SET l v IFEQ a GET => -WRONGTYPE Operation against a key holding the wrong kind of value
TYPE l => +list
SET n 10 => +OK
    events: __keyspace@0__:n set | __keyevent@0__:set n
SET n 11 IFEQ 10 => +OK
    events: __keyspace@0__:n set | __keyevent@0__:set n
SET n 12 IFEQ 011 => nil
GET n => "11"
SET e v EX 100 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e | __keyspace@0__:e expire | __keyevent@0__:expire e
SET e w IFEQ v => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e
TTL e => :-1
SET e x IFEQ w PX 100000 => +OK
    events: __keyspace@0__:e set | __keyevent@0__:set e | __keyspace@0__:e expire | __keyevent@0__:expire e
PTTL e => integer within [99000, 100000]
SET bin hex[3]=610062 => +OK
    events: __keyspace@0__:bin set | __keyevent@0__:set bin
SET bin c IFEQ hex[3]=610062 => +OK
    events: __keyspace@0__:bin set | __keyevent@0__:set bin
GET bin => "c"
SET k v12 IFEQ v10 GET KEEPTTL => "v10"
    events: __keyspace@0__:k set | __keyevent@0__:set k
DBSIZE => :5
`

INLINE_SCORE_CASES := `
## scores arithmetic that produces rounding
DEL z => ?
ZADD z 0.1 a => :1
2| ZINCRBY z 0.2 a => "0.30000000000000004"
3| ZINCRBY z 0.2 a => ,0.30000000000000004
2| ZINCRBY z 0.1 a => "0.4"
3| ZINCRBY z 0.1 a => ,0.4
2| ZINCRBY z 1e16 a => "10000000000000000"
3| ZINCRBY z 1e16 a => ,10000000000000000
2| ZINCRBY z 1 a => "10000000000000000"
3| ZINCRBY z 1 a => ,10000000000000000
2| ZINCRBY z -1e16 a => "0"
3| ZINCRBY z -1e16 a => ,0
2| ZSCORE z a => "0"
3| ZSCORE z a => ,0
DEL z => ?
ZADD z 1e21 a => :1
2| ZINCRBY z 1 a => "1e+21"
3| ZINCRBY z 1 a => ,1e+21
2| ZINCRBY z -1e21 a => "0"
3| ZINCRBY z -1e21 a => ,0
DEL z => ?
ZADD z 9007199254740992 a => :1
2| ZINCRBY z 1 a => "9007199254740992"
3| ZINCRBY z 1 a => ,9007199254740992
2| ZINCRBY z 1 a => "9007199254740992"
3| ZINCRBY z 1 a => ,9007199254740992
DEL z => ?
ZADD z 1.7976931348623157e308 a => :1
2| ZINCRBY z 1.7976931348623157e308 a => "inf"
3| ZINCRBY z 1.7976931348623157e308 a => ,inf
2| ZINCRBY z -1.7976931348623157e308 a => "inf"
3| ZINCRBY z -1.7976931348623157e308 a => ,inf
DEL z => ?
ZADD z inf a => :1
ZINCRBY z -inf a => -ERR resulting score is not a number (NaN)
2| ZINCRBY z 1 a => "inf"
3| ZINCRBY z 1 a => ,inf
DEL z => ?
ZADD z 0 a => :1
2| ZINCRBY z -0 a => "0"
3| ZINCRBY z -0 a => ,0
ZADD z -0 b => :1
2| ZRANGE z 0 -1 WITHSCORES => ["a", "0", "b", "0"]
3| ZRANGE z 0 -1 WITHSCORES => [["a", ,0], ["b", ,0]]
2| ZINCRBY z 0 b => "0"
3| ZINCRBY z 0 b => ,0
DEL z => ?
ZADD z 1 a 2 b 3 c => :3
2| ZUNION 1 z WITHSCORES => ["a", "1", "b", "2", "c", "3"]
3| ZUNION 1 z WITHSCORES => [["a", ,1], ["b", ,2], ["c", ,3]]
2| ZUNION 2 z z WITHSCORES => ["a", "2", "b", "4", "c", "6"]
3| ZUNION 2 z z WITHSCORES => [["a", ,2], ["b", ,4], ["c", ,6]]
2| ZUNION 2 z z WEIGHTS 0.1 0.2 WITHSCORES => ["a", "0.30000000000000004", "b", "0.6000000000000001", "c", "0.9000000000000001"]
3| ZUNION 2 z z WEIGHTS 0.1 0.2 WITHSCORES => [["a", ,0.30000000000000004], ["b", ,0.6000000000000001], ["c", ,0.9000000000000001]]
2| ZINTER 2 z z WEIGHTS 1e15 1e15 WITHSCORES => ["a", "2000000000000000", "b", "4000000000000000", "c", "6000000000000000"]
3| ZINTER 2 z z WEIGHTS 1e15 1e15 WITHSCORES => [["a", ,2000000000000000], ["b", ,4000000000000000], ["c", ,6000000000000000]]
2| ZRANDMEMBER z 1 WITHSCORES => ["b", "2"]
3| ZRANDMEMBER z 1 WITHSCORES => [["b", ,2]]
2| ZPOPMIN z => ["a", "1"]
3| ZPOPMIN z => ["a", ,1]
2| ZPOPMAX z 2 => ["c", "3", "b", "2"]
3| ZPOPMAX z 2 => [["c", ,3], ["b", ,2]]
## bit patterns through DEBUG and ZSCAN
DEL z => ?
ZADD z 0.1 v0.1 => :1
ZADD z 1e21 v1e21 => :1
ZADD z 1e16 v1e16 => :1
ZADD z 123456789012345678 v123456789012345678 => :1
ZADD z 5e-324 v5e-324 => :1
ZADD z 0.000001 v0.000001 => :1
ZADD z 0.0000001 v0.0000001 => :1
ZADD z 1.5 v1.5 => :1
ZADD z 100 v100 => :1
ZSCAN z 0 => ["0", ["v5e-324", "5e-324", "v0.0000001", "1e-7", "v0.000001", "0.000001", "v0.1", "0.1", "v1.5", "1.5", "v100", "100", "v1e16", "10000000000000000", "v123456789012345678", "123456789012345680", "v1e21", "1e+21"]]
2| ZRANGEBYSCORE z -inf +inf WITHSCORES => ["v5e-324", "5e-324", "v0.0000001", "1e-7", "v0.000001", "0.000001", "v0.1", "0.1", "v1.5", "1.5", "v100", "100", "v1e16", "10000000000000000", "v123456789012345678", "123456789012345680", "v1e21", "1e+21"]
3| ZRANGEBYSCORE z -inf +inf WITHSCORES => [["v5e-324", ,5e-324], ["v0.0000001", ,1e-7], ["v0.000001", ,0.000001], ["v0.1", ,0.1], ["v1.5", ,1.5], ["v100", ,100], ["v1e16", ,10000000000000000], ["v123456789012345678", ,123456789012345680], ["v1e21", ,1e+21]]
2| ZRANGE z 0 -1 WITHSCORES => ["v5e-324", "5e-324", "v0.0000001", "1e-7", "v0.000001", "0.000001", "v0.1", "0.1", "v1.5", "1.5", "v100", "100", "v1e16", "10000000000000000", "v123456789012345678", "123456789012345680", "v1e21", "1e+21"]
3| ZRANGE z 0 -1 WITHSCORES => [["v5e-324", ,5e-324], ["v0.0000001", ,1e-7], ["v0.000001", ,0.000001], ["v0.1", ,0.1], ["v1.5", ,1.5], ["v100", ,100], ["v1e16", ,10000000000000000], ["v123456789012345678", ,123456789012345680], ["v1e21", ,1e+21]]
`

INLINE_LCS_TYPE_CASES := `
SET s abc => +OK
RPUSH l a => :1
HSET h f v => :1
LCS s l => -ERR The specified keys must contain string values
LCS l s => -ERR The specified keys must contain string values
LCS l l => -ERR The specified keys must contain string values
LCS h s => -ERR The specified keys must contain string values
LCS s h LEN => -ERR The specified keys must contain string values
LCS s l IDX => -ERR The specified keys must contain string values
LCS l missing => -ERR The specified keys must contain string values
LCS missing l => -ERR The specified keys must contain string values
LCS l s BOGUS => -ERR The specified keys must contain string values
LCS s l LEN IDX => -ERR The specified keys must contain string values
LCS s l MINMATCHLEN abc => -ERR The specified keys must contain string values
LCS missing missing BOGUS => -ERR syntax error
LCS s s BOGUS => -ERR syntax error
LCS s s LEN IDX => -ERR If you want both the length and indexes, please just use IDX.
LCS missing missing LEN IDX => -ERR If you want both the length and indexes, please just use IDX.
DBSIZE => :3
`

Double_Case :: struct {
	text:   string,
	bits:   u64,
	score:  string,
	incr:   string,
	error:  string,
}

DOUBLE_CASES := [?]Double_Case {
	{"0", 0x0000000000000000, "0", "0", ""},
	{"-0", 0x8000000000000000, "0", "-0", ""},
	{"0.0", 0x0000000000000000, "0", "0", ""},
	{"-0.0", 0x8000000000000000, "0", "-0", ""},
	{"1", 0x3FF0000000000000, "1", "1", ""},
	{"-1", 0xBFF0000000000000, "-1", "-1", ""},
	{"2", 0x4000000000000000, "2", "2", ""},
	{"10", 0x4024000000000000, "10", "10", ""},
	{"100", 0x4059000000000000, "100", "100", ""},
	{"1000", 0x408F400000000000, "1000", "1000", ""},
	{"12345", 0x40C81C8000000000, "12345", "12345", ""},
	{"-12345", 0xC0C81C8000000000, "-12345", "-12345", ""},
	{"0.5", 0x3FE0000000000000, "0.5", "0.5", ""},
	{"-0.5", 0xBFE0000000000000, "-0.5", "-0.5", ""},
	{"1.5", 0x3FF8000000000000, "1.5", "1.5", ""},
	{"0.1", 0x3FB999999999999A, "0.1", "0.1", ""},
	{"0.2", 0x3FC999999999999A, "0.2", "0.2", ""},
	{"0.3", 0x3FD3333333333333, "0.3", "0.3", ""},
	{"0.30000000000000004", 0x3FD3333333333334, "0.30000000000000004", "0.30000000000000004", ""},
	{"3.14159", 0x400921F9F01B866E, "3.14159", "3.14159", ""},
	{"3.141592653589793", 0x400921FB54442D18, "3.141592653589793", "3.141592653589793", ""},
	{"2.718281828459045", 0x4005BF0A8B145769, "2.718281828459045", "2.718281828459045", ""},
	{"1e0", 0x3FF0000000000000, "1", "1", ""},
	{"1e1", 0x4024000000000000, "10", "10", ""},
	{"1e2", 0x4059000000000000, "100", "100", ""},
	{"1e5", 0x40F86A0000000000, "100000", "100000", ""},
	{"1e15", 0x430C6BF526340000, "1000000000000000", "1000000000000000", ""},
	{"1e16", 0x4341C37937E08000, "10000000000000000", "10000000000000000", ""},
	{"1e17", 0x4376345785D8A000, "100000000000000000", "100000000000000000", ""},
	{"1e18", 0x43ABC16D674EC800, "1000000000000000000", "1000000000000000000", ""},
	{"1e19", 0x43E158E460913D00, "1e+19", "1e+19", ""},
	{"1e20", 0x4415AF1D78B58C40, "1e+20", "1e+20", ""},
	{"1e21", 0x444B1AE4D6E2EF50, "1e+21", "1e+21", ""},
	{"1e22", 0x4480F0CF064DD592, "1e+22", "1e+22", ""},
	{"1e23", 0x44B52D02C7E14AF6, "99999999999999990000000", "99999999999999990000000", ""},
	{"1e100", 0x54B249AD2594C37D, "1e+100", "1e+100", ""},
	{"1e300", 0x7E37E43C8800759C, "1e+300", "1e+300", ""},
	{"1.5e15", 0x431550F7DCA70000, "1500000000000000", "1500000000000000", ""},
	{"1.5e16", 0x434AA535D3D0C000, "15000000000000000", "15000000000000000", ""},
	{"1.5e17", 0x4380A741A4627800, "150000000000000000", "150000000000000000", ""},
	{"123456789012345678", 0x437B69B4BA630F35, "123456789012345680", "123456789012345680", ""},
	{"1234567890123456789", 0x43B12210F47DE981, "1234567890123456768", "1234567890123456768", ""},
	{"12345678901234567890", 0x43E56A95319D63E1, "12345678901234567000", "12345678901234567000", ""},
	{"9007199254740992", 0x4340000000000000, "9007199254740992", "9007199254740992", ""},
	{"9007199254740993", 0x4340000000000000, "9007199254740992", "9007199254740992", ""},
	{"9007199254740994", 0x4340000000000001, "9007199254740994", "9007199254740994", ""},
	{"4503599627370496.5", 0x4330000000000000, "4503599627370496", "4503599627370496", ""},
	{"4503599627370497", 0x4330000000000001, "4503599627370497", "4503599627370497", ""},
	{"9223372036854775807", 0x43E0000000000000, "9223372036854776000", "9223372036854776000", ""},
	{"9223372036854775808", 0x43E0000000000000, "9223372036854776000", "9223372036854776000", ""},
	{"-9223372036854775808", 0xC3E0000000000000, "-9223372036854776000", "-9223372036854776000", ""},
	{"-9223372036854775809", 0xC3E0000000000000, "-9223372036854776000", "-9223372036854776000", ""},
	{"18446744073709551616", 0x43F0000000000000, "18446744073709552000", "18446744073709552000", ""},
	{"1e-1", 0x3FB999999999999A, "0.1", "0.1", ""},
	{"1e-2", 0x3F847AE147AE147B, "0.01", "0.01", ""},
	{"1e-3", 0x3F50624DD2F1A9FC, "0.001", "0.001", ""},
	{"1e-4", 0x3F1A36E2EB1C432D, "0.0001", "0.0001", ""},
	{"1e-5", 0x3EE4F8B588E368F1, "0.00001", "0.00001", ""},
	{"1e-6", 0x3EB0C6F7A0B5ED8D, "0.000001", "0.000001", ""},
	{"1e-7", 0x3E7AD7F29ABCAF48, "1e-7", "1e-7", ""},
	{"1e-8", 0x3E45798EE2308C3A, "1e-8", "1e-8", ""},
	{"1e-10", 0x3DDB7CDFD9D7BDBB, "1e-10", "1e-10", ""},
	{"1e-20", 0x3BC79CA10C924223, "1e-20", "1e-20", ""},
	{"1e-100", 0x2B2BFF2EE48E0530, "1e-100", "1e-100", ""},
	{"1e-300", 0x01A56E1FC2F8F359, "1e-300", "1e-300", ""},
	{"0.000001", 0x3EB0C6F7A0B5ED8D, "0.000001", "0.000001", ""},
	{"0.0000001", 0x3E7AD7F29ABCAF48, "1e-7", "1e-7", ""},
	{"0.00001234", 0x3EE9E0FCAF9380FC, "1.234e-5", "1.234e-5", ""},
	{"0.0001234", 0x3F202C9DEDBC309D, "1.234e-4", "1.234e-4", ""},
	{"1.234e-5", 0x3EE9E0FCAF9380FC, "1.234e-5", "1.234e-5", ""},
	{"1.234e-7", 0x3E808FFDE1023E12, "1.234e-7", "1.234e-7", ""},
	{"123.456", 0x405EDD2F1A9FBE77, "123.456", "123.456", ""},
	{"-123.456", 0xC05EDD2F1A9FBE77, "-123.456", "-123.456", ""},
	{"100.0", 0x4059000000000000, "100", "100", ""},
	{"100.5", 0x4059200000000000, "100.5", "100.5", ""},
	{"1.7976931348623157e308", 0x7FEFFFFFFFFFFFFF, "1.7976931348623157e+308", "1.7976931348623157e+308", ""},
	{"-1.7976931348623157e308", 0xFFEFFFFFFFFFFFFF, "-1.7976931348623157e+308", "-1.7976931348623157e+308", ""},
	{"2.2250738585072014e-308", 0x0010000000000000, "2.2250738585072014e-308", "2.2250738585072014e-308", ""},
	{"5e-324", 0x0000000000000001, "5e-324", "5e-324", ""},
	{"4.9406564584124654e-324", 0x0000000000000001, "5e-324", "5e-324", ""},
	{"2.2250738585072009e-308", 0x000FFFFFFFFFFFFF, "2.225073858507201e-308", "2.225073858507201e-308", ""},
	{"1.0000000000000002", 0x3FF0000000000001, "1.0000000000000002", "1.0000000000000002", ""},
	{"0.9999999999999999", 0x3FEFFFFFFFFFFFFF, "0.9999999999999999", "0.9999999999999999", ""},
	{"0.1234567890123456789", 0x3FBF9ADD3746F65F, "0.12345678901234568", "0.12345678901234568", ""},
	{"1234567890.1234567890", 0x41D26580B487E6B7, "1.2345678901234567e+9", "1.2345678901234567e+9", ""},
	{"123456789.123456789", 0x419D6F34547E6B75, "1.2345678912345679e+8", "1.2345678912345679e+8", ""},
	{"1e+21", 0x444B1AE4D6E2EF50, "1e+21", "1e+21", ""},
	{"1E21", 0x444B1AE4D6E2EF50, "1e+21", "1e+21", ""},
	{"1e+016", 0x4341C37937E08000, "10000000000000000", "10000000000000000", ""},
	{"2.5e-5", 0x3EFA36E2EB1C432D, "0.000025", "0.000025", ""},
	{"7e22", 0x44ADA56A4B0835C0, "70000000000000004000000", "70000000000000004000000", ""},
	{"1.2345678901234567e+30", 0x462F2A353F47450D, "1.2345678901234567e+30", "1.2345678901234567e+30", ""},
	{"9.999999999999999e22", 0x44B52D02C7E14AF6, "99999999999999990000000", "99999999999999990000000", ""},
	{"1e23", 0x44B52D02C7E14AF6, "99999999999999990000000", "99999999999999990000000", ""},
	{"8.5e21", 0x447CCC9324511E45, "8.5e+21", "8.5e+21", ""},
	{"1125899906842624", 0x4310000000000000, "1125899906842624", "1125899906842624", ""},
	{"1125899906842624.5", 0x4310000000000002, "1125899906842624.5", "1125899906842624.5", ""},
	{"72057594037927936", 0x4370000000000000, "72057594037927936", "72057594037927936", ""},
	{"72057594037927937", 0x4370000000000000, "72057594037927936", "72057594037927936", ""},
	{"-72057594037927936", 0xC370000000000000, "-72057594037927936", "-72057594037927936", ""},
	{"2.5", 0x4004000000000000, "2.5", "2.5", ""},
	{"2.50", 0x4004000000000000, "2.5", "2.5", ""},
	{"0.25", 0x3FD0000000000000, "0.25", "0.25", ""},
	{"1024", 0x4090000000000000, "1024", "1024", ""},
	{"1048576", 0x4130000000000000, "1048576", "1048576", ""},
	{"1073741824", 0x41D0000000000000, "1073741824", "1073741824", ""},
	{"4294967296", 0x41F0000000000000, "4294967296", "4294967296", ""},
	{"4294967297", 0x41F0000000100000, "4294967297", "4294967297", ""},
	{"281474976710656", 0x42F0000000000000, "281474976710656", "281474976710656", ""},
	{"281474976710657", 0x42F0000000000010, "281474976710657", "281474976710657", ""},
	{"1e8", 0x4197D78400000000, "100000000", "100000000", ""},
	{"1e9", 0x41CDCD6500000000, "1000000000", "1000000000", ""},
	{"1e10", 0x4202A05F20000000, "10000000000", "10000000000", ""},
	{"1e11", 0x42374876E8000000, "100000000000", "100000000000", ""},
	{"1e12", 0x426D1A94A2000000, "1000000000000", "1000000000000", ""},
	{"1e13", 0x42A2309CE5400000, "10000000000000", "10000000000000", ""},
	{"1e14", 0x42D6BCC41E900000, "100000000000000", "100000000000000", ""},
	{"123456789012", 0x423CBE991A140000, "123456789012", "123456789012", ""},
	{"-1e15", 0xC30C6BF526340000, "-1000000000000000", "-1000000000000000", ""},
	{"-1e16", 0xC341C37937E08000, "-10000000000000000", "-10000000000000000", ""},
	{"-1e17", 0xC376345785D8A000, "-100000000000000000", "-100000000000000000", ""},
	{"-1e21", 0xC44B1AE4D6E2EF50, "-1e+21", "-1e+21", ""},
	{"-1e22", 0xC480F0CF064DD592, "-1e+22", "-1e+22", ""},
	{"0.1e1", 0x3FF0000000000000, "1", "1", ""},
	{"15e-1", 0x3FF8000000000000, "1.5", "1.5", ""},
	{"1.0", 0x3FF0000000000000, "1", "1", ""},
	{"1.00", 0x3FF0000000000000, "1", "1", ""},
	{"001", 0x3FF0000000000000, "1", "1", ""},
	{"1.5e0", 0x3FF8000000000000, "1.5", "1.5", ""},
	{"12.0", 0x4028000000000000, "12", "12", ""},
	{"12.5", 0x4029000000000000, "12.5", "12.5", ""},
	{"0.75", 0x3FE8000000000000, "0.75", "0.75", ""},
	{"0.125", 0x3FC0000000000000, "0.125", "0.125", ""},
	{"0.1e-5", 0x3EB0C6F7A0B5ED8D, "0.000001", "0.000001", ""},
	{"0.00001", 0x3EE4F8B588E368F1, "0.00001", "0.00001", ""},
	{"0.000011", 0x3EE711947CFA26A2, "0.000011", "0.000011", ""},
	{"inf", 0x7FF0000000000000, "inf", "inf", ""},
	{"+inf", 0x7FF0000000000000, "inf", "inf", ""},
	{"-inf", 0xFFF0000000000000, "-inf", "-inf", ""},
	{"infinity", 0x7FF0000000000000, "inf", "inf", ""},
	{"-Infinity", 0xFFF0000000000000, "-inf", "-inf", ""},
	{"1e400", 0x0000000000000000, "", "", "-ERR value is not a valid float"},
	{"-1e400", 0x0000000000000000, "", "", "-ERR value is not a valid float"},
	{"1e-400", 0x0000000000000000, "", "", "-ERR value is not a valid float"},
	{"1.1", 0x3FF199999999999A, "1.1", "1.1", ""},
	{"2.2", 0x400199999999999A, "2.2", "2.2", ""},
	{"3.3", 0x400A666666666666, "3.3", "3.3", ""},
	{"4.4", 0x401199999999999A, "4.4", "4.4", ""},
	{"5.5", 0x4016000000000000, "5.5", "5.5", ""},
	{"6.6", 0x401A666666666666, "6.6", "6.6", ""},
	{"7.7", 0x401ECCCCCCCCCCCD, "7.7", "7.7", ""},
	{"8.8", 0x402199999999999A, "8.8", "8.8", ""},
	{"9.9", 0x4023CCCCCCCCCCCD, "9.9", "9.9", ""},
	{"10.1", 0x4024333333333333, "10.1", "10.1", ""},
	{"99.99", 0x4058FF5C28F5C28F, "99.99", "99.99", ""},
	{"0.01", 0x3F847AE147AE147B, "0.01", "0.01", ""},
	{"0.001", 0x3F50624DD2F1A9FC, "0.001", "0.001", ""},
	{"33.333333333333336", 0x4040AAAAAAAAAAAB, "33.333333333333336", "33.333333333333336", ""},
	{"66.66666666666667", 0x4050AAAAAAAAAAAB, "66.66666666666667", "66.66666666666667", ""},
	{"0.3333333333333333", 0x3FD5555555555555, "0.3333333333333333", "0.3333333333333333", ""},
	{"0.6666666666666666", 0x3FE5555555555555, "0.6666666666666666", "0.6666666666666666", ""},
	{"1e16", 0x4341C37937E08000, "10000000000000000", "10000000000000000", ""},
	{"12345678901234567", 0x4345EE2A2EB5A5C4, "12345678901234568", "12345678901234568", ""},
	{"123456789012345678", 0x437B69B4BA630F35, "123456789012345680", "123456789012345680", ""},
	{"1.2345678901234568e+17", 0x437B69B4BA630F35, "123456789012345680", "123456789012345680", ""},
	{"1.2345678901234568e+18", 0x43B12210F47DE981, "1234567890123456768", "1234567890123456768", ""},
	{"3e7", 0x417C9C3800000000, "30000000", "30000000", ""},
	{"30000000", 0x417C9C3800000000, "30000000", "30000000", ""},
	{"3e8", 0x41B1E1A300000000, "300000000", "300000000", ""},
	{"3e9", 0x41E65A0BC0000000, "3000000000", "3000000000", ""},
	{"3e16", 0x435AA535D3D0C000, "30000000000000000", "30000000000000000", ""},
	{"3e17", 0x4390A741A4627800, "300000000000000000", "300000000000000000", ""},
	{"1.5e300", 0x7E41EB2D66005835, "1.5e+300", "1.5e+300", ""},
	{"-1.5e300", 0xFE41EB2D66005835, "-1.5e+300", "-1.5e+300", ""},
	{"2e-7", 0x3E8AD7F29ABCAF48, "2e-7", "2e-7", ""},
	{"2e-6", 0x3EC0C6F7A0B5ED8D, "0.000002", "0.000002", ""},
}
