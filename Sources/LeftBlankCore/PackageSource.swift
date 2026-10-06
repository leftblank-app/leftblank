import Foundation

/// Registry sources are reference material, not editable project documents.
public enum PackageSource {
    public static func isReadOnly(_ url: URL, packageCache: URL? = nil) -> Bool {
        let manager = FileManager.default
        var roots = [
            packageCache ?? AppDistribution.defaultStateDirectory.appendingPathComponent("PackageCache"),
            AppDistribution.defaultStateDirectory.appendingPathComponent("Exports/PackageCache"),
        ]
        for directory in [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory] {
            roots += manager.urls(for: directory, in: .userDomainMask).map {
                $0.appendingPathComponent("typst/packages")
            }
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Packages") {
            roots.append(bundled)
        }
        if let local = ProcessInfo.processInfo.environment["TYPST_PACKAGE_PATH"] {
            roots.append(URL(fileURLWithPath: local))
        }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return roots.contains {
            let root = $0.resolvingSymlinksInPath().standardizedFileURL.path
            let original = $0.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/") ||
                url.standardizedFileURL.path == original || url.standardizedFileURL.path.hasPrefix(original + "/")
        }
    }

    public static func requireWritable(_ url: URL, packageCache: URL? = nil) throws {
        if isReadOnly(url, packageCache: packageCache) {
            throw DocumentStorageError.readOnlyPackage
        }
    }
}
