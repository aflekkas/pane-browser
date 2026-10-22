import SwiftUI

/// Native certificate-error interstitial. Rendered only by the app,
/// never from web content. "Go Back" is the default action; continuing
/// is an explicit, non-default choice scoped to this exact certificate
/// for this session (granted by `BrowserAuthHandler`, not here).
struct CertificateInterstitialView: View {
    @Environment(\.theme) var theme
    let evaluation: CertificateExceptions.Evaluation
    let onGoBack: () -> Void
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(theme.destructive)
            Text("This Connection Is Not Private")
                .font(.title2.bold())
            Text("\(evaluation.host):\(evaluation.port)")
                .font(.headline.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("certificate-endpoint")
            Text(evaluation.reason)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.mutedForeground)
            if let fingerprint = evaluation.fingerprint {
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(evaluation.chain, id: \.self) { line in
                            Text(line).font(.caption)
                        }
                        Text("SHA-256: \(fingerprint)")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: 420)
            }
            HStack(spacing: 12) {
                Button("Continue for This Session", role: .destructive) {
                    onContinue()
                }
                Button("Go Back") {
                    onGoBack()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}
