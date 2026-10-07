#if os(macOS)
    import CoreGraphics
    import Foundation
    @testable import LeftBlankCore
    import LeftBlankTestSupport
    import Testing

    /// The real Mac engine: a dedicated Tinymist helper renders each equation in a fitted page.
    @MainActor
    @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LEFTBLANK_INTEGRATION"] == "1"))
    struct InlineMathEngineTests {
        static let light = MathColor(red: 0x37, green: 0x47, blue: 0x4F)
        static let dark = MathColor(red: 0xE0, green: 0xE2, blue: 0xE5)

        private func renderer() throws -> (EngineMathRenderer, TinymistMathTypesetter, URL) {
            let directory = TestPaths.temporaryDirectory.appendingPathComponent("inline-math-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let typesetter = TinymistMathTypesetter(workDirectory: directory.appendingPathComponent("Engine"))
            return (EngineMathRenderer(typesetter: typesetter), typesetter, directory)
        }

        private func style(
            _ color: MathColor = light,
            preamble: String = "#set text(size: 11pt)",
            directory: URL? = nil,
        )
            -> MathRenderStyle
        {
            MathRenderStyle(fontSize: 16, color: color, preamble: preamble, scale: 2, directory: directory)
        }

        @Test func equationsRenderWithExactSizesBaselinesAndThemeColours() async throws {
            let (renderer, typesetter, directory) = try renderer()
            defer {
                typesetter.stop()
                try? FileManager.default.removeItem(at: directory)
            }
            let sources = ["$x$", "$y$", "$(a+b)/(c+d)$", "$sum_(i=0)^n x_i^2$", "$ a &= b \\ c &= d + e $", "$x_1$"]
            let requests = sources.map {
                MathRenderRequest(source: $0, isBlock: $0.hasPrefix("$ "), style: style())
            }
            let results = await renderer.render(requests)
            #expect(results.map(\.request) == requests)
            #expect(typesetter.starts == 1)
            var images: [String: (MathImage, MathBitmap)] = [:]
            for result in results {
                #expect(result.diagnostics.isEmpty, "\(result.request.source): \(result.diagnostics)")
                #expect(!result.isStale)
                let image = try #require(result.image, "\(result.request.source)")
                // The image covers the box at the requested scale, to Typst's pixel rounding.
                #expect(abs(Double(image.image.width) - image.size.width * 2) <= 1)
                #expect(abs(Double(image.image.height) - image.size.height * 2) <= 1)
                #expect(abs(image.scale - 2) < 0.1)
                #expect(image.baseline > 0 && image.baseline <= image.size.height)
                images[result.request.source] = try (image, #require(MathBitmap(image.image)))
            }
            // An x sits on the baseline; its ink ends there, within its 0.3 pt overshoot.
            let (x, xInk) = try #require(images["$x$"])
            let xBottom = try #require(xInk.inkRows.last).bottom / 2
            #expect(abs(xBottom - x.baseline) <= 0.5, "x ink ends at \(xBottom), baseline \(x.baseline)")
            #expect(x.descent < 0.5)
            // A descender reaches below the baseline, to the bottom of the box.
            let (y, yInk) = try #require(images["$y$"])
            #expect(y.descent > 2.5)
            #expect(try abs(#require(yInk.inkRows.last).bottom / 2 - y.size.height) <= 0.5)
            #expect(abs(y.baseline - x.baseline) <= 0.5)
            // A fraction bar lies on the maths axis: 0.25 em above the baseline in New Computer Modern Math.
            let (fraction, fractionInk) = try #require(images["$(a+b)/(c+d)$"])
            let bar = try #require(fractionInk.widestRow)
            #expect(
                abs(bar / 2 - (fraction.baseline - 0.25 * 16)) <= 0.5,
                "bar \(bar / 2), baseline \(fraction.baseline)",
            )
            #expect(fraction.descent > 4 && fraction.size.height > x.size.height + 6)
            // Limits and attachments extend the box both ways, and keep x's baseline height above them.
            let (sum, _) = try #require(images["$sum_(i=0)^n x_i^2$"])
            #expect(sum.descent > 2 && sum.size.width > 40)
            let (subscripted, subscriptInk) = try #require(images["$x_1$"])
            #expect(subscripted.descent > 1.5)
            // The x of x_1 stands as high above the baseline as a lone x.
            let xTop = try x.baseline - #require(xInk.inkRows.first).top / 2
            #expect(try abs(subscripted.baseline - #require(subscriptInk.inkRows.first).top / 2 - xTop) <= 0.5)
            // A display equation keeps its first line's baseline: the first band of ink ends there.
            let (block, blockInk) = try #require(images["$ a &= b \\ c &= d + e $"])
            let firstLine = try #require(blockInk.inkRows.first)
            #expect(
                abs(firstLine.bottom / 2 - block.baseline) <= 0.5,
                "first line \(firstLine), baseline \(block.baseline)",
            )
            #expect(blockInk.inkRows.count == 2 && block.descent > 10)
            // The editor's colour, not the document's black.
            #expect(xInk.inkColor.isClose(to: Self.light), "\(xInk.inkColor)")
            let darkResult = try #require(await renderer.render([MathRenderRequest(
                source: "$x$",
                isBlock: false,
                style: style(Self.dark),
            )]).first)
            let darkImage = try #require(darkResult.image)
            #expect(try #require(MathBitmap(darkImage.image)).inkColor.isClose(to: Self.dark))
            #expect(abs(darkImage.baseline - x.baseline) < 0.01 && darkImage.size == x.size)
            // A cached request costs no engine call.
            let starts = typesetter.starts
            let again = await renderer.render(requests)
            #expect(again.allSatisfy { $0.image != nil && !$0.isStale } && typesetter.starts == starts)
        }

        @Test func editorSizeScalesTheDocumentAndRulesStillApply() async throws {
            let (renderer, typesetter, directory) = try renderer()
            defer {
                typesetter.stop()
                try? FileManager.default.removeItem(at: directory)
            }
            try Data("#let R = math.bb(\"R\")\n".utf8).write(to: directory.appendingPathComponent("macros.typ"))
            func render(_ source: String, preamble: String) async throws -> MathRenderResult {
                try #require(await renderer.render([MathRenderRequest(
                    source: source,
                    isBlock: false,
                    style: style(preamble: preamble, directory: directory),
                )]).first)
            }
            let small = try #require(try await render("$x + y$", preamble: "#set text(size: 8pt)").image)
            let large = try #require(try await render("$x + y$", preamble: "#set text(size: 20pt)").image)
            // Either document size maps to the editor's 16 pt.
            #expect(abs(small.size.width - large.size.width) < 0.6 && abs(small.baseline - large.baseline) < 0.6)
            let bigger = try #require(try await render(
                "$x + y$",
                preamble: "#set text(size: 10pt)\n#show math.equation: set text(size: 1.5em, fill: red)",
            ).image)
            #expect(abs(bigger.size.width / small.size.width - 1.5) < 0.1)
            #expect(try #require(MathBitmap(bigger.image)).inkColor.isClose(to: Self.light))
            // Relative imports resolve beside the document.
            let imported = try await render("$R^n$", preamble: "#import \"macros.typ\": R")
            #expect(imported.image != nil && imported.diagnostics.isEmpty, "\(imported.diagnostics)")
            // Broken rules fall back to plain styling with a warning.
            let broken = try await render("$x$", preamble: "#import \"missing.typ\": *")
            #expect(broken.image != nil && !broken.failed)
            #expect(broken.diagnostics.map(\.severity) == [.warning])
        }

        @Test func invalidMathReturnsDiagnosticsAndTheRestOfTheBatchRenders() async throws {
            let (renderer, typesetter, directory) = try renderer()
            defer {
                typesetter.stop()
                try? FileManager.default.removeItem(at: directory)
            }
            let sources = ["$a + b$", "$x + foo$", "$ c \\\n  \"中文\" + baz $", "$e^x$"]
            let results = await renderer.render(sources.map {
                MathRenderRequest(source: $0, isBlock: $0.hasPrefix("$ "), style: style())
            })
            #expect(results[0].image != nil && results[3].image != nil)
            #expect(results[0].diagnostics.isEmpty && results[3].diagnostics.isEmpty)
            let foo = try #require(results[1].diagnostics.first)
            #expect(results[1].failed && results[1].image == nil)
            #expect(foo.message.contains("unknown variable: foo"), "\(foo.message)")
            #expect(foo.range == NSRange(location: 5, length: 0))
            // A later line of a display equation, after CJK text.
            let baz = try #require(results[2].diagnostics.first)
            #expect(baz.message.contains("unknown variable: baz"))
            #expect(baz.range?.location == ("$ c \\\n  \"中文\" + " as NSString).length)
            // Fixing the equation renders it; the failure was cached by source, not position.
            let fixed = await renderer.render([MathRenderRequest(
                source: "$x + f o o$",
                isBlock: false,
                style: style(),
            )])
            #expect(fixed.first?.image != nil)
            #expect(renderer.cached(results[1].request)?.failed == true)
        }

        @Test func everyEquationInSICPRendersInItsBookContext() async throws {
            let (renderer, typesetter, directory) = try renderer()
            defer {
                typesetter.stop()
                try? FileManager.default.removeItem(at: directory)
            }
            let book = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Examples/Books/SICP")
            let source = try String(contentsOf: book.appendingPathComponent("main.typ"), encoding: .utf8)
            let nodes = try #require(SyntaxTree(source)?.nodes())
            let text = source as NSString
            let equations = nodes.filter { $0.kind == .equation && !$0.isErroneous }
                .map { text.substring(with: $0.range) }
            let style = MathRenderStyle(
                fontSize: 16,
                color: Self.light,
                preamble: MathPreamble.extract(source: source, nodes: nodes),
                directory: book,
            )
            #expect(style.preamble.contains("styles/book.typ"))
            let requests = equations.map {
                MathRenderRequest(
                    source: $0,
                    isBlock: $0.count > 2 && $0.dropFirst().first?.isWhitespace == true &&
                        $0.dropLast().last?.isWhitespace == true,
                    style: style,
                )
            }
            let start = ContinuousClock.now
            let results = await renderer.render(requests)
            let cold = ContinuousClock.now - start
            let failures = results.filter(\.failed)
            #expect(failures.isEmpty, "\(failures.prefix(3).map { ($0.request.source, $0.diagnostics) })")
            let warm = ContinuousClock.now
            _ = await renderer.render(requests)
            let cached = ContinuousClock.now - warm
            print("SICP inline math: \(equations.count) equations, \(Set(requests).count) unique, " +
                "\(milliseconds(cold)) ms with engine start, \(milliseconds(cached)) ms cached, " +
                "\(renderer.cache.cost / 1024) KiB decoded" +
                (helperResidentKiB().map { ", helper \($0 / 1024) MiB" } ?? ""))
            #expect(equations.count > 1000 && cold < .seconds(30) && cached < .seconds(1))
        }

        @Test func batchesOfOneTwentyAndTwoHundredEquationsStayWithinBudget() async throws {
            let (renderer, typesetter, directory) = try renderer()
            defer {
                typesetter.stop()
                try? FileManager.default.removeItem(at: directory)
            }
            // The first request starts the engine; later batches reuse it.
            let cold = ContinuousClock.now
            _ = await renderer.render([MathRenderRequest(source: "$0$", isBlock: false, style: style())])
            var report = ["first request with engine start: \(milliseconds(ContinuousClock.now - cold)) ms"]
            let shapes = ["$x_%d^2$", "$(a + %d)/(b - 1)$", "$sum_(i=0)^%d i$", "$sqrt(x^2 + %d)$",
                          "$integral_0^%d f(x) dif x$", "$mat(1, %d; 3, 4)$", "$ a &= %d \\ b &= c $", "$alpha + %d$"]
            var salt = 0
            for count in [1, 20, 200] {
                let requests = (0 ..< count).map { index -> MathRenderRequest in
                    salt += 1
                    let source = String(format: shapes[index % shapes.count], salt)
                    return MathRenderRequest(source: source, isBlock: source.hasPrefix("$ "), style: style())
                }
                let start = ContinuousClock.now
                let results = await renderer.render(requests)
                let elapsed = ContinuousClock.now - start
                #expect(results.allSatisfy { $0.image != nil && $0.diagnostics.isEmpty })
                report.append("\(count): \(milliseconds(elapsed)) ms")
                // About 20 times the local M4 Pro results, for shared CI runners.
                #expect(elapsed < .seconds(count == 200 ? 8 : 2), "\(count) equations took \(elapsed)")
            }
            let cost = renderer.cache.cost
            report.append("cache \(renderer.cache.count) images, \(cost / 1024) KiB decoded")
            if let resident = helperResidentKiB() {
                report.append("helper resident \(resident / 1024) MiB")
            }
            print("Inline math render times: " + report.joined(separator: ", "))
            #expect(cost < 32 << 20)
        }
    }

    private func milliseconds(_ duration: Duration) -> Int {
        Int(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
    }

    /// Resident memory of this process's Tinymist helpers, from `ps`.
    private func helperResidentKiB() -> Int? {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "ppid=,rss=,comm="]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else {
            return nil
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let parent = String(ProcessInfo.processInfo.processIdentifier)
        return output.split(separator: "\n").compactMap { line -> Int? in
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, fields[0] == parent, fields[2].hasSuffix("tinymist") else {
                return nil
            }
            return Int(fields[1])
        }.max()
    }

    extension MathBitmap.Color {
        func isClose(to other: MathColor) -> Bool {
            abs(Int(red) - Int(other.red)) <= 10 && abs(Int(green) - Int(other.green)) <= 10
                && abs(Int(blue) - Int(other.blue)) <= 10
        }
    }
#endif
