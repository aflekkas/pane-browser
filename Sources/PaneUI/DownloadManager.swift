// spec: §6
import AppKit
import WebKit
import PaneCore

/// spec §6 downloads.
///
/// **Security-critical: quarantine.** The research corrected the spec here and
/// the correction matters (`docs/research/2026-08-07-boring-floor.md`):
///
/// - WebKit does **not** quarantine. `DownloadCocoa.mm` contains no quarantine
///   code, so it will not happen for free from `WKDownload`.
/// - LaunchServices does it, driven by `LSFileQuarantineEnabled` in Info.plist.
///   `CoreTypes.bundle/Exceptions.plist` force-enables it for known browsers by
///   bundle ID; a new bundle ID like Pane's is in neither list, so **without
///   that flag Pane gets no quarantine at all** — a malware vector, exactly as
///   the spec warned, just via a different mechanism than it described.
/// - The flag alone does not attach provenance. `kLSQuarantineOriginURLKey` and
///   `kLSQuarantineDataURLKey` are what produce Gatekeeper's "downloaded from"
///   attribution, and those must be written here.
///
/// The supported API is the `NSURLQuarantinePropertiesKey` resource key, not
/// `LSSetItemAttribute`.
@MainActor
public final class DownloadManager: NSObject {
    public struct Item: Identifiable, Sendable {
        public let id = UUID()
        public var filename: String
        public var destination: URL?
        public var sourceURL: URL?
        public var pageURL: URL?
        public var bytesWritten: Int64 = 0
        public var totalBytes: Int64 = 0
        public var isFinished = false
        public var failure: String?
        /// spec §6 — persisted so a failed download can be resumed.
        public var resumeData: Data?
    }

    public private(set) var items: [Item] = []
    public var onChange: (() -> Void)?
    private var byDownload: [ObjectIdentifier: UUID] = [:]
    private var observations: [ObjectIdentifier: NSKeyValueObservation] = [:]

    public func attach(_ download: WKDownload, pageURL: URL?) {
        download.delegate = self
        var item = Item(filename: "Downloading…")
        item.pageURL = pageURL
        items.append(item)
        byDownload[ObjectIdentifier(download)] = item.id
        observations[ObjectIdentifier(download)] = download.progress.observe(\.fractionCompleted) {
            [weak self] progress, _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.byDownload[ObjectIdentifier(download)],
                      let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].bytesWritten = progress.completedUnitCount
                self.items[i].totalBytes = progress.totalUnitCount
                self.onChange?()
            }
        }
        onChange?()
    }

    private func index(of download: WKDownload) -> Int? {
        guard let id = byDownload[ObjectIdentifier(download)] else { return nil }
        return items.firstIndex { $0.id == id }
    }

    /// spec §6 — "a uniquing pass against the destination directory".
    /// Never silently overwrite: a download that clobbers an existing file is
    /// data loss the user did not ask for.
    public static func uniqueDestination(in directory: URL, filename: String) -> URL {
        let fm = FileManager.default
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = directory.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    /// Attach provenance. The system fills in agent name, bundle identifier and
    /// timestamp when omitted (LSQuarantine.h says so explicitly), so only the
    /// two URLs and the type are set here.
    static func applyQuarantine(to fileURL: URL, source: URL?, page: URL?) {
        var props: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        // DataURL is the file itself; OriginURL is the page it came from. Both
        // are what Gatekeeper shows in its "downloaded from" prompt.
        //
        // These must be URL OBJECTS, not strings. LSQuarantine.h types them as
        // CFURLRef, and passing a String is silently dropped: the write
        // succeeds, the system-filled keys appear, and the provenance keys are
        // simply absent. Caught by reading the properties back rather than
        // trusting that setResourceValues did not throw.
        if let source { props[kLSQuarantineDataURLKey as String] = source as NSURL }
        if let page { props[kLSQuarantineOriginURLKey as String] = page as NSURL }

        do {
            var mutable = fileURL
            // The system has usually already quarantined the file by now
            // (LSFileQuarantineEnabled), creating an event row keyed by UUID.
            // Updating a partial dictionary onto that existing event does not
            // populate the URL columns, so clear and re-set with the full
            // dictionary in one write.
            var clear = URLResourceValues()
            clear.quarantineProperties = nil
            try? mutable.setResourceValues(clear)

            var values = URLResourceValues()
            values.quarantineProperties = props
            try mutable.setResourceValues(values)
        } catch {
            // Loud, not silent. A download that lands without quarantine is a
            // security regression, and the user should know rather than find
            // out when Gatekeeper fails to prompt.
            NSLog("Pane: FAILED to set quarantine on \(fileURL.lastPathComponent): \(error)")
        }
    }

    /// Verifiable from outside the app — the phase gate checks this with
    /// `xattr -p com.apple.quarantine`.
    public static func hasQuarantine(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?
            .quarantineProperties != nil
    }
}

extension DownloadManager: WKDownloadDelegate {
    /// The one required method.
    public func download(_ download: WKDownload,
                         decideDestinationUsing response: URLResponse,
                         suggestedFilename: String,
                         // WK_SWIFT_UI_ACTOR in the header — the completion is
                         // main-actor isolated, and omitting that fails
                         // conformance with a misleading "non-matching type".
                         completionHandler: @escaping @MainActor (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dest = Self.uniqueDestination(in: downloads, filename: suggestedFilename)
        if let i = index(of: download) {
            items[i].filename = dest.lastPathComponent
            items[i].destination = dest
            items[i].sourceURL = response.url
            onChange?()
        }
        completionHandler(dest)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        if let i = index(of: download) {
            items[i].isFinished = true
            if let dest = items[i].destination {
                Self.applyQuarantine(to: dest, source: items[i].sourceURL, page: items[i].pageURL)
            }
        }
        cleanup(download)
        onChange?()
    }

    public func download(_ download: WKDownload, didFailWithError error: Error,
                         resumeData: Data?) {
        if let i = index(of: download) {
            items[i].failure = error.localizedDescription
            items[i].resumeData = resumeData      // spec §6
        }
        cleanup(download)
        onChange?()
    }

    /// spec §6 — a download that redirects to an auth-protected host does NOT
    /// route through the navigation delegate. WKDownload has its own challenge
    /// method and omitting it rejects the protection space silently.
    public func download(_ download: WKDownload,
                         respondTo challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await AuthChallengeHandler.respond(to: challenge, window: NSApp.keyWindow)
    }

    private func cleanup(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        observations[key]?.invalidate()
        observations[key] = nil
        byDownload[key] = nil
    }
}
