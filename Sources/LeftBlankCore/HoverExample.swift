import Foundation

/// The cached package that defines a hovered symbol, as the manuscript resolved it.
public struct TypstPackage: Equatable, Hashable, Sendable {
    public let namespace: String
    public let name: String
    public let version: String

    public init(namespace: String, name: String, version: String) {
        self.namespace = namespace
        self.name = name
        self.version = version
    }

    public var specifier: String {
        "@\(namespace)/\(name):\(version)"
    }

    /// Only a definition inside the workspace's own package cache names a package;
    /// its validated path components become the preview's versioned import.
    public static func defining(_ definition: JSONValue, packageCache: URL) -> Self? {
        let destination = definition.array.first ?? definition
        guard let uri = destination["targetUri"].string ?? destination["uri"].string,
              let url = URL(string: uri), url.isFileURL
        else {
            return nil
        }
        let cache = packageCache.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(cache) else {
            return nil
        }
        let parts = path.dropFirst(cache.count).split(separator: "/").map(String.init)
        guard parts.count >= 4,
              parts[0].range(of: #"\A[a-z0-9][a-z0-9-]*\z"#, options: .regularExpression) != nil,
              parts[1].range(of: #"\A[a-z0-9][a-z0-9_-]*\z"#, options: .regularExpression) != nil,
              parts[2].range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil
        else {
            return nil
        }
        return Self(namespace: parts[0], name: parts[1], version: parts[2])
    }
}

public struct HoverExample: Equatable, Hashable, Sendable {
    /// Typst documentation examples are markup; package docs (tidy's ```example, ```typc)
    /// often hold code that Tinymist re-labels as ```typ.
    public enum Mode: String, Hashable, Sendable {
        case markup
        case code
    }

    public let source: String
    public let displaySource: String
    public let image: Data?
    public let imageFormat: String?
    public let mode: Mode
    /// The package whose documentation the example comes from, when the definition proves it.
    public let package: TypstPackage?

    /// Packages whose documentation runs code examples in a fixed context.
    /// Keep this explicit: an unknown package's code runs in a plain code block,
    /// and a snippet that cannot compile there shows only its source.
    static let codeContexts: [String: (open: String, close: String)] = [
        // CeTZ's manual evaluates every example inside a canvas with the draw API in scope.
        "preview/cetz": ("#cetz.canvas({\nimport cetz.draw: *", "})"),
    ]

    public func inPackage(_ package: TypstPackage?) -> Self {
        Self(
            source: source,
            displaySource: displaySource,
            image: image,
            imageFormat: imageFormat,
            mode: mode,
            package: package,
        )
    }

    /// The self-contained preview document either native engine compiles.
    public var previewSource: String {
        var lines = ["#set page(width: 300pt, height: auto, margin: 12pt, fill: white)"]
        if let imageFormat, image != nil {
            lines.append("#image(\"example.\(imageFormat)\", width: 100%)")
            return lines.joined(separator: "\n")
        }
        if let package {
            lines.append("#import \"\(package.specifier)\"")
        }
        switch mode {
        case .markup:
            lines.append(source)
        case .code:
            let context = package.flatMap { Self.codeContexts["\($0.namespace)/\($0.name)"] } ?? ("#{", "}")
            lines += [context.open, source, context.close]
        }
        return lines.joined(separator: "\n")
    }

    /// Build the same self-contained preview document for either native engine.
    public func writePreview(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let image, let imageFormat {
            try image.write(to: directory.appendingPathComponent("example.\(imageFormat)"))
        }
        let input = directory.appendingPathComponent("example.typ")
        try Data(previewSource.utf8).write(to: input)
        return input
    }

    /// A markup preview that only typesets the snippet's own call syntax as prose
    /// would mislead; the card then shows the source alone.
    public func isEchoed(by renderedText: String) -> Bool {
        guard image == nil, mode == .markup, !source.contains("#"), !source.contains("$"),
              source.range(of: #"[A-Za-z_][\w.-]*\("#, options: .regularExpression) != nil
        else {
            return false
        }
        let plain = source.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/|//[^\n]*"#,
            with: "",
            options: .regularExpression,
        )
        let rendered = Self.skeleton(renderedText)
        return !rendered.isEmpty && rendered == Self.skeleton(plain)
    }

    /// Letters, digits and brackets survive typesetting; quotes, dashes and spacing do not.
    static func skeleton(_ text: String) -> String {
        let kept = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "(){}[],;="))
        return String(String.UnicodeScalarView(
            text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter { kept.contains($0) },
        ))
    }

