# Owners

Owners add per-user privacy to [labels](labels.md). Every request names the end user it acts for, its owner, and one user's private data never reaches another user. An owner is the application's own user id, such as `u42`, `auth0|5f3c` or a UUID. `SHARED` is data that belongs to no user and that every user's commands can read. A command runs at a scope, a label and an owner, and a reader sees a copy when its label dominates the copy's label and the copy is shared or its own.

This release builds who is asking: the owner mode switch, the ways an owner arrives with a command, the login rules, the refusals, the transaction, watch, script and push bindings, the operator, the server-wide channels and the `OWNERS` command. The keyspace and vector set sides come in the next stage. Until then every key and vector set element is stored as shared data at its label whatever the command's owner, so owner mode does not yet isolate stored data; it isolates messages, introspection, the slow log and connection state as described below.

## Owner mode

```sh
./bin/eski --save '' --appendonly no --memcached-port 0 --owners yes \
  --label-levels 'UNCLASSIFIED,CONFIDENTIAL,SECRET' \
  --user default on nopass '~*' '&*' '+@all' 'clearance:*' owner-operator
```

The hidden setting `owners` is `no` by default and turns owner mode on at startup or with `CONFIG SET owners yes`. Like a label scheme it never turns off: `CONFIG SET owners no` answers `owner mode cannot be turned off`. Owner mode needs persistence and the memcached endpoint off and is refused with the label scheme's own texts otherwise, and while it is on persistence answers `ERR persistence is off while a label scheme is configured`, as in labelled mode. The words `OWNER` and `SHARED` become reserved: owner mode is refused on a scheme with a level of either name (`owner mode needs a label scheme without a level named OWNER or SHARED`), and while it is on no level can be added or renamed to them. Turning it on writes an `owners-on` audit record, and data present at that moment is shared data.

Owner mode works with or without a label scheme. It turns on the protected mode of labels in either case: commands run on the coordinator, persistence and the memcached endpoint stay off, introspection below top is filtered and push features pin their scope. With the default one-level scheme every command's label is top, so top in owner mode also needs the operator scope described below.

The settings `owner-quota-default` (bytes, 0 for none) and `owner-partitions-max` (0, meaning no limit) are hidden like the label settings, readable by exact name and written by `CONFIG REWRITE`. Owner quotas and partitions belong to the keyspace side of the next stage; this release stores the values.

