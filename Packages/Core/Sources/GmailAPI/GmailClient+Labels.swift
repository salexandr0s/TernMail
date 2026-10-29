import Foundation

/// How a label patch treats the color.
public enum LabelColorChange: Sendable, Hashable {
    case set(LabelColor)
    /// Sends `"color": null`.
    case remove
}

extension GmailClient {
    /// `labels.create`, shown in the label list and the message list.
    public func createLabel(name: String, color: LabelColor?) async throws -> GmailLabel {
        let body = try encode(NewLabel(name: name, color: color))
        return try decode(await send(.post("labels", body: body)))
    }

    /// `labels.patch` with only the fields given. A nil `color` leaves it as is.
    public func patchLabel(id: String, name: String? = nil, color: LabelColorChange? = nil) async throws -> GmailLabel {
        guard name != nil || color != nil else { throw GmailError.invalidRequest("Empty label patch") }
        let body = try encode(LabelPatch(name: name, color: color))
        return try decode(await send(.patch("labels/\(id)", body: body)))
    }

    /// `labels.delete`, which Gmail can't undo. A label that's already gone counts as deleted.
    public func deleteLabel(id: String) async throws {
        do {
            _ = try await send(.delete("labels/\(id)"))
        } catch GmailError.notFound {
            return
        }
    }
}

private struct NewLabel: Encodable {
    let name: String
    let labelListVisibility = "labelShow"
    let messageListVisibility = "show"
    let color: LabelColor?
}

private struct LabelPatch: Encodable {
    enum CodingKeys: String, CodingKey {
        case name, color
    }

    let name: String?
    let color: LabelColorChange?

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        switch color {
        case nil:
            break
        case .remove:
            try container.encodeNil(forKey: .color)
        case .set(let value):
            try container.encode(value, forKey: .color)
        }
    }
}
