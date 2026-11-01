import collections
import dataclasses
import json
import time


POOL_INVARIANTS = ['callback_lifetime_requires_join_not_park', 'no_fork_snapshot_with_live_worker_owners',
                   'accepted_mutations_and_effects_reconciled_before_snapshot',
                   'snapshot_contains_all_accepted_mutations', 'ordinary_libc_fork_runs_registered_hooks',
                   'child_resets_tid_queues_and_dead_thread_handles',
                   'parent_and_child_restore_exact_saved_signal_mask', 'parent_resumes_with_its_own_resources',
                   'shutdown_reconciles_accepted_work_before_free']
LEGACY_INVARIANTS = ['no_queued_or_active_callback_after_logger_teardown',
                     'all_accepted_legacy_effects_complete_before_teardown']


@dataclasses.dataclass(frozen=True)
class PoolState:
    phase: str
    workers: tuple
    jobs: tuple
    disconnected: int = 0
    resource: bool = True
    parent_mask: int = 0
    child_mask: int = -1
    child_reset: bool = False
    child_tid: bool = False
    child_handles: bool = True
    atfork: bool = False
    snapshot: int = -1
    parent_resumed: bool = False


@dataclasses.dataclass(frozen=True)
class LegacyState:
    phase: str = 'open'
    jobs: tuple = (0, 0)
    resource: bool = True
    logged: int = 0
    completed: int = 0


def change_tuple(items, index, value):
    return items[:index] + (value,) + items[index + 1:]


def pool_steps(state, scenario, mutant):
    s = state
    workers, job_bound, mode, saved = scenario
    result = []

    def add(name, **updates):
        result.append((name, dataclasses.replace(s, **updates)))

    if s.phase == 'open':
        for j in range(job_bound):
            if s.jobs[j] == 0:
                add('accept_mutation', jobs=change_tuple(s.jobs, j, 1))
        add('close_admission', phase='pausing')
    for j, stage in enumerate(s.jobs):
        owner = j % workers
        if stage > 0 and not s.disconnected & (1 << j):
            add('disconnect_keeps_accepted_work', disconnected=s.disconnected | (1 << j))
        if stage == 1 and s.workers[owner] in ('idle', 'parked'):
            add('worker_begin', jobs=change_tuple(s.jobs, j, 2),
                workers=change_tuple(s.workers, owner, 'running'))
        if stage == 2:
            add('worker_complete', jobs=change_tuple(s.jobs, j, 3),
                workers=change_tuple(s.workers, owner, 'idle'))
        if stage == 3 and s.phase in ('fenced', 'stopping', 'joined'):
            add('coordinator_reconcile', jobs=change_tuple(s.jobs, j, 4))
        if stage == 4 and s.phase in ('fenced', 'stopping', 'joined'):
            add('publish_effects', jobs=change_tuple(s.jobs, j, 5))
    for worker, status in enumerate(s.workers):
        if status == 'idle' and s.phase == 'pausing' and not any(stage in (1, 2) and j % workers == worker
                                         for j, stage in enumerate(s.jobs)):
            add('worker_park', workers=change_tuple(s.workers, worker, 'parked'))
        if status == 'parked' and s.phase == 'stopping':
            add('worker_leave_callback', workers=change_tuple(s.workers, worker, 'exited'))
        if status == 'exited':
            add('actual_thread_join', workers=change_tuple(s.workers, worker, 'joined'))
    if s.phase == 'pausing' and all(w == 'parked' for w in s.workers):
        add('pause_returns', phase='fenced')
        if mutant == 'free_on_park':
            add('mutant_free_on_park', resource=False)
    reconciled = all(stage in (0, 5) for stage in s.jobs)
    joined = all(w == 'joined' for w in s.workers)
    if s.phase == 'fenced' and (reconciled or mutant == 'fork_before_reconcile'):
        add('stop_wake', phase='stopping')
    if s.phase == 'stopping' and joined:
        add('stop_returns_after_join', phase='joined')
    if s.phase == 'joined' or mutant == 'fork_before_join' and s.phase == 'fenced' and reconciled:
        if mode == 'shutdown':
            add('free_callback_resources', phase='done', resource=False)
        else:
            add('block_alarm_save_exact_mask', phase='masked', parent_mask=saved | 1)
    if s.phase == 'masked':
        accepted = sum(1 << j for j, stage in enumerate(s.jobs) if stage)
        if mode == 'fork_failure':
            add('libc_fork_error_restore', phase='done', parent_mask=saved)
        else:
            add('libc_fork_snapshot', phase='forked', child_mask=s.parent_mask,
                snapshot=accepted, atfork=mutant != 'raw_clone')
    if s.phase == 'forked':
        add('child_reset_dead_thread_state', phase='child_reset',
            child_reset=mutant != 'child_wrong_state', child_tid=mutant != 'child_wrong_state',
            child_handles=mutant == 'child_wrong_state')
    if s.phase == 'child_reset':
        add('restore_parent_and_child_masks', phase='restored', parent_mask=saved,
            child_mask=saved | 1 if mutant == 'child_wrong_mask' else saved)
    if s.phase == 'restored':
        add('parent_resume', phase='done', parent_resumed=True)
    return result


