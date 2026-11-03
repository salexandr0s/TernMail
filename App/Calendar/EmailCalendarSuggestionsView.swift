import MessageContent
import SwiftUI

/// A compact part of the conversation header. Details stay with their event so
/// a conversation summary can follow this group without repeating its content.
struct EmailCalendarSuggestionsView: View {
    @Bindable var model: EmailCalendarModel
    var calendar: Calendar = .autoupdatingCurrent
    var accountID: String? = nil
    let onReview: (EmailCalendarItem) -> Void
    let onOpenExisting: (EmailCalendarItem) -> Void
    let onRespond: (EmailCalendarItem, InvitationReply.Answer) -> Void
    var onDismiss: (String) -> Void = { _ in }
    var onRetry: (() -> Void)? = nil
    @State private var showsAll = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var orderedItems: [EmailCalendarItem] {
        EmailCalendarPresentation.ordered(model.visibleItems, messages: model.messages)
    }

    var body: some View {
        if !orderedItems.isEmpty || model.isInterpreting || model.interpretationError != nil {
            VStack(alignment: .leading, spacing: 0) {
                let displayed = showsAll ? orderedItems : Array(orderedItems.prefix(2))
                ForEach(displayed) { item in
                    if item.id != displayed.first?.id {
                        Divider().padding(.horizontal, Tokens.Space.s4)
                    }
                    EmailCalendarSuggestionRow(
                        item: item, calendar: calendar, accountID: accountID,
                        canRespond: !item.isOutdated && item.kind != .cancelled
                            && item.invitation?.method == .request && model.attendee(for: item) != nil,
                        onReview: { onReview(item) }, onOpenExisting: { onOpenExisting(item) },
                        onRespond: { onRespond(item, $0) }, onDismiss: {
                            model.dismiss(item.id)
                            onDismiss(item.id)
                        })
                        .ternTransition(.disclosure)
                }
                if model.isInterpreting {
                    HStack(spacing: Tokens.Space.s2) {
                        ProgressView().controlSize(.mini)
                        Text("Checking events…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, Tokens.Space.s3)
                    .padding(.vertical, Tokens.Space.s2)
                }
                if orderedItems.count > 2 {
                    Divider().padding(.horizontal, Tokens.Space.s3)
                    Button {
                        showsAll.toggle()
                    } label: {
                        HStack(spacing: Tokens.Space.s1) {
                            Text(showsAll ? "Show fewer" : "Show all \(orderedItems.count) events")
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showsAll ? 180 : 0))
                            Spacer(minLength: 0)
                            if !showsAll, hiddenChanges > 0 {
                                Text(hiddenChanges == 1 ? "1 more update" : "\(hiddenChanges) more updates")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .padding(Tokens.Space.s3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .ternHover(radius: Tokens.Radius.md)
                    .accessibilityValue(showsAll ? "Expanded" : "Collapsed")
                }
                if let error = model.interpretationError {
                    HStack(alignment: .top, spacing: Tokens.Space.s2) {
                        Text("Some events could not be checked. \(error)")
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        if let onRetry {
                            Button("Retry", systemImage: "arrow.clockwise", action: onRetry)
                                .controlSize(.small)
                                .disabled(model.isInterpreting)
                                .help("Check events in this conversation again")
                                .accessibilityIdentifier("calendar-interpretation-retry")
                        }
                    }
                    .padding(.horizontal, Tokens.Space.s3)
                    .padding(.vertical, Tokens.Space.s2)
                }
            }
            .background(reduceTransparency ? Tokens.Surface.muted : Tokens.ConversationHeader.surface,
                in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.md)
                    .strokeBorder(contrast == .increased ? Tokens.Surface.border : Tokens.ConversationHeader.border,
                        lineWidth: Tokens.Border.hairline)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .ternAnimation(value: showsAll, duration: Tokens.Motion.slow)
            .onChange(of: model.messages.map(\.id)) { _, _ in showsAll = false }
        }
    }

    private var hiddenChanges: Int {
        orderedItems.dropFirst(2).filter { !$0.isOutdated && ($0.kind == .cancelled || $0.kind == .updated || $0.hasAmbiguousMatch) }.count
    }
}

private struct EmailCalendarSuggestionRow: View {
    let item: EmailCalendarItem
    let calendar: Calendar
    let accountID: String?
    let canRespond: Bool
    let onReview: () -> Void
    let onOpenExisting: () -> Void
    let onRespond: (InvitationReply.Answer) -> Void
    let onDismiss: () -> Void
    @State private var showsDetails = false
    @Environment(\.colorSchemeContrast) private var contrast

    private var presentation: EmailCalendarPresentation { .init(item: item, calendar: calendar) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Tokens.Space.s3) {
                    disclosure.frame(minWidth: Tokens.Space.s16 * 3)
                    HStack(spacing: Tokens.Space.s2) {
                        eventActions
                        moreMenu
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    HStack(alignment: .center, spacing: Tokens.Space.s3) {
                        disclosure
                        moreMenu.controlSize(.small).fixedSize()
                    }
                    eventActions
                        .controlSize(.small)
                        .fixedSize()
                        .padding(.leading, Tokens.ConversationHeader.dateTile + Tokens.Space.s3)
                }
            }
            if showsDetails {
                details.ternTransition(.disclosure)
            }
        }
        .padding(.horizontal, Tokens.Space.s4)
        .padding(.vertical, Tokens.Space.s3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.badge.text)
        .ternAnimation(value: showsDetails, duration: Tokens.Motion.slow)
    }

    private var disclosure: some View {
        Button { showsDetails.toggle() } label: {
            HStack(spacing: Tokens.Space.s3) {
                dateTile
                summary
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showsDetails ? 90 : 0))
                    .frame(width: Tokens.Space.s4)
            }
            .padding(.vertical, Tokens.Space.s1)
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain)
        .ternHover()
        .help(showsDetails ? "Hide event details" : "Show event details")
        .accessibilityLabel("\(showsDetails ? "Hide" : "Show") details for \(presentation.title)")
        .accessibilityValue("\(showsDetails ? "Expanded" : "Collapsed"), \(presentation.dateLine), \(presentation.badge.text)")
        .accessibilityIdentifier("calendar-details-\(item.id)")
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s1) {
            Text(presentation.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(presentation.title)
            Text(presentation.dateLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(presentation.badge.text, systemImage: presentation.badge.symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("calendar-status-\(item.id)")
            if let warning = item.authenticityWarning, warning != presentation.badge.text {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateTile: some View {
        dateTileFace
            .overlay(alignment: .topTrailing) {
                Image(systemName: presentation.badge.symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(badgeColor)
                    .frame(width: Tokens.ConversationHeader.statusBadge, height: Tokens.ConversationHeader.statusBadge)
                    .background(Tokens.Surface.muted, in: Circle())
                    .overlay { Circle().strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline) }
                    .offset(x: Tokens.Space.s1_5, y: -Tokens.Space.s1_5)
            }
            .fixedSize()
            .accessibilityHidden(true)
    }

    private var badgeColor: Color {
        switch presentation.badge.tone {
        case .positive: Tokens.Status.success
        case .caution: Tokens.Status.warning
        case .negative: Tokens.Status.error
        case .neutral: .secondary
        }
    }

    private var dateTileFace: some View {
        CalendarDateTile(month: presentation.month, day: presentation.day,
            size: Tokens.ConversationHeader.dateTile,
            isMuted: item.isOutdated || item.kind == .cancelled)
            .accessibilityHidden(true)
    }

    private var eventActions: some View {
        HStack(spacing: Tokens.Space.s2) {
            if canRespond {
                Menu("Respond") { responseActions }
                    .menuStyle(.borderedButton)
                    .help("Reply to this invitation")
            }
            if item.canReview && (item.kind == .updated || item.kind == .cancelled) {
                calendarButton
            } else if item.existingEventID != nil {
                Button("Open", systemImage: "calendar", action: onOpenExisting)
                    .help("Open this event in Calendar")
                    .accessibilityLabel("Open in Calendar: \(presentation.title)")
                    .accessibilityIdentifier("calendar-open-\(item.id)")
            } else if item.canReview {
                calendarButton
            }
        }
    }

    private var calendarButton: some View {
        Button(action: onReview) {
            Label(calendarActionLabel, systemImage: calendarActionSymbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(calendarActionColor)
            .padding(.horizontal, Tokens.Space.s2)
            .frame(minWidth: Tokens.Control.iconButton, minHeight: Tokens.Control.iconButton)
            .background(calendarActionColor.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .strokeBorder(calendarActionColor.opacity(contrast == .increased ? Tokens.Opacity.outline : Tokens.Opacity.tint),
                        lineWidth: Tokens.Border.hairline)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        }
        .buttonStyle(.plain)
        .ternHover()
        .help(calendarActionTitle)
        .accessibilityLabel("\(calendarActionTitle): \(presentation.title)")
        .accessibilityIdentifier("calendar-\(isAdding ? "add" : item.kind == .cancelled ? "remove" : "update")-\(item.id)")
    }

    private var isAdding: Bool { item.kind != .cancelled && !(item.kind == .updated && item.existingEventID != nil) }
    private var calendarActionColor: Color { item.kind == .cancelled ? Tokens.Status.error : .accentColor }
    private var calendarActionSymbol: String { isAdding ? "calendar.badge.plus" : item.kind == .cancelled ? "trash" : "arrow.triangle.2.circlepath" }
    private var calendarActionLabel: String { isAdding ? "Review…" : item.kind == .cancelled ? "Remove…" : "Update…" }

    private var calendarActionTitle: String {
        if item.kind == .cancelled { return "Remove cancelled event" }
        if item.kind == .updated, item.existingEventID != nil { return "Update in Calendar" }
        return item.invitation == nil ? "Review before adding to Calendar" : "Review personal copy before adding to Calendar"
    }

    private var moreMenu: some View {
        Menu {
            Button(showsDetails ? "Hide Details" : "Show Details") { showsDetails.toggle() }
            if item.existingEventID != nil { Button("Open in Calendar", action: onOpenExisting) }
            if item.canReview, item.existingEventID == nil || item.kind == .updated || item.kind == .cancelled {
                Button(calendarActionTitle, systemImage: calendarActionSymbol, action: onReview)
            }
            if canRespond { Menu("Reply to Invitation") { responseActions } }
            Divider()
            Button("Dismiss Suggestion", action: onDismiss)
        } label: {
            Label("Event details and actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .ternHover()
        .help("Event details and actions")
        .accessibilityLabel("Details and actions for \(presentation.title)")
    }

    @ViewBuilder private var responseActions: some View {
        Button("Accept") { onRespond(.accepted) }
        Button("Maybe") { onRespond(.tentative) }
        Button("Decline") { onRespond(.declined) }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            Divider()
            Text(presentation.title).font(.callout.weight(.medium)).foregroundStyle(.primary).textSelection(.enabled)
            Label(presentation.badge.text, systemImage: presentation.badge.symbol).foregroundStyle(badgeColor)
            if let location = presentation.location {
                Label(location, systemImage: "mappin.and.ellipse")
                    .textSelection(.enabled)
            }
            if let organizer = presentation.organizer {
                HStack(spacing: Tokens.Space.s2) {
                    AddressAvatar(accountID: accountID, address: item.invitation?.organizer?.email ?? "",
                                  name: item.invitation?.organizer?.name ?? organizer, size: Tokens.Space.s5)
                    Text("Organizer: \(organizer)")
                        .textSelection(.enabled)
                }
            }
            if let original = presentation.originalTimeZoneLine {
                Label(original, systemImage: "globe")
            }
            if let recurrence = presentation.recurrenceNote {
                Label(recurrence, systemImage: "repeat")
            }
            if let answer = presentation.answerLine, answer != presentation.badge.text {
                Label(answer, systemImage: "person.crop.circle")
            }
            ForEach(Array(presentation.responseLines.filter { $0 != presentation.badge.text }.enumerated()), id: \.offset) { _, answer in
                Text(answer).textSelection(.enabled)
            }
            if let organizer = item.invitation?.organizer?.email, canRespond {
                Text("Invitation responses go to \(organizer).")
                    .textSelection(.enabled)
            }
            if item.invitation == nil, !item.evidence.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("In the email").font(.caption.weight(.medium))
                    Text(item.evidence).font(.callout).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Tokens.Space.s3)
                .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
            if item.isOutdated {
                Text("A newer invitation or cancellation is saved in this account.")
            }
            ForEach(Array(item.uncertainties.enumerated()), id: \.offset) { _, uncertainty in
                Label(uncertainty, systemImage: "info.circle")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("calendar-detail-content-\(item.id)")
    }
}
