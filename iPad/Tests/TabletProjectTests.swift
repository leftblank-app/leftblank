import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import LeftBlankTestSupport
import PDFKit
import Testing

@Suite(.serialized)
@MainActor
struct TabletProjectTests {
    @Test func includedSourceKeepsEntryPreviewAndRejectsConflictingSave() async throws {
        let root = TestPaths.temporaryDirectory.appendingPathComponent("tablet-project-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let imported = root.appendingPathComponent("Input")
        try FileManager.default.createDirectory(at: imported, withIntermediateDirectories: true)
        let entry = imported.appendingPathComponent("book.typ")
        let chapter = imported.appendingPathComponent("chapter.typ")
        try Data("#include \"chapter.typ\"".utf8).write(to: entry)
        try Data("= Chapter\nProject body".utf8).write(to: chapter)
        let workspace = TabletWorkspace(stateDirectory: root.appendingPathComponent("State"))
        defer { workspace.client.stop() }
        let document = try await workspace.library.importProject(at: imported, mainFile: entry)
        await workspace.open(document)
        #expect(workspace.serviceReady)
        workspace.showProjectFiles()
        #expect(workspace.projectSources.count == 2)
        let source = document.sourceURL.deletingLastPathComponent().appendingPathComponent("chapter.typ")
        #expect(await workspace.openSource(source))
        #expect(workspace.sourceURL == source)
        #expect(workspace.entryURL == document.sourceURL)
        #expect(workspace.text == "= Chapter\nProject body")
        #expect(workspace.serviceReady)
        await workspace.exportPDF()
        let pdf = try #require(workspace.shareURL)
        #expect(try Data(contentsOf: pdf).starts(with: Data("%PDF".utf8)))
        let rendered = try #require(PDFDocument(url: pdf))
        #expect(rendered.pageCount == 1)
        #expect(rendered.string?.contains("Project body") == true)
        #expect(pdf.path.hasPrefix(workspace.exportDirectory.path + "/"))
        let originalHistory = workspace.historyKey
        #expect(await workspace.openSource(document.sourceURL))
        #expect(workspace.historyKey != originalHistory)
        #expect(await workspace.openSource(source))
        workspace.text = "Unsaved local chapter"
        _ = try DocumentStorage.write("External chapter", to: source, baseline: workspace.baseline)
        #expect(await workspace.openSource(document.sourceURL) == false)
        #expect(workspace.sourceURL == source)
        #expect(workspace.text == "Unsaved local chapter")
        #expect(try DocumentStorage.read(source).0 == "External chapter")
        let outside = root.appendingPathComponent("outside.typ")
        try Data("outside".utf8).write(to: outside)
        #expect(await workspace.openSource(outside) == false)
        #expect(workspace.sourceURL == source)
    }

    @Test func startupKeepsADocumentChosenWhileTheLibraryLoads() async throws {
        let root = TestPaths.temporaryDirectory.appendingPathComponent("tablet-startup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // Keep startup local; this test must not wait for an iCloud container.
        let defaults = UserDefaults.standard
        let cloud = defaults.object(forKey: "iPadCloudEnabled")
        defaults.set(false, forKey: "iPadCloudEnabled")
        defer { defaults.set(cloud, forKey: "iPadCloudEnabled") }
        let session = UUID()
        let state = root.appendingPathComponent("State")
        let earlier = TabletWorkspace(sessionID: session, stateDirectory: state)
        let previous = try await earlier.library.create(title: "Previous", text: "= Previous\n\nLast session\n")
        let chosen = try await earlier.library.create(title: "Chosen", text: "= Chosen\n\nPicked at launch\n")
        await earlier.open(previous)
        earlier.selection = NSRange(location: 4, length: 0)
        earlier.persistRecovery()
        earlier.client.stop()

        // Nothing chosen yet: startup reopens the last session at its caret.
        let restored = TabletWorkspace(sessionID: session, stateDirectory: state)
        await restored.start()
        #expect(restored.document?.id == previous.id)
        #expect(restored.selection.location == 4)
        restored.client.stop()

        // A person opens another document before startup finishes. Restoring
        // must neither replace it nor reload it and move its caret.
        let next = TabletWorkspace(sessionID: session, stateDirectory: state)
        defer { next.client.stop() }
        try await next.reloadLibrary()
        await next.open(chosen)
        next.selection = NSRange(location: 6, length: 0)
        await next.start()
        #expect(next.document?.id == chosen.id)
        #expect(next.selection.location == 6)
        #expect(next.text == "= Chosen\n\nPicked at launch\n")
    }
}
