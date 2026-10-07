import CoreGraphics
import Foundation
@testable import LeftBlankCore
import Testing
import UniformTypeIdentifiers

/// A typesetter that lays out the synthetic document's probe calls without an engine.
/// Each equation is 10 pt wide per character and 12 pt tall with a 3 pt descent, at 10 pt text.
/// An equation containing `bad` fails at its location; `rulefail` in the rules fails them.
actor FakeMathTypesetter: MathTypesetter {
    private(set) var exports: [MathExport] = []
    private(set) var documents: [String] = []
    var unavailable = false
    /// Reports errors without a location, as an engine panic would.
    var unplaced = false
    var delay: Duration?
    /// Equations that fail as if they used an unknown variable.
    var failing: Set<String> = []

    func setFailing(_ value: Set<String>) {
        failing = value
    }

    func setUnavailable(_ value: Bool) {
        unavailable = value
    }

    func setUnplaced(_ value: Bool) {
        unplaced = value
    }

    func setDelay(_ value: Duration?) {
        delay = value
    }

    func export(_ export: MathExport, source: String, file: String, root _: URL?, directory _: URL?) async
        -> MathExportOutput
    {
        exports.append(export)
        documents.append(source)
        if let delay {
            try? await Task.sleep(for: delay)
        }
        guard !unavailable else {
            return .unavailable("no engine")
        }
        let lines = source.components(separatedBy: "\n")
        let rulesEnd = lines.firstIndex { $0.hasPrefix("#set page(") } ?? 0
        if let line = lines[..<rulesEnd].firstIndex(where: { $0.contains("rulefail") }) {
            return .failed(Self.report("unknown variable: rulefail", file: file, line: line + 1, column: 1))
        }
        var probes: [JSONValue] = []
        for (number, line) in lines.enumerated() where line.hasPrefix("\(MathDocument.probeLabel)(") {
            let body = line.dropFirst(MathDocument.probeLabel.count + 1)
            guard let comma = body.firstIndex(of: ","), let index = Int(body[..<comma]) else {
                continue
            }
            let equation = String(body[body.index(comma, offsetBy: 2)...].dropLast())
            if let bad = line.range(of: "bad") ?? (failing.contains(equation) ? line.range(of: equation) : nil) {
                let column = line.distance(from: line.startIndex, to: bad.lowerBound)
                return .failed(unplaced ? "engine panicked" : Self.report(
                    "unknown variable: bad",
                    file: file,
                    line: number + 1,
                    column: column,
                ))
            }
            probes.append(.object([
                "i": .number(Double(index)), "w": .number(Double(equation.count * 10)), "h": .number(12),
                "d": .number(3), "size": .number(10), "page": .number(Double(probes.count + 1)),
            ]))
        }
        switch export {
        case .probe:
            let data = try? JSONEncoder().encode(JSONValue.array(probes))
            return .completed(.object(["data": .string(data?.base64EncodedString() ?? "")]))
        case let .png(pages, ppi):
            let items = pages.compactMap { page -> JSONValue? in
                guard page <= probes.count, let width = probes[page - 1]["w"].double,
                      let png = testImage(
                          width: max(1, Int((width * ppi / 72).rounded())),
                          height: Int((12 * ppi / 72).rounded()),
                          type: .png,
                      )
                else {
                    return nil
                }
                return .object(["page": .number(Double(page - 1)), "data": .string(png.base64EncodedString())])
            }
            return .completed(.object(["total_pages": .number(Double(probes.count)), "items": .array(items)]))
        }
    }

    /// Tinymist's export error: Typst's report quoted as a Rust string.
    static func report(_ message: String, file: String, line: Int, column: Int) -> String {
        let body = "error: \(message)\n  ┌─ \(file):\(line):\(column)\n  │\n  = hint: check the name\n\n"
        let quoted = body.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\"", with: "\\\"")
        return "crates/tinymist/src/task/export.rs:606:17: ExportTask(0): document is not available for export: \"\(quoted)\""
    }
}

struct InlineMathTests {
    static let style = MathRenderStyle(fontSize: 16, color: MathColor(red: 0x37, green: 0x47, blue: 0x4F), scale: 2)

    func request(_ source: String, style: MathRenderStyle = style) -> MathRenderRequest {
        MathRenderRequest(source: source, isBlock: source.hasPrefix("$ "), style: style)
    }

