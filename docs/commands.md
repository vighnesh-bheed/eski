# Command inventory

Generated from a temporary instance of the built executable using `COMMAND DOCS`, `COMMAND LIST` and `COMMAND COUNT`. The inventory contains 229 top-level commands and 319 names including subcommands. Metadata describes the protocol surface; the [command-group pages](README.md) and [conformance record](conformance.md) define implemented behavior and remaining gaps. Registered compatibility entries for excluded execution features do not provide scripting, replication or clustering.

Regenerate with `python3 -I test/readme_tables.py`; verify with `python3 -I test/readme_tables.py --check`. Use `--server HOST:PORT` to inspect an existing instance without starting one. The canonical command-metadata SHA256 is `2ecd2aa75ebc99420ed0e30ba2a2ee07c1ed748b1c049c2300bfa56bc64c2142`.

## Bitmap

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `BITCOUNT` | `<key> [<start> <end> [(BYTE \| BIT)]]` | Counts the number of set bits (population counting) in a string. |
| `BITFIELD` | `<key> [(GET <encoding> <offset> \| [OVERFLOW (WRAP \| SAT \| FAIL)] (SET <encoding> <offset> <value> \| INCRBY <encoding> <offset> <increment>)) ...]` | Performs arbitrary bitfield integer operations on strings. |
| `BITFIELD_RO` | `<key> [GET <encoding> <offset> ...]` | Performs arbitrary read-only bitfield integer operations on strings. |
| `BITOP` | `(AND \| OR \| XOR \| NOT) <destkey> <key> ...` | Performs bitwise operations on multiple strings, and stores the result. |
| `BITPOS` | `<key> <bit> [<start> [<end> [(BYTE \| BIT)]]]` | Finds the first set (1) or clear (0) bit in a string. |
| `GETBIT` | `<key> <offset>` | Returns a bit value by offset. |
| `SETBIT` | `<key> <offset> <value>` | Sets or clears the bit at offset of the string value. Creates the key if it doesn't exist. |

## Connection

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `AUTH` | `[<username>] <password>` | Authenticates the connection. |
| `CLIENT` | — | A container for client connection commands. |
| `CLIENT CACHING` | `(YES \| NO)` | Instructs the server whether to track the keys in the next request. |
| `CLIENT GETNAME` | — | Returns the name of the connection. |
| `CLIENT GETREDIR` | — | Returns the client ID to which the connection's tracking notifications are redirected. |
| `CLIENT HELP` | — | Returns helpful text about the different subcommands. |
| `CLIENT ID` | — | Returns the unique client ID of the connection. |
| `CLIENT INFO` | — | Returns information about the connection. |
| `CLIENT KILL` | `(<ip:port> \| ([ID <client-id>] \| [TYPE (NORMAL \| MASTER \| SLAVE \| REPLICA \| PUBSUB)] \| [USER <username>] \| [ADDR <ip:port>] \| [LADDR <ip:port>] \| [SKIPME (YES \| NO)] \| [MAXAGE <maxage>]) ...)` | Terminates open connections. |
| `CLIENT LIST` | `[TYPE (NORMAL \| MASTER \| REPLICA \| PUBSUB)] [ID <client-id> ...]` | Lists open connections. |
| `CLIENT NO-EVICT` | `(ON \| OFF)` | Sets the client eviction mode of the connection. |
| `CLIENT NO-TOUCH` | `(ON \| OFF)` | Controls whether commands sent by the client affect the LRU/LFU of accessed keys. |
| `CLIENT PAUSE` | `<timeout> [(WRITE \| ALL)]` | Suspends commands processing. |
| `CLIENT REPLY` | `(ON \| OFF \| SKIP)` | Instructs the server whether to reply to commands. |
| `CLIENT SETINFO` | `(LIB-NAME <libname> \| LIB-VER <libver>)` | Sets information specific to the client or connection. |
| `CLIENT SETNAME` | `<connection-name>` | Sets the connection name. |
| `CLIENT TRACKING` | `(ON \| OFF) [REDIRECT <client-id>] [PREFIX <prefix> ...] [BCAST] [OPTIN] [OPTOUT] [NOLOOP]` | Controls server-assisted client-side caching for the connection. |
| `CLIENT TRACKINGINFO` | — | Returns information about server-assisted client-side caching for the connection. |
| `CLIENT UNBLOCK` | `<client-id> [(TIMEOUT \| ERROR)]` | Unblocks a client blocked by a blocking command from a different connection. |
| `CLIENT UNPAUSE` | — | Resumes processing commands from paused clients. |
| `ECHO` | `<message>` | Returns the given string. |
| `HELLO` | `[<protover> [AUTH <username> <password>] [SETNAME <clientname>]]` | Handshakes with the Redis server. |
| `PING` | `[<message>]` | Returns the server's liveliness response. |
| `QUIT` | — | Closes the connection. |
| `RESET` | — | Resets the connection. |
| `SELECT` | `<index>` | Changes the selected database. |

