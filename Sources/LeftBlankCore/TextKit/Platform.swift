import CoreGraphics
import Foundation
#if canImport(AppKit)
    import AppKit

    public typealias PlatformFont = NSFont
    public typealias PlatformColor = NSColor
    public typealias StorageEditActions = NSTextStorageEditActions

    extension PlatformFont {
        func italic() -> PlatformFont {
            NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
        }
    }
#else
    import UIKit

    public typealias PlatformFont = UIFont
    public typealias PlatformColor = UIColor
    public typealias StorageEditActions = NSTextStorage.EditActions

    extension PlatformFont {
        func italic() -> PlatformFont {
            fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.traitItalic))
                .map { PlatformFont(descriptor: $0, size: pointSize) } ?? self
        }
    }
#endif
