import SwiftUI

/// Geometry-based navigation must preserve the active panels' native minimum.
struct WorkspaceMinimumWidth: PreferenceKey {
    static let defaultValue = Tokens.Layout.windowMinWidth

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
