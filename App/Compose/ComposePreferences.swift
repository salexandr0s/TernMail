import Foundation
import MessageContent

enum QuoteSelectionPolicy: String, CaseIterable {
    case ask, always, never
}

enum ComposePreferences {
    static let fontKey = "composeDefaultFont"
    static let fullAddressesKey = "composeFullRecipientAddresses"
    static let markdownKey = "composeMarkdown"
    static let quoteKey = "composeQuoteSelection"
    static let defaultAccountKey = "composeDefaultAccount"
    static let formatBarKey = "composeShowsFormatting"

    static var font: ComposeFont {
        ComposeFont(rawValue: UserDefaults.standard.string(forKey: fontKey) ?? "") ?? .sansSerif
    }

    static var markdown: Bool { UserDefaults.standard.object(forKey: markdownKey) as? Bool ?? true }
    static var quoteSelection: QuoteSelectionPolicy {
        QuoteSelectionPolicy(rawValue: UserDefaults.standard.string(forKey: quoteKey) ?? "") ?? .ask
    }
    static var defaultAccountID: String? {
        let value = UserDefaults.standard.string(forKey: defaultAccountKey) ?? ""
        return value.isEmpty ? nil : value
    }
}

extension Notification.Name {
    static let ternComposePreferencesChanged = Notification.Name("TernComposePreferencesChanged")
}
