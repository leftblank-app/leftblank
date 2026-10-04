import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import LeftBlankTestSupport
import Testing
import UIKit
import UniformTypeIdentifiers

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

@MainActor
private final class ImageDropSession: NSObject, UIDropSession {
    let items: [UIDragItem]
    let localDragSession: (any UIDragSession)? = nil
    let allowsMoveOperation = false
    let isRestrictedToDraggingApplication = false
    let progress = Progress(totalUnitCount: 1)
    var progressIndicatorStyle = UIDropSessionProgressIndicatorStyle.none

    init(_ providers: [NSItemProvider]) {
        items = providers.map { UIDragItem(itemProvider: $0) }
    }

    func location(in view: UIView) -> CGPoint {
        CGPoint(x: 20, y: 20)
    }

    func hasItemsConforming(toTypeIdentifiers types: [String]) -> Bool {
        items.contains { item in types.contains { item.itemProvider.hasItemConformingToTypeIdentifier($0) } }
    }

    func canLoadObjects(ofClass type: any NSItemProviderReading.Type) -> Bool {
        items.contains { $0.itemProvider.canLoadObject(ofClass: type) }
    }

    func loadObjects(
        ofClass type: any NSItemProviderReading.Type,
        completion: ([any NSItemProviderReading]) -> Void,
    ) -> Progress {
        completion([])
        return progress
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
        let recorded = try await workspace.history.recordEdit(
            key: key, previous: "Original", current: "Body", at: Date(), interval: .hourly,
        )
        let revision = try #require(recorded)
        let comparison = try await HistoryComparison(before: workspace.revisionSource(revision), after: workspace.text)
        #expect(!comparison.identical)
        #expect(!comparison.addedRanges.isEmpty)
        #expect(!comparison.removedRanges.isEmpty)
        editor.history.beginUndoGrouping()
        await workspace.restore(revision)
        editor.history.endUndoGrouping()
        #expect(workspace.text == "Original")
        let revisions = try await workspace.history.revisions(for: key)
        let preserved = try #require(revisions.first)
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

    @Test func hardwareCommandsPreserveSnippetSelectionAndRejectReadOnlyEdits() async throws {
        let (workspace, _, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = TabletTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        editor.workspace = workspace
        workspace.editor = editor
        editor.text = workspace.text
        editor.isEditable = true
        let first = NSRange(location: 0, length: 2), second = NSRange(location: 2, length: 2)
        editor.setSnippet(Snippet(text: "Body", selections: [first, second]), at: 0)
        #expect(workspace.selection == first)
        let tab = try #require(editor.keyCommands?.first { $0.input == "\t" && $0.modifierFlags.isEmpty })
        editor.perform(tab.action, with: tab)
        #expect(editor.selectedRange == second && workspace.selection == second)
        let back = try #require(editor.keyCommands?.first { $0.input == "\t" && $0.modifierFlags == .shift })
        editor.perform(back.action, with: back)
        #expect(workspace.selection == first)
        let coordinator = TabletEditor.Coordinator(workspace)
        #expect(coordinator.textView(editor, shouldChangeTextIn: first, replacementText: "Long"))
        editor.textStorage.replaceCharacters(in: first, with: "Long")
        editor.selectedRange = NSRange(location: 4, length: 0)
        coordinator.textViewDidChange(editor)
        #expect(workspace.text == "Longdy")
        editor.perform(tab.action, with: tab)
        #expect(editor.selectedRange == NSRange(location: 4, length: 2))
        editor.clearSnippet()
        #expect(editor.keyCommands?.contains { $0.input == "\t" && $0.wantsPriorityOverSystemBehavior } == false)
        let indent = try #require(editor.keyCommands?.first { $0.input == "]" && $0.modifierFlags == .command })
        let outdent = try #require(editor.keyCommands?.first { $0.input == "[" && $0.modifierFlags == .command })
        let comment = try #require(editor.keyCommands?.first { $0.input == "/" && $0.modifierFlags == .command })
        editor.perform(indent.action)
        #expect(workspace.text == "  Longdy")
        editor.perform(outdent.action)
        #expect(workspace.text == "Longdy")
        editor.perform(comment.action)
        #expect(workspace.text.contains("//"))
        editor.perform(comment.action)
        #expect(workspace.text == "Longdy")
        editor.isEditable = false
        #expect(try !editor.canPerformAction(#require(indent.action), withSender: nil))
        #expect(!editor.canPerformAction(NSSelectorFromString("paste:"), withSender: nil))
        workspace.busy = true
        #expect(!coordinator.textView(editor, shouldChangeTextIn: first, replacementText: "no"))
        workspace.busy = false
        #expect(workspace.text == "Longdy")
    }

    @Test func imagePasteAndDropCreatePortableReferencesAndRejectUnsupportedDrops() async throws {
        let (workspace, _, _, root) = try await fixture()
        let clipboard = UIPasteboard.general.items
        defer {
            UIPasteboard.general.items = clipboard
            try? FileManager.default.removeItem(at: root)
        }
        let editor = TabletTextView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        editor.workspace = workspace
        workspace.editor = editor
        editor.text = workspace.text
        editor.isEditable = true
        editor.selectedRange = workspace.selection
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        UIPasteboard.general.image = image
        #expect(editor.canPerformAction(NSSelectorFromString("paste:"), withSender: nil))
        editor.paste(nil)
        for _ in 0 ..< 250 where !workspace.text.contains("#image(") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(workspace.text.contains("#image("))
        let pasted = workspace.text
        let data = try #require(image.pngData())
        let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)
        let session = ImageDropSession([provider])
        let interaction = UIDropInteraction(delegate: editor)
        #expect(editor.dropInteraction(interaction, canHandle: session))
        #expect(editor.dropInteraction(interaction, sessionDidUpdate: session).operation == .copy)
        let unsupported = ImageDropSession([NSItemProvider(object: "plain text" as NSString)])
        #expect(!editor.dropInteraction(interaction, canHandle: unsupported))
        editor.dropInteraction(interaction, performDrop: session)
        for _ in 0 ..< 250 where workspace.text == pasted {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(workspace.text != pasted)
        let source = try #require(workspace.sourceURL), project = try #require(workspace.resourceRoot)
        let assets = try await DocumentResourceStore().list(kind: .image, in: project, relativeTo: source)
        #expect(!assets.isEmpty)
        #expect(assets.allSatisfy { $0.relativePath.hasPrefix("assets/") })
        #expect(!workspace.text.contains(root.path))
        editor.isEditable = false
        let before = workspace.text
        #expect(!editor.dropInteraction(interaction, canHandle: session))
        #expect(editor.dropInteraction(interaction, sessionDidUpdate: session).operation == .cancel)
        editor.paste(nil)
        editor.dropInteraction(interaction, performDrop: session)
        #expect(workspace.text == before)
    }

    @Test func resourceCommandsReuseExistingFilesAndCopySelectedFiles() async throws {
        let (workspace, editor, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chapter.typ")
        try Data("A reusable chapter".utf8).write(to: file)
        let command = try #require(WritingCommand.all.first { $0.id == "include" })
        editor.history.beginUndoGrouping()
        try await workspace.insertResourceCommand(command, values: [:], resource: .file(file))
        editor.history.endUndoGrouping()
        #expect(workspace.text.contains("#include"))
        let source = try #require(workspace.sourceURL), project = try #require(workspace.resourceRoot)
        let available = try await DocumentResourceStore().list(kind: .document, in: project, relativeTo: source)
        let imported = try #require(available.first)
        #expect(TabletResourceSelection.file(file).name == "chapter.typ")
        #expect(TabletResourceSelection.existing(imported).name == imported.relativePath)
        let before = workspace.text
        editor.history.beginUndoGrouping()
        try await workspace.insertResourceCommand(command, values: [:], resource: .existing(imported))
        editor.history.endUndoGrouping()
        #expect(workspace.text != before)
        #expect(try String(contentsOf: imported.url, encoding: .utf8) == "A reusable chapter")
        editor.history.undo()
        #expect(workspace.text == before)
    }

    @Test func independentWindowChangesMergeAndRemainUndoable() async throws {
        let (workspace, editor, _, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(workspace.sourceURL)
        let original = "One\nTwo\nThree\n"
        let base = try DocumentStorage.write(original, to: source, baseline: nil)
        workspace.baseline = base
        workspace.text = original
        workspace.savedText = original
        editor.text = original
        editor.selectedRange = NSRange(location: 0, length: 0)
        workspace.selection = editor.selectedRange
        editor.text = "Local\nTwo\nThree\n"
        workspace.edited(editor.text, selection: editor.selectedRange)
        _ = try DocumentStorage.write("One\nTwo\nRemote\n", to: source, baseline: base)
        editor.history.beginUndoGrouping()
        await workspace.refreshFromLibrary()
        editor.history.endUndoGrouping()
        #expect(workspace.text == "Local\nTwo\nRemote\n")
        #expect(editor.text == workspace.text)
        editor.history.undo()
        #expect(workspace.text == "Local\nTwo\nThree\n")
        editor.history.redo()
        #expect(workspace.text == "Local\nTwo\nRemote\n")
        #expect(await workspace.save())
        #expect(try DocumentStorage.read(source).0 == workspace.text)
        let other = TabletWorkspace(stateDirectory: root)
        await workspace.setCloud(true)
        #expect(workspace.message == L10n.text("Close other windows before changing iCloud Sync."))
        #expect(other.history === workspace.history)
    }
}
