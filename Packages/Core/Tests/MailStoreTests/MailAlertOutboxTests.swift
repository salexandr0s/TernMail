import Foundation
import Testing
@testable import MailStore

@Suite struct MailAlertOutboxTests {
    @Test func processingCursorAndExactDeliveryReferencesCommitAtomically() async throws {
        let store = try AccountStore.inMemory()
        try await store.save(AccountRecord(id: "a", email: "me@example.com", displayName: nil, grantedScopes: [], addedAt: .now))
        try await store.setMailAlertBaseline(accountID: "a", historyID: 10, at: .now)
        let alert = PendingMailAlert(accountID: "a", messageID: "m", threadID: "t", addedHistoryID: 15)
        #expect(try await store.enqueueMailAlerts(accountID: "a", expectedHistoryID: 10, to: 20, alerts: [alert]))
        #expect(try await store.mailAlertWatermark(accountID: "a")?.historyID == 20)
        #expect(try await store.pendingMailAlerts() == [alert])
        #expect(try await store.enqueueMailAlerts(accountID: "a", expectedHistoryID: 10, to: 20, alerts: [alert]) == false)
        let invalid = PendingMailAlert(accountID: "b", messageID: "foreign", threadID: "t", addedHistoryID: 25)
        await #expect(throws: MailPreferencesError.invalidRecord) {
            try await store.enqueueMailAlerts(accountID: "a", expectedHistoryID: 20, to: 30, alerts: [invalid])
        }
        #expect(try await store.mailAlertWatermark(accountID: "a")?.historyID == 20)
        try await store.resetMailAlertDeliveryBaseline(accountID: "a", historyID: 20, at: .now)
        #expect(try await store.pendingMailAlerts().isEmpty)
    }
}
