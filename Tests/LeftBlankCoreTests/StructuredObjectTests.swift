import Foundation
import LeftBlankCore
import Testing

struct StructuredObjectTests {
    @Test func insertionTablesRemainEditableAndPreserveSurroundingUnicode() throws {
        let inserted = try TypstInsertion.make("table", values: ["columns": "2", "rows": "2"]).text
        let source = "中文😀\n" + inserted + "\nKeep this comment // unchanged\n"
        var object = try #require(StructuredObject.at(NSRange(location: 10, length: 0), in: source))
        #expect(object.kind == .table)
        #expect(object.hasHeader)
        #expect(object.rows.count == 3)
        #expect(try object.replacement(in: source).text == inserted, "No-op edits preserve exact formatting")
        object.rows[1][0] = "A [nested] cell, 中文😀"
        for row in object.rows.indices {
            object.rows[row].append("New")
        }
        object.alignment = "center"
        let changed = try TextEditing.applying([object.replacement(in: source)], to: source)
        #expect(changed.hasPrefix("中文😀\n#table("))
        #expect(changed.hasSuffix("\nKeep this comment // unchanged\n"))
        let parsed = try #require(StructuredObject.at(NSRange(location: 10, length: 0), in: changed))
        #expect(parsed.rows[1][0] == "A [nested] cell, 中文😀")
        #expect(parsed.rows[0].count == 3)
        #expect(parsed.alignment == "center")
    }

    @Test func insertedImageCanChangeResourceWidthCaptionAndAlignment() throws {
        let source = try TypstInsertion.make("image", values: ["path": "images/old.png", "caption": "Old"]).text
        var object = try #require(StructuredObject.at(NSRange(location: 2, length: 0), in: source))
        object.path = "images/new \"quote\" 中文.png"
        object.width = "42mm"
        object.caption = "A quote: \"yes\"\nNew line"
        object.alignment = "right"
        let edited = try object.replacement(in: source).text
        let parsed = try #require(StructuredObject.at(NSRange(location: 3, length: 0), in: edited))
        #expect(parsed.path == object.path)
        #expect(parsed.width == "42mm")
        #expect(parsed.caption == object.caption)
        #expect(parsed.alignment == "right")
    }

    @Test func unsupportedObjectsAndLexicallyHiddenObjectsAreRejected() {
        for source in [
            "#table(columns: 2, ..rows)", "#table(columns: 2, [One])",
            "#table(columns: 2, table.cell(colspan: 2)[Span])",
            "#table(columns: (1fr, 2fr), [A], [B])",
            "#table(columns: 1, /* note */ [A])",
            "#image(path, width: 80%)", "#image(\"a.png\", width: measure())",
            "#figure(image(\"a.png\"), caption: [Rich caption])",
            "`#image(\"a.png\")`", "```typ\n#image(\"a.png\")\n```",
            "// #image(\"a.png\")", "/* nested /* inner */ #image(\"a.png\") */",
        ] {
            #expect(StructuredObject.at(NSRange(location: source.utf16.count / 2, length: 0), in: source) == nil)
        }
    }

    @Test func tablePasteIsRectangularAndEscapesExecutableSyntax() throws {
        let source = "#table(columns: 1, [A])"
        var object = try #require(StructuredObject.at(NSRange(location: 2, length: 0), in: source))
        try object.pasteTable("Name\tValue\r\n#read(\"secret\")\t[abc]\r\n")
        #expect(object.rows == [["Name", "Value"], ["\\#read(\\\"secret\\\")", "\\[abc\\]"]])
        let rendered = try object.replacement(in: source).text
        #expect(StructuredObject.at(NSRange(location: 2, length: 0), in: rendered)?.rows == object.rows)
        #expect(throws: ObjectEditError.self) { try object.pasteTable("a\tb\nc") }
        object.rows[0][0] = "] #read(\"secret\") ["
        #expect(throws: ObjectEditError.self) { try object.replacement(in: source) }
    }

    @Test func pastedMarkupRemainsLiteralAndCanBeReopened() throws {
        let source = "#table(columns: 1, [A])"
        var object = try #require(StructuredObject.at(NSRange(location: 2, length: 0), in: source))
        try object.pasteTable("= Heading\n- Item\n// comment\nAn unmatched \"quote")
        #expect(object.rows[0][0] == "\\= Heading")
        #expect(object.rows[1][0] == "\\- Item")
        #expect(object.rows[2][0] == "\\/\\/ comment")
        let updated = try object.replacement(in: source).text
        #expect(StructuredObject.at(NSRange(location: 2, length: 0), in: updated)?.rows == object.rows)
    }

