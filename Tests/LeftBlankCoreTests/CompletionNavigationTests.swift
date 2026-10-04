import Foundation
@testable import LeftBlankCore
import Testing

private func completionJSON(_ value: Any) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
}

private func completionRange(_ start: Int, _ end: Int, line: Int = 0) -> [String: Any] {
    ["start": ["line": line, "character": start], "end": ["line": line, "character": end]]
}

@Test func completionsApplyMainAndAdditionalUnicodeEdits() throws {
    let source = "// 中文😀\r\n#rec"
    let response = try completionJSON([["label": "rect", "textEdit": [
        "range": completionRange(1, 4, line: 1), "newText": "rect()",
    ], "additionalTextEdits": [["range": completionRange(0, 0), "newText": "// import\n"]]]])
    let item = try #require(LanguageAssistance.completions(
        response,
        source: source,
        selection: NSRange(location: source.utf16.count, length: 0),
    )
    .first)
    let result = try TextEditing.applying(item.edits, to: source)
    #expect(result == "// import\n// 中文😀\r\n#rect()")
    #expect(item.insertionEnd == result.utf16.count)
}

@Test func completionsRejectUnsafeOrUnsupportedEdits() throws {
    let source = "😀hello"
    let response = try completionJSON([
        ["label": "half scalar", "textEdit": ["range": completionRange(1, 2), "newText": "x"]],
        ["label": "invalid line", "textEdit": ["range": completionRange(0, 1, line: 4), "newText": "x"]],
        ["label": "snippet", "insertTextFormat": 2, "insertText": "${1:word}"],
        ["label": "command", "command": ["command": "run"]],
        ["label": "overlap", "textEdit": ["range": completionRange(2, 7), "newText": "x"],
         "additionalTextEdits": [["range": completionRange(3, 4), "newText": "y"]]],
        ["label": "malformed", "textEdit": ["newText": "x"]],
    ])
    #expect(LanguageAssistance.completions(response, source: source, selection: NSRange(location: 7, length: 0))
        .isEmpty)
    #expect(try LanguageAssistance.completions(
        completionJSON([["label": "word"]]),
        source: source,
        selection: NSRange(location: 1, length: 0),
    ).isEmpty)
}

@Test func completionsHonorDefaultReplaceRange() throws {
    let response = try completionJSON([
        "itemDefaults": ["editRange": ["insert": completionRange(1, 3), "replace": completionRange(1, 4)]],
        "items": [["label": "rect", "textEditText": "rect()", "detail": "A rectangle"]],
    ])
    let item = try #require(LanguageAssistance.completions(
        response,
        source: "#rec",
        selection: NSRange(location: 3, length: 0),
    ).first)
    #expect(try TextEditing.applying(item.edits, to: "#rec") == "#rect()")
    #expect(item.insertionEnd == 7)
}

@Test func snippetTraversalTracksEditsAndSupportsShiftTab() {
    let snippet = Snippet(
        text: "one two",
        selections: [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)],
    )
    var navigation = SnippetNavigation(snippet, at: 10)
    navigation.edit(NSRange(location: 10, length: 3), replacement: "😀")
    #expect(navigation.current == NSRange(location: 10, length: 2))
    #expect(navigation.move(backward: false) == NSRange(location: 13, length: 3))
    #expect(navigation.move(backward: true) == NSRange(location: 10, length: 2))
    #expect(navigation.move(backward: false) == NSRange(location: 13, length: 3))
    #expect(navigation.move(backward: false) == NSRange(location: 16, length: 0))
    #expect(navigation.current == nil)
    #expect(navigation.move(backward: false) == nil)
}

@Test func snippetEditOutsideActivePlaceholderStopsTraversal() {
    var navigation = SnippetNavigation(Snippet(text: "one", selections: [NSRange(location: 0, length: 3)]), at: 2)
    navigation.edit(NSRange(location: 0, length: 0), replacement: "x")
    #expect(navigation.current == nil)
}
