import Foundation
@testable import LeftBlankCore
import Testing

private let formatter = ChipFormatter(valueLabels: ["status": ["done": "已完成", "todo": "待办"]])

private func makeStore(
    _ text: String,
    selection: NSRange? = nil,
    options: PresentationOptions = PresentationOptions(formatter: formatter),
) throws -> PresentationStore {
    let source = text as NSString
    let tree = try #require(SyntaxTree(text))
    return PresentationStore(
        source: source,
        tree: tree,
        selection: selection ?? NSRange(location: source.length, length: 0),
        options: options,
    )
}

/// A readable rendering of a plan, one entry per line, for golden comparisons.
private func render(_ plan: DisplayPlan, _ text: String) -> [String] {
    let source = text as NSString
    func quote(_ range: NSRange) -> String {
        "\(range.location)+\(range.length) " + source.substring(with: range).debugDescription
    }
    var lines = plan.conceals.map { "conceal " + quote($0) }
    for replacement in plan.replacements {
        switch replacement.content {
        case let .chip(chip):
            let arguments = chip.arguments.map { "\($0.name ?? "_")=\($0.literal)" }.joined(separator: ",")
            lines.append("chip \(quote(replacement.range)) \(chip.label.debugDescription) [\(arguments)]")
        case .bullet: lines.append("bullet " + quote(replacement.range))
        case let .image(path): lines.append("image \(quote(replacement.range)) \(path)")
        case let .fragment(key, _): lines.append("fragment \(quote(replacement.range)) \(key)")
        }
    }
    lines += plan.styles.map { "style \($0.style) " + quote($0.range) }
    for request in plan.requests {
        switch request {
        case let .math(range, _, isBlock): lines.append("math \(isBlock ? "block" : "inline") " + quote(range))
        case let .image(range, path): lines.append("load \(quote(range)) \(path)")
        }
    }
    lines += plan.revealed.map { "revealed " + quote($0) }
    return lines
}

private func golden(_ text: String, selection: NSRange? = nil) throws -> [String] {
    try render(makeStore(text, selection: selection).plan, text)
}

@Test func presentationGoldenPlansForEachConstruct() throws {
    #expect(try golden("= 标题 😀\n== Two\n\nx") == [
        "conceal 0+2 \"= \"", "conceal 8+3 \"== \"",
        "style heading(level: 1) 0+7 \"= 标题 😀\"", "style heading(level: 2) 8+6 \"== Two\"",
    ])
    #expect(try golden("*粗体 bold* _emph_ x") == [
        "conceal 0+1 \"*\"", "conceal 8+1 \"*\"", "conceal 10+1 \"_\"", "conceal 15+1 \"_\"",
        "style strong 0+9 \"*粗体 bold*\"", "style emphasis 10+6 \"_emph_\"",
    ])
    #expect(try golden("`raw` and\n```rust\nfn main() {}\n```\n") == [
        "conceal 0+1 \"`\"", "conceal 4+1 \"`\"",
        "style code 0+5 \"`raw`\"", "style code 10+24 \"```rust\\nfn main() {}\\n```\"",
    ])
    #expect(try golden("See https://typst.app @intro <intro> x") == [
        "conceal 22+1 \"@\"", "conceal 29+1 \"<\"", "conceal 35+1 \">\"",
        "style link 4+17 \"https://typst.app\"", "style reference 22+6 \"@intro\"", "style label 29+7 \"<intro>\"",
    ])
    #expect(try golden("- item\n+ enum\n/ Term: desc\n") == [
        "bullet 0+1 \"-\"",
        "style listMarker 0+1 \"-\"", "style listMarker 7+1 \"+\"", "style listMarker 14+1 \"/\"",
    ])
    #expect(try golden("Inline $x^2$ and\n$ y = 1 $\n") == [
        "style math 7+5 \"$x^2$\"", "style math 17+9 \"$ y = 1 $\"",
        "math inline 7+5 \"$x^2$\"", "math block 17+9 \"$ y = 1 $\"",
    ])
    #expect(try golden("#image(\"fig/a.png\", width: 50%) x") == [
        "image 0+31 \"#image(\\\"fig/a.png\\\", width: 50%)\" fig/a.png",
        "load 0+31 \"#image(\\\"fig/a.png\\\", width: 50%)\" fig/a.png",
    ])
    let call = "#let item(id, title, status: \"todo\") = [#id #title]\n#item(\"LB-001\", \"标题\", status: \"done\") x"
    #expect(try golden(call) == [
        "chip 52+37 \"#item(\\\"LB-001\\\", \\\"标题\\\", status: \\\"done\\\")\" \"LB-001 标题 [已完成]\" " +
            "[id=LB-001,title=标题,status=done]",
    ])
}

