import AppKit
import ScreenCaptureKit

/// Captures native materials from the compositor, restricted to the audit process's own window.
enum NativeWindowCapture {
    @MainActor static func png(of window: NSWindow) async throws -> Data {
        guard window.windowNumber > 0, window.isVisible else {
            throw CaptureFailure(description: "The audit window must be visible before native capture")
        }
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return try await capture(windowID: CGWindowID(window.windowNumber),
            processID: ProcessInfo.processInfo.processIdentifier)
    }

    // Keep ScreenCaptureKit's non-Sendable objects within its nonisolated executor.
    // Only immutable window identifiers enter; encoded bytes return to the caller.
    private nonisolated static func capture(windowID: CGWindowID, processID: pid_t) async throws -> Data {
        // Own-process content is available without a Screen Recording grant.
        // A global content query or cacheDisplay fallback would violate this audit's scope.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.currentProcess
        } catch {
            throw CaptureFailure(description: "Could not enumerate the audit process's own window: \(error)")
        }
        guard let target = content.windows.first(where: {
            $0.windowID == windowID && $0.owningApplication?.processID == processID
        }) else {
            throw CaptureFailure(description: "No shareable window matches the requested audit window and process")
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded())
        configuration.height = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded())
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.colorSpaceName = CGColorSpace.sRGB
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            throw CaptureFailure(description: "Native compositor capture failed; no bitmap fallback was recorded: \(error)")
        }
        guard image.width > 0, image.height > 0,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CaptureFailure(description: "Native capture returned an empty image or could not be encoded as PNG")
        }
        return data
    }

    private struct CaptureFailure: Error, CustomStringConvertible {
        let description: String
    }
}
