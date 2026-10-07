import Foundation
@testable import LeftBlankCore
import Testing

/// Deterministic xorshift64* so a failure reproduces from its seed.
private struct SeededRandom {
    var state: UInt64

    mutating func below(_ bound: Int) -> Int {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return Int((state &* 0x2545_F491_4F6C_DD1D) % UInt64(max(bound, 1)))
    }
}

/// Markup, code, CJK, emoji, CRLF and unclosed delimiters.
private let fragments = [
    "= 标题 😀\n", "== Section\r\n", "*粗体*", "_emph_", " ", "\n", "\r\n", "\n\n",
    "#item(\"LB-001\", \"标题\", \"done\")", "#let item(id, title, status) = [#id #title]\n",
    "#f[content *b*]", "$x^2 + 中$", "```rust\nfn main() {}\n```", "`raw`", "- item\n", "@ref", "<label>",
    "// comment\n", "(", ")", "[", "]", "{", "}", "\"", "$", "*", "_", "#", "😀", "中文", "e\u{301}",
]

private func randomText(_ random: inout SeededRandom, pieces: Int) -> String {
    (0 ..< pieces).map { _ in fragments[random.below(fragments.count)] }.joined()
}

/// The nearest offset at or after `offset` that does not split a surrogate pair.
private func boundary(_ text: NSString, _ offset: Int) -> Int {
    var offset = min(offset, text.length)
    while offset < text.length, UTF16.isTrailSurrogate(text.character(at: offset)) {
        offset += 1
    }
    return offset
}

private func node(_ nodes: [SyntaxNode], _ kind: SyntaxKind, in source: NSString, text: String) -> SyntaxNode? {
    nodes.first { $0.kind == kind && source.substring(with: $0.range) == text }
}

@Test func syntaxKindCodesMatchTheParserTable() {
    #expect(SyntaxTree.isAvailable)
    for kind in SyntaxKind.allCases where kind != .other {
        var name = String(describing: kind)
        if name.hasSuffix("Keyword") {
            name.removeLast("Keyword".count)
        }
        #expect(kind.bridgeName == name.prefix(1).uppercased() + name.dropFirst(), "\(kind) = \(kind.rawValue)")
    }
    #expect(SyntaxKind.other.bridgeName == nil)
    // Every code the parser can emit has a Swift case.
    let known = (UInt16(0) ... 1024).filter { SyntaxKind.bridgeName(code: $0) != nil }
    #expect(known.count == SyntaxKind.allCases.count - 1)
    #expect(known.allSatisfy { SyntaxKind(rawValue: $0) != nil })
    #expect(SyntaxKind.strong.rawValue == 9 && SyntaxKind.funcCall.rawValue == 65)
}

@Test func syntaxTreeReportsUTF16RangesForCJKEmojiAndCRLF() throws {
    let text = "= 标题 😀\r\n*粗* _e_ #item(\"LB-001\", \"标题\")\r\n\r\n- 列表 $x$"
    let source = text as NSString
    let tree = try #require(SyntaxTree(text))
    #expect(tree.utf16Length == source.length)
    let nodes = try #require(tree.nodes())
    #expect(nodes.first?.kind == .markup && nodes.first?.range == NSRange(location: 0, length: source.length))
    #expect(nodes.first?.parent == nil)
    #expect(node(nodes, .heading, in: source, text: "= 标题 😀") != nil)
    #expect(node(nodes, .strong, in: source, text: "*粗*") != nil)
    #expect(node(nodes, .emph, in: source, text: "_e_") != nil)
    #expect(node(nodes, .hash, in: source, text: "#") != nil)
    #expect(node(nodes, .funcCall, in: source, text: "item(\"LB-001\", \"标题\")") != nil)
    #expect(node(nodes, .str, in: source, text: "\"标题\"") != nil)
    #expect(node(nodes, .parbreak, in: source, text: "\r\n\r\n") != nil)
    #expect(node(nodes, .listItem, in: source, text: "- 列表 $x$") != nil)
    #expect(node(nodes, .equation, in: source, text: "$x$") != nil)
    #expect(!nodes.contains { $0.kind == .text || $0.kind == .space || $0.isErroneous })
    for (index, child) in nodes.enumerated().dropFirst() {
        let parentIndex = try #require(child.parent)
        let parent = nodes[parentIndex]
        #expect(parentIndex < index && child.depth == parent.depth + 1)
        #expect(NSIntersectionRange(parent.range, child.range) == child.range)
    }
    // A window keeps each node with its ancestors.
    let window = source.range(of: "粗")
    let windowed = try #require(tree.nodes(in: window))
    #expect(windowed.map(\.kind) == [.markup, .strong, .markup])
    #expect(tree.nodes(in: NSRange(location: source.length, length: 0))?.first?.kind == .markup)
}

@Test func syntaxTreeFlagsUnfinishedConstructs() throws {
    let text = "*open and $x^2$ #item(\"a\","
    let nodes = try #require(SyntaxTree(text)?.nodes())
    #expect(nodes.first?.isErroneous == true)
    #expect(nodes.contains { $0.kind == .error })
    #expect(nodes.contains { $0.kind == .equation && !$0.isErroneous })
    let math = try #require(nodes.firstIndex { $0.kind == .math })
    #expect(!nodes.contains { $0.parent == math }, "Math is opaque")
}

