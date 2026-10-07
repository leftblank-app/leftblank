import CoreGraphics
import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Source-offset geometry on NSTextLayoutManager, shared by NSTextView and
/// UITextView. Never touches `layoutManager`: one access switches a view to
/// TextKit 1 for good. Rects are in text-container coordinates.
@MainActor
public enum TextKit2Geometry {
    public static func location(_ offset: Int, in manager: NSTextLayoutManager) -> NSTextLocation? {
        manager.location(manager.documentRange.location, offsetBy: offset)
    }

    public static func offset(of location: NSTextLocation, in manager: NSTextLayoutManager) -> Int {
        manager.offset(from: manager.documentRange.location, to: location)
    }

    public static func textRange(_ range: NSRange, in manager: NSTextLayoutManager) -> NSTextRange? {
        guard let start = location(range.location, in: manager),
              let end = manager.location(start, offsetBy: range.length)
        else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }

    /// Lays out just the paragraphs of `range`; TextKit 2 estimates the rest.
    public static func segments(
        _ range: NSRange,
        type: NSTextLayoutManager.SegmentType,
        in manager: NSTextLayoutManager,
    ) -> [CGRect] {
        guard let textRange = textRange(range, in: manager) else {
            return []
        }
        manager.ensureLayout(for: textRange)
        var rects: [CGRect] = []
        manager.enumerateTextSegments(in: textRange, type: type, options: [.rangeNotRequired]) { _, frame, _, _ in
            rects.append(frame)
            return true
        }
        return rects
    }

    public static func caretRect(at offset: Int, in manager: NSTextLayoutManager) -> CGRect? {
        segments(NSRange(location: offset, length: 0), type: .selection, in: manager).first
    }

    /// The insertion offset a click at `point` produces: the same navigation
    /// object the text views use for pointer input.
    public static func insertionOffset(at point: CGPoint, in manager: NSTextLayoutManager) -> Int? {
        manager.textSelectionNavigation.textSelections(
            interactingAt: point,
            inContainerAt: manager.documentRange.location,
            anchors: [],
            modifiers: [],
            selecting: false,
            bounds: .infinite,
        ).first?.textRanges.first.map { offset(of: $0.location, in: manager) }
    }

