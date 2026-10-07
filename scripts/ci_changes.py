#!/usr/bin/env python3
"""Select CI jobs from changed paths, and check the selected jobs' results.

`select` runs in the small ubuntu `changes` job of .github/workflows/ci.yml and
writes the `mac`, `ipad`, `suite`, `release` and `publish` outputs that every
macOS job's `if:` consumes. `release` adds the Mac App Store and memory checks
and `publish` the signed Preview; both run only from main's nightly schedule or
a manual main dispatch, never from pull requests or main pushes.
`gate` runs in the required `build and test` job and fails unless each job
either passed (selected) or was skipped (not selected).

Any doubt runs more, never less: unknown paths are shared, and a missing base
commit, API error or unexpected event selects every job.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = 'ci.yml'

# First matching prefix wins. A prefix ending in '/' matches a directory;
# anything else must match the whole path. Unlisted paths are shared.
DOCS = (
    'docs/', 'releases/', 'README.md', 'BRAND_POLICY.md', 'LICENSE', 'codecov.yml', 'Brand/README.md',
)
MAC = (
    'Sources/LeftBlank/', 'Sources/LeftBlankLauncher/',
    'Tests/LeftBlankAppTests/', 'Tests/MCP/',
    'Tools/MCPServer/',
    # Only scripts/lint.sh reads these; Mac regression runs it.
    'Benchmarks/', 'design/', '.swiftlint.yml', '.swiftformat',
    # Mac bundle metadata and icons. The iPad project references only
    # Resources/Icons, Licenses, Packages and the license texts.
    'Resources/Info.plist', 'Resources/Preview-Info.plist', 'Resources/LeftBlank.AppStore.entitlements',
    'Resources/LeftBlank.Helper.entitlements', 'Resources/LeftBlank.iCloud.entitlements.example',
    'Resources/AppIcon.icns', 'Resources/AppIcon.svg', 'Resources/AppIconLight.icns', 'Resources/AppIconLight.svg',
    'Resources/en.lproj/', 'Resources/zh-Hans.lproj/',
    'scripts/benchmark-books.sh', 'scripts/bootstrap.sh', 'scripts/build.sh', 'scripts/build-mcp.sh',
    'scripts/build-syntax.sh', 'scripts/build-tinymist.sh', 'scripts/check-memory.sh', 'scripts/export-appstore.py', 'scripts/package-app.py',
    'scripts/package-sicp.py', 'scripts/prepare-icloud-profile.py', 'scripts/prepare-large-document.py',
    'scripts/prepare-mcp-hurl.sh', 'scripts/prepare-sicp.py', 'scripts/preview-feed.py', 'scripts/publish-preview.py',
    'scripts/release.sh', 'scripts/release-appstore.sh', 'scripts/running_app.py', 'scripts/sign-app.sh',
    'scripts/smoke-app.py', 'scripts/sparkle-tools.sh', 'scripts/test-icloud-profile.py',
    'scripts/test-preview-release.py', 'scripts/test-running-app.py', 'scripts/test-tinymist-build.py',
    'scripts/test.sh', 'scripts/tinymist-native-tls.patch', 'scripts/verify-update.swift',
    '.github/workflows/release.yml',
)
IPAD = (
    'iPad/',
    # Only the iPad scripts build the embedded Tinymist engine; Mac runs the
    # Tinymist helper. Engine/SyntaxBridge is linked by both, so it is shared.
    'Engine/TinymistBridge/',
    'scripts/build-ipad.sh', 'scripts/check-ipad-mcp-boundary.py', 'scripts/ipad_frameworks.py', 'scripts/fixtures/', 'scripts/ipad_coverage.py',
    'scripts/ipad_release.py', 'scripts/ipad_simulator.py', 'scripts/ipad_storefront.py',
    'scripts/prepare-ipad-engine.sh', 'scripts/release-ipad.sh', 'scripts/test-ipad-coverage.py',
    'scripts/test-ipad-engine.py', 'scripts/test-ipad-engine.sh', 'scripts/test-ipad-release.py',
    'scripts/test-ipad-simulator.py', 'scripts/test-ipad-storefront.py', 'scripts/test-package-graphs.py',
    'scripts/tinymist-ipad.patch', 'scripts/tinymist-ipad-export.patch',
    '.github/workflows/ipad-release.yml',
)
# Shared, listed for readers; unlisted paths behave the same way.
SHARED = (
    'Sources/LeftBlankCore/', 'Sources/LeftBlankSyntaxFFI/', 'Engine/SyntaxBridge/', 'Sources/Package.swift', 'Package.swift', 'Package.resolved',
    'Tests/LeftBlankCoreTests/', 'Tests/Support/', 'Resources/', 'Examples/', 'Brand/', 'scripts/', '.github/',
)


def matches(path, prefixes):
    return any(path.startswith(prefix) if prefix.endswith('/') else path == prefix for prefix in prefixes)


def classify(path):
    """Return the platforms a changed path needs validated: a set of 'mac'/'ipad'."""
    for prefixes, platforms in ((DOCS, set()), (MAC, {'mac'}), (IPAD, {'ipad'})):
        if matches(path, prefixes):
            return platforms
    return {'mac', 'ipad'}


def select(paths):
    platforms = set()
    for path in paths:
        platforms |= classify(path)
    return {'mac': 'mac' in platforms, 'ipad': 'ipad' in platforms}


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True).strip()


def is_ancestor(base, head):
    return subprocess.run(['git', 'merge-base', '--is-ancestor', base, head], cwd=ROOT).returncode == 0


def changed_paths(base, head):
    return [line for line in git('diff', '--name-only', '--no-renames', base, head).splitlines() if line]


def successful_runs(repository, event):
    """Head SHAs of this workflow's successful main runs for an event, newest first."""
    output = subprocess.check_output(
        ['gh', 'api', '-X', 'GET', f'repos/{repository}/actions/workflows/{WORKFLOW}/runs',
         '-f', 'branch=main', '-f', f'event={event}', '-f', 'status=success', '-f', 'per_page=30',
         '--jq', '.workflow_runs[].head_sha'], text=True)
    return [line for line in output.splitlines() if line]


