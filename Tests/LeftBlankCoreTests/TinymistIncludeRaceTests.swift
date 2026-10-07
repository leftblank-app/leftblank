import Foundation
@testable import LeftBlankCore
import LeftBlankTestSupport
import Testing

/// Tinymist 0.15.8's VFS let a compilation of an older revision fill a file
/// cell the next revision shared, so an included file could keep stale
/// contents after its edit was applied. This drives the bundled binary with
/// edits to newly included files while the preview's compilations read them.
/// The unpatched 0.15.8 release kept a stale part in 12-15 of 40 rounds; the
/// build with `scripts/tinymist-vfs.patch` passed 1,000 rounds (40,000 racing
/// first reads). `LEFTBLANK_INCLUDE_RACE_ROUNDS` raises the count for soak runs.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["LEFTBLANK_INTEGRATION"] == "1"))
func includedEditsDuringCompilationReachExport() async throws {
    let rounds = ProcessInfo.processInfo.environment["LEFTBLANK_INCLUDE_RACE_ROUNDS"].flatMap(Int.init) ?? 40
    // One round's edits stay below the client's 64-message write queue bound.
    let partsPerRound = 40
    let root = TestPaths.temporaryDirectory.appendingPathComponent("LeftBlank-include-race-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let client = TinymistClient()
    defer {
        client.stop()
        try? FileManager.default.removeItem(at: root)
    }
    let main = root.appendingPathComponent("main.typ")
    try Data("Saved main".utf8).write(to: main)
    try await client.start(root: root, outputDirectory: root)
    try client.open(main, text: "Saved main", version: 1)
    _ = try await client.startPreview(main)

    var staleRounds: [String] = []
    for round in 0 ..< rounds {
        // Each round reads new files for the first time: the race needs a path
        // that no completed read has indexed yet.
        let parts = (0 ..< partsPerRound).map { root.appendingPathComponent("part-\(round)-\($0).typ") }
        for (index, part) in parts.enumerated() {
            try Data("[saved \(round)-\(index)]".utf8).write(to: part)
            try client.open(part, text: "[old \(round)-\(index)]", version: 1)
        }
        // Let the server take the opens before the burst of edits.
        _ = try await client.request("textDocument/documentSymbol", ["textDocument": ["uri": main.absoluteString]])
        let includes = parts.map { "#include \"\($0.lastPathComponent)\"\n" }.joined()
        try client.change(main, text: includes + "[main \(round)]\n", version: round + 2)
        // Edit every part immediately, while the preview compiles the new main.
        for (index, part) in parts.enumerated() {
            try client.change(part, text: "[new \(round)-\(index)]", version: 2)
        }
        let expected = parts.indices.map { "[new \(round)-\($0)]" } + ["[main \(round)]"]
        // Without the fix the stale part never recovers; a correct engine
        // converges within one or two compilations.
        let deadline = ContinuousClock.now + .seconds(5)
        var missing = expected
        while true {
            let result = try await client.command("tinymist.exportText", arguments: [main.path])
            let text = try String(contentsOfFile: #require(result["path"].string), encoding: .utf8)
            missing = expected.filter { !text.contains($0) }
            if missing.isEmpty || ContinuousClock.now > deadline {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        if !missing.isEmpty {
            staleRounds.append("round \(round): \(missing.prefix(3).joined(separator: ", "))")
        }
    }
    #expect(staleRounds.isEmpty, "Export kept stale included contents: \(staleRounds.joined(separator: "; "))")
}
