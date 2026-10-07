# Preview updates

LeftBlank Preview (留白预览版) is the main-branch testing channel. It can coexist with
LeftBlank, including the future App Store edition. The marketing version changes with
releases; the build number identifies each CI build. About LeftBlank Preview also
shows the source commit.

## Local state and app identities

| | LeftBlank | LeftBlank Preview |
| --- | --- | --- |
| Bundle identifier and preferences domain | `app.leftblank.writer` | `app.leftblank.writer.preview` |
| Application Support directory | `LeftBlank` | `LeftBlank Preview` |
| iCloud | On by default when available | On by default when available |

Each directory contains its own library, history, recovery copies, exports,
and logs. When sync is enabled, both editions use the shared
iCloud library and writing preferences. Turn sync off to keep an independent local
library.
Opening an external file deliberately still edits that file. `LEFTBLANK_STATE_DIR`
remains an explicit development and test override.

## Update experience

Only a build made with `LEFTBLANK_DISTRIBUTION=preview` resolves and links Sparkle.
Direct and App Store builds have no Sparkle dependency, update menu or feed.
The App Store handles its own updates.

Preview uses Sparkle 2's native update flow:

- The first launch leaves automatic checking disabled. Sparkle asks permission
  on the second launch; Settings → General also lets users change this preference.
- Automatic checks follow Sparkle's daily schedule. Check for Updates can be
  invoked manually at any time; an in-progress check disables that menu item.
- Sparkle schedules background reminders around idle time and application
  activation, rather than interrupting typing. The app does not run its own
  polling timer or check on every keystroke.
- Every installation requires an explicit user choice. Automatic downloading
  and installation are disabled by `SUAllowsAutomaticUpdates=false`.
- Update installation terminates through the normal AppKit application delegate.
  The editor finishes input composition, saves the document/recovery copy and
  drains queued history writes. Failure to preserve writing cancels termination.
  The delegate is used even when a previously prepared update is resumed, where
  Sparkle's optional postpone-relaunch callback would not be reliable.
- The appcast and archives are public HTTPS resources. Ed25519 update signatures
  are checked before extraction, and archives contain signed, notarized apps.
  No analytics or system-profile collection is enabled.

The package script supplies `SUFeedURL`, `SUPublicEDKey`, `LeftBlankCommit` and the
internal build number. Signing and publishing credentials are CI secrets; no
private key belongs in the app or repository. A feed always points to an
immutable versioned archive, preserving the bytes covered by its signature.

References: [Sparkle setup](https://sparkle-project.org/documentation/programmatic-setup/),
[configuration](https://sparkle-project.org/documentation/customization/),
[gentle reminders](https://sparkle-project.org/documentation/gentle-reminders/),
[relaunch delegate limitations](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html).

## CI publication

`build and test` remains on macOS 15 with Xcode 26.3. PRs do not package a
Release app. The full functional suite runs with Preview enabled; a second,
focused App Store configuration check confirms the binary does not link
Sparkle. Tests also exercise real archive/feed signatures and reject tampering.

Preview publishes from the nightly `build and test` run on main (18:00 UTC), or
on demand from a manual main run with `publish_preview` checked
(`gh workflow run ci.yml --ref main -f publish_preview=true`), which runs only
the Mac checks. Main pushes do not publish. Once Mac regression and Mac App
Store validation pass, a signed-preview job starts; iPad failures do not block
it. Nightly and manual runs never cancel each other or get cancelled by pushes,
so signing and publication always finish. The signed-preview job
compiles Release once, signs nested Sparkle helpers and the app, notarizes,
staples, checks Gatekeeper and cold-launches the relocated package. Only then
is the ZIP available as a seven-day Actions artifact and an immutable GitHub
prerelease `preview-<run number>.<attempt>`. A failed nightly publication is
retried by the next nightly, or immediately by a `publish_preview` run. The marketing version does not change.

`preview-latest` is a fixed tag used only to host `appcast.xml`. Its tag is never
moved or force-pushed. The signed feed points at an immutable build release,
so a downloaded archive cannot silently change. Publication is serialized and
compares build numbers to prevent a late old run from downgrading the feed.
A failed check, notarization or cold launch leaves the previous update intact.
Versioned release archives remain available for manual rollback; the updater
will not automatically downgrade. Document-format migrations must preserve
backward compatibility or snapshot data before migration.

The updater uses `SPARKLE_PRIVATE_KEY`, an Ed25519 seed generated by
Sparkle's official tool. Its matching public key is committed in
`Resources/Preview-Info.plist`. CI passes the private key through stdin to the
signer and independently verifies the archive against the app's public key.
The private key is never part of an artifact. The signed feed requires Sparkle
2.9 or later; Preview pins 2.10.0.

To check a local development package:

```sh
source scripts/environment.sh
LEFTBLANK_DISTRIBUTION=preview scripts/build.sh release
python3 scripts/test-preview-release.py
```

Local development packages are ad hoc signed. Download a published Preview to
verify the complete Developer ID, Gatekeeper and installation path. App Store
configuration checks cover updater exclusion, not App Store submission readiness.

## Verify an installed update

Use a published, signed Preview and a disposable library for upgrade testing.
After choosing **Install and Relaunch**, let Sparkle finish without invoking an
automation API that opens or activates the app. Some UI inspection APIs launch
the target if it is not running. Calling one while Sparkle replaces the bundle
can start the old executable before it is moved away, leaving a running process
whose executable no longer exists. Authorization services and accessibility can
then fail even though the replacement bundle on disk is valid.

Observe the process table without activating the app. Wait for the old PID and
this app's Sparkle installer to exit and for a new app PID to appear. Do not
terminate another app's Sparkle helpers. Check that new PID before reconnecting
the UI tool:

```sh
python3 scripts/running_app.py --app '/path/to/LeftBlank Preview.app' \
  --pid NEW_PID --expected-build EXPECTED_BUILD
```

This check reads the kernel's executable path and rejects a removed or relocated
live executable. Reading `CFBundleVersion` from disk alone is insufficient.
Then verify **About LeftBlank Preview**, **Check for Updates** (up to date), and saved
writing. Cold-launch CI also verifies the process path, while a regression test
replaces a bundle underneath a disposable process and confirms rejection.
These checks complement, but do not replace, an interactive upgrade test.

If a real installation is left in this state, cancel the update dialog, quit
normally so writing is saved, and reopen the installed app. Do not force-kill the
editor, erase update preferences, or weaken signature verification.

## iCloud sync

Preview and standard builds use the same iCloud document container and writing
preferences. Local state remains separate. Sync is attempted
by default on startup unless the user has turned it off. An unavailable account
or an unprovisioned build keeps local writing available and retries on a later launch.

For signed previews, register `app.leftblank.writer.preview` with iCloud Documents,
associate `iCloud.app.leftblank.writer`, and authorize the shared KVS identifier
`<AppIdentifierPrefix>.app.leftblank.writer`. Generate a Developer ID provisioning
profile for the preview App ID and signing certificate. Store its base64 contents
in the GitHub secret `ICLOUD_PREVIEW_PROVISIONING_PROFILE`. The release workflow
validates and embeds that profile and verifies the signed entitlements. This
secret is required: a missing or mismatched profile stops publication instead
of shipping a Preview with iCloud disabled.

On 2026-10-06, `app.leftblank.writer.preview` was registered and associated with
the existing LeftBlank Documents container. **LeftBlank Preview Developer ID
iCloud** uses the existing Developer ID certificate; its profile passed the
release validator for the Preview identity and shared KVS, and was stored in
`ICLOUD_PREVIEW_PROVISIONING_PROFILE`.
