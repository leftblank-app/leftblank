import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import PDFKit
import Testing

extension WritingFlowTests {
    /// Moving between files of one book (definitions, diagnostics, preview clicks,
    /// back navigation) keeps the running engine, preview and diagnostics. Only a
    /// different compilation entry or an explicit restart launches a new engine.
    /// Every wait is on real state with the fixture's generous timeout.
    @Test func sameBookFileSwitchesReuseTheRunningEngine() async throws {
        let source = "= Book\n\n#include \"chapter.typ\"\n\n#include \"appendix.typ\"\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let chapter = app.root.appendingPathComponent("chapter.typ")
        let appendix = app.root.appendingPathComponent("appendix.typ")
        try Data("= Chapter\n\nChapter body.\n".utf8).write(to: chapter)
        try Data("#set text(font: \"LeftBlank Missing Font\")\n= Appendix\n\nAppendix body.\n".utf8)
            .write(to: appendix)
        let editor = try #require(app.workspace.editor)
        func isAppendix(_ item: DiagnosticItem) -> Bool {
            item.url.standardizedFileURL.path == appendix.standardizedFileURL.path
        }

        app.workspace.startService()
        try await app.ready()
        try await app.wait { app.workspace.hasSuccessfulPreview }
        try await app.wait { app.workspace.diagnostics.contains(where: isAppendix) }
        #expect(app.workspace.engineLaunches == 1)
        let preview = try #require(app.workspace.previewURL)

        // Unsaved main-file text must reach the engine, which keeps the entry open.
        editor.insertText("Main sentinel\n\n", replacementRange: NSRange(location: 0, length: 0))
        #expect(app.workspace.open(chapter, preservingMain: true))
        #expect(app.workspace.documentURL == chapter)
        #expect(app.workspace.compilationURL == app.document)
        #expect(app.workspace.engineLaunches == 1)
        #expect(app.workspace.serviceReady)
        #expect(app.workspace.previewURL == preview)
        #expect(app.workspace.diagnostics.contains(where: isAppendix), "Other files' diagnostics are kept")
        try await app.wait { app.workspace.syntaxSnapshot?.source == app.workspace.text }
        try await app.wait { app.workspace.outline.map(\.title) == ["Chapter"] }

        // Unsaved chapter text compiles in the reused engine.
        editor.insertText("Chapter sentinel\n\n", replacementRange: NSRange(location: 0, length: 0))
        let firstPDF = try await app.exportedText(containing: ["Main sentinel", "Chapter sentinel", "Appendix body"])
        #expect(firstPDF.contains("Main sentinel"))
        #expect(firstPDF.contains("Chapter sentinel"))
        #expect(firstPDF.contains("Appendix body"))

        // Opening a diagnostic in another file of the book.
        let warning = try #require(app.workspace.diagnostics.first(where: isAppendix))
        app.workspace.showDiagnostic(warning)
        #expect(app.workspace.documentURL.standardizedFileURL.path == appendix.standardizedFileURL.path)
        #expect(app.workspace.engineLaunches == 1)
        #expect(app.workspace.previewURL == preview)
        // The chapter was saved and closed; the engine now reads it from disk.
        #expect(try String(contentsOf: chapter, encoding: .utf8).hasPrefix("Chapter sentinel"))
        editor.insertText(
            "Appendix sentinel\n\n",
            replacementRange: NSRange(location: editor.string.utf16.count, length: 0),
        )
        let secondPDF = try await app.exportedText(containing: ["Chapter sentinel", "Appendix sentinel"])
        #expect(secondPDF.contains("Chapter sentinel"))
        #expect(secondPDF.contains("Appendix sentinel"))

        // Back navigation and returning to the main document also keep the engine.
        app.workspace.navigateBack()
        #expect(app.workspace.documentURL == chapter)
        #expect(app.workspace.open(app.document))
        #expect(app.workspace.mainFileURL == nil)
        #expect(app.workspace.engineLaunches == 1)
        #expect(app.workspace.previewURL == preview)
        try await app.wait { app.workspace.syntaxSnapshot?.source == app.workspace.text }
        try await app.wait { app.workspace.outline.map(\.title) == ["Book"] }
        try await app.wait { !app.workspace.previewStale }

        // A different book needs its own engine and preview.
        let other = app.root.appendingPathComponent("Other/standalone.typ")
        try FileManager.default.createDirectory(
            at: other.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data("= Other book\n".utf8).write(to: other)
        #expect(app.workspace.open(other))
        #expect(app.workspace.engineLaunches == 2)
        try await app.ready()
        #expect(app.workspace.previewURL != preview)
        #expect(!app.workspace.diagnostics.contains(where: isAppendix))

        // An explicit restart always launches a fresh engine.
        try app.workspace.execute(#require(WritingCommand.all.first { $0.id == "restart" }))
        #expect(app.workspace.engineLaunches == 3)
        try await app.ready()
        let log = try String(
            contentsOf: app.workspace.stateDirectory.appendingPathComponent("Logs/events.jsonl"),
            encoding: .utf8,
        )
        #expect(log.contains("service.reuse"))
        #expect(log.contains("service.firstCompile"))
    }

    /// Tinymist ends a preview whose page stayed disconnected and unpins the
    /// compilation entry; such an engine cannot keep serving the book's preview.
    @Test func disposedPreviewMakesTheNextFileSwitchRestartTheEngine() async throws {
        let app = try WritingFixture(text: "= Book\n\n#include \"chapter.typ\"\n", startService: false)
        defer { app.close() }
        let chapter = app.root.appendingPathComponent("chapter.typ")
        try Data("= Chapter\n".utf8).write(to: chapter)
        app.workspace.startService()
        try await app.ready()
        let preview = try #require(app.workspace.previewURL)
        app.workspace.receive("tinymist/preview/dispose", .object(["taskId": .string("leftblank")]))
        #expect(app.workspace.open(chapter, preservingMain: true))
        #expect(app.workspace.engineLaunches == 2)
        try await app.ready()
        #expect(app.workspace.previewURL != preview)
        #expect(app.workspace.compilationURL == app.document)
        // The fresh engine is reusable again.
        #expect(app.workspace.open(app.document))
        #expect(app.workspace.engineLaunches == 2)
    }
}

extension WritingFixture {
    /// `tinymist.exportPdf` reads the engine's latest snapshot, which may not yet
    /// include an edit sent a moment earlier. Wait for the edit to compile, then
    /// export until the text appears or the deadline passes (slow CI machines).
    func exportedText(containing expected: [String]) async throws -> String {
        try await wait { !workspace.previewStale }
        let destination = root.appendingPathComponent("export-\(UUID().uuidString).pdf")
        let deadline = ContinuousClock.now + .seconds(30)
        var text = ""
        repeat {
            try await workspace.exportPDF(to: destination)
            text = PDFDocument(url: destination)?.string ?? ""
            if expected.allSatisfy(text.contains) {
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        } while ContinuousClock.now < deadline
        return text
    }
}
