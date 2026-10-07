import Foundation
import LeftBlankCore
import Testing

struct PreviewCallSiteTests {
    static let tracker = """
    #let status(s) = [#s]
    #let item(id, title, s, source: "你") = [
      #metadata((id: id, title: title, status: s, source: source)) <item>
      == #id #title #h(1fr) #status(s)
    ]
    #item("LB-001", "大文档检查时预览没有提示", "done")
    #item("LB-002", "部分示例无法渲染", "done", source: "评审")
    """

    /// Where Tinymist puts a click on text displayed from `name`: the identifier in the body.
    func parameter(_ name: String, in source: String, after marker: String = "== ") -> Int {
        let body = (source as NSString).range(of: marker).location
        return (source as NSString).range(of: name, range: NSRange(location: body, length: source.utf16.count - body))
            .location
    }

    func offset(of text: String, in source: String) -> Int {
        (source as NSString).range(of: text).location
    }

    func remap(_ target: Int, in source: String, _ text: String?, line: String = "") -> Int {
        PreviewCallSite.offset(target, in: source, click: text.flatMap { PreviewClick(text: $0, line: line) })
    }

    @Test func positionalParameterJumpsToTheCallWithTheClickedCJKText() {
        let source = Self.tracker
        let id = parameter("#id", in: source) + 1
        #expect(remap(id, in: source, "LB-001 ") == offset(of: "LB-001\"", in: source))
        #expect(remap(id, in: source, "LB-002") == offset(of: "LB-002\"", in: source))
        // The jump may arrive on the `#` before the identifier.
        #expect(remap(id - 1, in: source, "LB-002") == offset(of: "LB-002\"", in: source))
        let title = parameter("title", in: source)
        #expect(remap(title, in: source, "部分示例无法渲染") == offset(of: "部分示例", in: source))
        // A run inside a longer literal lands on that run, not the literal's start.
        #expect(remap(title, in: source, "预览没有") == offset(of: "预览没有", in: source))
        // A run that contains the whole literal lands on the literal.
        #expect(remap(id, in: source, "Item LB-001 here") == offset(of: "LB-001\"", in: source))
    }

    @Test func namedArgumentsAndForwardedParametersReachTheCall() {
        let source = Self.tracker
        let metadata = offset(of: "source: source", in: source) + "source: ".utf16.count
        #expect(remap(metadata, in: source, "评审") == offset(of: "评审", in: source))
        // The default applies where the argument is omitted; no call supplies 你.
        #expect(remap(metadata, in: source, "你") == metadata)
        // `done` renders through `status(s)`. Both calls pass "done"; the clicked line tells them apart.
        let status = parameter("#s]", in: source, after: "#let status") + 1
        let first = offset(of: "\"done\"", in: source) + 1
        let second = (source as NSString).range(of: "\"done\"", options: .backwards).location + 1
        #expect(remap(status, in: source, "done", line: "LB-001 大文档检查时预览没有提示done") == first)
        #expect(remap(status, in: source, "done", line: "LB-002 部分示例无法渲染done") == second)
        // Without a distinguishing line the target stays at the single forwarding call.
        #expect(remap(status, in: source, "done") == parameter("(s)", in: source) + 1)
    }

    @Test func unmatchedOrUnrelatedTargetsStayWhereTheyAre() {
        let source = Self.tracker
        let id = parameter("#id", in: source) + 1
        #expect(remap(id, in: source, "LB-404") == id)
        #expect(remap(id, in: source, nil) == id, "Several calls need clicked text to choose")
        #expect(remap(parameter("#h", in: source), in: source, "LB-001") == parameter("#h", in: source))
        let call = offset(of: "LB-001", in: source)
        #expect(remap(call, in: source, "LB-001") == call, "A call argument is not a function body")
        let plain = "= Heading\n\nSome #emph[id] text, LB-001.\n#let id = \"LB-001\"\n#id\n"
        let target = (plain as NSString).range(of: "id", options: .backwards).location
        #expect(remap(target, in: plain, "LB-001") == target, "A variable is not a parameter")
        #expect(remap(-1, in: plain, "x") == -1)
        #expect(remap(plain.utf16.count, in: plain, "x") == plain.utf16.count)
        // Equal arguments without a distinguishing line are ambiguous.
        let twice = "#let tag(t) = [#t]\n#tag(\"same\")\n#tag(\"same\")\n"
        let body = parameter("t]", in: twice, after: "[#")
        #expect(remap(body, in: twice, "same") == body)
    }

    @Test func singleCallSiteIsUsedWithoutClickedText() {
        let source = "#let note(body, by: none) = block[#body (#by)]\n\nIntro.\n#note([Read *this* first], by: \"Ana\")\n"
        let body = parameter("body (", in: source, after: "block[")
        #expect(remap(body, in: source, nil) == offset(of: "Read", in: source))
        #expect(remap(body, in: source, "this") == offset(of: "this", in: source))
        let by = parameter("by)", in: source, after: "block[")
        #expect(remap(by, in: source, nil) == offset(of: "Ana", in: source))
    }

