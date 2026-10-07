#!/usr/bin/env python3
"""CI capacity policy: path selection, nightly full iPad suite, gate and publication.

Runs in the ubuntu `changes` job before any macOS job starts. Workflow files are
inspected as text so the test needs only the Python standard library.
"""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_changes as ci  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / '.github/workflows'
MAC_JOBS = {'integration', 'appstore', 'memory'}
IPAD_JOBS = {'ipad-build', 'ipad-simulator-build', 'ipad-ui', 'ipad-coverage', 'ipad-memory'}
FULL_ONLY = {'ipad-coverage', 'ipad-memory'}


def jobs(workflow):
    """Map each job id to its text block."""
    text = (WORKFLOWS / workflow).read_text()
    body = text[text.index('\njobs:\n') + len('\njobs:\n'):]
    parts = re.split(r'^  ([a-z][a-z0-9-]*):\n', body, flags=re.M)
    return dict(zip(parts[1::2], parts[2::2]))


def field(block, name):
    match = re.search(rf'^    {name}: (.*)$', block, flags=re.M)
    return match.group(1).strip() if match else None


def needs(block):
    value = field(block, 'needs') or ''
    return set(value.strip('[]').replace(' ', '').split(',')) - {''}


class PathClassificationTests(unittest.TestCase):
    TABLE = {
        # Mac app, MCP helper and Mac-only packaging.
        'Sources/LeftBlank/Workspace.swift': {'mac'},
        'Sources/LeftBlankLauncher/main.swift': {'mac'},
        'Tests/LeftBlankAppTests/WritingFlowTests.swift': {'mac'},
        'Tests/MCP/editing.hurl': {'mac'},
        'Tools/MCPServer/src/main.rs': {'mac'},
        'Tools/MCPServer/Cargo.lock': {'mac'},
        'Resources/Info.plist': {'mac'},
        'Resources/Preview-Info.plist': {'mac'},
        'Resources/AppIcon.icns': {'mac'},
        'Resources/en.lproj/InfoPlist.strings': {'mac'},
        'scripts/test.sh': {'mac'},
        'scripts/build-tinymist.sh': {'mac'},
        'scripts/tinymist-native-tls.patch': {'mac'},
        'scripts/release.sh': {'mac'},
        'scripts/publish-preview.py': {'mac'},
        'scripts/check-memory.sh': {'mac'},
        'Benchmarks/Diffing/TextDiffingRoundTripTests.swift': {'mac'},
        '.swiftlint.yml': {'mac'},
        '.github/workflows/release.yml': {'mac'},
        # iPad app, embedded engine and iPad-only scripts.
        'iPad/Sources/TabletRoot.swift': {'ipad'},
        'iPad/LeftBlank.xcodeproj/project.pbxproj': {'ipad'},
        'iPad/UITests/WritingTests.swift': {'ipad'},
        'Engine/TinymistBridge/src/lib.rs': {'ipad'},
        'Engine/TinymistBridge/Cargo.lock': {'ipad'},
        'scripts/build-syntax.sh': {'mac'},
        'scripts/build-ipad.sh': {'ipad'},
        'scripts/ipad_simulator.py': {'ipad'},
        'scripts/test-ipad-simulator.py': {'ipad'},
        'scripts/tinymist-ipad.patch': {'ipad'},
        'scripts/prepare-ipad-engine.sh': {'ipad'},
        'scripts/fixtures/apple-storefront-schema.json': {'ipad'},
        '.github/workflows/ipad-release.yml': {'ipad'},
        # Shared code, resources and CI infrastructure run both.
        'Sources/LeftBlankCore/TinymistClient.swift': {'mac', 'ipad'},
        'Sources/LeftBlankCore/Resources/en.lproj/Localizable.strings': {'mac', 'ipad'},
        'Sources/Package.swift': {'mac', 'ipad'},
        'Sources/LeftBlankSyntaxFFI/include/LeftBlankSyntax.h': {'mac', 'ipad'},
        'Engine/SyntaxBridge/src/lib.rs': {'mac', 'ipad'},
        'Engine/SyntaxBridge/Cargo.lock': {'mac', 'ipad'},
        'Engine/NewBridge/Cargo.toml': {'mac', 'ipad'},
        'scripts/rust-licenses.py': {'mac', 'ipad'},
        'Package.swift': {'mac', 'ipad'},
        'Package.resolved': {'mac', 'ipad'},
        'Tests/LeftBlankCoreTests/CoreTests.swift': {'mac', 'ipad'},
        'Tests/Support/TestPaths.swift': {'mac', 'ipad'},
        'Resources/Icons/pen.svg': {'mac', 'ipad'},
        'Resources/Packages/preview/cetz/0.5.2/src/lib.typ': {'mac', 'ipad'},
        'Resources/ThirdParty.txt': {'mac', 'ipad'},
        'Examples/Welcome.typ': {'mac', 'ipad'},
        'Brand/mark-dark.svg': {'mac', 'ipad'},
        'scripts/environment.sh': {'mac', 'ipad'},
        'scripts/lint.sh': {'mac', 'ipad'},
        'scripts/tinymist-vfs.patch': {'mac', 'ipad'},
        'scripts/coverage.py': {'mac', 'ipad'},
        'scripts/appstore_connect.py': {'mac', 'ipad'},
        'scripts/test-appstore-release.py': {'mac', 'ipad'},
        'scripts/release_metadata.py': {'mac', 'ipad'},
        'scripts/ci_changes.py': {'mac', 'ipad'},
        'scripts/test-ci-policy.py': {'mac', 'ipad'},
        '.github/workflows/ci.yml': {'mac', 'ipad'},
        '.github/dependabot.yml': {'mac', 'ipad'},
        'something/new.txt': {'mac', 'ipad'},
        # Documentation runs no macOS job.
        'docs/development.md': set(),
        'docs/screenshots/editor.png': set(),
        'README.md': set(),
        'releases/0.5.0.md': set(),
        'LICENSE': set(),
        'Brand/README.md': set(),
    }

    def test_each_path_selects_its_platforms(self):
        for path, expected in self.TABLE.items():
            with self.subTest(path=path):
                self.assertEqual(ci.classify(path), expected)

    def test_prefixes_match_whole_names_or_directories(self):
        # A sibling sharing a name prefix must not inherit a narrower platform.
        self.assertEqual(ci.classify('Sources/LeftBlankCore/X.swift'), {'mac', 'ipad'})
        self.assertEqual(ci.classify('scripts/test.sh.orig'), {'mac', 'ipad'})
        self.assertEqual(ci.classify('docsite/index.md'), {'mac', 'ipad'})
        self.assertEqual(ci.classify('Examples/Books/SICP/README.md'), {'mac', 'ipad'})

    def test_every_tracked_script_is_classified_deliberately(self):
        listed = ci.MAC + ci.IPAD + ci.DOCS
        scripts = subprocess.check_output(['git', 'ls-files', 'scripts'], cwd=ROOT, text=True).split()
        shared = {'scripts/appstore_connect.py', 'scripts/ci_changes.py', 'scripts/coverage.py',
                  'scripts/environment.sh', 'scripts/lint.sh', 'scripts/rust-licenses.py',
                  'scripts/release_metadata.py', 'scripts/test-appstore-release.py', 'scripts/test-ci-policy.py',
                  'scripts/test-icon-policy.py', 'scripts/tinymist-vfs.patch', 'scripts/update-universe-snapshot.py'}
        for script in scripts:
            with self.subTest(script=script):
                self.assertTrue(ci.matches(script, listed) or script in shared,
                                'Classify new scripts in scripts/ci_changes.py (Mac, iPad or shared)')

    def test_selection_unions_the_changed_paths(self):
        self.assertEqual(ci.select(['docs/ipad.md', 'README.md']), {'mac': False, 'ipad': False})
        self.assertEqual(ci.select([]), {'mac': False, 'ipad': False})
        self.assertEqual(ci.select(['Tools/MCPServer/src/main.rs', 'docs/mcp-design.md']),
                         {'mac': True, 'ipad': False})
        self.assertEqual(ci.select(['iPad/Sources/TabletRoot.swift']), {'mac': False, 'ipad': True})
        self.assertEqual(ci.select(['iPad/Sources/TabletRoot.swift', 'Sources/LeftBlank/Workspace.swift']),
                         {'mac': True, 'ipad': True})
        self.assertEqual(ci.select(['Sources/LeftBlankCore/Library.swift']), {'mac': True, 'ipad': True})


