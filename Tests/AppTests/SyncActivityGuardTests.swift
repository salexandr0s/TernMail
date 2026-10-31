import Foundation
import Testing
@testable import Tern

@MainActor
@Suite struct SyncActivityGuardTests {
    @Test func oneActivityCoversEveryAccountAndASendRaisesIt() {
        let process = RecordingProcess()
        let activity = SyncActivityGuard(process: process)
        activity.update(.pass(accountID: "a"), isActive: true)
        activity.update(.pass(accountID: "b"), isActive: true)
        #expect(process.begun == [.background])

        activity.update(.send(accountID: "a"), isActive: true)
        #expect(process.begun == [.background, .userInitiatedAllowingIdleSystemSleep])
        #expect(process.ended == 1)

        // The send and one pass end; the other account's pass keeps a background hold.
        activity.update(.send(accountID: "a"), isActive: false)
        activity.update(.pass(accountID: "a"), isActive: false)
        #expect(process.begun.last == .background)
        #expect(process.begun.count == 3)

        activity.release(accountID: "b")
        #expect(process.ended == 3)
        #expect(activity.options == nil)
        #expect(activity.work.isEmpty)
    }
}

private final class RecordingProcess: ProcessActivities {
    var begun: [ProcessInfo.ActivityOptions] = []
    var ended = 0

    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol {
        begun.append(options)
        return NSObject()
    }

    func endActivity(_ activity: any NSObjectProtocol) {
        ended += 1
    }
}
