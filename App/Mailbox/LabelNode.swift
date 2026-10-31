import Foundation
import MailStore

/// User labels as an outline. Gmail stores nesting in the name, so
/// "Work/Clients" sits under "Work" when that label exists. A label whose
/// parent doesn't exist shows at the top level under its full name.
struct LabelNode: Identifiable, Equatable {
    let label: LabelRecord
    /// The name below the parent, or the full name at the top level.
    let title: String
    /// Nil for a label with nothing nested under it, as `OutlineGroup` expects.
    var children: [LabelNode]?

    var id: String { label.id }

    static func outline(_ labels: [LabelRecord]) -> [LabelNode] {
        let sorted = labels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let names = Set(sorted.map(\.name))
        // The nearest existing ancestor of each label, by full name.
        func parent(of name: String) -> String? {
            var path = name
            while let slash = path.lastIndex(of: "/") {
                path = String(path[..<slash])
                if names.contains(path) { return path }
            }
            return nil
        }
        let children = Dictionary(grouping: sorted) { parent(of: $0.name) ?? "" }
        func nodes(under parentName: String?) -> [LabelNode] {
            (children[parentName ?? ""] ?? []).map { label in
                let title = parentName.map { String(label.name.dropFirst($0.count + 1)) } ?? label.name
                let nested = nodes(under: label.name)
                return LabelNode(label: label, title: title, children: nested.isEmpty ? nil : nested)
            }
        }
        return nodes(under: nil)
    }
}
