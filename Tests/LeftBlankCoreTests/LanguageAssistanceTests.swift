import Foundation
@testable import LeftBlankCore
import LeftBlankTestSupport
import Testing

private let assistanceURL = URL(fileURLWithPath: "/Volumes/SSD/Developer/Codex/tmp/中文 notes.typ")

private func assistanceJSON(_ value: Any) throws -> JSONValue {
    try JSONDecoder().decode(
        JSONValue.self,
        from: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed),
    )
}

private func assistanceEdit(_ start: (Int, Int), _ end: (Int, Int), _ text: String) -> [String: Any] {
    [
        "range": ["start": ["line": start.0, "character": start.1], "end": ["line": end.0, "character": end.1]],
        "newText": text,
    ]
}

private func assistanceAction(_ edits: [[String: Any]], uri: String = assistanceURL.absoluteString) -> [String: Any] {
    ["title": "Rewrite", "kind": "refactor.rewrite", "isPreferred": true, "edit": ["changes": [uri: edits]]]
}

@Test func languageAssistanceDocumentationIsInertReadableText() throws {
    let result = try LanguageAssistance.hover(assistanceJSON(["contents": [
        ["language": "typst", "value": "rect(width: length) -> content"],
        [
            "kind": "markdown",
            "value": "# Rectangle\n\nA **shape** with [width](https://typst.app/docs).\n\n![image](https://example.com/image.png)\n<img src='https://example.com/pixel'>\n<script>alert(1)</script>\n\n```typst\n#rect(width: 2cm)\n```",
        ],
        "Second paragraph.",
    ]]))
    let text = try #require(result?.text)
    #expect(text.contains("rect(width: length) -> content"))
    #expect(text.contains("Rectangle\n\nA shape with width."))
    #expect(text.contains("#rect(width: 2cm)"))
    #expect(text.contains("Second paragraph."))
    #expect(!text.contains("https://") && !text.contains("<img") && !text.contains("alert"))
    #expect(LanguageAssistance.hover(.null) == nil)
    #expect(try LanguageAssistance.documentation(assistanceJSON([
        "kind": "plaintext",
        "value": "x < y and **literal**",
    ])) == "x < y and **literal**")
    #expect(try LanguageAssistance.documentation(assistanceJSON(["contents": "wrong shape"])).isEmpty)
    #expect(LanguageAssistance.documentation(.string(String(repeating: "a", count: 20000))).count == 8000)
}

@Test func languageAssistanceSignatureSelectsParameterAndUTF16Offsets() throws {
    let response = try assistanceJSON([
        "activeSignature": 1, "activeParameter": 0,
        "signatures": [["label": "unused()"], [
            "label": "f(😀, size: length)", "documentation": ["kind": "markdown", "value": "A **function**."],
            "activeParameter": 1,
            "parameters": [["label": "😀"], ["label": [6, 18], "documentation": "The size."]],
        ]],
    ])
    let signature = try #require(LanguageAssistance.signatureHelp(response))
    #expect(signature.label == "f(😀, size: length)")
    #expect(signature.activeParameter == "size: length")
    #expect(signature.parameterDocumentation == "The size.")
    #expect(signature.documentation == "A function.")
    #expect(LanguageAssistance.signatureHelp(.null) == nil)
    let invalid = try assistanceJSON([
        "activeSignature": 8,
        "signatures": [["label": "f(😀)", "parameters": [["label": [2, 3]]]]],
    ])
    #expect(LanguageAssistance.signatureHelp(invalid)?.activeParameter == nil)
    let simple = try assistanceJSON(["signatures": [["label": "f(x)", "parameters": [["label": "x"]]]]])
    #expect(LanguageAssistance.signatureHelp(simple)?.activeParameter == "x")
}

