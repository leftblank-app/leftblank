import Foundation

/// Localized starter content is chosen only when a document is created.
/// Existing manuscripts are never retranslated when the interface changes.
public enum WelcomeDocument {
    public static func source(language: AppLanguage? = nil) -> String {
        let suffix = AppLanguage.resolve(language ?? L10n.language) == .simplifiedChinese ? ".zh-Hans" : ""
        guard let url = CoreResources.bundle.url(forResource: "Welcome" + suffix, withExtension: "typ"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else {
            return DocumentTemplate.blank.source
        }
        return source
    }

    public static var thumbnailURL: URL? {
        thumbnailURL(language: L10n.language)
    }

    public static func thumbnailURL(language: AppLanguage) -> URL? {
        let suffix = AppLanguage.resolve(language) == .simplifiedChinese ? ".zh-Hans" : ""
        return CoreResources.bundle.url(forResource: "welcome-cover" + suffix, withExtension: "png")
    }

    public static let markFilename = "leftblank-mark.svg"

    public static func assets() throws -> [String: Data] {
        guard let url = CoreResources.bundle.url(forResource: "leftblank-mark", withExtension: "svg") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try [markFilename: Data(contentsOf: url)]
    }

    /// First-launch drafts and exported project copies use an ordinary relative asset.
    /// An existing author-edited mark always wins over the bundled original.
    public static func prepareAssets(in directory: URL) throws {
        for (name, data) in try assets() {
            let destination = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try data.write(to: destination, options: .withoutOverwriting)
            }
        }
    }
}
