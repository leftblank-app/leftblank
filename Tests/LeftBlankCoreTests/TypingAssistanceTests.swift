import Foundation
@testable import LeftBlankCore
import Testing

@Test func typingContextsSeparateProseCommentsRawTextAndExpressions() {
    func context(_ source: String) -> TypingContext? {
        TypingContext(source: source, selection: NSRange(location: source.utf16.count, length: 0))
    }
    for source in [
        "Ordinary text",
        "// #rect",
        "/* outer /* nested */ #rec",
        "`#rect",
        "```typ\n#rect",
        "#rect() prose",
        "\\#rec",
    ] {
        #expect(context(source) == nil, "Must not complete: \(source)")
    }
    #expect(context("#rec")?.prefix == "rec")
    #expect(context("@chap")?.wantsCompletion == true)
    #expect(context("$ alp")?.prefix == "alp")
    #expect(context("/* #false */\n#rect(\n  width: ")?.wantsSignature == true)
    #expect(context("#rect(\n  wid")?.prefix == "wid")
    #expect(context("#image(\"images/fi")?.prefix == "fi")
    #expect(context("#image(\"https://host/fi")?.wantsCompletion == true)
    #expect(context("```typ\n#fake\n```\n#real")?.prefix == "real")
    #expect(context("#f(// comment\n  width: ")?.wantsSignature == true)
    #expect(context("#函数")?.prefix == "函数")
    #expect(TypingContext(source: "#😀", selection: NSRange(location: 2, length: 0)) == nil)
    #expect(TypingContext(source: "#rec", selection: NSRange(location: 1, length: 3)) == nil)
}

@Test func completionListFiltersWithoutTruncatingAndPreservesSelectionBounds() {
    let response: JSONValue = .array((0 ..< 30).map { .object(["label": .string("rect\($0)")]) })
    let items = LanguageAssistance.completions(response, source: "#rec", selection: NSRange(location: 4, length: 0))
    var list = CompletionList(items: items, prefix: "REC")
    #expect(list.items.count == 30)
    list.move(-1)
    #expect(list.index == 0)
    list.move(29)
    #expect(list.selected?.label == "rect29")
    list.move(1)
    #expect(list.index == 29)
    #expect(CompletionList(items: items, prefix: "absent").selected == nil)
}

@Test func cancelledTypingContextDoesNotFinishScanningAnObsoleteBook() async {
    let source = String(repeating: "A long paragraph of prose.\n", count: 100_000) + "#rect("
    let task = Task {
        await TypingContext.resolve(source: source, selection: NSRange(location: source.utf16.count, length: 0))
    }
    task.cancel()
    #expect(await task.value == nil)
}