## Generic

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `COPY` | `<source> <destination> [DB <destination-db>] [REPLACE]` | Copies the value of a key to a new key. |
| `DEL` | `<key> ...` | Deletes one or more keys. |
| `DUMP` | `<key>` | Returns a serialized representation of the value stored at a key. |
| `EXISTS` | `<key> ...` | Determines whether one or more keys exist. |
| `EXPIRE` | `<key> <seconds> [(NX \| XX \| GT \| LT)]` | Sets the expiration time of a key in seconds. |
| `EXPIREAT` | `<key> <unix-time-seconds> [(NX \| XX \| GT \| LT)]` | Sets the expiration time of a key to a Unix timestamp. |
| `EXPIRETIME` | `<key>` | Returns the expiration time of a key as a Unix timestamp. |
| `KEYS` | `<pattern>` | Returns all key names that match a pattern. |
| `MIGRATE` | `<host> <port> (<key> \| EMPTY-STRING) <destination-db> <timeout> [COPY] [REPLACE] [(AUTH <password> \| AUTH2 <username> <password>)] [KEYS <key> ...]` | Atomically transfers a key from one Redis instance to another. |
| `MOVE` | `<key> <db>` | Moves a key to another database. |
| `OBJECT` | — | A container for object introspection commands. |
| `OBJECT ENCODING` | `<key>` | Returns the internal encoding of a Redis object. |
| `OBJECT FREQ` | `<key>` | Returns the logarithmic access frequency counter of a Redis object. |
| `OBJECT HELP` | — | Returns helpful text about the different subcommands. |
| `OBJECT IDLETIME` | `<key>` | Returns the time since the last access to a Redis object. |
| `OBJECT REFCOUNT` | `<key>` | Returns the reference count of a value of a key. |
| `PERSIST` | `<key>` | Removes the expiration time of a key. |
| `PEXPIRE` | `<key> <milliseconds> [(NX \| XX \| GT \| LT)]` | Sets the expiration time of a key in milliseconds. |
| `PEXPIREAT` | `<key> <unix-time-milliseconds> [(NX \| XX \| GT \| LT)]` | Sets the expiration time of a key to a Unix milliseconds timestamp. |
| `PEXPIRETIME` | `<key>` | Returns the expiration time of a key as a Unix milliseconds timestamp. |
| `PTTL` | `<key>` | Returns the expiration time in milliseconds of a key. |
| `RANDOMKEY` | — | Returns a random key name from the database. |
| `RENAME` | `<key> <newkey>` | Renames a key and overwrites the destination. |
| `RENAMENX` | `<key> <newkey>` | Renames a key only when the target key name doesn't exist. |
| `RESTORE` | `<key> <ttl> <serialized-value> [REPLACE] [ABSTTL] [IDLETIME <seconds>] [FREQ <frequency>]` | Creates a key from the serialized representation of a value. |
| `SCAN` | `<cursor> [MATCH <pattern>] [COUNT <count>] [TYPE <type>]` | Iterates over the key names in the database. |
| `SORT` | `<key> [BY <pattern>] [LIMIT <offset> <count>] [GET <pattern> ...] [(ASC \| DESC)] [ALPHA] [STORE <destination>]` | Sorts the elements in a list, a set, or a sorted set, optionally storing the result. |
| `SORT_RO` | `<key> [BY <pattern>] [LIMIT <offset> <count>] [GET <pattern> ...] [(ASC \| DESC)] [ALPHA]` | Returns the sorted elements of a list, a set, or a sorted set. |
| `TOUCH` | `<key> ...` | Returns the number of existing keys out of those specified after updating the time they were last accessed. |
| `TTL` | `<key>` | Returns the expiration time in seconds of a key. |
| `TYPE` | `<key>` | Determines the type of value stored at a key. |
| `UNLINK` | `<key> ...` | Asynchronously deletes one or more keys. |
| `WAIT` | `<numreplicas> <timeout>` | Blocks until the asynchronous replication of all preceding write commands sent by the connection is completed. |
| `WAITAOF` | `<numlocal> <numreplicas> <timeout>` | Blocks until all of the preceding write commands sent by the connection are written to the append-only file of the master and/or replicas. |

