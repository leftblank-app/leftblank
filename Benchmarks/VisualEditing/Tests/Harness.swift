import CoreGraphics
import Foundation
@testable import VisualEditing
import VisualPresentation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

enum Sample {
    static let text = """
    #let item(id, title, status) = [#id #title (#status)]
    = 第一章 Heading
    Text *粗体 bold* and _emph_ with `code`, @intro and <lab>.
    Before #item("LB-001", "标题", "done") after chip.
    - list item
    Inline $x^2 + y$ math.

    """
    static let formatter = ChipFormatter(valueLabels: ["status": ["done": "已完成", "todo": "待办"]])

    static func range(_ needle: String, in text: String = text) -> NSRange {
        (text as NSString).range(of: needle)
    }

    /// A selection away from every construct, so everything is concealed.
    static let away = NSRange(location: (text as NSString).length, length: 0)
}

/// Records spike observations; scripts/visual-editing-spike.sh collects them.
enum Report {
    nonisolated(unsafe) static var values: [String: Any] = [:]

    static func record(_ key: String, _ value: Any) {
        #if canImport(AppKit)
            let platform = "macOS"
        #else
            let platform = "iPadOS"
        #endif
        print("LB019 \(platform).\(key) = \(value)")
        let directory = ProcessInfo.processInfo.environment["LB019_REPORT_DIR"]
            ?? FileManager.default.temporaryDirectory.path
        let url = URL(fileURLWithPath: directory).appendingPathComponent("lb019-\(platform).json")
        // Merge with earlier processes (one fixture per run).
        if values.isEmpty, let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            values = existing
        }
        values["\(platform).\(key)"] = value
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }
}

/// Process physical footprint in MiB (same measure as the book benchmark).
func footprintMiB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func milliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
}

func summary(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    guard !sorted.isEmpty else {
        return [:]
    }
    func pick(_ quantile: Double) -> Double {
        sorted[Int((Double(sorted.count - 1) * quantile).rounded())]
    }
    return ["median": pick(0.5), "p95": pick(0.95), "max": sorted[sorted.count - 1]]
}

/// One editor per test on the real platform text view, in a real window so
/// viewport layout, attachment views and accessibility behave as in the app.
@MainActor
final class Harness {
    #if canImport(AppKit)
        let window: NSWindow
        let scroll: NSScrollView
        let view: NSTextView
    #else
        let window: UIWindow
        let view: UITextView
    #endif
    private(set) var switchedToTextKit1 = false
    private var observer: NSObjectProtocol?

