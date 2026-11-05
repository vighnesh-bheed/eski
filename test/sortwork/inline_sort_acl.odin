package sortwork

INLINE_SORT_ACL :: `# SORT under access control lists, Redis 7.4.11, protocol 2

## setup
RPUSH ids 2 1 => :2
MSET w_1 10 w_2 5 => +OK
HSET o_1 f x => :1
ACL SETUSER limited on nopass +@all ~ids ~out* => +OK
ACL SETUSER reader on nopass +@all %R~* => +OK
ACL SETUSER full on nopass +@all ~* => +OK
ACL SETUSER allkeys on nopass +@all allkeys => +OK

## user with a key pattern that does not cover every key
AUTH limited x => +OK
SORT ids => ["1", "2"]
SORT ids BY w_* => -ERR BY option of SORT denied due to insufficient ACL permissions.
SORT ids BY nosort => ["2", "1"]
SORT ids BY constant => ["2", "1"]
SORT ids GET # => -ERR GET option of SORT denied due to insufficient ACL permissions.
SORT ids GET w_* => -ERR GET option of SORT denied due to insufficient ACL permissions.
SORT ids BY w_* GET w_* => -ERR BY option of SORT denied due to insufficient ACL permissions.
SORT ids GET w_* BY w_* => -ERR GET option of SORT denied due to insufficient ACL permissions.
SORT ids BY o_*->f => -ERR BY option of SORT denied due to insufficient ACL permissions.
SORT ids STORE out => :2
SORT ids BY w_* STORE out => -ERR BY option of SORT denied due to insufficient ACL permissions.
SORT ids STORE other => -NOPERM No permissions to access a key
SORT_RO ids BY w_* => -ERR BY option of SORT denied due to insufficient ACL permissions.
SORT_RO ids GET # => -ERR GET option of SORT denied due to insufficient ACL permissions.
SORT ids BY w_* LIMIT abc 1 => -ERR BY option of SORT denied due to insufficient ACL permissions.
SORT ids LIMIT abc 1 BY w_* => -ERR value is not an integer or out of range
SORT ids BOGUS BY w_* => -ERR syntax error
SORT ids BY w_* BOGUS => -ERR BY option of SORT denied due to insufficient ACL permissions.
SORT missing BY w_* => -NOPERM No permissions to access a key
SORT w_1 BY w_* => -NOPERM No permissions to access a key

## user with read permission on every key
AUTH reader x => +OK
SORT ids BY w_* => ["2", "1"]
SORT ids GET w_* => ["10", "5"]
SORT ids BY w_* STORE out => -NOPERM No permissions to access a key
SORT ids STORE out => -NOPERM No permissions to access a key

## user with every key
AUTH full x => +OK
SORT ids BY w_* => ["2", "1"]
SORT ids GET w_* STORE out => :2
AUTH allkeys x => +OK
SORT ids BY w_* => ["2", "1"]
AUTH default x => +OK
SORT ids BY w_* GET w_* => ["5", "10"]
ACL DELUSER limited reader full allkeys => :4
`
