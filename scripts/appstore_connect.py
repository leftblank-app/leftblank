"""Upload tagged Apple builds; submit Mac versions after validating provenance."""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = 'https://api.appstoreconnect.apple.com'
SUBMITTED = {'WAITING_FOR_REVIEW', 'IN_REVIEW', 'ACCEPTED', 'PENDING_APPLE_RELEASE',
             'PROCESSING_FOR_DISTRIBUTION', 'READY_FOR_DISTRIBUTION', 'PENDING_DEVELOPER_RELEASE',
             'PROCESSING_FOR_APP_STORE', 'READY_FOR_SALE', 'PENDING_CONTRACT'}
EDITABLE = {'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED', 'METADATA_REJECTED', 'INVALID_BINARY'}
# Mac and iPad share one app record, so App Review sees the iPad subscription on
# Mac submissions too and asks where to buy it (2.1(b), Mac 1.0 review).
MAC_REVIEW_NOTES = (
    'The Mac app is free and has no in-app purchases. The auto-renewable subscription '
    'in this app record (app.leftblank.writer.ipad.monthly) is offered only in the iPad '
    'app; the Mac app never offers, sells or checks it. No login is required. Rendering '
    'runs locally. Additional Typst packages are downloaded over HTTPS.')


class APIError(RuntimeError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def encode(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


def jwt(key, key_id, issuer):
    now = int(time.time())
    header = encode(json.dumps({'alg': 'ES256', 'kid': key_id, 'typ': 'JWT'}).encode())
    payload = encode(json.dumps({'iss': issuer, 'iat': now - 10, 'exp': now + 600, 'aud': 'appstoreconnect-v1'}).encode())
    message = (header + '.' + payload).encode()
    signature = subprocess.check_output(['openssl', 'dgst', '-sha256', '-sign', str(key)], input=message)
    # OpenSSL returns ASN.1 DER, while ES256 JWT requires two fixed-width integers.
    if len(signature) > 127 or signature[:1] != b'\x30' or signature[1] != len(signature) - 2:
        raise ValueError('Expected a P-256 DER signature')
    offset, parts = 2, []
    for _ in range(2):
        if signature[offset] != 2:
            raise ValueError('Expected an ECDSA integer')
        size = signature[offset + 1]
        integer = signature[offset + 2:offset + 2 + size].lstrip(b'\x00')
        if not 1 <= len(integer) <= 32:
            raise ValueError('API key must use P-256')
        parts.append(integer.rjust(32, b'\x00'))
        offset += size + 2
    if offset != len(signature):
        raise ValueError('Unexpected ECDSA signature data')
    return message.decode() + '.' + encode(b''.join(parts))


class Client:
    def __init__(self, key, key_id, issuer):
        self.key, self.key_id, self.issuer = key, key_id, issuer

    def request(self, method, path, payload=None):
        url = path if path.startswith(API + '/') else API + path
        if not any(url.startswith(API + prefix) for prefix in ('/v1/', '/v2/', '/v3/')):
            raise ValueError('Unexpected API pagination origin')
        headers = {'Authorization': 'Bearer ' + jwt(self.key, self.key_id, self.issuer),
                   'Content-Type': 'application/json'}
        request = urllib.request.Request(url, method=method, headers=headers,
                                         data=None if payload is None else json.dumps(payload).encode())
        # Never automatically retry mutations with an unknown outcome. A workflow
        # rerun discovers the existing version, build, draft and submission first.
        for attempt in range(5):
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    body = response.read()
                    return json.loads(body) if body else {}
            except urllib.error.HTTPError as error:
                if method == 'GET' and error.code in (429, 500, 502, 503, 504) and attempt < 4:
                    time.sleep(min(2 ** attempt, 15))
                    continue
                try:
                    body = json.loads(error.read())
                except json.JSONDecodeError:
                    body = {}
                details = '; '.join(item.get('detail', item.get('title', 'API error')) for item in body.get('errors', []))
                raise APIError(error.code, f'Apple API {method} {path.split("?")[0]}: HTTP {error.code}: {details}') from None

    def optional(self, path):
        try:
            return self.request('GET', path).get('data')
        except APIError as error:
            if error.status == 404:
                return None
            raise

    def list(self, path, **query):
        next_page = path + ('?' + urllib.parse.urlencode(query) if query else '')
        result = []
        while next_page:
            page = self.request('GET', next_page)
            result.extend(page['data'])
            next_page = page.get('links', {}).get('next')
        return result

    def patch(self, kind, identifier, attributes, api_version='v1'):
        return self.request('PATCH', f'/{api_version}/{kind}/{identifier}',
                            {'data': {'type': kind, 'id': identifier, 'attributes': attributes}})


def relationship(kind, identifier):
    return {'data': {'type': kind, 'id': identifier}}


def state(version):
    attrs = version['attributes']
    return attrs.get('appVersionState') or attrs.get('state') or attrs.get('appStoreState')


class Release:
    def __init__(self, client, app, metadata, platform='MAC_OS'):
        if platform not in ('MAC_OS', 'IOS'):
            raise ValueError('Unsupported App Store platform')
        self.client, self.app, self.metadata = client, app, metadata
        self.platform = platform

    def versions(self):
        return self.client.list(f'/v1/apps/{self.app}/appStoreVersions', **{'filter[platform]': self.platform, 'limit': 200})

    def current(self):
        versions = self.versions()
        matching = [v for v in versions if v['attributes']['versionString'] == self.metadata['version']]
        if len(matching) > 1:
            raise RuntimeError('Apple returned more than one matching version')
        return matching[0] if matching else None

    def preflight(self):
        app = self.client.request('GET', f'/v1/apps/{self.app}')['data']
        if app['attributes']['bundleId'] != 'app.leftblank.writer':
            raise RuntimeError('APP_STORE_APP_ID does not identify LeftBlank')
        versions = self.versions()
        current = next((v for v in versions if v['attributes']['versionString'] == self.metadata['version']), None)
        if current:
            current_state = state(current)
            if current_state not in EDITABLE | SUBMITTED | {'READY_FOR_REVIEW'}:
                raise RuntimeError(f'Version needs manual attention: {current_state}')
            if current_state in SUBMITTED:
                attached = self.client.request('GET', f"/v1/appStoreVersions/{current['id']}/relationships/build").get('data')
                build = self.build()
                if not build or not attached or attached['id'] != build['id']:
                    raise RuntimeError('Already submitted version uses a different build; refusing to replace it')
                print(f'Already submitted: {self.metadata["version"]} ({self.metadata["build"]}), {current_state}')
                return False
        # No automatic withdrawal, replacement, or submission of unrelated drafts.
        for other in versions:
            if other == current:
                continue
            if state(other) in EDITABLE | {'READY_FOR_REVIEW', 'WAITING_FOR_REVIEW', 'IN_REVIEW', 'WAITING_FOR_EXPORT_COMPLIANCE'}:
                raise RuntimeError(f"Another version is pending: {other['attributes']['versionString']} ({state(other)})")
        if not self.build():
            builds = self.client.list('/v1/builds', **{'filter[app]': self.app,
                                      'filter[preReleaseVersion.platform]': self.platform, 'limit': 200})
            numbers = [int(b['attributes']['version']) for b in builds if b['attributes']['version'].isdigit()]
            if numbers and int(self.metadata['build']) <= max(numbers):
                raise RuntimeError('Increase CFBundleVersion above every previous App Store build')
        return True

    def build(self):
        matches = self.client.list('/v1/builds', **{'filter[app]': self.app,
                                   'filter[version]': self.metadata['build'],
                                   'filter[preReleaseVersion.version]': self.metadata['version'],
                                   'filter[preReleaseVersion.platform]': self.platform, 'limit': 200})
        if len(matches) > 1:
            raise RuntimeError('Ambiguous Apple build')
        return matches[0] if matches else None

    def wait_build(self, timeout):
        deadline, previous = time.monotonic() + timeout, None
        while True:
            build = self.build()
            processing = build['attributes']['processingState'] if build else 'NOT_VISIBLE'
            if processing != previous:
                print('Apple build processing: ' + processing, flush=True)
                previous = processing
            if processing in ('FAILED', 'INVALID'):
                raise RuntimeError('Apple rejected the uploaded build; inspect App Store Connect before retrying')
            if processing == 'VALID':
                attrs = build['attributes']
                if attrs.get('expired') or attrs.get('buildAudienceType') != 'APP_STORE_ELIGIBLE':
                    raise RuntimeError('Build is not eligible for App Store distribution')
                if attrs.get('usesNonExemptEncryption') is not False:
                    raise RuntimeError('Encryption declaration does not match the OS-native TLS build')
                return build
            if time.monotonic() >= deadline:
                raise RuntimeError('Apple processing timed out; rerun the same tag after processing completes')
            time.sleep(min(30, max(0, deadline - time.monotonic())))

    def claim(self):
        """Persist source provenance before upload, so a retry cannot reuse another commit's build."""
        tag = self.metadata['tag']
        view = subprocess.run(['gh', 'release', 'view', tag, '--json', 'assets,isDraft'], capture_output=True, text=True)
        if view.returncode:
            if 'release not found' not in view.stderr.lower():
                raise RuntimeError('Cannot inspect the GitHub release for source provenance')
            release = None
        else:
            release = json.loads(view.stdout)
        asset = 'appstore-source.json' if self.platform == 'MAC_OS' else 'appstore-source-ios.json'
        if release and any(item['name'] == asset for item in release['assets']):
            with tempfile.TemporaryDirectory(dir=os.environ['TMPDIR']) as directory:
                subprocess.run(['gh', 'release', 'download', tag, '--pattern', asset, '--dir', directory], check=True)
                previous = json.loads((Path(directory) / asset).read_text())
            if previous != self.metadata:
                raise RuntimeError('This tag/build was claimed by a different source commit or release message')
            return
        if self.build():
            raise RuntimeError('An Apple build already exists without CI source provenance; do not reuse its number')
        if release and not release['isDraft']:
            raise RuntimeError('Published GitHub release has no CI provenance; use a new release tag')
        if not release:
            notes = ['--notes-file', 'build/release-metadata.md'] if self.platform == 'MAC_OS' else [
                '--notes', 'iPad App Store build provenance. Initial app and subscription review is submitted together in App Store Connect.']
            subprocess.run(['gh', 'release', 'create', tag, '--verify-tag', '--draft',
                            '--title', 'LeftBlank ' + tag, *notes], check=True)
        path = Path('build') / asset
        path.write_text(json.dumps(self.metadata, ensure_ascii=False, indent=2) + '\n')
        subprocess.run(['gh', 'release', 'upload', tag, str(path)], check=True)

    def submit(self, build):
        if self.platform == 'IOS':
            from ipad_storefront import Storefront
            return Storefront(self).submit(build)
        if not self.preflight():
            return self.current()
        version = self.current()
        if not version:
            version = self.client.request('POST', '/v1/appStoreVersions', {'data': {
                'type': 'appStoreVersions', 'attributes': {'platform': 'MAC_OS',
                'versionString': self.metadata['version'], 'releaseType': 'AFTER_APPROVAL'},
                'relationships': {'app': relationship('apps', self.app)}}})['data']
        identifier = version['id']
        submissions = self.client.list(f'/v1/apps/{self.app}/reviewSubmissions',
                                       **{'filter[platform]': 'MAC_OS', 'limit': 200})
        draft = None
        for submission in submissions:
            submission_state = submission['attributes']['state']
            if submission_state == 'COMPLETE':
                continue
            items = self.client.list(f"/v1/reviewSubmissions/{submission['id']}/items", include='appStoreVersion')
            items = [item for item in items if item.get('attributes', {}).get('state') != 'REMOVED']
            if submission_state != 'READY_FOR_REVIEW' or any(
                    (item.get('relationships', {}).get('appStoreVersion', {}).get('data') or {}).get('id') != identifier
                    for item in items):
                raise RuntimeError('An unrelated or unresolved review submission exists; handle it in App Store Connect')
            if draft:
                raise RuntimeError('Multiple review drafts need manual attention')
            draft = (submission, items)
        if state(version) in EDITABLE:
            localizations = self.client.list(f'/v1/appStoreVersions/{identifier}/appStoreVersionLocalizations')
            by_locale = {item['attributes']['locale']: item for item in localizations}
            if not all(locale in by_locale for locale in self.metadata['notes']):
                raise RuntimeError('Expected inherited English and Chinese storefront metadata; set up missing locales first')
            for locale, notes in self.metadata['notes'].items():
                self.client.patch('appStoreVersionLocalizations', by_locale[locale]['id'], {'whatsNew': notes})
            self.client.patch('appStoreVersions', identifier, {'releaseType': 'AFTER_APPROVAL'})
            self.client.request('PATCH', f'/v1/appStoreVersions/{identifier}/relationships/build', relationship('builds', build['id']))
            # Apple copies the review contact from the previous version; only the notes are ours.
            details = self.client.optional(f'/v1/appStoreVersions/{identifier}/appStoreReviewDetail')
            if not details:
                raise RuntimeError('Set App Review contact information on the Mac version first')
            if details['attributes'].get('notes') != MAC_REVIEW_NOTES:
                self.client.patch('appStoreReviewDetails', details['id'], {'notes': MAC_REVIEW_NOTES})
        else:
            attached = self.client.request('GET', f'/v1/appStoreVersions/{identifier}/relationships/build').get('data')
            if not attached or attached['id'] != build['id']:
                raise RuntimeError('Ready-for-review draft uses a different build')
            locales = self.client.list(f'/v1/appStoreVersions/{identifier}/appStoreVersionLocalizations')
            actual_notes = {item['attributes']['locale']: item['attributes'].get('whatsNew') for item in locales}
            if any(actual_notes.get(locale) != notes for locale, notes in self.metadata['notes'].items()):
                raise RuntimeError('Ready-for-review draft has different release notes')
            details = self.client.optional(f'/v1/appStoreVersions/{identifier}/appStoreReviewDetail')
            if not details or details['attributes'].get('notes') != MAC_REVIEW_NOTES:
                raise RuntimeError('Ready-for-review draft has different App Review notes')
        if not draft:
            submission = self.client.request('POST', '/v1/reviewSubmissions', {'data': {
                'type': 'reviewSubmissions', 'attributes': {'platform': 'MAC_OS'},
                'relationships': {'app': relationship('apps', self.app)}}})['data']
            draft = (submission, [])
        submission, items = draft
        if not items:
            self.client.request('POST', '/v1/reviewSubmissionItems', {'data': {'type': 'reviewSubmissionItems',
                'relationships': {'reviewSubmission': relationship('reviewSubmissions', submission['id']),
                                  'appStoreVersion': relationship('appStoreVersions', identifier)}}})
        self.client.patch('reviewSubmissions', submission['id'], {'submitted': True})
        # Confirm the final state; a successful PATCH alone is not submission proof.
        deadline = time.monotonic() + 120
        while True:
            result = self.client.request('GET', f"/v1/reviewSubmissions/{submission['id']}")['data']
            if result['attributes']['state'] in ('WAITING_FOR_REVIEW', 'IN_REVIEW', 'COMPLETE', 'COMPLETING'):
                print('App Store submission: ' + result['attributes']['state'])
                return result
            if time.monotonic() >= deadline:
                raise RuntimeError('Submission state not confirmed; rerun to discover the actual outcome')
            time.sleep(10)


def upload_package(package, client):
    result = subprocess.run(['xcrun', 'altool', '--upload-package', str(package),
        '--api-key', client.key_id, '--api-issuer', client.issuer,
        '--p8-file-path', str(client.key), '--output-format', 'json'],
        check=True, text=True, stdout=subprocess.PIPE)
    # altool can exit zero while its JSON reports an upload validation failure.
    report = json.loads(result.stdout)
    if not isinstance(report, dict):
        raise RuntimeError('Unexpected altool upload response; verify Apple before retrying')
    errors = report.get('product-errors')
    if errors:
        raise RuntimeError('Apple rejected package upload: ' + json.dumps(errors))
    print('Apple package upload completed; waiting for build processing', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['preflight', 'claim', 'upload', 'submit', 'status', 'profile', 'prepare'])
    parser.add_argument('--metadata', type=Path, default=Path('build/release-metadata.json'))
    parser.add_argument('--key', type=Path, required=True)
    parser.add_argument('--package', type=Path, default=Path('build/LeftBlank-AppStore.pkg'))
    parser.add_argument('--platform', choices=['MAC_OS', 'IOS'], default='MAC_OS')
    parser.add_argument('--identity', help='SHA-1 of the existing Apple Distribution certificate')
    parser.add_argument('--profile-output', type=Path)
    parser.add_argument('--timeout', type=int, default=2400)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error('--timeout must be positive')
    client = Client(args.key, os.environ['APP_STORE_CONNECT_KEY_ID'], os.environ['APP_STORE_CONNECT_ISSUER_ID'])
    release = Release(client, os.environ['APP_STORE_APP_ID'], json.loads(args.metadata.read_text()), args.platform)
    if args.command == 'profile':
        if args.platform != 'IOS' or not args.identity or not args.profile_output:
            parser.error('profile requires IOS, --identity and --profile-output')
        from ipad_storefront import Storefront
        Storefront(release).profile(args.identity, args.profile_output)
        return
    if args.command == 'status':
        version, build = release.current(), release.build()
        print(json.dumps({'versionState': state(version) if version else None,
                          'buildState': build['attributes']['processingState'] if build else None}))
        return
    proceed = release.preflight()
    if args.command == 'claim':
        release.claim()
        return
    if not proceed:
        if args.command == 'submit':
            Path('build/appstore-submission.json').write_text(json.dumps(release.current(), indent=2) + '\n')
        return
    if args.command == 'preflight':
        print('App Store preflight passed')
        return
    if args.command == 'upload':
        if not release.build():
            upload_package(args.package, client)
        else:
            print('Reusing the uploaded build for this immutable tag')
        release.wait_build(args.timeout)
        return
    if args.command == 'prepare':
        if args.platform != 'IOS':
            parser.error('prepare is supported for IOS')
        from ipad_storefront import Storefront
        result = Storefront(release).prepare(release.wait_build(args.timeout))
    else:
        result = release.submit(release.wait_build(args.timeout))
    Path('build/appstore-submission.json').write_text(json.dumps(result, indent=2) + '\n')


if __name__ == '__main__':
    main()
