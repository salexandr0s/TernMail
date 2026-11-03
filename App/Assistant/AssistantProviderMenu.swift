import AppKit
import SwiftUI
import TernAI

/// The service identity is also its selector in the sidebar and detached window.
struct AssistantProviderMenu: View {
    @Bindable var model: AssistantModel
    let onSettings: () -> Void

    var body: some View {
        Menu {
            ForEach(AIService.allCases) { service in
                Button {
                    guard service != model.selectedService else { return }
                    model.selectService(service)
                    Task { await model.refreshConnection() }
                } label: {
                    HStack {
                        AssistantProviderBrand(service: service, size: Tokens.Space.s4)
                        Text(service.displayName)
                        if service == model.selectedService { Image(systemName: "checkmark") }
                    }
                }
            }
            Divider()
            Button("Manage Connections…", systemImage: "gearshape", action: onSettings)
        } label: {
            HStack(spacing: Tokens.Space.s2) {
                AssistantProviderBrand(service: model.selectedService, size: Tokens.Space.s5)
                    .frame(width: Tokens.Control.iconButton, height: Tokens.Control.iconButton)
                    .background(Tokens.Surface.primary, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .ternOutline(radius: Tokens.Radius.md)
                    .accessibilityHidden(true)
                Text(model.providerDisplayName).font(.headline).lineLimit(1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.md))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize(horizontal: true, vertical: false)
        .ternHover()
        .accessibilityLabel("Assistant provider")
        .accessibilityValue(model.providerDisplayName)
        .accessibilityIdentifier("assistant.provider")
        .help("Choose an assistant provider")
    }
}

/// Bundled provider artwork identifies the selected connection without a network request.
struct AssistantProviderBrand: View {
    let service: AIService
    var size: CGFloat = Tokens.Space.s5
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(nsImage: renderedImage)
            .renderingMode(service == .anthropic ? .template : .original)
            .frame(width: size, height: size)
            .accessibilityLabel(service.displayName)
    }

    /// Native menus read the image's point size, ignoring SwiftUI resize modifiers.
    private var renderedImage: NSImage {
        let renderer = ImageRenderer(content: artwork
            .frame(width: size, height: size)
            .environment(\.colorScheme, colorScheme))
        renderer.scale = displayScale
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
        image.size = NSSize(width: size, height: size)
        image.isTemplate = service == .anthropic
        return image
    }

    private var artwork: some View {
        Group {
            switch service {
            case .chatGPT, .openAI:
                ChatGPTBrand(size: size)
            case .anthropic:
                Image("ClaudeLogo")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.primary)
            case .deepSeek:
                Image("DeepSeekLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            }
        }
    }
}
