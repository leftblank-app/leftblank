import Combine
import Foundation
import LeftBlankCore

@MainActor
final class AppLocalization: ObservableObject {
    static let shared = AppLocalization()
    @Published private(set) var language = L10n.language
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .leftblankLanguageChanged,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.language != L10n.language else {
                    return
                }
                self?.language = L10n.language
            }
        }
    }

    func select(_ language: AppLanguage) {
        guard self.language != language else {
            return
        }
        self.language = language
        L10n.setLanguage(language)
    }
}
