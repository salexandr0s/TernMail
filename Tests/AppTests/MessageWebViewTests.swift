import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Tern

@Suite @MainActor struct MessageWebViewTests {
    @Test func heightShrinksWhenTextReflowsIntoAWiderPane() async throws {
        let height = HeightValue()
        let coordinator = MessageWebView.Coordinator(height: Binding(get: { height.value }, set: { height.value = $0 }))
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "ternHeight")
        let view = ContentSizedWebView(frame: NSRect(x: 0, y: 0, width: 220, height: 32), configuration: configuration)
        view.navigationDelegate = coordinator
        let text = String(repeating: "A sentence that wraps when the message pane is narrow. ", count: 12)
        coordinator.load("<html><body style='margin:0;padding:16px'><p>\(text)</p></body></html>", in: view)
        try await waitFor { height.value > 100 }
        let narrow = height.value
        view.setFrameSize(NSSize(width: 900, height: narrow))
        coordinator.measure(view)
        try await waitFor { height.value < narrow }
        #expect(height.value < narrow)
        // Inline images and fonts can lay out after navigation has finished.
        _ = try await view.evaluateJavaScript("document.querySelector('p').style.height = '800px'", in: nil, contentWorld: .defaultClient)
        try await waitFor { height.value >= 800 }
    }
}

@MainActor private final class HeightValue { var value: CGFloat = 0 }

@MainActor private func waitFor(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    #expect(condition(), "WebKit did not report the expected content height")
}
