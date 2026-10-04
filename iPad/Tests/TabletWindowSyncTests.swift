import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import LeftBlankTestSupport
import Testing

@Suite(.serialized)
@MainActor
struct TabletWindowSyncTests {
    private func directory() throws -> URL {
        let url = TestPaths.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func prepare(_ workspace: TabletWorkspace, source: String) async throws -> LibraryDocument {
        let item = try await workspace.library.create(title: "Shared writing", text: source)
        let read = try await workspace.library.read(item.id)
        workspace.document = item
        workspace.activeSourceURL = item.sourceURL
        workspace.text = read.text
        workspace.savedText = read.text
        workspace.baseline = read.baseline
        return item
    }

    @Test func cleanReadOnlyWindowAdoptsExternalRevision() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = TabletWorkspace(stateDirectory: root)
        let item = try await prepare(workspace, source: "= Title\nOriginal text\n")
        _ = try DocumentStorage.write(
            "= Title\nFrom another window\n",
            to: item.sourceURL,
            baseline: workspace.baseline,
        )
        workspace.selection = NSRange(location: 2, length: 0)
        await workspace.refreshFromLibrary()
        #expect(workspace.text == "= Title\nFrom another window\n")
        #expect(workspace.savedText == workspace.text)
        #expect(workspace.selection.location == 2)
        #expect(workspace.saveStatus == "Saved")
        #expect(workspace.version == 2)
    }

    @Test func overlappingExternalEditPreservesDraftAndDisk() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = TabletWorkspace(stateDirectory: root)
        let item = try await prepare(workspace, source: "Original paragraph\n")
        workspace.text = "My unsaved paragraph\n"
        _ = try DocumentStorage.write("Other window's paragraph\n", to: item.sourceURL, baseline: workspace.baseline)
        await workspace.refreshFromLibrary()
        #expect(workspace.text == "My unsaved paragraph\n")
        #expect(workspace.savedText == "Original paragraph\n")
        #expect(workspace.saveStatus == "Save Needs Attention")
        #expect(workspace.message != nil)
        let recovery = try JSONDecoder().decode(RecoverySnapshot.self, from: Data(contentsOf: workspace.recoveryURL))
        #expect(recovery.text == workspace.text)
        #expect(try DocumentStorage.read(item.sourceURL).0 == "Other window's paragraph\n")
        #expect(await workspace.save() == false)
    }

    @Test func sceneRecoveryFilesAreIndependentAndStable() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionID = UUID()
        let first = TabletWorkspace(sessionID: sessionID, stateDirectory: root)
        let second = TabletWorkspace(stateDirectory: root)
        first.text = "First window"
        second.text = "Second window"
        first.persistRecovery()
        second.persistRecovery()
        #expect(first.recoveryURL != second.recoveryURL)
        #expect(first.history === second.history)
        #expect(first.exportDirectory != second.exportDirectory)
        let reopened = TabletWorkspace(sessionID: sessionID, stateDirectory: root)
        #expect(reopened.recoveryURL == first.recoveryURL)
        let decoder = JSONDecoder()
        #expect(try decoder.decode(RecoverySnapshot.self, from: Data(contentsOf: first.recoveryURL))
            .text == "First window")
        #expect(try decoder.decode(RecoverySnapshot.self, from: Data(contentsOf: second.recoveryURL))
            .text == "Second window")
    }

    @Test func sourceExportPreservesUnsavedTextWithoutSubscription() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = TabletWorkspace(stateDirectory: root)
        let item = try await prepare(workspace, source: "Saved")
        workspace.text = "Unsaved 中文 $x$"
        workspace.exportSource()
        let exported = try #require(workspace.shareURL)
        #expect(exported != item.sourceURL)
        #expect(try String(contentsOf: exported, encoding: .utf8) == workspace.text)
        #expect(try DocumentStorage.read(item.sourceURL).0 == "Saved")
    }
}
