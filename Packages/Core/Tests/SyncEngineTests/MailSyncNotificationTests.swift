import Foundation
import GmailAPI
import Testing
@testable import SyncEngine

@Suite struct MailSyncNotificationTests {
    @Test func onlyAddedMessagesBecomeNotificationCandidates() throws {
        let records = try JSONDecoder().decode([HistoryRecord].self, from: Data(#"""
            [{"id":"20","messagesAdded":[{"message":{"id":"new","threadId":"thread"}}]},
             {"id":"21","labelsAdded":[{"message":{"id":"existing","threadId":"thread"},"labelIds":["UNREAD"]}]},
             {"id":"22","messagesAdded":[{"message":{"id":"new","threadId":"thread"}}]},
             {"id":"23","messagesDeleted":[{"message":{"id":"gone","threadId":"thread"}}]}]
            """#.utf8))
        #expect(MailSyncNotification.addedMessageHistory(records) == ["new": 22])
    }
}
