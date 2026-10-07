import Foundation
@testable import LeftBlankCore
import LeftBlankTestSupport
import Testing

@Test func documentationExamplesPreserveHiddenSetupAndPreferTheirOwnImage() throws {
    let svg = Data(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\"><rect width=\"100\" height=\"50\" fill=\"red\"/></svg>"
            .utf8,
    )
    let markdown = "```typc\nlet align(body);\n```\n\nExample\n\n```typ\n>>> #set text(size: 12pt)\n#align(center)[Hi]\n```\n\n<img alt=\"typst-block\" src=\"data:image/svg+xml;base64,\(svg.base64EncodedString())\" />"
    let help = try #require(LanguageAssistance.hover(.object(["contents": .string(markdown)])))
    let example = try #require(help.example)
    #expect(example.source == "#set text(size: 12pt)\n#align(center)[Hi]")
    #expect(example.displaySource == "#align(center)[Hi]")
    #expect(example.image == svg && example.imageFormat == "svg")
    #expect(help.signature == "let align(body);")
    let largerSVG =
        Data(("<svg xmlns=\"http://www.w3.org/2000/svg\"><!--" + String(repeating: "x", count: 20000) + "--></svg>")
                .utf8)
    let largeExample = markdown.replacingOccurrences(
        of: svg.base64EncodedString(),
        with: largerSVG.base64EncodedString(),
    )
    #expect(LanguageAssistance.hover(.object(["contents": .string(largeExample)]))?.example?.image == largerSVG)
    #expect(LanguageAssistance.hover(.object(["contents": .string("```typc\nlet rect();\n```")]))?.example == nil)
    #expect(LanguageAssistance.hover(.object(["contents": .object([
        "kind": .string("plaintext"),
        "value": .string(markdown),
    ])]))?.example == nil)
    let external = "```typst\n#align(center)[Hi]\n```\n<img src=\"https://example.com/image.svg\" />"
    let withoutImage = try #require(LanguageAssistance.hover(.object(["contents": .string(external)]))?.example)
    #expect(withoutImage.image == nil)
    #expect(withoutImage.source == "#align(center)[Hi]")
}

/// Tinymist re-labels tidy's ```example fences as ```typ, so CeTZ draw code arrives
/// looking like markup (LB-002). Captured from `tinymist lsp` hovering `group`.
private let cetzGroupHover = """
```typc
let group(
  body: array | function | none,
  name: none | str = none,
) = any;
```

---

Groups one or more elements together.

```typ
// Create group
group({
  stroke(5pt)
  scale(.5); rotate(45deg)
  rect((-1,-1),(1,1))
})
rect((-1,-1),(1,1))
```

# Positional Parameters

## body

```typc
type: array | function | none
```
"""

@Test func packageCodeExamplesAreClassifiedAsCodeAndMarkupStaysMarkup() throws {
    let group = try #require(LanguageAssistance.hover(.object(["contents": .string(cetzGroupHover)]))?.example)
    #expect(group.mode == .code)
    #expect(group.source.hasPrefix("// Create group\ngroup({"))
    func mode(_ code: String) -> HoverExample.Mode {
        HoverExample.mode(of: code)
    }
    // CeTZ manual shapes: calls, `let`, loops, imports, closers and comments.
    #expect(mode("let p = cetz.palette.new(colors: (red, blue))\nfor i in range(0, 3) {\n  circle((0,0))\n}") == .code)
    #expect(mode("import cetz.tree\nset-style(content: (padding: .1))\ntree.tree(([Root], [A]))") == .code)
    #expect(mode("let (a, b) = ((2, 1), (1, 1))\n\n// Show both\ncontent(a, [A]); content(b, [B])") == .code)
    #expect(mode("cetz.decorations.flat-brace((0,1),(2,1),\n  curves: .2)\n/* note */\nline((0,0), (1,1))") == .code)
    // Typst's own documentation examples are markup.
    #expect(mode("#set page(height: 120pt)\n#set align(center)\n\nCentered text") == .markup)
    #expect(mode("Start #h(1fr) End") == .markup)
    #expect(mode("= Heading\n- item") == .markup)
    #expect(mode("$ f(x) = x^2 $") == .markup)
    #expect(mode("for example, this is prose") == .markup)
    #expect(mode("let me explain") == .markup)
    #expect(mode("rect(width: 1cm)\nThen some prose.") == .markup, "Every top-level line must be code")
    #expect(mode("// only a comment") == .markup)
}

@Test func typcDocumentationExamplesAreCodeButTinymistAnnotationsAreNot() throws {
    let markdown = "```typc\nlet double(\n  x: any,\n) = any;\n```\n\n---\n\nDoubles.\n\n```typc\ndouble(2) + 1\n```\n\n```typ\n#double(3)\n```"
    let example = try #require(LanguageAssistance.hover(.object(["contents": .string(markdown)]))?.example)
    #expect(example.source == "double(2) + 1" && example.mode == .code)
    for annotation in [
        "```typc\nlet width = length;\n```\n\n---\n\n### Sampled Values\n```typc\n3pt = 1.06mm\n```",
        "```typc\nlet f() = any;\n```\n\n---\n\n## body\n\n```typc\ntype: array | none\n```",
        "Docs\n\n```typc\nlet rect(width: auto);\n```",
    ] {
        #expect(LanguageAssistance.hover(.object(["contents": .string(annotation)]))?.example == nil)
    }
}

