# Search over hashes and JSON

Eski indexes database 0 hashes and [JSON documents](json.md) by key prefix. Use `FT.CREATE` to define an index over either storage type. Writes, replacement, expiry and deletion update the index as part of the key lifecycle. Creating an index normally scans matching existing keys before the command returns. `SKIPINITIALSCAN` starts with later writes.

Search is built into the server. `MODULE LIST` advertises `search` version 81001 and `ReJSON` version 81000 for clients that check for them. Eski has no loadable module interface.

## Create and query an index

The following commands use shell quoting with `redis-cli` against a local Eski instance. Both examples can run on the same instance.

```sh
redis-cli -p 6399 FT.CREATE article ON HASH PREFIX 1 article: SCHEMA \
  title TEXT topic TAG year NUMERIC SORTABLE
redis-cli -p 6399 HSET article:1 title 'Memory stores' topic systems year 2026
redis-cli -p 6399 FT.SEARCH article '@title:memory @topic:{systems} @year:[2025 +inf]' \
  RETURN 2 title year SORTBY year DESC DIALECT 2

redis-cli -p 6399 FT.CREATE note ON JSON PREFIX 1 note: SCHEMA \
  '$.body.title' AS title TEXT '$.body.topic' AS topic TAG \
  '$.body.embedding' AS embedding VECTOR FLAT 6 TYPE FLOAT32 DIM 3 DISTANCE_METRIC COSINE
redis-cli -p 6399 JSON.SET note:1 '$' \
  '{"body":{"title":"Memory stores","topic":"systems","embedding":[1,0,0]}}'
redis-cli -p 6399 FT.SEARCH note '@topic:{systems}' RETURN 2 title '$.body' DIALECT 2
```

Use a binary-safe client to pass a vector query parameter. This example uses redis-py with its default binary replies.

```python
import struct
from redis import Redis

client = Redis(host="127.0.0.1", port=6399, protocol=3)
vector = struct.pack("<3f", 1, 0, 0)
page = client.execute_command(
    "FT.SEARCH", "note", "(@topic:{systems})=>[KNN 3 @embedding $v AS distance]",
    "PARAMS", 2, "v", vector, "SORTBY", "distance", "RETURN", 2, "title", "distance",
    "DIALECT", 2,
)
```

With `ON HASH`, store each vector in a hash field as a binary buffer matching the schema's type and dimension. With `ON JSON`, store it as a numeric array at the indexed path. JSON paths can also select several vectors for a document. A vector query returns a document once at its best matching distance. Vector query parameters remain binary in both storage modes. Use dialect 2 or later for the vector clauses. The server's default search dialect is 1. Distances sort from nearest to farthest.

A JSON schema can map a path to a field alias using `AS`. Query indexed fields by alias and project an alias or a JSONPath with `RETURN` or `LOAD`. Search without `RETURN` projects the document under `$`. Up through dialect 2, a projection returns the first match. Dialects 3 and 4 wrap all matches, and RESP3 with `FORMAT EXPAND` returns native values instead of JSON text. A missing path is omitted from a projection. A matching JSON null is kept. Sorts use the first value. JSON TAG fields without an explicit separator treat each string as a single tag. HASH TAG fields default to comma separation.

## Command and execution boundaries

| Task | Commands and options |
| --- | --- |
| Define and inspect | `FT.CREATE`, `FT.ALTER`, `FT.INFO`, `FT._LIST`, `FT.DROPINDEX`, `FT.ALIASADD`, `FT.ALIASUPDATE`, `FT.ALIASDEL` |
| Retrieve | `FT.SEARCH` combines TEXT, TAG, NUMERIC, GEO and VECTOR clauses. Text supports terms, phrases, prefix, suffix, infix and fuzzy matches, with highlighting and excerpts for supported projections. Vector queries support FLAT and HNSW, cosine, L2 and inner product, filtered KNN and range. |
| Aggregate and fuse | `FT.AGGREGATE` supports projections, score yields, expressions, filtering, grouping, reducers, sorting, paging and cursors. `FT.HYBRID` fuses text and vector branches with RRF or LINEAR. |
| Diagnose and tune | `FT.EXPLAIN`, `FT.EXPLAINCLI`, `FT.PROFILE`, `FT.TAGVALS`, `FT.CURSOR READ`, `DEL`, `GC` and `FT.CONFIG GET`, `HELP`, `SET` |

