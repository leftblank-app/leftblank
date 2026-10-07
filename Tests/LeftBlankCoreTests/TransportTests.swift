import Foundation
@testable import LeftBlankCore
import LeftBlankTestSupport
import Testing

@MainActor
@Test func stalledPipeDoesNotBlockInputAndPreservesMessageOrder() async throws {
    let pipe = Pipe()
    let received = TransportResults()
    let writer = try JSONRPCWriter(handle: pipe.fileHandleForWriting) { error in received.append(.failure(error)) }
    let reader = JSONRPCReader { received.append($0) }
    defer { writer.close()
        pipe.fileHandleForReading.readabilityHandler = nil
    }
    // Larger than the kernel pipe buffer. With no reader the worker blocks,
    // but enqueueing and the main actor remain available for input events.
    let source = String(repeating: "中文😀", count: 100_000)
    let start = ContinuousClock.now
    try writer.send(JSONValue(foundation: ["method": "change", "params": ["text": source, "version": 7, "flag": true]]))
    try writer.send(JSONValue(foundation: ["method": "tokens", "id": 8]))
    let enqueue = start.duration(to: .now)
    try await Task.sleep(for: .milliseconds(30))
    #expect(enqueue < .milliseconds(200), "Enqueue must not perform JSON encoding or wait for pipe capacity")
    #expect(received.values.isEmpty)
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if !data.isEmpty {
            reader.append(data)
        }
    }
    let deadline = ContinuousClock.now + .seconds(5)
    while deadline > .now, received.values.count < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    let values = received.values
    #expect(values.count == 2)
    let messages = try values.map { try $0.get() }
    #expect(messages.first?["params"]["text"].string == source)
    #expect(messages.first?["params"]["version"].int == 7)
    if case let .bool(flag) = messages.first?["params"]["flag"] {
        #expect(flag)
    } else {
        Issue.record("Boolean parameters must retain their type")
    }
    #expect(messages.last?["method"].string == "tokens")
    #expect(messages.last?["id"].int == 8)
    writer.close()
    #expect(throws: ServiceError.self) { try writer.send(.null) }
    print("LEFTBLANK TRANSPORT: enqueue 1 MB while pipe stalled: \(enqueue)")
}

@Test func transportRejectsUnboundedSnapshotsAndInvalidFrames() async throws {
    let pipe = Pipe()
    let results = TransportResults()
    let writer = try JSONRPCWriter(handle: pipe.fileHandleForWriting) { error in results.append(.failure(error)) }
    defer { writer.close() }
    #expect(throws: ServiceError.self) { try writer.send(.string(String(repeating: "x", count: 64 * 1024 * 1024))) }
    #expect(throws: EncodingError.self) { try JSONValue(foundation: URL(fileURLWithPath: "/unsupported")) }
    let reader = JSONRPCReader { results.append($0) }
    reader.append(Data("Content-Length: broken\r\n\r\n".utf8))
    let deadline = ContinuousClock.now + .seconds(2)
    while deadline > .now, results.values.count < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(results.values.count == 2)
    #expect(results.values.allSatisfy {
        if case .failure = $0 {
            return true
        }
        return false
    })
}

@Test func exitedServiceReportsBrokenPipeWithoutTerminatingEditor() async throws {
    let pipe = Pipe()
    let results = TransportResults()
    let writer = try JSONRPCWriter(handle: pipe.fileHandleForWriting) { results.append(.failure($0)) }
    defer { writer.close() }
    try pipe.fileHandleForReading.close()
    try writer.send(JSONValue(foundation: ["method": "change", "params": ["text": "Still writing"]]))
    let deadline = ContinuousClock.now + .seconds(2)
    while results.values.isEmpty, deadline > .now {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(results.values.count == 1)
    #expect(results.values.allSatisfy {
        if case .failure = $0 {
            return true
        }
        return false
    })
    #expect(throws: ServiceError.self) { try writer.send(.null) }
}

@Test func writerOwnsItsDescriptorUntilQueuedWritesFinish() async throws {
    let pipe = Pipe()
    let results = TransportResults()
    let writer = try JSONRPCWriter(handle: pipe.fileHandleForWriting) { results.append(.failure($0)) }
    let reader = JSONRPCReader { results.append($0) }
    defer {
        writer.close()
        pipe.fileHandleForReading.readabilityHandler = nil
    }
    // EmbeddedTinymist closes the transport handle on stop. A queued write
    // must still own a valid handle, even if shutdown won that race.
    try pipe.fileHandleForWriting.close()
    pipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            results.append(.success(.null))
        } else {
            reader.append(data)
        }
    }
    let message = JSONValue.string(String(repeating: "Queued 中文😀", count: 10000))
    try writer.send(message)
    let deadline = ContinuousClock.now + .seconds(5)
    while results.values.isEmpty, deadline > .now {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try results.values.first?.get().string == message.string)
    writer.close()
    // EOF is a second asynchronous operation. A busy executor can resume the
    // message assertion after its deadline; shutdown still needs its own wait.
    let closeDeadline = ContinuousClock.now + .seconds(5)
    while closeDeadline > .now, results.values.count < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(results.values.count == 2)
    if case .null = try results.values.last?.get() {} else {
        Issue.record("Closing the writer must release its descriptor and deliver EOF")
    }
}

private final class TransportResults: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<JSONValue, Error>] = []
    var values: [Result<JSONValue, Error>] {
        lock.withLock { results }
    }

    func append(_ value: Result<JSONValue, Error>) {
        lock.withLock { results.append(value) }
    }
}

#if os(macOS)
    /// A replaced engine that ignores SIGTERM must not keep competing for CPU.
    @MainActor
    @Test func stoppedEngineThatIgnoresTerminationIsKilled() async throws {
        let transport = ProcessTinymistTransport(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; echo ready; exec /bin/sleep 30"],
            killGracePeriod: .seconds(1),
        )
        let ready = TransportResults()
        transport.output.readabilityHandler = { handle in
            if String(decoding: handle.availableData, as: UTF8.self).contains("ready") {
                ready.append(.success(.null))
            }
        }
        defer { transport.output.readabilityHandler = nil }
        try transport.start(root: TestPaths.temporaryDirectory)
        let started = ContinuousClock.now + .seconds(20)
        while ready.values.isEmpty, started > .now {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!ready.values.isEmpty, "The stand-in engine must install its SIGTERM trap first")
        // The trap is installed, so SIGTERM alone cannot end this process.
        transport.stop()
        let deadline = ContinuousClock.now + .seconds(20)
        while transport.isRunning, deadline > .now {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!transport.isRunning, "The engine is killed after the grace period")
    }
#endif
