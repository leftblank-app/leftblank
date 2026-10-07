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

/// Behaviour of TextKit 2 display substitution on the real platform view.
/// The same file runs on macOS (NSTextView) and the iPad simulator (UITextView).
@MainActor
@Suite(.serialized)
struct TextKit2BehaviourTests {
    func open(_ mode: DisplaySubstitution.Mode = .zeroWidth) throws -> (Harness, VisualEditorSession) {
        let harness = Harness(text: Sample.text)
        let storage = try #require(harness.contentStorage)
        let session = try #require(VisualEditorSession(contentStorage: storage, mode: mode))
        session.formatter = Sample.formatter
        session.observeEdits()
        harness.selection = Sample.away
        session.selectionDidChange(Sample.away, hasMarkedText: false)
        harness.settle()
        return (harness, session)
    }

    func caretX(_ offset: Int, _ harness: Harness) throws -> CGFloat {
        let manager = try #require(harness.manager)
        return try #require(TextKit2Geometry.caretRect(at: offset, in: manager)).minX
    }

    @Test(arguments: [DisplaySubstitution.Mode.zeroWidth, .tinyFont])
    func concealedMarkersTakeNoWidthAndSourceIsUnchanged(mode: DisplaySubstitution.Mode) throws {
        let (harness, session) = try open(mode)
        defer { harness.close() }
        #expect(harness.string == Sample.text, "Display substitution must not change the backing string")
        let strong = Sample.range("*粗体 bold*")
        let open = strong.location, close = NSMaxRange(strong) - 1
        let widths = try [
            caretX(open + 1, harness) - caretX(open, harness),
            caretX(close + 1, harness) - caretX(close, harness),
        ]
        Report.record("tk2.\(mode).concealedMarkerWidths", widths)
        #expect(widths.allSatisfy { abs($0) < 0.5 }, "markers must collapse to zero width: \(widths)")
        let heading = Sample.range("= 第一章")
        #expect(try abs(caretX(heading.location + 2, harness) - caretX(heading.location, harness)) < 0.5)
        #expect(session.substitution.paragraphRequests > 0)
        #expect(!harness.switchedToTextKit1)
        #expect(harness.manager != nil)
    }

    @Test
    func chipIsOneBoxAndHitTestingMapsToSource() throws {
        let (harness, session) = try open()
        defer { harness.close() }
        let call = Sample.range("#item(\"LB-001\", \"标题\", \"done\")")
        let chip = try #require(session.chips.first)
        #expect(chip.range == call)
        #expect(chip.label == "LB-001 标题 [已完成]")
        let manager = try #require(harness.manager)
        let width = try caretX(NSMaxRange(call), harness) - caretX(call.location, harness)
        let expected = ChipDrawing.width(of: chip.label)
        Report.record("tk2.chip.width", ["layout": width, "box": expected])
        #expect(abs(width - expected) < 1)
        // Hit testing in the box resolves to one of its source edges.
        let caret = try #require(TextKit2Geometry.caretRect(at: call.location, in: manager))
        let inside = CGPoint(x: caret.minX + expected / 2, y: caret.midY)
        let hit = try #require(TextKit2Geometry.insertionOffset(at: inside, in: manager))
        let native = harness.nativeHit(inside)
        Report.record("tk2.chip.hit", ["navigation": hit, "native": native, "start": call.location])
        #expect([call.location, NSMaxRange(call)].contains(hit))
        // NSTextView/UITextView may answer one unit inside the box (after the
        // attachment unit); selection inside a construct reveals it, so the
        // adapter never needs to snap it.
        #expect(NSLocationInRange(native, call) || native == NSMaxRange(call))
        // Every visible character on the strong line round-trips.
        let line = Sample.range("Text *粗体 bold* and _emph_ with `code`, @intro and <lab>.")
        var failures: [Int] = []
        for offset in line.location ..< NSMaxRange(line) where !session.plan.isConcealed(offset) {
            guard let rect = TextKit2Geometry.caretRect(at: offset, in: manager),
                  let next = TextKit2Geometry.caretRect(at: offset + 1, in: manager), next.minX - rect.minX > 2
            else {
                continue
            }
            let point = CGPoint(x: rect.minX + 1, y: rect.midY)
            if TextKit2Geometry.insertionOffset(at: point, in: manager) != offset || harness
                .nativeHit(point) != offset
            {
                failures.append(offset)
            }
        }
        #expect(failures.isEmpty, "hit-test round trip failed at \(failures)")
        // TextKit 2 hosts the chip as a real view (clickable, VoiceOver element).
        let location = try #require(TextKit2Geometry.location(call.location, in: manager))
        let providers = manager.textLayoutFragment(for: location)?.textAttachmentViewProviders ?? []
        Report.record("tk2.chip.viewProviders", ["fragment": providers.count,
                                                 "requests": VisualAttachment.viewProviderRequests])
        #expect(providers.contains { $0.view is BoxView })
        // The attachment exists only in the display paragraph.
        #expect(!harness.string.contains("\u{FFFC}"))
        #expect(harness.copiedString(call).map { $0 == "#item(\"LB-001\", \"标题\", \"done\")" } ?? true)
    }

