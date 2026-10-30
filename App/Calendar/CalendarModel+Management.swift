import Foundation
import GmailAPI

extension CalendarModel {
    var workingStartHour: Int {
        get { workingHours.startMinute / 60 }
        set {
            var hours = workingHours
            hours.startMinute = min(23, max(0, newValue)) * 60
            hours.endMinute = max(hours.endMinute, hours.startMinute + 60)
            workingHours = hours
        }
    }
    var workingEndHour: Int {
        get { workingHours.endMinute / 60 }
        set {
            var hours = workingHours
            hours.endMinute = min(24, max(1, newValue)) * 60
            hours.startMinute = min(hours.startMinute, hours.endMinute - 60)
            workingHours = hours
        }
    }
    var workingWeekdays: Set<Int> {
        get { workingHours.weekdays }
        set { workingHours.weekdays = newValue.intersection(1...7) }
    }
    var timeZoneID: String {
        get { workingHours.timeZoneIdentifier }
        set { workingHours.timeZoneIdentifier = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func createCalendar(accountID: String, title: String) async throws {
        let client = try managementClient(accountID: accountID)
        try await finishManagement { try await client.create(title: title, timeZone: timeZoneID) }
    }
    func updateCalendar(_ calendar: CalendarDisplayCalendar, title: String, colorHex: String) async throws {
        let client = try managementClient(accountID: calendar.accountID)
        try await finishManagement { try await client.update(calendar.entry, title: title, colorHex: colorHex) }
    }
    func removeCalendar(_ calendar: CalendarDisplayCalendar) async throws {
        let client = try managementClient(accountID: calendar.accountID)
        try await finishManagement { try await client.remove(calendar.entry) }
    }
    func addCalendar(accountID: String, id: String) async throws {
        let client = try managementClient(accountID: accountID)
        try await finishManagement { try await client.add(id: id) }
    }
    func shares(_ calendar: CalendarDisplayCalendar) async throws -> [CalendarShare] {
        try await managementClient(accountID: calendar.accountID).shares(calendar.entry)
    }
    func saveShare(_ share: CalendarShare, calendar: CalendarDisplayCalendar) async throws {
        let client = try managementClient(accountID: calendar.accountID)
        try await finishManagement { try await client.saveShare(share, calendar: calendar.entry) }
    }
    func deleteShare(_ share: CalendarShare, calendar: CalendarDisplayCalendar) async throws {
        let client = try managementClient(accountID: calendar.accountID)
        try await finishManagement { try await client.deleteShare(share, calendar: calendar.entry) }
    }

    private func managementClient(accountID: String) throws -> CalendarManagementClient {
        guard let service = services[accountID] else { throw CalendarModelError.unavailable }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-audit-calendar"), service is CalendarAuditService {
            return CalendarManagementClient(service: service, requireAccess: { _ in })
        }
#endif
        return CalendarManagementClient(service: service) { [weak self] feature in
            guard let self, let app = self.app else { throw CalendarModelError.unavailable }
            let account = try await app.calendarAccounts().first(where: { $0.id == accountID })
            guard self.services[accountID] != nil, app.calendarService(for: accountID) != nil, let account,
                  account.enabledFeatures.contains(AccountFeature.calendar.rawValue),
                  account.enabledFeatures.contains(feature.rawValue),
                  GoogleScopes.isCovered(.calendar, by: account.grantedScopes),
                  GoogleScopes.isCovered(feature, by: account.grantedScopes) else { throw CalendarModelError.unavailable }
        }
    }

    private func finishManagement(_ operation: () async throws -> Void) async throws {
        do {
            try await operation()
            await refresh()
        } catch {
            // A multi-request change can partly succeed. Reload the actual state.
            await refresh()
            throw error
        }
    }
}

/// Management actions are online operations. Every write uses current account
/// permissions and remote resource versions; uncertain writes are never replayed.
@MainActor
struct CalendarManagementClient {
    let service: any CalendarService
    let requireAccess: @MainActor (AccountFeature) async throws -> Void

    func create(title: String, timeZone: String) async throws {
        let title = try Self.validTitle(title)
        guard TimeZone(identifier: timeZone) != nil else { throw CalendarManagementError.invalidTimeZone }
        try await requireAccess(.calendarManagement)
        do { _ = try await service.createCalendar(summary: title, timeZone: timeZone) }
        catch { throw Self.writeError(error, action: "created the calendar") }
    }

    func add(id: String) async throws {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !id.contains(where: \.isWhitespace), !id.contains("://") else { throw CalendarManagementError.invalidCalendarID }
        if try await entries().contains(where: { $0.id == id || id == "primary" && $0.primary == true }) { return }
        try await requireAccess(.calendar)
        do { _ = try await service.insertCalendarList(calendarID: id) }
        catch { throw Self.writeError(error, action: "added the calendar") }
    }

