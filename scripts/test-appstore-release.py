#!/usr/bin/env python3
"""Offline release contracts: wrong versions, partial retries and unrelated reviews."""
import base64
import copy
import json
import io
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import urllib.error
import urllib.parse
from unittest.mock import patch

import appstore_connect as asc
import release_metadata as meta


def resource(kind, identifier, **attrs):
    return {'type': kind, 'id': identifier, 'attributes': attrs}


class FakeApple:
    """Stateful fake service, independent of the release controller's decisions."""
    def __init__(self):
        self.version = None
        self.build = resource('builds', 'build-11', version='11', processingState='VALID', expired=False,
                              usesNonExemptEncryption=False, buildAudienceType='APP_STORE_ELIGIBLE')
        self.submission = None
        self.items = []
        self.attached = None
        self.locales = [resource('appStoreVersionLocalizations', locale, locale=locale) for locale in meta.LOCALES]
        self.writes = []
        self.other_versions = []
        self.review_detail = resource('appStoreReviewDetails', 'review', contactEmail='review@example.com', notes='Old notes')

    def list(self, path, **query):
        if path.endswith('/appStoreVersions'):
            return ([self.version] if self.version else []) + self.other_versions
        if path == '/v1/builds':
            if 'filter[version]' in query:
                return [self.build] if self.build else []
            return [resource('builds', 'old', version='10')]
        if path.endswith('/reviewSubmissions'):
            return [self.submission] if self.submission else []
        if path.endswith('/items'):
            return self.items
        if path.endswith('/appStoreVersionLocalizations'):
            return self.locales
        raise AssertionError(path)

    def request(self, method, path, payload=None):
        if method == 'GET':
            if path == '/v1/apps/app':
                return {'data': resource('apps', 'app', bundleId='app.leftblank.writer')}
            if path.endswith('/relationships/build'):
                return {'data': self.attached}
            if path.startswith('/v1/reviewSubmissions/'):
                return {'data': self.submission}
            if path.endswith('/appStoreReviewDetail'):
                return {'data': self.review_detail}
            raise AssertionError(path)
        self.writes.append((method, path, copy.deepcopy(payload)))
        if path == '/v1/appStoreVersions':
            self.version = resource('appStoreVersions', 'version', appVersionState='PREPARE_FOR_SUBMISSION',
                                    **payload['data']['attributes'])
            return {'data': self.version}
        if path.endswith('/relationships/build'):
            self.attached = payload['data']
        elif path == '/v1/reviewSubmissions':
            self.submission = resource('reviewSubmissions', 'submission', state='READY_FOR_REVIEW', platform='MAC_OS')
            return {'data': self.submission}
        elif path == '/v1/reviewSubmissionItems':
            self.items.append({**resource('reviewSubmissionItems', 'item', state='READY_FOR_REVIEW'),
                               'relationships': payload['data']['relationships']})
            self.version['attributes']['appVersionState'] = 'READY_FOR_REVIEW'
            return {'data': self.items[-1]}
        elif path == '/v1/reviewSubmissions/submission':
            self.submission['attributes']['state'] = 'WAITING_FOR_REVIEW'
            self.version['attributes']['appVersionState'] = 'WAITING_FOR_REVIEW'
        elif path == '/v1/appStoreVersions/version':
            self.version['attributes'].update(payload['data']['attributes'])
        elif path == '/v1/appStoreReviewDetails/review':
            self.review_detail['attributes'].update(payload['data']['attributes'])
        elif path.startswith('/v1/appStoreVersionLocalizations/'):
            next(item for item in self.locales if item['id'] == path.split('/')[-1])['attributes'].update(payload['data']['attributes'])
        else:
            raise AssertionError(path)
        return {}

    def optional(self, path):
        return self.request('GET', path)['data']

    def patch(self, kind, identifier, attributes):
        return self.request('PATCH', f'/v1/{kind}/{identifier}',
                            {'data': {'type': kind, 'id': identifier, 'attributes': attributes}})


