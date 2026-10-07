import CoreGraphics
import Foundation
import ImageIO

/// An sRGB text colour for rendered equations, usually the editor theme's text colour.
public struct MathColor: Hashable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The colour's sRGB components; nil when it cannot be converted (a pattern colour).
    public init?(_ color: CGColor) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: space, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3
        else {
            return nil
        }
        func byte(_ value: CGFloat) -> UInt8 {
            UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        self.init(
            red: byte(components[0]),
            green: byte(components[1]),
            blue: byte(components[2]),
            alpha: byte(converted.alpha),
        )
    }

    var typst: String {
        "rgb(\(red), \(green), \(blue), \(alpha))"
    }
}

/// Everything besides the equation's own source that changes how it renders.
public struct MathRenderStyle: Hashable, Sendable {
    /// The document's rules for equations, from `MathPreamble.extract`.
    public var preamble: String
    /// The editor's font size in points. The document's body text size maps to it.
    public var fontSize: Double
    public var color: MathColor
    /// Image pixels per point, usually the screen's backing scale factor.
    public var scale: Double
    /// The Typst project root, for absolute paths; defaults to `directory`.
    public var root: URL?
    /// The folder of the document's source, against which the preamble's relative imports resolve.
    /// Nil renders in a private folder, so relative imports fail.
    public var directory: URL?

    public init(
        fontSize: Double,
        color: MathColor,
        preamble: String = "",
        scale: Double = 2,
        root: URL? = nil,
        directory: URL? = nil,
    ) {
        self.preamble = preamble
        self.fontSize = fontSize
        self.color = color
        self.scale = scale
        self.root = root
        self.directory = directory
    }
}

/// One equation to render. Requests are revision-independent: the same source and style
/// share one cached image wherever and whenever they occur.
public struct MathRenderRequest: Hashable, Sendable {
    /// The equation node's text, including its `$` delimiters.
    public var source: String
    /// A display equation (`$ x $`); its baseline is the first line's.
    public var isBlock: Bool
    public var style: MathRenderStyle

    public init(source: String, isBlock: Bool, style: MathRenderStyle) {
        self.source = source
        self.isBlock = isBlock
        self.style = style
    }

    /// The request for a presentation plan's math request; nil for other requests.
    public init?(_ request: InlineRequest, style: MathRenderStyle) {
        guard case let .math(_, source, isBlock) = request else {
            return nil
        }
        self.init(source: source, isBlock: isBlock, style: style)
    }
}

public struct MathDiagnostic: Hashable, Sendable {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public let severity: Severity
    /// The engine's message, with any hints on following lines.
    public let message: String
    /// The UTF-16 location in the request's source; nil when the problem lies elsewhere,
    /// such as in the document's rules or an imported file.
    public let range: NSRange?

    public init(severity: Severity, message: String, range: NSRange? = nil) {
        self.severity = severity
        self.message = message
        self.range = range
    }
}

/// A rendered equation, sized for the editor. `CGImage` is immutable, so sharing it is safe.
public struct MathImage: @unchecked Sendable {
    /// Transparent background; ink in the requested colour.
    public let image: CGImage
    /// The layout box in points. Draw the image into this size.
    public let size: CGSize
    /// Distance in points from the box's top edge down to its baseline.
    public let baseline: CGFloat

    public init(image: CGImage, size: CGSize, baseline: CGFloat) {
        self.image = image
        self.size = size
        self.baseline = baseline
    }

    /// Distance in points from the baseline down to the box's bottom edge. A text attachment's
    /// bounds are `CGRect(x: 0, y: -descent, width: size.width, height: size.height)`.
    public var descent: CGFloat {
        size.height - baseline
    }

    /// Image pixels per point.
    public var scale: CGFloat {
        size.width > 0 ? CGFloat(image.width) / size.width : CGFloat(image.height) / max(size.height, 1)
    }

    public var fragment: RenderedFragment {
        RenderedFragment(size: size, baseline: baseline)
    }

    var cost: Int {
        image.bytesPerRow * image.height
    }
}

public struct MathRenderResult: Sendable {
    public let request: MathRenderRequest
    /// The rendered equation. With errors, or when `isStale`, it is an earlier rendering of the
    /// same source in another style, or nil.
    public let image: MathImage?
    /// Errors explain a failed rendering; warnings (rules that did not compile) do not prevent one.
    public let diagnostics: [MathDiagnostic]
    /// The image is not this request's rendering: show it marked until a current one arrives.
    public let isStale: Bool
    /// No engine result (the engine was unavailable); never cached, so a later request retries.
    var isTransient = false

    public init(request: MathRenderRequest, image: MathImage?, diagnostics: [MathDiagnostic], isStale: Bool) {
        self.request = request
        self.image = image
        self.diagnostics = diagnostics
        self.isStale = isStale
    }

    public var failed: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}

/// Renders equations with the document's engine, off the main thread.
public protocol InlineMathRenderer: Sendable {
    /// Results in request order. Batches and caches internally; a cached request costs no compile.
    func render(_ requests: [MathRenderRequest]) async -> [MathRenderResult]
    /// What can be shown now, without waiting: this request's cached result, or a stale one
    /// for the same source in another style. Safe to call from the main thread during layout.
    func cached(_ request: MathRenderRequest) -> MathRenderResult?
}

