import CoreGraphics
import Foundation
#if canImport(AppKit)
    import AppKit
#else
    import UIKit
#endif

/// Fonts and colours of the visual layer; each platform supplies its theme.
public struct VisualStyle: Equatable {
    public var fontSize: CGFloat
    public var text: PlatformColor
    public var strong: PlatformColor
    public var code: PlatformColor
    public var codeBackground: PlatformColor
    public var link: PlatformColor
    /// Revealed markup and list markers.
    public var marker: PlatformColor
    public var math: PlatformColor
    public var chip: PlatformColor
    public var chipFill: PlatformColor

    public init(
        fontSize: CGFloat,
        text: PlatformColor,
        strong: PlatformColor,
        code: PlatformColor,
        codeBackground: PlatformColor,
        link: PlatformColor,
        marker: PlatformColor,
        math: PlatformColor,
        chip: PlatformColor,
        chipFill: PlatformColor,
    ) {
        self.fontSize = fontSize
        self.text = text
        self.strong = strong
        self.code = code
        self.codeBackground = codeBackground
        self.link = link
        self.marker = marker
        self.math = math
        self.chip = chip
        self.chipFill = chipFill
    }

    public var font: PlatformFont {
        .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    /// Attributes of source text and of new typing.
    public var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 7
        paragraph.paragraphSpacing = 2
        return [.font: font, .foregroundColor: text, .paragraphStyle: paragraph]
    }

    func attributes(for style: PresentationStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case let .heading(level):
            [.font: PlatformFont.visualSystemFont(ofSize: fontSize + CGFloat(max(2, 8 - level * 2)), weight: .semibold),
             .foregroundColor: strong]
        case .strong:
            [.font: PlatformFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: strong]
        case .emphasis:
            [.font: font.visualItalic()]
        case .code:
            [.foregroundColor: code, .backgroundColor: codeBackground]
        case .link, .reference, .label:
            [.foregroundColor: link]
        case .listMarker:
            [.foregroundColor: marker]
        case .math:
            [.foregroundColor: math]
        case .revealedMarker:
            [.font: font, .foregroundColor: marker]
        }
    }
}
