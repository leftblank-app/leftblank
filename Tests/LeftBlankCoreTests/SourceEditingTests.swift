import Foundation
@testable import LeftBlankCore
import Testing

@Test func documentMetricsFollowUTF16AndUnicodeCharacterBoundaries() {
    for text in ["", "中文😀\r\nCafé\n\n👩‍💻 End\n", "Single line"] {
        let metrics = DocumentMetrics(text)
        #expect(metrics.wordCount == text.filter { !$0.isWhitespace }.count)
        for offset in -1 ... (text.utf16.count + 2) {
            #expect(metrics.position(at: offset) == TextPosition(offset: offset, in: text))
        }
    }
}

@Test func lineIndexHandlesUnicodeMixedLineEndingsAndBoundaryPositions() {
    let source = "中文😀\r\nCafé\r👩‍💻\n\nLast"
    let index = TextLineIndex(source)
    let lines = ["中文😀", "Café", "👩‍💻", "", "Last"]
    let starts = [0, 6, 12, 18, 19]
    for (line, text) in lines.enumerated() {
        // Native and LSP positions use UTF-16, including offsets inside an emoji.
        // The index maps units without silently converting them to Characters.
        for column in 0 ... text.utf16.count {
            let position = TextPosition(line: line, character: column)
            let offset = starts[line] + column
            #expect(index.offset(at: position) == offset)
            #expect(index.position(at: offset) == position)
        }
    }
    #expect(index.position(at: 5) == TextPosition(line: 0, character: 4))
    #expect(index.offset(at: .init(line: 0, character: Int.max)) == 4)
    #expect(index.offset(at: .init(line: Int.max, character: Int.max)) == source.utf16.count)
    #expect(index.offset(at: .init(line: -4, character: -10)) == 0)
    #expect(index.position(at: Int.max) == TextPosition(line: 4, character: 4))
    #expect(TextPosition(line: 2, character: 5).utf8Column(in: source) == 11)
    #expect(TextLineIndex("\r\n").position(at: 2) == TextPosition(line: 1, character: 0))
    #expect(TextLineIndex("").offset(at: .init(line: 0, character: 99)) == 0)
}

@Test func largeOutlineNavigationUsesOneRevisionIndex() {
    let paragraph = "= Chapter 中文😀\r\n\nA paragraph with é and 👩‍💻.\n\n"
    let chapterCount = 12000
    let source = String(repeating: paragraph, count: chapterCount)
    let metrics = DocumentMetrics(source)
    let width = paragraph.utf16.count
    let start = ContinuousClock.now
    var checksum = 0
    // Real outlines provide LSP line/column positions. Resolve the whole batch,
    // then move through it repeatedly as the outline selection changes.
    let headings = (0 ..< chapterCount).map { metrics.offset(at: .init(line: $0 * 4, character: 0)) }
    for chapter in 0 ..< chapterCount {
        let offset = headings[chapter]
        #expect(offset == chapter * width)
        #expect(metrics.position(at: offset) == TextPosition(line: chapter * 4, character: 0))
        checksum += offset
    }
    let duration = start.duration(to: .now)
    print("LEFTBLANK INDEX PERFORMANCE: \(source.utf16.count) UTF16, \(chapterCount) outline positions \(duration)")
    #expect(checksum == width * chapterCount * (chapterCount - 1) / 2)
    #expect(duration < .seconds(2))
    // A new revision must use its own index; old positions remain valid for
    // asynchronous work on the original snapshot and never mutate underneath it.
    let changed = DocumentMetrics("前言😀\r\n" + source)
    #expect(changed.offset(at: .init(line: 1, character: 0)) == 6)
    #expect(metrics.offset(at: .init(line: 0, character: 0)) == 0)
}

@Test func readingStylesRespectCodeMathCommentsAndIncompleteInput() throws {
    let source = """
    = 中文😀标题
    *bold* and _italic_ and `literal *stars*`.
    $ x * y _ z $
    ```typ
    = not a heading
    *not bold*
    ```
    // *comment*
    /* outer /* _nested_ */ *comment* */
    #let example = [
      *code content*
    ]
    plain_word and \\*escaped*.
    """
    let text = source as NSString
    let tree = try #require(SyntaxTree(source))
    let plan = Presentation.plan(
        source: text,
        nodes: tree.nodes() ?? [],
        selection: NSRange(location: text.length, length: 0),
        definitions: FunctionDefinitions(),
    )
    let styled = plan.styles.filter { [.strong, .emphasis, .code].contains($0.style) || $0.style == .heading(level: 1) }
        .map { text.substring(with: $0.range) }
    #expect(styled == ["= 中文😀标题", "*bold*", "_italic_", "`literal *stars*`",
                       "```typ\n= not a heading\n*not bold*\n```", "*code content*"])
    for unfinished in ["```\n*unfinished*", "$ unfinished *bold*", "/* *comment*", "* unfinished ",
                       "Text ``literal ` code`` after"]
    {
        let nodes = try #require(SyntaxTree(unfinished)?.nodes())
        let plan = Presentation.plan(
            source: unfinished as NSString,
            nodes: nodes,
            selection: NSRange(location: 0, length: 0),
            definitions: FunctionDefinitions(),
        )
        #expect(!plan.styles.contains { $0.style == .strong }, "\(unfinished)")
    }
    let blocks = CodeBlockHighlighting.codeBlocks(in: source + "```python\nprint(42)")
    #expect(blocks.map(\.language) == ["typ", "python"])
    #expect(text.substring(with: blocks[0].contentRange) == "= not a heading\n*not bold*\n")
    #expect(blocks[1].contentRange.length == "print(42)".utf16.count)
}

