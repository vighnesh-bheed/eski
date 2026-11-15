import collections
import dataclasses
import itertools
import json
import time


INVARIANTS = ['no_change_or_free_of_a_set_while_a_job_that_pinned_it_reads',
              'a_job_reads_the_set_as_it_was_when_the_job_was_admitted',
              'no_job_reads_a_freed_set',
              'a_withdrawn_job_is_never_run_by_a_worker',
              'cancelled_or_forgotten_work_publishes_nothing',
              'a_fork_snapshot_has_no_reading_job',
              'every_pin_is_released_when_the_work_is_done',
              'a_reply_shows_the_set_as_it_was_when_the_job_was_admitted']

UNSUBMITTED, QUEUED, RUNNING, DONE, WITHDRAWN, RETIRED = range(6)


@dataclasses.dataclass(frozen=True)
class State:
    jobs: tuple
    queue: tuple
    cancelled: tuple
    answered: tuple
    admitted_at: tuple
    released: tuple
    formatted: tuple
    versions: tuple
    freed: tuple
    writers: tuple
    coordinator: tuple = ('idle',)
    events: tuple = ()
    violations: frozenset = frozenset()


@dataclasses.dataclass(frozen=True)
class Scenario:
    workers: int
    job_sets: tuple
    job_owners: tuple
    writers: tuple
    events: tuple
    sets: int


def change(items, index, value):
    return items[:index] + (value,) + items[index + 1:]


def initial(scenario):
    j = len(scenario.job_sets)
    return State(jobs=(UNSUBMITTED,) * j, queue=(), cancelled=(False,) * j, answered=(False,) * j,
                 admitted_at=(-1,) * j, released=(False,) * j, formatted=(False,) * j, versions=(0,) * scenario.sets,
                 freed=(False,) * scenario.sets, writers=(0,) * len(scenario.writers))


def targets(scenario, writer):
    kind = scenario.writers[writer][0]
    if kind == 'flush':
        return tuple(range(scenario.sets))
    return (scenario.writers[writer][1],)


def pinning(s, scenario, sets):
    return [j for j, stage in enumerate(s.jobs) if scenario.job_sets[j] in sets and stage in (QUEUED, RUNNING, DONE)
            and not s.released[j]]


def write_reply(s, scenario, j, violations):
    k = scenario.job_sets[j]
    if s.freed[k] or s.versions[k] != s.admitted_at[j]:
        violations.add('a_reply_shows_the_set_as_it_was_when_the_job_was_admitted')
    return change(s.formatted, j, True)


def apply_writer(s, scenario, writer, mutant):
    kind = scenario.writers[writer][0]
    sets = targets(scenario, writer)
    violations = set(s.violations)
    reading = [j for j, stage in enumerate(s.jobs) if scenario.job_sets[j] in sets and stage in (QUEUED, RUNNING)]
    if reading:
        violations.add('no_change_or_free_of_a_set_while_a_job_that_pinned_it_reads')
    versions = s.versions
    freed = s.freed
    for k in sets:
        if kind == 'mutate':
            versions = change(versions, k, versions[k] + 1)
        else:
            freed = change(freed, k, True)
    return dataclasses.replace(s, versions=versions, freed=freed, writers=change(s.writers, writer, 2),
                               coordinator=('idle',), violations=frozenset(violations))