## Geo

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `GEOADD` | `<key> [(NX \| XX)] [CH] <longitude> <latitude> <member> ...` | Adds one or more members to a geospatial index. The key is created if it doesn't exist. |
| `GEODIST` | `<key> <member1> <member2> [(M \| KM \| FT \| MI)]` | Returns the distance between two members of a geospatial index. |
| `GEOHASH` | `<key> [<member> ...]` | Returns members from a geospatial index as geohash strings. |
| `GEOPOS` | `<key> [<member> ...]` | Returns the longitude and latitude of members from a geospatial index. |
| `GEORADIUS` | `<key> <longitude> <latitude> <radius> (M \| KM \| FT \| MI) [WITHCOORD] [WITHDIST] [WITHHASH] [COUNT <count> [ANY]] [(ASC \| DESC)] [(STORE <key> \| STOREDIST <key>)]` | Queries a geospatial index for members within a distance from a coordinate, optionally stores the result. |
| `GEORADIUS_RO` | `<key> <longitude> <latitude> <radius> (M \| KM \| FT \| MI) [WITHCOORD] [WITHDIST] [WITHHASH] [COUNT <count> [ANY]] [(ASC \| DESC)]` | Returns members from a geospatial index that are within a distance from a coordinate. |
| `GEORADIUSBYMEMBER` | `<key> <member> <radius> (M \| KM \| FT \| MI) [WITHCOORD] [WITHDIST] [WITHHASH] [COUNT <count> [ANY]] [(ASC \| DESC)] [(STORE <key> \| STOREDIST <key>)]` | Queries a geospatial index for members within a distance from a member, optionally stores the result. |
| `GEORADIUSBYMEMBER_RO` | `<key> <member> <radius> (M \| KM \| FT \| MI) [WITHCOORD] [WITHDIST] [WITHHASH] [COUNT <count> [ANY]] [(ASC \| DESC)]` | Returns members from a geospatial index that are within a distance from a member. |
| `GEOSEARCH` | `<key> (FROMMEMBER <member> \| FROMLONLAT <longitude> <latitude>) (BYRADIUS <radius> (M \| KM \| FT \| MI) \| BYBOX <width> <height> (M \| KM \| FT \| MI)) [(ASC \| DESC)] [COUNT <count> [ANY]] [WITHCOORD] [WITHDIST] [WITHHASH]` | Queries a geospatial index for members inside an area of a box or a circle. |
| `GEOSEARCHSTORE` | `<destination> <source> (FROMMEMBER <member> \| FROMLONLAT <longitude> <latitude>) (BYRADIUS <radius> (M \| KM \| FT \| MI) \| BYBOX <width> <height> (M \| KM \| FT \| MI)) [(ASC \| DESC)] [COUNT <count> [ANY]] [STOREDIST]` | Queries a geospatial index for members inside an area of a box or a circle, optionally stores the result. |

## Hash

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `HDEL` | `<key> <field> ...` | Deletes one or more fields and their values from a hash. Deletes the hash if no fields remain. |
| `HEXISTS` | `<key> <field>` | Determines whether a field exists in a hash. |
| `HEXPIRE` | `<key> <seconds> [(NX \| XX \| GT \| LT)] FIELDS <numfields> <field> ...` | Set expiry for hash field using relative time to expire (seconds) |
| `HEXPIREAT` | `<key> <unix-time-seconds> [(NX \| XX \| GT \| LT)] FIELDS <numfields> <field> ...` | Set expiry for hash field using an absolute Unix timestamp (seconds) |
| `HEXPIRETIME` | `<key> FIELDS <numfields> <field> ...` | Returns the expiration time of a hash field as a Unix timestamp, in seconds. |
| `HGET` | `<key> <field>` | Returns the value of a field in a hash. |
| `HGETALL` | `<key>` | Returns all fields and values in a hash. |
| `HINCRBY` | `<key> <field> <increment>` | Increments the integer value of a field in a hash by a number. Uses 0 as initial value if the field doesn't exist. |
| `HINCRBYFLOAT` | `<key> <field> <increment>` | Increments the floating point value of a field by a number. Uses 0 as initial value if the field doesn't exist. |
| `HKEYS` | `<key>` | Returns all fields in a hash. |
| `HLEN` | `<key>` | Returns the number of fields in a hash. |
| `HMGET` | `<key> <field> ...` | Returns the values of all fields in a hash. |
| `HMSET` | `<key> <field> <value> ...` | Sets the values of multiple fields. |
| `HPERSIST` | `<key> FIELDS <numfields> <field> ...` | Removes the expiration time for each specified field |
| `HPEXPIRE` | `<key> <milliseconds> [(NX \| XX \| GT \| LT)] FIELDS <numfields> <field> ...` | Set expiry for hash field using relative time to expire (milliseconds) |
| `HPEXPIREAT` | `<key> <unix-time-milliseconds> [(NX \| XX \| GT \| LT)] FIELDS <numfields> <field> ...` | Set expiry for hash field using an absolute Unix timestamp (milliseconds) |
| `HPEXPIRETIME` | `<key> FIELDS <numfields> <field> ...` | Returns the expiration time of a hash field as a Unix timestamp, in msec. |
| `HPTTL` | `<key> FIELDS <numfields> <field> ...` | Returns the TTL in milliseconds of a hash field. |
| `HRANDFIELD` | `<key> [<count> [WITHVALUES]]` | Returns one or more random fields from a hash. |
| `HSCAN` | `<key> <cursor> [MATCH <pattern>] [COUNT <count>] [NOVALUES]` | Iterates over fields and values of a hash. |
| `HSET` | `<key> <field> <value> ...` | Creates or modifies the value of a field in a hash. |
| `HSETNX` | `<key> <field> <value>` | Sets the value of a field in a hash only when the field doesn't exist. |
| `HSTRLEN` | `<key> <field>` | Returns the length of the value of a field. |
| `HTTL` | `<key> FIELDS <numfields> <field> ...` | Returns the TTL in seconds of a hash field. |
| `HVALS` | `<key>` | Returns all values in a hash. |

## Hyperloglog

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `PFADD` | `<key> [<element> ...]` | Adds elements to a HyperLogLog key. Creates the key if it doesn't exist. |
| `PFCOUNT` | `<key> ...` | Returns the approximated cardinality of the set(s) observed by the HyperLogLog key(s). |
| `PFDEBUG` | `<subcommand> <key>` | Internal commands for debugging HyperLogLog values. |
| `PFMERGE` | `<destkey> [<sourcekey> ...]` | Merges one or more HyperLogLog values into a single key. |
| `PFSELFTEST` | — | An internal command for testing HyperLogLog values. |

