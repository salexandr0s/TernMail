import Foundation
import GRDB
import MessageContent

extension CacheTransaction {
    /// Writes a stored body's text into the search index.
    func indexBody(_ body: MessageBodyRecord) throws {
        try db.execute(
            sql: "UPDATE messageText SET body = ? WHERE accountID = ? AND messageID = ?",
            arguments: [SearchText.body(html: body.html, plainText: body.plainText), body.accountID, body.messageID]
        )
    }

    /// Conversations to list for a search: those with a cached message matching
    /// `query`, plus `included`, newest first. Only `included` when the query
    /// can't run locally.
    ///
    /// A conversation matches when one of its messages matches, and labels are
    /// read as Gmail last reported them, as Gmail's own search does. Spam and
    /// Trash are left out unless the query names them.
    public func searchThreads(
        _ query: SearchQuery,
        including included: Set<String> = [],
        accountID: String,
        timeZone: TimeZone,
        now: Date,
        limit: Int
    ) throws -> [ThreadRecord] {
        var conditions: [String] = []
        var arguments: StatementArguments = [accountID]
        if query.runsLocally, let root = query.root {
            var compiler = SearchCompiler(labelIDs: try labelIDsByName(accountID: accountID), timeZone: timeZone, now: now)
            let predicate = compiler.sql(root)
            var sql = """
                thread.id IN (
                    SELECT m.threadID FROM message m
                    JOIN messageText mt ON mt.accountID = m.accountID AND mt.messageID = m.id
                    WHERE m.accountID = ? AND \(predicate)
                """
            if !query.includesSpamAndTrash {
                sql += """
                     AND NOT EXISTS (
                        SELECT 1 FROM messageLabel x
                        WHERE x.accountID = m.accountID AND x.messageID = m.id AND x.labelID IN (?, ?))
                    """
                compiler.arguments += [SystemLabel.spam, SystemLabel.trash]
            }
            conditions.append(sql + ")")
            arguments += [accountID]
            arguments += compiler.arguments
        }
        if !included.isEmpty {
            conditions.append("thread.id IN (\(databaseQuestionMarks(count: included.count)))")
            arguments += StatementArguments(included.sorted())
        }
        guard !conditions.isEmpty else { return [] }
        arguments += [limit]
        return try ThreadRecord.fetchAll(db, sql: """
            SELECT thread.* FROM thread
            WHERE thread.accountID = ? AND (\(conditions.joined(separator: " OR ")))
            ORDER BY thread.lastDate DESC, thread.id
            LIMIT ?
            """, arguments: arguments)
    }

    /// Label IDs by name as `label:` writes it: any case, with spaces and
    /// slashes typed as hyphens.
    private func labelIDsByName(accountID: String) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for label in try labels(accountID: accountID) {
            result[SearchCompiler.normalizedLabelName(label.name), default: []].append(label.id)
        }
        return result
    }
}

extension MailCache {
    /// `CacheTransaction.searchThreads`, refreshed whenever the cache changes.
    public func searchResults(
        _ query: SearchQuery,
        including included: Set<String> = [],
        accountID: String,
        timeZone: TimeZone,
        now: Date,
        limit: Int
    ) -> AsyncThrowingStream<[ThreadRecord], any Error> {
        observe { db in
            try CacheTransaction(db: db).searchThreads(
                query, including: included, accountID: accountID, timeZone: timeZone, now: now, limit: limit
            )
        }
    }
}

/// Turns a query tree into an SQL condition on a message `m` and its search
/// text `mt`, collecting arguments in the order they appear.
struct SearchCompiler {
    let labelIDs: [String: [String]]
    let timeZone: TimeZone
    let now: Date
    var arguments: StatementArguments = []

    init(labelIDs: [String: [String]], timeZone: TimeZone, now: Date) {
        self.labelIDs = labelIDs
        self.timeZone = timeZone
        self.now = now
    }

    mutating func sql(_ node: SearchQuery.Node) -> String {
        switch node {
        case .all(let nodes):
            nodes.isEmpty ? "1" : "(" + nodes.map { sql($0) }.joined(separator: " AND ") + ")"
        case .any(let nodes):
            nodes.isEmpty ? "0" : "(" + nodes.map { sql($0) }.joined(separator: " OR ") + ")"
        case .not(let node):
            "(NOT \(sql(node)))"
        case .term(let term):
            sql(term)
        }
    }

    private mutating func sql(_ term: SearchQuery.Term) -> String {
        switch term {
        case .word(let text, let isPrefix):
            return match(text, column: nil, isPrefix: isPrefix)
        case .phrase(let text):
            return match(text, column: nil, isPrefix: false)
        case .field(let field, let text):
            return match(text, column: Self.column(for: field), isPrefix: false)
        case .labelID(let id):
            return hasLabel([id])
        case .labelName(let name):
            return hasLabel(labelIDs[Self.normalizedLabelName(name)] ?? [])
        case .anywhere:
            return "1"
        case .date(let bound):
            switch bound {
            case .onOrAfter(let value):
                guard let date = value.date(in: timeZone, now: now) else { return "0" }
                arguments += [date]
                return "m.date >= ?"
            case .before(let value):
                guard let date = value.date(in: timeZone, now: now) else { return "0" }
                arguments += [date]
                return "m.date < ?"
            }
        case .gmailOnly:
            return "0"
        }
    }

    /// Text with nothing the tokenizer keeps can't match anything.
    private mutating func match(_ text: String, column: String?, isPrefix: Bool) -> String {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return "0" }
        let phrase = Self.ftsPhrase(text, isPrefix: isPrefix)
        arguments += [column.map { "\($0) : \(phrase)" } ?? phrase]
        return "mt.id IN (SELECT rowid FROM messageSearch WHERE messageSearch MATCH ?)"
    }

    private mutating func hasLabel(_ ids: [String]) -> String {
        guard !ids.isEmpty else { return "0" }
        arguments += StatementArguments(ids)
        return """
            EXISTS (SELECT 1 FROM messageLabel ml WHERE ml.accountID = m.accountID AND ml.messageID = m.id \
            AND ml.labelID IN (\(databaseQuestionMarks(count: ids.count))))
            """
    }

    /// An FTS5 string, which the tokenizer splits into a phrase. Quotes inside
    /// are doubled, so operators in the text stay plain words.
    static func ftsPhrase(_ text: String, isPrefix: Bool) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" + (isPrefix ? "*" : "")
    }

    static func column(for field: SearchQuery.Field) -> String {
        switch field {
        case .from: "sender"
        case .to: "recipients"
        case .cc: "cc"
        case .subject: "subject"
        }
    }

    static func normalizedLabelName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }
}
