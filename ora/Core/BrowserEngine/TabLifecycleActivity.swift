import Foundation

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

/// Probes a page through `BrowserPage.evaluateJavaScript` (public API)
/// with a self-contained script.
///
/// Limitations, deliberately conservative: the script runs in the page
/// world, so a hostile page can spoof a "clear" result, and cross-origin
/// iframe documents cannot be read at all. Uninspectable frames therefore
/// block discard (see `hasUninspectableFrames`), but a spoofed clear
/// cannot be detected from here — this probe is a data-loss guard for
/// ordinary pages, not a security boundary. Form dirtiness is derived by
/// comparing live values against their defaults in the top document and
/// every inspectable same-origin frame; MediaSession state comes from
/// `navigator.mediaSession`.
enum TabLifecycleActivityProbe {
    static let script = """
    (function () {
        try {
            var result = {
                hasForm: false,
                dirty: false,
                mediaSessionActive: false,
                uninspectableFrames: false,
                playing: false
            };
            function inspectDocument(doc, depth) {
                if (!doc || depth > 5) return;
                if (doc.querySelector('form, input, textarea, select, [contenteditable="true"]')) {
                    result.hasForm = true;
                }
                doc.querySelectorAll('input, textarea').forEach(function (el) {
                    if (el.type === 'checkbox' || el.type === 'radio') {
                        if (el.checked !== el.defaultChecked) result.dirty = true;
                    } else if ((el.value || '') !== (el.defaultValue || '')) {
                        result.dirty = true;
                    }
                });
                doc.querySelectorAll('select').forEach(function (el) {
                    var options = Array.prototype.slice.call(el.options || []);
                    if (options.some(function (option) {
                        return option.selected !== option.defaultSelected;
                    })) {
                        result.dirty = true;
                    }
                });
                doc.querySelectorAll('[contenteditable="true"]').forEach(function (el) {
                    if (el.textContent && el.textContent.length > 0) result.dirty = true;
                });
                doc.querySelectorAll('video, audio').forEach(function (el) {
                    if (!el.paused && !el.ended) result.playing = true;
                });
                doc.querySelectorAll('iframe, frame').forEach(function (frame) {
                    var frameDoc = null;
                    try {
                        frameDoc = frame.contentDocument ||
                            (frame.contentWindow && frame.contentWindow.document) || null;
                    } catch (error) {
                        frameDoc = null;
                    }
                    if (frameDoc) {
                        inspectDocument(frameDoc, depth + 1);
                    } else {
                        result.uninspectableFrames = true;
                    }
                });
            }
            inspectDocument(document, 0);
            try {
                result.mediaSessionActive = !!(navigator.mediaSession &&
                    navigator.mediaSession.playbackState &&
                    navigator.mediaSession.playbackState !== 'none');
            } catch (error) {}
            return {
                v: 2,
                hasForm: result.hasForm,
                dirty: result.dirty,
                mediaSessionActive: result.mediaSessionActive,
                uninspectableFrames: result.uninspectableFrames,
                playing: result.playing
            };
        } catch (error) {
            return { v: 2, probeFailed: true };
        }
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
        page.evaluateJavaScript(script) { result, error in
            finish(error == nil ? parse(result) : .unknown)
        }
    }
}
