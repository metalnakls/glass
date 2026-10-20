"""Exercise the real installer in a temporary folder with build/signing stubs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class BuildInstallTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="glass-install-check-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.installed = self.root / "Applications/Glass.app"
        self.product = self.root / ".build/Xcode/Build/Products/Debug/Glass.app"
        scripts = self.root / "Scripts"
        scripts.mkdir()
        original = Path(__file__).resolve().parents[2] / "Scripts/build-mac-app.sh"
        source = original.read_text()
        self.assertEqual(source.count('INSTALL_DIR="/Applications/Glass.app"'), 1)
        # The production entry point stays intact; only its absolute installation
        # destination is redirected to the fixture. No command can touch Glass.
        source = source.replace('INSTALL_DIR="/Applications/Glass.app"',
                                'INSTALL_DIR="' + str(self.installed) + '"')
        self.script = scripts / "build-mac-app.sh"
        self.script.write_text(source)
        self.script.chmod(0o755)
        self.make_app(self.installed, {"Contents/MacOS/Glass": "old",
                                    "Contents/PlugIns/QuickLook/Resources/default.metallib": "obsolete"})
        self.make_app(self.product, {"Contents/MacOS/Glass": "new",
                                  "Contents/Resources/title.txt": "current"})
        self.original_files = self.contents(self.installed)
        self.original_inode = self.installed.stat().st_ino
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        self.environment = dict(os.environ, PATH=str(bin_dir) + ":" + os.environ["PATH"],
                                GLASS_CODESIGN_IDENTITY="1" * 40, GLASS_SKIP_INSTALL="0",
                                FIXTURE_PRODUCT=str(self.product))
        self.executable(bin_dir / "xcodebuild", "#!/bin/sh\nexit 0\n")
        self.executable(bin_dir / "security", '#!/bin/sh\necho \'1) ' + "1" * 40 + ' "Apple Development: Fixture"\'\n')
        self.executable(bin_dir / "codesign", '''#!/usr/bin/env python3
import json, pathlib, sys
if '--verify' in sys.argv:
    app = pathlib.Path(sys.argv[-1])
    actual = {str(p.relative_to(app)): p.read_text() for p in app.rglob('*') if p.is_file() and p.name != '.fixture-seal'}
    expected = json.loads((app / '.fixture-seal').read_text())
    if actual != expected:
        print('fixture signature mismatch', file=sys.stderr)
        sys.exit(1)
''')
        self.executable(bin_dir / "ditto", '''#!/usr/bin/env python3
import os, pathlib, shutil, sys
source, destination = map(pathlib.Path, sys.argv[1:])
if os.environ.get('FIXTURE_FAIL_INSTALL') == '1' and str(source) == os.environ['FIXTURE_PRODUCT']:
    (destination / 'partial-copy').write_text('incomplete')
    sys.exit(17)
shutil.copytree(source, destination, dirs_exist_ok=True)
''')

    def executable(self, path, source):
        path.write_text(source)
        path.chmod(0o755)

    def make_app(self, app, files):
        for relative, text in files.items():
            path = app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        (app / ".fixture-seal").write_text(json.dumps(files, sort_keys=True))

    def contents(self, app):
        return {str(path.relative_to(app)): path.read_bytes() for path in app.rglob("*") if path.is_file()}

    def run_install(self, fail=False):
        environment = dict(self.environment)
        if fail:
            environment["FIXTURE_FAIL_INSTALL"] = "1"
        return subprocess.run([str(self.script), "debug"], env=environment, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_replaces_obsolete_resources_and_retains_app_wrapper(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.contents(self.installed), self.contents(self.product))
        self.assertEqual(self.installed.stat().st_ino, self.original_inode)
        self.assertEqual(self.contents(self.root / ".app-backups/Glass.app.backup"), self.original_files)

    def test_failed_copy_restores_previous_contents(self):
        result = self.run_install(fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.contents(self.installed), self.original_files)
        self.assertEqual(self.installed.stat().st_ino, self.original_inode)
        self.assertEqual(self.contents(self.root / ".app-backups/Glass.app.backup"), self.original_files)


if __name__ == "__main__":
    unittest.main()