class PlanTests(unittest.TestCase):
    """Event handling against a real scratch repository."""

    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix='leftblank-ci-', dir=os.environ.get('TMPDIR'))
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        patcher = mock.patch.object(ci, 'ROOT', self.root)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.git('init', '-q', '-b', 'main')
        self.base = self.commit('docs/start.md')

    def git(self, *args):
        env = {**os.environ, 'GIT_AUTHOR_NAME': 'CI', 'GIT_AUTHOR_EMAIL': 'ci@example.invalid',
               'GIT_COMMITTER_NAME': 'CI', 'GIT_COMMITTER_EMAIL': 'ci@example.invalid'}
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, env=env).strip()

    def commit(self, path):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(file.read_text() + '.' if file.exists() else path)
        self.git('add', '-A')
        self.git('commit', '-q', '-m', path)
        return self.git('rev-parse', 'HEAD')

    def plan(self, event, head, runs=lambda repository, event: [], **kwargs):
        return ci.plan(event, head, 'smoke', 'leftblank-app/leftblank', runs=runs, **kwargs)[0]

    def test_push_diffs_against_the_last_successful_main_run(self):
        self.commit('Sources/LeftBlank/Workspace.swift')   # its run was cancelled
        head = self.commit('iPad/Sources/TabletRoot.swift')
        self.assertEqual(self.plan('push', head, runs=lambda repository, event: [self.base]),
                         {'mac': True, 'ipad': True})
        self.assertEqual(self.plan('push', head, runs=lambda repository, event: [self.git('rev-parse', 'HEAD~1')]),
                         {'mac': False, 'ipad': True})

    def test_push_ignores_its_own_and_unrelated_successes(self):
        head = self.commit('Tools/MCPServer/src/main.rs')
        self.git('checkout', '-q', '-b', 'other', self.base)
        unrelated = self.commit('iPad/Sources/Other.swift')
        self.git('checkout', '-q', 'main')
        # A rerun of an already successful commit still diffs against an earlier run.
        runs = lambda repository, event: [head, unrelated, self.base]  # noqa: E731
        self.assertEqual(self.plan('push', head, runs=runs), {'mac': True, 'ipad': False})

    def test_push_without_a_usable_base_runs_everything(self):
        head = self.commit('docs/more.md')
        self.assertEqual(self.plan('push', head), {'mac': True, 'ipad': True})

        def broken(repository, event):
            raise subprocess.CalledProcessError(1, 'gh')
        self.assertEqual(self.plan('push', head, runs=broken), {'mac': True, 'ipad': True})

    def test_docs_only_push_runs_no_macos_job(self):
        head = self.commit('docs/more.md')
        self.assertEqual(self.plan('push', head, runs=lambda repository, event: [self.base]),
                         {'mac': False, 'ipad': False})

    def test_pull_request_diffs_its_test_merge_commit_against_the_base(self):
        self.git('checkout', '-q', '-b', 'feature')
        self.commit('Tools/MCPServer/src/main.rs')
        self.git('checkout', '-q', 'main')
        self.commit('iPad/Sources/Landed.swift')          # already on the base branch
        self.git('merge', '-q', '--no-ff', '-m', 'merge', 'feature')
        merge = self.git('rev-parse', 'HEAD')
        self.assertEqual(self.plan('pull_request', merge), {'mac': True, 'ipad': False})

    def test_pull_request_head_checkout_uses_the_merge_base(self):
        self.git('checkout', '-q', '-b', 'feature')
        head = self.commit('iPad/Sources/TabletRoot.swift')
        self.assertEqual(self.plan('pull_request', head, pr_base=self.base), {'mac': False, 'ipad': True})

    def test_nightly_runs_everything_unless_main_is_unchanged(self):
        head = self.commit('docs/more.md')
        self.assertEqual(self.plan('schedule', head, runs=lambda repository, event: [self.base]),
                         {'mac': True, 'ipad': True})
        self.assertEqual(self.plan('schedule', head, runs=lambda repository, event: [head, self.base]),
                         {'mac': False, 'ipad': False})
        self.assertEqual(self.plan('schedule', head), {'mac': True, 'ipad': True})

    def test_a_failed_nightly_is_retried_so_preview_still_publishes(self):
        # The successful-runs query never returns a failed nightly, whether its
        # tests or its Preview publication failed, so the same commit runs again.
        head = self.commit('Sources/LeftBlank/Workspace.swift')
        last_success = lambda repository, event: [self.base]  # noqa: E731  (the run for head failed)
        selection = self.plan('schedule', head, runs=last_success)
        self.assertEqual(selection, {'mac': True, 'ipad': True})
        self.assertTrue(ci.outputs(selection, 'schedule', 'refs/heads/main', 'full')['publish'])

    def test_nightly_only_compares_with_earlier_nightlies(self):
        seen = []
        self.plan('schedule', self.base, runs=lambda repository, event: seen.append(event) or [])
        self.assertEqual(seen, ['schedule'])

    def test_manual_and_unknown_events_run_everything(self):
        for event in ('workflow_dispatch', 'merge_group', 'release'):
            with self.subTest(event=event):
                self.assertEqual(self.plan(event, self.base), {'mac': True, 'ipad': True})

    def test_preview_dispatch_runs_only_the_mac_checks(self):
        self.assertEqual(self.plan('workflow_dispatch', self.base, publish_preview=True),
                         {'mac': True, 'ipad': False})


