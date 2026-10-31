import Foundation

/// A trackpad may begin with zero deltas. Choose its axis on the first actual
/// movement and keep it through momentum; a mouse wheel decides per event.
struct ScrollDirection {
    private var horizontal: Bool?

    mutating func isHorizontal(x: CGFloat, y: CGFloat, startsGesture: Bool = false, isMouseWheel: Bool = false) -> Bool {
        if startsGesture || isMouseWheel { horizontal = nil }
        if horizontal == nil, x != 0 || y != 0 { horizontal = abs(x) > abs(y) }
        return horizontal ?? false
    }
}
