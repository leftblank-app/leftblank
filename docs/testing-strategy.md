# Testing LeftBlank as a writing application

LeftBlank's primary automated checks are feature integration tests, with an 80% production source-line coverage gate. Coverage is a useful floor; it cannot establish that a menu looks right or that a person can complete a workflow.

## Running today

Run `scripts/test.sh` from an SSD checkout. It exercises the real AppKit editor, SwiftUI hosting views, document storage, undo, Tinymist compilation and WebKit preview. Tests use isolated document directories and injected cloud stores, never a personal iCloud account. After main Mac validation succeeds, a separate job builds and notarizes LeftBlank Preview, validates its Developer ID signature and cold-launches a relocated copy with the build-directory resource bundle hidden. Pull requests run the functional suite, coverage gate and book benchmarks without the release build or app upload, keeping review feedback faster. Successful main builds automatically upload a runnable Preview app for seven days and publish its signed update feed. PRs cannot access release credentials. Tagged stable releases retain their separate signing and notarization workflow. Main runs a separate App Store distribution check before Preview packaging to keep the external updater out of the App Store binary. PRs skip that distribution rebuild. The launch check uses a fresh library and verifies Chinese starter content plus a ready Tinymist service. Its isolated logs are retained as artifacts. All native UI scenarios share one serialized suite because AppKit menus, field editors and sheet presentation are process-wide. Codecov publishes project and changed-line coverage on each PR.

For build-system-specific resource failures, the native SwiftPM builder can be reproduced separately on toolchains that still support it:

```sh
source scripts/environment.sh
swift test --build-system native --scratch-path .build/native-validation \
  --filter bundledLanguagesResolveWithoutChangingSystemSettings
```

Keep the scratch path inside the SSD checkout. The hosted CI toolchain is deliberately older than the development machine, so local success is not a substitute for its result.

## Main-only memory checks

The `Memory safety` jobs run on main pushes and manual main runs, never on pull
requests. They run independently of preview packaging and preserve diagnostics
in `build/memory` for 14 days. Existing functional and book-performance PR gates
remain enabled.

- **Lifecycle and leaks:** after one AppKit/SwiftUI warm-up window, open, edit,
  undo/redo and close ten more windows. Weak references must release each
  Workspace, native editor and window within ten seconds. The test captures its
  own process with Apple's `leaks`, before and after the ten cycles; CI checks
  the final graph with `--diffFrom` to detect newly leaked allocations. This
  avoids gating on existing framework startup leaks. Missing graphs, failed
  tests and newly detected leaks fail the job. Logs and both `.memgraph` files
  are retained for inspection in Instruments. Allocation stacks are enabled.
- **Address Sanitizer:** run the core Swift Testing suite with
  `swift test --sanitize address` in a separate scratch directory. This detects
  invalid memory accesses such as use-after-free and buffer overruns;
  [Apple explicitly notes that ASan does not detect leaks](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early).
  Native SwiftPM avoids the sanitizer/filter runner issue in the pinned Xcode
  26.3 toolchain. Sanitizer results are never used as performance baselines.

These checks deliberately use isolated local documents and do not start
Tinymist in the lifecycle scenario. They do not establish leak freedom in
Tinymist, WebKit child processes, real iCloud sessions or all user workflows.
Weak checks also catch objects retained from live roots that a heap leak scan
can consider reachable. The warm-up graph is a per-run reference, not a saved
performance baseline, and leaks already present at warm-up are outside the
differential gate.

Run from an SSD checkout with `scripts/check-memory.sh leaks` or
`scripts/check-memory.sh address`. Normal local/PR tests skip the lifecycle
scenario unless explicitly enabled by the script.

