import Foundation

/// Shared resources in installed apps, Xcode builds and SwiftPM test executables.
enum CoreResources {
    static let bundle: Bundle = {
        // Native SwiftPM's generated accessor checks beside the executable
        // bundle and in the build checkout. Installed apps use Contents/Resources.
        if let url = Bundle.main.url(forResource: "LeftBlank_LeftBlankCore", withExtension: "bundle"),
           let bundle = Bundle(url: url)
        {
            return bundle
        }
        return Bundle.module
    }()
}
