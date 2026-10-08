#!/usr/bin/env python3
"""Sign an immutable preview archive and its feed without exporting the CI key.

The new build replaces only its own channel's item in the published feed
(nightly or alpha, see preview_channels.py), and the merged feed is re-signed.
"""
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from preview_channels import ALPHA, CHANNELS, NIGHTLY, SPARKLE, merge, release_tag  # noqa: E402


def published_feed(url, key, signer):
    """The live feed, verified with the CI key, or None before the first build.
    PREVIEW_CURRENT_FEED names a local copy instead (empty: no feed yet)."""
    local = os.environ.get('PREVIEW_CURRENT_FEED')
    path = Path('build/current-appcast.xml')
    if local is not None:
        if not local:
            return None
        path = Path(local)
    else:
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(response.read())
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise
    subprocess.run([signer, '--ed-key-file', '-', '--verify', str(path)], input=key, check=True)
    return ET.parse(path).getroot()


def make_feed(archive, build, channel=NIGHTLY):
    if not re.fullmatch(r'[1-9][0-9]*\.[1-9][0-9]*', build):
        raise ValueError('Expected run_number.run_attempt')
    if channel not in CHANNELS:
        raise ValueError(f'Unknown Preview channel {channel!r}')
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read('LeftBlank Preview.app/Contents/Info.plist'))
    if info.get('CFBundleIdentifier') != 'app.leftblank.writer.preview' or info.get('CFBundleVersion') != build:
        raise ValueError('Archive identity/build does not match the preview feed')
    expected = plistlib.loads(Path('Resources/Preview-Info.plist').read_bytes())
    if any(info.get(key) != value for key, value in expected.items()):
        raise ValueError('Archive update configuration differs from the committed configuration')
    key = os.environ['SPARKLE_PRIVATE_KEY'].strip().encode()
    if len(base64.b64decode(key, validate=True)) != 32:
        raise ValueError('Expected a Sparkle Ed25519 seed')
    subprocess.run(['scripts/sparkle-tools.sh'], check=True)
    signer = '.tools/sparkle/bin/sign_update'
    signature = subprocess.check_output([signer, '--ed-key-file', '-', '-p', str(archive)], input=key).decode().strip()
    subprocess.run(['swift', '-module-cache-path', '.build/update-module-cache',
                    'scripts/verify-update.swift', info['SUPublicEDKey'], signature, str(archive)], check=True)
    root = ET.Element('rss', version='2.0')
    feed_channel = ET.SubElement(root, 'channel')
    ET.SubElement(feed_channel, 'title').text = 'LeftBlank Preview'
    ET.SubElement(feed_channel, 'link').text = 'https://leftblank.app'
    item = ET.SubElement(feed_channel, 'item')
    ET.SubElement(item, 'title').text = f'LeftBlank Preview {info["CFBundleShortVersionString"]} ({build})'
    ET.SubElement(item, 'pubDate').text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = build
    if channel == ALPHA:
        # Nightly stays Sparkle's default channel; only opted-in apps see alpha.
        ET.SubElement(item, f'{{{SPARKLE}}}channel').text = ALPHA
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = info['CFBundleShortVersionString']
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = '14.0.0'
    ET.SubElement(item, f'{{{SPARKLE}}}hardwareRequirements').text = 'arm64'
    kind = 'alpha' if channel == ALPHA else 'nightly'
    ET.SubElement(item, 'description').text = f'Tested {kind} main build {build}. Commit {info["LeftBlankCommit"][:12]}. Your writing and preferences stay on this Mac.'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/leftblank-app/leftblank/releases/download/{release_tag(build, channel)}/{archive.name}',
        'length': str(archive.stat().st_size), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}edSignature': signature,
    })
    feed = archive.parent / 'appcast.xml'
    root = merge(published_feed(expected['SUFeedURL'], key, signer), root)
    ET.ElementTree(root).write(feed, encoding='utf-8', xml_declaration=True)
    subprocess.run([signer, '--ed-key-file', '-', str(feed)], input=key, check=True)
    subprocess.run([signer, '--ed-key-file', '-', '--verify', str(feed)], input=key, check=True)
    subprocess.run([signer, '--ed-key-file', '-', '--verify', str(archive), signature], input=key, check=True)
    print(f'Preview archive and feed signatures verified for build {build}.')


if __name__ == '__main__':
    make_feed(Path(sys.argv[1]), sys.argv[2], *sys.argv[3:4])
