import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func longManuscriptTypingUndoAndIdleStylingKeepTheViewportStable() async throws {
        let source = String(
            repeating: "= Chapter\n\nA paragraph with *strong*, _emphasis_ and `code`. 中文😀\n\n",
            count: 1500,
        ) + "Writing here\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        editor.setSelectedRange(NSRange(location: source.utf16.count - 1, length: 0))
        editor.highlight()
        editor.reveal(editor.selectedRange())
        let edits = try StorageEditRecorder(#require(editor.textStorage))
        var durations: [Duration] = []
        editor.breakUndoCoalescing()
        editor.undoManager?.beginUndoGrouping()
        for _ in 0 ..< 30 {
            let start = ContinuousClock.now
            editor.insertText("a", replacementRange: editor.selectedRange())
            _ = app.workspace.position
            _ = app.workspace.wordCount
            durations.append(start.duration(to: .now))
            try await Task.sleep(for: .milliseconds(20))
        }
        editor.undoManager?.endUndoGrouping()
        let selection = editor.selectedRange()
        let origin = editor.enclosingScrollView?.contentView.bounds.origin
        edits.ranges.removeAll()
        try await Task.sleep(for: .milliseconds(250))
        #expect(edits.ranges.isEmpty, "Idle styling must not invalidate unchanged paragraphs")
        #expect(editor.selectedRange() == selection)
        #expect(editor.enclosingScrollView?.contentView.bounds.origin == origin)
        let p95 = durations.sorted()[28]
        print("LEFTBLANK TYPING: \(source.utf16.count) UTF16, 30 native edits including metrics, p95 \(p95)")
        #expect(p95 < .milliseconds(100), "Broad CI budget; track the measured local frame cost")
        editor.undoManager?.undo()
        #expect(editor.string == source)
        #expect(app.workspace.text == source)
        editor.undoManager?.redo()
        #expect(editor.string.contains(String(repeating: "a", count: 30)))
        #expect(editor.string == app.workspace.text)
    }

    @Test func nestedSchemeGrammarKeepsTheSpecificKeywordColor() async throws {
        let source = "= Scheme\n\n```scheme\n(define (square x) (* x x))\n```\n"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        try await app.wait { app.workspace.syntaxSnapshot?.source == source }
        let editor = try #require(app.workspace.editor)
        let keyword = (source as NSString).range(of: "define").location
        #expect(
            editorColor(editor, at: keyword) == Theme.sourceFunction,
            "An outer name span must not overwrite its nested built-in token",
        )
    }

    @Test func continuousTypingKeepsSemanticColorsAndDoesNotRestyleTheDocument() async throws {
        let source = "= Stable writing\n\n```python\ntotal = sum(range(1, 11))\nprint(total)\n```\n\nWrite here\n"
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        try await app.wait { app.workspace.syntaxSnapshot?.source == source }
        let editor = try #require(app.workspace.editor)
        let storage = try #require(editor.textStorage)
        let sum = (source as NSString).range(of: "sum").location
        let expected = editorColor(editor, at: sum)
        #expect(expected == Theme.sourceFunction)
        let edits = StorageEditRecorder(storage)
        editor.setSelectedRange(NSRange(location: source.utf16.count - 1, length: 0))
        editor.highlight()
        for character in " gently 中文😀" {
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            let selection = editor.selectedRange()
            let origin = editor.enclosingScrollView?.contentView.bounds.origin
            edits.ranges.removeAll()
            editor.highlight()
            #expect(edits.ranges.isEmpty, "Typing in plain text must not rewrite document attributes: \(edits.ranges)")
            #expect(editorColor(editor, at: sum) == expected, "Keep semantic colors while the next result is pending")
            #expect(editor.selectedRange() == selection)
            #expect(editor.enclosingScrollView?.contentView.bounds.origin == origin)
        }
        edits.ranges.removeAll()
        let finalSource = editor.string
        try await app.wait { app.workspace.syntaxSnapshot?.source == finalSource }
        #expect(edits.ranges.isEmpty, "Semantic replies must not edit text storage or trigger reflow")
        #expect(editorColor(editor, at: sum) == expected)
        #expect(app.workspace.text == finalSource)
    }
}

@MainActor
func editorColor(_ editor: ManuscriptTextView, at offset: Int) -> NSColor? {
    editor.drawnColor(at: offset)
}

@MainActor
private final class StorageEditRecorder: NSObject {
    var ranges: [NSRange] = []
    init(_ storage: NSTextStorage) {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(record(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: storage,
        )
    }

    @objc private func record(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
              storage.editedMask.contains(.editedAttributes)
        else {
            return
        }
        ranges.append(storage.editedRange)
    }
}