def steps(s, scenario, mutant=''):
    result = []

    def add(name, state):
        result.append((name, state))

    busy = sum(1 for stage in s.jobs if stage == RUNNING)
    if s.queue and busy < scenario.workers:
        j = s.queue[0]
        k = scenario.job_sets[j]
        violations = set(s.violations)
        if s.jobs[j] == WITHDRAWN:
            violations.add('a_withdrawn_job_is_never_run_by_a_worker')
        if s.cancelled[j]:
            add('worker_skips_cancelled_job', dataclasses.replace(
                s, queue=s.queue[1:], jobs=change(s.jobs, j, DONE),
                released=change(s.released, j, mutant != 'pin_released_by_procedure'),
                violations=frozenset(violations)))
        else:
            if s.freed[k]:
                violations.add('no_job_reads_a_freed_set')
            if s.versions[k] != s.admitted_at[j]:
                violations.add('a_job_reads_the_set_as_it_was_when_the_job_was_admitted')
            add('worker_begins_search', dataclasses.replace(s, queue=s.queue[1:], jobs=change(s.jobs, j, RUNNING),
                                                            violations=frozenset(violations)))
    for j, stage in enumerate(s.jobs):
        if stage == RUNNING:
            add('worker_completes_and_keeps_the_pin_for_the_reply', dataclasses.replace(
                s, jobs=change(s.jobs, j, DONE), released=change(s.released, j, s.released[j] or mutant == 'pin_released_at_completion')))
    mode = s.coordinator[0]
    if mode == 'idle':
        for j, stage in enumerate(s.jobs):
            k = scenario.job_sets[j]
            if stage == UNSUBMITTED:
                if s.freed[k]:
                    add('missing_set_answers_inline', dataclasses.replace(s, jobs=change(s.jobs, j, RETIRED), released=change(s.released, j, True)))
                else:
                    pinned = mutant != 'pin_not_counted'
                    add('submit_pins_and_queues', dataclasses.replace(
                        s, jobs=change(s.jobs, j, QUEUED), queue=s.queue + (j,),
                        admitted_at=change(s.admitted_at, j, s.versions[k]),
                        released=change(s.released, j, not pinned)))
                    add('full_pool_searches_on_the_coordinator_and_pins_for_the_reply', dataclasses.replace(
                        s, jobs=change(s.jobs, j, DONE), admitted_at=change(s.admitted_at, j, s.versions[k]),
                        released=change(s.released, j, mutant == 'coordinated_without_pin')))
            if stage in (DONE, WITHDRAWN):
                violations = set(s.violations)
                answered = stage == DONE or s.answered[j]
                formatted = s.formatted
                if s.cancelled[j]:
                    name = 'tick_drops_cancelled_job'
                    if mutant == 'publish_cancelled':
                        violations.add('cancelled_or_forgotten_work_publishes_nothing')
                        name = 'mutant_tick_publishes_cancelled_job'
                elif answered:
                    name = 'tick_publishes_and_unpins'
                    if not s.formatted[j]:
                        formatted = write_reply(s, scenario, j, violations)
                else:
                    name = 'tick_drops_unanswered_job'
                add(name, dataclasses.replace(s, jobs=change(s.jobs, j, RETIRED), released=change(s.released, j, True),
                                              formatted=formatted, violations=frozenset(violations)))
        for w, status in enumerate(s.writers):
            if status == 0:
                if mutant == 'writer_skips_quiesce':
                    add('mutant_writer_changes_without_quiesce', apply_writer(s, scenario, w, mutant))
                else:
                    add('writer_hook_quiesces', dataclasses.replace(s, writers=change(s.writers, w, 1),
                                                                    coordinator=('quiesce', w)))
        for event in scenario.events:
            if event in s.events:
                continue
            if event == 'close':
                add('client_close_cancels', dataclasses.replace(s, cancelled=change(s.cancelled, 0, True),
                                                                events=s.events + (event,)))
            elif event == 'forget':
                cancelled = tuple(c or scenario.job_owners[j] == 1 for j, c in enumerate(s.cancelled))
                add('forget_closes_owner_connections', dataclasses.replace(s, cancelled=cancelled,
                                                                           events=s.events + (event,)))
            elif event == 'fork':
                if mutant == 'fork_without_join':
                    add('mutant_fork_snapshot_now', fork_snapshot(s, event))
                else:
                    add('fork_stops_and_joins_pool', dataclasses.replace(s, coordinator=('fork',)))
    elif mode == 'quiesce':
        w = s.coordinator[1]
        sets = targets(scenario, w)
        held = pinning(s, scenario, sets)
        queued = [j for j in held if s.jobs[j] == QUEUED]
        finished = [j for j in held if s.jobs[j] == DONE]
        if mutant == 'pin_released_by_procedure':
            held = [j for j, stage in enumerate(s.jobs) if scenario.job_sets[j] in sets
                    and stage in (QUEUED, RUNNING, DONE) and not s.released[j]]
            if not held:
                add('writer_changes_after_release', apply_writer(s, scenario, w, mutant))
        elif queued:
            j = queued[0]
            k = scenario.job_sets[j]
            violations = set(s.violations)
            live = not s.cancelled[j]
            if live and s.versions[k] != s.admitted_at[j]:
                violations.add('a_job_reads_the_set_as_it_was_when_the_job_was_admitted')
            formatted = write_reply(s, scenario, j, violations) if live else s.formatted
            add('quiesce_withdraws_queued_job_and_answers_inline' if live else 'quiesce_withdraws_cancelled_job',
                dataclasses.replace(s, jobs=change(s.jobs, j, WITHDRAWN), queue=tuple(x for x in s.queue if x != j),
                                    answered=change(s.answered, j, live), released=change(s.released, j, True),
                                    formatted=formatted, violations=frozenset(violations)))
        elif finished:
            j = finished[0]
            violations = set(s.violations)
            live = not s.cancelled[j]
            formatted = write_reply(s, scenario, j, violations) if live and not s.formatted[j] else s.formatted
            add('quiesce_writes_the_reply_of_a_finished_search' if live else 'quiesce_unpins_a_cancelled_finished_job',
                dataclasses.replace(s, released=change(s.released, j, True), formatted=formatted,
                                    violations=frozenset(violations)))
        elif not held:
            add('writer_changes_after_pins_release', apply_writer(s, scenario, w, mutant))
    elif mode == 'fork':
        if not any(stage in (QUEUED, RUNNING) for stage in s.jobs):
            add('fork_snapshot_after_join', fork_snapshot(s, 'fork'))
    return result