    @Test
    func selectionRectsSpanConcealedTextWithoutGaps() throws {
        let (harness, _) = try open()
        defer { harness.close() }
        let manager = try #require(harness.manager)
        let range = Sample.range("Text *粗体 bold* and")
        let rects = TextKit2Geometry.selectionRects(range, in: manager)
        let sorted = rects.sorted { $0.minX < $1.minX }
        var gaps: [CGFloat] = []
        for (left, right) in zip(sorted, sorted.dropFirst()) {
            gaps.append(right.minX - left.maxX)
        }
        Report.record("tk2.selection.segments", rects.count)
        #expect(gaps.allSatisfy { $0 < 0.5 }, "gaps \(gaps)")
        let copied = harness.copiedString(range)
        Report.record("tk2.copy", copied ?? "not measured on this platform")
        if let copied {
            #expect(copied == "Text *粗体 bold* and", "copy must use source, not display text")
        }
    }

    /// Raw TextKit 2 navigation with a *static* plan: each concealed UTF-16
    /// unit is still a caret stop. This is why entering a construct reveals it.
    @Test
    func navigationStopsInsideConcealedUnitsUnlessRevealed() throws {
        let (harness, session) = try open()
        defer { harness.close() }
        let manager = try #require(harness.manager)
        let strong = Sample.range("*粗体 bold*")
        var stops: [Int] = []
        var offset = strong.location - 1
        for _ in 0 ..< 4 {
            guard let next = TextKit2Geometry.step(from: offset, direction: .forward, in: manager) else {
                break
            }
            stops.append(next)
            offset = next
        }
        Report.record("tk2.navigation.staticStops", ["from": strong.location - 1, "stops": stops])
        // The caret never rests on the concealed `*` (same x as the next
        // unit): the first stop is already inside the construct.
        #expect(!stops.contains(strong.location))
        #expect(stops.first.map { NSLocationInRange($0, strong) } == true)
        // Reveal-on-entry: the caret reaching the construct edge shows its source.
        let changed = session.selectionDidChange(NSRange(location: strong.location, length: 0), hasMarkedText: false)
        harness.layout()
        #expect(!changed.isEmpty)
        #expect(!session.plan.isConcealed(strong.location))
        #expect(try caretX(strong.location + 1, harness) - caretX(strong.location, harness) > 3)
        if harness.supportsNativeArrowKeys {
            harness.selection = NSRange(location: strong.location - 1, length: 0)
            session.selectionDidChange(harness.selection, hasMarkedText: false)
            harness.moveRightNatively()
            Report.record("tk2.navigation.nativeMoveRight", harness.selection.location)
            #expect(NSLocationInRange(harness.selection.location, strong))
        }
    }

