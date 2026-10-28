import Foundation

public struct AgentProjectSnapshot: Sendable {
    public let root: URL
    public var files: [String: Data]
    public let omitted: [String]
    public var texts: [String: String] {
        files.compactMapValues { data in
            guard data.count <= AgentTools.maximumTextBytes, !data.contains(0) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }
}

/// Bounded, coordinated disk access. The live-buffer overlay is supplied by the platform host.
public enum AgentProjectFiles {
    public static func validate(_ path: String) throws {
        let pieces = path.components(separatedBy: "/")
        guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\\"), !path.contains("\0"),
              pieces.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }),
              pieces.first?.caseInsensitiveCompare(DocumentLibrary.metadataName) != .orderedSame,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw AgentToolError("unsafe_path", "Use a project-relative path without hidden components or traversal.")
        }
    }

    public static func url(_ path: String, in root: URL) throws -> URL {
        try validate(path)
        let root = root.standardizedFileURL
        guard root.resolvingSymlinksInPath() == root else {
            throw AgentToolError(
                "unsafe_path",
                "The project root changed.",
            )
        }
        var current = root
        for component in path.components(separatedBy: "/") {
            current.appendPathComponent(component)
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw AgentToolError("unsafe_path", "Symlinks are not editable through agent tools.")
            }
        }
        guard current.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw AgentToolError("unsafe_path", "The path leaves the project.")
        }
        return current
    }

    public static func capture(root: URL, paths: Set<String>? = nil) throws -> AgentProjectSnapshot {
        if let paths {
            return try capturePaths(paths, root: root)
        }
        return try CoordinatedFileAccess.read(root) { directory in
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles],
            ) else {
                throw AgentToolError("unavailable", "Cannot enumerate the project.")
            }
            var files: [String: Data] = [:], omitted: [String] = [], size = 0, count = 0
            for case let file as URL in enumerator {
                let path = String(file.path.dropFirst(directory.path.count + 1))
                if path.caseInsensitiveCompare(DocumentLibrary.metadataName) == .orderedSame {
                    continue
                }
                count += 1
                guard count <= 2000 else {
                    throw AgentToolError(
                        "project_too_large",
                        "Agent access is limited to 2000 project entries.",
                    )
                }
                let values = try file.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    omitted.append(path)
                    continue
                }
                if values.isDirectory == true {
                    continue
                }
                guard values.isRegularFile == true else {
                    omitted.append(path)
                    continue
                }
                _ = try url(path, in: directory)
                if LibraryCloudEnvironment.state(of: file) == .waitingForDownload {
                    omitted.append(path)
                    continue
                }
                guard let bytes = values.fileSize, bytes <= 16 * 1024 * 1024, size + bytes <= 64 * 1024 * 1024 else {
                    throw AgentToolError(
                        "project_too_large",
                        "Agent access is limited to 16 MiB per asset and 64 MiB per project.",
                    )
                }
                let data = try Data(contentsOf: file)
                guard data.count <= 16 * 1024 * 1024, size + data.count <= 64 * 1024 * 1024 else {
                    throw AgentToolError("project_too_large", "The project exceeded the read budget.")
                }
                size += data.count
                files[path] = data
            }
            return AgentProjectSnapshot(root: directory, files: files, omitted: omitted.sorted())
        }
    }

    /// Single-file reads and edit rechecks do not need to reread every project resource.
    private static func capturePaths(_ paths: Set<String>, root: URL) throws -> AgentProjectSnapshot {
        try CoordinatedFileAccess.read(root) { directory in
            var files: [String: Data] = [:], omitted: [String] = [], size = 0
            for path in paths.sorted() {
                let file = try url(path, in: directory)
                let values: URLResourceValues
                do {
                    values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                    [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
                {
                    continue
                }
                guard values.isRegularFile == true,
                      LibraryCloudEnvironment.state(of: file) != .waitingForDownload
                else {
                    omitted.append(path)
                    continue
                }
                guard let bytes = values.fileSize, bytes <= 16 * 1024 * 1024,
                      size + bytes <= 64 * 1024 * 1024
                else {
                    throw AgentToolError(
                        "project_too_large",
                        "Agent access is limited to 16 MiB per file and 64 MiB per read.",
                    )
                }
                let data = try Data(contentsOf: file)
                guard data.count <= 16 * 1024 * 1024, size + data.count <= 64 * 1024 * 1024 else {
                    throw AgentToolError("project_too_large", "The files exceeded the read budget.")
                }
                files[path] = data
                size += data.count
            }
            return AgentProjectSnapshot(root: directory, files: files, omitted: omitted)
        }
    }

    public static func write(_ text: String?, path: String, root: URL, expected: Data?) throws {
        try PackageSource.requireWritable(url(path, in: root))
        try CoordinatedFileAccess.write(root) { directory in
            let destination = try url(path, in: directory)
            try PackageSource.requireWritable(destination)
            let existing: Data?
            if FileManager.default.fileExists(atPath: destination.path) {
                let values = try destination.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else {
                    throw AgentToolError(
                        "unsafe_path",
                        "The target is not a regular file.",
                    )
                }
                try LibraryCloudEnvironment.requestDownloadIfNeeded(destination)
                existing = try Data(contentsOf: destination)
            } else {
                existing = nil
            }
            guard existing == expected else {
                throw AgentToolError(
                    "revision_conflict",
                    "The file changed on disk; read it again.",
                )
            }
            guard LibraryCloudEnvironment.state(of: destination) != .conflict
            else {
                throw LibraryError.unresolvedConflict
            }
            if let text {
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                )
                _ = try url(path, in: directory)
                try Data(text.utf8).write(to: destination, options: .atomic)
            } else {
                try FileManager.default.removeItem(at: destination)
            }
        }
    }

    public static func matches(_ path: String, glob: String) throws -> Bool {
        guard glob.utf8.count <= 1024 else {
            throw AgentToolError("invalid_params", "Glob is too long.")
        }
        let characters = Array(glob)
        var expression = "^", index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                if index < characters.count, characters[index] == "/" {
                    expression += "(?:.*/)?"
                    index += 1
                } else {
                    expression += ".*"
                }
                continue
            }
            if character == "*" {
                expression += "[^/]*"
            } else if character == "?" {
                expression += "[^/]"
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        expression += "$"
        return try NSRegularExpression(pattern: expression).firstMatch(
            in: path,
            range: NSRange(location: 0, length: path.utf16.count),
        ) != nil
    }
}
