import SwiftUI

extension Tokens {
    /// Today keeps work readable while reserving a compact rail for the calendar.
    enum Today {
        static let contentWidth: CGFloat = 1120
        static let calendarWidth: CGFloat = 280
        static let workColumnMinWidth: CGFloat = 500
        static let columnGap = Space.s5
        static let pageInset = Space.s6
        static let compactInset = Space.s4
        static let twoColumnMinWidth = workColumnMinWidth + calendarWidth + columnGap + pageInset * 2
    }
}
