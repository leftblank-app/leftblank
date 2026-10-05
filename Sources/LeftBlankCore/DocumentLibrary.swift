import CryptoKit
import Foundation

public struct LibraryDocument: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let createdAt: Date
    public let modifiedAt: Date
    public let trashedAt: Date?
    public let sourceURL: URL
    public let folderURL: URL
    public let snippet: String
    public let hasUnresolvedConflicts: Bool
    public let metadataRevision: String
    public var isTrashed: Bool {
        trashedAt != nil
    }
}

public struct LibraryReadResult: Sendable {
    public let document: LibraryDocument
    public let text: String
    public let baseline: DiskBaseline
}

public struct LibraryIssue: Sendable {
    public let folderURL: URL
    public let message: String
}

/// Captures the exact trash contents the user confirmed, independent of search.
public struct LibraryTrashSnapshot: Sendable {
    let rootURL: URL
    let entries: [UUID: Date]
    public var count: Int {
        entries.count
    }

    public var isEmpty: Bool {
        entries.isEmpty
    }
}

public struct LibraryEmptyTrashResult: Sendable {
    public let deletedCount: Int
    public let issues: [LibraryIssue]
}

public enum LibraryError: LocalizedError {
    case notFound
    case invalidTitle
    case invalidMetadata
    case invalidProject
    case unsafeResource
    case destinationExists
    case libraryChanged
    case downloadPending
    case unresolvedConflict
    case cloudNotConfigured
    case cloudAccountUnavailable
    case cloudUnavailable
    public var errorDescription: String? {
        switch self {
        case .notFound: L10n.text("This document is no longer available in the library.")
        case .libraryChanged: L10n.text("The library location changed. Open Trash and try again.")
        case .invalidTitle: L10n.text("Use a document title between 1 and 200 characters.")
        case .invalidMetadata: L10n
            .text("This document's library metadata could not be read. Its files have been preserved.")
        case .invalidProject: L10n.text("Choose a project folder containing the selected Typst source file.")
        case .unsafeResource: L10n
            .text(
                "The project contains a symbolic link or unsupported file. Copy the required resources into the project first.",
            )
        case .destinationExists: L10n
            .text("The export destination already exists. Choose a different name to preserve both copies.")
        case .downloadPending: L10n.text("This document is downloading from iCloud. Try opening it again in a moment.")
        case .unresolvedConflict: L10n
            .text(
                "iCloud has conflicting versions of this document. Your changes are preserved; resolve the versions before overwriting it.",
            )
        case .cloudNotConfigured: L10n
            .text("This build is not provisioned for iCloud. Your documents remain available locally.")
        case .cloudAccountUnavailable: L10n
            .text("Sign in to iCloud and enable iCloud Drive in System Settings before turning on sync.")
        case .cloudUnavailable: L10n
            .text("The iCloud container is unavailable. Your current library has not been changed.")
        }
    }
}

public struct LibrarySyncReport: Sendable {
    public let rootURL: URL
    public let isICloud: Bool
    public let copiedCount: Int
    public let conflictCopies: Int
    public let idMappings: [UUID: UUID]
}

