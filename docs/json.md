# JSON documents

JSON values are native keys. They support [key lifecycle operations](keyspace.md), [labels](labels.md) and [owners](owners.md). A document has one key, one expiry and one access scope. `TYPE` reports `ReJSON-RL` for a JSON key. Use [search over JSON](search.md#create-and-query-an-index) to index typed values selected from documents.

```sh
redis-cli -p 6399 JSON.SET item:one '$' '{"body":{"title":"Memory stores","count":1},"tags":["db"]}'
redis-cli -p 6399 JSON.GET item:one '$.body.title'
redis-cli -p 6399 JSON.NUMINCRBY item:one '$.body.count' 1
redis-cli -p 6399 JSON.ARRAPPEND item:one '$.tags' '"search"'
redis-cli -p 6399 JSON.GET item:one .body.title
```

Use `$` for JSONPath and `.` for the legacy root. JSONPath reads such as `JSON.GET item:one '$.body.title'` return a JSON array of matches. The legacy read in the example returns the selected JSON string. Use single quotes in a shell to preserve path characters and JSON string quoting. JSONPath supports field and array selection, wildcards, recursive descent, unions, slices and supported filter expressions. Where a mutation selects several matches, some commands can apply earlier changes before reporting a later error.

| Operation | Commands |
| --- | --- |
| Read and inspect | `JSON.GET`, `JSON.MGET`, `JSON.TYPE`, `JSON.RESP`, `JSON.DEBUG MEMORY`, `JSON.DEBUG HELP` |
| Write and remove | `JSON.SET` with `NX` or `XX`, `JSON.MSET`, `JSON.MERGE`, `JSON.DEL`, `JSON.FORGET`, `JSON.CLEAR` |
| Edit scalars | `JSON.NUMINCRBY`, `JSON.NUMMULTBY`, `JSON.NUMPOWBY`, `JSON.TOGGLE`, `JSON.STRAPPEND`, `JSON.STRLEN` |
| Work with arrays | `JSON.ARRAPPEND`, `JSON.ARRINDEX`, `JSON.ARRINSERT`, `JSON.ARRLEN`, `JSON.ARRPOP`, `JSON.ARRTRIM` |
| Inspect objects | `JSON.OBJKEYS`, `JSON.OBJLEN` |

`JSON.MSET` takes successive key, path and value triples. `JSON.MGET` takes one path after all keys and reports each key to `COMMAND GETKEYS`, enabling ACL checks on every read. The [command inventory](commands.md#module) lists argument metadata and the available spellings.

## Format and limits

The parser accepts UTF-8 JSON text, signed and unsigned integers and finite floating-point values. JSON text input and output are bounded at 512 MiB. The parser and document operations cap depth at 127 containers and bound nodes, entries and result rows at 16,777,216. Paths are limited to 1 MiB, 1,024 selectors or expression operations, with their own nesting and evaluation bounds. The filter implementation covers a subset of the Redis extensions. Regex supports anchors, case-insensitive matching, character classes, wildcards and simple repetition. Grouping, alternation and counted repetitions are outside that subset. Binary BSON input is rejected. `JSON.SET` accepts FP16, BF16, FP32 and FP64 via `FPHA` for supported numeric arrays. The full interaction of narrowing and subsequent edits is outside the reference comparisons.

`JSON.DEBUG MEMORY` reports Eski's content charge. Scope quotas charge the document by content and global `maxmemory` counts actual allocations. Snapshots and `DUMP` use Eski's native JSON payload, with support for `RESTORE` and `MIGRATE` between Eski instances where the access mode permits. Move documents between engines with JSON text. Append-only rewrite supports JSON and preserves deadlines. Command-form rewrite uses `JSON.SET` for lossless text round trips and a native `RESTORE` payload where text would change the stored representation, including FPHA arrays. [Persistence](persistence.md#search-definitions-and-json-values)