    @Test func staleObjectAndInvalidWidthCannotOverwriteSource() throws {
        let source = "#image(\"a.png\", width: 80%)"
        var object = try #require(StructuredObject.at(NSRange(location: 2, length: 0), in: source))
        #expect(throws: ObjectEditError.self) { try object.replacement(in: "Changed" + source) }
        object.width = "80%); read(\"secret\")"
        #expect(throws: ObjectEditError.self) { try object.replacement(in: source) }
    }

    @Test func quotesInMarkupArePlainTextAndCodeStringsStayOpaque() throws {
        let table = #"#table(columns: 2, [Model], [Size], [A], [13"], [B], [15"])"#
        for prose in ["", #"A 13" screen. "#, #"Two "quoted" words. "#] {
            let source = prose + table
            let object = try #require(StructuredObject.at(
                NSRange(location: prose.utf16.count + 3, length: 0),
                in: source,
            ))
            #expect(object.rows == [["Model", "Size"], ["A", #"13""#], ["B", #"15""#]])
        }
        let odd = try #require(StructuredObject.at(
            NSRange(location: 3, length: 0),
            in: #"#table(columns: 2, [A], [13"], [B], [x])"#,
        ))
        #expect(odd.rows == [["A", #"13""#], ["B", "x"]])
        let nested = try #require(StructuredObject.at(
            NSRange(location: 3, length: 0),
            in: #"#table(columns: 1, [#text("]")], [b])"#,
        ))
        #expect(nested.rows == [[#"#text("]")"#], ["b"]])
        for (prefix, path) in [
            (#"He said "hi. "#, "a.png"), (#"#text("a\"b") "#, "b.png"),
            (#"#let note = [#image("c.png")]"# + "\n", "c.png"),
            (#"#let s = "13\" (["; #text("]") "# + "\n", "d.png"),
        ] {
            let source = prefix + #"#image("\#(path)")"#
            let object = StructuredObject.at(NSRange(location: source.utf16.count - 3, length: 0), in: source)
            #expect(object?.path == path, "\(source)")
        }
        let escaped = try #require(StructuredObject.at(NSRange(location: 2, length: 0), in: #"#image("a\"].png")"#))
        #expect(escaped.path == #"a"].png"#)
        // Strings that span cell delimiters, statements in cells, and code strings are never parsed as objects.
        for source in [
            #"#table(columns: 2, [#"a], [b"])"#, #"#table(columns: 2, [$"], ["$])"#,
            #"#table(columns: 1, [#let x = "]"])"#, ##"#let s = "#image(\"a.png\")""##,
        ] {
            #expect(StructuredObject.at(NSRange(location: source.utf16.count - 4, length: 0), in: source) == nil)
        }
    }

    @Test func quoteTypedIntoCellAppliesAndDeletionsKeepEveryCell() throws {
        let source = "#table(columns: 1, [A])"
        var typed = try #require(StructuredObject.at(NSRange(location: 2, length: 0), in: source))
        typed.rows[0][0] = #"13" "wide""#
        let applied = try typed.replacement(in: source).text
        #expect(StructuredObject.at(NSRange(location: 2, length: 0), in: applied)?.rows == [[#"13" "wide""#]])
        let table = #"#table(columns: 2, [Model], [Size], [A], [13"], [B], [15"])"#
        let original = try #require(StructuredObject.at(NSRange(location: 3, length: 0), in: table))
        var column = original
        for row in column.rows.indices {
            column.rows[row].remove(at: 1)
        }
        let narrowed = try TextEditing.applying([column.replacement(in: table)], to: table)
        #expect(StructuredObject.at(NSRange(location: 3, length: 0), in: narrowed)?.rows == [["Model"], ["A"], ["B"]])
        var row = original
        row.rows.remove(at: 1)
        let shortened = try TextEditing.applying([row.replacement(in: table)], to: table)
        #expect(StructuredObject.at(NSRange(location: 3, length: 0), in: shortened)?.rows
            == [["Model", "Size"], ["B", #"15""#]])
    }

    @Test func attachedContentBlockKeepsTheCallInSourceMode() throws {
        let source = "#table(columns: 1, [a])[b]"
        for location in [3, source.utf16.count - 2] {
            #expect(StructuredObject.at(NSRange(location: location, length: 0), in: source) == nil)
        }
        let spaced = "#table(columns: 1, [a]) [b]"
        #expect(StructuredObject.at(NSRange(location: 3, length: 0), in: spaced)?.rows == [["a"]])
        let wrapped = "#align(center)[#table(columns: 1, [a])]"
        #expect(StructuredObject.at(NSRange(location: 3, length: 0), in: wrapped) == nil)
        let inner = try #require(StructuredObject.at(NSRange(location: 20, length: 0), in: wrapped))
        #expect(inner.range == NSRange(location: 15, length: 23))
        #expect(inner.rows == [["a"]])
    }
}
