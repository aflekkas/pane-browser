// spec: §6
import AppKit
import Security

/// spec §6 — "Native full-content-area interstitial, red/amber by severity,
/// 'Advanced' disclosure showing the actual chain."
///
/// spec §1 — this is AppKit, covering the content area. It is never a
/// `loadHTMLString` error page: rendering the warning *inside* the renderer
/// whose trust just failed is the exact attack the invariant exists to prevent.
@MainActor
public final class CertInterstitialView: NSView {
    public enum Severity {
        /// Name mismatch, expired — usually misconfiguration.
        case amber
        /// Untrusted root, revoked, or a chain that fails to build — assume
        /// interception until proven otherwise.
        case red
    }

    public var onGoBack: (() -> Void)?
    public var onProceed: (() -> Void)?

    private let disclosure = NSButton()
    private let chainScroll = NSScrollView()
    private var chainHeight: NSLayoutConstraint!

    public init(host: String, reason: String, severity: Severity,
                chain: [String], fingerprint: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let badge = NSImageView()
        badge.image = NSImage(systemSymbolName: severity == .red ? "exclamationmark.shield.fill"
                                                                 : "exclamationmark.triangle.fill",
                              accessibilityDescription: nil)
        badge.contentTintColor = severity == .red ? .systemRed : .systemOrange
        badge.symbolConfiguration = .init(pointSize: 44, weight: .regular)

        let title = NSTextField(labelWithString: "This Connection Is Not Private")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString:
            "Pane cannot verify the identity of “\(host)”.\n\n\(reason)\n\n"
            + (severity == .red
               ? "Someone may be impersonating this site to steal what you send it."
               : "This is often a server misconfiguration, but it can also be interception."))
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 460

        let back = NSButton(title: "Go Back", target: self, action: #selector(goBack))
        back.keyEquivalent = "\r"          // safe action is the default
        back.bezelStyle = .rounded
        back.controlSize = .large

        // Destructive, deliberately understated and never the default.
        let proceed = NSButton(title: "Continue for This Session",
                               target: self, action: #selector(proceed))
        proceed.bezelStyle = .rounded
        proceed.controlSize = .large

        disclosure.title = "Advanced"
        disclosure.bezelStyle = .inline
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.target = self
        disclosure.action = #selector(toggleAdvanced)

        // The actual chain, per §6.
        var text = chain.enumerated()
            .map { "\($0.offset == 0 ? "Leaf" : "Issuer \($0.offset)"):  \($0.element)" }
            .joined(separator: "\n")
        if let fingerprint {
            text += "\n\nSHA-256:\n" + stride(from: 0, to: fingerprint.count, by: 16).map {
                let s = fingerprint.index(fingerprint.startIndex, offsetBy: $0)
                let e = fingerprint.index(s, offsetBy: min(16, fingerprint.count - $0))
                return String(fingerprint[s..<e]).uppercased()
            }.joined(separator: "\n")
        }
        let chainText = NSTextView()
        chainText.string = text
        chainText.isEditable = false
        chainText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        chainText.drawsBackground = false
        chainScroll.documentView = chainText
        chainScroll.drawsBackground = false
        chainScroll.hasVerticalScroller = true
        chainScroll.isHidden = true

        let buttons = NSStackView(views: [back, proceed])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let column = NSStackView(views: [badge, title, body, buttons, disclosure, chainScroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        chainHeight = chainScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -48),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            chainScroll.widthAnchor.constraint(equalToConstant: 460),
            chainHeight,
        ])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func goBack()  { onGoBack?() }
    @objc private func proceed() { onProceed?() }

    @objc private func toggleAdvanced() {
        let open = disclosure.state == .on
        chainScroll.isHidden = !open
        chainHeight.animator().constant = open ? 160 : 0
    }

    /// Map the trust failure to a severity. Amber is for the failures that are
    /// usually misconfiguration; everything else is treated as red, because
    /// guessing low on an unrecognised failure is the wrong direction to err.
    public static func severity(for error: CFError?) -> Severity {
        guard let error else { return .red }
        let code = CFErrorGetCode(error)
        switch code {
        case Int(errSecCertificateExpired), Int(errSecCertificateNotValidYet),
             Int(errSecHostNameMismatch):
            return .amber
        default:
            return .red
        }
    }

    public static func chainSummary(_ trust: SecTrust) -> [String] {
        guard let certs = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else { return [] }
        return certs.map { SecCertificateCopySubjectSummary($0) as String? ?? "(unnamed certificate)" }
    }
}