def pool_invariants(s, scenario):
    workers, jobs, mode, saved = scenario
    failures = []
    if not s.resource and any(w != 'joined' for w in s.workers):
        failures.append('callback_lifetime_requires_join_not_park')
    if s.phase in ('masked', 'forked', 'child_reset', 'restored') or s.snapshot >= 0:
        if any(w != 'joined' for w in s.workers):
            failures.append('no_fork_snapshot_with_live_worker_owners')
        if any(stage not in (0, 5) for stage in s.jobs):
            failures.append('accepted_mutations_and_effects_reconciled_before_snapshot')
    if s.snapshot >= 0:
        expected = sum(1 << j for j, stage in enumerate(s.jobs) if stage)
        if s.snapshot != expected:
            failures.append('snapshot_contains_all_accepted_mutations')
        if not s.atfork:
            failures.append('ordinary_libc_fork_runs_registered_hooks')
    if s.phase in ('child_reset', 'restored', 'done') and s.snapshot >= 0:
        if not s.child_reset or not s.child_tid or s.child_handles:
            failures.append('child_resets_tid_queues_and_dead_thread_handles')
    if s.phase in ('restored', 'done'):
        if s.parent_mask != saved or s.snapshot >= 0 and s.child_mask != saved:
            failures.append('parent_and_child_restore_exact_saved_signal_mask')
    if s.phase == 'done' and mode == 'fork' and not s.parent_resumed:
        failures.append('parent_resumes_with_its_own_resources')
    if s.phase == 'done' and mode == 'shutdown' and (s.resource or any(stage not in (0, 5) for stage in s.jobs)):
        failures.append('shutdown_reconciles_accepted_work_before_free')
    return failures


def legacy_steps(s, scenario, mutant):
    result = []

    def add(name, **updates):
        result.append((name, dataclasses.replace(s, **updates)))

    for j, stage in enumerate(s.jobs):
        if s.phase == 'open' and stage == 0:
            add(('lazyfree' if j == 0 else 'bio') + '_accept', jobs=change_tuple(s.jobs, j, 1))
        if stage == 1:
            add('dequeue_to_active', jobs=change_tuple(s.jobs, j, 2))
        if stage == 2 and not s.logged & 1 << j:
            add('callback_logging_and_effects', logged=s.logged | 1 << j)
        if stage == 2 and s.logged & 1 << j:
            add('release_completion_decrement', jobs=change_tuple(s.jobs, j, 3),
                completed=s.completed | 1 << j)
    if s.phase == 'open':
        add('shutdown_closes_producers', phase='draining')
    if s.phase == 'draining':
        pending = any(stage in (1, 2) for stage in s.jobs)
        if mutant == 'ignore_active':
            pending = any(stage == 1 for stage in s.jobs)
        if not pending:
            add('acquire_drain_before_logger_teardown', phase='closed', resource=False)
    return result


