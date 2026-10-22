import CoreServices
import Foundation
import SwiftData
import SwiftUI

@MainActor
class DownloadManager: ObservableObject {
    @Published var activeDownloads: [Download] = []
    @Published var recentDownloads: [Download] = []
    @Published var isShowingDownloadsHistory = false

    let modelContainer: ModelContainer
    let modelContext: ModelContext
    /// Private-browsing download records: memory only, never inserted
    /// into the SwiftData context, lost at relaunch by design. The
    /// downloaded file itself still lands in the user's Downloads folder.
    private var ephemeralDownloads: [Download] = []

    func isEphemeral(_ download: Download) -> Bool {
        ephemeralDownloads.contains { $0.id == download.id }
    }

    private var activeDownloadTasks: [UUID: BrowserDownloadTask] = [:]
    private var taskDownloads: [UUID: Download] = [:]
    private var taskDestinationURLs: [UUID: URL] = [:]
    private var progressTimers: [UUID: Timer] = [:]
    weak var toastManager: ToastManager?
    private var downloadSessions: [String: DownloadTransferSession] = [:]
    private var pendingRetries: [UUID: UUID] = [:]
    private var pendingCancellations: Set<UUID> = []
    private static var reservedDestinations: Set<URL> = []
    /// Tests use an isolated real directory; production uses ~/Downloads.
    var downloadsDirectory: URL?

    func registerDownloadSession(_ session: DownloadTransferSession) {
        downloadSessions[session.profileScopeID] = session
    }

    init(
        modelContainer: ModelContainer,
        modelContext: ModelContext
    ) {
        self.modelContainer = modelContainer
        self.modelContext = modelContext
        loadRecentDownloads()
    }

    private func loadRecentDownloads() {
        let descriptor = FetchDescriptor<Download>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )

        do {
            let downloads = try modelContext.fetch(descriptor)
            let merged = ephemeralDownloads + downloads.filter { persisted in
                !ephemeralDownloads.contains { $0.id == persisted.id }
            }
            self.recentDownloads = Array(merged.prefix(50))
            self.activeDownloads = merged.filter { $0.status == .downloading || $0.status == .pending }
        } catch {
            // Failed to load downloads
        }
    }

    func startDownload(
        from downloadTask: BrowserDownloadTask,
        originalURL: URL,
        suggestedFilename: String,
        expectedSize: Int64 = 0
    ) -> Download {
        let download = Download(
            originalURL: originalURL,
            fileName: DownloadSafety.sanitizedFilename(suggestedFilename),
            fileSize: expectedSize
        )
        download.pageURLString = downloadTask.pageURL?.absoluteString
        download.profileID = downloadTask.profileScopeID

        download.status = .downloading
        download.isActive = true

        if downloadTask.profileScopeID?.hasPrefix("private:") == true {
            // Private browsing: record stays in memory only. The file
            // still downloads to the user's chosen folder, but no URL or
            // filename is persisted to the normal store.
            ephemeralDownloads.append(download)
        } else {
            // Save to SwiftData
            modelContext.insert(download)
            do {
                try modelContext.save()
            } catch {
                // Failed to save download
            }
        }

        activeDownloadTasks[download.id] = downloadTask
        activeDownloads.append(download)
        refreshRecentDownloads()

        // Ensure SwiftUI picks up the change when called from WKDownload callbacks
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }

        toastManager?.show("Downloading \(suggestedFilename)", type: .info, icon: .system("arrow.down.circle"))

        return download
    }

    func updateDownloadProgress(_ download: Download, downloadedBytes: Int64, totalBytes: Int64) {
        download.updateProgress(downloadedBytes: downloadedBytes, totalBytes: totalBytes)

        try? modelContext.save()

        // Trigger UI updates
        DispatchQueue.main.async {
            self.objectWillChange.send()
            download.objectWillChange.send()
        }
    }

    func completeDownload(_ download: Download, destinationURL: URL) {
        download.markCompleted(destinationURL: destinationURL)

        try? modelContext.save()

        activeDownloadTasks.removeValue(forKey: download.id)
        activeDownloads.removeAll { $0.id == download.id }
        refreshRecentDownloads()

        toastManager?.show("Downloaded \(download.fileName)", icon: .system("checkmark.circle"))
    }

    func failDownload(_ download: Download, error: String, resumeData: Data? = nil) {
        if let resumeData {
            download.resumeData = resumeData
        }
        download.markFailed(error: error)

        try? modelContext.save()

        activeDownloadTasks.removeValue(forKey: download.id)
        activeDownloads.removeAll { $0.id == download.id }
        refreshRecentDownloads()

        toastManager?.show("Download failed \(download.fileName)", type: .error)
    }

    func cancelDownload(_ download: Download) {
        let fileName = download.fileName
        pendingRetries.removeValue(forKey: download.id)
        if let scope = download.profileID {
            downloadSessions[scope]?.cancelPending(download.id)
        }
        if let downloadTask = activeDownloadTasks[download.id] {
            pendingCancellations.insert(download.id)
            // Capture resume data so Retry can resume instead of restarting.
            downloadTask.cancel { [weak self] resumeData in
                Task { @MainActor in
                    self?.pendingCancellations.remove(download.id)
                    download.resumeData = resumeData
                    try? self?.modelContext.save()
                }
            }
            cleanupTask(downloadTask.id)
        }

        download.markCancelled()

        try? modelContext.save()

        activeDownloadTasks.removeValue(forKey: download.id)
        activeDownloads.removeAll { $0.id == download.id }
        refreshRecentDownloads()

        toastManager?.show("Download cancelled \(fileName)", type: .info, icon: .system("xmark.circle"))
    }

    func handleDownload(_ task: BrowserDownloadTask, reusing record: Download? = nil) {
        task.onDestinationRequest = { [weak self] response, suggestedFilename, completion in
            guard let self else {
                completion(nil)
                return
            }

            let downloadsDir = self.getDownloadsDirectory()
            // Untrusted filename: sanitise, contain, and uniquify. Never
            // use `suggestedFilename` as a path verbatim.
            let finalURL = DownloadSafety.uniqueDestination(
                in: downloadsDir, suggestedFilename: suggestedFilename, reserved: Self.reservedDestinations
            )
            Self.reservedDestinations.insert(finalURL)
            let expectedSize = response.expectedContentLength
            let download = record ?? self.startDownload(
                from: task,
                originalURL: task.originalURL,
                suggestedFilename: finalURL.lastPathComponent,
                expectedSize: expectedSize
            )

            download.fileName = finalURL.lastPathComponent
            download.destinationURL = finalURL
            self.activeDownloadTasks[download.id] = task
            self.taskDownloads[task.id] = download
            self.taskDestinationURLs[task.id] = finalURL
            self.startProgressTimer(for: task, download: download, expectedSize: expectedSize)
            completion(finalURL)
        }

        task.onRedirect = { [weak self] newURL in
            guard let self, let download = self.taskDownloads[task.id] else { return }
            download.originalURL = newURL
            download.originalURLString = newURL.absoluteString
            try? self.modelContext.save()
        }

        task.onFinish = { [weak self] in
            guard let self,
                  let download = self.taskDownloads[task.id],
                  let destinationURL = self.taskDestinationURLs[task.id]
            else {
                return
            }

            let pageURL = task.pageURL ?? download.pageURLString.flatMap(URL.init(string:))
            download.quarantineVerified = Self.applyQuarantine(
                to: destinationURL,
                source: download.originalURL,
                page: pageURL
            )
            if !download.quarantineVerified {
                NSLog("Pane: download finished WITHOUT verified quarantine: \(destinationURL.lastPathComponent)")
            }
            self.completeDownload(download, destinationURL: destinationURL)
            self.cleanupTask(task.id)
        }

        task.onFail = { [weak self] error, resumeData in
            guard let self, let download = self.taskDownloads[task.id] else { return }
            self.failDownload(download, error: error.localizedDescription, resumeData: resumeData)
            self.cleanupTask(task.id)
        }
    }

    /// Rebinds an existing failed/cancelled record to a resumed task
    /// (from `WKWebView.resumeDownload(fromResumeData:)` via the tab layer).
    @discardableResult
    func handleResumedDownload(_ task: BrowserDownloadTask, for download: Download) -> Bool {
        guard DownloadSafety.canResume(downloadProfileID: download.profileID, taskProfileID: task.profileScopeID) else {
            task.cancel()
            NSLog("Pane: refused download resume from a different profile")
            return false
        }
        download.status = .downloading
        download.isActive = true
        download.error = nil
        download.resumeData = nil
        try? modelContext.save()
        if !activeDownloads.contains(where: { $0.id == download.id }) {
            activeDownloads.append(download)
        }
        // Resumption normally uses WebKit's embedded destination without asking
        // for one again. Install ALL tracking before returning to WebKit.
        handleDownload(task, reusing: download)
        activeDownloadTasks[download.id] = task
        taskDownloads[task.id] = download
        if let destination = download.destinationURL {
            taskDestinationURLs[task.id] = destination
            Self.reservedDestinations.insert(destination)
        }
        startProgressTimer(for: task, download: download, expectedSize: download.fileSize)
        refreshRecentDownloads()
        return true
    }

    func clearCompletedDownloads() {
        let completedDownloads = recentDownloads.filter { $0.status == .completed }
        ephemeralDownloads.removeAll { $0.status == .completed }
        for download in completedDownloads where !isEphemeral(download) {
            modelContext.delete(download)
        }

        try? modelContext.save()
        refreshRecentDownloads()
    }

    func clearNonActiveDownloads() {
        let nonActive = recentDownloads.filter {
            $0.status == .completed || $0.status == .failed || $0.status == .cancelled
        }
        ephemeralDownloads.removeAll { download in nonActive.contains { $0.id == download.id } }
        for download in nonActive where !isEphemeral(download) {
            modelContext.delete(download)
        }

        try? modelContext.save()
        refreshRecentDownloads()
    }

    func deleteDownload(_ download: Download) {
        // If it's an active download, cancel it first
        if download.status == .downloading || download.status == .pending {
            cancelDownload(download)
        }

        let wasEphemeral = isEphemeral(download)
        ephemeralDownloads.removeAll { $0.id == download.id }
        if !wasEphemeral {
            modelContext.delete(download)
        }
        try? modelContext.save()
        refreshRecentDownloads()
    }

    func openDownloadInFinder(_ download: Download) {
        guard let destinationURL = download.destinationURL else { return }
        NSWorkspace.shared.selectFile(destinationURL.path, inFileViewerRootedAtPath: "")
    }

    func openFile(_ download: Download) {
        guard let url = download.destinationURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Moves the downloaded file to Trash and removes the entry from history
    func moveToTrash(_ download: Download) {
        if let url = download.destinationURL {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        deleteDownload(download)
    }

    func canRetryDownload(_ download: Download) -> Bool {
        pendingRetries[download.id] == nil && !pendingCancellations.contains(download.id)
            && (download.status == .failed || download.status == .cancelled)
    }

    /// A retry is one asynchronous operation in the originating data store.
    /// Legacy records without a proven owner fail closed; they cannot safely
    /// inherit the focused window's profile or private identity.
    func retryDownload(_ download: Download) {
        guard canRetryDownload(download),
              let scope = download.profileID,
              let session = downloadSessions[scope],
              DownloadSafety.canResume(downloadProfileID: scope, taskProfileID: session.profileScopeID)
        else { return }
        let operationID = UUID()
        pendingRetries[download.id] = operationID
        download.status = .pending
        download.isActive = true
        refreshRecentDownloads()
        let resumeData = download.destinationURL == nil ? nil : download.resumeData
        let once = OnceCompletion<BrowserDownloadTask?> { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, self.pendingRetries[download.id] == operationID else {
                    task?.cancel()
                    return
                }
                self.pendingRetries.removeValue(forKey: download.id)
                guard let task else {
                    self.failDownload(download, error: "The original download session is unavailable.")
                    return
                }
                if resumeData == nil {
                    download.destinationURL = nil
                }
                self.handleResumedDownload(task, for: download)
            }
        }
        session.start(download, resumeData: resumeData) { once.call($0) }
    }

    private func refreshRecentDownloads() {
        loadRecentDownloads()
    }

    /// Helper to get default downloads directory
    func getDownloadsDirectory() -> URL {
        if let downloadsDirectory {
            return downloadsDirectory
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Helper to create unique filename if file already exists
    func createUniqueFilename(for url: URL) -> URL {
        var finalURL = url
        var counter = 1

        while FileManager.default.fileExists(atPath: finalURL.path) {
            let filename = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            let directory = url.deletingLastPathComponent()

            let newFilename = ext.isEmpty ? "\(filename) (\(counter))" : "\(filename) (\(counter)).\(ext)"
            finalURL = directory.appendingPathComponent(newFilename)
            counter += 1
        }

        return finalURL
    }

    private func startProgressTimer(for task: BrowserDownloadTask, download: Download, expectedSize: Int64) {
        let taskID = task.id
        progressTimers[taskID]?.invalidate()
        progressTimers[taskID] = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let completedBytes = task.progress.completedUnitCount
            let totalBytes = task.progress.totalUnitCount > 0 ? task.progress.totalUnitCount : expectedSize
            Task { @MainActor in
                guard let download = self.taskDownloads[taskID] else { return }
                self.updateDownloadProgress(
                    download,
                    downloadedBytes: completedBytes,
                    totalBytes: totalBytes
                )
            }
        }
    }

    /// Belt-and-braces quarantine, ported from Pane (spec §6): on current
    /// macOS `WKDownload` usually quarantines the file itself, but that is
    /// undocumented, so the xattr is set explicitly and then read back.
    /// Only the read-back counts — the write not throwing proves nothing.
    /// Provenance URLs must be `NSURL` objects; strings are silently
    /// dropped. `page` is nil for now: the source page's URL only reaches
    /// this manager once `BrowserPage` passes it through (see the
    /// downloads/cert integration suggestions). Returns whether quarantine
    /// was verified on the finished file.
    static func applyQuarantine(to fileURL: URL, source: URL?, page: URL?) -> Bool {
        // Delegates to DownloadSafety, which never clears or overwrites an
        // existing (stronger, system-created) quarantine and verifies by
        // read-back. Provenance is best-effort only (see Pane api-note).
        DownloadSafety.applyQuarantine(to: fileURL, source: source, page: page).verified
    }

    static func hasQuarantine(_ url: URL) -> Bool {
        DownloadSafety.hasQuarantine(url)
    }

    private func cleanupTask(_ taskID: UUID) {
        progressTimers[taskID]?.invalidate()
        progressTimers.removeValue(forKey: taskID)
        if let record = taskDownloads.removeValue(forKey: taskID),
           let task = activeDownloadTasks[record.id], task.id == taskID
        {
            task.clearCallbacks()
        }
        if let url = taskDestinationURLs.removeValue(forKey: taskID) {
            Self.reservedDestinations.remove(url)
        }
    }
}