## List

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `BLMOVE` | `<source> <destination> (LEFT \| RIGHT) (LEFT \| RIGHT) <timeout>` | Pops an element from a list, pushes it to another list and returns it. Blocks until an element is available otherwise. Deletes the list if the last element was moved. |
| `BLMPOP` | `<timeout> <numkeys> <key> ... (LEFT \| RIGHT) [COUNT <count>]` | Pops the first element from one of multiple lists. Blocks until an element is available otherwise. Deletes the list if the last element was popped. |
| `BLPOP` | `<key> ... <timeout>` | Removes and returns the first element in a list. Blocks until an element is available otherwise. Deletes the list if the last element was popped. |
| `BRPOP` | `<key> ... <timeout>` | Removes and returns the last element in a list. Blocks until an element is available otherwise. Deletes the list if the last element was popped. |
| `BRPOPLPUSH` | `<source> <destination> <timeout>` | Pops an element from a list, pushes it to another list and returns it. Block until an element is available otherwise. Deletes the list if the last element was popped. |
| `LINDEX` | `<key> <index>` | Returns an element from a list by its index. |
| `LINSERT` | `<key> (BEFORE \| AFTER) <pivot> <element>` | Inserts an element before or after another element in a list. |
| `LLEN` | `<key>` | Returns the length of a list. |
| `LMOVE` | `<source> <destination> (LEFT \| RIGHT) (LEFT \| RIGHT)` | Returns an element after popping it from one list and pushing it to another. Deletes the list if the last element was moved. |
| `LMPOP` | `<numkeys> <key> ... (LEFT \| RIGHT) [COUNT <count>]` | Returns multiple elements from a list after removing them. Deletes the list if the last element was popped. |
| `LPOP` | `<key> [<count>]` | Returns the first elements in a list after removing it. Deletes the list if the last element was popped. |
| `LPOS` | `<key> <element> [RANK <rank>] [COUNT <num-matches>] [MAXLEN <len>]` | Returns the index of matching elements in a list. |
| `LPUSH` | `<key> <element> ...` | Prepends one or more elements to a list. Creates the key if it doesn't exist. |
| `LPUSHX` | `<key> <element> ...` | Prepends one or more elements to a list only when the list exists. |
| `LRANGE` | `<key> <start> <stop>` | Returns a range of elements from a list. |
| `LREM` | `<key> <count> <element>` | Removes elements from a list. Deletes the list if the last element was removed. |
| `LSET` | `<key> <index> <element>` | Sets the value of an element in a list by its index. |
| `LTRIM` | `<key> <start> <stop>` | Removes elements from both ends a list. Deletes the list if all elements were trimmed. |
| `RPOP` | `<key> [<count>]` | Returns and removes the last elements of a list. Deletes the list if the last element was popped. |
| `RPOPLPUSH` | `<source> <destination>` | Returns the last element of a list after removing and pushing it to another list. Deletes the list if the last element was popped. |
| `RPUSH` | `<key> <element> ...` | Appends one or more elements to a list. Creates the key if it doesn't exist. |
| `RPUSHX` | `<key> <element> ...` | Appends an element to a list only when the list exists. |

## Pubsub

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `PSUBSCRIBE` | `<pattern> ...` | Listens for messages published to channels that match one or more patterns. |
| `PUBLISH` | `<channel> <message>` | Posts a message to a channel. |
| `PUBSUB` | — | A container for Pub/Sub commands. |
| `PUBSUB CHANNELS` | `[<pattern>]` | Returns the active channels. |
| `PUBSUB HELP` | — | Returns helpful text about the different subcommands. |
| `PUBSUB NUMPAT` | — | Returns a count of unique pattern subscriptions. |
| `PUBSUB NUMSUB` | `[<channel> ...]` | Returns a count of subscribers to channels. |
| `PUBSUB SHARDCHANNELS` | `[<pattern>]` | Returns the active shard channels. |
| `PUBSUB SHARDNUMSUB` | `[<shardchannel> ...]` | Returns the count of subscribers of shard channels. |
| `PUNSUBSCRIBE` | `[<pattern> ...]` | Stops listening to messages published to channels that match one or more patterns. |
| `SPUBLISH` | `<shardchannel> <message>` | Post a message to a shard channel |
| `SSUBSCRIBE` | `<shardchannel> ...` | Listens for messages published to shard channels. |
| `SUBSCRIBE` | `<channel> ...` | Listens for messages published to channels. |
| `SUNSUBSCRIBE` | `[<shardchannel> ...]` | Stops listening to messages posted to shard channels. |
| `UNSUBSCRIBE` | `[<channel> ...]` | Stops listening to messages posted to channels. |

