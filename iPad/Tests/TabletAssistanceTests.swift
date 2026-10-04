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
}
