import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import time

sys.dont_write_bytecode = True

PHASES = ('calibration', 'benchmark')
WORKFLOW_SCHEMA = 'eski-exam-workflow-v1'
LAUNCH_SCHEMA = 'eski-exam-launch-v1'
PROTOCOL_SCHEMA = 'eski-exam-protocol-v1'
EXPERIMENT_SCHEMA = 'eski-exam-experiment-v1'
EXPORT_SCHEMA = 'eski-exam-export-v1'
EXPERIMENT_FIELDS = ('targets', 'server_cpus', 'client_cpus', 'control_cpus', 'server_memory', 'client_memory', 'maxmemory',
                     'repetitions', 'sensor_chip', 'sensor_label', 'cool_temp_c', 'max_temp_c', 'min_idle', 'min_rest',
                     'stable_seconds', 'max_wait', 'sample_seconds', 'min_free_bytes', 'resource_policy',
                     'max_client_utilization_pct', 'max_latency_seconds')
OPTIONAL_FIELDS = ('package_sensor', 'power_source')
WORKFLOW_FIELDS = ('idle_watch_seconds',)
ACTIVE = ('STARTING', 'RUNNING')
FINISHED = ('DONE', 'DONE WITH EXCLUSIONS')
EXPORTED_DIRECTORIES = ('control', 'calibration/results', 'benchmark/results')
REASONS = {
    'NOT STARTED': 'no launch has been requested; a no-argument invocation starts once',
    'STARTING': 'the detached controller is starting',
    'RUNNING': 'the planned cases are running',
    'HELD': 'held; read the reason above, then resume explicitly if the cause is gone',
    'INTERRUPTED': 'the controller stopped; resume explicitly with exam.sh resume',
    'DONE': 'every planned measurement is valid',
    'DONE WITH EXCLUSIONS': 'every planned case is terminal; some outcomes are not valid measurements',
}


def load(path):
    return json.loads(Path(path).read_text())


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def workspace(root):
    return root / 'workspace'


def control(root):
    return root / 'control'


