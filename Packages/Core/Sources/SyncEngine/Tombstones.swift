import Foundation

/// Message IDs the engine knows Gmail deleted, so a fetch that was already in
/// flight cannot write one back. Gmail never reuses an ID, so the set only
/// grows; once it holds `limit` entries the oldest go, by which time any
/// request that could still carry them has long finished.
struct Tombstones: Sendable {
    static let limit = 20_000

    private var ids = Set<String>()
    /// Insertion order, oldest first.
    private var order: [String] = []

    var count: Int { ids.count }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    @discardableResult
    mutating func insert(_ id: String) -> Bool {
        guard ids.insert(id).inserted else { return false }
        order.append(id)
        trim()
        return true
    }

    mutating func formUnion(_ new: some Sequence<String>) {
        for id in new where ids.insert(id).inserted {
            order.append(id)
        }
        trim()
    }

    private mutating func trim() {
        let excess = order.count - Self.limit
        guard excess > 0 else { return }
        for id in order.prefix(excess) { ids.remove(id) }
        order.removeFirst(excess)
    }
}