    func update(_ snapshot: GoogleCalendarEntry, title: String, colorHex: String) async throws {
        let title = try Self.validTitle(title)
        guard colorHex.count == 7, colorHex.first == "#", UInt32(colorHex.dropFirst(), radix: 16) != nil else {
            throw CalendarManagementError.invalidColor
        }
        let entry = try await currentCalendar(snapshot.id)
        let rename = title != (snapshot.summary ?? snapshot.id)
        let recolor = colorHex.lowercased() != (snapshot.backgroundColor ?? "#4285f4").lowercased()
        var renamed = false
        if rename {
            guard entry.isOwner else { throw CalendarModelError.readOnly }
            try await requireAccess(.calendarManagement)
            let resource = try await service.calendar(calendarID: entry.id)
            guard resource.summary == snapshot.summary || resource.summary == title else { throw CalendarManagementError.changed }
            if resource.summary != title {
                try await requireAccess(.calendarManagement)
                do { _ = try await service.patchCalendar(calendarID: entry.id, fields: ["summary": .string(title)], etag: try Self.version(resource.etag)) }
                catch { throw Self.writeError(error, action: "changed the calendar name") }
                renamed = true
            }
        }
        if recolor {
            do {
                let latest = renamed ? try await currentCalendar(entry.id) : entry
                let originalColor = (snapshot.backgroundColor ?? "#4285f4").lowercased()
                let latestColor = (latest.backgroundColor ?? "#4285f4").lowercased()
                guard latestColor == originalColor || latestColor == colorHex.lowercased() else { throw CalendarManagementError.changed }
                if latestColor != colorHex.lowercased() {
                    try await requireAccess(.calendar)
                    _ = try await service.patchCalendarList(calendarID: entry.id,
                        fields: ["backgroundColor": .string(colorHex.lowercased())], etag: try Self.version(latest.etag))
                }
            } catch {
                if renamed { throw CalendarManagementError.partial("The calendar name was saved. The color change could not be confirmed; refresh before trying again.") }
                throw Self.writeError(error, action: "changed the calendar color")
            }
        }
    }

    func remove(_ snapshot: GoogleCalendarEntry) async throws {
        let entry = try await currentCalendar(snapshot.id)
        guard entry.primary != true, entry.id != "primary" else { throw CalendarManagementError.primaryCalendar }
        // A changed ownership role changes the meaning of Remove vs Delete.
        guard entry.isOwner == snapshot.isOwner else { throw CalendarManagementError.changed }
        if entry.isOwner {
            try await requireAccess(.calendarManagement)
            let resource = try await service.calendar(calendarID: entry.id)
            try await requireAccess(.calendarManagement)
            do { try await service.deleteCalendar(calendarID: entry.id, etag: try Self.version(resource.etag)) }
            catch { throw Self.writeError(error, action: "deleted the calendar") }
        } else {
            try await requireAccess(.calendar)
            do { try await service.deleteCalendarList(calendarID: entry.id) }
            catch { throw Self.writeError(error, action: "removed the calendar from your list") }
        }
    }

    func shares(_ snapshot: GoogleCalendarEntry) async throws -> [CalendarShare] {
        let entry = try await currentCalendar(snapshot.id)
        guard entry.isOwner else { return [] }
        return try await rules(entry.id).map { rule in
            CalendarShare(id: rule.id, email: rule.scopeValue ?? "", role: rule.role,
                          scopeType: rule.scopeType ?? "user", etag: rule.etag)
        }.sorted { ($0.role == "owner" ? 0 : 1, $0.email.localizedLowercase) < ($1.role == "owner" ? 0 : 1, $1.email.localizedLowercase) }
    }

    func saveShare(_ share: CalendarShare, calendar snapshot: GoogleCalendarEntry) async throws {
        guard ["freeBusyReader", "reader", "writer"].contains(share.role) else { throw CalendarManagementError.invalidRole }
        let entry = try await currentCalendar(snapshot.id)
        guard entry.isOwner else { throw CalendarModelError.readOnly }
        let currentRules = try await rules(entry.id)
        if share.id.isEmpty {
            guard share.scopeType == "user" else { throw CalendarManagementError.newShareMustBePerson }
            let email = share.email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.isEmail(email) else { throw CalendarManagementError.invalidEmail }
            if let existing = currentRules.first(where: { $0.scopeType == "user" && $0.scopeValue?.caseInsensitiveCompare(email) == .orderedSame }) {
                guard existing.role == share.role else { throw CalendarManagementError.alreadyShared }
                return
            }
            try await requireAccess(.calendarSharing)
            do { _ = try await service.insertACL(calendarID: entry.id, rule: CalendarACLRule(role: share.role, scopeValue: email), sendNotifications: true) }
            catch { throw Self.writeError(error, action: "shared the calendar") }
        } else {
            let current = try Self.reviewedRule(share, in: currentRules)
            if ["default", "domain"].contains(current.scopeType ?? ""),
               Self.roleRank(share.role) > Self.roleRank(current.role) { throw CalendarManagementError.wideSharing }
            guard current.role != share.role else { return }
            try await requireAccess(.calendarSharing)
            do { _ = try await service.patchACL(calendarID: entry.id, ruleID: current.id,
                fields: ["role": .string(share.role)], etag: try Self.version(current.etag)) }
            catch { throw Self.writeError(error, action: "changed sharing access") }
        }
    }

