# Connections and protocol

Eski listens for IPv4 TCP connections and speaks RESP2 or RESP3. The default RESP port is 6399. Use an explicit bind when starting a local instance:

```sh
./bin/eski --bind 127.0.0.1 --port 6399
redis-cli -p 6399 PING
redis-cli -p 6399 HELLO 3
```

The default configuration has no password and has protected mode off. Configure [ACLs](acl.md) and network access deliberately. The listener implementation does not provide IPv6, TLS or Unix-domain socket transport; configuration names retained for compatibility do not establish those capabilities. An optional IPv6 bind can be skipped, while a required IPv6 bind fails.

## Requests and replies

RESP arrays of bulk strings are the binary-safe command form. The parser also accepts inline requests, preserves incomplete input across reads and enforces protocol limits. Pipelining allows multiple requests in one connection buffer, with execution and ordinary replies in order. A malformed protocol request can close the connection after an error. RESP3 changes reply types and enables push delivery; client libraries must account for pushes instead of assuming every received frame is the next command's reply.

`HELLO 2|3` negotiates the protocol and accepts `AUTH user password` and `SETNAME name`. `AUTH password` authenticates the default user; `AUTH user password` selects a named user. `SELECT` changes the local database. `PING`, `ECHO`, `QUIT` and `RESET` provide basic connection controls; reset clears connection-specific modes and state. Use a persistent connection for transactions, watches, subscriptions and tracking.

## Client controls

`CLIENT ID`, `INFO`, `LIST`, `GETNAME`, `SETNAME` and `SETINFO` expose connection identity and metadata. `CLIENT KILL` closes matching connections; `CLIENT UNBLOCK` ends a blocking operation with timeout or error behaviour. `CLIENT PAUSE timeout [WRITE|ALL]` and `UNPAUSE` control foreground client progress. The recorded expanded suite has pause/expiry and buffer-accounting differences, so refer to [conformance](conformance.md) before depending on exact reference scheduling or memory statistics.

`CLIENT REPLY ON|OFF|SKIP` controls replies. `NO-EVICT` and `NO-TOUCH` control eligible client eviction and key access touches. Tracking/caching options are described in [pub/sub and tracking](pubsub-notifications-tracking.md). `CLIENT HELP` and the generated [command reference](commands.md) list subcommands and accepted arguments.

`maxclients`, `timeout`, `tcp-keepalive`, `client-query-buffer-limit`, `client-output-buffer-limit` and `maxmemory-clients` bound different resources. Input/output buffers and subscription traffic count toward client memory work; a slow consumer can be disconnected. Large pipelines still require buffering and can delay other foreground work.

Verify with `python3 -I test/request_parser/run.py`, `bash test/run_packages.sh`, `bash test/smoke.sh` and `./test/conformance/run.sh --suite redis --units protocol,querybuf,networking,pause,quit`. These checks cover supported protocol behaviour, not transport features that are absent here.
