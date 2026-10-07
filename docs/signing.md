# Developer ID signing and automated releases

LeftBlank distributes a macOS arm64 app ZIP directly, outside the Mac App Store, using a **Developer ID Application** identity. The app and bundled helpers use hardened runtime and secure timestamps. Apple notarization, ticket stapling and Gatekeeper validation must succeed before the public release ZIP is produced.

## One-time setup

Signing in to Xcode locally does not give a GitHub runner signing credentials. The repository requires:

| GitHub setting | Value |
|---|---|
| Secret `SIGNING_CERTIFICATE_P12` | Base64-encoded `.p12` containing the Developer ID Application private key |
| Secret `SIGNING_CERTIFICATE_PASSWORD` | Password used to export the `.p12` |
| Secret `APP_STORE_CONNECT_PRIVATE_KEY` | Dedicated App Store Connect Team API `.p8` private key |
| Secret `APP_STORE_CONNECT_KEY_ID` | API key ID |
| Secret `APP_STORE_CONNECT_ISSUER_ID` | Team API issuer ID |
| Variable `APPLE_TEAM_ID` | The certificate's developer team ID |
| Secret `ICLOUD_PROVISIONING_PROFILE` | Base64 Developer ID profile for `app.leftblank.writer` authorizing the shared iCloud container and KVS |
| Secret `ICLOUD_PREVIEW_PROVISIONING_PROFILE` | Base64 Developer ID profile for `app.leftblank.writer.preview` authorizing the same container and KVS |

Create the certificate through Xcode → Settings → Apple Accounts → team → Manage Certificates → Developer ID Application. Create the API key under App Store Connect → Users and Access → Integrations, with the least privilege needed for notarization. The private key can be downloaded once; store it in a password manager or protected file, never an issue, PR or chat.

Supply secrets to `gh secret set --repo leftblank-app/leftblank NAME` through stdin rather than expanding values in command arguments or logs. Certificates and private keys do not belong in source or build artifacts.

The previous Sumi testing identity and profile were configured on 2026-10-01. On 2026-10-02, the `app.leftblank.writer` App ID and dedicated `iCloud.app.leftblank.writer` container were registered and associated, and the **LeftBlank Developer ID iCloud** profile was generated with the existing Developer ID certificate. The downloaded profile passed local validation and replaced `ICLOUD_PROVISIONING_PROFILE` in the repository on 2026-10-02. `prepare-icloud-profile.py` checks team, App ID, certificate membership, expiration, distribution scope and required capabilities, then emits only the required entitlements. The release embeds the profile and verifies the signed entitlements. Helper processes do not receive iCloud entitlements. Local development builds remain ad hoc and cannot use iCloud. LeftBlank Preview requires its own Developer ID profile for `app.leftblank.writer.preview`, with the same production container and KVS. The release never substitutes the standard App ID profile or publishes a Preview without iCloud entitlements.

