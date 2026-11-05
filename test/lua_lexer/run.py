import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description='Protected Lua lexer boundary checks without multi-gigabyte input allocation.')
    parser.parse_args()
    subprocess.run(['bash', 'tools/build_lua.sh', 'all'], cwd=ROOT, check=True)
    compiler = os.environ.get('ESKI_LUA_CC', 'clang')
    vendor = ROOT / 'third_party/lua/vendor/valkey-8.1.0-lua/src'
    source = ROOT / 'test/lua_lexer/line_boundary.c'
    variants = [('debug', 'release', ['-O0', '-g']),
                ('address', 'address', ['-O1', '-g', '-fsanitize=address', '-fno-omit-frame-pointer']),
                ('release', 'release', ['-O2'])]
    with tempfile.TemporaryDirectory(prefix='eski-lexer-') as directory:
        for name, archive, flags in variants:
            binary = Path(directory) / name
            subprocess.run([compiler, '-std=c11', '-D_POSIX_C_SOURCE=200809L', '-D_DEFAULT_SOURCE',
                            '-I'+str(vendor), *flags, str(source),
                            str(ROOT / '.build/lua' / archive / 'libeslua-runtime.a'), '-lm', '-o', str(binary)], check=True)
            environment = dict(os.environ, ASAN_OPTIONS='detect_leaks=1:halt_on_error=1')
            subprocess.run([str(binary)], env=environment, check=True, timeout=15)
            print(name+': passed', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