@Test func languageAssistanceActionsApplyUnicodeCRLFAndVersionedEdits() throws {
    let source = "中文😀\r\n= Heading\r\n$x$\r\n"
    let response = try assistanceJSON([assistanceAction([
        assistanceEdit((1, 0), (1, 1), "=="), assistanceEdit((0, 2), (0, 4), "🙂"), assistanceEdit(
            (3, 0),
            (3, 0),
            "End",
        ),
    ])])
    let action = try #require(LanguageAssistance.codeActions(
        response,
        source: source,
        documentURL: assistanceURL,
        version: 7,
    ).first)
    #expect(action.title == "Rewrite" && action.isPreferred && action.sourceVersion == 7 && action
        .documentURL == assistanceURL)
    #expect(action.kind == "refactor.rewrite")
    #expect(try TextEditing.applying(action.edits, to: source) == "中文🙂\r\n== Heading\r\n$x$\r\nEnd")
    let versioned = try assistanceJSON([["title": "Versioned", "edit": ["documentChanges": [[
        "textDocument": ["uri": assistanceURL.absoluteString, "version": 7], "edits": [assistanceEdit(
            (1, 0),
            (1, 1),
            "===",
        )],
    ]]]]])
    #expect(LanguageAssistance.codeActions(versioned, source: source, documentURL: assistanceURL, version: 7)
        .count == 1)
    #expect(LanguageAssistance.codeActions(versioned, source: source, documentURL: assistanceURL, version: 8).isEmpty)
    let loneCR = try assistanceJSON([assistanceAction([assistanceEdit((1, 0), (1, 1), "X")])])
    let crAction = try #require(LanguageAssistance.codeActions(
        loneCR,
        source: "a\rb",
        documentURL: assistanceURL,
        version: 1,
    ).first)
    #expect(try TextEditing.applying(crAction.edits, to: "a\rb") == "a\rX")
}

@Test func languageAssistanceRejectsMalformedRangesWithoutPartialEdits() throws {
    let source = "😀x\r\nabc"
    let invalid: [[String: Any]] = [
        assistanceEdit((0, 1), (0, 2), "split surrogate"),
        assistanceEdit((0, 3), (0, 4), "CRLF overflow"),
        assistanceEdit((2, 0), (2, 0), "nonexistent line"),
        assistanceEdit((-1, 0), (0, 0), "negative line"),
        assistanceEdit((1, -1), (1, 0), "negative column"),
        assistanceEdit((1, 2), (1, 1), "reversed"),
    ]
    for bad in invalid {
        let response = try assistanceJSON([assistanceAction([assistanceEdit((1, 0), (1, 1), "valid"), bad])])
        #expect(LanguageAssistance.codeActions(response, source: source, documentURL: assistanceURL, version: 1)
            .isEmpty)
    }
    for edits in [
        [assistanceEdit((1, 0), (1, 2), "x"), assistanceEdit((1, 1), (1, 3), "y")],
        [assistanceEdit((1, 0), (1, 0), "x"), assistanceEdit((1, 0), (1, 0), "y")],
    ] {
        #expect(try LanguageAssistance.codeActions(
            assistanceJSON([assistanceAction(edits)]),
            source: source,
            documentURL: assistanceURL,
            version: 1,
        ).isEmpty)
    }
}

@Test func languageAssistanceRejectsCommandsResourcesCrossDocumentAndSnippets() throws {
    let edit = assistanceEdit((0, 0), (0, 1), "b")
    var command = assistanceAction([edit])
    command["command"] = ["command": "arbitrary.command"]
    var disabled = assistanceAction([edit])
    disabled["disabled"] = ["reason": "Unavailable"]
    var snippet = edit
    snippet["insertTextFormat"] = 2
    var annotated = edit
    annotated["annotationId"] = "approval"
    let textChange: [String: Any] = ["textDocument": ["uri": assistanceURL.absoluteString], "edits": [edit]]
    let unsafe: [[String: Any]] = [
        command, disabled, assistanceAction([snippet]), assistanceAction([annotated]),
        assistanceAction([edit], uri: "file:///another.typ"), assistanceAction(
            [edit],
            uri: "https://example.com/doc.typ",
        ),
        assistanceAction([edit], uri: "file://remote" + assistanceURL.path),
        [
            "title": "Two files",
            "edit": ["changes": [assistanceURL.absoluteString: [edit], "file:///another.typ": [edit]]],
        ],
        [
            "title": "Create and edit",
            "edit": ["documentChanges": [textChange, ["kind": "create", "uri": "file:///new.typ"]]],
        ],
        [
            "title": "Cross document",
            "edit": ["documentChanges": [textChange, ["textDocument": ["uri": "file:///other.typ"], "edits": [edit]]]],
        ],
        [
            "title": "Annotations",
            "edit": [
                "changes": [assistanceURL.absoluteString: [edit]],
                "changeAnnotations": ["approval": ["needsConfirmation": true]],
            ],
        ],
        [
            "title": "Ambiguous",
            "edit": ["changes": [assistanceURL.absoluteString: [edit]], "documentChanges": [textChange]],
        ],
        [
            "title": "Malformed",
            "edit": ["changes": [assistanceURL.absoluteString: [edit, ["newText": "missing range"]]]],
        ],
        ["title": "No changes", "edit": ["changes": [assistanceURL.absoluteString: []]]],
    ]
    let response = try assistanceJSON(unsafe + [assistanceAction([edit])])
    let result = LanguageAssistance.codeActions(response, source: "a", documentURL: assistanceURL, version: 1)
    #expect(result.count == 1)
    #expect(try TextEditing.applying(#require(result.first).edits, to: "a") == "b")
}

