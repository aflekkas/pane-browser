// spec: §5
import AppKit
import WebKit

/// Window capture for visual verification.
///
/// Three mechanisms, because the obvious ones do not work for the thing that
/// matters most. All validate the result before claiming success — a capture
/// that "succeeded" with a non-nil bitmap but is one flat colour proves nothing
/// (harness design §7.3).
@MainActor
public enum Capture {

    /// TCC-free composite capture: AppKit chrome via `displayIgnoringOpacity`,
    /// web content via `WKWebView.takeSnapshot`, drawn into one bitmap.
    ///
    /// This is the pairing that finally works, and each half exists because the
    /// other half cannot do its job:
    ///
    /// - `cacheDisplay` skips the layer tree the window server composites for
    ///   `NSScrollView`, so the sidebar comes out flat. `displayIgnoringOpacity`
    ///   re-draws the hierarchy directly into the given context instead of
    ///   sampling cached layer contents, which is why the scroll view survives —
    ///   measured, not theorised: 341 distinct colours in the sidebar region vs
    ///   1 for `cacheDisplay` on the same window (docs/api-notes/appkit.md).
    /// - No in-process draw can reach `WKWebView` pixels: they live in the
    ///   WebContent process's remote layer tree. `takeSnapshot` is WebKit's own
    ///   sanctioned export of exactly those pixels.
    ///
    /// Neither half consults the window server, so this works with the window
    /// occluded or never ordered on screen — which is what makes it runnable
    /// from a gate with a terminal frontmost, launched as a bare binary, with
    /// no Screen Recording grant and no LaunchServices activation dance.
    public static func composite(_ w: NSWindow, to path: String) async -> Bool {
        guard let view = w.contentView else { return false }
        view.layoutSubtreeIfNeeded()

        let size = view.bounds.size
        // 1x deliberately: displayIgnoringOpacity draws at the context's own
        // scale, not the window's backing scale (a 2x bitmap comes out with the
        // UI in one quarter) — and a golden that depends on the runner's screen
        // density would diff against itself across machines anyway.
        guard size.width > 1, size.height > 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width),
                                         pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }

        view.displayIgnoringOpacity(view.bounds, in: ctx)

        // Overlay every attached web view at its own frame. Only the selected
        // tab's view is in the hierarchy, but walking rather than asking the
        // controller keeps the harness ignorant of how tabs are managed.
        for web in webViews(under: view) where !web.isHiddenOrHasHiddenAncestor {
            // Snapshotting mid-load hands back the page's bare background — a
            // flat fill that looks exactly like a broken capture. Bounded, so a
            // page that never settles degrades the image instead of hanging the
            // gate.
            for _ in 0..<40 where web.isLoading {
                try? await Task.sleep(for: .milliseconds(250))
            }
            // TIFF data crosses the continuation rather than NSImage because
            // Data is Sendable and the image is not; the cost is one encode of
            // a single frame.
            guard let data = await snapshotData(web), let img = NSImage(data: data) else {
                FileHandle.standardError.write(Data(
                    "capture: takeSnapshot produced nothing for \(web.url?.absoluteString ?? "?")\n".utf8))
                continue
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            img.draw(in: web.convert(web.bounds, to: view))
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.flushGraphics()

        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return false }
        // requireSidebar: a composite whose left edge is flat means the chrome
        // draw silently regressed to the cacheDisplay failure mode, even if the
        // web overlay keeps the whole-image check green.
        return report(rep, path: path, via: "composite", requireSidebar: true)
    }

    /// Capture by CGWindowID via `screencapture -l`.
    ///
    /// `NSWindow.windowNumber` **is** the CGWindowID, so the app names its own
    /// window. That removes the "whichever app is frontmost" ambiguity which
    /// silently captured a *different application* twice while this was being
    /// built — a failure that would have been invisible in an unattended run.
    ///
    /// Kept as the one capture that shows the REAL pixels the window server
    /// composited — traffic lights, vibrancy, layer effects — for manual parity
    /// checks. Not wired into the gate: the TCC grant lands on the *responsible
    /// process*, which is Pane itself under `open` and therefore never granted
    /// on an unattended machine, and the window must genuinely be frontmost and
    /// unoccluded to have painted. `composite(_:to:)` has neither dependency.
    public static func windowByID(_ w: NSWindow, to path: String) -> Bool {
        w.orderFront(nil)
        w.displayIfNeeded()
        let id = w.windowNumber
        guard id > 0 else { return false }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l" + String(id), path]
        do { try p.run() } catch { return false }
        p.waitUntilExit()

        guard p.terminationStatus == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count > 1024,
              let rep = NSBitmapImageRep(data: data) else {
            FileHandle.standardError.write(Data(
                "capture: screencapture failed — Screen Recording permission?\n".utf8))
            return false
        }
        return report(rep, path: path, via: "windowID")
    }

    /// In-app capture via `cacheDisplay`. Needs no TCC permission, renders the
    /// WKWebView content correctly — and leaves the sidebar blank, because it
    /// samples layer contents the offscreen scroll view never gets. Kept only
    /// so the failure stays reproducible; use `composite(_:to:)` for goldens.
    public static func window(_ w: NSWindow, to path: String) -> Bool {
        guard let view = w.contentView else { return false }
        // A window never ordered on screen has an undrawn view hierarchy, and
        // cacheDisplay on it yields a flat fill.
        w.orderFront(nil)
        w.displayIfNeeded()
        view.display()

        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return false }
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return false }
        return report(rep, path: path, via: "cacheDisplay")
    }

    private static func webViews(under root: NSView) -> [WKWebView] {
        var found: [WKWebView] = []
        var stack = [root]
        while let v = stack.popLast() {
            if let web = v as? WKWebView { found.append(web); continue }
            stack.append(contentsOf: v.subviews)
        }
        return found
    }

    private static func snapshotData(_ web: WKWebView) async -> Data? {
        await withCheckedContinuation { cont in
            web.takeSnapshot(with: nil) { img, _ in
                cont.resume(returning: img?.tiffRepresentation)
            }
        }
    }

    private static func report(_ rep: NSBitmapImageRep, path: String, via: String,
                               requireSidebar: Bool = false) -> Bool {
        let uniform = isUniform(rep)
        // The default 232pt sidebar is 18% of the 1280pt window; sampling the
        // left 15% stays inside it even with the divider counted.
        let sidebarColors = distinctColors(
            rep, xRange: 0..<max(1, Int(Double(rep.pixelsWide) * 0.15)), cap: 8)
        let sidebarBlank = sidebarColors < 6
        let line = "{\"rec\":\"capture\",\"path\":\"\(path)\",\"w\":\(rep.pixelsWide),"
            + "\"h\":\(rep.pixelsHigh),\"uniform\":\(uniform),"
            + "\"sidebar_colors\":\(sidebarColors),\"via\":\"\(via)\"}\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        return !uniform && !(requireSidebar && sidebarBlank)
    }

    /// Samples a grid rather than every pixel — enough to tell "real UI" from
    /// "one flat colour" without walking millions of pixels.
    private static func isUniform(_ rep: NSBitmapImageRep) -> Bool {
        distinctColors(rep, xRange: 0..<rep.pixelsWide, cap: 16) < 16
    }

    private static func distinctColors(_ rep: NSBitmapImageRep,
                                       xRange: Range<Int>, cap: Int) -> Int {
        var seen = Set<UInt32>()
        let stepX = max(1, xRange.count / 64)
        let stepY = max(1, rep.pixelsHigh / 64)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: xRange.lowerBound, to: xRange.upperBound, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let r = UInt32(c.redComponent * 255)
                let g = UInt32(c.greenComponent * 255)
                let b = UInt32(c.blueComponent * 255)
                seen.insert(r << 16 | g << 8 | b)
                if seen.count >= cap { return seen.count }
            }
        }
        return seen.count
    }
}
