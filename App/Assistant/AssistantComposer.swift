import AppKit
import SwiftUI

/// The same input stays anchored below the conversation in the sidebar and window.
struct AssistantComposer: View {
    @Bindable var model: AssistantModel
    let setup: AssistantSetupPrompt?
    let canSubmit: Bool
    @FocusState.Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onSetup: () -> Void
    var isCompact = false

    var body: some View {
        composerLayout {
            input
            if let setup, !model.messages.isEmpty, !isCompact {
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text(setup.detail).font(.caption).foregroundStyle(.secondary)
                    Button(setup.action, action: onSetup)
                        .buttonStyle(.link).font(.caption)
                        .disabled(model.isLoadingModels)
                }
            }
            HStack(alignment: .center, spacing: Tokens.Space.s3) {
                if let setup, !model.messages.isEmpty, isCompact {
                    Button(setup.action, action: onSetup)
                        .buttonStyle(.link).font(.caption)
                        .disabled(model.isLoadingModels)
                        .help(setup.detail).accessibilityHint(setup.detail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !isCompact {
                    Text(inputHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                sendButton
            }
        }
        .padding(isCompact ? Tokens.Space.s3 : Tokens.Space.s4)
        .background(Tokens.Surface.canvas, in: .rect(cornerRadius: Tokens.Radius.lg))
        .ternOutline(radius: Tokens.Radius.lg)
    }

    private var composerLayout: AnyLayout {
        if isCompact {
            AnyLayout(HStackLayout(alignment: .bottom, spacing: Tokens.Space.s2))
        } else {
            AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Space.s3))
        }
    }

    private var input: some View {
        TextField(model.messages.isEmpty ? "Ask about mail or calendar…" : "Ask a follow-up…",
                  text: $model.composerText, axis: .vertical)
            .font(.body).textFieldStyle(.plain).lineLimit(isCompact ? 2...2 : 2...6)
            .padding(.horizontal, Tokens.Space.s1)
            .padding(.top, Tokens.Space.s1)
            .frame(maxWidth: .infinity, alignment: .leading)
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

    private var inputHint: String {
        model.isRunning ? "You can keep writing while the assistant responds." : "Return to send · ⇧Return for a new line"
    }

    private var sendButton: some View {
        Group {
            if model.isRunning {
                Button("Stop", systemImage: "stop.fill") { model.stop() }
                    .help("Stop response").accessibilityLabel("Stop response")
            } else {
                Button("Send", systemImage: "arrow.up", action: onSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSubmit)
                    .help("Send message (Return or ⌘ Return)")
                    .accessibilityLabel("Send message")
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .fixedSize()
        .accessibilityIdentifier("assistant.send")
    }
}
