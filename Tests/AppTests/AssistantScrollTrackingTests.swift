import CoreGraphics
import Foundation
import Observation
import Synchronization
import Testing
@testable import Tern

@MainActor struct AssistantScrollTrackingTests {
    @Test func slowUpwardScrollStopsFollowingAcrossStreamedGrowth() {
        let tracking = AssistantScrollTracking()
        var frame = CGRect(x: 0, y: -600, width: 360, height: 1_000)
        tracking.update(frame: frame, viewportHeight: 400)

        for _ in 0..<6 {
            frame.origin.y += 1
            tracking.update(frame: frame, viewportHeight: 400)
            #expect(!tracking.followsLatest)
            frame.size.height += 10
            tracking.update(frame: frame, viewportHeight: 400)
        }
        #expect(!tracking.followsLatest)

        frame.size.height += 100
        tracking.update(frame: frame, viewportHeight: 400)
        #expect(!tracking.followsLatest)

        frame.origin.y = 400 - frame.height
        tracking.update(frame: frame, viewportHeight: 400)
        #expect(tracking.followsLatest)
    }

    @Test func contentAndViewportChangesDoNotImitateReaderScrolling() {
        let tracking = AssistantScrollTracking()
        tracking.update(frame: CGRect(x: 0, y: -600, width: 360, height: 1_000), viewportHeight: 400)
        tracking.update(frame: CGRect(x: 0, y: -600, width: 360, height: 1_100), viewportHeight: 400)
        tracking.update(frame: CGRect(x: 0, y: -550, width: 380, height: 1_050), viewportHeight: 400)
        tracking.update(frame: CGRect(x: 0, y: -500, width: 380, height: 1_050), viewportHeight: 450)
        #expect(tracking.followsLatest)

        tracking.update(frame: CGRect(x: 0, y: -480, width: 380, height: 1_050), viewportHeight: 450)
        #expect(!tracking.followsLatest)
        tracking.followLatest()
        #expect(tracking.followsLatest)
    }

    @Test func geometryChangesNotifyOnlyWhenFollowingChanges() {
        let tracking = AssistantScrollTracking()
        let changes = Mutex(0)
        func observe() {
            withObservationTracking { _ = tracking.followsLatest } onChange: {
                changes.withLock { $0 += 1 }
            }
        }
        var frame = CGRect(x: 0, y: -600, width: 360, height: 1_000)
        observe()
        tracking.update(frame: frame, viewportHeight: 400)
        tracking.followLatest()
        tracking.update(frame: frame, viewportHeight: 400)
        #expect(changes.withLock { $0 } == 0)

        frame.origin.y += 1
        tracking.update(frame: frame, viewportHeight: 400)
        #expect(changes.withLock { $0 } == 1)
        #expect(!tracking.followsLatest)

        observe()
        for _ in 0..<100 {
            frame.origin.y += 1
            tracking.update(frame: frame, viewportHeight: 400)
            frame.size.height += 10
            tracking.update(frame: frame, viewportHeight: 400)
        }
        #expect(changes.withLock { $0 } == 1)

        frame.origin.y = 400 - frame.height
        tracking.update(frame: frame, viewportHeight: 400)
        #expect(changes.withLock { $0 } == 2)
        #expect(tracking.followsLatest)

        observe()
        frame.origin.y += 1
        tracking.update(frame: frame, viewportHeight: 400)
        #expect(changes.withLock { $0 } == 3)
        observe()
        tracking.followLatest()
        #expect(changes.withLock { $0 } == 4)
        #expect(tracking.followsLatest)
    }
}
