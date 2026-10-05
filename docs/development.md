# Developing LeftBlank

LeftBlank uses SwiftUI and AppKit for the app and editing experience, with Tinymist as a managed child process for Typst language services and preview. Documents use ordinary `.typ` source and relative assets. The visual approach was inspired by Nano Emacs.

Use Xcode 26 or later with a Swift 6.2 or later toolchain and the macOS SDK. The macOS MCP helper additionally requires Rust 1.92.0 (`rustup toolchain install 1.92.0 --profile minimal`). Local development scripts expect the external development volume at `/Volumes/SSD/Developer`; run from an SSD checkout:

```sh
scripts/build.sh release
scripts/test.sh
```

The build downloads Tinymist **0.15.8** (Typst 0.15.1), verifies its pinned SHA-256, and produces `build/LeftBlank.app` with an ad hoc development signature. Functional tests exercise the real native editor, workspace, windows, WebKit preview and Tinymist process: discovery, insertion, undo/redo, Unicode, recovery, multiple files, compilation errors and PDF output. Small boundary tests cover text ranges and index validation.

`scripts/test.sh` writes HTML, raw coverage data and `build/coverage/summary.md`. It requires **80% coverage of unique executable lines across production Swift sources**, including the interface. LCOV records are deduplicated by source file and line to avoid counting SwiftUI generic instantiations repeatedly. Plain `swift test` omits explicitly enabled integration scenarios and does not enforce coverage.

GitHub Actions uses `macos-15` with Xcode 26.3 for both pull requests and signed releases. The `build and test` check must pass on an up-to-date pull request before merging. It checks functional coverage (at least 80%), runs book benchmarks, and uploads reports. After all checks pass on main, CI builds, signs, notarizes and uploads LeftBlank Preview for testing, then publishes its signed automatic-update feed. Preview uses a separate local library and can coexist with LeftBlank. Swift package sources are cached; application binaries are rebuilt. [Codecov](https://app.codecov.io/github/leftblank-app/leftblank) reports project and patch coverage, including PR comments. A version tag matching `Info.plist` triggers testing and a release ZIP with SHA-256. Public releases require Developer ID signing, successful Apple notarization, ticket stapling and Gatekeeper validation. See [release signing](signing.md) and [Preview updates](preview-updates.md). Local builds remain development-signed.

The source is split into the launcher, testable native app and core document logic. Bundled third-party licenses are listed in `Resources/ThirdParty.txt`.

See [iPad development and validation](ipad.md) for the native iPad target and embedded engine.

## Scope and verification

LeftBlank remains a development preview. It has one active editing buffer, with the main compilation entry preserved when navigating into included files. It does not provide collaborative accounts, Vim emulation, arbitrary visual editing of typeset pages.

Unicode editing, marked-text protection, undo and saving have automated coverage. Complete third-party input-method and VoiceOver flows, and a physical Mac running macOS 14, still need manual verification. Real 1.4 MB SICP and 3.3 MB War and Peace fixtures exercise highlighting, typing, pointer placement and scrolling in [book benchmarks](large-document-performance.md). [Template and package discovery](discovery.md) includes a downloadable, editable SICP example; [the complete books and conversion scripts](../Examples/Books/README.md) are checked in with their own attribution and licenses. Verification evidence and remaining limitations live in [the progress record](progress.md).

## Design and engineering notes

- [MCP integration design and implementation status](mcp-design.md)
- [Product requirements](requirements.md)
- [Architecture](architecture.md)
- [Implementation and verification](progress.md)
- [Writing features](editor-evolution.md)
- [Interaction and performance](interaction.md)
- [Brand assets and favicons](../Brand/README.md)
- [Localization](localization.md)
- [Library and synchronization](library-and-sync.md)
- [Code notes](code-notes.md)
- [Merge evaluation](merge-evaluation.md)
