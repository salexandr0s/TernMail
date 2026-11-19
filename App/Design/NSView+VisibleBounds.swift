import AppKit

extension NSView {
    /// The part of the view's own bounds that is on screen.
    ///
    /// `visibleRect` alone reaches past the bounds of a view that does not clip, as far as its nearest clipping
    /// ancestor allows: a 12-point handle in an unclipped 600-point container reports all 600 points.
    var visibleBounds: NSRect { bounds.intersection(visibleRect) }
}
