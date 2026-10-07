import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import Testing

/// The TextKit 2 manuscript view: guard against TextKit 1, a full session of
/// AppKit features, and precise jumps. VisualLayerFlowTests covers display.
extension WritingFlowTests {
    @Test func textKit2ViewSurvivesAFullEditingSession() async throws {
        let source = "#let note(body) = body\n= Title\n\n*Strong* and _emphasis_ with `code`, 中文 and 😀.\n\n" +
            "#rect(width: 20pt)\n#note[Definition target]\n\n" + String(
                repeating: "== Section\n\nA paragraph that wraps across the writing column more than once. 中文😀\n\n",
                count: 120,
            )
        let app = try WritingFixture(text: source)
        defer { app.close() }
        try await app.ready()
        let editor = try #require(app.workspace.editor)
        #expect(editor.textLayoutManager != nil)
        app.window.makeFirstResponder(editor)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: editor.visibleRect))

        // Typing, Chinese IME and undo.
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.insertText("Q", replacementRange: editor.selectedRange())
        editor.setMarkedText(
            "zhong",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0),
        )
        let marked = editor.firstRect(forCharacterRange: editor.markedRange(), actualRange: nil)
        #expect(marked.width > 0)
        editor.insertText("中", replacementRange: editor.markedRange())
        #expect(editor.string.hasPrefix("#let notQ中e"))
        editor.undoManager?.undo()
        editor.undoManager?.undo()
        #expect(editor.string == source)
        editor.undoManager?.redo()
        editor.undoManager?.undo()
        #expect(app.workspace.text == source)

        // Copy, paste and deletion.
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let strong = (source as NSString).range(of: "*Strong*")
        editor.setSelectedRange(strong)
        let plain = try #require(editor.writablePasteboardTypes.first)
        #expect(editor.writeSelection(to: pasteboard, types: [plain]))
        #expect(pasteboard.string(forType: .string) == "*Strong*")
        editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        #expect(editor.readSelection(from: pasteboard, type: plain))
        editor.deleteBackward(nil)
        editor.undoManager?.undo()
        editor.undoManager?.undo()
        #expect(editor.string == source)

        // Find bar with incremental search highlighting.
        let find = NSMenuItem()
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        editor.performTextFinderAction(find)
        await app.layout()
        let field = try #require(searchField(in: editor.enclosingScrollView?.findBarView))
        field.stringValue = "Section"
        if let action = field.action {
            NSApp.sendAction(action, to: field.target, from: field)
        }
        await app.layout()
        find.tag = NSTextFinder.Action.nextMatch.rawValue
        editor.performTextFinderAction(find)
        await app.layout()
        print("DEBUG find", editor.selectedRange())
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        find.tag = NSTextFinder.Action.hideFindInterface.rawValue
        editor.performTextFinderAction(find)
        editor.isContinuousSpellCheckingEnabled = true
        editor.checkTextInDocument(nil)
        await app.layout()
        editor.isContinuousSpellCheckingEnabled = false
        #expect(editor.accessibilityValue() == source)
        #expect(editor.accessibilityString(for: strong) == "*Strong*")
        #expect(editor.accessibilityFrame(for: strong).width > 0)
        #expect(editor.accessibilityLine(for: strong.location) >= 0)
        _ = editor.accessibilityRange(forLine: 1)
        _ = editor.accessibilityVisibleCharacterRange()
        _ = editor.accessibilityInsertionPointLineNumber()
        editor.appearance = NSAppearance(named: .darkAqua)
        editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        editor.appearance = nil

        // Pointer: hover preparation and command-click.
        try await app.hover(over: "rect")
        try await app.wait { app.workspace.canNavigateSource }
        try app.commandClick("note[")
        try await app.wait { app.workspace.selection.location == (source as NSString).range(of: "note(").location }

        // Reading-style and font changes, navigation, outline and window size.
        app.workspace.styledSource = false
        app.workspace.styledSource = true
        app.workspace.fontSize += 2
        await app.layout()
        for fraction in [0.95, 0.05, 0.6] {
            app.workspace.jump(to: Int(Double(source.utf16.count) * fraction))
            editor.updateOutlineForViewport()
            editor.cacheDisplay(in: editor.visibleRect, to: bitmap)
        }
        #expect(app.workspace.activeOutlineIndex != nil)
        editor.moveToEndOfDocument(nil)
        editor.pageUp(nil)
        editor.selectAll(nil)
        app.window.setContentSize(NSSize(width: 900, height: 700))
        app.workspace.layout = .writing
        await app.layout()
        editor.insertSnippet(Snippet(text: "Snippet "), replacing: NSRange(location: 0, length: 0))
        #expect(editor.visibleCharacterRange() != nil)
        await app.layout()

        #expect(editor.textLayoutManager != nil, "AppKit switched the manuscript view to TextKit 1")
        #expect(!editor.switchedToTextKit1)
    }

    @Test func aLayoutManagerAccessIsDetected() throws {
        let app = try WritingFixture(text: "= Title\n\n*Strong* words.\n", startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        #expect(editor.textLayoutManager != nil)
        // swiftlint:disable:next text_kit_1_layout_manager
        _ = editor.layoutManager
        #expect(editor.switchedToTextKit1)
        #expect(editor.textLayoutManager == nil)
        let log = try String(
            contentsOf: app.workspace.stateDirectory.appendingPathComponent("Logs/events.jsonl"),
            encoding: .utf8,
        )
        #expect(log.contains("editor.textKit1Fallback"))
        app.allowsTextKit1 = true
    }

    @Test func preciseJumpsLandOnDistantTargetsAndHitTestsRoundTrip() async throws {
        let paragraph = "A paragraph with *strong* words, 中文 and 😀 that wraps across the writing column. "
        let source = (0 ..< 1500).map { "== Section \($0)\n\n" + String(repeating: paragraph, count: 3) + "\n\n" }
            .joined()
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        app.window.orderFront(nil)
        await app.layout()
        let editor = try #require(app.workspace.editor)
        let text = source as NSString
        for fraction in [0.1, 0.9, 0.5, 0.99, 0.01, 0.75] {
            let paragraph = text.paragraphRange(for: NSRange(location: Int(Double(text.length) * fraction), length: 0))
            let offset = paragraph.location + min(4, paragraph.length - 2)
            app.workspace.jump(to: offset)
            await app.layout()
            let rect = try #require(editor.characterRect(at: offset))
            let point = NSPoint(x: rect.minX + 1, y: rect.midY)
            #expect(editor.visibleRect.contains(point), "Jump to \(offset) left \(rect) outside \(editor.visibleRect)")
            #expect(editor.characterIndexForInsertion(at: point) == offset)
            let event = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: editor.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0,
            ))
            #expect(editor.sourceOffset(at: event) == offset)
            let visible = try #require(editor.visibleCharacterRange())
            #expect(NSLocationInRange(offset, visible))
        }
        // Past the end of a line and in the margin, no character is under the pointer.
        let line = text.range(of: "== Section 7\n")
        app.workspace.jump(to: line.location)
        await app.layout()
        let end = try #require(editor.characterRect(at: line.location + 11))
        for point in [
            NSPoint(x: end.maxX + 80, y: end.midY),
            NSPoint(x: editor.textContainerOrigin.x - 8, y: end.midY),
        ] {
            let event = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: editor.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: app.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0,
            ))
            #expect(editor.sourceOffset(at: event) == nil)
        }
    }
}

@MainActor
private func searchField(in view: NSView?) -> NSSearchField? {
    guard let view else {
        return nil
    }
    return view as? NSSearchField ?? view.subviews.lazy.compactMap { searchField(in: $0) }.first
}
