import AppKit
@testable import LeftBlankApp
@testable import LeftBlankCore
import Testing

/// Reading styles in the real Mac editor: fonts on the source text, nothing
/// hidden or replaced. `SourceStylingTests` covers the shared styler.
extension WritingFlowTests {
    @Test func theEditorStylesSourceWithFontsAndShowsEveryCharacter() async throws {
        let source = """
        #let item(id, title, s) = [#id #title #s]
        = Title
        == Section

        Text *strong* and _emph_ with `code`.
        #item("LB-001", "标题", "done")
        $φ = (1+√5)/2 ≈ 1.618$
        - item

        """
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        let text = source as NSString
        await app.settle(editor)
        let size = app.workspace.fontSize
        let font = { (substring: String) in
            editor.drawnAttribute(.font, at: text.range(of: substring).location) as? NSFont
        }
        #expect(font("Title")?.pointSize == size + 6)
        #expect(font("Section")?.pointSize == size + 4)
        #expect(font("strong")?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(font("emph")?.fontDescriptor.symbolicTraits.contains(.italic) == true)
        #expect(font("code")?.isFixedPitch == true)
        #expect(font("Text")?.pointSize == size)
        // Every character is laid out as typed: markers, calls and equations.
        for marker in ["= Title", "*strong", "_emph", "`code", "#item", "$φ", "- item", "≈"] {
            let offset = text.range(of: marker).location
            #expect((editor.characterRect(at: offset)?.width ?? 0) > 1, "\(marker) is drawn")
        }
        var attachments = 0
        editor.textStorage?.enumerateAttribute(.attachment, in: NSRange(
            location: 0,
            length: text.length,
        )) { value, _, _ in
            attachments += value == nil ? 0 : 1
        }
        #expect(attachments == 0)
        #expect(editor.subviews.allSatisfy { !String(describing: type(of: $0)).contains("Attachment") })
        #expect(editor.string == source)

        // Reading mode off shows one font; on restores the styles.
        app.workspace.styledSource = false
        try await app.wait { font("Title")?.pointSize == size }
        app.workspace.styledSource = true
        try await app.wait { font("Title")?.pointSize == size + 6 }
    }

    @Test func typingNeverWaitsForTheParser() async throws {
        let paragraph = "A paragraph with *strong* words and `code` that the styles cover.\n\n"
        let source = String(repeating: paragraph, count: 4000)
        let app = try WritingFixture(text: source, startService: false)
        defer { app.close() }
        let editor = try #require(app.workspace.editor)
        let middle = (source as NSString).length / 2
        editor.setSelectedRange(NSRange(location: middle, length: 0))
        await app.settle(editor)
        // An unclosed `$` reparses to the end of the document in the engine.
        var durations: [Duration] = []
        for character in "$ x + y" {
            let start = ContinuousClock.now
            editor.insertText(String(character), replacementRange: editor.selectedRange())
            durations.append(start.duration(to: .now))
        }
        #expect(try #require(durations.max()) < .milliseconds(50), "\(durations)")
        await app.settle(editor)
        #expect(editor.string.utf16.count == source.utf16.count + 7)
    }
}

extension WritingFixture {
    /// Waits for the styles of the current text and lays it out.
    func settle(_ editor: ManuscriptTextView) async {
        await editor.styler?.settled()
        await layout()
        editor.prepareForPointerInteraction()
    }
}