/// One stable folder per document preserves the base URL of relative Typst resources.
/// Operations run off the main actor; external editor saves may use DocumentStorage directly.
public actor DocumentLibrary {
    public typealias CloudResolver = @Sendable () throws -> URL
    public let localRootURL: URL
    public private(set) var rootURL: URL
    public private(set) var isICloud = false
    public private(set) var issues: [LibraryIssue] = []
    private let cloudResolver: CloudResolver
    private let now: @Sendable () -> Date
    private let manager = FileManager.default

    public init(
        rootURL: URL,
        cloudResolver: @escaping CloudResolver = { try LibraryCloudEnvironment.containerURL() },
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        localRootURL = rootURL.standardizedFileURL
        self.rootURL = rootURL.standardizedFileURL
        self.cloudResolver = cloudResolver
        self.now = now
    }

    public func list(
        query: String = "",
        includeTrashed: Bool = false,
        allowedDocumentIDs: Set<UUID>? = nil,
    ) throws -> [LibraryDocument] {
        try prepareRoot(rootURL)
        issues = []
        let words = normalized(query).split(whereSeparator: \.isWhitespace)
        var documents: [LibraryDocument] = []
        for folder in try documentFolders(in: rootURL) {
            do {
                let metadata = try readMetadata(folder)
                if let allowedDocumentIDs, !allowedDocumentIDs.contains(metadata.id) {
                    continue
                }
                if !includeTrashed, metadata.trashedAt != nil {
                    continue
                }
                let document = try describe(metadata, folder: folder)
                if !words.isEmpty {
                    let source = LibraryCloudEnvironment
                        .state(of: document.sourceURL) == .waitingForDownload ? "" :
                        ((try? DocumentStorage.read(document.sourceURL).0) ?? "")
                    let searchable = normalized(document.title + " " + source)
                    guard words.allSatisfy({ searchable.contains($0) }) else {
                        continue
                    }
                }
                documents.append(document)
            } catch { issues.append(LibraryIssue(folderURL: folder, message: error.localizedDescription)) }
        }
        return documents
            .sorted {
                $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt > $1.modifiedAt
            }
    }

    public func create(title: String = "", text: String = "", assets: [String: Data] = [:]) throws -> LibraryDocument {
        let title = title.isEmpty ? L10n.text("Untitled") : try validatedTitle(title)
        guard assets.keys
            .allSatisfy({
                !$0.contains("/") && !$0.contains("\\") && !$0
                    .isEmpty && $0 != "." && $0 != ".." && $0 != "main.typ" && $0 != Self.metadataName })
        else {
            throw LibraryError.unsafeResource
        }
        return try createDocument(title: title) { source in
            try Data(text.utf8).write(to: source, options: .atomic)
            for (name, data) in assets {
                try data.write(to: source.deletingLastPathComponent().appendingPathComponent(name), options: .atomic)
            }
        }
    }

    public func read(_ id: UUID) throws -> LibraryReadResult {
        let folder = try folder(for: id)
        let metadata = try readMetadata(folder)
        let sourceURL = try sourceURL(metadata, in: folder)
        if isICloud, (try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            try manager.startDownloadingUbiquitousItem(at: folder)
        }
        try LibraryCloudEnvironment.requestDownloadIfNeeded(sourceURL)
        let (text, baseline) = try DocumentStorage.read(sourceURL)
        return try LibraryReadResult(
            document: describe(metadata, folder: folder, text: text),
            text: text,
            baseline: baseline,
        )
    }

    public func save(_ id: UUID, text: String, baseline: DiskBaseline?) throws -> LibraryReadResult {
        let folder = try folder(for: id)
        let metadata = try readMetadata(folder)
        let source = try sourceURL(metadata, in: folder)
        let baseline = try DocumentStorage.write(text, to: source, baseline: baseline)
        return try LibraryReadResult(
            document: describe(metadata, folder: folder, text: text),
            text: text,
            baseline: baseline,
        )
    }

    public func rename(_ id: UUID, title: String, expectedMetadataRevision: String? = nil) throws -> LibraryDocument {
        let title = try validatedTitle(title)
        return try updateMetadata(id, expectedRevision: expectedMetadataRevision) { $0.title = title
            $0.modifiedAt = now()
        }
    }

    public func trash(_ id: UUID, expectedMetadataRevision: String? = nil) throws -> LibraryDocument {
        try updateMetadata(id, expectedRevision: expectedMetadataRevision) {
            if $0.trashedAt == nil {
                $0.trashedAt = now()
                $0.modifiedAt = now()
            }
        }
    }

    public func restore(_ id: UUID, expectedMetadataRevision: String? = nil) throws -> LibraryDocument {
        try updateMetadata(id, expectedRevision: expectedMetadataRevision) { $0.trashedAt = nil
            $0.modifiedAt = now()
        }
    }

    public func trashSnapshot() throws -> LibraryTrashSnapshot {
        let entries = try list(includeTrashed: true).compactMap { document in
            document.trashedAt.map { (document.id, $0) }
        }
        return LibraryTrashSnapshot(rootURL: rootURL, entries: Dictionary(uniqueKeysWithValues: entries))
    }

    /// Permanent deletion is limited to the confirmed trash generation. A restore,
    /// re-trash, or library migration while the confirmation is open is preserved.
    public func emptyTrash(_ snapshot: LibraryTrashSnapshot) throws -> LibraryEmptyTrashResult {
        guard snapshot.rootURL == rootURL else {
            throw LibraryError.libraryChanged
        }
        var deleted = 0, failures: [LibraryIssue] = []
        for (id, trashedAt) in snapshot.entries {
            let candidate = rootURL.appendingPathComponent("Documents/" + id.uuidString)
            guard manager.fileExists(atPath: candidate.path) else {
                continue
            }
            do {
                let folder = try folder(for: id)
                let removed = try CoordinatedFileAccess.write(folder, options: .forDeleting) { coordinated in
                    let metadata = try decodeMetadata(
                        coordinated.appendingPathComponent(Self.metadataName),
                        in: coordinated,
                    )
                    guard metadata.trashedAt == trashedAt else {
                        return false
                    }
                    if (try? coordinated.appendingPathComponent(Self.metadataName)
                        .resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey])
                        .ubiquitousItemHasUnresolvedConflicts) == true
                    {
                        throw LibraryError.unresolvedConflict
                    }
                    try manager.removeItem(at: coordinated)
                    return true
                }
                if removed {
                    deleted += 1
                }
            } catch { failures.append(LibraryIssue(folderURL: candidate, message: error.localizedDescription)) }
        }
        return LibraryEmptyTrashResult(deletedCount: deleted, issues: failures)
    }

    /// Imports one source file; use importProject when it has relative resource dependencies.
    public func importDocument(at url: URL, title: String? = nil) throws -> LibraryDocument {
        let (text, _) = try DocumentStorage.read(url)
        return try create(title: title ?? url.deletingPathExtension().lastPathComponent, text: text)
    }

    /// Copies only the explicitly selected project directory; never follows symbolic links.
    public func importProject(at directory: URL, mainFile: URL, title: String? = nil) throws -> LibraryDocument {
        let directory = directory.standardizedFileURL
        let mainFile = mainFile.standardizedFileURL
        guard mainFile.path.hasPrefix(directory.path + "/"),
              mainFile.pathExtension.lowercased() == "typ"
        else {
            throw LibraryError.invalidProject
        }
        let relative = String(mainFile.path.dropFirst(directory.path.count + 1))
        _ = try DocumentStorage.read(mainFile)
        let title = try validatedTitle(title ?? mainFile.deletingPathExtension().lastPathComponent)
        return try createDocument(title: title, sourcePath: "Project/" + relative) { target in
            let project = target.deletingLastPathComponent()
            // The initializer's staging folder is derived from the validated relative path.
            var projectRoot = project
            for _ in relative.split(separator: "/").dropLast() {
                projectRoot.deleteLastPathComponent()
            }
            try CoordinatedFileAccess.read(directory) { source in
                try validateTree(source)
                if manager.fileExists(atPath: projectRoot.path) {
                    try manager.removeItem(at: projectRoot)
                }
                try manager.copyItem(at: source, to: projectRoot)
            }
        }
    }

    public func exportSource(_ id: UUID, to destination: URL) throws {
        let document = try read(id)
        try CoordinatedFileAccess.write(destination) { target in
            guard !manager.fileExists(atPath: target.path) else {
                throw LibraryError.destinationExists
            }
            try Data(document.text.utf8).write(to: target, options: .atomic)
        }
    }

    /// Exports a self-contained project directory, preserving its relative resource paths.
    public func exportProject(_ id: UUID, to destination: URL) throws {
        let folder = try folder(for: id)
        let metadata = try readMetadata(folder)
        try CoordinatedFileAccess.read(folder) { sourceFolder in
            try CoordinatedFileAccess.write(destination) { target in
                guard !manager.fileExists(atPath: target.path) else {
                    throw LibraryError.destinationExists
                }
                try validateTree(sourceFolder)
                let staging = target.deletingLastPathComponent()
                    .appendingPathComponent(".leftblank-export-" + UUID().uuidString)
                defer { try? manager.removeItem(at: staging) }
                try manager.copyItem(at: sourceFolder, to: staging)
                try manager.removeItem(at: staging.appendingPathComponent(Self.metadataName))
                // This file identifies the entry point without exposing internal UUID metadata.
                let readme = "Open \(metadata.sourcePath) as the main Typst document.\n"
                let hint = staging.appendingPathComponent("LEFTBLANK-ENTRYPOINT.txt")
                if !manager.fileExists(atPath: hint.path) {
                    try Data(readme.utf8).write(to: hint)
                }
                try manager.moveItem(at: staging, to: target)
            }
        }
    }

    /// Managed entries share a compilation root so standard Typst paths can reference other documents.
    public func compilationRoot(for sourceURL: URL) throws -> URL {
        try documentID(for: sourceURL) == nil ? sourceURL.deletingLastPathComponent() :
            rootURL.appendingPathComponent("Documents", isDirectory: true)
    }

    public func documentID(for sourceURL: URL) throws -> UUID? {
        let source = sourceURL.standardizedFileURL
        let documentsRoot = rootURL.appendingPathComponent("Documents").standardizedFileURL
        guard source.path.hasPrefix(documentsRoot.path + "/") else {
            return nil
        }
        let relative = source.path.dropFirst(documentsRoot.path.count + 1)
        guard let first = relative.split(separator: "/").first,
              let id = UUID(uuidString: String(first))
        else {
            return nil
        }
        let metadata = try readMetadata(folder(for: id))
        return try self.sourceURL(metadata, in: folder(for: id)).standardizedFileURL == source ? id : nil
    }

    /// Restores a previously chosen location without re-importing stale local backups.
    public func resumeICloud() throws -> URL {
        let root = try cloudResolver().appendingPathComponent("Documents/LeftBlankLibrary", isDirectory: true)
        try prepareRoot(root)
        rootURL = root
        isICloud = true
        return root
    }

    /// Migration never replaces a different document at the destination or deletes originals.
    public func setICloudEnabled(_ enabled: Bool) throws -> LibrarySyncReport {
        if enabled == isICloud {
            return LibrarySyncReport(
                rootURL: rootURL,
                isICloud: isICloud,
                copiedCount: 0,
                conflictCopies: 0,
                idMappings: [:],
            )
        }
        let destination = enabled ? try cloudResolver().appendingPathComponent(
            "Documents/LeftBlankLibrary",
            isDirectory: true,
        ) : localRootURL
        try prepareRoot(rootURL)
        try prepareRoot(destination)
        let result = try copyLibrary(from: rootURL, to: destination)
        rootURL = destination
        isICloud = enabled
        return LibrarySyncReport(
            rootURL: rootURL,
            isICloud: enabled,
            copiedCount: result.copied,
            conflictCopies: result.conflicts,
            idMappings: result.mapping,
        )
    }

    private static let metadataName = "document.json"
    private struct Metadata: Codable {
        var schema = 1
        var id: UUID
        var title: String
        var createdAt: Date
        var modifiedAt: Date
        var trashedAt: Date?
        var sourcePath: String
        var originID: UUID?
        var originFingerprint: String?
    }

    private func prepareRoot(_ root: URL) throws {
        try manager.createDirectory(at: root.appendingPathComponent("Documents"), withIntermediateDirectories: true)
    }

    private func folder(for id: UUID) throws -> URL {
        let folder = rootURL.appendingPathComponent("Documents/" + id.uuidString, isDirectory: true)
        guard manager.fileExists(atPath: folder.path) else {
            throw LibraryError.notFound
        }
        let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true,
              properties.isSymbolicLink != true
        else {
            throw LibraryError.unsafeResource
        }
        return folder
    }

    private func documentFolders(in root: URL) throws -> [URL] {
        try manager.contentsOfDirectory(
            at: root.appendingPathComponent("Documents"),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles],
        )
        .filter { UUID(uuidString: $0.lastPathComponent) != nil }
    }

    private func readMetadata(_ folder: URL) throws -> Metadata {
        let metadataURL = folder.appendingPathComponent(Self.metadataName)
        let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true,
              (try? metadataURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else {
            throw LibraryError.unsafeResource
        }
        try LibraryCloudEnvironment.requestDownloadIfNeeded(metadataURL)
        return try CoordinatedFileAccess.read(metadataURL) { url in
            try decodeMetadata(url, in: folder)
        }
    }

    private func decodeMetadata(_ url: URL, in folder: URL) throws -> Metadata {
        let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else {
            throw LibraryError.unsafeResource
        }
        guard let data = try? Data(contentsOf: url), let metadata = try? JSONDecoder().decode(
            Metadata.self,
            from: data,
        ),
            metadata.schema == 1,
            metadata.id.uuidString == folder.lastPathComponent
        else {
            throw LibraryError.invalidMetadata
        }
        _ = try sourceURL(metadata, in: folder)
        return metadata
    }

    private func sourceURL(_ metadata: Metadata, in folder: URL) throws -> URL {
        let components = metadata.sourcePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !metadata.sourcePath.hasPrefix("/"),
              !metadata.sourcePath.contains("\\")
        else {
            throw LibraryError.invalidMetadata
        }
        let source = folder.appendingPathComponent(metadata.sourcePath)
        guard source.pathExtension.lowercased() == "typ" else {
            throw LibraryError.invalidMetadata
        }
        guard source.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
        else {
            throw LibraryError.unsafeResource
        }
        return source
    }

    private func describe(_ metadata: Metadata, folder: URL, text: String? = nil) throws -> LibraryDocument {
        let source = try sourceURL(metadata, in: folder)
        let values = try? source.resourceValues(forKeys: [
            .contentModificationDateKey,
            .ubiquitousItemHasUnresolvedConflictsKey,
        ])
        let preview: String = if let text {
            text
        } else if LibraryCloudEnvironment.state(of: source) == .waitingForDownload {
            ""
        } else {
            (try? CoordinatedFileAccess.read(source) { url in
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                return try String(decoding: handle.read(upToCount: 4096) ?? Data(), as: UTF8.self)
            }) ?? ""
        }
        // Prefer prose over template imports and typesetting directives in the
        // library. This is a display excerpt, not a parser or a source transform.
        let prose = preview.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter {
                !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") && !$0.hasPrefix("=") && !$0.hasPrefix("```")
            }
            .joined(separator: " ")
        let snippet = String((prose.isEmpty ? preview : prose).split(whereSeparator: \.isWhitespace)
            .joined(separator: " ").prefix(180))
        return try LibraryDocument(
            id: metadata.id,
            title: metadata.title,
            createdAt: metadata.createdAt,
            modifiedAt: max(
                metadata.modifiedAt,
                values?.contentModificationDate ?? metadata.modifiedAt,
            ),
            trashedAt: metadata.trashedAt,
            sourceURL: source,
            folderURL: folder,
            snippet: snippet,
            hasUnresolvedConflicts: values?
                .ubiquitousItemHasUnresolvedConflicts == true ||
                (try? folder.appendingPathComponent(Self.metadataName)
                    .resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey])
                    .ubiquitousItemHasUnresolvedConflicts) == true,
            metadataRevision: metadataRevision(metadata, folder: folder),
        )
    }

    private func metadataRevision(_ metadata: Metadata, folder: URL) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data(folder.standardizedFileURL.path.utf8)
        try data.append(encoder.encode(metadata))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validatedTitle(_ title: String) throws -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 200).contains(value.count),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw LibraryError.invalidTitle
        }
        return value
    }

    private func normalized(_ string: String) -> String {
        string.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"),
        )
    }

    private func updateMetadata(
        _ id: UUID,
        expectedRevision: String? = nil,
        _ update: (inout Metadata) -> Void,
    ) throws -> LibraryDocument {
        let folder = try folder(for: id)
        let metadata = try CoordinatedFileAccess.write(folder.appendingPathComponent(Self.metadataName)) { url in
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ==
                true
            {
                throw LibraryError.unsafeResource
            }
            if (try? url.resourceValues(forKeys: [.ubiquitousItemHasUnresolvedConflictsKey])
                .ubiquitousItemHasUnresolvedConflicts) == true
            {
                throw LibraryError.unresolvedConflict
            }
            guard let data = try? Data(contentsOf: url), var metadata = try? JSONDecoder().decode(
                Metadata.self,
                from: data,
            ), metadata.id == id, metadata.schema == 1 else {
                throw LibraryError.invalidMetadata
            }
            _ = try sourceURL(metadata, in: folder)
            if let expectedRevision, try metadataRevision(metadata, folder: folder) != expectedRevision {
                throw DocumentStorageError.externalChange
            }
            update(&metadata)
            try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
            return metadata
        }
        return try describe(metadata, folder: folder)
    }

    private func createDocument(
        title: String,
        sourcePath: String = "main.typ",
        populate: (URL) throws -> Void,
    ) throws -> LibraryDocument {
        try prepareRoot(rootURL)
        let id = UUID()
        let documents = rootURL.appendingPathComponent("Documents")
        let final = documents.appendingPathComponent(id.uuidString)
        let staging = documents.appendingPathComponent(".pending-" + id.uuidString)
        let metadata = Metadata(id: id, title: title, createdAt: now(), modifiedAt: now(), sourcePath: sourcePath)
        try manager.createDirectory(
            at: staging.appendingPathComponent(sourcePath).deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        defer { try? manager.removeItem(at: staging) }
        try populate(staging.appendingPathComponent(sourcePath))
        try JSONEncoder().encode(metadata).write(
            to: staging.appendingPathComponent(Self.metadataName),
            options: .atomic,
        )
        try CoordinatedFileAccess.write(documents) { _ in try manager.moveItem(at: staging, to: final) }
        return try describe(metadata, folder: final)
    }

    private func validateTree(_ folder: URL) throws {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        let root = try folder.resourceValues(forKeys: keys)
        guard root.isDirectory == true, root.isSymbolicLink != true else {
            throw LibraryError.unsafeResource
        }
        guard let files = manager.enumerator(at: folder, includingPropertiesForKeys: Array(keys))
        else {
            throw LibraryError.invalidProject
        }
        for case let url as URL in files {
            let value = try url.resourceValues(forKeys: keys)
            guard value.isSymbolicLink != true,
                  value.isRegularFile == true || value.isDirectory == true
            else {
                throw LibraryError.unsafeResource
            }
        }
    }

    private func fingerprint(_ folder: URL, includingMetadata: Bool = true) throws -> String {
        try validateTree(folder)
        guard let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw LibraryError.notFound
        }
        let files = enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        var digest = SHA256()
        for file in files {
            if !includingMetadata, file == folder.appendingPathComponent(Self.metadataName) {
                continue
            }
            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            let path = String(file.path.dropFirst(folder.path.count))
            digest
                .update(
                    data: Data(
                        "path:\(path.utf8.count):\(path)\nbytes:\(properties.isRegularFile == true ? properties.fileSize ?? 0 : 0)\n"
                            .utf8,
                    ),
                )
            guard properties.isRegularFile == true else {
                continue
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
                digest.update(data: data)
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func copyLibrary(
        from source: URL,
        to target: URL,
    ) throws -> (copied: Int, conflicts: Int, mapping: [UUID: UUID]) {
        var copied = 0, conflicts = 0
        var mapping: [UUID: UUID] = [:]
        for folder in try documentFolders(in: source) {
            try CoordinatedFileAccess.read(folder) { sourceFolder in
                var metadata = try readMetadata(sourceFolder)
                let originalID = metadata.id
                let destination = target.appendingPathComponent("Documents/" + originalID.uuidString)
                let sourceFingerprint = try fingerprint(sourceFolder)
                var final = destination
                if manager.fileExists(atPath: destination.path) {
                    let identical = try CoordinatedFileAccess
                        .read(destination) { try fingerprint($0) == sourceFingerprint }
                    if identical {
                        return
                    }
                    if let existing = try documentFolders(in: target).first(where: {
                        guard let value = try? readMetadata($0) else {
                            return false
                        }
                        guard value.originID == originalID, value.originFingerprint == sourceFingerprint,
                              let existingContents = try? fingerprint($0, includingMetadata: false),
                              let sourceContents = try? fingerprint(sourceFolder, includingMetadata: false)
                        else {
                            return false
                        }
                        return existingContents == sourceContents
                    }) {
                        mapping[originalID] = UUID(uuidString: existing.lastPathComponent)
                        return
                    }
                    metadata.id = UUID()
                    metadata.originID = originalID
                    metadata.originFingerprint = sourceFingerprint
                    metadata.title += " (" + L10n.text("Preserved copy") + ")"
                    final = target.appendingPathComponent("Documents/" + metadata.id.uuidString)
                    conflicts += 1
                }
                let staging = target.appendingPathComponent("Documents/.pending-" + UUID().uuidString)
                defer { try? manager.removeItem(at: staging) }
                try manager.copyItem(at: sourceFolder, to: staging)
                if metadata.id != originalID {
                    try JSONEncoder().encode(metadata).write(
                        to: staging.appendingPathComponent(Self.metadataName),
                        options: .atomic,
                    )
                }
                try CoordinatedFileAccess.write(target.appendingPathComponent("Documents")) { _ in
                    guard !manager.fileExists(atPath: final.path) else {
                        throw LibraryError.destinationExists
                    }
                    try manager.moveItem(at: staging, to: final)
                }
                mapping[originalID] = metadata.id
                copied += 1
            }
        }
        return (copied, conflicts, mapping)
    }
}
