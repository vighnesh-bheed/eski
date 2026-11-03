import dataclasses
import gzip
import hashlib
import json
import time
from collections import Counter, deque
from pathlib import Path


INVARIANTS = (
    'exclusive_mutable_record_and_owner',
    'reads_match_accepted_record_history',
    'records_match_independent_history',
    'publication_is_accepted_prefix_once',
    'rejection_preserves_sequence_and_resources',
    'accepted_write_survives_disconnect',
    'rollback_and_retry_publish_once',
    'no_product_deadlock',
    'no_lost_worker_wakeup',
    'no_lost_completion_notification',
    'no_lost_quiescence_wakeup',
)


@dataclasses.dataclass(frozen=True)
class Plan:
    name: str
    records: tuple
    writes: bool = True
    abort: bool = False
    reject: bool = False


@dataclasses.dataclass(frozen=True)
class Scenario:
    name: str
    owners: tuple
    plans: tuple
    capacity: int = 3
    disconnect: int = -1
    pause: bool = False


@dataclasses.dataclass(frozen=True)
class State:
    admission: int
    accepted: tuple
    rejected: tuple
    stages: tuple
    queues: tuple
    workers: tuple
    arrived: tuple
    departed: tuple
    cancelled: tuple
    failed: tuple
    steps: tuple
    snapshots: tuple
    reads: tuple
    values: tuple
    completed: tuple
    staged: tuple
    published: tuple
    effects: tuple
    delivery: tuple
    connected: tuple
    outstanding: int = 0
    halted: bool = False
    pause_phase: int = 0
    fencing: bool = False
    replay: bool = False
    parked: tuple = (True, True)
    deciding: tuple = (False, False)
    notify: tuple = (False, False)
    efd: bool = False
    coordinator: str = 'sleep'
    reported: bool = False
    quiescent_wake: bool = False


class Violation(Exception):
    def __init__(self, invariant, detail):
        self.invariant = invariant
        self.detail = detail
        super().__init__(invariant + ': ' + detail)


def require(condition, invariant, detail):
    if not condition:
        raise Violation(invariant, detail)


def change_tuple(values, index, value):
    return values[:index] + (value,) + values[index + 1:]


def initial(scenario):
    n = len(scenario.plans)
    return State(0, (), (), ('new',) * n, ((), ()), (-1, -1), (0,) * n,
                 (0,) * n, (False,) * n, (False,) * n, (0,) * n,
                 ((),) * n, ((),) * n, (0,) * len(scenario.owners), (), (),
                 (), (), (), (True,) * n)


def owners_of(scenario, job, mutant):
    records = scenario.plans[job].records
    if mutant == 'bypass_ownership':
        return (scenario.owners[records[0]],)
    return tuple(sorted({scenario.owners[r] for r in records}))


def apply_plan(values, plan, job, count=None):
    values = list(values)
    if plan.writes:
        for r in plan.records[:count]:
            values[r] = values[r] * 10 + job + 1
    return tuple(values)


def reference(scenario, accepted, before=None):
    values = (0,) * len(scenario.owners)
    observations = {}
    for job in accepted:
        plan = scenario.plans[job]
        seen = []
        for r in plan.records:
            seen.append(values[r])
            if plan.writes:
                values = change_tuple(values, r, values[r] * 10 + job + 1)
        observations[job] = tuple(seen)
        if job == before:
            break
    return values, observations


def terminal(scenario, state):
    return (state.admission == len(scenario.plans) and
            len(state.published) == len(state.accepted) and
            not state.outstanding and not state.completed and not state.staged and
            not state.halted and not state.replay and not state.fencing and
            all(w == -1 for w in state.workers) and all(state.parked) and
            not any(state.notify) and not any(state.deciding) and not state.efd and
            state.coordinator == 'sleep' and not state.reported and
            (not scenario.pause or state.pause_phase == 3))


def quiescent(state):
    return all(state.parked) and not any(state.queues)


def park(state, w):
    state = dataclasses.replace(state, parked=change_tuple(state.parked, w, True),
                                deciding=change_tuple(state.deciding, w, False))
    if state.pause_phase == 1 and quiescent(state):
        state = dataclasses.replace(state, quiescent_wake=True)
    return state


def wake(state):
    if state.coordinator == 'sleep':
        return dataclasses.replace(state, coordinator='read', reported=state.efd)
    return state