class OutputTests(unittest.TestCase):
    """Release checks and Preview publication run only from main's nightly or a manual main run."""
    MAIN, BRANCH = 'refs/heads/main', 'refs/heads/feature'

    def result(self, event, ref=MAIN, mac=True, publish_preview=False):
        selection = {'mac': mac, 'ipad': True}
        values = ci.outputs(selection, event, ref, 'smoke', publish_preview)
        return values['release'], values['publish']

    def test_pull_requests_and_main_pushes_never_release_or_publish(self):
        for event, ref in (('pull_request', 'refs/pull/79/merge'), ('push', self.MAIN)):
            with self.subTest(event=event):
                self.assertEqual(self.result(event, ref), (False, False))
                self.assertEqual(self.result(event, ref, publish_preview=True), (False, False))

    def test_nightly_releases_and_publishes_from_main(self):
        self.assertEqual(self.result('schedule'), (True, True))
        # An unchanged nightly selects no Mac job, so it neither tests nor publishes.
        self.assertEqual(self.result('schedule', mac=False), (False, False))

    def test_manual_main_runs_release_and_publish_only_on_request(self):
        self.assertEqual(self.result('workflow_dispatch'), (True, False))
        self.assertEqual(self.result('workflow_dispatch', publish_preview=True), (True, True))
        self.assertEqual(self.result('workflow_dispatch', self.BRANCH, publish_preview=True), (False, False))
        self.assertEqual(self.result('schedule', self.BRANCH), (False, False))


