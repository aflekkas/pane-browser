import AppKit
import Foundation

enum BrowserWebsiteDataType: Hashable {
    case cookies
    case cache
    case all
}

enum BrowserUserScriptInjectionTime {
    case atDocumentStart
    case atDocumentEnd
}

/// Where an injected script runs. Privileged bridge scripts (today only the
/// password manager) must use an explicit isolated world so page script can
/// neither see their globals nor reach their message handler.
enum BrowserScriptContentWorld: Equatable {
    case page
    case isolated(name: String)
}

struct BrowserUserScript {
    let name: String?
    let source: String
    let injectionTime: BrowserUserScriptInjectionTime
    let forMainFrameOnly: Bool
    let contentWorld: BrowserScriptContentWorld

    init(
        name: String?,
        source: String,
        injectionTime: BrowserUserScriptInjectionTime,
        forMainFrameOnly: Bool,
        contentWorld: BrowserScriptContentWorld = .page
    ) {
        self.name = name
        self.source = source
        self.injectionTime = injectionTime
        self.forMainFrameOnly = forMainFrameOnly
        self.contentWorld = contentWorld
    }
}

struct BrowserScriptMessage {
    let name: String
    let body: Any?
    /// Native frame facts from `WKScriptMessage.frameInfo`. Never trust the
    /// JS payload for these; privileged handlers must be validated against
    /// them (main frame only, frame origin == committed page origin).
    let isMainFrame: Bool
    let frameURL: URL?
    let pageURL: URL?

    init(name: String, body: Any?, isMainFrame: Bool = true, frameURL: URL? = nil, pageURL: URL? = nil) {
        self.name = name
        self.body = body
        self.isMainFrame = isMainFrame
        self.frameURL = frameURL
        self.pageURL = pageURL
    }
}

struct BrowserOpenPanelOptions {
    let allowsDirectories: Bool
    let allowsMultipleSelection: Bool
}

enum BrowserPermissionKind {
    case mediaCapture
}

enum BrowserPermissionDecision {
    case grant
    case deny
}

struct BrowserNavigationAction {
    let request: URLRequest
    let modifierFlags: NSEvent.ModifierFlags
}

enum BrowserNavigationActionDisposition {
    case allow
    case cancel
    case openInNewTab
}

enum BrowserNavigationPhase {
    case started
    case committed
    case finished
}

struct BrowserNavigationEvent {
    let phase: BrowserNavigationPhase
    let url: URL?
    let title: String?
    let progress: Double
    let isLoading: Bool
}

struct BrowserSnapshotConfiguration {
    let rect: CGRect?
    let afterScreenUpdates: Bool

    static let full = BrowserSnapshotConfiguration(rect: nil, afterScreenUpdates: false)
}
