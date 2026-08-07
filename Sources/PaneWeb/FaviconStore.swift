// spec: §2
import Foundation
import AppKit

/// spec §2 — "Favicons and screenshots go to a content-addressed blob directory
/// on disk, not the DB."
///
/// Without this the app re-fetches every icon on every launch: the sidebar
/// starts as a column of grey globes and fills in over a second or two, and a
/// restored session hits the network for something it already knew.
///
/// Content-addressed by host so two tabs on the same site share one blob.
public enum FaviconStore {

    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("Pane/favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Host, not full URL: one icon per site, and a path is not part of a
    /// site's identity for this purpose.
    static func filename(for host: String) -> String {
        // Hosts are already filesystem-safe apart from case; normalise rather
        // than hash, so the cache is inspectable by a human.
        host.lowercased().replacingOccurrences(of: "/", with: "_") + ".png"
    }

    public static func load(host: String) -> NSImage? {
        let url = directory.appendingPathComponent(filename(for: host))
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    public static func save(_ image: NSImage, host: String) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: directory.appendingPathComponent(filename(for: host)))
    }

    /// Everything on disk, so the in-memory cache can be warmed in one pass at
    /// launch rather than lazily as rows scroll into view.
    public static func loadAll() -> [String: NSImage] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return [:]
        }
        var out: [String: NSImage] = [:]
        for name in names where name.hasSuffix(".png") {
            let host = String(name.dropLast(4))
            if let image = load(host: host) { out[host] = image }
        }
        return out
    }

    /// Bounded so a long-lived install does not accumulate icons for sites
    /// visited once. Called at launch; cheap because it only stats.
    public static func prune(keeping limit: Int = 400) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path),
              names.count > limit else { return }
        let dated = names.compactMap { name -> (String, Date)? in
            let p = directory.appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let d = attrs[.modificationDate] as? Date else { return nil }
            return (name, d)
        }.sorted { $0.1 > $1.1 }
        for (name, _) in dated.dropFirst(limit) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
