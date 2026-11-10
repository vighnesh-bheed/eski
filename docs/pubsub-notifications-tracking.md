# Pub/sub, notifications and tracking

## Pub/sub

`SUBSCRIBE`/`UNSUBSCRIBE` manage literal channels and `PSUBSCRIBE`/`PUNSUBSCRIBE` manage glob patterns. `PUBLISH` delivers messages to matching connected subscribers. `SSUBSCRIBE`, `SUNSUBSCRIBE` and `SPUBLISH` expose the sharded-channel command names, but delivery remains inside this single node. `PUBSUB` provides channel, subscriber-count and pattern introspection, including the local sharded-channel forms.

In one terminal subscribe, then publish from another:

```sh
redis-cli -p 6399 SUBSCRIBE demo:updates
```

```sh
redis-cli -p 6399 PUBLISH demo:updates hello
```

Pub/sub messages are transient. A disconnected or slow subscriber cannot replay missed messages through this API. Output-buffer limits can disconnect a slow client. Use [streams](streams.md) for retained entries and consumer acknowledgement. RESP2 subscription mode restricts ordinary commands; RESP3 expresses deliveries as push replies and supports a broader command flow on the connection.

## Keyspace notifications

`notify-keyspace-events` selects notification classes and keyspace (`K`) or keyevent (`E`) channel naming. It is empty by default. For a local experiment:

```sh
redis-cli -p 6399 CONFIG SET notify-keyspace-events KEA
redis-cli -p 6399 PSUBSCRIBE '__keyevent@0__:*'
```

Write or expire a key from a different connection. A keyspace channel identifies the key and carries an event name; a keyevent channel identifies the event and carries the key. Notifications use pub/sub's transient delivery and are not a durable audit log. Expiration events occur when expiry is discovered, which can be later than the stored deadline. `CONFIG GET notify-keyspace-events` shows the active selection.

## Client-side cache tracking

`CLIENT TRACKING ON|OFF` enables invalidation tracking. Options include `REDIRECT`, `BCAST`, `PREFIX`, `OPTIN`, `OPTOUT` and `NOLOOP`, subject to combination checks. `CLIENT CACHING YES|NO` marks the next eligible command in opt-in/out mode. `CLIENT TRACKINGINFO` and `CLIENT GETREDIR` inspect the setup. A redirected connection must still be alive and able to receive invalidations; RESP3 clients can receive push invalidations directly.

Tracking observes local key mutations and flushes. It is an invalidation mechanism, not a cached-value stream or a transaction across application caches. On disconnect or a lost invalidation channel, discard or resynchronize cached values before trusting them. Prefix broadcasting can produce traffic independent of which keys a client read.

With a label scheme configured, a message carries the publishing command's label and reaches only subscribers whose session label dominates it, a keyspace notification carries the label of the copy that changed, and tracking invalidations reach only clients whose session label dominates it. A connection that subscribes or turns tracking on without a session keeps its login's label, as if it had sent `LABEL SESSION`. See [Labels](labels.md#what-is-enforced-in-this-release).

Verify with `bash test/run_packages.sh`, `bash test/smoke.sh` and `./test/conformance/run.sh --suite redis --units pubsub,pubsubshard,tracking`. Package checks cover channel registries, notification classes, tracking delivery and socket/output-buffer behaviour. See [connections](connections-and-protocol.md) for client limits and [conformance](conformance.md) for the recorded scope.

Eski is an independent project, not affiliated with, endorsed or certified by Redis Ltd. Redis is a registered trademark of Redis Ltd.; any rights therein are reserved to Redis Ltd.
