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
    var tasks: GoogleTasksModel? = nil
    var taskRequest: (EmailCalendarItem) -> TaskCreationRequest? = { _ in nil }
    var onAddTask: (TaskCreationRequest) -> Void = { _ in }
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
                        Divider().padding(.horizontal, Tokens.Space.s3)
                    }
                    EmailCalendarSuggestionRow(
                        item: item, calendar: calendar, accountID: accountID,
                        canRespond: !item.isOutdated && item.kind != .cancelled
                            && item.invitation?.method == .request && model.attendee(for: item) != nil,
                        onReview: { onReview(item) }, onOpenExisting: { onOpenExisting(item) },
                        onRespond: { onRespond(item, $0) }, onDismiss: {
                            model.dismiss(item.id)
                            onDismiss(item.id)
                        }, tasks: tasks, taskRequest: taskRequest(item), onAddTask: onAddTask)
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
                            Image(systemName: showsAll ? "chevron.up" : "chevron.down")
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
                    .accessibilityValue(showsAll ? "Expanded" : "Collapsed")
                }
                if let error = model.interpretationError {
                    Text("Some events could not be checked. \(error)")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
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
    let tasks: GoogleTasksModel?
    let taskRequest: TaskCreationRequest?
    let onAddTask: (TaskCreationRequest) -> Void
    @State private var showsDetails = false

    private var presentation: EmailCalendarPresentation { .init(item: item, calendar: calendar) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Tokens.Space.s3) {
                    dateTile
                    summary.frame(minWidth: Tokens.Space.s16 * 2)
                    HStack(spacing: Tokens.Space.s1) {
                        eventActions
                        moreMenu
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    HStack(alignment: .center, spacing: Tokens.Space.s3) {
                        dateTile
                        summary
                        moreMenu.controlSize(.small).fixedSize()
                    }
                    eventActions
                        .controlSize(.small)
                        .fixedSize()
                        .padding(.leading, Tokens.ConversationHeader.dateTile + Tokens.Space.s3)
                }
            }
            if showsDetails { details }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.badge.text)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
            Text(presentation.title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .help(presentation.title)
                .textSelection(.enabled)
            Text(presentation.dateLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning = item.authenticityWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dateTile: some View {
        Button { showsDetails.toggle() } label: {
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(presentation.badge.text)
        .accessibilityLabel("\(showsDetails ? "Hide" : "Show") event details: \(presentation.badge.text)")
        .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
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
        VStack(spacing: 0) {
            if let month = presentation.month, let day = presentation.day {
                Text(month)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.isOutdated || item.kind == .cancelled ? Color.secondary : .accentColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: Tokens.Space.s3)
                    .background(Color.accentColor.opacity(Tokens.Calendar.eventTint))
                Text(day)
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(item.isOutdated ? .secondary : .primary)
                    .frame(height: Tokens.Space.s5)
            } else {
                Image(systemName: "calendar")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(height: Tokens.ConversationHeader.dateTile)
            }
        }
        .frame(width: Tokens.ConversationHeader.dateTile, height: Tokens.ConversationHeader.dateTile)
        .background(Tokens.Surface.muted)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                .strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline)
        }
        .accessibilityHidden(true)
    }

    private var eventActions: some View {
        HStack(spacing: Tokens.Space.s1) {
            primaryAction
            if let tasks, let taskRequest {
                EmailTaskAddButton(request: taskRequest, model: tasks, onAdd: onAddTask)
                    .accessibilityIdentifier("calendar-task-add-\(item.id)")
            }
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if item.canReview && (item.kind == .updated || item.kind == .cancelled) {
            reviewButton
        } else if canRespond {
            Menu("Respond") { responseActions }
                .menuStyle(.borderedButton)
                .help("Reply to this invitation")
        } else if item.existingEventID != nil {
            Button("Open", action: onOpenExisting)
                .help("Open this event in Calendar")
        } else if item.canReview {
            reviewButton
        }
    }

    private var reviewButton: some View {
        Button("Review", action: onReview)
            .help(reviewTitle)
            .accessibilityLabel("\(reviewTitle): \(presentation.title)")
            .accessibilityIdentifier("calendar-review-\(item.id)")
    }

    private var reviewTitle: String {
        if item.kind == .cancelled { return "Review Cancellation" }
        if item.kind == .updated, item.existingEventID != nil { return "Review Update" }
        return item.invitation == nil ? "Review Event" : "Add Personal Copy"
    }

    private var moreMenu: some View {
        Menu {
            Button(showsDetails ? "Hide Details" : "Show Details") { showsDetails.toggle() }
            if item.existingEventID != nil { Button("Open in Calendar", action: onOpenExisting) }
            if item.canReview, item.existingEventID == nil || item.kind == .updated || item.kind == .cancelled {
                Button(reviewTitle, action: onReview)
            }
            if canRespond { Menu("Reply to Invitation") { responseActions } }
            Divider()
            Button("Dismiss Suggestion", action: onDismiss)
        } label: {
            Label("Event details and actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
            Text(presentation.title).foregroundStyle(.primary).textSelection(.enabled)
            Label(presentation.badge.text, systemImage: presentation.badge.symbol)
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
                    Text(item.evidence).textSelection(.enabled)
                }
            }
            if item.isOutdated {
                Text("A newer invitation or cancellation is saved in this account.")
            }
            ForEach(Array(item.uncertainties.enumerated()), id: \.offset) { _, uncertainty in
                Label(uncertainty, systemImage: "info.circle")
            }
            Button("Hide Details") { showsDetails = false }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
