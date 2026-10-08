#!/usr/bin/env python3
"""Exercise real Sparkle signing, public-key verification and tamper rejection."""
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'scripts'))
import preview_channels as channels  # noqa: E402

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def feed_root(*items):
    """A feed with (build, channel) items, as previously published."""
    root = ET.Element('rss', version='2.0')
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'LeftBlank Preview'
    for build, name in items:
        item = ET.SubElement(channel, 'item')
        ET.SubElement(item, SPARKLE + 'version').text = build
        if name == channels.ALPHA:
            ET.SubElement(item, SPARKLE + 'channel').text = name
        ET.SubElement(item, 'enclosure', url='https://github.com/leftblank-app/leftblank/releases/download/'
                      f'{channels.release_tag(build, name)}/LeftBlank-Preview.zip')
    return root


class PreviewReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['scripts/sparkle-tools.sh'], cwd=ROOT, check=True)

    def test_signed_archive_feed_and_wrong_key(self):
        key = base64.b64encode(os.urandom(32))
        public = subprocess.check_output(['swift', '-module-cache-path', str(ROOT / '.build/update-module-cache'),
                                          str(ROOT / 'scripts/verify-update.swift'), '--public-key'], input=key).decode().strip()
        with tempfile.TemporaryDirectory(prefix='leftblank-update-contract-', dir=os.environ['TMPDIR']) as temporary:
            root = Path(temporary)
            (root / 'scripts').symlink_to(ROOT / 'scripts', target_is_directory=True)
            (root / '.tools').symlink_to(ROOT / '.tools', target_is_directory=True)
            (root / 'Resources').mkdir()
            info = plistlib.loads((ROOT / 'Resources/Preview-Info.plist').read_bytes())
            info['SUPublicEDKey'] = public
            (root / 'Resources/Preview-Info.plist').write_bytes(plistlib.dumps(info))
            info.update(CFBundleVersion='91.1', CFBundleShortVersionString='0.5.0', LeftBlankCommit='abcdef123456')
            archive = root / 'LeftBlank-Preview-test.zip'
            with zipfile.ZipFile(archive, 'w') as bundle:
                bundle.writestr('LeftBlank Preview.app/Contents/Info.plist', plistlib.dumps(info))
            # No published feed yet; never read the live feed from a test.
            environment = {**os.environ, 'SPARKLE_PRIVATE_KEY': key.decode(), 'PREVIEW_CURRENT_FEED': ''}
            def generate(build='91.1', **extra):
                return subprocess.run(['python3', str(ROOT / 'scripts/preview-feed.py'), str(archive), build],
                                      cwd=root, env={**environment, **extra}, capture_output=True)
            result = generate()
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            feed = root / 'appcast.xml'
            enclosure = ET.parse(feed).find('.//enclosure')
            self.assertIn('/preview-91.1/', enclosure.attrib['url'])
            signature = enclosure.attrib['{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature']
            # The public key compiled into the application independently accepts the archive.
            verifier = ['swift', '-module-cache-path', str(ROOT / '.build/update-module-cache'),
                        str(ROOT / 'scripts/verify-update.swift'), public, signature, str(archive)]
            self.assertEqual(subprocess.run(verifier, capture_output=True).returncode, 0)
            self.assertNotEqual(generate('92.1').returncode, 0)
            self.assertNotEqual(generate(SPARKLE_PRIVATE_KEY=base64.b64encode(os.urandom(32)).decode()).returncode, 0)
            archive.write_bytes(archive.read_bytes() + b'corrupt')
            self.assertNotEqual(subprocess.run(verifier, capture_output=True).returncode, 0)
            feed.write_bytes(feed.read_bytes().replace(b'Tested nightly', b'Changed nightly'))
            result = subprocess.run([str(ROOT / '.tools/sparkle/bin/sign_update'), '--ed-key-file', '-',
                                     '--verify', str(feed)], input=key, capture_output=True)
            self.assertNotEqual(result.returncode, 0)


    def test_channels_share_one_signed_feed(self):
        key = base64.b64encode(os.urandom(32))
        public = subprocess.check_output(['swift', '-module-cache-path', str(ROOT / '.build/update-module-cache'),
                                          str(ROOT / 'scripts/verify-update.swift'), '--public-key'], input=key).decode().strip()
        signer = str(ROOT / '.tools/sparkle/bin/sign_update')
        with tempfile.TemporaryDirectory(prefix='leftblank-channels-contract-', dir=os.environ['TMPDIR']) as temporary:
            root = Path(temporary)
            (root / 'scripts').symlink_to(ROOT / 'scripts', target_is_directory=True)
            (root / '.tools').symlink_to(ROOT / '.tools', target_is_directory=True)
            (root / 'Resources').mkdir()
            info = plistlib.loads((ROOT / 'Resources/Preview-Info.plist').read_bytes())
            info['SUPublicEDKey'] = public
            (root / 'Resources/Preview-Info.plist').write_bytes(plistlib.dumps(info))
            archive, feed = root / 'LeftBlank-Preview-test.zip', root / 'appcast.xml'

            def publish(build, channel, current):
                with zipfile.ZipFile(archive, 'w') as bundle:
                    bundle.writestr('LeftBlank Preview.app/Contents/Info.plist', plistlib.dumps(
                        {**info, 'CFBundleVersion': build, 'CFBundleShortVersionString': '0.5.0',
                         'LeftBlankCommit': 'abcdef123456'}))
                result = subprocess.run(['python3', str(ROOT / 'scripts/preview-feed.py'), str(archive), build, channel],
                                        cwd=root, capture_output=True, env={
                                            **os.environ, 'SPARKLE_PRIVATE_KEY': key.decode(),
                                            'PREVIEW_CURRENT_FEED': str(current) if current else ''})
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                saved = root / f'{channel}-{build}.xml'
                saved.write_bytes(feed.read_bytes())
                return saved

            def items(path):
                return {channels.item_channel(item): (channels.version(item), item.find('enclosure').attrib['url'])
                        for item in ET.parse(path).getroot().findall('./channel/item')}

            nightly = publish('91.1', 'nightly', None)
            both = publish('92.1', 'alpha', nightly)
            self.assertEqual(set(items(both)), {'nightly', 'alpha'})
            self.assertEqual(items(both)['nightly'][0], '91.1')
            self.assertEqual(items(both)['alpha'][0], '92.1')
            self.assertIn('/preview-alpha-92.1/', items(both)['alpha'][1])
            self.assertIn('/preview-91.1/', items(both)['nightly'][1])
            # Nightly items stay on Sparkle's default channel.
            nightly_item = next(item for item in ET.parse(both).getroot().iter('item')
                                if channels.version(item) == '91.1')
            self.assertIsNone(nightly_item.find(SPARKLE + 'channel'))
            # A new nightly replaces only the nightly item; the merged feed is re-signed.
            later = publish('93.1', 'nightly', both)
            self.assertEqual({name: entry[0] for name, entry in items(later).items()},
                             {'nightly': '93.1', 'alpha': '92.1'})
            verify = [signer, '--ed-key-file', '-', '--verify', str(later)]
            self.assertEqual(subprocess.run(verify, input=key, capture_output=True).returncode, 0)
            # A tampered published feed is never merged.
            later.write_bytes(later.read_bytes().replace(b'93.1', b'99.1'))
            with zipfile.ZipFile(archive, 'w') as bundle:
                bundle.writestr('LeftBlank Preview.app/Contents/Info.plist', plistlib.dumps(
                    {**info, 'CFBundleVersion': '94.1', 'LeftBlankCommit': 'abcdef123456',
                     'CFBundleShortVersionString': '0.5.0'}))
            result = subprocess.run(['python3', str(ROOT / 'scripts/preview-feed.py'), str(archive), '94.1', 'alpha'],
                                    cwd=root, capture_output=True, env={
                                        **os.environ, 'SPARKLE_PRIVATE_KEY': key.decode(),
                                        'PREVIEW_CURRENT_FEED': str(later)})
            self.assertNotEqual(result.returncode, 0)
            # Identity checks still apply per channel.
            result = subprocess.run(['python3', str(ROOT / 'scripts/preview-feed.py'), str(archive), '95.1', 'alpha'],
                                    cwd=root, capture_output=True, env={
                                        **os.environ, 'SPARKLE_PRIVATE_KEY': key.decode(), 'PREVIEW_CURRENT_FEED': ''})
            self.assertNotEqual(result.returncode, 0)
            result = subprocess.run(['python3', str(ROOT / 'scripts/preview-feed.py'), str(archive), '94.1', 'beta'],
                                    cwd=root, capture_output=True, env={
                                        **os.environ, 'SPARKLE_PRIVATE_KEY': key.decode(), 'PREVIEW_CURRENT_FEED': ''})
            self.assertNotEqual(result.returncode, 0)


