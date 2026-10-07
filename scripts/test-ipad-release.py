#!/usr/bin/env python3
"""Offline iPad signing, archive and platform isolation release contracts."""
import copy
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch

import appstore_connect as asc
import ipad_frameworks
import ipad_release as ipad
from ipad_storefront import Storefront

spec = importlib.util.spec_from_file_location('mac_release_tests', Path(__file__).with_name('test-appstore-release.py'))
mac = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mac)


class MetadataTests(unittest.TestCase):
    def test_icon_rejects_alpha_channel_even_if_pixels_are_opaque(self):
        source = ipad.ROOT / 'iPad/Assets.xcassets/AppIcon.appiconset/icon.png'
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            path = Path(directory) / 'icon.png'
            data = bytearray(source.read_bytes())
            data[25] = 6
            path.write_bytes(data)
            with self.assertRaisesRegex(ValueError, 'alpha channel'):
                ipad.validate_icon(path)

    def test_icon_rejects_transparency_chunk_and_wrong_size(self):
        source = ipad.ROOT / 'iPad/Assets.xcassets/AppIcon.appiconset/icon.png'
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            path = Path(directory) / 'icon.png'
            data = source.read_bytes()
            path.write_bytes(data[:33] + struct.pack('>I', 6) + b'tRNS' + bytes(10) + data[33:])
            with self.assertRaisesRegex(ValueError, 'transparency'):
                ipad.validate_icon(path)
            resized = bytearray(data)
            resized[16:20] = struct.pack('>I', 512)
            path.write_bytes(resized)
            with self.assertRaisesRegex(ValueError, '1024x1024'):
                ipad.validate_icon(path)

    def test_bilingual_metadata_and_confirmed_subscription(self):
        result = ipad.metadata(ipad.ROOT)
        self.assertEqual(result['platform'], 'IOS')
        self.assertEqual(result['storefront']['subscription']['product_id'], ipad.PRODUCT)
        self.assertEqual(set(result['localizations']), {'en-US', 'zh-Hans'})

    def test_price_or_trial_drift_stops_release(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            root = Path(directory)
            (root / 'iPad/Storefront').mkdir(parents=True)
            (root / 'iPad/Info.plist').write_bytes((ipad.ROOT / 'iPad/Info.plist').read_bytes())
            original = json.loads((ipad.ROOT / 'iPad/Storefront/manifest.json').read_text())
            for field, value in [('base_price', '3.99'), ('period', 'ONE_YEAR'),
                                  ('introductory_offer', {'mode': 'FREE_TRIAL', 'duration': 'ONE_MONTH'})]:
                with self.subTest(field=field):
                    store = copy.deepcopy(original)
                    store['subscription'][field] = value
                    (root / 'iPad/Storefront/manifest.json').write_text(json.dumps(store))
                    with self.assertRaisesRegex(ValueError, 'business model'):
                        ipad.metadata(root)


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.identity = hashlib.sha1(b'certificate').hexdigest().upper()
        self.profile = {
            'Platform': ['iOS'], 'UUID': 'uuid', 'TeamIdentifier': ['TEAM'],
            'DeveloperCertificates': [b'certificate'],
            'ExpirationDate': datetime.datetime(2030, 1, 1),
            'Entitlements': {
                'application-identifier': 'TEAM.' + ipad.BUNDLE, 'get-task-allow': False,
                'com.apple.developer.icloud-container-identifiers': ['iCloud.' + ipad.BUNDLE],
                'com.apple.developer.ubiquity-container-identifiers': ['iCloud.' + ipad.BUNDLE],
                'com.apple.developer.icloud-services': ['CloudDocuments'],
                'com.apple.developer.icloud-container-environment': 'Production',
                'com.apple.developer.ubiquity-kvstore-identifier': 'TEAM.' + ipad.BUNDLE,
            },
        }

    def test_appstore_production_profile(self):
        self.assertEqual(ipad.validate_profile(self.profile, self.identity), ('TEAM', 'uuid'))

    def test_apple_profile_allows_production_with_wildcard_cloud_services(self):
        # Entitlement shapes from the actual Apple-generated iOS App Store profile.
        self.profile['Entitlements'].update({
            'com.apple.developer.icloud-services': '*',
            'com.apple.developer.icloud-container-environment': ['Production', 'Development'],
            'com.apple.developer.ubiquity-kvstore-identifier': 'TEAM.*',
        })
        self.assertEqual(ipad.validate_profile(self.profile, self.identity), ('TEAM', 'uuid'))

    def test_development_adhoc_enterprise_mac_and_expired_profiles_stop(self):
        for changes in [{'Platform': ['OSX']}, {'ProvisionedDevices': ['device']},
                        {'ProvisionsAllDevices': True}, {'ExpirationDate': datetime.datetime(2020, 1, 1)}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                ipad.validate_profile({**self.profile, **changes}, self.identity)
        for key, value in [('application-identifier', 'TEAM.other'), ('get-task-allow', True),
                           ('com.apple.developer.icloud-container-environment', 'Development'),
                           ('com.apple.developer.icloud-container-environment', ['Development']),
                           ('com.apple.developer.icloud-container-environment', None),
                           ('com.apple.developer.icloud-services', ['CloudKit']),
                           ('com.apple.developer.icloud-services', None),
                           ('com.apple.developer.ubiquity-container-identifiers', []),
                           ('com.apple.developer.ubiquity-kvstore-identifier', 'OTHER.*')]:
            with self.subTest(key=key):
                profile = copy.deepcopy(self.profile)
                profile['Entitlements'][key] = value
                with self.assertRaises(ValueError):
                    ipad.validate_profile(profile, self.identity)
        with self.assertRaisesRegex(ValueError, 'certificate'):
            ipad.validate_profile(self.profile, 'NOT_THE_CERTIFICATE')


CORE = '@rpath/LeftBlankCore.framework/LeftBlankCore'


class ArchiveTests(unittest.TestCase):
    @patch('ipad_frameworks.load_commands', return_value=(['/usr/lib/swift', '@executable_path/Frameworks'], [CORE]))
    def test_versions_device_family_crypto_and_desktop_components(self, _):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            archive = Path(directory)
            app = archive / 'Products/Applications/LeftBlank.app'
            app.mkdir(parents=True)
            (app / 'LeftBlank').write_bytes(b'executable')
            core = app / 'Frameworks/LeftBlankCore.framework/LeftBlankCore'
            core.parent.mkdir(parents=True)
            core.write_bytes(b'framework')
            info = {'CFBundleIdentifier': ipad.BUNDLE, 'CFBundleShortVersionString': '1.0.0',
                    'CFBundleVersion': '1', 'UIDeviceFamily': [2], 'CFBundleExecutable': 'LeftBlank',
                    'ITSAppUsesNonExemptEncryption': False, 'CFBundleSupportedPlatforms': ['iPhoneOS']}
            path = app / 'Info.plist'
            path.write_bytes(plistlib.dumps(info))
            expected = {'version': '1.0.0', 'build': '1'}
            (app / 'Sparkle-LICENSE.txt').write_text('Shared third-party attribution')
            (app / 'sparkle.svg').write_text('<svg/>')
            self.assertEqual(ipad.validate_archive(archive, expected), app)
            for key, value in [('CFBundleVersion', '2'), ('UIDeviceFamily', [1, 2]),
                               ('ITSAppUsesNonExemptEncryption', True), ('CFBundleSupportedPlatforms', ['MacOSX'])]:
                with self.subTest(key=key):
                    path.write_bytes(plistlib.dumps({**info, key: value}))
                    with self.assertRaisesRegex(ValueError, key):
                        ipad.validate_archive(archive, expected)
            path.write_bytes(plistlib.dumps(info))
            for name in ['LeftBlankMCP', 'Sparkle.framework', 'LeftBlankAutomation.framework']:
                unexpected = app / name
                if name.endswith('.framework'):
                    unexpected.mkdir()
                else:
                    unexpected.touch()
                with self.assertRaisesRegex(ValueError, 'desktop-only'):
                    ipad.validate_archive(archive, expected)
                if unexpected.is_dir():
                    unexpected.rmdir()
                else:
                    unexpected.unlink()
            for name in ['LeftBlank.storekit', 'LeftBlankTests.xctest']:
                unexpected = app / name
                unexpected.touch()
                with self.assertRaisesRegex(ValueError, 'test-only'):
                    ipad.validate_archive(archive, expected)
                unexpected.unlink()
            core.unlink()
            with self.assertRaisesRegex(ValueError, 'shared Core framework'):
                ipad.validate_archive(archive, expected)

    def test_linked_frameworks_must_resolve_inside_the_installed_app(self):
        # The simulator finds LeftBlankCore in the build products, so only a
        # device launch fails when the app lacks @executable_path/Frameworks.
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            app = Path(directory) / 'LeftBlank.app'
            core = app / 'Frameworks/LeftBlankCore.framework/LeftBlankCore'
            core.parent.mkdir(parents=True)
            core.touch()
            (app / 'LeftBlank').touch()
            (app / 'LeftBlank.debug.dylib').touch()
            for rpaths in [['/usr/lib/swift'], ['@loader_path'], ['/Volumes/build/PackageFrameworks']]:
                with self.subTest(rpaths=rpaths), patch('ipad_frameworks.load_commands', return_value=(rpaths, [CORE])):
                    with self.assertRaisesRegex(ValueError, 'without a runpath'):
                        ipad_frameworks.check_app(app)
            for rpaths in [['@executable_path/Frameworks'], ['@loader_path/Frameworks']]:
                with self.subTest(rpaths=rpaths), patch('ipad_frameworks.load_commands', return_value=(rpaths, [CORE])):
                    ipad_frameworks.check_app(app)
            with patch('ipad_frameworks.load_commands', return_value=([], ['/usr/lib/libSystem.B.dylib'])):
                ipad_frameworks.check_app(app)


class PlatformTests(unittest.TestCase):
    def test_latest_required_ci_gate_must_pass(self):
        check = {'id': 1, 'name': 'build and test', 'conclusion': 'success', 'app': {'slug': 'github-actions'}}
        ipad.validate_ci([check])
        for records in [[], [{**check, 'conclusion': 'failure'}], [{**check, 'app': {'slug': 'other'}}],
                        [check, {**check, 'id': 2, 'conclusion': None}]]:
            with self.subTest(records=records), self.assertRaisesRegex(ValueError, 'gate has not passed'):
                ipad.validate_ci(records)

    def test_ios_filters_do_not_confuse_mac_builds_or_pending_versions(self):
        apple = mac.FakeApple()
        original = apple.list
        calls = []

        def list_platform(path, **query):
            calls.append((path, query))
            return original(path, **query)

        apple.list = list_platform
        release = asc.Release(apple, 'app', {'version': '1.0.0', 'build': '1'}, platform='IOS')
        self.assertTrue(release.preflight())
        self.assertTrue(any(query.get('filter[platform]') == 'IOS' for _, query in calls))
        self.assertTrue(any(query.get('filter[preReleaseVersion.platform]') == 'IOS' for _, query in calls))
        self.assertFalse(any('MAC_OS' in query.values() for _, query in calls))

    def test_initial_subscription_cannot_be_submitted_as_an_app_only_review(self):
        apple = mac.FakeApple()
        release = asc.Release(apple, '6818442294', ipad.metadata(ipad.ROOT), platform='IOS')
        prepared = {'appStoreVersion': {'id': 'ios-version'}, 'firstSubscription': True, 'submitted': False}
        with patch.object(Storefront, 'prepare', return_value=prepared), patch('ipad_storefront.Path.write_text'):
            with self.assertRaisesRegex(RuntimeError, 'initial submission'):
                release.submit(apple.build)
        self.assertEqual(apple.writes, [])

    def test_api_supports_versioned_subscription_metadata_without_cross_origin_requests(self):
        client = asc.Client(Path('unused'), 'key', 'issuer')
        for path in ['https://evil.example/v2/subscriptionLocalizations', '//evil.example/v1/apps',
                     '/v20/apps', 'https://api.appstoreconnect.apple.com.evil.example/v1/apps']:
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, 'origin'):
                client.request('GET', path)

    def test_only_missing_optional_resources_are_ignored(self):
        client = asc.Client(Path('unused'), 'key', 'issuer')
        with patch.object(client, 'request', side_effect=asc.APIError(404, 'not found')):
            self.assertIsNone(client.optional('/v1/subscriptions/id/subscriptionAvailability'))
        with patch.object(client, 'request', side_effect=asc.APIError(403, 'forbidden')):
            with self.assertRaisesRegex(asc.APIError, 'forbidden'):
                client.optional('/v1/subscriptions/id/subscriptionAvailability')


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.apple = mac.FakeApple()
        self.release = asc.Release(self.apple, '6818442294', ipad.metadata(ipad.ROOT), 'IOS')
        self.store = Storefront(self.release)
        self.apple.version = mac.resource('appStoreVersions', 'version', appVersionState='PREPARE_FOR_SUBMISSION')
        self.prepared = {'submitted': False, 'firstSubscription': False, 'appStoreVersion': self.apple.version,
                         'subscriptionVersion': None, 'subscriptionGroupVersion': None}

    def test_subsequent_tag_submits_the_exact_ios_version(self):
        with patch.object(self.store, 'prepare', return_value=self.prepared):
            result = self.store.submit(self.apple.build)
        self.assertEqual(result['attributes']['state'], 'WAITING_FOR_REVIEW')
        creation = next(data for _, path, data in self.apple.writes if path == '/v1/reviewSubmissions')
        self.assertEqual(creation['data']['attributes']['platform'], 'IOS')
        self.assertEqual(self.apple.items[0]['relationships']['appStoreVersion']['data']['id'], 'version')

    def test_resuming_owned_draft_does_not_duplicate_review_items(self):
        self.apple.submission = mac.resource('reviewSubmissions', 'submission', state='READY_FOR_REVIEW')
        self.apple.items = [{'id': 'item', 'relationships': {'appStoreVersion': asc.relationship('appStoreVersions', 'version')}}]
        with patch.object(self.store, 'prepare', return_value=self.prepared):
            self.store.submit(self.apple.build)
        self.assertFalse(any(path == '/v1/reviewSubmissionItems' for _, path, _ in self.apple.writes))

    def test_unrelated_draft_is_never_submitted_or_withdrawn(self):
        self.apple.submission = mac.resource('reviewSubmissions', 'submission', state='READY_FOR_REVIEW')
        self.apple.items = [{'id': 'item', 'relationships': {'appStoreVersion': asc.relationship('appStoreVersions', 'other')}}]
        with patch.object(self.store, 'prepare', return_value=self.prepared):
            with self.assertRaisesRegex(RuntimeError, 'unrelated'):
                self.store.submit(self.apple.build)
        self.assertEqual(self.apple.writes, [])

    def test_previously_submitted_review_needs_no_more_writes(self):
        with patch.object(self.store, 'prepare', return_value={'submitted': True}):
            self.assertEqual(self.store.submit(self.apple.build), {'submitted': True})
        self.assertEqual(self.apple.writes, [])


class PricingTests(unittest.TestCase):
    def setUp(self):
        self.apple = mac.FakeApple()
        self.store = Storefront(asc.Release(self.apple, '6818442294', ipad.metadata(ipad.ROOT), 'IOS'))
        self.point = {**mac.resource('subscriptionPricePoints', 'usd-299', customerPrice='2.99'),
                      'relationships': {'territory': asc.relationship('territories', 'USA')}}
        self.price = {**mac.resource('subscriptionPrices', 'price', startDate='2026-01-01'),
                      'relationships': {'territory': asc.relationship('territories', 'USA'),
                                        'subscriptionPricePoint': asc.relationship('subscriptionPricePoints', 'usd-299')}}
        self.offer = {**mac.resource('subscriptionIntroductoryOffers', 'offer', duration='TWO_WEEKS',
                                    offerMode='FREE_TRIAL', numberOfPeriods=1, startDate=None, endDate=None),
                      'relationships': {'territory': asc.relationship('territories', 'USA')}}
        self.prices, self.offers = [self.price], [self.offer]
        self.apple.list = self.list
        self.apple.optional = lambda _: {'id': 'availability'}

    def list(self, path, **query):
        if path.endswith('/pricePoints'):
            return [self.point]
        if path.endswith('/equalizations'):
            return []
        if path.endswith('/prices'):
            return self.prices
        if path.endswith('/introductoryOffers'):
            return self.offers
        if path == '/v1/territories':
            return [mac.resource('territories', 'USA', currency='USD')]
        raise AssertionError(path)

    def test_existing_price_and_trial_are_valid_on_retry(self):
        self.store.prices_and_trial('monthly')
        self.assertEqual(self.apple.writes, [])

    def test_price_or_trial_drift_does_not_overwrite_existing_terms(self):
        for row, key, value in [(self.price['relationships']['subscriptionPricePoint']['data'], 'id', 'usd-399'),
                                (self.offer['attributes'], 'duration', 'ONE_MONTH'),
                                (self.offer['attributes'], 'endDate', '2099-01-01')]:
            previous = row[key]
            row[key] = value
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, 'differs'):
                self.store.prices_and_trial('monthly')
            row[key] = previous
        self.assertEqual(self.apple.writes, [])

    def test_scheduled_future_price_is_not_treated_as_current(self):
        self.price['attributes']['startDate'] = '2099-01-01'
        with self.assertRaisesRegex(RuntimeError, 'price differs'):
            self.store.prices_and_trial('monthly')
        self.assertEqual(self.apple.writes, [])

    def test_only_the_missing_introductory_offer_is_created(self):
        self.offers = []
        writes = []
        self.store.create = lambda kind, attrs, rels: writes.append((kind, attrs, rels))
        self.store.prices_and_trial('monthly')
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0][0], 'subscriptionIntroductoryOffers')
        self.assertEqual(writes[0][1], {'duration': 'TWO_WEEKS', 'offerMode': 'FREE_TRIAL', 'numberOfPeriods': 1})
        self.assertEqual(writes[0][2]['territory']['data']['id'], 'USA')


if __name__ == '__main__':
    unittest.main()
