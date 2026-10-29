import Foundation
import Testing
@testable import IMAPIdle

@Suite struct IdleSessionTests {
    private let start = ContinuousClock.now

    private func receive(_ session: inout IdleSession, _ lines: String..., after elapsed: Duration = .zero) -> [IdleSession.Action] {
        session.receive(Data(lines.map { $0 + "\r\n" }.joined().utf8), at: start + elapsed)
    }

    private func sent(_ actions: [IdleSession.Action]) -> [String] {
        actions.compactMap { action in
            guard case .send(let data) = action else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// A session waiting for the answer to AUTHENTICATE.
    private func signingIn(capabilities: String = "IMAP4rev1 IDLE AUTH=XOAUTH2 SASL-IR") -> IdleSession {
        var session = IdleSession(address: "ann@example.com", startedAt: start)
        _ = receive(&session, "* OK Gimap ready")
        _ = receive(&session, "* CAPABILITY " + capabilities, "A1 OK done")
        _ = session.provideToken("token")
        return session
    }

    /// A session in IDLE since `start`, whose IDLE command was tagged A4.
    private func idling() -> IdleSession {
        var session = signingIn()
        _ = receive(&session, "A2 OK [CAPABILITY IMAP4rev1 IDLE] authenticated")
        _ = receive(&session, "A3 OK [READ-ONLY] selected")
        _ = receive(&session, "+ idling")
        return session
    }

    @Test func theCommandsRunFromTheGreetingToIdle() {
        var session = IdleSession(address: "ann@example.com", startedAt: start)
        #expect(session.start() == [.startTimer(.reply, after: IdleSession.replyTimeout)])
        #expect(sent(receive(&session, "* OK Gimap ready")) == ["A1 CAPABILITY\r\n"])
        #expect(receive(&session, "* CAPABILITY IMAP4rev1 IDLE AUTH=XOAUTH2 SASL-IR", "A1 OK done")
            == [.cancelTimer(.reply), .requestToken(forceRefresh: false)])

        let credentials = Data("user=ann@example.com\u{01}auth=Bearer ya29.token\u{01}\u{01}".utf8).base64EncodedString()
        #expect(sent(session.provideToken("ya29.token")) == ["A2 AUTHENTICATE XOAUTH2 \(credentials)\r\n"])
        #expect(sent(receive(&session, "A2 OK [CAPABILITY IMAP4rev1 IDLE] authenticated")) == ["A3 EXAMINE INBOX\r\n"])

        // EXISTS answers EXAMINE and isn't a change. The finished EXAMINE signals once.
        let examined = receive(&session, "* 10 EXISTS", "* 0 RECENT", "A3 OK [READ-ONLY] selected")
        #expect(examined.filter { $0 == .signal }.count == 1)
        #expect(sent(examined) == ["A4 IDLE\r\n"])
        #expect(receive(&session, "+ idling") == [.cancelTimer(.reply), .startTimer(.idleRestart, after: IdleSession.idleRestartInterval)])
    }

    @Test func withoutSASLIRTheCredentialsFollowTheContinuation() {
        var session = IdleSession(address: "ann@example.com", startedAt: start)
        _ = receive(&session, "* OK Gimap ready")
        _ = receive(&session, "* CAPABILITY IMAP4rev1 AUTH=XOAUTH2", "A1 OK done")
        #expect(sent(session.provideToken("t")) == ["A2 AUTHENTICATE XOAUTH2\r\n"])
        #expect(sent(receive(&session, "+ ")) == [IdleSession.xoauth2(address: "ann@example.com", token: "t") + "\r\n"])
        // The answer lists no capabilities, so the session asks again.
        #expect(sent(receive(&session, "A2 OK Success")) == ["A3 CAPABILITY\r\n"])
        #expect(sent(receive(&session, "* CAPABILITY IMAP4rev1 IDLE", "A3 OK done")) == ["A4 EXAMINE INBOX\r\n"])
    }

    @Test func aServerWithoutXOAUTH2OrIdleIsUnsupported() {
        var noXOAUTH2 = IdleSession(address: "ann@example.com", startedAt: start)
        _ = receive(&noXOAUTH2, "* OK Gimap ready")
        #expect(receive(&noXOAUTH2, "* CAPABILITY IMAP4rev1 IDLE AUTH=PLAIN", "A1 OK done") == [.close(.unsupported)])

        var noIdleInCode = signingIn()
        #expect(receive(&noIdleInCode, "A2 OK [CAPABILITY IMAP4rev1 MOVE] authenticated") == [.close(.unsupported)])

        var noIdleInAnswer = signingIn()
        _ = receive(&noIdleInAnswer, "A2 OK Success")
        #expect(receive(&noIdleInAnswer, "* CAPABILITY IMAP4rev1 MOVE", "A3 OK done") == [.close(.unsupported)])
    }

    @Test func aFailedSignInRetriesOnceWithARefreshedTokenThenGivesUp() {
        var session = signingIn()
        // Gmail's failure challenge holds base64 JSON. An empty line ends the exchange.
        #expect(sent(receive(&session, "+ eyJzdGF0dXMiOiI0MDAifQ==")) == ["\r\n"])
        #expect(receive(&session, "A2 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)")
            == [.cancelTimer(.reply), .requestToken(forceRefresh: true)])

        #expect(sent(session.provideToken("fresh")).first?.hasPrefix("A3 AUTHENTICATE XOAUTH2 ") == true)
        _ = receive(&session, "+ eyJzdGF0dXMiOiI0MDAifQ==")
        #expect(receive(&session, "A3 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)") == [.close(.authenticationFailed)])
    }

