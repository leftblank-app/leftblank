import Foundation

/// LSP source navigation, shared by the platform editors. LSP results use UTF-16
/// columns; Tinymist's preview-to-source jumps count Unicode scalars instead.
public struct SourceLocation: Equatable, Sendable {
    public let url: URL
    public let position: TextPosition
    public let scalarColumns: Bool

    public init?(_ params: JSONValue, scalarColumns: Bool = false) {
        guard let uri = params["uri"].string, let url = URL(string: uri), url.isFileURL else {
            return nil
        }
        self.url = url
        let start = params["selection"]["start"]
        position = TextPosition(line: max(0, start["line"].int ?? 0), character: max(0, start["character"].int ?? 0))
        self.scalarColumns = scalarColumns
    }

    /// The UTF-16 offset of this location in `text`, clamped to its line.
    public func offset(in text: String) -> Int {
        guard scalarColumns else {
            return position.offset(in: text)
        }
        let index = TextLineIndex(text)
        let start = index.offset(at: TextPosition(line: position.line, character: 0))
        let end = index.offset(at: TextPosition(line: position.line, character: .max))
        var offset = start
        for scalar in (text as NSString).substring(with: NSRange(location: start, length: end - start)).unicodeScalars
            .prefix(position.character)
        {
            offset += scalar.utf16.count
        }
        return offset
    }
}
