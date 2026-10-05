import CoreFoundation
import Darwin
import Foundation

extension JSONValue {
    /// Freeze Foundation parameters before crossing the worker-queue boundary.
    /// Strings remain value snapshots; JSON encoding happens off the UI thread.
    init(foundation value: Any) throws {
        switch value {
        case let value as String: self = .string(value)
        case let value as NSNumber:
            self = CFGetTypeID(value) == CFBooleanGetTypeID() ? .bool(value.boolValue) : .number(value.doubleValue)
        case let value as [String: Any]: self = try .object(value.mapValues { try JSONValue(foundation: $0) })
        case let value as [Any]: self = try .array(value.map { try JSONValue(foundation: $0) })
        case is NSNull: self = .null
        default: throw EncodingError.invalidValue(
                value,
                .init(codingPath: [], debugDescription: "Unsupported JSON-RPC parameter"),
            )
        }
    }

    var queuedBytes: Int {
        switch self {
        case let .string(text): text.utf8.count + 32
        case let .array(values): values.reduce(32) { $0 + $1.queuedBytes }
        case let .object(values): values.reduce(32) { $0 + $1.key.utf8.count + $1.value.queuedBytes }
        default: 32
        }
    }
}

/// A slow or stopped language server must never block native key dispatch.
/// FIFO preserves didChange/request ordering. A bounded queue prevents a stalled
/// peer from retaining unlimited document snapshots. The queue owns a duplicate
/// descriptor so transport shutdown cannot close a handle during a write.
/// The lock protects cancellation and accounting, never blocking I/O.
final class JSONRPCWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.leftblank.rpc.write", qos: .userInitiated)
    private let handle: FileHandle
    private let onFailure: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var closed = false
    private var pendingBytes = 0
    private var pendingCount = 0

    init(handle: FileHandle, onFailure: @escaping @Sendable (Error) -> Void) throws {
        let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        // A service can exit between isRunning and the queued write. Keep that
        // broken pipe as an EPIPE error instead of terminating the whole editor.
        if fcntl(descriptor, F_SETNOSIGPIPE, 1) == -1 {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            Darwin.close(descriptor)
            throw error
        }
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.onFailure = onFailure
    }

    func send(_ message: JSONValue) throws {
        let cost = message.queuedBytes
        let accepted = lock.withLock {
            guard !closed, pendingCount < 64, cost <= 64 * 1024 * 1024 - pendingBytes else {
                return false
            }
            pendingBytes += cost
            pendingCount += 1
            return true
        }
        guard accepted else {
            onFailure(ServiceError.disconnected)
            throw ServiceError.disconnected
        }
        queue.async { [self] in
            defer { lock.withLock { pendingBytes -= cost
                pendingCount -= 1
            } }
            guard !lock.withLock({ closed }) else {
                return
            }
            do {
                let payload = try JSONEncoder().encode(message)
                var frame = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
                frame.append(payload)
                try handle.write(contentsOf: frame)
            } catch {
                let report = lock.withLock { let report = !closed
                    closed = true
                    return report
                }
                if report {
                    onFailure(error)
                }
            }
        }
    }

    func close() {
        lock.withLock { closed = true }
        queue.async { [handle] in try? handle.close() }
    }
}

/// Framing and JSON decoding of large token responses also stay off the main
/// actor. The caller checks the service generation before delivering messages.
final class JSONRPCReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.leftblank.rpc.read", qos: .userInitiated)
    private var framer = JSONRPCFramer() // confined to queue
    private let receive: @Sendable (Result<JSONValue, Error>) -> Void

    init(receive: @escaping @Sendable (Result<JSONValue, Error>) -> Void) {
        self.receive = receive
    }

    func append(_ data: Data) {
        queue.async { [self] in
            do {
                for frame in try framer.append(data) {
                    try receive(.success(JSONDecoder().decode(JSONValue.self, from: frame)))
                }
            } catch { receive(.failure(error)) }
        }
    }
}
