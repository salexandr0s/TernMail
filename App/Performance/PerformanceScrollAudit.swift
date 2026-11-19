#if TERN_TEST_SUPPORT || TERN_PERFORMANCE
import AppKit
import QuartzCore

/// Measures display-link callback delivery while changing a native scroll offset.
/// It deliberately does not label callback gaps as missed *rendered* frames.
@MainActor
final class PerformanceScrollAudit: NSObject {
    struct Result: Codable {
        let name: String
        let callbacks: Int
        let durationSeconds: Double
        let expectedFrameMilliseconds: Double
        let callbackIntervals: NavigationPerformance.Summary?
        let delayedCallbacks: Int
        let delayedCallbackFraction: Double
        let mainRunLoopStallsOver100ms: Int
        let timedOut: Bool
        let failureReason: String?
        let surfaceIdentifier: String?
        let documentType: String?
        let maximumScrollRangePoints: Double
        let distanceScrolledPoints: Double
        let physicalFootprintBytes: UInt64?
        /// Set when the run placed the pointer: true while it rested on the surface.
        var pointerOverSurface: Bool? = nil
        /// Mail rows that gained or lost the pointer during the scroll.
        var hoverChanges: Int? = nil
        /// Whether the pointer was inside the window when the scroll began. A
        /// run that doesn't place the pointer finds it where it was left.
        var pointerInWindowAtStart: Bool? = nil
        /// Set when the surface noted reader events: each kind's count, the
        /// callbacks it fell in, how many of those were late and how long the
        /// main thread was awake in them.
        var events: [EventSummary]? = nil
        /// Late callbacks with no event in them or in the callback before.
        var delayedCallbacksWithoutEvents: Int? = nil
        /// The first late callbacks, with the events in each and in the one before it.
        var lateCallbacks: [LateCallback]? = nil
        /// Main-thread time awake between one callback and the next: over all
        /// callbacks, over those a message entered in, and over those with no
        /// reader event in them or in the one before.
        var busyMilliseconds: NavigationPerformance.Summary? = nil
        var busyWithRowEntered: NavigationPerformance.Summary? = nil
        var busyWithoutEvents: NavigationPerformance.Summary? = nil
        /// The first callbacks a message entered in: each reader event and when
        /// it came, counted from the callback before.
        var entryTimelines: [EntryTimeline]? = nil
        /// Callbacks whose work began with the main thread on an efficiency core,
        /// and the same for the callbacks a message entered in. The scheduler
        /// starts a burst there when the frames before it were light.
        var callbacksBegunOnEfficiencyCore: Int? = nil
        var entriesBegunOnEfficiencyCore: Int? = nil
        /// The main thread's CPU time in the callbacks a message entered in.
        /// Close to the time awake when nothing else took the core from it.
        var cpuWithRowEntered: NavigationPerformance.Summary? = nil
        /// Set by `TERN_SCROLL_KEEP_BUSY`: arithmetic added to every callback.
        /// A report with it shows a diagnostic, not the app's scroll.
        var addedBusyMilliseconds: Double? = nil

        struct EntryTimeline: Codable {
            let intervalMilliseconds: Double
            let busyMilliseconds: Double
            let cpuMilliseconds: Double
            /// The core the main thread was on when the callback's work began.
            let begunOnCore: Int?
            /// When the main thread first went back to waiting.
            let firstRestMilliseconds: Double?
            let steps: [Step]

            struct Step: Codable {
                let kind: String
                let count: Int
                let atMilliseconds: Double
            }
        }

        struct EventSummary: Codable {
            let kind: String
            let count: Int
            let callbacks: Int
            let delayedCallbacks: Int
            /// Main-thread time awake in the callbacks this kind fell in.
            let busyMilliseconds: NavigationPerformance.Summary?
        }

        struct LateCallback: Codable {
            let milliseconds: Double
            /// Main-thread time awake since the callback before.
            let busyMilliseconds: Double
            let events: [String: Int]
            let previousEvents: [String: Int]
        }

        static func failure(name: String, reason: String) -> Self {
            Self(name: name, callbacks: 0, durationSeconds: 0, expectedFrameMilliseconds: 0, callbackIntervals: nil,
                 delayedCallbacks: 0, delayedCallbackFraction: 0, mainRunLoopStallsOver100ms: 0,
                 timedOut: false, failureReason: reason, surfaceIdentifier: nil, documentType: nil,
                 maximumScrollRangePoints: 0, distanceScrolledPoints: 0, physicalFootprintBytes: nil)
        }
    }

