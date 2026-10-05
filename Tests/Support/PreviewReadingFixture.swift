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
    #if os(macOS)
        private let window: NSWindow
    #else
        private let window: UIWindow
    #endif

    public init(script: String) {
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
            window = UIWindow(frame: web.frame)
            let controller = UIViewController()
            controller.view.addSubview(web)
            window.rootViewController = controller
            window.isHidden = false
        #endif
        web.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;} #typst-container-main{width:100%;height:100%;overflow:auto;}
        #typst-container{width:100%;} .typst-page-inner{width:100%;aspect-ratio:3/5;margin-bottom:20px;background:white;}</style></head>
        <body><div id="typst-container-main"><div id="typst-container"><div class="typst-doc">
        <div class="typst-page-inner">One</div><div class="typst-page-inner">Two</div><div class="typst-page-inner">Three</div>
        </div></div></div></body></html>
        """, baseURL: nil)
    }

    public func ready() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if !web.isLoading,
               await (try? web.evaluateJavaScript("typeof window.leftblankRestoreReading === 'function'")) as? Bool ==
               true
            {
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw NSError(domain: "PreviewReadingFixture", code: 1)
    }

    public func close() {
        web.stopLoading()
        web.removeFromSuperview()
        #if os(macOS)
            window.close()
        #else
            window.isHidden = true
            window.rootViewController = nil
        #endif
    }
}
