# Lua scripting

Eski implements EVAL-style scripting with an embedded Lua 5.5.1 C runtime and an Odin command adapter. This is a supported API subset, with language and library differences from the reference server's Lua 5.1 environment. Executable FUNCTION libraries and FCALL remain outside the scope. The Lua runtime retains its MIT terms in [third-party notices](../THIRD_PARTY_NOTICES.md#lua-551); Eski's own code remains Apache-2.0.

## Execute and cache source

| Command | Behavior |
| --- | --- |
| `EVAL source numkeys key ... arg ...` | Execute text source with binary-safe `KEYS` and `ARGV`. |
| `EVALSHA sha1 numkeys key ... arg ...` | Execute cached source; a missing digest returns `NOSCRIPT`. |
| `EVAL_RO` / `EVALSHA_RO` | Execute through the same paths while rejecting write/effect commands. |
| `SCRIPT LOAD source` | Compile without running the body, pin the source in cache and return its SHA1. |
| `SCRIPT EXISTS sha1 ...` | Return ordered integer cache-presence results. |
| `SCRIPT FLUSH [SYNC\|ASYNC]` | Detach all cached source; reclaim immediately or through bounded coordinator cleanup. |
| `SCRIPT KILL` | Request cancellation before a running script has performed a write/effect. |
| `SCRIPT HELP` | Describe implemented subcommands. |

`SCRIPT DEBUG` appears in command metadata but is unsupported; no interactive script debugger is provided.

For example:

```sh
redis-cli -p 6399 EVAL \
  'local n=redis.call("INCR",KEYS[1]); return {n,ARGV[1]}' \
  1 demo:counter hello
redis-cli -p 6399 EVAL_RO 'return redis.call("GET",KEYS[1])' 1 demo:counter
```

`numkeys` must be nonnegative and cannot exceed the remaining arguments. It partitions those arguments into `KEYS` and `ARGV`, with at most 4096 combined key/argument entries per invocation. Each inner `redis.call`/`redis.pcall` also accepts at most 4096 arguments, including its command name. These are Eski admission boundaries. Ordinary EVAL can access undeclared keys, subject to the caller's actual command/key/channel ACL on every inner operation. Declare accessed keys for client portability; this single-node implementation supplies no cluster routing guarantee.

Each invocation creates a fresh VM and recompiles its source. Library-table changes and globals cannot persist into another invocation. New or undefined globals are rejected, so use local variables. Loading binary bytecode is rejected. A `#!lua` header and `#!lua flags=no-writes` are accepted; other languages and flags are rejected. SHA1 includes the original source bytes, including the header, and source line numbers are preserved.

The cache contains source, not persistent compiled programs. Explicit LOAD entries are pinned until flush; sources introduced through EVAL have an LRU limit of 500 entries and share the byte budget. A valid source can remain cached even if execution fails. If pinned entries exhaust the budget, growth fails instead of evicting them. The cache disappears on restart and is absent from RDB/AOF. Handle `NOSCRIPT` by loading or evaluating source again. The default FLUSH mode follows `lazyfree-lazy-user-flush`; asynchronous cleanup does not transfer a Lua VM to a worker.

## Command execution and effects

Scripts run on the coordinator without interleaving ordinary commands from other clients. Keyspace workers reconcile before entry, and supported inner commands, including LCS, execute synchronously. Expiry checks and PTTL use frozen command time throughout execution, including an outer EXEC; TIME still reports wall-clock time. Notifications, watched keys, tracking and blocked consumers observe the actual inner operations; blocked consumers resume after the script completes. Tracking uses the real caller and keys actually read, including undeclared keys.

`redis.call` raises command errors while retaining host error classes such as WRONGTYPE, OOM and ERR. `redis.pcall` returns ordinary command errors as an `err` table so source can handle them; the global Lua `pcall` catches a raised command error as a string. Inner ACL failures use `ERR ACL failure in script`, while ordinary outer permission denials remain NOPERM. An ordinary Lua `error('ERR plain',0)` still receives the outer ERR wrapper, yielding `ERR ERR plain`; it is distinct from a host-origin command error. Exact Lua 5.1 stack/context wording is not reproduced.

