# Labels

Labels let one Eski node hold data for readers with different clearances. A label is a level, a set of compartments and a trust level. The operator configures the scheme of names, each login gets a clearance, and every command runs at one label that the application asserts for it. This release builds who is asking (the scheme, the logins, the ways a label arrives with a command, contexts, signed levels, transactions and scripts, labelled pub/sub, the server-wide channels, the audit file and the refusal of persistence) and what is stored: every key of the ordinary types carries the label of the command that created it, and every vector set element carries the label of the command that wrote it.

Without a scheme Eski behaves exactly as before. The default scheme has one level named `UNCLASSIFIED`, no compartments and one unnamed trust level; in that mode replies are the reference's, nothing on the request path consults labels beyond one predictable branch, and the `LABEL` and `CONTEXT` commands answer `ERR labels are not configured on this server` except for `HELP`.

## The scheme

```sh
./bin/eski --save '' --appendonly no \
  --label-levels 'UNCLASSIFIED,CONFIDENTIAL,SECRET,TOP SECRET' \
  --label-compartments 'A,B' \
  --label-trust-levels 'WEB,VETTED' \
  --label-audit-file /var/lib/eski/audit.log
```

`label-levels` lists up to 256 levels from lowest to highest, `label-compartments` up to 256 compartments and `label-trust-levels` up to 256 trust levels from lowest to highest; each value is a comma-separated list. A name has 1 to 64 bytes of letters, digits, `-`, `_` and single inner spaces, starts each word with a letter or a digit, and is folded to upper case. Levels and compartments share one set of names, trust levels have their own, and `CONTEXT` and `TOKEN` cannot name a level. An empty trust list means one unnamed trust level. The scheme is labelled as soon as it has more than one level, any compartment or more than one trust level.

A scheme can grow but never shrink. At startup each directive sets its list. Afterwards `CONFIG SET` may only rename names in place and append new ones; a list that is shorter, reorders names or reuses a name the scheme already had is refused with `label scheme names can be added and renamed, never removed or reordered` or `a renamed or added label name must be new to the scheme`. Because stored data refers to positions, a rename changes how every marking is written and nothing else. `CONFIG` is an administrative command, the settings are hidden from `CONFIG GET *` like Eski's other settings that the 7.4 server lacks, `CONFIG REWRITE` writes them, and every change is written to the audit file.

A labelled scheme and persistence exclude each other until the next stage carries labels into the files. A scheme is refused while `save` has save points, `appendonly` is `yes` or `shutdown-on-sigterm` or `shutdown-on-sigint` includes `save`, including the default save points, and while a scheme is configured `CONFIG SET save` with save points, `CONFIG SET appendonly yes`, setting either shutdown option to include `save`, `SAVE`, `BGSAVE`, `BGREWRITEAOF`, `DUMP`, `RESTORE`, `RESTORE-ASKING`, `MIGRATE`, `DEBUG RELOAD`, `DEBUG LOADAOF`, `SHUTDOWN SAVE` and the replication commands answer `ERR persistence is off while a label scheme is configured`. The snapshot and append-only writers refuse on their own as well, so no signal or timer can write a file, and SIGTERM and SIGINT always stop a labelled server without saving. For the same reason a scheme is refused while the memcached endpoint is on, because memcached requests carry no label.

## Markings and the order

A marking is written `LEVEL`, `LEVEL//COMPARTMENT/COMPARTMENT` or either of those followed by `;TRUST`, for example `SECRET//A/B;VETTED`. Input is case-insensitive and tolerates spaces around names; replies use the canonical form, with compartments in configuration order and the trust part left out at the lowest trust level. Commands also accept the trust as a separate `TRUST <name>` argument, but not both forms at once.

A reader at label r can read data at label d when r's level is at least d's, r's compartments include d's, and r's trust is at most d's. A trusted task therefore reads only data at its trust or higher, while an untrusted task reads everything its level allows. Every write lands exactly at the command's label, including its trust. A label is top when it dominates every label the scheme can form: the highest level, every compartment and the lowest trust.

## Logins

| Rule | Meaning |
| --- | --- |
| `clearance:<marking>` | the highest level and compartments the login may assert; `clearance:*` means the top of the scheme as it grows; without the rule a login has the lowest level and no compartments |
| `trust:<name>` | the highest trust the login may assert; `trust:*` means the highest trust level; without the rule a login has the lowest trust |
| `label-per-command`, `label-per-session` | require every command to arrive through `LABEL AS`, or allow commands that run at the session label (the default) |
| `require-token`, `token-optional` | accept only `LABEL AS TOKEN`, or also the other forms (the default) |
| `token-key:<64 hex digits>`, `reset-token-keys` | add an Ed25519 public key for signed levels, up to eight, or remove them all |