    @Test func batchesDeduplicatesAndScalesToTheEditorFontSize() async throws {
        let typesetter = FakeMathTypesetter()
        let renderer = EngineMathRenderer(typesetter: typesetter)
        let requests = ["$a$", "$bb$", "$a$", "$ c $"].map { request($0) }
        let results = await renderer.render(requests)
        #expect(results.map(\.request) == requests)
        // One compile for the sizes and one for the pixels, for three unique equations.
        let exports = await typesetter.exports
        #expect(exports.count == 2 && exports.first == .probe)
        #expect(exports.last == .png(pages: [1, 2, 3], ppi: 72 * 2 * 1.6))
        let document = try #require(await typesetter.documents.first)
        #expect(document.components(separatedBy: "\n").count { $0.hasPrefix(MathDocument.probeLabel + "(") } == 3)
        #expect(document.contains("#set text(fill: rgb(55, 71, 79, 255))"))
        // Document text at 10 pt maps to the editor's 16 pt.
        let image = try #require(results[1].image)
        #expect(image.size == CGSize(width: 64, height: 12 * 1.6))
        #expect(abs(image.baseline - 14.4) < 1e-9 && abs(image.descent - 4.8) < 1e-9)
        #expect(image.image.width == 128 && image.image.height == 38 && abs(image.scale - 2) < 1e-9)
        #expect(image.fragment == RenderedFragment(size: image.size, baseline: image.baseline))
        #expect(results.allSatisfy { !$0.isStale && $0.diagnostics.isEmpty && !$0.failed })
        // Cached: no further compile, and a synchronous answer for layout.
        _ = await renderer.render(requests)
        #expect(await typesetter.exports.count == 2)
        #expect(renderer.cached(requests[0])?.image?.size == CGSize(width: 48, height: 12 * 1.6))
        #expect(renderer.cache.count == 3)
    }

    @Test func splitsBatchesByStyleAndSize() async {
        let typesetter = FakeMathTypesetter()
        let renderer = EngineMathRenderer(typesetter: typesetter, maximumBatch: 2)
        var dark = Self.style
        dark.color = MathColor(red: 0xE0, green: 0xE2, blue: 0xE5)
        let requests = ["$a$", "$b$", "$c$"].map { request($0) } + [request("$a$", style: dark)]
        let results = await renderer.render(requests)
        #expect(results.allSatisfy { $0.image != nil })
        // Two batches for the light style (2 + 1) and one for the dark one, each probed and drawn.
        let documents = await typesetter.documents
        #expect(documents.count == 6)
        #expect(documents.filter { $0.contains("rgb(224, 226, 229, 255)") }.count == 2)
    }

    @Test func concurrentRequestsShareOneCompile() async {
        let typesetter = FakeMathTypesetter()
        await typesetter.setDelay(.milliseconds(50))
        let renderer = EngineMathRenderer(typesetter: typesetter)
        let requests = ["$a$", "$b$"].map { request($0) }
        async let first = renderer.render(requests)
        async let second = renderer.render(requests.reversed())
        let (one, two) = await (first, second)
        #expect(one.allSatisfy { $0.image != nil } && two.allSatisfy { $0.image != nil })
        #expect(two.map(\.request) == requests.reversed())
        #expect(await typesetter.exports.count == 2)
    }

    @Test func errorsFailOnlyTheirEquationWithALocation() async throws {
        let typesetter = FakeMathTypesetter()
        let renderer = EngineMathRenderer(typesetter: typesetter)
        let requests = ["$a$", "$x + bad$", "$c$", "$bad$"].map { request($0) }
        let results = await renderer.render(requests)
        #expect(results[0].image != nil && results[2].image != nil)
        let failure = try #require(results[1].diagnostics.first)
        #expect(results[1].failed && results[1].image == nil && !results[1].isStale)
        #expect(failure.message == "unknown variable: bad\ncheck the name")
        #expect(failure.range == NSRange(location: 5, length: 0))
        #expect(results[3].diagnostics.first?.range == NSRange(location: 1, length: 0))
        // Failures are cached by source and style, so typing elsewhere does not recompile them.
        let count = await typesetter.exports.count
        _ = await renderer.render([requests[1]])
        #expect(await typesetter.exports.count == count)
    }

    @Test func unplacedErrorsSplitTheBatch() async {
        let typesetter = FakeMathTypesetter()
        await typesetter.setUnplaced(true)
        let renderer = EngineMathRenderer(typesetter: typesetter)
        let results = await renderer.render(["$a$", "$b$", "$bad$", "$d$", "$e$"].map { request($0) })
        #expect(results.map { $0.image != nil } == [true, true, false, true, true])
        #expect(results[2].diagnostics.map(\.message) == ["engine panicked"])
    }

