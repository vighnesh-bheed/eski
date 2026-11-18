from collections import Counter
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (ClientCase, Guard, INVALID_VECTOR_OPTION, OTHER, POINT, THIRD, execute,
                    pairs, point, setup)

if __name__ == '__main__':
    args = setup({'redisvl': '0.31.0', 'redis': '8.1.0', 'langchain-redis': '0.2.6',
                  'langchain-core': '1.7.6'})
    guard = Guard(args.port)
    guard.install()
    guard.record_redis()

from langchain_core.documents import Document
from langchain_core.embeddings import DeterministicFakeEmbedding
from langchain_core.messages import AIMessage, HumanMessage
from langchain_core.outputs import Generation
from langchain_redis import RedisCache, RedisChatMessageHistory, RedisConfig, RedisSemanticCache
from langchain_redis import RedisVectorStore
from redisvl.exceptions import RedisSearchError
from redisvl.extensions.cache.llm import SemanticCache
from redisvl.extensions.message_history import MessageHistory, SemanticMessageHistory
from redisvl.extensions.router import Route, SemanticRouter
from redisvl.index import SearchIndex
from redisvl.query import (AggregateHybridQuery, CountQuery, FilterQuery, HybridQuery, MultiVectorQuery,
                           TextQuery, Vector, VectorQuery, VectorRangeQuery)
from redisvl.query.filter import Geo, GeoRadius, Num, Tag, Text
from redisvl.redis.utils import array_to_buffer
from redisvl.utils.vectorize import CustomVectorizer

EMBEDDINGS = DeterministicFakeEmbedding(size=8)
EXAMPLES = {
    'one': ('alpha cat', 'Health Care', 2024, POINT),
    'two': ('beta dog', 'sports', 2025, OTHER),
    'three': ('gamma fox', 'tech', 2026, THIRD),
}


def content_vector(text):
    return OTHER if 'dog' in text else POINT


def dictionary(index, prefix, storage, algorithm):
    nested = storage == 'json'
    fields = [
        {'name': 'content', 'type': 'text'},
        {'name': 'section', 'type': 'tag', 'attrs': {'index_missing': True}},
        {'name': 'year', 'type': 'numeric', 'attrs': {'sortable': True}},
        {'name': 'place', 'type': 'geo'},
        {'name': 'embedding', 'type': 'vector', 'attrs': {
            'dims': 3, 'distance_metric': 'cosine', 'algorithm': algorithm, 'datatype': 'float32'}},
    ]
    if nested:
        for field in fields:
            field['path'] = '$.body.' + field['name']
    return {'index': {'name': index, 'prefix': prefix, 'storage_type': storage}, 'fields': fields}


def document(storage, key, override=None):
    content, section, year, vector = override or EXAMPLES[key]
    row = {'content': content, 'section': section, 'year': year, 'embedding': vector,
           'place': '-122.4,37.75'}
    if storage == 'json':
        return {'body': row}
    return dict(row, embedding=array_to_buffer(vector, 'float32'))


class ModernCase(ClientCase):
    def redis_protocol(self, protocol):
        return protocol if protocol else 2 if self.args.protocol == 2 else None


