import Foundation

public struct HoverExample: Equatable, Hashable, Sendable {
    public let source: String
    public let displaySource: String
    public let image: Data?
    public let imageFormat: String?

    /// Extract one runnable documentation example, never a `typc` signature.
    /// Documentation's `>>>` setup lines run but stay hidden in the displayed snippet.
    static func first(in contents: [JSONValue]) -> Self? {
        for value in contents where value["kind"].string != "plaintext" && value["language"].string == nil {
            guard let raw = value.string ?? value["value"].string,
                  let fence =
                  try? NSRegularExpression(pattern: #"(?m)^```(?:typ|typst)[ \t]*\r?\n([\s\S]*?)^```[ \t]*$"#)
            else {
                continue
            }
            let text = String(raw.prefix(256_000)) as NSString
            guard let match = fence.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length))
            else {
                continue
            }
            let code = text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, code.utf8.count <= 12000 else {
                continue
            }
            let lines = code.components(separatedBy: .newlines)
            let source = lines.map { $0.hasPrefix(">>> ") ? String($0.dropFirst(4)) : $0 }.joined(separator: "\n")
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
            return Self(source: source, displaySource: display, image: image, imageFormat: format)
        }
        return nil
    }
}
