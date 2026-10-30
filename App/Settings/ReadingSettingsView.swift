import SwiftUI

struct ReadingSettingsView: View {
    @AppStorage(ReadingPreferences.blockImagesKey) private var blocksImages = true
    @AppStorage(ReadingPreferences.adaptDarkKey) private var adaptsDark = true
    @AppStorage(ReadingPreferences.orderKey) private var order = ReadingPreferences.Order.oldestFirst.rawValue
    @AppStorage(ReadingPreferences.markReadKey) private var markRead = ReadingPreferences.MarkRead.immediately.rawValue
    @AppStorage(ReadingPreferences.readDelayKey) private var delay = 3.0
    @AppStorage(ReadingPreferences.textScaleKey) private var scale = 1.0
    @AppStorage(ReadingPreferences.sizeKey) private var showsSize = false

    var body: some View {
        Section("Reading") {
            Toggle("Block remote images", isOn: $blocksImages)
            Text("Load Images allows HTTPS images for one message. Known tracking images stay blocked.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Adapt messages to Dark Mode", isOn: $adaptsDark)
            Picker("Conversation order", selection: $order) {
                Text("Oldest first").tag(ReadingPreferences.Order.oldestFirst.rawValue)
                Text("Newest first").tag(ReadingPreferences.Order.newestFirst.rawValue)
            }
            Picker("Mark as read", selection: $markRead) {
                Text("Immediately").tag(ReadingPreferences.MarkRead.immediately.rawValue)
                Text("After a delay").tag(ReadingPreferences.MarkRead.delayed.rawValue)
                Text("Manually").tag(ReadingPreferences.MarkRead.manually.rawValue)
            }
            if markRead == ReadingPreferences.MarkRead.delayed.rawValue {
                Picker("Read delay", selection: $delay) {
                    ForEach([1.0, 3, 5, 10, 30], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
            }
            Picker("Text size", selection: $scale) {
                Text("Small").tag(0.85)
                Text("Default").tag(1.0)
                Text("Large").tag(1.15)
                Text("Extra large").tag(1.3)
                Text("Largest").tag(1.5)
            }
            Toggle("Show message size", isOn: $showsSize)
        }
    }
}