@Test func definitionsInsideThePackageCacheNameTheExamplePackage() throws {
    let cache = URL(fileURLWithPath: "/Volumes/Cache/PackageCache")
    func definition(_ path: String, key: String = "targetUri") -> JSONValue {
        .array([.object([key: .string(URL(fileURLWithPath: path).absoluteString)])])
    }
    let cetz = try #require(TypstPackage.defining(
        definition("/Volumes/Cache/PackageCache/preview/cetz/0.3.2/src/draw/grouping.typ"),
        packageCache: cache,
    ))
    #expect(cetz == TypstPackage(namespace: "preview", name: "cetz", version: "0.3.2"))
    #expect(cetz.specifier == "@preview/cetz:0.3.2")
    #expect(TypstPackage.defining(
        definition("/Volumes/Cache/PackageCache/preview/cetz-plot/0.1.4/src/plot.typ", key: "uri"),
        packageCache: cache,
    )?.name == "cetz-plot")
    for outside in [
        "/Users/me/Book/preview/cetz/0.5.2/lib.typ",
        "/Volumes/Cache/PackageCache/preview/cetz/latest/lib.typ",
        "/Volumes/Cache/PackageCache/preview/cetz\"/0.5.2/lib.typ",
        "/Volumes/Cache/PackageCache/preview/cetz/0.5.2",
        "/Volumes/Cache/PackageCache/../preview/cetz/0.5.2/lib.typ",
    ] {
        #expect(TypstPackage.defining(definition(outside), packageCache: cache) == nil, "\(outside)")
    }
    #expect(TypstPackage.defining(.null, packageCache: cache) == nil)

    let directory = TestPaths.temporaryDirectory.appendingPathComponent("LeftBlank-hover-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let real = directory.appendingPathComponent("Real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let linked = directory.appendingPathComponent("Linked")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)
    #expect(TypstPackage.defining(
        definition(real.path + "/preview/cetz/0.5.2/src/lib.typ"),
        packageCache: linked,
    )?.version == "0.5.2", "A symlinked cache still contains its packages")
}

@Test func previewDocumentsRunCodeInItsDocumentedContext() throws {
    let help = try #require(LanguageAssistance.hover(.object(["contents": .string(cetzGroupHover)])))
    let group = try #require(help.example)
    let cache = URL(fileURLWithPath: "/Volumes/Cache/PackageCache")
    let definition = JSONValue.array([.object(["targetUri": .string(
        "file:///Volumes/Cache/PackageCache/preview/cetz/0.5.2/src/draw/grouping.typ",
    )])])
    let packaged = try #require(help.withExamplePackage(from: definition, packageCache: cache).example)
    #expect(packaged.package?.specifier == "@preview/cetz:0.5.2")
    #expect(packaged.displaySource == group.displaySource && packaged.source == group.source)
    #expect(packaged.previewSource == """
    #set page(width: 300pt, height: auto, margin: 12pt, fill: white)
    #import "@preview/cetz:0.5.2"
    #cetz.canvas({
    import cetz.draw: *
    \(group.source)
    })
    """)
    #expect(help.withExamplePackage(from: .null, packageCache: cache).example?.package == nil)
    // Without a known package context, code runs in a plain code block.
    #expect(group.previewSource.hasSuffix("\n#{\n\(group.source)\n}"))
    let other = group.inPackage(TypstPackage(namespace: "preview", name: "tidy", version: "0.4.0"))
    #expect(other.previewSource.hasSuffix("#import \"@preview/tidy:0.4.0\"\n#{\n\(group.source)\n}"))
    // Markup examples (e.g. CeTZ's `#cetz.styles.resolve(…)`) only gain the import.
    let markup = try #require(LanguageAssistance.hover(.object([
        "contents": .string("```typ\n#cetz.styles.resolve((:))\n```"),
    ]))?.example).inPackage(packaged.package)
    #expect(markup.mode == .markup)
    #expect(markup.previewSource.hasSuffix("#import \"@preview/cetz:0.5.2\"\n#cetz.styles.resolve((:))"))
}

@Test func previewsThatOnlyEchoTheSnippetAsProseAreRejected() throws {
    func example(_ code: String) throws -> HoverExample {
        try #require(LanguageAssistance.hover(.object(["contents": .string("```typ\n\(code)\n```")]))?.example)
    }
    // The screenshot's preview: code typeset as text, with typographic quotes and minus signs.
    let echoed = try example("// Draw\nline((-1, 0), (1, 0), name: \"a\")\nx += 1")
    #expect(echoed.mode == .markup)
    #expect(echoed.isEchoed(by: "line((−1, 0), (1, 0), name: “a”) x += 1"))
    #expect(!echoed.isEchoed(by: ""))
    #expect(!echoed.isEchoed(by: "A drawing label"))
    // Markup that legitimately renders as its own text is kept.
    #expect(try !example("Hello *world*").isEchoed(by: "Hello world"))
    #expect(try !example("$ f(x) = x $").isEchoed(by: "f(x) = x"))
    #expect(try !example("#emph[f(x)]").isEchoed(by: "f(x)"))
    #expect(
        try !example("group({ rect((0,0),(1,1)) })").isEchoed(by: "group({ rect((0,0),(1,1)) })"),
        "Code mode never typesets its source",
    )
}
