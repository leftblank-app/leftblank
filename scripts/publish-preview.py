#!/usr/bin/env python3
"""Publish versioned binaries first, then advance the stable signed feed.

The feed holds the newest nightly item and the newest alpha item; this
publisher's build is its own channel's item (PREVIEW_CHANNEL).
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import preview_channels as channels  # noqa: E402

REPO = 'leftblank-app/leftblank'
FEED_TAG = 'preview-latest'


def gh(*args, **kwargs):
    return subprocess.check_output(['gh', *args, '--repo', REPO], text=True, **kwargs).strip()


def release_exists(tag):
    result = subprocess.run(['gh', 'release', 'view', tag, '--repo', REPO, '--json', 'tagName'],
                            text=True, capture_output=True)
    if result.returncode == 0:
        return True
    if 'release not found' in result.stderr.lower():
        return False
    raise RuntimeError(result.stderr.strip())


def main():
    directory = Path('build/release')
    feed = ET.parse(directory / 'appcast.xml').getroot()
    channel = os.environ.get('PREVIEW_CHANNEL', channels.NIGHTLY)
    build = channels.version(channels.items_by_channel(feed)[channel])
    tag = channels.release_tag(build, channel)
    commit = os.environ['GITHUB_SHA']
    # GITHUB_SHA must be the commit that passed the dependency job, never a fresh checkout of main.
    subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'origin/main'], check=True)
    notes = directory / 'notes.md'
    notes.write_text(f'Tested {channel} main build **{build}**, commit `{commit}`.\n\nDownload the ZIP, unzip and drag **LeftBlank Preview.app** to Applications. Preview uses its own local library and offers signed updates. It does not access the stable app\'s iCloud library.\n')
    if not release_exists(tag):
        gh('release', 'create', tag, *map(str, directory.glob('*.zip')), *map(str, directory.glob('*.sha256')),
           str(directory / 'appcast.xml'), '--target', commit, '--prerelease', '--latest=false',
           '--title', f'LeftBlank Preview {build}' + (' (alpha)' if channel == channels.ALPHA else ''),
           '--notes-file', str(notes))
    if not release_exists(FEED_TAG):
        gh('release', 'create', FEED_TAG, '--target', commit, '--prerelease', '--latest=false',
           '--title', 'LeftBlank Preview updates', '--notes', 'Signed update feed for LeftBlank Preview: the newest nightly build, plus the newest alpha build for apps that opt in. The feed tag stays fixed; each app archive has its own immutable build tag.')
    # Reject an old rerun so it can never move its channel back. The feed was
    # merged when this build was signed; if the other channel published since,
    # its item reverts until that channel's next publication.
    current = directory / 'current-feed'
    current.mkdir(exist_ok=True)
    assets = json.loads(gh('release', 'view', FEED_TAG, '--json', 'assets'))['assets']
    if any(asset['name'] == 'appcast.xml' for asset in assets):
        gh('release', 'download', FEED_TAG, '--pattern', 'appcast.xml', '--dir', str(current), '--clobber')
        if channels.superseded(ET.parse(current / 'appcast.xml').getroot(), channel, build):
            print(f'The {channel} channel already offers a build at least as new as {build}; preserving it.')
            return
    gh('release', 'upload', FEED_TAG, str(directory / 'appcast.xml'), '--clobber')
    print(f'Published LeftBlank Preview {build} to the {channel} channel.')
    # Only after the new feed is live, and never what it points to.
    tags = gh('release', 'list', '--limit', '1000', '--json', 'tagName', '--jq', '.[].tagName').split()
    for old in channels.alpha_tags_to_prune(tags, feed):
        gh('release', 'delete', old, '--cleanup-tag', '--yes')
        print(f'Pruned old alpha release {old}.')


if __name__ == '__main__':
    main()
