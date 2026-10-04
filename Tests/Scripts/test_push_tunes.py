"""Exercise publication against a local bare remote, never GitHub."""
import json
import pathlib
import runpy
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class PublishTunesTests(unittest.TestCase):
    def test_config_only_publication(self):
        with tempfile.TemporaryDirectory() as folder:
            base = pathlib.Path(folder)
            remote, checkout = base / 'remote.git', base / 'checkout'
            def git(*args, cwd=checkout):
                return subprocess.check_output(['git', *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL).strip()
            subprocess.run(['git', 'init', '--bare', '--quiet', str(remote)], check=True)
            checkout.mkdir()
            git('init', '--quiet', '-b', 'main')
            git('config', 'user.name', 'Fixture')
            git('config', 'user.email', 'fixture@example.invalid')
            git('remote', 'add', 'origin', str(remote))
            (checkout / 'VERSION').write_text('2.0\n')
            git('add', 'VERSION')
            git('commit', '--quiet', '-m', 'fixture')
            git('push', '--quiet', 'origin', 'main')
            main = git('rev-parse', 'HEAD')
            source = base / 'AppearanceDefaults.json'
            source.write_text(json.dumps({'GlassList.highlightColorDark': '121212'}))
            namespace = runpy.run_path(str(ROOT / 'Scripts/push-tunes'))
            command = namespace['main']
            command.__globals__.update(ROOT=checkout, SOURCE=source)
            argv = sys.argv
            sys.argv = ['push-tunes']
            try:
                command()
                first = git('ls-remote', 'origin', 'refs/heads/tunes')
                command()  # Unchanged config must not create another commit.
                self.assertEqual(first, git('ls-remote', 'origin', 'refs/heads/tunes'))
                source.write_text(json.dumps({'GlassList.highlightColorDark': '232323'}))
                command()
            finally:
                sys.argv = argv
            self.assertEqual(git('rev-parse', 'HEAD'), main)
            self.assertEqual(git('branch', '--show-current'), 'main')
            self.assertEqual(git('status', '--porcelain'), '')
            self.assertEqual(git('ls-remote', 'origin', 'refs/heads/main').split()[0], main)
            git('fetch', '--quiet', 'origin', 'tunes')
            self.assertEqual(git('ls-tree', '--name-only', 'FETCH_HEAD'), 'AppearanceDefaults.json')
            self.assertEqual(json.loads(git('show', 'FETCH_HEAD:AppearanceDefaults.json'))['GlassList.highlightColorDark'], '232323')
            self.assertEqual(git('rev-list', '--count', 'FETCH_HEAD'), '2')


if __name__ == '__main__':
    unittest.main()
