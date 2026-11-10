# Owners

Owners add per-user privacy to [labels](labels.md). Every request names the end user it acts for, its owner, and one user's private data never reaches another user. An owner is the application's own user id, such as `u42`, `auth0|5f3c` or a UUID. `SHARED` is data that belongs to no user and that every user's commands can read. A command runs at a scope, a label and an owner, and a reader sees a copy when its label dominates the copy's label and the copy is shared or its own.

This release builds who is asking (the owner mode switch, the ways an owner arrives with a command, the login rules, the refusals, the transaction, watch, script and push bindings, the operator, the server-wide channels and the `OWNERS` command) and where the data lives: every key and vector set element is stored at the scope of the command that wrote it, each user's data is its own small partition, and another user's copy behaves exactly like a missing key.

## Owner mode

```sh
./bin/eski --save '' --appendonly no --memcached-port 0 --owners yes \
  --label-levels 'UNCLASSIFIED,CONFIDENTIAL,SECRET' \
  --user default on nopass '~*' '&*' '+@all' 'clearance:*' owner-operator
```

The hidden setting `owners` is `no` by default and turns owner mode on at startup or with `CONFIG SET owners yes`. Like a label scheme it never turns off: `CONFIG SET owners no` answers `owner mode cannot be turned off`. Owner mode needs persistence and the memcached endpoint off and is refused with the label scheme's own texts otherwise, and while it is on persistence answers `ERR persistence is off while a label scheme is configured`, as in labelled mode; without a label scheme the texts name owner mode instead: `owner mode needs persistence off: ...` and `owner mode needs the memcached endpoint off, because its requests carry no owner` when it is turned on, and `ERR persistence is off while owner mode is on` and `persistence stays off while owner mode is on` while it is on. The words `OWNER` and `SHARED` become reserved: owner mode is refused on a scheme with a level of either name (`owner mode needs a label scheme without a level named OWNER or SHARED`), and while it is on no level can be added or renamed to them. Turning it on writes an `owners-on` audit record. Owner mode starts on an empty server, as a label scheme does: `CONFIG SET owners yes` is refused while the server holds any key in any database, vector sets included, with `owner mode needs a server without keys, because existing keys carry no owner`, and a server started with owner mode exits at startup when the data file that `dir` and `dbfilename` name exists, saying why (see [Labels](labels.md#the-scheme)). To adopt owners for existing data, start the server empty in owner mode and write each user's data again through `LABEL AS OWNER <id>`, and shared data through `LABEL AS SHARED`; to keep the old data, start once without owner mode and move it out first, or move the file away.

Owner mode works with or without a label scheme. It turns on the protected mode of labels in either case: commands run on the coordinator, persistence and the memcached endpoint stay off, introspection below top is filtered and push features pin their scope. With the default one-level scheme every command's label is top, so top in owner mode also needs the operator scope described below.