def plan(event, head, suite, repository, runs=successful_runs, pr_base=None, publish_preview=False):
    """Decide which platforms run; returns (selection dict, human-readable reason)."""
    everything = {'mac': True, 'ipad': True}
    if event == 'workflow_dispatch':
        if publish_preview:
            return {'mac': True, 'ipad': False}, 'preview dispatch runs the Mac checks and publishes'
        return everything, 'manual dispatch runs every job'
    if event == 'schedule':
        try:
            last = next(iter(runs(repository, 'schedule')), None)
        except (OSError, subprocess.CalledProcessError) as error:
            return everything, f'could not read previous nightly runs ({error}); running everything'
        # Only a fully successful nightly (tests and Preview publication) of
        # this exact commit is skipped; a failed one is retried.
        if last == head:
            return {'mac': False, 'ipad': False}, f'main is unchanged since the last successful nightly ({head})'
        return everything, 'nightly runs every job'
    if event == 'pull_request':
        try:
            parents = git('rev-list', '--parents', '-n', '1', head).split()[1:]
            # The default checkout is GitHub's test merge commit; its first
            # parent is the base branch, so the diff is exactly this PR.
            base = parents[0] if len(parents) == 2 else git('merge-base', pr_base, head)
        except (subprocess.CalledProcessError, TypeError) as error:
            return everything, f'could not find the pull request base ({error}); running everything'
    elif event == 'push':
        try:
            candidates = [sha for sha in runs(repository, 'push') if sha != head]
        except (OSError, subprocess.CalledProcessError) as error:
            return everything, f'could not read previous main runs ({error}); running everything'
        # Diffing against the last successful main run, not the previous
        # commit, keeps changes from cancelled or failed runs selected.
        base = next((sha for sha in candidates if is_ancestor(sha, head)), None)
        if base is None:
            return everything, 'no successful earlier main run is an ancestor; running everything'
    else:
        return everything, f'unexpected event {event}; running everything'
    try:
        paths = changed_paths(base, head)
    except subprocess.CalledProcessError as error:
        return everything, f'could not diff {base}..{head} ({error}); running everything'
    selection = select(paths)
    listed = '\n'.join(f'- `{path}`: {"+".join(sorted(classify(path))) or "docs"}' for path in paths[:200])
    return selection, f'{len(paths)} changed path(s) since {base}:\n{listed}'