@Test func lineEditingPreservesSelectionBoundariesAndUnicode() throws {
    let source = "中文😀\n  second\nthird\n"
    let selected = NSRange(location: 0, length: "中文😀\n  second\n".utf16.count)
    let indent = TextEditing.lines(.indent, text: source, selection: selected)
    let indented = try TextEditing.applying([indent], to: source)
    #expect(indented == "  中文😀\n    second\nthird\n")
    let outdent = TextEditing.lines(
        .outdent,
        text: indented,
        selection: NSRange(location: 0, length: indent.text.utf16.count),
    )
    #expect(try TextEditing.applying([outdent], to: indented) == source)
    let comment = TextEditing.lines(.comment, text: source, selection: selected)
    #expect(comment.text == "// 中文😀\n  // second\n")
    let commented = try TextEditing.applying([comment], to: source)
    let uncomment = TextEditing.lines(
        .comment,
        text: commented,
        selection: NSRange(location: 0, length: comment.text.utf16.count),
    )
    #expect(try TextEditing.applying([uncomment], to: commented) == source)
    #expect(TextEditing.lines(.outdent, text: "\tx", selection: NSRange(location: 0, length: 0)).text == "x")
    #expect(TextEditing.lines(.outdent, text: " x", selection: NSRange(location: 0, length: 0)).text == "x")
    #expect(TextEditing.lines(.comment, text: "// a\n  \n//b", selection: NSRange(location: 0, length: 12))
        .text == "a\n  \nb")
    #expect(TextEditing.lines(.indent, text: "", selection: NSRange(location: 200, length: 0)).text == "  ")
    #expect(try TextEditing.applying(
        [.init(range: NSRange(location: 0, length: 1), text: "A"), .init(
            range: NSRange(location: 2, length: 1),
            text: "C",
        )],
        to: "abc",
    ) == "AbC")
    #expect(throws: CommandError.self) { try TextEditing.applying(
        [.init(range: NSRange(location: 99, length: 1), text: "x")],
        to: "abc",
    ) }
    #expect(throws: CommandError.self) { try TextEditing.applying(
        [.init(range: NSRange(location: 0, length: 3), text: "x"), .init(
            range: NSRange(location: 2, length: 1),
            text: "y",
        )],
        to: "abc",
    ) }
}

@Test func nativeEditMetricsPreserveUnicodeAndMixedNewlinesAcrossTransactions() {
    var text = "Title\r\n中文😀 Café\n👩‍💻 end\rLast\n"
    var metrics = DocumentMetrics(text)
    let fragments = ["", "\n", "\r", "\r\n", "e", "\u{301}", "👩", "\u{200D}", "💻", "中文", " ", "a\n\nb"]
    for step in 0 ..< 240 {
        let ns = text as NSString
        let boundaries = text.indices.map { $0.utf16Offset(in: text) } + [ns.length]
        let index = (step * 17) % boundaries.count
        let start = boundaries[index]
        let end = boundaries[min(index + (step % 3), boundaries.count - 1)]
        let edit = TextReplacement(
            range: NSRange(location: start, length: end - start),
            text: fragments[step % fragments.count],
        )
        let applied = metrics.apply(edit, to: text)
        #expect(applied)
        text = ns.replacingCharacters(in: edit.range, with: edit.text)
        let expected = DocumentMetrics(text)
        #expect(metrics.wordCount == expected.wordCount, "Transaction \(step), \(text.debugDescription)")
        for offset in 0 ... text.utf16.count {
            #expect(
                metrics.position(at: offset) == expected.position(at: offset),
                "Transaction \(step) offset \(offset)",
            )
        }
        for line in 0 ... (text.utf16.count + 1) {
            #expect(metrics.offset(at: .init(line: line, character: 99)) == expected.offset(at: .init(
                line: line,
                character: 99,
            )))
        }
    }
}

@Test func textIdentityComparesUTF16Literally() {
    #expect(TextIdentity.equal("中文😀\r\n", "中文😀\r\n"))
    #expect(!TextIdentity.equal("e\u{301}", "\u{E9}"), "Canonically equivalent text is still a different source")
    #expect(!TextIdentity.equal("abc", "abd"))
    #expect(!TextIdentity.equal("abc", "abcd"))
}