Returning or throwing a table with a string `err` field preserves that tagged error text. The helper `redis.error_reply('')` supplies `ERR `, while directly returning `{err=''}` produces an empty error reply. CR/LF bytes are replaced by spaces so they cannot create additional protocol frames. Eski preserves embedded NUL bytes and their suffix in error text; the stock reference truncates this text at NUL. Runtime, memory, output, bridge and cancellation failures terminate the invocation; supplied `pcall`/`xpcall` cannot swallow these terminal failures indefinitely. Earlier successful writes remain applied after an error. There is no rollback.

AOF stores translated command effects rather than EVALSHA or source-cache dependencies. Effects are grouped, including successful writes before a later runtime error; a script inside MULTI joins the surrounding transaction group. Relative expiry is propagated as its absolute deadline. Durability still depends on [AOF synchronization](persistence.md), and resource errors do not undo previous effects.

Inner execution admits selected synchronous data-type commands and harmless inspection such as PING, ECHO, TIME and DBSIZE. It rejects administrative, blocking, reentrant and arbitrary-key handlers, commands with incomplete key specifications, and selected indirect operations. Examples rejected inside scripts include EVAL/SCRIPT/FUNCTION, MULTI/EXEC/WATCH, AUTH/HELLO/CLIENT, CONFIG/ACL/DEBUG, persistence and shutdown commands, SELECT/FLUSH/SWAPDB, MIGRATE, SORT/SORT_RO, KEYS/SCAN/RANDOMKEY, DUMP and HLL debugging. A command working directly does not guarantee it is admitted through `redis.call`.

Read-only variants and the no-writes header reject writes before invoking the handler. PUBLISH, SPUBLISH and PFCOUNT also count as write/effect commands for this policy and cancellation, even when they do not change a stored value. `SCRIPT KILL` returns `NOTBUSY` when idle and `UNKILLABLE` after an effect has occurred.

## Lua API and replies

The environment exposes selected base, string, table and math functions, `KEYS`, `ARGV`, and these helper subsets:

| API | Scope |
| --- | --- |
| `redis` | `call`, `pcall`, `status_reply`, `error_reply`, `sha1hex`, `log` with log constants, and `setresp(2\|3)`. |
| `redis.replicate_commands()` | Returns true; this engine already propagates command effects locally. `set_repl` is unsupported. |
| `cjson` | `encode`, `decode`, `null`; no tuning/new-instance API. Requires valid UTF-8, finite numbers and string object keys. Empty tables encode as objects. |
| `cmsgpack` | `pack`, `unpack` for standard scalars, strings/binary, arrays and maps; no extension types. Concatenated values and empty streams are accepted. Empty tables encode as arrays. |
| `bit` | Signed 32-bit operations, shifts, rotations, byte swap, `tobit` and `tohex`. There is no unsigned Lua 5.2 `bit32` API. |

The environment excludes file/process/network loaders, package/require, io/os/debug, coroutine, collectgarbage, metatable mutation, raw get/set and string.dump. User finalizers cannot be installed. `struct` and the full reference library surface are absent. Lua 5.5 integers, arithmetic/coercion, formatting and iteration can differ from Lua 5.1; test application scripts instead of assuming language equivalence. Object/map order is unspecified.

Unseeded invocations receive fresh default random seeds. An explicit `math.randomseed` gives repeatable sequences within this runtime; sequence values need not match Lua 5.1, and `math.random` is not a cryptographic API. Numeric command arguments such as `2.0` become `2`, and numeric zero of either sign becomes `0` at the command boundary; the Lua math value itself is unchanged. Explicit strings such as `'2.0'` and `'-0.0'` retain their bytes. This lets numeric `2.0` work with INCRBY while the string `'2.0'` remains invalid. Other floating-point precision/formatting differences remain subject to the Lua version boundary.

Strings and nested arrays are binary-safe. Array replies stop at the first nil. Tagged status/error/map/set/double/big-number/verbatim replies follow their RESP forms. The script's `redis.setresp` choice is separate from the connection's HELLO protocol. Default script RESP2 maps false to null and true to integer 1 for either client protocol. With script RESP3, booleans remain booleans for RESP3 clients and become integer 0/1 for RESP2 clients. Lua nil remains null. Non-integral ordinary Lua number replies are truncated to integers; use a tagged double when a floating-point reply is required.

