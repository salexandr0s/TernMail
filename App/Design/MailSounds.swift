import AppKit
import SyncEngine

@MainActor enum MailSounds {
    enum Event { case archive, trash, send }
    nonisolated static let enabledKey = "mailSoundsEnabled"

    static func event(for action: MailAction) -> Event? {
        switch action {
        case .archive: .archive
        case .trash: .trash
        case .markRead, .markUnread, .star, .unstar: nil
        }
    }

    static func playAction(_ action: MailAction) {
        if let event = event(for: action), !Task.isCancelled { play(event) }
    }

    static func play(_ event: Event) {
        guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
        let name = switch event {
        case .archive: "Tink"
        case .trash: "Pop"
        case .send: "Glass"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
