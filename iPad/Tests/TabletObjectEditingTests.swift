import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import LeftBlankTestSupport
import PDFKit
import Testing
import UIKit

@MainActor
private final class ObjectPurchaseService: TabletPurchaseService {
    var access = SubscriptionAccess.subscribed(until: Date().addingTimeInterval(3600))
    func offering() -> SubscriptionOffering {
        .init(displayPrice: "$1", trialWeeks: nil)
    }

    func entitlement() -> SubscriptionAccess {
        access
    }

    func purchase() -> SubscriptionPurchaseResult {
        .cancelled
    }

    func restore() {}
    func manage(in scene: UIWindowScene) {}
    func updates() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

@MainActor
private final class ObjectTextView: UITextView {
    let history = UndoManager()
    override var undoManager: UndoManager? {
        history
    }
}

@Suite(.serialized)
@MainActor
struct TabletObjectEditingTests {
    private func fixture() async throws -> (TabletWorkspace, ObjectTextView, ObjectPurchaseService) {
        let service = ObjectPurchaseService()
        let subscription = TabletSubscription(service: service)
        await subscription.refresh()
        let root = TestPaths.temporaryDirectory.appendingPathComponent("objects-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = TabletWorkspace(subscription: subscription, stateDirectory: root)
        let editor = ObjectTextView()
        editor.history.groupsByEvent = false
        workspace.editor = editor
        workspace.text = "中文😀\n#table(columns: 2, [A], [B])\nKeep this."
        workspace.activeSourceURL = root.appendingPathComponent("main.typ")
        editor.text = workspace.text
        editor.selectedRange = NSRange(location: 12, length: 0)
        workspace.selection = editor.selectedRange
        return (workspace, editor, service)
    }

    @Test func editedTableAndImageCompileWithTheEmbeddedEngine() async throws {
        let (workspace, editor, _) = try await fixture()
        defer {
            workspace.client.stop()
            try? FileManager.default.removeItem(at: workspace.stateDirectory)
        }
        let source = "#table(columns: 2, [A], [B])\n#image(\"mark.svg\", width: 20%)"
        workspace.activeSourceURL = nil
        let asset = Data(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"20\"><rect width=\"20\" height=\"20\"/></svg>"
                .utf8,
        )
        let document = try await workspace.library.create(text: source, assets: ["mark.svg": asset])
        await workspace.open(document)
        editor.text = workspace.text
        editor.selectedRange = NSRange(location: 3, length: 0)
        workspace.selection = editor.selectedRange
        workspace.editObjectAtCursor()
        let table = try #require(workspace.objectEditSession)
        var draft = table.object
        try draft.pasteTable("Name\tValue\nEdited table\t42")
        draft.hasHeader = true
        workspace.applyObjectEdit(draft, session: table)
        editor.selectedRange = NSRange(location: (editor.text as NSString).range(of: "#image").location + 3, length: 0)
        workspace.selection = editor.selectedRange
        workspace.editObjectAtCursor()
        let image = try #require(workspace.objectEditSession)
        draft = image.object
        draft.width = "40%"
        draft.caption = "Edited image"
        draft.alignment = "center"
        workspace.applyObjectEdit(draft, session: image)
        let output = try await workspace.compiledPDF()
        let rendered = try #require(PDFDocument(url: output)?.string)
        #expect(rendered.contains("Edited table"))
        #expect(rendered.contains("Edited image"))
        editor.history.undo()
        #expect(editor.text.contains("#image(\"mark.svg\", width: 20%)"))
        editor.history.undo()
        #expect(editor.text == source)
        #expect(workspace.text == source)
    }

    @Test func objectEditIsOneNativeUndoAndRedoWithModelSynchronization() async throws {
        let (workspace, editor, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.stateDirectory) }
        let original = workspace.text
        workspace.editObjectAtCursor()
        #expect(workspace.panel == .objectEditor)
        let session = try #require(workspace.objectEditSession)
        var draft = session.object
        draft.rows[0][0] = "中文 New"
        draft.rows.append(["C", "D"])
        workspace.applyObjectEdit(draft, session: session)
        #expect(workspace.text == editor.text)
        #expect(workspace.text.hasSuffix("\nKeep this."))
        #expect(workspace.text.contains("[中文 New], [B]"))
        #expect(workspace.objectEditSession == nil)
        #expect(workspace.panel == nil)
        #expect(editor.history.undoActionName == L10n.text("Edit Object"))
        editor.history.undo()
        #expect(workspace.text == original && editor.text == original)
        editor.history.redo()
        #expect(workspace.text.contains("[中文 New], [B]"))
        #expect(workspace.text == editor.text)
    }

    @Test func objectDraftCannotCrossRevisionDocumentOrSubscriptionBoundary() async throws {
        let (workspace, editor, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.stateDirectory) }
        workspace.editObjectAtCursor()
        let session = try #require(workspace.objectEditSession)
        var draft = session.object
        draft.rows[0][0] = "Wrong"
        workspace.version += 1
        workspace.applyObjectEdit(draft, session: session)
        #expect(!workspace.text.contains("Wrong"))
        workspace.version -= 1
        let url = workspace.activeSourceURL
        workspace.activeSourceURL = workspace.stateDirectory.appendingPathComponent("other.typ")
        workspace.applyObjectEdit(draft, session: session)
        #expect(!workspace.text.contains("Wrong"))
        workspace.activeSourceURL = url
        service.access = .expired
        await workspace.subscription.refresh()
        workspace.applyObjectEdit(draft, session: session)
        #expect(!workspace.text.contains("Wrong"))
        #expect(workspace.text == editor.text)
        #expect(!editor.history.canUndo)
    }

    @Test func markedTextAndNoopDoNotCreateObjectEdits() async throws {
        let (workspace, editor, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.stateDirectory) }
        workspace.editObjectAtCursor()
        let session = try #require(workspace.objectEditSession)
        workspace.applyObjectEdit(session.object, session: session)
        #expect(!editor.history.canUndo)
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0))
        workspace.editObjectAtCursor()
        #expect(workspace.objectEditSession == nil)
        editor.unmarkText()
    }
}
