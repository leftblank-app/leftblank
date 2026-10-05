import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func automaticCompletionKeepsFocusSupportsTabAndUndo() async throws {
        let app = try WritingFixture(text: "#rec")
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        app.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.scheduleTypingAssistance()
        try await app.wait { editor.typingList.items.contains { $0.label.hasPrefix("rect") } }
        try await app.wait { editor.typingTask == nil }
        #expect(editor.typingPanel != nil)
        #expect(app.window.firstResponder === editor)
        #expect(editor.string == "#rec")
        let index = try #require(editor.typingList.items.firstIndex { $0.label.hasPrefix("rect") })
        editor.typingList.move(index)
        #expect(editor.handleTypingKey(app.key("\t", code: 48)))
        #expect(editor.string.hasPrefix("#rect"))
        #expect(app.workspace.text == editor.string)
        editor.undoManager?.undo()
        #expect(editor.string == "#rec")
        #expect(app.workspace.text == "#rec")
        // Native undo selects the restored text. Automatic suggestions need a caret.
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.scheduleTypingAssistance()
        try await app.wait { !editor.typingList.items.isEmpty }
        #expect(editor.handleTypingKey(app.key("\u{1b}", code: 53)))
        #expect(editor.typingPanel == nil)
        #expect(editor.string == "#rec")
    }

    @Test func automaticParameterHelpAndCompositionRejectStaleCandidates() async throws {
        let source = "#rect(\n  width: 20pt,\n  height: 30pt)"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        let range = (source as NSString).range(of: "width: ")
        editor.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
        editor.scheduleTypingAssistance()
        try await app.wait { editor.typingSignature?.activeParameter == "width:" }
        #expect(editor.string == source)
        editor.insertSnippet(Snippet(text: "#rec"), replacing: NSRange(location: 0, length: source.utf16.count))
        editor.scheduleTypingAssistance()
        try await app.wait { !editor.typingList.items.isEmpty }
        let stale = try #require(editor.typingList.selected)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.acceptTypingCompletion(stale)
        #expect(editor.string == "#rec")
        editor.setMarkedText(
            "中文",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: 0, length: 0),
        )
        editor.scheduleTypingAssistance()
        #expect(editor.typingPanel == nil)
        #expect(editor.typingTask == nil)
        #expect(!editor.handleTypingKey(app.key("\t", code: 48)))
        editor.unmarkText()
    }

    @Test func escapeReachesPlaceholdersWhileAssistanceIsInvisible() async throws {
        let app = try WritingFixture(text: "#rect(width: 1pt)", startService: false)
        defer { app.close() }
        await app.layout()
        let editor = try #require(app.workspace.editor)
        app.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 17, length: 0))
        editor.scheduleTypingAssistance()
        #expect(editor.typingTask != nil)
        #expect(!editor.handleTypingKey(app.key("\u{1b}", code: 53)), "A pending request must not consume Escape")
        #expect(editor.typingTask == nil)
        // After a snippet is accepted, the first Escape leaves its placeholder.
        editor.setCompletionPlaceholders([NSRange(location: 13, length: 3)])
        editor.setSelectedRange(NSRange(location: 13, length: 3))
        editor.typingTask = Task {}
        editor.keyDown(with: app.key("\u{1b}", code: 53))
        #expect(editor.selectedRange() == NSRange(location: 16, length: 0))
        #expect(editor.string == "#rect(width: 1pt)")
    }
}
