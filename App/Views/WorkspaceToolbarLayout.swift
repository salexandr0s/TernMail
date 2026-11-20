import SwiftUI

/// What the window toolbar folds at one window width.
///
/// A unified toolbar never shrinks its controls. Once they no longer fit it
/// moves the trailing ones, Assistant and Tasks first, into its overflow menu,
/// and it does that before it gives up any of the window title's width. This
/// type folds controls ahead of that point.
///
/// While the search field fits beside every section's folded actions, the
/// room left goes first to the section's expanded actions, then to the
/// profile picker's name, then to the window title. Below that width:
///
/// 1. The search field folds into a button, in every section at once, so
///    Search, Tasks and Assistant keep their places when the section changes.
/// 2. The section's sidebar steps aside (see `sidebarRoom`).
/// 3. Replies join the mail menu, and Today and then Previous and Next join
///    the calendar view menu.
/// 4. The profile picker joins the mail menu.
///
/// In Icon and Text mode most items grow to fit their labels, so each step
/// comes at a wider window. A window narrower than about 1,050 points can't
/// hold Mail's labelled controls even once all of them have folded, and there
/// the overflow menu takes the trailing ones.
///
/// The widths in `Metrics` are AppKit's item sizes in a unified toolbar on
/// macOS 26 and 27, not design tokens. `WorkspaceToolbarLayoutTests` lays the
/// toolbar out at each width in both modes and fails when a control leaves it.
struct WorkspaceToolbarLayout: Equatable {
    /// Where each section's sidebar ends, in points from the window's leading
    /// edge, or 0 while that sidebar is hidden.
    struct Sidebars: Equatable {
        var mail: CGFloat = 0
        var calendar: CGFloat = 0
        var attachments: CGFloat = 0
    }

    private(set) var showsTitle = false
    private(set) var compactProfile = true
    private(set) var compactActions = true
    private(set) var foldsSearch = true
    private(set) var foldsReplies = false
    private(set) var foldsCalendarToday = false
    private(set) var foldsCalendarNavigation = false
    private(set) var foldsProfile = false

    /// `profileNameWidth` is the active profile's name as the toolbar draws
    /// it, or nil while the user has no profiles and the picker stays hidden.
    /// `labels` is true while the toolbar shows a label under each item.
    init(section: WorkspaceSection, width: CGFloat, sidebars: Sidebars = Sidebars(), profileNameWidth: CGFloat? = nil,
         labels: Bool = false) {
        let hasProfiles = profileNameWidth != nil
        let fit = Fit(width: width, sidebars: sidebars, profileNameWidth: profileNameWidth,
            metrics: Metrics(labels: labels))
        foldsSearch = WorkspaceSection.allCases.contains { !fit.holds($0, .compact, search: .field) }
        guard foldsSearch else {
            // Mail has the most controls, so its room decides the picker's name
            // for Today and Waiting for as well.
            compactProfile = !hasProfiles || width < Metrics.namedProfileWindow
                || !fit.holds(.mail, .standard, search: .field, profile: .named)
            let profile: Profile = compactProfile ? .compact : .named
            compactActions = !fit.holds(section, .standard, search: .field, profile: profile)
            showsTitle = fit.holds(section, compactActions ? .compact : .standard, search: .field,
                profile: profile, title: true)
            return
        }
        guard !fit.holds(section, .compact, search: .button) else { return }
        switch section {
        case .mail:
            foldsReplies = true
            foldsProfile = hasProfiles && !fit.holds(.mail, .folded, search: .button)
        case .calendar:
            foldsCalendarToday = true
            foldsCalendarNavigation = !fit.holds(.calendar, .folded, search: .button)
        case .attachments, .followUps, .today:
            break
        }
    }

    /// The widest sidebar that leaves `section`'s folded actions, the Search
    /// button, Tasks and Assistant in a toolbar `width` points wide. A sidebar
    /// wider than this steps aside.
    static func sidebarRoom(for section: WorkspaceSection, width: CGFloat, hasProfiles: Bool = false,
                            labels: Bool = false) -> CGFloat {
        let fit = Fit(width: width, sidebars: Sidebars(), profileNameWidth: hasProfiles ? 0 : nil,
            metrics: Metrics(labels: labels))
        return width - fit.required(section, .compact, search: .button, edge: 0)
    }

    enum Actions { case standard, compact, folded, minimal }
    enum Search { case field, button }
    enum Profile { case compact, named }

    private struct Fit {
        let width: CGFloat
        let sidebars: Sidebars
        let profileNameWidth: CGFloat?
        let metrics: Metrics