def read_notification(state, phase):
    label = 'coordinator_read_notification' if state.reported else 'coordinator_skip_read'
    return label, dataclasses.replace(state, coordinator=phase, reported=False, efd=state.efd and not state.reported)


def take_completions(state, phase):
    return dataclasses.replace(
        state, coordinator=phase, completed=(), staged=state.staged + state.completed,
        outstanding=state.outstanding - len(state.completed),
        replay=state.replay or any(state.failed[j] for j in state.completed))


def successors(scenario, s, mutant=''):
    p = scenario.plans
    n = len(p)
    if terminal(scenario, s):
        return
    yield 'environment_yield', s
    blocked = s.pause_phase in (1, 4)
    if s.admission < n and not s.fencing and not blocked and s.coordinator != 'take':
        j = s.admission
        rejecting = p[j].reject or s.halted or s.pause_phase == 2 or s.outstanding >= scenario.capacity
        if rejecting:
            yield 'reject', dataclasses.replace(wake(s), admission=j + 1, rejected=s.rejected + (j,),
                                               stages=change_tuple(s.stages, j, 'rejected'))
        else:
            queues = s.queues
            parked = s.parked
            for owner in owners_of(scenario, j, mutant):
                queues = change_tuple(queues, owner, queues[owner] + (j,))
                parked = change_tuple(parked, owner, False)
            yield 'admit_assign_sequence', dataclasses.replace(
                wake(s), admission=j + 1, accepted=s.accepted + (j,), queues=queues, parked=parked,
                stages=change_tuple(s.stages, j, 'queued'), outstanding=s.outstanding + 1)
    for w in range(2):
        ready = s.workers[w] == -1 and not s.parked[w] and not s.notify[w] and not s.deciding[w]
        if ready and s.queues[w]:
            j = s.queues[w][0]
            yield 'worker_arrive', dataclasses.replace(
                s, queues=change_tuple(s.queues, w, s.queues[w][1:]),
                workers=change_tuple(s.workers, w, j),
                arrived=change_tuple(s.arrived, j, s.arrived[j] | (1 << w)))
        if ready and not s.queues[w]:
            if mutant == 'park_outside_mutex':
                yield 'worker_see_empty_queue', dataclasses.replace(s, deciding=change_tuple(s.deciding, w, True))
            else:
                yield 'worker_park', park(s, w)
        if s.deciding[w]:
            yield 'worker_park', park(s, w)
        if s.notify[w]:
            yield 'worker_notify', dataclasses.replace(s, notify=change_tuple(s.notify, w, False), efd=True)
        j = s.workers[w]
        if j != -1 and s.stages[j] == 'executed':
            departed = s.departed[j] | (1 << w)
            complete = departed == sum(1 << owner for owner in owners_of(scenario, j, mutant))
            yield 'worker_depart_complete' if complete else 'worker_depart', dataclasses.replace(
                s, workers=change_tuple(s.workers, w, -1),
                departed=change_tuple(s.departed, j, departed),
                stages=change_tuple(s.stages, j, 'completed') if complete else s.stages,
                completed=s.completed + (j,) if complete else s.completed,
                notify=change_tuple(s.notify, w, True) if complete and not s.completed else s.notify)
    for j in s.accepted:
        required = sum(1 << owner for owner in owners_of(scenario, j, mutant))
        if s.stages[j] == 'queued' and s.arrived[j] == required:
            cancelled = s.halted or (mutant == 'drop_disconnected_write' and not s.connected[j])
            yield 'worker_cancel_halted' if cancelled else 'worker_begin_mutation', dataclasses.replace(
                s, stages=change_tuple(s.stages, j, 'executed' if cancelled else 'mutating'),
                cancelled=change_tuple(s.cancelled, j, cancelled),
                failed=change_tuple(s.failed, j, cancelled),
                snapshots=change_tuple(s.snapshots, j, s.values))
        if s.stages[j] == 'mutating':
            step = s.steps[j]
            if step < len(p[j].records):
                r = p[j].records[step]
                values = s.values
                if p[j].writes:
                    values = change_tuple(values, r, values[r] * 10 + j + 1)
                yield 'worker_read_mutate_record', dataclasses.replace(
                    s, values=values, reads=change_tuple(s.reads, j, s.reads[j] + (s.values[r],)),
                    steps=change_tuple(s.steps, j, step + 1))
            elif p[j].abort:
                values = s.values
                for r in set(p[j].records):
                    values = change_tuple(values, r, s.snapshots[j][r])
                yield 'rollback_abort_halt', dataclasses.replace(
                    s, values=values, failed=change_tuple(s.failed, j, True), halted=True,
                    stages=change_tuple(s.stages, j, 'executed'))
            else:
                yield 'worker_commit', dataclasses.replace(s, stages=change_tuple(s.stages, j, 'executed'))
    if not blocked:
        if s.coordinator == 'sleep' and s.efd:
            yield 'coordinator_wake_notified', dataclasses.replace(s, coordinator='read', reported=True)
        if s.coordinator == 'read':
            if mutant == 'take_before_read':
                yield 'coordinator_poll', take_completions(s, 'take')
            else:
                yield read_notification(s, 'take')
        if s.coordinator == 'take':
            if mutant == 'take_before_read':
                yield read_notification(s, 'sleep')
            else:
                yield 'coordinator_poll', take_completions(s, 'sleep')
    candidates = s.staged if mutant == 'out_of_order_publish' else s.accepted[len(s.published):len(s.published) + 1]
    for j in candidates:
        if j not in s.staged or s.failed[j] and not s.fencing:
            continue
        if s.failed[j]:
            if mutant == 'drop_disconnected_write' and not s.connected[j]:
                values, observations = s.values, s.reads[j]
            else:
                values = s.values
                observations = []
                for r in p[j].records:
                    observations.append(values[r])
                    if p[j].writes:
                        values = change_tuple(values, r, values[r] * 10 + j + 1)
                observations = tuple(observations)
            yield 'coordinator_retry_publish', dataclasses.replace(
                s, values=values, reads=change_tuple(s.reads, j, observations),
                staged=tuple(k for k in s.staged if k != j), published=s.published + (j,),
                effects=s.effects + (j,), stages=change_tuple(s.stages, j, 'retried'),
                delivery=s.delivery + ((j, 'reply' if s.connected[j] else 'drop'),))
        else:
            yield 'coordinator_publish', dataclasses.replace(
                s, staged=tuple(k for k in s.staged if k != j), published=s.published + (j,),
                effects=s.effects + (j,), stages=change_tuple(s.stages, j, 'published'),
                delivery=s.delivery + ((j, 'reply' if s.connected[j] else 'drop'),))
    if s.replay and not s.fencing and not s.outstanding and all(w == -1 for w in s.workers):
        yield 'fence_import_then_replay', dataclasses.replace(s, fencing=True)
    if s.fencing and len(s.published) == len(s.accepted):
        yield 'fence_finish_resume', dataclasses.replace(s, fencing=False, halted=False, replay=False)
    if scenario.disconnect >= 0:
        j = scenario.disconnect
        if j in s.accepted and s.connected[j] and j not in s.published:
            yield 'disconnect_delivery_only', dataclasses.replace(s, connected=change_tuple(s.connected, j, False))
    if scenario.pause:
        if s.pause_phase == 0 and s.coordinator != 'take':
            waiting = 4 if mutant == 'pause_registers_after_check' and not quiescent(s) else 1
            yield 'pause_close_admission', dataclasses.replace(wake(s), pause_phase=waiting,
                                                               quiescent_wake=quiescent(s))
        if s.pause_phase == 4:
            yield 'pause_register_wait', dataclasses.replace(s, pause_phase=1)
        if s.pause_phase == 1 and s.quiescent_wake and quiescent(s):
            collected = take_completions(read_notification(s, s.coordinator)[1] if s.reported else s, s.coordinator)
            yield 'pause_quiescent', dataclasses.replace(collected, pause_phase=2, quiescent_wake=False)
        if s.pause_phase == 2 and s.coordinator != 'take' and not s.replay:
            yield 'resume', dataclasses.replace(wake(s), pause_phase=3, halted=False)
        elif s.pause_phase == 2 and s.coordinator != 'take' and len(s.published) == len(s.accepted):
            yield 'resume', dataclasses.replace(wake(s), pause_phase=3, halted=False, replay=False, fencing=False)