@Test func presentationLeavesErroneousAndIncompleteConstructsAsSource() throws {
    for text in [
        "*open", "_open", "#f(1", "$x", "```raw", "<lab", "= ", "**", "@", "#let f(a) = a\n#f(\"x\"",
        "#let f(a) = a\n#f[content]", "#let f(a) = a\n#f(1 + 2)", "#let f(a) = a\n#f(a)", "#let f(a) = a\n#f(..xs)",
        "#unknown(\"no signature\")", "#x.y(1)", "#image(path)", "#let f(a) = a\n#f(\"a\\u{1F600}\")",
    ] {
        let plan = try makeStore(text).plan
        #expect(plan.conceals.isEmpty && plan.replacements.isEmpty, "\(text.debugDescription): \(render(plan, text))")
    }
    // An error elsewhere keeps the rest of the document planned.
    let unfinished = "*ok* and *open\n\n_fine_\n\nx"
    #expect(try render(makeStore(unfinished).plan, unfinished).filter { $0.hasPrefix("conceal") } == [
        "conceal 0+1 \"*\"", "conceal 3+1 \"*\"", "conceal 16+1 \"_\"", "conceal 21+1 \"_\"",
    ])
}

@Test func presentationRevealsTheTouchedConstructOrParagraph() throws {
    let text = "#let f(x) = x\nLead *粗体* and _emph_ #f(\"a\").\n\nNext *b*\n"
    let source = text as NSString
    let strong = source.range(of: "*粗体*"), emph = source.range(of: "_emph_"), chip = source.range(of: "#f(\"a\")")
    for location in [strong.location, strong.location + 2, NSMaxRange(strong)] {
        let plan = try makeStore(text, selection: NSRange(location: location, length: 0)).plan
        #expect(!plan.isConcealed(strong.location) && plan.revealed.contains(strong))
        #expect(plan.styles.contains(StyleRun(
            range: NSRange(location: strong.location, length: 1),
            style: .revealedMarker,
        )))
        #expect(plan.isConcealed(emph.location) && plan.replacement(containing: chip.location) != nil)
    }
    let selected = try makeStore(
        text,
        selection: NSRange(location: emph.location - 1, length: chip.location - emph.location + 2),
    )
    #expect(selected.plan.replacement(containing: chip.location) == nil, "a selection across the chip reveals it")
    let paragraph = try makeStore(
        text,
        selection: NSRange(location: strong.location + 2, length: 0),
        options: PresentationOptions(reveal: .paragraph),
    ).plan
    #expect(!paragraph.isConcealed(emph.location) && paragraph.replacement(containing: chip.location) == nil)
    #expect(paragraph.isConcealed(source.range(of: "*b*").location), "other paragraphs stay concealed")
}

@Test func presentationNamesArgumentsFromTheVisibleSignature() throws {
    let text = """
    #let item(id, title, status: "todo") = [#id]
    #item("A", "First")
    #let item(title, id: 0) = [#title]
    #item("B", id: 7, 2.5pt)
    #image("a.png")
    """
    let store = try makeStore(text, options: PresentationOptions(formatter: formatter, showsImages: false))
    let source = text as NSString
    #expect(store.definitions.definitions.map(\.signature.parameters.count) == [3, 2])
    #expect(store.definitions.signature("item", before: source.length)?.parameters.last?.defaultSource == "0")
    #expect(store.definitions.signature("item", before: 0) == nil, "a call cannot precede every definition")
    let chips = store.plan.chips
    #expect(chips.map(\.label) == ["A First", "B 2.5pt"], "each call uses the latest definition before it")
    #expect(chips[0].arguments.map(\.name) == ["id", "title"])
    #expect(chips[1].arguments.map(\.name) == ["title", "id", nil])
    #expect(chips[1].arguments.map(\.isString) == [true, false, false])
    #expect(store.plan.requests.isEmpty, "images are off")
    #expect(ChipFormatter().label(callee: "f", arguments: []) == "f")
}