## Scripting

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `FUNCTION` | — | Compatibility entry; excluded execution features remain unavailable. A container for function commands. |
| `FUNCTION DELETE` | `<library-name>` | Compatibility entry; excluded execution features remain unavailable. Deletes a library and its functions. |
| `FUNCTION DUMP` | — | Compatibility entry; excluded execution features remain unavailable. Dumps all libraries into a serialized binary payload. |
| `FUNCTION FLUSH` | `[(ASYNC \| SYNC)]` | Compatibility entry; excluded execution features remain unavailable. Deletes all libraries and functions. |
| `FUNCTION HELP` | — | Compatibility entry; excluded execution features remain unavailable. Returns helpful text about the different subcommands. |
| `FUNCTION KILL` | — | Compatibility entry; excluded execution features remain unavailable. Terminates a function during execution. |
| `FUNCTION LIST` | `[LIBRARYNAME <library-name-pattern>] [WITHCODE]` | Compatibility entry; excluded execution features remain unavailable. Returns information about all libraries. |
| `FUNCTION LOAD` | `[REPLACE] <function-code>` | Compatibility entry; excluded execution features remain unavailable. Creates a library. |
| `FUNCTION RESTORE` | `<serialized-value> [(FLUSH \| APPEND \| REPLACE)]` | Compatibility entry; excluded execution features remain unavailable. Restores all libraries from a payload. |
| `FUNCTION STATS` | — | Compatibility entry; excluded execution features remain unavailable. Returns information about a function during execution. |

## Server

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `ACL` | — | A container for Access List Control commands. |
| `ACL CAT` | `[<category>]` | Lists the ACL categories, or the commands inside a category. |
| `ACL DELUSER` | `<username> ...` | Deletes ACL users, and terminates their connections. |
| `ACL DRYRUN` | `<username> <command> [<arg> ...]` | Simulates the execution of a command by a user, without executing the command. |
| `ACL GENPASS` | `[<bits>]` | Generates a pseudorandom, secure password that can be used to identify ACL users. |
| `ACL GETUSER` | `<username>` | Lists the ACL rules of a user. |
| `ACL HELP` | — | Returns helpful text about the different subcommands. |
| `ACL LIST` | — | Dumps the effective rules in ACL file format. |
| `ACL LOAD` | — | Reloads the rules from the configured ACL file. |
| `ACL LOG` | `[(<count> \| RESET)]` | Lists recent security events generated due to ACL rules. |
| `ACL SAVE` | — | Saves the effective ACL rules in the configured ACL file. |
| `ACL SETUSER` | `<username> [<rule> ...]` | Creates and modifies an ACL user and its rules. |
| `ACL USERS` | — | Lists all ACL users. |
| `ACL WHOAMI` | — | Returns the authenticated username of the current connection. |
| `BGREWRITEAOF` | — | Asynchronously rewrites the append-only file to disk. |
| `BGSAVE` | `[SCHEDULE]` | Asynchronously saves the database(s) to disk. |
| `COMMAND` | — | Returns detailed information about all commands. |
| `COMMAND COUNT` | — | Returns a count of commands. |
| `COMMAND DOCS` | `[<command-name> ...]` | Returns documentary information about one, multiple or all commands. |
| `COMMAND GETKEYS` | `<command> [<arg> ...]` | Extracts the key names from an arbitrary command. |
| `COMMAND GETKEYSANDFLAGS` | `<command> [<arg> ...]` | Extracts the key names and access flags for an arbitrary command. |
| `COMMAND HELP` | — | Returns helpful text about the different subcommands. |
| `COMMAND INFO` | `[<command-name> ...]` | Returns information about one, multiple or all commands. |
| `COMMAND LIST` | `[FILTERBY (MODULE <module-name> \| ACLCAT <category> \| PATTERN <pattern>)]` | Returns a list of command names. |
| `CONFIG` | — | A container for server configuration commands. |
| `CONFIG GET` | `<parameter> ...` | Returns the effective values of configuration parameters. |
| `CONFIG HELP` | — | Returns helpful text about the different subcommands. |
| `CONFIG RESETSTAT` | — | Resets the server's statistics. |
| `CONFIG REWRITE` | — | Persists the effective configuration to file. |
| `CONFIG SET` | `<parameter> <value> ...` | Sets configuration parameters in-flight. |
| `DBSIZE` | — | Returns the number of keys in the database. |
| `DEBUG` | — | A container for debugging commands. |
| `FLUSHALL` | `[(ASYNC \| SYNC)]` | Removes all keys from all databases. |
| `FLUSHDB` | `[(ASYNC \| SYNC)]` | Remove all keys from the current database. |
| `INFO` | `[<section> ...]` | Returns information and statistics about the server. |
| `LASTSAVE` | — | Returns the Unix timestamp of the last successful save to disk. |
| `LATENCY` | — | A container for latency diagnostics commands. |
| `LATENCY DOCTOR` | — | Returns a human-readable latency analysis report. |
| `LATENCY GRAPH` | `<event>` | Returns a latency graph for an event. |
| `LATENCY HELP` | — | Returns helpful text about the different subcommands. |
| `LATENCY HISTOGRAM` | `[<command> ...]` | Returns the cumulative distribution of latencies of a subset or all commands. |
| `LATENCY HISTORY` | `<event>` | Returns timestamp-latency samples for an event. |
| `LATENCY LATEST` | — | Returns the latest latency samples for all events. |
| `LATENCY RESET` | `[<event> ...]` | Resets the latency data for one or more events. |
| `MEMORY` | — | A container for memory diagnostics commands. |
| `MEMORY DOCTOR` | — | Outputs a memory problems report. |
| `MEMORY HELP` | — | Returns helpful text about the different subcommands. |
| `MEMORY MALLOC-STATS` | — | Returns the allocator statistics. |
| `MEMORY PURGE` | — | Asks the allocator to release memory. |
| `MEMORY STATS` | — | Returns details about memory usage. |
| `MEMORY USAGE` | `<key> [SAMPLES <count>]` | Estimates the memory usage of a key. |
| `MONITOR` | — | Listens for all requests received by the server in real-time. |
| `SAVE` | — | Synchronously saves the database(s) to disk. |
| `SHUTDOWN` | `[(NOSAVE \| SAVE)] [NOW] [FORCE] [ABORT]` | Synchronously saves the database(s) to disk and shuts down the Redis server. |
| `SLOWLOG` | — | A container for slow log commands. |
| `SLOWLOG GET` | `[<count>]` | Returns the slow log's entries. |
| `SLOWLOG HELP` | — | Show helpful text about the different subcommands |
| `SLOWLOG LEN` | — | Returns the number of entries in the slow log. |
| `SLOWLOG RESET` | — | Clears all entries from the slow log. |
| `SWAPDB` | `<index1> <index2>` | Swaps two Redis databases. |
| `TIME` | — | Returns the server time. |

