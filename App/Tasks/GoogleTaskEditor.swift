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
        VStack(alignment: .leading, spacing: Tokens.Space.s2) {
            HStack(alignment: .top, spacing: Tokens.Space.s1_5) {
                TextField("What needs to be done?", text: $session.title)
                    .font(.body.weight(.medium)).textFieldStyle(.plain)
                    .focused($focusedField, equals: .title)
                    .onSubmit(submit)
                    .accessibilityLabel("Task title")
                    .accessibilityIdentifier("google-task-title")
                    .padding(.vertical, Tokens.Space.s1_5)
                    .disabled(session.isSaving)
                HStack(spacing: Tokens.Space.s0_5) {
                    Button(action: submit) {
                        Group {
                            if session.isSaving { ProgressView().controlSize(.small) }
                            else { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .frame(width: Tokens.Space.s6, height: Tokens.Control.iconButton)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!session.canSave)
                    .help("Save task (Return)").accessibilityLabel("Save task")
                    .accessibilityIdentifier("google-task-inline-save")
                    .ternHover(isEnabled: session.canSave)
                    Button(action: finish) {
                        Image(systemName: "xmark")
                            .frame(width: Tokens.Space.s6, height: Tokens.Control.iconButton)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(session.isSaving)
                    .help("Cancel editing (Escape)").accessibilityLabel("Cancel editing")
                    .accessibilityIdentifier("google-task-inline-cancel")
                    .ternHover(isEnabled: !session.isSaving)
                }
            }
            TextField("Add details", text: $session.notes, axis: .vertical)
                .font(.callout).textFieldStyle(.plain).lineLimit(1...4)
                .focused($focusedField, equals: .notes)
                .disabled(session.isSaving)
                .accessibilityLabel("Task notes")
                .accessibilityIdentifier("google-task-notes")
            dueFields.font(.caption).controlSize(.small)
            if let url = GoogleTaskRow.emailURL(context.task?.notes ?? "") {
                Button { openURL(url) } label: {
                    Label(GoogleTaskRow.emailSubject(context.task?.notes ?? "") ?? "Source email", systemImage: "envelope")
                        .font(.caption).lineLimit(1)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(session.isSaving)
            }
            errorMessage
        }
        .padding(.horizontal, Tokens.Space.s3)
        .padding(.vertical, Tokens.Space.s2)
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
        VStack(alignment: .leading, spacing: Tokens.Space.s4) {
            HStack(spacing: Tokens.Space.s3) {
                Image(systemName: "checklist").font(.title2).foregroundStyle(Color.accentColor)
                    .frame(width: Tokens.Space.s10, height: Tokens.Space.s10)
                    .background(Color.accentColor.opacity(Tokens.Opacity.wash), in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(context.task == nil ? "New task" : "Task details").font(.title3.weight(.semibold))
                    Text(context.listTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(context.listTitle)
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s3) {
                VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                    Text("Title").font(.caption).foregroundStyle(.secondary)
                    TextField("What needs to be done?", text: $session.title, axis: .vertical)
                        .font(.title3.weight(.medium)).textFieldStyle(.plain)
                        .lineLimit(2...4).focused($focusedField, equals: .title)
                        .accessibilityLabel("Task title")
                        .accessibilityIdentifier("google-task-title")
                }
                Divider()
                VStack(alignment: .leading, spacing: Tokens.Space.s1_5) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
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
                            Text("Source email").font(.caption2).foregroundStyle(.secondary)
                            Text(GoogleTaskRow.emailSubject(context.task?.notes ?? "") ?? "Open source email")
                                .font(.callout).lineLimit(1)
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
            HStack {
                if session.isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: finish).keyboardShortcut(.cancelAction).disabled(session.isSaving)
                Button(context.task == nil ? "Add Task" : "Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canSave)
            }
        }
        .padding(Tokens.Space.s5)
        .frame(width: Tokens.Sheet.smallWidth)
        .background(Tokens.Surface.primary.overlay(Color.primary.opacity(Tokens.Opacity.hover)))
        .interactiveDismissDisabled(session.isSaving)
    }

    private var dueFields: some View {
        HStack(spacing: Tokens.Space.s2) {
            Toggle("Due date", isOn: $session.hasDueDate).toggleStyle(.checkbox)
            Spacer(minLength: Tokens.Space.s1)
            if session.hasDueDate {
                DatePicker("Due", selection: $session.dueDate, displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden()
                    .accessibilityLabel("Task due date")
            }
        }
        .disabled(session.isSaving)
    }

    @ViewBuilder private var errorMessage: some View {
        if let error = session.error {
            Label(error, systemImage: "exclamationmark.circle")
                .font(isInline ? .caption : .callout).foregroundStyle(Tokens.Status.error)
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
