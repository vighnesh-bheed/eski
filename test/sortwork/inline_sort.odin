package sortwork

INLINE_SORT :: `# SORT and SORT_RO observations, Redis 7.4.11, protocol 2, keyspace events KEA

## numeric sort of a list
RPUSH l 3 1 2 10 -5 2.5 1e2 0 => :8
    events: __keyspace@0__:l rpush | __keyevent@0__:rpush l
SORT l => ["-5", "0", "1", "2", "2.5", "3", "10", "1e2"]
SORT l DESC => ["1e2", "10", "3", "2.5", "2", "1", "0", "-5"]
SORT l ASC => ["-5", "0", "1", "2", "2.5", "3", "10", "1e2"]
SORT l asc => ["-5", "0", "1", "2", "2.5", "3", "10", "1e2"]
SORT l LIMIT 0 3 => ["-5", "0", "1"]
SORT l LIMIT 2 3 => ["1", "2", "2.5"]
SORT l LIMIT 6 10 => ["10", "1e2"]
SORT l LIMIT 8 10 => []
SORT l LIMIT 100 10 => []
SORT l LIMIT 0 0 => []
SORT l LIMIT 0 -1 => ["-5", "0", "1", "2", "2.5", "3", "10", "1e2"]
SORT l LIMIT 3 -1 => ["2", "2.5", "3", "10", "1e2"]
SORT l LIMIT -1 3 => ["-5", "0", "1"]
SORT l LIMIT -5 3 => ["-5", "0", "1"]
SORT l LIMIT -1 -1 => ["-5", "0", "1", "2", "2.5", "3", "10", "1e2"]
SORT l LIMIT 0 2 DESC => ["1e2", "10"]
SORT l LIMIT abc 2 => -ERR value is not an integer or out of range
SORT l LIMIT 0 abc => -ERR value is not an integer or out of range
SORT l LIMIT 0 => -ERR syntax error
SORT l LIMIT => -ERR syntax error
SORT l LIMIT 9223372036854775807 1 => []
SORT l LIMIT 0 9223372036854775807 => ["-5", "0", "1", "2", "2.5", "3", "10", "1e2"]
SORT l LIMIT -9223372036854775808 9223372036854775807 => ["-5", "0", "1", "2", "2.5", "3", "10", "1e2"]
SORT l LIMIT 1 -9223372036854775808 => ["0", "1", "2", "2.5", "3", "10", "1e2"]
SORT l LIMIT 0 3 LIMIT 1 2 => ["0", "1"]
SORT l DESC ASC => ["-5", "0", "1", "2", "2.5", "3", "10", "1e2"]
SORT l ASC DESC => ["1e2", "10", "3", "2.5", "2", "1", "0", "-5"]
SORT l BOGUS => -ERR syntax error
SORT l ALPHA BOGUS => -ERR syntax error
SORT => -ERR wrong number of arguments for 'sort' command
SORT l DESC LIMIT 1 2 ALPHA => ["2.5", "2"]
RPUSH bad 1 abc 2 => :3
    events: __keyspace@0__:bad rpush | __keyevent@0__:rpush bad
SORT bad => -ERR One or more scores can't be converted into double
SORT bad ALPHA => ["1", "2", "abc"]
SORT bad LIMIT 0 1 => -ERR One or more scores can't be converted into double
SORT bad BY nosort => ["1", "abc", "2"]
RPUSH bad2 1 "" 2 => :3
    events: __keyspace@0__:bad2 rpush | __keyevent@0__:rpush bad2
SORT bad2 => ["", "1", "2"]
RPUSH bad3 1 " 2" 3 => :3
    events: __keyspace@0__:bad3 rpush | __keyevent@0__:rpush bad3
SORT bad3 => ["1", " 2", "3"]
RPUSH bad4 1 "2 " 3 => :3
    events: __keyspace@0__:bad4 rpush | __keyevent@0__:rpush bad4
SORT bad4 => -ERR One or more scores can't be converted into double
RPUSH bad5 inf -inf 1 nan => :4
    events: __keyspace@0__:bad5 rpush | __keyevent@0__:rpush bad5
SORT bad5 => -ERR One or more scores can't be converted into double
RPUSH bad6 inf -inf 1 +inf 1e400 => :5
    events: __keyspace@0__:bad6 rpush | __keyevent@0__:rpush bad6
SORT bad6 => -ERR One or more scores can't be converted into double
RPUSH bad7 0x10 1 2 => :3
    events: __keyspace@0__:bad7 rpush | __keyevent@0__:rpush bad7
SORT bad7 => -ERR One or more scores can't be converted into double
RPUSH bad8 1,5 1 2 => :3
    events: __keyspace@0__:bad8 rpush | __keyevent@0__:rpush bad8
SORT bad8 => -ERR One or more scores can't be converted into double
RPUSH bad9 .5 5. 1e +1 -0 00 => :6
    events: __keyspace@0__:bad9 rpush | __keyevent@0__:rpush bad9
SORT bad9 => -ERR One or more scores can't be converted into double
RPUSH bad10 1 1.0 1.00 1e0 01 +1 => :6
    events: __keyspace@0__:bad10 rpush | __keyevent@0__:rpush bad10
SORT bad10 => -ERR One or more scores can't be converted into double
SORT bad10 DESC => -ERR One or more scores can't be converted into double
RPUSH hex 1 0x1A 2 => :3
    events: __keyspace@0__:hex rpush | __keyevent@0__:rpush hex
SORT hex => -ERR One or more scores can't be converted into double
RPUSH ws 1 	2 3
 => :3
    events: __keyspace@0__:ws rpush | __keyevent@0__:rpush ws
SORT ws => -ERR One or more scores can't be converted into double
RPUSH longnum 12345678901234567890 1 9223372036854775808 1e19 => :4
    events: __keyspace@0__:longnum rpush | __keyevent@0__:rpush longnum
SORT longnum => -ERR One or more scores can't be converted into double
RPUSH prec 9007199254740993 9007199254740992 9007199254740994 9007199254740992.5 => :4
    events: __keyspace@0__:prec rpush | __keyevent@0__:rpush prec
SORT prec => -ERR One or more scores can't be converted into double
SORT prec DESC => -ERR One or more scores can't be converted into double
RPUSH big {50..1} => :50
    events: __keyspace@0__:big rpush | __keyevent@0__:rpush big
SORT big LIMIT 0 5 => ["1", "2", "3", "4", "5"]
SORT big LIMIT 45 10 => ["46", "47", "48", "49", "50"]
SORT big LIMIT 0 5 DESC => ["50", "49", "48", "47", "46"]
SORT big LIMIT 10 5 => ["11", "12", "13", "14", "15"]
SORT big LIMIT 10 5 DESC => ["40", "39", "38", "37", "36"]
SORT big LIMIT 40 100 DESC => ["10", "9", "8", "7", "6", "5", "4", "3", "2", "1"]
SORT big LIMIT 49 1 => ["50"]
SORT big LIMIT 50 1 => []

## ALPHA sort
RPUSH a banana apple Cherry apple ápple "" b B a1 a10 a2 => :11
    events: __keyspace@0__:a rpush | __keyevent@0__:rpush a
SORT a ALPHA => ["", "B", "Cherry", "a1", "a10", "a2", "apple", "apple", "b", "banana", hex[6]=c3a170706c65]
SORT a ALPHA DESC => [hex[6]=c3a170706c65, "banana", "b", "apple", "apple", "a2", "a10", "a1", "Cherry", "B", ""]
SORT a alpha => ["", "B", "Cherry", "a1", "a10", "a2", "apple", "apple", "b", "banana", hex[6]=c3a170706c65]
SORT a ALPHA LIMIT 1 3 => ["B", "Cherry", "a1"]
SORT a ALPHA LIMIT 1 3 DESC => ["banana", "b", "apple"]
SORT a => -ERR One or more scores can't be converted into double
RPUSH bin hex[3]=610062 hex[3]=610061 a hex[2]=6100 hex[1]=ff hex[1]=00 => :6
    events: __keyspace@0__:bin rpush | __keyevent@0__:rpush bin
SORT bin ALPHA => [hex[1]=00, hex[3]=610062, hex[3]=610061, "a", hex[2]=6100, hex[1]=ff]
SORT bin ALPHA DESC => [hex[1]=ff, hex[3]=610062, hex[3]=610061, "a", hex[2]=6100, hex[1]=00]
RPUSH pre ab a abc abd ab aa => :6
    events: __keyspace@0__:pre rpush | __keyevent@0__:rpush pre
SORT pre ALPHA => ["a", "aa", "ab", "ab", "abc", "abd"]
SORT pre ALPHA DESC => ["abd", "abc", "ab", "ab", "aa", "a"]

## sets
SADD s 3 1 2 10 => :4
    events: __keyspace@0__:s sadd | __keyevent@0__:sadd s
SORT s => -ERR One or more scores can't be converted into double
SORT s DESC => -ERR One or more scores can't be converted into double
SORT s LIMIT 1 2 => -ERR One or more scores can't be converted into double
SORT s ALPHA => ["1", "10", "2", "3"]
SADD sa b a c aa => :4
    events: __keyspace@0__:sa sadd | __keyevent@0__:sadd sa
SORT sa ALPHA => ["a", "aa", "b", "c"]
SORT sa => -ERR One or more scores can't be converted into double
SORT sa BY nosort => ["b", "a", "c", "aa"]
SORT sa BY nosort STORE sa_out => :4
    events: __keyspace@0__:sa_out sortstore | __keyevent@0__:sortstore sa_out
LRANGE sa_out 0 -1 => ["a", "aa", "b", "c"]
SORT sa BY nosort DESC STORE sa_out => :4
    events: __keyspace@0__:sa_out sortstore | __keyevent@0__:sortstore sa_out
LRANGE sa_out 0 -1 => ["c", "b", "aa", "a"]
SORT s BY nosort STORE s_out => :4
    events: __keyspace@0__:s_out sortstore | __keyevent@0__:sortstore s_out
LRANGE s_out 0 -1 => ["1", "10", "2", "3"]
SORT s BY nosort LIMIT 0 2 STORE s_out => :2
    events: __keyspace@0__:s_out sortstore | __keyevent@0__:sortstore s_out
LRANGE s_out 0 -1 => ["1", "10"]
SADD sbig {1000..1} => :1000
    events: __keyspace@0__:sbig sadd | __keyevent@0__:sadd sbig
OBJECT ENCODING sbig => "hashtable"
SORT sbig LIMIT 0 5 => -ERR One or more scores can't be converted into double
SORT sbig BY nosort LIMIT 0 5 STORE sbig_out => :5
    events: __keyspace@0__:sbig_out sortstore | __keyevent@0__:sortstore sbig_out
LRANGE sbig_out 0 -1 => ["1", "10", "100", "1000", "101"]
SADD shash x y z m{0..599} => :603
    events: __keyspace@0__:shash sadd | __keyevent@0__:sadd shash
OBJECT ENCODING shash => "hashtable"
SORT shash ALPHA LIMIT 0 5 => ["m0", "m1", "m10", "m100", "m101"]
SORT shash BY nosort LIMIT 0 5 STORE shash_out => :5
    events: __keyspace@0__:shash_out sortstore | __keyevent@0__:sortstore shash_out
LRANGE shash_out 0 -1 => ["m0", "m1", "m10", "m100", "m101"]
SORT shash BY nosort LIMIT 0 5 STORE shash_out => :5
    events: __keyspace@0__:shash_out sortstore | __keyevent@0__:sortstore shash_out
LRANGE shash_out 0 -1 => ["m0", "m1", "m10", "m100", "m101"]
SORT shash BY nosort ALPHA LIMIT 0 5 STORE shash_out => :5
    events: __keyspace@0__:shash_out sortstore | __keyevent@0__:sortstore shash_out
LRANGE shash_out 0 -1 => ["m0", "m1", "m10", "m100", "m101"]
SORT shash BY nosort ALPHA LIMIT 0 5 DESC STORE shash_out => :5
    events: __keyspace@0__:shash_out sortstore | __keyevent@0__:sortstore shash_out
LRANGE shash_out 0 -1 => ["z", "y", "x", "m99", "m98"]

## sorted sets
ZADD z 3 c 1 a 2 b 0.5 d 100 e => :5
    events: __keyspace@0__:z zadd | __keyevent@0__:zadd z
SORT z => -ERR One or more scores can't be converted into double
SORT z ALPHA => ["a", "b", "c", "d", "e"]
SORT z ALPHA DESC => ["e", "d", "c", "b", "a"]
SORT z BY nosort => ["d", "a", "b", "c", "e"]
SORT z BY nosort DESC => ["e", "c", "b", "a", "d"]
SORT z BY nosort LIMIT 1 2 => ["a", "b"]
SORT z BY nosort LIMIT 1 2 DESC => ["c", "b"]
SORT z BY nosort LIMIT 0 -1 DESC => ["e", "c", "b", "a", "d"]
SORT z BY nosort LIMIT 3 100 => ["c", "e"]
SORT z BY nosort LIMIT 10 2 => []
SORT z BY nosort LIMIT -1 2 => ["d", "a"]
SORT z BY nosort ALPHA LIMIT 1 2 => ["a", "b"]
SORT z BY nosort STORE z_out => :5
    events: __keyspace@0__:z_out sortstore | __keyevent@0__:sortstore z_out
LRANGE z_out 0 -1 => ["d", "a", "b", "c", "e"]
SORT z BY nosort DESC LIMIT 1 2 STORE z_out => :2
    events: __keyspace@0__:z_out sortstore | __keyevent@0__:sortstore z_out
LRANGE z_out 0 -1 => ["c", "b"]
ZADD zn 1 3 2 1 3 2 => :3
    events: __keyspace@0__:zn zadd | __keyevent@0__:zadd zn
SORT zn => ["1", "2", "3"]
SORT zn BY nosort => ["3", "1", "2"]
SORT zn DESC => ["3", "2", "1"]
ZADD zbig {0..299}~m{1000..701} => :300
    events: __keyspace@0__:zbig zadd | __keyevent@0__:zadd zbig
OBJECT ENCODING zbig => "skiplist"
SORT zbig ALPHA LIMIT 0 3 => ["m1000", "m701", "m702"]
SORT zbig BY nosort LIMIT 0 3 => ["m1000", "m999", "m998"]
SORT zbig BY nosort LIMIT 297 10 => ["m703", "m702", "m701"]
SORT zbig BY nosort LIMIT 0 3 DESC => ["m701", "m702", "m703"]
SORT zbig BY nosort LIMIT 297 10 DESC => ["m998", "m999", "m1000"]
ZADD ztie 1 b 1 a 1 c => :3
    events: __keyspace@0__:ztie zadd | __keyevent@0__:zadd ztie
SORT ztie BY nosort => ["a", "b", "c"]
SORT ztie BY nosort DESC => ["c", "b", "a"]

## wrong types and missing keys
SORT missing => []
SORT missing ALPHA DESC LIMIT 0 1 => []
SORT missing STORE missing_out => :0
EXISTS missing_out => :0
RPUSH missing_out x => :1
    events: __keyspace@0__:missing_out rpush | __keyevent@0__:rpush missing_out
SORT missing STORE missing_out => :0
    events: __keyspace@0__:missing_out del | __keyevent@0__:del missing_out
EXISTS missing_out => :0
SET str v => +OK
    events: __keyspace@0__:str set | __keyevent@0__:set str
SORT str => -WRONGTYPE Operation against a key holding the wrong kind of value
HSET h f v => :1
    events: __keyspace@0__:h hset | __keyevent@0__:hset h
SORT h => -WRONGTYPE Operation against a key holding the wrong kind of value
SORT h ALPHA => -WRONGTYPE Operation against a key holding the wrong kind of value
XADD xs * f v => "1793177705262-0"
    events: __keyspace@0__:xs xadd | __keyevent@0__:xadd xs
SORT xs => -WRONGTYPE Operation against a key holding the wrong kind of value
SORT str STORE out => -WRONGTYPE Operation against a key holding the wrong kind of value
SORT missing LIMIT abc 1 => -ERR value is not an integer or out of range
SORT missing BOGUS => -ERR syntax error
SORT str BOGUS => -ERR syntax error
SORT str LIMIT abc 1 => -ERR value is not an integer or out of range

## BY patterns
RPUSH ids 1 2 3 4 => :4
    events: __keyspace@0__:ids rpush | __keyevent@0__:rpush ids
MSET w_1 40 w_2 10 w_3 30 w_4 20 => +OK
    events: __keyspace@0__:w_1 set | __keyevent@0__:set w_1 | __keyspace@0__:w_2 set | __keyevent@0__:set w_2 | __keyspace@0__:w_3 set | __keyevent@0__:set w_3 | __keyspace@0__:w_4 set | __keyevent@0__:set w_4
SORT ids BY w_* => ["2", "4", "3", "1"]
SORT ids BY w_* DESC => ["1", "3", "4", "2"]
SORT ids BY w_* LIMIT 1 2 => ["4", "3"]
SORT ids BY w_* GET # => ["2", "4", "3", "1"]
SORT ids BY w_* GET w_* => ["10", "20", "30", "40"]
SORT ids BY w_* GET # GET w_* => ["2", "10", "4", "20", "3", "30", "1", "40"]
SORT ids BY w_* GET w_* GET # GET w_* => ["10", "2", "10", "20", "4", "20", "30", "3", "30", "40", "1", "40"]
SORT ids BY w_* GET missing_* => [nil, nil, nil, nil]
SORT ids GET w_* => ["40", "10", "30", "20"]
SORT ids GET # => ["1", "2", "3", "4"]
SORT ids GET nostar => [nil, nil, nil, nil]
SORT ids GET w_1 => [nil, nil, nil, nil]
SORT ids GET "" => [nil, nil, nil, nil]
SORT ids GET * => [nil, nil, nil, nil]
SORT ids GET *_x => [nil, nil, nil, nil]
SORT ids GET ** => [nil, nil, nil, nil]
SORT ids GET w_*_* => [nil, nil, nil, nil]
MSET w_1_1 a w_2_2 b => +OK
    events: __keyspace@0__:w_1_1 set | __keyevent@0__:set w_1_1 | __keyspace@0__:w_2_2 set | __keyevent@0__:set w_2_2
SORT ids GET w_*_* => [nil, nil, nil, nil]
SORT ids BY w_*_* => ["1", "2", "3", "4"]
SORT ids BY nosort => ["1", "2", "3", "4"]
SORT ids BY nosort DESC => ["4", "3", "2", "1"]
SORT ids BY NOSORT => ["1", "2", "3", "4"]
SORT ids BY nosort LIMIT 1 2 => ["2", "3"]
SORT ids BY nosort GET # => ["1", "2", "3", "4"]
SORT ids BY constant => ["1", "2", "3", "4"]
SORT ids BY constant DESC => ["4", "3", "2", "1"]
SORT ids BY "" => ["1", "2", "3", "4"]
SORT ids BY w_1 => ["1", "2", "3", "4"]
SORT ids BY nostar_*x => ["1", "2", "3", "4"]
SORT ids BY w_* BY nosort => ["1", "2", "3", "4"]
SORT ids BY nosort BY w_* => ["1", "2", "3", "4"]
SORT ids BY => -ERR syntax error
SORT ids GET => -ERR syntax error
SORT ids BY w_* ALPHA => ["2", "4", "3", "1"]
MSET w_1 d w_2 a w_3 c w_4 b => +OK
    events: __keyspace@0__:w_1 set | __keyevent@0__:set w_1 | __keyspace@0__:w_2 set | __keyevent@0__:set w_2 | __keyspace@0__:w_3 set | __keyevent@0__:set w_3 | __keyspace@0__:w_4 set | __keyevent@0__:set w_4
SORT ids BY w_* => -ERR One or more scores can't be converted into double
SORT ids BY w_* ALPHA => ["2", "4", "3", "1"]
SORT ids BY w_* ALPHA DESC => ["1", "3", "4", "2"]
MSET w_1 2 w_2 2 w_3 1 w_4 1 => +OK
    events: __keyspace@0__:w_1 set | __keyevent@0__:set w_1 | __keyspace@0__:w_2 set | __keyevent@0__:set w_2 | __keyspace@0__:w_3 set | __keyevent@0__:set w_3 | __keyspace@0__:w_4 set | __keyevent@0__:set w_4
SORT ids BY w_* => ["3", "4", "1", "2"]
SORT ids BY w_* DESC => ["2", "1", "4", "3"]
RPUSH ids2 4 3 2 1 => :4
    events: __keyspace@0__:ids2 rpush | __keyevent@0__:rpush ids2
SORT ids2 BY w_* => ["3", "4", "1", "2"]
SORT ids2 BY w_* DESC => ["2", "1", "4", "3"]
SADD sids 1 2 3 4 => :4
    events: __keyspace@0__:sids sadd | __keyevent@0__:sadd sids
SORT sids BY w_* => ["3", "4", "1", "2"]
SORT sids BY w_* DESC => ["2", "1", "4", "3"]
ZADD zids 10 1 20 2 30 3 40 4 => :4
    events: __keyspace@0__:zids zadd | __keyevent@0__:zadd zids
SORT zids BY w_* => ["3", "4", "1", "2"]
SORT zids BY w_* DESC => ["2", "1", "4", "3"]
DEL w_2 => :1
    events: __keyspace@0__:w_2 del | __keyevent@0__:del w_2
SORT ids BY w_* => ["2", "3", "4", "1"]
SORT ids BY w_* DESC => ["1", "4", "3", "2"]
SORT ids BY w_* GET w_* => [nil, "1", "1", "2"]
MSET w_1 2 w_2 2 w_3 1 w_4 1 => +OK
    events: __keyspace@0__:w_1 set | __keyevent@0__:set w_1 | __keyspace@0__:w_2 set | __keyevent@0__:set w_2 | __keyspace@0__:w_3 set | __keyevent@0__:set w_3 | __keyspace@0__:w_4 set | __keyevent@0__:set w_4
SORT ids BY missing_* => ["1", "2", "3", "4"]
SORT ids BY missing_* DESC => ["4", "3", "2", "1"]
SORT ids BY missing_* ALPHA => ["1", "2", "3", "4"]
SORT ids BY missing_* ALPHA DESC => ["1", "2", "3", "4"]
MSET w_1 1 w_2 abc w_3 3 w_4 4 => +OK
    events: __keyspace@0__:w_1 set | __keyevent@0__:set w_1 | __keyspace@0__:w_2 set | __keyevent@0__:set w_2 | __keyspace@0__:w_3 set | __keyevent@0__:set w_3 | __keyspace@0__:w_4 set | __keyevent@0__:set w_4
SORT ids BY w_* => -ERR One or more scores can't be converted into double
SORT ids BY w_* ALPHA => ["1", "3", "4", "2"]
RPUSH w_3 x => -WRONGTYPE Operation against a key holding the wrong kind of value
SORT ids BY w_* => -ERR One or more scores can't be converted into double
SORT ids BY w_* ALPHA => ["1", "3", "4", "2"]
SORT ids GET w_* => ["1", "abc", "3", "4"]
HSET w_3 f v => -WRONGTYPE Operation against a key holding the wrong kind of value
SORT ids BY w_* => -ERR One or more scores can't be converted into double
SORT ids GET w_* => ["1", "abc", "3", "4"]
SADD w_3 v => -WRONGTYPE Operation against a key holding the wrong kind of value
SORT ids BY w_* ALPHA => ["1", "3", "4", "2"]
SORT ids GET w_* => ["1", "abc", "3", "4"]
ZADD w_3 1 v => -WRONGTYPE Operation against a key holding the wrong kind of value
SORT ids BY w_* ALPHA => ["1", "3", "4", "2"]
SORT ids GET w_* => ["1", "abc", "3", "4"]
DEL w_3 => :1
    events: __keyspace@0__:w_3 del | __keyevent@0__:del w_3
SET w_3 3 => +OK
    events: __keyspace@0__:w_3 set | __keyevent@0__:set w_3
MSET w_1 1 w_2 2 w_3 3 w_4 4 => +OK
    events: __keyspace@0__:w_1 set | __keyevent@0__:set w_1 | __keyspace@0__:w_2 set | __keyevent@0__:set w_2 | __keyspace@0__:w_3 set | __keyevent@0__:set w_3 | __keyspace@0__:w_4 set | __keyevent@0__:set w_4

## hash field patterns
HSET o_1 name d age 40 n x => :3
    events: __keyspace@0__:o_1 hset | __keyevent@0__:hset o_1
HSET o_2 name a age 10 n y => :3
    events: __keyspace@0__:o_2 hset | __keyevent@0__:hset o_2
HSET o_3 name c age 30 => :2
    events: __keyspace@0__:o_3 hset | __keyevent@0__:hset o_3
HSET o_4 name b age 20 => :2
    events: __keyspace@0__:o_4 hset | __keyevent@0__:hset o_4
SORT ids BY o_*->age => ["2", "4", "3", "1"]
SORT ids BY o_*->age DESC => ["1", "3", "4", "2"]
SORT ids BY o_*->name ALPHA => ["2", "4", "3", "1"]
SORT ids BY o_*->name => -ERR One or more scores can't be converted into double
SORT ids BY o_*->age GET o_*->name => ["a", "b", "c", "d"]
SORT ids BY o_*->age GET o_*->name GET # GET o_*->n => ["a", "2", "y", "b", "4", nil, "c", "3", nil, "d", "1", "x"]
SORT ids BY o_*->missing => ["1", "2", "3", "4"]
SORT ids BY o_*->missing ALPHA => ["1", "2", "3", "4"]
SORT ids GET o_*->missing => [nil, nil, nil, nil]
SORT ids GET o_*-> => [nil, nil, nil, nil]
SORT ids BY o_*-> => ["1", "2", "3", "4"]
SORT ids GET o_*->name->x => [nil, nil, nil, nil]
SORT ids GET *->name => [nil, nil, nil, nil]
SORT ids GET o_1->name => [nil, nil, nil, nil]
SORT ids BY o_1->age => ["1", "2", "3", "4"]
SORT ids BY o_1->age DESC => ["4", "3", "2", "1"]
SORT ids GET o_*->na* => [nil, nil, nil, nil]
SORT ids GET o_*-*>name => [nil, nil, nil, nil]
SORT ids GET ->name => [nil, nil, nil, nil]
SORT ids BY ->age => ["1", "2", "3", "4"]
SORT ids GET w_*->name => [nil, nil, nil, nil]
SORT ids BY w_*->name => ["1", "2", "3", "4"]
SORT ids BY w_*->name ALPHA => ["1", "2", "3", "4"]
HSET o_2 age abc => :0
    events: __keyspace@0__:o_2 hset | __keyevent@0__:hset o_2
SORT ids BY o_*->age => -ERR One or more scores can't be converted into double
HSET o_2 age 10 => :0
    events: __keyspace@0__:o_2 hset | __keyevent@0__:hset o_2
HDEL o_3 age => :1
    events: __keyspace@0__:o_3 hdel | __keyevent@0__:hdel o_3
SORT ids BY o_*->age => ["3", "2", "4", "1"]
SORT ids BY o_*->age DESC => ["1", "4", "2", "3"]
HSET o_3 age 30 => :1
    events: __keyspace@0__:o_3 hset | __keyevent@0__:hset o_3
SORT ids BY o_*->age LIMIT 1 2 GET o_*->name => ["b", "c"]
HSET ox f v => :1
    events: __keyspace@0__:ox hset | __keyevent@0__:hset ox
SORT ids GET ox->f => [nil, nil, nil, nil]
SORT ids BY ox->f => ["1", "2", "3", "4"]
SORT ids GET o_*->age GET # BY nosort => ["40", "1", "10", "2", "30", "3", "20", "4"]
HPEXPIRE o_1 1 FIELDS 1 age => [:1]
    events: __keyspace@0__:o_1 hexpire | __keyevent@0__:hexpire o_1
SORT ids BY o_*->age => ["1", "2", "4", "3"]
    events: __keyspace@0__:o_1 hexpired | __keyevent@0__:hexpired o_1
SORT ids GET o_*->age => [nil, "10", "30", "20"]
HSET o_1 age 40 => :1
    events: __keyspace@0__:o_1 hset | __keyevent@0__:hset o_1
SET o_5 str => +OK
    events: __keyspace@0__:o_5 set | __keyevent@0__:set o_5
RPUSH ids3 1 5 => :2
    events: __keyspace@0__:ids3 rpush | __keyevent@0__:rpush ids3
SORT ids3 BY o_*->age => ["5", "1"]
SORT ids3 GET o_*->age => ["40", nil]
SORT ids3 GET o_* => [nil, "str"]
SORT ids3 BY o_* => -ERR One or more scores can't be converted into double
SORT ids3 BY o_* ALPHA => ["1", "5"]

## STORE
RPUSH l 3 1 2 => :3
    events: __keyspace@0__:l rpush | __keyevent@0__:rpush l
SORT l STORE out => :3
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["1", "2", "3"]
TYPE out => +list
OBJECT ENCODING out => "listpack"
SORT l DESC STORE out => :3
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["3", "2", "1"]
SORT l STORE l => :3
    events: __keyspace@0__:l sortstore | __keyevent@0__:sortstore l
LRANGE l 0 -1 => ["1", "2", "3"]
SET out str => +OK
    events: __keyspace@0__:out set | __keyevent@0__:set out
SORT l STORE out => :3
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
TYPE out => +list
LRANGE out 0 -1 => ["1", "2", "3"]
SORT l LIMIT 0 0 STORE out => :0
    events: __keyspace@0__:out del | __keyevent@0__:del out
EXISTS out => :0
SORT l LIMIT 0 0 STORE out => :0
SORT l STORE out => :3
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
EXPIRE out 100 => :1
    events: __keyspace@0__:out expire | __keyevent@0__:expire out
SORT l STORE out => :3
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
TTL out => :-1
SORT missing STORE out => :0
    events: __keyspace@0__:out del | __keyevent@0__:del out
EXISTS out => :0
SORT l STORE => -ERR syntax error
SORT l STORE out STORE out2 => :3
    events: __keyspace@0__:out2 sortstore | __keyevent@0__:sortstore out2
EXISTS out2 => :1
LRANGE out 0 -1 => []
SORT l STORE out LIMIT 0 1 => :1
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["1"]
MSET w_1 a w_2 b w_3 c => +OK
    events: __keyspace@0__:w_1 set | __keyevent@0__:set w_1 | __keyspace@0__:w_2 set | __keyevent@0__:set w_2 | __keyspace@0__:w_3 set | __keyevent@0__:set w_3
SORT l GET w_* STORE out => :3
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["a", "b", "c"]
DEL w_2 => :1
    events: __keyspace@0__:w_2 del | __keyevent@0__:del w_2
SORT l GET w_* STORE out => :3
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["a", "", "c"]
SORT l GET w_* GET # STORE out => :6
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["a", "1", "", "2", "c", "3"]
SORT l GET missing_* STORE out => :3
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["", "", ""]
SORT l GET missing_* => [nil, nil, nil]
SORT l BY nosort STORE out => :3
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["1", "2", "3"]
SORT l ALPHA STORE out => :3
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["1", "2", "3"]
SORT l STORE out BOGUS => -ERR syntax error
EXISTS out => :1
SORT str STORE out => :0
    events: __keyspace@0__:out del | __keyevent@0__:del out
SET str v => +OK
    events: __keyspace@0__:str set | __keyevent@0__:set str
SORT str STORE out => -WRONGTYPE Operation against a key holding the wrong kind of value
EXISTS out => :0
SORT l STORE str => :3
    events: __keyspace@0__:str sortstore | __keyevent@0__:sortstore str
TYPE str => +list
RPUSH bad 1 abc => :2
    events: __keyspace@0__:bad rpush | __keyevent@0__:rpush bad
SORT bad STORE out => -ERR One or more scores can't be converted into double
LRANGE out 0 -1 => []
SORT bad ALPHA STORE out => :2
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["1", "abc"]
RPUSH bigl {200..1} => :200
    events: __keyspace@0__:bigl rpush | __keyevent@0__:rpush bigl
SORT bigl STORE bigout => :200
    events: __keyspace@0__:bigout sortstore | __keyevent@0__:sortstore bigout
OBJECT ENCODING bigout => "listpack"
LRANGE bigout 0 4 => ["1", "2", "3", "4", "5"]
LLEN bigout => :200
SORT bigl STORE bigout LIMIT 0 3 => :3
    events: __keyspace@0__:bigout sortstore | __keyevent@0__:sortstore bigout
OBJECT ENCODING bigout => "listpack"
LRANGE bigout 0 -1 => ["1", "2", "3"]
SELECT 1 => +OK
SORT l STORE out => :0
SELECT 0 => +OK
RPUSH dupes a a b => :3
    events: __keyspace@0__:dupes rpush | __keyevent@0__:rpush dupes
SORT dupes ALPHA STORE dout => :3
    events: __keyspace@0__:dout sortstore | __keyevent@0__:sortstore dout
LRANGE dout 0 -1 => ["a", "a", "b"]

## SORT_RO
SORT_RO l => ["1", "2", "3"]
SORT_RO l DESC => ["3", "2", "1"]
SORT_RO l ALPHA LIMIT 0 2 => ["1", "2"]
SORT_RO l GET w_* BY w_* => -ERR One or more scores can't be converted into double
SORT_RO l STORE out => -ERR syntax error
SORT_RO l STORE => -ERR syntax error
SORT_RO l BOGUS => -ERR syntax error
SORT_RO missing => []
SORT_RO str => ["1", "2", "3"]
SORT_RO => -ERR wrong number of arguments for 'sort_ro' command
SORT_RO l store out => -ERR syntax error
SORT_RO l LIMIT abc 1 => -ERR value is not an integer or out of range
SORT_RO l BY nosort STORE out => -ERR syntax error
SORT_RO l GET # STORE out => -ERR syntax error
SORT_RO bad => -ERR One or more scores can't be converted into double
SORT_RO l STORE out LIMIT abc 1 => -ERR syntax error
SORT_RO l LIMIT abc 1 STORE out => -ERR value is not an integer or out of range

## arity and option parsing order
SORT l LIMIT 0 1 STORE => -ERR syntax error
SORT l BY => -ERR syntax error
SORT l GET => -ERR syntax error
SORT l LIMIT 0 => -ERR syntax error
SORT str LIMIT 0 => -ERR syntax error
SORT str BY => -ERR syntax error
SORT missing BY => -ERR syntax error
SORT missing BOGUS => -ERR syntax error
SORT missing GET # LIMIT x 1 => -ERR value is not an integer or out of range
SORT l DESC DESC ALPHA ALPHA => ["3", "2", "1"]
SORT l STORE out STORE out => :3
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["1", "2", "3"]
SORT l LIMIT 0 1 BY w_* GET # ALPHA DESC STORE out => :1
    events: __keyspace@0__:out sortstore | __keyevent@0__:sortstore out
LRANGE out 0 -1 => ["3"]

## types of sort input against encodings
RPUSH lq 2 1 => :2
    events: __keyspace@0__:lq rpush | __keyevent@0__:rpush lq
OBJECT ENCODING lq => "listpack"
SORT lq => ["1", "2"]
RPUSH lq {0..299} => :302
    events: __keyspace@0__:lq rpush | __keyevent@0__:rpush lq
OBJECT ENCODING lq => "listpack"
SORT lq LIMIT 0 3 => ["0", "1", "1"]
SORT lq LIMIT 0 3 DESC => ["299", "298", "297"]
SORT lq BY nosort LIMIT 0 3 => ["2", "1", "0"]
SORT lq BY nosort LIMIT 0 3 DESC => ["299", "298", "297"]
SORT lq BY nosort LIMIT 299 3 => ["297", "298", "299"]
SORT lq BY nosort LIMIT 299 3 DESC => ["0", "1", "2"]
SORT lq BY nosort LIMIT 0 -1 DESC STORE lq_out => :302
    events: __keyspace@0__:lq_out sortstore | __keyevent@0__:sortstore lq_out
LRANGE lq_out 0 2 => ["299", "298", "297"]
LLEN lq_out => :302
SORT lq BY nosort DESC STORE lq_out => :302
    events: __keyspace@0__:lq_out sortstore | __keyevent@0__:sortstore lq_out
LRANGE lq_out 0 2 => ["299", "298", "297"]
SORT lq BY nosort DESC => ["{299..0}", "1", "2"]
SADD si 5 3 9 => :3
    events: __keyspace@0__:si sadd | __keyevent@0__:sadd si
OBJECT ENCODING si => "intset"
SORT si => ["3", "5", "9"]
SORT si BY nosort => ["3", "5", "9"]
SORT si BY nosort STORE si_out => :3
    events: __keyspace@0__:si_out sortstore | __keyevent@0__:sortstore si_out
LRANGE si_out 0 -1 => ["3", "5", "9"]
SADD sl c a b => :3
    events: __keyspace@0__:sl sadd | __keyevent@0__:sadd sl
OBJECT ENCODING sl => "listpack"
SORT sl ALPHA => ["a", "b", "c"]
SORT sl BY nosort => ["c", "a", "b"]
SORT sl BY nosort STORE sl_out => :3
    events: __keyspace@0__:sl_out sortstore | __keyevent@0__:sortstore sl_out
LRANGE sl_out 0 -1 => ["a", "b", "c"]
SORT sl BY nosort LIMIT 0 2 STORE sl_out => :2
    events: __keyspace@0__:sl_out sortstore | __keyevent@0__:sortstore sl_out
LRANGE sl_out 0 -1 => ["a", "b"]
SORT sl BY nosort LIMIT 0 2 => ["c", "a"]
SORT sl BY nosort DESC LIMIT 0 2 => ["c", "a"]
ZADD zl 1 b 2 a => :2
    events: __keyspace@0__:zl zadd | __keyevent@0__:zadd zl
OBJECT ENCODING zl => "listpack"
SORT zl ALPHA => ["a", "b"]
SORT zl BY nosort => ["b", "a"]
SORT zl BY nosort DESC => ["a", "b"]
SORT zl BY nosort DESC LIMIT 0 1 => ["a"]
SORT zl BY nosort LIMIT 1 1 => ["a"]
SORT zl BY nosort LIMIT 1 1 DESC => ["b"]
DBSIZE => :7
`