## Set

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `SADD` | `<key> <member> ...` | Adds one or more members to a set. Creates the key if it doesn't exist. |
| `SCARD` | `<key>` | Returns the number of members in a set. |
| `SDIFF` | `<key> ...` | Returns the difference of multiple sets. |
| `SDIFFSTORE` | `<destination> <key> ...` | Stores the difference of multiple sets in a key. |
| `SINTER` | `<key> ...` | Returns the intersect of multiple sets. |
| `SINTERCARD` | `<numkeys> <key> ... [LIMIT <limit>]` | Returns the number of members of the intersect of multiple sets. |
| `SINTERSTORE` | `<destination> <key> ...` | Stores the intersect of multiple sets in a key. |
| `SISMEMBER` | `<key> <member>` | Determines whether a member belongs to a set. |
| `SMEMBERS` | `<key>` | Returns all members of a set. |
| `SMISMEMBER` | `<key> <member> ...` | Determines whether multiple members belong to a set. |
| `SMOVE` | `<source> <destination> <member>` | Moves a member from one set to another. |
| `SPOP` | `<key> [<count>]` | Returns one or more random members from a set after removing them. Deletes the set if the last member was popped. |
| `SRANDMEMBER` | `<key> [<count>]` | Get one or multiple random members from a set |
| `SREM` | `<key> <member> ...` | Removes one or more members from a set. Deletes the set if the last member was removed. |
| `SSCAN` | `<key> <cursor> [MATCH <pattern>] [COUNT <count>]` | Iterates over members of a set. |
| `SUNION` | `<key> ...` | Returns the union of multiple sets. |
| `SUNIONSTORE` | `<destination> <key> ...` | Stores the union of multiple sets in a key. |

