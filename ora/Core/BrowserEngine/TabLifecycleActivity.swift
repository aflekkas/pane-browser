import Foundation
@preconcurrency import WebKit

/// Result of probing a live page for activity that must block discard.
///
/// Guards are independent booleans, not a single state: a page can have a
/// dirty form *and* an active MediaSession at once, and neither may mask
/// the other. Any probe failure (`probeFailed`: JS error, timeout, hung
/// renderer, malformed payload, no result) blocks automatic discard
/// unconditionally — an unanswered probe is never permission to unload,
/// whether or not a form was detected.
struct TabLifecycleActivity: Sendable, Equatable {
    let probeFailed: Bool
    let hasForm: Bool
    let formDirty: Bool
    let mediaSessionActive: Bool
    /// A frame exists whose document the probe could not inspect (e.g. a
    /// cross-origin iframe). Its form state is unknowable from the top
    /// document, so it blocks discard like a dirty form.
    let hasUninspectableFrames: Bool
    let isPlayingMedia: Bool

    init(
        probeFailed: Bool = false,
        hasForm: Bool = false,
        formDirty: Bool = false,
        mediaSessionActive: Bool = false,
        hasUninspectableFrames: Bool = false,
        isPlayingMedia: Bool = false
    ) {
        self.probeFailed = probeFailed
        self.hasForm = hasForm
        self.formDirty = formDirty
        self.mediaSessionActive = mediaSessionActive
        self.hasUninspectableFrames = hasUninspectableFrames
        self.isPlayingMedia = isPlayingMedia
    }

    static let unknown = TabLifecycleActivity(probeFailed: true)

    var hasActiveMediaSession: Bool {
        mediaSessionActive
    }

    /// Fail closed: dirty form, uninspectable frames, or any probe failure
    /// all read as unsaved work to the discard policy.
    var hasUnsavedFormState: Bool {
        probeFailed || formDirty || hasUninspectableFrames
    }

    var blocksDiscard: Bool {
        hasUnsavedFormState || mediaSessionActive || isPlayingMedia
    }
}

/// Per-document edit tracking runs in its own isolated world in every frame.
/// Cross-origin frames, missing installation, traversal limits and closed shadow
/// roots are unknown and block discard. The page-world shadow marker is a
/// conservative data-loss guard, not a security boundary against hostile pages.
enum TabLifecycleActivityProbe {
    static let world = WKContentWorld.world(name: "com.pane.lifecycle")

    static func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(
            source: shadowCoverageScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        controller.addUserScript(WKUserScript(
            source: trackingScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world
        ))
    }

    /// Closed roots cannot be inspected from an isolated world. Mark their
    /// existence before page scripts run; never assume their contents are clean.
    static let shadowCoverageScript = """
    (() => {
        let unknown = false;
        const mark = () => {
            if (document.documentElement && unknown) {
                document.documentElement.setAttribute('data-pane-unknown-shadow', '');
            }
        };
        new MutationObserver(records => {
            for (const record of records) for (const node of record.addedNodes) {
                if (node.nodeType === 1 && (node.matches('template[shadowrootmode="closed"]') ||
                    node.querySelector('template[shadowrootmode="closed"]'))) unknown = true;
            }
            mark();
        }).observe(document, { childList: true, subtree: true });
        const attach = Element.prototype.attachShadow;
        Element.prototype.attachShadow = function(options) {
            const root = attach.call(this, options);
            if (options.mode === 'closed') this.setAttribute('data-pane-closed-shadow', '');
            return root;
        };
    })();
    """

    static let trackingScript = """
    (() => {
        if (window.__paneLifecycle) return;
        const dirty = new Set();
        const accepted = new WeakMap();
        const value = el => el.isContentEditable ? el.innerHTML :
            (el.type === 'checkbox' || el.type === 'radio' ? el.checked :
            (el.tagName === 'SELECT' ? Array.from(el.options).map(o => o.selected).join(',') : el.value));
        const editable = el => el && el.nodeType === 1 &&
            (el.matches('input,textarea,select') || el.isContentEditable);
        const changed = event => {
            const path = event.composedPath();
            const el = path.find(editable);
            if (el) dirty.add(el);
            // Retargeted closed-root edits have no inspectable control.
            else if (event.target && event.target !== document) dirty.add(event.target);
        };
        document.addEventListener('input', changed, true);
        document.addEventListener('change', changed, true);
        function accept(form) {
            for (const el of form.querySelectorAll('input,textarea,select,[contenteditable]')) {
                dirty.delete(el);
                accepted.set(el, value(el));
            }
        }
        document.addEventListener('submit', event => {
            // A cancelled submission may still contain an unsaved draft.
            queueMicrotask(() => { if (!event.defaultPrevented) accept(event.target); });
        }, true);
        document.addEventListener('reset', event => {
            setTimeout(() => { if (!event.defaultPrevented) accept(event.target); }, 0);
        }, true);
        window.__paneLifecycle = { dirty, accepted, value };
    })();
    """