@Test func chipEditsWriteOneReplacementAndKeepFormatting() throws {
    let text = "#let item(id, title, status: \"todo\", weight: 1) = []\n#item(\"A\",  /* keep */ \"T\")\n"
    let source = text as NSString
    let store = try makeStore(text)
    let chip = try #require(store.plan.chips.first)
    let signature = try #require(store.definitions.signature("item", before: chip.range.location))
    func applying(_ values: [String: String]) throws -> String? {
        try ChipEditing.edit(chip, values: values, signature: signature, source: source)
            .map { source.replacingCharacters(in: $0.range, with: $0.text) }
    }
    #expect(try applying(["id": "B\"1\\", "status": "done"])?.contains(
        "#item(\"B\\\"1\\\\\",  /* keep */ \"T\", status: \"done\")",
    ) == true)
    #expect(try applying(["weight": "2.5"])?.contains("\"T\", weight: 2.5)") == true)
    #expect(try applying(["id": "A", "title": "T"]) == nil, "unchanged values")
    #expect(throws: ChipEditing.Failure.invalidLiteral(parameter: "weight", value: "heavy")) {
        try applying(["weight": "heavy"])
    }
    #expect(throws: ChipEditing.Failure.unknownParameter("colour")) { try applying(["colour": "red"]) }
    // Missing positional arguments are inserted in order, before named ones.
    let short = "#let item(id, title, status: \"todo\") = []\n#item(status: \"done\",)\n"
    let shortStore = try makeStore(short)
    let shortChip = try #require(shortStore.plan.chips.first)
    let edit = try #require(try ChipEditing.edit(
        shortChip,
        values: ["id": "X", "title": "Y", "status": "todo"],
        signature: signature,
        source: short as NSString,
    ))
    #expect((short as NSString).replacingCharacters(in: edit.range, with: edit.text)
        .contains("#item(\"X\", \"Y\", status: \"todo\",)"))
    #expect(throws: ChipEditing.Failure.missingArgument("id")) {
        try ChipEditing.edit(shortChip, values: ["title": "Y"], signature: signature, source: short as NSString)
    }
    let empty = "#let f(a, b: none) = []\n#f()\n"
    let emptyChip = try #require(makeStore(empty).plan.chips.first)
    let emptySignature = FunctionSignature(name: "f", parameters: [
        .init(name: "a", isPositional: true, defaultSource: nil),
        .init(name: "b", isPositional: false, defaultSource: "none"),
    ])
    let filled = try #require(try ChipEditing.edit(
        emptyChip,
        values: ["a": "x", "b": "auto"],
        signature: emptySignature,
        source: empty as NSString,
    ))
    #expect((empty as NSString).replacingCharacters(in: filled.range, with: filled.text).contains("#f(\"x\", b: auto)"))
}

@Test func repeatPreviousCallKeepsEnumerationsAndAddsPlaceholders() throws {
    let text = "#let item(id, title, status: \"todo\", weight: 1) = []\n#item(\"LB-001\", \"标题\", status: \"done\", weight: 3)\n"
    let source = text as NSString
    let chips = try makeStore(text, selection: NSRange(location: 0, length: 0)).plan.chips
    #expect(ChipEditing.repeatPrevious(before: 10, chips: chips, formatter: formatter) == nil)
    let insertion = try #require(ChipEditing.repeatPrevious(before: source.length, chips: chips, formatter: formatter))
    #expect(insertion.range == NSRange(location: source.length, length: 0))
    #expect(insertion.snippet.text == "#item(\"\", \"\", status: \"done\", weight: 3)")
    let snippet = insertion.snippet.text as NSString
    #expect(insertion.snippet.selections.map { snippet.substring(with: $0) } == ["", "", "3"])
    #expect(insertion.snippet.selections.prefix(2).map(\.location) == [7, 11])
    // Applied as one edit, the copy becomes a chip of its own.
    let inserted = text + insertion.snippet.text
    #expect(try makeStore(inserted, selection: NSRange(location: 0, length: 0)).plan.chips.count == 2)
}

