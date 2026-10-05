import Foundation
@testable import LeftBlankCore
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