    private weak var scroll: NSScrollView?
    private var link: CADisplayLink?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<Result, Never>?
    private let name: String
    private let requestedDuration: Double
    private var intervals: [Double] = []
    private var expected = 1.0 / 60
    private var lastTime: CFTimeInterval?
    private var firstTime: CFTimeInterval?
    private var direction: CGFloat = 1
    private var ticks = 0
    private var delayed = 0
    private var maximumRange = 0.0
    private var distance = 0.0
    private var eventCounts: [PerformanceFrameEvents.Kind: Int] = [:]
    private var eventCallbacks: [PerformanceFrameEvents.Kind: Int] = [:]
    private var eventDelayedCallbacks: [PerformanceFrameEvents.Kind: Int] = [:]
    private var eventBusy: [PerformanceFrameEvents.Kind: [Double]] = [:]
    private var previousEvents: [PerformanceFrameEvents.Kind: Int] = [:]
    private var delayedWithoutEvents = 0
    private var lateCallbacks: [Result.LateCallback] = []
    private var observer: CFRunLoopObserver?
    private var awakeSince: CFTimeInterval?
    private var awake = 0.0
    private var busy: [Double] = []
    private var busyEntered: [Double] = []
    private var busyQuiet: [Double] = []
    private var firstRest: CFTimeInterval?
    private var entryTimelines: [Result.EntryTimeline] = []
    /// Apple silicon numbers its efficiency cores first, so a core below this count is one.
    private let efficiencyCores: Int = {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.perflevel1.logicalcpu", &count, &size, nil, 0) == 0 ? Int(count) : 0
    }()
    private var coreAtLastTick: Int?
    private var cpuAtLastTick: UInt64 = 0
    private var cpuEntered: [Double] = []
    private var begunOnEfficiency = 0
    private var entriesBegunOnEfficiency = 0
    /// A diagnostic that shows what a row's entry costs when the main thread is
    /// already busy: milliseconds of arithmetic added to every callback.
    private let keepBusy = Double(ProcessInfo.processInfo.environment["TERN_SCROLL_KEEP_BUSY"] ?? "") ?? 0
    private var busyWork = 1.0

    private init(name: String, scroll: NSScrollView, duration: Double) {
        self.name = name
        self.scroll = scroll
        self.requestedDuration = duration
    }

    static func run(name: String, scroll: NSScrollView, duration: Double = 30) async -> Result {
        let audit = PerformanceScrollAudit(name: name, scroll: scroll, duration: duration)
        return await audit.start()
    }

