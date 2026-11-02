import GmailAPI

extension PendingAction.SettingsChange {
    /// A deletion identifies its filter by ID. Only the new filter in a create
    /// or replacement needs these labels to exist when Gmail receives it.
    public var requiredLabelIDs: [String] {
        switch self {
        case .createFilter(let filter, _), .replaceFilter(_, _, let filter, _, _):
            (filter.action.addLabelIds ?? []) + (filter.action.removeLabelIds ?? [])
        case .deleteFilter, .vacation, .signature: []
        }
    }

    /// Every label in the payload, including the old filter kept for Undo.
    public var referencedLabelIDs: [String] {
        switch self {
        case .createFilter(let filter, _), .deleteFilter(_, let filter, _):
            (filter.action.addLabelIds ?? []) + (filter.action.removeLabelIds ?? [])
        case .replaceFilter(_, let old, let new, _, _):
            (old.action.addLabelIds ?? []) + (old.action.removeLabelIds ?? [])
                + (new.action.addLabelIds ?? []) + (new.action.removeLabelIds ?? [])
        case .vacation, .signature: []
        }
    }

    func mappingLabelIDs(_ transform: (String) -> String) -> Self {
        func map(_ filter: GmailFilter) -> GmailFilter {
            var result = filter
            result.action.addLabelIds = filter.action.addLabelIds?.map(transform)
            result.action.removeLabelIds = filter.action.removeLabelIds?.map(transform)
            return result
        }
        switch self {
        case .createFilter(let filter, let listedIDs):
            return .createFilter(filter: map(filter), listedIDs: listedIDs)
        case .deleteFilter(let id, let filter, let listedIDs):
            return .deleteFilter(id: id, filter: map(filter), listedIDs: listedIDs)
        case .replaceFilter(let oldID, let old, let new, let listedIDs, let newID):
            return .replaceFilter(oldID: oldID, old: map(old), new: map(new), listedIDs: listedIDs, newID: newID)
        case .vacation, .signature: return self
        }
    }
}
