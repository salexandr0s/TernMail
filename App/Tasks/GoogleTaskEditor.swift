import AppKit
import GmailAPI
import SwiftUI

struct GoogleTaskEditorContext: Identifiable {
    let id = UUID()
    let task: GoogleTask?
    let location: GoogleTaskLocation
    let listTitle: String
}

struct GoogleTaskEditor: View {
    @State private var session: GoogleTaskEditingSession
    private var onFinish: (() -> Void)?
    private var context: GoogleTaskEditorContext { session.context }
    private var isInline: Bool { onFinish != nil }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    private enum Field { case title, notes }
    @FocusState private var focusedField: Field?

    init(model: GoogleTasksModel, context: GoogleTaskEditorContext) {
        _session = State(initialValue: GoogleTaskEditingSession(model: model, context: context))
    }

    init(session: GoogleTaskEditingSession, onFinish: @escaping () -> Void) {
        _session = State(initialValue: session)
        self.onFinish = onFinish
    }

    var body: some View {
        Group {
            if isInline { inlineEditor }
            else { modalEditor }
        }
        .task(id: context.id) { focusedField = .title }
    }

    private var inlineEditor: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            Label("Editing task", systemImage: "pencil")
                .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            TextField("What needs to be done?", text: $session.title)
                .font(.title3.weight(.semibold)).textFieldStyle(.plain)
                .focused($focusedField, equals: .title)
                .onSubmit(submit)
                .accessibilityLabel("Task title")
                .accessibilityIdentifier("google-task-title")
                .disabled(session.isSaving)
            TextField("Add details", text: $session.notes, axis: .vertical)
                .font(.body).textFieldStyle(.plain).lineLimit(1...4)
                .focused($focusedField, equals: .notes)
                .disabled(session.isSaving)
                .accessibilityLabel("Task notes")
                .accessibilityIdentifier("google-task-notes")
            dueFields.font(.callout).controlSize(.small)
            if let url = GoogleTaskRow.emailURL(context.task?.notes ?? "") {
                Button { openURL(url) } label: {
                    Label(GoogleTaskRow.emailSubject(context.task?.notes ?? "") ?? "Source email", systemImage: "envelope")
                        .font(.callout).lineLimit(2)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(session.isSaving)
            }
            errorMessage
            Divider()
            HStack(spacing: Tokens.Space.s2) {
                if session.isSaving { ProgressView().controlSize(.small).accessibilityLabel("Saving task") }
                Spacer(minLength: 0)
                Button("Cancel", action: finish)
                    .disabled(session.isSaving)
                    .help("Cancel editing (Escape)")
                    .accessibilityLabel("Cancel editing")
                    .accessibilityIdentifier("google-task-inline-cancel")
                Button("Save Task", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canSave)
                    .help("Save task (Return)")
                    .accessibilityIdentifier("google-task-inline-save")
            }
        }
        .padding(Tokens.Space.s3)
        .background(Color.accentColor.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md, focus: .accentColor)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("google-task-inline-editor")
        .onKeyPress(.escape) {
            guard !session.isSaving, !hasMarkedText else { return .ignored }
            finish()
            return .handled
        }
        .onKeyPress(keys: [.return]) { press in
            guard press.modifiers == .command, !hasMarkedText else { return .ignored }
            submit()
            return .handled
        }
    }

    private var modalEditor: some View {
        ScrollViewReader { scroll in
            SettingsEditorSheet(title: context.task == nil ? "New Task" : "Task Details",
                                width: Tokens.Settings.editorWideWidth, messages: modalMessages) {
                VStack(alignment: .leading, spacing: Tokens.Space.s4) {
                    Label(context.listTitle, systemImage: "list.bullet")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(2).help(context.listTitle)
                    VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                        VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                            Text("Title").font(.callout.bold()).foregroundStyle(.secondary)
                            TextField("What needs to be done?", text: $session.title, axis: .vertical)
                                .font(.title2.weight(.semibold)).textFieldStyle(.plain)
                                .lineLimit(2...4).focused($focusedField, equals: .title)
                                .accessibilityLabel("Task title")
                                .accessibilityIdentifier("google-task-title")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                            Text("Notes").font(.callout.bold()).foregroundStyle(.secondary)
                            TextField("Add details", text: $session.notes, axis: .vertical)
                                .textFieldStyle(.plain).lineLimit(3...8)
                                .focused($focusedField, equals: .notes)
                                .accessibilityLabel("Task notes")
                                .accessibilityIdentifier("google-task-notes")
                        }
                    }
                    .padding(Tokens.Space.s4)
                    .ternSurface(style: .grouped)
                    .ternOutline(radius: Tokens.Radius.lg, style: .contrastOnly, focus: focusedField == nil ? nil : .accentColor)
                    .disabled(session.isSaving)
                    dueFields
                        .padding(Tokens.Space.s3)
                        .ternSurface(style: .grouped)
                    if let url = GoogleTaskRow.emailURL(context.task?.notes ?? "") {
                        Button { openURL(url) } label: {
                            HStack(spacing: Tokens.Space.s2) {
                                Image(systemName: "envelope").foregroundStyle(Color.accentColor)
                                    .frame(width: Tokens.Space.s6)
                                VStack(alignment: .leading, spacing: Tokens.Space.s0_5) {
                                    Text("Source email").font(.caption).foregroundStyle(.secondary)
                                    Text(GoogleTaskRow.emailSubject(context.task?.notes ?? "") ?? "Open source email")
                                        .font(.body).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(Tokens.Space.s3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .ternSurface(style: .grouped)
                        .ternHover(radius: Tokens.Radius.lg)
                        .accessibilityLabel("Open source email")
                    }
                    errorMessage
                }
            } actions: {
                if session.isSaving { ProgressView().controlSize(.small).accessibilityLabel("Saving task") }
                if session.needsConflictReview {
                    Button("Review Changes") { scroll.scrollTo("google-task-conflict-review", anchor: .top) }
                        .accessibilityIdentifier("google-task-review-changes")
                }
                Button("Cancel", action: finish).keyboardShortcut(.cancelAction).disabled(session.isSaving)
                Button(context.task == nil ? "Add Task" : "Save Task", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canSave)
            }
            .interactiveDismissDisabled(session.isSaving)
        }
    }

    private var modalMessages: [String] {
        if let error = session.error { return [error] }
        if session.needsConflictReview { return ["Review the latest Google Tasks version before saving."] }
        return []
    }

    private var dueFields: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Tokens.Space.s3) {
                dueToggle
                Spacer(minLength: 0)
                dueDatePicker
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                dueToggle
                dueDatePicker
            }
        }
        .disabled(session.isSaving)
    }

    private var dueToggle: some View {
        Toggle("Due date", isOn: $session.hasDueDate).toggleStyle(.checkbox).fixedSize()
    }

    @ViewBuilder private var dueDatePicker: some View {
        if session.hasDueDate {
            DatePicker("Due", selection: $session.dueDate, displayedComponents: .date)
                .datePickerStyle(.field).labelsHidden().fixedSize()
                .accessibilityLabel("Task due date")
        }
    }

    @ViewBuilder private var errorMessage: some View {
        if session.needsConflictReview {
            GoogleTaskConflictReview(session: session)
                .id("google-task-conflict-review")
        }
        if let error = session.error, isInline {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.callout).foregroundStyle(Tokens.Status.error)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("google-task-editor-error")
        }
    }

    private var hasMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    private func submit() {
        guard session.canSave else { return }
        Task { if await session.save() { finish() } }
    }

    private func finish() {
        if let onFinish { onFinish() }
        else { dismiss() }
    }
}