class RedisVL(ModernCase):
    def check_store(self, storage, algorithm):
        name = self.name(f'rvl-{storage}')
        client = self.redis()
        mark = len(self.guard.commands)
        index = SearchIndex.from_dict(dictionary(name, name, storage, algorithm), redis_client=client)
        index.create()
        self.addCleanup(index.delete, drop=True)
        self.assertTrue(index.exists())
        self.assertIn(name, index.listall())
        ids = [f'{name}:{key}' for key in EXAMPLES]
        self.assertEqual(index.load([document(storage, key) for key in EXAMPLES], keys=ids, ttl=600), ids)
        self.assertGreater(client.ttl(ids[0]), 0)
        self.assertEqual(index.fetch('one')['body' if storage == 'json' else 'content'],
                         document(storage, 'one')['body' if storage == 'json' else 'content'])
        attached = SearchIndex.from_existing(name, redis_client=client)
        self.assertEqual(attached.schema.index.storage_type.value, storage)
        self.assertEqual(attached.schema.fields['embedding'].attrs.dims, 3)
        self.assertEqual(index.query(CountQuery('*')), 3)

        fields = ['content', 'section', 'year']
        query = VectorQuery(POINT, 'embedding', return_fields=fields, num_results=3)
        results = index.query(query)
        self.assertEqual([r['id'] for r in results], ids)
        for distance, row in enumerate(results):
            self.assert_distance(row['vector_distance'], distance)
        knn = next(command for command in self.guard.commands[mark:]
                   if command[:2] == ('FT.SEARCH', name) and 'KNN' in command[2])
        self.assertIn('DIALECT', knn)
        self.assertIn(point(), knn)
        raw = self.raw(self.args.protocol)
        reply = raw.call(*knn)
        if self.args.protocol == 2:
            raw_ids = reply[1::2]
            raw_fields = pairs(reply[2])
        else:
            raw_ids = [row['id'] for row in reply['results']]
            raw_fields = reply['results'][0]['extra_attributes']
        self.assertEqual(raw_ids, [key.encode() for key in ids])
        self.assertEqual(raw_fields[b'content'], b'alpha cat')
        self.assert_distance(raw_fields[b'vector_distance'])

        for condition in (Tag('section') == 'Health Care', Num('year').between(2024, 2025, inclusive='left'),
                          Text('content') % 'alp*', Text('content') % '%alpa%'):
            found = index.query(VectorQuery(POINT, 'embedding', num_results=3, filter_expression=condition))
            self.assertEqual([r['id'] for r in found], ids[:1])
        self.assertEqual(index.query(CountQuery(Geo('place') == GeoRadius(-122.4, 37.75, 1, 'km'))), 3)
        self.assertEqual(index.query(CountQuery(Tag('section').is_missing())), 0)
        pages = list(index.paginate(FilterQuery('*', return_fields=['year'], sort_by=('year', 'ASC')), page_size=2))
        self.assertEqual([[row['id'] for row in page] for page in pages], [ids[:2], ids[2:]])
        text = index.query(TextQuery('alpha', 'content', return_fields=['content'], text_scorer='BM25STD'))
        self.assertEqual([r['id'] for r in text], ids[:1])
        self.assertGreater(float(text[0]['score']), 0)
        self.assertEqual([r['id'] for r in index.query(VectorRangeQuery(POINT, 'embedding', distance_threshold=1.01,
                                                                        return_fields=['content']))], ids[:2])
        if algorithm == 'hnsw':
            self.assertEqual([r['id'] for r in index.query(VectorQuery(POINT, 'embedding', num_results=1, ef_runtime=20))], ids[:1])
        else:
            with self.assertRaisesRegex(RedisSearchError, INVALID_VECTOR_OPTION):
                index.query(VectorRangeQuery(POINT, 'embedding', distance_threshold=1.01, epsilon=0.1))

        for pipeline in (
                AggregateHybridQuery('alpha', 'content', POINT, 'embedding', num_results=3, return_fields=['content']),
                MultiVectorQuery([Vector(vector=POINT, field_name='embedding', weight=1.0)], num_results=3,
                                 return_fields=['content']),
                HybridQuery('alpha', 'content', POINT, 'embedding', combination_method='RRF',
                            rrf_window=3, num_results=3, return_fields=['content']),
                HybridQuery('alpha', 'content', POINT, 'embedding', combination_method='LINEAR',
                            linear_alpha=0.5, num_results=3, return_fields=['content'])):
            rows = index.query(pipeline)
            self.assertEqual(rows[0]['content'], 'alpha cat', rows)
            self.assertEqual(Counter(row['content'] for row in rows),
                             Counter(row[0] for row in EXAMPLES.values()))
        for command in ('FT.CREATE', 'FT.INFO', 'FT.AGGREGATE', 'FT.HYBRID'):
            self.expect_wire(mark, command, name)
        self.expect_wire(mark, 'JSON.SET' if storage == 'json' else 'HSET', ids[0])
        if self.args.protocol == 3:
            self.expect_wire(mark, 'HELLO', 3)
        self.assertEqual(index.drop_documents(['three']), 1)
        self.assertEqual(index.query(CountQuery('*')), 2)
        self.assertEqual(index.clear(), 2)

    def test_hash_hnsw(self):
        self.check_store('hash', 'hnsw')

    def test_json_flat(self):
        self.check_store('json', 'flat')

    def test_explicit_native_resp3_adapter(self):
        if self.args.protocol != 3:
            self.skipTest('requires explicit native RESP3')
        name = self.name('rvl-native')
        client = self.redis(3)
        index = SearchIndex.from_dict(dictionary(name, name, 'hash', 'flat'), redis_client=client)
        index.create()
        self.addCleanup(index.delete, drop=True)
        index.load([document('hash', 'one')], keys=[name + ':one'])
        mark = len(self.guard.commands)
        with self.assertRaisesRegex(AttributeError, "object has no attribute 'total'"):
            index.query(CountQuery('*'))
        command = next(cmd for cmd in self.guard.commands[mark:] if cmd[:2] == ('FT.SEARCH', name))
        self.assertEqual(self.raw(3).call(*command)['total_results'], 1)

    def test_extensions(self):
        client = self.redis()
        vectorizer = CustomVectorizer(embed=content_vector,
                                      embed_many=lambda texts: [content_vector(text) for text in texts])
        cache = SemanticCache(name=self.name('rvl-cache'), distance_threshold=0.2,
                              vectorizer=vectorizer, redis_client=client)
        self.addCleanup(cache.delete)
        cache.store(prompt='alpha cat', response='cached cat', ttl=600)
        self.assertEqual([r['response'] for r in cache.check(prompt='alpha cat')], ['cached cat'])
        self.assertEqual(cache.check(prompt='beta dog'), [])
        cache.clear()

        for history_class in (MessageHistory, SemanticMessageHistory):
            kwargs = {'vectorizer': vectorizer, 'distance_threshold': 0.2} if history_class is SemanticMessageHistory else {}
            history = history_class(name=self.name(history_class.__name__), session_tag='fixture',
                                    redis_client=client, **kwargs)
            self.addCleanup(history.delete)
            history.store('alpha cat', 'beta dog')
            self.assertEqual([row['content'] for row in history.get_recent(top_k=2)], ['alpha cat', 'beta dog'])
            if kwargs:
                self.assertEqual([row['content'] for row in history.get_relevant('alpha cat', top_k=2)], ['alpha cat'])
            history.clear()
            self.assertEqual(history.get_recent(top_k=2), [])

        routes = [Route(name='cat', references=['alpha cat'], distance_threshold=0.2),
                  Route(name='dog', references=['beta dog'], distance_threshold=0.2)]
        router = SemanticRouter(name=self.name('rvl-router'), routes=routes, vectorizer=vectorizer, redis_client=client)
        self.addCleanup(router.delete)
        self.assertEqual(router('alpha cat').name, 'cat')
        self.assertEqual([match.name for match in router.route_many('beta dog', max_k=2)], ['dog'])


