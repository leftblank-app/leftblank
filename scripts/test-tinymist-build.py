#!/usr/bin/env python3
"""Every Mac channel bundles the pinned Tinymist source build with LeftBlank's patches."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
PATCHES = ('scripts/tinymist-native-tls.patch', 'scripts/tinymist-vfs.patch')


def expected_stamp(root=ROOT):
    return subprocess.check_output([str(root / 'scripts/build-tinymist.sh'), '--stamp'], cwd=root, text=True)


class TinymistBuildTests(unittest.TestCase):
    def test_stamp_records_the_vfs_and_native_tls_patches(self):
        stamp = expected_stamp()
        self.assertIn('tinymist 0.15.8 32f908199ee17ea295512bbc27166e890c438175\n', stamp)
        for patch in PATCHES:
            digest = hashlib.sha256((ROOT / patch).read_bytes()).hexdigest()
            self.assertIn(f'patch {patch} {digest}\n', stamp)

    def test_binary_in_use_was_built_from_current_inputs(self):
        binary, stamp = ROOT / '.tools/tinymist', ROOT / '.tools/tinymist.stamp'
        self.assertTrue(binary.is_file(), 'Run scripts/bootstrap.sh to build .tools/tinymist first')
        self.assertEqual(stamp.read_text(), expected_stamp(),
                         '.tools/tinymist predates the current patches; run scripts/build-tinymist.sh')
        subprocess.run([str(ROOT / 'scripts/build-tinymist.sh'), '--check'], cwd=ROOT, check=True)
        self.assertIn('v0.15.8', subprocess.check_output([str(binary), '--version'], text=True))

    def test_check_rejects_release_or_stale_binaries(self):
        with tempfile.TemporaryDirectory(prefix='leftblank-tinymist-', dir=os.environ.get('TMPDIR')) as temporary:
            root = Path(temporary)
            (root / 'scripts').mkdir()
            for name in ('build-tinymist.sh', *(Path(patch).name for patch in PATCHES)):
                shutil.copy2(ROOT / 'scripts' / name, root / 'scripts' / name)
            (root / '.tools').mkdir()
            binary = root / '.tools/tinymist'
            binary.write_text('#!/bin/sh\necho "Build Git Describe:  v0.15.8"\n')
            binary.chmod(0o755)

            def check():
                return subprocess.run([str(root / 'scripts/build-tinymist.sh'), '--check'], cwd=root,
                                      capture_output=True).returncode

            self.assertNotEqual(check(), 0, 'An unstamped upstream release binary must be rejected')
            (root / '.tools/tinymist.stamp').write_text(expected_stamp(root))
            self.assertEqual(check(), 0)
            patch = root / 'scripts/tinymist-vfs.patch'
            patch.write_text(patch.read_text() + '\n')
            self.assertNotEqual(check(), 0, 'A changed patch must force a rebuild')

    def test_every_distribution_packages_the_patched_build(self):
        package = (ROOT / 'scripts/package-app.py').read_text()
        self.assertNotIn('tinymist-appstore', package)
        self.assertIn("['scripts/build-tinymist.sh', '--check']", package)
        bootstrap = (ROOT / 'scripts/bootstrap.sh').read_text()
        self.assertIn('scripts/build-tinymist.sh', bootstrap)
        self.assertNotIn('releases/download', bootstrap)
        # The iPad engine carries the same VFS fix.
        self.assertIn('scripts/tinymist-vfs.patch', (ROOT / 'scripts/prepare-ipad-engine.sh').read_text())

    def test_ci_caches_the_binary_by_its_inputs(self):
        key = re.compile(r"key: mac-tinymist-[^\n]*hashFiles\('scripts/build-tinymist.sh', "
                         r"'scripts/tinymist-native-tls.patch', 'scripts/tinymist-vfs.patch'\)")
        for workflow, jobs in (('ci.yml', 2), ('release.yml', 2)):
            text = (ROOT / '.github/workflows' / workflow).read_text()
            self.assertEqual(len(key.findall(text)), jobs, workflow)
            self.assertNotIn('tinymist-appstore', text)
            # Each job restores or builds the helper before anything packages or tests it.
            for job in re.split(r'\n  [a-z-]+:\n    name:', text):
                if 'scripts/test.sh' in job or 'scripts/release.sh' in job or 'release-appstore.sh' in job:
                    build = job.index('run: scripts/build-tinymist.sh')
                    consumer = min(job.index(script) for script in
                                   ('scripts/test.sh', 'scripts/release.sh', 'release-appstore.sh') if script in job)
                    self.assertLess(job.index('Restore patched Tinymist'), build)
                    self.assertLess(build, consumer)


if __name__ == '__main__':
    unittest.main()