## Resource and cancellation controls

These dynamic Eski controls are inspected by exact name, including uppercase spelling, and remain hidden from wildcard CONFIG discovery:

| Setting | Default | Bound |
| --- | ---: | --- |
| `lua-max-memory` | 64 MiB | VM and runtime conversion allocations; source/KEYS/ARGV payload admission is also bounded. |
| `lua-max-output` | 16 MiB | Serialized script output and captured inner reply size. |
| `lua-max-bridge-memory` | 32 MiB | Host argument/capture ownership across the C boundary. |
| `lua-max-cache-memory` | 32 MiB | Owned cache source/metadata, including retired entries awaiting cleanup. |

All four accept memory-size values and have a minimum of 4096 bytes. A cache limit cannot be reduced below currently owned cache memory. These are requested-allocation limits, not process RSS limits. The decoder/serializer also bounds nesting to 64 and rejects cycles. A reply budget can reject an inner mutation before execution when its possible result cannot fit safely. Memory, output and bridge failures stop later inner calls while retaining earlier successful effects.

Database `maxmemory` has a separate inner-command policy: while over the limit, allocation-requiring commands marked deny-OOM are rejected before the script has performed an effect. A successful effect, such as deleting an existing key, allows later inner writes to complete the effect sequence even if the database remains over that limit. The Lua allocation/output/bridge caps continue to apply. This policy does not make a rejected command succeed or roll back earlier work.

`busy-reply-threshold` defaults to 5000 milliseconds and has the alias `lua-time-limit`. It starts restricted BUSY service; it does not automatically terminate the script. Other clients receive BUSY for ordinary commands. Newly accepted clients can authenticate, and authorized clients can request SCRIPT KILL or exact SHUTDOWN NOSAVE. Client reply suppression still applies. Socket activity uses real time while expiry checks retain frozen command time.

A pending first SIGTERM/SIGINT cancels a script with no effects at a serviced hook, then normal coordinator shutdown runs. After writes, the first signal waits for completion; SCRIPT KILL remains forbidden. Authorized SHUTDOWN NOSAVE immediately exits without normal save/cleanup, and another SIGINT while a shutdown signal is pending forces exit status 1. Both escape paths can lose unflushed changes.

Setting the threshold to zero disables BUSY/KILL service and hook-based signal cancellation. Normal shutdown then waits for script completion; another SIGINT remains a forced escape. Hooks are cooperative: C library work runs between hooks, so neither the threshold nor these budgets provide a preemptive wall-clock deadline.

## Verification

Run `python3 -I test/scripting/run.py --server /path/to/eski` against a prepared executable. `--case 'Class.method*'` selects cases; `--reference-port PORT` runs the portable subset against an explicitly isolated localhost reference and clears its database/cache. The package runner includes the driver once. Native FFI lifecycle, sanitizer, persistence, smoke and conformance gates provide additional boundaries described in [build and test](build-run-test.md#verification).

The runtime passed 51 dedicated scripting cases in release, ASan and TSan builds, 12 native FFI lifecycle tests in debug, ASan and TSan, strict checks for 52 packages and 19 portable cases against stock Redis 7.4.12. An additional diagnostic copy of the native suite invoked LeakSanitizer explicitly after freeing each result: all 212 checks passed. The container executable passed the same 51 scripting cases, and script effects survived three container replacements. The full package gate passed all 94 runs. Both default and enabled-worker configurations passed all 2,428 smoke checks and preserved all 1,504 conformance baseline passes with zero regressions. The expanded 43-unit run retains 16 failures and 151 skips; see [conformance](conformance.md). These are bounded correctness results; no Lua benchmark or full scripting-compatibility claim is made. The earlier threading checkpoint `78eb2f1` remains separate evidence.

Separate exploratory upstream scripting runs are not green. The unmodified unit includes unsupported FUNCTION libraries; an EVAL-only branch selection also exposes API, sandbox, error-message and suite-execution differences. Those runs are not the baseline regression gate or a completed scripting-compatibility gate. The dedicated results validate the documented subset and do not establish Lua 5.1 parity.
