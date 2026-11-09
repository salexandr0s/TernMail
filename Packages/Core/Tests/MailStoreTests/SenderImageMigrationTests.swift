import Foundation
import GRDB
import Testing
@testable import MailStore

@Suite struct SenderImageMigrationTests {
    @Test func oldMessagesStayUntrustedAndCachedBodiesRequestReceiverEvidenceOnce() throws {
        let writer = try DatabaseQueue()
        try Schema.cacheMigrator.migrate(writer, upTo: "newsletters-v1")
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO message(accountID,id,threadID,historyID,date,snippet,sender,recipients,subject,sizeEstimate)
                VALUES ('account','message','thread',1,0,'','trusted@example.com','recipient@example.com','',0)
                """)
            try db.execute(sql: "INSERT INTO messageBody(accountID,messageID,plainText,fetchedAt,enrichedAt) VALUES ('account','message','cached mail',0,1)")
        }
        try Schema.cacheMigrator.migrate(writer)
        try writer.read { db in
            let record = try #require(try MessageRecord.fetchOne(db, key: ["accountID": "account", "id": "message"]))
            #expect(record.verifiedImageSender == nil)
            #expect(try String.fetchOne(db, sql: "SELECT plainText FROM messageBody") == "cached mail")
            #expect(try CacheTransaction(db: db).bodyEnrichedAt(messageID: "message", accountID: "account") == nil)
        }
    }
}