def legacy_invariants(s, scenario):
    failures = []
    if not s.resource and any(stage in (1, 2) for stage in s.jobs):
        failures.append('no_queued_or_active_callback_after_logger_teardown')
    if s.phase == 'closed':
        accepted = sum(1 << j for j, stage in enumerate(s.jobs) if stage)
        if accepted != s.completed:
            failures.append('all_accepted_legacy_effects_complete_before_teardown')
    return failures


def explore(initial, scenario, steps, invariants, terminal, mutant='', state_cap=200000, seconds=30):
    started = time.monotonic()
    predecessor = {initial: None}
    queue = collections.deque([initial])
    reverse = collections.defaultdict(set)
    forward = collections.defaultdict(set)
    coverage = collections.Counter()
    checked = collections.Counter()
    terminals = set()
    waiting = collections.Counter()
    edges = 0

    def witness(state, failures):
        trace = []
        while predecessor[state] is not None:
            previous, action = predecessor[state]
            trace.append({'action': action, 'state': json.loads(json.dumps(dataclasses.asdict(state)))})
            state = previous
        return {'violations': failures, 'initial': json.loads(json.dumps(dataclasses.asdict(initial))),
                'trace': list(reversed(trace)), 'scenario': scenario, 'mutant': mutant}

    while queue:
        if len(predecessor) > state_cap or time.monotonic() - started > seconds:
            raise AssertionError('finite exploration cap reached; exhaustive success forbidden')
        state = queue.popleft()
        failures = invariants(state, scenario)
        if failures:
            return {'exhausted': False, 'states': len(predecessor), 'edges': edges,
                    'counterexample': witness(state, failures)}
        checked.update(LEGACY_INVARIANTS if isinstance(state, LegacyState) else POOL_INVARIANTS)
        successors = steps(state, scenario, mutant)
        if terminal(state):
            terminals.add(state)
        if not successors and not terminal(state):
            raise AssertionError('unexpected nonterminal deadlock: ' + repr(state))
        if isinstance(state, LegacyState) and state.phase == 'draining' and any(j in (1, 2) for j in state.jobs):
            waiting['drain_waits_for_callback_progress'] += 1
        if isinstance(state, PoolState) and state.phase in ('pausing', 'stopping'):
            waiting['coordinator_waits_for_workers'] += 1
        for action, successor in successors:
            edges += 1
            coverage[action] += 1
            reverse[successor].add(state)
            forward[state].add(successor)
            if successor not in predecessor:
                predecessor[successor] = (state, action)
                queue.append(successor)
    reachable = set(terminals)
    queue = collections.deque(terminals)
    while queue:
        for previous in reverse[queue.popleft()]:
            if previous not in reachable:
                reachable.add(previous)
                queue.append(previous)
    if len(reachable) != len(predecessor):
        raise AssertionError('nonterminal state has no completion path')
    indegree = {state: len(reverse[state]) for state in predecessor}
    queue = collections.deque(state for state, degree in indegree.items() if degree == 0)
    ordered = 0
    while queue:
        state = queue.popleft()
        ordered += 1
        for successor in forward[state]:
            indegree[successor] -= 1
            if indegree[successor] == 0:
                queue.append(successor)
    if ordered != len(predecessor):
        raise AssertionError('progress graph contains a cycle requiring additional fairness analysis')
    return {'exhausted': True, 'states': len(predecessor), 'edges': edges,
            'terminals': len(terminals), 'transition_coverage': dict(coverage),
            'invariant_coverage': dict(checked), 'intentional_wait_states': dict(waiting),
            'nonterminal_deadlocks': 0, 'progress_cycles': 0,
            'states_with_completion_path': len(reachable)}


