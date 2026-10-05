#!/usr/bin/env python3
"""Run native and UI tests on one iPad simulator."""

import argparse
import codecs
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import shlex
import signal
import subprocess
import sys
import time
import uuid


# Pull requests run every native unit test plus these UI scenarios: writing,
# split view, autosave, preview, rotation, rendering and PDF sharing. Main and
# full dispatches run the complete UI suite.
SMOKE_TESTS = ('LeftBlankUITests/WritingTests/testEditingPersistsAcrossPreviewAndRotation',
               'LeftBlankUITests/WritingTests/testWelcomePreviewAndPDFExport')


def wait_for_tests(process, startup_timeout, execution_timeout):
    """Budget cold Xcode launch separately; only the first test start resets time."""
    started = time.monotonic()
    deadline = started + startup_timeout
    phase = 'startup'
    pending = ''
    decoder = codecs.getincrementaldecoder('utf-8')(errors='replace')
    marker = re.compile(r"^(Test Suite '.+' started at |Test Case '.+' started\.|◇ Test run started\.)", re.MULTILINE)
    with selectors.DefaultSelector() as output:
        output.register(process.stdout, selectors.EVENT_READ)
        while output.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError(f'Xcode test {phase} timed out; startup limit {startup_timeout}s, '
                                   f'execution limit {execution_timeout}s')
            for key, _ in output.select(remaining):
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    output.unregister(key.fileobj)
                    continue
                text = decoder.decode(chunk)
                sys.stdout.write(text)
                sys.stdout.flush()
                if phase == 'startup':
                    pending += text
                    if marker.search(pending):
                        now = time.monotonic()
                        print(f'Xcode test startup completed in {now - started:.1f}s; '
                              f'execution budget {execution_timeout}s', flush=True)
                        phase = 'execution'
                        deadline = now + execution_timeout
                    # Retain an unfinished line, not the entire test log.
                    pending = pending.rsplit('\n', 1)[-1][-65536:]
    process.wait(timeout=max(0, deadline - time.monotonic()))


def run(command, timeout, *, capture=False, check=True, startup_timeout=None):
    limit = f'limit {timeout}s' if startup_timeout is None else f'startup {startup_timeout}s, execution {timeout}s'
    print(f"+ {shlex.join(map(str, command))} ({limit})", flush=True)
    process = subprocess.Popen(command, start_new_session=True,
                               stdout=subprocess.PIPE if capture or startup_timeout else None,
                               stderr=subprocess.STDOUT if capture or startup_timeout else None, text=True)
    try:
        if startup_timeout is None:
            output, _ = process.communicate(timeout=timeout)
        else:
            wait_for_tests(process, startup_timeout, timeout)
            output = None
    except BaseException:
        # Let Xcode finalize failure attachments before removing its workers.
        # A hung process group still has a bounded, unconditional cleanup.
        if startup_timeout is not None:
            try:
                os.killpg(process.pid, signal.SIGINT)
                output, _ = process.communicate(timeout=30)
                if output:
                    print(output, end='', flush=True)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    finally:
        if process.stdout is not None:
            process.stdout.close()
    if check and process.returncode:
        raise subprocess.CalledProcessError(process.returncode, command, output=output)
    return subprocess.CompletedProcess(command, process.returncode, stdout=output)


def inventory(*, timeout=30):
    return json.loads(run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'],
                          timeout, capture=True).stdout)['devices']


def select_device(devices, size):
    runtimes = sorted((runtime for runtime in devices if '.iOS-' in runtime),
                      key=lambda runtime: tuple(map(int, runtime.split('.iOS-')[1].split('-'))),
                      reverse=True)
    for runtime in runtimes:
        matches = [entry for entry in devices[runtime]
                   if 'iPad' in entry['name'] and size in entry['name']]
        if matches:
            device = sorted(matches, key=lambda entry: entry['name'])[0]
            print(f"Using {device['name']} on {runtime}", flush=True)
            return device
    raise RuntimeError(f'No available iOS runtime with a {size} iPad')