def scheduler_module(root):
    path = workspace(root) / 'bench' / 'exam_scheduler.py'
    spec = importlib.util.spec_from_file_location('eski_exam_scheduler', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def session(root):
    return 'eski-exam-' + hashlib.sha256(str(root).encode()).hexdigest()[:12]


def host_lock():
    return Path(tempfile.gettempdir()) / ('eski-exam-%d.lock' % os.getuid())


def tool_environment(root):
    environment = os.environ.copy()
    environment['PYTHONDONTWRITEBYTECODE'] = '1'
    path = workspace(root) / 'profile.json'
    profile = load(path) if path.exists() else {}
    if profile.get('tool_bin'):
        directory = (workspace(root) / profile['tool_bin']).resolve()
        if not directory.is_relative_to(workspace(root).resolve()):
            raise ValueError('tool_bin escapes the installed workspace')
        environment['PATH'] = str(directory) + os.pathsep + environment.get('PATH', '')
    return environment


def tmux_state(root, environment=None):
    environment = environment or tool_environment(root)
    executable = shutil.which('tmux', path=environment.get('PATH'))
    if not executable:
        return None, False
    done = subprocess.run([executable, 'has-session', '-t', session(root)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=environment)
    return executable, done.returncode == 0


def experiment(root, phase):
    value = load(workspace(root) / 'plans' / phase / 'experiment.json')
    if value.get('schema') != EXPERIMENT_SCHEMA:
        raise ValueError(phase + ' experiment.json has an unsupported schema')
    unknown = set(value) - set(EXPERIMENT_FIELDS) - set(OPTIONAL_FIELDS) - set(WORKFLOW_FIELDS) - {'schema'}
    missing = [name for name in EXPERIMENT_FIELDS if name not in value]
    if unknown or missing:
        raise ValueError('%s experiment.json fields differ: unknown %s, missing %s' % (phase, sorted(unknown), missing))
    if not isinstance(value['targets'], list) or not value['targets'] or not all(isinstance(t, str) for t in value['targets']):
        raise ValueError(phase + ' targets must be a nonempty list of names')
    watch = value.get('idle_watch_seconds', 0)
    if type(watch) is not int or watch < 0:
        raise ValueError(phase + ' idle_watch_seconds must be a non-negative integer number of seconds')
    return value


def phase_arguments(root, phase):
    config = experiment(root, phase)
    environment = tool_environment(root)
    base = workspace(root)
    arguments = ['--plan', str(base / 'plans' / phase / 'plan.json'), '--profile', str(base / 'profile.json'),
                 '--output', str(root / phase / 'results'), '--host-lock', str(control(root) / 'child-host.lock')]
    for name in EXPERIMENT_FIELDS + OPTIONAL_FIELDS:
        if name in config and config[name] is not None:
            arguments += ['--' + name.replace('_', '-'), ','.join(config[name]) if name == 'targets' else str(config[name])]
    pool = ','.join(config[role + '_cpus'] for role in ('server', 'client', 'control'))
    executable = ['taskset', '--cpu-list', pool, sys.executable, '-B', str(base / 'bench' / 'exam_scheduler.py')]
    return executable, arguments, environment


def inspect(root):
    phases = {}
    for phase in PHASES:
        executable, arguments, environment = phase_arguments(root, phase)
        done = subprocess.run(executable + ['inspect'] + arguments, env=environment, capture_output=True, text=True, timeout=300)
        if done.returncode:
            raise ValueError(phase + ' preflight rejected: ' + (done.stdout + done.stderr).strip()[-2000:])
        phases[phase] = json.loads(done.stdout)['identity']
    strip = lambda config: {key: value for key, value in config.items() if key != 'repetitions'}
    if strip(phases['benchmark']['config']) != strip(phases['calibration']['config']):
        raise ValueError('calibration and benchmark resource profiles differ')
    return dict(schema=LAUNCH_SCHEMA, workflow_sha256=digest(__file__), phases=phases)


def frozen_inputs(root):
    observed = inspect(root)
    path = root / 'protocol.json'
    protocol = load(path)
    if protocol.get('schema') != PROTOCOL_SCHEMA:
        raise ValueError('protocol.json has an unsupported schema')
    for phase in PHASES:
        expected = (protocol.get('phases') or {}).get(phase) or {}
        identity = observed['phases'][phase]
        if expected.get('identity') != identity['sha256'] or expected.get('plan_sha256') != identity['plan_sha256']:
            raise ValueError(phase + ' identity differs from the frozen protocol')
    observed['protocol_sha256'] = digest(path)
    return observed


def atomic(root, path, value):
    scheduler_module(root).atomic(path, value)


def workflow_state(root):
    path = control(root) / 'workflow.json'
    return load(path) if path.exists() else None


def alive(module, owner, boot_id):
    current = module.metrics.process(owner.get('pid')) if owner and owner.get('pid') else None
    return bool(current and current['start_ticks'] == owner.get('start_ticks') and current['state'] != 'Z'
                and boot_id == module.metrics.read('/proc/sys/kernel/random/boot_id'))


def plan_items(root, phase):
    items = load(workspace(root) / 'plans' / phase / 'plan.json').get('items')
    if not isinstance(items, list) or not items:
        raise ValueError(phase + ' plan has no items')
    return items


def design_counts(root):
    result = {}
    for phase in PHASES:
        config = experiment(root, phase)
        workloads, targets, repetitions = len(plan_items(root, phase)), len(config['targets']), config['repetitions']
        if type(repetitions) is not int or repetitions < 1:
            raise ValueError(phase + ' repetitions must be a positive integer')
        result[phase] = dict(workloads=workloads, targets=targets, repetitions=repetitions, measurements=workloads * targets * repetitions)
    return result


def phase_view(root, phase, module):
    path = root / phase / 'results' / 'checkpoint.json'
    stored = load(path) if path.exists() else None
    view = module.status_view(stored)
    if stored is None:
        planned = design_counts(root)[phase]['measurements']
        view['counts'].update(planned=planned, pending=planned, missing=planned)
    counts = view['counts']
    current = None
    if stored and not view['done']:
        current = next((row for row in stored['cases'] if row['state'] == 'running'), None)
        current = current or next((row for row in stored['cases'] if row['state'] not in module.TERMINAL), None)
    reasons = list(((stored or {}).get('pause') or {}).get('reasons') or [])
    if current and current.get('attempts') and current['attempts'][-1].get('interruption_reason'):
        reasons.append(current['attempts'][-1]['interruption_reason'])
    return dict(status=view['status'], done=view['done'], passed=view['passed'], counts=counts,
                completed=counts['planned'] - counts['missing'], remaining=counts['missing'],
                current=dict(target=current['target'], key=current['key'], repetition=current['repetition']) if current else None,
                pause_reasons=reasons, controller_alive=view.get('controller_alive', False))


def idle_watch(reader, seconds, interval, cpus, clock=time, stop=lambda: False, record=None):
    start = clock.monotonic()
    offenders, samples = [], 0
    while not stop():
        sample = reader.sample()
        samples += 1
        for proc in sample.get('external_cpu') or []:
            if proc.get('processor') is None or proc.get('processor') in cpus:
                offenders.append(dict(comm=proc.get('comm'), pid=proc.get('pid'), cpu=proc.get('processor'), cores=proc.get('cpu_cores'),
                                      kthread=proc.get('kthread'), wall_time=sample.get('wall_time'), sample=samples))
        if record is not None:
            record(dict(wall_time=sample.get('wall_time'), monotonic=sample.get('monotonic'), idle_pct=sample.get('idle_pct'), loadavg=sample.get('loadavg'),
                        external_cpu=sample.get('external_cpu'), cpu_share_pct=sample.get('cpu_share_pct')))
        if clock.monotonic() - start >= seconds:
            break
        clock.sleep(interval)
    return dict(seconds=seconds, interval=interval, elapsed=clock.monotonic() - start, samples=samples, cpus=sorted(cpus),
                offenders=offenders, passed=not offenders and not stop(), interrupted=bool(stop()),
                rule='every process outside the run, kernel threads included, that used at least a tenth of a core on a server or client CPU in any sample')


def idle_watch_reason(result, roles):
    groups = {}
    for item in result['offenders']:
        group = groups.setdefault((item['comm'], item['cpu']), dict(samples=0, cores=0))
        group['samples'] += 1
        group['cores'] = max(group['cores'], item['cores'] or 0)
    parts = []
    for (comm, cpu), group in sorted(groups.items(), key=lambda entry: -entry[1]['samples']):
        role = next((name for name, cpus in roles.items() if cpu in cpus), 'unknown')
        parts.append('%s on %s CPU %s at up to %.2f cores in %d of %d samples' % (comm, role, cpu, group['cores'], group['samples'], result['samples']))
    return ('the idle watch of %d s before the calibration found %s; a kernel worker bound to a role CPU usually comes from a loaded display driver, so blacklist '
            'it on the kernel command line (for example modprobe.blacklist=i915), reboot and resume' % (result['seconds'], '; '.join(parts)))


def idle_watch_phase(root, module, launch, stop):
    config = experiment(root, 'calibration')
    seconds = config.get('idle_watch_seconds', 0)
    if not seconds:
        return None
    roles = {role: module.metrics.cpu_set(config[role + '_cpus']) for role in ('server', 'client', 'control')}
    reader = module.metrics.Reader(config.get('package_sensor'), config.get('sensor_chip', 'coretemp'), config.get('sensor_label', 'Package id 0'))
    samples = control(root) / ('idle-watch-%d.jsonl' % launch)
    result = idle_watch(reader, seconds, config.get('sample_seconds', 1), roles['server'] | roles['client'], stop=stop,
                        record=lambda row: module.metrics.append_json(samples, row))
    result.update(launch=launch, samples_file=samples.name, started_at=time.time() - result['elapsed'], finished_at=time.time(),
                  reason=None if result['passed'] else idle_watch_reason(result, roles) if result['offenders'] else 'the idle watch was interrupted')
    module.atomic(control(root) / 'idle-watch.json', result)
    return result


def os_release(module):
    release = {}
    for line in (module.metrics.read('/etc/os-release') or '').splitlines():
        key, separator, value = line.partition('=')
        if separator:
            values = shlex.split(value)
            release[key] = values[0] if values else ''
    return release


def machine_description(root, module):
    source = module.metrics
    try:
        config = experiment(root, 'benchmark')
    except (OSError, ValueError):
        config = {}
    processors = []
    for block in (source.read('/proc/cpuinfo') or '').split('\n\n'):
        fields = {key.strip(): value.strip() for key, _, value in (line.partition(':') for line in block.splitlines() if ':' in line)}
        if 'processor' in fields:
            processors.append(fields)
    physical = {(p['physical id'], p['core id']) for p in processors if 'physical id' in p and 'core id' in p}
    memory = {}
    for line in (source.read('/proc/meminfo') or '').splitlines():
        words = line.split()
        if len(words) > 1 and words[0] in ('MemTotal:', 'MemAvailable:'):
            memory[words[0][:-1]] = int(words[1]) * 1024
    supplies = source.power_supplies()
    ac = {name: device['online'] for name, device in (supplies or {}).items() if device['type'] == 'Mains'}
    sensor = source.Reader(config.get('package_sensor'), config.get('sensor_chip', 'coretemp'), config.get('sensor_label', 'Package id 0')).sensor()
    engines_path = root / 'engines.json'
    engines = load(engines_path).get('engines', []) if engines_path.exists() else []
    profile_path = workspace(root) / 'profile.json'
    profile = load(profile_path) if profile_path.exists() else {}
    inventory = source.machine_inventory()
    return dict(hostname=socket.gethostname(), os=os_release(module).get('PRETTY_NAME'), kernel=platform.release(),
                kernel_cmdline=inventory['cmdline'], kernel_modules=inventory['modules'], drm=inventory['drm'],
                display_drivers=source.display_drivers(inventory), timer_migration=inventory['timer_migration'],
                idle_watch_seconds=config.get('idle_watch_seconds', 0),
                cpu_model=processors[0].get('model name') if processors else None,
                physical_cores=len(physical) or None, logical_cores=len(processors) or os.cpu_count(),
                ram_total_bytes=memory.get('MemTotal'), ram_available_bytes=memory.get('MemAvailable'),
                disk_free_bytes=shutil.disk_usage(root).free, package_temperature=sensor, ac_online=ac,
                power_source=config.get('power_source') or 'mains', power_supplies=supplies,
                configured_cpus={role: config.get(role + '_cpus') for role in ('server', 'client', 'control')},
                configured_limits={name: config.get(name) for name in ('server_memory', 'client_memory', 'maxmemory')},
                engines=engines, source=dict(revision=profile.get('source_revision'), tree_sha256=profile.get('source_sha256')),
                captured_at=time.time())


def gib(value):
    return 'unavailable' if value is None else '%.2f GiB' % (value / 1024 ** 3)


def status(root):
    module = scheduler_module(root)
    state = workflow_state(root) or dict(status='NOT STARTED', phase='calibration')
    executable, running = tmux_state(root)
    live = alive(module, state.get('controller'), state.get('boot_id'))
    effective = dict(state)
    if state['status'] == 'RUNNING' and not live:
        effective.update(status='INTERRUPTED', reason='the controller stopped without finishing; resume explicitly with exam.sh resume')
    elif state['status'] == 'STARTING' and not running and not live:
        effective.update(status='INTERRUPTED', reason='the detached session ended before the controller started; read control/workflow.log, then resume explicitly')
    phase = state.get('phase', 'calibration')
    view = phase_view(root, phase, module)
    watch = state.get('idle_watch') or {}
    reason = effective.get('reason') or ('; '.join(view['pause_reasons']) if view['pause_reasons'] else None)
    if reason is None and effective['status'] == 'RUNNING' and watch.get('status') == 'watching':
        reason = 'the idle watch of %s s samples the machine before the calibration starts' % watch.get('seconds')
    reason = reason or REASONS[effective['status']]
    receipt_path = root / 'exports' / 'receipt.json'
    return dict(status=effective['status'], phase=phase, phase_status=view, reason=reason, workflow=state,
                machine=machine_description(root, module), design=design_counts(root), session=session(root),
                tmux_available=executable is not None, tmux_running=running, controller_alive=live,
                export=load(receipt_path) if receipt_path.exists() else None, export_error=state.get('export_error'))


def show(root, as_json=False, error=None):
    details = status(root)
    if error:
        details['error'] = str(error)
    if as_json:
        print(json.dumps(details, indent=2, sort_keys=True))
        return details
    machine = details['machine']
    print('Machine: %s | %s | kernel %s' % (machine['hostname'], machine['os'] or 'OS unavailable', machine['kernel']))
    print('Kernel command line: %s' % (machine['kernel_cmdline'] or 'unavailable'))
    print('Display drivers: %s | kernel modules: %d | timer_migration: %s | idle watch: %s' % (
        ', '.join(machine['display_drivers']) or 'none', len(machine['kernel_modules']),
        'unavailable' if machine['timer_migration'] is None else machine['timer_migration'],
        '%d s before the calibration' % machine['idle_watch_seconds'] if machine['idle_watch_seconds'] else 'off'))
    print('CPU: %s | %s physical / %s logical cores' % (machine['cpu_model'] or 'unavailable', machine['physical_cores'] or 'unavailable', machine['logical_cores']))
    print('RAM: %s total / %s available | disk free: %s' % (gib(machine['ram_total_bytes']), gib(machine['ram_available_bytes']), gib(machine['disk_free_bytes'])))
    sensor = machine['package_temperature']
    temperature = '%.1f C' % sensor['celsius'] if sensor.get('available') else 'unavailable'
    ac = ', '.join('%s=%s' % (key, 'online' if value == 1 else 'offline' if value == 0 else 'unavailable') for key, value in machine['ac_online'].items()) or 'not exposed'
    print('CPU package: %s | AC: %s' % (temperature, ac))
    devices = machine['power_supplies']
    listed = 'unreadable' if devices is None else ', '.join('%s=%s' % (name, device.get('type') or 'unknown type') for name, device in sorted(devices.items())) or 'none'
    print('Power gate: %s | power supply devices: %s' % (machine['power_source'], listed))
    print('CPU masks: ' + ' | '.join('%s=%s' % (role, value or 'unavailable') for role, value in machine['configured_cpus'].items()))
    limits = machine['configured_limits']
    print('Limits: server container %s | client container %s | maxmemory %s bytes' % (limits['server_memory'], limits['client_memory'], limits['maxmemory']))
    for engine in machine['engines']:
        print('Engine %s: %s | %s' % (engine.get('target'), engine.get('version') or engine.get('label') or 'version unavailable', engine.get('image_id') or 'image unavailable'))
    print('Source: revision %s, tree sha256 %s' % (machine['source']['revision'] or 'unavailable', machine['source']['tree_sha256'] or 'unavailable'))
    print('')
    view = details['phase_status']
    counts = view['counts']
    print('Workflow: %s | phase: %s | phase status: %s' % (details['status'], details['phase'], view['status']))
    print('Phase progress: %d/%d complete; %d remaining | valid: %d | failed: %d | invalid: %d | skipped: %d' % (
        view['completed'], counts['planned'], view['remaining'], counts['valid'], counts['failed'], counts['invalid'], counts['skipped']))
    design = details['design']
    print('Design: %d workloads x %d engines x %d repetitions = %d measurements; calibration first: %d workload x %d engines x %d = %d' % (
        design['benchmark']['workloads'], design['benchmark']['targets'], design['benchmark']['repetitions'], design['benchmark']['measurements'],
        design['calibration']['workloads'], design['calibration']['targets'], design['calibration']['repetitions'], design['calibration']['measurements']))
    current = view['current']
    print('Current/next: ' + ('%s %s repetition %d' % (current['target'], current['key'], current['repetition']) if current else 'none'))
    print('Reason: ' + details['reason'])
    if error:
        print('Error: ' + str(error))
    print('Controller: %s | tmux: %s (session %s)' % ('alive' if details['controller_alive'] else 'stopped',
          'running' if details['tmux_running'] else 'stopped' if details['tmux_available'] else 'unavailable', details['session']))
    if details['export']:
        print('Export: exports/%s sha256 %s (%d bytes)' % (details['export']['archive'], details['export']['sha256'], details['export']['bytes']))
    if details['export_error']:
        print('Export error: ' + details['export_error'])
    return details


def launch(root, state):
    environment = tool_environment(root)
    executable, running = tmux_state(root, environment)
    if not executable:
        raise ValueError('tmux unavailable; the installation never starts or downloads it')
    if running:
        raise ValueError('the detached session is already running: ' + session(root))
    atomic(root, control(root) / 'workflow.json', state)
    command = shlex.join([sys.executable, '-B', '-I', str(Path(__file__).resolve()), '--root', str(root), '_run'])
    command += ' >>' + shlex.quote(str(control(root) / 'workflow.log')) + ' 2>&1'
    done = subprocess.run([executable, 'new-session', '-d', '-s', session(root), '-c', str(root), command], capture_output=True, text=True, env=environment)
    if done.returncode:
        atomic(root, control(root) / 'workflow.json', dict(state, status='HELD', reason='tmux launch failed: ' + done.stderr.strip()))
        raise ValueError('tmux launch failed: ' + done.stderr.strip())
    return True


def start(root, default=False):
    module = scheduler_module(root)
    control(root).mkdir(mode=0o700, exist_ok=True)
    with module.Lock(control(root) / 'entry.lock'):
        if workflow_state(root) is not None or (control(root) / 'frozen-launch.json').exists():
            if default:
                return False
            raise ValueError('the workflow was already started; use status, or resume after an interruption')
        frozen = frozen_inputs(root)
        module.atomic(control(root) / 'frozen-launch.json', frozen)
        return launch(root, dict(schema=WORKFLOW_SCHEMA, status='STARTING', phase='calibration', requested_at=time.time(), launches=1, resume=False))


def resume(root):
    module = scheduler_module(root)
    control(root).mkdir(mode=0o700, exist_ok=True)
    with module.Lock(control(root) / 'entry.lock'):
        state = workflow_state(root)
        if state is None or not (control(root) / 'frozen-launch.json').exists():
            raise ValueError('nothing to resume; a no-argument invocation starts the workflow once')
        _, running = tmux_state(root)
        if running or alive(module, state.get('controller'), state.get('boot_id')):
            raise ValueError('the controller is active; resume is only for a stopped workflow')
        if state['status'] in FINISHED:
            raise ValueError('the workflow finished; nothing to resume')
        calibration = (state.get('phase_outcomes') or {}).get('calibration') or {}
        if calibration.get('checkpoint_done') and not calibration.get('checkpoint_passed'):
            raise ValueError('calibration did not pass for every engine; resume cannot admit the benchmark')
        return launch(root, dict(state, status='STARTING', resume=True, reason=None, resumed_at=time.time(), launches=int(state.get('launches') or 1) + 1))


def run(root):
    module = scheduler_module(root)
    path = control(root) / 'workflow.json'
    state = load(path)
    if state['status'] != 'STARTING':
        raise ValueError('the workflow is not awaiting its controller; no automatic retry')
    state.update(status='RUNNING', started_at=time.time(), controller=module.metrics.process(os.getpid()),
                 boot_id=module.metrics.read('/proc/sys/kernel/random/boot_id'), reason=None)
    outcomes = state.setdefault('phase_outcomes', {})
    child = None
    stopped = False

    def stop(*_):
        nonlocal stopped
        stopped = True
        if child is not None and child.poll() is None:
            try:
                os.kill(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, stop)
    with module.Lock(host_lock()):
        try:
            frozen = load(control(root) / 'frozen-launch.json')
            if frozen_inputs(root) != frozen:
                raise ValueError('the frozen launch inputs or the host identity changed')
            os.sched_setaffinity(0, frozen['phases']['benchmark']['config']['cpus']['control'])
            state['control_cpus'] = sorted(os.sched_getaffinity(0))
            module.atomic(path, state)
            inventory = module.metrics.machine_inventory()
            module.atomic(control(root) / 'machine.json', dict(inventory, display_drivers=module.metrics.display_drivers(inventory),
                                                                launch=int(state.get('launches') or 1), captured_at=time.time()))
            for phase in PHASES:
                if stopped:
                    break
                checkpoint = root / phase / 'results' / 'checkpoint.json'
                view = module.status_view(load(checkpoint)) if checkpoint.exists() else None
                if view is not None and view['done']:
                    previous = outcomes.get(phase) or {}
                    outcomes[phase] = dict(previous, checkpoint_passed=view['passed'], checkpoint_done=True, counts=view['counts'],
                                           exitcode=previous.get('exitcode', 0 if view['passed'] else 2))
                else:
                    if frozen_inputs(root) != frozen:
                        raise ValueError('the frozen launch inputs or the host identity changed before the ' + phase + ' phase')
                    if stopped:
                        break
                    state['phase'] = phase
                    module.atomic(path, state)
                    if phase == 'calibration':
                        seconds = experiment(root, phase).get('idle_watch_seconds', 0)
                        if seconds:
                            state['idle_watch'] = dict(status='watching', seconds=seconds, started_at=time.time())
                            module.atomic(path, state)
                        watch = idle_watch_phase(root, module, int(state.get('launches') or 1), lambda: stopped)
                        if watch is not None:
                            state['idle_watch'] = dict(status='passed' if watch['passed'] else 'failed', seconds=seconds, samples=watch['samples'],
                                                       offenders=len(watch['offenders']), started_at=watch['started_at'], finished_at=watch['finished_at'])
                        if stopped:
                            break
                        if watch is not None and not watch['passed']:
                            state.update(status='HELD', reason=watch['reason'])
                            break
                    executable, arguments, environment = phase_arguments(root, phase)
                    started = checkpoint.exists() or (root / phase / 'results' / 'identity.json').exists()
                    command = ['resume', '--retry-interrupted'] if started else ['run']
                    log = control(root) / ('%s-launch-%d.log' % (phase, int(state.get('launches') or 1)))
                    with log.open('ab') as output:
                        child = subprocess.Popen(executable + command[:1] + arguments + command[1:], env=environment, stdout=output, stderr=subprocess.STDOUT)
                        if stopped:
                            stop()
                        code = child.wait()
                    view = module.status_view(load(checkpoint)) if checkpoint.exists() else dict(passed=False, done=False, counts=None)
                    outcomes[phase] = dict(exitcode=code, checkpoint_passed=view['passed'], checkpoint_done=view['done'], counts=view['counts'], command=command)
                state['phase'] = phase
                module.atomic(path, state)
                if stopped:
                    break
                outcome = outcomes[phase]
                if phase == 'calibration' and (outcome['exitcode'] != 0 or not outcome['checkpoint_passed']):
                    state.update(status='HELD', reason='calibration did not pass for every engine with a clean exit; the benchmark phase was not started')
                    break
                if phase == 'benchmark':
                    if outcome['checkpoint_passed'] and outcome['exitcode'] == 0:
                        state.update(status='DONE', reason='every planned measurement is valid')
                    elif outcome['checkpoint_done']:
                        state.update(status='DONE WITH EXCLUSIONS', reason='every planned case is terminal; the excluded outcomes keep their reasons')
                    else:
                        state.update(status='HELD', reason='the benchmark phase stopped before every case was terminal; read the phase status, then resume explicitly')
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            state.update(status='HELD', reason=str(error))
        if stopped:
            state.update(status='INTERRUPTED', reason='stopped by a signal; partial evidence kept; resume explicitly with exam.sh resume')
        if state['status'] == 'RUNNING':
            state.update(status='HELD', reason='the controller ended without a phase outcome')
        state['finished_at'] = time.time()
        module.atomic(path, state)
        try:
            export(root)
            state.pop('export_error', None)
        except (OSError, ValueError, tarfile.TarError) as error:
            state['export_error'] = str(error)
        module.atomic(path, state)
    return 0 if state['status'] == 'DONE' and not state.get('export_error') else 2


def unsafe(root, path):
    relative = path.relative_to(root)
    return path.is_symlink() or not path.resolve().is_relative_to(root.resolve()) or any(
        (root / Path(*relative.parts[:index])).is_symlink() for index in range(1, len(relative.parts)))


def exporter_path():
    return Path(__file__).resolve()


def tool_directory(base, profile):
    tool_bin = profile.get('tool_bin')
    if not tool_bin:
        return None
    relative = Path(tool_bin)
    if relative.is_absolute() or not relative.parts or '..' in relative.parts:
        raise ValueError('tool_bin must be a relative path inside the workspace')
    return base / relative.parts[0]


def export_files(root):
    files = [path for path in root.iterdir() if path.is_file()]
    for relative in EXPORTED_DIRECTORIES:
        directory = root / relative
        if directory.exists():
            files += [path for path in directory.rglob('*') if path.is_file()]
    base = workspace(root)
    profile = load(base / 'profile.json')
    files.append(base / 'profile.json')
    tools = tool_directory(base, profile)
    exporter = exporter_path()
    notes = dict(tools_verified_not_archived=0, exporter=None)
    for name, expected in sorted((profile.get('files') or {}).items()):
        source = base / name
        if tools is not None and source.is_relative_to(tools):
            if not source.resolve().is_relative_to(tools.resolve()):
                raise ValueError('tool inventory entry resolves outside the tools directory: ' + name)
            if digest(source) != expected:
                raise ValueError('workspace file changed before export: ' + name)
            notes['tools_verified_not_archived'] += 1
            continue
        if not source.resolve().is_relative_to(base.resolve()) or source.is_symlink():
            raise ValueError('unsafe workspace inventory entry: ' + name)
        observed = digest(source)
        if source.resolve() == exporter:
            notes['exporter'] = dict(path='workspace/' + name, sha256=observed, recorded_sha256=expected, matches=observed == expected)
        elif observed != expected:
            raise ValueError('workspace file changed before export: ' + name)
        files.append(source)
    for path in files:
        if unsafe(root, path):
            raise ValueError('unsafe archive input: ' + str(path))
    return sorted(set(files)), notes


def export(root):
    module = scheduler_module(root)
    state = workflow_state(root) or {}
    if state.get('status') in ACTIVE and alive(module, state.get('controller'), state.get('boot_id')) and state.get('controller', {}).get('pid') != os.getpid():
        raise ValueError('cannot export while the controller is active')
    exports = root / 'exports'
    exports.mkdir(exist_ok=True)
    number = 1
    while (exports / ('results.tar.gz' if number == 1 else 'results-%d.tar.gz' % number)).exists():
        number += 1
    name = 'results.tar.gz' if number == 1 else 'results-%d.tar.gz' % number
    output = exports / name
    files, notes = export_files(root)
    inventory = {str(path.relative_to(root)): dict(sha256=digest(path), bytes=path.stat().st_size) for path in files}
    module.atomic(exports / 'inventory.json', inventory)
    descriptor, temporary = tempfile.mkstemp(prefix='.results-', dir=exports)
    os.close(descriptor)
    try:
        with tarfile.open(temporary, 'w:gz') as archive:
            for path in files + [exports / 'inventory.json']:
                archive.add(path, arcname=str(path.relative_to(root)), recursive=False)
        with open(temporary, 'rb') as handle:
            os.fsync(handle.fileno())
        os.link(temporary, output)
    finally:
        Path(temporary).unlink(missing_ok=True)
    receipt = dict(schema=EXPORT_SCHEMA, archive=name, sha256=digest(output), bytes=output.stat().st_size, files=len(inventory),
                   inventory='exports/inventory.json', root=root.name, workflow_status=state.get('status', 'NOT STARTED'), created_at=time.time(),
                   tools_verified_not_archived=notes['tools_verified_not_archived'], exporter=notes['exporter'])
    module.atomic(exports / 'receipt.json', receipt)
    module.metrics.append_json(exports / 'receipts.jsonl', receipt)
    return receipt


def manual_export(root):
    module = scheduler_module(root)
    state = workflow_state(root)
    _, running = tmux_state(root)
    if state is None:
        raise ValueError('the workflow never started; nothing to export')
    if running or alive(module, state.get('controller'), state.get('boot_id')):
        raise ValueError('the controller is active; it exports by itself when it finishes')
    return export(root)


HELP = '''usage: exam.sh [status [--json] | inspect | resume | collect | help]

No arguments: the first invocation checks the frozen protocol and starts the calibration phase and
then the benchmark phase once, in a detached tmux session; every later invocation only shows status.
  status [--json]  show the machine, the progress and the reason; never starts anything
  inspect          run the preflight of both phases and print their identities; never starts anything
  resume           start the detached controller again after an interruption or a hold; finished
                   cases are kept, interrupted cases get a new preserved attempt
  collect          write the export archive again when the controller is stopped
The controller writes exports/results.tar.gz, exports/inventory.json and exports/receipt.json when
it stops, whatever the outcome.'''


def pin_control(root):
    try:
        config = experiment(root, 'benchmark')
        os.sched_setaffinity(0, scheduler_module(root).metrics.cpu_set(config['control_cpus']))
    except (OSError, ValueError, KeyError, TypeError):
        pass


def main(argv=None):
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('command', nargs='?', default='dashboard', choices=('dashboard', 'status', 'inspect', 'resume', 'collect', 'help', '_run'))
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    root = args.root.resolve()
    try:
        if args.command == 'help':
            print(HELP)
            return 0
        if args.command != '_run':
            pin_control(root)
        if args.command == 'status':
            show(root, args.json)
            return 0
        if args.command == 'inspect':
            print(json.dumps(inspect(root), indent=2, sort_keys=True))
            return 0
        if args.command == 'collect':
            print(json.dumps(manual_export(root), indent=2, sort_keys=True))
            return 0
        if args.command == '_run':
            return run(root)
        if args.command == 'resume':
            resume(root)
        else:
            start(root, default=True)
        show(root, args.json)
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        if args.command == '_run':
            path = control(root) / 'workflow.json'
            try:
                state = load(path) if path.exists() else None
                if state and state.get('status') == 'STARTING':
                    scheduler_module(root).atomic(path, dict(state, status='HELD', reason=str(error)))
            except (OSError, ValueError):
                pass
        if args.command in ('dashboard', 'resume'):
            try:
                show(root, args.json, error)
            except (OSError, ValueError, KeyError, TypeError):
                pass
        print(json.dumps(dict(state='rejected', error=str(error))), file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
