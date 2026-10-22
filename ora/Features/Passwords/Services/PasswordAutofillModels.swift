import AppKit
import Foundation

enum PasswordFormAction: String, Codable {
    case login
    case createAccount
}

enum PasswordAutofillFieldKind: String, Codable {
    case email
    case password
    case username
}

enum PasswordAutofillKeyCommand: String, Codable {
    case moveUp
    case moveDown
    case activate
    case dismiss
}

struct PasswordBridgeRect: Codable, Equatable {
    let originX: Double
    let originY: Double
    let width: Double
    let height: Double

    enum CodingKeys: String, CodingKey {
        case originX = "x"
        case originY = "y"
        case width
        case height
    }

    var cgRect: CGRect {
        CGRect(x: originX, y: originY, width: width, height: height)
    }
}

struct PasswordBridgeFocusPayload: Codable, Equatable {
    let fieldID: String
    let hostname: String
    let action: PasswordFormAction
    let fieldKind: PasswordAutofillFieldKind
    let usernameFieldID: String?
    let passwordFieldIDs: [String]
    let rect: PasswordBridgeRect
}

struct PasswordBridgeSubmitPayload: Codable, Equatable {
    let hostname: String
    let username: String
    let password: String
    let action: PasswordFormAction
}

struct PasswordBridgeEvent: Codable, Equatable {
    let type: String
    let focus: PasswordBridgeFocusPayload?
    let submit: PasswordBridgeSubmitPayload?
    let keyCommand: PasswordAutofillKeyCommand?
    let fieldID: String?
    let rect: PasswordBridgeRect?
}

struct PasswordFillRequest: Codable {
    let usernameFieldID: String?
    let passwordFieldIDs: [String]
    let username: String?
    let password: String
    let highlightColor: String
    let submitAfterFill: Bool
    /// Per-document token from the captured `PasswordDocumentContext`. The
    /// isolated script refuses to write when it does not match its own
    /// document, so a fill minted before a navigation/reload is inert.
    let documentToken: String
}

enum PasswordAutofillSuggestion: Identifiable, Equatable {
    case generatedPassword(host: String, password: String)
    case savedCredential(SavedPasswordSummary)
    case email(PasswordEmailSuggestion)

    var id: String {
        switch self {
        case let .generatedPassword(_, password):
            return "generated-\(password)"
        case let .savedCredential(entry):
            return "saved-\(entry.id)"
        case let .email(suggestion):
            return "email-\(suggestion.id)"
        }
    }

    var host: String {
        switch self {
        case let .generatedPassword(host, _):
            return host
        case let .savedCredential(entry):
            return entry.host
        case let .email(suggestion):
            return suggestion.host
        }
    }
}

struct PasswordAutofillOverlayState: Equatable {
    let focus: PasswordBridgeFocusPayload
    let savedPasswordEntries: [SavedPasswordSummary]
    let emailSuggestions: [PasswordEmailSuggestion]
    let generatedPassword: String?
    let selectedSuggestionIndex: Int
    /// Native document binding captured when the overlay was presented.
    /// Compared (never trusted from JS) again at fill time. Defaulted so
    /// pure suggestion-resolution constructions stay context-free; only
    /// the presented overlay carries one, and fills fail closed without it.
    var fillContext: PasswordDocumentContext?

    init(
        focus: PasswordBridgeFocusPayload,
        savedPasswordEntries: [SavedPasswordSummary],
        emailSuggestions: [PasswordEmailSuggestion],
        generatedPassword: String?,
        selectedSuggestionIndex: Int,
        fillContext: PasswordDocumentContext? = nil
    ) {
        self.focus = focus
        self.savedPasswordEntries = savedPasswordEntries
        self.emailSuggestions = emailSuggestions
        self.generatedPassword = generatedPassword
        self.selectedSuggestionIndex = selectedSuggestionIndex
        self.fillContext = fillContext
    }

    var suggestions: [PasswordAutofillSuggestion] {
        var items: [PasswordAutofillSuggestion] = []

        if let generatedPassword {
            items.append(.generatedPassword(host: focus.hostname, password: generatedPassword))
        }

        items.append(contentsOf: savedPasswordEntries.prefix(4).map(PasswordAutofillSuggestion.savedCredential))
        items.append(contentsOf: emailSuggestions.prefix(4).map(PasswordAutofillSuggestion.email))

        return items
    }
}

struct PasswordSavePromptDetails: Equatable {
    let title: String
    let message: String
    let confirmButtonTitle: String
    let neverButtonTitle: String
    let showsSecurityWarning: Bool
    /// ADR 0007: the vault's actual protection level, stated at the moment
    /// of decision. Separate from `message` so the decision copy above stays
    /// stable; the sheet presents both. Never claim Touch ID protection the
    /// runtime probe did not confirm.
    let protectionNote: String
}

/// Injectable operations for `PasswordAutofillCoordinator.autofill` only,
/// so tests can control the async authentication delay (and simulate
/// navigation mid-auth) without OS auth or the Keychain. The defaults
/// delegate to the shared password service; every other service call the
/// coordinator makes is unchanged.
struct PasswordAutofillOperations: Sendable {
    let authenticate: @Sendable (String) async -> Bool
    let revealPassword: @Sendable (SavedPasswordSummary) throws -> String
    let markUsed: @Sendable (SavedPasswordSummary) -> Void

    static let live = PasswordAutofillOperations(
        authenticate: { reason in
            await PasswordManagerService.shared.authenticate(reason: reason)
        },
        revealPassword: { entry in
            try PasswordManagerService.shared.revealPassword(for: entry)
        },
        markUsed: { entry in
            PasswordManagerService.shared.markUsed(entry)
        }
    )
}
