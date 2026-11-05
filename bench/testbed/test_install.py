import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location('eski_testbed_install', Path(__file__).with_name('install.py'))
install = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(install)
REPOSITORY = Path(__file__).resolve().parents[2]
DESIGN = Path(__file__).with_name('design.json')


def sha(data):
    return hashlib.sha256(data).hexdigest()


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.work = Path(self.temporary.name)
        archive = self.work / 'eski-fixture.tar'
        archive.write_bytes(b'fixture image archive')
        (self.work / 'eski-fixture.tar.sha256').write_text(sha(archive.read_bytes()) + '  eski-fixture.tar\n')
        self.manifest = dict(image='eski:local', image_id='sha256:' + 'e' * 64, source_revision='dev', source_sha256='5' * 64,
                             binary=dict(path='/usr/local/bin/eski', sha256='b' * 64, version='eski v=0.1.0'),
                             archive=dict(path=str(archive), sha256=sha(archive.read_bytes())))
        self.manifest_path = self.work / 'image.json'
        self.manifest_path.write_text(json.dumps(self.manifest))
        self.overlay = self.work / 'overlay.tar'
        self.built = install.build_overlay(REPOSITORY, DESIGN, self.manifest_path, 'comparison-v1', self.overlay)
        self.base = self.work / 'base'
        self.base.mkdir()
        (self.base / 'earlier-root').mkdir()
        (self.base / 'earlier-root' / 'marker').write_text('untouched')

    def tearDown(self):
        self.temporary.cleanup()

    def test_overlay_packs_runner_plans_design_and_image(self):
        with tarfile.open(self.overlay) as handle:
            names = set(handle.getnames())
            overlay = json.load(handle.extractfile('overlay.json'))
            shipped = json.load(handle.extractfile('image.json'))
            modes = {member.name: member.mode for member in handle.getmembers()}
            contents = {name: handle.extractfile(name).read() for name in overlay['files']}
        for name in install.RUNNER:
            self.assertIn('workspace/bench/' + name, names)
            self.assertEqual(contents['workspace/bench/' + name], (REPOSITORY / 'bench' / name).read_bytes())
        for name in ('workspace/bench/testbed/fill.sh', 'workspace/plans/benchmark/plan.json', 'workspace/plans/calibration/experiment.json',
                     'design.json', 'install.py', 'images/eski-fixture.tar', 'images/eski-fixture.tar.sha256'):
            self.assertIn(name, names)
        self.assertEqual({name: sha(data) for name, data in contents.items()}, overlay['files'])
        self.assertEqual(shipped['archive']['path'], 'images/eski-fixture.tar')
        self.assertEqual(overlay['image_id'], self.manifest['image_id'])
        self.assertTrue(modes['workspace/bench/exam.sh'] & stat.S_IXUSR)
        self.assertTrue(modes['workspace/bench/testbed/fill.sh'] & stat.S_IXUSR)
        self.assertEqual(self.built['sha256'], install.sha(self.overlay))
        self.assertFalse(any('test_' in name or '__pycache__' in name for name in names))

    def test_overlay_refuses_an_unverified_image(self):
        broken = dict(self.manifest, archive=dict(self.manifest['archive'], sha256='0' * 64))
        self.manifest_path.write_text(json.dumps(broken))
        with self.assertRaisesRegex(ValueError, 'sha256'):
            install.build_overlay(REPOSITORY, DESIGN, self.manifest_path, 'other', self.work / 'other.tar')
        self.manifest_path.write_text(json.dumps(dict(self.manifest, archive=None)))
        with self.assertRaisesRegex(ValueError, 'no exported archive'):
            install.build_overlay(REPOSITORY, DESIGN, self.manifest_path, 'other', self.work / 'other.tar')

    def fakes(self, fail=False, drivers=()):
        calls = []

        def inventory():
            calls.append('inventory')
            return dict(cmdline='BOOT_IMAGE=/vmlinuz nosmt modprobe.blacklist=i915', modules=sorted(['xfs', 'overlay', *drivers]),
                        drm=dict(available=True, entries=['card0', 'renderD128'] if drivers else [], cards={'card0': drivers[0]} if drivers else {}), timer_migration=1)

        def jq(partial, design):
            calls.append('jq')
            path = partial / 'workspace' / 'tools' / 'bin' / 'jq'
            path.parent.mkdir(parents=True)
            path.write_text('#!/bin/sh\n')
            return dict(packages=design['tools']['jq']['packages'], version='jq-1.7.1')

        def eski(partial, manifest):
            calls.append('eski')
            self.assertEqual(install.sha(partial / manifest['archive']['path']), manifest['archive']['sha256'])
            return dict(reference='eski:local', image_id='sha256:' + 'c' * 64, built_image_id=manifest['image_id'], version='eski v=0.1.0')

        def engine(reference):
            calls.append(reference)
            return dict(reference=reference, image_id=reference.split('@')[1], pulled=True)

        def check(root):
            calls.append('check')
            self.assertTrue((root / 'workspace' / 'profile.json').is_file())
            if fail:
                raise ValueError('preflight rejected: fixture')
            identity = lambda phase, repetitions: dict(sha256=phase[0] * 64, plan_sha256='1' * 64, profile_sha256='2' * 64,
                                                       config=dict(targets=['eski-docker', 'redis', 'valkey', 'dragonfly'], repetitions=repetitions, cpus=dict(server=[1])),
                                                       host=dict(cpu_model='Fixture CPU'), files={'bench/' + name: '3' * 64 for name in install.RUNNER})
            return dict(phases=dict(calibration=identity('calibration', 1), benchmark=identity('benchmark', 4)))
        return calls, dict(check=check, jq=jq, eski=eski, engine=engine, inventory=inventory)

    def arguments(self, root='comparison-v1', accept=False):
        return argparse.Namespace(base=str(self.base), root=root, overlay=str(self.overlay), sha256=self.built['sha256'], accept_display_driver=accept)

    def test_a_loaded_display_driver_is_refused_before_any_download_unless_accepted(self):
        calls, fakes = self.fakes(drivers=('i915',))
        with self.assertRaisesRegex(ValueError, 'display driver is loaded: i915.*modprobe.blacklist=i915.*--accept-display-driver'):
            install.remote(self.arguments(), **fakes)
        self.assertEqual(calls, ['inventory'])
        self.assertFalse((self.base / 'comparison-v1').exists())
        self.assertFalse(list(self.base.glob('.comparison-v1.partial-*')))
        calls, fakes = self.fakes(drivers=('i915',))
        self.assertEqual(install.remote(self.arguments(accept=True), **fakes), 0)
        machine = json.loads((self.base / 'comparison-v1' / 'protocol.json').read_text())['machine']
        self.assertEqual((machine['display_drivers'], machine['display_driver_accepted'], machine['cpu_model']), (['i915'], True, 'Fixture CPU'))
        self.assertEqual(machine['drm']['cards'], {'card0': 'i915'})
        self.assertIn('modprobe.blacklist=i915', machine['cmdline'])
        self.assertEqual(machine['timer_migration'], 1)
        self.assertIn('i915', machine['modules'])

    def test_remote_installs_a_new_root_beside_earlier_ones_without_starting(self):
        calls, fakes = self.fakes()
        self.assertEqual(install.remote(self.arguments(), **fakes), 0)
        root = self.base / 'comparison-v1'
        profile = json.loads((root / 'workspace' / 'profile.json').read_text())
        files = {str(path.relative_to(root / 'workspace')): install.sha(path) for path in (root / 'workspace').rglob('*') if path.is_file() and path.name != 'profile.json'}
        self.assertEqual(profile['files'], files)
        self.assertEqual(profile['images']['cli'], profile['images']['redis'])
        self.assertEqual(profile['images']['eski-docker'], 'sha256:' + 'c' * 64)
        self.assertEqual(profile['dragonfly_threads'], 1)
        self.assertEqual(profile['schema'], 'eski-exam-profile-v1')
        protocol = json.loads((root / 'protocol.json').read_text())
        self.assertEqual(protocol['phases']['benchmark']['identity'], 'b' * 64)
        self.assertEqual((protocol['machine']['display_drivers'], protocol['machine']['display_driver_accepted']), ([], False))
        self.assertEqual(protocol['machine']['modules'], ['overlay', 'xfs'])
        self.assertEqual(protocol['machine']['cmdline'], 'BOOT_IMAGE=/vmlinuz nosmt modprobe.blacklist=i915')
        self.assertEqual(protocol['phases']['calibration']['identity'], 'c' * 64)
        self.assertEqual(protocol['design']['gates']['power_source'], 'mains')
        for phase in ('calibration', 'benchmark'):
            self.assertEqual(json.loads((root / 'workspace' / 'plans' / phase / 'experiment.json').read_text())['power_source'], 'mains')
        receipt = json.loads((root / 'install.json').read_text())
        self.assertFalse(receipt['started'])
        self.assertEqual(receipt['protocol_sha256'], install.sha(root / 'protocol.json'))
        self.assertEqual(receipt['planned_measurements'], dict(calibration=4, benchmark=32 * 4))
        self.assertEqual(receipt['siblings'], ['earlier-root'])
        self.assertEqual(receipt['overlay']['sha256'], self.built['sha256'])
        self.assertTrue(os.access(root / 'exam.sh', os.X_OK))
        self.assertTrue(os.access(root / 'fill.sh', os.X_OK))
        engines = json.loads((root / 'engines.json').read_text())['engines']
        self.assertEqual([engine['target'] for engine in engines], ['eski-docker', 'redis', 'valkey', 'dragonfly'])
        self.assertEqual(engines[1]['version'], '7.4.12')
        self.assertFalse((root / 'control').exists())
        self.assertEqual((self.base / 'earlier-root' / 'marker').read_text(), 'untouched')
        self.assertEqual(sorted(path.name for path in self.base.iterdir()), ['comparison-v1', 'earlier-root'])
        self.assertEqual(calls[0:3], ['inventory', 'jq', 'eski'])
        self.assertEqual(calls[-1], 'check')
        with self.assertRaisesRegex(ValueError, 'already exists'):
            install.remote(self.arguments(), **self.fakes()[1])

    def test_failed_preflight_leaves_the_root_name_free(self):
        _, fakes = self.fakes(fail=True)
        with self.assertRaisesRegex(ValueError, 'preflight rejected'):
            install.remote(self.arguments(), **fakes)
        self.assertFalse((self.base / 'comparison-v1').exists())
        self.assertEqual(len(list(self.base.glob('.failed-comparison-v1-*'))), 1)
        self.assertFalse(list(self.base.glob('.comparison-v1.partial-*')))

    def test_transfer_hash_mismatch_is_refused(self):
        arguments = self.arguments()
        arguments.sha256 = '0' * 64
        with self.assertRaisesRegex(ValueError, 'overlay sha256'):
            install.remote(arguments, **self.fakes()[1])
        self.assertFalse((self.base / 'comparison-v1').exists())

    def test_tampered_overlay_is_refused(self):
        with tarfile.open(self.overlay) as handle:
            members = [(member, handle.extractfile(member).read() if member.isfile() else None) for member in handle.getmembers()]
        tampered = self.work / 'tampered.tar'
        with tarfile.open(tampered, 'w') as handle:
            for member, data in members:
                if member.name == 'workspace/bench/run.sh':
                    data = data + b'\n'
                    member.size = len(data)
                handle.addfile(member, __import__('io').BytesIO(data) if data is not None else None)
        arguments = argparse.Namespace(base=str(self.base), root='comparison-v1', overlay=str(tampered), sha256=install.sha(tampered))
        with self.assertRaisesRegex(ValueError, 'changed in transit'):
            install.remote(arguments, **self.fakes()[1])
        self.assertFalse(list(self.base.glob('.comparison-v1.partial-*')))


if __name__ == '__main__':
    unittest.main()
