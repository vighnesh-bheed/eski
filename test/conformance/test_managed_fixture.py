import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from managed_fixture import READINESS, prepare


class ManagedFixture(unittest.TestCase):
    @unittest.skipUnless(shutil.which('tclsh'), 'Tcl required for readiness fixture control')
    def test_expected_fatal_startup_does_not_become_a_harness_error(self):
        with tempfile.TemporaryDirectory(prefix='eski-readiness-control-') as temporary:
            root = Path(temporary)
            config, output = root / 'server.conf', root / 'server.log'
            config.write_text('port 0\n')
            output.write_text('actual fatal startup diagnostic\n')
            script = '''set errors 0
proc start_server_error {config message} {incr ::errors}
''' + READINESS + '''
proc invoke {config output early} {
    set wait_ready [expr {!$early}]
    return [wait_server_started $config $output 2147483647]
}
proc invoke_descriptor {config output} {
    set wait_ready true
    set code undefined
    return [wait_server_started $config $output 2147483647]
}
set config [lindex $argv 0]
set output [lindex $argv 1]
invoke $config $output 1
puts "expected=$errors"
invoke_descriptor $config $output
puts "descriptor=$errors"
invoke $config $output 0
puts "unexpected=$errors"
'''
            path = root / 'control.tcl'
            path.write_text(script)
            result = subprocess.run(['tclsh', str(path), str(config), str(output)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), ['expected=0', 'descriptor=0', 'unexpected=1'])

    def test_generated_launcher_preserves_alias_and_actual_executable_identity(self):
        archive = Path(__file__).resolve().parent / '.redis/redis-7.4.11.tar.gz'
        if not archive.is_file():
            self.skipTest('pinned upstream test archive not present locally')
        with tempfile.TemporaryDirectory(prefix='eski-launcher-control-') as temporary:
            root = Path(temporary) / 'fixture'
            prepare(archive, root, 'redis-7.4.11', sys.executable, hashlib.sha256(archive.read_bytes()).hexdigest(), None)
            launcher = root / 'src/redis-server'
            code = 'import json,os;print(json.dumps([open("/proc/self/cmdline","rb").read().split(bytes([0]))[0].decode(),os.readlink("/proc/self/exe")]))'
            result = subprocess.run([str(launcher), '-c', code], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            alias, executable = json.loads(result.stdout)
            self.assertEqual(alias, str(launcher))
            self.assertEqual(Path(executable).resolve(), Path(sys.executable).resolve())
            receipt = json.loads((root / 'fixture-receipt.json').read_text())
            self.assertEqual(receipt['launcher_sha256'], hashlib.sha256(launcher.read_bytes()).hexdigest())


if __name__ == '__main__':
    unittest.main()
