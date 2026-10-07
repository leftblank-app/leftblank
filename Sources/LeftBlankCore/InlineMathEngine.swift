import CoreGraphics
import Foundation
import ImageIO

/// One export of the synthetic math document.
public enum MathExport: Sendable, Equatable {
    /// Each equation's size and baseline (`tinymist.exportQuery`).
    case probe
    /// The given 1-based pages as PNG (`tinymist.exportPng`).
    case png(pages: [Int], ppi: Double)
}

public enum MathExportOutput: Sendable {
    /// The engine's command result.
    case completed(JSONValue)
    /// The document did not compile, or the engine rejected the command.
    case failed(String)
    /// No engine is available; nothing is wrong with the equations.
    case unavailable(String)
}

/// Compiles a math document in a long-lived engine and runs one export on it.
public protocol MathTypesetter: Sendable {
    /// `file` names the document in `directory`; it never exists on disk.
    func export(_ export: MathExport, source: String, file: String, root: URL?, directory: URL?) async
        -> MathExportOutput
}

/// Batches, caches and typesets equations with a `MathTypesetter`, one batch at a time.
public actor EngineMathRenderer: InlineMathRenderer {
    public nonisolated let cache: MathRenderCache
    private let typesetter: any MathTypesetter
    private let maximumBatch: Int
    /// The largest image edge in pixels; larger equations fail with a diagnostic.
    static let maximumEdge = 4096.0
    private let file = ".leftblank-math-\(UUID().uuidString).typ"
    private var inflight: [MathRenderRequest: Task<[MathRenderRequest: MathRenderResult], Never>] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(typesetter: any MathTypesetter, cache: MathRenderCache = MathRenderCache(), maximumBatch: Int = 200) {
        self.typesetter = typesetter
        self.cache = cache
        self.maximumBatch = max(1, maximumBatch)
    }

    public nonisolated func cached(_ request: MathRenderRequest) -> MathRenderResult? {
        cache.lookup(request)
    }

    public func render(_ requests: [MathRenderRequest]) async -> [MathRenderResult] {
        var results: [MathRenderRequest: MathRenderResult] = [:]
        var missing: [MathRenderRequest] = [], waiting: [Task<[MathRenderRequest: MathRenderResult], Never>] = []
        var seen = Set<MathRenderRequest>()
        for request in requests where seen.insert(request).inserted {
            // A cached failure is current too, even while it shows a stale image.
            if let hit = cache.lookup(request), !hit.isStale || hit.failed {
                results[request] = hit
            } else if let task = inflight[request] {
                waiting.append(task)
            } else {
                missing.append(request)
            }
        }
        if !missing.isEmpty {
            let task = Task { await self.typeset(missing) }
            for request in missing {
                inflight[request] = task
            }
            waiting.append(task)
        }
        for task in waiting {
            await results.merge(task.value) { old, _ in old }
        }
        for request in missing {
            inflight[request] = nil
        }
        return requests.map { results[$0] ?? failure($0, L10n.text("The equation could not be rendered.")) }
    }

    private func typeset(_ requests: [MathRenderRequest]) async -> [MathRenderRequest: MathRenderResult] {
        var groups: [MathRenderStyle: [MathRenderRequest]] = [:], order: [MathRenderStyle] = []
        for request in requests {
            if groups[request.style] == nil {
                order.append(request.style)
            }
            groups[request.style, default: []].append(request)
        }
        var results: [MathRenderRequest: MathRenderResult] = [:]
        for style in order {
            let group = groups[style] ?? []
            for start in stride(from: 0, to: group.count, by: maximumBatch) {
                await acquire()
                let batch = Array(group[start ..< min(start + maximumBatch, group.count)])
                let rendered = await compile(batch, style: style)
                release()
                for result in rendered {
                    cache.store(result)
                    results[result.request] = result
                }
            }
        }
        return results
    }

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Isolates failures: an error inside an equation fails that equation, an error in the rules
    /// drops the rules with a warning, and an unplaced error splits the batch.
    private func compile(_ batch: [MathRenderRequest], style: MathRenderStyle) async -> [MathRenderResult] {
        var results: [MathRenderResult] = []
        var queue = [batch], preamble = style.preamble, warnings: [MathDiagnostic] = [], rulesChecked = false
        while var current = queue.popLast() {
            let sources = current.map(\.source)
            let document = MathDocument(sources, style: style, preamble: preamble)
            switch await export(.probe, document, style) {
            case let .unavailable(message):
                results += current.map { failure($0, message) }
            case let .completed(response):
                results += await draw(current, document: document, probes: response, style: style)
            case let .failed(message):
                let errors = MathDocument.errors(in: message)
                var failures: [Int: [MathDiagnostic]] = [:]
                for error in errors {
                    if let (index, offset) = document.locate(error, file: file, equations: sources) {
                        failures[index, default: []].append(MathDiagnostic(
                            severity: .error,
                            message: error.message,
                            range: NSRange(location: offset, length: 0),
                        ))
                    }
                }
                if !failures.isEmpty {
                    results += failures.map { failure(current[$0.key], $0.value) }
                    current = current.enumerated().filter { failures[$0.offset] == nil }.map(\.element)
                    if !current.isEmpty {
                        queue.append(current)
                    }
                    continue
                }
                if !rulesChecked, !preamble.isEmpty {
                    rulesChecked = true
                    let rules = MathDocument([], style: style, preamble: preamble)
                    if case let .failed(rulesMessage) = await export(.probe, rules, style) {
                        let reason = MathDocument.errors(in: rulesMessage).first?.message ?? rulesMessage
                        warnings.append(MathDiagnostic(
                            severity: .warning,
                            message: L10n.format("The document's rules for equations do not compile: %@", reason),
                        ))
                        preamble = ""
                        queue.append(current)
                        continue
                    }
                }
                if current.count == 1 {
                    let diagnostics = errors.map { MathDiagnostic(severity: .error, message: $0.message) }
                    results.append(failure(current[0], diagnostics.isEmpty ? [MathDiagnostic(
                        severity: .error,
                        message: message,
                    )] : diagnostics))
                } else {
                    queue.append(Array(current[(current.count / 2)...]))
                    queue.append(Array(current[..<(current.count / 2)]))
                }
            }
        }
        guard !warnings.isEmpty else {
            return results
        }
        return results.map { result in
            var warned = MathRenderResult(
                request: result.request,
                image: result.image,
                diagnostics: result.diagnostics + warnings,
                isStale: result.isStale,
            )
            warned.isTransient = result.isTransient
            return warned
        }
    }

    private struct Probe {
        let width: Double
        let height: Double
        let descent: Double
        let textSize: Double
        let page: Int
    }

    /// Rasterizes the probed pages, scaled so the document's text size becomes the editor's.
    private func draw(
        _ batch: [MathRenderRequest],
        document: MathDocument,
        probes response: JSONValue,
        style: MathRenderStyle,
    ) async -> [MathRenderResult] {
        let notRendered = L10n.text("The equation could not be rendered.")
        var probes: [Int: Probe] = [:]
        if let encoded = response["data"].string, let data = Data(base64Encoded: encoded),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        {
            for item in value.array {
                guard let index = item["i"].int, let width = item["w"].double, let height = item["h"].double,
                      let descent = item["d"].double, let size = item["size"].double, let page = item["page"].int
                else {
                    continue
                }
                probes[index] = Probe(width: width, height: height, descent: descent, textSize: size, page: page)
            }
        }
        guard let textSize = probes.values.first?.textSize, textSize > 0 else {
            return batch.map { failure($0, notRendered) }
        }
        let factor = style.fontSize / textSize, ppi = 72 * style.scale * factor
        var results: [MathRenderResult] = []
        var pages: [Int: (request: MathRenderRequest, probe: Probe)] = [:]
        for (index, request) in batch.enumerated() {
            guard let probe = probes[index] else {
                results.append(failure(request, notRendered))
                continue
            }
            guard max(probe.width, probe.height) * ppi / 72 <= Self.maximumEdge else {
                results.append(failure(request, [MathDiagnostic(
                    severity: .error,
                    message: L10n.text("The equation is too large to show in the editor."),
                )]))
                continue
            }
            pages[probe.page] = (request, probe)
        }
        guard !pages.isEmpty else {
            return results
        }
        let output = await export(.png(pages: pages.keys.sorted(), ppi: ppi), document, style)
        guard case let .completed(rendered) = output else {
            let message = switch output {
            case let .failed(message), let .unavailable(message): message
            case .completed: ""
            }
            return results + pages.values.map { failure($0.request, message) }
        }
        var images: [Int: CGImage] = [:]
        for item in rendered["items"].array {
            if let page = item["page"].int, let encoded = item["data"].string,
               let data = Data(base64Encoded: encoded), let image = Self.decode(data)
            {
                images[page + 1] = image
            }
        }
        for (page, entry) in pages.sorted(by: { $0.key < $1.key }) {
            guard let image = images[page] else {
                results.append(failure(entry.request, notRendered))
                continue
            }
            let probe = entry.probe
            results.append(MathRenderResult(
                request: entry.request,
                image: MathImage(
                    image: image,
                    size: CGSize(width: probe.width * factor, height: probe.height * factor),
                    baseline: (probe.height - probe.descent) * factor,
                ),
                diagnostics: [],
                isStale: false,
            ))
        }
        return results
    }

    private func export(_ export: MathExport, _ document: MathDocument, _ style: MathRenderStyle) async
        -> MathExportOutput
    {
        await typesetter.export(
            export,
            source: document.source,
            file: file,
            root: style.root,
            directory: style.directory,
        )
    }

    /// Decodes now, off the main thread, so drawing never decompresses.
    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(
            source,
            0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary,
        )
    }

    /// A failed rendering that keeps showing an earlier image of the same source, marked stale.
    private nonisolated func failure(
        _ request: MathRenderRequest,
        _ diagnostics: [MathDiagnostic],
    ) -> MathRenderResult {
        let earlier = cache.lookup(request)
        return MathRenderResult(
            request: request,
            image: earlier?.image,
            diagnostics: diagnostics,
            isStale: earlier?.image != nil,
        )
    }

    /// The engine produced no result, so the failure is not cached.
    private nonisolated func failure(_ request: MathRenderRequest, _ message: String) -> MathRenderResult {
        var result = failure(request, [MathDiagnostic(severity: .error, message: message)])
        result.isTransient = true
        return result
    }
}