/// Rendered equations by request, with a least-recently-used bound on decoded image memory.
public final class MathRenderCache: Sendable {
    private struct Variant: Hashable {
        let source: String
        let isBlock: Bool
    }

    private struct Entry {
        let image: MathImage?
        let diagnostics: [MathDiagnostic]
        var used: UInt64
    }

    private struct State {
        var entries: [MathRenderRequest: Entry] = [:]
        /// The last successful style of each source, for stale display.
        var latest: [Variant: MathRenderRequest] = [:]
        var cost = 0
        var clock: UInt64 = 0
    }

    public let maximumCost: Int
    public let maximumCount: Int
    private let state = NSLockedState(State())

    /// Decoded bitmaps take 4 bytes per pixel: 64 MiB holds about 3,000 typical inline equations at 2x.
    public init(maximumCost: Int = 64 << 20, maximumCount: Int = 4096) {
        self.maximumCost = maximumCost
        self.maximumCount = maximumCount
    }

    public var count: Int {
        state.withLock { $0.entries.count }
    }

    public var cost: Int {
        state.withLock { $0.cost }
    }

    public var isEmpty: Bool {
        state.withLock { $0.entries.isEmpty }
    }

    /// The request's result, or the last image of its source in another style marked stale.
    /// A cached failure keeps its diagnostics and shows that stale image.
    public func lookup(_ request: MathRenderRequest) -> MathRenderResult? {
        state.withLock { state in
            state.clock += 1
            let entry = state.entries[request]
            if let entry {
                state.entries[request]?.used = state.clock
                if entry.image != nil {
                    return MathRenderResult(
                        request: request,
                        image: entry.image,
                        diagnostics: entry.diagnostics,
                        isStale: false,
                    )
                }
            }
            let variant = Variant(source: request.source, isBlock: request.isBlock)
            let previous = state.latest[variant]
            let image = previous.flatMap { state.entries[$0]?.image }
            if let previous, image != nil {
                state.entries[previous]?.used = state.clock
            }
            guard entry != nil || image != nil else {
                return nil
            }
            return MathRenderResult(
                request: request,
                image: image,
                diagnostics: entry?.diagnostics ?? [],
                isStale: image != nil,
            )
        }
    }

    /// Keeps a current result: a rendering, or a failure the engine explained.
    func store(_ result: MathRenderResult) {
        guard !result.isTransient, result.failed || !result.isStale else {
            return
        }
        let image = result.failed ? nil : result.image
        state.withLock { state in
            state.clock += 1
            if let old = state.entries[result.request] {
                state.cost -= old.image?.cost ?? 0
            }
            state.entries[result.request] = Entry(image: image, diagnostics: result.diagnostics, used: state.clock)
            state.cost += image?.cost ?? 0
            if image != nil {
                state.latest[Variant(source: result.request.source, isBlock: result.request.isBlock)] = result.request
            }
            guard state.cost > maximumCost || state.entries.count > maximumCount else {
                return
            }
            // Evict to three quarters of each bound, oldest first, so eviction is rare.
            let targetCost = maximumCost / 4 * 3, targetCount = maximumCount / 4 * 3
            for (request, entry) in state.entries.sorted(by: { $0.value.used < $1.value.used }) {
                guard state.cost > targetCost || state.entries.count > targetCount else {
                    break
                }
                state.entries[request] = nil
                state.cost -= entry.image?.cost ?? 0
                let variant = Variant(source: request.source, isBlock: request.isBlock)
                if state.latest[variant] == request {
                    state.latest[variant] = nil
                }
            }
        }
    }

    /// Forgets everything, for example after a file the rules import changed on disk.
    public func removeAll() {
        state.withLock { $0 = State() }
    }
}

/// A value behind a lock; the closure must not escape it.
final class NSLockedState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// The document's rules that style its equations.
public enum MathPreamble {
    /// Top-level `#set`, `#show selector: …`, `#let` and `#import` statements of `source`, in order.
    /// Whole-document `#show: template` rules and content are left out: a template's pages and
    /// title would shape every equation's page.
    public static func extract(source: String, nodes: [SyntaxNode]) -> String {
        let text = source as NSString
        let kinds: Set<SyntaxKind> = [.setRule, .showRule, .letBinding, .moduleImport]
        var statements: [String] = []
        for node in nodes where node.parent == 0 && kinds.contains(node.kind) && !node.isErroneous {
            let statement = text.substring(with: node.range)
            if node.kind == .showRule,
               statement.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(":")
            {
                continue
            }
            let hashed = node.range.location > 0 && text.character(at: node.range.location - 1) == 0x23
            statements.append((hashed ? "#" : "") + statement)
        }
        return statements.joined(separator: "\n")
    }

    /// Parses `source` first; empty when no parser is available.
    public static func extract(source: String) -> String {
        guard let nodes = SyntaxTree(source)?.nodes() else {
            return ""
        }
        return extract(source: source, nodes: nodes)
    }
}
