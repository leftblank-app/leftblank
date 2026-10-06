import Foundation

public enum PreviewScripts {
    /// Documents up to this many pages are painted completely, so scrolling
    /// never reveals an unpainted page. Longer documents render by viewport.
    public static let fullRenderingPageLimit = 20
    /// Viewport repaint cadence while a long document scrolls.
    public static let scrollRepaintIntervalMilliseconds = 100

    public static func setup(canvas: String, scheme: String) -> String {
        """
        // Tinymist paints both the body and page gaps with this variable using
        // !important. Setting body.style.background alone cannot override it.
        const chromeStyle = document.createElement('style');
        chromeStyle.textContent = `
            :root { --typst-preview-background-color: var(--leftblank-canvas) !important; }
            html, body, #typst-container-main, #typst-app {
                background-color: var(--leftblank-canvas) !important;
            }
        `;
        document.head.appendChild(chromeStyle);
        window.leftblankSetChrome = (background, scheme) => {
            document.documentElement.style.setProperty('--leftblank-canvas', background);
            document.documentElement.style.colorScheme = scheme;
        };
        window.leftblankSetChrome('\(canvas)', '\(scheme)');
        // Tinymist 0.15.8 mixes off-screen canvas pages into SVG foreignObjects.
        // In WebKit these create enormous backing layers for book-length SVGs.
        // Keep its viewport SVG renderer, without the optional canvas fallback.
        const container = document.getElementById('typst-container');
        const configured = new WeakSet();
        // Partial rendering paints only pages intersecting the viewport and
        // repaints 500 ms after scrolling stops, so pages scrolled into view stay
        // blank while scrolling. Paint short documents completely. Longer ones
        // keep partial rendering, with one viewport painted ahead on each side
        // and repaints while scrolling instead of only after it stops.
        const fullRenderingPageLimit = \(fullRenderingPageLimit);
        const scrollRepaintInterval = \(scrollRepaintIntervalMilliseconds);
        const pageCount = impl => {
            try {
                const pages = impl.kModule?.retrievePagesInfo?.();
                return Array.isArray(pages) ? pages.length : Infinity;
            } catch { return Infinity; }
        };
        const configureViewportRendering = impl => {
            let requested = !!impl.partialRendering;
            Object.defineProperty(impl, 'partialRendering', {
                configurable: true,
                get: () => requested && pageCount(impl) > fullRenderingPageLimit,
                set: value => { requested = !!value; }
            });
            if (typeof impl.statSvgFromDom === 'function') {
                const stat = impl.statSvgFromDom;
                impl.statSvgFromDom = function(...args) {
                    const area = stat.apply(this, args);
                    return {...area, top: area.top - area.height, height: area.height * 3};
                };
            }
        };
        let scrollRepaint;
        document.getElementById('typst-container-main')?.addEventListener('scroll', () => {
            if (scrollRepaint !== undefined) return;
            scrollRepaint = setTimeout(() => {
                scrollRepaint = undefined;
                for (const doc of container?.documents || []) {
                    if (doc?.impl?.partialRendering) doc.impl.addViewportChange?.();
                }
            }, scrollRepaintInterval);
        }, {passive: true});
        const configureDocument = doc => {
            const impl = doc?.impl;
            if (!impl || configured.has(impl)) return;
            configured.add(impl);
            if (impl.renderMode === 'svg' && 'feat$canvas' in impl) impl.feat$canvas = false;
            configureViewportRendering(impl);
            // A resize anchor lives across several rendering passes. An explicit
            // source jump must supersede it, or the next pass restores the old page.
            if (typeof impl.scrollTo === 'function' && typeof impl.clearSvgResizeAnchor === 'function') {
                const scrollTo = impl.scrollTo;
                impl.scrollTo = function(...args) {
                    window.leftblankSourceJump?.();
                    this.clearSvgResizeAnchor();
                    return scrollTo.apply(this, args);
                };
            }
        };
        const watchDocuments = documents => {
            if (!Array.isArray(documents)) return documents;
            documents.forEach(configureDocument);
            const push = documents.push;
            documents.push = function(...docs) { docs.forEach(configureDocument); return push.apply(this, docs); };
            return documents;
        };
        if (container) {
            let documents = watchDocuments(container.documents);
            Object.defineProperty(container, 'documents', {
                configurable: true,
                get: () => documents,
                set: value => { documents = watchDocuments(value); }
            });
        }
        const checkReady = () => {
            const bounds = document.querySelector('.typst-doc > .typst-page-inner, .typst-doc > g.typst-page')?.getBoundingClientRect();
            if (bounds && bounds.width > 0 && bounds.height > 0) {
                readyObserver.disconnect();
                window.webkit.messageHandlers.leftblankPreviewReady.postMessage('ready');
            }
        };
        const readyObserver = new MutationObserver(checkReady);
        readyObserver.observe(document.body, {childList: true, subtree: true});
        checkReady();
        window.addEventListener('resize', checkReady);
        window.leftblankSetDark = (dark) => {
            window.leftblankPreviewDark = dark;
            const root = document.getElementById('typst-app');
            if (!root) return;
            if (root.classList.contains('invert-colors') !== dark) root.classList.toggle('invert-colors', dark);
            if (!root.classList.contains('normal-image')) root.classList.add('normal-image');
        };
        const root = document.getElementById('typst-app');
        if (root) new MutationObserver(() => window.leftblankSetDark(!!window.leftblankPreviewDark))
            .observe(root, {attributes: true, attributeFilter: ['class']});
        """ + reading
    }
}
