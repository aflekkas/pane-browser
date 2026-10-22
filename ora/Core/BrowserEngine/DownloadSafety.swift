// spec: §6 (Pane boring floor — downloads)
import Foundation

/// Filename sanitisation, destination containment, uniquing and quarantine
/// for downloads. Pure/Foundation-only so it is unit-testable without WebKit.
///
/// Security invariants (do not weaken):
/// - A server-supplied `suggestedFilename` is untrusted input. It must never
///   escape the downloads directory, never become a hidden file, and never
///   silently overwrite an existing file.
/// - A completed download must carry `com.apple.quarantine`, verified by
///   reading it back. An existing (stronger) quarantine is never cleared or
///   overwritten; see `docs/api-notes/quarantine.md` in the Pane repo for the
///   three recorded provenance attempts — do not try a fourth variation.
enum DownloadSafety {
    // MARK: - Filename sanitisation

    /// Maximum filename length in UTF-8 bytes (APFS component limit is 255).
    static let maxFilenameBytes = 200

    private static let fallbackFilename = "download"

    /// Returns a single safe path component derived from untrusted input.
    static func sanitizedFilename(_ suggested: String?, fallbackExtension: String? = nil) -> String {
        var name = (suggested ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "/\\"))
            .last ?? ""
        name = name.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) && $0 != "\0" }
            .map(String.init)
            .joined()
        name = name.replacingOccurrences(of: ":", with: "-")
        // Strip leading dots/spaces (hidden files, "." / "..") and trailing
        // dots/spaces (ignored or surprising on several filesystems).
        while let first = name.first, first == "." || first == " " {
            name.removeFirst()
        }
        while let last = name.last, last == "." || last == " " {
            name.removeLast()
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            name = fallbackFilename
            if let fallbackExtension, !fallbackExtension.isEmpty {
                let ext = fallbackExtension.hasPrefix(".") ? String(fallbackExtension.dropFirst()) : fallbackExtension
                name += "." + ext
            }
            return name
        }
        return truncatedToByteLimit(name)
    }

    private static func truncatedToByteLimit(_ name: String) -> String {
        guard name.utf8.count > maxFilenameBytes else { return name }
        let nsName = name as NSString
        let ext = nsName.pathExtension
        let base = nsName.deletingPathExtension
        let extSuffix = ext.isEmpty ? "" : "." + ext
        let extBytes = extSuffix.utf8.count
        var baseBytes = [UInt8](base.utf8)
        let allowed = max(1, maxFilenameBytes - extBytes)
        if baseBytes.count > allowed {
            baseBytes = Array(baseBytes.prefix(allowed))
            // Never split a UTF-8 scalar.
            while !baseBytes.isEmpty, String(bytes: baseBytes, encoding: .utf8) == nil {
                baseBytes.removeLast()
            }
        }
        let truncatedBase = String(bytes: baseBytes, encoding: .utf8) ?? fallbackFilename
        return truncatedBase + extSuffix
    }

    // MARK: - Containment + uniquing

    /// True when `url` is `directory` itself or strictly inside it, after
    /// standardising both paths (resolves `..` and redundant separators).
    static func isContained(_ url: URL, in directory: URL) -> Bool {
        let dirPath = directory.standardizedFileURL.path
        let urlPath = url.standardizedFileURL.path
        if urlPath == dirPath {
            return true
        }
        let prefix = dirPath.hasSuffix("/") ? dirPath : dirPath + "/"
        return urlPath.hasPrefix(prefix)
    }

    /// Ora's uniquing spelling (`name (1).ext`), kept from the existing UI.
    /// Sanitises first and guarantees the result stays inside `directory`.
    static func uniqueDestination(
        in directory: URL,
        suggestedFilename: String?,
        fileManager: FileManager = .default
    ) -> URL {
        let safeName = sanitizedFilename(suggestedFilename)
        let dir = directory.standardizedFileURL
        var candidate = dir.appendingPathComponent(safeName)
        guard isContained(candidate, in: dir) else {
            candidate = dir.appendingPathComponent(fallbackFilename)
            return candidate
        }
        let nsName = safeName as NSString
        let base = nsName.deletingPathExtension
        let ext = nsName.pathExtension
        var counter = 1
        while fileManager.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            candidate = dir.appendingPathComponent(next)
            counter += 1
        }
        return candidate
    }

    // MARK: - Quarantine (belt-and-braces; WKDownload also quarantines)

    struct QuarantineOutcome: Equatable {
        /// Verified by read-back after the call.
        var verified: Bool
        /// An existing quarantine was present and left untouched.
        var preservedExisting: Bool
        var errorDescription: String?
    }

    /// Applies quarantine without overwriting an existing one. If the file is
    /// already quarantined (e.g. by `WKDownload`/`LSFileQuarantineEnabled`),
    /// that stronger, system-created state is preserved verbatim. Otherwise a
    /// web-download quarantine is set with NSURL-typed provenance (strings are
    /// silently dropped) and verified by reading it back.
    @discardableResult
    static func applyQuarantine(to fileURL: URL, source: URL?, page: URL?) -> QuarantineOutcome {
        if hasQuarantine(fileURL) {
            return QuarantineOutcome(verified: true, preservedExisting: true, errorDescription: nil)
        }
        var props: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String
        ]
        if let source {
            props[kLSQuarantineDataURLKey as String] = source as NSURL
        }
        if let page {
            props[kLSQuarantineOriginURLKey as String] = page as NSURL
        }
        do {
            var mutable = fileURL
            var values = URLResourceValues()
            values.quarantineProperties = props
            try mutable.setResourceValues(values)
        } catch {
            // Loud, not silent: an unquarantined download is a security regression.
            NSLog("Pane: FAILED to set quarantine on \(fileURL.lastPathComponent): \(error)")
            return QuarantineOutcome(
                verified: hasQuarantine(fileURL),
                preservedExisting: false,
                errorDescription: "\(error)"
            )
        }
        let verified = hasQuarantine(fileURL)
        if !verified {
            NSLog("Pane: quarantine read-back missing on \(fileURL.lastPathComponent)")
        }
        return QuarantineOutcome(verified: verified, preservedExisting: false, errorDescription: nil)
    }

    /// Verifiable from outside the app via `xattr -p com.apple.quarantine`.
    static func hasQuarantine(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?
            .quarantineProperties != nil
    }

    static func quarantineType(_ url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.quarantinePropertiesKey]))?
            .quarantineProperties?[kLSQuarantineTypeKey as String] as? String
    }

    // MARK: - Resumption scope

    /// Resume data must only be replayed into a web view from the same
    /// profile/Space it came from. Fail closed when the download recorded a
    /// profile but the resuming task cannot prove it belongs to it.
    static func canResume(downloadProfileID: String?, taskProfileID: String?) -> Bool {
        // Fail closed for unscoped records too: legacy/nil profile resume
        // data must not be replayed into an arbitrary profile. Callers
        // fall back to a fresh download instead.
        guard let downloadProfileID, !downloadProfileID.isEmpty,
              let taskProfileID, !taskProfileID.isEmpty
        else { return false }
        return downloadProfileID == taskProfileID
    }
}

/// Fires a completion exactly once; later calls are dropped. Used to bridge
/// WebKit's completion-handler delegates without double-fire/never-fire bugs.
final class OnceCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let handler: (Value) -> Void

    init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    func call(_ value: Value) {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        handler(value)
    }

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }
}