With owners off, Eski answers exactly as without this feature, in both labels-off and labelled mode, apart from the order of the ACL check in labelled mode described in [Labels](labels.md#logins) and two exceptions: the `OWNERS` command exists and answers `ERR owners are not enabled on this server` except for `OWNERS HELP`, and the owner login rules answer `Owners are not enabled on this server` instead of a syntax error. `CONFIG GET owners` and the two other settings also answer by exact name. The words `OWNER` and `SHARED` in `LABEL AS`, the `OWNER` and `SHARED` options of `CONTEXT CREATE` and owner lines in signed tokens fail exactly as before, as an unknown command, a syntax error and a refused token.

## Owner ids

An owner id is 1 to 128 bytes of printable ASCII other than space, compared byte for byte. Inside, Eski interns each id into a 32-bit number in the order of first use, the first command that names it, a read included. A number is never reused while the server runs and never appears in a reply, an error or an audit record; the text does. `OWNERS FORGET` drops an id, and a later use of it starts afresh.

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

The commands that need no owner on an `owners:*` login are `AUTH`, `HELLO`, `PING`, `ECHO`, `SELECT`, `QUIT`, `RESET`, `CLIENT SETNAME`, `CLIENT SETINFO`, `CLIENT ID`, `LABEL WHOAMI`, `LABEL HELP`, `CONTEXT HELP` and `OWNERS HELP`; every other command answers `ERR this login must name an owner with every command` unless it names one or runs inside a transaction whose `MULTI` named one.

| Refusal | Cause |
| --- | --- |
| `ERR invalid owner` | a malformed id, an id the login may not act for, `SHARED` without the right, or a full owner table; one text for all, so a fixed-owner login cannot probe which ids exist |
| `ERR this login must name an owner with every command` | an unprefixed command of an `owners:*` login |
| `ERR the owner differs from the context's owner` | an explicit owner or `SHARED` that disagrees with the context it names |
| `ERR this connection is bound to another owner` | a named owner other than the connection's pinned owner |
| `ERR invalid context` | a context whose owner the login may no longer act for |
| `ERR invalid label token` | a token whose owner the login may not act for, a token without an owner line on an `owners:*` login, or a token whose context has another owner |

The arity and ACL checks of the wrapped command and its keys run first, with `NOPERM` and the `ACL LOG` record, then the label refusals of top-only commands and persistence and then these owner refusals. The refusals that decide which command runs and at which label come before them, as in labels: the errors of the `LABEL AS` prefix itself, the refusals of `label-per-command` and `require-token` logins, a transaction at another label, an invalid label and a subscription that needs a session (see [Labels](labels.md#logins)). A command that does not exist answers the unknown-command error whatever its owner.

## Contexts and signed tokens

`CONTEXT CREATE [LEVEL <marking>] [TRUST <trust>] [OWNER <id> | SHARED]` fixes a label and an owner. The owner defaults to the creating command's owner and must be one the login may act for, else `ERR invalid owner`. `CONTEXT INFO` also returns the `owner` (the id, or nil for `SHARED`) in owner mode. An agent that holds a handle cannot change its owner, and the contexts of a forgotten owner are dropped.

A signed statement may carry one line `owner <id>` or one line `shared`. On an `owners:*` login exactly one of them is required; on other logins a token without one runs at the login's own owner. The token's owner must be one the login may act for, and when the token names a context the context must have the same owner. Servers without owner mode refuse such tokens, because they refuse unknown lines.

## Transactions and scripts

`MULTI` binds the label and the owner. A queued command that names another owner is refused when it is queued with `ERR the command's label differs from the transaction's label`, and `EXEC` must carry the same owner or none. `WATCH` records its scope: when any key was watched at a scope other than the transaction's label and owner, `EXEC` runs nothing and answers `EXECABORT Transaction discarded because of: the command's label differs from the transaction's label`, whatever the data. The texts are the label ones in this release.

Scripts and functions run for the caller's owner, and `LABEL WHOAMI` inside them shows it. `LABEL AS` stays refused inside scripts, and `OWNERS` is not allowed from scripts. While a script is busy, `SCRIPT KILL`, `FUNCTION KILL` and the running script in `FUNCTION STATS` need a label that dominates the script's label and, on top of that, the script's own owner or the operator scope. Seeing the script's owner is not enough: `SHARED` sits below every user, yet a user may not act on a script that runs as `SHARED`, nor on one that runs for another user; for such a caller `FUNCTION STATS` shows no running script and the kill commands answer `ERR this command needs a label that dominates the running script's label`.

## The push pin

`SUBSCRIBE`, `PSUBSCRIBE`, `SSUBSCRIBE` and `CLIENT TRACKING ON` fix the connection's owner together with its label. A login without an owner rule pins at `SHARED`, an `owner:<id>` login at its id, and an `owners:*` login must name the owner on that command with the owner-only prefix, as in `LABEL AS OWNER u42 SUBSCRIBE ch`; a marking in the prefix stays refused as labels refuse it without a session. An `owners:*` operator that names no owner pins at every owner. The pin is set only after the command passes the arity and `ACL` checks and the label and owner refusals, so a push command refused with `NOPERM`, or with an owner refusal such as `ERR this login must name an owner with every command`, pins neither the session nor the owner. After pinning the connection receives only messages whose scope its pin dominates, and every later command on it that names another owner is refused with `ERR this connection is bound to another owner`, so a client-side cache never mixes two users. `RESET` and `AUTH` to another login clear the pin; a connection that still holds subscriptions or tracking is then pinned at the new login's owner, or closed when the new login must name owners. `LABEL WHOAMI` shows the pin in `pinned-owner`: nil, `SHARED`, `OWNER <id>` or `EVERY`.

## The operator and top

Top in owner mode means two things at once: the command's label dominates the scheme's top label, and the login carries `owner-operator`. The top-only commands of labels (`MONITOR`, `LATENCY`, `SWAPDB`, `DEBUG`, `CLIENT PAUSE` and `UNPAUSE`, `MEMORY STATS`, `DOCTOR`, `MALLOC-STATS` and `PURGE`, `SLOWLOG RESET`, `CONFIG RESETSTAT`, `LABEL COPIES` and `LABEL QUOTA`), the full `INFO` numbers and the `OWNERS` subcommands other than `HELP` need it, else `ERR this command needs a label that dominates the whole label scheme`. For the filtered introspection below, the operator sees every owner at the labels it dominates.

## Server-wide channels

| Channel | Rule in owner mode |
| --- | --- |
| Pub/sub | a message carries the publishing command's scope and reaches only connections whose pin dominates it; `PUBLISH` and `SPUBLISH` count the receivers at exactly the publisher's scope; `PUBSUB CHANNELS`, `NUMSUB`, `NUMPAT`, `SHARDCHANNELS` and `SHARDNUMSUB` count only the subscribers the caller dominates |
| Keyspace notifications | carry the changed copy's label and, in this release, the shared owner, so they reach every pin at a dominating label |
| `MONITOR` | top in owner mode, so operator only, and sees every command |
| `CLIENT LIST`, `CLIENT KILL`, `CLIENT UNBLOCK` | a connection's scope is its pin; for a login without an owner rule it is `SHARED`, for an unpinned `owner:<id>` connection its id, and for an unpinned `owners:*` connection, which serves many users in turn, every owner, which only the operator sees; a connection always sees itself |
| `SLOWLOG GET` and `LEN` | an entry carries its command's scope and shows to the callers that dominate it; ids and the capacity stay shared |
| `INFO` | below top as in labelled mode; the operator also gets an `# Owners` section with `owners_known`, `owners_holding_data`, `owner_partitions` and `owner_bytes` |
| Scripts and functions | run at the caller's scope; the script cache and function libraries are application code and `SCRIPT EXISTS` and `FUNCTION LIST` stay global |
| `ACL LOG` | stays an administrative command |

## The OWNERS command

| Command | Rule |
| --- | --- |
| `OWNERS FORGET <id>` | closes every connection pinned to the owner, bound to it by `MULTI` or `WATCH`, or blocked as that owner, drops its contexts, its cached tokens and its slow log entries, drops its id and writes an `owner-forget` audit record with the counts; replies with a map of the `keys`, `elements` and `bytes` removed, which the keyspace side of the next stage fills in |
| `OWNERS INFO <id>` | the owner's `keys`, `elements`, `bytes`, `partitions`, `labels` and `quota`, counts only |
| `OWNERS LIST <cursor> [COUNT <count>]` | a cursor over the ids of the owners that hold data, in order of first use |
| `OWNERS QUOTA <id> [LIMIT <bytes>]` | shows the owner's quota and used bytes, or sets the quota (0 falls back to `owner-quota-default`) and writes an `owner-quota` audit record |
| `OWNERS HELP` | the subcommands |

`FORGET`, `INFO`, `LIST` and `QUOTA` are the subcommands `owners|forget`, `owners|info`, `owners|list` and `owners|quota`, in the `@admin` and `@dangerous` categories only, and need the operator at top. Shared data written on a user's behalf is not that user's data and is not forgotten.

## Audit

The audit file of labels receives `owners-on` when owner mode turns on, `owner-forget` with the id and the counts, `owner-quota` with the id and the limit, and the ACL changes to owner rules through `acl-setuser`. Records never carry values.

## What this release does not do

The keyspace and vector set sides of owners, with owner partitions, resolution with the own-before-shared tie, writes at the command's owner, owner quotas, per-scope random streams and the keyspace half of `OWNERS FORGET`, `INFO` and `LIST`, come in the next stage, together with the owner scope of watches, blocking and tracking on the keyspace side. Until then `FLUSHDB` and `FLUSHALL` delete every label only at operator top. Owners in snapshots and the append-only file come with persistence for labels.

Verify with `python3 -I test/compatibility/owners_subjects.py --server bin/eski`, also with `--keyspace-threads 2`, `odin test src/owner` and `python3 -I proofs/verify.py --project label`. The [command reference](commands.md) lists the `OWNERS` subcommands.

Eski is an independent project, not affiliated with, endorsed or certified by Redis Ltd. Redis is a registered trademark of Redis Ltd.; any rights therein are reserved to Redis Ltd.