    func deleteShare(_ share: CalendarShare, calendar snapshot: GoogleCalendarEntry) async throws {
        let entry = try await currentCalendar(snapshot.id)
        guard entry.isOwner else { throw CalendarModelError.readOnly }
        let current = try Self.reviewedRule(share, in: await rules(entry.id))
        try await requireAccess(.calendarSharing)
        do { try await service.deleteACL(calendarID: entry.id, ruleID: current.id, etag: try Self.version(current.etag)) }
        catch { throw Self.writeError(error, action: "removed sharing access") }
    }

    private func currentCalendar(_ id: String) async throws -> GoogleCalendarEntry {
        guard let entry = try await entries().first(where: { $0.id == id }), entry.deleted != true else { throw CalendarModelError.unavailable }
        return entry
    }

    private func entries() async throws -> [GoogleCalendarEntry] {
        var result: [GoogleCalendarEntry] = [], token: String?
        var seen = Set<String>()
        repeat {
            try await requireAccess(.calendar)
            let page = try await service.calendarList(pageToken: token, syncToken: nil)
            try await requireAccess(.calendar)
            result += page.items.filter { $0.deleted != true }
            token = page.nextPageToken
            if let token, !seen.insert(token).inserted || seen.count > 100 { throw CalendarManagementError.incomplete }
        } while token != nil
        return result
    }

    private func rules(_ id: String) async throws -> [CalendarACLRule] {
        var result: [CalendarACLRule] = [], token: String?
        var seen = Set<String>()
        repeat {
            try await requireAccess(.calendarSharing)
            let page = try await service.acl(calendarID: id, pageToken: token)
            try await requireAccess(.calendarSharing)
            result += page.items
            token = page.nextPageToken
            if let token, !seen.insert(token).inserted || seen.count > 100 { throw CalendarManagementError.incomplete }
        } while token != nil
        return result
    }

    private static func reviewedRule(_ share: CalendarShare, in rules: [CalendarACLRule]) throws -> CalendarACLRule {
        guard let rule = rules.first(where: { $0.id == share.id }), rule.scopeType == share.scopeType,
              (rule.scopeValue ?? "").caseInsensitiveCompare(share.email) == .orderedSame,
              let shownVersion = share.etag, shownVersion == rule.etag else { throw CalendarManagementError.changed }
        guard rule.role != "owner" else { throw CalendarManagementError.ownerAccess }
        return rule
    }
    private static func version(_ etag: String?) throws -> String {
        guard let etag, !etag.isEmpty else { throw CalendarManagementError.incomplete }
        return etag
    }
    private static func validTitle(_ title: String) throws -> String {
        let result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw CalendarManagementError.emptyTitle }
        return result
    }
    private static func isEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } && !value.contains(where: \.isWhitespace)
            && !value.contains(where: { "<>,;\r\n".contains($0) })
    }
    private static func roleRank(_ role: String) -> Int { ["none", "freeBusyReader", "reader", "writer", "owner"].firstIndex(of: role) ?? 0 }
    private static func writeError(_ error: any Error, action: String) -> any Error {
        if error is CancellationError { return CalendarManagementError.unknownOutcome(action) }
        if let error = error as? GmailError {
            switch error {
            case .transport, .server, .decoding, .missingBatchPart: return CalendarManagementError.unknownOutcome(action)
            case .http(status: 412, reason: _): return CalendarManagementError.changed
            default: break
            }
        }
        return error
    }
}

enum CalendarManagementError: Error, Equatable, LocalizedError {
    case emptyTitle, invalidTimeZone, invalidCalendarID, invalidColor, primaryCalendar, invalidRole, invalidEmail
    case newShareMustBePerson, alreadyShared, wideSharing, ownerAccess, changed, incomplete
    case unknownOutcome(String), partial(String)
    var errorDescription: String? {
        switch self {
        case .emptyTitle: "Enter a calendar name."
        case .invalidTimeZone: "Enter a valid time zone, such as Europe/Vienna."
        case .invalidCalendarID: "Enter a Google calendar ID."
        case .invalidColor: "Choose a valid calendar color."
        case .primaryCalendar: "Your primary Google calendar cannot be removed here."
        case .invalidRole: "Choose availability, event details, or event editing access."
        case .invalidEmail: "Enter a complete email address."
        case .newShareMustBePerson: "Add a person's email address. Manage public or domain sharing in Google Calendar."
        case .alreadyShared: "This person already has access. Change their existing sharing entry."
        case .wideSharing: "Use Google Calendar settings to grant broader public or domain access."
        case .ownerAccess: "The calendar owner's access cannot be changed here."
        case .changed: "The calendar or sharing permissions changed. Reload the settings before saving."
        case .incomplete: "Google returned incomplete calendar settings. Refresh and try again."
        case .unknownOutcome(let action): "Google may have \(action), but Tern could not confirm it. Check Google Calendar before trying again."
        case .partial(let message): message
        }
    }
}
