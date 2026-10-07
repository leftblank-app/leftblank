import AppKit
import LeftBlankCore
import SwiftUI

/// The side-by-side divider's pointer target. AppKit owns the cursor, drag and
/// accessibility: macOS 14 has no SwiftUI resize pointer style, and a dragged
/// view keeps receiving events after the pointer leaves its few points.
struct SplitDividerHandle: NSViewRepresentable {
    /// The editor's share of the writing area, reported to accessibility.
    let fraction: CGFloat
    let hovering: (Bool) -> Void
    let begin: () -> Void
    /// The horizontal distance from the press, in window points.
    let drag: (CGFloat) -> Void
    let end: () -> Void
    let reset: () -> Void
    let adjust: (Int) -> Void

    func makeNSView(context: Context) -> SplitDividerView {
        SplitDividerView()
    }

    func updateNSView(_ view: SplitDividerView, context: Context) {
        view.fraction = fraction
        view.hovering = hovering
        view.begin = begin
        view.drag = drag
        view.end = end
        view.reset = reset
        view.adjust = adjust
    }
}

@MainActor
final class SplitDividerView: NSView {
    /// Wide enough to grab without aiming for the 1 pt line.
    static let hitWidth: CGFloat = 10
    var fraction = SplitLayout.defaultFraction
    var hovering: (Bool) -> Void = { _ in }
    var begin: () -> Void = {}
    var drag: (CGFloat) -> Void = { _ in }
    var end: () -> Void = {}
    var reset: () -> Void = {}
    var adjust: (Int) -> Void = { _ in }
    private var pressX: CGFloat?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
        )
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        hovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        if pressX == nil {
            hovering(false)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            pressX = nil
            reset()
            return
        }
        pressX = event.locationInWindow.x
        begin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressX else {
            return
        }
        NSCursor.resizeLeftRight.set()
        drag(event.locationInWindow.x - pressX)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressX != nil else {
            return
        }
        pressX = nil
        end()
        hovering(bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .splitter
    }

    override func accessibilityIdentifier() -> String {
        "split-divider"
    }

    override func accessibilityLabel() -> String? {
        L10n.text("Resize Writing and Preview")
    }

    override func accessibilityHelp() -> String? {
        L10n.text("Drag to resize. Double-click to split evenly.")
    }

    override func accessibilityValue() -> Any? {
        "\(Int((fraction * 100).rounded()))%"
    }

    override func accessibilityPerformIncrement() -> Bool {
        adjust(1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        adjust(-1)
        return true
    }
}
