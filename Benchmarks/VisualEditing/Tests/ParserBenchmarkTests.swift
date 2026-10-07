import Foundation
import Testing
import VisualPresentation

/// Opt-in (LB019_FIXTURE): typst-syntax through the C ABI, measured from
/// Swift on each platform, including conversion to Swift values.
struct ParserBenchmarkTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LB019_FIXTURE"] != nil))
    func parseFlattenAndEditThroughTheBridge() throws {
        let path = try #require(ProcessInfo.processInfo.environment["LB019_FIXTURE"])
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        var parse: [Double] = []
        var tree: SyntaxTree?
        for _ in 0 ..< 5 {
            parse.append(milliseconds { tree = SyntaxTree(text) })
        }
        let syntax = try #require(tree)
        var nodes: [SyntaxNode] = []
        let flatten = milliseconds { nodes = syntax.nodes() }
        let length = (text as NSString).length
        var window: [Double] = []
        for index in 1 ... 6 {
            let start = length * index / 7
            window.append(milliseconds { _ = syntax.nodes(in: NSRange(location: start, length: 6000)) })
        }
        var edits: [Double] = []
        var cursor = (text as NSString).paragraphRange(for: NSRange(location: length / 2, length: 0)).location
        for character in String(repeating: "Typing 中文 *x* 😀", count: 6) {
            let unit = String(character)
            edits.append(milliseconds {
                if let reparsed = syntax.edit(NSRange(location: cursor, length: 0), replacement: unit) {
                    _ = syntax.nodes(in: reparsed)
                }
            })
            cursor += (unit as NSString).length
        }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        Report.record(
            "parser.\(name)",
            ["parse_ms": summary(parse), "nodes": nodes.count, "flatten_to_swift_ms": flatten,
             "window_6000_ms": summary(window), "typing_edit_fetch_ms": summary(edits)],
        )
        #expect(syntax.utf16Length == length + edits.count * 0 + (cursor - (text as NSString).paragraphRange(
            for: NSRange(location: length / 2, length: 0),
        ).location))
    }
}