    @Test func brokenRulesFallBackToPlainStylingWithAWarning() async {
        let typesetter = FakeMathTypesetter()
        let renderer = EngineMathRenderer(typesetter: typesetter)
        var style = Self.style
        style.preamble = "#set text(size: 10pt)\n#let x = rulefail"
        let results = await renderer.render([request("$a$", style: style), request("$bad$", style: style)])
        #expect(results[0].image != nil && !results[0].failed)
        #expect(results[0].diagnostics.map(\.severity) == [.warning])
        #expect(results[0].diagnostics.first?.message.contains("unknown variable: rulefail") == true)
        #expect(results[1].failed && results[1].diagnostics.map(\.severity) == [.error, .warning])
        #expect(await typesetter.documents.last?.contains("rulefail") == false)
    }

    @Test func styleChangesShowTheEarlierImageMarkedStale() async throws {
        let typesetter = FakeMathTypesetter()
        let renderer = EngineMathRenderer(typesetter: typesetter)
        let original = request("$a$")
        #expect(renderer.cached(original) == nil)
        _ = await renderer.render([original])
        var restyled = Self.style
        restyled.preamble = "#set text(size: 12pt)"
        let pending = request("$a$", style: restyled)
        // Until the new style renders, the earlier image is available, marked stale.
        let stale = try #require(renderer.cached(pending))
        #expect(stale.isStale && stale.image != nil && stale.request == pending && stale.diagnostics.isEmpty)
        let fresh = try #require(await renderer.render([pending]).first)
        #expect(!fresh.isStale && fresh.image != nil)
        #expect(renderer.cached(pending)?.isStale == false)
        // A failure keeps showing the last good rendering of that source, marked stale, with its errors.
        await typesetter.setFailing(["$a$"])
        restyled.preamble = "#set text(size: 14pt)"
        let failing = request("$a$", style: restyled)
        let failed = try #require(await renderer.render([failing]).first)
        #expect(failed.failed && failed.isStale && failed.image?.size == fresh.image?.size)
        let remembered = try #require(renderer.cached(failing))
        #expect(remembered.failed && remembered.isStale && remembered.image != nil)
        let exports = await typesetter.exports.count
        #expect(await renderer.render([failing]).first?.failed == true)
        #expect(await typesetter.exports.count == exports)
        // Without an earlier image, a failure has none.
        let unseen = try #require(await renderer.render([request("$bad$")]).first)
        #expect(unseen.failed && !unseen.isStale && unseen.image == nil)
        #expect(renderer.cached(unseen.request)?.image == nil)
    }

    @Test func anUnavailableEngineIsRetriedAndKeepsStaleImages() async throws {
        let typesetter = FakeMathTypesetter()
        let renderer = EngineMathRenderer(typesetter: typesetter)
        _ = await renderer.render([request("$a$")])
        await typesetter.setUnavailable(true)
        var larger = Self.style
        larger.fontSize = 20
        let result = try #require(await renderer.render([request("$a$", style: larger)]).first)
        #expect(result.failed && result.isStale && result.image != nil)
        #expect(result.diagnostics.map(\.message) == ["no engine"])
        await typesetter.setUnavailable(false)
        let retried = try #require(await renderer.render([request("$a$", style: larger)]).first)
        #expect(!retried.failed && !retried.isStale && retried.image?.size.width == 60)
    }

    @Test func oversizedEquationsFailWithoutRasterizing() async {
        let typesetter = FakeMathTypesetter()
        let renderer = EngineMathRenderer(typesetter: typesetter)
        let huge = "$" + String(repeating: "x", count: 1300) + "$"
        let results = await renderer.render([request(huge), request("$a$")])
        #expect(results[0].failed && results[0].diagnostics.first?.message.contains("too large") == true)
        #expect(results[1].image != nil)
        #expect(await typesetter.exports.last == .png(pages: [2], ppi: 72 * 2 * 1.6))
    }

    @Test func cacheEvictsLeastRecentlyUsedImagesWithinItsBounds() throws {
        let image = try #require(testImage(width: 32, height: 32, type: .png).flatMap(EngineMathRenderer.decode))
        let cache = MathRenderCache(maximumCost: image.bytesPerRow * image.height * 4, maximumCount: 100)
        let requests = (0 ..< 5).map { request("$\($0)$") }
        func store(_ request: MathRenderRequest) {
            cache.store(MathRenderResult(
                request: request,
                image: MathImage(image: image, size: CGSize(width: 16, height: 16), baseline: 12),
                diagnostics: [],
                isStale: false,
            ))
        }
        requests.prefix(4).forEach(store)
        #expect(cache.count == 4)
        _ = cache.lookup(requests[0])
        // Over budget: evict the least recently used down to three quarters.
        store(requests[4])
        #expect(cache.cost <= cache.maximumCost * 3 / 4 && cache.count == 3)
        #expect(cache.lookup(requests[0]) != nil && cache.lookup(requests[4]) != nil)
        #expect(cache.lookup(requests[1]) == nil && cache.lookup(requests[2]) == nil)
        // Stale results and engine outages are never stored.
        cache.store(MathRenderResult(request: request("$s$"), image: nil, diagnostics: [], isStale: true))
        var outage = MathRenderResult(request: request("$t$"), image: nil, diagnostics: [MathDiagnostic(
            severity: .error,
            message: "no engine",
        )], isStale: false)
        outage.isTransient = true
        cache.store(outage)
        #expect(cache.count == 3)
        cache.removeAll()
        #expect(cache.isEmpty && cache.cost == 0 && cache.lookup(requests[4]) == nil)
    }

