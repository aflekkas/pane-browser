// spec: §5
import AppKit

/// Window capture for visual verification.
///
/// Two mechanisms, because the obvious one does not work for the thing that
/// matters most. Both validate the result before claiming success — a capture
/// that "succeeded" with a non-nil bitmap but is one flat colour proves nothing
/// (harness design §7.3).
@MainActor
public enum Capture {

    /// Capture by CGWindowID via `screencapture -l`.
    ///
    /// `NSWindow.windowNumber` **is** the CGWindowID, so the app names its own
    /// window. That removes the "whichever app is frontmost" ambiguity which
    /// silently captured a *different application* twice while this was being
    /// built — a failure that would have been invisible in an unattended run.
    ///
    /// This is the ONE place a TCC permission (Screen Recording) is needed, and
    /// it earns it: `cacheDisplay` cannot capture layer-backed AppKit views,
    /// and `NSScrollView` is layer-backed by AppKit no matter what the app
    /// asks for — so the sidebar, the main thing goldens exist to check, comes
    /// out blank. See `docs/api-notes/appkit.md`.
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

    /// In-app capture. Needs no TCC permission at all, but does not traverse
    /// layer-backed subviews — it renders the WKWebView content correctly and
    /// leaves the sidebar blank, which is the opposite of the failure the
    /// research predicted. Kept for the content area and for environments with
    /// no Screen Recording grant.
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

    private static func report(_ rep: NSBitmapImageRep, path: String, via: String) -> Bool {
        let uniform = isUniform(rep)
        let line = "{\"rec\":\"capture\",\"path\":\"\(path)\",\"w\":\(rep.pixelsWide),"
            + "\"h\":\(rep.pixelsHigh),\"uniform\":\(uniform),\"via\":\"\(via)\"}\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        return !uniform
    }

    /// Samples a grid rather than every pixel — enough to tell "real UI" from
    /// "one flat colour" without walking millions of pixels.
    private static func isUniform(_ rep: NSBitmapImageRep) -> Bool {
        var seen = Set<UInt32>()
        let stepX = max(1, rep.pixelsWide / 64)
        let stepY = max(1, rep.pixelsHigh / 64)
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let r = UInt32(c.redComponent * 255)
                let g = UInt32(c.greenComponent * 255)
                let b = UInt32(c.blueComponent * 255)
                seen.insert(r << 16 | g << 8 | b)
                if seen.count >= 16 { return false }
            }
        }
        return true
    }
}
