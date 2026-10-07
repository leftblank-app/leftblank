import Combine
import Foundation

/// A geometric reading position. Page indices are zero based. Fractions remain
/// useful when a page scales; they do not promise semantic tracking after reflow.
public struct PreviewReadingAnchor: Codable, Equatable, Sendable {
    public let page: Int
    public let x: Double
    public let y: Double
    public let viewportY: Double

    public init?(page: Int, x: Double, y: Double, viewportY: Double) {
        guard page >= 0, x.isFinite, y.isFinite, viewportY.isFinite,
              (0 ... 1).contains(x), (0 ... 1).contains(y), (0 ... 1).contains(viewportY)
        else {
            return nil
        }
        self.page = page
        self.x = x
        self.y = y
        self.viewportY = viewportY
    }

    public init?(message: Any) {
        guard let values = message as? [String: Any], let page = values["page"] as? Int,
              let x = values["x"] as? Double, let y = values["y"] as? Double,
              let viewportY = values["viewportY"] as? Double
        else {
            return nil
        }
        self.init(page: page, x: x, y: y, viewportY: viewportY)
    }

    public var javaScript: String {
        "{page:\(page),x:\(x),y:\(y),viewportY:\(viewportY)}"
    }
}

@MainActor
public final class PreviewReadingSession: ObservableObject {
    public struct Restore: Equatable, Sendable {
        public let id = UUID()
        public let anchor: PreviewReadingAnchor
        public let consumesBookmark: Bool
    }

    @Published public var followsWriting = false
    @Published public private(set) var returnAnchor: PreviewReadingAnchor?
    @Published public private(set) var restore: Restore?
    public private(set) var anchor: PreviewReadingAnchor?
    /// Tinymist answers a preview click with at most one source jump, shortly after it.
    public static let clickPairing: Duration = .seconds(2)
    private var click: (text: PreviewClick?, time: ContinuousClock.Instant)?

    public init() {}

    public func observe(_ anchor: PreviewReadingAnchor) {
        self.anchor = anchor
    }

    /// Remember the text under the latest preview click, or that it had none.
    public func observe(_ click: PreviewClick?, at time: ContinuousClock.Instant = .now) {
        self.click = (click, time)
    }

    /// The text of a click that may have caused the source jump arriving now. Each click pairs once.
    public func takeClick(at time: ContinuousClock.Instant = .now) -> PreviewClick? {
        defer { click = nil }
        guard let click, time - click.time <= Self.clickPairing else {
            return nil
        }
        return click.text
    }

    /// Record a message from the shared reading script.
    public func receive(_ message: [String: Any]) {
        switch message["kind"] as? String {
        case "manualScroll": pauseFollowing()
        case "click": observe(PreviewClick(message: message))
        default: break
        }
        if let value = message["anchor"], let anchor = PreviewReadingAnchor(message: value) {
            observe(anchor)
        }
    }

    public func rememberReturnPosition() {
        if let anchor {
            returnAnchor = anchor
        }
        // Editing after a preview-to-source jump must not erase the bookmark.
        followsWriting = false
    }

    public func returnToReading() {
        guard let returnAnchor else {
            return
        }
        followsWriting = false
        restore = Restore(anchor: returnAnchor, consumesBookmark: true)
    }

    public func didRestore(_ id: UUID) {
        guard restore?.id == id else {
            return
        }
        if restore?.consumesBookmark == true {
            returnAnchor = nil
        }
        restore = nil
    }

    /// A new WebKit page restores the current location without consuming the return bookmark.
    public func prepareReload() {
        guard restore == nil, let anchor else {
            return
        }
        restore = Restore(anchor: anchor, consumesBookmark: false)
    }

    public func pauseFollowing() {
        followsWriting = false
    }

    public func reset() {
        anchor = nil
        returnAnchor = nil
        restore = nil
        click = nil
        followsWriting = false
    }
}
