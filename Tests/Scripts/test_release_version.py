"""Exercise version reservations and the real release entry point without publishing."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release_version', ROOT / 'Scripts/check-release-version.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class ReleaseVersionTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.root = Path(self.folder.name)
        self.git('init', '--quiet', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.version('8.6')
        self.baseline = self.git('rev-parse', 'HEAD')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, stderr=subprocess.DEVNULL).strip()

    def version(self, value):
        (self.root / 'VERSION').write_text(value + '\n')
        self.git('add', 'VERSION')
        self.git('commit', '--quiet', '-m', 'fixture')

    def check(self, requested=None):
        return CHECK.validate(self.root, '8.6', self.baseline, requested)

    def test_followup_fixes_keep_pending_version(self):
        self.version('8.7')
        (self.root / 'fix').write_text('another fix')
        self.git('add', 'fix')
        self.git('commit', '--quiet', '-m', 'fix')
        self.assertEqual(self.check(), '8.7')

    def test_rejects_the_reported_8_7_to_8_10_drift(self):
        self.version('8.7')
        self.version('8.8')
        self.version('8.9')
        self.version('8.10')
        with self.assertRaisesRegex(ValueError, 'already reserved 8.7'):
            self.check()

    def test_correction_needs_no_history_rewrite(self):
        self.version('8.7')
        self.version('8.8')
        self.version('8.7')
        self.assertEqual(self.check(), '8.7')

    def test_explicit_target_must_match_exactly(self):
        self.version('8.7')
        self.version('8.10')
        self.assertEqual(self.check('8.10'), '8.10')
        with self.assertRaisesRegex(ValueError, 'does not match'):
            self.check('8.11')

    def test_rejects_already_published_and_uncommitted_versions(self):
        with self.assertRaisesRegex(ValueError, 'already published'):
            self.check()
        self.version('8.7')
        (self.root / 'VERSION').write_text('8.8\n')
        with self.assertRaisesRegex(ValueError, 'Commit the reserved VERSION'):
            self.check()

    def test_next_publication_starts_a_new_batch(self):
        self.version('8.7')
        published = self.git('rev-parse', 'HEAD')
        self.version('8.8')
        self.assertEqual(CHECK.validate(self.root, '8.7', published), '8.8')

    def test_release_script_stops_before_build_and_publication(self):
        self.version('8.7')
        self.version('8.10')
        scripts, binaries = self.root / 'Scripts', self.root / 'bin'
        scripts.mkdir()
        binaries.mkdir()
        for name in ['release.sh', 'check-release-version.py']:
            shutil.copy2(ROOT / 'Scripts' / name, scripts / name)
        build = scripts / 'build-mac-app.sh'
        build.write_text('#!/bin/sh\ntouch "' + str(self.root / 'build-ran') + '"\nexit 99\n')
        build.chmod(0o755)
        gh = binaries / 'gh'
        gh.write_text('#!/bin/sh\n[ "${GLASS_TEST_LOOKUP_FAIL:-}" = 1 ] && exit 1\ncase "$2" in\n*/releases/latest) echo \'{"tag_name":"v8.6"}\' ;;\n'
                      '*/commits/v8.6) echo ' + self.baseline + ' ;;\n*) exit 91 ;;\nesac\n')
        gh.chmod(0o755)
        env = dict(os.environ, PATH=str(binaries) + os.pathsep + os.environ['PATH'])
        env.pop('GLASS_REQUESTED_RELEASE_VERSION', None)
        result = subprocess.run(['bash', str(scripts / 'release.sh')], env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('already reserved 8.7', result.stderr)
        self.assertFalse((self.root / 'build-ran').exists())
        env['GLASS_TEST_LOOKUP_FAIL'] = '1'
        result = subprocess.run(['bash', str(scripts / 'release.sh')], env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Release version check failed', result.stderr)
        self.assertFalse((self.root / 'build-ran').exists())


if __name__ == '__main__':
    unittest.main()
