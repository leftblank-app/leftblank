"""Validate iPad release metadata, production signing and archived app boundaries."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import struct
import time
import ipad_frameworks

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = 'app.leftblank.writer'
PRODUCT = BUNDLE + '.ipad.monthly'


def validate_icon(path):
    data = path.read_bytes()
    if (len(data) < 33 or data[:8] != b'\x89PNG\r\n\x1a\n'
            or data[12:16] != b'IHDR' or struct.unpack('>II', data[16:24]) != (1024, 1024)
            or data[24:26] != bytes([8, 2])):
        raise ValueError('iPad App Store icon must be a 1024x1024 RGB PNG without an alpha channel')
    offset = 8
    while offset + 12 <= len(data):
        length = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        if kind == b'tRNS':
            raise ValueError('iPad App Store icon must not contain PNG transparency')
        offset += length + 12
        if kind == b'IEND':
            return
    raise ValueError('Incomplete iPad App Store PNG icon')


def metadata(root):
    info = plistlib.loads((root / 'iPad/Info.plist').read_bytes())
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('iPad marketing version must be MAJOR.MINOR.PATCH')
    if not re.fullmatch(r'[1-9][0-9]{0,3}', build):
        raise ValueError('iPad build number must be an integer from 1 to 9999')
    if info.get('ITSAppUsesNonExemptEncryption') is not False:
        raise ValueError('Declare OS-native encryption in the iPad Info.plist')
    store = json.loads((root / 'iPad/Storefront/manifest.json').read_text())
    subscription = store['subscription']
    if (store['bundle_id'] != BUNDLE or store['platform'] != 'IOS' or store['download_price'] != '0.00'
            or subscription['product_id'] != PRODUCT or subscription['period'] != 'ONE_MONTH'
            or subscription['base_territory'] != 'USA' or subscription['base_price'] != '2.99'
            or subscription['currency'] != 'USD' or subscription['introductory_offer'] != {
                'mode': 'FREE_TRIAL', 'duration': 'TWO_WEEKS', 'number_of_periods': 1}):
        raise ValueError('iPad business model must be free download, two weeks trial, then US $2.99/month')
    configuration = json.loads((root / 'iPad/Storefront/LeftBlank.storekit').read_text())
    products = [product for group in configuration['subscriptionGroups'] for product in group['subscriptions']]
    if (len(products) != 1 or products[0]['productID'] != PRODUCT or products[0]['displayPrice'] != '2.99'
            or products[0]['recurringSubscriptionPeriod'] != 'P1M'
            or products[0]['introductoryOffer']['paymentMode'] != 'free'
            or products[0]['introductoryOffer']['subscriptionPeriod'] != 'P2W'
            or products[0]['introductoryOffer']['numberOfPeriods'] != 1):
        raise ValueError('StoreKit test configuration differs from the iPad subscription')
    locales = {}
    for locale in ('en-US', 'zh-Hans'):
        fields = json.loads((root / 'iPad/Storefront' / (locale + '.json')).read_text())
        for key, limit in [('name', 30), ('subtitle', 30), ('keywords', 100), ('promotional_text', 170), ('description', 4000)]:
            if not 1 <= len(fields[key]) <= limit or re.search(r'\bTODO\b', fields[key], re.IGNORECASE):
                raise ValueError(f'{locale}: invalid {key}')
        if any(store[key] not in fields['description'] for key in ('privacy_url', 'terms_url')):
            raise ValueError(f'{locale}: description must include privacy and terms URLs')
        locales[locale] = fields
    screenshots = store['screenshots']
    if set(screenshots) != set(locales) or any(not 1 <= len(names) <= 10 or len(set(names)) != len(names)
                                            for names in screenshots.values()):
        raise ValueError('Provide one to ten distinct screenshots for each storefront locale')
    screenshot_names = {name for names in screenshots.values() for name in names}
    for name in sorted(screenshot_names | {'subscription.png'}):
        path = root / 'iPad/Storefront/screenshots' / name
        if path.parent != root / 'iPad/Storefront/screenshots' or not path.is_file():
            raise ValueError('Missing or unsafe iPad screenshot: ' + name)
        data = path.read_bytes()
        if data[:8] != b'\x89PNG\r\n\x1a\n' or len(data) < 26:
            raise ValueError('Expected a real iPad PNG screenshot: ' + name)
        dimensions = struct.unpack('>II', data[16:24])
        if dimensions not in ((2048, 2732), (2732, 2048), (2064, 2752), (2752, 2064)):
            raise ValueError('Screenshot must match the 13-inch iPad slot: ' + name)
    icons = root / 'iPad/Assets.xcassets/AppIcon.appiconset'
    images = json.loads((icons / 'Contents.json').read_text())['images']
    appearances = [image.get('appearances', []) for image in images]
    if (len(images) != 2 or [] not in appearances
            or [{'appearance': 'luminosity', 'value': 'dark'}] not in appearances):
        raise ValueError('Provide both default light and dark iPad app icons')
    for image in images:
        path = icons / image['filename']
        if path.parent != icons:
            raise ValueError('Unsafe iPad app icon path')
        validate_icon(path)
    return {'platform': 'IOS', 'version': version, 'build': build, 'storefront': store, 'localizations': locales}


def validate_profile(profile, identity, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    allowed = profile['Entitlements']
    team = profile['TeamIdentifier'][0]
    if ('iOS' not in profile.get('Platform', []) or 'OSX' in profile.get('Platform', []) or profile.get('ProvisionedDevices')
            or profile.get('ProvisionsAllDevices') or allowed.get('get-task-allow')
            or profile['ExpirationDate'] <= now or allowed.get('application-identifier') != team + '.' + BUNDLE):
        raise ValueError('Expected a current App Store iOS distribution profile matching LeftBlank')
    certificates = [hashlib.sha1(cert).hexdigest().upper() for cert in profile['DeveloperCertificates']]
    if identity.upper() not in certificates:
        raise ValueError('The signing certificate is not included in the iPad profile')
    cloud = 'iCloud.' + BUNDLE
    for key in ('com.apple.developer.icloud-container-identifiers', 'com.apple.developer.ubiquity-container-identifiers'):
        if cloud not in allowed.get(key, []):
            raise ValueError('iPad profile must authorize ' + key)
    # A profile lists allowed entitlements, not the app's selected environment.
    # Apple's App Store profiles can allow both environments and wildcard services;
    # exportOptions still explicitly selects Production for the signed IPA.
    services = allowed.get('com.apple.developer.icloud-services', [])
    environments = allowed.get('com.apple.developer.icloud-container-environment', [])
    if isinstance(services, str):
        services = [services]
    if isinstance(environments, str):
        environments = [environments]
    if (not isinstance(services, list) or not {'CloudDocuments', '*'}.intersection(services)
            or not isinstance(environments, list) or 'Production' not in environments
            or allowed.get('com.apple.developer.ubiquity-kvstore-identifier') not in (team + '.' + BUNDLE, team + '.*')):
        raise ValueError('iPad profile must authorize production iCloud document storage')
    return team, profile['UUID']


def validate_archive(archive, expected):
    app = archive / 'Products/Applications/LeftBlank.app'
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    for key, value in [('CFBundleIdentifier', BUNDLE), ('CFBundleShortVersionString', expected['version']),
                       ('CFBundleVersion', expected['build']), ('UIDeviceFamily', [2]),
                       ('ITSAppUsesNonExemptEncryption', False), ('CFBundleSupportedPlatforms', ['iPhoneOS'])]:
        if info.get(key) != value:
            raise ValueError('Archive differs from iPad release: ' + key)
    for path in app.rglob('*'):
        # Shared icons and third-party attribution are resources, not desktop code.
        if ((path.is_dir() or path.suffix.lower() in ('', '.dylib', '.so', '.a'))
                and any(name in path.name.lower() for name in ('mcp', 'sparkle', 'automation'))):
            raise ValueError('iPad archive contains a desktop-only component: ' + path.name)
    if not (app / info['CFBundleExecutable']).is_file():
        raise ValueError('iPad archive is missing its executable')
    if not (app / 'Frameworks/LeftBlankCore.framework/LeftBlankCore').is_file():
        raise ValueError('iPad archive is missing its shared Core framework')
    ipad_frameworks.check_app(app)
    if any(app.rglob('*.storekit')) or any(app.rglob('*.xctest')):
        raise ValueError('iPad archive contains test-only StoreKit configuration or tests')
    return app


def validate_ci(checks):
    gates = [check for check in checks if check['name'] == 'build and test'
             and check.get('app', {}).get('slug') == 'github-actions']
    if not gates or max(gates, key=lambda check: check['id']).get('conclusion') != 'success':
        raise ValueError('The required Mac/iPad build and test gate has not passed for this source commit')


def wait_ci(commit, timeout):
    if timeout <= 0:
        raise ValueError('CI wait timeout must be positive')
    deadline = time.monotonic() + timeout
    print('Waiting for the required Mac/iPad gate for ' + commit, flush=True)
    while True:
        result = subprocess.check_output(['gh', 'api', '--paginate',
            f"repos/{os.environ['GH_REPO']}/commits/{commit}/check-runs?filter=latest&per_page=100",
            '--jq', '.check_runs[] | {id, name, conclusion, app: {slug: .app.slug}} | tojson'], text=True)
        checks = [json.loads(line) for line in result.splitlines() if line]
        gates = [c for c in checks if c['name'] == 'build and test' and c.get('app', {}).get('slug') == 'github-actions']
        latest = max(gates, key=lambda c: c['id']) if gates else None
        if latest and latest.get('conclusion') == 'success':
            validate_ci(checks)
            destination = ROOT / 'build/iPad-release/checks.jsonl'
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(result)
            return
        if latest and latest.get('conclusion'):
            raise ValueError('Required source CI failed: ' + latest['conclusion'])
        if time.monotonic() >= deadline:
            raise ValueError('Required source CI is still pending; rerun this immutable tag after CI completes')
        time.sleep(30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tag')
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--profile', type=Path)
    parser.add_argument('--identity')
    parser.add_argument('--checks-file', type=Path)
    parser.add_argument('--wait-for-ci', type=int)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/iPad-release/source.json')
    args = parser.parse_args()
    expected = metadata(ROOT)
    expected['commit'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if args.wait_for_ci:
        wait_ci(expected['commit'], args.wait_for_ci)
    if args.checks_file:
        validate_ci([json.loads(line) for line in args.checks_file.read_text().splitlines() if line])
    if args.tag:
        if args.tag != 'ipad-v' + expected['version']:
            parser.error('Use an immutable ipad-vMAJOR.MINOR.PATCH tag matching iPad/Info.plist')
        subprocess.run(['git', 'merge-base', '--is-ancestor', 'HEAD', 'origin/main'], cwd=ROOT, check=True)
        tagged = subprocess.check_output(['git', 'rev-parse', args.tag + '^{commit}'], cwd=ROOT, text=True).strip()
        if tagged != expected['commit']:
            parser.error('The checkout must match the requested iPad tag')
        expected['tag'] = args.tag
    if args.profile:
        if not args.identity:
            parser.error('--profile requires the signing identity SHA-1')
        profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(args.profile)]))
        team, identifier = validate_profile(profile, args.identity)
        print(f'Validated iPad production profile: {team}, {identifier}')
    if args.archive:
        app = validate_archive(args.archive, expected)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        linked = subprocess.check_output(['otool', '-L', str(app / 'LeftBlank')], text=True).lower()
        if any(name in linked for name in ('sparkle', 'mcp', 'automation')):
            raise ValueError('iPad executable links a desktop-only component')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(expected, ensure_ascii=False, indent=2) + '\n')
    print(f"Validated iPad {expected['version']} ({expected['build']}); source {expected['commit']}")


if __name__ == '__main__':
    main()
