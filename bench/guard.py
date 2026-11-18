import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def start_ticks(pid):
    try:
        return int(Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()[19])
    except (OSError, IndexError, ValueError):
        return None


def alive(pid, ticks):
    try:
        state = Path('/proc/%d/stat' % pid).read_text().rsplit(')', 1)[1].split()[0]
    except (OSError, IndexError):
        return False
    current = start_ticks(pid)
    return state != 'Z' and current is not None and str(current) == str(ticks)


def stop(pid, ticks, group=False, log=None):
    kill = os.killpg if group else os.kill
    sent = False
    for number, wait in ((signal.SIGTERM, 15), (signal.SIGKILL, 10)):
        if not alive(pid, ticks):
            return 'stopped' if sent else 'gone'
        sent = True
        try:
            kill(pid, number)
        except (ProcessLookupError, PermissionError) as error:
            return 'signal failed: %s' % error
        deadline = time.monotonic() + wait
        while alive(pid, ticks) and time.monotonic() < deadline:
            time.sleep(0.1)
    return 'stopped' if not alive(pid, ticks) else 'still running'


def exists(name):
    return subprocess.run(['docker', 'container', 'inspect', name], capture_output=True, timeout=60).returncode == 0


def remove_container(name):
    detail = ''
    removed = False
    absent = 0
    for _ in range(40):
        if exists(name):
            absent = 0
            done = subprocess.run(['docker', 'rm', '-f', name], capture_output=True, text=True, timeout=120)
            removed = removed or done.returncode == 0
            detail = done.stderr.strip()[-300:]
        else:
            absent += 1
            if absent >= 4:
                return 'removed' if removed else 'gone'
        time.sleep(0.5)
    return 'still present: ' + detail


def exam_cleanup(results):
    outcome = []
    checkpoint = Path(results) / 'checkpoint.json'
    try:
        state = json.loads(checkpoint.read_text())
    except (OSError, ValueError):
        return ['no checkpoint at %s' % checkpoint]
    for row in state.get('cases', []):
        for attempt in row.get('attempts', []):
            if attempt.get('state') != 'running':
                continue
            process = attempt.get('harness_process') or {}
            if process.get('pid'):
                outcome.append('harness %s: %s' % (process['pid'], stop(process['pid'], process.get('start_ticks'), group=True)))
            run_id = attempt.get('run_id')
            if run_id:
                listed = subprocess.run(['docker', 'ps', '-aq', '--filter', 'label=eski-bench=' + run_id], capture_output=True, text=True, timeout=60)
                for container in listed.stdout.split():
                    outcome.append('container %s of %s: %s' % (container, run_id, remove_container(container)))
    return outcome


def clean(folder):
    actions = []
    for path in sorted(Path(folder).glob('*')):
        if path.name.startswith('.'):
            continue
        kind, _, name = path.name.partition('-')
        value = path.read_text().strip()
        if kind == 'server':
            pid, _, ticks = value.partition(' ')
            result = stop(int(pid), ticks)
        elif kind == 'group':
            pid, _, ticks = value.partition(' ')
            result = stop(int(pid), ticks, group=True)
        elif kind == 'container':
            result = remove_container(value)
        elif kind == 'exam':
            result = '; '.join(exam_cleanup(value)) or 'nothing running'
        elif kind == 'label':
            listed = subprocess.run(['docker', 'ps', '-aq', '--filter', 'label=eski-bench=' + value], capture_output=True, text=True, timeout=60)
            result = '; '.join('%s: %s' % (container, remove_container(container)) for container in listed.stdout.split()) or 'no container'
        else:
            result = 'unknown entry'
        actions.append(dict(entry=path.name, value=value, result=result))
        path.unlink()
    return actions


def main():
    folder, log = sys.argv[1], sys.argv[2]
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    message = sys.stdin.buffer.read()
    actions = clean(folder)
    with open(log, 'a') as handle:
        handle.write(json.dumps(dict(at=time.time(), parent_message=message.decode(errors='replace').strip(), actions=actions)) + '\n')


if __name__ == '__main__':
    main()
