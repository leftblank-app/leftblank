#!/usr/bin/env python3
"""Cold-launch a relocated app without SwiftPM's build-directory fallback.

Runs with a fresh library and saved read-only MCP access, as after an update.
Only the process group created here is terminated.
Use after building, never concurrently with a build using the same resources.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import subprocess
import tempfile
import time
import uuid

from running_app import verify_running_app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('build/LeftBlank.app'))
    parser.add_argument('--development-resources', type=Path, required=True)
    parser.add_argument('--artifacts', type=Path, default=Path('build/launch-smoke'))
    parser.add_argument('--hurl', type=Path, help='Run the MCP authoring contract (CI only)')
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    resources = args.development_resources.resolve(strict=True)
    if resources.name != 'LeftBlank_LeftBlankCore.bundle':
        parser.error('Expected the SwiftPM LeftBlank_LeftBlankCore.bundle directory')
    artifacts = args.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    hurl = args.hurl.resolve(strict=True) if args.hurl else None
    contract = Path(__file__).resolve().parent.parent / 'Tests/MCP/authoring-guides.hurl'
    # Require an explicitly configured temporary directory (SSD locally).
    temp_root = Path(os.environ['TMPDIR']).resolve(strict=True)
    hidden = resources.with_name(resources.name + '.smoke-' + uuid.uuid4().hex)
    with tempfile.TemporaryDirectory(prefix='leftblank-launch-', dir=temp_root) as temporary:
        root = Path(temporary)
        relocated = root / 'LeftBlank.app'
        shutil.copytree(app, relocated, symlinks=True)
        state = root / 'State'
        # A clean install leaves MCP disabled and never loads its authoring catalog.
        # Resume a saved grant so startup exercises the same path as an existing user.
        access = state / 'MCP/access.json'
        access.parent.mkdir(parents=True, mode=0o700)
        access.write_text(json.dumps({'token': secrets.token_hex(32), 'grantID': str(uuid.uuid4()),
                                      'documentIDs': [], 'canWrite': False}))
        access.chmod(0o600)
        process = None
        resources.rename(hidden)
        try:
            with (artifacts / 'process.log').open('wb') as output:
                process = subprocess.Popen(
                    [str(relocated / 'Contents/MacOS/LeftBlank'), '-appLanguage', 'zh-Hans',
                     '-SUEnableAutomaticChecks', 'NO'],
                    cwd=root, env={**os.environ, 'LEFTBLANK_STATE_DIR': str(state)},
                    stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                deadline = time.monotonic() + 30
                events_file = state / 'Logs/events.jsonl'
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise RuntimeError(f'Relocated app exited early: {process.returncode}')
                    events = []
                    if events_file.exists():
                        for line in events_file.read_text().splitlines():
                            try:
                                events.append(json.loads(line))
                            except json.JSONDecodeError:
                                pass  # A live append may not be complete yet.
                    ready = any(event.get('event') == 'service.ready' for event in events)
                    icon_loaded = any(event.get('event') == 'application.iconLoaded' for event in events)
                    localized = any('此中有真意，欲辨已忘言' in source.read_text()
                                    for source in (state / 'Library/Documents').glob('*/main.typ'))
                    descriptor = state / 'MCP/connection.json'
                    if ready and localized and icon_loaded and descriptor.exists():
                        verify_running_app(relocated, process.pid)
                        if hurl:
                            connection = json.loads(descriptor.read_text())
                            with (artifacts / 'mcp-hurl.log').open('wb') as report:
                                try:
                                    result = subprocess.run(
                                        [str(hurl), '--test', '--max-time', '10', '--secret',
                                         'token=' + connection['authentication']['token'], '--variable',
                                         'url=' + connection['url'], str(contract)],
                                        stdout=report, stderr=subprocess.STDOUT, timeout=60,
                                    )
                                except subprocess.TimeoutExpired:
                                    raise RuntimeError('Packaged MCP authoring contract timed out; '
                                                       'see mcp-hurl.log') from None
                            if result.returncode:
                                raise RuntimeError('Packaged MCP authoring contract failed; see mcp-hurl.log')
                        if process.poll() is not None:
                            raise RuntimeError(f'Relocated app exited during MCP checks: {process.returncode}')
                        print('PASS: relocated app launched, app icon and Chinese resources loaded, '
                              'library created, Tinymist ready, saved MCP access resumed.' +
                              (' Authoring Hurl contract passed.' if hurl else ''))
                        return
                    time.sleep(0.1)
                raise RuntimeError('App did not reach a localized library, ready typesetting service '
                                   'and resumed MCP connection in 30 seconds')
        finally:
            if process is not None:
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
                except ProcessLookupError:
                    pass
            hidden.rename(resources)
            logs = state / 'Logs'
            if logs.exists():
                shutil.copytree(logs, artifacts / 'Logs', dirs_exist_ok=True)


if __name__ == '__main__':
    main()