def check(scenario, s, edge=None, previous=None):
    active = [j for j, stage in enumerate(s.stages) if stage == 'mutating']
    for i, j in enumerate(active):
        for k in active[:i]:
            owners_j = {scenario.owners[r] for r in scenario.plans[j].records}
            owners_k = {scenario.owners[r] for r in scenario.plans[k].records}
            require(not owners_j.intersection(owners_k), INVARIANTS[0], f'jobs {j},{k} mutate shared owner')
            require(not set(scenario.plans[j].records).intersection(scenario.plans[k].records),
                    INVARIANTS[0], f'jobs {j},{k} mutate shared record')
    _, expected_reads = reference(scenario, s.accepted)
    for j in s.accepted:
        if s.cancelled[j] and s.stages[j] != 'retried':
            continue
        require(s.reads[j] == expected_reads[j][:len(s.reads[j])], INVARIANTS[1],
                f'job {j}: {s.reads[j]} != accepted history {expected_reads[j]}')
    expected = (0,) * len(scenario.owners)
    for j in s.accepted:
        stage = s.stages[j]
        if stage == 'mutating':
            expected = apply_plan(expected, scenario.plans[j], j, s.steps[j])
        elif stage in ('executed', 'completed', 'published') and not s.failed[j] or stage == 'retried':
            expected = apply_plan(expected, scenario.plans[j], j)
    require(s.values == expected, INVARIANTS[2], f'values {s.values} != history {expected}')
    require(s.published == s.accepted[:len(s.published)] and s.effects == s.published,
            INVARIANTS[3], f'publication {s.published}, accepted {s.accepted}, effects {s.effects}')
    require(len(set(s.effects)) == len(s.effects), INVARIANTS[6], 'duplicate effects')
    require(len(s.accepted) + len(s.rejected) == s.admission and set(s.accepted).isdisjoint(s.rejected),
            INVARIANTS[4], 'admission partition')
    if edge == 'reject':
        require(previous.accepted == s.accepted and previous.outstanding == s.outstanding and
                previous.queues == s.queues and previous.values == s.values and previous.parked == s.parked,
                INVARIANTS[4], 'rejected job changed sequence, resources, data or worker wakeups')
    for w in range(2):
        require(not s.parked[w] or not s.queues[w], INVARIANTS[8], f'worker {w} parked with queued jobs {s.queues[w]}')
    require(s.coordinator != 'sleep' or not s.completed or s.efd or any(s.notify), INVARIANTS[9],
            f'coordinator sleeps with completions {s.completed} and no pending notification')
    require(s.pause_phase != 1 or not quiescent(s) or s.quiescent_wake, INVARIANTS[10],
            'pause waits on a quiescent pool without a pending wakeup')
    if edge == 'disconnect_delivery_only':
        require(previous.values == s.values and previous.queues == s.queues and
                previous.outstanding == s.outstanding and previous.stages == s.stages,
                INVARIANTS[5], 'disconnect changed accepted work')
    if terminal(scenario, s):
        expected_final, _ = reference(scenario, s.accepted)
        require(s.values == expected_final, INVARIANTS[5], f'accepted final writes {s.values} != {expected_final}')