    static let script = """
    (() => {
        try {
            const result = { v: 3, hasForm: false, dirty: false,
                mediaSessionActive: false, uninspectableFrames: false, playing: false };
            let inspected = 0;
            let roots = 0;
            function inspectRoot(root, tracker, depth) {
                if (!root || depth > 32 || ++roots > 256) {
                    result.uninspectableFrames = true; return;
                }
                for (const el of root.querySelectorAll('*')) {
                    if (++inspected > 20000) { result.uninspectableFrames = true; return; }
                    if (el.hasAttribute('data-pane-closed-shadow') || el.hasAttribute('data-pane-unknown-shadow')) {
                        result.uninspectableFrames = true;
                    }
                    // Declarative closed roots do not call attachShadow. Custom
                    // elements with hidden internals also have unknown coverage.
                    if (el.localName.includes('-') && !el.shadowRoot) result.uninspectableFrames = true;
                    if (el.matches('template[shadowrootmode="closed"]')) result.uninspectableFrames = true;
                    if (el.shadowRoot) inspectRoot(el.shadowRoot, tracker, depth + 1);
                    if (el.matches('input,textarea,select') || el.isContentEditable) {
                        result.hasForm = true;
                        if (tracker.dirty.has(el)) result.dirty = true;
                        if (tracker.accepted.has(el)) {
                            if (tracker.value(el) !== tracker.accepted.get(el)) result.dirty = true;
                        } else if (el.matches('input,textarea')) {
                            if (el.type === 'checkbox' || el.type === 'radio') {
                                if (el.checked !== el.defaultChecked) result.dirty = true;
                            } else if (el.value !== el.defaultValue) result.dirty = true;
                        } else if (el.tagName === 'SELECT') {
                            if (Array.from(el.options).some(o => o.selected !== o.defaultSelected)) result.dirty = true;
                        }
                    }
                    if (el.matches('video,audio') && !el.paused && !el.ended) result.playing = true;
                    if (el.matches('iframe,frame')) {
                        try {
                            if (!el.contentDocument || (el.src && el.src !== 'about:blank' &&
                                el.contentDocument.URL === 'about:blank')) result.uninspectableFrames = true;
                            else inspectWindow(el.contentWindow, depth + 1);
                        } catch (_) { result.uninspectableFrames = true; }
                    }
                }
            }
            function inspectWindow(win, depth) {
                if (!win || depth > 32) { result.uninspectableFrames = true; return; }
                const tracker = win.__paneLifecycle;
                if (!tracker || !win.document) { result.uninspectableFrames = true; return; }
                for (const el of tracker.dirty) {
                    if (el.isConnected) result.dirty = true;
                    else tracker.dirty.delete(el);
                }
                const session = win.navigator.mediaSession;
                if (session && session.playbackState !== 'none') result.mediaSessionActive = true;
                // onbeforeunload cannot reveal whether an app's draft is saved.
                if (win.onbeforeunload) result.uninspectableFrames = true;
                inspectRoot(win.document, tracker, depth);
            }
            inspectWindow(window, 0);
            return result;
        } catch (_) { return { v: 3, probeFailed: true }; }
    })();
    """

    /// Parses an `evaluateJavaScript` result. Every field must be present
    /// with the expected type; a missing field, a wrong type, an old
    /// single-state payload, or an explicit probe failure is `.unknown`,
    /// which blocks discard. A `nil` result (no result / JS error path)
    /// is likewise `.unknown`.
    static func parse(_ result: Any?) -> TabLifecycleActivity {
        guard let payload = result as? [String: Any],
              payload["probeFailed"] as? Bool != true,
              let hasForm = payload["hasForm"] as? Bool,
              let dirty = payload["dirty"] as? Bool,
              let mediaSessionActive = payload["mediaSessionActive"] as? Bool,
              let uninspectableFrames = payload["uninspectableFrames"] as? Bool,
              let playing = payload["playing"] as? Bool
        else {
            return .unknown
        }
        return TabLifecycleActivity(
            hasForm: hasForm,
            formDirty: dirty,
            mediaSessionActive: mediaSessionActive,
            hasUninspectableFrames: uninspectableFrames,
            isPlayingMedia: playing
        )
    }

    /// Probes `page`, calling back on the main queue. Errors, timeouts,
    /// and missing results all report `.unknown`. The timeout matters: a
    /// hung renderer must block discard, not wedge the cleanup sweep.
    static func probe(
        page: BrowserPage,
        timeout: TimeInterval = 1.0,
        completion: @escaping (TabLifecycleActivity) -> Void
    ) {
        var finished = false
        let finish: (TabLifecycleActivity) -> Void = { activity in
            DispatchQueue.main.async {
                guard !finished else { return }
                finished = true
                completion(activity)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish(.unknown)
        }
        var documentActivity: TabLifecycleActivity?
        var nativePlaying: Bool?
        let combine = {
            guard let activity = documentActivity, let playing = nativePlaying else { return }
            finish(TabLifecycleActivity(
                probeFailed: activity.probeFailed, hasForm: activity.hasForm,
                formDirty: activity.formDirty, mediaSessionActive: activity.mediaSessionActive,
                hasUninspectableFrames: activity.hasUninspectableFrames,
                isPlayingMedia: activity.isPlayingMedia || playing
            ))
        }
        // Public WebKit playback state covers media hidden in closed roots and
        // frames whose elements cannot be inspected from the top document.
        page.webView.requestMediaPlaybackState { state in
            switch state {
            case .playing, .suspended: nativePlaying = true
            case .none, .paused: nativePlaying = false
            @unknown default: finish(.unknown)
                return
            }
            combine()
        }
        page.webView.evaluateJavaScript(script, in: nil, in: world) { result in
            switch result {
            case let .success(value): documentActivity = parse(value)
            case .failure: documentActivity = .unknown
            }
            combine()
        }
    }
}
