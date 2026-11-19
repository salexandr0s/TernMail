import AppKit
import MailStore
import QuickLook
import SwiftUI
import SyncEngine

struct AttachmentLibraryView: View {
    @Bindable var model: AttachmentLibraryModel
    let viewMode: AttachmentLibraryViewMode
    /// False while the library is mounted behind Mail. It then stops observing
    /// the cache, closes its popovers and gives up the keyboard.
    var isActive = true
    /// Moves focus to the window's search field, which searches the library.
    var focusSearch: () -> Void = {}
    @State private var showsFilters = false
    @State private var showsCoverage = false
    @State private var pane = PaneSize()
    /// Moves the keyboard between the files and Mail as the library comes to
    /// front and goes behind.
    @State private var keyboard = SectionKeyboard()

    /// The library's height, which caps the Filters popover. Only the popover reads it,
    /// and only when it opens, so it is kept outside the view's state: resizing the
    /// window then does not run `body` again for every new height.
    @MainActor private final class PaneSize { var height: CGFloat? }

    /// The page for the current query hasn't arrived. This also covers the
    /// update before the load starts, when `isLoading` is still false.
    private var isAwaitingPage: Bool {
        model.isLoading || (!model.isPageReady && model.errorMessage == nil)
    }

    var body: some View {
        // The chips are built once per update. The filter bar, the empty state and
        // the footer all read them, and the footer makes every selection change an update.
        let chips = AttachmentFilterChip.values(for: model)
        let hasFilters = !chips.isEmpty
        // An empty library shows the first pass's progress in place of the list,
        // and the status bar leaves out its count until results arrive.
        let showsIndexProgress = model.items.isEmpty && !isAwaitingPage && !hasFilters && model.isBuildingIndex
        VStack(spacing: 0) {
            filterBar(chips)
            Divider()
            VStack(spacing: 0) {
                if let error = model.errorMessage {
                    errorBanner(error)
                        .ternTransition(.disclosure)
                }
                GeometryReader { geometry in
                    Group {
                        if model.presentedItems.isEmpty {
                            emptyState(hasFilters: hasFilters, showsIndexProgress: showsIndexProgress)
                                .ternTransition(.fade)
                        } else {
                            // Rows from the previous query stay up while the next page loads.
                            // They ignore clicks until then, because commands act on `items`.
                            AttachmentLibraryCollection(model: model, viewMode: viewMode,
                                availableWidth: geometry.size.width, keyboard: keyboard)
                                .allowsHitTesting(!model.isPresentingEarlierPage)
                                .ternTransition(.fade)
                        }
                    }
                    .ternAnimation(value: model.presentedItems.isEmpty, duration: Tokens.Motion.fast)
                }
            }
            // Only the banner and the list it pushes down animate with the error.
            .ternAnimation(value: model.errorMessage != nil)
            Divider()
            footer(showsIndexProgress: showsIndexProgress)
        }
        .background(Tokens.Surface.canvas)
        .sectionKeyboard(keyboard, isInFront: isActive)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pane.height = $0 }
        .quickLookPreview($model.previewURL, in: model.previewURLs)
        .protectAttachmentPreview(model.previewURL)
        .task(id: isActive ? model.coverageKey : nil) { if isActive { await model.start() } }
        .task(id: isActive ? model.observationKey : nil) { if isActive { await model.reload() } }
        .onChange(of: isActive) { _, active in
            if !active { showsFilters = false; showsCoverage = false }
        }
    }

    /// Category shortcuts and the Filters popover. Search, the layout and the
    /// sort order are in the window's toolbar.
    private func filterBar(_ chips: [AttachmentFilterChip]) -> some View {
        // Search and category already have visible, editable controls above.
        let listed = chips.filter { $0.id != "search" && $0.id != "category" }
        return VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(spacing: Tokens.Space.s3) {
                AttachmentCategoryShortcuts(model: model)
                Spacer(minLength: 0)
                filtersButton(filterCount: chips.count(where: { $0.id != "search" }))
            }
            AttachmentActiveFilters(model: model, chips: listed)
        }
        .padding(.horizontal, Tokens.Space.s5).padding(.vertical, Tokens.Space.s3)
        .background(Tokens.Surface.primary)
        .ternAnimation(value: listed.map(\.id))
    }

    private func filtersButton(filterCount: Int) -> some View {
        Button { showsFilters.toggle() } label: {
            HStack(spacing: Tokens.Space.s2) {
                Image(systemName: "line.3.horizontal.decrease")
                Text("Filters")
                if filterCount > 0 {
                    Text(filterCount.formatted()).font(.caption.weight(.semibold))
                        .padding(.horizontal, Tokens.Space.s1_5).padding(.vertical, Tokens.Space.s0_5)
                        .background(Color.accentColor.opacity(Tokens.Opacity.tint), in: Capsule())
                        .ternTransition(.fade)
                }
            }
            .ternAnimation(value: filterCount > 0, duration: Tokens.Motion.fast)
        }
        .fixedSize()
        .accessibilityLabel(filterCount == 0 ? "Filters" : "Filters, \(filterCount) active")
        // No taller than the library, so in a short window the form scrolls.
        .popover(isPresented: $showsFilters, arrowEdge: .bottom) {
            AttachmentLibraryFilters(model: model, maxHeight: pane.height)
        }
    }

    @ViewBuilder private func emptyState(hasFilters: Bool, showsIndexProgress: Bool) -> some View {
        if isAwaitingPage {
            TernEmptyState(title: "Finding Your Files", systemImage: "doc.text.magnifyingglass",
                message: "Loading attachments from your mail library.")
                .ternDelayedLoading()
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
        } else if showsIndexProgress {
            ProgressView {
                Text(model.coverageSummary)
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
        .padding(.horizontal, Tokens.Space.s5).padding(.vertical, Tokens.Space.s3)
    }

    private func footer(showsIndexProgress: Bool) -> some View {
        let controls = pageControls(showsIndexProgress: showsIndexProgress)
        return VStack(spacing: Tokens.Space.s3) {
            if !model.selection.isEmpty {
                VStack(spacing: Tokens.Space.s3) {
                    AttachmentSelectionActions(model: model)
                    Divider()
                }
                .ternTransition(.disclosure)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s3) { controls; Spacer(minLength: Tokens.Space.s3); coverageButton }
                VStack(alignment: .leading, spacing: Tokens.Space.s2) { controls; coverageButton }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .ternAnimation(value: model.selection.isEmpty)
        .padding(.horizontal, Tokens.Space.s5).padding(.vertical, Tokens.Space.s3)
        .background(Tokens.Surface.primary)
    }

    private func pageControls(showsIndexProgress: Bool) -> some View {
        // Rows of the earlier page stay up while the next one loads. Their count and
        // page buttons stay with them, and a spinner shows that the list is changing.
        let isUpdating = isAwaitingPage && model.isPresentingEarlierPage
        return HStack(spacing: Tokens.Space.s2) {
            if model.isWorking { ProgressView().controlSize(.mini); Text("Preparing files…") }
            else if !showsIndexProgress {
                Text(isAwaitingPage && !isUpdating ? "Loading…" : model.rangeSummary).monospacedDigit()
            }
            if model.hasPreviousPage || model.isPresentingPartialPage {
                Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.hasPreviousPage || model.isLoading)
                    .help("Previous page").accessibilityLabel("Previous page")
                Button { Task { await model.loadMore() } } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.hasMore || model.isLoading)
                    .help("Next page").accessibilityLabel("Next page")
            }
            ProgressView().controlSize(.mini)
                .accessibilityLabel("Updating the list")
                .ternDelayedLoading(isUpdating && !model.isWorking)
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
                    Button("Retry Indexing") { Task { await model.retryIndexing() } }
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
        Group {
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
            Button("Copy", systemImage: "doc.on.doc") { Task { await model.copyFiles(files) } }
            ShareLink(items: files.map { AttachmentFileItem(attachment: $0.attachment, mailbox: model.mailbox) },
                      preview: { SharePreview(SyncEngine.safeFilename($0.attachment.filename)) })
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
        }
        .disabled(model.isWorking)
    }
}
