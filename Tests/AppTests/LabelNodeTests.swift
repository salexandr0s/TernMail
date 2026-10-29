import MailStore
import Testing
@testable import Tern

@Suite struct LabelNodeTests {
    @Test func labelsNestUnderTheirNearestExistingAncestor() throws {
        let names = ["Work/Clients/Acme", "Travel", "Work", "Old/Receipts", "Work/Clients/Acme/2026"]
        let labels = names.enumerated().map { index, name in
            LabelRecord(accountID: "a", id: "Label_\(index)", name: name, isSystem: false)
        }

        let outline = LabelNode.outline(labels)

        // "Old" doesn't exist, so its child keeps its full name at the top level.
        #expect(outline.map(\.title) == ["Old/Receipts", "Travel", "Work"])
        #expect(outline[0].children == nil)
        // "Work/Clients" doesn't exist either, so Acme sits under Work.
        let acme = try #require(outline[2].children?.first)
        #expect(acme.title == "Clients/Acme")
        #expect(acme.children?.map(\.title) == ["2026"])
    }
}
