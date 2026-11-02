import Foundation
import Testing
@testable import MessageContent

@Suite struct CalendarForwardedTextTests {
    @Test func explicitForwardKeepsOnlyItsBody() throws {
        let body = try #require(CalendarForwardedText.extract(html: nil, plainText: """
            Here is my booking.
            ---------- Forwarded message ---------
            From: Airline <bookings@example.invalid>
            Date: July 1, 2031 at 08:00
            Subject: Booking confirmation
            To: Passenger <passenger@example.invalid>

            Flight to Vienna on July 15, 2031 at 14:00 UTC.
            --
            Airline signature
            """))
        #expect(body == "Flight to Vienna on July 15, 2031 at 14:00 UTC.")
        #expect(!CalendarForwardedText.containsExplicitDay("2031-07-01", in: body))
        #expect(CalendarForwardedText.containsExplicitDay("2031-07-15", in: body))
    }

    @Test func htmlForwardRetainsBookingButExcludesHiddenAndNestedReplyText() throws {
        let body = try #require(CalendarForwardedText.extract(html: """
            <div>Sharing my booking.</div><div class="gmail_quote">
            <div>---------- Forwarded message ---------<br>
            From: Airline<br>Date: July 1, 2031<br>Subject: Booking confirmation<br></div>
            <p>Flight to Vienna on July 15, 2031 at 14:00 UTC.</p>
            <script>Secret departure July 16, 2031</script>
            <p hidden>Hidden departure July 17, 2031</p>
            <p aria-hidden="true">Hidden departure July 18, 2031</p>
            <p style="DISPLAY: none">Hidden departure July 19, 2031</p>
            <blockquote>Old departure July 20, 2031</blockquote>
            </div><p>Wrapper footer July 21, 2031.</p>
            """, plainText: nil))
        #expect(body.contains("July 15, 2031"))
        for day in 16...21 { #expect(!body.contains("July \(day), 2031")) }
        #expect(!body.contains("Booking confirmation"))
    }

    @Test(arguments: [
        "On Tuesday, Someone wrote:\n---------- Forwarded message ---------\nFrom: Airline\nDate: July 1, 2031\nSubject: Booking\n\nFlight July 15, 2031.",
        "> ---------- Forwarded message ---------\nFrom: Airline\nDate: July 1, 2031\nSubject: Booking\n\nFlight July 15, 2031.",
        "I mentioned a forwarded message about July 15, 2031.",
        "---------- Forwarded message ---------\nFlight July 15, 2031."
    ])
    func ordinaryRepliesAndUnstructuredQuotesAreNotForwardedSources(_ text: String) {
        #expect(CalendarForwardedText.extract(html: nil, plainText: text) == nil)
    }

    @Test func ordinaryHTMLReplyCannotExposeANestedForward() {
        let html = """
            <p>Thanks.</p><div class="gmail_quote">On Tuesday, Someone wrote:
            <p>---------- Forwarded message ---------<br>From: Airline<br>Date: July 1, 2031<br>Subject: Booking</p>
            <p>Flight July 15, 2031.</p></div>
            """
        #expect(CalendarForwardedText.extract(html: html, plainText: nil) == nil)
    }

    @Test func forwardedHeadersCannotExposeANestedQuotedBody() {
        let html = """
            <div class="gmail_quote">
            <p>---------- Forwarded message ---------<br>From: Airline<br>Date: July 1, 2031<br>Subject: Booking</p>
            <blockquote>Old flight July 15, 2031 at 14:00 UTC.</blockquote>
            </div>
            """
        #expect(CalendarForwardedText.extract(html: html, plainText: nil) == nil)
    }

    @Test func htmlForwardStopsAtItsQuoteWrapper() {
        let html = """
            <blockquote>---------- Forwarded message ---------<br>
            From: Airline<br>Date: July 1, 2031<br>Subject: Booking<br>
            Flight July 15, 2031 at 14:00 UTC.</blockquote>
            <p>Wrapper footer July 16, 2031.</p>
            """
        #expect(CalendarForwardedText.extract(html: html, plainText: nil) == "Flight July 15, 2031 at 14:00 UTC.")
    }

    @Test func explicitDaysRequireAnUnambiguousYearAndMatchTheProposedDay() {
        #expect(CalendarForwardedText.containsExplicitDay("2031-07-15", in: "Departure 2031-07-15 at 14:00 UTC."))
        #expect(CalendarForwardedText.containsExplicitDay("2031-07-15", in: "Confirmed flight arriving July 15, 2031 at 14:00."))
        for text in ["Departure tomorrow at 14:00.", "Departure July 15 at 14:00.",
                     "Departure 07/15/31 at 14:00.", "Departure 07/08/2031 at 14:00.",
                     "Departure July 16, 2031 at 14:00.", "> Departure July 15, 2031 at 14:00."] {
            #expect(!CalendarForwardedText.containsExplicitDay("2031-07-15", in: text))
        }
        #expect(!CalendarForwardedText.containsExplicitDay("2031-07-08", in: "Departure 07/08/2031 at 14:00."))
        #expect(!CalendarForwardedText.containsExplicitDay("2031-02-30", in: "Departure February 30, 2031."))
    }

    @Test func oversizedSourcesAreNotForwarded() {
        let text = String(repeating: "x", count: CalendarDetection.maximumTextLength + 1)
        #expect(CalendarForwardedText.extract(html: nil, plainText: text) == nil)
        #expect(!CalendarForwardedText.containsExplicitDay("2031-07-15", in: text))
    }
}