A space inside a marking or a name is written as `+` in these rules, for example `clearance:TOP+SECRET//A`, because ACL files separate rules by spaces; `ACL SETUSER` also accepts a real space inside one argument. The clearance is checked component by component and is not dominance: an asserted label is allowed when its level is at most the clearance's level, its compartments are among the clearance's and its trust is at most the trust rule. `ACL LIST`, `ACL SAVE` and `ACL LOAD` carry the rules, `ACL GETUSER` adds `clearance`, `trust` and `token-keys` fields and lists `label-per-command` and `require-token` among the flags, and `reset` clears them all. The rules are refused while no scheme is configured. An ACL change that leaves a connection's session, transaction label or monitor label outside the login's new clearance closes that connection, and an ACL change that removes a login drops its contexts.

The ACL checks commands and keys exactly as before; labels add to them and replace nothing. Rights over labels are ordinary subcommand rules: `CONTEXT CREATE` is the subcommand `context|create`, in the `@admin` and `@dangerous` categories only, so `+@all` and an explicit `+context|create` grant it while `+@all -@dangerous`, `+@all -@admin` and `+@slow` do not; an agent login should still carry `-context|create` when it is built from `+@all`. The `CONTEXT` container itself has no category. The `LABEL AS` prefix itself is not checked by the ACL; the wrapped command is.

## How a command gets its label

```text
LABEL AS SECRET//A GET doc:7
LABEL AS SECRET//A TRUST VETTED HSET doc:7 title draft
LABEL AS CONTEXT 3f1c...e9 VSIM memory ELE question
LABEL AS SECRET//A TRUST VETTED CONTEXT 3f1c...e9 GET doc:7
LABEL AS TOKEN 65736b...2e.9a77...01 GET doc:7
LABEL SESSION CONFIDENTIAL
LABEL WHOAMI
```

`LABEL AS` wraps exactly one command in the same request, so it is safe under pipelining and on pooled connections; the ACL checks the wrapped command and its keys. With a marking it runs the command at that label, with `CONTEXT` at the context's label, with a marking and `CONTEXT` only when they are equal, and with `TOKEN` at the label of a verified signed statement. `LABEL AS` cannot wrap `LABEL AS` or `LABEL SESSION`. Without a prefix a command runs at the connection's session label: the one set with `LABEL SESSION <marking> [TRUST <name>]`, or else the login's clearance level and compartments at the lowest trust. `RESET` and `AUTH` clear the session, and a connection's label state counts toward its client memory (`tot-mem` in `CLIENT LIST`). `LABEL WHOAMI` returns the login, the command's label as one text and as marking and trust, the clearance, the trust clearance, whether a session was set, the two login flags and whether the label is top.

Unknown names, names outside the clearance and a full label table all answer the same `ERR invalid label`, so the vocabulary cannot be probed. On a `label-per-command` login every other command is refused with `ERR this login must send every command through LABEL AS`, except `AUTH`, `HELLO`, `PING`, `ECHO`, `SELECT`, `QUIT`, `RESET`, `CLIENT SETNAME`, `CLIENT SETINFO`, `CLIENT ID`, `LABEL WHOAMI`, `LABEL HELP` and `CONTEXT HELP`, and `LABEL SESSION` answers `ERR LABEL SESSION is not available to this login`; a `require-token` login behaves the same way and accepts only `LABEL AS TOKEN`. Subscriptions and `CLIENT TRACKING ON` need a session set with `LABEL SESSION`, because pushed messages carry no label of their own; they answer `ERR this command needs a session label set with LABEL SESSION` otherwise, so push features use a login without `label-per-command`.

The SDKs of a later stage expose the label and the context as properties of a client, never as arguments of a call, so that a language model composing a command cannot choose its own label. Until then the application must add the prefix itself and must never let model output reach it.

## Transactions and scripts

A label on `MULTI` binds the transaction: queued commands run at that label whether or not they repeat it, a queued command with a different label is refused when it is queued with `ERR the command's label differs from the transaction's label` and the transaction is discarded at `EXEC`, and `EXEC` itself must carry the same label or none. Without a prefix, `MULTI` binds the session label. On a `label-per-command` login only `MULTI` needs the prefix. `LABEL SESSION` is not allowed inside a transaction.

