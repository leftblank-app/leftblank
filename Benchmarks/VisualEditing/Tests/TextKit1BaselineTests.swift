import CoreGraphics
import Foundation
import Testing
@testable import VisualEditing
import VisualPresentation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Baseline: the same plan through TextKit 1 null/control glyphs
/// (`ConcealingLayoutManager`), on NSTextView and UITextView(TK1).
@MainActor
@Suite(.serialized)
struct TextKit1BaselineTests {
    func open() throws -> (Harness, ConcealingLayoutManager, DisplayPlan) {
        let manager = ConcealingLayoutManager()
        let harness = Harness(text: Sample.text, textKit1: manager)
        let tree = try #require(SyntaxTree(Sample.text))
        let nodes = tree.nodes()
        var input = PresentationInput(source: Sample.text as NSString, nodes: nodes, selection: Sample.away)
        input.formatter = Sample.formatter
        input.signatures = Presentation.signatures(nodes: nodes, source: Sample.text as NSString)
        let plan = Presentation.plan(input)
        manager.apply(plan)
        harness.layout()
        return (harness, manager, plan)
    }

    func x(_ offset: Int, _ manager: NSLayoutManager) -> CGFloat {
        let glyph = manager.glyphIndexForCharacter(at: offset)
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.minX + manager.location(forGlyphAt: glyph).x
    }

    @Test
    func nullGlyphsConcealAndControlGlyphSizesTheChip() throws {
        let (harness, manager, plan) = try open()
        defer { harness.close() }
        #expect(harness.manager == nil, "explicit TK1 stack")
        #expect(harness.string == Sample.text)
        let strong = Sample.range("*粗体 bold*")
        let widths = [x(strong.location + 1, manager) - x(strong.location, manager),
                      x(NSMaxRange(strong), manager) - x(NSMaxRange(strong) - 1, manager)]
        let call = Sample.range("#item(\"LB-001\", \"标题\", \"done\")")
        let chipWidth = x(NSMaxRange(call), manager) - x(call.location, manager)
        let label = try #require(plan.replacements.compactMap { replacement -> String? in
            if case let .chip(chip) = replacement.content {
                return chip.label
            }
            return nil
        }.first)
        Report.record("tk1.markerWidths", widths)
        Report.record("tk1.chip.width", ["layout": chipWidth, "box": ChipDrawing.width(of: label)])
        #expect(widths.allSatisfy { abs($0) < 0.5 })
        #expect(abs(chipWidth - ChipDrawing.width(of: label)) < 1)
        // Pointer and IME geometry come from the same glyphs.
        let caret = harness.nativeCaret(NSMaxRange(call) + 6)
        harness.selection = NSRange(location: NSMaxRange(call) + 6, length: 0)
        harness.setMarkedText("zhong")
        let marked = harness.markedFirstRect()
        Report.record("tk1.ime", ["caret": caret.minX, "marked": marked.minX])
        #expect(abs(marked.minX - caret.minX) < 2)
        harness.commitMarkedText("中")
        harness.undo()
        #expect(harness.string == Sample.text)
        let inside = CGPoint(x: x(call.location, manager) + chipWidth / 2, y: caret.midY)
        let hit = harness.nativeHit(inside)
        Report.record("tk1.chip.hit", ["native": hit, "start": call.location])
        #expect(NSLocationInRange(hit, call) || hit == NSMaxRange(call))
        let accessibility = harness.accessibility(strong)
        Report.record("tk1.accessibility.range", accessibility.range ?? "nil")
        if let copied = harness.copiedString(strong) {
            #expect(copied == "*粗体 bold*")
        }
    }
}