The Preview profile and GitHub secret were configured on 2026-10-06; see
[Preview iCloud setup](preview-updates.md#icloud-sync). A signed release run and
native account/two-Mac verification remain the end-to-end sync checks. The prior
notarization result below predates this capability.

## Verification and publication

Stable tags now also build, upload and submit the Mac App Store release. Follow
[Tag-driven releases](app-store-releases.md) to bump the versions, write the shared
bilingual release message and retry a partial release. An empty-tag manual run
continues to verify only Developer ID packaging.

1. PR CI runs functional tests, coverage, large-book benchmarks and distribution-isolation checks without release credentials. After successful main CI, a separate job creates a Developer ID signed and notarized LeftBlank Preview package, uploads it for seven days, and publishes its signed update feed. See [Preview updates](preview-updates.md).
2. A manual Release workflow on main verifies signing and notarization and saves an artifact without creating a public Release.
3. Run `release_metadata.py prepare` and finish the bilingual release message, then merge the verified commit into main.
4. Push a matching version tag, such as `v0.6.0`. The workflow checks that main contains the tagged commit, runs functional tests and the 80% coverage gate, then signs, notarizes, staples and publishes.

Missing credentials, invalid certificates, team mismatch, rejected notarization or timeout stop public publication. There is no fallback to development signing. The temporary signing keychain joins the search list so codesign can locate the identity and chain. Cleanup restores the old list and removes the temporary keychain, certificate and API key. Notarization submission results remain available for investigation; private keys are never uploaded as artifacts.

Development builds use `scripts/build.sh release`. Set `LEFTBLANK_DISTRIBUTION=preview` to package `build/LeftBlank Preview.app`; `LEFTBLANK_BUILD_NUMBER` must be an increasing `run_number.run_attempt` for published builds. `scripts/release.sh` requires the settings above. Local temporary release material stays on the external SSD.

## Completed verification

On 2026-10-01, before the LeftBlank rename, all release credentials were configured for `fenjin-ai/sumi`, and [a manual release run](https://github.com/leftblank-app/leftblank/actions/runs/36824914236) passed on commit `72f7d8e`, app version **0.2.0**, build **3**. This generated an Actions artifact only, without a public tag or Release.

- 36 functional and integration tests passed; production coverage was 88.57%, above the 80% gate.
- The arm64 app and Tinymist helper were signed by `Developer ID Application: Fenjin Wang (X6BK42MX95)` with hardened runtime and secure timestamps. The certificate expires on 2031-09-17.
- Apple submission `ae76e6c3-2354-4259-8e60-7e6411c5271c` returned `Accepted`, and its ticket was stapled.
- An independently downloaded final ZIP passed SHA-256, `codesign --verify --deep --strict`, `stapler validate` and Gatekeeper (`source=Notarized Developer ID`). The signed Tinymist helper ran successfully.

That run's `release-macos-15` artifact contains `Sumi-0.2.0-macOS-arm64.zip` and its `.sha256`. Actions artifacts expire after seven days; tagged public Releases use persistent downloadable attachments. This historical validation does not claim that every later development build is notarized.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [App Store Connect API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api), [GitHub signing setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).


## Mac App Store

Build and export from the repository root on an SSD-backed checkout:

```sh
export TMPDIR=/Volumes/SSD/Developer/Codex/tmp
export TMP="$TMPDIR"
export TEMP="$TMPDIR"
LEFTBLANK_DISTRIBUTION=appstore scripts/build.sh release
python3 scripts/export-appstore.py \
  --profile /absolute/path/LeftBlank.provisionprofile \
  --identity DISTRIBUTION_CERTIFICATE_SHA1 \
  --installer-identity INSTALLER_CERTIFICATE_SHA1 \
  --keychain /absolute/path/signing.keychain-db
```

Use an Apple Distribution certificate and a Mac Installer Distribution certificate.
The export validates the current Mac App Store profile, app identifier, distribution
certificate and iCloud permissions before embedding the profile. The app gets
sandbox and production iCloud entitlements; its helper executables inherit the
sandbox. Signing materials stay outside the repository. If codesign cannot find
the intermediate certificate in a dedicated keychain, install Apple's WWDR G3
intermediate in the user's login keychain without changing its trust settings.

The default installer is `build/LeftBlank-AppStore.pkg`. Validate and upload it
with Xcode's `altool` and an existing App Store Connect API key. Pass an explicit
SSD `TMPDIR` or `-CDTempDir` to keep upload chunks on the external disk. Never put
API private keys or keychain passwords in source control or command output.

The initial 0.5.0 (9) installer passed Apple's validation on 2026-10-02 and
processed as a valid, App Store eligible build. Its ad-hoc sandbox cold-launch
check also verified bundled resources, document-library creation and Tinymist
connection. App Store approval and actual cloud account behavior remain separate
from these checks.


Every Mac edition bundles Tinymist 0.15.8 built at pinned commit
`32f908199ee17ea295512bbc27166e890c438175` with the checked-in native TLS
patch and lockfile changes, plus the VFS revision fix shared with iPad. Reqwest
then uses macOS Security Framework instead of Rust TLS. The source checkout,
Cargo cache and target directory live under `.tools/tinymist-mac-source`; Rust
1.92.0 is required. The GitHub download and Preview editions use the same
binary: nothing in them requires Rust TLS, and system trust settings apply to
package downloads in every edition.

The native TLS engine compiled all fourteen marketing documents, downloaded
CeTZ and its dependencies into an empty isolated package cache, and passed the
sandbox cold-launch smoke check. App Store packaging declares exempt OS
provided encryption; this declaration must be revisited if a dependency adds
another encryption implementation.
