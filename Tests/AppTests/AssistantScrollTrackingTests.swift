import CoreGraphics
import Foundation
import Testing
@testable import Tern

@MainActor struct AssistantScrollTrackingTests {
    @Test func slowUpwardScrollStopsFollowingAcrossStreamedGrowth() {
        var tracking = AssistantScrollTracking()
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
        var tracking = AssistantScrollTracking()
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
}
