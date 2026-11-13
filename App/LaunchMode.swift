import Foundation

/// How this process was launched, resolved once before any store opens.
///
/// Debug and Release builds always resolve to `.standard` and act only on
/// `--navigation-report=`. A Debug app stops instead when XCTest hosts it or
/// when it gets an audit or benchmark flag. The Debug-Testing configuration
/// and the benchmark build compile in test support and never resolve to
/// `.standard`, so they never open the user's data.
struct LaunchMode: Sendable, Equatable {
    enum Host: Sendable, Equatable {
        /// A normal launch that uses the user's stores and Keychain.
        case standard
        /// The app is the host process for unit tests.
        case hostedTests
        /// A synthetic UI or performance audit.
        case audit
    }

    var host = Host.standard
    var audit = AuditOptions()
    var performance = PerformanceOptions()
    /// Where to write the navigation timing report. Every build reads it, and
    /// only an absolute path is accepted.
    var navigationReport: URL?

    /// Isolated launches keep away from the user's data and Keychain, so call
    /// sites use in-memory stores and volatile credentials instead.
    var isIsolated: Bool { host != .standard }

    static let current: LaunchMode = {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        #if TERN_TEST_SUPPORT || TERN_PERFORMANCE
        // The shipping bundle ID owns the user's container and Keychain items,
        // so a build with test support stops rather than run under it.
        if AppIdentity.bundleIdentifier == "dev.tern.mail" {
            preconditionFailure("Debug-Testing and benchmark builds need their own bundle ID.")
        }
        #elseif DEBUG
        // A Debug app opens the user's data, so it stops when XCTest loads it
        // as a test host. UI tests launch the app as a normal process, so it
        // also stops on the flag prefixes that only builds with test support
        // act on.
        if isHostedTest(environment) {
            preconditionFailure("Hosted tests use the Debug-Testing configuration.")
        }
        let testSupportPrefixes = ["--ui-audit", "--performance-", "--reader-"]
        if arguments.contains(where: { argument in testSupportPrefixes.contains { argument.hasPrefix($0) } }) {
            preconditionFailure("UI audits and benchmarks need a Debug-Testing or benchmark build.")
        }
        #endif
        return resolve(arguments: arguments, environment: environment)
    }()

    static func resolve(arguments: [String], environment: [String: String]) -> LaunchMode {
        let navigationReport = navigationReportURL(in: arguments)
        #if TERN_TEST_SUPPORT || TERN_PERFORMANCE
        // A build with test support never opens the user's data, even when it
        // is launched without arguments.
        return LaunchMode(host: isHostedTest(environment) ? .hostedTests : .audit,
                          audit: AuditOptions(arguments: arguments, environment: environment),
                          performance: PerformanceOptions(arguments: arguments),
                          navigationReport: navigationReport)
        #else
        return LaunchMode(navigationReport: navigationReport)
        #endif
    }

    private static func navigationReportURL(in arguments: [String]) -> URL? {
        guard let path = arguments.value(after: "--navigation-report="),
              path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path)
    }
}

/// Synthetic fixtures and switches for UI audits. Debug and Release builds keep
/// the defaults because they never parse the flags.
struct AuditOptions: Sendable, Equatable {
    enum Onboarding: Sendable, Equatable {
        /// Setup from the start, with no account.
        case empty
        /// Setup with the audit accounts already connected.
        case connected
    }

    enum Appearance: Sendable, Equatable { case light, dark }

    var calendar = false
    var list = false
    var attachments = false
    var attachmentCategories = false
    var writingStyle = false
    var reauth = false
    var cachedReauth = false
    var avatars = false
    var onboarding: Onboarding?
    var onboardingStep: OnboardingState.Step?
    var appearance: Appearance?
    var highContrast = false
    var liveChatGPT = false
    var liveClaude = false
    var readmeDemo = false
}

