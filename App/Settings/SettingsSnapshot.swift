import GmailAPI
import MailStore

/// The last server read stays separate from the queue overlay, so cancelling
/// an offline change restores the server value without another network call.
struct SettingsSnapshot: Equatable {
    var filters: [GmailFilter] = []
    var identities: [IdentityRecord] = []
    var vacation = VacationSettings()

    func applying(_ actions: [PendingAction]) -> SettingsSnapshot {
        var snapshot = self
        for row in actions where row.state != .sent && row.state != .undone {
            switch row.settingsChange {
            case .createFilter(let filter, _):
                if !snapshot.filters.contains(where: { $0.hasSameRules(as: filter) }) { snapshot.filters.append(filter) }
            case .deleteFilter(let id, let filter, _):
                snapshot.filters.removeAll { id == nil ? $0.hasSameRules(as: filter) : $0.id == id }
            case .replaceFilter(let oldID, let old, let new, _, _):
                snapshot.filters.removeAll { oldID == nil ? $0.hasSameRules(as: old) : $0.id == oldID }
                if !snapshot.filters.contains(where: { $0.hasSameRules(as: new) }) { snapshot.filters.append(new) }
            case .signature(let address, let html, _):
                if let index = snapshot.identities.firstIndex(where: { $0.address.lowercased() == address.lowercased() }) {
                    snapshot.identities[index].signatureHTML = html
                }
            case .vacation(let fields, let new, _):
                for field in fields {
                    switch field {
                    case .enableAutoReply: snapshot.vacation.enableAutoReply = new.enableAutoReply
                    case .subject: snapshot.vacation.responseSubject = new.responseSubject
                    case .body:
                        snapshot.vacation.responseBodyPlainText = new.responseBodyPlainText
                        snapshot.vacation.responseBodyHtml = new.responseBodyHtml
                    case .restrictToContacts: snapshot.vacation.restrictToContacts = new.restrictToContacts
                    case .restrictToDomain: snapshot.vacation.restrictToDomain = new.restrictToDomain
                    case .startTime: snapshot.vacation.startTime = new.startTime
                    case .endTime: snapshot.vacation.endTime = new.endTime
                    }
                }
            case nil: break
            }
        }
        return snapshot
    }
}
