#!/usr/bin/env python3
"""Offline CI contracts for simulator resource ownership and bounded failures."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import ipad_simulator as runner


DEVICES = [('11-inch', {'name': 'iPad Air 11-inch', 'udid': 'small'}),
           ('13-inch', {'name': 'iPad Air 13-inch', 'udid': 'large'})]


class SimulatorContracts(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='ipad-simulator-contract-', dir=os.environ['TMPDIR'])
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.quiet = contextlib.redirect_stdout(io.StringIO())
        self.quiet.__enter__()
        self.addCleanup(self.quiet.__exit__, None, None, None)

    def test_newest_runtime_for_requested_size(self):
        inventory = {
            'com.apple.CoreSimulator.SimRuntime.iOS-26-10': [DEVICES[0][1]],
            'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [device for _, device in DEVICES],
            'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [device for _, device in DEVICES],
        }
        for size, device in DEVICES:
            self.assertEqual(runner.select_device(inventory, size), device)
        with self.assertRaises(RuntimeError):
            runner.select_device({'com.apple.CoreSimulator.SimRuntime.iOS-26-10': [DEVICES[0][1]]}, '13-inch')

    def test_invocation_requires_one_explicit_size_before_any_boot(self):
        with patch.object(runner, 'inventory') as inventory, contextlib.redirect_stderr(io.StringIO()):
            for arguments in ([], ['--size', 'both']):
                with self.assertRaises(SystemExit) as error:
                    runner.main(arguments)
                self.assertEqual(error.exception.code, 2)
            inventory.assert_not_called()

    def prepare_bundle(self):
        bundle = self.root / 'build/iPad/Build/Products/test.xctestrun'
        bundle.parent.mkdir(parents=True)
        bundle.touch()
        return bundle

    def test_cold_discovery_waits_past_old_limit_then_runs_requested_suite(self):
        bundle = self.prepare_bundle()
        devices = {'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [device for _, device in DEVICES]}

        def command(args, timeout, **_options):
            if args[:3] == ['xcrun', 'simctl', 'list']:
                # Model a cold service that cannot return within the old limit.
                if timeout < 90:
                    raise subprocess.TimeoutExpired(args, timeout)
                self.assertLessEqual(timeout, 180)
                return subprocess.CompletedProcess(args, 0, stdout=json.dumps({'devices': devices}))
            return subprocess.CompletedProcess(args, 0)

        with patch.object(runner, '__file__', str(self.root / 'scripts/ipad_simulator.py')), \
             patch.object(runner, 'run', side_effect=command), \
             patch.object(runner, 'test_device', return_value=True) as tests:
            self.assertEqual(runner.main(['--size', '13-inch']), 0)
        tests.assert_called_once_with('13-inch', DEVICES[1][1], bundle, self.root / 'build/iPad-writing')

    def test_fresh_device_owns_only_created_simulator_even_on_failure(self):
        self.prepare_bundle()
        existing = dict(DEVICES[1][1], deviceTypeIdentifier='iPad-Air-13-inch')
        devices = {'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [existing]}
        identifier = '12345678-1234-1234-1234-123456789abc'
        for outcome in (True, False, RuntimeError('test process failed')):
            with self.subTest(outcome=outcome), \
                 patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}), \
                 patch.object(runner, '__file__', str(self.root / 'scripts/ipad_simulator.py')), \
                 patch.object(runner, 'inventory', return_value=devices), \
                 patch.object(runner, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=identifier)) as run, \
                 patch.object(runner, 'test_device') as tests:
                if isinstance(outcome, Exception):
                    tests.side_effect = outcome
                    with self.assertRaises(RuntimeError):
                        runner.main(['--size', '13-inch', '--fresh-device'])
                else:
                    tests.return_value = outcome
                    self.assertEqual(runner.main(['--size', '13-inch', '--fresh-device']), 0 if outcome else 1)
                created = tests.call_args.args[1]
                self.assertTrue(tests.call_args.kwargs['cold_start'])
                self.assertEqual(created['udid'], identifier)
                self.assertNotEqual(created['udid'], existing['udid'])
                create = next(call.args[0] for call in run.call_args_list if call.args[0][1:3] == ['simctl', 'create'])
                self.assertEqual(create[-2:], ['iPad-Air-13-inch', 'com.apple.CoreSimulator.SimRuntime.iOS-26-2'])
                self.assertEqual(run.call_args.args[0], ['xcrun', 'simctl', 'delete', identifier])

    def test_sanitizer_reuses_owned_device_and_cleans_up_after_each_failure_stage(self):
        original = self.prepare_bundle()
        device = dict(DEVICES[0][1], deviceTypeIdentifier='iPad-Air-11-inch')
        inventory = {'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [device]}
        identifier = '12345678-1234-1234-1234-123456789abc'
        for sanitizer in ('address', 'thread'):
            sanitized = self.root / 'build/iPad-memory' / sanitizer / 'Build/Products/tests.xctestrun'
            sanitized.parent.mkdir(parents=True)
            sanitized.touch()
            for failure in (None, 'ui', 'build', 'sanitizer'):
                events = []

                def command(args, _timeout, **_options):
                    if args[0].endswith('build-ipad.sh'):
                        events.append('build')
                        self.assertEqual(args[1:], ['simulator', sanitizer])
                        if failure == 'build':
                            raise subprocess.CalledProcessError(65, args)
                    if args[:3] == ['xcrun', 'simctl', 'delete']:
                        events.append('delete')
                        self.assertEqual(args[3], identifier)
                    return subprocess.CompletedProcess(args, 0, stdout=identifier)

                def tests(_size, owned, bundle, _results, **options):
                    self.assertEqual(owned['udid'], identifier)
                    if bundle == original:
                        events.append('ui')
                        self.assertTrue(options['cold_start'])
                        self.assertTrue(options['memory'])
                        return failure != 'ui'
                    events.append('sanitizer')
                    self.assertEqual(bundle, sanitized)
                    self.assertEqual(options, {'suite': 'unit', 'coverage': False, 'appearance': 'light'})
                    return failure != 'sanitizer'

                with self.subTest(sanitizer=sanitizer, failure=failure), \
                     patch.dict(os.environ, {'GITHUB_ACTIONS': 'true'}), \
                     patch.object(runner, '__file__', str(self.root / 'scripts/ipad_simulator.py')), \
                     patch.object(runner, 'inventory', return_value=inventory), \
                     patch.object(runner, 'run', side_effect=command), \
                     patch.object(runner, 'test_device', side_effect=tests):
                    arguments = ['--size', '11-inch', '--fresh-device', '--memory',
                                 '--appearance', 'light', '--sanitizer', sanitizer]
                    if failure == 'build':
                        with self.assertRaises(subprocess.CalledProcessError):
                            runner.main(arguments)
                    else:
                        self.assertEqual(runner.main(arguments), 1 if failure else 0)
                expected = ['ui']
                if failure != 'ui':
                    expected.append('build')
                    if failure != 'build':
                        expected.append('sanitizer')
                self.assertEqual(events, expected + ['delete'])

    def test_fresh_device_rejects_local_default_device_storage(self):
        with patch.dict(os.environ, {'GITHUB_ACTIONS': 'false'}), \
             patch.object(runner, 'inventory') as inventory, contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                runner.main(['--size', '13-inch', '--fresh-device'])
            inventory.assert_not_called()

    def test_discovery_failure_saves_diagnostics_without_booting_or_testing(self):
        self.prepare_bundle()
        for error in (subprocess.TimeoutExpired(['xcrun', 'simctl'], 180),
                      subprocess.CalledProcessError(1, ['xcrun', 'simctl']),
                      RuntimeError('No available iOS runtime with a 11-inch iPad')):
            with self.subTest(error=error), \
                 patch.object(runner, '__file__', str(self.root / 'scripts/ipad_simulator.py')), \
                 patch.object(runner, 'run'), patch.object(runner, 'inventory', side_effect=error), \
                 patch.object(runner, 'test_device') as tests, \
                 patch.object(runner, 'diagnostics') as diagnostics:
                self.assertEqual(runner.main(['--size', '11-inch']), 1)
                tests.assert_not_called()
                diagnostics.assert_called_once_with(
                    self.root / 'build/iPad-writing/11-inch-discovery-diagnostics.log')

    def test_diagnostics_remain_bounded_when_simulator_service_hangs(self):
        calls = []

        def command(args, timeout, **options):
            calls.append(args)
            self.assertEqual(timeout, 10)
            self.assertEqual(options, {'capture': True, 'check': False})
            if args[:2] == ['xcrun', 'simctl']:
                raise subprocess.TimeoutExpired(args, timeout)
            return subprocess.CompletedProcess(args, 0, stdout='diagnostic output\n')

        path = self.root / 'diagnostics.log'
        with patch.object(runner, 'run', side_effect=command):
            runner.diagnostics(path)
        self.assertIn('Diagnostic command timed out after 10 seconds.', path.read_text())
        self.assertEqual(calls[-1][0], 'tail', 'Service logs must survive a hung inventory query')

    def exercise(self, failure=None, size='11-inch'):
        active = set()
        events = []
        result_paths = []

        def command(args, timeout, **_options):
            if args[:2] == ['xcrun', 'xcresulttool']:
                return subprocess.CompletedProcess(args, 0, stdout=json.dumps(
                    {'result': 'Passed', 'passedTests': 1, 'failedTests': 0, 'runtimeWarnings': []}))
            if args[0] == 'xcodebuild':
                device = args[args.index('-destination') + 1].split('id=')[1]
                operation = 'test'
                self.assertEqual(active, {device})
                self.assertIn('test-without-building', args)
                self.assertNotIn('-project', args)
                self.assertEqual(_options['startup_timeout'], 600)
                result_paths.append(args[args.index('-resultBundlePath') + 1])
            else:
                operation, device = args[2:4]
                if operation == 'bootstatus':
                    self.assertFalse(active, 'A second simulator was booted before the first shut down')
                    active.add(device)
                elif operation == 'shutdown':
                    if failure != ('shutdown', device):
                        active.discard(device)
            events.append((operation, device))
            self.assertGreater(timeout, 0)
            if (operation, device) == failure:
                raise subprocess.TimeoutExpired(args, timeout)
            return subprocess.CompletedProcess(args, 0)

        device = next(device for label, device in DEVICES if label == size)
        with patch.object(runner, 'run', side_effect=command), patch.object(runner, 'diagnostics'), \
             patch.object(runner, 'export_coverage'), patch.object(runner, 'configure_coverage'):
            passed = runner.test_device(size, device, self.root / 'test.xctestrun', self.root)
        self.assertFalse(active)
        self.assertEqual(len(result_paths), len(set(result_paths)))
        return passed, events

    def test_each_invocation_runs_only_its_size_and_full_suite(self):
        for size, device in DEVICES:
            passed, events = self.exercise(size=size)
            self.assertTrue(passed)
            self.assertEqual(events, [(operation, device['udid']) for operation in ('bootstatus', 'test', 'shutdown')])

    def test_memory_validation_keeps_the_requested_unit_target(self):
        with patch.object(runner, 'run', return_value=subprocess.CompletedProcess([], 0)) as run, \
             patch.object(runner, 'verify_result') as verify, patch.object(runner, 'export_coverage'), \
             patch.object(runner, 'configure_coverage'):
            self.assertTrue(runner.test_device('11-inch', DEVICES[0][1], self.root / 'test.xctestrun',
                                             self.root, suite='unit', memory=True))
        command = next(call.args[0] for call in run.call_args_list if call.args[0][0] == 'xcodebuild')
        self.assertIn('-only-testing:LeftBlankTabletTests', command)
        self.assertIn('-derivedDataPath', command)
        self.assertEqual(command[command.index('-enableCodeCoverage') + 1], 'YES')
        self.assertNotIn('-enablePerformanceTestsDiagnostics', command)
        verify.assert_called_once_with(self.root / '11-inch.xcresult', self.root, memory=True)

    def test_full_ui_suite_retains_memory_validation_and_coverage(self):
        with patch.object(runner, 'run', return_value=subprocess.CompletedProcess([], 0)) as run, \
             patch.object(runner, 'verify_result') as verify, patch.object(runner, 'export_coverage') as coverage, \
             patch.object(runner, 'configure_coverage'):
            self.assertTrue(runner.test_device('11-inch', DEVICES[0][1], self.root / 'test.xctestrun',
                                             self.root, memory=True))
        call = next(call for call in run.call_args_list if call.args[0][0] == 'xcodebuild')
        command = call.args[0]
        self.assertFalse(any(arg.startswith('-only-testing:') for arg in command))
        self.assertEqual(command[command.index('-enableCodeCoverage') + 1], 'YES')
        self.assertNotIn('-enablePerformanceTestsDiagnostics', command)
        self.assertEqual(call.args[1], 1500)
        self.assertEqual(call.kwargs['startup_timeout'], 600)
        verify.assert_called_once_with(self.root / '11-inch.xcresult', self.root, memory=True)
        coverage.assert_called_once()

    def test_custom_memory_products_do_not_reuse_coverage_build(self):
        bundle = self.root / 'build/iPad-memory/address/Build/Products/memory.xctestrun'
        bundle.parent.mkdir(parents=True)
        bundle.touch()
        devices = {'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [DEVICES[0][1]]}
        with patch.object(runner, '__file__', str(self.root / 'scripts/ipad_simulator.py')), \
             patch.object(runner, 'run'), patch.object(runner, 'inventory', return_value=devices), \
             patch.object(runner, 'test_device', return_value=True) as tests:
            self.assertEqual(runner.main(['--size', '11-inch', '--suite', 'unit', '--memory',
                                         '--derived-data', 'build/iPad-memory/address',
                                         '--results', 'build/iPad-memory/address-results']), 0)
        tests.assert_called_once_with('11-inch', DEVICES[0][1], bundle,
                                      self.root / 'build/iPad-memory/address-results', suite='unit', memory=True)

    def test_success_without_executed_tests_or_with_runtime_warnings_fails(self):
        for summary in ({'result': 'Passed', 'passedTests': 0, 'failedTests': 0},
                        {'result': 'Failed', 'passedTests': 1, 'failedTests': 1},
                        {'result': 'Passed', 'passedTests': 1, 'failedTests': 0,
                         'runtimeWarnings': [{'issueType': 'Main Thread Checker'}]}):
            with self.subTest(summary=summary), patch.object(runner, 'run', return_value=
                    subprocess.CompletedProcess([], 0, stdout=json.dumps(summary))):
                with self.assertRaises(RuntimeError):
                    runner.verify_result(self.root / 'test.xcresult', self.root)
            self.assertEqual(json.loads((self.root / 'test-summary.json').read_text()), summary)

    def test_boot_failure_cleans_up_without_testing(self):
        passed, events = self.exercise(('bootstatus', 'small'))
        self.assertFalse(passed)
        self.assertNotIn(('test', 'small'), events)
        self.assertEqual(events[-1], ('shutdown', 'small'))

    def test_cold_appearance_setup_is_bounded_and_verified_before_tests(self):
        events = []

        def command(args, timeout, **_options):
            if args[:3] == ['xcrun', 'simctl', 'ui']:
                # Both setting and reading the first appearance can stall while
                # hosted UI services initialize, even after bootstatus returns.
                if timeout < 90:
                    raise subprocess.TimeoutExpired(args, timeout)
                self.assertLessEqual(timeout, 120)
                if len(args) == 6:
                    events.append('set appearance')
                    return subprocess.CompletedProcess(args, 0)
                events.append('verify appearance')
                return subprocess.CompletedProcess(args, 0, stdout='Dark\n')
            if args[0] == 'xcodebuild':
                events.append('test')
            return subprocess.CompletedProcess(args, 0)

        with patch.object(runner, 'run', side_effect=command), patch.object(runner, 'verify_result'), \
             patch.object(runner, 'configure_coverage'), patch.object(runner, 'export_coverage'):
            self.assertTrue(runner.test_device('13-inch', DEVICES[1][1], self.root / 'tests.xctestrun',
                                              self.root, appearance='dark'))
        self.assertEqual(events, ['set appearance', 'verify appearance', 'test'])

    def test_wrong_appearance_cleans_up_without_testing(self):
        for failure in ('mismatch', 'timeout'):
            def command(args, timeout, **_options):
                if failure == 'timeout' and args[:3] == ['xcrun', 'simctl', 'ui'] and len(args) == 5:
                    raise subprocess.TimeoutExpired(args, timeout)
                return subprocess.CompletedProcess(args, 0, stdout='Light\n')

            with self.subTest(failure=failure), \
                 patch.object(runner, 'run', side_effect=command) as run, \
                 patch.object(runner, 'diagnostics'), patch.object(runner, 'configure_coverage'):
                self.assertFalse(runner.test_device('13-inch', DEVICES[1][1], self.root / 'tests.xctestrun',
                                                   self.root, appearance='dark'))
            self.assertFalse(any(call.args[0][0] == 'xcodebuild' for call in run.call_args_list))
            self.assertEqual(run.call_args.args[0][:3], ['xcrun', 'simctl', 'shutdown'])

    def test_cold_setup_reboots_before_appearance_verification_and_tests(self):
        for failure in (None, 'second boot', 'appearance'):
            events = []

            def command(args, timeout, **_options):
                operation = args[2] if args[0] == 'xcrun' else 'test'
                if operation == 'shutdown':
                    self.assertEqual(timeout, 120)
                if operation == 'bootstatus':
                    operation = 'second boot' if 'first boot' in events else 'first boot'
                if operation == 'ui':
                    operation = 'set appearance' if len(args) == 6 else 'appearance'
                events.append(operation)
                if operation == failure:
                    raise subprocess.TimeoutExpired(args, timeout)
                return subprocess.CompletedProcess(args, 0, stdout='Dark\n')

            with self.subTest(failure=failure), patch.object(runner, 'run', side_effect=command), \
                 patch.object(runner, 'configure_coverage'), patch.object(runner, 'export_coverage'), \
                 patch.object(runner, 'verify_result'), patch.object(runner, 'diagnostics'):
                passed = runner.test_device('11-inch', DEVICES[0][1], self.root / 'tests.xctestrun',
                                            self.root, appearance='dark', cold_start=True)
            self.assertEqual(passed, failure is None)
            self.assertEqual(events[:4], ['first boot', 'set appearance', 'shutdown', 'second boot'])
            self.assertEqual(events[-1], 'shutdown')
            self.assertEqual(events.count('test'), 1 if failure is None else 0)
            if failure is None:
                self.assertEqual(events[4:], ['appearance', 'test', 'shutdown'])

    def test_memory_validation_rejects_missing_workload_metrics(self):
        summary = {'result': 'Passed', 'passedTests': 2, 'failedTests': 0}
        with patch.object(runner, 'run', side_effect=[
                subprocess.CompletedProcess([], 0, stdout=json.dumps(summary)),
                subprocess.CompletedProcess([], 0, stdout='[]')]):
            with self.assertRaisesRegex(RuntimeError, 'physical peak memory'):
                runner.verify_result(self.root / 'test.xcresult', self.root, memory=True)

    def test_coverage_export_requires_fresh_run_and_includes_core_image(self):
        products = self.root / 'Build/Products'
        app = products / 'Debug-iphonesimulator/LeftBlank.app'
        app.mkdir(parents=True)
        (app / 'LeftBlank.debug.dylib').touch()
        framework = products / 'Debug-iphonesimulator/PackageFrameworks/LeftBlankCore.framework'
        framework.mkdir(parents=True)
        (framework / 'LeftBlankCore').touch()
        injected = app / 'Frameworks/Testing.framework/Testing'
        injected.parent.mkdir(parents=True)
        injected.touch()
        profile = self.root / 'Build/ProfileData/small/Coverage.profdata'
        with self.assertRaisesRegex(RuntimeError, 'fresh coverage profile'):
            runner.export_coverage(products / 'tests.xctestrun', DEVICES[0][1], self.root, '11-inch', 0)
        profile.parent.mkdir(parents=True)
        profile.touch()
        with patch.object(runner, 'run', return_value=subprocess.CompletedProcess([], 0, stdout='real LCOV')) as run:
            runner.export_coverage(products / 'tests.xctestrun', DEVICES[0][1], self.root, '11-inch', 0)
        self.assertIn(str(framework / 'LeftBlankCore'), run.call_args.args[0])
        self.assertNotIn(str(injected), run.call_args.args[0])
        self.assertEqual((self.root / '11-inch.lcov').read_text(), 'real LCOV')

    def test_relocatable_run_declares_both_instrumented_images(self):
        import plistlib
        bundle = self.prepare_bundle()
        bundle.write_bytes(plistlib.dumps({'TestConfigurations': []}))
        for folder, image in [('iPad/Sources', 'LeftBlank.app/LeftBlank.debug.dylib'),
                              ('Sources/LeftBlankCore', 'PackageFrameworks/LeftBlankCore.framework/LeftBlankCore')]:
            base = self.root / folder
            base.mkdir(parents=True)
            (base / 'Source.swift').touch()
            binary = bundle.parent / 'Debug-iphonesimulator' / image
            binary.parent.mkdir(parents=True)
            binary.touch()
        with patch.object(runner, '__file__', str(self.root / 'scripts/ipad_simulator.py')):
            runner.configure_coverage(bundle)
        targets = plistlib.loads(bundle.read_bytes())['CodeCoverageBuildableInfos']
        self.assertEqual([target['Name'] for target in targets], ['LeftBlank.app', 'LeftBlankCore.framework'])
        self.assertTrue(all(target['IncludeInReport'] for target in targets))
        self.assertTrue(all('__TESTROOT__' in target['ProductPaths'][0] for target in targets))

    def test_test_failure_cleans_up_and_cannot_report_success(self):
        passed, events = self.exercise(('test', 'small'))
        self.assertFalse(passed)
        self.assertEqual(events[-1], ('shutdown', 'small'))

    def test_shutdown_failure_cannot_report_success(self):
        with self.assertRaises(subprocess.TimeoutExpired):
            self.exercise(('shutdown', 'small'))

    def test_timeout_kills_descendants_holding_output_open(self):
        # A surviving child keeps communicate() blocked. This tests real process
        # cleanup without CoreSimulator, networking or a development database.
        program = ("import subprocess, sys, time; "
                   "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); "
                   "print('started', flush=True); time.sleep(30)")
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            runner.run([sys.executable, '-c', program], 0.5, capture=True)
        self.assertLess(time.monotonic() - started, 3)

    def test_cold_launch_does_not_consume_execution_budget(self):
        # The command exceeds its execution allowance overall, but its actual
        # test phase fits. Split the marker across writes, like a real pipe.
        program = ("import time; time.sleep(0.7); "
                   "print(\"Test Suite 'All tests' sta\", end='', flush=True); "
                   "time.sleep(0.1); print('rted at now', flush=True); time.sleep(0.7)")
        result = runner.run([sys.executable, '-c', program], 1.2, startup_timeout=3)
        self.assertEqual(result.returncode, 0)

    def test_startup_chatter_cannot_extend_deadline(self):
        program = "import time\nwhile True:\n print('Still launching', flush=True)\n time.sleep(0.02)"
        with self.assertRaisesRegex(RuntimeError, 'startup timed out'):
            runner.run([sys.executable, '-c', program], 3, startup_timeout=0.3)

    def test_later_suites_cannot_extend_execution_deadline(self):
        program = ("import time\nwhile True:\n"
                   " print(\"Test Suite 'Another suite' started at now\", flush=True)\n time.sleep(0.02)")
        with self.assertRaisesRegex(RuntimeError, 'execution timed out'):
            runner.run([sys.executable, '-c', program], 0.3, startup_timeout=3)

    def test_phased_timeout_kills_descendants_holding_output_open(self):
        program = ("import subprocess, sys, time; "
                   "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); "
                   "print(\"Test Suite 'All tests' started at now\", flush=True); time.sleep(30)")
        started = time.monotonic()
        with self.assertRaisesRegex(RuntimeError, 'execution timed out'):
            runner.run([sys.executable, '-c', program], 0.3, startup_timeout=3)
        self.assertLess(time.monotonic() - started, 4)

    def test_phased_timeout_allows_result_finalization(self):
        report = self.root / 'finalized.txt'
        program = ("import signal, sys, time\n"
                   "from pathlib import Path\n"
                   "def finalize(_signum, _frame):\n"
                   " Path(sys.argv[1]).write_text('failure attachments saved')\n"
                   " raise SystemExit(0)\n"
                   "signal.signal(signal.SIGINT, finalize)\n"
                   "print(\"Test Suite 'All tests' started at now\", flush=True)\n"
                   "time.sleep(30)\n")
        with self.assertRaisesRegex(RuntimeError, 'execution timed out'):
            runner.run([sys.executable, '-c', program, str(report)], 0.3, startup_timeout=3)
        self.assertEqual(report.read_text(), 'failure attachments saved')

    def test_phased_command_failure_is_not_success(self):
        with self.assertRaises(subprocess.CalledProcessError) as failure:
            runner.run([sys.executable, '-c', 'raise SystemExit(65)'], 3, startup_timeout=3)
        self.assertEqual(failure.exception.returncode, 65)


if __name__ == '__main__':
    unittest.main()
