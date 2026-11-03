import SwiftUI

/// Compose commands observe the draft directly; the session owner controls assistant visibility.
struct ComposeToolbar: ToolbarContent {
    @Bindable var model: ComposeModel
    @Binding var showsAssistant: Bool
    let availableWidth: CGFloat
    let onCloseAssistant: () -> Void

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        // On the leading side, far from Send.
        ToolbarItem(placement: .navigation) {
            Button {
                Task { await model.discard() }
            } label: {
                Label("Discard Draft", systemImage: "trash")
            }
            .help("Discard Draft")
            .disabled(!model.isEditable)
        }
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                if showsAssistant { onCloseAssistant() }
                else { showsAssistant = true }
            } label: {
                toolbarLabel("Ask AI", systemImage: "sparkles")
                    .foregroundStyle(showsAssistant ? Color.accentColor : .primary)
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .help(showsAssistant ? "Close compose assistant (⇧⌘J)" : "Ask the assistant to help write (⇧⌘J)")
            .accessibilityLabel("Compose Assistant")
            .accessibilityIdentifier("compose-assistant-toggle")
            .accessibilityValue(showsAssistant ? "Open" : "Closed")
            .disabled(!model.isEditable)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showsFormatting.toggle()
            } label: {
                Label("Formatting", systemImage: "textformat")
                    .foregroundStyle(model.showsFormatting ? Color.accentColor : .primary)
            }
            .labelStyle(.iconOnly)
            .help(model.showsFormatting ? "Hide Formatting" : "Show Formatting")
            .accessibilityLabel("Formatting")
            .accessibilityIdentifier("compose-formatting-toggle")
            .accessibilityValue(model.showsFormatting ? "Expanded" : "Collapsed")
            .disabled(!model.isEditable)
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.isChoosingFiles = true
            } label: {
                Label("Attach Files", systemImage: "paperclip")
            }
            .help("Attach Files")
            .disabled(!model.isEditable)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Toggle("Request Read Receipt", isOn: $model.content.requestsReadReceipt)
                Text("Receipts depend on the recipient's email app and settings.")
                if !model.templates.isEmpty || model.canSendAndArchive { Divider() }
                if !model.templates.isEmpty {
                    Menu("Insert Template", systemImage: "doc.text") {
                        ForEach(model.templates) { template in
                            Button(template.name) { model.insertTemplate(template) }
                        }
                    }
                }
                if model.canSendAndArchive {
                    if !model.templates.isEmpty { Divider() }
                    Button("Send and Archive", systemImage: "archivebox") { Task { await model.send(archive: true) } }
                }
            } label: {
                Label("More", systemImage: "ellipsis")
                    .foregroundStyle(model.content.requestsReadReceipt ? Color.accentColor : .primary)
            }
            .labelStyle(.iconOnly)
            .menuIndicator(.hidden)
            .help(model.content.requestsReadReceipt ? "Read receipt requested. More compose actions" : "More compose actions")
            .accessibilityLabel("More Compose Actions")
            .accessibilityIdentifier("compose-more")
            .accessibilityValue(model.content.requestsReadReceipt ? "Read receipt requested" : "")
            .disabled(!model.isEditable)
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.send() }
            } label: {
                Label("Send", systemImage: "paperplane")
                    .labelStyle(.titleAndIcon)
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .help("Send (⇧⌘D)")
            .accessibilityLabel("Send")
            .accessibilityIdentifier("compose-send")
            .disabled(!model.isEditable)
        }
    }

    @ViewBuilder private func toolbarLabel(_ title: String, systemImage: String) -> some View {
        if availableWidth >= Tokens.Compose.labeledToolbarWidth {
            Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
        } else {
            Label(title, systemImage: systemImage).labelStyle(.iconOnly)
        }
    }

}
