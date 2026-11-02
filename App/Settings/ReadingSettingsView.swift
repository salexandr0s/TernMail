import SwiftUI

struct ReadingSettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage(ReadingPreferences.blockImagesKey) private var blocksImages = true
    @AppStorage(ReadingPreferences.adaptDarkKey) private var adaptsDark = true
    @AppStorage(ReadingPreferences.orderKey) private var order = ReadingPreferences.Order.oldestFirst.rawValue
    @AppStorage(ReadingPreferences.markReadKey) private var markRead = ReadingPreferences.MarkRead.immediately.rawValue
    @AppStorage(ReadingPreferences.readDelayKey) private var delay = 3.0
    @AppStorage(ReadingPreferences.textScaleKey) private var scale = 1.0
    @AppStorage(ReadingPreferences.sizeKey) private var showsSize = false
    @AppStorage(DomainLogoImages.preferenceKey) private var showsLogos = DomainLogoPreferences.defaultEnabled
    @AppStorage(MailSpotlightIndexer.enabledKey) private var showsInSpotlight = false

    var body: some View {
        SettingsPage {
            Section("Appearance") {
                SettingsControlRow("Text size") {
                    Picker("Text size", selection: $scale) {
                        Text("Small").tag(0.85)
                        Text("Default").tag(1.0)
                        Text("Large").tag(1.15)
                        Text("Extra large").tag(1.3)
                        Text("Largest").tag(1.5)
                    }
                    .fixedSize()
                }
                SettingsToggleRow("Adapt Messages to Dark Mode", isOn: $adaptsDark)
                SettingsToggleRow("Show Message Size", isOn: $showsSize)
            }

            Section("Conversations") {
                SettingsControlRow("Message order") {
                    Picker("Conversation order", selection: $order) {
                        Text("Oldest first").tag(ReadingPreferences.Order.oldestFirst.rawValue)
                        Text("Newest first").tag(ReadingPreferences.Order.newestFirst.rawValue)
                    }
                    .fixedSize()
                }
                SettingsControlRow("Mark as read") {
                    Picker("Mark as read", selection: $markRead) {
                        Text("Immediately").tag(ReadingPreferences.MarkRead.immediately.rawValue)
                        Text("After a delay").tag(ReadingPreferences.MarkRead.delayed.rawValue)
                        Text("Manually").tag(ReadingPreferences.MarkRead.manually.rawValue)
                    }
                    .fixedSize()
                }
                if markRead == ReadingPreferences.MarkRead.delayed.rawValue {
                    SettingsControlRow("Read delay") {
                        Picker("Read delay", selection: $delay) {
                            ForEach([1.0, 3, 5, 10, 30], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                        }
                        .fixedSize()
                    }
                }
            }

            Section("Privacy") {
                SettingsToggleRow("Block Remote Images", detail: "Choose Load Images to allow HTTPS images in one message. Known tracking images stay blocked.", isOn: $blocksImages)
                SettingsToggleRow("Show Company Logos", detail: "When a sender has no photo, look for an icon on their website. Websites receive your IP address, but no email address or message content.", isOn: $showsLogos)
                SettingsToggleRow("Show Mail in Spotlight", detail: "Spotlight lists conversation subjects, sender names and previews. Turning this off removes them.", isOn: $showsInSpotlight)
                if app.spotlightRemoval.hasPendingRemoval {
                    LabeledContent {
                        if app.spotlightRemoval.isRemoving {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Retry Removal") { app.retrySpotlightRemoval() }
                        }
                    } label: {
                        Text(app.spotlightRemoval.error ?? (app.spotlightRemoval.isRemoving
                            ? "Removing mail from Spotlight…" : "Mail is waiting to be removed from Spotlight."))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
