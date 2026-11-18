from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import ClientCase, Guard, OTHER, POINT, THIRD, execute, point, setup

if __name__ == '__main__':
    args = setup({'llama-index-vector-stores-redis': '0.9.0', 'llama-index-core': '0.14.25',
                  'redisvl': '0.4.1', 'redis': '5.3.1'})
    guard = Guard(args.port)
    guard.install()
    guard.record_redis()

from llama_index.core import Settings, StorageContext, VectorStoreIndex
from llama_index.core.embeddings import MockEmbedding
from llama_index.core.schema import NodeRelationship, RelatedNodeInfo, TextNode
from llama_index.core.vector_stores.types import FilterOperator, MetadataFilter, MetadataFilters, VectorStoreQuery
from llama_index.vector_stores.redis import RedisVectorStore
from redisvl.schema import IndexSchema


def schema(base, storage='hash'):
    fields = [{'type': 'tag', 'name': field} for field in ('id', 'doc_id', 'section')]
    fields += [
        {'type': 'text', 'name': 'text'},
        {'type': 'numeric', 'name': 'year'},
        {'type': 'vector', 'name': 'vector', 'attrs': {
            'dims': 3, 'algorithm': 'hnsw', 'distance_metric': 'cosine'}},
    ]
    if storage == 'json':
        for field in fields:
            field['path'] = '$.' + field['name']
    return IndexSchema.from_dict({'index': {'name': base, 'prefix': base, 'storage_type': storage}, 'fields': fields})


def example(id_, text, section, year, vector=None):
    return TextNode(id_=id_, text=text, metadata={'section': section, 'year': year}, embedding=vector,
                    relationships={NodeRelationship.SOURCE: RelatedNodeInfo(node_id='source-' + id_)})


def filters(*conditions):
    return MetadataFilters(filters=list(conditions))


class LlamaIndex(ClientCase):
    def test_default_retriever(self):
        Settings.tokenizer = lambda text: text.split()
        mark = len(self.guard.commands)
        store = RedisVectorStore(redis_url=f'redis://127.0.0.1:{self.args.port}?protocol={self.args.protocol}')
        self.expect_wire(mark, 'MODULE', 'LIST')
        self.addCleanup(store.delete_index)
        storage = StorageContext.from_defaults(vector_store=store)
        node = example('one', 'alpha cat', 'Health Care', 2024)
        index = VectorStoreIndex([node], storage_context=storage, embed_model=MockEmbedding(embed_dim=1536))
        retrieved = index.as_retriever(similarity_top_k=1).retrieve('alpha cat')
        self.assertEqual([(row.node.node_id, row.node.text) for row in retrieved], [('one', 'alpha cat')])
        self.assert_distance(retrieved[0].score, 1)
        index.delete_ref_doc('source-one')
        self.assertEqual(index.as_retriever(similarity_top_k=1).retrieve('alpha cat'), [])

    def test_hash_metadata_and_lifecycle(self):
        name = self.name('li-hash')
        client = self.redis()
        mark = len(self.guard.commands)
        definition = schema(name)
        store = RedisVectorStore(schema=definition, redis_client=client)
        self.addCleanup(store.delete_index)
        self.assertTrue(store.index_exists())
        rows = [example('one', 'alpha cat', 'Health Care', 2024, POINT),
                example('two', 'beta dog', 'sports', 2025, OTHER),
                example('three', 'gamma fox', 'tech', 2026, THIRD)]
        self.assertEqual(store.add(rows), ['one', 'two', 'three'])
        query = VectorStoreQuery(query_embedding=POINT, similarity_top_k=3)
        results = store.query(query)
        self.assertEqual(results.ids, [f'{name}:{id_}' for id_ in ('one', 'two', 'three')])
        self.assertEqual([node.text for node in results.nodes], [node.text for node in rows])
        for score, expected in zip(results.similarities, (1, 0, -1), strict=True):
            self.assert_distance(score, expected)
        knn = next(command for command in self.guard.commands[mark:]
                   if command[:2] == ('FT.SEARCH', name) and 'KNN' in command[2])
        self.assertIn('params', knn)
        self.assertIn(point(), knn)
        self.expect_wire(mark, 'FT._LIST')
        self.expect_wire(mark, 'HSET')
        for condition in (MetadataFilter(key='section', value='Health Care'),
                          MetadataFilter(key='year', value=2025, operator=FilterOperator.LT),
                          MetadataFilter(key='text', value='alpha', operator=FilterOperator.TEXT_MATCH)):
            result = store.query(VectorStoreQuery(query_embedding=POINT, filters=filters(condition)))
            self.assertEqual(result.ids, [name + ':one'])
        tag = MetadataFilter(key='section', value=['Health Care', 'tech'], operator=FilterOperator.IN)
        self.assertEqual(store.query(VectorStoreQuery(query_embedding=POINT, similarity_top_k=3,
                                                      filters=filters(tag))).ids, [name + ':one', name + ':three'])
        self.assertEqual({n.node_id for n in store.get_nodes(filters=filters(tag))}, {'one', 'three'})
        legacy = RedisVectorStore(schema=definition, redis_client=client, legacy_filters=True)
        with self.assertRaisesRegex(ValueError, 'only supports exact match'):
            legacy.query(VectorStoreQuery(query_embedding=POINT, filters=filters(tag)))
        with self.assertRaises(NotImplementedError):
            store.clear()
        store.delete_nodes(node_ids=['one'])
        self.assertEqual(store.query(query).ids, [name + ':two', name + ':three'])
        store.delete('source-two')
        self.assertEqual([node.node_id for node in store.get_nodes(node_ids=['two', 'three'])], ['three'])

    def test_json_binary_is_rejected_by_client(self):
        name = self.name('li-json')
        store = RedisVectorStore(schema=schema(name, 'json'), redis_client=self.redis())
        self.addCleanup(store.delete_index)
        self.assertTrue(store.index_exists())
        mark = len(self.guard.commands)
        with self.assertRaisesRegex(TypeError, 'bytes is not JSON serializable'):
            store.add([example('one', 'alpha cat', 'Health Care', 2024, POINT)])
        self.assertFalse(any(cmd[0] == 'JSON.SET' for cmd in self.guard.commands[mark:]))
        self.assertEqual(self.raw(self.args.protocol).call('SCAN', 0, 'MATCH', name + '*', 'COUNT', 100)[1], [])