The [command inventory](commands.md#module) gives the wire syntax. The available scorers include BM25STD, BM25, normalized and tanh BM25STD, TFIDF, TFIDF.DOCNORM, DISMAX, DOCSCORE and HAMMING. Text analysis supplies English stemming. Approximate term expansion can pick a different score contribution when a document matches several expansions. Excerpts can use different boundaries from Redis. Profile reports Eski's own execution steps, iterator tree and measurements. See `FT.CONFIG HELP *` for the tuning names Eski exposes. Search tuning is read and changed with `FT.CONFIG` only: `CONFIG GET` and `CONFIG SET` do not know the `search-*` parameter names, and `CONFIG GET search-*` returns an empty list.

With DIALECT 4 and without `WITHCOUNT`, the reported total is at most the `LIMIT` count. A DIALECT 4 query with no text term and no `SORTBY` returns documents in index order, and with `NOCONTENT` it reports a total of 1. `FT.HYBRID` parses its text query and its vector `FILTER` with dialect 2 whatever the default dialect. With `NOSORT` and no `LIMIT` it returns every fused row in an unspecified order. A `LIMIT` sorts by fused score even with `NOSORT`. In `FT.AGGREGATE`, `SORTBY` without `MAX` keeps 10 rows unless the pipeline has a `LIMIT`. The leading count of an aggregate reply follows the Redis count of each observed pipeline shape and is not always a count of all matches. Expression functions apply Eski's own type rules to numeric and null arguments, so some calls that Redis refuses return a value or a different error.

Equal scores are ordered by internal document id. Documents found by the initial scan of `FT.CREATE` get their ids in keyspace order, which neither engine fixes. Ties can therefore resolve differently from Redis and between two instances, including which documents an `FT.HYBRID` window keeps and therefore its fused rows and total. Scores right after documents are rewritten or deleted can also differ. Redis keeps counting the replaced copies in its collection statistics until its garbage collector runs, while Eski counts live documents only.

In `FT.INFO`, the memory figures, `bytes_per_record_avg` and `offset_bits_per_record_avg` describe Eski's own accounting. `num_records`, `num_terms`, `max_doc_id` and `records_per_doc_avg` count live records. Redis also counts records it has not yet collected, and its `gc_stats` follow its own collector, so these figures differ after updates and deletions. `dialect_stats` shows 1 for each dialect a query has used on the index since it was created or loaded. The search entries of `COMMAND DOCS` follow the Redis layout. Those of `FT.AGGREGATE`, `FT.HYBRID` and the diagnostic, alias, cursor and configuration commands carry Eski's own shorter summaries and argument descriptions.

Indexes cover database 0 only. References to corresponding keys in other logical databases do not participate. Unsupported Redis Search features include SVS-VAMANA, phonetic matching, index-creation filters and temporary indexes, `GEOSHAPE` fields, spellcheck, suggestion dictionaries and synonym commands. `FT.CREATE` refuses `NOOFFSETS`, `NOHL`, `NOFIELDS` and `NOFREQS`. The deprecated `FT.DROP` and the internal `FT._DROPINDEXIFX`, `FT._CREATEIFNX` and `_FT.DEBUG` are not implemented. Use `FT.DROPINDEX`, with `DD` to delete the documents. `EF_RUNTIME` and `EPSILON` apply to HNSW and are rejected where used on FLAT. Queries run on the coordinator, including when keyspace or compute workers are enabled. A deadline is checked cooperatively and the command returns a timeout error without a partial page.

With [labels](labels.md#search-indexes) or [owners](owners.md#search-indexes) enabled, the definition and each document have their own scope. A document contributes to definitions its write scope can see. Queries check read permission for every index prefix and rank the visible document copies. A shadowed copy cannot contribute a hit. Search counts and ranking statistics come from visible partitions. Below operator scope, activity-sensitive counters and timings are suppressed. Scoped rank ties among retained candidates use key name. FLAT considers all eligible local ties. HNSW can discard an equal-distance candidate at a partition's local cutoff before the key-name merge. Index creation scans synchronously, so the duration can vary with the scanned data.

Cursors hold materialized values, belong to the opening ACL user and scope, and recheck access when read. Expiry, removal or shadowing of source documents can invalidate a scoped cursor. Active cursors and query activity reset across restart. Definitions and aliases persist, and Eski rebuilds derived index contents from the loaded keys. This can make data skipped by `FT.ALTER ... SKIPINITIALSCAN` searchable after a snapshot reload or AOF rewrite. [Persistence](persistence.md#search-definitions-and-json-values)

## Python clients

Use a localhost `redis://` URL and database 0. The checks use local deterministic embeddings. The table describes the pinned versions exercised by the fixture.

| Client | Exercise and client limits |
| --- | --- |
| redisvl 0.31.0 with redis-py 8.1.0 | `SearchIndex` works with HASH and JSON in RESP2 and RESP3. Configure JSON with `storage_type="json"` and path aliases. The fixture exercises filtered KNN, ranges, text, aggregate/hybrid queries, pagination, cache, message histories and routing. |
| langchain-redis 0.2.6 with langchain-core 1.7.6 and redis-py 8.1.0 | `RedisVectorStore` works with HASH and JSON in RESP2 and RESP3. Pass `storage_type="json"` for JSON, including when attaching to an existing index if you use storage-dependent operations such as `get_by_ids` or MMR. `similarity_search_with_score` returns a distance. Its relevance-score API and score-threshold retriever raise `NotImplementedError`. Use `distance_threshold` for range search. |
| llama-index-vector-stores-redis 0.9.0 with llama-index-core 0.14.25, redisvl 0.4.1 and redis-py 5.3.1 | Use HASH with RESP2. With a forced RESP3 connection, the pinned redisvl 0.4.1 adapter expects a RESP2 result object and raises `AttributeError`. A JSON definition can be created, but the store generates a binary vector that fails JSON serialization before sending a document write. The store's `clear()` and legacy non-equality filters are client limitations. |

With redis-py 8.1.0 and redisvl 0.31.0, leave the protocol at its default for RESP3 on the wire with compatible Python result objects. Explicit `protocol=3` with default response settings selects native Python maps. The pinned redisvl query adapter can then raise `AttributeError` when it expects a result object. Use `protocol=2` to select RESP2 explicitly.

The pinned `RedisChatMessageHistory` stores JSON and searches nested fields. Use a RESP2 client such as `Redis.from_url(url, protocol=2)` as `redis_client` when opening an existing chat index. The pinned wrapper expects a RESP2 list in `FT.INFO`; under RESP3 the server returns a map and the wrapper raises `AttributeError`. This reproduces on the Redis reference as well.

With connection pooling and Eski access controls, use a login whose default clearance and fixed owner match the application scope. The client libraries issue ordinary search and document commands on pooled connections. A login that requires command-level labels or tokens needs an integration that supplies the scope for every applicable request and transaction.

Here is the earlier JSON index through redisvl, plus a separate LangChain store with a local example embedding.

```python
from langchain_core.embeddings import DeterministicFakeEmbedding
from langchain_redis import RedisConfig, RedisVectorStore
from redis import Redis
from redisvl.index import SearchIndex
from redisvl.query import VectorQuery

url = "redis://127.0.0.1:6399"
index = SearchIndex.from_existing("note", redis_client=Redis.from_url(url, protocol=2))
hits = index.query(VectorQuery([1.0, 0.0, 0.0], "embedding", return_fields=["title"], num_results=1))

store = RedisVectorStore(
    DeterministicFakeEmbedding(size=8),
    config=RedisConfig(redis_url=url, index_name="notes-lc", storage_type="json"),
)
store.add_texts(["Memory stores"])
docs = store.similarity_search("Memory stores", k=1)
```

For LlamaIndex, pass `RedisVectorStore(redis_url=url)` from `llama_index.vector_stores.redis` into `StorageContext.from_defaults(vector_store=store)`. Supply an embedding model matching the schema when constructing `VectorStoreIndex`. The pinned default schema uses a 1,536-dimensional HASH vector. The [fixture](../test/compatibility/search_clients/llama.py) shows the default schema and a custom HASH schema.

### Rerun the client checks

Build Eski with `./build.sh release`, then create the two independent Python 3.12 environments. The fixture was exercised on CPython 3.12.14.

```sh
python3.12 -m venv /tmp/eski-search-modern
python3.12 -m venv /tmp/eski-search-llama
/tmp/eski-search-modern/bin/pip install -r test/compatibility/search_clients/requirements-modern.txt
/tmp/eski-search-llama/bin/pip install -r test/compatibility/search_clients/requirements-llama.txt
python3 -IB test/compatibility/search_clients/run.py \
  --modern-python /tmp/eski-search-modern/bin/python \
  --llama-python /tmp/eski-search-llama/bin/python
```

The runner starts isolated loopback instances and runs the pinned clients with scoped and ordinary access. `--keyspace-threads 2` rechecks behavior with keyspace workers enabled. It uses local embeddings and disallows remote connections. The regular [package checks](build-run-test.md#verification) use the standard library wire tests and run independently of these Python environments.
