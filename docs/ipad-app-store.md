# iPad App Store release

The iPad download is free. Creating and editing documents requires the monthly
`app.leftblank.writer.ipad.monthly` auto-renewable subscription. Eligible new
subscribers receive **two weeks free**, followed by **US $2.99/month** in the USA.
The app displays Apple's localized price and checks introductory-offer eligibility;
it never starts a local countdown or treats installing the app as a subscription.
Apple permits one introductory offer per subscription group. Mac remains free.
Expired subscriptions retain access to reading, PDF export and complete project
export, including source and assets.

The first iPad submission, **1.0.2 (3)**, entered **Waiting for Review** on
2026-10-04 at 00:21 Singapore time. Submission
`2ec7e9c7-b3f9-443c-b59c-304bb49509d3` includes the app, monthly subscription
and subscription group. Its immutable tag `ipad-v1.0.2` points to
`18a6de963dcf9c1c8a4769d2a201c409f7af0b54`, whose full main CI passed before tagging.
Release run `37135785704` signed and uploaded the IPA, and Apple processed it as
VALID. Storefront preparation then failed because the price query omitted
`include=appPricePoint`; the authorized first submission was completed in Chrome.
The corrected query below is for future releases; do not rerun or retag this
submitted binary to change that historical workflow result.

## Storefront preparation

`iPad/Storefront/manifest.json` is the business configuration; `en-US.json` and
`zh-Hans.json` provide final localized storefront copy. The initial iPad version is
`1.0.2 (3)` in `iPad/Info.plist`, independently versioned from Mac. The initial
`ipad-v1.0.0` attempt stopped before upload because its profile validator did not
accept Apple's iCloud entitlement allowlists; that tag remains immutable. Subsequent iPad
releases must increase the build number; Apple preflight checks previous iOS builds.

CI creates or reuses the iOS version in app **6818442294**, the **LeftBlank iPad**
subscription group, its monthly product and English/Chinese localizations. It
configures the USA $2.99 price and Apple's equalizations, plus a two-week free
trial without an end date in every supported territory. Existing conflicting
products, pricing, offers or unrelated review drafts stop the release.

Real 13-inch screenshots are committed in `iPad/Storefront/screenshots`, including
a subscription review screenshot and light/dark, English/Chinese views. CI uploads
and confirms screenshot processing. It preserves shared Mac App Info and verifies
the app download remains free. Review contacts are inherited from the latest configured Mac
version; if missing, set them on the iPad draft once. Shared privacy answers and
age rating must describe the final app. Accepting agreements and completing
banking or tax forms require the account owner.

The bilingual website privacy policy covers the iPad subscription, on-device
transaction checks and document access after expiry. `privacy-additions.md` records
the release's policy text. StoreKit's local configuration is not a production
product; the workflow creates production subscription metadata through Apple.

## Signed build

The workflow reuses the Mac Apple Distribution certificate and API key. It finds
a valid **IOS_APP_STORE** profile for that certificate and iOS App ID, or creates
one through Apple and verifies its production iCloud permissions. It never rotates
certificates or enables new capabilities. An existing base64 profile may be
provided as optional secret `IPAD_APPSTORE_PROVISIONING_PROFILE` if the existing
API key cannot manage profiles. The required existing secrets are
`APPSTORE_DISTRIBUTION_P12`, `APPSTORE_CERTIFICATE_PASSWORD`,
`APPSTORE_CONNECT_KEY_ID`, `APPSTORE_CONNECT_ISSUER_ID`, and
`APPSTORE_CONNECT_PRIVATE_KEY`; `APP_STORE_APP_ID` is the existing repository
variable. Signing materials use an ephemeral keychain and are cleaned up.

The 1024-pixel light and dark icons reuse the Mac designs as opaque RGB PNGs.
iPadOS 18 and later select the dark asset when the Home Screen icon appearance
is dark (including Automatic when the system is dark). Earlier systems use the
default light icon. Release validation rejects alpha channels and PNG transparency
before signing. Upload validation also checks
`altool` JSON errors, because its process can exit zero after Apple rejects a package.

Validate the preparation without credentials:

```sh
source scripts/environment.sh
python3 scripts/test-ipad-release.py
python3 scripts/ipad_release.py
```