@Test func syntaxTreeRejectsSurrogateSplittingAndOutOfRangeEdits() throws {
    let text = "a😀b"
    for range in [
        NSRange(location: 2, length: 0), NSRange(location: 1, length: 1), NSRange(location: 2, length: 1),
        NSRange(location: 0, length: 5), NSRange(location: -1, length: 1), NSRange(location: 0, length: -1),
    ] {
        let tree = try #require(SyntaxTree(text))
        #expect(tree.edit(range, replacement: "x") == nil, "\(range)")
        #expect(!tree.isValid && tree.nodes() == nil && tree.utf16Length == 0)
        #expect(tree.edit(NSRange(location: 0, length: 0), replacement: "x") == nil, "stays invalid")
    }
    let tree = try #require(SyntaxTree(text))
    let reparsed = try #require(tree.edit(NSRange(location: 1, length: 2), replacement: "*中*"))
    #expect(tree.isValid && tree.utf16Length == 5)
    #expect(NSIntersectionRange(reparsed, NSRange(location: 1, length: 3)).length == 3)
    #expect(tree.nodes()?.contains { $0.kind == .strong && $0.range == NSRange(location: 1, length: 3) } == true)
}

@Test func seededIncrementalEditsMatchAFreshParse() throws {
    for seed: UInt64 in [7, 0x1B019] {
        var random = SeededRandom(state: seed)
        let text = NSMutableString(string: randomText(&random, pieces: 60))
        let tree = try #require(SyntaxTree(text as String))
        for step in 0 ..< 150 {
            let start = boundary(text, random.below(text.length + 1))
            let end = boundary(text, start + random.below(20))
            let range = NSRange(location: start, length: end - start)
            let replacement = randomText(&random, pieces: random.below(3))
            text.replaceCharacters(in: range, with: replacement)
            let reparsed = try #require(tree.edit(range, replacement: replacement), "seed \(seed) step \(step)")
            #expect(NSMaxRange(reparsed) <= text.length)
            let fresh = try #require(SyntaxTree(text as String)?.nodes())
            #expect(tree.nodes() == fresh, "seed \(seed) step \(step): \(range) -> \(replacement.debugDescription)")
            #expect(tree.utf16Length == text.length)
        }
    }
}

@Test func syntaxTreeInstallRequiresAMatchingTable() throws {
    let incompatible = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
    defer { incompatible.deallocate() }
    incompatible.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
    #expect(!SyntaxTree.install(UnsafeRawPointer(incompatible)), "ABI version 0")
    #expect(SyntaxTree.isAvailable)
    let table = try #require(SyntaxTree.installedTable)
    #expect(SyntaxTree.install(table))
    #expect(SyntaxTree("*b*")?.nodes()?.contains { $0.kind == .strong } == true)
}

/// Parses the checked-in books (docs/large-document-performance.md) with the
/// release parser and checks generous budgets. scripts/benchmark-books.sh sets
/// LEFTBLANK_SYNTAX_REPORT to keep the measurements.
@Test func bookLengthSourcesParseWithinBudget() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    var report: [String: Any] = [:]
    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    for (name, path) in [
        ("war-and-peace", "Examples/Books/WarAndPeace/war-and-peace-highlighted.typ"),
        ("sicp", "Examples/Books/SICP/main.typ"),
    ] {
        let text = try String(contentsOf: repository.appendingPathComponent(path), encoding: .utf8)
        let clock = ContinuousClock()
        var parses: [Double] = []
        var tree: SyntaxTree?
        for _ in 0 ..< 3 {
            let started = clock.now
            tree = SyntaxTree(text)
            parses.append(milliseconds(started.duration(to: clock.now)))
        }
        let parsed = try #require(tree)
        var started = clock.now
        let nodes = try #require(parsed.nodes())
        let convert = milliseconds(started.duration(to: clock.now))
        // Type in the middle of the book, at a line start, and refresh the
        // reparsed range, as the editor would after each keystroke.
        let mirror = NSMutableString(string: text)
        var cursor = NSMaxRange(mirror.lineRange(for: NSRange(location: mirror.length / 2, length: 0)))
        var typing: [Double] = []
        for character in "Typing 中文 and *strong* text with #f(x) calls 😀 more".map(String.init) {
            let range = NSRange(location: cursor, length: 0)
            mirror.replaceCharacters(in: range, with: character)
            started = clock.now
            let reparsed = try #require(parsed.edit(range, replacement: character))
            _ = parsed.nodes(in: reparsed)
            typing.append(milliseconds(started.duration(to: clock.now)))
            cursor += (character as NSString).length
        }
        // An unclosed `$` reparses to the end of the book: the worst case.
        started = clock.now
        let dollar = NSRange(location: cursor, length: 0)
        mirror.replaceCharacters(in: dollar, with: "$")
        _ = parsed.edit(dollar, replacement: "$").flatMap { parsed.nodes(in: $0) }
        let unclosed = milliseconds(started.duration(to: clock.now))
        #expect(parsed.nodes() == SyntaxTree(mirror as String)?.nodes(), "\(name): incremental equals fresh")
        typing.sort()
        let parse = parses.sorted()[1], median = typing[typing.count / 2]
        let slowest = try #require(typing.last)
        print("LEFTBLANK SYNTAX \(name): parse \(parse) ms, \(nodes.count) nodes in \(convert) ms, " +
            "typing median \(median) / max \(slowest) ms, unclosed $ \(unclosed) ms")
        report[name] = [
            "utf16": (text as NSString).length, "nodes": nodes.count, "parse_ms": parse, "nodes_ms": convert,
            "typing_median_ms": median, "typing_max_ms": slowest, "unclosed_dollar_ms": unclosed,
        ]
        // About 20x the M4 Pro release measurements, for slow shared CI runners.
        #expect(parse < 500, "\(name) full parse")
        #expect(convert < 1000, "\(name) whole-tree conversion")
        #expect(median < 25, "\(name) typing median")
        #expect(unclosed < 2000, "\(name) unclosed equation")
    }
    if let path = ProcessInfo.processInfo.environment["LEFTBLANK_SYNTAX_REPORT"] {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path))
    }
}
