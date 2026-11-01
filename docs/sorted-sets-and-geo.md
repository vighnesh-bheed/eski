# Sorted sets and geo

Sorted sets associate each unique binary-safe member with a numeric score. `ZADD` supports `NX`, `XX`, `GT`, `LT`, `CH` and `INCR` with the applicable combination checks. `ZINCRBY` updates a score. `ZREM`, `ZCARD`, `ZSCORE`, `ZMSCORE`, `ZRANK` and `ZREVRANK` remove or inspect members; rank commands can include `WITHSCORE`. Equal-score members use lexical member ordering.

`ZRANGE` selects ranks, scores (`BYSCORE`) or lexical bounds (`BYLEX`) and accepts `REV`, applicable `LIMIT` options and `WITHSCORES`. Rank endpoints are inclusive and support negative offsets. Score bounds can be inclusive or exclusive and accept infinities. Lexical ranges are useful when members have the same score. `ZRANGESTORE` writes a range to a destination. Compatibility forms include `ZREVRANGE`, `ZRANGEBYSCORE`, `ZREVRANGEBYSCORE`, `ZRANGEBYLEX` and `ZREVRANGEBYLEX`.

`ZCOUNT` and `ZLEXCOUNT` count a range; `ZREMRANGEBYRANK`, `ZREMRANGEBYSCORE` and `ZREMRANGEBYLEX` remove it. `ZUNION`, `ZINTER` and `ZDIFF`, plus their `...STORE` forms, perform algebra. Union/intersection accept `WEIGHTS` and `AGGREGATE SUM|MIN|MAX`; `ZINTERCARD` accepts `LIMIT`. `ZRANDMEMBER` optionally includes scores and supports repeated sampling with a negative count. `ZSCAN` supports `MATCH` and `COUNT` with the usual non-snapshot cursor semantics.

```sh
redis-cli -p 6399 ZADD demo:scores 10 Ada 20 Grace 20 Katherine
redis-cli -p 6399 ZRANGE demo:scores 0 -1 WITHSCORES
redis-cli -p 6399 ZRANGE demo:scores 10 20 BYSCORE LIMIT 0 2 WITHSCORES
redis-cli -p 6399 ZPOPMAX demo:scores 1
```

`ZPOPMIN`, `ZPOPMAX` and `ZMPOP` remove extreme members. `BZPOPMIN`, `BZPOPMAX` and `BZMPOP` wait for data, with fractional-second timeouts and zero for an indefinite wait. Queued transaction execution does not block for a future write.

## Geospatial operations

Geo coordinates are encoded in sorted-set scores. `GEOADD` accepts longitude/latitude/member triples with `NX`, `XX` and `CH`. `GEOPOS`, `GEOHASH` and `GEODIST` inspect coordinates or distance. Coordinates must be in the supported longitude/latitude range; distance calculations use the implementation's spherical-earth model rather than a surveying guarantee.

`GEOSEARCH` chooses `FROMMEMBER` or `FROMLONLAT`, then `BYRADIUS` or `BYBOX`. Units are `m`, `km`, `ft` and `mi`; `ASC`, `DESC`, `COUNT`/`ANY`, `WITHCOORD`, `WITHDIST` and `WITHHASH` control results. `GEOSEARCHSTORE` writes a result, optionally with `STOREDIST`. Legacy `GEORADIUS`/`GEORADIUSBYMEMBER` and their `_RO` forms are also registered; read-only forms cannot store results.

```sh
redis-cli -p 6399 GEOADD demo:places 13.4050 52.5200 Berlin 13.0645 52.3906 Potsdam
redis-cli -p 6399 GEOSEARCH demo:places FROMMEMBER Berlin BYRADIUS 50 km WITHDIST ASC
```

Verify with `bash test/zsettype/compare.sh`, `bash test/geo/compare.sh`, `bash test/run_packages.sh` and `./test/conformance/run.sh --suite redis --units type/zset,geo`. See the [command reference](commands.md) for complete option metadata and [conformance](conformance.md) for measured coverage.
