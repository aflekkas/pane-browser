// spec: §7
import Foundation
import WebKit
import PaneCore

/// spec §7 — login-form detection and autofill.
///
/// **Invariant: this script runs in an ISOLATED `WKContentWorld`, never the
/// page world.** In the page world a hostile site could read the message
/// handler, call it, and impersonate the bridge. An isolated world has its own
/// global object, so page script cannot see any of this.
///
/// The trade-off, from `docs/research/2026-08-07-credentials.md`: an isolated
/// world also cannot *override* page globals — a `navigator.credentials` shim
/// there is invisible to page script, which is why §7's passkey shim was
/// deleted (ADR 0003). Reading and writing the DOM does cross the boundary,
/// which is all this needs.
public enum CredentialBridge {
    public static let worldName = "pane.credentials"
    public static let messageName = "paneCredentials"

    public static var world: WKContentWorld { .world(name: worldName) }

    /// Injected at `.atDocumentEnd` per §7, main frame only.
    ///
    /// Main frame only is deliberate: a login form inside a third-party iframe
    /// belongs to that frame's origin, not the page's, and offering the page's
    /// credentials to it would be a handout to any site that embeds an iframe.
    public static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentEnd,
                     forMainFrameOnly: true, in: world)
    }

    private static let source = """
    (function () {
      'use strict';

      // §7's heuristic: the username field is the nearest preceding text or
      // email input in the same form. Falls back to the whole document for the
      // increasingly common case of inputs with no <form> at all.
      function usernameFor(passwordEl) {
        const scope = passwordEl.form || document;
        const candidates = Array.from(
          scope.querySelectorAll('input[type=text], input[type=email], input:not([type])'));
        let best = null;
        for (const el of candidates) {
          if (el.compareDocumentPosition(passwordEl) & Node.DOCUMENT_POSITION_FOLLOWING) {
            best = el;   // precedes the password field; keep the nearest one
          }
        }
        return best;
      }

      function rectOf(el) {
        const r = el.getBoundingClientRect();
        return { x: r.left, y: r.top, w: r.width, h: r.height };
      }

      function scan() {
        const pw = document.querySelector('input[type=password]');
        if (!pw) return null;
        const user = usernameFor(pw);
        return {
          hasLoginForm: true,
          origin: location.origin,
          usernameValue: user ? user.value : '',
          passwordRect: rectOf(pw),
          usernameRect: user ? rectOf(user) : null
        };
      }

      function report(kind) {
        const info = scan();
        if (!info) return;
        info.kind = kind;
        window.webkit.messageHandlers.paneCredentials.postMessage(info);
      }

      // Setting .value alone does not update React, Vue or anything else with a
      // controlled input: they track the native setter. Going through the
      // prototype descriptor and then dispatching input+change is what makes
      // the framework notice (§7).
      window.__paneFill = function (username, password) {
        const pw = document.querySelector('input[type=password]');
        if (!pw) return false;
        const user = usernameFor(pw);
        const setNative = (el, value) => {
          const proto = Object.getPrototypeOf(el);
          const desc = Object.getOwnPropertyDescriptor(proto, 'value');
          if (desc && desc.set) { desc.set.call(el, value); } else { el.value = value; }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        };
        if (user && username) setNative(user, username);
        setNative(pw, password);
        return true;
      };

      report('detected');

      // §7: intercept submit so a new or changed password can be offered for
      // saving. Capture phase, because a page handler may cancel the event.
      document.addEventListener('submit', function () { report('submitted'); }, true);

      // Many sign-in flows never fire submit — they POST via fetch from a click.
      document.addEventListener('click', function (e) {
        const t = e.target;
        if (!t) return;
        const isButton = t.tagName === 'BUTTON'
          || (t.tagName === 'INPUT' && (t.type === 'submit' || t.type === 'button'));
        if (isButton) setTimeout(function () { report('submitted'); }, 0);
      }, true);
    })();
    """
}

/// What the page reported. Deliberately a small, closed shape: anything from a
/// web page is untrusted input, and a narrow struct is the parse boundary.
public struct LoginFormInfo: Sendable {
    public enum Kind: String, Sendable { case detected, submitted }
    public let kind: Kind
    public let origin: String
    public let usernameValue: String
    public let passwordRect: CGRect

    public init?(_ body: Any) {
        guard let d = body as? [String: Any],
              let kindRaw = d["kind"] as? String, let kind = Kind(rawValue: kindRaw),
              let origin = d["origin"] as? String,
              let rect = d["passwordRect"] as? [String: Any] else { return nil }
        self.kind = kind
        self.origin = origin
        self.usernameValue = (d["usernameValue"] as? String) ?? ""
        self.passwordRect = CGRect(
            x: (rect["x"] as? Double) ?? 0, y: (rect["y"] as? Double) ?? 0,
            width: (rect["w"] as? Double) ?? 0, height: (rect["h"] as? Double) ?? 0)
    }
}
