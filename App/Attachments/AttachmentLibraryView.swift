import AppKit
import MailStore
import QuickLook
import SwiftUI

struct AttachmentLibraryView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: AttachmentLibraryModel
    let viewMode: AttachmentLibraryViewMode
    /// Moves focus to the window's search field, which searches the library.
    var focusSearch: () -> Void = {}
    @State private var showsFilters = false
    @State private var showsCoverage = false

    private var filterCount: Int { AttachmentFilterChip.values(for: model).filter { $0.id != "search" }.count }
    private var hasFilters: Bool { !AttachmentFilterChip.values(for: model).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            resultsTitle
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Tokens.Space.s5).padding(.vertical, Tokens.Space.s3)
            if let error = model.errorMessage { errorBanner(error) }
            GeometryReader { geometry in
                if model.items.isEmpty { emptyState }
                else {
                    AttachmentLibraryCollection(model: model, viewMode: viewMode,
                        availableWidth: geometry.size.width)
                }
            }
            Divider()
            footer
        }
        .background(Tokens.Surface.canvas)
        .navigationTitle(app.destination == .mail ? "Attachments" : "Calendar")
        .quickLookPreview($model.previewURL, in: model.previewURLs)
        .protectAttachmentPreview(model.previewURL)
        .task(id: model.coverageKey) { await model.start() }
        .task(id: model.observationKey) { await model.reload() }
    }

    /// Category shortcuts and the Filters popover. Search, the layout and the
    /// sort order are in the window's toolbar.
    private var filterBar: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s3) {
                AttachmentCategoryShortcuts(model: model)
                Spacer(minLength: 0)
                filtersButton
            }
            AttachmentActiveFilters(model: model)
        }
        .padding(.horizontal, Tokens.Space.s5).padding(.vertical, Tokens.Space.s3)
        .background(Tokens.Surface.primary)
    }

    private var filtersButton: some View {
        Button { showsFilters.toggle() } label: {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: "line.3.horizontal.decrease")
                Text("Filters")
                if filterCount > 0 {
                    Text(filterCount.formatted()).font(.caption.weight(.semibold))
                        .padding(.horizontal, Tokens.Space.s1_5).padding(.vertical, Tokens.Space.s0_5)
                        .background(Color.accentColor.opacity(Tokens.Opacity.tint), in: Capsule())
                }
            }
        }
        .fixedSize()
        .accessibilityLabel(filterCount == 0 ? "Filters" : "Filters, \(filterCount) active")
        .popover(isPresented: $showsFilters, arrowEdge: .bottom) { AttachmentLibraryFilters(model: model) }
    }

    private var resultsTitle: some View {
        HStack(spacing: Tokens.Space.s2) {
            if model.isLoading {
                ProgressView().controlSize(.mini)
                Text("Finding attachments…").foregroundStyle(.secondary)
            } else {
                Text(model.totalCount == 1 ? "1 attachment" : "\(model.totalCount.formatted()) attachments")
                    .fontWeight(.semibold).monospacedDigit()
                if hasFilters { Text("found").foregroundStyle(.secondary) }
            }
        }
        .font(.callout).fixedSize()
    }

    @ViewBuilder private var emptyState: some View {
        if model.isLoading {
            TernEmptyState(title: "Finding Your Files", systemImage: "doc.text.magnifyingglass",
                message: "Loading attachments from your mail library.")
        } else if hasFilters {
            VStack(spacing: 0) {
                TernEmptyState(title: "No Matching Attachments", systemImage: "doc.text.magnifyingglass",
                    message: model.category == nil
                        ? "Try a different filename, sender or filter."
                        : "Try another category or clear your filters. Categories appear as attachments are indexed and read. You can correct a category from an attachment's menu.",
                    fillsSpace: false)
                Button("Clear All Filters") { model.clearFilters(); focusSearch() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TernEmptyState(title: "No Attachments Yet", systemImage: "paperclip",
                message: "Attachments from your email will appear here, including archived mail. Inline images and email logos are left out.")
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.Status.warning).accessibilityHidden(true)
            Text(error).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again") { Task { await model.retryLastAction() } }.disabled(model.isWorking)
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Dismiss error").accessibilityLabel("Dismiss error")
        }
        .padding(Tokens.Space.s3)
        .background(Tokens.Status.warning.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .padding(.horizontal, Tokens.Space.s5).padding(.bottom, Tokens.Space.s3)
    }

    private var footer: some View {
        VStack(spacing: Tokens.Space.s3) {
            if !model.selection.isEmpty {
                AttachmentSelectionActions(model: model)
                Divider()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s3) { pageControls; Spacer(minLength: Tokens.Space.s3); coverageButton }
                VStack(alignment: .leading, spacing: Tokens.Space.s2) { pageControls; coverageButton }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Tokens.Space.s5).padding(.vertical, Tokens.Space.s3)
        .background(Tokens.Surface.primary)
    }

    private var pageControls: some View {
        HStack(spacing: Tokens.Space.s2) {
            if model.isWorking { ProgressView().controlSize(.mini); Text("Preparing files…") }
            else { Text(model.isLoading ? "Loading…" : model.rangeSummary).monospacedDigit() }
            if model.hasPreviousPage || model.hasMore {
                Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.hasPreviousPage || model.isLoading)
                    .help("Previous page").accessibilityLabel("Previous page")
                Button { Task { await model.loadMore() } } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.hasMore || model.isLoading)
                    .help("Next page").accessibilityLabel("Next page")
            }
        }
        .fixedSize()
    }

    private var coverageButton: some View {
        Button { showsCoverage.toggle() } label: {
            Label(model.coverageSummary, systemImage: model.indexingNeedsRetry ? "exclamationmark.circle" : "info.circle")
                .lineLimit(1)
        }
        .buttonStyle(.plain).help("View attachment indexing status")
        .popover(isPresented: $showsCoverage) {
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                Label("Mail history", systemImage: "clock.arrow.circlepath").font(.headline)
                Text(model.coverageDetail).font(.callout)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if model.indexingNeedsRetry {
                    Button("Retry indexing") { Task { await model.retryIndexing() } }
                }
            }
            .padding(Tokens.Space.s4).frame(width: Tokens.Popover.width)
        }
    }
}