    @Test func changesSignalDuringIdleAndAroundItsRestart() {
        var session = idling()
        for change in ["* 11 EXISTS", "* 3 EXPUNGE", "* 5 FETCH (FLAGS (\\Seen))"] {
            #expect(receive(&session, change) == [.signal])
        }
        #expect(receive(&session, "* 1 RECENT", "* FLAGS (\\Seen)", "* OK Still here").isEmpty)
        #expect(receive(&session, "* 12 EXISTS", "* 13 EXISTS") == [.signal])

        // After DONE, before its OK, and after the OK, before the next "+".
        _ = session.timerFired(.idleRestart, at: start + IdleSession.idleRestartInterval)
        #expect(receive(&session, "* 14 EXISTS") == [.signal])
        _ = receive(&session, "A4 OK IDLE terminated")
        #expect(receive(&session, "* 15 EXISTS") == [.signal])
    }

    @Test func theRestartTimerSendsDoneAndThenIdleWithANewTag() {
        var session = idling()
        #expect(session.timerFired(.idleRestart, at: start + IdleSession.idleRestartInterval)
            == [.send(Data("DONE\r\n".utf8)), .startTimer(.reply, after: IdleSession.doneTimeout)])
        #expect(receive(&session, "A4 OK IDLE terminated")
            == [.cancelTimer(.idleRestart), .send(Data("A5 IDLE\r\n".utf8)), .startTimer(.reply, after: IdleSession.replyTimeout)])
    }

    @Test func noAnswerToDoneClosesForAReconnect() {
        var session = idling()
        // A reply timer left over from before IDLE does nothing.
        #expect(session.timerFired(.reply, at: start + .seconds(1)).isEmpty)
        _ = session.timerFired(.idleRestart, at: start + IdleSession.idleRestartInterval)
        let late = start + IdleSession.idleRestartInterval + IdleSession.doneTimeout
        // Nine minutes in IDLE count as healthy, so the backoff starts over.
        #expect(session.timerFired(.reply, at: late)
            == [.close(.reconnect(.init(immediately: false, forceRefresh: false, resetBackoff: true)))])
    }

    @Test func aByeReconnectsAtOnceAfterALongSessionAndBacksOffAfterAShortOne() {
        var long = idling()
        #expect(receive(&long, "* BYE Session expired", after: .seconds(3600))
            == [.close(.reconnect(.init(immediately: true, forceRefresh: false, resetBackoff: true)))])

        var short = IdleSession(address: "ann@example.com", startedAt: start)
        _ = receive(&short, "* OK Gimap ready")
        #expect(receive(&short, "* BYE Too many connections", after: .seconds(2))
            == [.close(.reconnect(.init(immediately: false, forceRefresh: true, resetBackoff: false)))])

        var dropped = signingIn()
        #expect(dropped.connectionEnded(at: start + .seconds(5))
            == .reconnect(.init(immediately: false, forceRefresh: false, resetBackoff: false)))
    }

    @Test func backoffDoublesToFiveMinutesStaysWithinItsJitterAndResets() {
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        var backoff = Backoff()
        let delays = (0..<10).map { _ in seconds(backoff.nextDelay(jitter: 0)) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 64, 128, 256, 300])
        // Jitter is held to 20%.
        #expect(abs(seconds(backoff.nextDelay(jitter: 0.5)) - 360) < 1e-6)
        backoff.reset()
        #expect(abs(seconds(backoff.nextDelay(jitter: -0.2)) - 0.8) < 1e-6)
    }
}
