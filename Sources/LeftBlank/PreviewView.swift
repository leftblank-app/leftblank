import LeftBlankCore
import SwiftUI
import WebKit

struct PreviewView: NSViewRepresentable {
    let url: URL
    let zoom: CGFloat
    var maxPageWidth: CGFloat?
    var dark = false
    @ObservedObject var readingSession = PreviewReadingSession()
    var onLoading: () -> Void = {}
    var onReady: () -> Void = {}
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(readingSession: readingSession, onLoading: onLoading, onReady: onReady, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "leftblankPreviewReady")
        config.userContentController.add(context.coordinator, name: "leftblankPreviewReading")
        let css = PreviewScripts.setup(
            canvas: PreviewWebView.chromeColor(for: NSApp.effectiveAppearance),
            scheme: PreviewWebView.chromeScheme(for: NSApp.effectiveAppearance),
        )
        config.userContentController.addUserScript(WKUserScript(
            source: css,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
        ))
        let view = PreviewWebView(frame: .zero, configuration: config)
        view.onWillLoad = { [weak coordinator = context.coordinator] in
            coordinator?.readingSession.prepareReload()
            coordinator?.onLoading()
        }
        view.navigationDelegate = context.coordinator
        view.applyChromeAppearance()
        view.setAccessibilityLabel(L10n.text("Document Preview"))
        _ = view.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.readingSession = readingSession
        context.coordinator.onLoading = onLoading
        context.coordinator.onReady = onReady
        view.setAccessibilityLabel(L10n.text("Document Preview"))
        context.coordinator.zoom = zoom
        context.coordinator.maxPageWidth = maxPageWidth
        context.coordinator.dark = dark
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            view.load(URLRequest(url: url))
        }
        context.coordinator.applyZoom(to: view)
        context.coordinator.restoreReading(in: view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "leftblankPreviewReady")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "leftblankPreviewReading")
        view.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var loadedURL: URL? {
            didSet {
                if loadedURL != oldValue {
                    recoveredTermination = false
                }
            }
        }

        var readingSession: PreviewReadingSession
        private var restoringID: UUID?
        var zoom: CGFloat = 1
        var maxPageWidth: CGFloat?
        var dark = false
        private var appliedZoom: CGFloat?
        private var appliedMaxPageWidth: CGFloat?
        private var appliedDark: Bool?
        private var recoveredTermination = false
        let onError: (String) -> Void
        var onLoading: () -> Void
        var onReady: () -> Void
        init(
            readingSession: PreviewReadingSession = .init(),
            onLoading: @escaping () -> Void = {},
            onReady: @escaping () -> Void = {},
            onError: @escaping (String) -> Void,
        ) {
            self.readingSession = readingSession
            self.onLoading = onLoading
            self.onReady = onReady
            self.onError = onError
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
        ) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url == loadedURL else {
                return
            }
            if message.name == "leftblankPreviewReady" {
                onReady()
                if let view = message.webView {
                    restoreReading(in: view)
                }
            } else if message.name == "leftblankPreviewReading", let body = message.body as? [String: Any] {
                receiveReading(body)
            }
        }

        func receiveReading(_ body: [String: Any]) {
            readingSession.receive(body)
        }

        func restoreReading(in view: WKWebView) {
            guard !view.isLoading, let request = readingSession.restore, restoringID != request.id else {
                return
            }
            restoringID = request.id
            view
                .evaluateJavaScript("window.leftblankRestoreReading?.(\(request.anchor.javaScript)) ?? false") { [
                    weak self,
                ] result, _ in
                    guard let self, restoringID == request.id else {
                        return
                    }
                    restoringID = nil
                    if result as? Bool == true {
                        readingSession.didRestore(request.id)
                    }
                }
        }

        func applyZoom(to view: WKWebView) {
            guard !view.isLoading,
                  appliedZoom != zoom || appliedMaxPageWidth != maxPageWidth || appliedDark != dark
            else {
                return
            }
            // Tinymist fits pages to this container; browser pageZoom is cancelled by that fit.
            // Limit the default reading width, while allowing explicit zoom to enlarge it.
            let script = """
            (() => {
                const container = document.getElementById('typst-container');
                if (!container) return false;
                const width = '\(zoom * 100)%';
                const maxWidth = '\(maxPageWidth.map { "\($0 * zoom)px" } ?? "none")';
                if (container.style.width !== width || container.style.maxWidth !== maxWidth) {
                    window.leftblankPrepareResize?.();
                }
                container.style.width = width;
                container.style.maxWidth = maxWidth;
                container.style.marginInline = 'auto';
                if (window.leftblankSetDark) window.leftblankSetDark(\(dark ? "true" : "false"));
                window.dispatchEvent(new Event('resize'));
                return true;
            })()
            """
            let requestedZoom = zoom
            let requestedMaxPageWidth = maxPageWidth
            let requestedDark = dark
            view.evaluateJavaScript(script) { [weak self] result, _ in
                if result as? Bool == true {
                    self?.appliedZoom = requestedZoom
                    self?.appliedMaxPageWidth = requestedMaxPageWidth
                    self?.appliedDark = requestedDark
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            appliedZoom = nil
            appliedDark = nil
            (webView as? PreviewWebView)?.applyChromeAppearance()
            applyZoom(to: webView)
            restoreReading(in: webView)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            onLoading()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @MainActor (WKNavigationActionPolicy) -> Void,
        ) {
            guard let target = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if target.host == "127.0.0.1", target.port == loadedURL?.port {
                decisionHandler(.allow)
            } else if target.scheme == "about" {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if navigationAction.navigationType == .linkActivated,
                   ["https", "http"].contains(target.scheme ?? "")
                {
                    NSWorkspace.shared.open(target)
                }
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            appliedZoom = nil
            appliedDark = nil
            if !recoveredTermination {
                recoveredTermination = true
                webView.reload()
            } else {
                onError(L10n.text("Preview stopped unexpectedly. Reconnect typesetting to try again."))
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            onError(L10n.format(
                "Preview failed to load: %@",
                error.localizedDescription,
            ))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error,
        ) {
            onError(L10n.format("Preview temporarily unavailable: %@", error.localizedDescription))
        }
    }
}

/// Invalidate navigation readiness synchronously. WebKit's provisional-load
/// callback arrives later; a source jump in that gap would reach the old page.
final class PreviewWebView: WKWebView {
    static func chromeScheme(for appearance: NSAppearance) -> String {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
    }

    static func chromeColor(for appearance: NSAppearance) -> String {
        chromeScheme(for: appearance) == "dark" ? "#22262b" : "#fafafa"
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyChromeAppearance()
    }

    func applyChromeAppearance() {
        // Recolor the surrounding canvas without touching the document's own
        // Light/Dark choice, scroll position, zoom or Tinymist render state.
        // WebKit snapshots this color for rubber-banding; resolve it now instead
        // of passing a dynamic NSColor that can retain the previous appearance.
        let background = Self.chromeColor(for: effectiveAppearance)
        underPageBackgroundColor = NSColor(hex: Self
            .chromeScheme(for: effectiveAppearance) == "dark" ? 0x22262B : 0xFAFAFA)
        guard !isLoading else {
            return
        }
        let scheme = Self.chromeScheme(for: effectiveAppearance)
        evaluateJavaScript("window.leftblankSetChrome?.('\(background)', '\(scheme)')", completionHandler: nil)
    }

    var onWillLoad: (() -> Void)?
    override func load(_ request: URLRequest) -> WKNavigation? {
        onWillLoad?()
        return super.load(request)
    }

    override func reload() -> WKNavigation? {
        onWillLoad?()
        return super.reload()
    }
}

struct PreviewReadingControls: View {
    @ObservedObject var session: PreviewReadingSession
    var showFollow = true
    var onReturn: () -> Void

    var body: some View {
        if showFollow {
            Toggle(isOn: $session.followsWriting) {
                Label { Text(L10n.text("Follow Writing")) } icon: { PhosphorIcon(name: "crosshair") }
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            .accessibilityIdentifier("preview-follow")
            .help(L10n.text("Pause automatically when you scroll the preview."))
        }
        Button { session.returnToReading()
            onReturn()
        } label: {
            Label { Text(L10n.text("Return to Reading")) } icon: { PhosphorIcon(name: "arrow-counter-clockwise") }
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("preview-return")
        .disabled(session.returnAnchor == nil)
    }
}
