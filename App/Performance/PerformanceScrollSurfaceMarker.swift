import SwiftUI

/// Put this inside scrolling content, so AppKit supplies the actual enclosing
/// scroll container. Production builds contain only an EmptyView.
struct PerformanceScrollSurfaceMarker: View {
    let name: String
    let isActive: Bool

    var body: some View {
        #if DEBUG || TERN_PERFORMANCE
        NativeMarker(name: name, isActive: isActive)
        #else
        EmptyView()
        #endif
    }
}

#if DEBUG || TERN_PERFORMANCE
import AppKit

private struct NativeMarker: NSViewRepresentable {
    let name: String
    let isActive: Bool

    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) { view.configure(name: name, active: isActive) }
    static func dismantleNSView(_ view: MarkerView, coordinator: Void) { view.unregister() }

    final class MarkerView: NSView {
        private var name = ""
        private var active = false
        private weak var registeredScroll: NSScrollView?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); register() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); register() }
        override func layout() { super.layout(); register() }

        func configure(name: String, active: Bool) {
            unregister()
            self.name = name
            self.active = active
            register()
            DispatchQueue.main.async { [weak self] in self?.register() }
        }

        private func register() {
            if active, registeredScroll?.window === window,
               registeredScroll?.identifier == NSUserInterfaceItemIdentifier("tern-performance-scroll-" + name) { return }
            guard active, let scroll = enclosingScrollView ?? (name == "mailbox" ? nativeListScroll() : nil) else { return }
            scroll.identifier = NSUserInterfaceItemIdentifier("tern-performance-scroll-" + name)
            registeredScroll = scroll
        }

        /// SwiftUI List hosts its background beside its native table. Find only
        /// an unambiguous table container in the nearest enclosing native subtree,
        /// whose viewport occupies the marker's own rectangle. Never pick a
        /// rightmost/largest unrelated scroll view elsewhere in the workspace.
        private func nativeListScroll() -> NSScrollView? {
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return nil }
            let marker = convert(bounds, to: nil)
            func collect(_ view: NSView) -> [NSScrollView] {
                if let scroll = view as? NSScrollView { return [scroll] }
                return view.subviews.flatMap(collect)
            }
            var ancestor = superview
            while let view = ancestor {
                let matching = collect(view).filter { scroll in
                    guard scroll.documentView is NSTableView else { return false }
                    let frame = scroll.convert(scroll.bounds, to: nil)
                    let intersection = frame.intersection(marker)
                    return !intersection.isNull && intersection.width * intersection.height >= marker.width * marker.height * 0.9
                        && abs(frame.width - marker.width) < 4 && abs(frame.height - marker.height) < 4
                }
                if matching.count == 1 { return matching[0] }
                if matching.count > 1 { return nil }
                ancestor = view.superview
            }
            return nil
        }

        func unregister() {
            let identifier = NSUserInterfaceItemIdentifier("tern-performance-scroll-" + name)
            if registeredScroll?.identifier == identifier { registeredScroll?.identifier = nil }
            registeredScroll = nil
        }
    }
}
#endif