class GateTests(unittest.TestCase):
    def needs(self, mac, ipad, suite, release, **overrides):
        outputs = {'mac': str(mac).lower(), 'ipad': str(ipad).lower(), 'suite': suite,
                   'release': str(release).lower(), 'publish': str(release).lower()}
        result = {'changes': {'result': 'success', 'outputs': outputs}}
        for job, expected in ci.expected_results(mac, ipad, suite, release).items():
            result[job] = {'result': expected, 'outputs': {}}
        for job, value in overrides.items():
            result[job.replace('_', '-')] = {'result': value, 'outputs': {}}
        return result

    def test_selected_jobs_must_pass_and_filtered_jobs_must_skip(self):
        for mac in (True, False):
            for ipad in (True, False):
                for suite in ('smoke', 'full'):
                    for release in ((True, False) if mac else (False,)):
                        with self.subTest(mac=mac, ipad=ipad, suite=suite, release=release):
                            self.assertEqual(ci.gate(self.needs(mac, ipad, suite, release)), [])

    def test_docs_only_run_passes_with_every_macos_job_skipped(self):
        needs = self.needs(False, False, 'smoke', False)
        self.assertTrue(all(needs[job]['result'] == 'skipped' for job in MAC_JOBS | IPAD_JOBS))
        self.assertEqual(ci.gate(needs), [])

    def test_failed_cancelled_or_unexpected_results_fail(self):
        cases = [
            self.needs(True, True, 'smoke', False, integration='failure'),
            self.needs(True, True, 'smoke', False, ipad_ui='cancelled'),
            self.needs(True, False, 'smoke', False, integration='skipped'),
            self.needs(False, True, 'smoke', False, ipad_build='skipped'),
            self.needs(True, True, 'full', True, ipad_memory='skipped'),
            self.needs(True, True, 'full', True, memory='failure'),
            self.needs(True, True, 'full', True, appstore='skipped'),
            # A job that should have been filtered out but ran is a selection bug.
            self.needs(False, True, 'smoke', False, integration='success'),
            self.needs(True, True, 'smoke', False, ipad_coverage='success'),
            self.needs(True, True, 'smoke', False, appstore='success'),
        ]
        for needs in cases:
            with self.subTest(needs=needs):
                self.assertNotEqual(ci.gate(needs), [])

    def test_preview_publication_is_reported_separately(self):
        needs = self.needs(True, True, 'full', True)
        needs['preview'] = {'result': 'failure'}
        self.assertEqual(ci.gate(needs), [])
        self.assertNotIn('preview', ci.expected_results(True, True, 'full', True))

    def test_a_failed_or_malformed_selection_fails(self):
        needs = self.needs(True, True, 'smoke', False)
        needs['changes']['result'] = 'failure'
        self.assertNotEqual(ci.gate(needs), [])
        for outputs in ({'mac': '', 'ipad': 'true', 'suite': 'smoke', 'release': 'false'},
                        {'mac': 'true', 'ipad': 'true', 'suite': '', 'release': 'false'},
                        {'mac': 'true', 'ipad': 'true', 'suite': 'smoke'},
                        {'mac': 'false', 'ipad': 'true', 'suite': 'smoke', 'release': 'true'}, {}):
            needs = self.needs(True, True, 'smoke', False)
            needs['changes']['outputs'] = outputs
            with self.subTest(outputs=outputs):
                self.assertNotEqual(ci.gate(needs), [])


class WorkflowContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = (WORKFLOWS / 'ci.yml').read_text()
        cls.jobs = jobs('ci.yml')

    def test_nightly_schedule_runs_the_full_ipad_suite(self):
        self.assertRegex(self.text, r"\n  schedule:\n    - cron: '0 18 \* \* \*'\n")
        self.assertIn("\n  IPAD_SUITE: ${{ (github.event_name == 'schedule' || (github.event_name == "
                      "'workflow_dispatch' && inputs.ipad_suite != 'smoke')) && 'full' || 'smoke' }}\n", self.text)
        self.assertRegex(self.text, r'ipad_suite:\n(?:        .*\n)*        options: \[full, smoke\]\n'
                                    r'        default: full\n')
        self.assertRegex(self.text, r'publish_preview:\n(?:        .*\n)*        type: boolean\n'
                                    r'        default: false\n')

    def test_pull_requests_and_main_pushes_run_the_smoke_suite(self):
        # Only the nightly schedule and a full dispatch evaluate to 'full';
        # every other event, including pull_request and push, falls to 'smoke'.
        expression = re.search(r'\n  IPAD_SUITE: \$\{\{ (.*) \}\}\n', self.text).group(1)
        self.assertTrue(expression.endswith("&& 'full' || 'smoke'"))
        self.assertNotIn("'pull_request'", expression)
        self.assertNotIn("'push'", expression)
        self.assertIn("fromJSON(needs.changes.outputs.suite == 'smoke' && '[{\"size\":\"11-inch\","
                      "\"appearance\":\"light\"}]'", self.jobs['ipad-ui'])
        # Full-only jobs depend on the selected suite, never on event names.
        for job in FULL_ONLY:
            self.assertIn("needs.changes.outputs.suite == 'full'", field(self.jobs[job], 'if'))

    def test_changes_job_runs_contracts_then_selects(self):
        changes = self.jobs['changes']
        self.assertIn('runs-on: ubuntu-latest', changes)
        self.assertIn('fetch-depth: 0', changes)
        self.assertIn('actions: read', changes)
        self.assertIn('PUBLISH_PREVIEW: ${{ inputs.publish_preview }}', changes)
        self.assertLess(changes.index('python3 scripts/test-ci-policy.py'),
                        changes.index('python3 scripts/ci_changes.py select'))
        for output in ('mac', 'ipad', 'suite', 'release', 'publish'):
            self.assertIn(f'{output}: ${{{{ steps.select.outputs.{output} }}}}', changes)

    def test_path_outputs_gate_every_macos_job(self):
        macos = {name for name, block in self.jobs.items() if 'runs-on: macos' in block}
        self.assertEqual(macos, MAC_JOBS | IPAD_JOBS | {'preview'})
        for name in MAC_JOBS | IPAD_JOBS:
            block = self.jobs[name]
            output = 'release' if name in ('appstore', 'memory') else 'mac' if name in MAC_JOBS else 'ipad'
            with self.subTest(job=name):
                self.assertIn('changes', needs(block))
                self.assertTrue(field(block, 'if').startswith(f"needs.changes.outputs.{output} == 'true'"))
        # Release checks no longer run on pull requests or main pushes.
        for name in ('appstore', 'memory'):
            self.assertEqual(field(self.jobs[name], 'if'), "needs.changes.outputs.release == 'true'")

    def test_ipad_only_changes_still_lint(self):
        lint = re.search(r"- name: Strict SwiftFormat and SwiftLint\n\s+if: (.*)\n\s+run: scripts/lint.sh",
                         self.jobs['ipad-build'])
        self.assertEqual(lint.group(1), "matrix.platform == 'engine' && needs.changes.outputs.mac != 'true'")
        self.assertIn('run: scripts/lint.sh', self.jobs['integration'])

    def test_gate_checks_every_job_and_treats_filtered_skips_as_success(self):
        gate = self.jobs['gate']
        self.assertEqual(field(gate, 'name'), 'build and test')
        self.assertEqual(field(gate, 'if'), 'always()')
        self.assertIn('runs-on: ubuntu-latest', gate)
        gated = set(self.jobs) - {'changes', 'gate', 'preview', 'publish-preview'}
        self.assertEqual(needs(gate), gated | {'changes'})
        self.assertEqual(set(ci.expected_results(True, True, 'full', True)), gated)
        self.assertIn('NEEDS: ${{ toJSON(needs) }}', gate)
        self.assertIn('run: python3 scripts/ci_changes.py gate', gate)
        self.assertEqual(ci.gate({'changes': {'result': 'success', 'outputs': {
            'mac': 'false', 'ipad': 'false', 'suite': 'smoke', 'release': 'false', 'publish': 'false'}},
            **{job: {'result': 'skipped'} for job in gated}}), [])

    def test_only_pull_requests_and_main_pushes_cancel_in_progress_runs(self):
        self.assertIn('\nconcurrency:\n  group: ci-${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}\n'
                      "  cancel-in-progress: ${{ github.event_name == 'pull_request' || "
                      "github.event_name == 'push' }}\n", self.text)
        self.assertEqual(re.findall(r'cancel-in-progress: (.*)', self.text),
                         ["${{ github.event_name == 'pull_request' || github.event_name == 'push' }}", 'false'])

    def test_preview_publishes_after_mac_checks_from_non_cancelling_runs(self):
        preview, publish = self.jobs['preview'], self.jobs['publish-preview']
        self.assertEqual(field(preview, 'name'), 'Signed preview')
        self.assertEqual(field(preview, 'if'), "needs.changes.outputs.publish == 'true'")
        # Mac checks only: iPad failures fail the gate but do not hold back Preview.
        self.assertEqual(needs(preview), {'changes', 'integration', 'appstore'})
        self.assertIn('run: scripts/release.sh', preview)
        self.assertEqual(needs(publish), {'preview'})
        self.assertIn('run: python3 scripts/publish-preview.py', publish)
        self.assertIn('    concurrency:\n      group: preview-publish\n      cancel-in-progress: false\n', publish)
        self.assertIn('LEFTBLANK_BUILD_NUMBER: ${{ github.run_number }}.${{ github.run_attempt }}', preview)
        # Only these jobs see release credentials or write access.
        for name, block in self.jobs.items():
            if name not in ('preview', 'publish-preview'):
                with self.subTest(job=name):
                    self.assertNotIn('secrets.', block)
                    self.assertNotIn('contents: write', block)


if __name__ == '__main__':
    unittest.main()
