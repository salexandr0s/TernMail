import Foundation
import Testing
@testable import Tern

/// Hosted tests run in the Debug-Testing configuration, which never opens the
/// user's data.
@Suite struct LaunchModeTests {
    @Test func launchWithoutArgumentsIsIsolated() {
        let mode = LaunchMode.resolve(arguments: [], environment: [:])
        #expect(mode.host != .standard)
        #expect(mode.isIsolated)
    }

    @Test func calendarAuditAloneSelectsTheCalendarFixture() {
        let mode = LaunchMode.resolve(arguments: ["Tern", "--ui-audit-calendar"], environment: [:])
        #expect(mode.isIsolated)
        #expect(mode.audit.calendar)
    }

    @Test func navigationReportNeedsAnAbsolutePath() {
        let absolute = LaunchMode.resolve(arguments: ["Tern", "--navigation-report=/tmp/navigation.json"],
                                          environment: [:])
        #expect(absolute.navigationReport?.path == "/tmp/navigation.json")
        let relative = LaunchMode.resolve(arguments: ["Tern", "--navigation-report=navigation.json"],
                                          environment: [:])
        #expect(relative.navigationReport == nil)
    }
}