def plain(state):
    return dataclasses.asdict(state) if dataclasses.is_dataclass(state) else state


def canonical(value):
    return json.dumps(value, separators=(',', ':'), sort_keys=True)


def explore(start, transition, invariant, is_terminal, output, max_states=250000, timeout=90):
    deadline = time.monotonic() + timeout
    queue = deque([start])
    states = [start]
    indices = {start: 0}
    parents = [None]
    edges = []
    coverage = Counter()
    terminals = []
    checks = 0
    graph = []
    invariant(start)
    while queue:
        if time.monotonic() > deadline:
            raise RuntimeError('exploration deadline exceeded; exhaustive success refused')
        s = queue.popleft()
        sid = indices[s]
        successors_list = list(transition(s))
        if not successors_list:
            require(is_terminal(s), INVARIANTS[7], f'state {sid} has unfinished work and no transitions')
            terminals.append(sid)
        elif all(t == s for _, t in successors_list):
            raise Violation(INVARIANTS[7], f'state {sid} has only environment stuttering')
        nonstutter = []
        for label, t in successors_list:
            coverage[label] += 1
            checks += 1
            try:
                invariant(t, label, s)
            except Violation as error:
                trace = [{'transition': label, 'state': plain(t)}]
                cursor = sid
                while cursor is not None:
                    parent = parents[cursor]
                    trace.append({'state_id': cursor, 'transition': parent[1] if parent else 'initial',
                                  'state': plain(states[cursor])})
                    cursor = parent[0] if parent else None
                trace.reverse()
                witness = {'invariant': error.invariant, 'detail': error.detail, 'trace': trace,
                           'states_before_failure': len(states), 'edges_before_failure': len(edges)}
                output.write_text(json.dumps(witness, indent=2) + '\n')
                return {'rejected': True, 'witness': output.name, 'invariant': error.invariant,
                        'witness_sha256': hashlib.sha256(output.read_bytes()).hexdigest()}
            if t not in indices:
                if len(states) >= max_states:
                    raise RuntimeError('state cap exceeded; exhaustive success refused')
                indices[t] = len(states)
                states.append(t)
                parents.append((sid, label))
                queue.append(t)
            tid = indices[t]
            edges.append((sid, label, tid))
            if s != t:
                nonstutter.append(tid)
        graph.append(nonstutter)
    indegree = [0] * len(states)
    for outgoing in graph:
        for target in outgoing:
            indegree[target] += 1
    ready = deque(i for i, count in enumerate(indegree) if not count)
    visited = 0
    while ready:
        source = ready.popleft()
        visited += 1
        for target in graph[source]:
            indegree[target] -= 1
            if not indegree[target]:
                ready.append(target)
    require(visited == len(states), INVARIANTS[7], 'nonstuttering cycle requires separate liveness analysis')
    artifact = {'states': [plain(s) for s in states], 'edges': edges, 'terminal_ids': terminals}
    payload = (canonical(artifact) + '\n').encode()
    output.write_bytes(gzip.compress(payload, mtime=0))
    return {'states': len(states), 'edges': len(edges), 'terminals': len(terminals),
            'transition_coverage': dict(sorted(coverage.items())), 'invariant_edge_checks': checks,
            'exhausted': True, 'nonstuttering_graph_acyclic': True,
            'stuttering_edges': coverage['environment_yield'], 'product_deadlocks': 0,
            'graph': output.name, 'graph_sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
            'relation_sha256': hashlib.sha256(payload).hexdigest()}


