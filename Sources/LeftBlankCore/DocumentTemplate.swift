import Foundation

public enum DocumentTemplate: String, CaseIterable, Identifiable, Sendable {
    case blank
    case codeNotes
    public var id: String {
        rawValue
    }

    public var title: String {
        L10n.text(self == .blank ? "Blank page" : "Code notes")
    }

    public var source: String {
        let base = "#set text(font: (\"New York\", \"PingFang SC\"), size: 11pt)\n#set page(margin: 24mm)\n\n"
        switch self {
        case .blank: return base
        case .codeNotes:
            return """
            #import "@preview/codly:1.3.0": *
            #import "@preview/codly-languages:0.1.1": *
            #show: codly-init.with()
            #codly(languages: codly-languages, display-icon: false, zebra-fill: none)
            \(base)
            = \(L10n.text("Code notes"))

            \(L10n.text("Write the idea, show the code, explain the result."))

            ```python
            total = sum(range(1, 11))
            print(total)
            ```

            """
        }
    }
}

/// Curated packages ship with the app. Their explicit versioned imports remain
/// ordinary Typst, so exported sources work without any LeftBlank-only preprocessor.
public enum BundledPackages {
    public static func prepare(in cache: URL, resources: URL? = nil) throws {
        var source = resources ?? Bundle.main.resourceURL?.appendingPathComponent("Packages")
        #if DEBUG
            if source.map({ !FileManager.default.fileExists(atPath: $0.path) }) ?? true {
                source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().appendingPathComponent("Resources/Packages")
            }
        #endif
        guard let source, FileManager.default.fileExists(atPath: source.path) else {
            return
        }
        let manager = FileManager.default
        for (name, version) in [
            ("codly", "1.3.0"),
            ("codly-languages", "0.1.1"),
            ("cetz", "0.5.2"),
            ("oxifmt", "1.0.0"),
        ] {
            let path = "preview/\(name)/\(version)"
            let destination = cache.appendingPathComponent(path)
            let bundled = source.appendingPathComponent(path)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Serialize validation and replacement across windows/processes.
            try CoordinatedFileAccess.write(destination) { destination in
                guard !manager.contentsEqual(atPath: bundled.path, andPath: destination.path) else {
                    return
                }
                let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
                defer { try? manager.removeItem(at: staging) }
                try manager.copyItem(at: bundled, to: staging)
                var backup: URL?
                if manager.fileExists(atPath: destination.path) {
                    let saved = cache.deletingLastPathComponent()
                        .appendingPathComponent("PackageBackups/\(UUID().uuidString)/\(path)")
                    try manager.createDirectory(
                        at: saved.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                    )
                    try manager.moveItem(at: destination, to: saved)
                    backup = saved
                }
                do { try manager.moveItem(at: staging, to: destination) }
                catch {
                    if let backup {
                        try? manager.moveItem(at: backup, to: destination)
                    }
                    throw error
                }
            }
        }
    }
}
