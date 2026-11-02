import Foundation
import Testing
@testable import Tern

@Suite @MainActor struct AssistantDiagramLayoutTests {
    @Test(arguments: ["TD", "BT", "LR", "RL"])
    func crossingConnectionsKeepBothLabelsReadable(direction: String) throws {
        let diagram = try #require(AssistantDiagram.parse("""
        flowchart \(direction)
        A
        B
        C
        D
        A -->|Red| D
        B -->|Blue| C
        """))
        try expectClearGeometry(diagram)
    }

    @Test(arguments: ["LR", "RL"])
    func wrappedBranchLabelsHaveSeparatePaddedBounds(direction: String) throws {
        let diagram = try #require(AssistantDiagram.parse("""
        flowchart \(direction)
        A -->|Needs review before sending| B
        A -->|Ready for immediate delivery| C
        """))
        let layout = AssistantDiagramLayout(diagram: diagram)
        #expect(layout.connections.compactMap(\.labelBounds).allSatisfy { $0.height > 24 })
        try expectClearGeometry(diagram)
    }

    @Test(arguments: ["TD", "BT", "LR", "RL"])
    func outsideLanesKeepLongLabelsClearOfRanksAndOtherLabels(direction: String) throws {
        let diagram = try #require(AssistantDiagram.parse("""
        flowchart \(direction)
        A[Start] -->|Review request| B[Review]
        B -->|Needs final approval| C[Confirm]
        C -->|Ready for delivery| D[Send]
        A -->|Bypass lengthy review| D
        E[Alternate] -->|Escalate for review| C
        """))
        try expectClearGeometry(diagram)
    }

    @Test(arguments: ["TD", "BT", "LR", "RL"])
    func aLongNodeKeepsOtherNodesCompactWithoutMovingArrowAnchorsInsideThem(direction: String) throws {
        let diagram = try #require(AssistantDiagram.parse("""
        flowchart \(direction)
        A[Start] --> B[Review the proposal and confirm the final delivery date with the project team]
        A --> D[Wait]
        B -->|Approved| C[Send]
        D --> C
        """))
        let layout = AssistantDiagramLayout(diagram: diagram)
        let long = try #require(layout.nodeBounds["B"])
        let short = try #require(layout.nodeBounds["D"])
        #expect(long.height > short.height)
        #expect(layout.nodeBounds["A"]?.height == short.height)
        #expect(layout.nodeBounds["C"]?.height == short.height)
        try expectClearGeometry(diagram)
    }

    private func expectClearGeometry(_ diagram: AssistantDiagram) throws {
        let layout = AssistantDiagramLayout(diagram: diagram)
        let viewport = CGRect(origin: .zero, size: layout.size)
        #expect(layout.size.width.isFinite && layout.size.height.isFinite)
        let nodes = Array(layout.nodeBounds.values)
        #expect(nodes.count == diagram.nodes.count)
        for (index, node) in nodes.enumerated() {
            #expect(viewport.contains(node))
            for other in nodes.dropFirst(index + 1) { #expect(!node.intersects(other)) }
        }
        let labels = layout.connections.compactMap(\.labelBounds)
        #expect(labels.count == diagram.edges.filter { $0.label != nil }.count)
        for (index, label) in labels.enumerated() {
            #expect(viewport.contains(label))
            for other in labels.dropFirst(index + 1) { #expect(!label.intersects(other)) }
            for node in diagram.nodes {
                #expect(!label.intersects(try nodeBounds(node.id, in: layout)))
            }
        }
        for edge in diagram.edges {
            let connection = try #require(layout.connections.first { $0.id == edge.id })
            let source = try nodeBounds(edge.source, in: layout)
            let target = try nodeBounds(edge.target, in: layout)
            let anchors: (CGPoint, CGPoint)
            switch diagram.direction {
            case .TD, .TB:
                anchors = (CGPoint(x: source.midX, y: source.maxY), CGPoint(x: target.midX, y: target.minY))
            case .BT:
                anchors = (CGPoint(x: source.midX, y: source.minY), CGPoint(x: target.midX, y: target.maxY))
            case .LR:
                anchors = (CGPoint(x: source.maxX, y: source.midY), CGPoint(x: target.minX, y: target.midY))
            case .RL:
                anchors = (CGPoint(x: source.minX, y: source.midY), CGPoint(x: target.maxX, y: target.midY))
            }
            let first = try #require(connection.route.first)
            let last = try #require(connection.route.last)
            #expect(abs(first.x - anchors.0.x) < 0.01 && abs(first.y - anchors.0.y) < 0.01)
            #expect(abs(last.x - anchors.1.x) < 0.01 && abs(last.y - anchors.1.y) < 0.01)
            for node in diagram.nodes where node.id != edge.source && node.id != edge.target {
                let bounds = try nodeBounds(node.id, in: layout).insetBy(dx: 0.01, dy: 0.01)
                for (start, end) in zip(connection.route, connection.route.dropFirst()) {
                    for step in 1..<20 {
                        let fraction = CGFloat(step) / 20
                        let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                            y: start.y + (end.y - start.y) * fraction)
                        #expect(!bounds.contains(point))
                    }
                }
            }
        }
    }

    private func nodeBounds(_ id: String, in layout: AssistantDiagramLayout) throws -> CGRect {
        try #require(layout.nodeBounds[id])
    }
}