    /// A ```typ fence is code when no line uses markup's `#` and every top-level line
    /// is a code statement (call, `let`, `import`, loop, …) or a closing bracket.
    static func mode(of code: String) -> Mode {
        let statement = try? NSRegularExpression(pattern: #"""
        \A(?:let\s+(?:[A-Za-z_][\w-]*|\([^)]*\))\s*(?:\([^)]*\)\s*)?=
        |import\s+(?:"|[A-Za-z_])|include\s+"|for\s.+\sin\s|while\s.+\{|if\s.+\{|else\b|return\b
        |context\s|set\s+[A-Za-z_][\w.-]*\s*\(|show\s.*:
        |[A-Za-z_][\w-]*(?:\.[A-Za-z_][\w-]*)*\s*\()
        """#, options: [.allowCommentsAndWhitespace])
        var statements = 0
        var comment = false
        for line in code.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if comment || trimmed.hasPrefix("/*") {
                comment = !trimmed.contains("*/")
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("//") {
                continue
            }
            if trimmed.hasPrefix("#") {
                return .markup
            }
            guard line.first?.isWhitespace != true, !")]}".contains(trimmed.first ?? " ") else {
                continue
            }
            let range = NSRange(location: 0, length: (trimmed as NSString).length)
            guard statement?.firstMatch(in: trimmed, range: range) != nil else {
                return .markup
            }
            statements += 1
        }
        return statements > 0 ? .code : .markup
    }

    /// Tinymist's own ```typc blocks annotate types and sampled values; they are not examples.
    private static func isAnnotation(_ code: String, after preceding: String) -> Bool {
        code.hasPrefix("type:") || code.range(of: #"\Alet\s[\s\S]*;\z"#, options: .regularExpression) != nil ||
            preceding.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("Sampled Values")
    }

    /// Extract one runnable documentation example, never a signature or type annotation.
    /// Documentation's `>>>` setup lines run but stay hidden in the displayed snippet.
    static func first(in contents: [JSONValue]) -> Self? {
        guard let fence =
            try? NSRegularExpression(pattern: #"(?m)^```(typ|typst|typc)[ \t]*\r?\n([\s\S]*?)^```[ \t]*$"#)
        else {
            return nil
        }
        for value in contents where value["kind"].string != "plaintext" && value["language"].string == nil {
            guard let raw = value.string ?? value["value"].string else {
                continue
            }
            let text = String(raw.prefix(256_000)) as NSString
            for match in fence.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let code = text.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty, code.utf8.count <= 12000 else {
                    continue
                }
                let typc = text.substring(with: match.range(at: 1)) == "typc"
                if typc, isAnnotation(code, after: text.substring(to: match.range.location)) {
                    continue
                }
                let lines = code.components(separatedBy: .newlines)
                let source = lines.map { $0.hasPrefix(">>> ") ? String($0.dropFirst(4)) : $0 }
                    .joined(separator: "\n")
                let display = lines.filter { !$0.hasPrefix(">>> ") }.joined(separator: "\n")
                let rest = text.substring(from: NSMaxRange(match.range)) as NSString
                var image: Data?, format: String?
                if let expression =
                    try? NSRegularExpression(
                        pattern: #"\A\s*<img\b[^>]*\bsrc=["']data:image/(svg\+xml|png);base64,([A-Za-z0-9+/=\r\n]+)["'][^>]*>"#,
                    ),
                    let result = expression.firstMatch(
                        in: rest as String,
                        range: NSRange(location: 0, length: rest.length),
                    ),
                    let data = Data(
                        base64Encoded: rest.substring(with: result.range(at: 2)),
                        options: .ignoreUnknownCharacters,
                    ), data.count <= 1_000_000
                {
                    image = data
                    format = rest.substring(with: result.range(at: 1)) == "png" ? "png" : "svg"
                }
                return Self(
                    source: source,
                    displaySource: display,
                    image: image,
                    imageFormat: format,
                    mode: typc ? .code : mode(of: source),
                    package: nil,
                )
            }
        }
        return nil
    }
}

public extension LanguageHover {
    /// Attach the defining package (from `textDocument/definition`) so package examples
    /// compile against the version the manuscript uses.
    func withExamplePackage(from definition: JSONValue, packageCache: URL) -> Self {
        guard let example else {
            return self
        }
        return Self(
            text: text,
            signature: signature,
            documentation: documentation,
            documentationURL: documentationURL,
            example: example.inPackage(TypstPackage.defining(definition, packageCache: packageCache)),
        )
    }
}

public extension TinymistClient {
    /// Hover help for one position. When it carries an example, the symbol's definition
    /// names its package so the example compiles against the version this manuscript resolves.
    func hoverHelp(_ params: [String: Any], packageCache: URL) async throws -> LanguageHover? {
        guard let help = try await LanguageAssistance.hover(request("textDocument/hover", params)) else {
            return nil
        }
        guard help.example != nil, supports("definitionProvider"), !Task.isCancelled,
              let definition = try? await request("textDocument/definition", params)
        else {
            return help
        }
        return help.withExamplePackage(from: definition, packageCache: packageCache)
    }
}