class UploadTests(unittest.TestCase):
    def setUp(self):
        self.client = asc.Client(Path('key.p8'), 'key-id', 'issuer')

    def test_zero_exit_with_apple_validation_error_stops_upload(self):
        report = {'product-errors': [{'code': -19241, 'message': 'Invalid large app icon'}]}
        with patch.object(asc.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 0, stdout=json.dumps(report))):
            with self.assertRaisesRegex(RuntimeError, 'Invalid large app icon'):
                asc.upload_package(Path('app.ipa'), self.client)

    def test_successful_json_upload(self):
        with patch.object(asc.subprocess, 'run', return_value=subprocess.CompletedProcess(
                [], 0, stdout='{"product-errors": []}')) as run:
            asc.upload_package(Path('app.ipa'), self.client)
        self.assertTrue(run.call_args.kwargs['check'])

    def test_malformed_response_cannot_be_treated_as_success(self):
        for response in ('not json', '[]'):
            with self.subTest(response=response), patch.object(asc.subprocess, 'run',
                    return_value=subprocess.CompletedProcess([], 0, stdout=response)):
                with self.assertRaises((ValueError, RuntimeError)):
                    asc.upload_package(Path('app.ipa'), self.client)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.apple = FakeApple()
        self.metadata = {'version': '0.6.0', 'build': '11', 'notes': {'en-US': '- Faster editing.', 'zh-Hans': '- 编辑更流畅。'}}
        self.release = asc.Release(self.apple, 'app', self.metadata)

    def test_submit_and_repeated_run_make_one_submission(self):
        result = self.release.submit(self.release.wait_build(1))
        self.assertEqual(result['attributes']['state'], 'WAITING_FOR_REVIEW')
        self.assertEqual(self.apple.version['attributes']['releaseType'], 'AFTER_APPROVAL')
        self.assertEqual({l['id']: l['attributes']['whatsNew'] for l in self.apple.locales}, self.metadata['notes'])
        self.assertEqual(self.apple.review_detail['attributes']['notes'], asc.MAC_REVIEW_NOTES)
        self.assertEqual(self.apple.review_detail['attributes']['contactEmail'], 'review@example.com')
        writes = len(self.apple.writes)
        self.release.submit(self.apple.build)
        self.assertEqual(len(self.apple.writes), writes)

    def test_review_notes_say_the_ipad_subscription_is_not_in_the_mac_app(self):
        for phrase in ('no in-app purchases', 'app.leftblank.writer.ipad.monthly', 'only in the iPad app'):
            self.assertIn(phrase, asc.MAC_REVIEW_NOTES)
        self.assertLessEqual(len(asc.MAC_REVIEW_NOTES), 4000)

    def test_missing_review_contact_stops_before_submission(self):
        self.apple.review_detail = None
        with self.assertRaisesRegex(RuntimeError, 'App Review contact'):
            self.release.submit(self.release.wait_build(1))
        self.assertIsNone(self.apple.submission)

    def test_ready_draft_with_other_review_notes_is_not_submitted(self):
        self.release.submit(self.release.wait_build(1))
        self.apple.submission['attributes']['state'] = 'READY_FOR_REVIEW'
        self.apple.version['attributes']['appVersionState'] = 'READY_FOR_REVIEW'
        self.apple.review_detail['attributes']['notes'] = 'Edited by hand'
        writes = len(self.apple.writes)
        with self.assertRaisesRegex(RuntimeError, 'App Review notes'):
            self.release.submit(self.apple.build)
        self.assertEqual(len(self.apple.writes), writes)

    def test_retry_after_item_added_does_not_duplicate_it(self):
        real_patch = self.apple.patch
        def fail_submit(kind, identifier, attributes):
            if kind == 'reviewSubmissions':
                raise RuntimeError('connection lost before submission')
            return real_patch(kind, identifier, attributes)
        with patch.object(self.apple, 'patch', side_effect=fail_submit):
            with self.assertRaisesRegex(RuntimeError, 'connection lost'):
                self.release.submit(self.apple.build)
        self.release.submit(self.apple.build)
        self.assertEqual(len(self.apple.items), 1)
        self.assertEqual(sum(path == '/v1/reviewSubmissions' for _, path, _ in self.apple.writes), 1)

    def test_retry_after_version_created_reuses_version(self):
        real_patch = self.apple.patch
        with patch.object(self.apple, 'patch', side_effect=RuntimeError('interrupted metadata')):
            with self.assertRaises(RuntimeError):
                self.release.submit(self.apple.build)
        self.apple.patch = real_patch
        self.release.submit(self.apple.build)
        self.assertEqual(sum(path == '/v1/appStoreVersions' for _, path, _ in self.apple.writes), 1)

    def test_unrelated_pending_version_stops_before_any_write(self):
        self.apple.other_versions = [resource('appStoreVersions', 'other', versionString='0.5.0', appVersionState='WAITING_FOR_REVIEW')]
        with self.assertRaisesRegex(RuntimeError, 'Another version'):
            self.release.submit(self.apple.build)
        self.assertEqual(self.apple.writes, [])

    def test_unrelated_draft_is_not_submitted(self):
        self.apple.submission = resource('reviewSubmissions', 'submission', platform='MAC_OS', state='READY_FOR_REVIEW')
        self.apple.items = [{'attributes': {'state': 'READY_FOR_REVIEW'},
                             'relationships': {'appEvent': asc.relationship('appEvents', 'event'),
                                               'appStoreVersion': {'data': None}}}]
        with self.assertRaisesRegex(RuntimeError, 'unrelated'):
            self.release.submit(self.apple.build)
        self.assertFalse(any(path == '/v1/reviewSubmissions/submission' for _, path, _ in self.apple.writes))

    def test_submitted_wrong_build_stops(self):
        self.release.submit(self.apple.build)
        self.apple.attached = {'type': 'builds', 'id': 'different-build'}
        with self.assertRaisesRegex(RuntimeError, 'different build'):
            self.release.preflight()

    def test_old_build_number_stops(self):
        self.apple.build = None
        self.metadata['build'] = '10'
        with self.assertRaisesRegex(RuntimeError, 'Increase CFBundleVersion'):
            self.release.preflight()

    def test_failed_expired_internal_or_crypto_build_is_rejected(self):
        for attrs in [{'processingState': 'INVALID'}, {'expired': True},
                      {'buildAudienceType': 'INTERNAL_ONLY'}, {'usesNonExemptEncryption': True},
                      {'usesNonExemptEncryption': None}]:
            with self.subTest(attrs=attrs):
                original = copy.deepcopy(self.apple.build)
                self.apple.build['attributes'].update(attrs)
                with self.assertRaises(RuntimeError):
                    self.release.wait_build(1)
                self.apple.build = original

    def test_processing_timeout_never_submits(self):
        self.apple.build['attributes']['processingState'] = 'PROCESSING'
        with patch('appstore_connect.time.monotonic', side_effect=[0, 2]):
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                self.release.wait_build(1)
        self.assertEqual(self.apple.writes, [])

    def test_existing_manual_build_cannot_claim_ci_provenance(self):
        self.metadata.update(tag='v0.6.0', commit='commit')
        response = subprocess.CompletedProcess([], 1, '', 'release not found')
        with patch('appstore_connect.subprocess.run', return_value=response) as gh:
            with self.assertRaisesRegex(RuntimeError, 'without CI source provenance'):
                self.release.claim()
        self.assertEqual(gh.call_count, 1)

    def test_provenance_written_before_upload_and_checked_on_retry(self):
        self.metadata.update(tag='v0.6.0', commit='commit')
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            provenance = Path(directory) / 'appstore-source.json'
            provenance.write_text(json.dumps(self.metadata))
            response = subprocess.CompletedProcess([], 0, json.dumps({'isDraft': True, 'assets': [{'name': provenance.name}]}), '')
            def gh(*args, **kwargs):
                if args[0][2] == 'view':
                    return response
                destination = Path(args[0][-1]) / provenance.name
                destination.write_bytes(provenance.read_bytes())
                return subprocess.CompletedProcess([], 0)
            with patch('appstore_connect.subprocess.run', side_effect=gh) as commands:
                self.release.claim()
                self.assertEqual(commands.call_count, 2)
                self.metadata['commit'] = 'another-commit'
                with self.assertRaisesRegex(RuntimeError, 'different source commit'):
                    self.release.claim()

    def test_new_build_provenance_is_uploaded_before_any_apple_write(self):
        self.metadata.update(tag='v0.6.0', commit='commit')
        self.apple.build = None
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            original = Path.cwd()
            try:
                os.chdir(directory)
                Path('build').mkdir()
                response = subprocess.CompletedProcess([], 1, '', 'release not found')
                with patch('appstore_connect.subprocess.run', return_value=response) as commands:
                    self.release.claim()
                    self.assertEqual(commands.call_count, 3)
                self.assertEqual(json.loads(Path('build/appstore-source.json').read_text()), self.metadata)
                self.assertEqual(self.apple.writes, [])
            finally:
                os.chdir(original)


