import CoreGraphics
import Foundation
#if canImport(AppKit)
    import AppKit

    public typealias PlatformFont = NSFont
    public typealias PlatformColor = NSColor
    public typealias PlatformView = NSView
    public typealias PlatformTextView = NSTextView
    public typealias StorageEditActions = NSTextStorageEditActions

    extension PlatformFont {
        static func visualSystemFont(ofSize size: CGFloat, weight: Weight) -> PlatformFont {
            .systemFont(ofSize: size, weight: weight)
        }

        func visualItalic() -> PlatformFont {
            NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
        }

        var visualIsMonospaced: Bool {
            isFixedPitch
        }
    }
#else
    import UIKit

    public typealias PlatformFont = UIFont
    public typealias PlatformColor = UIColor
    public typealias PlatformView = UIView
    public typealias PlatformTextView = UITextView
    public typealias StorageEditActions = NSTextStorage.EditActions

    extension PlatformFont {
        static func visualSystemFont(ofSize size: CGFloat, weight: Weight) -> PlatformFont {
            .systemFont(ofSize: size, weight: weight)
        }

        func visualItalic() -> PlatformFont {
            fontDescriptor.withSymbolicTraits(.traitItalic)
                .map { PlatformFont(descriptor: $0, size: pointSize) } ?? self
        }

        var visualIsMonospaced: Bool {
            fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        }
    }
#endif
