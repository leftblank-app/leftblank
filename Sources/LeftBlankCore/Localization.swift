import Foundation

public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String {
        rawValue
    }

    public static func resolve(_ language: Self, preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        guard language == .system else {
            return language
        }
        let best = Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferredLanguages).first
        return best == "zh-Hans" ? .simplifiedChinese : .english
    }
}

public extension Notification.Name {
    static let leftblankLanguageChanged = Notification.Name("LeftBlank.languageChanged")
}

/// Native bundle lookup with an explicit app language. No process-wide AppleLanguages override.
public enum L10n {
    public static let preferenceKey = "appLanguage"
    private static let state = LocalizationState()
    private static let bundles: [AppLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        [AppLanguage.english, .simplifiedChinese].compactMap { language in
            // SwiftPM's native builder lowercases locale directories; the Xcode
            // builder preserves their spelling. Bundle lookup is case-sensitive.
            let identifier = CoreResources.bundle.localizations.first {
                $0.caseInsensitiveCompare(language.rawValue) == .orderedSame
            } ?? language.rawValue
            return CoreResources.bundle.path(forResource: identifier, ofType: "lproj")
                .flatMap(Bundle.init(path:)).map { (language, $0) }
        })

    public static var language: AppLanguage {
        state.readLanguage()
    }

    public static var resolvedLanguage: AppLanguage {
        AppLanguage.resolve(language)
    }

    public static var locale: Locale {
        Locale(identifier: resolvedLanguage.rawValue)
    }

    public static func setLanguage(_ language: AppLanguage) {
        guard state.changeLanguage(language) else {
            return
        }
        UserDefaults.standard.set(language.rawValue, forKey: preferenceKey)
        NotificationCenter.default.post(name: .leftblankLanguageChanged, object: nil)
    }

    public static func text(_ key: String, language: AppLanguage? = nil) -> String {
        let selected = AppLanguage.resolve(language ?? self.language)
        return bundles[selected]?.localizedString(forKey: key, value: key, table: nil) ?? key
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    /// Search is stable across language changes, including a query typed before switching.
    public static func searchTerms(_ key: String) -> String {
        key + " " + text(key, language: .simplifiedChinese)
    }
}

private final class LocalizationState: @unchecked Sendable {
    private let lock = NSLock()
    private var language = AppLanguage(
        rawValue: UserDefaults.standard.string(forKey: L10n.preferenceKey) ?? "system",
    ) ??
        .system

    func readLanguage() -> AppLanguage {
        lock.withLock { language }
    }

    func changeLanguage(_ next: AppLanguage) -> Bool {
        lock.withLock {
            guard language != next else {
                return false
            }
            language = next
            return true
        }
    }
}