The settings `owner-quota-default` (bytes, 0 for none) and `owner-partitions-max` (0, meaning no limit) are hidden like the label settings, readable by exact name and written by `CONFIG REWRITE`. Their effect is described under [Quotas and memory](#quotas-and-memory).

With owners off, Eski answers exactly as without this feature, in both labels-off and labelled mode, apart from the order of the ACL check in labelled mode described in [Labels](labels.md#logins) and two exceptions: the `OWNERS` command exists and answers `ERR owners are not enabled on this server` except for `OWNERS HELP`, and the owner login rules answer `Owners are not enabled on this server` instead of a syntax error. `CONFIG GET owners` and the two other settings also answer by exact name. The words `OWNER` and `SHARED` in `LABEL AS`, the `OWNER` and `SHARED` options of `CONTEXT CREATE` and owner lines in signed tokens fail exactly as before, as an unknown command, a syntax error and a refused token.

## Owner ids

An owner id is 1 to 128 bytes of printable ASCII other than space, compared byte for byte. The id `*` is reserved: the login rule `owner:*` is refused as an invalid owner rule and `OWNER *` answers `ERR invalid owner`, while `owners:*` keeps its meaning of any owner. Inside, Eski interns each id into a 32-bit number in the order of first use, the first command that names it, a read included. A number is never reused while the server runs and never appears in a reply, an error or an audit record; the text does. `OWNERS FORGET` drops an id, and a later use of it starts afresh. Ids appear in audit records, ACL files and error texts, and every id that is ever named, even by a read, keeps about 150 bytes until it is forgotten, so applications should pass opaque ids such as UUIDs or database keys, never e-mail addresses or other personal data.

## Logins

| Rule | Meaning |
| --- | --- |
| no owner rule | every command runs as `SHARED`, as before; naming a user owner is refused |
| `owners:*` | the login may act for any owner and must name one with every command except housekeeping |
| `owner:<id>` | the login always acts for that one owner; its commands need no prefix and naming another owner is refused |
| `owner-shared` | an `owners:*` or `owner:<id>` login may also run commands as `SHARED`, by naming `SHARED`; without it such a login cannot act on shared data |
| `owner-operator` | the operator scope: top in owner mode, the full introspection and the `OWNERS` commands |

`reset` clears the owner rules with every other rule, and the rules are refused while owners are off. `ACL LIST`, `ACL SAVE` and `ACL LOAD` carry them, and in owner mode `ACL GETUSER` adds an `owners` field (`*`, the id or empty) and lists `owner-shared` and `owner-operator` among the flags. An owner id in a rule needs no escaping, because it holds no space. A login without an owner rule may name `SHARED`, its only scope. An ACL change that leaves a connection's pinned owner, its transaction's owner or the owner of a key it watches outside what the login may now act for closes that connection, as does removing the operator scope from a login whose connection runs `MONITOR`.

## How the owner arrives

```text
LABEL AS SECRET OWNER u42 GET note
LABEL AS SECRET TRUST VETTED SHARED HGET doc:7 title
LABEL AS OWNER u42 GET note
LABEL AS SHARED GET catalog
LABEL AS OWNER u42 CONTEXT 3f1c...e9 VSIM memory ELE question
LABEL AS CONTEXT 3f1c...e9 GET note
LABEL AS TOKEN 65736b...2e.9a77...01 GET note
```

`LABEL AS <marking> [TRUST <trust>] [OWNER <id> | SHARED] [CONTEXT <handle>]` runs the wrapped command at that label for that owner. `LABEL AS OWNER <id>` and `LABEL AS SHARED` take the label from the connection's session, as an unprefixed command does, and count as unprefixed for the label rules: a `label-per-command` login is refused outside a transaction unless the command is housekeeping, and a `require-token` login accepts them only for housekeeping. With a `CONTEXT` tail the context's label must equal the session label, and a `require-token` login refuses the form. `LABEL AS CONTEXT <handle>` takes the label and the owner from the context, and `LABEL AS TOKEN` takes them from the token. `LABEL SESSION` takes no owner: there is no connection-wide owner except the push pin below.

The commands that need no owner on an `owners:*` login are `AUTH`, `HELLO`, `PING`, `ECHO`, `SELECT`, `QUIT`, `RESET`, `CLIENT SETNAME`, `CLIENT SETINFO`, `CLIENT ID`, `LABEL WHOAMI`, `LABEL HELP`, `LABEL SESSION`, `CONTEXT HELP` and `OWNERS HELP`; every other command answers `ERR this login must name an owner with every command` unless it names one or runs inside a transaction whose `MULTI` named one.

| Refusal | Cause |
| --- | --- |
| `ERR invalid owner` | a malformed id, an id the login may not act for, `SHARED` without the right, or a full owner table; one text for all, so a fixed-owner login cannot probe which ids exist |
| `ERR this login must name an owner with every command` | an unprefixed command of an `owners:*` login |
| `ERR the owner differs from the context's owner` | an explicit owner or `SHARED` that disagrees with the context it names |
| `ERR this connection is bound to another owner` | a named owner other than the connection's pinned owner |
| `ERR invalid context` | a context whose owner the login may no longer act for |
| `ERR invalid label token` | a token whose owner the login may not act for, a token without an owner line on an `owners:*` login, or a token whose context has another owner |

The arity and ACL checks of the wrapped command and its keys run first, with `NOPERM` and the `ACL LOG` record, then the label refusals of top-only commands and persistence and then these owner refusals. The refusals that decide which command runs and at which label come before them, as in labels: the errors of the `LABEL AS` prefix itself, the refusals of `label-per-command` and `require-token` logins, a transaction at another label, an invalid label and a subscription that needs a session (see [Labels](labels.md#logins)). A command that does not exist answers the unknown-command error whatever its owner.

## Keys

Every key lives at exactly one scope, the label and the owner of the command that created it, and each user's keys at a label form a small partition of their own, created by the first write there and released when it empties. Owner partitions keep their keys and values on the heap and their small tables in single heap blocks, so they need no mapping of their own and idle partitions cost no CPU: expiry, field expiry, rehashing and type maintenance visit only the partitions that have such work due, and eviction picks among owners in constant time.

A command for user `o` at label `r` sees a copy at label `d` and owner `w` when `r` dominates `d` and `w` is `SHARED` or `o`; another user's copy behaves exactly like a missing key, before any type check. When several visible copies share a name, a read returns one of them, in this order:

1. the user's own copy at exactly `r`;
2. otherwise the shared copy at exactly `r`;
3. otherwise the highest visible copy by the label order of [Labels](labels.md#keys) (higher level, then more compartments, then higher trust), the user's own copy before the shared one at equal rank, then the older copy within one scope.

A user without private data therefore reads exactly like a shared reader at the same label, and after `OWNERS FORGET` the user's reads equal the shared view. The rule matters with trust: a reader at `C` sees `C;VETTED` data, so a user's own copy at `C;VETTED` loses to the shared copy at exactly `C` for that reader, while a reader at `S` gets the own copy. A read never changes a copy at another scope: no access-time or frequency update, no lazy expiry, no field reaping and no cached HyperLogLog count, so `OBJECT IDLETIME` and `FREQ` count only accesses at the copy's own scope.

Every write lands at exactly the command's label and owner. When the writer sees the name only at another of its own labels or only as shared, the whole command is refused with `INUSE name in use at <label> SHARED` or `INUSE name in use at <label> OWNER <id>`, where the text after `at` is a valid `LABEL AS` head and the id is always the caller's own. Create-only forms (`SET NX`, `SETNX`, `MSETNX`, `RENAMENX` for its destination, `MOVE` for its target and `COPY` without `REPLACE`) give their normal already-exists answer instead. A shared writer never sees private copies, so creating a name a user also holds succeeds and every user keeps its own copy. `LABEL OF` ends with the same ` SHARED` or ` OWNER <id>` suffix in owner mode, for every caller. `LABEL DECLASSIFY` keeps the owner, `RENAME`, `MOVE` and `COPY` stay within the command's owner, and `COPY` from a visible shared source into the user's own scope is allowed, being a read and a write. No command changes an owner: data moves between users or into shared data only by a read and a write. `SWAPDB` is operator only and swaps the owner partitions with the databases.

`DBSIZE`, `INFO keyspace`, `KEYS`, `SCAN` and `RANDOMKEY` show each visible name once, counting the user's own partitions and the shared partitions at visible labels; the work is bounded by the user's own data and the shared data the user can see, never by the number of owners. `RANDOMKEY` draws uniformly over the visible names from the scope's own random stream. For a user reader the `SCAN` cursor is an unsigned 64-bit number sent as text, as every cursor is: bit 63 is always clear, bits 48 to 62 hold an ordinal, bits 1 to 47 a position and bit 0 the phase, which is 0 while the scan walks the labels where the user has held keys in the database and 1 while it walks the shared labels. A scan can return a name twice but never misses one that stays present, across partition releases and `OWNERS FORGET` included, and cursor values depend only on data the caller can see. Shared readers and label-only servers keep the labels cursor unchanged.

`LABEL COPIES [OWNER <id> | SHARED] [<key>]`, operator at top, lists the names held at more than one label within one scope, `SHARED` by default, or the copies of one name in that scope with their scope suffix; there is no listing across owners.

Random draws (`RANDOMKEY`, `SPOP`, `SRANDMEMBER`, `HRANDFIELD`, `ZRANDMEMBER`, `VRANDMEMBER`, skiplist levels, frequency counters, graph levels and quota eviction sampling) come from one stream per scope, seeded from the label, the owner's id and the server's startup secret, so another user's draws never move a visible draw. A scope's stream is stored only once a command has drawn from it; a command that draws nothing allocates nothing.

### FLUSHDB and FLUSHALL

What a flush deletes depends on how the command names its owner:

| The flush | Below a top label | At a top label |
| --- | --- | --- |
| acts for a user: `OWNER <id>`, a context or token with that owner, or an `owner:<id>` login | that user's keys at exactly the command's label | that user's keys at every label |
| names `SHARED` explicitly, or comes from a non-operator login without owner rules | the shared keys at exactly the command's label | the shared keys at every label |
| comes from an operator (a login with `owner-operator` and no owner rule) that names no owner | the shared keys at exactly the command's label | everything: every user and the shared data |

Only the last case at a top label deletes every user's data. An `owners:*` login must name an owner or `SHARED` on every command, so it can never flush everything; to remove one user use `OWNERS FORGET`. Inside a transaction the owner named by `MULTI`, or by any queued command, decides the case. Watches, tracking and notifications follow the scope of the deletion: a flush of one user's keys marks only that user's watchers and invalidates only the clients pinned to a scope that dominates it.

## Vector sets

A vector set element carries its writer's scope, and each label and owner present in a set is its own partition of the set. A user's partition starts as a flat block that is searched exactly and becomes a graph above 512 elements, as label partitions do. A set has a key in every partition, owner or shared, where it holds elements, and a reader sees the set exactly when it can see one of its elements; `DEL`, `UNLINK`, expiry, eviction, `RENAME` and `MOVE` act on the elements of the command's own scope only.

Elements resolve with the same order as keys: the user's own element at exactly the reader's label, then the shared element at exactly that label, then the highest visible rank with the user's own element first at equal rank. `VSIM` searches every visible partition and merges exactly by score, then by name; `VCARD`, `VRANGE`, `VRANDMEMBER`, `VINFO` and `VLINKS` count and list each visible name once. A write of an element the writer sees only at another of its labels, or only as shared, answers `INUSE element in use at <label> SHARED` or `... OWNER <id>`, and `LABEL OF <key> <element>` carries the same suffix. A user's partition is charged its own block, elements and names; the set's shared structure is charged to a shared partition, or to global memory when the set has none. Opening a user's view costs the visible shared partitions, the user's own partitions and, when a collision check is due, the user's own names, never anything per other user.

## Quotas and memory

`OWNERS QUOTA <id> LIMIT <bytes>` sets one user's quota, and `owner-quota-default` applies to every user without one. A user's usage is the sum over its partitions in every database: keys, values, vector set elements and the user's share of each set, the structures that hold them, and the owner entry itself (the entry, its id and its slot in the owner table). Before a command that can grow memory runs over the user's quota, Eski evicts inside that user's partitions only, by `maxmemory-policy`; if the user is still over, the command answers `OOM command not allowed when used memory > 'owner-quota'.`. Label quotas count shared data only, so one user's writes never evict another user's keys through a label quota. Global `maxmemory` still covers the whole server, and without a quota for every user it remains a channel between users, as for labels. `owner-partitions-max`, when set, caps the number of owner partitions and answers `ERR owner partition limit reached` past it; that count is itself a channel between users.

Every owner structure counts in `used_memory`. Measured on this release with 300,000 users, a user holding one small key costs about 1.9 KiB in `used_memory` and 2.0 KiB of resident memory, and one vector set element in a set that all of them share about 0.6 KiB more, so 300,000 such users take about 730 MB counted and 790 MB resident. A more compact form of the per-user partition is in progress. An owner entry, about 0.2 KiB (211 bytes for a 7-byte id), is created by the first command that names the id, reads included, and lasts until `OWNERS FORGET`; it counts in the user's quota use.

## Forget

`OWNERS FORGET <id>` runs at once on the coordinator, freeing large values lazily. It removes every key and vector set element of the user in every database, sends the `del` events at the user's scope when keyspace notifications are on, marks the user's watchers, invalidates its tracked keys, closes the connections pinned to it, bound to it or blocked as it, and drops its contexts, cached tokens, slow log entries, random streams and entry. It reads and changes no shared partition and no other user's structure, so nothing another user or a shared reader can observe changes, apart from global memory and timing. It replies with the `keys`, `elements` and `bytes` removed; `bytes` includes the entry. Shared data written on a user's behalf is not that user's data and stays.

## Contexts and signed tokens

`CONTEXT CREATE [LEVEL <marking>] [TRUST <trust>] [OWNER <id> | SHARED]` fixes a label and an owner. The owner defaults to the creating command's owner and must be one the login may act for, else `ERR invalid owner`. `CONTEXT INFO` also returns the `owner` (the id, or nil for `SHARED`) in owner mode. An agent that holds a handle cannot change its owner, and the contexts of a forgotten owner are dropped.

A signed statement may carry one line `owner <id>` or one line `shared`. On an `owners:*` login exactly one of them is required; on other logins a token without one runs at the login's own owner. The token's owner must be one the login may act for, and when the token names a context the context must have the same owner. Servers without owner mode refuse such tokens, because they refuse unknown lines.

## Transactions and scripts

`MULTI` binds the label and the owner. A queued command that names another owner is refused when it is queued with `ERR the command's owner differs from the transaction's owner`, and `EXEC` must carry the same owner or none, else it answers `EXECABORT Transaction discarded because of: the command's owner differs from the transaction's owner`. `WATCH` records its scope: when any key was watched at a scope other than the transaction's label and owner, `EXEC` runs nothing, whatever the data, and answers `EXECABORT Transaction discarded because of: the command's label differs from the transaction's label` when a label differs and `EXECABORT Transaction discarded because of: the command's owner differs from the transaction's owner` when only owners differ. A label that differs is reported first, as labels report it without owners.

Scripts and functions run for the caller's owner, and `LABEL WHOAMI` inside them shows it. `LABEL AS` stays refused inside scripts, and `OWNERS` is not allowed from scripts. While a script is busy, `SCRIPT KILL`, `FUNCTION KILL` and the running script in `FUNCTION STATS` need a label that dominates the script's label and, on top of that, the script's own owner or the operator scope. Seeing the script's owner is not enough: `SHARED` sits below every user, yet a user may not act on a script that runs as `SHARED`, nor on one that runs for another user; for such a caller `FUNCTION STATS` shows no running script and the kill commands answer `ERR this command needs a label that dominates the running script's label`.

The script cache and the stored functions follow the scope as they follow the label in [Labels](labels.md#transactions-and-scripts). Changing stored functions and `SCRIPT FLUSH` need the operator at top. A cached script is visible to a caller that sees one of the scopes that loaded it: a user sees the scripts loaded as `SHARED` at labels it dominates and its own, never another user's, and the operator at top sees them all. The `EVAL` bound and its eviction apply per scope, each scope has its own `math.random` stream, every run starts with the engine's starting cjson settings, and `OWNERS FORGET` drops the scripts and the stream of the forgotten user. Function code is installed by the operator and must not keep data between calls, because a library's closures survive calls for every user. [Scripts](scripting.md#labels-and-owners) gives the details.

## The push pin

`SUBSCRIBE`, `PSUBSCRIBE`, `SSUBSCRIBE` and `CLIENT TRACKING ON` fix the connection's owner together with its label. A login without an owner rule pins at `SHARED`, an `owner:<id>` login at its id, and an `owners:*` login must name the owner on that command with the owner-only prefix, as in `LABEL AS OWNER u42 SUBSCRIBE ch`; a marking in the prefix stays refused as labels refuse it without a session. An `owners:*` operator that names no owner pins at every owner. The pin is set only after the command passes the arity and `ACL` checks and the label and owner refusals, so a push command refused with `NOPERM`, or with an owner refusal such as `ERR this login must name an owner with every command`, pins neither the session nor the owner. After pinning the connection receives only messages whose scope its pin dominates, and every later command on it that names another owner is refused with `ERR this connection is bound to another owner`, so a client-side cache never mixes two users. `RESET` and `AUTH` to another login clear the pin; a connection that still holds subscriptions or tracking is then pinned at the new login's owner, or closed when the new login must name owners. `LABEL WHOAMI` shows the pin in `pinned-owner`: nil, `SHARED`, `OWNER <id>` or `EVERY`.

## The operator and top

Top in owner mode means two things at once: the command's label dominates the scheme's top label, and the login carries `owner-operator`. The top-only commands of labels (`MONITOR`, `LATENCY`, `SWAPDB`, `DEBUG`, `CLIENT PAUSE` and `UNPAUSE`, `MEMORY STATS`, `DOCTOR`, `MALLOC-STATS` and `PURGE`, `SLOWLOG RESET`, `CONFIG RESETSTAT`, `LABEL COPIES` and `LABEL QUOTA`, `FUNCTION LOAD`, `DELETE`, `FLUSH` and `RESTORE` and `SCRIPT FLUSH`), the full `INFO` numbers and the `OWNERS` subcommands other than `HELP` need it, else `ERR this command needs a label that dominates the whole label scheme`, or `ERR this command needs a login with the owner-operator right` when the label is top and only the operator scope is missing, as it always is for a login without `owner-operator` in owner mode without a label scheme. For the filtered introspection below, the operator sees every owner at the labels it dominates.

## Server-wide channels

| Channel | Rule in owner mode |
| --- | --- |
| Pub/sub | a message carries the publishing command's scope and reaches only connections whose pin dominates it; `PUBLISH` and `SPUBLISH` count the receivers at exactly the publisher's scope; `PUBSUB CHANNELS`, `NUMSUB`, `NUMPAT`, `SHARDCHANNELS` and `SHARDNUMSUB` count only the subscribers the caller dominates |
| Keyspace notifications | carry the changed copy's scope, its label and its owner, expired and evicted events included, so they reach only pins that dominate it: a user's events reach that user's pins and operator pins, shared events reach every pin at a dominating label |
| `WATCH` | aborted by any write at a scope the watcher's own scope sees, shared writes included, and never by another user's writes; flushes and `SWAPDB` mark watchers by what their own view held |
| Blocking | pops and moves wait on the name at exactly their label and owner; read-only blockers such as `XREAD` wake on writes at any scope they see |
| Client tracking | invalidations, broadcast mode, flushes and `REDIRECT` targets included, reach only connections whose pin dominates the written scope, so a client-side cache never mixes two users |
| `MONITOR` | top in owner mode, so operator only, and sees every command |
| `CLIENT LIST`, `CLIENT KILL`, `CLIENT UNBLOCK` | a connection's scope is its pin; for a login without an owner rule it is `SHARED`, for an unpinned `owner:<id>` connection its id, and for an unpinned `owners:*` connection, which serves many users in turn, every owner, which only the operator sees; a connection always sees itself |
| `SLOWLOG GET` and `LEN` | an entry carries its command's scope and shows to the callers that dominate it; ids and the capacity stay shared |
| `INFO` | below top as in labelled mode, with `INFO keyspace` counting the caller's view; the operator also gets an `# Owners` section with `owners_known` (entries in the owner table), `owners_holding_data` (users with a key or element), `owner_partitions` and `owner_bytes` (users' data and structures, entries included); at operator top `DBSIZE` and `INFO keyspace` count the shared view |
| Scripts and functions | run at the caller's scope; the script cache, `SCRIPT EXISTS` and `EVALSHA` see only scripts loaded at scopes the caller sees; stored functions change only at operator top, and `FUNCTION LIST` shows the operator's libraries to everyone |
| `ACL LOG` | stays an administrative command |

## The OWNERS command

| Command | Rule |
| --- | --- |
| `OWNERS FORGET <id>` | removes every key and vector set element of the owner in every database, closes every connection pinned to the owner, bound to it by `MULTI` or `WATCH`, or blocked as that owner, drops its contexts, its cached tokens and its slow log entries, drops its id and writes an `owner-forget` audit record with the counts; replies with a map of the `keys`, `elements` and `bytes` removed (see [Forget](#forget)) |
| `OWNERS INFO <id>` | the owner's `keys`, `elements`, `bytes`, `partitions`, `labels` and `quota`, counts only |
| `OWNERS LIST <cursor> [COUNT <count>]` | a cursor over the ids of the owners that hold data (a key or a vector set element in any database), in order of first use; each step costs the same whatever the owners hold |
| `OWNERS QUOTA <id> [LIMIT <bytes>]` | shows the owner's quota and used bytes, or sets the quota (0 falls back to `owner-quota-default`) and writes an `owner-quota` audit record |
| `OWNERS HELP` | the subcommands |

`FORGET`, `INFO`, `LIST` and `QUOTA` are the subcommands `owners|forget`, `owners|info`, `owners|list` and `owners|quota`, in the `@admin` and `@dangerous` categories only, and need the operator at top. Shared data written on a user's behalf is not that user's data and is not forgotten.

## Audit

The audit file of labels receives `owners-on` when owner mode turns on, `owner-forget` with the id and the counts, `owner-quota` with the id and the limit, and the ACL changes to owner rules through `acl-setuser`. Records never carry values.

## What stays observable

Everything that [Labels](labels.md#what-comes-next) lists as observable across labels stays observable across users, among them the `BUSY` replies that every connection gets while any user's script runs, counts that include expired keys not yet removed at a pace all users share, the label table that one login can fill for everyone, and the shared Lua engine state with the closures of stored functions. Reads for another user leave no trace, so shared data that users only read looks unused to the eviction policy; where that matters, use per-user and per-label quotas or the `noeviction` policy.

## What this release does not do

Owners are not yet carried by snapshots, the append-only file, `DUMP` or `RESTORE`, so persistence stays refused in owner mode. The documented channels between users are global `maxmemory`, `owner-partitions-max` when set, timing, and `MEMORY USAGE` below top, whose figures for hashes, lists, sets, sorted sets, streams and vector sets come from the allocator's usable sizes and can differ by a few bytes with other scopes' allocation history; string sizes do not. The script cache and function libraries stay global. Per-user retention and sharing private data between users are not built.

Verify with `python3 -I test/compatibility/owners_keyspace.py --server bin/eski` and `python3 -I test/compatibility/owners_subjects.py --server bin/eski`, each also with `--keyspace-threads 2`, `odin test src/owner` and `python3 -I proofs/verify.py --project label`. The [command reference](commands.md) lists the `OWNERS` subcommands.

Eski is an independent project, not affiliated with, endorsed or certified by Redis Ltd. Redis is a registered trademark of Redis Ltd.; any rights therein are reserved to Redis Ltd.