        func holds(_ section: WorkspaceSection, _ actions: Actions, search: Search,
                   profile: Profile = .compact, title: Bool = false) -> Bool {
            let edge: CGFloat = switch section {
            case .mail: sidebars.mail
            case .calendar: sidebars.calendar
            case .attachments: sidebars.attachments
            case .followUps, .today: 0
            }
            return required(section, actions, search: search, profile: profile, title: title,
                edge: max(edge, Metrics.windowControls)) <= width
        }

        /// The toolbar width `section` needs past `edge`, with the margin that
        /// keeps a control from sitting against the window's edge.
        func required(_ section: WorkspaceSection, _ actions: Actions, search: Search,
                      profile: Profile = .compact, title: Bool = false, edge: CGFloat) -> CGFloat {
            var picker: CGFloat = 0
            if let profileNameWidth, section != .calendar, section != .attachments {
                picker = metrics.profile(profile, nameWidth: profileNameWidth)
            }
            return edge + metrics.navigation(section) + Metrics.flexibleSpace + picker
                + metrics.actions(section, actions)
                + (search == .field ? Metrics.searchField : metrics.searchButton(section)) + metrics.utilities
                + (title ? Metrics.title : 0) + Metrics.margin
        }
    }

    /// Measured item widths, each with the gap that follows it. With `labels`
    /// they are the widths in Icon and Text mode.
    private struct Metrics {
        let labels: Bool

        /// The close, minimize and zoom buttons, where the toolbar starts
        /// while no sidebar shows.
        static let windowControls: CGFloat = 88
        /// The narrowest a unified toolbar draws the window title.
        static let title: CGFloat = 164
        static let flexibleSpace: CGFloat = 8
        static let margin: CGFloat = 8
        static let compactProfile: CGFloat = 58
        /// Between the picker's icon and its name, with room for a toolbar
        /// font slightly wider than the one the name is measured in.
        static let profileNameGap: CGFloat = 16
        /// A named profile picker waits for a wide window.
        static let namedProfileWindow: CGFloat = 1440
        /// Two spaces, the field, and two more spaces. The field shows no
        /// label in either mode.
        static let searchField: CGFloat = 216

        /// With labels, the picker is never narrower than its label.
        func profile(_ profile: Profile, nameWidth: CGFloat) -> CGFloat {
            let labelled: CGFloat = labels ? 99 : 0
            return switch profile {
            case .compact: max(labelled, Self.compactProfile)
            case .named: max(labelled, Self.compactProfile + Self.profileNameGap + nameWidth)
            }
        }

        /// Two spaces, the Search button, and two more spaces. The button's
        /// label names what it searches, so its width changes by section.
        func searchButton(_ section: WorkspaceSection) -> CGFloat {
            guard labels else { return 68 }
            return switch section {
            case .mail: 111
            case .calendar: 124
            case .attachments: 155
            case .followUps: 145
            case .today: 121
            }
        }

        /// Tasks and Assistant, with the toolbar's trailing margin.
        var utilities: CGFloat { labels ? 159 : 92 }

        /// Sidebar, Refresh, the section switcher and New, or Refresh and the
        /// switcher alone where a section has no sidebar or New button.
        /// AppKit draws the Sidebar and Refresh item 80 points wide, and this
        /// counts it as 85. Without those 5 points, Mail's expanded actions
        /// would fill a default-size window beside the sidebar with no room
        /// to spare, and the window would lose its title. With labels the
        /// switcher keeps its width, and Calendar's New Event label is
        /// shorter than New Message.
        func navigation(_ section: WorkspaceSection) -> CGFloat {
            let switcher = CGFloat(WorkspaceSection.allCases.count) * 40
            let items: CGFloat = switch section {
            case .mail, .attachments: labels ? 199 : 137
            case .calendar: labels ? 181 : 137
            case .followUps, .today: labels ? 66 : 52
            }
            return items + switcher
        }

        /// A section's own controls. Mail's two fixed spaces stay in every
        /// section, because a toolbar space can't be hidden.
        func actions(_ section: WorkspaceSection, _ actions: Actions) -> CGFloat {
            switch (section, actions) {
            case (.mail, .standard): labels ? 714 : 396
            case (.mail, .compact): labels ? 384 : 167
            case (.mail, .folded), (.mail, .minimal): labels ? 277 : 126
            case (.calendar, .standard): labels ? 296 : 222
            case (.calendar, .compact): labels ? 257 : 176
            case (.calendar, .folded): labels ? 214 : 139
            case (.calendar, .minimal): 54
            case (.attachments, .standard): labels ? 151 : 141
            case (.attachments, _): labels ? 104 : 57
            case (.followUps, _), (.today, _): 16
            }
        }
    }
}
