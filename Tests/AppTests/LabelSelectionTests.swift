import Testing
@testable import Tern

@Suite struct LabelSelectionTests {
    @Test func statesComeFromEverySelectedConversation() {
        let selection = LabelSelection(applied: [["Label_a", "Label_b"], ["Label_a"]])
        #expect(selection.state(of: "Label_a") == .on)
        #expect(selection.state(of: "Label_b") == .mixed)
        #expect(selection.state(of: "Label_c") == .off)
        #expect(selection.change.isEmpty)
    }

    @Test func aMixedLabelCyclesBackToChangingNothing() {
        var selection = LabelSelection(applied: [["Label_b"], []])
        selection.toggle("Label_b")
        #expect(selection.change == .init(add: ["Label_b"]))
        selection.toggle("Label_b")
        #expect(selection.change == .init(remove: ["Label_b"]))
        selection.toggle("Label_b")
        #expect(selection.state(of: "Label_b") == .mixed)
        #expect(selection.change.isEmpty)
    }

    @Test func onAndOffAlternateAndOnlyDifferencesAreSent() {
        var selection = LabelSelection(applied: [["Label_a"]])
        selection.toggle("Label_a")
        selection.toggle("Label_c")
        #expect(selection.change == .init(add: ["Label_c"], remove: ["Label_a"]))
        selection.toggle("Label_a")
        selection.toggle("Label_c")
        #expect(selection.state(of: "Label_a") == .on)
        #expect(selection.change.isEmpty)
    }
}
