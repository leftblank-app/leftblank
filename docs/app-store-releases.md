# Tag-driven releases

One stable tag releases the same source commit to the Mac App Store and GitHub.
The App Store retains its free worldwide availability and publishes automatically
after Apple approves the version. Preview updates continue on their existing main
CI workflow; they do not submit to the App Store.

## Prepare the next release

From a worktree based on current main:

```sh
python3 scripts/release_metadata.py prepare 0.6.0
```

This changes `CFBundleShortVersionString` to `0.6.0`, increments `CFBundleVersion`
from 10 to 11, and creates `releases/0.6.0.md`. Finish both sections of that file:

```text
## en-US

- Describe the changes that matter to users.

## zh-Hans

- 用中文说明用户能感知到的改进。
```

Use plain text and bullet points, with 1–4000 characters per language. Placeholder
TODO text, missing translations, Markdown links and formatting are rejected.
This file is the release message: GitHub uses it as the Release body; Apple gets
each language's section as its localized “What's New.” GitHub's generated commit
list and the annotated tag message are not substituted for the user-facing copy.

Commit the version and message with the application changes, merge the PR, and
tag that exact main commit:

```sh
git fetch origin
git tag -a v0.6.0 origin/main -m 'LeftBlank 0.6.0'
git push origin v0.6.0
```

Do not run the example tag commands to republish the initial 0.5.0 while it is in
review. The next version should describe actual application changes.

## What CI does

1. Rejects tags other than `vMAJOR.MINOR.PATCH`, mismatched plist versions,
   non-integer build numbers, unfinished release messages, and commits outside main.
2. Runs release contract tests, strict Swift lint, integration tests and coverage.
3. Signs and notarizes the Developer ID download package using the existing pipeline.
4. Tests the App Store distribution with the pinned Tinymist engine shared by all
   Mac editions (macOS native TLS and the VFS fix). Cached engine binaries are keyed
   by the patches and build script.
5. Checks the App ID, other pending versions, and increasing App Store build number.
   Creates a draft GitHub Release with `appstore-source.json` before upload, binding
   the tag, version, build, commit and release message. A retry must match this record.
   Imports temporary signing identities, validates the production iCloud profile,
   signs the sandboxed app and helpers, and creates the signed installer.
6. Uploads through Apple's `altool`, waits up to 40 minutes for a valid eligible
   build, and checks its encryption declaration. An existing matching build is
   reused on retry only with matching CI provenance. Invalid, expired, internal-only
   or mismatched builds stop release. Pre-existing manual builds cannot be claimed.
7. Creates or reuses the App Store version, uses its inherited storefront assets,
   writes bilingual update notes, attaches the build, and submits a review containing
   only this app version. Confirms the submission state with a separate API read.
8. Publishes the GitHub ZIP, checksum and shared release message. Saves the App Store
   installer, source metadata and submission result as Actions artifacts for 14 days.

`Resources/Info.plist` is the version source for both app packages. Store build
numbers increase independently of the marketing version; never reset them to 1.
The exact tag, plist version, packaged version/build, and source commit are checked.
No workflow automatically bumps the source, moves a tag, or force-pushes.

The workflow does not accept new Apple contracts, change prices or regions, withdraw
another version, or submit unrelated review items. A new Apple requirement or missing
inherited storefront data fails with an actionable error for manual resolution.
Apple review approval remains Apple's decision; successful CI means submitted,
not necessarily available in the store.

## Retry a failed run

Prefer Actions → failed Release run → **Re-run failed jobs**. You can also manually
run the Release workflow on main with its `tag` input set to the existing tag. Leave
the input empty to verify only Developer ID packaging without uploading to Apple.
App Store jobs are serialized globally and are never canceled by a newer release.

An upload timeout can have an unknown outcome. Wait for Apple to make the build
visible, then retry the same unchanged tag. The workflow reuses a created version,
uploaded build, matching review draft or already-submitted version. It will not
overwrite a submitted version that has a different build or submit a draft with
different release notes. If Apple invalidates a binary, resolve the pending version
in App Store Connect, then prepare a new marketing version and build with a new
tag. Never replace the commit behind an existing tag.

A failed release may leave its GitHub Release as a draft. Keep its provenance
attachment for retries; the final publish job makes the draft public only after
App Store submission succeeds.

## GitHub configuration

The Mac App Store uses separate signing and API credentials from Developer ID:

| Setting | Purpose |
|---|---|
| Secret `APPSTORE_DISTRIBUTION_P12` | Base64 Apple Distribution certificate and private key |
| Secret `APPSTORE_INSTALLER_P12` | Base64 Mac Installer Distribution certificate and private key |
| Secret `APPSTORE_CERTIFICATE_PASSWORD` | Password shared by these two CI exports |
| Secret `APPSTORE_PROVISIONING_PROFILE` | Base64 current Mac App Store production iCloud profile |
| Secret `APPSTORE_CONNECT_PRIVATE_KEY` | App Manager Team API private key, never base64 |
| Secret `APPSTORE_CONNECT_KEY_ID` | ID of that App Manager key |
| Secret `APPSTORE_CONNECT_ISSUER_ID` | Apple team API issuer |
| Variable `APP_STORE_APP_ID` | `6818442294` |

The original `APP_STORE_CONNECT_*` Developer key remains for Developer ID
notarization. App Manager is required for submission; a Developer key can upload
but cannot submit. Apple Team keys cover every app in the account. The new key was
explicitly authorized for this repository's release automation.

On 2026-10-02, the store signing certificates and provisioning profile were
configured in repository secrets, along with App Manager key `43J8872G3A`
(`LeftBlank App Store CI`). The certificates expire in October 2027; renew their CI
exports and the profile before that date. The initial `0.5.0 (10)` release was
uploaded locally from `604972b` and submitted manually, then confirmed through
the same API client without mutation. The new CI submission path is covered by
offline service-contract tests; its first live end-to-end run will be the next
actual release tag.

References: [Apple review submissions](https://developer.apple.com/documentation/appstoreconnectapi/review-submissions),
[App Store Connect API roles](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/).
