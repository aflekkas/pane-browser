import Foundation

/// The viewport must remain at its clamped target across rendered frames, not
/// merely immediately after scrollTo. WebKit can still apply native restoration
/// after didFinish and layout may change as a hidden view becomes visible.
enum BrowserLifecycleViewportRestore {
    static func script(id: UUID, urlLiteral: String, scrollX: Double, scrollY: Double) -> String {
        """
        (() => {
          const operation = { id: "\(id.uuidString)", frame: null };
          globalThis.__paneLifecycleViewportRestore = operation;
          const requestedX = \(scrollX), requestedY = \(scrollY);
          let frames = 0, stable = 0, previous = null, applied = false;
          const sample = () => {
            const root = document.scrollingElement || document.documentElement;
            const extentX = Math.max(0, root.scrollWidth - root.clientWidth);
            const rtl = getComputedStyle(root).direction === 'rtl';
            const minX = rtl ? -extentX : 0, maxX = rtl ? 0 : extentX;
            const maxY = Math.max(0, root.scrollHeight - root.clientHeight);
            return { url: location.href, scrollX, scrollY, requestedX, requestedY,
              targetX: Math.min(maxX, Math.max(minX, requestedX)),
              targetY: Math.min(maxY, Math.max(0, requestedY)),
              width: root.clientWidth, height: root.clientHeight, innerWidth, innerHeight,
              documentWidth: root.scrollWidth, documentHeight: root.scrollHeight,
              visibility: document.visibilityState, rtl, time: performance.now(), frames,
              restoreID: operation.id };
          };
          const report = (phase, value) => window.webkit.messageHandlers.paneLifecycleScroll.postMessage({
            ...value, phase, stable
          });
          const close = () => {
            document.removeEventListener('visibilitychange', visible);
            if (globalThis.__paneLifecycleViewportRestore === operation)
              delete globalThis.__paneLifecycleViewportRestore;
          };
          operation.cancel = close;
          const next = () => { operation.frame = requestAnimationFrame(step); };
          const visible = () => {
            if (document.visibilityState === 'visible') {
              cancelAnimationFrame(operation.frame);
              next();
            }
          };
          const step = () => {
            if (globalThis.__paneLifecycleViewportRestore !== operation) { close(); return; }
            const value = sample();
            if (location.href !== \(urlLiteral)) { close(); report('abandoned', value); return; }
            // A snapshot can render a hidden page. That is not a usable viewport.
            if (value.visibility !== 'visible') {
              stable = 0; previous = null; report('hidden', value); return;
            }
            frames++;
            if (frames > 120) { close(); report('abandoned', value); return; }
            if (value.width <= 0 || value.height <= 0) { stable = 0; next(); return; }
            const layout = [value.width, value.height, value.documentWidth, value.documentHeight].join(':');
            const matched = Math.abs(value.scrollX - value.targetX) < 1 && Math.abs(value.scrollY - value.targetY) < 1;
            if (!applied || !matched || previous !== layout) {
              stable = 0;
              previous = layout;
              applied = true;
              scrollTo({ left: value.targetX, top: value.targetY, behavior: 'instant' });
              report('applied', sample());
            } else {
              stable++;
              if (stable >= 3) { close(); report('settled', value); return; }
            }
            next();
          };
          document.addEventListener('visibilitychange', visible);
          report('scheduled', sample());
          next();
        })(); true;
        """
    }

    /// Check the acknowledged position against the requested viewport and its
    /// actual scrollable range, rather than accepting an arbitrary reported zero.
    static func accepts(_ body: [String: Any], requestedX: Double, requestedY: Double) -> Bool {
        guard body["phase"] as? String == "settled", body["visibility"] as? String == "visible",
              let stable = body["stable"] as? Int, stable >= 3,
              let width = body["width"] as? Double, let height = body["height"] as? Double,
              let documentWidth = body["documentWidth"] as? Double,
              let documentHeight = body["documentHeight"] as? Double,
              let scrollX = body["scrollX"] as? Double, let scrollY = body["scrollY"] as? Double,
              [width, height, documentWidth, documentHeight, scrollX, scrollY].allSatisfy(\.isFinite),
              width > 0, height > 0 else { return false }
        let extentX = max(0, documentWidth - width)
        let rtl = body["rtl"] as? Bool == true
        let targetX = min(rtl ? 0 : extentX, max(rtl ? -extentX : 0, requestedX))
        let targetY = min(max(0, documentHeight - height), max(0, requestedY))
        return abs(scrollX - targetX) < 1 && abs(scrollY - targetY) < 1
    }
}
