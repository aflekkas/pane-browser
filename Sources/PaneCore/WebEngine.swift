// spec: §1
import Foundation

/// The seam between Pane's logic and WebKit. `PaneCore` speaks only this
/// vocabulary, so the tab logic can be tested against a fake with no WebKit
/// present (ADR 0006).
/// `@MainActor` because every conforming engine wraps AppKit/WebKit, which is
/// main-actor-isolated in the macOS 26 SDK. Isolating the protocol rather than
/// the implementations keeps the fake used by tests on the same actor as the
/// real one, so tests exercise the real isolation rules.
@MainActor
public protocol WebEngine: AnyObject {
    var currentURL: URL? { get }
    var title: String? { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var estimatedProgress: Double { get }

    func load(_ url: URL)
    func goBack()
    func goForward()
    func reload()
    func stopLoading()

    /// Opaque blob carrying the full back/forward list, scroll and form state.
    /// This is the mechanism the whole discard/restore claim rests on (spec §4).
    func captureInteractionState() -> Data?
    func restoreInteractionState(_ data: Data)
}

/// What the engine tells us. Deliberately small — anything WebKit-shaped stays
/// on the far side of this boundary.
public enum WebEngineEvent: Equatable, Sendable {
    case didStartNavigation(URL?)
    case didCommit(URL?)
    case didFinish(URL?, title: String?)
    case didFail(URL?, message: String)
    case progressChanged(Double)
    case titleChanged(String?)
    case urlChanged(URL?)
    case contentProcessDidTerminate
}