/// Benchmark settings. Debug and Release builds keep the defaults because they
/// never parse the flags.
struct PerformanceOptions: Sendable, Equatable {
    var audit = false
    var scenario = "all"
    /// Synthetic calendar events, 100 to 1,000.
    var events = 100
    /// Synthetic messages per account, 200 to 60,000.
    var mails = 1_000
    /// Selections per reader scenario, 100 to 1,000.
    var iterations = 100
    var output: URL?
    var exitsAfterReport = false
    /// Seconds to wait before quitting after the report, 0 to 30.
    var memoryPause = 0
    var fixedKeyLoop = false
    var startFile: String?
    /// Runs the benchmark in a visible window without requiring the app to be
    /// active, for a comparison when nobody can bring it to the front. Its
    /// report is marked and cannot pass acceptance.
    var unattended = false
    /// Where reader layout diagnostics write their report: one absolute path.
    var readerLayoutReport: URL?
    /// Starts reader prefetches at once instead of after the 90 ms delay.
    var readerPrefetchImmediate = false
}

#if DEBUG || TERN_PERFORMANCE
extension LaunchMode {
    /// XCTest sets these variables in a test host, and loads its classes and
    /// the test bundle into it.
    private static func isHostedTest(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
    }
}
#endif

#if TERN_TEST_SUPPORT || TERN_PERFORMANCE
// Every flag parsed here starts with --ui-audit, --performance- or --reader-.
// A Debug app stops on those prefixes, so a new flag keeps one of them.
extension AuditOptions {
    init(arguments: [String], environment: [String: String]) {
        calendar = arguments.contains("--ui-audit-calendar")
        list = arguments.contains("--ui-audit-list")
        attachments = arguments.contains("--ui-audit-attachments")
        attachmentCategories = arguments.contains("--ui-audit-attachment-categories")
        writingStyle = arguments.contains("--ui-audit-writing-style")
        reauth = arguments.contains("--ui-audit-reauth")
        cachedReauth = arguments.contains("--ui-audit-cached-reauth")
        // The remaining switches need the full synthetic app.
        guard arguments.contains("--ui-audit") else { return }
        avatars = arguments.contains("--ui-audit-avatars")
        if arguments.contains("--ui-audit-onboarding-connected") {
            onboarding = .connected
        } else if arguments.contains("--ui-audit-onboarding") {
            onboarding = .empty
        }
        if onboarding != nil {
            onboardingStep = arguments.value(after: "--ui-audit-onboarding-step=")
                .flatMap(OnboardingState.Step.init(rawValue:))
        }
        if arguments.contains("--ui-audit-light") {
            appearance = .light
        } else if arguments.contains("--ui-audit-dark") {
            appearance = .dark
        }
        highContrast = arguments.contains("--ui-audit-contrast")
        liveChatGPT = arguments.contains("--ui-audit-live-chatgpt")
        liveClaude = arguments.contains("--ui-audit-live-claude")
        readmeDemo = environment["TERN_README_SCREENSHOTS"] == "1"
    }
}

extension PerformanceOptions {
    init(arguments: [String]) {
        audit = arguments.contains("--performance-audit")
        scenario = arguments.value(after: "--performance-scenario=") ?? scenario
        events = arguments.integer(after: "--performance-events=", default: events, in: 100...1_000)
        mails = arguments.integer(after: "--performance-mails=", default: mails, in: 200...60_000)
        iterations = arguments.integer(after: "--performance-iterations=", default: iterations, in: 100...1_000)
        output = arguments.value(after: "--performance-output=").map { URL(fileURLWithPath: $0) }
        exitsAfterReport = arguments.contains("--performance-exit")
        memoryPause = arguments.integer(after: "--performance-memory-pause=", default: memoryPause, in: 0...30)
        fixedKeyLoop = arguments.contains("--performance-fixed-key-loop")
        startFile = arguments.value(after: "--performance-start-file=")
        unattended = arguments.contains("--performance-unattended")
        readerLayoutReport = ReaderLayoutDiagnostics.destination(in: arguments)
        readerPrefetchImmediate = arguments.contains("--reader-prefetch-immediate")
    }
}

private extension [String] {
    /// The whole number after `prefix`, or `fallback`, clamped to `range`.
    func integer(after prefix: String, default fallback: Int, in range: ClosedRange<Int>) -> Int {
        let value = self.value(after: prefix).flatMap { Int($0) } ?? fallback
        return Swift.min(range.upperBound, Swift.max(range.lowerBound, value))
    }
}
#endif

private extension [String] {
    /// The text after `prefix` in the first argument that starts with it.
    func value(after prefix: String) -> String? {
        first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }
}