class PreviewChannelTests(unittest.TestCase):
    def test_merge_replaces_only_its_own_channel(self):
        current = feed_root(('91.1', 'nightly'), ('92.1', 'alpha'))
        merged = channels.merge(current, feed_root(('95.1', 'alpha')))
        self.assertEqual({name: channels.version(item) for name, item in channels.items_by_channel(merged).items()},
                         {'nightly': '91.1', 'alpha': '95.1'})
        self.assertEqual([channels.version(item) for item in merged.iter('item')], ['95.1', '91.1'])

    def test_a_feed_from_before_channels_is_the_nightly_channel(self):
        merged = channels.merge(feed_root(('90.1', 'nightly')), feed_root(('91.1', 'alpha')))
        self.assertEqual(set(channels.items_by_channel(merged)), {'nightly', 'alpha'})
        self.assertEqual(channels.merge(None, feed_root(('91.1', 'nightly'))).findtext('./channel/title'),
                         'LeftBlank Preview')

    def test_an_older_build_never_moves_its_channel_back(self):
        current = feed_root(('91.1', 'nightly'), ('95.1', 'alpha'))
        self.assertTrue(channels.superseded(current, 'alpha', '94.1'))
        self.assertTrue(channels.superseded(current, 'alpha', '95.1'))
        self.assertFalse(channels.superseded(current, 'alpha', '95.2'))
        # Channels are independent: an alpha build newer than nightly does not block nightly.
        self.assertFalse(channels.superseded(current, 'nightly', '92.1'))
        self.assertFalse(channels.superseded(feed_root(('91.1', 'nightly')), 'alpha', '90.1'))
        # Build numbers compare numerically, not as text.
        self.assertFalse(channels.superseded(feed_root(('9.1', 'nightly')), 'nightly', '10.1'))

    def test_pruning_keeps_recent_alpha_and_whatever_the_feed_offers(self):
        tags = ['preview-latest', 'preview-80.1', 'preview-81.1', *(f'preview-alpha-{n}.1' for n in range(90, 100))]
        feed = feed_root(('81.1', 'nightly'), ('91.1', 'alpha'))
        pruned = channels.alpha_tags_to_prune(tags, feed)
        self.assertEqual(sorted(pruned), sorted(f'preview-alpha-{n}.1' for n in (90, 92, 93, 94)))
        self.assertFalse(any(not tag.startswith('preview-alpha-') for tag in pruned))
        self.assertEqual(channels.alpha_tags_to_prune(tags[:5], feed), [])

    def test_release_tags_distinguish_channels(self):
        self.assertEqual(channels.release_tag('91.1', 'nightly'), 'preview-91.1')
        self.assertEqual(channels.release_tag('91.1', 'alpha'), 'preview-alpha-91.1')
        with self.assertRaises(ValueError):
            channels.release_tag('91.1', 'beta')


if __name__ == '__main__':
    unittest.main()