After merging, wait until the required `build and test` check has succeeded on
the actual merged main commit. A successful PR check alone is not sufficient.
Only then push an immutable tag matching the iPad version; do not start a release
runner just to wait for CI:

```sh
git tag ipad-v1.0.2 <merged-main-commit>
git push origin ipad-v1.0.2
```

This automatically starts **iPad App Store release**, independently from Mac
`v*` tags. It waits for that exact source commit's required Mac/iPad CI gate,
validates metadata and archive boundaries, signs/exports the IPA, uploads it,
waits for Apple processing, prepares storefront/subscription metadata, and submits
the iOS version for review. Actions artifacts include the IPA, source provenance,
prepared-review details and verified submission state. The tag's draft GitHub
Release records iOS provenance before upload. Retrying the workflow on main with
the same tag discovers existing resources; never move a tag or force-push.

**First subscription:** Apple's current API documentation explicitly requires
submitting the first subscription with an app binary through the App Store
Connect website. CI prepares all supported metadata and saves
`build/iPad-release/review-prepared.json`, then reports that requirement instead
of claiming submission. Complete this one initial submission from the prepared
iPad version, including the monthly subscription and group metadata. After
approval, subsequent tags submit automatically. The agent performing this launch
can complete the initial website submission once the account is signed in.
Build processing and App Review submission are distinct from approval.

## Validation before review

Hosted CI measures executable iPad Swift/Core coverage and runs the native UI
suite on an 11-inch iPad in light mode and a 13-inch iPad in dark mode, hosted
unit/lifecycle tests, Address Sanitizer, Thread Sanitizer and Main
Thread Checker. Compiler concurrency checks and warnings are enforced. Rust FFI
formatting and Clippy checks supplement the embedded-engine integration test.
Xcode's Swift sanitizer instrumentation does not instrument the precompiled Rust
library. See `docs/coverage.md` for the coverage denominator and gate.

UI tests verify actual window bounds after rotation. On failure they also rotate
Apple Settings and capture Control Center and SpringBoard diagnostics, so an
accepted XCTest orientation request cannot conceal an unchanged app window.
Fresh hosted simulators complete first-boot migration and appearance setup, then
fully shut down and boot again before the measured suite. In run 37125166334,
SpringBoard crashed during first-boot setup; after its restart both LeftBlank and
Apple Settings stayed in portrait despite delivered landscape events. The full
boot separates that setup from testing; it is not an application-test retry.
Both device/appearance configurations require real rotation and passing tests.
The full suite gives Xcode at most ten minutes to start the first test, then
eighteen minutes to execute and finalize results. Only the first XCTest/Swift
Testing start marker changes the deadline; log chatter and later suites cannot
extend it. Startup duration is printed, and timeout failures identify the phase.
Run 37165225912 spent 8m39s before the first test and hit the previous combined
18-minute limit during its last UI case, after 95 tests had passed. Its session
log places 7m15s in test-host launch after installation; the precise underlying
Xcode/CoreSimulator delay is not established. The separate budgets prevent slow
host startup from consuming test execution time, while per-test timeouts,
failure propagation, process cleanup and result/coverage validation still apply.
The template cover and subscription sheet must hand off through `onDismiss`;
changing both presentation bindings at once can leave XCTest waiting for an
animation to finish. Purchase and expired-export scenarios run independently,
with the same per-test timeout and all content/entitlement assertions retained.

Test the StoreKit configuration in Xcode, then Apple's Sandbox/TestFlight product:
eligible two-week offer, ineligible returning subscriber, cancellation, pending
approval, verified renewal, expiration, restore, refunds/revocation, billing grace
and retry, and offline relaunch. Confirm expired users can export full source and
assets. StoreKit's local test configuration never travels inside an App Store app;
local purchases are not evidence that App Store Connect pricing is configured.
Also complete the real-device IME, accessibility, suspension and iCloud checks in
`docs/ipad.md`.

Apple references: [introductory offers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-introductory-offers-for-auto-renewable-subscriptions),
[first subscription review](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/),
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

Current API workflow: [subscription version review](https://developer.apple.com/documentation/appstoreconnectapi/submitting-subscriptions-and-subscription-groups-for-app-review).
