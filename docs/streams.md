# Streams

Streams store ordered entries whose IDs contain a millisecond component and a sequence component. Each entry contains field/value pairs. `XADD` accepts an automatic `*` ID or an explicit valid ID, optional `NOMKSTREAM`, and `MAXLEN`/`MINID` trimming. `XLEN`, `XRANGE` and `XREVRANGE` inspect entries; range endpoints can be inclusive or exclusive. `XDEL` deletes entries and `XTRIM` trims by length or minimum ID. Exact `=` and approximate `~` forms and applicable `LIMIT` values affect trimming work.

```sh
redis-cli -p 6399 XADD demo:events '*' kind signup user Ada
redis-cli -p 6399 XRANGE demo:events - + COUNT 10
redis-cli -p 6399 XREAD COUNT 10 STREAMS demo:events 0-0
```

`XREAD` accepts `COUNT`, `BLOCK milliseconds` and parallel lists of stream names and last-seen IDs after `STREAMS`. Use `$` to begin after the current end when waiting for future entries. Zero block time waits indefinitely. A blocking read is a local wait registration; queued execution in a transaction does not wait for another client to append data.

## Consumer groups

`XGROUP CREATE` creates group state at an ID or `$`, optionally creating an empty stream with `MKSTREAM`. Other group operations include `SETID`, `CREATECONSUMER`, `DELCONSUMER`, `DESTROY` and help. `ENTRIESREAD` can set the group's read counter where supported by the operation. `XREADGROUP GROUP group consumer` supports `COUNT`, `BLOCK`, `NOACK` and `STREAMS`; `>` requests new group deliveries, while an explicit ID reads that consumer's pending history.

```sh
redis-cli -p 6399 XGROUP CREATE demo:events demo:workers 0 MKSTREAM
redis-cli -p 6399 XREADGROUP GROUP demo:workers worker-a COUNT 10 STREAMS demo:events '>'
redis-cli -p 6399 XPENDING demo:events demo:workers
```

After processing a returned ID, use `XACK key group id ...` to remove it from the pending-entry list. `XPENDING` supports summary or ranged output, a consumer filter and `IDLE`. `XCLAIM` transfers pending work with options including `IDLE`, `TIME`, `RETRYCOUNT`, `FORCE`, `JUSTID` and `LASTID`. `XAUTOCLAIM` scans eligible pending work with `COUNT` and optional `JUSTID`. A deleted entry can still require pending-state cleanup; pending membership is not proof that an entry's payload remains present.

`XINFO STREAM`, `GROUPS` and `CONSUMERS` inspect local state; `XSETID` adjusts stream metadata subject to validation. Consumer groups support local acknowledgement bookkeeping. They do not provide replicated durability, an external side-effect transaction or exactly-once processing; an application should tolerate redelivery and choose [persistence](persistence.md) deliberately.

Verify with `bash test/streamtype/compare.sh`, `bash test/run_packages.sh` and `./test/conformance/run.sh --suite redis --units type/stream,type/stream-cgroups`. Consult [commands](commands.md) for the registry and [conformance](conformance.md) for recorded results.
