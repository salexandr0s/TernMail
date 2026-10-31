import Foundation
import Testing
@testable import MessageContent

@Suite struct SearchQueryTests {
    private typealias Node = SearchQuery.Node

    private func word(_ text: String, prefix: Bool = false) -> Node { .term(.word(text, isPrefix: prefix)) }

    @Test func orBindsTighterThanTheImpliedAnd() {
        #expect(SearchQuery("hike trail OR lake map").root == .all([
            word("hike"), .any([word("trail"), word("lake")]), word("map", prefix: true),
        ]))
        // Explicit AND means the same as a space.
        #expect(SearchQuery("hike AND map ").root == .all([word("hike"), word("map")]))
        // Lowercase "or" is a word.
        #expect(SearchQuery("a or b ").root == .all([word("a"), word("or"), word("b")]))
    }

    @Test func aScopeLimitsTheWholeQuery() {
        // Written into the text, the scope would join the OR: either Inbox or "lake".
        #expect(SearchQuery("in:inbox OR lake tra").root == .all([
            .any([.term(.labelID("INBOX")), word("lake")]), word("tra", prefix: true),
        ]))
        let scoped = SearchQuery("OR lake tra", scope: "in:inbox")
        #expect(scoped.root == .all([.term(.labelID("INBOX")), .all([word("lake"), word("tra", prefix: true)])]))
        #expect(scoped.gmailQuery(timeZone: .gmt) == "in:inbox (OR lake tra)")
        #expect(SearchQuery("lake", scope: "in:trash").includesSpamAndTrash)
        // Text with nothing to search locally stays that way.
        #expect(SearchQuery("!!", scope: "in:inbox").root == nil)
    }

    @Test func negationBracesAndGroups() {
        #expect(SearchQuery("-trail ").root == .not(word("trail")))
        #expect(SearchQuery("-\"lake map\"").root == .not(.term(.phrase("lake map"))))
        #expect(SearchQuery("-(a b) ").root == .not(.all([word("a"), word("b")])))
        #expect(SearchQuery("{a b} c ").root == .all([.any([word("a"), word("b")]), word("c")]))
        // A hyphen inside a word isn't negation.
        #expect(SearchQuery("e-mail ").root == word("e-mail"))
    }

    @Test func malformedInputStillParses() {
        #expect(SearchQuery("").root == nil)
        #expect(SearchQuery("  ) OR AND ").root == nil)
        #expect(SearchQuery("(a b").root == .all([word("a"), word("b", prefix: true)]))
        #expect(SearchQuery("a ) b ").root == .all([word("a"), word("b")]))
        #expect(SearchQuery("a OR ").root == word("a"))
        #expect(SearchQuery("- & a ").root == word("a"))
        #expect(!SearchQuery("").runsLocally)
    }

    @Test func fieldOperators() {
        #expect(SearchQuery("from:\"Ann Lee\" ").root == .term(.field(.from, "Ann Lee")))
        #expect(SearchQuery("To:ann@example.com ").root == .term(.field(.to, "ann@example.com")))
        #expect(SearchQuery("subject:(dinner -movie)").root == .all([
            .term(.field(.subject, "dinner")), .not(.term(.field(.subject, "movie"))),
        ]))
        // A negated field stays local: headers are always cached.
        #expect(SearchQuery("-from:ann").runsLocally)
        // Only documented operators count; anything else is a word.
        #expect(SearchQuery("10:30 re:plans ").root == .all([word("10:30"), word("re:plans")]))
    }

    @Test func labelsAndStates() {
        #expect(SearchQuery("label:my-family").root == .term(.labelName("my-family")))
        #expect(SearchQuery("is:read").root == .not(.term(.labelID("UNREAD"))))
        #expect(SearchQuery("is:unread in:inbox category:social").root == .all([
            .term(.labelID("UNREAD")), .term(.labelID("INBOX")), .term(.labelID("CATEGORY_SOCIAL")),
        ]))
        #expect(SearchQuery("in:anywhere").root == .term(.anywhere))
    }

    @Test func spamAndTrashOnlyWhenNamed() {
        #expect(!SearchQuery("trail").includesSpamAndTrash)
        #expect(SearchQuery("in:trash trail").includesSpamAndTrash)
        #expect(SearchQuery("in:anywhere trail").includesSpamAndTrash)
        #expect(SearchQuery("label:Spam").includesSpamAndTrash)
    }

    @Test func dates() {
        func bound(_ text: String) -> SearchQuery.DateBound? {
            if case .term(.date(let bound)) = SearchQuery(text).root { bound } else { nil }
        }
        #expect(bound("after:2026/01/15") == .onOrAfter(.day(year: 2026, month: 1, day: 15)))
        #expect(bound("before:01/15/2026") == .before(.day(year: 2026, month: 1, day: 15)))
        #expect(bound("newer:2026/1/5") == .onOrAfter(.day(year: 2026, month: 1, day: 5)))
        #expect(bound("after:1388552400") == .onOrAfter(.epochSeconds(1_388_552_400)))
        #expect(bound("newer_than:3d") == .onOrAfter(.ago(3, .days)))
        #expect(bound("older_than:2M") == .before(.ago(2, .months)))
        #expect(bound("older_than:1y") == .before(.ago(1, .years)))
        // Days that don't exist and other forms go to Gmail as written.
        #expect(SearchQuery("after:2026/02/30").root == .term(.gmailOnly("after:2026/02/30")))
        #expect(SearchQuery("newer_than:3w").root == .term(.gmailOnly("newer_than:3w")))
    }

    @Test func relativeDatesResolveAgainstNow() throws {
        let now = Date(timeIntervalSince1970: 1_768_453_200) // 2026-01-15 00:00 in New York
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let threeDaysAgo = SearchQuery.DateValue.ago(3, .days).date(in: zone, now: now)
        #expect(threeDaysAgo == Date(timeIntervalSince1970: 1_768_453_200 - 3 * 86_400))
        let day = SearchQuery.DateValue.day(year: 2026, month: 1, day: 15).date(in: zone, now: .distantPast)
        #expect(day == now)
    }

    @Test func gmailOnlyParts() {
        for text in [
            "has:attachment", "size:5m", "larger:10M", "filename:pdf", "is:muted", "in:snoozed",
            "category:reservations", "trail AROUND 3 lake", "+exact", "label:(a b) trail", "-invoice", "-\"lake map\"",
            "-(trail map)", "-{a b}",
        ] {
            #expect(!SearchQuery(text).runsLocally, "\(text) should go to Gmail only")
        }
        for text in ["trail", "\"lake map\"", "from:ann -to:ben", "is:unread -in:inbox", "after:2026/01/15 trail", "-(from:a to:b)"] {
            #expect(SearchQuery(text).runsLocally, "\(text) should run locally")
        }
        // The rest of a query after a Gmail-only group still parses.
        #expect(SearchQuery("label:(a b) trail ").root == .all([.term(.gmailOnly("label:(a b)")), word("trail")]))
    }

    @Test func onlyTheLastWordIsAPrefix() {
        #expect(SearchQuery("hike tra").root == .all([word("hike"), word("tra", prefix: true)]))
        #expect(SearchQuery("hike tra ").root == .all([word("hike"), word("tra")]))
        #expect(SearchQuery("from:tra").root == .term(.field(.from, "tra")))
        #expect(SearchQuery("\"lake ma").root == .term(.phrase("lake ma")))
    }

    @Test func gmailQueryRewritesDaysAsEpochSecondsInTheGivenZone() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        #expect(SearchQuery("trail after:2026/01/15").gmailQuery(timeZone: zone) == "trail after:1768453200")
        #expect(
            SearchQuery("-before:07/04/2026 OR newer_than:2d {a b}").gmailQuery(timeZone: zone)
                == "-before:1783137600 OR newer_than:2d {a b}"
        )
        #expect(SearchQuery("after:\"2026/01/15\" x").gmailQuery(timeZone: zone) == "after:\"1768453200\" x")
        #expect(SearchQuery("has:attachment ann").gmailQuery(timeZone: zone) == "has:attachment ann")
    }
}
