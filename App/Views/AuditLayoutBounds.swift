import AppKit
import SwiftUI

extension View {
    /// SwiftUI can merge AX groups and report their children's union without
    /// padding, or include a safe-area ancestor. Audit native bounds instead.
    @ViewBuilder func auditLayoutBounds(_ identifier: String) -> some View {
        #if DEBUG || TERN_PERFORMANCE
        overlay {
            if ProcessInfo.processInfo.arguments.contains("--ui-audit") {
                AuditLayoutBounds(identifier: identifier)
                    .accessibilityHidden(true)
            }
        }
        #else
        self
        #endif
    }
}

#if DEBUG || TERN_PERFORMANCE
/// An audit-only overlay measures its host without changing layout or hit testing.
struct AuditLayoutBounds: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ view: BoundaryView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BoundaryView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class BoundaryView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
#endif
