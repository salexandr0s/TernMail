import SwiftUI

extension Tokens {
    /// Hierarchical text follows the surrounding foreground and selection context.
    enum Text {
        static let primary = HierarchicalShapeStyle.primary
        static let secondary = HierarchicalShapeStyle.secondary
        /// Badge text and avatar initials retain label ink inside selected rows.
        static let label = Color(nsColor: .labelColor)
    }

    enum Action {
        static let accent = Color.accentColor
    }

    /// Shared component roles retain native text styles and their current weights.
    enum Typography {
        static let sectionTitle = Font.headline
        static let supporting = Font.callout
        static let metadata = Font.caption
        static let finePrint = Font.caption2
        static let controlSymbol = Font.title3
        static let badge = Font.caption.weight(.medium)
        static let avatar = Font.caption.weight(.semibold)
        static let avatarLarge = Font.headline
        static let emptyStateTitle = Font.title3.weight(.semibold)
        static let emptyStateSymbol = Font.largeTitle.weight(.light)
    }
}