For further performance work, Apple's
[XCTest memory metrics](https://developer.apple.com/documentation/xcode/preventing-memory-use-regressions)
are appropriate when an Xcode UI-test target exists. The mature
[ordo-one Benchmark package](https://github.com/ordo-one/benchmark) supports
allocation/ARC/CPU metrics and baseline comparisons for focused SwiftPM
benchmarks. Neither is added yet: current book tests already cover native
interaction wall/CPU timings, and an end-of-run footprint is not a peak-memory
or leak measurement. Release benchmarks and whole-process-tree memory budgets
need separate representative workloads and measured runner baselines.

## iPad safety checks

Pull requests run the native iPad unit suite and a few curated UI smoke
scenarios on both simulator sizes. Main (and full manual dispatches) run the
complete UI suite on both sizes, the separate 80% application coverage gate,
and two sanitizer jobs. The native suite checks ownership release after
repeated workspace/editor/engine lifecycles; full runs also require its XCTest
memory metrics, retained in the result bundle. Address Sanitizer and Thread
Sanitizer each compile separate Swift test products and run the hosted unit
suite in parallel with UI testing; these tools are mutually exclusive. The compiler treats warnings as
errors, applies complete Swift concurrency checking, and enables actor runtime
checks. The normal scheme retains Main Thread Checker. A successful process
exit with zero executed tests, failed tests, or recorded runtime safety warnings
fails validation. Simulator discovery, test execution, diagnostics and shutdown
are bounded, and timeouts kill the test runner's process group.

The Rust bridge also runs formatting and Clippy checks with warnings and unsafe
operations inside unsafe functions treated as errors, followed by real engine
integration. The Swift/Xcode sanitizers do **not** instrument the precompiled
Rust engine or WebKit child processes. Weak ownership assertions detect retained
objects; XCTest memory metrics record footprint but do not establish whole-heap
leak freedom or a peak-memory regression budget without a measured baseline.
The Mac differential `leaks` check remains separate. Undefined Behavior
Sanitizer is omitted because Apple's tool supports C-family languages, not
Swift or this prebuilt Rust library. See
[Apple's sanitizer scope](https://developer.apple.com/documentation/xcode/diagnosing-memory-thread-and-crash-issues-early).

All required iPad build, native test, coverage and memory jobs feed the final
`build and test` gate. Native `.xcresult` and memory diagnostics remain available
as Actions artifacts for 14 days. Device compilation continues independently
to catch simulator-only assumptions; actual device performance and App Store
StoreKit delivery still require release acceptance on hardware.

## Dependency maintenance

Actions are pinned to full commit SHAs with readable version comments, so a
moved release tag cannot silently change the code CI runs. Dependabot keeps
those pins and Swift package dependencies current.

Each ecosystem is checked monthly, on the first day at 09:00 Asia/Singapore.
All versions, including major upgrades, are grouped into one pull request per
ecosystem, with at most one open routine update in each ecosystem (two total).
Security updates have their own groups and can arrive between monthly checks;
GitHub does not apply the routine-update schedule or PR limit to them. Every
update still needs the required `build and test` check before merging.

## Recommended next layer

Use Apple's [XCTest and XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation) for a small set of complete macOS user journeys. Keep Swift Testing for the existing integration suite. UI tests need a dedicated Xcode UI-test target and a logged-in graphical runner; the current Swift package does **not** yet include this target.

Start with six journeys:

1. Launch an isolated library, create a document, type Unicode text, quit and reopen.
2. Search for a table, change parameters, insert, move through placeholders, undo and redo.
3. Search document content, rename, trash, restore and reopen without losing edits; cancel and then confirm emptying an isolated trash.
4. Switch interface language while preserving the editor buffer and selection.
5. Switch writing views, pin the outline and verify the manuscript's position stays fixed.
6. Render a valid document, introduce a syntax error, retain the last successful preview, recover and export a new PDF.

Use stable accessibility identifiers and wait for observable states, not fixed delays or screen coordinates. Preserve failed screenshots, the accessibility hierarchy, `.xcresult`, compiler diagnostics and isolated action logs as CI artifacts. A retry may diagnose a flaky test; it must not silently turn a failed workflow into a passing gate.

Add [SnapshotTesting](https://github.com/pointfreeco/swift-snapshot-testing) only to test targets for a few important visual states: the compact toolbar hint, library header, command list/form and narrow/wide outline. Pin the macOS version, display scale, fonts, locale, appearance and fixture timestamps. Review changed reference images explicitly; do not regenerate them automatically in CI. This is a proposed addition, not an existing screenshot gate.

## Release acceptance

Run the release workflow manually after a passing main commit to exercise Developer ID signing, profile embedding, notarization and Gatekeeper validation without publishing a version tag. Use the resulting artifact to test capabilities that an ad hoc local build does not have.

Real iCloud delivery remains a two-Mac acceptance check: offline edits, nonoverlapping and overlapping changes, account changes, pending downloads and assets. A deterministic injected-store test does not prove Apple's cross-device delivery or latency. Full input-method composition and VoiceOver also need real user-interface checks.

## Issues found during 0.4 acceptance

- Swift 6.2.4 crashed while converting an actor-isolated setting method to a SwiftUI binding closure; explicit closures compile successfully in the hosted toolchain.
- The native SwiftPM builder emitted `zh-hans.lproj` while the newer builder preserved `zh-Hans.lproj`. Bundle lookup is case-sensitive; localization now selects the actual bundled identifier. The failure and fix were reproduced locally with the native builder.
- Native menu labels ignored the SwiftUI image frame and used the PDF icon's 256-point artboard. The shared template images now have a compact intrinsic size, with a resource regression check.
- A packaged native SwiftPM app could still depend on the build checkout for localized resources. App-bundle resource lookup and the relocated launch gate remove that dependency.
- Managed-document titles support single-click inline rename and double-click navigation; the library exposes direct trash/restore actions. Preview colors keep a fixed 68 × 28 hit target in both states.
- Managed-document export dialogs now suggest the document title instead of the internal `main` filename.

The first two were caught by CI and the icon defect by a real-window visual check. This is why LeftBlank needs complementary behavior and visual checks, in addition to its line-coverage target.