def scenarios():
    return (
        Scenario('opposite_owners_aliases', (0, 1), (
            Plan('write_a', (0,)), Plan('reverse_alias', (1, 0, 1)), Plan('read_alias', (0, 1, 0), False))),
        Scenario('independent_completion_order', (0, 1, 0), (
            Plan('write_a', (0,)), Plan('write_b', (1,)), Plan('same_owner_read_c_a', (2, 0), False))),
        Scenario('abort_retry_disconnect', (0, 1), (
            Plan('rollback_alias', (0, 1, 0), abort=True), Plan('dependent_write', (1,)),
            Plan('dependent_read', (0, 1), False)), disconnect=0),
        Scenario('independent_abort', (0, 1), (
            Plan('rollback_a', (0,), abort=True), Plan('write_b', (1,)), Plan('read_b_a', (1, 0), False))),
        Scenario('rejected_admission', (0, 1), (
            Plan('invalid', (0,), reject=True), Plan('accepted', (1,)), Plan('capacity_reject', (0,))), capacity=1),
        Scenario('pause_resume_disconnect', (0, 1), (
            Plan('write_a', (0,)), Plan('alias_write', (1, 0, 1)), Plan('read', (1,), False)),
                 disconnect=1, pause=True),
    )


def engine_control(output):
    def moves(state):
        for bit in range(4):
            if not state & (1 << bit):
                yield 'set_bit', state | (1 << bit)
    result = explore(0, moves, lambda *args: None, lambda s: s == 15, output / 'engine-control.json.gz')
    if (result['states'], result['edges'], result['terminals']) != (16, 32, 1):
        raise AssertionError('independent hypercube count failed')
    with gzip.open(output / result['graph'], 'rt') as handle:
        graph = json.load(handle)
    expected_edges = {(s, 'set_bit', s | (1 << b)) for s in range(16) for b in range(4) if not s & (1 << b)}
    observed = {(graph['states'][a], label, graph['states'][b]) for a, label, b in graph['edges']}
    if set(graph['states']) != set(range(16)) or observed != expected_edges:
        raise AssertionError('engine independently enumerated relation mismatch')
    try:
        explore(0, moves, lambda *args: None, lambda s: s == 15, output / 'cap-must-fail.json.gz', max_states=5)
    except RuntimeError:
        result['cap_control_rejected'] = True
    else:
        raise AssertionError('exploration cap silently succeeded')
    return result