def verify_models(output):
    scenarios = []
    for workers in (1, 2):
        for jobs in (0, 1, 2):
            for mode in ('fork', 'fork_failure', 'shutdown'):
                for mask in (0, 1, 2, 3):
                    scenario = (workers, jobs, mode, mask)
                    initial = PoolState('open', ('idle',) * workers, (0,) * jobs, parent_mask=mask)
                    result = explore(initial, scenario, pool_steps, pool_invariants, lambda s: s.phase == 'done')
                    if not result['exhausted']:
                        raise AssertionError(result)
                    scenarios.append({'scenario': scenario, **result})
    legacy = explore(LegacyState(), (), legacy_steps, legacy_invariants, lambda s: s.phase == 'closed')
    scenarios.append({'scenario': 'legacy_shutdown_two_services', **legacy})
    mutants = {}
    for name in ('free_on_park', 'fork_before_join', 'fork_before_reconcile',
                 'child_wrong_state', 'child_wrong_mask', 'raw_clone', 'ignore_active'):
        scenario = (2, 2, 'fork', 2)
        initial = PoolState('open', ('idle',) * 2, (0,) * 2, parent_mask=2)
        if name == 'ignore_active':
            result = explore(LegacyState(), (), legacy_steps, legacy_invariants,
                             lambda s: s.phase == 'closed', name)
        else:
            result = explore(initial, scenario, pool_steps, pool_invariants,
                             lambda s: s.phase == 'done', name)
        if 'counterexample' not in result:
            raise AssertionError('meaningful mutant survived: ' + name)
        witness = result['counterexample']
        current = LegacyState() if name == 'ignore_active' else initial
        steps = legacy_steps if name == 'ignore_active' else pool_steps
        for item in witness['trace']:
            choices = [s for action, s in steps(current, () if name == 'ignore_active' else scenario, name)
                       if action == item['action'] and json.loads(json.dumps(dataclasses.asdict(s))) == item['state']]
            if len(choices) != 1:
                raise AssertionError('counterexample replay is ambiguous or invalid')
            current = choices[0]
        if not (legacy_invariants(current, ()) if name == 'ignore_active' else pool_invariants(current, scenario)):
            raise AssertionError('counterexample does not violate an independent invariant')
        mutants[name] = {'rejected': True, 'replayed': True, **witness}
    all_coverage = collections.Counter()
    all_invariants = collections.Counter()
    for scenario in scenarios:
        all_coverage.update(scenario['transition_coverage'])
        all_invariants.update(scenario['invariant_coverage'])
    required = {'worker_begin', 'worker_complete', 'coordinator_reconcile', 'publish_effects',
                'worker_park', 'worker_leave_callback', 'actual_thread_join', 'libc_fork_snapshot',
                'child_reset_dead_thread_state', 'restore_parent_and_child_masks', 'parent_resume',
                'libc_fork_error_restore', 'callback_logging_and_effects', 'dequeue_to_active',
                'release_completion_decrement', 'acquire_drain_before_logger_teardown'}
    if required - all_coverage.keys():
        raise AssertionError('uncovered lifecycle transitions')
    return {'bounds': {'workers': [1, 2], 'accepted_mutations': [0, 1, 2], 'legacy_services': 2,
                       'legacy_jobs_per_service': 1, 'forks_or_shutdowns': 1, 'saved_mask_classes': 4,
                       'state_cap_per_scenario': 200000, 'seconds_cap_per_scenario': 30},
            'exhausted': True, 'scenarios': scenarios, 'scenario_count': len(scenarios),
            'states': sum(s['states'] for s in scenarios), 'edges': sum(s['edges'] for s in scenarios),
            'transition_coverage': dict(all_coverage), 'rejected_mutants': mutants,
            'invariant_coverage': dict(all_invariants),
            'liveness': 'Every reachable state has a terminal path, and the enumerated non-stuttering progress graph is acyclic. Actual completion additionally requires fair enabled worker/coordinator steps, terminating callbacks and successful OS operations. Blocking wait/stuttering and arbitrary starvation are not progress edges.',
            'ordering': 'Sequentially consistent abstract steps with mutex publication, actual thread joins, Release completion decrements and Acquire drains assumed. No universal weak-memory or machine-code race proof.'}
