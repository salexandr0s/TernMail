import AppKit
import MailStore
import QuickLook
import SwiftUI

struct AttachmentLibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorSchemeContrast) private var contrast
    @Bindable var model: AttachmentLibraryModel
    var onOpenSource: () -> Void
    @AppStorage("attachments.viewMode") private var viewMode = "list"
    @State private var showsFilters = false
    @State private var showsCoverage = false
    @FocusState private var searchFocused: Bool

    private var filterCount: Int { AttachmentFilterChip.values(for: model).filter { $0.id != "search" }.count }
    private var hasFilters: Bool { !AttachmentFilterChip.values(for: model).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            resultsToolbar
            if let error = model.errorMessage { errorBanner(error) }
            GeometryReader { geometry in
                if model.items.isEmpty { emptyState }
                else {
                    AttachmentLibraryCollection(model: model, viewMode: viewMode,
                        availableWidth: geometry.size.width, onOpenSource: onOpenSource)
                }
            }
            Divider()
            footer
        }
        .background(Tokens.Surface.canvas)
        .navigationTitle(app.destination == .mail ? "Attachments" : "Calendar")
        .quickLookPreview($model.previewURL)
        .task(id: model.coverageKey) { await model.start() }
        .task(id: model.observationKey) { await model.reload() }
        .toolbar {
            if app.destination == .mail {
                ToolbarItem(placement: .automatic) {
                    Button { searchFocused = true } label: {
                        Label("Find attachment", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Find attachment (⌘F)")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: "paperclip")
                    .font(.title2.weight(.medium)).foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Space.s12, height: Tokens.Space.s12)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Attachments").font(.title.weight(.semibold))
                    Text("Files from your connected mail accounts")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Tokens.Space.s3) {
                searchField
                Button { showsFilters.toggle() } label: {
                    HStack(spacing: Tokens.Space.s2) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text("Filters")
                        if filterCount > 0 {
                            Text(filterCount.formatted()).font(.caption.weight(.semibold))
                                .padding(.horizontal, Tokens.Space.s1_5).padding(.vertical, Tokens.Space.s0_5)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }
                    }
                    .frame(minHeight: Tokens.Space.s6)
                }
                .fixedSize().controlSize(.large)
                .accessibilityLabel(filterCount == 0 ? "Filters" : "Filters, \(filterCount) active")
                .popover(isPresented: $showsFilters, arrowEdge: .bottom) { AttachmentLibraryFilters(model: model) }
            }
            AttachmentCategoryShortcuts(model: model)
            AttachmentActiveFilters(model: model)
        }
        .padding(Tokens.Space.s5)
        .background(Tokens.Surface.primary)
    }

    private var searchField: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "magnifyingglass").foregroundStyle(searchFocused ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            TextField("Search filenames, senders or subjects", text: $model.search)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("Search filenames, senders and email subjects")
                .help("Search filenames, senders and email subjects. Document contents aren't searched.")
                .accessibilityHint("Searches file and email details. Document contents aren't searched.")
            if !model.search.isEmpty {
                Button { model.search = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Tokens.Space.s3)
        .frame(minWidth: Tokens.Layout.searchMinWidth, minHeight: Tokens.Space.s10)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.md)
                .strokeBorder(searchFocused ? Color.accentColor : (contrast == .increased ? .primary : Tokens.Surface.border),
                              lineWidth: searchFocused ? Tokens.Border.focus : Tokens.Border.hairline)
                .allowsHitTesting(false)
        }
    }

    private var resultsToolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s3) { resultsTitle; Spacer(minLength: Tokens.Space.s2); displayControls }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                resultsTitle
                HStack { Spacer(minLength: 0); displayControls }
            }
        }
        .padding(.horizontal, Tokens.Space.s5).padding(.vertical, Tokens.Space.s3)
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

    private var displayControls: some View {
        HStack(spacing: Tokens.Space.s3) {
            Picker("Sort attachments", selection: $model.sort) {
                ForEach(AttachmentLibrarySort.allCases, id: \.self) { sort in Text(sort.title).tag(sort) }
            }
            .labelsHidden().frame(width: Tokens.Layout.sidebarMinWidth)
            .help("Sort attachments")
            Picker("View", selection: $viewMode) {
                Image(systemName: "list.bullet").tag("list").accessibilityLabel("List view")
                Image(systemName: "square.grid.2x2").tag("grid").accessibilityLabel("Card view")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: Tokens.Space.s10 * 2)
            .help("Choose list or card view")
        }
        .fixedSize()
    }

    @ViewBuilder private var emptyState: some View {
        if model.isLoading {
            TernEmptyState(title: "Finding your files", systemImage: "doc.text.magnifyingglass",
                message: "Loading attachments from your mail library.")
        } else if hasFilters {
            VStack(spacing: 0) {
                TernEmptyState(title: "No matching attachments", systemImage: "doc.text.magnifyingglass",
                    message: model.category == nil
                        ? "Try a different filename, sender or filter."
                        : "Try another category or clear your filters. To assign a category, use an attachment's menu.",
                    fillsSpace: false)
                Button("Clear all filters") { model.clearFilters(); searchFocused = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TernEmptyState(title: "Your files, together", systemImage: "paperclip",
                message: "Attachments from your email will appear here, including archived mail. Inline images and email logos are left out.")
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text(error).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again") { Task { await model.retryLastAction() } }.disabled(model.isWorking)
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Dismiss error").accessibilityLabel("Dismiss error")
        }
        .padding(Tokens.Space.s3)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .padding(.horizontal, Tokens.Space.s5).padding(.bottom, Tokens.Space.s3)
    }

    private var footer: some View {
        VStack(spacing: Tokens.Space.s3) {
            if !model.selection.isEmpty {
                AttachmentSelectionActions(model: model, onOpenSource: onOpenSource)
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
    let onOpenSource: () -> Void

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
            if let item = selected {
                Button("Preview", systemImage: "eye") { Task { await model.preview(item) } }.help("Preview (Space)")
                Button("Show Email", systemImage: "envelope") {
                    Task { if await model.openSource(item) { onOpenSource() } }
                }
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
    let onOpenSource: () -> Void

    var body: some View {
        Button("Preview", systemImage: "eye") { Task { await model.preview(item) } }
        Button("Open with Default App", systemImage: "arrow.up.forward.app") { Task { await model.openFile(item) } }
        Button("Save…", systemImage: "arrow.down.to.line") { Task { await model.save(item) } }
        if model.selection.count > 1, model.selection.contains(item.id) {
            Button("Save Selected Files…") { Task { await model.saveSelection() } }
        }
        Divider()
        Button("Show Email", systemImage: "envelope") {
            Task { if await model.openSource(item) { onOpenSource() } }
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