class RESP3(ClientCase):
    def test_reply_reaches_wire_but_client_expects_resp2_result(self):
        name = self.name('li-resp3')
        client = self.redis()
        store = RedisVectorStore(schema=schema(name), redis_client=client)
        self.addCleanup(store.delete_index)
        store.add([example('one', 'alpha cat', 'Health Care', 2024, POINT)])
        mark = len(self.guard.commands)
        query = VectorStoreQuery(query_embedding=POINT, similarity_top_k=1)
        with self.assertRaisesRegex(AttributeError, "object has no attribute 'docs'"):
            store.query(query)
        command = next(cmd for cmd in self.guard.commands[mark:] if cmd[:2] == ('FT.SEARCH', name))
        c = self.raw(3)
        reply = c.call(*command)
        self.assertEqual([row['id'] for row in reply['results']], [f'{name}:one'.encode()])
        self.assert_distance(reply['results'][0]['extra_attributes'][b'vector_distance'])
        attach = RedisVectorStore(schema=schema(name), redis_client=self.redis(2))
        self.assertEqual([node.text for node in attach.query(query).nodes], ['alpha cat'])


class Scoped(ClientCase):
    def test_private_hash_store(self):
        self.scoped_users()
        name = self.name('scoped-li-hash')
        alice = RedisVectorStore(schema=schema(name), redis_client=self.redis(user='client-alice'))
        bob = RedisVectorStore(schema=schema(name), redis_client=self.redis(user='client-bob'))
        self.addCleanup(alice.delete_index)
        self.addCleanup(bob.delete_index)
        alice.add([example('one', 'alpha cat', 'Health Care', 2024, POINT)])
        bob.add([example('one', 'beta dog', 'sports', 2025, OTHER),
                 example('two', 'gamma fox', 'tech', 2026, THIRD)])
        query = VectorStoreQuery(query_embedding=POINT, similarity_top_k=3)
        self.assertEqual([n.text for n in alice.query(query).nodes], ['alpha cat'])
        self.assertEqual([n.text for n in bob.query(query).nodes], ['beta dog', 'gamma fox'])
        self.assertEqual(alice.get_nodes(node_ids=['two']), [])
        alice.delete_nodes(node_ids=['one'])
        self.assertEqual(alice.query(query).ids, [])
        self.assertEqual([n.text for n in bob.query(query).nodes], ['beta dog', 'gamma fox'])


if __name__ == '__main__':
    case = Scoped if args.scoped else (LlamaIndex if args.protocol == 2 else RESP3)
    execute(args, guard, case)
