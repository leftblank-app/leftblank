import Foundation

/// Small synchronous writes keep the last action available after a process crash.
/// The lock protects the file handle, rotation and sequence number together.
/// Several logs may share a file, such as a relaunched workspace while the
/// previous one still finishes its work, so every record is appended at the
/// file's current end instead of at an offset this instance remembers.
public final class ActionLog: @unchecked Sendable {
    public let fileURL: URL
    private let directory: URL
    private let limit: Int
    private let archives: Int
    private let session = UUID().uuidString
    private let lock = NSLock()
    private var handle: FileHandle?
    private var sequence = 0

    public init(directory: URL, maxBytes: Int = 1_048_576, archivedFiles: Int = 3) throws {
        self.directory = directory
        limit = max(512, maxBytes)
        archives = max(1, archivedFiles)
        fileURL = directory.appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try openFile()
    }

    deinit { try? handle?.close() }

    @discardableResult
    public func record(_ event: String, fields: [String: String] = [:]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            sequence += 1
            let entry: [String: Any] = [
                "time": Date().ISO8601Format(.init(includingFractionalSeconds: true)), "session": session,
                "sequence": sequence, "event": String(event.prefix(80)),
                "fields": fields.mapValues { String($0.prefix(256)) },
            ]
            var data = try JSONSerialization.data(withJSONObject: entry, options: .sortedKeys)
            data.append(0x0A)
            if handle == nil || !handleIsCurrentFile() {
                try? handle?.close()
                try openFile()
            }
            // Another writer may have appended too, so rotate by the file's real size.
            let size = try handle?.seekToEnd() ?? 0
            if size > 0, Int(size) + data.count > limit {
                try rotate()
            }
            try handle?.write(contentsOf: data)
            return true
        } catch {
            // Logging must never interrupt writing or saving a manuscript.
            try? handle?.close()
            handle = nil
            return false
        }
    }

    private func openFile() throws {
        let descriptor = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// Another log sharing the file may have rotated it away from this handle.
    private func handleIsCurrentFile() -> Bool {
        guard let handle else {
            return false
        }
        var opened = stat(), current = stat()
        return fstat(handle.fileDescriptor, &opened) == 0 && stat(fileURL.path, &current) == 0
            && opened.st_ino == current.st_ino && opened.st_dev == current.st_dev
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let files = FileManager.default
        for index in stride(from: archives, through: 1, by: -1) {
            let destination = directory.appendingPathComponent("events.\(index).jsonl")
            let source = index == 1 ? fileURL : directory.appendingPathComponent("events.\(index - 1).jsonl")
            if files.fileExists(atPath: destination.path) {
                try files.removeItem(at: destination)
            }
            if files.fileExists(atPath: source.path) {
                try files.moveItem(at: source, to: destination)
            }
        }
        try openFile()
    }
}