Scripts and functions run at the label of the command that called them, and every `redis.call` inside them uses it. `LABEL AS`, `LABEL SESSION` and every `CONTEXT` subcommand except `HELP` are refused inside scripts, while `LABEL WHOAMI` shows the caller's label. While a script is busy, the commands other connections may still run (`SCRIPT KILL`, `FUNCTION KILL`, `FUNCTION STATS`, `AUTH`, `HELLO`, `MULTI`, `WATCH` and the rest) run at their own connection's label, including a `LABEL AS` prefix, and the script's label is restored afterwards. `FUNCTION STATS` shows the running function only to a caller whose label dominates the label the script runs at, and `SCRIPT KILL` and `FUNCTION KILL` need such a label, or else answer `ERR this command needs a label that dominates the running script's label`.

## Contexts

```text
CONTEXT CREATE [LEVEL <marking>] [TRUST <name>]
CONTEXT INFO <handle>
CONTEXT DROP <handle>
```

A context fixes one label for one task, typically an agent's run on behalf of a user. `CONTEXT CREATE` returns a handle of 32 hexadecimal digits drawn from the operating system's random source and bound to the creating login. Its label is the creating command's label, with `LEVEL` replacing the level and compartments and `TRUST` the trust, and it must be within the login's clearance. Commands under the context read what its label dominates and write exactly at it. `CONTEXT INFO` returns the marking and the trust so that the application can stamp the agent's answer, and `CONTEXT DROP` ends the context. A handle from another login, an expired handle and an unknown or malformed handle all answer `ERR invalid context`, and a context whose label has left the login's clearance stops working. A context expires after `label-context-idle-timeout` seconds without use (default 3600), and a login holds at most `label-context-max-per-login` contexts (default 1000); both are operator settings.

## Signed levels

A signed level lets the application relay a label that a separate issuer signed, so that a compromised application can only replay labels it was given. The token is the hexadecimal encoding of a statement, a dot, and the hexadecimal encoding of the statement's 64-byte Ed25519 signature. The statement is text with one field per line:

```text
eski-label-token 1
marking SECRET//A
trust VETTED
expires 1767225600000
audience prod-node-1
context 3f1c0a5e6b7d8c9f0a1b2c3d4e5f6a7b
```

The header line, `marking`, `expires` (Unix time in milliseconds) and `audience` are required; `trust` and `context` are optional; each field appears at most once and any other line refuses the token. Eski accepts a token when its signature verifies with one of the login's `token-key` rules, the audience equals the `label-token-audience` setting (tokens are refused while it is empty), it has not expired, its label is within the login's clearance and, when it names a context, that context belongs to the login and has the same label. Any failure answers `ERR invalid label token`. Verified statements are cached by a hash of the login and the token, with the expiry and the clearance checked again on every use and the cache cleared by every ACL change. Issuing tokens belongs to the paid layer; Eski only verifies them.

## What is enforced in this release

| Channel | Rule |
| --- | --- |
| Pub/sub | a message carries the publishing command's label and reaches only subscribers whose session label dominates it; `PUBLISH` and `SPUBLISH` count the receivers at exactly that label; `PUBSUB CHANNELS`, `NUMSUB`, `NUMPAT`, `SHARDCHANNELS` and `SHARDNUMSUB` count only subscribers the caller dominates |
| Keyspace notifications | published through the same path with the label of the copy that changed, so they reach only sessions that dominate it |
| `MONITOR`, `LATENCY`, `SWAPDB`, `DEBUG`, `CLIENT PAUSE`, `CLIENT UNPAUSE`, `MEMORY STATS`, `DOCTOR`, `MALLOC-STATS` and `PURGE`, `SLOWLOG RESET`, `CONFIG RESETSTAT` | need a top label, else `ERR this command needs a label that dominates the whole label scheme`; a monitor sees only commands its label dominates |
| `CLIENT LIST`, `CLIENT KILL`, `CLIENT UNBLOCK` | act only on connections whose session label the caller dominates |
| `SLOWLOG GET` and `LEN` | show only entries whose label the caller dominates |
| `INFO` | for callers below top, `connected_clients` counts the connections they dominate, the other numbers of the clients, memory, persistence, stats, replication and CPU sections are zero, and the command, error and latency statistics are empty; the server section is unchanged and the keyspace section counts what the caller can see (see Keys) |
| `ACL LOG` | stays an administrative command |

The audit file named by `label-audit-file` is opened at startup, append-only with mode 0600, and receives one JSON line per event with the time in milliseconds, the login, the client id and address, the event and its details: `scheme-load` at startup, `scheme-change` with the list before and after, `acl-setuser` with the rules (password rules redacted), `acl-deluser`, `acl-load`, `declassify` and `raise` with the key, the element and both labels (never values), and `label-quota`. Storing and searching audit records belongs to the paid layer.

While a scheme is configured every command runs on the coordinator; the keyspace workers stay idle.

## Keys

Every key of the ordinary types (strings, lists, sets, hashes, sorted sets and streams, with bitmaps, HyperLogLog and geo following their storage type) has one label: the label of the command that created it. A name can exist at more than one label; each such copy is an independent key.

A read returns exactly one copy: the copy at exactly the command's label if there is one, otherwise the highest copy the reader can see, ordered by higher level, then more compartments, then higher trust, then the older copy. A copy's age is the moment its name came into existence at its label: overwriting a copy keeps its age, while deleting and recreating it, or creating it by `RENAME`, `MOVE` or `COPY`, makes a new copy. A copy the reader cannot see behaves exactly like a missing key before any other check, so `GET` answers nil, `TYPE` none, `EXISTS` 0 and `TTL` -2, and a write of another type creates a new copy instead of answering `WRONGTYPE`.

A write lands exactly at the command's label. When the copy at exactly that label exists, the write applies to it as usual. When the writer can see a copy only at another label, the whole command is refused before any effect with `INUSE name in use at <label>`, which names the copy the writer would read; this covers creating, overwriting, changing and deleting, including `SETNX`, `SET NX`, `MSETNX`, `RENAMENX`, `HSETNX`, `MOVE` and `COPY`, which answer the error rather than 0. When the writer can see no copy, the copy is created at the command's label and any hidden copy stays hidden. The check runs once per command from its key specifications, after the arity and ACL checks and before the command's own syntax and type checks; in a transaction it runs when `EXEC` reaches the command, and in a script for each `redis.call`. A task at `SECRET` therefore cannot change or delete its own `UNCLASSIFIED` keys; that is intended. Multi-key commands read their sources as reads and write their destinations as writes, and `SORT BY` and `GET` read hidden keys as missing.

A read of a copy at another label never changes it: it does not touch the copy's access time or frequency, does not delete it when expired, does not delete expired hash fields and does not write the HyperLogLog cardinality cache. `OBJECT IDLETIME` and `OBJECT FREQ` therefore count only accesses made at the copy's own label.

Listings and counts show each name once. `SCAN`, `KEYS` and `RANDOMKEY` walk one dictionary per label the reader can see; a name with copies at several visible labels appears only at the copy a read resolves to. A labelled `SCAN` cursor holds the position among the labels the reader can see that have held keys in the database and an exact position in that label's hash space, so cursor values and the keys of each call depend only on visible data, and a label that appears during a scan can repeat keys but never skip one. `RANDOMKEY` draws a visible key uniformly, retries only on visible keys that are shadowed by another copy or expired, and after 100 draws falls back to an exact pass over the visible labels, so it answers nil only when the reader can see no live name. `DBSIZE` and the keys and expires of `INFO keyspace` keep the per-database meaning they have without labels (keys present in the table, including expired keys not yet reaped) and are summed over the visible labels, minus the extra copies of names held at more than one visible label; `avg_ttl` is the average over the visible labels weighted by their timed keys.

`FLUSHDB` and `FLUSHALL` delete only the keys at exactly the command's label, in the selected database or in every database; at a top label they delete everything. `SWAPDB` needs a top label and swaps every label of both databases.

`WATCH` is aborted by a write at any label the watching command's label dominates, and never by a write at a hidden label. A blocking pop or move waits on the name at exactly its own label, because that is the only copy it can change; `XREAD` and other read-only blocking commands wake on a write at any label they dominate. A keyspace notification carries the label of the copy that changed, and client tracking invalidations, including broadcast mode and the invalidation that follows a flush, reach only clients whose session label dominates that label.

Random draws (`RANDOMKEY`, `SRANDMEMBER`, `SPOP`, `HRANDFIELD`, `ZRANDMEMBER`, `VRANDMEMBER`, the frequency counter of the LFU policies and the levels of new graph nodes) come from one stream per command label, so commands at other labels never shift a draw. The streams are seeded from the label and a secret drawn at startup; the hidden startup setting `label-stream-seed` fixes the secret for tests.

Each label of a database is its own dictionary with its own value storage, and the hidden startup setting `label-partitions-max` (default 1024) bounds how many of them the server holds across all databases: a write that needs a new one beyond the limit answers `ERR label partition limit reached`, and reads never create one. Data that exists when a scheme is configured at run time becomes data at the lowest label.

## Vector sets

A vector set element carries the label of the command that wrote it, and each label in a set is its own index. A set is present at each label where it holds elements, so a reader sees the set exactly when it can see one of its elements, and its view is the set's visible elements, one copy per element name by the same order as keys. Searches run over every visible label and merge exactly by score, then by name. `VADD` into a set the writer can see adds the element at the writer's label; a name the writer can see only at another label answers `INUSE element in use at <label>`, as do `VREM` and `VSETATTR` for an element the writer can see only elsewhere. A set present at a label the writer cannot see stays hidden, so a lower writer can create any type under the same name at its own label.

`DEL`, `UNLINK`, expiry, eviction and `FLUSHDB` at a label remove only that label's elements, and `EXPIRE` sets a deadline for that label's part only. `RENAME` and `MOVE` move only the elements at the command's label into a set of their own. `COPY` of a vector set is refused as it is without labels. `MEMORY USAGE` and `DEBUG OBJECT` report the reader's view. A set that exists when a scheme is configured is read as data at the lowest label.

## Key commands

| Command | Rule |
| --- | --- |
| `LABEL OF key [element]` | the label of the copy, or of the vector set element, that a read resolves to, or nil |
| `LABEL DECLASSIFY key <marking> [TRUST <trust>] [ELEMENT <element>]` | moves the copy at exactly the command's label, or one of its vector set elements, to a label the command's label dominates, keeping value, expiry and access time; refused with `INUSE name in use at <label>` when the target holds a copy; needs the `label|declassify` right and writes a `declassify` audit record |
| `LABEL RAISE key <marking> [TRUST <trust>] [ELEMENT <element>]` | the same towards a label that dominates the command's label; needs `label|raise` and writes a `raise` audit record |
| `LABEL COPIES [key]` | needs a top label; the names held at more than one label in the selected database, or every copy of one key with its type, for cleanup |
| `LABEL QUOTA <marking> [TRUST <trust>] [LIMIT <bytes>]` | needs a top label; shows the quota and the bytes held at exactly that label across all databases, or sets the quota (0 removes it) |

`LABEL OF` is in the `@fast` and `@connection` categories; `DECLASSIFY`, `RAISE`, `COPIES` and `QUOTA` are only in `@slow`, so `+@write`, `+@keyspace` and `+@dangerous` do not grant them, while `+@all` and `+@slow` do. Agent logins are configured without them, for example with `-label|declassify -label|raise`.

A quota bounds the keys, values and dictionary memory at exactly one label. Before a command that can grow memory runs at a label over its quota, Eski evicts keys at that label only, with the configured `maxmemory-policy`, and refuses the command with `OOM command not allowed when used memory > 'label-quota'.` if the label is still over. `maxmemory` still applies to the whole server; without quotas for every label in use, global eviction and `OOM` remain a channel between labels.

## What comes next

Later stages carry labels into snapshots and the append-only file, add the search commands and an owner id per command, and ship the SDK helpers.

Timing (including the time to create a key, which probes the dictionaries of hidden labels), memory pressure and eviction without quotas, the tracking table limit, the shared slow log capacity and its entry ids, and connection ids remain observable across labels.

Verify with `python3 -I test/compatibility/labels_subjects.py --server bin/eski` and `python3 -I test/compatibility/labels_keyspace.py --server bin/eski`, each also with `--keyspace-threads 2`, `odin test src/label`, `bash test/run_packages.sh`, `python3 -I proofs/verify.py --project label` and `python3 -I proofs/verify.py --project vector`. The [ACL page](acl.md) describes the rules labels add to and the [command reference](commands.md) lists the `LABEL` and `CONTEXT` forms.

Eski is an independent project, not affiliated with, endorsed or certified by Redis Ltd. Redis is a registered trademark of Redis Ltd.; any rights therein are reserved to Redis Ltd.