    private func start() async -> Result {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            guard let scroll else { finish(timedOut: true); return }
            let link = scroll.displayLink(target: self, selector: #selector(tick(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
            // Last among the observers, so a frame's commit counts as time awake.
            awakeSince = CACurrentMediaTime()
            let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
            let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { [weak self] _, activity in
                MainActor.assumeIsolated { self?.runLoopChanged(activity) }
            }
            self.observer = observer
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds((self?.requestedDuration ?? 30) + 15)) } catch { return }
                self?.finish(timedOut: true)
            }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scroll, let document = scroll.documentView else { finish(timedOut: true); return }
        guard LaunchMode.current.performance.unattended || (NSApp.isActive && scroll.window?.isKeyWindow == true),
              scroll.window?.occlusionState.contains(.visible) == true else {
            finish(timedOut: false, failureReason: "Foreground activation was lost."); return
        }
        let time = CACurrentMediaTime()
        if firstTime == nil { firstTime = time }
        let period = link.targetTimestamp - link.timestamp
        if period > 0 { expected = period }
        let events = PerformanceFrameEvents.take()
        let timeline = PerformanceFrameEvents.takeTimeline()
        let spent = (awake + (awakeSince.map { time - $0 } ?? 0)) * 1_000
        let rested = firstRest
        awake = 0
        awakeSince = time
        firstRest = nil
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let cpuSpent = Double(cpu &- cpuAtLastTick) / 1_000_000
        let began = coreAtLastTick
        cpuAtLastTick = cpu
        var core = 0
        coreAtLastTick = pthread_cpu_number_np(&core) == 0 ? core : nil
        if let lastTime, ticks > 10 {
            let interval = time - lastTime
            intervals.append(interval * 1_000)
            let isDelayed = interval > expected * 1.5
            if isDelayed { delayed += 1 }
            busy.append(spent)
            let onEfficiency = began.map { $0 < efficiencyCores } ?? false
            if onEfficiency { begunOnEfficiency += 1 }
            if events[.rowEntered] != nil {
                busyEntered.append(spent)
                cpuEntered.append(cpuSpent)
                if onEfficiency { entriesBegunOnEfficiency += 1 }
                if entryTimelines.count < 40 {
                    var steps: [Result.EntryTimeline.Step] = []
                    for (kind, at) in timeline {
                        if let last = steps.last, last.kind == kind.rawValue {
                            steps[steps.count - 1] = .init(kind: last.kind, count: last.count + 1, atMilliseconds: last.atMilliseconds)
                        } else {
                            steps.append(.init(kind: kind.rawValue, count: 1, atMilliseconds: (at - lastTime) * 1_000))
                        }
                    }
                    entryTimelines.append(.init(intervalMilliseconds: interval * 1_000, busyMilliseconds: spent,
                        cpuMilliseconds: cpuSpent, begunOnCore: began, firstRestMilliseconds: rested.map { ($0 - lastTime) * 1_000 }, steps: steps))
                }
            } else if events.isEmpty, previousEvents.isEmpty { busyQuiet.append(spent) }
            note(events, milliseconds: interval * 1_000, busy: spent, isDelayed: isDelayed)
        }
        previousEvents = events
        lastTime = time
        ticks += 1
        if keepBusy > 0 {
            let end = CACurrentMediaTime() + keepBusy / 1_000
            while CACurrentMediaTime() < end {
                for step in 1...200 { busyWork = (busyWork * 1.000001 + Double(step)).truncatingRemainder(dividingBy: 9_973) }
            }
        }
        let clip = scroll.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        maximumRange = max(maximumRange, maximum)
        var origin = clip.bounds.origin
        let previousY = origin.y
        origin.y = min(maximum, max(0, origin.y + 18 * direction))
        if origin.y >= maximum { direction = -1 }
        else if origin.y <= 0 { direction = 1 }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        distance += abs(clip.bounds.origin.y - previousY)
        if time - (firstTime ?? time) >= requestedDuration { finish(timedOut: false) }
    }

    private func runLoopChanged(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .beforeWaiting {
            if let awakeSince { awake += now - awakeSince }
            awakeSince = nil
            if firstRest == nil { firstRest = now }
        } else {
            awakeSince = now
        }
    }

    private func note(_ events: [PerformanceFrameEvents.Kind: Int], milliseconds: Double, busy: Double, isDelayed: Bool) {
        for (kind, count) in events {
            eventCounts[kind, default: 0] += count
            eventCallbacks[kind, default: 0] += 1
            eventBusy[kind, default: []].append(busy)
            if isDelayed { eventDelayedCallbacks[kind, default: 0] += 1 }
        }
        guard isDelayed else { return }
        if events.isEmpty, previousEvents.isEmpty { delayedWithoutEvents += 1 }
        guard lateCallbacks.count < 300 else { return }
        func named(_ events: [PerformanceFrameEvents.Kind: Int]) -> [String: Int] {
            Dictionary(uniqueKeysWithValues: events.map { ($0.key.rawValue, $0.value) })
        }
        lateCallbacks.append(.init(milliseconds: milliseconds, busyMilliseconds: busy, events: named(events),
                                   previousEvents: named(previousEvents)))
    }

    private func finish(timedOut: Bool, failureReason: String? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        link?.invalidate(); link = nil
        timeout?.cancel(); timeout = nil
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        var result = makeResult(timedOut: timedOut, failureReason: failureReason)
        result.busyMilliseconds = NavigationPerformance.Summary(busy)
        result.callbacksBegunOnEfficiencyCore = begunOnEfficiency
        if keepBusy > 0 { result.addedBusyMilliseconds = keepBusy }
        if !eventCounts.isEmpty {
            result.events = PerformanceFrameEvents.Kind.allCases.compactMap { kind in
                eventCounts[kind].map {
                    .init(kind: kind.rawValue, count: $0, callbacks: eventCallbacks[kind] ?? 0,
                          delayedCallbacks: eventDelayedCallbacks[kind] ?? 0,
                          busyMilliseconds: NavigationPerformance.Summary(eventBusy[kind] ?? []))
                }
            }
            result.delayedCallbacksWithoutEvents = delayedWithoutEvents
            result.lateCallbacks = lateCallbacks
            result.busyWithRowEntered = NavigationPerformance.Summary(busyEntered)
            result.cpuWithRowEntered = NavigationPerformance.Summary(cpuEntered)
            result.entriesBegunOnEfficiencyCore = entriesBegunOnEfficiency
            result.entryTimelines = entryTimelines
            result.busyWithoutEvents = NavigationPerformance.Summary(busyQuiet)
        }
        continuation.resume(returning: result)
    }

    private func makeResult(timedOut: Bool, failureReason: String?) -> Result {
        Result(name: name, callbacks: intervals.count,
               durationSeconds: firstTime.map { CACurrentMediaTime() - $0 } ?? 0,
               expectedFrameMilliseconds: expected * 1_000,
               callbackIntervals: NavigationPerformance.Summary(intervals),
               delayedCallbacks: delayed,
               delayedCallbackFraction: Double(delayed) / Double(max(1, intervals.count)),
               mainRunLoopStallsOver100ms: intervals.filter { $0 >= 100 }.count,
               timedOut: timedOut,
               failureReason: failureReason ?? (distance > 0 ? nil : "No native scroll offset movement was observed."),
               surfaceIdentifier: scroll?.identifier?.rawValue ?? ((scroll?.documentView is NSTableView) ? "native-mail-table" : nil),
               documentType: scroll?.documentView.map { String(reflecting: type(of: $0)) },
               maximumScrollRangePoints: maximumRange,
               distanceScrolledPoints: distance,
               physicalFootprintBytes: NavigationPerformance.physicalFootprint())
    }
}

