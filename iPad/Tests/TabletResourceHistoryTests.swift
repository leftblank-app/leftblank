import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import LeftBlankTestSupport
import Testing
import UIKit

@MainActor
private final class ResourcePurchases: TabletPurchaseService {
    var access: SubscriptionAccess = .subscribed(until: Date().addingTimeInterval(3600))
    func offering() -> SubscriptionOffering {
        SubscriptionOffering(displayPrice: "$2.99", trialWeeks: nil)
    }

    func entitlement() -> SubscriptionAccess {
        access
    }

    func purchase() -> SubscriptionPurchaseResult {
        .cancelled
    }

    func restore() {}
    func manage(in _: UIWindowScene) {}
    func updates() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

@MainActor
private final class ResourceEditor: UITextView {
    let history = UndoManager()
    override var undoManager: UndoManager? {
        history
    }
}

@Suite(.serialized)
@MainActor
struct TabletResourceHistoryTests {
    private func fixture() async throws -> (TabletWorkspace, ResourceEditor, ResourcePurchases, URL) {
        let root = TestPaths.temporaryDirectory.appendingPathComponent("tablet-resources-" + UUID().uuidString)
        let purchases = ResourcePurchases()
        let subscription = TabletSubscription(service: purchases)
        await subscription.refresh()
        let workspace = TabletWorkspace(subscription: subscription, stateDirectory: root)
        let item = try await workspace.library.create(text: "Body")
        workspace.document = item
        workspace.activeSourceURL = item.sourceURL
        workspace.text = "Body"
        workspace.savedText = "Body"
        let editor = ResourceEditor()
        editor.history.groupsByEvent = false
        editor.text = workspace.text
        editor.isEditable = true
        editor.selectedRange = NSRange(location: 4, length: 0)
        workspace.selection = editor.selectedRange
        workspace.editor = editor
        return (workspace, editor, purchases, root)
    }

    @Test func importCopiesIntoActiveChapterAndUndoKeepsItsResource() async throws {
        let (workspace, editor, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try #require(workspace.document)
        let chapter = document.folderURL.appendingPathComponent("chapters/chapter.typ")
        try FileManager.default.createDirectory(
            at: chapter.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try Data(workspace.text.utf8).write(to: chapter)
        workspace.activeSourceURL = chapter
        let original = root.appendingPathComponent("图 \"sample\".svg")
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1\" height=\"1\"/>".utf8)
        try svg.write(to: original)
        editor.history.beginUndoGrouping()
        try await workspace.importAndInsertResources([.file(original)], kind: .image, replacing: workspace.selection)
        editor.history.endUndoGrouping()
        let resources = try await DocumentResourceStore().list(
            kind: .image,
            in: document.folderURL,
            relativeTo: chapter,
        )
        let resource = try #require(resources.first)
        #expect(resource.relativePath.hasPrefix("../assets/"))
        #expect(!workspace.text.contains(root.path))
        #expect(workspace.text.contains("\\\"sample\\\""))
        let inserted = workspace.text
        #expect(editor.text == inserted)
        try FileManager.default.removeItem(at: original)
        #expect(try Data(contentsOf: resource.url) == svg)
        editor.history.undo()
        #expect(workspace.text == "Body")
        #expect(editor.selectedRange == NSRange(location: 4, length: 0))
        #expect(FileManager.default.fileExists(atPath: resource.url.path))
        editor.history.redo()
        #expect(workspace.text == inserted)
        #expect(await workspace.save())
    }

    @Test func resourceImportRejectsExpiredReadOnlyAndStaleSelections() async throws {
        let (workspace, editor, purchases, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("reference.bib")
        try Data("@book{example, title={Example}}".utf8).write(to: original)
        let range = workspace.selection
        editor.selectedRange = NSRange(location: 0, length: 0)
        try await workspace.importAndInsertResources([.file(original)], kind: .bibliography, replacing: range)
        #expect(workspace.text == "Body")
        editor.selectedRange = range
        editor.isEditable = false
        try await workspace.importAndInsertResources([.file(original)], kind: .bibliography, replacing: range)
        #expect(workspace.text == "Body")
        editor.isEditable = true
        purchases.access = .expired
        await workspace.subscription.refresh()
        try await workspace.importAndInsertResources([.file(original)], kind: .bibliography, replacing: range)
        #expect(workspace.text == "Body")
        #expect(workspace.panel == .subscription)
        let project = try #require(workspace.resourceRoot)
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("assets").path))
    }

    @Test func fabricatedExistingResourceCannotReferenceAnExternalFile() async throws {
        let (workspace, editor, _, root) = try await fixture()
        defer {
            withExtendedLifetime(editor) {}
            try? FileManager.default.removeItem(at: root)
        }
        let source = try #require(workspace.sourceURL)
        let outside = root.appendingPathComponent("outside.typ")
        try Data("Outside".utf8).write(to: outside)
        let command = try #require(WritingCommand.all.first { $0.id == "include" })
        await #expect(throws: DocumentResourceError.invalidLocation) {
            try await workspace.insertResourceCommand(
                command,
                values: [:],
                resource: .existing(DocumentResource(
                    url: outside,
                    relativeTo: source,
                )),
            )
        }
        #expect(workspace.text == "Body")
    }

    @Test func restorePreservesCurrentWritingAndSupportsUndo() async throws {
        let (workspace, editor, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let key = try #require(workspace.historyKey)
        let revision = try await #require(workspace.history.recordEdit(
            key: key, previous: "Original", current: "Body", at: Date(), interval: .hourly,
        ))
        let comparison = try await HistoryComparison(before: workspace.revisionSource(revision), after: workspace.text)
        #expect(!comparison.identical)
        #expect(!comparison.addedRanges.isEmpty)
        #expect(!comparison.removedRanges.isEmpty)
        editor.history.beginUndoGrouping()
        await workspace.restore(revision)
        editor.history.endUndoGrouping()
        #expect(workspace.text == "Original")
        let preserved = try await #require(workspace.history.revisions(for: key).first)
        #expect(preserved.reason == .beforeRestore)
        #expect(try await workspace.history.source(for: preserved, key: key) == "Body")
        editor.history.undo()
        #expect(workspace.text == "Body")
        #expect(await workspace.save())
    }

    @Test func emptyTrashPreservesDocumentsRestoredAfterConfirmation() async throws {
        let (workspace, _, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = try #require(workspace.document)
        let deleted = try await workspace.library.create(text: "Delete this")
        _ = try await workspace.library.trash(kept.id)
        _ = try await workspace.library.trash(deleted.id)
        let snapshot = try await workspace.library.trashSnapshot()
        _ = try await workspace.library.restore(kept.id)
        await workspace.emptyTrash(snapshot)
        #expect(try await workspace.library.read(kept.id).text == "Body")
        await #expect(throws: LibraryError.notFound) { try await workspace.library.read(deleted.id) }
        #expect(workspace.trashedDocuments.isEmpty)
    }
}
