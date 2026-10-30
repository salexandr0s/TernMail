import AppIntents
import Foundation
import MailStore

struct MailProfileEntity: AppEntity {
    static let allID = "__all__"
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Mail profile")
    static let defaultQuery = MailProfileEntityQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct MailProfileEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MailProfileEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [MailProfileEntity] {
        let all = MailProfileEntity(id: MailProfileEntity.allID, name: "All accounts")
        guard let store = try Self.store() else { return [all] }
        return [all] + (try await store.mailProfiles()).map { MailProfileEntity(id: $0.id, name: $0.name) }
    }
    private static func store() throws -> AccountStore? {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        let url = support.appending(path: "Tern/config.sqlite")
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try AccountStore.open(at: url)
    }
}

struct MailFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Tern Profile"
    static let description = IntentDescription("Show accounts and new-mail notifications from one Tern profile.")

    @Parameter(title: "Profile") var profile: MailProfileEntity?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Tern profile", subtitle: "\(profile?.name ?? "All accounts")")
    }

    var appContext: FocusFilterAppContext {
        guard let profile, profile.id != MailProfileEntity.allID else { return FocusFilterAppContext() }
        // Other notification families, including Calendar, have no mail prefix.
        let unrelated = NSPredicate(format: "NOT (SELF BEGINSWITH %@)", "tern.mail.profile:")
        let matching = NSPredicate(format: "SELF == %@", "tern.mail.profile:" + profile.id)
        return FocusFilterAppContext(notificationFilterPredicate: NSCompoundPredicate(orPredicateWithSubpredicates: [unrelated, matching]))
    }

    func perform() async throws -> some IntentResult {
        if let profile, profile.id != MailProfileEntity.allID {
            let available = try await MailProfileEntityQuery().entities(for: [profile.id])
            guard !available.isEmpty else { throw SetFocusFilterIntentError.notFound }
        }
        let id = profile.flatMap { $0.id == MailProfileEntity.allID ? nil : $0.id }
        await MainActor.run {
            let defaults = UserDefaults.standard
            defaults.set(id, forKey: AccountPreferencesModel.activeProfileKey)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }
        return .result()
    }
}
