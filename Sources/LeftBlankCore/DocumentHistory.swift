import CryptoKit
import Foundation

public enum HistoryInterval: String, CaseIterable, Sendable {
    case hourly
    case daily
    public var duration: TimeInterval {
        self == .hourly ? 3600 : 86400
    }
}

public struct DocumentRevision: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let bytes: Int
    public let digest: String
    public let reason: Reason
    public enum Reason: String, Codable, Sendable {
        case automatic
        case beforeRestore = "beforeRestore"
        case beforeAgentEdit = "beforeAgentEdit"
    }
}

/// Source history is intentionally local and separate from document autosave and
/// iCloud. All encoding, hashing and I/O occurs on this actor, never the editor.
public actor DocumentHistory {
    private let root: URL
    public static let retention = 7

    public init(root: URL) {
        self.root = root
    }

    public func revisions(for key: String) throws -> [DocumentRevision] {
        let index = directory(for: key).appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: index.path) else {
            return []
        }
        return try JSONDecoder().decode([DocumentRevision].self, from: Data(contentsOf: index))
    }

    /// Called only for an edited batch. Preserve its pre-edit contents on the
    /// first edit, then at most once per interval. Opening and idle ticks never
    /// enter this path. Comparing on the actor also ignores edit-then-undo batches.
    @discardableResult
    public func recordEdit(
        key: String,
        previous: String,
        current: String,
        at date: Date,
        interval: HistoryInterval,
    ) throws -> DocumentRevision? {
        guard previous != current else {
            return nil
        }
        let entries = try revisions(for: key)
        if let newest = entries.first, date.timeIntervalSince(newest.createdAt) < interval.duration {
            return nil
        }
        return try append(previous, key: key, at: date, reason: .automatic, entries: entries)
    }

    /// Must succeed before restoration changes the live source. A duplicate is
    /// already safely preserved, so no redundant revision needs to be written.
    @discardableResult
    public func preserveBeforeRestore(_ source: String, key: String, at date: Date) throws -> DocumentRevision {
        let entries = try revisions(for: key)
        return try append(source, key: key, at: date, reason: .beforeRestore, entries: entries)
    }

    /// Agent preimages bypass the automatic interval, including for non-Typst UTF-8 project files.
    @discardableResult
    public func preserveBeforeAgentEdit(_ source: String, key: String, at date: Date) throws -> DocumentRevision {
        try append(source, key: key, at: date, reason: .beforeAgentEdit, entries: revisions(for: key))
    }

    public func source(for revision: DocumentRevision, key: String) throws -> String {
        // Only indexed revisions are readable; callers cannot supply arbitrary files.
        guard try revisions(for: key).contains(revision) else {
            throw HistoryError.unavailable
        }
        let data = try Data(contentsOf: directory(for: key).appendingPathComponent("\(revision.id).typ"))
        guard Self.digest(data) == revision.digest, let source = String(data: data, encoding: .utf8) else {
            throw HistoryError.damaged
        }
        return source
    }

    private func append(
        _ source: String,
        key: String,
        at date: Date,
        reason: DocumentRevision.Reason,
        entries: [DocumentRevision],
    ) throws -> DocumentRevision {
        let data = Data(source.utf8)
        let digest = Self.digest(data)
        // A matching index is insufficient: the payload may have been removed
        // or damaged. Restore is safe only when the retained bytes are readable.
        if let newest = entries.first, newest.digest == digest,
           (try? self.source(for: newest, key: key)) == source
        {
            return newest
        }
        let revision = DocumentRevision(id: UUID(), createdAt: date, bytes: data.count, digest: digest, reason: reason)
        let directory = directory(for: key)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = directory.appendingPathComponent("\(revision.id).typ")
        try data.write(to: payload, options: .atomic)
        let retained = Array(([revision] + entries).prefix(Self.retention))
        do { try JSONEncoder().encode(retained).write(
            to: directory.appendingPathComponent("index.json"),
            options: .atomic,
        ) } catch { try? FileManager.default.removeItem(at: payload)
            throw error
        }
        // Publish the index first. A crash during cleanup can only leave an orphan,
        // never an index pointing at a deleted revision. Clean orphans next write.
        let keep = Set(retained.map { "\($0.id).typ" } + ["index.json"])
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where !keep.contains(file.lastPathComponent) && file.pathExtension == "typ"
        {
            try FileManager.default.removeItem(at: file)
        }
        return revision
    }

    private func directory(for key: String) -> URL {
        root.appendingPathComponent(
            Self.digest(Data(key.utf8)),
            isDirectory: true,
        )
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }
            .joined()
    }
}

public enum HistoryError: Error, LocalizedError, Sendable {
    case unavailable
    case damaged
    case changed
    public var errorDescription: String? {
        switch self {
        case .unavailable: L10n.text("This snapshot is no longer available.")
        case .damaged: L10n.text("This snapshot could not be verified. Your current writing is unchanged.")
        case .changed: L10n.text("The document changed while history was loading. Please try again.")
        }
    }
}

/// Bounded, linear-space comparison. Trim identical prefix/suffix and show the
/// changed span with context. It deliberately avoids quadratic line-diff work
/// on whole books and clearly reports when output is abbreviated.
public struct HistoryComparison: Sendable {
    public let before: String
    public let after: String
    public let identical: Bool
    public let abbreviated: Bool
    public let firstLine: Int
    public let removedRanges: [NSRange]
    public let addedRanges: [NSRange]

    public init(before: String, after: String, limit: Int = 24000) {
        identical = before == after
        guard !identical else {
            self.before = ""
            self.after = ""
            abbreviated = false
            firstLine = 1
            removedRanges = []
            addedRanges = []
            return
        }
        let old = before.split(separator: "\n", omittingEmptySubsequences: false)
        let new = after.split(separator: "\n", omittingEmptySubsequences: false)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1]
        {
            suffix += 1
        }
        let start = max(0, prefix - 2)
        firstLine = start + 1
        func excerpt(_ lines: [Substring]) -> (String, Bool) {
            let end = min(lines.count, lines.count - suffix + 2)
            var result = "", truncated = false, byteCount = 0
            for line in lines[start ..< max(start, end)] {
                let remaining = max(0, limit - byteCount)
                // Limit by Unicode scalars, preserving valid Unicode in the UI.
                if line.utf8.count + 1 > remaining {
                    result += String(line.unicodeScalars.prefix(remaining / 4))
                    truncated = true
                    break
                }
                result += line + "\n"
                byteCount += line.utf8.count + 1
            }
            return (result, truncated || start > 0 || end < lines.count)
        }
        let left = excerpt(old), right = excerpt(new)
        self.before = left.0
        self.after = right.0
        let highlights = HistoryHighlights(before: left.0, after: right.0)
        removedRanges = highlights.removed
        addedRanges = highlights.added
        abbreviated = left.1 || right.1
    }
}
