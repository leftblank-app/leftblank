#!/bin/bash
# A public release must be Developer ID signed and accepted by Apple's notary service.
set -euo pipefail
set +x
cd "$(dirname "$0")/.."
source scripts/environment.sh
distribution=${LEFTBLANK_DISTRIBUTION:-direct}
required=(SIGNING_CERTIFICATE_P12 SIGNING_CERTIFICATE_PASSWORD APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_PRIVATE_KEY APPLE_TEAM_ID)
if [ "$distribution" = preview ]; then
  required+=(LEFTBLANK_BUILD_NUMBER SPARKLE_PRIVATE_KEY ICLOUD_PREVIEW_PROVISIONING_PROFILE)
elif [ "$distribution" = direct ]; then
  required+=(ICLOUD_PROVISIONING_PROFILE)
else
  echo 'Developer ID releases support direct and preview only.' >&2; exit 1
fi
for variable in "${required[@]}"; do
  if [ -z "${!variable:-}" ]; then echo "Missing release credential: $variable" >&2; exit 1; fi
done
test "$(uname -m)" = arm64 || { echo 'Public releases support Apple Silicon only.' >&2; exit 1; }
umask 077
signing_dir=$(mktemp -d "$TMPDIR/leftblank-signing.XXXXXX")
keychain="$signing_dir/signing.keychain-db"
security list-keychains -d user > "$signing_dir/keychains.txt"
set_keychain_search_list() {
  python3 - "$signing_dir/keychains.txt" "$@" <<'PY'
import pathlib, shlex, subprocess, sys
original = shlex.split(pathlib.Path(sys.argv[1]).read_text())
subprocess.run(["security", "list-keychains", "-d", "user", "-s", *sys.argv[2:], *original], check=True)
PY
}
cleanup() {
  set_keychain_search_list >/dev/null 2>&1 || true
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$signing_dir"
}
trap cleanup EXIT
keychain_password=$(openssl rand -base64 32)
python3 - "$signing_dir" <<'PY'
import base64, os, pathlib, sys
folder = pathlib.Path(sys.argv[1])
(folder / "certificate.p12").write_bytes(base64.b64decode(os.environ["SIGNING_CERTIFICATE_P12"], validate=True))
(folder / "notary.p8").write_text(os.environ["APP_STORE_CONNECT_PRIVATE_KEY"])
profile_key = "ICLOUD_PREVIEW_PROVISIONING_PROFILE" if os.environ.get("LEFTBLANK_DISTRIBUTION") == "preview" else "ICLOUD_PROVISIONING_PROFILE"
(folder / "icloud.provisionprofile").write_bytes(base64.b64decode(os.environ[profile_key], validate=True))
PY
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
curl --fail --silent --show-error --location --proto '=https' \
  https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer -o "$signing_dir/DeveloperIDG2CA.cer"
printf '%s  %s\n' f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a "$signing_dir/DeveloperIDG2CA.cer" | shasum -a 256 -c -
security import "$signing_dir/DeveloperIDG2CA.cer" -k "$keychain" >/dev/null
security import "$signing_dir/certificate.p12" -k "$keychain" -P "$SIGNING_CERTIFICATE_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$keychain_password" "$keychain" >/dev/null
# codesign also needs the identity and intermediate certificates in its search list.
set_keychain_search_list "$keychain"
unset SIGNING_CERTIFICATE_P12 SIGNING_CERTIFICATE_PASSWORD APP_STORE_CONNECT_PRIVATE_KEY ICLOUD_PROVISIONING_PROFILE ICLOUD_PREVIEW_PROVISIONING_PROFILE
identities=$(security find-identity -v -p codesigning "$keychain" | awk '/"Developer ID Application:/ {print $2}')
test "$(printf '%s\n' "$identities" | awk 'NF {n++} END {print n+0}')" = 1 || { echo 'Expected exactly one valid Developer ID Application identity.' >&2; exit 1; }
scripts/build.sh release
app=build/LeftBlank.app
entitlements=""
bundle_id=app.leftblank.writer
if [ "$distribution" = preview ]; then
  app="build/LeftBlank Preview.app"
  bundle_id=app.leftblank.writer.preview
fi
python3 scripts/prepare-icloud-profile.py --app "$bundle_id" --profile "$signing_dir/icloud.provisionprofile" --team "$APPLE_TEAM_ID" --identity "$identities" --output "$signing_dir/icloud.entitlements"
cp "$signing_dir/icloud.provisionprofile" "$app/Contents/embedded.provisionprofile"
entitlements="$signing_dir/icloud.entitlements"
scripts/sign-app.sh "$app" "$identities" "$keychain" "$entitlements"
codesign -d --entitlements :- "$app" > "$signing_dir/signed-entitlements.plist" 2>/dev/null
python3 - "$signing_dir" <<'PYVERIFY'
import pathlib, plistlib, sys
root = pathlib.Path(sys.argv[1])
expected = plistlib.loads((root / "icloud.entitlements").read_bytes())
actual = plistlib.loads((root / "signed-entitlements.plist").read_bytes())
if any(actual.get(key) != value for key, value in expected.items()):
    raise SystemExit("Signed app is missing required iCloud entitlements.")
PYVERIFY
actual_team=$(codesign -d --verbose=4 "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')
test "$actual_team" = "$APPLE_TEAM_ID" || { echo 'Signing certificate team does not match APPLE_TEAM_ID.' >&2; exit 1; }
python3 - <<'PYCLEAN'
from pathlib import Path
import shutil
for path in (Path('build/notarization'), Path('build/release')):
    if path.exists(): shutil.rmtree(path)
    path.mkdir(parents=True)
PYCLEAN
ditto -c -k --sequesterRsrc --keepParent "$app" "$signing_dir/submission.zip"
notary_status=0
xcrun notarytool submit "$signing_dir/submission.zip" --key "$signing_dir/notary.p8" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait --timeout 30m --output-format json > build/notarization/result.json || notary_status=$?
if [ "$notary_status" -ne 0 ]; then
  echo 'Apple notarization did not complete successfully; no release archive will be published.' >&2
  exit "$notary_status"
fi
python3 - <<'PY'
import json
from pathlib import Path
result = json.loads(Path("build/notarization/result.json").read_text())
if result.get("status") != "Accepted":
    raise SystemExit("Apple notarization status: " + str(result.get("status", "unknown")))
print("Apple notarization accepted: " + result["id"])
PY
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
archive="LeftBlank-${version}-macOS-arm64.zip"
if [ "$distribution" = preview ]; then
  archive="LeftBlank-Preview-${version}-${LEFTBLANK_BUILD_NUMBER}-macOS-arm64.zip"
fi
ditto -c -k --sequesterRsrc --keepParent "$app" "build/release/$archive"
(cd build/release && shasum -a 256 "$archive" > "$archive.sha256")
if [ "$distribution" = preview ]; then
  python3 scripts/preview-feed.py "build/release/$archive" "$LEFTBLANK_BUILD_NUMBER" "${LEFTBLANK_PREVIEW_CHANNEL:-nightly}"
fi
echo "Signed, notarized and stapled: build/release/$archive"