def outputs(selection, event, ref, suite, publish_preview=False):
    """The job outputs: platform selection plus the main-only release and publish steps."""
    release = selection['mac'] and ref == 'refs/heads/main' and event in ('schedule', 'workflow_dispatch')
    publish = release and (event == 'schedule' or publish_preview)
    return {'mac': selection['mac'], 'ipad': selection['ipad'], 'suite': suite, 'release': release, 'publish': publish}


def expected_results(mac, ipad, suite, release):
    """The result each gated job must report for this selection. Preview
    publication is deliberately not gated: it reports its own failure."""
    def need(selected):
        return 'success' if selected else 'skipped'
    return {
        'integration': need(mac),
        'appstore': need(release),
        'memory': need(release),
        'ipad-build': need(ipad),
        'ipad-simulator-build': need(ipad),
        'ipad-ui': need(ipad),
        'ipad-coverage': need(ipad and suite == 'full'),
        'ipad-memory': need(ipad and suite == 'full'),
    }


def gate(needs):
    """Return a list of problems with the `needs` context of the gate job."""
    changes = needs.get('changes', {})
    if changes.get('result') != 'success':
        return [f"changes is {changes.get('result')}, expected success"]
    values = changes.get('outputs', {})
    flags = [values.get(name) for name in ('mac', 'ipad', 'release')]
    if any(flag not in ('true', 'false') for flag in flags) or values.get('suite') not in ('smoke', 'full'):
        return [f'changes produced invalid outputs {values}']
    mac, ipad, release = (flag == 'true' for flag in flags)
    if release and not mac:
        return [f'changes selected release checks without Mac jobs: {values}']
    expected = expected_results(mac, ipad, values['suite'], release)
    problems = []
    for job, result in expected.items():
        actual = needs.get(job, {}).get('result')
        if actual != result:
            problems.append(f'{job} is {actual}, expected {result}')
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('select', help='write the job selection to $GITHUB_OUTPUT')
    commands.add_parser('gate', help='check the gate job needs context (JSON in $NEEDS)')
    commands.add_parser('classify', help='print the platforms for each path on stdin')
    args = parser.parse_args()

    if args.command == 'classify':
        for path in sys.stdin.read().split():
            print(path, '+'.join(sorted(classify(path))) or 'docs')
        return 0
    if args.command == 'gate':
        problems = gate(json.loads(os.environ['NEEDS']))
        for problem in problems:
            print('::error::' + problem)
        if not problems:
            print('Every selected job passed; every other job was skipped.')
        return 1 if problems else 0

    suite = os.environ['IPAD_SUITE']
    if suite not in ('smoke', 'full'):
        raise SystemExit(f'Unexpected IPAD_SUITE {suite}')
    event = os.environ['GITHUB_EVENT_NAME']
    publish_preview = event == 'workflow_dispatch' and os.environ.get('PUBLISH_PREVIEW') == 'true'
    selection, reason = plan(event, os.environ['GITHUB_SHA'], suite, os.environ['GITHUB_REPOSITORY'],
                             pr_base=os.environ.get('PR_BASE_SHA'), publish_preview=publish_preview)
    result = outputs(selection, event, os.environ['GITHUB_REF'], suite, publish_preview)
    lines = [f'{name}={str(value).lower()}' for name, value in result.items()]
    print('\n'.join(lines))
    print(reason)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('\n'.join(lines) + '\n')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as output:
            output.write('### Selected jobs\n\n' + ', '.join(f'{name}: **{value}**' for name, value in result.items())
                         + f'\n\n{reason}\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
