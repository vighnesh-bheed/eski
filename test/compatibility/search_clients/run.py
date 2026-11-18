import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))
import scoped_log as scopes


def run(driver, interpreter, port, protocol, scoped=False):
    print(f'{driver} RESP{protocol} {"scoped" if scoped else "ordinary"} port {port}', flush=True)
    env = dict(os.environ, HF_HUB_OFFLINE='1', TRANSFORMERS_OFFLINE='1',
               LANGCHAIN_TRACING_V2='false', LANGSMITH_TRACING='false',
               LLAMA_INDEX_TELEMETRY_ENABLED='false')
    args = [interpreter, '-IB', HERE / (driver + '.py'), str(port), str(protocol)]
    if scoped:
        args.append('--scoped')
    subprocess.run(args, env=env, timeout=60, check=True)


def exercise(args, port, scoped=False):
    for protocol in (2, 3):
        run('modern', args.modern_python, port, protocol, scoped)
        if protocol == 2 or not scoped:
            run('llama', args.llama_python, port, protocol, scoped)


def server(args, directory, mode):
    instance = scopes.Server(args.server, directory, mode, ('--save', ''), args.keyspace_threads)
    try:
        instance.up()
        print(f'Eski PID {instance.run.process.pid} port {instance.run.port}', flush=True)
        exercise(args, instance.run.port, bool(mode))
    finally:
        if instance.run.process is not None:
            code = instance.stop()
            output = instance.run.log()
            if code != 0 or 'AddressSanitizer' in output or 'LeakSanitizer' in output:
                raise RuntimeError(f'Eski exit status {code}\n{output}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--modern-python', type=lambda s: os.path.abspath(s), required=True)
    parser.add_argument('--llama-python', type=lambda s: os.path.abspath(s), required=True)
    parser.add_argument('--server', type=Path, default=ROOT / 'bin/eski')
    parser.add_argument('--ports', help='inclusive loopback port range, for example 7840-7849')
    parser.add_argument('--keyspace-threads', type=int, choices=(0, 2), default=0)
    parser.add_argument('--reference-port', type=int, help='also test a disposable Redis on this loopback port')
    args = parser.parse_args()
    args.server = args.server.resolve()
    if args.ports:
        scopes.use_ports(args.ports)
    if args.reference_port:
        exercise(args, args.reference_port)
    with tempfile.TemporaryDirectory(prefix='eski-search-clients-') as work:
        server(args, Path(work), '')
    with tempfile.TemporaryDirectory(prefix='eski-search-clients-') as work:
        server(args, Path(work), 'both')


if __name__ == '__main__':
    main()
