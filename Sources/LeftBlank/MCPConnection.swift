import AppKit
import Combine
import Darwin
import Foundation
import LeftBlankCore
import Security

/// macOS-only lifecycle and credentials. Neither this file nor the helper is in the iPad package graph.
@MainActor
final class MCPConnection: ObservableObject {
    private struct Configuration: Codable {
        let token: String
        let grantID: UUID
        let documentIDs: Set<UUID>?
        let canWrite: Bool
        var access: AgentToolAccess {
            AgentToolAccess(documentIDs: documentIDs, canWrite: canWrite, id: grantID)
        }
    }

    private weak var workspace: Workspace?
    private let directory: URL
    private let helperURL: URL?
    private var process: Process?
    private var pipe: MCPLinePipe?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var generation = UUID()
    private var calls: [Int: Task<Void, Never>] = [:]
    private var startup: CheckedContinuation<Void, Error>?
    private var startupTimeout: Task<Void, Never>?
    private var dispatcher: AgentToolDispatcher?
    private var configuration: Configuration?
    private var port = 0
    @Published private(set) var isRunning = false
    @Published private(set) var isEnabled = false
    @Published private(set) var failureMessage: String?
    @Published private(set) var portInUse = false
    var allowsEditing: Bool {
        configuration?.canWrite ?? false
    }

    var grantedDocumentIDs: Set<UUID>? {
        configuration?.documentIDs
    }

    var descriptorURL: URL {
        directory.appendingPathComponent("connection.json")
    }

    init(workspace: Workspace, helperURL: URL? = nil) {
        self.workspace = workspace
        directory = workspace.stateDirectory.appendingPathComponent("MCP")
        self.helperURL = helperURL ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/leftblank-mcp")
    }