/// Incremental edits and selection moves must leave exactly the plan a fresh
/// full plan produces: the invariant the editor relies on.
@Test func presentationStoreIncrementalUpdatesMatchAFullPlan() throws {
    let paragraph = """
    = 标题 \(1)
    Text *粗体 bold* and _emph_ `raw` @ref <lab> #item("LB-001", "标题", status: "done") 😀
    - item $x^2$ #image("a.png")

    """
    var random = SeededRandom(state: 0x1B019)
    let insertions = ["*", "x", "中", "\n", "\n\n", "#item(\"Z\", \"y\")", "_", "$", " ", "`", "😀", "#let item(a) = a\n"]
    for reveal in [RevealPolicy.construct, .paragraph] {
        let text = NSMutableString(string: "#let item(id, title, status: \"todo\") = []\n" +
            String(repeating: paragraph, count: 60))
        let tree = try #require(SyntaxTree(text as String))
        var store = PresentationStore(
            source: text,
            tree: tree,
            selection: NSRange(location: 0, length: 0),
            options: PresentationOptions(reveal: reveal, formatter: formatter),
        )
        #expect(store.blocks.count > 3, "the fixture spans several blocks")
        for step in 0 ..< 250 {
            if random.below(3) == 0 {
                let location = random.below(text.length + 1)
                let selection = text.rangeOfComposedCharacterSequences(for: NSRange(
                    location: min(location, max(0, text.length - 1)),
                    length: random.below(2) * min(random.below(12), text.length - min(location, text.length)),
                ))
                store.select(
                    location == text.length ? NSRange(location: location, length: 0) : selection,
                    source: text,
                    tree: tree,
                )
            } else {
                var range = NSRange(location: random.below(text.length + 1), length: 0)
                if random.below(4) == 0, range.location < text.length {
                    range = text.rangeOfComposedCharacterSequences(for: NSRange(
                        location: range.location,
                        length: min(1 + random.below(30), text.length - range.location),
                    ))
                } else if range.location < text.length {
                    range.location = text.rangeOfComposedCharacterSequence(at: range.location).location
                }
                let insertion = random.below(5) == 0 ? "" : insertions[random.below(insertions.count)]
                text.replaceCharacters(in: range, with: insertion)
                let reparsed = try #require(tree.edit(range, replacement: insertion))
                store.edit(
                    range,
                    replacementLength: (insertion as NSString).length,
                    reparsed: reparsed,
                    source: text,
                    tree: tree,
                )
            }
            let fresh = try #require(SyntaxTree(text as String))
            let expected = PresentationStore(
                source: text,
                tree: fresh,
                selection: store.selection,
                options: store.options,
            )
            #expect(store.plan == expected.plan, "\(reveal) step \(step)")
            #expect(store.definitions == expected.definitions && store.length == text.length)
            if store.plan != expected.plan {
                return
            }
        }
    }
}