    @Test func documentPlacesEachEquationAndMapsErrorsBack() throws {
        let equations = ["$a$", "$ x \\\r\n  y + 中文😀z $", "$b$"]
        let document = MathDocument(equations, style: Self.style, preamble: "#set text(size: 9pt)\n#let f(x) = x")
        let lines = document.source.components(separatedBy: "\n")
        #expect(document.preambleLines == 2 && lines[0] == "#set text(size: 9pt)")
        for (placement, equation) in zip(document.placements, equations) {
            let line = lines[placement.line - 1]
            #expect(line.hasPrefix(MathDocument.probeLabel + "(") && line.unicodeScalars.count >= placement.column)
            #expect(equation.hasPrefix(String(String.UnicodeScalarView(line.unicodeScalars.dropFirst(placement.column)
                    .prefix(3)))))
        }
        #expect(MathDocument.lineBreaks(in: "a\r\nb\rc\nd\u{2028}") == 4)
        let second = document.placements[1]
        // Line 2 of the display equation, after the CJK text and emoji (scalars, not UTF-16 units).
        let error = MathDocument.EngineError(message: "m", path: "f.typ", line: second.line + 1, column: 9)
        let located = try #require(document.locate(error, file: "f.typ", equations: equations))
        #expect(located.index == 1)
        #expect(located.offset == ("$ x \\\r\n  y + 中文😀" as NSString).length)
        let first = MathDocument.EngineError(
            message: "m",
            path: "/x/f.typ",
            line: second.line,
            column: second.column + 2,
        )
        let start = try #require(document.locate(first, file: "f.typ", equations: equations))
        #expect(start.index == 1 && start.offset == 2)
        // Errors in the rules, another file or without a location belong to no equation.
        for other in [MathDocument.EngineError(message: "m", path: "f.typ", line: 2, column: 0),
                      MathDocument.EngineError(message: "m", path: "g.typ", line: second.line, column: 0),
                      MathDocument.EngineError(message: "m", path: nil, line: nil, column: nil)]
        {
            #expect(document.locate(other, file: "f.typ", equations: equations) == nil)
        }
        let parsed = MathDocument.errors(in: FakeMathTypesetter.report(
            "bad: \"q\"",
            file: "a:b.typ",
            line: 3,
            column: 4,
        ))
        #expect(parsed == [MathDocument.EngineError(
            message: "bad: \"q\"\ncheck the name",
            path: "a:b.typ",
            line: 3,
            column: 4,
        )])
        #expect(MathDocument.unescape(#"a\tb\\c\"\r"#) == "a\tb\\c\"\r")
    }

    @Test func preambleKeepsTopLevelRulesAndSkipsTemplatesAndContent() throws {
        try #require(SyntaxTree.isAvailable)
        let source = """
        #import "template.typ": *
        #set text(font: "Libertinus Serif", size: 11pt)
        #show: project.with(title: "Book")
        #show math.equation: set text(fill: blue)
        = Heading $x$
        #let R = math.bb("R")
        Body #set text(red) inline
        #block[#set text(size: 20pt)]
        #let broken(x =
        """
        #expect(MathPreamble.extract(source: source) == """
        #import "template.typ": *
        #set text(font: "Libertinus Serif", size: 11pt)
        #show math.equation: set text(fill: blue)
        #let R = math.bb("R")
        #set text(red)
        """)
        #expect(MathPreamble.extract(source: "Just $x$ text").isEmpty)
    }

    @Test func requestsAndColoursComeFromThePresentationModel() throws {
        let plan = InlineRequest.math(range: NSRange(location: 3, length: 5), source: "$ x $", isBlock: true)
        let request = try #require(MathRenderRequest(plan, style: Self.style))
        #expect(request.source == "$ x $" && request.isBlock && request.style == Self.style)
        #expect(MathRenderRequest(.image(range: NSRange(), path: "a.png"), style: Self.style) == nil)
        let color = try #require(MathColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.5)))
        #expect(color == MathColor(red: 255, green: 128, blue: 0, alpha: 128))
        #expect(MathColor(CGColor(gray: 0, alpha: 1)) == MathColor(red: 0, green: 0, blue: 0))
        #expect(color.typst == "rgb(255, 128, 0, 128)")
    }
}