extension JSONValue {
    var double: Double? {
        if case let .number(value) = self {
            return value
        }
        return nil
    }
}

/// A dedicated Tinymist session for equations, separate from the manuscript's: it starts on the
/// first request, keeps one virtual file open and stops after an idle period.
@MainActor
public final class TinymistMathTypesetter: MathTypesetter {
    private let makeTransport: (@MainActor () throws -> any TinymistTransport)?
    private let workDirectory: URL
    private let fontPaths: [URL]
    private let packageCache: URL?
    private let idleTimeout: Duration
    private var client: TinymistClient?
    private var root: URL?
    private var file: URL?
    private var text: String?
    private var version = 0
    private var idle: Task<Void, Never>?
    public private(set) var starts = 0

    public init(
        makeTransport: (@MainActor () throws -> any TinymistTransport)? = nil,
        workDirectory: URL,
        fontPaths: [URL] = [],
        packageCache: URL? = nil,
        idleTimeout: Duration = .seconds(60),
    ) {
        self.makeTransport = makeTransport
        self.workDirectory = workDirectory
        self.fontPaths = fontPaths
        self.packageCache = packageCache
        self.idleTimeout = idleTimeout
    }

    public var isRunning: Bool {
        client?.initialized == true
    }

    public func export(_ export: MathExport, source: String, file name: String, root: URL?, directory: URL?) async
        -> MathExportOutput
    {
        idle?.cancel()
        defer { scheduleStop() }
        let directory = (directory ?? root ?? workDirectory.appendingPathComponent("Root")).standardizedFileURL
        var root = (root ?? directory).standardizedFileURL
        if !(directory.path + "/").hasPrefix(root.path + "/") {
            root = directory
        }
        let file = directory.appendingPathComponent(name)
        do {
            let client = try await session(root: root)
            if self.file?.path != file.path {
                if let previous = self.file {
                    try? client.close(previous)
                }
                version += 1
                try client.open(file, text: source, version: version)
                self.file = file
                text = source
            } else if text != source {
                version += 1
                try client.change(file, text: source, version: version)
                text = source
            }
            let options: JSONValue = switch export {
            case .probe:
                .object([
                    "format": .string("json"),
                    "selector": .string("<\(MathDocument.probeLabel)>"),
                    "field": .string("value"),
                    "one": .bool(false),
                ])
            case let .png(pages, ppi):
                .object(["pages": .array(pages.map { .string(String($0)) }), "ppi": .number(ppi)])
            }
            let command = export == .probe ? "tinymist.exportQuery" : "tinymist.exportPng"
            let response = try await client.command(command, arguments: [file.path, options.foundationValue,
                                                                         ["write": false]])
            return .completed(response)
        } catch let ServiceError.remote(message) {
            return .failed(message.replacingOccurrences(of: directory.path + "/", with: ""))
        } catch {
            stop()
            return .unavailable(error.localizedDescription)
        }
    }

