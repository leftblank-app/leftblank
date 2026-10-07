import CoreGraphics
import Foundation

/// Mac and iPad share the side-by-side ratio model; each platform keeps its
/// own pointer, touch and accessibility handling. The ratio is a per-device
/// preference: screens and window sizes differ, so it stays in local defaults
/// rather than the synced preferences.
public enum SplitLayout {
    public static let defaultFraction: CGFloat = 0.5
    /// Neither pane may take more than this share of the writing area.
    public static let fractionRange: ClosedRange<CGFloat> = 0.2 ... 0.8
    /// Each pane keeps this width whenever the writing area allows it.
    public static let minimumPaneWidth: CGFloat = 280
    /// Accessibility increments move the divider by this share.
    public static let adjustmentStep: CGFloat = 0.05
    public static let storageKey = "splitFraction"

    public static func clamped(_ fraction: CGFloat) -> CGFloat {
        guard fraction.isFinite else {
            return defaultFraction
        }
        return min(fractionRange.upperBound, max(fractionRange.lowerBound, fraction))
    }

    /// The editor width for a writing area of `width`, after `divider` points
    /// for the separator. An area too narrow for two minimum panes is divided
    /// equally instead of overflowing.
    public static func editorWidth(in width: CGFloat, fraction: CGFloat, divider: CGFloat = 0) -> CGFloat {
        let available = max(0, width - divider)
        let minimum = min(minimumPaneWidth, available / 2)
        return min(available - minimum, max(minimum, (available * clamped(fraction)).rounded()))
    }

    /// The ratio that places the editor at `editorWidth`, e.g. while dragging.
    public static func fraction(editorWidth: CGFloat, in width: CGFloat, divider: CGFloat = 0) -> CGFloat {
        let available = width - divider
        guard available > 0 else {
            return defaultFraction
        }
        return clamped(editorWidth / available)
    }

    /// Steps from the effective ratio, so an adjustment always moves a divider
    /// that a minimum pane width is holding in place.
    public static func adjusted(
        by steps: Int,
        editorWidth: CGFloat,
        in width: CGFloat,
        divider: CGFloat = 0,
    ) -> CGFloat {
        clamped(fraction(editorWidth: editorWidth, in: width, divider: divider) + CGFloat(steps) * adjustmentStep)
    }

    public static func storedFraction(in defaults: UserDefaults, key: String = storageKey) -> CGFloat {
        guard let value = defaults.object(forKey: key) as? NSNumber else {
            return defaultFraction
        }
        return clamped(value.doubleValue)
    }

    public static func store(_ fraction: CGFloat, in defaults: UserDefaults, key: String = storageKey) {
        defaults.set(Double(clamped(fraction)), forKey: key)
    }
}
