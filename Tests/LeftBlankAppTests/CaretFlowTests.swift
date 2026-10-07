import AppKit
@testable import LeftBlankApp
import LeftBlankCore
import Testing

extension WritingFlowTests {
    @Test func mouseHitTestingMatchesVisibleGlyphsAcrossLayoutsAndStyles() async throws {
        let source =
            "= A quiet title\n\nWrite the idea, show the code, explain the result.\n\n*Strong words* beside plain words. 中文与 emoji 😀 stay aligned.\n\n" +
            String(
                repeating: "A long paragraph wraps naturally across the writing area. ",
                count: 15,
            ) + "\n"
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        for layout in [EditorLayout.writing, .split] {
            app.workspace.layout = layout
            for width in [1220.0, 1720.0, 900.0] {
                app.window.setContentSize(NSSize(width: width, height: 820))
                await app.layout()
                for needle in ["quiet", "show", "explain", "words", "中文", "naturally"] {
                    editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
                    editor.highlight()
                    let range = (source as NSString).range(of: needle)
                    editor.reveal(range)
                    let screenRect = editor.firstRect(
                        forCharacterRange: NSRange(location: range.location, length: 0),
                        actualRange: nil,
                    )
                    let windowPoint = app.window.convertFromScreen(NSRect(
                        x: screenRect.minX + 1,
                        y: screenRect.midY,
                        width: 0,
                        height: 0,
                    )).origin
                    let point = editor.convert(windowPoint, from: nil)
                    let hit = editor.characterIndexForInsertion(at: point)
                    #expect(
                        abs(hit - range.location) <= 1,
                        "\(layout) width \(width), \(needle), expected \(range.location) hit \(hit); inset \(editor.textContainerInset), rect \(screenRect), point \(point)",
                    )
                    let hitView = try app.window.contentView?.hitTest(#require(app.window.contentView?.convert(
                        windowPoint,
                        from: nil,
                    )))
                    #expect(hitView === editor, "Mouse hit routed to \(String(describing: hitView))")
                    editor.setSelectedRange(NSRange(location: hit, length: 0))
                    try await Task.sleep(for: .milliseconds(150))
                    #expect(
                        abs(editor.selectedRange().location - range.location) <= 1,
                        "\(layout) width \(width), \(needle), selected \(editor.selectedRange()) expected \(range.location)",
                    )
                }
            }
        }
    }
}

extension WritingFlowTests {
    @Test func editableTextUsesIBeamAndPreservesCompositionDuringRestyling() throws {
        let app = try WritingFixture(text: "= Title\n\n中文 input\n", startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        let event = app.key("", code: 0)
        NSCursor.arrow.set()
        editor.cursorUpdate(with: event)
        #expect(NSCursor.current == NSCursor.iBeam)
        editor.setSelectedRange(NSRange(location: 10, length: 0))
        editor.setMarkedText(
            "输入",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: editor.selectedRange(),
        )
        editor.prepareForPointerInteraction()
        editor.highlight()
        #expect(editor.hasMarkedText())
        editor.unmarkText()
        NSCursor.arrow.set()
    }
}
