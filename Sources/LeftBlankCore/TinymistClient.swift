import Foundation

public enum ServiceError: LocalizedError {
    case unavailable
    case disconnected
    case timeout
    case remote(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: L10n
            .text("The typesetting service could not be found. Rebuild the app or check the Tinymist path.")
        case .disconnected: L10n.text("The typesetting service disconnected. You can still edit and save your writing.")
        case .timeout: L10n.text("The typesetting service timed out. Try again or reconnect.")
        case let .remote(message):
            if let start = message.range(of: "error: ") {
                String(message[start.upperBound...].components(separatedBy: "\\n")[0])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                String(message.prefix(400))
            }
        }
    }
}

@MainActor
public final class TinymistClient {
    public static var bundledFontURL: URL? {
        L10n.resourceBundle.url(forResource: "NotoSansSC", withExtension: "ttf")
    }

    private let makeTransport: @MainActor () throws -> any TinymistTransport

    public init(makeTransport: (@MainActor () throws -> any TinymistTransport)? = nil) {
        self.makeTransport = makeTransport ?? {
            #if os(macOS)
                return ProcessTinymistTransport()
            #else
                throw ServiceError.unavailable
            #endif
        }
    }

    public var onNotification: ((String, JSONValue) -> Void)?
    public var onShowDocument: ((JSONValue) -> Void)?
    public var onDisconnect: ((String) -> Void)?
    private var transport: (any TinymistTransport)?
    private var writer: JSONRPCWriter?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var serial = 0
    private var generation = UUID()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    public private(set) var capabilities: JSONValue = .null
    public private(set) var initialized = false
    public private(set) var semanticTokenTypes: [String] = []
    public private(set) var semanticTokenModifiers: [String] = []

    #if os(macOS)
        public static var binaryURL: URL? {
            ProcessTinymistTransport.binaryURL
        }
    #endif

