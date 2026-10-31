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

    /// Status colors. System colors carry Increase Contrast and dark variants
    /// that the literal `.red` and friends lack.
    enum Status {
        static let error = Color(nsColor: .systemRed)
        static let warning = Color(nsColor: .systemOrange)
        static let success = Color(nsColor: .systemGreen)
        static let star = Color(nsColor: .systemYellow)
        static let important = Color(nsColor: .systemOrange)
    }

    /// Tint strengths for hover, pressed and selected states.
    enum Opacity {
        static let hover = 0.06
        static let pressed = 0.10
        static let tint = 0.14
        static let disabled = 0.5
    }

    /// Generated reading aids sit more quietly than the original message cards.
    enum ConversationHeader {
        static let surface = Surface.primary.opacity(0.45)
        static let border = Surface.border.opacity(0.6)
        static let dateTile = Space.s8
        static let statusBadge = Space.s3
    }

    enum Assistant {
        static let sidebarMinWidth: CGFloat = 320
        static let sidebarWidth: CGFloat = 380
        static let sidebarMaxWidth: CGFloat = 480
        static let readerMinWidth = Layout.emptyStateWidth
        static let contentWidth: CGFloat = 720
        static let settingsHeight: CGFloat = 680
        static let bubbleInset = Space.s10
        static let userBubble = Color.accentColor.opacity(0.14)
        static let assistantBubble = Surface.primary
        static let chatBackground = Surface.canvas
    }

    /// Calendar panes and sheets share native control sizing and semantic surfaces.
    enum Calendar {
        static let sidebarWidth: CGFloat = 248
        static let compactWidth: CGFloat = 760
        static let contentMinWidth: CGFloat = 420
        static let viewPickerWidth: CGFloat = 260
        static let editorWidth: CGFloat = 600
        static let editorHeight: CGFloat = 680
        static let settingsWidth: CGFloat = 760
        static let settingsHeight: CGFloat = 680
        static let activityWidth: CGFloat = 620
        static let activityHeight: CGFloat = 520
        static let eventTint = 0.12
        static let allDayTint = 0.18
        static let selectedTint = 0.24
        static let todayTint = 0.04
        /// Sheets grow with their content; this keeps the editor and reviews usable when nearly empty.
        static let sheetMinHeight: CGFloat = 400
    }

    enum Settings {
        static let width: CGFloat = 800
        static let height: CGFloat = 620
        static let minWidth: CGFloat = 740
        static let minHeight: CGFloat = 500
        static let sidebarWidth: CGFloat = 208
        static let contentWidth: CGFloat = 640
        static let controlWidth: CGFloat = 280
        /// Pickers and fields inside a settings group.
        static let pickerWidth: CGFloat = 240
        static let navigationIcon = Space.s5
        static let groupTint = 0.045
        static let rowHeight = Space.s6 + Space.s1
        static let editorWidth: CGFloat = 480
        static let editorWideWidth: CGFloat = 560
        static let editorMaxContentHeight: CGFloat = 440
        static let editorLabelWidth: CGFloat = 80
        /// Account rows in Preferences show an avatar beside two lines of text.
        static let accountRowHeight = Space.s12
        /// Typing pauses this long before a live-applied field writes.
        static let liveApplyDelay: Duration = .milliseconds(750)
    }

    /// Native controls use the contract's compact dimensions.
    enum Control {
        static let icon = Space.s4
        static let iconButton = Space.s8
        static let avatar = Space.s8
        static let avatarLarge = Space.s10
        /// Message list rows show a smaller disc than headers do.
        static let listAvatar = Space.s5
    }

    enum Layout {
        static let windowWidth: CGFloat = 1280
        static let windowHeight: CGFloat = 800
        // Two windows fit side by side on a 13-inch display.
        static let windowMinWidth: CGFloat = 720
        static let windowMinHeight: CGFloat = 480
        static let compactToolbarWidth: CGFloat = 1120
        static let sidebarMinWidth: CGFloat = 180
        static let sidebarWidth: CGFloat = 220
        static let sidebarMaxWidth: CGFloat = 320
        static let listMinWidth: CGFloat = 300
        static let listWidth: CGFloat = 360
        /// Grab gutter beside the sidebar and the list, outside their scroll views.
        static let columnGutter = Space.s2
        static let searchMinWidth: CGFloat = 180
        static let searchWidth: CGFloat = 200
        static let searchMaxWidth: CGFloat = 420
        static let readableWidth: CGFloat = 880
        static let emptyStateWidth: CGFloat = 320
        static let composeMinWidth: CGFloat = 480
        static let composeMinHeight: CGFloat = 360
        /// A conversation in its own window keeps its header and toolbar readable.
        static let conversationMinWidth: CGFloat = 560
        static let conversationMinHeight: CGFloat = 400
        /// The To, Cc and Subject column in a compose header.
        static let composeLabelWidth: CGFloat = 64
        /// Room to write below the recipients, files and quoted text.
        static let editorMinHeight: CGFloat = 128
        /// A sender name keeps this much width before the metadata wraps below it.
        static let senderMinWidth: CGFloat = 128
        static let quoteMaxHeight: CGFloat = 128
        static let linkEditorWidth: CGFloat = 320
        static let attachmentWidth: CGFloat = 240
        static let shortcutsWidth: CGFloat = 480
        static let shortcutsHeight: CGFloat = 600
        static let settingsWidth: CGFloat = 520
        static let settingsHeight: CGFloat = 280
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
