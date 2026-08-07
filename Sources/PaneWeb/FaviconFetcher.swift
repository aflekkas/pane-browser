// spec: §2
import Foundation
import AppKit

/// spec §2 stores `favicon_blob` per tab. This fetches it.
///
/// Deliberately dumb: one request per origin, cached in memory, no parsing of
/// `<link rel="icon">` from the DOM. `/favicon.ico` plus Google's S2 endpoint
/// as a fallback covers effectively every site, and doing it properly would
/// mean injecting script into every page to read link tags — which costs more
/// than the feature is worth.
@MainActor
public final class FaviconFetcher {
    public static let shared = FaviconFetcher()
    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    private init() {
        // Warm from disk in one pass at launch, so a restored session renders
        // its icons immediately rather than as a column of grey globes that
        // fills in over a second while the network is hit for things we
        // already knew (spec §2).
        cache = FaviconStore.loadAll()
        FaviconStore.prune()
    }

    public func icon(for url: URL) -> NSImage? {
        guard let host = url.host else { return nil }
        if let hit = cache[host] { return hit }
        // Second chance from disk: covers an icon written by a previous run
        // after this process had already warmed its cache.
        if let onDisk = FaviconStore.load(host: host) {
            cache[host] = onDisk
            return onDisk
        }
        return nil
    }

    /// Fetches if not already known. `completion` fires only on a new icon, so
    /// callers can use it to trigger a targeted row reload.
    public func fetch(for url: URL, completion: @escaping (NSImage) -> Void) {
        guard let host = url.host, cache[host] == nil, !inFlight.contains(host),
              let scheme = url.scheme, scheme.hasPrefix("http") else { return }
        inFlight.insert(host)

        // S2 first: it is a CDN, returns a consistent size, and does not 404 on
        // sites that never shipped a /favicon.ico.
        let candidates = [
            URL(string: "https://www.google.com/s2/favicons?sz=64&domain=\(host)"),
            URL(string: "\(scheme)://\(host)/favicon.ico"),
        ].compactMap { $0 }

        Task { [weak self] in
            for candidate in candidates {
                guard let (data, response) = try? await URLSession.shared.data(from: candidate),
                      let http = response as? HTTPURLResponse, http.statusCode == 200,
                      let image = NSImage(data: data), image.size.width > 1 else { continue }
                image.size = NSSize(width: 16, height: 16)
                await MainActor.run {
                    self?.cache[host] = image
                    self?.inFlight.remove(host)
                    FaviconStore.save(image, host: host)   // survive relaunch
                    completion(image)
                }
                return
            }
            await MainActor.run { self?.inFlight.remove(host) }
        }
    }
}