## Sorted-Set

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `BZMPOP` | `<timeout> <numkeys> <key> ... (MIN \| MAX) [COUNT <count>]` | Removes and returns a member by score from one or more sorted sets. Blocks until a member is available otherwise. Deletes the sorted set if the last element was popped. |
| `BZPOPMAX` | `<key> ... <timeout>` | Removes and returns the member with the highest score from one or more sorted sets. Blocks until a member available otherwise.  Deletes the sorted set if the last element was popped. |
| `BZPOPMIN` | `<key> ... <timeout>` | Removes and returns the member with the lowest score from one or more sorted sets. Blocks until a member is available otherwise. Deletes the sorted set if the last element was popped. |
| `ZADD` | `<key> [(NX \| XX)] [(GT \| LT)] [CH] [INCR] <score> <member> ...` | Adds one or more members to a sorted set, or updates their scores. Creates the key if it doesn't exist. |
| `ZCARD` | `<key>` | Returns the number of members in a sorted set. |
| `ZCOUNT` | `<key> <min> <max>` | Returns the count of members in a sorted set that have scores within a range. |
| `ZDIFF` | `<numkeys> <key> ... [WITHSCORES]` | Returns the difference between multiple sorted sets. |
| `ZDIFFSTORE` | `<destination> <numkeys> <key> ...` | Stores the difference of multiple sorted sets in a key. |
| `ZINCRBY` | `<key> <increment> <member>` | Increments the score of a member in a sorted set. |
| `ZINTER` | `<numkeys> <key> ... [WEIGHTS <weight> ...] [AGGREGATE (SUM \| MIN \| MAX)] [WITHSCORES]` | Returns the intersect of multiple sorted sets. |
| `ZINTERCARD` | `<numkeys> <key> ... [LIMIT <limit>]` | Returns the number of members of the intersect of multiple sorted sets. |
| `ZINTERSTORE` | `<destination> <numkeys> <key> ... [WEIGHTS <weight> ...] [AGGREGATE (SUM \| MIN \| MAX)]` | Stores the intersect of multiple sorted sets in a key. |
| `ZLEXCOUNT` | `<key> <min> <max>` | Returns the number of members in a sorted set within a lexicographical range. |
| `ZMPOP` | `<numkeys> <key> ... (MIN \| MAX) [COUNT <count>]` | Returns the highest- or lowest-scoring members from one or more sorted sets after removing them. Deletes the sorted set if the last member was popped. |
| `ZMSCORE` | `<key> <member> ...` | Returns the score of one or more members in a sorted set. |
| `ZPOPMAX` | `<key> [<count>]` | Returns the highest-scoring members from a sorted set after removing them. Deletes the sorted set if the last member was popped. |
| `ZPOPMIN` | `<key> [<count>]` | Returns the lowest-scoring members from a sorted set after removing them. Deletes the sorted set if the last member was popped. |
| `ZRANDMEMBER` | `<key> [<count> [WITHSCORES]]` | Returns one or more random members from a sorted set. |
| `ZRANGE` | `<key> <start> <stop> [(BYSCORE \| BYLEX)] [REV] [LIMIT <offset> <count>] [WITHSCORES]` | Returns members in a sorted set within a range of indexes. |
| `ZRANGEBYLEX` | `<key> <min> <max> [LIMIT <offset> <count>]` | Returns members in a sorted set within a lexicographical range. |
| `ZRANGEBYSCORE` | `<key> <min> <max> [WITHSCORES] [LIMIT <offset> <count>]` | Returns members in a sorted set within a range of scores. |
| `ZRANGESTORE` | `<dst> <src> <min> <max> [(BYSCORE \| BYLEX)] [REV] [LIMIT <offset> <count>]` | Stores a range of members from sorted set in a key. |
| `ZRANK` | `<key> <member> [WITHSCORE]` | Returns the index of a member in a sorted set ordered by ascending scores. |
| `ZREM` | `<key> <member> ...` | Removes one or more members from a sorted set. Deletes the sorted set if all members were removed. |
| `ZREMRANGEBYLEX` | `<key> <min> <max>` | Removes members in a sorted set within a lexicographical range. Deletes the sorted set if all members were removed. |
| `ZREMRANGEBYRANK` | `<key> <start> <stop>` | Removes members in a sorted set within a range of indexes. Deletes the sorted set if all members were removed. |
| `ZREMRANGEBYSCORE` | `<key> <min> <max>` | Removes members in a sorted set within a range of scores. Deletes the sorted set if all members were removed. |
| `ZREVRANGE` | `<key> <start> <stop> [WITHSCORES]` | Returns members in a sorted set within a range of indexes in reverse order. |
| `ZREVRANGEBYLEX` | `<key> <max> <min> [LIMIT <offset> <count>]` | Returns members in a sorted set within a lexicographical range in reverse order. |
| `ZREVRANGEBYSCORE` | `<key> <max> <min> [WITHSCORES] [LIMIT <offset> <count>]` | Returns members in a sorted set within a range of scores in reverse order. |
| `ZREVRANK` | `<key> <member> [WITHSCORE]` | Returns the index of a member in a sorted set ordered by descending scores. |
| `ZSCAN` | `<key> <cursor> [MATCH <pattern>] [COUNT <count>]` | Iterates over members and scores of a sorted set. |
| `ZSCORE` | `<key> <member>` | Returns the score of a member in a sorted set. |
| `ZUNION` | `<numkeys> <key> ... [WEIGHTS <weight> ...] [AGGREGATE (SUM \| MIN \| MAX)] [WITHSCORES]` | Returns the union of multiple sorted sets. |
| `ZUNIONSTORE` | `<destination> <numkeys> <key> ... [WEIGHTS <weight> ...] [AGGREGATE (SUM \| MIN \| MAX)]` | Stores the union of multiple sorted sets in a key. |