    public func start(root: URL, outputDirectory: URL, fontPaths: [URL] = [], packageCache: URL? = nil) async throws {
        stop()
        let transport = try makeTransport()
        let session = generation
        let reader = JSONRPCReader { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == session else {
                    return
                }
                switch result {
                case let .success(message): self.consume(message)
                case let .failure(error): connectionFailed(error)
                }
            }
        }
        transport.output.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                reader.append(data)
            }
        }
        // Drain stderr without logging manuscript content.
        transport.errorOutput?.readabilityHandler = { handle in _ = handle.availableData }
        transport.onExit = { [weak self] status in
            guard let self, generation == session else {
                return
            }
            stop()
            onDisconnect?(L10n.format(
                "The typesetting service exited (%@). Your writing is still safe.",
                String(status),
            ))
        }
        self.transport = transport
        writer = try JSONRPCWriter(handle: transport.input) { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == session else {
                    return
                }
                connectionFailed(error)
            }
        }
        output = transport.output
        errorOutput = transport.errorOutput
        try transport.start(root: root)
        let packageCache = packageCache ?? outputDirectory.deletingLastPathComponent()
            .appendingPathComponent("PackageCache")
        try BundledPackages.prepare(in: packageCache)
        // iPad's PingFang UI collection uses Apple-specific glyph tables that
        // Typst cannot parse. Supply the same portable CJK fallback on both platforms.
        let bundledFont = Self.bundledFontURL
        let response = try await request("initialize", [
            "processId": ProcessInfo.processInfo.processIdentifier,
            "rootUri": root.absoluteString,
            "capabilities": [
                "general": ["positionEncodings": ["utf-16"]],
                "window": ["showDocument": ["support": true]],
                "textDocument": [
                    "publishDiagnostics": ["versionSupport": true],
                    "completion": ["completionItem": ["snippetSupport": false]],
                    "hover": ["contentFormat": ["plaintext"]],
                    "definition": ["linkSupport": true],
                    "signatureHelp": ["signatureInformation": [
                        "documentationFormat": ["plaintext"],
                        "parameterInformation": ["labelOffsetSupport": true],
                    ]],
                    "codeAction": ["codeActionLiteralSupport": ["codeActionKind": ["valueSet": [
                        "quickfix",
                        "refactor",
                        "refactor.rewrite",
                    ]]]],
                    "semanticTokens": ["requests": ["full": true], "tokenTypes": SemanticHighlighting.tokenTypes,
                                       "tokenModifiers": SemanticHighlighting.tokenModifiers,
                                       "formats": ["relative"],
                                       "multilineTokenSupport": false, "overlappingTokenSupport": false],
                ],
            ],
            "initializationOptions": [
                "fontPaths": (fontPaths + [bundledFont].compactMap(\.self)).map(\.path),
                "rootPath": root.path,
                "exportPdf": "never",
                "outputPath": outputDirectory.appendingPathComponent("$name").path,
                "compileStatus": "enable",
                "typstExtraArgs": ["--package-cache-path", packageCache.path],
            ],
        ])
        guard generation == session else {
            throw ServiceError.disconnected
        }
        capabilities = response["capabilities"]
        let legend = response["capabilities"]["semanticTokensProvider"]["legend"]
        semanticTokenTypes = legend["tokenTypes"].array.compactMap(\.string)
        semanticTokenModifiers = legend["tokenModifiers"].array.compactMap(\.string)
        try notify("initialized", [:])
        initialized = true
    }

    public func supports(_ capability: String) -> Bool {
        switch capabilities[capability] {
        case let .bool(enabled): enabled
        case .object: true
        default: false
        }
    }

    public func stop() {
        generation = UUID()
        initialized = false
        capabilities = .null
        semanticTokenTypes = []
        semanticTokenModifiers = []
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        transport?.onExit = nil
        writer?.close()
        writer = nil
        transport?.stop()
        output = nil
        errorOutput = nil
        transport = nil
        let waiting = pending
        pending.removeAll()
        timeouts.values.forEach { $0.cancel() }
        timeouts.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: ServiceError.disconnected)
        }
    }

    public func notify(_ method: String, _ params: [String: Any]) throws {
        try write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    public func request(_ method: String, _ params: [String: Any]) async throws -> JSONValue {
        serial += 1
        let id = serial
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.pending.removeValue(forKey: id)?.resume(throwing: ServiceError.timeout)
                self?.timeouts.removeValue(forKey: id)
            }
            do { try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) }
            catch {
                timeouts.removeValue(forKey: id)?.cancel()
                pending.removeValue(forKey: id)?.resume(throwing: error)
            }
        }
    }

    public func command(_ name: String, arguments: [Any]) async throws -> JSONValue {
        try await request("workspace/executeCommand", ["command": name, "arguments": arguments])
    }

    public func open(_ url: URL, text: String, version: Int) throws {
        try notify(
            "textDocument/didOpen",
            ["textDocument": ["uri": url.absoluteString, "languageId": "typst", "version": version, "text": text]],
        )
    }

    public func change(_ url: URL, text: String, version: Int) throws {
        try notify(
            "textDocument/didChange",
            ["textDocument": ["uri": url.absoluteString, "version": version], "contentChanges": [["text": text]]],
        )
    }

    public func startPreview(_ url: URL) async throws -> URL {
        let response = try await command("tinymist.doStartPreview", arguments: [[
            "--task-id=leftblank", "--data-plane-host=127.0.0.1:0", "--control-plane-host=127.0.0.1:0", "--no-open",
            "--partial-rendering=true",
            "--invert-colors=never", url.path,
        ]])
        guard let port = response["staticServerPort"].int,
              let preview = URL(string: "http://127.0.0.1:\(port)/")
        else {
            throw ServiceError.remote(L10n.text("The preview service did not return a valid address."))
        }
        return preview
    }

    private func write(_ object: [String: Any]) throws {
        guard let writer, transport?.isRunning == true else {
            throw ServiceError.disconnected
        }
        try writer.send(JSONValue(foundation: object))
    }

    private func consume(_ message: JSONValue) {
        do {
            if let method = message["method"].string {
                if !message["id"].isNull {
                    let result: Any
                    if method == "window/showDocument" {
                        onShowDocument?(message["params"])
                        result = ["success": true]
                    } else if method == "workspace/configuration" {
                        result = message["params"]["items"].array.map { _ in NSNull() }
                    } else {
                        result = NSNull()
                    }
                    try write(["jsonrpc": "2.0", "id": message["id"].foundationValue, "result": result])
                } else {
                    onNotification?(method, message["params"])
                }
            } else if let id = message["id"].int, let continuation = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel()
                if !message["error"]
                    .isNull
                {
                    continuation
                        .resume(throwing: ServiceError
                            .remote(message["error"]["message"].string ?? L10n
                                .text("The typesetting service encountered an error.")))
                } else {
                    continuation.resume(returning: message["result"])
                }
            }
        } catch { connectionFailed(error) }
    }

    private func connectionFailed(_ error: Error) {
        stop()
        onDisconnect?(L10n.format("Typesetting connection interrupted: %@", error.localizedDescription))
    }
}
