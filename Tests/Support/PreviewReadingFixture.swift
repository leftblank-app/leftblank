import Foundation
import WebKit
#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Exercises the production JavaScript in each platform's actual WebKit.
/// The deterministic pages need neither a renderer process nor network access.
@MainActor
public final class PreviewReadingFixture {
    public let web: WKWebView
    private let navigation = PreviewFixtureNavigation()
    #if os(macOS)
        private let window: NSWindow
    #else
        private let window: UIWindow
        private weak var previousKeyWindow: UIWindow?
    #endif

    public init(script: String, lazySVG: Bool = false) throws {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
        ))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 500), configuration: config)
        #if os(macOS)
            _ = NSApplication.shared
            window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = web
            web.configuration.preferences.inactiveSchedulingPolicy = .none
        #else
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
            else {
                throw NSError(domain: "PreviewReadingFixture", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The WebKit fixture requires a foreground window scene.",
                ])
            }
            previousKeyWindow = scene.keyWindow
            window = UIWindow(windowScene: scene)
            window.frame = web.frame
            let controller = UIViewController()
            controller.view.addSubview(web)
            window.rootViewController = controller
            window.makeKeyAndVisible()
        #endif
        let pages = lazySVG ? """
        <svg class="typst-doc" width="100%" viewBox="0 0 600 3000">
        <g class="typst-page" data-page-width="600" data-page-height="1000" transform="translate(0,0)"></g>
        <g class="typst-page" data-page-width="600" data-page-height="1000" transform="translate(0,1000)"></g>
        <g class="typst-page" data-page-width="600" data-page-height="1000" transform="translate(0,2000)"></g>
        </svg>
        """ : """
        <div class="typst-doc"><div class="typst-page-inner">One</div><div class="typst-page-inner">Two</div><div class="typst-page-inner">Three</div></div>
        """
        web.navigationDelegate = navigation
        web.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;} #typst-container-main{width:100%;height:100%;overflow:auto;}
        #typst-container{width:100%;} .typst-page-inner{width:100%;aspect-ratio:3/5;margin-bottom:20px;background:white;}</style></head>
        <body><div id="typst-container-main"><div id="typst-container">\(pages)</div></div></body></html>
        """, baseURL: nil)
    }

    public func ready() async throws {
        // A cold simulator can take longer than ten seconds to start WebKit.
        // Match the UI suite's load budget, but report navigation failures at once.
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if let error = navigation.error {
                throw error
            }
            if navigation.finished {
                guard try await web.evaluateJavaScript("typeof window.leftblankRestoreReading === 'function'")
                    as? Bool == true
                else {
                    throw NSError(domain: "PreviewReadingFixture", code: 3, userInfo: [
                        NSLocalizedDescriptionKey: "The loaded fixture did not install the production reading script.",
                    ])
                }
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw NSError(domain: "PreviewReadingFixture", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "WebKit fixture did not finish navigation; loading=\(web.isLoading), " +
                "attached=\(web.window != nil)",
        ])
    }

    public func close() {
        web.stopLoading()
        web.removeFromSuperview()
        #if os(macOS)
            window.close()
        #else
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        #endif
    }
}

@MainActor
private final class PreviewFixtureNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?

    func webView(_: WKWebView, didFinish _: WKNavigation?) {
        finished = true
    }

    func webView(_: WKWebView, didFail _: WKNavigation?, withError error: Error) {
        self.error = error
    }

    func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: Error) {
        self.error = error
    }

    func webViewWebContentProcessDidTerminate(_: WKWebView) {
        error = NSError(domain: "PreviewReadingFixture", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "The fixture's WebKit content process terminated.",
        ])
    }
}

public extension PreviewReadingFixture {
    /// Draws a heading as Tinymist's SVG renderer does, one text group with a
    /// selection layer per run, presses a pointer on its first run and returns
    /// the click the reading script reports. The second run's selection layer
    /// overflows onto the first, as WebKit lets oversized layers do, so the hit
    /// element is not the run under the pointer.
    func pressHeadingRun() async throws -> [String: Any] {
        let recorder = PreviewMessageRecorder()
        web.configuration.userContentController.add(recorder, name: "leftblankPreviewReading")
        defer { web.configuration.userContentController.removeScriptMessageHandler(forName: "leftblankPreviewReading") }
        let layer = #"<foreignObject width="200" height="20" style="overflow: visible">"#
        _ = try await web.evaluateJavaScript("""
        (() => {
            const page = document.querySelector('.typst-doc > g.typst-page');
            page.innerHTML = `
            <g class="typst-text" transform="translate(50,100)"><rect width="80" height="20"/>
            <foreignObject width="80" height="20"><div xmlns="http://www.w3.org/1999/xhtml" class="tsel">LB-001 </div></foreignObject></g>
            <g class="typst-text" transform="translate(140,100)"><rect width="200" height="20"/>
            \(layer)<div xmlns="http://www.w3.org/1999/xhtml" class="tsel" style="margin-left: -150px; width: 400px; height: 60px">大文档检查</div></foreignObject></g>
            <g class="typst-text" transform="translate(50,300)"><rect width="80" height="20"/>
            <foreignObject width="80" height="20"><div xmlns="http://www.w3.org/1999/xhtml" class="tsel">Elsewhere</div></foreignObject></g>`;
            const box = page.querySelector('.typst-text rect').getBoundingClientRect();
            const x = box.left + 5, y = box.top + box.height / 2;
            document.elementFromPoint(x, y).dispatchEvent(new PointerEvent('pointerdown', {bubbles: true, clientX: x, clientY: y}));
            return true;
        })()
        """)
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let click = recorder.messages.first(where: { $0["kind"] as? String == "click" }) {
                return click
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw NSError(domain: "PreviewReadingFixture", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "The reading script did not report the pressed run.",
        ])
    }
}

@MainActor
private final class PreviewMessageRecorder: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] {
            messages.append(body)
        }
    }
}
