import MailStore
import QuickLook
import SwiftUI

struct MeetingPreparationView: View {
    @Bindable var model: MeetingPreparationModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.locale) private var locale
    @State private var showsSourcePicker = false
    @State private var previewURL: URL?
    @State private var previewedFileID: String?
    @State private var previewRequest: UUID?
    @State private var fileError: String?

    /// What decides which cards and rows the page shows. The stack animates
    /// when it changes, so new content fades in and the content below it moves
    /// to its new place.
    private struct LayoutKey: Equatable {
        let isLoading: Bool
        let sources: [MeetingPreparationSourceRow]
        let sections: [String]
        let pending: [ThreadKey]
        let hasTrackedWork: Bool
        let hasFiles: Bool
    }

    var body: some View {
        // Read once per update: the cards and the animation key share them.
        let sections = model.sections, pending = model.pendingSummaries
        let trackedWork = model.trackedWork, recentFiles = model.recentFiles
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    status
                    sourceSelection
                    ForEach(sections) { section in
                        MeetingPreparationThreadSection(section: section,
                            accountName: model.followUps.accountName(for: section.candidate.thread.accountID),
                            canTrack: !model.isLoading && !model.isStale,
                            openSource: model.openSource, track: model.trackSuggestion)
                            .ternTransition(.fade)
                    }
                    ForEach(pending, id: \.thread) { candidate in
                        MeetingPreparationPendingSection(candidate: candidate,
                            accountName: model.followUps.accountName(for: candidate.thread.accountID))
                            .ternTransition(.fade)
                    }
                    if !trackedWork.isEmpty {
                        MeetingPreparationCard(title: "Tracked work", symbol: "checklist") {
                            Text("Your saved descriptions and status take precedence over generated suggestions.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(trackedWork) { entry in
                                MeetingPreparationTrackedRow(entry: entry,
                                    accountName: model.followUps.accountName(for: entry.record.accountID),
                                    open: { model.followUps.openSource(entry) })
                                if entry.id != trackedWork.last?.id { Divider() }
                            }
                        }
                        .accessibilityIdentifier("meeting-tracked-work")
                        .ternTransition(.fade)
                    }
                    if !recentFiles.isEmpty { files(recentFiles).ternTransition(.fade) }
                }
                .ternAnimation(value: LayoutKey(isLoading: model.isLoading, sources: model.sources,
                    sections: sections.map(\.id), pending: pending.map(\.thread),
                    hasTrackedWork: !trackedWork.isEmpty, hasFiles: !recentFiles.isEmpty))
                .frame(maxWidth: Tokens.Layout.readableWidth)
                .padding(Tokens.Space.s5)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(minWidth: Tokens.Layout.conversationMinWidth, minHeight: Tokens.Layout.conversationMinHeight)
        .background(Tokens.Surface.muted)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-preparation")
        .task(id: model.id) { await model.start() }
        .onDisappear { model.stop(); clearPreview() }
        .onChange(of: recentFiles.map(\.id)) { _, ids in
            if let previewedFileID, !ids.contains(previewedFileID) { clearPreview() }
        }
        .sheet(isPresented: $showsSourcePicker) { MeetingPreparationSourcePicker(model: model) }
        .quickLookPreview($previewURL)
        .protectAttachmentPreview(previewURL)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                Label("Meeting preparation", systemImage: "person.2.wave.2").font(.headline).foregroundStyle(.secondary)
                Text(model.event.title).font(.title2.weight(.semibold)).lineLimit(3).textSelection(.enabled)
                Text(eventDate).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let location = model.event.event.location, !location.isEmpty {
                    Label(location, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.isLoading {
                Button("Cancel", systemImage: "xmark.circle", action: model.cancel)
                    .accessibilityIdentifier("meeting-cancel")
            } else {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .disabled(model.occurrence == nil)
                    .accessibilityIdentifier("meeting-refresh")
            }
        }
        .padding(Tokens.Space.s5)
        .background(Tokens.Surface.primary)
    }

    private var eventDate: String {
        var calendar = Calendar.autoupdatingCurrent
        calendar.locale = locale
        calendar.timeZone = TimeZone(identifier: model.event.fallbackTimeZoneID) ?? .autoupdatingCurrent
        let dates = CalendarEventDateDescription.text(start: model.event.start, end: model.event.end,
            isAllDay: model.event.isAllDay, calendar: calendar)
        return model.event.isAllDay ? "\(dates) · All day" : "\(dates) · \(calendar.timeZone.abbreviation(for: model.event.start) ?? calendar.timeZone.identifier)"
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                if model.isLoading {
                    ProgressView().controlSize(.small).accessibilityLabel("Preparing meeting")
                        .ternTransition(.fade)
                }
                if model.statusMessage != model.errorMessage {
                    Text(model.statusMessage).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(model.coverageMessage).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.omittedSourceCount > 0 {
                Label("\(model.omittedSourceCount) conversations are outside this preparation’s limits. Narrow the included sources and refresh to review others.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(model.partialNotes.enumerated()), id: \.offset) { _, note in
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isStale {
                Label("The event or supporting mail has changed. Refresh to update this preparation.", systemImage: "arrow.clockwise.circle")
                    .font(.callout).foregroundStyle(Tokens.Status.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meeting-stale")
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(Tokens.Status.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("meeting-error")
            }
            if model.state == .permissionDisabled || model.state == .providerUnavailable {
                FlowLayout(spacing: Tokens.Space.s3) {
                    Button("Assistant Settings…", systemImage: "gearshape") {
                        SettingsNavigationRequests.shared.request(.assistant)
                        openSettings()
                    }
                    .accessibilityIdentifier("meeting-settings")
                    if model.state == .permissionDisabled {
                        Button("Calendar Access…", systemImage: "calendar") {
                            SettingsNavigationRequests.shared.request(.calendar)
                            openSettings()
                        }
                        .accessibilityIdentifier("meeting-calendar-settings")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting-status")
    }

    private var sourceSelection: some View {
        MeetingPreparationCard(title: "Included conversations", symbol: "envelope") {
            HStack(alignment: .top, spacing: Tokens.Space.s2) {
                Text("Choose the conversations that belong to this occurrence.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Include Conversation…", systemImage: "plus") { showsSourcePicker = true }
                    .disabled(model.occurrence == nil)
                    .accessibilityIdentifier("meeting-include-conversation")
            }
            let included = model.sources.filter { !$0.isExcluded }
            if included.isEmpty {
                Text(model.isLoading ? "Finding related conversations…" : "No conversations included. Add one or restore an excluded conversation.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .ternTransition(.fade)
            }
            ForEach(included) { source in
                MeetingPreparationSourceRowView(source: source,
                    accountName: model.followUps.accountName(for: source.key.accountID),
                    actionTitle: "Exclude", actionSymbol: "minus.circle",
                    open: { model.openConversation(source.key) },
                    act: { Task { await model.exclude(source.key) } })
                    .ternTransition(.fade)
            }
            let excluded = model.sources.filter(\.isExcluded)
            if !excluded.isEmpty {
                DisclosureGroup("Excluded conversations (\(excluded.count))") {
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        ForEach(excluded) { source in
                            MeetingPreparationSourceRowView(source: source,
                                accountName: model.followUps.accountName(for: source.key.accountID),
                                actionTitle: "Restore", actionSymbol: "arrow.uturn.backward",
                                open: { model.openConversation(source.key) },
                                act: { Task { await model.restore(source.key) } })
                        }
                    }
                    .padding(.top, Tokens.Space.s2)
                }
                .accessibilityIdentifier("meeting-excluded-sources")
                .ternTransition(.fade)
            }
        }
        .accessibilityIdentifier("meeting-sources")
    }

    private func files(_ recentFiles: [MeetingPreparationAttachment]) -> some View {
        MeetingPreparationCard(title: "Recent files", symbol: "paperclip") {
            Text("Files from included conversations, newest first.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(recentFiles) { file in
                HStack(alignment: .top, spacing: Tokens.Space.s3) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                        Button { preview(file) } label: {
                            Label(file.filename, systemImage: "doc").font(.callout.weight(.medium))
                                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(previewRequest != nil && previewedFileID == file.id)
                        .accessibilityLabel("Preview \(file.filename)")
                        .accessibilityIdentifier("meeting-file-\(file.id)")
                        Text("\(file.sender) · \(file.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if previewRequest != nil && previewedFileID == file.id { ProgressView().controlSize(.small) }
                    Button("Open Email", systemImage: "envelope") { model.openSource(file.source) }
                        .controlSize(.small).accessibilityIdentifier("meeting-file-source-\(file.id)")
                }
                .accessibilityElement(children: .contain)
                if file.id != recentFiles.last?.id { Divider() }
            }
            if let fileError {
                Label(fileError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Tokens.Status.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("meeting-files")
    }

    private func preview(_ file: MeetingPreparationAttachment) {
        let request = UUID()
        previewRequest = request; previewedFileID = file.id; fileError = nil
        Task {
            let url = await model.previewAttachment(file)
            guard previewRequest == request, model.recentFiles.contains(where: { $0.id == file.id }) else { return }
            previewRequest = nil
            if let url { previewURL = url }
            else { fileError = "Couldn’t preview this file. Open its source email to try again." }
        }
    }

    private func clearPreview() {
        previewRequest = nil; previewedFileID = nil; previewURL = nil; fileError = nil
    }
}