    @Test
    func revealIsImmediateAndOnlyTouchesTheConstruct() throws {
        let (harness, session) = try open()
        defer { harness.close() }
        var samples: [Double] = []
        var paragraphs = 0
        for needle in ["*粗体 bold*", "#item(", "_emph_", "= 第一章", "@intro"] {
            let target = Sample.range(needle).location + 1
            let before = session.substitution.paragraphRequests
            samples.append(milliseconds {
                harness.selection = NSRange(location: target, length: 0)
                session.selectionDidChange(harness.selection, hasMarkedText: false)
                harness.layout()
            })
            paragraphs = max(paragraphs, session.substitution.paragraphRequests - before)
            #expect(session.plan.revealed.contains { NSLocationInRange(target, $0) })
        }
        Report.record("tk2.reveal.ms", summary(samples))
        Report.record("tk2.reveal.maxParagraphsRebuilt", paragraphs)
        #expect(try #require(summary(samples)["max"]) < 50)
        #expect(harness.view.undoManager?.canUndo != true, "plan changes must not create undo records")
    }

    @Test
    func chineseInputMethodNextToConcealedConstructs() throws {
        let (harness, session) = try open()
        defer { harness.close() }
        let anchor = Sample.range(" after chip.")
        let insertion = anchor.location + 6 // between "after" and " chip."
        harness.selection = NSRange(location: insertion, length: 0)
        session.selectionDidChange(harness.selection, hasMarkedText: harness.hasMarkedText)
        harness.layout()
        let chipStillConcealed = session.chips.count == 1
        let caret = try caretX(insertion, harness)
        harness.setMarkedText("zhong")
        // Composition defers presentation updates.
        #expect(session.selectionDidChange(harness.selection, hasMarkedText: harness.hasMarkedText).isEmpty)
        let marked = harness.markedFirstRect()
        Report.record("tk2.ime.markedRect", ["x": marked.minX, "caret": caret, "width": marked.width])
        #expect(abs(marked.minX - caret) < 2, "IME candidate window anchors at the visible caret")
        harness.commitMarkedText("中")
        #expect(!harness.hasMarkedText)
        session.selectionDidChange(harness.selection, hasMarkedText: false)
        harness.layout()
        let expected = (Sample.text as NSString).replacingCharacters(
            in: NSRange(location: insertion, length: 0),
            with: "中",
        )
        #expect(harness.string == expected)
        #expect(session.editFailures == 0)
        #expect(chipStillConcealed && session.chips.count == 1)
        harness.undo()
        session.selectionDidChange(harness.selection, hasMarkedText: false)
        #expect(harness.string == Sample.text)
    }

