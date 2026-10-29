# Bitmaps and HyperLogLog

## Bitmaps

Bitmap commands interpret a string as bits, with bit zero at the most significant bit of its first byte. `SETBIT` changes a bit and returns its old value; `GETBIT` reads it. Writing beyond the existing string extends it with zero bytes, which can require a large allocation even for one changed bit. Bitmap values remain strings and can be read or changed with string commands.

`BITCOUNT` counts set bits in an optional range, with `BYTE` or `BIT` addressing. `BITPOS` finds the first requested bit with optional start/end and range units. `BITOP AND|OR|XOR|NOT` stores a result in a destination; `NOT` takes one source. These operations process bytes on the foreground path and should be sized accordingly.

`BITFIELD` reads or writes signed/unsigned fixed-width integers with `GET`, `SET` and `INCRBY`. Offsets are absolute bits, or `#index` to address an integer-sized slot. `OVERFLOW WRAP|SAT|FAIL` controls subsequent increments. `BITFIELD_RO` permits only reads. The parser checks widths, offsets and incompatible forms rather than silently truncating an invalid request.

```sh
redis-cli -p 6399 SETBIT demo:flags 7 1
redis-cli -p 6399 GETBIT demo:flags 7
redis-cli -p 6399 BITCOUNT demo:flags
redis-cli -p 6399 BITFIELD demo:counters SET u8 0 10 INCRBY u8 0 2
redis-cli -p 6399 BITFIELD_RO demo:counters GET u8 0
```

## HyperLogLog

`PFADD` adds observations to a probabilistic cardinality sketch. `PFCOUNT` estimates one sketch or the union of multiple sketches; `PFMERGE` writes a merged sketch. Repeated observations do not increase an exact membership set because no such set is retained. Estimates have statistical error and should not be used where exact counts or per-member retrieval are required.

```sh
redis-cli -p 6399 PFADD demo:visitors Ada Grace Ada
redis-cli -p 6399 PFCOUNT demo:visitors
redis-cli -p 6399 PFMERGE demo:visitors:all demo:visitors
```

HLL values use an encoded string with sparse/dense representations and cached cardinality information. Arbitrary string writes can corrupt that encoding; HLL commands validate the payload and can reject it. `PFDEBUG` and `PFSELFTEST` provide implementation diagnostics rather than application data operations.

Verify with `bash test/bitmap/compare.sh`, `bash test/hll/compare.sh`, `bash test/run_packages.sh` and `./test/conformance/run.sh --suite redis --units bitops,bitfield,hyperloglog`. The [command reference](commands.md) lists accepted forms; the [conformance report](conformance.md) qualifies the tested scope.