def diagnostics(path, device=None):
    commands = [
        ['xcode-select', '-p'],
        ['xcodebuild', '-version'],
        ['sysctl', 'hw.memsize', 'hw.ncpu', 'vm.swapusage'],
        ['vm_stat'],
        ['ps', '-axo', 'pid,ppid,%cpu,%mem,rss,comm'],
        ['xcrun', 'simctl', 'list', 'devices'],
        ['tail', '-n', '200', str(Path.home() / 'Library/Logs/CoreSimulator/CoreSimulator.log')],
    ]
    if device:
        commands.append(['xcrun', 'simctl', 'spawn', device['udid'],
                         'defaults', 'read', 'com.apple.springboard'])
        commands.append(['xcrun', 'simctl', 'spawn', device['udid'], 'log', 'show',
                         '--last', '20m', '--style', 'compact', '--info', '--debug', '--predicate',
                         'eventMessage CONTAINS[c] "orient" OR eventMessage CONTAINS[c] "rotat"'])
    with path.open('w') as output:
        for command in commands:
            output.write(f"+ {shlex.join(command)}\n")
            try:
                timeout = 60 if command[:3] == ['xcrun', 'simctl', 'spawn'] else 10
                result = run(command, timeout, capture=True, check=False)
                output.write(result.stdout)
                print(result.stdout, flush=True)
            except subprocess.TimeoutExpired:
                output.write(f'Diagnostic command timed out after {timeout} seconds.\n')

    # Xcode's bounded diagnostics can omit the actual simulator crash report.
    # Retain only this application's newest reports, with a fixed size limit.
    reports = Path.home() / 'Library/Logs/DiagnosticReports'
    crashes = [report for pattern in ('LeftBlank*.ips', 'LeftBlank*.crash')
               for report in reports.glob(pattern)]
    for report in sorted(crashes, key=lambda item: item.stat().st_mtime, reverse=True)[:3]:
        if report.stat().st_size <= 5 * 1024 * 1024:
            shutil.copy2(report, path.parent / report.name)


def shutdown(device):
    # Cold iOS 26 services can outlast 60 seconds while completing migration.
    # Use the same bounded allowance as appearance setup; never retry tests.
    result = run(['xcrun', 'simctl', 'shutdown', device['udid']], 120, check=False)
    if result.returncode:
        # A failed boot can already be shut down; verify rather than hiding errors.
        states = [entry['state'] for entries in inventory().values()
                  for entry in entries if entry['udid'] == device['udid']]
        if states != ['Shutdown']:
            raise RuntimeError(f"Could not shut down {device['name']}")


