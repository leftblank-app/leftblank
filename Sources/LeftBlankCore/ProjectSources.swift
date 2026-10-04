import Foundation

/// Local Typst sources which can be edited without leaving a project's directory.
public enum ProjectSources {
    public static func relativePath(of source: URL, in root: URL) throws -> String {
        let directory = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = source.standardizedFileURL.resolvingSymlinksInPath()
        guard file.isFileURL, file.path.hasPrefix(directory.path + "/"),
              file.pathExtension.lowercased() == "typ",
              try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else {
            throw LibraryError.invalidProject
        }
        return String(file.path.dropFirst(directory.path.count + 1))
    }

    public static func list(in root: URL) throws -> [URL] {
        let directory = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
        ) else {
            throw LibraryError.invalidProject
        }
        var sources: [URL] = []
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                files.skipDescendants()
                continue
            }
            if values.isRegularFile == true, file.pathExtension.lowercased() == "typ" {
                _ = try relativePath(of: file, in: directory)
                sources.append(file)
            }
        }
        return sources.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public static func historyKey(documentID: UUID, source: URL, entry: URL, root: URL) throws -> String {
        let path = try relativePath(of: source, in: root)
        // Keep existing entry-document history available after enabling project editing.
        return source.resolvingSymlinksInPath() == entry.resolvingSymlinksInPath()
            ? documentID.uuidString : documentID.uuidString + "/" + path
    }
}