class LangChain(ModernCase):
    def check_store(self, storage):
        name = self.name(f'lc-{storage}')
        client = self.redis()
        mark = len(self.guard.commands)
        cfg = RedisConfig(redis_client=client, index_name=name, key_prefix=name, storage_type=storage,
                          metadata_schema=[{'name': 'section', 'type': 'tag'}, {'name': 'year', 'type': 'numeric'}])
        store = RedisVectorStore(EMBEDDINGS, config=cfg, ttl=600)
        self.addCleanup(store.index.delete, drop=True)
        store.add_texts(['alpha cat', 'beta dog'], [{'section': 'Health Care', 'year': 2024},
                                                     {'section': 'sports', 'year': 2025}], keys=['one', 'two'])
        store.add_documents([Document(page_content='gamma fox', metadata={'section': 'tech', 'year': 2026})],
                            ids=['three'])
        self.assertGreater(client.ttl(name + ':one'), 0)
        exact, distance = store.similarity_search_with_score('alpha cat', k=1)[0]
        self.assertEqual(exact.page_content, 'alpha cat')
        self.assertEqual(exact.metadata, {'section': 'Health Care', 'year': 2024})
        self.assert_distance(distance)
        for condition in (Tag('section') == 'Health Care', Num('year') == 2024, '@section:{Health\\ Care}'):
            self.assertEqual([r.page_content for r in store.similarity_search('alpha cat', k=3, filter=condition)],
                             ['alpha cat'])
        self.assertEqual([r.page_content for r in store.similarity_search('alpha cat', k=3, distance_threshold=0.01)],
                         ['alpha cat'])
        self.assertEqual(store.similarity_search_by_vector(EMBEDDINGS.embed_query('alpha cat'), k=1)[0].page_content,
                         'alpha cat')
        self.assertEqual(store.max_marginal_relevance_search('alpha cat', k=2, fetch_k=3)[0].page_content, 'alpha cat')
        self.assertEqual(store.as_retriever(search_kwargs={'k': 1}).invoke('alpha cat')[0].page_content, 'alpha cat')
        with self.assertRaises(NotImplementedError):
            store.similarity_search_with_relevance_scores('alpha cat', k=1)
        with self.assertRaises(NotImplementedError):
            store.as_retriever(search_type='similarity_score_threshold',
                               search_kwargs={'score_threshold': 0.5, 'k': 1}).invoke('alpha cat')
        attached = RedisVectorStore.from_existing_index(name, EMBEDDINGS, redis_client=client,
                                                        storage_type=storage, key_prefix=name)
        self.assertEqual(attached.similarity_search('alpha cat', k=1)[0].page_content, 'alpha cat')
        self.assertEqual([r.page_content for r in attached.get_by_ids(['one', 'missing'])], ['alpha cat'])
        self.expect_wire(mark, 'JSON.MGET' if storage == 'json' else 'HGETALL', name + ':one')
        self.assertTrue(store.delete(ids=['two']))
        self.assertEqual(store.get_by_ids(['two']), [])

    def test_hash(self):
        self.check_store('hash')

    def test_json(self):
        self.check_store('json')

    def test_json_chat(self):
        client = self.redis()
        mark = len(self.guard.commands)
        history = RedisChatMessageHistory('first', redis_client=client, index_name='client-chat', ttl=600)
        self.addCleanup(history.index.delete, drop=True)
        history.add_messages([HumanMessage(content='alpha cat'), AIMessage(content='beta dog')])
        self.assertEqual([r.content for r in history.messages], ['alpha cat', 'beta dog'])
        self.assertEqual([r["content"] for r in history.search_messages('dog', limit=2)], ['beta dog'])
        self.assertTrue(any(cmd[0] == 'JSON.SET' and cmd[1].startswith('chat:first:') for cmd in self.guard.commands[mark:]))
        query = next(cmd for cmd in self.guard.commands[mark:] if cmd[:2] == ('FT.SEARCH', 'client-chat') and '$.data' in cmd)
        reply = self.raw(self.args.protocol).call(*query)
        rows = [pairs(row) for row in reply[2::2]] if self.args.protocol == 2 else [
            row['extra_attributes'] for row in reply['results']]
        self.assertEqual([json.loads(row[b'$.data'])['content'] for row in rows], ['alpha cat', 'beta dog'])
        if self.args.protocol == 3:
            with self.assertRaisesRegex(AttributeError, "object has no attribute 'index'"):
                RedisChatMessageHistory('second', redis_client=client, index_name='client-chat')
        second = RedisChatMessageHistory('second', redis_client=self.redis(2), index_name='client-chat')
        second.add_message(HumanMessage(content='second session'))
        history.clear()
        self.assertEqual(history.messages, [])
        self.assertEqual(second.search_messages('session', limit=1)[0]["content"], 'second session')
        second.clear()

    def test_caches(self):
        port = self.args.port
        url = f'redis://127.0.0.1:{port}' + ('?protocol=2' if self.args.protocol == 2 else '')
        for cache in (RedisCache(redis_url=url, ttl=600, prefix=self.name('lc-cache')),
                      RedisSemanticCache(embeddings=EMBEDDINGS, redis_url=url, ttl=600,
                                         name=self.name('lc-semantic'), distance_threshold=0.001)):
            cache.update('alpha cat', 'fixture-model', [Generation(text='cached cat')])
            self.assertEqual(cache.lookup('alpha cat', 'fixture-model'), [Generation(text='cached cat')])
            self.assertIsNone(cache.lookup('unknown', 'fixture-model'))
            cache.clear()
            self.assertIsNone(cache.lookup('alpha cat', 'fixture-model'))