@Test func presentationStoreAnswersRangeQueriesAndRecovers() throws {
    let unit = "Para *b* _e_ #image(\"x.png\")\n\n"
    let text = String(repeating: unit, count: 200)
    let source = text as NSString
    let tree = try #require(SyntaxTree(text))
    var store = PresentationStore(source: source, tree: tree, selection: NSRange(location: 0, length: 0))
    #expect(store.blocks.count > 2)
    for (previous, block) in zip(store.blocks, store.blocks.dropFirst()) {
        #expect(NSMaxRange(previous.range) == block.start)
    }
    let second = source.paragraphRange(for: NSRange(location: (unit as NSString).length, length: 0))
    let local = store.plan(in: second)
    #expect(local.conceals.count == 4 && local.replacements.count == 1 && local.requests.count == 1)
    #expect(local.conceals.allSatisfy { NSLocationInRange($0.location, second) })
    // A stale edit (lengths that do not add up) rebuilds instead of corrupting the plan.
    let mutable = NSMutableString(string: text)
    mutable.replaceCharacters(in: NSRange(location: 0, length: 4), with: "")
    let rebuilt = try #require(SyntaxTree(mutable as String))
    let changed = store.edit(
        NSRange(location: 0, length: 0),
        replacementLength: 0,
        reparsed: NSRange(location: 0, length: 0),
        source: mutable,
        tree: rebuilt,
    )
    #expect(changed == [NSRange(location: 0, length: mutable.length)])
    #expect(store.plan == PresentationStore(source: mutable, tree: rebuilt, selection: store.selection).plan)
    #expect(store.select(store.selection, source: mutable, tree: rebuilt).isEmpty)
    // An edit at the start of a selection that spans several blocks re-plans its far end too.
    let wide = NSRange(location: 40, length: mutable.length - 80)
    store.select(wide, source: mutable, tree: rebuilt)
    mutable.replaceCharacters(in: NSRange(location: 38, length: 4), with: "*z*")
    let reparsed = try #require(rebuilt.edit(NSRange(location: 38, length: 4), replacement: "*z*"))
    let ranges = store.edit(
        NSRange(location: 38, length: 4),
        replacementLength: 3,
        reparsed: reparsed,
        source: mutable,
        tree: rebuilt,
    )
    #expect(ranges.count == 2 && store.selection == NSRange(location: 40, length: wide.length - 1))
    #expect(store.plan == PresentationStore(source: mutable, tree: rebuilt, selection: store.selection).plan)
    store.setOptions(PresentationOptions(showsImages: false), source: mutable, tree: rebuilt)
    #expect(store.plan.replacements.isEmpty && store.options.showsImages == false)
    #expect(PresentationStore.rebase(
        NSRange(location: 5, length: 4),
        editing: NSRange(location: 6, length: 2),
        delta: 3,
    )
        == NSRange(location: 5, length: 7))
}

@Test func presentationPlansBookLengthSourcesIncrementally() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let text = try NSMutableString(
        string: String(contentsOf: repository.appendingPathComponent("Examples/Books/SICP/main.typ"), encoding: .utf8),
    )
    let tree = try #require(SyntaxTree(text as String))
    let clock = ContinuousClock()
    var started = clock.now
    var store = PresentationStore(source: text, tree: tree, selection: NSRange(location: 0, length: 0))
    let build = started.duration(to: clock.now)
    var cursor = NSMaxRange(text.lineRange(for: NSRange(location: text.length / 2, length: 0)))
    var typing: [Duration] = []
    for character in "Typing 中文 and *strong* text 😀".map(String.init) {
        let range = NSRange(location: cursor, length: 0)
        started = clock.now
        text.replaceCharacters(in: range, with: character)
        let reparsed = try #require(tree.edit(range, replacement: character))
        store.edit(
            range,
            replacementLength: (character as NSString).length,
            reparsed: reparsed,
            source: text,
            tree: tree,
        )
        store.select(NSRange(location: cursor + (character as NSString).length, length: 0), source: text, tree: tree)
        typing.append(started.duration(to: clock.now))
        cursor += (character as NSString).length
    }
    typing.sort()
    print("LEFTBLANK PRESENTATION sicp: build \(build), \(store.blocks.count) blocks, " +
        "keystroke median \(typing[typing.count / 2]) max \(typing[typing.count - 1])")
    // Generous budgets for slow shared runners; locally both are far lower.
    #expect(build < .seconds(3))
    #expect(typing[typing.count / 2] < .milliseconds(50))
    let fresh = try #require(SyntaxTree(text as String))
    #expect(store.plan == PresentationStore(source: text, tree: fresh, selection: store.selection).plan)
}
