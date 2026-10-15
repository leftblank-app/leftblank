"""Reject stale live processes even when the replacement bundle looks correct."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import time
import unittest

from running_app import verify_running_app


class RunningAppTests(unittest.TestCase):
    def test_replaced_bundle_does_not_make_old_process_healthy(self):
        with tempfile.TemporaryDirectory(prefix='leftblank-process-', dir=os.environ['TMPDIR']) as temporary:
            root = Path(temporary)
            app = root / 'LeftBlank.app'
            # Copied system binaries such as /bin/sleep violate macOS launch constraints and are
            # killed at exec, so build an ad-hoc signed stand-in instead.
            sleeper = root / 'sleeper'
            subprocess.run(['cc', '-x', 'c', '-o', sleeper, '-'], check=True,
                           input=b'#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n')

            def make_app(build):
                executable = app / 'Contents/MacOS/LeftBlank'
                executable.parent.mkdir(parents=True)
                shutil.copyfile(sleeper, executable)
                executable.chmod(0o755)
                (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleExecutable': 'LeftBlank', 'CFBundleVersion': build,
                }))
                return executable

            executable = make_app('1')
            process = subprocess.Popen([str(executable)])
            try:
                # Wait for exec, without launching or activating the process again.
                deadline = time.monotonic() + 5
                while True:
                    try:
                        self.assertEqual(verify_running_app(app, process.pid, '1')['build'], '1')
                        break
                    except RuntimeError:
                        if time.monotonic() >= deadline:
                            raise
                        time.sleep(0.01)
                with self.assertRaisesRegex(RuntimeError, 'Expected build'):
                    verify_running_app(app, process.pid, '2')
                retired = root / 'Retired.app'
                app.rename(retired)
                make_app('2')
                with self.assertRaises(RuntimeError):
                    verify_running_app(app, process.pid, '2')
                shutil.rmtree(retired)
                with self.assertRaises(RuntimeError):
                    verify_running_app(app, process.pid, '2')
            finally:
                process.terminate()
                process.wait(timeout=5)
            with self.assertRaises(RuntimeError):
                verify_running_app(app, process.pid)


if __name__ == '__main__':
    unittest.main()