#if os(macOS)
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEFTBLANK_INTEGRATION"] == "1"))
    func realTinymistLanguageAssistance() async throws {
        let root = TestPaths.temporaryDirectory.appendingPathComponent("LeftBlank-assistance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("文稿.typ")
        let source = "#rect(width: 20pt, height: 30pt)\n== Heading\n$alpha+beta$\n"
        try Data("Disk sentinel\n".utf8).write(to: file)
        let client = TinymistClient()
        defer { client.stop()
            try? FileManager.default.removeItem(at: root)
        }
        try await client.start(root: root, outputDirectory: root)
        try client.open(file, text: source, version: 1)
        let document = ["uri": file.absoluteString]
        let hover = try await client.request(
            "textDocument/hover",
            ["textDocument": document, "position": ["line": 0, "character": 3]],
        )
        let help = try #require(LanguageAssistance.hover(hover))
        #expect(help.text.lowercased().contains("rectangle"))
        let signature = try await client.request(
            "textDocument/signatureHelp",
            ["textDocument": document, "position": ["line": 0, "character": 12]],
        )
        let call = try #require(LanguageAssistance.signatureHelp(signature))
        #expect(call.label.hasPrefix("rect("))
        #expect(call.activeParameter == "width:")
        let heading = try await client.request("textDocument/codeAction", [
            "textDocument": document, "range": [
                "start": ["line": 1, "character": 4],
                "end": ["line": 1, "character": 4],
            ],
            "context": ["diagnostics": [], "triggerKind": 1],
        ])
        let headingActions = LanguageAssistance.codeActions(heading, source: source, documentURL: file, version: 1)
        let increase = try #require(headingActions.first { $0.title == "Increase depth of heading" })
        #expect(try TextEditing.applying(increase.edits, to: source).contains("\n=== Heading\n"))
        let decrease = try #require(headingActions.first { $0.title == "Decrease depth of heading" })
        #expect(try TextEditing.applying(decrease.edits, to: source).contains("\n= Heading\n"))
        let equation = try await client.request("textDocument/codeAction", [
            "textDocument": document, "range": [
                "start": ["line": 2, "character": 3],
                "end": ["line": 2, "character": 3],
            ],
            "context": ["diagnostics": [], "triggerKind": 1],
        ])
        let equationActions = LanguageAssistance.codeActions(equation, source: source, documentURL: file, version: 1)
        let block = try #require(equationActions.first { $0.title == "Convert to block equation" })
        #expect(try TextEditing.applying(block.edits, to: source).contains("$ alpha+beta $"))
        let multiline = try #require(equationActions.first { $0.title == "Convert to multiple-line block equation" })
        #expect(try TextEditing.applying(multiline.edits, to: source).contains("$\nalpha+beta\n$"))
        try client.change(file, text: "#rec", version: 2)
        let completed = try await client.request("textDocument/completion", [
            "textDocument": document, "position": ["line": 0, "character": 4],
            "context": ["triggerKind": 1],
        ])
        let choices = LanguageAssistance.completions(
            completed,
            source: "#rec",
            selection: NSRange(location: 4, length: 0),
        )
        #expect(choices.contains { $0.label.hasPrefix("rect") })
        #expect(try String(contentsOf: file, encoding: .utf8) == "Disk sentinel\n")
    }

#endif
