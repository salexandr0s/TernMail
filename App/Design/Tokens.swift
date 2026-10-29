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
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
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
