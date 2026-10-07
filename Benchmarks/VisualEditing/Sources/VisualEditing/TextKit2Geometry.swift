import CoreGraphics
import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Source-offset geometry on NSTextLayoutManager, shared by both platforms.
/// Everything the editor needs for hover, cmd-click, outline/rail positions
/// and preview sync, without touching `layoutManager` (which would switch a
/// view back to TextKit 1). Rects are in text-container coordinates.
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

    /// Lays out just enough to answer for `offset` (TextKit 2 estimates the rest).
    public static func ensureLayout(_ range: NSRange, in manager: NSTextLayoutManager) {
        if let textRange = textRange(range, in: manager) {
            manager.ensureLayout(for: textRange)
        }
    }

    public static func caretRect(at offset: Int, in manager: NSTextLayoutManager) -> CGRect? {
        guard let range = textRange(NSRange(location: offset, length: 0), in: manager) else {
            return nil
        }
        manager.ensureLayout(for: range)
        var result: CGRect?
        manager.enumerateTextSegments(in: range, type: .selection, options: [.rangeNotRequired]) { _, frame, _, _ in
            result = frame
            return false
        }
        return result
    }

    public static func selectionRects(_ range: NSRange, in manager: NSTextLayoutManager) -> [CGRect] {
        guard let textRange = textRange(range, in: manager) else {
            return []
        }
        manager.ensureLayout(for: textRange)
        var rects: [CGRect] = []
        manager.enumerateTextSegments(in: textRange, type: .selection, options: []) { _, frame, _, _ in
            rects.append(frame)
            return true
        }
        return rects
    }

    /// The insertion offset a click at `point` would produce (the same
    /// navigation object NSTextView and UITextView use for pointer input).
    public static func insertionOffset(at point: CGPoint, in manager: NSTextLayoutManager) -> Int? {
        let selections = manager.textSelectionNavigation.textSelections(
            interactingAt: point,
            inContainerAt: manager.documentRange.location,
            anchors: [],
            modifiers: [],
            selecting: false,
            bounds: .infinite,
        )
        return selections.first?.textRanges.first.map { offset(of: $0.location, in: manager) }
    }

    /// One arrow-key step, through TextKit 2's own selection navigation.
    public static func step(
        from offset: Int,
        direction: NSTextSelectionNavigation.Direction,
        in manager: NSTextLayoutManager,
    ) -> Int? {
        guard let location = location(offset, in: manager) else {
            return nil
        }
        let selection = NSTextSelection(location, affinity: .downstream)
        let next = manager.textSelectionNavigation.destinationSelection(
            for: selection,
            direction: direction,
            destination: .character,
            extending: false,
            confined: false,
        )
        return next?.textRanges.first.map { self.offset(of: $0.location, in: manager) }
    }

    /// Paragraph-precise y for preview sync / jump-to-line: lay out only the
    /// target paragraph, then read its fragment frame.
    public static func fragmentFrame(at offset: Int, in manager: NSTextLayoutManager) -> CGRect? {
        guard let location = location(offset, in: manager) else {
            return nil
        }
        manager.ensureLayout(for: NSTextRange(location: location))
        return manager.textLayoutFragment(for: location)?.layoutFragmentFrame
    }

    /// Jump-to-offset that does not trust `scrollRangeToVisible` on estimated
    /// geometry: lay out the target paragraph, scroll to its fragment, let the
    /// viewport re-anchor, and repeat until the fragment stops moving.
    /// `scroll(y)` scrolls the platform view so container-y `y` is at the top;
    /// returns the passes needed (1 = first try was exact).
    @discardableResult
    public static func reveal(
        _ offset: Int,
        in manager: NSTextLayoutManager,
        topInset: CGFloat,
        scroll: (CGFloat) -> Void,
    ) -> Int {
        var previous: CGFloat?
        for pass in 1 ... 4 {
            guard let frame = fragmentFrame(at: offset, in: manager) else {
                return pass
            }
            if let previous, abs(previous - frame.minY) < 0.5 {
                return pass - 1
            }
            previous = frame.minY
            scroll(max(0, frame.minY - topInset))
            manager.textViewportLayoutController.layoutViewport()
        }
        return 4
    }

    /// Lays out the document in bounded slices (call from idle/run-loop
    /// time) so geometry converges to exact heights without one long stall.
    /// Returns false when everything is laid out.
    public static func layoutSlice(
        after location: inout NSTextLocation?,
        in manager: NSTextLayoutManager,
        budget: TimeInterval,
    ) -> Bool {
        let start = Date()
        var cursor = location ?? manager.documentRange.location
        var more = true
        manager.enumerateTextLayoutFragments(from: cursor, options: [.ensuresLayout]) { fragment in
            cursor = fragment.rangeInElement.endLocation
            return Date().timeIntervalSince(start) < budget
        }
        if cursor.compare(manager.documentRange.endLocation) != .orderedAscending {
            more = false
        }
        location = cursor
        return more
    }
}
