# Labels

Labels let one Eski node hold data for readers with different clearances. A label is a level, a set of compartments and a trust level. The operator configures the scheme of names, each login gets a clearance, and every command runs at one label that the application asserts for it. This release builds who is asking: the scheme, the logins, the ways a label arrives with a command, contexts, signed levels, transactions and scripts, labelled pub/sub, the server-wide channels, the audit file and the refusal of persistence. Labels on keys and on vector set elements come in the next stage; until then every key is stored as it is today.

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
| Keyspace notifications | published through the same path with the lowest label until keys carry labels |
| `MONITOR`, `LATENCY`, `SWAPDB`, `DEBUG`, `CLIENT PAUSE`, `CLIENT UNPAUSE`, `MEMORY STATS`, `DOCTOR`, `MALLOC-STATS` and `PURGE`, `SLOWLOG RESET`, `CONFIG RESETSTAT` | need a top label, else `ERR this command needs a label that dominates the whole label scheme`; a monitor sees only commands its label dominates |
| `CLIENT LIST`, `CLIENT KILL`, `CLIENT UNBLOCK` | act only on connections whose session label the caller dominates |
| `SLOWLOG GET` and `LEN` | show only entries whose label the caller dominates |
| `INFO` | for callers below top, `connected_clients` counts the connections they dominate, the other numbers of the clients, memory, persistence, stats, replication and CPU sections are zero, and the command, error and latency statistics are empty; the server section is unchanged and the keyspace section follows the next stage |
| `ACL LOG` | stays an administrative command |

The audit file named by `label-audit-file` is opened at startup, append-only with mode 0600, and receives one JSON line per event with the time in milliseconds, the login, the client id and address, the event and its details: `scheme-load` at startup, `scheme-change` with the list before and after, `acl-setuser` with the rules (password rules redacted), `acl-deluser` and `acl-load`. Declassification events will use the same file. Storing and searching audit records belongs to the paid layer.

While a scheme is configured every command runs on the coordinator; the keyspace workers stay idle.

## What comes next

The next stage puts a label on every key of the ordinary types and on every vector set element, so that a hidden key or element behaves exactly like a missing one, a read returns the copy at the reader's label or else the highest copy the reader can see, listings and counts show each name once, writes land exactly at the command's label with `name in use at <marking>` when the writer can see a copy elsewhere, and `WATCH`, blocking operations, keyspace notifications and client tracking are keyed by name and label. It adds `LABEL OF`, relabelling and declassification with their own rights and audit events, the keyspace section of `INFO` and one vector set partition per label. Later stages carry labels into snapshots and the append-only file, add the search commands and an owner id per command, and ship the SDK helpers.

Timing, memory pressure and eviction, the shared slow log capacity and its entry ids, and connection ids remain observable across labels; the owner can bound memory per label with quotas in a later stage.

Verify with `python3 -I test/compatibility/labels_subjects.py --server bin/eski`, the same with `--keyspace-threads 2`, `odin test src/label`, `bash test/run_packages.sh` and `python3 -I proofs/verify.py --project label`. The [ACL page](acl.md) describes the rules labels add to and the [command reference](commands.md) lists the `LABEL` and `CONTEXT` forms.

Eski is an independent project, not affiliated with, endorsed or certified by Redis Ltd. Redis is a registered trademark of Redis Ltd.; any rights therein are reserved to Redis Ltd.