/// What the reader did since the last display-link callback. A scroll run takes
/// the counts at every callback, so its report can show which events came with
/// a late one. The counts hold no mail.
@MainActor
enum PerformanceFrameEvents {
    enum Kind: String, CaseIterable {
        /// A message scrolled into the reader's viewport, or out of it.
        case rowEntered, rowLeft
        /// A message's prepared body arrived, or was dropped after it left.
        case bodyPrepared, bodyReleased
        case webViewMade, webViewDismantled
        /// A web view's measured height changed the message's height.
        case heightPublished
        case becameReadable
        /// Evaluations of `MessageView.body` and `MessageHeader.body`.
        case messageBody, headerBody
        /// The lazy stack built a message's row, or let it go.
        case rowBuilt, rowDropped
        /// Evaluations of the bodies inside a header.
        case actionsBody, menuItemsBody, addressMenuBody, avatarBody
    }

    private static var counts: [Kind: Int] = [:]
    private static var timeline: [(Kind, CFTimeInterval)] = []

    static func note(_ kind: Kind) {
        counts[kind, default: 0] += 1
        if timeline.count < 200 { timeline.append((kind, CACurrentMediaTime())) }
    }

    /// The events since the last call in the order they came, each with its time.
    static func takeTimeline() -> [(Kind, CFTimeInterval)] {
        defer { timeline.removeAll(keepingCapacity: true) }
        return timeline
    }

    /// The events since the last call.
    static func take() -> [Kind: Int] {
        defer { counts.removeAll(keepingCapacity: true) }
        return counts
    }
}

/// Places the real pointer for a scroll measurement. Only a run started with
/// `--performance-pointer-on-list` or `--performance-pointer-on-reader` calls
/// this, and it returns the pointer to where it found it.
@MainActor
enum PerformancePointer {
    /// Mail rows that gained or lost the pointer since this was last set to zero.
    static var hoverChanges = 0

    /// The pointer's place in Core Graphics' global coordinates, whose origin
    /// is the top left of the first screen.
    static var location: CGPoint { global(NSEvent.mouseLocation) }

    private static func global(_ screenPoint: NSPoint) -> CGPoint {
        CGPoint(x: screenPoint.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screenPoint.y)
    }

    /// Rests the pointer on the middle of `view`'s visible part.
    static func rest(on view: NSView) -> Bool {
        guard let window = view.window else { return false }
        let visible = view.visibleRect
        return move(to: view.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil), in: window)
    }

    /// Parks the pointer in the window's trailing bottom corner, away from the lists.
    static func park(in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        let inset = Tokens.Space.s6
        return move(to: content.convert(NSPoint(x: content.bounds.maxX - inset,
            y: content.isFlipped ? content.bounds.maxY - inset : content.bounds.minY + inset), to: nil), in: window)
    }

    /// Moving the pointer this way posts no event, so AppKit hears of it
    /// from a mouse-moved event sent here.
    private static func move(to windowPoint: NSPoint, in window: NSWindow) -> Bool {
        let target = global(window.convertPoint(toScreen: windowPoint))
        guard restore(target) else { return false }
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: windowPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0) {
            NSApp.sendEvent(event)
        }
        let now = location
        return abs(now.x - target.x) <= 1 && abs(now.y - target.y) <= 1
    }

    @discardableResult
    static func restore(_ location: CGPoint) -> Bool {
        guard CGWarpMouseCursorPosition(location) == .success else { return false }
        // A warp holds real pointer movement back for a quarter of a second unless told otherwise.
        CGAssociateMouseAndMouseCursorPosition(1)
        return true
    }
}
#endif
