import Foundation
import Testing
import VisualPresentation

/// Pure presentation-model tests: no text system, identical on both platforms.
struct PresentationTests {
    func plan(_ text: String, selection: NSRange? = nil) throws -> DisplayPlan {
        let tree = try #require(SyntaxTree(text))
        let nodes = tree.nodes()
        let source = text as NSString
        var input = PresentationInput(
            source: source,
            nodes: nodes,
            selection: selection ?? NSRange(location: source.length, length: 0),
        )
        input.formatter = Sample.formatter
        input.signatures = Presentation.signatures(nodes: nodes, source: source)
        return Presentation.plan(input)
    }

    @Test
    func kindCodesMatchTheBridge() {
        for kind in SyntaxKind.allCases where kind != .other {
            let expected = switch kind {
            case .noneLiteral: "None"
            case .letKeyword: "Let"
            case .setKeyword: "Set"
            case .showKeyword: "Show"
            case .importKeyword: "Import"
            case .includeKeyword: "Include"
            default: String(describing: kind).prefix(1).uppercased() + String(describing: kind).dropFirst()
            }
            #expect(kind.bridgeName == expected, "\(kind)")
        }
    }

    @Test
    func concealsMarkersAndBuildsChipsFromTheSignature() throws {
        let plan = try plan(Sample.text)
        let source = Sample.text as NSString
        let concealed = plan.conceals.map { source.substring(with: $0) }
        #expect(concealed.contains("= "))
        #expect(concealed.contains("*") && concealed.contains("_") && concealed.contains("`"))
        #expect(concealed.contains("@") && concealed.contains("<") && concealed.contains(">"))
        let chips = plan.replacements.compactMap { replacement -> Chip? in
            if case let .chip(chip) = replacement.content {
                return chip
            }
            return nil
        }
        #expect(chips.map(\.label) == ["LB-001 标题 [已完成]"])
        #expect(chips.first?.arguments.map(\.name) == ["id", "title", "status"])
        #expect(plan.replacements.contains { $0.content == .bullet })
        #expect(plan.requests.contains {
            if case .math = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test
    func revealIsPerConstructAndTouchesEdges() throws {
        let strong = Sample.range("*粗体 bold*")
        for location in [strong.location, NSMaxRange(strong), strong.location + 3] {
            let plan = try plan(Sample.text, selection: NSRange(location: location, length: 0))
            #expect(!plan.isConcealed(strong.location))
            #expect(plan.isConcealed(Sample.range("_emph_").location), "other constructs stay concealed")
        }
        let paragraph = try {
            let tree = try #require(SyntaxTree(Sample.text))
            var input = PresentationInput(
                source: Sample.text as NSString,
                nodes: tree.nodes(),
                selection: NSRange(location: strong.location + 3, length: 0),
            )
            input.policy = .paragraph
            return Presentation.plan(input)
        }()
        #expect(!paragraph.isConcealed(Sample.range("_emph_").location), "paragraph policy reveals the line")
    }

    @Test
    func erroneousAndContentCallsStaySource() throws {
        let text = "#let f(a) = a\nOpen *unclosed\n\n#f[content] #f(1 + 2) #f(\"ok\")\n"
        let plan = try plan(text)
        let chips = plan.replacements.compactMap { replacement -> String? in
            if case let .chip(chip) = replacement.content {
                return (text as NSString).substring(with: chip.range)
            }
            return nil
        }
        #expect(chips == ["#f(\"ok\")"])
        #expect(!plan.isConcealed((text as NSString).range(of: "*unclosed").location))
    }

    @Test
    func formEditsWriteOneReplacementAndKeepFormatting() throws {
        let text = "#let item(id, title, status: \"todo\") = []\n#item(\"A\",  /* keep */ \"T\")\n"
        let plan = try plan(text)
        guard case let .chip(chip) = try #require(plan.replacements.first).content else {
            Issue.record("expected a chip")
            return
        }
        let edit = try #require(ChipEditing.edit(
            chip,
            values: ["id": "B\"1", "status": "done"],
            source: text as NSString,
        ))
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
        #expect(result.contains("#item(\"B\\\"1\",  /* keep */ \"T\", status: \"done\")"))
    }

    /// Incremental re-planning after edits and selection moves must equal a
    /// fresh full plan (the invariant the editor relies on).
    @Test
    func incrementalUpdatesMatchFullPlans() throws {
        var text = String(repeating: Sample.text, count: 20)
        let tree = try #require(SyntaxTree(text))
        var selection = NSRange(location: 0, length: 0)
        var signatures = Presentation.signatures(nodes: tree.nodes(), source: text as NSString)
        func input(_ text: String) -> PresentationInput {
            var input = PresentationInput(source: text as NSString, nodes: [], selection: selection)
            input.formatter = Sample.formatter
            input.signatures = signatures
            return input
        }
        var current = Presentation.plan({ var full = input(text)
            full.nodesOverride = tree.nodes()
            return full
        }())
        var generator = SeededGenerator(seed: 0x1019)
        let insertions = ["*", "x", "中", "\n", "#item(\"Z\", \"y\", \"todo\")", "_", "$", " "]
        for step in 0 ..< 400 {
            let length = (text as NSString).length
            if step.isMultiple(of: 3) {
                let old = selection
                if ProcessInfo.processInfo.environment["LB019_TRACE"] != nil {
                    print("MISMATCH op \(step) select from \(old) maxSpan \(current.maxSpan)")
                }
                selection = NSRange(location: Int.random(in: 0 ... length, using: &generator), length: 0)
                for window in [old, selection] {
                    current = Presentation.update(current, window: window, input: input(text)) { tree.nodes(in: $0) }
                        .plan
                }
            } else {
                let location = Int.random(in: 0 ... length, using: &generator)
                let removal = step.isMultiple(of: 5) ? min(3, length - location) : 0
                var range = NSRange(location: location, length: removal)
                range = (text as NSString).rangeOfComposedCharacterSequences(for: range)
                if removal == 0 {
                    range.length = 0
                }
                let insertion = insertions[step % insertions.count]
                let delta = (insertion as NSString).length - range.length
                let reparsed = try #require(tree.edit(range, replacement: insertion))
                text = (text as NSString).replacingCharacters(in: range, with: insertion)
                if selection.location > NSMaxRange(range) {
                    selection.location += delta
                } else if selection.location > range.location {
                    selection.location = range.location
                }
                let edited = NSRange(location: range.location, length: (insertion as NSString).length)
                if ProcessInfo.processInfo.environment["LB019_TRACE"] != nil {
                    print(
                        "MISMATCH op \(step) replace \(range) with \(insertion.debugDescription) reparsed \(reparsed) maxSpan \(current.maxSpan)",
                    )
                }
                let before = signatures
                signatures = Presentation.signatures(nodes: tree.nodes(), source: text as NSString)
                if signatures != before {
                    // A `#let` changed: every call of it may change (the session does the same).
                    var full = input(text)
                    full.nodesOverride = tree.nodes()
                    current = Presentation.plan(full)
                } else {
                    current = Presentation.update(
                        current.shifted(editing: range, delta: delta),
                        window: NSUnionRange(edited, reparsed),
                        input: input(text),
                    ) { tree.nodes(in: $0) }.plan
                }
            }
            var full = input(text)
            full.nodesOverride = tree.nodes()
            let expected = Presentation.plan(full)
            #expect(current.conceals == expected.conceals, "step \(step)")
            #expect(current.replacements == expected.replacements, "step \(step)")
            if current.conceals != expected.conceals || current.replacements != expected.replacements {
                let ns = text as NSString
                let extra = current.conceals.filter { !expected.conceals.contains($0) }
                let missing = expected.conceals.filter { !current.conceals.contains($0) }
                func show(_ ranges: [NSRange]) -> [String] {
                    ranges.map { "\($0.location)+\($0.length) \(ns.substring(with: $0).debugDescription) in " +
                        ns.substring(with: ns.paragraphRange(for: $0)).debugDescription
                    }
                }
                if let first = missing.first {
                    let paragraph = ns.paragraphRange(for: first)
                    var local = input(text)
                    local.nodesOverride = tree.nodes(in: paragraph)
                    let direct = Presentation.plan(local)
                    print(
                        "MISMATCH direct partial conceals \(direct.conceals.count) nodes \(local.nodesOverride?.count ?? 0) kinds \(local.nodesOverride?.prefix(6).map { "\($0.kind)\($0.range)" } ?? [])",
                    )
                }
                let extraR = current.replacements.filter { !expected.replacements.contains($0) }
                let missingR = expected.replacements.filter { !current.replacements.contains($0) }
                print("MISMATCH replacements extra \(extraR) missing \(missingR)")
                print("MISMATCH step \(step) selection \(selection) extra \(show(extra)) missing \(show(missing))")
                return
            }
        }
    }
}

/// Deterministic SplitMix64 so failures reproduce.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
