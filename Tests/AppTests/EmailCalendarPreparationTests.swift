import Foundation
import MessageContent
import Testing
@testable import Tern

@MainActor @Suite struct EmailCalendarPreparationTests {
    @Test func unchangedMailReusesTextAndDatesButZoneAndLifetimeChangesInvalidate() async throws {
        let worker = EmailCalendarPreparation()
        let zone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let otherZone = try #require(TimeZone(identifier: "America/New_York"))
        let first = try await worker.prepare([source()], accountID: "a", lifetime: "one", timeZone: zone)
        #expect(first.messages.first?.text.contains("Planning meeting") == true)
        #expect(first.messages.first?.text.contains("quoted date") == false)
        let again = try await worker.prepare([source()], accountID: "a", lifetime: "one", timeZone: zone)
        #expect(first.messages == again.messages)
        #expect(first.revision == again.revision)
        #expect(await worker.preparationCount == 1)
        let changedZone = try await worker.prepare([source()], accountID: "a", lifetime: "one", timeZone: otherZone)
        #expect(changedZone.revision != first.revision)
        #expect(await worker.preparationCount == 2)
        _ = try await worker.prepare([source()], accountID: "a", lifetime: "two", timeZone: zone)
        #expect(await worker.preparationCount == 3)
        await worker.remove(accountID: "a")
        #expect(await worker.cost == 0)
    }

    @Test func contentAndSenderOffsetChangesProduceNewCardsWithoutLosingReplyAddressBehavior() async throws {
        let worker = EmailCalendarPreparation()
        let zone = try #require(TimeZone(identifier: "Europe/Vienna"))
        let first = try await worker.prepare([source()], accountID: "a", lifetime: "one", timeZone: zone)
        let offset = try await worker.prepare([source(offset: -28_800)], accountID: "a", lifetime: "one", timeZone: zone)
        #expect(first.revision != offset.revision)
        let model = EmailCalendarModel()
        model.update(prepared: first, addresses: [], timeZone: zone)
        let revision = model.revision
        model.update(prepared: first, addresses: ["owner@example.invalid"], timeZone: zone)
        #expect(model.revision == revision)
        #expect(model.addresses == ["owner@example.invalid"])
        let generation = model.beginPreparation()
        _ = model.beginPreparation()
        #expect(!model.acceptsPreparation(generation))
    }

    @Test func preparationHonorsCancellationAndByteBudget() async throws {
        let worker = EmailCalendarPreparation(capacity: 1)
        let work = Task {
            try Task.checkCancellation()
            return try await worker.prepare([source()], accountID: "a", lifetime: "one", timeZone: .gmt)
        }
        work.cancel()
        await #expect(throws: CancellationError.self) { try await work.value }
        _ = try await worker.prepare([source()], accountID: "a", lifetime: "one", timeZone: .gmt)
        #expect(await worker.cost == 0)
    }

    private func source(offset: Int? = nil) -> EmailCalendarSource {
        EmailCalendarSource(id: "message", subject: "Planning", date: Date(timeIntervalSince1970: 1_790_000_000),
            html: "<p>Planning meeting on November 4, 2027 at 10 am in Room 2.</p><blockquote>quoted date: May 5, 2028</blockquote>",
            plainText: nil, invitations: [], sender: "River <river@example.invalid>",
            allowsDateDetection: true, dateHeaderOffset: offset)
    }
}