    @Test func codeCallsTrailingContentAndEscapedStringsAreRecognized() {
        let source = #"""
        #let row(label, value) = {
          let shown = [#label: #value]
          shown
        }
        // row("LB-404", "comment")
        #row("say \"hi\"", "plain (x)")
        #{
          let rows = (row("a\u{1F600}b", [nested, "text"]), row("tab\tbed", "x"))
          rows.join()
        }
        #row("literal")[Trailing *content*]
        """#
        let label = parameter("label:", in: source, after: "[#")
        let value = parameter("value]", in: source, after: "[#")
        #expect(remap(label, in: source, "say \"hi\"") == offset(of: #"say \"hi"#, in: source))
        #expect(remap(label, in: source, "\"hi\"") == offset(of: #"\"hi"#, in: source))
        #expect(remap(value, in: source, "plain (x)") == offset(of: "plain (x)", in: source))
        #expect(remap(label, in: source, "😀b") == offset(of: #"\u{1F600}b"#, in: source))
        #expect(remap(label, in: source, "bed") == offset(of: "bed", in: source))
        #expect(remap(value, in: source, "nested, \"text\"") == offset(of: "nested, \"text\"", in: source))
        #expect(remap(value, in: source, "Trailing content") == value, "Markup differs from its rendered text")
        #expect(remap(value, in: source, "content") == offset(of: "content*", in: source))
        #expect(remap(label, in: source, "LB-404") == label, "Comments hold no calls")
    }

    @Test func shadowedSpreadAndDestructuredParametersStayConservative() {
        let shadow = "#let f(x) = [#x]\n#f(\"one\")\n#let f(x) = [*#x*]\n#f(\"two\")\n"
        let first = parameter("x]", in: shadow, after: "[#")
        #expect(remap(first, in: shadow, nil) == offset(of: "one", in: shadow))
        #expect(remap(first, in: shadow, "two") == offset(of: "one", in: shadow), "Only calls before the shadow")
        let spread = "#let g(a, b) = [#a #b]\n#let args = (\"p\",)\n#g(..args, \"q\")\n#g(\"r\", \"s\")\n"
        let b = parameter("b]", in: spread, after: "#a #")
        #expect(remap(b, in: spread, "q") == b, "A spread hides the position of later arguments")
        #expect(remap(b, in: spread, "s") == offset(of: "s\"", in: spread))
        let destructured = "#let h((a, b), c) = [#a #c]\n#h((\"x\", \"y\"), \"z\")\n"
        let c = parameter("c]", in: destructured, after: "#a #")
        #expect(remap(c, in: destructured, "z") == offset(of: "z", in: destructured))
        let a = parameter("a #", in: destructured, after: "[#")
        #expect(remap(a, in: destructured, "x") == a)
    }

    @Test func previewJumpColumnsCountUnicodeScalars() throws {
        let text = "😀 Plain *text* here.\n中文😀x\r\nend"
        func location(_ line: Int, _ character: Int, scalar: Bool = true) throws -> LeftBlankCore.SourceLocation {
            try #require(SourceLocation(.object([
                "uri": .string("file:///tmp/a.typ"),
                "selection": .object(["start": .object([
                    "line": .number(Double(line)), "character": .number(Double(character)),
                ])]),
            ]), scalarColumns: scalar))
        }
        #expect(try location(0, 14).offset(in: text) == 15)
        #expect(try location(0, 14, scalar: false).offset(in: text) == 14)
        #expect(try location(1, 3).offset(in: text) == offset(of: "x\r", in: text))
        #expect(try location(1, 99).offset(in: text) == offset(of: "\r", in: text))
        #expect(try location(9, 0).offset(in: text) == text.utf16.count)
    }

    @MainActor @Test func sessionPairsOneRecentClick() {
        let session = PreviewReadingSession()
        let start = ContinuousClock.now
        session.receive(["kind": "click", "text": " LB-001 ", "line": "LB-001 x"])
        #expect(session.takeClick() == PreviewClick(text: "LB-001", line: "LB-001 x"))
        #expect(session.takeClick() == nil, "A click pairs with one jump")
        session.observe(PreviewClick(text: "late"), at: start)
        #expect(session.takeClick(at: start + .seconds(3)) == nil)
        session.receive(["kind": "click", "text": "   "])
        #expect(session.takeClick() == nil)
        session.observe(PreviewClick(text: "reset"))
        session.reset()
        #expect(session.takeClick() == nil)
        session.receive([
            "kind": "manualScroll",
            "anchor": ["page": 0, "x": 0.5, "y": 0.5, "viewportY": 0.2] as [String: Any],
        ])
        #expect(session.anchor?.page == 0)
    }
}
