#if DEBUG || TERN_PERFORMANCE
import AppKit
import QuartzCore

/// Measures display-link callback delivery while changing a native scroll offset.
/// It deliberately does not label callback gaps as missed *rendered* frames.
@MainActor
final class PerformanceScrollAudit: NSObject {
    struct Result: Codable {
        let name: String
        let callbacks: Int
        let expectedFrameMilliseconds: Double
        let callbackIntervals: NavigationPerformance.Summary?
        let delayedCallbacks: Int
        let delayedCallbackFraction: Double
        let mainRunLoopStallsOver100ms: Int
        let timedOut: Bool
        let physicalFootprintBytes: UInt64?
    }

    private weak var scroll: NSScrollView?
    private var link: CADisplayLink?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<Result, Never>?
    private let name: String
    private let requestedFrames: Int
    private var intervals: [Double] = []
    private var expected = 1.0 / 60
    private var lastTime: CFTimeInterval?
    private var direction: CGFloat = 1
    private var ticks = 0
    private var delayed = 0

    private init(name: String, scroll: NSScrollView, frames: Int) {
        self.name = name
        self.scroll = scroll
        self.requestedFrames = frames
    }

    static func run(name: String, scroll: NSScrollView, frames: Int = 360) async -> Result {
        let audit = PerformanceScrollAudit(name: name, scroll: scroll, frames: frames)
        return await audit.start()
    }

    private func start() async -> Result {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            guard let scroll else { finish(timedOut: true); return }
            let link = scroll.displayLink(target: self, selector: #selector(tick(_:)))
            self.link = link
            link.add(to: .main, forMode: .common)
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                self?.finish(timedOut: true)
            }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scroll, let document = scroll.documentView else { finish(timedOut: true); return }
        let time = CACurrentMediaTime()
        let period = link.targetTimestamp - link.timestamp
        if period > 0 { expected = period }
        if let lastTime, ticks > 10 {
            let interval = time - lastTime
            intervals.append(interval * 1_000)
            if interval > expected * 1.5 { delayed += 1 }
        }
        lastTime = time
        ticks += 1
        let clip = scroll.contentView
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(maximum, max(0, origin.y + 18 * direction))
        if origin.y >= maximum { direction = -1 }
        else if origin.y <= 0 { direction = 1 }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        if ticks >= requestedFrames { finish(timedOut: false) }
    }

    private func finish(timedOut: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        link?.invalidate(); link = nil
        timeout?.cancel(); timeout = nil
        continuation.resume(returning: Result(name: name, callbacks: intervals.count,
                                              expectedFrameMilliseconds: expected * 1_000,
                                              callbackIntervals: NavigationPerformance.Summary(intervals),
                                              delayedCallbacks: delayed,
                                              delayedCallbackFraction: Double(delayed) / Double(max(1, intervals.count)),
                                              mainRunLoopStallsOver100ms: intervals.filter { $0 >= 100 }.count,
                                              timedOut: timedOut,
                                              physicalFootprintBytes: NavigationPerformance.physicalFootprint()))
    }
}
#endif