## Stream

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `XACK` | `<key> <group> <id> ...` | Returns the number of messages that were successfully acknowledged by the consumer group member of a stream. |
| `XADD` | `<key> [NOMKSTREAM] [(MAXLEN \| MINID) [(= \| ~)] <threshold> [LIMIT <count>]] (* \| <id>) <field> <value> ...` | Appends a new message to a stream. Creates the key if it doesn't exist. |
| `XAUTOCLAIM` | `<key> <group> <consumer> <min-idle-time> <start> [COUNT <count>] [JUSTID]` | Changes, or acquires, ownership of messages in a consumer group, as if the messages were delivered to as consumer group member. |
| `XCLAIM` | `<key> <group> <consumer> <min-idle-time> <id> ... [IDLE <ms>] [TIME <unix-time-milliseconds>] [RETRYCOUNT <count>] [FORCE] [JUSTID] [LASTID <lastid>]` | Changes, or acquires, ownership of a message in a consumer group, as if the message was delivered a consumer group member. |
| `XDEL` | `<key> <id> ...` | Returns the number of messages after removing them from a stream. |
| `XGROUP` | — | A container for consumer groups commands. |
| `XGROUP CREATE` | `<key> <group> (<id> \| $) [MKSTREAM] [ENTRIESREAD <entries-read>]` | Creates a consumer group. |
| `XGROUP CREATECONSUMER` | `<key> <group> <consumer>` | Creates a consumer in a consumer group. |
| `XGROUP DELCONSUMER` | `<key> <group> <consumer>` | Deletes a consumer from a consumer group. |
| `XGROUP DESTROY` | `<key> <group>` | Destroys a consumer group. |
| `XGROUP HELP` | — | Returns helpful text about the different subcommands. |
| `XGROUP SETID` | `<key> <group> (<id> \| $) [ENTRIESREAD <entries-read>]` | Sets the last-delivered ID of a consumer group. |
| `XINFO` | — | A container for stream introspection commands. |
| `XINFO CONSUMERS` | `<key> <group>` | Returns a list of the consumers in a consumer group. |
| `XINFO GROUPS` | `<key>` | Returns a list of the consumer groups of a stream. |
| `XINFO HELP` | — | Returns helpful text about the different subcommands. |
| `XINFO STREAM` | `<key> [FULL [COUNT <count>]]` | Returns information about a stream. |
| `XLEN` | `<key>` | Return the number of messages in a stream. |
| `XPENDING` | `<key> <group> [[IDLE <min-idle-time>] <start> <end> <count> [<consumer>]]` | Returns the information and entries from a stream consumer group's pending entries list. |
| `XRANGE` | `<key> <start> <end> [COUNT <count>]` | Returns the messages from a stream within a range of IDs. |
| `XREAD` | `[COUNT <count>] [BLOCK <milliseconds>] STREAMS <key> ... <id> ...` | Returns messages from multiple streams with IDs greater than the ones requested. Blocks until a message is available otherwise. |
| `XREADGROUP` | `GROUP <group> <consumer> [COUNT <count>] [BLOCK <milliseconds>] [NOACK] STREAMS <key> ... <id> ...` | Returns new or historical messages from a stream for a consumer in a group. Blocks until a message is available otherwise. |
| `XREVRANGE` | `<key> <end> <start> [COUNT <count>]` | Returns the messages from a stream within a range of IDs in reverse order. |
| `XSETID` | `<key> <last-id> [ENTRIESADDED <entries-added>] [MAXDELETEDID <max-deleted-id>]` | An internal command for replicating stream values. |
| `XTRIM` | `<key> (MAXLEN \| MINID) [(= \| ~)] <threshold> [LIMIT <count>]` | Deletes messages from the beginning of a stream. |

## String

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `APPEND` | `<key> <value>` | Appends a string to the value of a key. Creates the key if it doesn't exist. |
| `DECR` | `<key>` | Decrements the integer value of a key by one. Uses 0 as initial value if the key doesn't exist. |
| `DECRBY` | `<key> <decrement>` | Decrements a number from the integer value of a key. Uses 0 as initial value if the key doesn't exist. |
| `GET` | `<key>` | Returns the string value of a key. |
| `GETDEL` | `<key>` | Returns the string value of a key after deleting the key. |
| `GETEX` | `<key> [(EX <seconds> \| PX <milliseconds> \| EXAT <unix-time-seconds> \| PXAT <unix-time-milliseconds> \| PERSIST)]` | Returns the string value of a key after setting its expiration time. |
| `GETRANGE` | `<key> <start> <end>` | Returns a substring of the string stored at a key. |
| `GETSET` | `<key> <value>` | Returns the previous string value of a key after setting it to a new value. |
| `INCR` | `<key>` | Increments the integer value of a key by one. Uses 0 as initial value if the key doesn't exist. |
| `INCRBY` | `<key> <increment>` | Increments the integer value of a key by a number. Uses 0 as initial value if the key doesn't exist. |
| `INCRBYFLOAT` | `<key> <increment>` | Increment the floating point value of a key by a number. Uses 0 as initial value if the key doesn't exist. |
| `LCS` | `<key1> <key2> [LEN] [IDX] [MINMATCHLEN <min-match-len>] [WITHMATCHLEN]` | Finds the longest common substring. |
| `MGET` | `<key> ...` | Atomically returns the string values of one or more keys. |
| `MSET` | `<key> <value> ...` | Atomically creates or modifies the string values of one or more keys. |
| `MSETNX` | `<key> <value> ...` | Atomically modifies the string values of one or more keys only when all keys don't exist. |
| `PSETEX` | `<key> <milliseconds> <value>` | Sets both string value and expiration time in milliseconds of a key. The key is created if it doesn't exist. |
| `SET` | `<key> <value> [(NX \| XX)] [GET] [(EX <seconds> \| PX <milliseconds> \| EXAT <unix-time-seconds> \| PXAT <unix-time-milliseconds> \| KEEPTTL)]` | Sets the string value of a key, ignoring its type. The key is created if it doesn't exist. |
| `SETEX` | `<key> <seconds> <value>` | Sets the string value and expiration time of a key. Creates the key if it doesn't exist. |
| `SETNX` | `<key> <value>` | Set the string value of a key only when the key doesn't exist. |
| `SETRANGE` | `<key> <offset> <value>` | Overwrites a part of a string value with another by an offset. Creates the key if it doesn't exist. |
| `STRLEN` | `<key>` | Returns the length of a string value. |
| `SUBSTR` | `<key> <start> <end>` | Returns a substring from a string value. |

## Transactions

| Command | Arguments | Metadata summary |
| --- | --- | --- |
| `DISCARD` | — | Discards a transaction. |
| `EXEC` | — | Executes all commands in a transaction. |
| `MULTI` | — | Starts a transaction. |
| `UNWATCH` | — | Forgets about watched keys of a transaction. |
| `WATCH` | `<key> ...` | Monitors changes to keys to determine the execution of a transaction. |
