import SwiftUI

/// Sets the hosting window's edited state, which the close button shows as a dot.
struct WindowEditedMarker: NSViewRepresentable {
    let isEdited: Bool

    func makeNSView(context: Context) -> MarkerView {
        let view = MarkerView()
        view.isEdited = isEdited
        return view
    }

    func updateNSView(_ view: MarkerView, context: Context) {
        view.isEdited = isEdited
    }

    final class MarkerView: NSView {
        var isEdited = false {
            didSet { window?.isDocumentEdited = isEdited }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isDocumentEdited = isEdited
        }
    }
}