def fork_snapshot(s, event):
    violations = set(s.violations)
    if any(stage in (QUEUED, RUNNING) for stage in s.jobs):
        violations.add('a_fork_snapshot_has_no_reading_job')
    return dataclasses.replace(s, coordinator=('idle',), events=s.events + (event,), violations=frozenset(violations))


def terminal(s, scenario):
    return (all(stage == RETIRED for stage in s.jobs) and all(w == 2 for w in s.writers)
            and len(s.events) == len(scenario.events) and s.coordinator == ('idle',))


def invariants(s, scenario):
    failures = sorted(s.violations)
    for j, stage in enumerate(s.jobs):
        if stage == WITHDRAWN and j in s.queue:
            failures.append('a_withdrawn_job_is_never_run_by_a_worker')
    if terminal(s, scenario) and not all(s.released):
        failures.append('every_pin_is_released_when_the_work_is_done')
    return sorted(set(failures))


def as_json(state):
    return json.loads(json.dumps(dataclasses.asdict(state), default=sorted))


def explore(scenario, mutant='', state_cap=400000, seconds=60):
    started = time.monotonic()
    start = initial(scenario)
    predecessor = {start: None}
    queue = collections.deque([start])
    reverse = collections.defaultdict(set)
    forward = collections.defaultdict(set)
    coverage = collections.Counter()
    checked = collections.Counter()
    waiting = collections.Counter()
    terminals = set()
    edges = 0

    def witness(state, failures):
        trace = []
        while predecessor[state] is not None:
            previous, action = predecessor[state]
            trace.append({'action': action, 'state': as_json(state)})
            state = previous
        return {'violations': failures, 'initial': as_json(start), 'trace': list(reversed(trace)),
                'scenario': dataclasses.asdict(scenario), 'mutant': mutant}

    while queue:
        if len(predecessor) > state_cap or time.monotonic() - started > seconds:
            raise AssertionError('finite exploration cap reached; exhaustive success forbidden')
        state = queue.popleft()
        failures = invariants(state, scenario)
        if failures:
            return {'exhausted': False, 'states': len(predecessor), 'edges': edges, 'counterexample': witness(state, failures)}
        checked.update(INVARIANTS)
        successors = steps(state, scenario, mutant)
        if terminal(state, scenario):
            terminals.add(state)
        if not successors and not terminal(state, scenario):
            return {'exhausted': False, 'states': len(predecessor), 'edges': edges,
                    'counterexample': witness(state, ['deadlock: a writer or the pool can never proceed'])}
        if state.coordinator[0] in ('quiesce', 'fork') and not any(name.startswith(('quiesce', 'writer', 'fork')) for name, _ in successors):
            waiting['coordinator_waits_on_the_pool'] += 1
        for action, successor in successors:
            edges += 1
            coverage[action] += 1
            reverse[successor].add(state)
            forward[state].add(successor)
            if successor not in predecessor:
                predecessor[successor] = (state, action)
                queue.append(successor)
    reachable = set(terminals)
    pending = collections.deque(terminals)
    while pending:
        for previous in reverse[pending.popleft()]:
            if previous not in reachable:
                reachable.add(previous)
                pending.append(previous)
    if len(reachable) != len(predecessor):
        stuck = next(state for state in predecessor if state not in reachable)
        return {'exhausted': False, 'states': len(predecessor), 'edges': edges,
                'counterexample': witness(stuck, ['no completion path'])}
    indegree = {state: len(reverse[state]) for state in predecessor}
    ready = collections.deque(state for state, degree in indegree.items() if degree == 0)
    ordered = 0
    while ready:
        state = ready.popleft()
        ordered += 1
        for successor in forward[state]:
            indegree[successor] -= 1
            if indegree[successor] == 0:
                ready.append(successor)
    if ordered != len(predecessor):
        raise AssertionError('progress graph contains a cycle requiring additional fairness analysis')
    return {'exhausted': True, 'states': len(predecessor), 'edges': edges, 'terminals': len(terminals),
            'transition_coverage': dict(coverage), 'invariant_coverage': dict(checked),
            'intentional_wait_states': dict(waiting), 'nonterminal_deadlocks': 0, 'progress_cycles': 0,
            'states_with_completion_path': len(reachable)}


