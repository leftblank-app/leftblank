import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import LeftBlankTestSupport
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
        let pdf = try await workspace.compiledPDF()
        #expect(try Data(contentsOf: pdf).starts(with: Data("%PDF".utf8)))
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
}
