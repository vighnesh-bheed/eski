# Lua scripts and Functions

Eski embeds Lua 5.1.5 with permissively licensed libraries from the pinned Valkey Lua distribution. EVAL scripts, executable Function libraries and interactive debugging run on the coordinator. The Odin host supplies command dispatch, ACL, persistence and connection handling through a protected C ABI; all allocation-capable Lua API calls and error unwinding stay in C. Eski remains Apache-2.0, with component terms in [third-party notices](../THIRD_PARTY_NOTICES.md#lua515).

The commands below are implemented and covered by native, whole-node and managed upstream checks. The [verification record](build-run-test.md#verification) separates those results from the external-server conformance snapshot and documents the remaining resource limit.

## Evaluate and cache scripts

| Command | Behavior |
| --- | --- |
| `EVAL source numkeys key ... arg ...` | Execute text with binary-safe `KEYS` and `ARGV`. |
| `EVALSHA sha1 numkeys key ... arg ...` | Execute cached source; a missing digest returns `NOSCRIPT`. |
| `EVAL_RO` / `EVALSHA_RO` | Execute while rejecting write/effect commands. |
| `SCRIPT LOAD source` | Compile without running the body, pin the source and return its SHA1. |
| `SCRIPT EXISTS sha1 ...` | Return ordered integer cache-presence results. |
| `SCRIPT FLUSH [SYNC\|ASYNC]` | Detach cached scripts and reset the EVAL engine. |
| `SCRIPT KILL` | Request cancellation before the script becomes unkillable through writes/effects. |
| `SCRIPT DEBUG YES\|SYNC\|NO` | Select forked, synchronous or disabled interactive debugging for subsequent EVAL. |

```sh
redis-cli -p 6399 EVAL \
  'local n=redis.call("INCR",KEYS[1]); return {n,ARGV[1]}' \
  1 demo:counter hello
redis-cli -p 6399 EVAL_RO 'return redis.call("GET",KEYS[1])' 1 demo:counter
```

`numkeys` partitions the remaining arguments into `KEYS` and `ARGV`. Each actual inner operation uses the caller's command/key/channel ACL, including undeclared keys. Declare keys for client portability; this engine provides no cluster routing.

EVAL retains one VM between calls. A source is compiled once, into that VM, when EVAL or SCRIPT LOAD first adds it to the cache; later EVAL and EVALSHA calls of the same digest run the stored function with fresh `KEYS`, `ARGV` and global environment, and its memory is reported as EVAL VM memory until eviction or SCRIPT FLUSH releases it. Builtin tables and globals are read-only, while user-owned tables support ordinary Lua metatables and raw access. Library configuration, such as cjson precision, persists until SCRIPT FLUSH; it is separate from the Functions engine. The source cache owns original bytes and SHA1 metadata. Sources first cached by SCRIPT LOAD remain pinned until flush. Sources first cached by EVAL stay in a 500-entry LRU and share the configured byte budget; a later SCRIPT LOAD of the same source neither pins nor refreshes them, SCRIPT EXISTS does not refresh them, and EVAL or EVALSHA moves them to the newest position. Script source/cache state is absent from RDB/AOF and disappears on restart, so applications must handle NOSCRIPT.

Text loaders and `string.dump` are available, but loading binary bytecode is rejected. Headers accept `#!lua` and the flags `no-writes`, `allow-oom`, `allow-stale`, `no-cluster` and `allow-cross-slot-keys`. A header must end with a line feed; header errors quote the offending engine, option or flag. Single-node support for a flag does not provide replication or cluster services. SHA1 includes the original header and source bytes.

## Executable Function libraries

FUNCTION LOAD stages a library atomically; REPLACE replaces its previous definition only after successful validation. Libraries register named callbacks with `redis.register_function`, using either positional arguments or a table containing `function_name`, `callback`, optional `description` and `flags`. Table keys and flag names are matched without regard to case, and a numeric name or description is accepted as its text. Registration and load-time errors are reported after `Error registering functions:`, and a library body that runs for 500 milliseconds fails with a load timeout regardless of `busy-reply-threshold`. Metadata in the `#!lua name=...` line is checked before the engine name, and the line must end with a line feed. While loading, the `redis` table offers registration, logging, the log level constants and the version fields.

```sh
redis-cli -p 6399 FUNCTION LOAD '#!lua name=demo
redis.register_function("greeting", function(keys, args)
  return "hello " .. args[1]
end)'
redis-cli -p 6399 FCALL greeting 0 world
redis-cli -p 6399 FUNCTION LIST WITHCODE
```

FCALL and FCALL_RO look up the function before validating the key count, partition keys/arguments like EVAL and pass them to the callback. FCALL_RO requires a function registered with `no-writes`; ordinary FCALL applies the function's declared policy. Function names are case-insensitive; library names retain their own identity and spelling. Two names in one library that differ only in case are rejected. LIST supports library-pattern filtering and WITHCODE. DELETE, FLUSH, STATS, KILL, DUMP and RESTORE provide library lifecycle and control.

All libraries share one persistent Functions VM. Their closures and upvalues survive calls, and cjson module configuration is shared between libraries. EVAL has a separate module configuration. Deleting a library releases its callbacks; FUNCTION FLUSH resets the Functions engine. RDB and AOF persist library definitions, which rebuild their closure state from source on restart. Store durable application state in keys. DUMP/RESTORE preserve library definitions with the selected APPEND, REPLACE or FLUSH policy; RESTORE checks each payload library for duplicate library and function names in payload order before comparing it with the loaded libraries. FUNCTION FLUSH ASYNC defers the release only when more than 64 functions are loaded.

## Commands, atomicity and replies

Workers reconcile before a script or Function begins. Inner commands execute synchronously and ordinary commands from other clients do not interleave with the invocation. Supported blocking data commands return without waiting. Commands marked NOSCRIPT are rejected; SELECT affects the invocation's database without changing the caller's selected database. Expiry and TIME use cached command time during execution. Notifications, WATCH, tracking and blocked consumers observe the completed operation sequence.

`redis.call` raises an ordinary command error; `redis.pcall` returns its error table for source-level handling. The Lua `pcall` and `xpcall` functions catch ordinary Lua errors. Host memory/output/bridge failures and requested cancellation remain terminal. Successful writes survive a later error: an invocation is atomic with respect to other clients, but it does not roll back earlier effects.

AOF records translated command effects rather than source-cache dependencies, including successful writes before a later error. Relative expiry becomes an absolute deadline. A script or Function inside MULTI joins the enclosing AOF group. `redis.set_repl` can select local AOF propagation through its standard mask constants; replica mask constants do not create a replication service. See [persistence](persistence.md).

Strings and arrays are binary-safe; ordinary array replies stop at the first nil. Status/error tables and RESP3 map/set/double/big-number/verbatim forms preserve their protocol meaning. The script's `redis.setresp(2|3)` is independent of the client's HELLO protocol. Ordinary Lua numeric replies become integers; use a tagged double for a floating-point reply. Numeric command arguments and tagged double replies are written in integer form for integral values whose magnitude is at most 2^62 and otherwise in the shortest text that reads back as the same double, with exponent notation outside the plain range. Explicit strings retain their bytes. Error/status lines truncate at NUL and replace CR/LF with spaces, preserving following protocol frames; returned error tables and `redis.error_reply` first drop trailing CR/LF. A `verbatim_string` table needs string `format` and `string` fields; the format is cut or space-padded to three bytes, and a table without both fields is sent as an ordinary array.

## Libraries and environment

The environment provides the Lua 5.1 base, string, table, math and coroutine APIs, garbage-collection controls, user-table metatables/raw access, text loaders and `os.clock`. Helper modules include full cjson configuration and `cjson.new`, cmsgpack, struct and BitOp. The Redis helper table supplies command calls, replies, logging, SHA1, protocol selection, ACL checks, propagation controls and version/constants.

Filesystem/process/package APIs such as io, require, package, loadfile and dofile are unavailable. The standard debug library is unavailable. The immutable startup option `lua-enable-deprecated-api yes` enables legacy getfenv, setfenv and newproxy behavior for applications that require those APIs; its default is no.

The math.random stream is shared by EVAL and Functions on the coordinator. Without math.randomseed it starts from the standard drand48 initial state when the server starts, so every fresh server produces the same sequence. Explicit math.randomseed affects that stream, which survives SCRIPT/FUNCTION FLUSH. It is not a cryptographic random API. Object/map iteration order remains unspecified.

## Debugging and cancellation

SCRIPT DEBUG YES forks an isolated debugging child; writes made in that child are discarded. SYNC executes in the server and retains writes. The interactive protocol supports stepping, source listing, breakpoints, tracing, printing locals/upvalues, evaluating expressions and issuing Redis commands. Debugger EVAL uses its own evaluation frame, so a local visible through PRINT is not automatically a global available to EVAL. A completed session sends its end marker, ordinary invocation result and connection close. A request with more than 1,024 arguments ends the session with a protocol error. MAXLEN values from 1 to 60 become 60 and zero means unlimited. SCRIPT DEBUG inside MULTI fails when EXEC runs it.

`busy-reply-threshold`, also named `lua-time-limit`, defaults to 5,000 milliseconds. It enables restricted BUSY service rather than automatically terminating the invocation. During that service unknown commands and wrong argument counts still receive their ordinary errors, and commands marked allow-busy (AUTH, HELLO, MULTI, DISCARD, WATCH, UNWATCH, QUIT, RESET, SCRIPT KILL, FUNCTION KILL, FUNCTION STATS and SHUTDOWN) are served; MULTI queues them. Other commands, FUNCTION STATS during an EVAL script and SHUTDOWN without NOSAVE receive BUSY naming the kill command for the running kind. Either KILL reports UNKILLABLE after writes/effects; otherwise the wrong one reports BUSY. The killed client receives the kill error with the script name and line. SHUTDOWN NOSAVE runs the ordinary shutdown sequence without saving. Read-only script cancellation and client activity handling preserve the invocation's frozen expiry time.

SIGTERM/SIGINT requests normal shutdown after permitted cancellation/completion. A repeated SIGINT forces exit status 1. SHUTDOWN NOSAVE and forced interruption can discard unflushed changes. Hooks are cooperative: C library work runs between hooks, so the threshold is not a preemptive wall-clock deadline.

## Optional resource controls

These dynamic Eski settings are available by exact name and hidden from wildcard CONFIG discovery:

| Setting | Default | Bound |
| --- | ---: | --- |
| `lua-max-memory` | Host signed-integer maximum | VM and runtime conversion allocations. |
| `lua-max-output` | 512 MiB | Serialized output and captured inner reply size. |
| `lua-max-bridge-memory` | Host signed-integer maximum | Host argument/capture ownership. |
| `lua-max-cache-memory` | Host signed-integer maximum | Owned cache source/metadata, including retired entries. |

The host maximum is 2^63−1 bytes on the supported 64-bit target. Explicit controls accept memory-size values with a 4,096-byte minimum. A cache limit cannot be reduced below its current ownership. These requested-allocation bounds are separate from process RSS and database maxmemory. Allocation, output or bridge failure stops later commands while preserving prior successful effects.

## Verification

Run the following against a prepared executable; none starts a performance benchmark:

```sh
python3 -I test/scripting/run.py --server /path/to/eski
python3 -I test/functions/run.py --server /path/to/eski
python3 -I test/scripting/debugger.py --server /path/to/eski
python3 -I test/compatibility/lua_edges.py --server /path/to/eski
ESKI_TEST_BIN=/path/to/eski bash test/run_packages.sh
```

Portable reference cases require an explicitly disposable reference instance; those drivers clear its data and library/cache state. Native ABI, address/thread sanitizer and explicit leak checks cover protected allocation, error conversion, codecs, persistent engines and debugging. Managed upstream scripting/Functions tests add process, configuration and lifecycle coverage. See the [verification record](build-run-test.md#verification) for counts, fixture modes and exclusions.

The two original upstream JSON string-encoding cases over 2 GB, one for each engine, remain unqualified: an isolated 14 GiB memory limit ended in a kernel OOM kill on the qualification machine. Four separate upstream large escape-sequence/newline cases passed; they do not establish the JSON cases. Run those JSON cases on a machine with sufficient available memory before claiming that boundary. Expanded worker/Lua performance benchmarking is deferred.
