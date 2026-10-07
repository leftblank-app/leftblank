# Developing LeftBlank

LeftBlank uses SwiftUI and AppKit for the app and editing experience, with Tinymist as a managed child process for Typst language services and preview. Documents use ordinary `.typ` source and relative assets. The visual approach was inspired by Nano Emacs.

Use Xcode 26 or later with a Swift 6.2 or later toolchain and the macOS SDK. The Tinymist and macOS MCP helpers, and the typst-syntax parser linked into LeftBlankCore, are built with Rust 1.92.0 (`rustup toolchain install 1.92.0 --profile minimal`). `scripts/build.sh` and `scripts/test.sh` build the parser through `scripts/bootstrap.sh`; run `scripts/build-syntax.sh` once before a plain `swift build` or `swift test`. Local development scripts expect the external development volume at `/Volumes/SSD/Developer`; run from an SSD checkout:

```sh
scripts/build.sh release
scripts/test.sh
```

The build compiles Tinymist **0.15.8** (Typst 0.15.1) from its pinned commit with `scripts/tinymist-native-tls.patch` and `scripts/tinymist-vfs.patch` (`scripts/build-tinymist.sh`), and produces `build/LeftBlank.app` with an ad hoc development signature. The first build takes about 15 minutes; `.tools/tinymist.stamp` records the revision, toolchain and patch hashes, so later builds reuse the binary until a patch changes. CI caches the binary under the same inputs, and `scripts/test-tinymist-build.py` checks that the binary in use matches them. Functional tests exercise the real native editor, workspace, windows, WebKit preview and Tinymist process: discovery, insertion, undo/redo, Unicode, recovery, multiple files, compilation errors and PDF output. Small boundary tests cover text ranges and index validation.

`scripts/test.sh` writes HTML, raw coverage data and `build/coverage/summary.md`. It requires **80% coverage of unique executable lines across production Swift sources**, including the interface. LCOV records are deduplicated by source file and line to avoid counting SwiftUI generic instantiations repeatedly. Plain `swift test` omits explicitly enabled integration scenarios and does not enforce coverage.

GitHub Actions uses `macos-15` with Xcode 26.3 for both pull requests and signed releases. The `build and test` check must pass on an up-to-date pull request before merging. It checks functional coverage (at least 80%), runs book benchmarks, and uploads reports. Each night, after Mac validation passes on main, CI builds, signs, notarizes and uploads LeftBlank Preview for testing, then publishes its signed automatic-update feed; a manual run can publish between nightlies. Preview uses a separate local library and can coexist with LeftBlank. Swift package sources are cached; application binaries are rebuilt. [Codecov](https://app.codecov.io/github/leftblank-app/leftblank) reports project and patch coverage, including PR comments. A version tag matching `Info.plist` triggers testing and a release ZIP with SHA-256. Public releases require Developer ID signing, successful Apple notarization, ticket stapling and Gatekeeper validation. See [release signing](signing.md) and [Preview updates](preview-updates.md). Local builds remain development-signed.

The source is split into the launcher, testable native app and core document logic. Bundled third-party licenses are listed in `Resources/ThirdParty.txt`.

See [iPad development and validation](ipad.md) for the native iPad target and embedded engine.

### CI capacity policy

The organization has about five concurrent macOS runners, so `build and test` (`.github/workflows/ci.yml`) runs only what each change needs:

- **Path selection.** A small ubuntu `Select jobs` job runs `scripts/ci_changes.py`, which classifies every changed path as Mac, iPad, shared or documentation. Mac-only changes (`Sources/LeftBlank`, `Tests/LeftBlankAppTests`, `Tools/MCPServer`, Mac packaging scripts and bundle metadata) skip the iPad jobs. iPad-only changes (`iPad/`, `Engine/TinymistBridge`, iPad scripts) skip Mac regression, and the iPad engine job lints the repository instead. Shared code (`Sources/LeftBlankCore`, `Engine/SyntaxBridge`, both `Package.swift` manifests, `Tests/LeftBlankCoreTests`, shared resources and scripts, `.github/`) and any unlisted path run both. Documentation-only changes run no macOS job. Pull requests diff against their base; main pushes diff against the last successful main run, so changes from a cancelled or failed run stay selected. Classify new scripts in `scripts/ci_changes.py`; `scripts/test-ci-policy.py` fails until you do.
- **Pull requests and main pushes** run exactly the same path-selected checks: Mac regression and the iPad smoke suite. A newer push cancels the in-progress run for the same pull request or for main. Main pushes no longer run Mac App Store validation, Mac memory safety or Preview publication.
- **Nightly** at 18:00 UTC (02:00 Beijing), the schedule runs every job on main: the full iPad suite (both UI sizes, iPad sanitizers and the 80% iPad coverage gate), Mac App Store validation and Mac memory safety. It then signs and publishes LeftBlank Preview once Mac regression and App Store validation pass. An iPad failure does not hold back Preview, but it fails `build and test` for the nightly run and is reported there. The nightly skips only when the same commit already had a fully successful nightly, so a failed nightly (tests or publication) runs again the next night even if main has not changed. A full-suite iPad regression can therefore reach main and be reported up to a day later.
- **Manual runs.** Run **build and test** (`workflow_dispatch`) to check a commit sooner. It runs every job at the `ipad_suite` depth (default `full`), adding App Store and memory checks on main. To upgrade Preview between nightlies, run it on main with `publish_preview` checked (`gh workflow run ci.yml --ref main -f publish_preview=true`). That runs only the Mac checks, then signs and publishes, skipping the iPad suite.
- **Publication is never cancelled.** Only nightly and manual runs publish, and they use non-cancelling concurrency groups; `Publish preview update` also serializes in its own `preview-publish` group.
- **Gate.** `build and test` is the only required check. It fails unless every selected job passed and every other job was skipped, so a filtered skip passes but a failed, cancelled or wrongly skipped job does not. `scripts/test-ci-policy.py` checks this policy, the path table and the workflow structure in the `Select jobs` job.

## Scope and verification

LeftBlank remains a development preview. It has one active editing buffer, with the main compilation entry preserved when navigating into included files. It does not provide collaborative accounts, Vim emulation, arbitrary visual editing of typeset pages. Source-level visual editing is planned in [visual editing](visual-editing.md).

Unicode editing, marked-text protection, undo and saving have automated coverage. Complete third-party input-method and VoiceOver flows, and a physical Mac running macOS 14, still need manual verification. Real 1.4 MB SICP and 3.3 MB War and Peace fixtures exercise highlighting, typing, pointer placement and scrolling in [book benchmarks](large-document-performance.md). [Template and package discovery](discovery.md) includes a downloadable, editable SICP example; [the complete books and conversion scripts](../Examples/Books/README.md) are checked in with their own attribution and licenses. Verification evidence and remaining limitations live in [the progress record](progress.md).

## Design and engineering notes

- [MCP integration design and implementation status](mcp-design.md)
- [Product requirements](requirements.md)
- [Architecture](architecture.md)
- [Implementation and verification](progress.md)
- [Writing features](editor-evolution.md)
- [Visual editing plan and parser bridge (LB-019)](visual-editing.md)
- [Interaction and performance](interaction.md)
- [Brand assets and favicons](../Brand/README.md)
- [Localization](localization.md)
- [Library and synchronization](library-and-sync.md)
- [Code notes](code-notes.md)
- [Merge evaluation](merge-evaluation.md)