    private func session(root: URL) async throws -> TinymistClient {
        // Compare paths: a directory URL gains a trailing slash once the folder exists.
        if let client, client.initialized, self.root?.path == root.path {
            return client
        }
        stop()
        let client = TinymistClient(makeTransport: makeTransport)
        client.onDisconnect = { [weak self, weak client] _ in
            guard let self, let client, self.client === client else {
                return
            }
            stop()
        }
        self.client = client
        self.root = root
        let output = workDirectory.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: workDirectory.appendingPathComponent("Root"),
            withIntermediateDirectories: true,
        )
        starts += 1
        try await client.start(root: root, outputDirectory: output, fontPaths: fontPaths, packageCache: packageCache)
        return client
    }

    private func scheduleStop() {
        idle?.cancel()
        let timeout = idleTimeout
        idle = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.stop()
        }
    }

    /// Ends the engine; the next request starts a new one.
    public func stop() {
        idle?.cancel()
        idle = nil
        client?.stop()
        client = nil
        root = nil
        file = nil
        text = nil
    }

    #if os(macOS)
        /// The Mac renderer: its own Tinymist helper process, so equations never touch the
        /// manuscript's session, preview or diagnostics.
        public static func renderer(stateDirectory: URL) -> EngineMathRenderer {
            EngineMathRenderer(typesetter: TinymistMathTypesetter(
                workDirectory: stateDirectory.appendingPathComponent("InlineMath"),
                packageCache: stateDirectory.appendingPathComponent("PackageCache"),
            ))
        }
    #endif
}