class Scoped(ModernCase):
    def test_shared_hash_and_json_through_pooled_clients(self):
        admin = self.scoped_users()
        actor = self.redis(user='client-alice')
        visitor = self.redis(user='client-bob')
        actual = self.raw(self.args.protocol, 'client-alice')
        for storage, data_cmd in (('hash', 'HGETALL'), ('json', 'JSON.GET')):
            with self.subTest(storage=storage):
                prefix = f'catalog-{storage}'
                visible = self.name(f'visible-{storage}')
                hidden = self.name(f'hidden-{storage}')
                schema = dictionary(visible, prefix, storage, 'flat')
                fields = ('content', 'TEXT', 'embedding')
                if storage == 'json':
                    fields = ('$.body.content', 'AS', 'content', 'TEXT', '$.body.embedding', 'AS', 'embedding')
                admin.call('LABEL', 'AS', 'U', 'SHARED', 'FT.CREATE', visible, 'ON', storage.upper(),
                           'PREFIX', 1, prefix + ':', 'SCHEMA', *fields, 'VECTOR', 'FLAT', 6,
                           'TYPE', 'FLOAT32', 'DIM', 3, 'DISTANCE_METRIC', 'COSINE')
                index = SearchIndex.from_dict(schema, redis_client=actor)
                keys = [prefix + ':one', prefix + ':two']
                index.load([document(storage, 'one'), document(storage, 'two')], keys=keys)
                self.assert_scope(actual, visible, prefix)
                before = repr(actual.call('FT.INFO', visible))
                foreign = SearchIndex.from_dict(dictionary(hidden, prefix, storage, 'flat'), redis_client=visitor)
                foreign.create()
                foreign.load([document(storage, 'three')] * 2, keys=[prefix + ':one', prefix + ':hidden'])
                if storage == 'hash':
                    admin.call('LABEL', 'AS', 'C', 'SHARED', 'HSET', prefix + ':high', 'content', 'high', 'embedding', point())
                else:
                    admin.call('LABEL', 'AS', 'C', 'SHARED', 'JSON.SET', prefix + ':high', '$',
                               json.dumps(document(storage, 'one')))
                self.assertEqual(repr(actual.call('FT.INFO', visible)), before)
                self.assertEqual(index.query(CountQuery('*')), 2)
                hits = index.query(VectorQuery(POINT, 'embedding', num_results=2, return_fields=['content']))
                self.assertEqual([row['id'] for row in hits], keys)
                self.assertEqual(index.fetch('one')['body' if storage == 'json' else 'content'],
                                 document(storage, 'one')['body' if storage == 'json' else 'content'])
                self.assert_missing_twin(actual, visible, hidden, data_cmd, prefix)
                self.assert_scope(actual, visible, prefix)
                self.assertEqual(foreign.query(CountQuery('*')), 2)
                self.assertEqual(index.drop_documents(['one']), 1)
                self.assertEqual(index.query(CountQuery('*')), 1)
                self.assertEqual(foreign.query(CountQuery('*')), 2)
                foreign.delete(drop=True)
                admin.call('LABEL', 'AS', 'U', 'SHARED', 'FT.DROPINDEX', visible)
                admin.call('LABEL', 'AS', 'C', 'SHARED', 'DEL', prefix + ':high')

        name = self.name('scoped-lc')
        config = dict(index_name=name, key_prefix=name, storage_type='json')
        lca = RedisVectorStore(EMBEDDINGS, config=RedisConfig(redis_client=actor, **config))
        lcb = RedisVectorStore(EMBEDDINGS, config=RedisConfig(redis_client=visitor, **config))
        lca.add_texts(['alpha cat'], keys=['one'])
        lcb.add_texts(['beta dog'], keys=['one'])
        self.assertEqual(lca.similarity_search('beta dog', k=2)[0].page_content, 'alpha cat')
        self.assertEqual(lcb.get_by_ids(['one'])[0].page_content, 'beta dog')
        lcb.index.delete(drop=True)
        self.assertEqual(lca.get_by_ids(['one'])[0].page_content, 'alpha cat')
        lca.index.delete(drop=True)


if __name__ == '__main__':
    execute(args, guard, Scoped) if args.scoped else execute(args, guard, RedisVL, LangChain)
