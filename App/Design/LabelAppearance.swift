import Foundation
import GmailAPI
import MailStore
import Observation

/// Local label icons. Gmail's label API stores names and colors only.
@MainActor
@Observable
final class LabelAppearance {
    struct Icon: Identifiable, Sendable {
        let systemImage: String
        let name: String
        var id: String { systemImage }
    }

    nonisolated static let icons: [Icon] = [
        .init(systemImage: "tag", name: "Label"),
        .init(systemImage: "folder", name: "Folder"),
        .init(systemImage: "briefcase", name: "Work"),
        .init(systemImage: "house", name: "Home"),
        .init(systemImage: "person", name: "Personal"),
        .init(systemImage: "person.2", name: "People"),
        .init(systemImage: "star", name: "Star"),
        .init(systemImage: "heart", name: "Heart"),
        .init(systemImage: "flag", name: "Flag"),
        .init(systemImage: "bookmark", name: "Bookmark"),
        .init(systemImage: "checkmark.seal", name: "Approved"),
        .init(systemImage: "clock", name: "Later"),
        .init(systemImage: "calendar", name: "Calendar"),
        .init(systemImage: "doc.text", name: "Documents"),
        .init(systemImage: "book", name: "Reading"),
        .init(systemImage: "graduationcap", name: "Education"),
        .init(systemImage: "cart", name: "Shopping"),
        .init(systemImage: "creditcard", name: "Payments"),
        .init(systemImage: "gift", name: "Gifts"),
        .init(systemImage: "airplane", name: "Travel"),
        .init(systemImage: "car", name: "Car"),
        .init(systemImage: "leaf", name: "Nature"),
        .init(systemImage: "lightbulb", name: "Ideas"),
        .init(systemImage: "tray", name: "Inbox")
    ]

    static let shared = LabelAppearance(
        persists: !ProcessInfo.processInfo.arguments.contains("--ui-audit")
    )
    static let storageKey = "labelIcons"

    private struct Preference: Codable, Equatable, Sendable {
        let icon: String
        let revision: Int
    }

    private struct Alias: Sendable {
        let accountID: String
        let temporaryID: String
        let labelID: String
    }

    private var preferences: [String: [String: Preference]]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persists: Bool

    init(defaults: UserDefaults = .standard, persists: Bool = true) {
        self.defaults = defaults
        self.persists = persists
        if persists, let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String: [String: Preference]].self, from: data) {
            preferences = stored
        } else {
            preferences = [:]
        }
    }

    func icon(for label: LabelRecord) -> String {
        let icon = preferences[label.accountID]?[label.id]?.icon ?? "tag"
        return Self.icons.contains { $0.systemImage == icon } ? icon : "tag"
    }

    /// Uncolored labels use a stable local palette; these fallbacks aren't saved to Gmail.
    func badgeColor(for label: LabelRecord) -> LabelColor {
        if let background = label.backgroundColor,
           let color = LabelColor(backgroundColor: background) { return color }

        let index: Int
        switch label.id {
        case "CATEGORY_PERSONAL": index = 12
        case "CATEGORY_PROMOTIONS": index = 14
        case "CATEGORY_UPDATES": index = 13
        case "CATEGORY_SOCIAL": index = 15
        case "CATEGORY_FORUMS": index = 9
        case "CATEGORY_PURCHASES": index = 11
        default:
            let hash = label.id.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
            index = 8 + Int(hash % 8)
        }
        return LabelColor.grid[index]
    }

    func setIcon(_ icon: String, labelID: String, accountID: String) {
        guard Self.icons.contains(where: { $0.systemImage == icon }) else { return }
        let revision = (preferences.values.flatMap(\.values).map(\.revision).max() ?? 0) + 1
        preferences[accountID, default: [:]][labelID] = Preference(icon: icon, revision: revision)
        persist()
    }

    /// Follows Gmail's permanent IDs. Account startup calls this before the
    /// engine clears saved aliases; the sidebar calls it as labels change.
    /// Revisions preserve edits made while this read is in flight.
    func reconcile(using cache: MailCache) async {
        let pending = preferences.flatMap { accountID, icons in
            icons.keys.filter(LabelRules.isTemporary).map { (accountID: accountID, labelID: $0) }
        }
        guard !pending.isEmpty else { return }
        guard let aliases = try? await cache.read({ tx in
            try pending.map { item in
                Alias(
                    accountID: item.accountID,
                    temporaryID: item.labelID,
                    labelID: try tx.resolvedLabelID(item.labelID, accountID: item.accountID)
                )
            }
        }) else { return }

        var updated = preferences
        for alias in aliases where alias.temporaryID != alias.labelID {
            guard let pending = updated[alias.accountID]?[alias.temporaryID] else { continue }
            let current = updated[alias.accountID]?[alias.labelID]
            if current == nil || pending.revision > (current?.revision ?? 0) {
                updated[alias.accountID, default: [:]][alias.labelID] = pending
            }
            updated[alias.accountID]?[alias.temporaryID] = nil
        }
        guard updated != preferences else { return }
        preferences = updated
        persist()
    }

    private func persist() {
        guard persists, let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
