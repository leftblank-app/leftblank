import LeftBlankCore
import SwiftUI
import UIKit

@MainActor
enum TabletTheme {
    static let nativeBackground = adaptive(light: 0xFAFAFA, dark: 0x171A1D)
    static let nativeBorder = adaptive(light: 0xDFE5E8, dark: 0x343A41)
    static let background = Color(uiColor: nativeBackground)
    static let border = Color(uiColor: nativeBorder)
    static let secondary = Color(uiColor: nativeSecondary)
    static let nativeEditor = adaptive(light: 0xFFFFFF, dark: 0x1C1F23)
    static let nativeText = adaptive(light: 0x37474F, dark: 0xE0E2E5)
    static let nativeSecondary = adaptive(light: 0x586B75, dark: 0x9DA6B2)
    static let nativeAccent = adaptive(light: 0x673AB7, dark: 0xD9B97C)
    static let accent = Color(uiColor: nativeAccent)

    static let sourceText = adaptive(light: 0x37474F, dark: 0xD5D9DE)
    static let sourceStrong = adaptive(light: 0x263238, dark: 0xEEE8DA)
    static let sourceComment = adaptive(light: 0x637681, dark: 0x7C8793)
    static let sourceString = adaptive(light: 0x526D42, dark: 0xA8B89A)
    static let sourceKeyword = adaptive(light: 0x673AB7, dark: 0xBEA4C9)
    static let sourceNumber = adaptive(light: 0x9C5700, dark: 0xD9B97C)
    static let sourceFunction = adaptive(light: 0x326A83, dark: 0x9DBBCD)
    static let sourceCode = adaptive(light: 0x455A64, dark: 0xBAC4CF)

    static func color(for token: HighlightToken) -> UIColor {
        let kind = token.kind.replacingOccurrences(of: "hljs-", with: "").components(separatedBy: " ").first ?? token
            .kind
        return switch kind {
        case "comment", "punct", "delim", "meta": sourceComment
        case "string", "regexp", "escape": sourceString
        case "keyword", "operator", "selector-tag": sourceKeyword
        case "number", "bool", "literal", "symbol", "bullet": sourceNumber
        case "function", "title", "built_in", "type", "namespace", "link", "ref", "label": sourceFunction
        case "heading", "strong": sourceStrong
        case "raw", "code": sourceCode
        default: token.modifiers.contains("math") ? sourceNumber : sourceText
        }
    }

    private nonisolated static func adaptive(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((value >> 16) & 255) / 255,
                green: CGFloat((value >> 8) & 255) / 255,
                blue: CGFloat(value & 255) / 255,
                alpha: 1,
            )
        }
    }
}

struct TabletIcon: View {
    let name: String
    var size: CGFloat = 18

    /// Native menus require an Image label, without the decorative view's
    /// accessibility hiding modifier, to expose their title and action.
    static func menuImage(_ name: String, title: String) -> Image {
        guard let rendered = TabletIconStore.image(name, size: 18), let pixels = rendered.cgImage else {
            return Image("Icons/" + name, label: Text(title))
        }
        return Image(pixels, scale: rendered.scale, label: Text(title)).renderingMode(.template)
    }

    var body: some View {
        if let image = TabletIconStore.image(name, size: size) {
            Image(uiImage: image).renderingMode(.template).resizable().frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

struct TabletBackButton: View {
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button { dismiss() } label: {
            TabletIcon(name: "arrow-left", size: 18).frame(width: 44, height: 44)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

/// UIKit keeps its menu preview inside this native container instead of
/// reparenting views directly into SwiftUI's hosting controller.
struct TabletLibraryMenu: UIViewRepresentable {
    struct Action {
        let title: String
        let icon: String
        let perform: @MainActor () -> Void
    }

    let actions: [Action]

    func makeUIView(context _: Context) -> UIView {
        let container = UIView()
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = true
        button.setImage(TabletIconStore.image("dots-three-vertical", size: 18), for: .normal)
        button.accessibilityIdentifier = "library-actions"
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateUIView(_ container: UIView, context _: Context) {
        guard let button = container.subviews.first as? UIButton else {
            return
        }
        button.tintColor = TabletTheme.nativeSecondary
        button.accessibilityLabel = L10n.text("Library actions")
        let items = actions.map { action in
            UIAction(title: action.title, image: TabletIconStore.image(action.icon, size: 18)) { _ in
                MainActor.assumeIsolated { action.perform() }
            }
        }
        button.menu = UIMenu(children: [
            UIMenu(options: .displayInline, children: Array(items.prefix(2))),
            UIMenu(options: .displayInline, children: Array(items.dropFirst(2))),
        ])
    }
}

@MainActor private enum TabletIconStore {
    private static var images: [String: UIImage] = [:]
    static func image(_ name: String, size: CGFloat) -> UIImage? {
        let key = "\(name)-\(size)"
        if let image = images[key] {
            return image
        }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Icons/\(name).pdf"),
              let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1)
        else {
            return nil
        }
        let box = page.getBoxRect(.mediaBox)
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            context.cgContext.translateBy(x: 0, y: size)
            context.cgContext.scaleBy(x: size / box.width, y: -size / box.height)
            context.cgContext.drawPDFPage(page)
        }.withRenderingMode(.alwaysTemplate)
        images[key] = image
        return image
    }
}

struct TabletEmptyState: View {
    let title: String
    let icon: String
    var detail = ""
    var body: some View {
        VStack(spacing: 12) {
            TabletIcon(name: icon, size: 28).foregroundStyle(TabletTheme.accent)
            Text(title).font(.headline)
            if !detail
                .isEmpty
            {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.frame(maxWidth: 320).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
