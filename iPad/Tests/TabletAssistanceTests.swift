import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import LeftBlankTestSupport
import Testing
import UIKit

@MainActor
private final class AssistancePurchaseService: TabletPurchaseService {
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
private final class AssistanceEditor: UITextView {
    let history = UndoManager()
    override var undoManager: UndoManager? {
        history
    }
}

@Suite(.serialized)
@MainActor
struct TabletAssistanceTests {
    private func fixture() async throws
        -> (TabletWorkspace, AssistanceEditor, AssistancePurchaseService, SourceCompletion)
    {
        let service = AssistancePurchaseService()
        let subscription = TabletSubscription(service: service)
        await subscription.refresh()
        let root = TestPaths.temporaryDirectory.appendingPathComponent("assistance-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = TabletWorkspace(subscription: subscription, stateDirectory: root)
        let editor = AssistanceEditor()
        workspace.editor = editor
        workspace.text = "#rec"
        workspace.activeSourceURL = URL(fileURLWithPath: "/completion-fixture.typ")
        workspace.selection = NSRange(location: 4, length: 0)
        editor.text = workspace.text
        editor.selectedRange = workspace.selection
        let response: JSONValue = .array([.object([
            "label": .string("rect()"), "textEdit": .object([
                "newText": .string("rect()"), "range": .object([
                    "start": .object(["line": .number(0), "character": .number(1)]),
                    "end": .object(["line": .number(0), "character": .number(4)]),
                ]),
            ]),
        ])])
        let completion = try #require(LanguageAssistance.completions(
            response,
            source: workspace.text,
            selection: workspace.selection,
        ).first)
        workspace.assistance.snapshot = try .init(
            source: workspace.text,
            url: #require(workspace.sourceURL),
            version: workspace.version,
            generation: workspace.generation,
            selection: workspace.selection,
        )
        workspace.assistance.completions = [completion]
        return (workspace, editor, service, completion)
    }