class HttpTests(unittest.TestCase):
    def test_filters_and_pagination(self):
        pages = [{'data': [{'id': 'first'}], 'links': {'next': asc.API + '/v1/builds?cursor=next'}},
                 {'data': [{'id': 'second'}], 'links': {}}]
        requests = []
        def respond(request, **kwargs):
            requests.append(request)
            return io.BytesIO(json.dumps(pages.pop(0)).encode())
        with patch('appstore_connect.jwt', return_value='test-token'), patch('appstore_connect.urllib.request.urlopen', side_effect=respond):
            client = asc.Client(Path('unused'), 'key', 'issuer')
            results = client.list('/v1/builds', **{'filter[version]': '11', 'filter[preReleaseVersion.version]': '0.6.0'})
        self.assertEqual([row['id'] for row in results], ['first', 'second'])
        query = urllib.parse.parse_qs(urllib.parse.urlparse(requests[0].full_url).query)
        self.assertEqual(query['filter[version]'], ['11'])
        self.assertEqual(query['filter[preReleaseVersion.version]'], ['0.6.0'])

    def test_mutation_errors_are_not_retried(self):
        error = urllib.error.HTTPError(asc.API + '/v1/reviewSubmissions', 503, 'Unavailable', {}, io.BytesIO(b'not JSON'))
        with patch('appstore_connect.jwt', return_value='test-token'), patch('appstore_connect.urllib.request.urlopen', side_effect=error) as request:
            with self.assertRaisesRegex(RuntimeError, 'HTTP 503'):
                asc.Client(Path('unused'), 'key', 'issuer').request('POST', '/v1/reviewSubmissions', {'data': {}})
        self.assertEqual(request.call_count, 1)

    def test_pagination_cannot_send_token_to_another_origin(self):
        client = asc.Client(Path('unused'), 'key', 'issuer')
        with self.assertRaises(ValueError):
            client.request('GET', 'https://unexpected.example/v1/builds')


