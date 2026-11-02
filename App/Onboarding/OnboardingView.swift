import AppKit
import MailStore
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var preferenceDefaults: UserDefaults

    init(preferenceDefaults: UserDefaults? = nil) {
        let isolated = ProcessInfo.processInfo.arguments.contains("--ui-audit") || AssistantRuntimeEnvironment.isTestHost
        _preferenceDefaults = State(initialValue: preferenceDefaults
            ?? (isolated ? UserDefaults(suiteName: "tern.onboarding.preview") ?? UserDefaults() : .standard))
    }

    private var step: OnboardingState.Step { app.onboarding.step }
    private var connectedAccounts: [AccountRecord] {
        if case .signInRequired = app.phase { return [] }
        return app.mailbox?.accounts.map(\.account).filter { !app.accountsNeedingSignIn.contains($0.id) } ?? []
    }
    private var isBusy: Bool {
        let connection = app.assistant.connection
        return app.isSigningIn || connection.isConnecting || connection.isDisconnecting || connection.isRestoring
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < Tokens.Onboarding.compactWidth
            HStack(spacing: 0) {
                if !compact {
                    sidebar
                    Divider()
                }
                VStack(spacing: 0) {
                    if compact { compactProgress }
                    ScrollView {
                        VStack(alignment: .leading, spacing: Tokens.Space.s6) {
                            header
                            stepContent
                        }
                        .frame(maxWidth: Tokens.Onboarding.contentWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(compact ? Tokens.Space.s6 : Tokens.Space.s8)
                    }
                    .id(step)
                    .transition(.opacity)
                    Divider()
                    footer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Tokens.Surface.primary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: Tokens.Layout.windowMinWidth, minHeight: Tokens.Layout.windowMinHeight)
        .background(Tokens.Surface.muted)
        .defaultAppStorage(preferenceDefaults)
        .ternAnimation(value: step)
        .task(id: step) {
            if step == .preferences || step == .ready { await app.assistant.refreshConnection() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s8) {
            HStack(spacing: Tokens.Space.s3) {
                appIcon(size: Tokens.Space.s10)
                VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                    Text("Tern").font(.title2.weight(.semibold))
                    Text("Set up your space").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                ForEach(OnboardingState.Step.allCases.filter { $0 != .ready }, id: \.self) { item in
                    HStack(spacing: Tokens.Space.s3) {
                        Image(systemName: item.index < step.index ? "checkmark.circle.fill" : item.symbol)
                            .font(.body.weight(.medium))
                            .frame(width: Tokens.Space.s6)
                            .foregroundStyle(item == step ? Color.accentColor : .secondary)
                            .accessibilityHidden(true)
                        Text(item.shortTitle).font(.body.weight(item == step ? .semibold : .regular))
                    }
                    .padding(Tokens.Space.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(item == step ? Color.accentColor.opacity(Tokens.Opacity.wash) : .clear,
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(item.shortTitle)
                    .accessibilityValue(item == step ? "Current step" : item.index < step.index ? "Visited" : "Upcoming")
                }
            }
            Spacer(minLength: Tokens.Space.s6)
            OnboardingNote(text: "Your progress is saved as you go.", symbol: "checkmark.circle")
        }
        .padding(Tokens.Space.s5)
        .frame(width: Tokens.Onboarding.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background {
            Tokens.Surface.muted.overlay(alignment: .top) {
                LinearGradient(colors: [Color.accentColor.opacity(Tokens.Opacity.wash), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    private var compactProgress: some View {
        HStack(spacing: Tokens.Space.s3) {
            appIcon(size: Tokens.Space.s8)
            Text("Tern").font(.headline)
            Spacer()
            Text(step == .ready ? "Review setup" : "Step \(step.index + 1) of 4 · \(step.shortTitle)")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Tokens.Space.s6)
        .padding(.vertical, Tokens.Space.s3)
        .background(Tokens.Surface.muted)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            if step == .welcome { appIcon(size: Tokens.Onboarding.heroIcon) }
            if step == .ready {
                Image(systemName: connectedAccounts.isEmpty ? "person.crop.circle.badge.exclamationmark" : "checkmark.circle.fill")
                    .font(.largeTitle).foregroundStyle(connectedAccounts.isEmpty ? Tokens.Status.warning : Tokens.Status.success)
                    .frame(width: Tokens.Space.s16, height: Tokens.Space.s16)
                    .background(Tokens.Status.success.opacity(Tokens.Opacity.wash), in: Circle())
                    .accessibilityHidden(true)
            }
            Text(step == .ready && connectedAccounts.isEmpty ? "One last connection." : step.title)
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(step == .ready && connectedAccounts.isEmpty ? "Your preferences are saved. Reconnect Google to open your inbox." : step.subtitle)
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                OnboardingFeature(symbol: "tray.2", title: "Bring your accounts together",
                                  detail: "Keep work and personal Gmail in one place.")
                OnboardingFeature(symbol: "sparkles", title: "Get help with your mail",
                                  detail: "Connect ChatGPT for summaries, search, and writing help.")
                OnboardingFeature(symbol: "slider.horizontal.3", title: "Choose what works for you",
                                  detail: "Set up sending, privacy, and notifications.")
            }
        case .google: OnboardingGoogleStep()
        case .chatGPT: OnboardingChatGPTStep()
        case .preferences: OnboardingPreferencesStep()
        case .ready: readySummary
        }
    }

    private var readySummary: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s5) {
            VStack(alignment: .leading, spacing: Tokens.Space.s5) {
                OnboardingFeature(symbol: "tray.2", title: "\(connectedAccounts.count) Google \(connectedAccounts.count == 1 ? "account" : "accounts") connected",
                                  detail: connectedAccounts.isEmpty ? "Return to Google accounts to reconnect." : "Your mail syncs in the background. You can start using Tern now.")
                OnboardingFeature(symbol: "sparkles", title: assistantSummary.title, detail: assistantSummary.detail)
                OnboardingFeature(symbol: "checkmark.circle", title: "Preferences saved",
                                  detail: preferencesSummary)
            }
            .padding(Tokens.Space.s5)
            .ternSurface()
            if connectedAccounts.isEmpty {
                OnboardingError(message: "Reconnect a Google account before opening your inbox.")
            }
        }
    }

    private var assistantSummary: (title: String, detail: String) {
        let assistant = app.assistant
        if assistant.connection.isRestoring {
            return ("Opening your ChatGPT connection", "Checking the connection saved in your Keychain.")
        }
        if assistant.connection.needsStorageRetry {
            return ("ChatGPT needs Keychain access", "Retry the saved connection in Settings → Assistant.")
        }
        guard assistant.connection.canUsePlan else {
            return ("ChatGPT can wait", "Connect whenever you're ready in Settings → Assistant.")
        }
        if assistant.isLoadingModels {
            return ("ChatGPT connected", "Available models are still loading. You can open Tern while they load.")
        }
        if assistant.modelErrorMessage != nil || !assistant.models.contains(where: { $0.id == assistant.selectedModelID }) {
            return ("ChatGPT connected", "Finish loading an available model in Settings → Assistant.")
        }
        if assistant.enabledAccountIDs.isEmpty {
            return ("ChatGPT connected", "Mail access is off. Choose accounts in Settings → Assistant when you're ready.")
        }
        return ("Your assistant is ready", "Use the assistant for the mail accounts you allowed.")
    }

    private var preferencesSummary: String {
        let delay = preferenceDefaults.object(forKey: UndoSendDelay.key) as? Int ?? UndoSendDelay.defaultSeconds
        let blocksImages = preferenceDefaults.object(forKey: ReadingPreferences.blockImagesKey) as? Bool ?? true
        return "Undo Send: \(delay) seconds. \(blocksImages ? "Remote images blocked." : "Remote images allowed.")"
    }

    private var footer: some View {
        HStack(spacing: Tokens.Space.s3) {
            if step == .welcome {
                Text("Next: Google accounts").font(.callout).foregroundStyle(.secondary)
            }
            if step != .welcome {
                Button("Back", systemImage: "chevron.left") { navigate(to: step.previous) }
                    .disabled(isBusy)
                    .accessibilityIdentifier("onboarding.back")
            }
            Spacer(minLength: Tokens.Space.s2)
            if step == .google && connectedAccounts.isEmpty {
                Text("Connect an account to continue.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if step == .chatGPT && !app.assistant.connection.canUsePlan {
                    continueButton.buttonStyle(.bordered)
                } else {
                    continueButton.buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(isBusy || (step == .google && connectedAccounts.isEmpty))
            .accessibilityIdentifier("onboarding.continue")
        }
        .padding(.horizontal, Tokens.Space.s6)
        .padding(.vertical, Tokens.Space.s4)
    }

    private var continueButton: some View {
        Button(action: advance) {
            HStack(spacing: Tokens.Space.s2) {
                Text(primaryTitle)
                Image(systemName: "arrow.right").accessibilityHidden(true)
            }
            .padding(.horizontal, Tokens.Space.s2)
        }
    }

    private var primaryTitle: String {
        switch step {
        case .welcome: "Get started"
        case .chatGPT: app.assistant.connection.canUsePlan ? "Continue" : "Set up later"
        case .preferences: "Review setup"
        case .ready: connectedAccounts.isEmpty ? "Review accounts" : "Open Tern"
        default: "Continue"
        }
    }

    private func advance() {
        guard !isBusy else { return }
        if step == .ready {
            if connectedAccounts.isEmpty { navigate(to: .google) }
            else { app.onboarding.finish(hasConnectedAccount: true) }
        } else if step != .google || !connectedAccounts.isEmpty {
            navigate(to: step.next)
        }
    }

    private func navigate(to destination: OnboardingState.Step) {
        guard !isBusy else { return }
        withAnimation(reduceMotion ? nil : Tokens.Motion.standard()) { app.onboarding.step = destination }
    }

    private func appIcon(size: CGFloat) -> some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

private extension OnboardingState.Step {
    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    var previous: Self { Self.allCases[max(0, index - 1)] }
    var next: Self { Self.allCases[min(Self.allCases.count - 1, index + 1)] }
    var shortTitle: String {
        switch self {
        case .welcome: "Welcome"
        case .google: "Google accounts"
        case .chatGPT: "ChatGPT"
        case .preferences: "Preferences"
        case .ready: "Ready"
        }
    }
    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .google: "tray.2"
        case .chatGPT: "sparkles"
        case .preferences: "slider.horizontal.3"
        case .ready: "checkmark.circle"
        }
    }
    var title: String {
        switch self {
        case .welcome: "Welcome to Tern."
        case .google: "Make room for every inbox."
        case .chatGPT: "A little help from ChatGPT."
        case .preferences: "Make Tern yours."
        case .ready: "You're ready to go."
        }
    }
    var subtitle: String {
        switch self {
        case .welcome: "Your Gmail accounts, a helpful assistant, and a few choices to get you started."
        case .google: "Connect the Google accounts you'd like to use in Tern."
        case .chatGPT: "Connect your ChatGPT account and choose which mail it can use."
        case .preferences: "Start with the essentials. You can adjust everything later."
        case .ready: "Your accounts and preferences are in place."
        }
    }
}