    @Test func completionUpdatesModelAndUndoesAsOneEdit() async throws {
        let (workspace, editor, _, completion) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.stateDirectory) }
        editor.history.beginUndoGrouping()
        workspace.applyCompletion(completion)
        editor.history.endUndoGrouping()
        #expect(workspace.text == "#rect()")
        #expect(editor.text == workspace.text)
        #expect(workspace.selection == NSRange(location: 7, length: 0))
        #expect(editor.history.canUndo)
        editor.history.undo()
        #expect(workspace.text == "#rec")
        #expect(workspace.selection == NSRange(location: 4, length: 0))
        #expect(editor.text == workspace.text)
    }

    @Test func completionRejectsMovedCaretAndReplacedSession() async throws {
        let (workspace, editor, _, completion) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.stateDirectory) }
        workspace.selection = NSRange(location: 0, length: 0)
        workspace.applyCompletion(completion)
        #expect(workspace.text == "#rec" && editor.text == "#rec")
        workspace.selection = NSRange(location: 4, length: 0)
        workspace.generation = UUID()
        workspace.applyCompletion(completion)
        #expect(workspace.text == "#rec" && editor.text == "#rec")
        #expect(!editor.history.canUndo)
    }

    @Test func completionRejectsExpiredAccessAfterResultsArrive() async throws {
        let (workspace, editor, service, completion) = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.stateDirectory) }
        service.access = .expired
        await workspace.subscription.refresh()
        workspace.applyCompletion(completion)
        #expect(workspace.text == "#rec" && editor.text == "#rec")
        #expect(workspace.panel == .subscription)
        #expect(!editor.history.canUndo)
    }

    @Test func embeddedHelpActionsDefinitionAndPreviewUseCurrentSource() async throws {
        let (workspace, editor, _, _) = try await fixture()
        defer {
            workspace.client.stop()
            try? FileManager.default.removeItem(at: workspace.stateDirectory)
        }
        let source = "#let answer = 42\n#answer\n#rect(width: 20pt, height: 30pt)\n== Heading\n"
        let document = try await workspace.library.create(text: source)
        // The fixture has no document yet; opening must not try to save its synthetic completion URL.
        workspace.activeSourceURL = nil
        await workspace.open(document)
        #expect(workspace.serviceReady)
        let keyboard = TabletTextView()
        keyboard.workspace = workspace
        func invoke(_ name: String) throws {
            let key = try #require(keyboard.keyCommands?.first { $0.action.map(NSStringFromSelector) == name })
            let action = try #require(key.action)
            #expect(keyboard.canPerformAction(action, withSender: key))
            keyboard.perform(action)
        }
        func select(_ line: Int, _ character: Int) {
            let offset = TextPosition(line: line, character: character).offset(in: workspace.text)
            workspace.selection = NSRange(location: offset, length: 0)
            editor.selectedRange = workspace.selection
        }
        select(2, 3)
        try invoke("explainSource")
        await workspace.assistance.task?.value
        #expect(workspace.assistance.hover?.text.lowercased().contains("rectangle") == true)
        select(2, 12)
        try invoke("explainSource")
        await workspace.assistance.task?.value
        #expect(workspace.assistance.signature?.activeParameter == "width:")
        select(3, 4)
        try invoke("sourceActions")
        await workspace.assistance.task?.value
        let action = try #require(workspace.assistance.actions.first { $0.title == "Increase depth of heading" })
        editor.history.beginUndoGrouping()
        workspace.applyContextAction(action)
        editor.history.endUndoGrouping()
        #expect(workspace.text.contains("\n=== Heading\n"))
        editor.history.undo()
        #expect(workspace.text == source)
        select(1, 3)
        let origin = workspace.selection
        try invoke("definition")
        await workspace.assistance.task?.value
        #expect(workspace.navigationHistory.count == 1)
        #expect(workspace.selection.location < origin.location)
        try invoke("back")
        for _ in 0 ..< 100 where !workspace.navigationHistory.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(workspace.navigationHistory.isEmpty)
        #expect(workspace.selection == origin)
        workspace.previewReady = false
        workspace.layout = .writing
        workspace.revealPreview()
        #expect(workspace.assistance.pendingPreview != nil)
        #expect(workspace.layout == .preview)
        workspace.previewReady = true
        workspace.serviceStatus = "Ready"
        workspace.sendPendingPreviewNavigation()
        #expect(workspace.assistance.pendingPreview == nil)
        workspace.previewReady = false
        workspace.revealPreview()
        workspace.version += 1
        workspace.sendPendingPreviewNavigation()
        #expect(workspace.assistance.pendingPreview == nil)
        workspace.layout = .writing
        workspace.replace("#rec")
        editor.selectedRange = NSRange(location: 4, length: 0)
        workspace.selection = editor.selectedRange
        try invoke("completeSource")
        await workspace.assistance.task?.value
        #expect(workspace.assistance.completions.contains { $0.label.hasPrefix("rect") })
    }

    @Test func projectImportRequiresAnEntryAndRejectsPathsOutsideTheProject() async throws {
        let (workspace, editor, _, _) = try await fixture()
        defer {
            withExtendedLifetime(editor) {}
            workspace.client.stop()
            try? FileManager.default.removeItem(at: workspace.stateDirectory)
        }
        workspace.activeSourceURL = nil
        let folder = workspace.stateDirectory.appendingPathComponent("Import")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entry = folder.appendingPathComponent("book.typ")
        let chapter = folder.appendingPathComponent("chapter.typ")
        try Data("#include \"chapter.typ\"".utf8).write(to: entry)
        try Data("A chapter".utf8).write(to: chapter)
        await workspace.importProject(folder)
        #expect(workspace.panel == .projectEntry)
        #expect(workspace.importSources == [entry, chapter])
        #expect(workspace.importSourceLabel(entry) == "book.typ")
        workspace.cancelProjectImport()
        #expect(workspace.importSources.isEmpty)
        #expect(workspace.importSourceLabel(entry) == "book.typ")
        await workspace.importProject(folder)
        await workspace.finishProjectImport(workspace.stateDirectory.appendingPathComponent("outside.typ"))
        #expect(workspace.document == nil)
        #expect(workspace.message != nil)
        await workspace.importProject(folder)
        await workspace.finishProjectImport(entry)
        #expect(workspace.entryURL?.lastPathComponent == "book.typ")
        #expect(workspace.text == "#include \"chapter.typ\"")
        #expect(workspace.importSources.isEmpty && workspace.panel == nil)
        #expect(workspace.serviceReady)
    }
}