def scenarios():
    writer_sets = [
        (('mutate', 0),),
        (('free', 0),),
        (('mutate', 0), ('free', 1)),
        (('flush',),),
        (('mutate', 1), ('mutate', 0)),
    ]
    event_sets = [(), ('close',), ('forget',), ('fork',), ('close', 'forget'), ('close', 'fork')]
    for workers in (1, 2):
        for jobs in (1, 2, 3):
            job_sets = tuple(j % 2 for j in range(jobs))
            job_owners = tuple(j % 2 for j in range(jobs))
            for writers in writer_sets:
                for events in event_sets:
                    yield Scenario(workers=workers, job_sets=job_sets, job_owners=job_owners, writers=writers,
                                   events=events, sets=2)


def replay(scenario, mutant, witness):
    current = initial(scenario)
    for item in witness['trace']:
        choices = [state for action, state in steps(current, scenario, mutant)
                   if action == item['action'] and as_json(state) == item['state']]
        if len(choices) != 1:
            raise AssertionError('counterexample replay is ambiguous or invalid')
        current = choices[0]
    return current


MUTANTS = {
    'writer_skips_quiesce': ('no_change_or_free_of_a_set_while_a_job_that_pinned_it_reads',
                             'a_job_reads_the_set_as_it_was_when_the_job_was_admitted', 'no_job_reads_a_freed_set'),
    'pin_released_by_procedure': ('deadlock: a writer or the pool can never proceed', 'no completion path'),
    'pin_not_counted': ('no_change_or_free_of_a_set_while_a_job_that_pinned_it_reads',
                        'a_job_reads_the_set_as_it_was_when_the_job_was_admitted', 'no_job_reads_a_freed_set'),
    'publish_cancelled': ('cancelled_or_forgotten_work_publishes_nothing',),
    'fork_without_join': ('a_fork_snapshot_has_no_reading_job',),
    'pin_released_at_completion': ('a_reply_shows_the_set_as_it_was_when_the_job_was_admitted',),
    'coordinated_without_pin': ('a_reply_shows_the_set_as_it_was_when_the_job_was_admitted',),
}


