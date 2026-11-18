import struct


def smoke(replay, protocols):
    for proto in protocols:
        replay.reset()
        call = replay.connection(proto).case
        query = struct.pack("<2f", 1, 0)
        call("introspection", "modules", "MODULE", "LIST")
        call("introspection", "suggestion-dictionary", "FT.SUGLEN", "suggestions")
        call("hash search", "create", "FT.CREATE", "articles", "ON", "HASH", "PREFIX", 1, "article:",
             "SCHEMA", "title", "TEXT", "NOSTEM", "topic", "TAG", "price", "NUMERIC", "SORTABLE",
             "v", "VECTOR", "FLAT", 6, "TYPE", "FLOAT32", "DIM", 2, "DISTANCE_METRIC", "L2")
        for index, (title, topic, price, vector) in enumerate((
            ("memory stores", "db", 10, (1, 0)),
            ("memory search", "db", 20, (0, 1)),
            ("outdoor maps", "travel", 30, (-1, 0)),
        )):
            call("hash search", "write-%d" % index, "HSET", "article:%d" % index, "title", title,
                 "topic", topic, "price", price, "v", struct.pack("<2f", *vector))
        call("hash search", "filter-project", "FT.SEARCH", "articles", "@title:memory @topic:{db}",
             "SORTBY", "price", "ASC", "RETURN", 2, "title", "price", "DIALECT", 2)
        call("hash search", "vector", "FT.SEARCH", "articles", "@topic:{db}=>[KNN 2 @v $query AS d]",
             "PARAMS", 2, "query", query, "SORTBY", "d", "RETURN", 1, "d", "DIALECT", 2)
        call("hash search", "missing-index", "FT.SEARCH", "missing", "*")
        call("aggregate", "group", "FT.AGGREGATE", "articles", "*", "LOAD", 1, "@topic",
             "GROUPBY", 1, "@topic", "REDUCE", "COUNT", 0, "AS", "n", "SORTBY", 2, "@topic", "ASC")
        cursor = call("aggregate", "cursor", "FT.AGGREGATE", "articles", "*", "LOAD", 1, "@price",
                      "SORTBY", 2, "@price", "ASC", "WITHCURSOR", "COUNT", 1)
        call("aggregate", "cursor-read", "FT.CURSOR", "READ", "articles", cursor, "COUNT", 1)
        call("aggregate", "cursor-delete", "FT.CURSOR", "DEL", "articles", cursor)
        call("hybrid", "terms-and-vector", "FT.HYBRID", "articles", "SEARCH", "memory",
             "VSIM", "@v", "$query", "COMBINE", "RRF", 2, "YIELD_SCORE_AS", "rank",
             "LOAD", 1, "@__key", "LIMIT", 0, 3, "PARAMS", 2, "query", query)
        call("JSON", "write", "JSON.SET", "note:1", "$", '{"text":"memory","rank":1,"tags":["db"]}')
        call("JSON", "increment", "JSON.NUMINCRBY", "note:1", "$.rank", 2)
        call("JSON", "projection", "JSON.GET", "note:1", "$.rank", "$.tags")
        call("JSON", "create-json-index", "FT.CREATE", "notes", "ON", "JSON", "PREFIX", 1, "note:",
             "SCHEMA", "$.text", "AS", "text", "TEXT", "$.rank", "AS", "rank", "NUMERIC")
        replay.wait_indexed("notes")
        call("JSON", "search", "FT.SEARCH", "notes", "@rank:[3 3]", "RETURN", 2, "text", "rank", "DIALECT", 2)
        call("JSON", "replace-field", "JSON.SET", "note:1", "$.rank", "4")
        call("JSON", "update-index", "FT.SEARCH", "notes", "@rank:[3 3]", "NOCONTENT", "DIALECT", 2)
        call("introspection", "index-inventory", "FT._LIST")
        call("hash search", "drop-with-documents", "FT.DROPINDEX", "articles", "DD")
        call("hash search", "documents-dropped", "EXISTS", "article:0", "article:1", "article:2")
