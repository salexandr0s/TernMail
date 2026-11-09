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
            let required = SearchCompiler.requiredMatch(root)
            let predicate = compiler.sql(root, matched: required != nil)
            var sql: String
            if let required {
                // The matches come first, each finding its message by key,
                // so a search reads what it matches rather than every
                // message of the account.
                sql = """
                    thread.id IN (
                        SELECT m.threadID FROM messageSearch
                        CROSS JOIN messageText mt ON mt.id = messageSearch.rowid
                        CROSS JOIN message m ON m.accountID = mt.accountID AND m.id = mt.messageID
                        WHERE messageSearch MATCH ? AND mt.accountID = ? AND \(predicate)
                    """
                arguments += [required, accountID]
            } else {
                // With no text that every match has, as with a label alone,
                // an OR or a NOT, each message of the account is checked.
                sql = """
                    thread.id IN (
                        SELECT m.threadID FROM message m
                        JOIN messageText mt ON mt.accountID = m.accountID AND mt.messageID = m.id
                        WHERE m.accountID = ? AND \(predicate)
                    """
                arguments += [accountID]
            }
            if !query.includesSpamAndTrash {
                sql += """
                     AND NOT EXISTS (
                        SELECT 1 FROM messageLabel x
                        WHERE x.accountID = m.accountID AND x.messageID = m.id AND x.labelID IN (?, ?))
                    """
                compiler.arguments += [SystemLabel.spam, SystemLabel.trash]
            }
            conditions.append(sql + ")")
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
    func labelIDsByName(accountID: String) throws -> [String: [String]] {
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

    /// With `matched`, the rows are matches of `requiredMatch(node)`
    /// already, so the text terms it reads become `1`.
    mutating func sql(_ node: SearchQuery.Node, matched: Bool = false) -> String {
        switch node {
        case .all(let nodes):
            nodes.isEmpty ? "1" : "(" + nodes.map { sql($0, matched: matched) }.joined(separator: " AND ") + ")"
        case .any(let nodes):
            nodes.isEmpty ? "0" : "(" + nodes.map { sql($0) }.joined(separator: " OR ") + ")"
        case .not(let node):
            "(NOT \(sql(node)))"
        case .term(let term):
            matched && Self.requiredMatch(node) != nil ? "1" : sql(term)
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
        guard let match = Self.ftsQuery(text, column: column, isPrefix: isPrefix) else { return "0" }
        arguments += [match]
        // The `+` keeps SQLite from looping over every match for each message
        // it checks. With it, SQLite reads the matches once and looks each
        // message up in them.
        return "+mt.id IN (SELECT rowid FROM messageSearch WHERE messageSearch MATCH ?)"
    }

    /// An FTS5 query that every message `node` matches also matches, or nil
    /// when there's none, as with a label alone or an `OR`.
    static func requiredMatch(_ node: SearchQuery.Node) -> String? {
        switch node {
        case .all(let nodes):
            let parts = nodes.compactMap(requiredMatch)
            return parts.isEmpty ? nil : parts.map { "(\($0))" }.joined(separator: " AND ")
        case .term(.word(let text, let isPrefix)):
            return ftsQuery(text, column: nil, isPrefix: isPrefix)
        case .term(.phrase(let text)):
            return ftsQuery(text, column: nil, isPrefix: false)
        case .term(.field(let field, let text)):
            return ftsQuery(text, column: column(for: field), isPrefix: false)
        case .term, .any, .not:
            return nil
        }
    }

    /// The FTS5 query for `text` in `column`, or in every column. Nil when
    /// the text has nothing the tokenizer keeps.
    static func ftsQuery(_ text: String, column: String?, isPrefix: Bool) -> String? {
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let phrase = ftsPhrase(text, isPrefix: isPrefix)
        return column.map { "\($0) : \(phrase)" } ?? phrase
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
