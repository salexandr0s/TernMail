import Testing
@testable import SyncEngine

@Suite struct TombstonesTests {
    @Test func theOldestTombstonesGoOnceTheLimitIsReached() {
        var tombstones = Tombstones()
        tombstones.formUnion((0..<Tombstones.limit).map { "m\($0)" })
        #expect(tombstones.count == Tombstones.limit)
        #expect(tombstones.contains("m0"))

        tombstones.insert("new")
        #expect(!tombstones.contains("m0"))
        #expect(tombstones.contains("m1"))
        #expect(tombstones.contains("new"))

        // A known ID keeps its place; only a new one pushes the oldest out.
        tombstones.formUnion(["m1"])
        #expect(tombstones.contains("m1"))
        tombstones.formUnion(["other"])
        #expect(!tombstones.contains("m1"))
        #expect(tombstones.count == Tombstones.limit)
    }
}