def verify_models():
    results = []
    for scenario in scenarios():
        result = explore(scenario)
        if not result['exhausted']:
            raise AssertionError(json.dumps(result['counterexample'])[:4000])
        results.append({'scenario': dataclasses.asdict(scenario), **result})
    mutants = {}
    for name, expected in MUTANTS.items():
        found = None
        for scenario in scenarios():
            result = explore(scenario, name)
            if 'counterexample' in result:
                found = result['counterexample']
                break
        if found is None:
            raise AssertionError('meaningful mutant survived: ' + name)
        if not set(found['violations']) & set(expected):
            raise AssertionError('mutant %s failed for an unexpected reason: %r' % (name, found['violations']))
        scenario = Scenario(**{k: tuple(tuple(x) if isinstance(x, list) else x for x in v) if isinstance(v, list) else v
                               for k, v in found['scenario'].items()})
        final = replay(scenario, name, found)
        if found['violations'][0].startswith(('deadlock', 'no completion')):
            if steps(final, scenario, name) and found['violations'][0].startswith('deadlock'):
                raise AssertionError('deadlock witness of %s still has successors' % name)
        elif not invariants(final, scenario):
            raise AssertionError('counterexample of %s does not violate an invariant on replay' % name)
        mutants[name] = {'rejected': True, 'replayed': True, **found}
    coverage = collections.Counter()
    checked = collections.Counter()
    for r in results:
        coverage.update(r['transition_coverage'])
        checked.update(r['invariant_coverage'])
    required = {'worker_begins_search', 'worker_completes_and_keeps_the_pin_for_the_reply', 'worker_skips_cancelled_job',
                'submit_pins_and_queues', 'missing_set_answers_inline', 'tick_publishes_and_unpins',
                'full_pool_searches_on_the_coordinator_and_pins_for_the_reply', 'quiesce_writes_the_reply_of_a_finished_search',
                'quiesce_unpins_a_cancelled_finished_job',
                'tick_drops_cancelled_job', 'writer_hook_quiesces', 'quiesce_withdraws_queued_job_and_answers_inline',
                'quiesce_withdraws_cancelled_job', 'writer_changes_after_pins_release', 'client_close_cancels',
                'forget_closes_owner_connections', 'fork_stops_and_joins_pool', 'fork_snapshot_after_join'}
    missing = required - coverage.keys()
    if missing:
        raise AssertionError('uncovered pin transitions: ' + ', '.join(sorted(missing)))
    return {'bounds': {'workers': [1, 2], 'jobs': [1, 2, 3], 'sets': 2, 'owners': 2,
                       'writer_programs': 5, 'event_programs': 6, 'state_cap_per_scenario': 400000,
                       'seconds_cap_per_scenario': 60},
            'exhausted': True, 'scenarios': results, 'scenario_count': len(results),
            'states': sum(r['states'] for r in results), 'edges': sum(r['edges'] for r in results),
            'transition_coverage': dict(coverage), 'invariant_coverage': dict(checked),
            'rejected_mutants': mutants,
            'liveness': 'Every reachable state has a terminal path and the progress graph is acyclic. Completion assumes fair worker steps and searches that terminate; the coordinator waits only on the pool and runs no other command while it waits.',
            'ordering': 'Sequentially consistent abstract steps; the pool mutex publishes queue and state changes and the release store of the completed state ends a pin. No weak-memory or machine-code race proof.'}


if __name__ == '__main__':
    summary = verify_models()
    print(json.dumps({k: summary[k] for k in ('scenario_count', 'states', 'edges')}))
    print(sorted(summary['rejected_mutants']))
