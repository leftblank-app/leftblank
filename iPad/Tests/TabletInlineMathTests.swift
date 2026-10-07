import CoreGraphics
import Foundation
import LeftBlankCore
@testable import LeftBlankTablet
import LeftBlankTestSupport
import Testing

/// The embedded engine renders equations in the simulator exactly as the Mac helper does.
@MainActor
struct TabletInlineMathTests {
    @Test func embeddedEngineRendersEquationsWithBaselinesColoursAndDiagnostics() async throws {
        let root = TestPaths.temporaryDirectory.appendingPathComponent("inline-math-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = TabletWorkspace(stateDirectory: root)
        let renderer = workspace.makeInlineMathRenderer()
        let color = MathColor(red: 0xE0, green: 0xE2, blue: 0xE5)
        let style = MathRenderStyle(fontSize: 17, color: color, preamble: "#set text(size: 11pt)", scale: 2)
        let sources = ["$x$", "$(a+b)/(c+d)$", "$ a &= b \\ c &= d $", "$x + foo$"]
        let start = ContinuousClock.now
        let results = await renderer.render(sources.map {
            MathRenderRequest(source: $0, isBlock: $0.hasPrefix("$ "), style: style)
        })
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(30), "first batch with engine start took \(elapsed)")
        for result in results.prefix(3) {
            let image = try #require(result.image, "\(result.request.source): \(result.diagnostics)")
            #expect(result.diagnostics.isEmpty && !result.isStale)
            #expect(abs(Double(image.image.width) - image.size.width * 2) <= 1)
            #expect(abs(Double(image.image.height) - image.size.height * 2) <= 1)
        }
        let x = try #require(results[0].image)
        let xInk = try #require(MathBitmap(x.image))
        #expect(try abs(#require(xInk.inkRows.last).bottom / 2 - x.baseline) <= 0.5)
        let ink = xInk.inkColor
        #expect(abs(Int(ink.red) - Int(color.red)) <= 10 && abs(Int(ink.blue) - Int(color.blue)) <= 10)
        // The fraction bar lies on the maths axis, 0.25 em above the baseline.
        let fraction = try #require(results[1].image)
        let bar = try #require(MathBitmap(fraction.image)?.widestRow)
        #expect(abs(bar / 2 - (fraction.baseline - 0.25 * 17)) <= 0.5)
        // A display equation keeps its first line's baseline.
        let block = try #require(results[2].image)
        let bands = try #require(MathBitmap(block.image)?.inkRows)
        let firstLine = try #require(bands.first)
        #expect(abs(firstLine.bottom / 2 - block.baseline) <= 0.5, "\(bands), \(block.size), \(block.baseline)")
        // Invalid maths fails alone, with the engine's message at its location.
        let failure = try #require(results[3].diagnostics.first)
        #expect(results[3].failed && results[3].image == nil)
        #expect(failure.message.contains("unknown variable: foo") && failure.range?.location == 5)
        #expect(renderer.cached(results[0].request)?.image != nil)
    }
}