    /// The insertion offset at `point`, found among the fragments laid out in
    /// the viewport. After a distant jump, `insertionOffset` (and UIKit's
    /// `closestPosition`) can return a location 100,000 units away, because an
    /// estimated fragment elsewhere still claims that height; laid-out
    /// viewport fragments do not. Nil when the point is outside the viewport.
    public static func viewportInsertionOffset(at point: CGPoint, in manager: NSTextLayoutManager) -> Int? {
        let controller = manager.textViewportLayoutController
        guard let viewport = controller.viewportRange else {
            return nil
        }
        var result: Int?
        manager.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresLayout]) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else {
                return false
            }
            let frame = fragment.layoutFragmentFrame
            guard point.y >= frame.minY, point.y < frame.maxY else {
                return true
            }
            // Line indices count from the start of the paragraph's text.
            let start = offset(
                of: fragment.textElement?.elementRange?.location ?? fragment.rangeInElement.location,
                in: manager,
            )
            let lines = fragment.textLineFragments
            let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
            guard let line = lines.first(where: { local.y < $0.typographicBounds.maxY }) ?? lines.last else {
                result = start
                return false
            }
            let linePoint = CGPoint(x: local.x - line.typographicBounds.minX, y: local.y - line.typographicBounds.minY)
            var index = line.characterIndex(for: linePoint)
            if line.fractionOfDistanceThroughGlyph(for: linePoint) > 0.5, index < NSMaxRange(line.characterRange) {
                index += 1
            }
            result = start + min(max(index, line.characterRange.location), NSMaxRange(line.characterRange))
            return false
        }
        return result
    }

    /// The source range the laid-out viewport fragments show inside `rect`.
    public static func displayedRange(in rect: CGRect, manager: NSTextLayoutManager) -> NSRange? {
        guard let top = viewportInsertionOffset(at: CGPoint(x: rect.minX, y: rect.minY), in: manager),
              let bottom = viewportInsertionOffset(at: CGPoint(x: rect.maxX, y: rect.maxY - 1), in: manager)
        else {
            return nil
        }
        return NSRange(location: min(top, bottom), length: abs(bottom - top))
    }

    /// Scrolls `offset` into view by anchoring the viewport on it. For
    /// `UITextView`: there, a fragment laid out on its own (`ensureLayout`) can
    /// be placed where the viewport shows text 100,000 units away, so neither
    /// its frame nor `scrollRangeToVisible` can be trusted; the viewport's own
    /// layout from the target can. The target ends up a third of the way down,
    /// or at the top.
    public static func revealByRelocating(
        _ offset: Int,
        in manager: NSTextLayoutManager,
        visible: () -> CGRect,
        scroll: (CGFloat) -> Void,
    ) {
        let controller = manager.textViewportLayoutController
        controller.layoutViewport()
        if let shown = displayedRange(in: visible(), manager: manager), NSLocationInRange(offset, shown) {
            return
        }
        guard let location = location(offset, in: manager) else {
            return
        }
        // A third of a screen of context above the target; laying that text
        // out can push the target off the top, and then it goes to the top.
        for margin in [visible().height / 3, 0] {
            let top = controller.relocateViewport(to: location)
            scroll(max(0, top - margin))
            controller.layoutViewport()
            if let shown = displayedRange(in: visible(), manager: manager), NSLocationInRange(offset, shown) {
                return
            }
        }
    }

    /// The character under `point`, not the nearest insertion position.
    public static func character(at point: CGPoint, in manager: NSTextLayoutManager, text: NSString) -> Int? {
        // The margins hold no text; keep such points away from selection navigation.
        guard let container = manager.textContainer, point.x >= 0, point.y >= 0,
              point.x <= container.size.width,
              let insertion = insertionOffset(at: point, in: manager)
        else {
            return nil
        }
        // The insertion point is the nearest boundary; the character under the
        // pointer is on one side of it, if the pointer is over text at all.
        for candidate in [insertion, insertion - 1] where candidate >= 0 && candidate < text.length {
            // A line break's segment reaches the margin; it is not text.
            if text.character(at: candidate) == 10 || text.character(at: candidate) == 13 {
                continue
            }
            let character = text.rangeOfComposedCharacterSequence(at: candidate)
            if segments(character, type: .standard, in: manager).contains(where: { $0.contains(point) }) {
                return character.location
            }
        }
        return nil
    }

    /// Source of the lines intersecting `rect`.
    public static func characterRange(in rect: CGRect, manager: NSTextLayoutManager) -> NSRange? {
        guard !rect.isEmpty else {
            return nil
        }
        manager.textViewportLayoutController.layoutViewport()
        let width = manager.textContainer?.size.width ?? rect.maxX
        guard let start = insertionOffset(at: CGPoint(x: max(0, rect.minX), y: max(0, rect.minY)), in: manager),
              let end = insertionOffset(at: CGPoint(x: min(width, rect.maxX), y: rect.maxY), in: manager)
        else {
            return nil
        }
        return NSRange(location: min(start, end), length: abs(end - start))
    }

    /// Lays out about a screen of text on both sides of `offset`. TextKit 2
    /// finds the fragment at a viewport's top by laying out forward from the
    /// nearest laid-out one above it; scrolling onto text not laid out makes
    /// it lay out everything in between (1.3 s for one SICP jump on macOS 15),
    /// and every later edit walks those paragraphs.
    public static func layOutContext(around offset: Int, in manager: NSTextLayoutManager) {
        let length = self.offset(of: manager.documentRange.endLocation, in: manager)
        guard let start = location(max(0, offset - 3000), in: manager),
              let end = location(min(length, offset + 3000), in: manager),
              let context = NSTextRange(location: start, end: end)
        else {
            return
        }
        manager.ensureLayout(for: context)
    }

    /// Scrolls `offset` into view without trusting `scrollRangeToVisible`,
    /// which reads estimated geometry and can leave a distant target thousands
    /// of points away (1 of 6 War and Peace jumps on the Mac, every distant
    /// jump on iPad). Lays out the target and the text above it, scrolls the
    /// target a third of the way down the viewport, lets the viewport
    /// re-anchor, and repeats until its frame stops moving. A target that is
    /// already visible does not scroll.
    ///
    /// `visible` returns the visible rect in container coordinates; `scroll`
    /// scrolls so that container-y `y` is at the top.
    public static func reveal(
        _ offset: Int,
        in manager: NSTextLayoutManager,
        visible: () -> CGRect,
        scroll: (CGFloat) -> Void,
    ) {
        layOutContext(around: offset, in: manager)
        var previous: CGFloat?
        for _ in 0 ..< 4 {
            guard let target = caretRect(at: offset, in: manager) else {
                return
            }
            let viewport = visible()
            let inside = target.minY >= viewport.minY && target.maxY <= viewport.maxY
            if inside, previous.map({ abs($0 - target.minY) < 0.5 }) ?? true {
                return
            }
            previous = target.minY
            if !inside {
                scroll(max(0, target.minY - viewport.height / 3))
            }
            manager.textViewportLayoutController.layoutViewport()
        }
    }
}
