# Memcached text endpoint

An optional second IPv4 TCP listener accepts the memcached text protocol. It is disabled by default (`memcached-port 0`). Enable it at startup with an explicit bind:

```sh
./bin/eski --bind 127.0.0.1 --port 6399 --memcached-port 11211
```

The supported commands are `get`, `gets`, `set`, `add`, `replace`, `append`, `prepend`, `cas`, `delete`, `incr`, `decr`, `touch`, `gat`, `gats`, `flush_all`, `stats`, `version`, `verbosity` and `quit`. Eligible mutations accept `noreply`. The binary protocol and SASL authentication are absent. The text endpoint does not use RESP ACL authentication, so its network reachability must be controlled separately. `shutdown` is deliberately rejected.

Text storage commands specify a key, flags, expiry and exact value byte length followed by CRLF and the payload. `gets` includes a CAS token and `cas` checks it before replacement. Numeric updates accept unsigned decimal values, with protocol-specific increment/decrement behaviour. Expiry follows the text protocol's relative/absolute timestamp rules, and `touch`/`gat`/`gats` update the deadline. `flush_all` accepts an optional delay; it affects the shared database rather than a private text-only store.

With a local server running, this standard-library Python example writes and reads a value on one connection:

```sh
python3 - <<'PY'
import socket
with socket.create_connection(('127.0.0.1', 11211)) as sock:
    stream = sock.makefile('rb')
    sock.sendall(b'set demo:text 0 0 5\r\nhello\r\n')
    print(stream.readline().decode().rstrip())
    sock.sendall(b'get demo:text\r\n')
    print(stream.readline().decode().rstrip())
    print(stream.readline().decode().rstrip())
    print(stream.readline().decode().rstrip())
PY
redis-cli -p 6399 GET demo:text
```

## Shared data and limits

The endpoint shares string values in logical database zero with RESP clients. A RESP collection at the same key is not a text item; cross-protocol replacement/deletion and expiry affect the same keyspace. Memcached flags and CAS metadata follow the text endpoint's rules, so do not assume arbitrary RESP writes preserve an earlier text item's metadata. Persistence covers shared values through the node's normal local persistence path.

`memcached-max-item-size` controls item-size accounting, including the key and item metadata, and defaults to one mebibyte. Both endpoint options are startup-only. Request parsing validates key length, item lengths, numeric fields and CRLF boundaries. Pipeline text commands only with a client that can associate each reply correctly, especially when using `noreply` or CAS errors.

Verify with `bash test/run_packages.sh` and `bash test/smoke.sh`. Smoke compares the text listener with a reference container, exercises cross-protocol string access and checks persistence. `ESKI_SMOKE_MC_PORT` and `ESKI_SMOKE_MC_REF_PORT` select its ports. See [connections](connections-and-protocol.md) for the RESP listener and [persistence](persistence.md) for local durability choices.
