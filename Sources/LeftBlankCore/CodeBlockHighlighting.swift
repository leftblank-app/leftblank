import Foundation
import JavaScriptCore

/// Runs the bundled, pinned language grammars off the UI actor. Manuscript code
/// is passed as a function argument; it is never evaluated or sent to a network.
public actor CodeBlockHighlighting {
    private var context: JSContext?
    private struct Key: Hashable { let language: String
        let text: String
    }

    private var cache: [Key: [HighlightToken]] = [:]
    public init() {}

    public func tokens(in source: String) -> [HighlightToken] {
        if context == nil {
            let bundle = Bundle.main.url(forResource: "LeftBlank_LeftBlankCore", withExtension: "bundle")
                .flatMap(Bundle.init(url:)) ?? Bundle.module
            guard let url = bundle.url(forResource: "highlight.min", withExtension: "js"),
                  let script = try? String(contentsOf: url, encoding: .utf8),
                  let engine = JSContext()
            else {
                return []
            }
            engine.evaluateScript(script)
            if let grammar = bundle.url(forResource: "scheme.min", withExtension: "js"),
               let scheme = try? String(contentsOf: grammar, encoding: .utf8)
            {
                engine.evaluateScript(scheme)
            }
            engine
                .evaluateScript(
                    "function leftblankHighlight(code, language) { return hljs.getLanguage(language) ? hljs.highlight(code, {language: language, ignoreIllegals: true}).value : null; }",
                )
            context = engine
        }
        let text = source as NSString
        var result: [HighlightToken] = [], nextCache: [Key: [HighlightToken]] = [:]
        var budget = 1_048_576
        for block in Self.codeBlocks(in: source).prefix(2048) {
            guard !Task.isCancelled else {
                return []
            }
            guard !block.language.isEmpty, block.contentRange.length <= 32000,
                  block.contentRange.length <= budget
            else {
                continue
            }
            budget -= block.contentRange.length
            let code = text.substring(with: block.contentRange)
            let key = Key(language: block.language, text: code)
            let spans: [HighlightToken]
            if let cached = cache[key] {
                spans = cached
            } else if let html = context?.objectForKeyedSubscript("leftblankHighlight")?.call(withArguments: [
                code,
                block.language,
            ])?.toString(), html != "null" {
                let reader = HighlightHTMLReader()
                let parser =
                    XMLParser(data: Data(("<code>" + html.replacingOccurrences(of: "\r", with: "&#13;") + "</code>")
                                .utf8))
                parser.shouldResolveExternalEntities = false
                parser.delegate = reader
                spans = parser.parse() && reader.text == code ? reader.tokens : []
            } else {
                spans = []
            }
            nextCache[key] = spans
            result += spans.map { .init(
                range: NSRange(location: block.contentRange.location + $0.range.location, length: $0.range.length),
                kind: $0.kind,
            ) }
        }
        cache = nextCache
        return result
    }
}

extension CodeBlockHighlighting {
    struct CodeBlock: Equatable {
        let language: String
        let contentRange: NSRange
    }

    /// Fenced raw blocks with a language: the lines after the opening fence, up
    /// to the closing fence or, while it is still being typed, the text's end.
    static func codeBlocks(in source: String) -> [CodeBlock] {
        guard let nodes = SyntaxTree(source)?.nodes() else {
            return []
        }
        let text = source as NSString
        var children = [[SyntaxNode]](repeating: [], count: nodes.count)
        for node in nodes {
            if let parent = node.parent, parent < nodes.count {
                children[parent].append(node)
            }
        }
        var blocks: [CodeBlock] = []
        for node in nodes where node.kind == .error && node.range.length > 3 {
            // A fence still being typed is one error node to the end of the text.
            let body = text.substring(with: node.range)
            guard body.hasPrefix("```"), let newline = body.firstIndex(where: \.isNewline) else {
                continue
            }
            let language = body[body.index(body.startIndex, offsetBy: 3) ..< newline]
                .trimmingCharacters(in: CharacterSet(charactersIn: "`").union(.whitespaces))
            let start = node.range.location + (String(body[...newline]) as NSString).length
            if !language.isEmpty {
                blocks.append(CodeBlock(
                    language: language.lowercased(),
                    contentRange: NSRange(location: start, length: NSMaxRange(node.range) - start),
                ))
            }
        }
        for (index, node) in nodes.enumerated() where node.kind == .raw {
            let delimiters = children[index].filter { $0.kind == .rawDelim }
            guard let open = delimiters.first, open.range.length >= 3,
                  let language = children[index].first(where: { $0.kind == .rawLang })
            else {
                continue
            }
            let end = delimiters.count > 1 ? delimiters[delimiters.count - 1].range.location : NSMaxRange(node.range)
            let head = NSRange(location: NSMaxRange(language.range), length: max(0, end - NSMaxRange(language.range)))
            let newline = text.rangeOfCharacter(from: .newlines, range: head)
            guard newline.location != NSNotFound else {
                continue
            }
            let start = NSMaxRange(newline)
            blocks.append(CodeBlock(
                language: text.substring(with: language.range).lowercased(),
                contentRange: NSRange(location: start, length: max(0, end - start)),
            ))
        }
        return blocks.sorted { $0.contentRange.location < $1.contentRange.location }
    }
}

private final class HighlightHTMLReader: NSObject, XMLParserDelegate {
    var text = ""
    private var offset = 0
    private var stack: [(start: Int, kind: String)] = []
    private var spans: [(token: HighlightToken, depth: Int)] = []
    var tokens: [HighlightToken] {
        spans.sorted {
            if $0.token.range.length == $1.token.range.length {
                return $0.depth < $1.depth
            }
            return $0.token.range.length > $1.token.range.length
        }.map(\.token)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement name: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String],
    ) {
        if name == "span" {
            stack.append((offset, attributes["class"] ?? ""))
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
        offset += string.utf16.count
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "span", let start = stack.popLast(), offset > start.start {
            spans.append((
                .init(range: NSRange(location: start.start, length: offset - start.start), kind: start.kind),
                stack.count,
            ))
        }
    }
}
