import AppKit
import MailStore
import QuickLook
import SwiftUI

struct AttachmentLibraryView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: AttachmentLibraryModel
    var onOpenSource: () -> Void
    @AppStorage("attachments.viewMode") private var viewMode = "list"
    @State private var showsFilters = false
    @State private var showsCoverage = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.errorMessage {
                errorBanner(error)
            }
            GeometryReader { geometry in
                if model.items.isEmpty {
                    emptyState
                } else {
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
                    Button {
                        searchFocused = true
                    } label: {
                        Label("Find attachment", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    .help("Find attachment (⌘F)")
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(alignment: .center, spacing: Tokens.Space.s3) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Attachments").font(.title2.weight(.semibold))
                    Text("Files from your connected mail accounts")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: Tokens.Space.s2)
                Picker("View", selection: $viewMode) {
                    Image(systemName: "list.bullet").tag("list").accessibilityLabel("List view")
                    Image(systemName: "square.grid.2x2").tag("grid").accessibilityLabel("Card view")
                }
                .pickerStyle(.segmented).frame(width: Tokens.Space.s16 * 2)
                .help("Choose list or card view")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s2) { searchField; filterAndSort }
                VStack(alignment: .leading, spacing: Tokens.Space.s2) { searchField; filterAndSort }
            }
            Text("Search filenames, senders and email subjects. Document contents aren't searched.")
                .font(.caption).foregroundStyle(.secondary)
            AttachmentActiveFilters(model: model)
        }
        .padding(Tokens.Space.s5)
        .background(Tokens.Surface.primary)
    }

    private var searchField: some View {
        HStack(spacing: Tokens.Space.s2) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Search attachments", text: $model.search)
                .textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("Search filenames, senders and email subjects")
            if !model.search.isEmpty {
                Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .padding(Tokens.Space.s2)
        .frame(minWidth: Tokens.Layout.searchMinWidth)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .overlay { RoundedRectangle(cornerRadius: Tokens.Radius.sm).strokeBorder(Tokens.Surface.border, lineWidth: Tokens.Border.hairline) }
    }

    private var filterAndSort: some View {
        HStack(spacing: Tokens.Space.s2) {
            Button { showsFilters.toggle() } label: {
                Label("Filters", systemImage: AttachmentFilterChip.values(for: model).isEmpty
                      ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
            .popover(isPresented: $showsFilters, arrowEdge: .bottom) { AttachmentLibraryFilters(model: model) }
            Picker("Sort", selection: $model.sort) {
                ForEach(AttachmentLibrarySort.allCases, id: \.self) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .labelsHidden().frame(width: Tokens.Layout.searchMinWidth)
            .help("Sort attachments")
        }
        .fixedSize()
    }

    @ViewBuilder private var emptyState: some View {
        if model.isLoading {
            VStack(spacing: Tokens.Space.s3) {
                ProgressView().controlSize(.small)
                Text("Loading attachments…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !AttachmentFilterChip.values(for: model).isEmpty {
            VStack(spacing: Tokens.Space.s3) {
                TernEmptyState(title: "No matching attachments", systemImage: "doc.text.magnifyingglass",
                    message: "Try another sender, filename or filter. Results may grow while older mail is being indexed.", fillsSpace: false)
                Button("Clear all filters") { model.clearFilters() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TernEmptyState(title: "Your attachments will appear here", systemImage: "paperclip",
                message: "Tern looks for files across your mail history. Inline images and email logos are left out.")
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again") { Task { await model.retryLastAction() } }
                .disabled(model.isWorking)
            Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Dismiss error").accessibilityLabel("Dismiss error")
        }
        .padding(Tokens.Space.s3)
        .background(Color.orange.opacity(0.1))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            if !model.selection.isEmpty {
                AttachmentSelectionActions(model: model, onOpenSource: onOpenSource)
                Divider()
            }
            HStack(spacing: Tokens.Space.s2) {
                if model.isLoading || model.isWorking { ProgressView().controlSize(.mini) }
                Text(model.rangeSummary).monospacedDigit()
                if model.hasPreviousPage || model.hasMore {
                    Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                        .disabled(!model.hasPreviousPage || model.isLoading)
                        .help("Previous page").accessibilityLabel("Previous page")
                    Button { Task { await model.loadMore() } } label: { Image(systemName: "chevron.right") }
                        .disabled(!model.hasMore || model.isLoading)
                        .help("Next page").accessibilityLabel("Next page")
                }
                Spacer(minLength: Tokens.Space.s2)
                Button { showsCoverage.toggle() } label: {
                    Label(model.coverageSummary, systemImage: model.indexingNeedsRetry ? "exclamationmark.circle" : "info.circle")
                        .lineLimit(1)
                }
                .buttonStyle(.link)
                .popover(isPresented: $showsCoverage) {
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        Text("Indexing coverage").font(.headline)
                        Text(model.coverageDetail).font(.callout)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if model.indexingNeedsRetry {
                            Button("Retry indexing") { Task { await model.retryIndexing() } }
                        }
                    }
                    .padding(Tokens.Space.s4).frame(width: Tokens.Popover.width)
                }
                if model.indexingNeedsRetry {
                    Button("Retry") { Task { await model.retryIndexing() } }.buttonStyle(.link)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Tokens.Space.s4).padding(.vertical, Tokens.Space.s3)
        .background(Tokens.Surface.primary)
    }
}

struct AttachmentSelectionActions: View {
    let model: AttachmentLibraryModel
    let onOpenSource: () -> Void

    private var selected: AttachmentLibraryItem? {
        model.selection.count == 1 ? model.items.first { model.selection.contains($0.id) } : nil
    }

    var body: some View {
        HStack(spacing: Tokens.Space.s3) {
            Text("\(model.selection.count) selected").font(.caption).monospacedDigit()
            Spacer(minLength: Tokens.Space.s2)
            if let item = selected {
                Button("Preview", systemImage: "eye") { Task { await model.preview(item) } }
                    .help("Preview (Space)")
                Button("Show Email", systemImage: "envelope") {
                    Task { if await model.openSource(item) { onOpenSource() } }
                }
            }
            Button("Save…", systemImage: "arrow.down.to.line") { Task { await model.saveSelection() } }
        }
        .disabled(model.isWorking)
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