class MetadataTests(unittest.TestCase):
    def test_tag_version_notes_and_placeholders(self):
        notes = '## en-US\n\n- Faster.\n\n## zh-Hans\n\n- 更快。\n'
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            root = Path(directory)
            (root / 'Resources').mkdir()
            (root / 'releases').mkdir()
            (root / 'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.6.0', 'CFBundleVersion': '11'}))
            path = root / 'releases/0.6.0.md'
            path.write_text(notes)
            self.assertEqual(meta.metadata(root, 'v0.6.0')['build'], '11')
            for tag in ['v0.5.0', 'v0.6.0-beta', '0.6.0', 'v00.6.0']:
                with self.assertRaises(ValueError):
                    meta.metadata(root, tag)
            for invalid in [notes.replace('Faster', 'TODO'), notes.replace('Faster', 'x' * 4001),
                            notes.replace('## zh-Hans', '## fr-FR'), notes.replace('- Faster.', ''),
                            notes.replace('Faster.', '[Read](https://example.com)')]:
                path.write_text(invalid)
                with self.assertRaises(ValueError):
                    meta.metadata(root, 'v0.6.0')

    def test_real_es256_token_signature_is_verified_by_openssl(self):
        with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
            root = Path(directory)
            key, public = root / 'key.pem', root / 'public.pem'
            subprocess.run(['openssl', 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', str(key)], check=True, capture_output=True)
            subprocess.run(['openssl', 'pkey', '-in', str(key), '-pubout', '-out', str(public)], check=True, capture_output=True)
            token = asc.jwt(key, 'test-key', 'test-issuer')
            header, payload, signature = token.split('.')
            self.assertEqual(json.loads(base64.urlsafe_b64decode(header + '=='))['alg'], 'ES256')
            claims = json.loads(base64.urlsafe_b64decode(payload + '=='))
            self.assertEqual(claims['aud'], 'appstoreconnect-v1')
            self.assertLessEqual(claims['exp'] - claims['iat'], 1200)
            raw = base64.urlsafe_b64decode(signature + '==')
            integers = []
            for part in [raw[:32], raw[32:]]:
                part = part.lstrip(b'\0') or b'\0'
                if part[0] & 128:
                    part = b'\0' + part
                integers.append(b'\x02' + bytes([len(part)]) + part)
            body = b''.join(integers)
            sig = root / 'signature.der'
            sig.write_bytes(b'\x30' + bytes([len(body)]) + body)
            result = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public), '-signature', str(sig)],
                                    input=(header + '.' + payload).encode(), capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())


if __name__ == '__main__':
    unittest.main()
