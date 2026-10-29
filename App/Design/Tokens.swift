import SwiftUI

/// Spacing, radius and motion values mirrored from the workspace design contract
/// (`~/.claude/uiux-contract/design_tokens.json`). Colors and type use macOS
/// semantic colors and text styles instead, so system appearance settings apply.
enum Tokens {
    enum Space {
        static let s0_5: CGFloat = 2
        static let s1: CGFloat = 4
        static let s1_5: CGFloat = 6
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
        static let s10: CGFloat = 40
        static let s12: CGFloat = 48
        static let s16: CGFloat = 64
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
    }

    enum Surface {
        static let canvas = Color(nsColor: .underPageBackgroundColor)
        static let primary = Color(nsColor: .controlBackgroundColor)
        static let muted = Color(nsColor: .windowBackgroundColor)
        static let border = Color(nsColor: .separatorColor)
    }

    enum Border {
        static let hairline: CGFloat = 1
        static let focus: CGFloat = 2
    }

    /// Native controls use the contract's compact dimensions.
    enum Control {
        static let icon = Space.s4
        static let iconButton = Space.s8
        static let avatar = Space.s8
        static let avatarLarge = Space.s10
    }

    enum Layout {
        static let windowWidth: CGFloat = 1280
        static let windowHeight: CGFloat = 800
        static let windowMinWidth: CGFloat = 960
        static let windowMinHeight: CGFloat = 600
        static let compactToolbarWidth: CGFloat = 1120
        static let sidebarMinWidth: CGFloat = 180
        static let sidebarWidth: CGFloat = 220
        static let sidebarMaxWidth: CGFloat = 320
        static let listMinWidth: CGFloat = 300
        static let listWidth: CGFloat = 360
        static let searchMinWidth: CGFloat = 180
        static let searchWidth: CGFloat = 320
        static let searchMaxWidth: CGFloat = 420
        static let readableWidth: CGFloat = 880
        static let emptyStateWidth: CGFloat = 320
        static let composeMinWidth: CGFloat = 480
        static let composeMinHeight: CGFloat = 360
        static let quoteMaxHeight: CGFloat = 180
        static let linkEditorWidth: CGFloat = 320
        static let attachmentWidth: CGFloat = 240
        static let shortcutsWidth: CGFloat = 480
        static let shortcutsHeight: CGFloat = 600
    }

    /// `shadow.md`: 0 8px 20px rgba(0,0,0,0.10). SwiftUI's radius is about half the CSS blur.
    enum Shadow {
        static let mdColor = Color.black.opacity(0.10)
        static let mdRadius: CGFloat = 10
        static let mdY: CGFloat = 8
    }

    /// `components/dropdown.yaml`: width and list height cap for pickers.
    enum Popover {
        static let width: CGFloat = 320
        static let maxListHeight: CGFloat = 320
    }

    /// `components/modal.yaml`, small size.
    enum Sheet {
        static let smallWidth: CGFloat = 420
    }

    /// `components/toast.yaml`.
    enum Toast {
        static let width: CGFloat = 360
        static let info: Duration = .milliseconds(3500)
        static let error: Duration = .milliseconds(6000)
    }

    enum Motion {
        static let fast: Double = 0.12
        static let base: Double = 0.16
        static let slow: Double = 0.22

        /// `motion.easing.standard`: cubic-bezier(0.2, 0.8, 0.2, 1).
        static func standard(duration: Double = base) -> Animation {
            .timingCurve(0.2, 0.8, 0.2, 1, duration: duration)
        }
    }
}
