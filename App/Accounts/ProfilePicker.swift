import AppKit
import SwiftUI

/// Shows mail from one profile's accounts, or from every account. The toolbar
/// shows the active profile's name unless the window is compact.
struct ProfilePicker: View {
    @Bindable var model: AccountPreferencesModel
    var isCompact = false

    static let allAccounts = "All Accounts"

    /// How wide the toolbar draws the active profile's name, or nil while
    /// there are no profiles to pick from.
    static func nameWidth(_ model: AccountPreferencesModel) -> CGFloat? {
        guard !model.profiles.isEmpty else { return nil }
        let name = model.profiles.first { $0.id == model.activeProfileID }?.name ?? allAccounts
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return (name as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    var body: some View {
        let active = model.profiles.first { $0.id == model.activeProfileID }
        Menu {
            ProfileChoices(model: model).pickerStyle(.inline)
        } label: {
            let label = Label(active?.name ?? Self.allAccounts, systemImage: active?.symbol ?? "tray.2")
            // Toolbars hide menu titles by default; the active profile is what this menu says.
            if isCompact { label.labelStyle(.iconOnly) } else { label.labelStyle(.titleAndIcon) }
        }
        .fixedSize()
        .help("Show mail from one profile's accounts")
        .accessibilityLabel("Profile")
        .accessibilityValue(active?.name ?? Self.allAccounts)
    }
}

/// The profile choices, for the toolbar's picker and for the mail menu that
/// holds them in a narrow window.
struct ProfileChoices: View {
    @Bindable var model: AccountPreferencesModel

    var body: some View {
        Picker("Profile", selection: Binding(model.activeProfileID, set: model.selectProfile)) {
            Label(ProfilePicker.allAccounts, systemImage: "tray.2").tag(String?.none)
            ForEach(model.profiles) { profile in Label(profile.name, systemImage: profile.symbol).tag(Optional(profile.id)) }
        }
    }
}
