import AppKit
import SwiftUI

/// Input and its context controls travel together between the sidebar and window.
struct AssistantComposer: View {
    @Bindable var model: AssistantModel
    let setup: AssistantSetupPrompt?
    let canSubmit: Bool
    @FocusState.Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onSettings: () -> Void
    let onSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            input
            if let setup, !model.messages.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(setup.detail).font(.caption).foregroundStyle(.secondary)
                    Button(setup.action, action: onSetup)
                    .buttonStyle(.link).font(.caption)
                        .disabled(model.isLoadingModels)
                }
                .ternTransition(.disclosure)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Tokens.Space.s2) {
                    accessButton
                    scopeMenu.fixedSize()
                    Spacer(minLength: Tokens.Space.s3)
                    modelMenu.fixedSize()
                    sendButton
                }
                VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                    scopeMenu
                    HStack(spacing: Tokens.Space.s2) {
                        accessButton
                        Spacer(minLength: Tokens.Space.s2)
                        modelMenu
                        sendButton
                    }
                }
            }
        }
        .padding(Tokens.Space.s3)
        .background(Tokens.Assistant.composerBackground,
                    in: RoundedRectangle(cornerRadius: Tokens.Assistant.composerRadius))
        .ternOutline(radius: Tokens.Assistant.composerRadius, style: .contrastOnly)
        .ternAnimation(value: setup != nil && !model.messages.isEmpty)
    }

    private var input: some View {
        TextField(model.messages.isEmpty ? "Ask about mail or calendar…" : "Ask a follow-up…",
                  text: $model.composerText, axis: .vertical)
            .font(.body).textFieldStyle(.plain).lineLimit(2...6)
            .padding(.horizontal, Tokens.Space.s1)
            .padding(.top, Tokens.Space.s1)
            .focused($isFocused)
            .onKeyPress(.return, phases: .down) { press in
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
                   editor.hasMarkedText() { return .ignored }
                if press.modifiers.contains(.shift) {
                    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return .ignored }
                    editor.insertNewlineIgnoringFieldEditor(nil)
                    return .handled
                }
                guard !press.modifiers.contains(.option),
                      !press.modifiers.contains(.control) else { return .ignored }
                onSubmit()
                return .handled
            }
            .accessibilityLabel("Message to assistant")
            .accessibilityIdentifier("assistant.message")
            .accessibilityHint("Return to send. Shift-Return for a new line.")
            .disabled(setup != nil)
    }

    private var scopeMenu: some View {
        Menu {
            Picker("Mail scope", selection: $model.selectedScope) {
                ForEach(AssistantScope.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Manage Mail & Calendar Access…", systemImage: "slider.horizontal.3", action: onSettings)
        } label: {
            Label(model.usesPreviousMailScope ? "Previous mail scope" : model.selectedScope.title, systemImage: "envelope")
                .lineLimit(1)
            .padding(.horizontal, Tokens.Space.s1)
            .frame(minHeight: Tokens.Control.iconButton)
            .contentShape(Capsule())
        }
        .menuIndicator(.visible).menuStyle(.borderlessButton)
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityLabel("Mail scope").accessibilityValue(model.conversationScopeDescription)
        .accessibilityIdentifier("assistant.scope")
        .help("Mail scope: \(model.conversationScopeDescription). Calendar access is managed separately in settings.")
    }

    private var modelMenu: some View {
        Menu {
            if model.models.isEmpty {
                Button(model.isLoadingModels ? "Loading models…" : "Choose a Model…", action: onSettings)
                    .disabled(model.isLoadingModels)
            } else {
                Picker("Model", selection: $model.selectedModelID) {
                    ForEach(model.models) { Text($0.displayName).tag($0.id) }
                }
                .pickerStyle(.inline)
                .disabled(model.isRunning || model.isLoadingModels)
            }
            Divider()
            Button("Assistant Settings…", systemImage: "gearshape", action: onSettings)
        } label: {
            Text(modelName).lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, Tokens.Space.s1)
            .frame(minHeight: Tokens.Control.iconButton)
            .contentShape(Capsule())
        }
        .menuIndicator(.visible).menuStyle(.borderlessButton)
        .font(.caption).foregroundStyle(.secondary)
        .accessibilityLabel("Model").accessibilityValue(modelName)
        .accessibilityIdentifier("assistant.model")
        .help(modelName)
    }

    private var accessButton: some View {
        Button(action: onSettings) {
            Image(systemName: "slider.horizontal.3")
                .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .contentShape(.focusEffect, Circle())
        .help("Manage mail and calendar access")
        .accessibilityLabel("Manage assistant access. \(model.enabledAccountIDs.count) enabled mail accounts")
        .accessibilityIdentifier("assistant.access")
    }

    private var sendButton: some View {
        Group {
            if model.isRunning {
                Button { model.stop() } label: {
                    sendIcon("stop.fill")
                }
                .help("Stop response").accessibilityLabel("Stop response")
            } else {
                Button(action: onSubmit) { sendIcon("arrow.up") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSubmit)
                    .help("Send message (Return or ⌘ Return)")
                    .accessibilityLabel("Send message")
            }
        }
        .buttonStyle(AssistantSendButtonStyle())
        .contentShape(.focusEffect, Circle())
        .accessibilityIdentifier("assistant.send")
    }

    private func sendIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
            .contentShape(Circle())
    }

    private var modelName: String {
        model.models.first(where: { $0.id == model.selectedModelID })?.displayName ?? "ChatGPT"
    }
}

private struct AssistantSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Tokens.Surface.primary : Color.secondary)
            .background(isEnabled ? Color.primary : Color.primary.opacity(Tokens.Opacity.hover), in: Circle())
            .opacity(configuration.isPressed ? Tokens.Opacity.disabled : 1)
    }
}