    func resume() async {
        let file = directory.appendingPathComponent("access.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            return
        }
        isEnabled = true
        do {
            let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file))
            try await start(value)
        } catch where !portInUse {
            failureMessage = L10n.text("Could not start the coding agent connection. Enable it again in Settings.")
        } catch {}
    }

    /// Keeps the saved permission and token but lets the helper pick a free port.
    func useNewPort() async throws {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("port.json"))
        let file = directory.appendingPathComponent("access.json")
        if let value = try? JSONDecoder().decode(Configuration.self, from: Data(contentsOf: file)) {
            try await start(value)
        } else {
            try await enable()
        }
    }

    static func canListen(on port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else {
            return true
        }
        defer { close(socket) }
        // Match the helper's listener, which reuses addresses left in TIME_WAIT.
        var reuse: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    func enable(documentIDs: Set<UUID>? = nil, canWrite: Bool = true) async throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else {
            throw ServiceError.unavailable
        }
        let value = Configuration(
            token: bytes.map { String(format: "%02x", $0) }.joined(),
            grantID: UUID(),
            documentIDs: documentIDs,
            canWrite: canWrite,
        )
        try await start(value)
        do {
            try writePrivate(JSONEncoder().encode(value), name: "access.json")
            isEnabled = true
        } catch { stop()
            throw error
        }
    }

    private func start(_ value: Configuration) async throws {
        stop()
        guard let workspace, let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw AgentToolError("helper_unavailable", "The MCP helper is missing. Build or reinstall the macOS app.")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        guard try (directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
        else {
            throw ServiceError.unavailable
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        port = (try? JSONDecoder().decode(
            Int.self,
            from: Data(contentsOf: directory.appendingPathComponent("port.json")),
        )) ?? 0
        guard (0 ... 65535).contains(port) else {
            throw ServiceError.unavailable
        }
        // Agents are configured with this port, so explain a conflict instead of silently moving.
        guard port == 0 || Self.canListen(on: port) else {
            portInUse = true
            let message = L10n.format(
                "Port %@ is used by another app. Quit that app, or use a new port and give your coding agent the setup prompt again.",
                // A port is an identifier, so never group its digits.
                String(port),
            )
            failureMessage = message
            throw AgentToolError("port_in_use", message)
        }
        portInUse = false
        configuration = value
        dispatcher = AgentToolDispatcher(
            library: workspace.library.store,
            history: workspace.history.store,
            host: workspace,
        )
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = helperURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let session = generation
        let connection = try MCPLinePipe(input: input.fileHandleForWriting) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, generation == session else {
                    return
                }
                switch result {
                case let .success(message): receive(message)
                case .failure: fail()
                }
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                connection.disconnected()
            } else {
                connection.receive(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == session else {
                    return
                }
                fail()
            }
        }
        self.process = process
        pipe = connection
        self.output = output.fileHandleForReading
        errorOutput = errors.fileHandleForReading
        do {
            try process.run()
            try input.fileHandleForReading.close()
            try input.fileHandleForWriting.close()
            try output.fileHandleForWriting.close()
            try errors.fileHandleForWriting.close()
            try connection.send(.object(["bridge_version": .number(1), "port": .number(Double(port)),
                                         "token": .string(value.token),
                                         "instructions": .string(AgentTools.instructions),
                                         "tools": .array(AgentTools.definitions.filter { value.canWrite || $0.readOnly }
                                             .map { tool in .object([
                                                 "name": .string(tool.name),
                                                 "description": .string(tool.description),
                                                 "inputSchema": tool.inputSchema,
                                                 "outputSchema": .object(["type": .string("object")]),
                                                 "annotations": .object([
                                                     "readOnlyHint": .bool(tool.readOnly),
                                                     "destructiveHint": .bool(tool.destructive),
                                                     "openWorldHint": .bool(false),
                                                 ]),
                                             ]) })]))
            try await withCheckedThrowingContinuation { continuation in
                startup = continuation
                startupTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(10)) } catch { return }
                    guard let self, generation == session else {
                        return
                    }
                    fail()
                }
            }
        } catch { stop()
            throw error
        }
    }

    private func receive(_ message: JSONValue) {
        guard let configuration else {
            return
        }
        if message["event"].string == "ready" {
            guard !isRunning, message["bridge_version"].int == 1, let assigned = message["port"].int,
                  (1 ... 65535).contains(assigned), port == 0 || assigned == port
            else {
                fail()
                return
            }
            port = assigned
            do {
                try writePrivate(JSONEncoder().encode(port), name: "port.json")
                let descriptor: JSONValue = .object(["format_version": .number(1), "server_name": .string(serverName),
                                                     "app_bundle_id": .string(AppDistribution.current.bundleIdentifier),
                                                     "app_version": .string(Bundle.main
                                                         .object(
                                                             forInfoDictionaryKey: "CFBundleShortVersionString",
                                                         ) as? String ??
                                                         "development"),
                                                     "instance_id": .string(generation.uuidString),
                                                     "transport": .string("streamable-http"),
                                                     "url": .string("http://127.0.0.1:\(port)/mcp"),
                                                     "authentication": .object([
                                                         "type": .string("bearer"),
                                                         "token": .string(configuration.token),
                                                     ])])
                try writePrivate(JSONEncoder().encode(descriptor), name: "connection.json")
                isRunning = true
                failureMessage = nil
                startupTimeout?.cancel()
                startupTimeout = nil
                startup?.resume()
                startup = nil
            } catch { fail() }
            return
        }
        if let id = message["cancel"].int {
            calls[id]?.cancel()
            return
        }
        guard isRunning, let id = message["id"].int, let method = message["method"].string, let dispatcher,
              calls[id] == nil, calls.count < 32
        else {
            fail()
            return
        }
        let session = generation
        calls[id] = Task { [weak self] in
            let result = await dispatcher.call(method, arguments: message["arguments"], access: configuration.access)
            guard let self, generation == session else {
                return
            }
            calls[id] = nil
            var value = result.value
            if method == "get_app_state", !result.isError, case var .object(state) = value {
                state["instance_id"] = .string(session.uuidString)
                state["mcp"] = .object(["transport": .string("streamable-http"), "connected": .bool(true)])
                value = .object(state)
            }
            let images: [JSONValue] = result.images.map { image in .object([
                "data": .string(image.data.base64EncodedString()),
                "mime_type": .string(image.mimeType),
            ]) }
            do { try pipe?.send(.object([
                "id": .number(Double(id)),
                "result": .object(["value": value, "is_error": .bool(result.isError), "images": .array(images)]),
            ])) } catch { fail() }
        }
    }

    private var serverName: String {
        AppDistribution.current == .preview ? "leftblank-preview" : "leftblank"
    }

    func setupPrompt() throws -> String {
        guard isRunning else {
            throw AgentToolError("unavailable", "Enable the coding agent connection first.")
        }
        return """
        请把这台 Mac 上的 LeftBlank MCP 服务配置到你当前使用的 coding agent 客户端。
        应用已自带服务，无需下载 server 或安装 Rust/Cargo/Node/Python，应用需保持运行。
        连接信息文件：\(descriptorURL.path)
        预期应用标识：\(AppDistribution.current.bundleIdentifier)
        预期服务名称：\(serverName)
        1. 确认在同一台 Mac 执行，识别当前客户端的实际配置位置。
        2. 用本地程序读取 JSON，校验 format_version=1、应用标识、名称和 URL 主机 127.0.0.1。文件含凭证，不要打印全文、token 或带凭证的命令，不写入仓库或聊天。
        3. 按已安装客户端官方文档配置用户私有范围的 Streamable HTTP 服务，凭证通过 Authorization Bearer 使用。保留其他配置；同名不同应用的连接报告冲突。不要修改全局审批或信任设置。确保客户端重启后仍能取得凭证。
        4. 重载服务，列出工具并只读调用 get_app_state，验证应用和 instance_id。不要读取正文或修改文档来测试安装。无法在当前会话重载时，报告配置已写入、尚未验证，并给出重连步骤。
        5. 简要报告配置位置、服务名称和验证结果，不显示凭证。遇到文件缺失、身份不符、认证失败或重定向时停止，让我回到应用重新启用连接。不要扫描凭证或绕开 MCP 访问文档库。
        官方参考：https://developers.openai.com/codex/mcp 和 https://code.claude.com/docs/en/mcp
        """
    }

    func disable() {
        stop()
        let savedAccess = directory.appendingPathComponent("access.json")
        try? FileManager.default.removeItem(at: savedAccess)
        isEnabled = FileManager.default.fileExists(atPath: savedAccess.path)
        if isEnabled {
            failureMessage = L10n
                .text("The connection stopped, but its saved permission could not be removed. Try disconnecting again.")
        }
    }

    func stop() {
        generation = UUID()
        isRunning = false
        startupTimeout?.cancel()
        startupTimeout = nil
        startup?.resume(throwing: ServiceError.disconnected)
        startup = nil
        calls.values.forEach { $0.cancel() }
        calls.removeAll()
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        process?.terminationHandler = nil
        pipe?.close()
        pipe = nil
        if let process, process.isRunning {
            process.terminate()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        process = nil
        output = nil
        errorOutput = nil
        dispatcher = nil
        configuration = nil
        try? FileManager.default.removeItem(at: descriptorURL)
    }

    private func fail() {
        stop()
        failureMessage = L10n.text("The coding agent connection stopped. Your writing remains open.")
        workspace?.showMessage(failureMessage ?? "", persistent: true)
    }

    private func writePrivate(_ data: Data, name: String) throws {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The serial queue owns its duplicated descriptor; slow helper I/O never blocks AppKit.
private final class MCPLinePipe: @unchecked Sendable {
    private let input: FileHandle
    private let writeQueue = DispatchQueue(label: "app.leftblank.mcp.write")
    private let readQueue = DispatchQueue(label: "app.leftblank.mcp.read")
    private let lock = NSLock()
    private var closed = false
    private var queued = 0
    private var buffer = Data()
    private let callback: @Sendable (Result<JSONValue, Error>) -> Void
    init(input: FileHandle, callback: @escaping @Sendable (Result<JSONValue, Error>) -> Void) throws {
        let descriptor = fcntl(input.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else {
            throw ServiceError.unavailable
        }
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
            Darwin.close(descriptor)
            throw ServiceError.unavailable
        }
        self.input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.callback = callback
    }

    func send(_ message: JSONValue) throws {
        var data = try JSONEncoder().encode(message)
        data.append(10)
        let frame = data
        let allowed = lock.withLock {
            guard !closed, frame.count < 8 * 1024 * 1024, queued + frame.count <= 16 * 1024 * 1024 else {
                return false
            }
            queued += frame.count
            return true
        }
        guard allowed else {
            throw ServiceError.disconnected
        }
        writeQueue.async { [self] in
            defer { lock.withLock { queued -= frame.count } }
            guard !lock.withLock({ closed }) else {
                return
            }
            do { try input.write(contentsOf: frame) }
            catch { disconnected() }
        }
    }

    func receive(_ data: Data) {
        readQueue.async { [self] in
            guard !lock.withLock({ closed }) else {
                return
            }
            buffer.append(data)
            guard buffer.count <= 8 * 1024 * 1024 else {
                disconnected()
                return
            }
            do {
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end])
                    buffer.removeSubrange(...end)
                    try callback(.success(JSONDecoder().decode(JSONValue.self, from: line)))
                }
            } catch { disconnected() }
        }
    }

    func disconnected() {
        callback(.failure(ServiceError.disconnected))
    }

    func close() {
        lock.withLock { closed = true }
        writeQueue.async { [input] in try? input.close() }
    }
}