    @Test
    func formEditIsOneUndoableReplacement() throws {
        let (harness, session) = try open()
        defer { harness.close() }
        let chip = try #require(session.chips.first)
        let edit = try #require(ChipEditing.edit(
            chip,
            values: ["status": "todo", "title": "新标题"],
            source: harness.string as NSString,
        ))
        harness.replace(edit.range, with: edit.text)
        session.selectionDidChange(Sample.away, hasMarkedText: false)
        #expect(harness.string.contains("#item(\"LB-001\", \"新标题\", \"todo\")"))
        #expect(session.chips.first?.label == "LB-001 新标题 [待办]")
        harness.undo()
        session.selectionDidChange(Sample.away, hasMarkedText: false)
        #expect(harness.string == Sample.text, "one undo restores the original call")
        #expect(session.chips.first?.label == "LB-001 标题 [已完成]")
        let repeated = try #require(ChipEditing.repeatPrevious(
            before: NSMaxRange(chip.range) + 1,
            chips: session.chips,
            formatter: Sample.formatter,
        ))
        #expect(repeated.text == "#item(\"\", \"\", \"done\")")
        #expect(repeated.placeholders.count == 2)
    }

    @Test
    func accessibilityExposesSourceText() throws {
        let (harness, _) = try open()
        defer { harness.close() }
        let range = Sample.range("*粗体 bold*")
        let exposed = harness.accessibility(range)
        Report.record("tk2.accessibility", ["valueIsSource": exposed.value == Sample.text,
                                            "valuePrefix": String((exposed.value ?? "nil").prefix(24)),
                                            "range": exposed.range ?? "nil"])
        #expect(exposed.range == "*粗体 bold*", "AX reads the backing string, not the display paragraph")
        #expect(exposed.value?.contains("\u{200B}") != true)
    }

    @Test
    func touchingLayoutManagerSwitchesTheViewToTextKit1() {
        let harness = Harness(text: Sample.text)
        defer { harness.close() }
        #expect(harness.manager != nil)
        _ = harness.touchLayoutManager()
        Report.record("tk2.layoutManagerAccessFallsBack", harness.manager == nil)
        #expect(harness.manager == nil, "any .layoutManager access permanently drops TextKit 2")
        #if canImport(AppKit)
            #expect(harness.switchedToTextKit1)
        #endif
    }

    /// Length-changing substitution, for comparison. TextKit 2 treats display
    /// offsets as document offsets, so geometry drifts from the source.
    @Test
    func shorterSubstitutionBreaksLocationMapping() throws {
        let after = Sample.range(" and _emph_").location // first unit after "*粗体 bold*"
        let end = NSMaxRange(Sample.range("<lab>."))
        func measure(_ mode: DisplaySubstitution.Mode) throws -> (after: CGFloat, end: CGFloat?) {
            let (harness, _) = try open(mode)
            defer { harness.close() }
            let manager = try #require(harness.manager)
            return try (caretX(after, harness), TextKit2Geometry.caretRect(at: end, in: manager)?.minX)
        }
        let same = try measure(.zeroWidth), shorter = try measure(.shorter)
        Report.record("tk2.shorter", ["zeroWidthAfterX": same.after, "shorterAfterX": shorter.after,
                                      "zeroWidthEndX": same.end ?? -1, "shorterEndX": shorter.end ?? -1])
        // Offsets are read against the shorter display string: the caret lands
        // two characters late, i.e. source and display no longer agree.
        #expect(abs(shorter.after - same.after) > 10)
    }

    /// Alternative: a custom NSTextLayoutFragment that skips drawing markers.
    /// Drawing is customizable, geometry is not: hidden markers keep width.
    @Test
    func customFragmentDrawingCannotCollapseWidth() throws {
        let harness = Harness(text: "")
        defer { harness.close() }
        let manager = try #require(harness.manager)
        let delegate = SkippingFragmentDelegate()
        manager.delegate = delegate
        harness.setString(Sample.text)
        harness.layout()
        let strong = Sample.range("*粗体 bold*")
        let rect = try #require(TextKit2Geometry.caretRect(at: strong.location, in: manager))
        let next = try #require(TextKit2Geometry.caretRect(at: strong.location + 1, in: manager))
        Report.record("tk2.customFragment.markerWidth", next.minX - rect.minX)
        #expect(delegate.created > 0)
        #expect(next.minX - rect.minX > 3)
    }
}

final class SkippingFragment: NSTextLayoutFragment {
    /// Drawing can be customized (a real version would clip concealed glyph
    /// runs); the line fragments, and therefore caret geometry, cannot.
    override func draw(at point: CGPoint, in context: CGContext) {
        context.saveGState()
        context.setAlpha(0.999)
        super.draw(at: point, in: context)
        context.restoreGState()
    }
}

final class SkippingFragmentDelegate: NSObject, NSTextLayoutManagerDelegate {
    nonisolated(unsafe) var created = 0

    func textLayoutManager(
        _: NSTextLayoutManager,
        textLayoutFragmentFor _: any NSTextLocation,
        in textElement: NSTextElement,
    ) -> NSTextLayoutFragment {
        created += 1
        return SkippingFragment(textElement: textElement, range: textElement.elementRange)
    }
}