    /// TextKit 2 unless `textKit1` supplies a TK1 layout manager (baseline).
    init(text: String, size: CGSize = CGSize(width: 700, height: 500), textKit1: NSLayoutManager? = nil) {
        let font = PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        #if canImport(AppKit)
            window = NSWindow(
                contentRect: CGRect(origin: .zero, size: size),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false,
            )
            window.isReleasedWhenClosed = false
            scroll = NSScrollView(frame: CGRect(origin: .zero, size: size))
            scroll.hasVerticalScroller = true
            if let manager = textKit1 {
                let storage = NSTextStorage()
                storage.addLayoutManager(manager)
                manager.allowsNonContiguousLayout = false
                let container = NSTextContainer(size: CGSize(width: size.width, height: .greatestFiniteMagnitude))
                manager.addTextContainer(container)
                view = NSTextView(frame: CGRect(origin: .zero, size: size), textContainer: container)
            } else {
                view = NSTextView(usingTextLayoutManager: true)
                view.frame = CGRect(origin: .zero, size: size)
            }
            view.isRichText = false
            view.allowsUndo = true
            view.isVerticallyResizable = true
            view.minSize = .zero
            view.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            view.font = font
            scroll.documentView = view
            window.contentView = scroll
            observer = NotificationCenter.default.addObserver(
                forName: NSTextView.willSwitchToNSLayoutManagerNotification,
                object: view,
                queue: nil,
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.switchedToTextKit1 = true }
            }
            // Attachment view providers are only created for an ordered-in
            // window; keep it off-screen.
            window.setFrameOrigin(CGPoint(x: -8000, y: -8000))
            window.orderFrontRegardless()
            view.string = text
        #else
            window = UIWindow(frame: CGRect(origin: .zero, size: size))
            if let manager = textKit1 {
                let storage = NSTextStorage()
                storage.addLayoutManager(manager)
                let container = NSTextContainer(size: CGSize(width: size.width, height: .greatestFiniteMagnitude))
                manager.addTextContainer(container)
                view = UITextView(frame: CGRect(origin: .zero, size: size), textContainer: container)
            } else {
                view = UITextView(usingTextLayoutManager: true)
                view.frame = CGRect(origin: .zero, size: size)
            }
            view.font = font
            view.textContainerInset = .zero
            view.textContainer.lineFragmentPadding = 0
            window.addSubview(view)
            window.isHidden = false
            view.text = text
        #endif
        layout()
    }

    func close() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        #if canImport(AppKit)
            window.close()
        #else
            window.isHidden = true
        #endif
    }

    var manager: NSTextLayoutManager? {
        view.textLayoutManager
    }

    var contentStorage: NSTextContentStorage? {
        #if canImport(AppKit)
            view.textContentStorage
        #else
            view.textLayoutManager?.textContentManager as? NSTextContentStorage
        #endif
    }

    var textStorage: NSTextStorage {
        view.textStorage ?? NSTextStorage()
    }

    var string: String {
        textStorage.string
    }

    func setString(_ text: String) {
        #if canImport(AppKit)
            // Attachment view providers are only created for an ordered-in
            // window; keep it off-screen.
            window.setFrameOrigin(CGPoint(x: -8000, y: -8000))
            window.orderFrontRegardless()
            view.string = text
        #else
            view.text = text
        #endif
    }

    var selection: NSRange {
        get { view.selectedRange }
        set {
            #if canImport(AppKit)
                view.setSelectedRange(newValue)
            #else
                view.selectedRange = newValue
            #endif
        }
    }

    /// Lets AppKit/UIKit run their deferred layout and view-provider passes.
    func settle() {
        layout()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        layout()
    }

    func layout() {
        #if canImport(AppKit)
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            manager?.textViewportLayoutController.layoutViewport()
            view.displayIfNeeded()
        #else
            window.layoutIfNeeded()
            view.layoutIfNeeded()
            manager?.textViewportLayoutController.layoutViewport()
        #endif
    }

    /// Text-container origin in view coordinates.
    var origin: CGPoint {
        #if canImport(AppKit)
            view.textContainerOrigin
        #else
            CGPoint(x: view.textContainerInset.left, y: view.textContainerInset.top)
        #endif
    }

    /// Native pointer hit test (view API), taking a container point.
    func nativeHit(_ point: CGPoint) -> Int {
        let viewPoint = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
        #if canImport(AppKit)
            return view.characterIndexForInsertion(at: viewPoint)
        #else
            guard let position = view.closestPosition(to: viewPoint) else {
                return -1
            }
            return view.offset(from: view.beginningOfDocument, to: position)
        #endif
    }

    /// Native caret rect (view API) in container coordinates.
    func nativeCaret(_ offset: Int) -> CGRect {
        #if canImport(AppKit)
            selection = NSRange(location: offset, length: 0)
            let screen = view.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: nil)
            let inWindow = window.convertFromScreen(screen)
            let local = view.convert(inWindow, from: nil)
            return local.offsetBy(dx: -origin.x, dy: -origin.y)
        #else
            guard let position = view.position(from: view.beginningOfDocument, offset: offset) else {
                return .null
            }
            return view.caretRect(for: position).offsetBy(dx: -origin.x, dy: -origin.y)
        #endif
    }

    var visibleRect: CGRect {
        #if canImport(AppKit)
            view.visibleRect
        #else
            CGRect(origin: view.contentOffset, size: view.bounds.size)
        #endif
    }

    var contentHeight: CGFloat {
        #if canImport(AppKit)
            view.frame.height
        #else
            view.contentSize.height
        #endif
    }

    func scroll(by delta: CGFloat) {
        #if canImport(AppKit)
            let clip = scroll.contentView
            let maxY = max(0, view.frame.height - clip.bounds.height)
            clip.scroll(to: CGPoint(x: 0, y: min(maxY, max(0, clip.bounds.origin.y + delta))))
            scroll.reflectScrolledClipView(clip)
        #else
            let maxY = max(0, view.contentSize.height - view.bounds.height)
            view.contentOffset = CGPoint(x: 0, y: min(maxY, max(0, view.contentOffset.y + delta)))
        #endif
        layout()
    }

    /// Scroll so container-y `y` is at the top of the viewport.
    func scrollTo(containerY y: CGFloat) {
        #if canImport(AppKit)
            let clip = scroll.contentView
            clip.scroll(to: CGPoint(x: 0, y: y + origin.y))
            scroll.reflectScrolledClipView(clip)
        #else
            view.contentOffset = CGPoint(x: 0, y: y + origin.y)
        #endif
    }

    /// TK2 jump through `TextKit2Geometry.reveal` (the proposed mitigation).
    @discardableResult
    func revealPrecisely(_ offset: Int) -> Int {
        selection = NSRange(location: offset, length: 0)
        guard let manager else {
            reveal(offset)
            return 1
        }
        let passes = TextKit2Geometry.reveal(offset, in: manager, topInset: visibleRect.height / 3) {
            scrollTo(containerY: $0)
        }
        layout()
        return passes
    }

    func reveal(_ offset: Int) {
        selection = NSRange(location: offset, length: 0)
        view.scrollRangeToVisible(NSRange(location: offset, length: 0))
        layout()
    }

    #if canImport(AppKit)
        private lazy var bitmap = view.bitmapImageRepForCachingDisplay(in: view.visibleRect)
    #endif

    /// Paint the visible region into a CPU bitmap (as the book benchmark does).
    func draw() {
        #if canImport(AppKit)
            if let bitmap, bitmap.size == view.visibleRect.size {
                view.cacheDisplay(in: view.visibleRect, to: bitmap)
            } else if let fresh = view.bitmapImageRepForCachingDisplay(in: view.visibleRect) {
                view.cacheDisplay(in: view.visibleRect, to: fresh)
            }
        #else
            _ = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
        #endif
    }

    func setMarkedText(_ text: String) {
        #if canImport(AppKit)
            view.setMarkedText(
                text,
                selectedRange: NSRange(location: (text as NSString).length, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: 0),
            )
        #else
            view.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
        #endif
    }

    var hasMarkedText: Bool {
        #if canImport(AppKit)
            view.hasMarkedText()
        #else
            view.markedTextRange != nil
        #endif
    }

    /// First rect of the marked text, in container coordinates.
    func markedFirstRect() -> CGRect {
        #if canImport(AppKit)
            let range = view.markedRange()
            let screen = view.firstRect(forCharacterRange: range, actualRange: nil)
            return view.convert(window.convertFromScreen(screen), from: nil).offsetBy(dx: -origin.x, dy: -origin.y)
        #else
            guard let range = view.markedTextRange else {
                return .null
            }
            return view.firstRect(for: range).offsetBy(dx: -origin.x, dy: -origin.y)
        #endif
    }

    func commitMarkedText(_ text: String) {
        #if canImport(AppKit)
            view.insertText(text, replacementRange: view.markedRange())
        #else
            view.setMarkedText(text, selectedRange: NSRange(location: (text as NSString).length, length: 0))
            view.unmarkText()
        #endif
    }

    /// A native, undoable replacement (what a form edit or snippet does).
    func replace(_ range: NSRange, with text: String) {
        #if canImport(AppKit)
            view.insertText(text, replacementRange: range)
        #else
            guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length),
                  let textRange = view.textRange(from: start, to: end)
            else {
                return
            }
            view.replace(textRange, withText: text)
        #endif
    }

    func undo() {
        view.undoManager?.undo()
    }

    /// The string the platform copy command writes (macOS only: iPad copy
    /// would touch the shared simulator pasteboard).
    func copiedString(_ range: NSRange) -> String? {
        #if canImport(AppKit)
            selection = range
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("lb019-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            guard view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes) else {
                return nil
            }
            return pasteboard.string(forType: .string)
        #else
            return nil
        #endif
    }

    /// What the accessibility API exposes for the whole editor and a range.
    func accessibility(_ range: NSRange) -> (value: String?, range: String?) {
        #if canImport(AppKit)
            return (view.accessibilityValue() as? String, view.accessibilityString(for: range))
        #else
            let value = view.accessibilityValue
            guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length),
                  let textRange = view.textRange(from: start, to: end)
            else {
                return (value, nil)
            }
            return (value, view.text(in: textRange))
        #endif
    }

    func moveRightNatively() {
        #if canImport(AppKit)
            view.moveRight(nil)
        #endif
    }

    var supportsNativeArrowKeys: Bool {
        #if canImport(AppKit)
            true
        #else
            false
        #endif
    }

    /// Touches `layoutManager`, the call that must never happen on TK2 views.
    func touchLayoutManager() -> Bool {
        #if canImport(AppKit)
            return view.layoutManager != nil
        #else
            return view.layoutManager.textStorage != nil
        #endif
    }
}