struct AttachmentSelectionActions: View {
    let model: AttachmentLibraryModel

    private var selected: AttachmentLibraryItem? {
        model.selection.count == 1 ? model.items.first { model.selection.contains($0.id) } : nil
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s3) { selectionLabel; Spacer(minLength: Tokens.Space.s3); actions }
            VStack(alignment: .leading, spacing: Tokens.Space.s3) { selectionLabel; actions }
        }
    }

    private var selectionLabel: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).accessibilityHidden(true)
            Text("\(model.selection.count) selected").font(.callout.weight(.medium)).monospacedDigit()
            Button { model.selection.removeAll() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Clear selection (Esc)").accessibilityLabel("Clear selection")
        }
        .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: Tokens.Space.s2) {
            if let first = model.items.first(where: { model.selection.contains($0.id) }) {
                Button("Quick Look", systemImage: "eye") { Task { await model.preview(first) } }.help("Quick Look (Space)")
            }
            if let item = selected {
                Button("Open Conversation", systemImage: "macwindow.badge.plus") {
                    Task { await model.openSource(item) }
                }
                .help("Open Conversation in New Window")
            }
            Button(model.selection.count == 1 ? "Save…" : "Save Files…", systemImage: "arrow.down.to.line") {
                Task { await model.saveSelection() }
            }
            .buttonStyle(.borderedProminent)
        }
        .fixedSize().disabled(model.isWorking)
    }
}

struct AttachmentItemMenu: View {
    let item: AttachmentLibraryItem
    let model: AttachmentLibraryModel

    var body: some View {
        // Commands on a file in a multiple selection act on the selection, as in Finder.
        let files = model.selectedItems(with: item)
        let saved = files.compactMap { model.savedFile(for: $0) }
        Button("Open", systemImage: "arrow.up.forward.app") { Task { await model.openFiles(files) } }
        Button("Open With…") { Task { await model.openWith(item) } }
        Button("Quick Look", systemImage: "eye") { Task { await model.preview(item) } }
        Divider()
        Button("Save…", systemImage: "arrow.down.to.line") { Task { await model.save(item) } }
        if files.count > 1 {
            Button("Save Selected Files…") { Task { await model.saveSelection() } }
        }
        if !saved.isEmpty {
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(saved) }
        }
        Button("Copy", systemImage: "doc.on.doc") { Task { await model.copyFile(item) } }
        ShareLink(items: files.map { AttachmentFileItem(attachment: $0.attachment, mailbox: model.mailbox) },
                  preview: { SharePreview($0.attachment.filename) })
        Divider()
        Button("Open Conversation in New Window", systemImage: "macwindow.badge.plus") {
            Task { await model.openSource(item) }
        }
        Menu("Category") {
            ForEach(AttachmentCategory.allCases, id: \.self) { category in
                Button {
                    Task { await model.setCategory(category, for: item) }
                } label: {
                    if category == item.category { Label(category.title, systemImage: "checkmark") }
                    else { Text(category.title) }
                }
            }
        }
        .disabled(model.isWorking)
    }
}
