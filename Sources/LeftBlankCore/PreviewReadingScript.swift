import Foundation

public extension PreviewScripts {
    /// Keep this script shared by both native clients. Renderer source jumps
    /// cancel pending restores; user scrolls cancel restores and follow mode.
    static var reading: String {
        #"""
        ;(() => {
            const scroll = () => document.getElementById('typst-container-main');
            const pages = () => {
                const rects = [...document.querySelectorAll('.typst-doc > .typst-page-inner')];
                return rects.length ? rects : [...document.querySelectorAll('.typst-doc > g.typst-page')];
            };
            const send = (kind, anchor) => window.webkit?.messageHandlers?.leftblankPreviewReading?.postMessage({kind, anchor});
            const clamp = value => Math.max(0, Math.min(1, value));
            let lastAnchor = null, restoring = false, generation = 0, scrollTimer, suppressUntil = 0;
            const capture = () => {
                const host = scroll();
                if (!host || !host.clientWidth || !host.clientHeight) return null;
                const viewport = host.getBoundingClientRect();
                const viewportY = .2;
                const top = viewport.top + host.clientHeight * viewportY;
                const list = pages();
                let page = list.findIndex(p => p.getBoundingClientRect().bottom > top);
                if (page < 0) page = list.length - 1;
                const bounds = list[page]?.getBoundingClientRect();
                if (!bounds || bounds.width <= 0 || bounds.height <= 0) return null;
                return {page, x: clamp((viewport.left + host.clientWidth / 2 - bounds.left) / bounds.width),
                    y: clamp((top - bounds.top) / bounds.height), viewportY};
            };
            const report = () => {
                if (restoring) return;
                const anchor = capture();
                if (anchor) { lastAnchor = anchor; send('anchor', anchor); }
            };
            const cancel = () => { generation++; restoring = false; };
            const clearRendererAnchor = () => {
                for (const doc of document.getElementById('typst-container')?.documents || []) {
                    doc?.impl?.clearSvgResizeAnchor?.();
                }
            };
            const apply = anchor => {
                const host = scroll(), list = pages();
                if (!host || !host.clientWidth || !host.clientHeight || !list.length) return false;
                const bounds = list[Math.min(anchor.page, list.length - 1)].getBoundingClientRect();
                if (!bounds.width || !bounds.height) return false;
                const viewport = host.getBoundingClientRect();
                host.scrollTo({top: host.scrollTop + bounds.top + bounds.height * anchor.y - viewport.top - host.clientHeight * anchor.viewportY,
                    left: host.scrollLeft + bounds.left + bounds.width * anchor.x - viewport.left - host.clientWidth / 2,
                    behavior: 'instant'});
                return true;
            };
            const preserve = anchor => {
                if (!anchor || performance.now() < suppressUntil) return;
                cancel();
                restoring = true;
                const token = generation;
                // Bounded passes cover renderer resize without an endless scroll lock.
                for (const delay of [40, 160, 400]) setTimeout(() => {
                    if (token !== generation) return;
                    apply(anchor);
                    if (delay === 400) { restoring = false; report(); }
                }, delay);
            };
            window.leftblankCaptureReading = () => { report(); return lastAnchor; };
            window.leftblankPrepareResize = () => preserve(lastAnchor || capture());
            window.leftblankRestoreReading = anchor => {
                if (!anchor || !Number.isInteger(anchor.page) || anchor.page < 0 ||
                    !['x', 'y', 'viewportY'].every(k => Number.isFinite(anchor[k]) && anchor[k] >= 0 && anchor[k] <= 1)) return false;
                suppressUntil = 0;
                clearRendererAnchor();
                if (!apply(anchor)) return false;
                preserve(anchor);
                return true;
            };
            window.leftblankSourceJump = () => {
                cancel();
                lastAnchor = null;
                suppressUntil = performance.now() + 700;
                const token = generation;
                setTimeout(() => { if (token === generation) report(); }, 450);
            };
            const userScroll = event => {
                if (!event.isTrusted) return;
                cancel();
                suppressUntil = 0;
                clearRendererAnchor();
                send('manualScroll');
            };
            document.addEventListener('wheel', userScroll, {passive: true, capture: true});
            document.addEventListener('touchmove', userScroll, {passive: true, capture: true});
            document.addEventListener('keydown', event => {
                if (['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(event.key)) userScroll(event);
            }, true);
            document.addEventListener('pointerdown', report, true);
            document.addEventListener('scroll', () => {
                clearTimeout(scrollTimer);
                scrollTimer = setTimeout(report, 50);
            }, true);
            window.addEventListener('resize', () => preserve(lastAnchor || capture()));
            // Compilation can replace page geometry without changing the viewport.
            const observer = new MutationObserver(records => {
                if (records.some(record => ['typst-doc', 'typst-page-inner', 'typst-page'].some(name => record.target.classList?.contains(name)))) {
                    if (!restoring) preserve(lastAnchor);
                    if (!lastAnchor) report();
                }
            });
            observer.observe(document.body, {childList: true, subtree: true, attributes: true, attributeFilter: ['transform', 'height', 'width', 'viewBox', 'y', 'x']});
            report();
        })();
        """#
    }
}
