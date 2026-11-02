import AppKit
import SyncEngine
import Testing
@testable import Tern

@Suite struct CalendarScrollNavigationTests {
    @Test @MainActor func gestureChangesTheDisplayedPeriodInEveryMode() throws {
        let defaultsName = "CalendarScrollNavigationTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = CalendarModel(app: nil, defaults: defaults)
        model.workingHours = CalendarWorkingHours(timeZoneIdentifier: "Europe/Vienna")
        let calendar = model.calendar
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12)))
        let cases: [(CalendarDisplayMode, DateComponents)] = [
            (.day, DateComponents(year: 2026, month: 11, day: 3, hour: 12)),
            (.week, DateComponents(year: 2026, month: 11, day: 9, hour: 12)),
            (.month, DateComponents(year: 2026, month: 12, day: 2, hour: 12)),
            (.year, DateComponents(year: 2027, month: 11, day: 2, hour: 12)),
            (.schedule, DateComponents(year: 2026, month: 12, day: 2, hour: 12))
        ]
        for (mode, expected) in cases {
            model.mode = mode
            model.date = start
            var gesture = CalendarScrollGesture()
            let forward = gesture.handle(deltaX: -40, deltaY: 0, phase: .began,
                                         momentumPhase: [], timestamp: 1)
            model.shift(periods: try #require(forward.direction))
            #expect(model.date == calendar.date(from: expected))
            let backward = gesture.handle(deltaX: 40, deltaY: 0, phase: .began,
                                          momentumPhase: [], timestamp: 1.1)
            model.shift(periods: try #require(backward.direction))
            #expect(model.date == start)
        }
    }

    @Test func longSwipeChangesOnePeriodAndConsumesItsMomentum() {
        var gesture = CalendarScrollGesture()
        #expect(gesture.handle(deltaX: -12, deltaY: 1, phase: .began,
                               momentumPhase: [], timestamp: 1).direction == nil)
        #expect(gesture.handle(deltaX: -30, deltaY: 2, phase: .changed,
                               momentumPhase: [], timestamp: 1.02).direction == 1)
        let continuation = gesture.handle(deltaX: -200, deltaY: 0, phase: .changed,
                                          momentumPhase: [], timestamp: 1.04)
        #expect(continuation.direction == nil && continuation.consumesEvent)
        _ = gesture.handle(deltaX: 0, deltaY: 0, phase: .ended, momentumPhase: [], timestamp: 1.05)
        let momentum = gesture.handle(deltaX: -200, deltaY: 0, phase: [],
                                      momentumPhase: .began, timestamp: 1.6)
        #expect(momentum.direction == nil && momentum.consumesEvent)
        #expect(gesture.handle(deltaX: -200, deltaY: 0, phase: [],
                               momentumPhase: .changed, timestamp: 1.7).direction == nil)
    }

    @Test func verticalGestureKeepsScrollingDespiteLaterHorizontalDrift() {
        var gesture = CalendarScrollGesture()
        let start = gesture.handle(deltaX: 2, deltaY: 12, phase: .began,
                                   momentumPhase: [], timestamp: 1)
        #expect(!start.consumesEvent && start.direction == nil)
        let drift = gesture.handle(deltaX: -100, deltaY: 3, phase: .changed,
                                   momentumPhase: [], timestamp: 1.1)
        #expect(!drift.consumesEvent && drift.direction == nil)
        let momentum = gesture.handle(deltaX: -100, deltaY: 1, phase: [],
                                      momentumPhase: .began, timestamp: 1.2)
        #expect(!momentum.consumesEvent && momentum.direction == nil)
    }

    @Test func newGestureCanReverseDirectionBeforePreviousMomentumFinishes() {
        var gesture = CalendarScrollGesture()
        #expect(gesture.handle(deltaX: -40, deltaY: 0, phase: .began,
                               momentumPhase: [], timestamp: 1).direction == 1)
        _ = gesture.handle(deltaX: -80, deltaY: 0, phase: [], momentumPhase: .changed, timestamp: 1.1)
        #expect(gesture.handle(deltaX: 40, deltaY: 0, phase: .began,
                               momentumPhase: [], timestamp: 1.11).direction == -1)
    }

    @Test func smallJitterDoesNotNavigateAndUnphasedBurstsOnlyNavigateOnce() {
        var gesture = CalendarScrollGesture()
        #expect(gesture.handle(deltaX: -3, deltaY: 1, phase: [],
                               momentumPhase: [], timestamp: 1).direction == nil)
        #expect(gesture.handle(deltaX: -40, deltaY: 0, phase: [],
                               momentumPhase: [], timestamp: 1.01).direction == 1)
        #expect(gesture.handle(deltaX: -80, deltaY: 0, phase: [],
                               momentumPhase: [], timestamp: 1.1).direction == nil)
        #expect(gesture.handle(deltaX: 40, deltaY: 0, phase: [],
                               momentumPhase: [], timestamp: 1.5).direction == -1)
    }

    @Test func enteringCanvasMidGestureWaitsForANewGesture() {
        var gesture = CalendarScrollGesture()
        // The monitor cancels while the pointer is outside the canvas or input is disabled.
        gesture.cancel(at: 1)
        let continuation = gesture.handle(deltaX: -100, deltaY: 0, phase: .changed,
                                          momentumPhase: [], timestamp: 1.01)
        #expect(!continuation.consumesEvent && continuation.direction == nil)
        #expect(gesture.handle(deltaX: -100, deltaY: 0, phase: [],
                               momentumPhase: .changed, timestamp: 1.1).direction == nil)
        #expect(gesture.handle(deltaX: -40, deltaY: 0, phase: .began,
                               momentumPhase: [], timestamp: 1.2).direction == 1)
    }

    @Test func cancelledGestureCannotNavigateOnItsContinuation() {
        var gesture = CalendarScrollGesture()
        _ = gesture.handle(deltaX: -12, deltaY: 0, phase: .began, momentumPhase: [], timestamp: 1)
        _ = gesture.handle(deltaX: 0, deltaY: 0, phase: .cancelled, momentumPhase: [], timestamp: 1.01)
        #expect(gesture.handle(deltaX: -100, deltaY: 0, phase: .changed,
                               momentumPhase: [], timestamp: 1.1).direction == nil)
        #expect(gesture.handle(deltaX: 40, deltaY: 0, phase: .began,
                               momentumPhase: [], timestamp: 1.2).direction == -1)
    }
}