def run(output):
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    results = {}
    for scenario in scenarios():
        result = explore(initial(scenario), lambda s: successors(scenario, s),
                         lambda s, edge=None, previous=None: check(scenario, s, edge, previous),
                         lambda s: terminal(scenario, s), output / (scenario.name + '.json.gz'))
        if result.get('rejected'):
            raise AssertionError('positive model rejected: ' + str(result))
        result['bounds'] = dataclasses.asdict(scenario)
        results[scenario.name] = result
    mutants = {}
    for mutant, scenario in (
            ('bypass_ownership', scenarios()[0]),
            ('out_of_order_publish', scenarios()[1]),
            ('drop_disconnected_write', scenarios()[2]),
            ('park_outside_mutex', scenarios()[0]),
            ('take_before_read', scenarios()[1]),
            ('pause_registers_after_check', scenarios()[5])):
        result = explore(initial(scenario), lambda s: successors(scenario, s, mutant),
                         lambda s, edge=None, previous=None: check(scenario, s, edge, previous),
                         lambda s: terminal(scenario, s), output / (mutant + '-witness.json'))
        if not result.get('rejected'):
            raise AssertionError('mutant survived: ' + mutant)
        witness_path = output / result['witness']
        witness = json.loads(witness_path.read_text())
        witness.update(scenario=scenario.name, mutant=mutant)
        witness_path.write_text(json.dumps(witness, indent=2) + '\n')
        result['witness_sha256'] = hashlib.sha256(witness_path.read_bytes()).hexdigest()
        mutants[mutant] = result
    return {'scenarios': results, 'mutants': mutants, 'engine_control': engine_control(output),
            'states': sum(r['states'] for r in results.values()),
            'edges': sum(r['edges'] for r in results.values()),
            'terminals': sum(r['terminals'] for r in results.values()),
            'invariants': list(INVARIANTS), 'exhausted': True}


def tuple_tree(value):
    return tuple(tuple_tree(x) for x in value) if isinstance(value, list) else value


def replay(path):
    witness = json.loads(Path(path).read_text())
    scenario = next(s for s in scenarios() if s.name == witness['scenario'])
    trace = witness['trace']
    previous = initial(scenario)
    if State(**{k: tuple_tree(v) for k, v in trace[0]['state'].items()}) != previous:
        raise AssertionError('witness does not start at the declared initial state')
    for index, item in enumerate(trace[1:], 1):
        state = State(**{k: tuple_tree(v) for k, v in item['state'].items()})
        if (item['transition'], state) not in list(successors(scenario, previous, witness['mutant'])):
            raise AssertionError('witness contains an impossible transition')
        try:
            check(scenario, state, item['transition'], previous)
        except Violation as error:
            if index != len(trace) - 1 or error.invariant != witness['invariant']:
                raise AssertionError('witness fails at a different invariant or step')
            return {'replayed': True, 'transitions': index, 'invariant': error.invariant}
        previous = state
    raise AssertionError('witness did not reproduce a violation')


def audit_graph(scenario, path):
    with gzip.open(path, 'rt', encoding='utf-8') as handle:
        artifact = json.load(handle)
    states = [State(**{k: tuple_tree(v) for k, v in item.items()}) for item in artifact['states']]
    indices = {state: index for index, state in enumerate(states)}
    if len(indices) != len(states) or states[0] != initial(scenario):
        raise AssertionError('graph state inventory is not unique or has wrong root')
    actual = set()
    reached = {0}
    outgoing = {}
    for a, label, b in artifact['edges']:
        actual.add((a, label, b))
        outgoing.setdefault(a, set()).add(b)
    expected = set()
    for index, state in enumerate(states):
        check(scenario, state)
        for label, target in successors(scenario, state):
            if target not in indices:
                raise AssertionError('saved graph omitted a reachable successor')
            check(scenario, target, label, state)
            expected.add((index, label, indices[target]))
    if actual != expected or len(actual) != len(artifact['edges']):
        raise AssertionError('saved edge relation is incomplete or duplicated')
    todo = [0]
    while todo:
        for target in outgoing.get(todo.pop(), ()):
            if target not in reached:
                reached.add(target)
                todo.append(target)
    if len(reached) != len(states):
        raise AssertionError('graph contains unreachable padding')
    terminals = [i for i, state in enumerate(states) if terminal(scenario, state)]
    if terminals != artifact['terminal_ids']:
        raise AssertionError('terminal inventory differs')
    return {'passed': True, 'states': len(states), 'edges': len(expected), 'terminals': len(terminals)}
