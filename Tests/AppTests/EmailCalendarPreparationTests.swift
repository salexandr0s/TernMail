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

    @Test func forwardedBookingHasSeparateEvidenceAndCountsTowardTheCacheBudget() async throws {
        func booking(_ day: Int, padding: String = "") -> EmailCalendarSource {
            EmailCalendarSource(id: "forward", subject: "Fwd: Booking", date: Date(timeIntervalSince1970: 1_790_000_000),
                html: """
                <p>Sharing my booking.</p><div class="gmail_quote">
                <p>---------- Forwarded message ---------<br>From: Airline<br>Date: July 1, 2031<br>Subject: Booking</p>
                <p>Flight to Vienna July \(day), 2031 at 14:00 UTC. \(padding)</p></div>
                """, plainText: nil, invitations: [], sender: "Passenger <passenger@example.invalid>",
                allowsDateDetection: true, dateHeaderOffset: 0)
        }
        let worker = EmailCalendarPreparation()
        let first = try await worker.prepare([booking(15)], accountID: "a", lifetime: "one", timeZone: .gmt)
        let message = try #require(first.messages.first)
        #expect(!message.text.contains("Flight to Vienna"))
        #expect(message.forwardedText?.contains("Flight to Vienna July 15, 2031") == true)
        #expect(first.detections[message.id]?.isEmpty == true)
        let changed = try await worker.prepare([booking(16)], accountID: "a", lifetime: "one", timeZone: .gmt)
        #expect(first.revision != changed.revision)
        #expect(await worker.preparationCount == 2)

        let bounded = EmailCalendarPreparation(capacity: 1_000)
        _ = try await bounded.prepare([booking(15, padding: String(repeating: "x", count: 1_000))],
                                      accountID: "a", lifetime: "one", timeZone: .gmt)
        #expect(await bounded.cost == 0)
    }

    private func source(offset: Int? = nil) -> EmailCalendarSource {
        EmailCalendarSource(id: "message", subject: "Planning", date: Date(timeIntervalSince1970: 1_790_000_000),
            html: "<p>Planning meeting on November 4, 2027 at 10 am in Room 2.</p><blockquote>quoted date: May 5, 2028</blockquote>",
            plainText: nil, invitations: [], sender: "River <river@example.invalid>",
            allowsDateDetection: true, dateHeaderOffset: offset)
    }
}
