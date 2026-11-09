import GRDB

enum MeetingPreparationSchema {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("meeting-preparation-preferences-v1") { db in
            try db.create(table: "meetingPreparationPreference") { t in
                t.column("eventAccountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("calendarID", .text).notNull()
                t.column("occurrenceKey", .text).notNull()
                t.column("occurrence", .jsonText).notNull()
                t.column("mailAccountID", .text).notNull().references("account", onDelete: .cascade)
                t.column("threadID", .text).notNull()
                t.column("choice", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("revision", .text).notNull()
                t.primaryKey(["eventAccountID", "calendarID", "occurrenceKey", "mailAccountID", "threadID"])
            }
            try db.create(index: "meetingPreparationMailAccount", on: "meetingPreparationPreference", columns: ["mailAccountID"])
        }
    }
}
