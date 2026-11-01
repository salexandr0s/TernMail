#if DEBUG || TERN_PERFORMANCE
import AppKit
import Testing
import WebKit
@testable import Tern

@Suite @MainActor struct ReaderLayoutDiagnosticsTests {
    @Test func requiresOneExplicitAbsoluteReportPath() {
        #expect(ReaderLayoutDiagnostics.destination(in: []) == nil)
        #expect(ReaderLayoutDiagnostics.destination(in: ["--reader-layout-report="]) == nil)
        #expect(ReaderLayoutDiagnostics.destination(in: ["--reader-layout-report=relative.json"]) == nil)
        #expect(ReaderLayoutDiagnostics.destination(in: ["--reader-layout-report=/tmp/a", "--reader-layout-report=/tmp/b"]) == nil)
        #expect(ReaderLayoutDiagnostics.destination(in: ["--reader-layout-report=/tmp/a\0b"]) == nil)
        #expect(ReaderLayoutDiagnostics.destination(in: ["--reader-layout-report=/tmp/reader-layout.json"])?.path == "/tmp/reader-layout.json")
    }

    @Test func ringRemainsBoundedAndStopFlushesOnlyTheLatestEvents() async throws {
        let destination = temporaryReport()
        defer { try? FileManager.default.removeItem(at: destination) }
        let recorder = ReaderLayoutDiagnostics(destination: destination)
        for generation in 0..<4_100 { recordVisibility(recorder, generation: UInt64(generation)) }
        let live = recorder.report()
        #expect(!live.stopped)
        #expect(live.events.count == 4_096)
        #expect(live.totalEvents == 4_100 && live.overwrittenEvents == 4)
        #expect(live.events.first?.sequence == 4 && live.events.last?.sequence == 4_099)
        #expect(live.events.allSatisfy { $0.renderer == nil && $0.visibility?.window.attached == false })
        let flushed = await recorder.stop()
        #expect(flushed)
        recordVisibility(recorder, generation: 4_101)
        #expect(recorder.report().totalEvents == 4_100)
        let stored = try JSONDecoder().decode(ReaderLayoutDiagnostics.Report.self, from: Data(contentsOf: destination))
        #expect(stored.stopped && stored.events.count == 4_096 && stored.totalEvents == 4_100)
    }

    @Test func rendererEpochsKeepRequestAndReceiptDistinctAndRejectNonfiniteNumbers() async throws {
        let destination = temporaryReport()
        defer { try? FileManager.default.removeItem(at: destination) }
        let recorder = ReaderLayoutDiagnostics(destination: destination)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = ContentSizedWebView(frame: .zero, configuration: configuration)
        recorder.register(view)
        recorder.recordRenderer(view, phase: .load, documentRevision: 3, readable: false)
        let request = try #require(view.readerLayoutState?.epoch)
        recorder.recordRenderer(view, phase: .frame, widthChanged: true)
        recorder.recordRenderer(view, phase: .activation, active: false, previousActive: true, requestedActive: false)
        recorder.recordRenderer(view, phase: .height, heightSource: .nativeEvaluation, requestEpoch: request,
                                receivedHeight: .nan, oldBindingHeight: .infinity, publishedHeight: false)
        let receipt = try #require(recorder.report().events.last?.renderer)
        #expect(receipt.requestEpoch == request)
        #expect(receipt.epoch.documentRevision == 3)
        #expect(receipt.epoch.roundedWidthGeneration == 1 && receipt.epoch.activationGeneration == 1)
        #expect(receipt.receivedHeight == nil && receipt.oldBindingHeight == nil)
        #expect(recorder.report().invalidHeights == 1)
        recorder.recordRenderer(view, phase: .height, heightSource: .script, receivedHeight: 240)
        #expect(recorder.report().events.last?.renderer?.requestEpoch == nil)
        let flushed = await recorder.stop()
        #expect(flushed)
        let stored = try JSONDecoder().decode(ReaderLayoutDiagnostics.Report.self, from: Data(contentsOf: destination))
        #expect(stored.invalidHeights == 1 && stored.stopped)
    }

    @Test func windowTokensDoNotRetainClosedWindows() async throws {
        let destination = temporaryReport()
        defer { try? FileManager.default.removeItem(at: destination) }
        let recorder = ReaderLayoutDiagnostics(destination: destination)
        let windows = NSHashTable<NSWindow>.weakObjects()
        autoreleasepool {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            windows.add(window)
            recordVisibility(recorder, generation: 1, window: window)
            window.close()
        }
        #expect(windows.allObjects.isEmpty)
        let recordedWindow = try #require(recorder.report().events.first?.visibility?.window)
        #expect(recordedWindow.attached && recordedWindow.token != nil)
        let flushed = await recorder.stop()
        #expect(flushed)
    }

    private func recordVisibility(_ recorder: ReaderLayoutDiagnostics, generation: UInt64, window: NSWindow? = nil) {
        recorder.recordVisibility(observerToken: 1, ownerToken: 2, queuedOwnerToken: 2,
            callbackGeneration: generation, queuedCallbackGeneration: generation, phase: .deliver,
            reasonBits: 4, window: window, reported: false, sampledVisible: true,
            ownerVisible: false, scheduled: false, stopped: false)
    }

    private func temporaryReport() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "reader-layout-\(UUID().uuidString).json")
    }
}
#endif
