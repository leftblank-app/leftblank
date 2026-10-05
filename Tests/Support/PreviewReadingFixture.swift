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
        web.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;} #typst-container-main{width:100%;height:100%;overflow:auto;}
        #typst-container{width:100%;} .typst-page-inner{width:100%;aspect-ratio:3/5;margin-bottom:20px;background:white;}</style></head>
        <body><div id="typst-container-main"><div id="typst-container">\(pages)</div></div></body></html>
        """, baseURL: nil)
    }

    public func ready() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        var scriptError: Error?
        while ContinuousClock.now < deadline {
            if !web.isLoading {
                do {
                    if try await web.evaluateJavaScript("typeof window.leftblankRestoreReading === 'function'")
                        as? Bool == true
                    {
                        return
                    }
                } catch { scriptError = error }
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw NSError(domain: "PreviewReadingFixture", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "WebKit fixture did not become ready; loading=\(web.isLoading), " +
                "attached=\(web.window != nil), script error=\(scriptError?.localizedDescription ?? "none")",
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
