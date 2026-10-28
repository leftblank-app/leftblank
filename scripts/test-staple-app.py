#!/usr/bin/env python3
"""Replay Apple ticket-service failures without credentials or network access."""
from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

import staple_app


NETWORK_FAILURE = ('error is Error Domain=NSURLErrorDomain Code=-1005 '
                   '"The network connection was lost."\n'
                   'CloudKit\'s response is inconsistent with expections: (null)\n')


def response(code=0, output='The action worked!\n'):
    return subprocess.CompletedProcess([], code, stdout=output)


class StaplerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='leftblank-stapler-', dir=os.environ['TMPDIR'])
        self.addCleanup(temporary.cleanup)
        self.logs = Path(temporary.name) / 'notarization'
        self.app = Path(temporary.name) / 'LeftBlank Preview.app'
        self.output = io.StringIO()

    def run_stapler(self, responses):
        with mock.patch.object(staple_app.subprocess, 'run', side_effect=responses) as run, \
                mock.patch.object(staple_app.time, 'sleep') as sleep, redirect_stdout(self.output):
            status = staple_app.staple(self.app, self.logs)
        return status, [call.args[0] for call in run.call_args_list], sleep.call_args_list

    def test_success_checks_both_operations_without_retrying(self):
        status, calls, sleeps = self.run_stapler([response(), response()])
        self.assertEqual(status, 0)
        self.assertEqual(calls, [['xcrun', 'stapler', action, str(self.app)]
                                 for action in ('staple', 'validate')])
        self.assertEqual(sleeps, [])
        self.assertEqual(len(list(self.logs.glob('*.log'))), 2)

    def test_both_observed_main_failures_recover_independently(self):
        # The main push failed while stapling; the nightly failed validating
        # an already stapled app. Both reported this URL-loading error and 68.
        status, calls, sleeps = self.run_stapler([
            response(68, NETWORK_FAILURE), response(),
            response(68, NETWORK_FAILURE), response(),
        ])
        self.assertEqual(status, 0)
        self.assertEqual([call[2] for call in calls], ['staple', 'staple', 'validate', 'validate'])
        self.assertEqual(sleeps, [mock.call(15), mock.call(15)])
        for action in ('staple', 'validate'):
            self.assertEqual((self.logs / f'stapler-{action}-1.log').read_text(), NETWORK_FAILURE)
            self.assertTrue((self.logs / f'stapler-{action}-2.log').exists())

    def test_persistent_network_failure_stops_after_five_attempts(self):
        status, calls, sleeps = self.run_stapler([response(68, NETWORK_FAILURE)] * 5)
        self.assertEqual(status, 68)
        self.assertEqual([call[2] for call in calls], ['staple'] * 5)
        self.assertEqual(sleeps, [mock.call(delay) for delay in (15, 30, 60, 120)])
        self.assertEqual(len(list(self.logs.glob('*.log'))), 5)

    def test_invalid_missing_or_revoked_tickets_fail_immediately(self):
        for code, output in ((65, 'The ticket data is invalid.'),
                             (66, 'The existing ticket is missing or invalid.'),
                             (68, 'Record not found.'),
                             (77, 'The ticket has been revoked.')):
            with self.subTest(code=code):
                status, calls, sleeps = self.run_stapler([response(), response(code, output)])
                self.assertEqual(status, code)
                self.assertEqual([call[2] for call in calls], ['staple', 'validate'])
                self.assertEqual(sleeps, [])

    def test_a_validation_failure_after_network_recovery_still_fails(self):
        status, calls, sleeps = self.run_stapler([
            response(), response(68, NETWORK_FAILURE), response(65, 'Invalid ticket.'),
        ])
        self.assertEqual(status, 65)
        self.assertEqual([call[2] for call in calls], ['staple', 'validate', 'validate'])
        self.assertEqual(sleeps, [mock.call(15)])


if __name__ == '__main__':
    unittest.main()
