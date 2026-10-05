import LeftBlankCore
import SwiftUI
import WebKit

struct TabletPreview: UIViewRepresentable {
    @AppStorage("iPadPreviewDark") private var previewDark = false
    @ObservedObject var workspace: TabletWorkspace
    @ObservedObject var readingSession: PreviewReadingSession

    init(workspace: TabletWorkspace) {
        self.workspace = workspace
        readingSession = workspace.previewReading
    }

    @Environment(\.colorScheme) private var scheme

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "leftblankPreviewReady")
        config.userContentController.add(context.coordinator, name: "leftblankPreviewReading")
        config.userContentController.add(context.coordinator, name: "leftblankPreviewError")
        config.userContentController.addUserScript(WKUserScript(
            source: PreviewScripts.setup(
                canvas: scheme == .dark ? "#171a1d" : "#fafafa",
                scheme: scheme == .dark ? "dark" : "light",
            ),
            injectionTime: .atDocumentEnd, forMainFrameOnly: true,
        ))
        config.userContentController.addUserScript(WKUserScript(
            source: """
            const report = error => window.webkit.messageHandlers.leftblankPreviewError.postMessage(String(error).slice(0, 400));
            window.addEventListener('error', event => report(event.message));
            window.addEventListener('unhandledrejection', event => report(event.reason));
            """,
            injectionTime: .atDocumentStart, forMainFrameOnly: true,
        ))
        let view = TabletPreviewWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.onWillLoad = { [weak coordinator = context.coordinator] in
            coordinator?.workspace.previewReading.prepareReload()
            coordinator?.workspace.previewReady = false
        }
        view.isOpaque = false
        view.backgroundColor = TabletTheme.nativeEditor
        view.accessibilityLabel = L10n.text("Document Preview")
        view.accessibilityIdentifier = "document-preview"
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.workspace = workspace
        if context.coordinator.url != workspace.previewURL {
            context.coordinator.url = workspace.previewURL
            if let url = workspace.previewURL {
                view.load(URLRequest(url: url))
            } else {
                view.loadHTMLString("", baseURL: nil)
            }
        }
        context.coordinator.applyPresentation(to: view, zoom: workspace.previewZoom, dark: previewDark)
        context.coordinator.restoreReading(in: view)
        if !view.isLoading {
            let dark = scheme == .dark
            view.evaluateJavaScript(
                "window.leftblankSetChrome?.('\(dark ? "#171a1d" : "#fafafa")', '\(dark ? "dark" : "light")'); window.leftblankSetDark?.(\(previewDark ? "true" : "false"));",
                completionHandler: nil,
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(workspace)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "leftblankPreviewReady")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "leftblankPreviewReading")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "leftblankPreviewError")
        view.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var workspace: TabletWorkspace
        var url: URL?
        private var recovered = false
        private var restoringID: UUID?
        private var appliedZoom: CGFloat?
        private var appliedDark: Bool?
        init(_ workspace: TabletWorkspace) {
            self.workspace = workspace
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url == url else {
                return
            }
            if message.name == "leftblankPreviewReady" {
                workspace.previewReady = true
                workspace.previewIssue = nil
                workspace.sendPendingPreviewNavigation()
                if let view = message.webView {
                    applyPresentation(
                        to: view,
                        zoom: workspace.previewZoom,
                        dark: UserDefaults.standard.bool(forKey: "iPadPreviewDark"),
                    )
                    restoreReading(in: view)
                }
            } else if message.name == "leftblankPreviewReading", let body = message.body as? [String: Any] {
                receiveReading(body)
            } else if let error = message.body as? String {
                workspace.previewIssue = error
            }
        }

        func receiveReading(_ body: [String: Any]) {
            if body["kind"] as? String == "manualScroll" {
                workspace.previewReading.pauseFollowing()
            }
            if let value = body["anchor"],
               let anchor = PreviewReadingAnchor(message: value)
            {
                workspace.previewReading.observe(anchor)
            }
        }

        func applyPresentation(to view: WKWebView, zoom: CGFloat, dark: Bool) {
            guard !view.isLoading, appliedZoom != zoom || appliedDark != dark else {
                return
            }
            view.evaluateJavaScript("""
            (() => {
                const container = document.getElementById('typst-container');
                if (!container) return false;
                if (container.style.width !== '\(zoom * 100)%') window.leftblankPrepareResize?.();
                container.style.width = '\(zoom * 100)%';
                window.leftblankSetDark?.(\(dark ? "true" : "false"));
                window.dispatchEvent(new Event('resize'));
                return true;
            })()
            """) { [weak self] result, _ in
                if result as? Bool == true {
                    self?.appliedZoom = zoom
                    self?.appliedDark = dark
                }
            }
        }

        func restoreReading(in view: WKWebView) {
            guard !view.isLoading, let request = workspace.previewReading.restore,
                  restoringID != request.id
            else {
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
                        workspace.previewReading.didRestore(request.id)
                    }
                }
        }

        func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            workspace.previewReady = false
            appliedZoom = nil
            appliedDark = nil
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation?) {
            applyPresentation(
                to: view,
                zoom: workspace.previewZoom,
                dark: UserDefaults.standard.bool(forKey: "iPadPreviewDark"),
            )
            restoreReading(in: view)
        }

        func webView(
            _ view: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation?,
            withError error: Error,
        ) {
            workspace.previewIssue = error.localizedDescription
        }

        func webView(_ view: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            workspace.previewIssue = error.localizedDescription
        }

        func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
            if !recovered {
                recovered = true
                view.reload()
            } else {
                workspace.previewIssue = L10n.text("Preview stopped unexpectedly. Reconnect typesetting to try again.")
            }
        }
    }
}

@MainActor final class TabletPreviewWebView: WKWebView {
    var onWillLoad: (() -> Void)?
    override func load(_ request: URLRequest) -> WKNavigation? {
        onWillLoad?()
        return super.load(request)
    }

    override func reload() -> WKNavigation? {
        onWillLoad?()
        return super.reload()
    }

    private var lastSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, lastSize != bounds.size else {
            return
        }
        lastSize = bounds.size
        // Hidden panes begin with no viewport; resizing must refit the actual
        // SVG page when preview is revealed or the iPad window changes size.
        evaluateJavaScript("window.dispatchEvent(new Event('resize'));", completionHandler: nil)
    }
}

struct TabletPreviewReadingControls: View {
    @ObservedObject var session: PreviewReadingSession
    var showFollow = true
    var onReturn: () -> Void

    var body: some View {
        if showFollow {
            Toggle(isOn: $session.followsWriting) {
                Label(L10n.text("Follow Writing"), systemImage: "cursorarrow.motionlines")
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            .accessibilityIdentifier("preview-follow")
            .frame(minWidth: 44, minHeight: 44)
        }
        Button { session.returnToReading()
            onReturn()
        } label: {
            Label(L10n.text("Return to Reading"), systemImage: "arrow.uturn.backward")
        }
        .labelStyle(.iconOnly)
        .accessibilityIdentifier("preview-return")
        .frame(minWidth: 44, minHeight: 44)
        .disabled(session.returnAnchor == nil)
    }
}