def verify_result(bundle, output, *, memory=False):
    summary = json.loads(run(['xcrun', 'xcresulttool', 'get', 'test-results', 'summary',
                              '--path', str(bundle)], 30, capture=True).stdout)
    (output / 'test-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    if summary['result'] != 'Passed' or summary['passedTests'] < 1 or summary['failedTests']:
        raise RuntimeError('Result bundle must contain executed, passing tests')
    if summary.get('runtimeWarnings'):
        raise RuntimeError('Xcode recorded runtime safety warnings; see test-summary.json')
    if memory:
        metrics = run(['xcrun', 'xcresulttool', 'get', 'test-results', 'metrics',
                       '--path', str(bundle)], 30, capture=True).stdout
        (output / 'memory-metrics.json').write_text(metrics)
        measurements = [value for test in json.loads(metrics)
                        if test['testIdentifier'] == 'TabletLifecycleTests/testWorkspaceOwnershipMemory()'
                        for test_run in test['testRuns'] for metric in test_run['metrics']
                        if metric['identifier'] == 'com.apple.dt.XCTMetric_Memory.physical_peak'
                        for value in metric['measurements']]
        if not measurements or any(value <= 0 for value in measurements):
            raise RuntimeError('The ownership workload must record physical peak memory measurements')


def export_coverage(bundle, device, results, size, started):
    products = bundle.parent
    directory = products.parent / 'ProfileData' / device['udid']
    profiles = sorted(path for path in directory.glob('*.profraw') if path.stat().st_mtime >= started)
    profile = directory / 'Coverage.profdata'
    if profiles:
        profile = results / (size + '.profdata')
        run(['xcrun', 'llvm-profdata', 'merge', '-sparse', *map(str, profiles), '-o', str(profile)], 60)
    elif not profile.is_file() or profile.stat().st_mtime < started:
        raise RuntimeError('This simulator run must produce a fresh coverage profile')
    app = products / 'Debug-iphonesimulator/LeftBlank.app'
    executable = app / 'LeftBlank.debug.dylib'
    if not executable.is_file():
        executable = app / 'LeftBlank'
    images = [executable]
    core = products / 'Debug-iphonesimulator/PackageFrameworks/LeftBlankCore.framework/LeftBlankCore'
    if not core.is_file():
        raise RuntimeError('Coverage requires the instrumented shared Core image')
    # Only our app and Core are instrumented for the production denominator.
    # Hosted test runs inject universal Apple XCTest frameworks; those are not
    # production coverage objects and require a separate architecture selection.
    images.append(core)
    objects = [str(images[0])]
    for image in images[1:]:
        objects += ['-object', str(image)]
    report = run(['xcrun', 'llvm-cov', 'export', *objects,
                  '-instr-profile=' + str(profile), '-format=lcov'], 60, capture=True).stdout
    (results / (size + '.lcov')).write_text(report)


def configure_coverage(bundle):
    # Xcode can omit package/app entries when producing a relocatable test run.
    # Declare the two actual instrumented images using Apple's xctestrun schema.
    root = Path(__file__).resolve().parent.parent
    products = bundle.parent
    images = [('LeftBlank.app', 'A00000000000000000000005:primary', 'iPad/Sources',
               'LeftBlank.app/LeftBlank.debug.dylib'),
              ('LeftBlankCore.framework', 'LeftBlankCore:primary', 'Sources/LeftBlankCore',
               'PackageFrameworks/LeftBlankCore.framework/LeftBlankCore')]
    targets = []
    for name, identifier, folder, image in images:
        base = root / folder
        sources = sorted(base.rglob('*.swift'))
        if not sources or not (products / 'Debug-iphonesimulator' / image).is_file():
            raise RuntimeError('Coverage requires the compiled iPad app and shared Core images')
        targets.append({'Name': name, 'BuildableIdentifier': identifier, 'IncludeInReport': True,
                        'IsStatic': False, 'Architectures': ['arm64'],
                        'ProductPaths': ['__TESTROOT__/Debug-iphonesimulator/' + image],
                        'SourceFiles': [str(path.relative_to(base)) for path in sources],
                        'SourceFilesCommonPathPrefix': str(base) + '/',
                        'Toolchains': ['com.apple.dt.toolchain.XcodeDefault']})
    parameters = plistlib.loads(bundle.read_bytes())
    parameters['CodeCoverageBuildableInfos'] = targets
    bundle.write_bytes(plistlib.dumps(parameters))


def test_device(size, device, bundle, results, *, suite='all', memory=False, coverage=True, appearance=None,
                cold_start=False):
    print(f"::group::{size}: boot, native {suite} tests, shutdown", flush=True)
    try:
        if coverage:
            configure_coverage(bundle)
        # bootstatus also initiates the boot and reports migration progress.
        run(['xcrun', 'simctl', 'bootstatus', device['udid'], '-b', '-d'], 240)
        if appearance:
            # A cold hosted simulator can still be initializing UI services after
            # bootstatus completes. Keep a bounded startup allowance and confirm
            # the actual appearance before measuring the test run.
            run(['xcrun', 'simctl', 'ui', device['udid'], 'appearance', appearance], 120)
        if cold_start:
            # iOS 26 can crash/respring SpringBoard during first-boot setup and
            # then acknowledge orientation events without rotating even Settings.
            # A first-boot device also runs tests measurably slower and failed
            # timing-sensitive WebKit tests. Finish migration/preferences before a
            # full boot of the initialized device. This is setup, not a retry.
            shutdown(device)
            run(['xcrun', 'simctl', 'bootstatus', device['udid'], '-b', '-d'], 240)
        if appearance:
            actual = run(['xcrun', 'simctl', 'ui', device['udid'], 'appearance'], 120, capture=True).stdout
            if actual.strip().lower() != appearance:
                raise RuntimeError('Simulator appearance differs from the requested ' + appearance)
        # Xcode's verbose sysdiagnose can spend ten minutes after a test failure.
        # Keep the test report and attachments, then collect our bounded diagnostics.
        selection = []
        if suite != 'all':
            selection = ['-only-testing:' + test for test in
                         ('LeftBlankTabletTests', *(SMOKE_TESTS if suite == 'smoke' else ()))]
        started = time.time()
        run(['xcodebuild', '-xctestrun', str(bundle),
             '-derivedDataPath', str(bundle.parent.parent.parent),
             '-destination', f"platform=iOS Simulator,id={device['udid']}",
             '-destination-timeout', '30', '-parallel-testing-enabled', 'NO',
             '-maximum-concurrent-test-simulator-destinations', '1',
             '-test-timeouts-enabled', 'YES', '-default-test-execution-time-allowance', '150',
             '-maximum-test-execution-time-allowance', '180',
             '-collect-test-diagnostics', 'never',
             '-enableCodeCoverage', 'YES' if coverage else 'NO',
             '-resultBundlePath', str(results / f'{size}.xcresult'),
             *selection, 'test-without-building'], {'all': 1500, 'smoke': 600}.get(suite, 1080),
            startup_timeout=None if suite == 'unit' else 600)
        verify_result(results / f'{size}.xcresult', results, memory=memory)
        if coverage:
            export_coverage(bundle, device, results, size, started)
        return True
    except (RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"::error::{size}: {error}", flush=True)
        if isinstance(error, subprocess.CalledProcessError) and error.output:
            print(error.output, flush=True)
        diagnostics(results / f'{size}-diagnostics.log', device)
        return False
    finally:
        try:
            shutdown(device)
        finally:
            print('::endgroup::', flush=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--size', choices=('11-inch', '13-inch'), required=True)
    parser.add_argument('--suite', choices=('all', 'smoke', 'unit'), default='all',
                        help='smoke runs the native unit tests and the curated SMOKE_TESTS UI scenarios')
    parser.add_argument('--derived-data', type=Path, default=Path('build/iPad'))
    parser.add_argument('--results', type=Path, default=Path('build/iPad-writing'))
    parser.add_argument('--memory', action='store_true')
    parser.add_argument('--no-coverage', action='store_true')
    parser.add_argument('--appearance', choices=('light', 'dark'))
    parser.add_argument('--fresh-device', action='store_true',
                        help='Create a disposable simulator on a hosted CI runner')
    args = parser.parse_args(argv)
    if args.fresh_device and os.environ.get('GITHUB_ACTIONS') != 'true':
        parser.error('--fresh-device is restricted to disposable hosted CI runners')
    root = Path(__file__).resolve().parent.parent
    bundles = list((root / args.derived_data / 'Build/Products').glob('*.xctestrun'))
    if len(bundles) != 1:
        raise RuntimeError('Expected one .xctestrun bundle; run scripts/build-ipad.sh simulator first')
    results = root / args.results
    results.mkdir(parents=True, exist_ok=True)
    run(['sysctl', 'hw.memsize', 'hw.ncpu'], 10)
    print(f'::group::{args.size}: initialize simulator service and discover device', flush=True)
    try:
        # A fresh UI runner has not warmed CoreSimulator through compilation.
        # Allow its first query to initialize services and mount runtimes;
        # subsequent inventory checks retain their short timeout.
        devices = inventory(timeout=180)
        device = select_device(devices, args.size)
        if args.fresh_device:
            runtime = next(runtime for runtime, entries in devices.items() if device in entries)
            name = 'LeftBlank-' + args.size + '-' + uuid.uuid4().hex[:8]
            identifier = run(['xcrun', 'simctl', 'create', name,
                              device['deviceTypeIdentifier'], runtime], 60, capture=True).stdout.strip()
            uuid.UUID(identifier)
            device = dict(device, udid=identifier, name=name)
            print(f'Created disposable simulator {identifier}', flush=True)
    except (RuntimeError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        print(f'::error::{args.size}: simulator discovery failed: {error}', flush=True)
        diagnostics(results / f'{args.size}-discovery-diagnostics.log')
        return 1
    finally:
        print('::endgroup::', flush=True)
    options = {}
    if args.fresh_device:
        options['cold_start'] = True
    if args.appearance:
        options['appearance'] = args.appearance
    if args.suite != 'all':
        options['suite'] = args.suite
    if args.memory:
        options['memory'] = True
    if args.no_coverage:
        options['coverage'] = False
    try:
        return 0 if test_device(args.size, device, bundles[0], results, **options) else 1
    finally:
        if args.fresh_device:
            run(['xcrun', 'simctl', 'delete', device['udid']], 60)


if __name__ == '__main__':
    # Give the current simulator its cleanup even when Actions cancels the step.
    def cancelled(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, cancelled)
    try:
        sys.exit(main())
    except (RuntimeError, subprocess.SubprocessError) as error:
        print(f'::error::{error}', flush=True)
        sys.exit(1)
