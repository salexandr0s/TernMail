import Foundation
import GmailAPI
import Testing
@testable import Tern

@Suite @MainActor struct CalendarManagementTests {
    @Test func personalColorDoesNotRequireOwnerOrManagementAccess() async throws {
        let service = ManagementCalendarService(role: "reader")
        let snapshot = await service.entry
        let client = CalendarManagementClient(service: service) { feature in
            guard feature == .calendar else { throw CalendarModelError.readOnly }
        }
        try await client.update(snapshot, title: "Team", colorHex: "#00ff00")
        let calls = await service.writes
        #expect(calls == [.init(kind: "list", etag: "list-version", fields: ["backgroundColor": .string("#00ff00")])])
    }

    @Test func renameUsesCalendarVersionAndColorUsesCalendarListVersion() async throws {
        let service = ManagementCalendarService()
        let client = CalendarManagementClient(service: service) { _ in }
        try await client.update(await service.entry, title: "New title", colorHex: "#00ff00")
        let calls = await service.writes
        #expect(calls == [
            .init(kind: "calendar", etag: "resource-version", fields: ["summary": .string("New title")]),
            .init(kind: "list", etag: "list-version", fields: ["backgroundColor": .string("#00ff00")]),
        ])
    }

    @Test func staleSharingVersionAndNewPublicGrantNeverWrite() async throws {
        let service = ManagementCalendarService()
        let client = CalendarManagementClient(service: service) { _ in }
        let snapshot = await service.entry
        await #expect(throws: CalendarManagementError.changed) {
            try await client.saveShare(.init(id: "user:guest", email: "guest@example.invalid", role: "writer", etag: "old"), calendar: snapshot)
        }
        await #expect(throws: CalendarManagementError.newShareMustBePerson) {
            try await client.saveShare(.init(id: "", email: "", role: "reader", scopeType: "default"), calendar: snapshot)
        }
        #expect(await service.writes.isEmpty)
    }

    @Test func sharingChangesOnlyTheReviewedRole() async throws {
        let service = ManagementCalendarService()
        let client = CalendarManagementClient(service: service) { _ in }
        let snapshot = await service.entry
        let shares = try await client.shares(snapshot)
        var reviewed = try #require(shares.first)
        #expect(reviewed.etag == "acl-version")
        reviewed.role = "writer"
        try await client.saveShare(reviewed, calendar: snapshot)
        #expect(await service.writes == [.init(kind: "acl", etag: "acl-version", fields: ["role": .string("writer")])])
    }

    @Test func uncertainCalendarCreationIsNotRetried() async throws {
        let service = ManagementCalendarService()
        let client = CalendarManagementClient(service: service) { _ in }
        await #expect(throws: CalendarManagementError.unknownOutcome("created the calendar")) {
            try await client.create(title: "Project", timeZone: "Europe/Vienna")
        }
        #expect(await service.createAttempts == 1)
    }

    @Test func changedOwnershipCannotTurnRemovalIntoDeletion() async throws {
        let service = ManagementCalendarService(role: "owner")
        let client = CalendarManagementClient(service: service) { _ in }
        var stale = await service.entry
        stale.accessRole = "reader"
        await #expect(throws: CalendarManagementError.changed) { try await client.remove(stale) }
        #expect(await service.writes.isEmpty)
    }

    @Test func permissionLossDuringReadsPreventsTheWrite() async throws {
        let service = ManagementCalendarService()
        var allowed = 2
        let client = CalendarManagementClient(service: service) { _ in
            guard allowed > 0 else { throw CalendarModelError.unavailable }
            allowed -= 1
        }
        await #expect(throws: CalendarModelError.self) {
            try await client.update(await service.entry, title: "New", colorHex: "#4285f4")
        }
        #expect(await service.writes.isEmpty)
    }

    @Test func schedulingBindingsPersistTheExistingWorkingHoursValue() throws {
        let suite = "CalendarManagementTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CalendarModel(app: nil, defaults: defaults)
        model.workingStartHour = 20
        #expect(model.workingHours.startMinute == 1200)
        #expect(model.workingEndHour == 21)
        model.workingEndHour = 8
        #expect(model.workingStartHour == 7)
        model.workingWeekdays = [0, 2, 4, 8]
        model.timeZoneID = "Europe/Vienna"
        let restored = CalendarModel(app: nil, defaults: defaults)
        #expect(restored.workingHours == model.workingHours)
        #expect(restored.workingWeekdays == [2, 4])
    }
}

private actor ManagementCalendarService: CalendarService {
    struct Write: Equatable {
        var kind: String
        var etag: String?
        var fields: [String: CalendarJSON]
    }
    var entry: GoogleCalendarEntry
    var resource: GoogleCalendarEntry
    var writes: [Write] = []
    var createAttempts = 0
    init(role: String = "owner") {
        entry = GoogleCalendarEntry(id: "team", summary: "Team", timeZone: "Europe/Vienna", accessRole: role, backgroundColor: "#4285f4")
        entry.etag = "list-version"
        resource = GoogleCalendarEntry(id: "team", summary: "Team", timeZone: "Europe/Vienna")
        resource.etag = "resource-version"
    }
    func calendarList(pageToken: String?, syncToken: String?) async throws -> CalendarListPage { .init(items: [entry]) }
    func calendar(calendarID: String) async throws -> GoogleCalendarEntry { resource }
    func createCalendar(summary: String, timeZone: String) async throws -> GoogleCalendarEntry {
        createAttempts += 1
        throw GmailError.transport(.networkConnectionLost)
    }
    func patchCalendar(calendarID: String, fields: [String: CalendarJSON], etag: String?) async throws -> GoogleCalendarEntry {
        writes.append(.init(kind: "calendar", etag: etag, fields: fields))
        for (key, value) in fields { resource.rawValue[key] = value }
        return resource
    }
    func patchCalendarList(calendarID: String, fields: [String: CalendarJSON], etag: String?) async throws -> GoogleCalendarEntry {
        writes.append(.init(kind: "list", etag: etag, fields: fields))
        for (key, value) in fields { entry.rawValue[key] = value }
        return entry
    }
    func acl(calendarID: String, pageToken: String?) async throws -> CalendarACLPage {
        var rule = CalendarACLRule(id: "user:guest", role: "reader", scopeValue: "guest@example.invalid")
        rule.etag = "acl-version"
        return .init(items: [rule])
    }
    func patchACL(calendarID: String, ruleID: String, fields: [String: CalendarJSON], etag: String?) async throws -> CalendarACLRule {
        writes.append(.init(kind: "acl", etag: etag, fields: fields))
        return CalendarACLRule(id: ruleID, role: fields["role"]?.stringValue ?? "reader", scopeValue: "guest@example.invalid")
    }
}
