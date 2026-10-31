import AppKit
import SwiftUI

/// Native geometry keeps labels at readable size. Wide branches scroll within the
/// card, while arrows that skip a rank use separate lanes outside the nodes.
struct AssistantDiagramLayout {
    struct Connection: Identifiable {
        let id: Int
        let path: Path
        let arrow: Path
        let label: String?
        let labelPosition: CGPoint
        /// The corner points of `path`. Tests check them against node bounds.
        let route: [CGPoint]
    }
    let size: CGSize
    let nodeSize: CGSize
    let centers: [String: CGPoint]
    let connections: [Connection]
    let labelWidth: CGFloat

    init(diagram: AssistantDiagram) {
        let labelWidth = Tokens.Space.s16
        self.labelWidth = labelWidth
        let nodeWidth = Tokens.Space.s16 + Tokens.Space.s10 + Tokens.Space.s4
        let textWidth = nodeWidth - Tokens.Space.s4
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .medium)
        let nodeHeight = max(Tokens.Space.s12, diagram.nodes.map { node in
            Self.textHeight(node.label, width: textWidth, font: font)
                + Tokens.Space.s4 + (node.shape == .decision ? Tokens.Space.s5 : 0)
        }.max() ?? 0)
        nodeSize = CGSize(width: nodeWidth, height: nodeHeight)
        let labelHeight = diagram.edges.compactMap(\.label).map {
            Self.textHeight($0, width: labelWidth - Tokens.Space.s2,
                            font: .systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .medium))
        }.max() ?? 0
        let horizontal = diagram.direction == .LR || diagram.direction == .RL
        let labelExtent = horizontal && labelHeight > 0 ? labelWidth : labelHeight
        let gap = max(Tokens.Space.s12, labelExtent + Tokens.Space.s4)
        let reversed = diagram.direction == .BT || diagram.direction == .RL
        let ranks = Dictionary(grouping: diagram.nodes, by: { diagram.ranks[$0.id] ?? 0 })
        let rankCount = (diagram.ranks.values.max() ?? 0) + 1
        let slots = ranks.values.map(\.count).max() ?? 1
        let breadth = horizontal ? nodeHeight : nodeWidth
        let depth = horizontal ? nodeWidth : nodeHeight
        let crossSize = CGFloat(slots) * breadth + CGFloat(slots - 1) * Tokens.Space.s4
        let mainSize = CGFloat(rankCount) * depth + CGFloat(rankCount - 1) * gap
        let skipEdges = diagram.edges.filter {
            (diagram.ranks[$0.target] ?? 0) > (diagram.ranks[$0.source] ?? 0) + 1
        }
        let laneWidth = labelWidth + Tokens.Space.s4
        let totalCross = crossSize + CGFloat(skipEdges.count) * laneWidth
        size = horizontal ? CGSize(width: mainSize, height: totalCross) : CGSize(width: totalCross, height: mainSize)
        func point(cross: CGFloat, main: CGFloat) -> CGPoint {
            let position = reversed ? mainSize - main : main
            return horizontal ? CGPoint(x: position, y: cross) : CGPoint(x: cross, y: position)
        }
        var logicalCenters: [String: CGPoint] = [:]
        var centers: [String: CGPoint] = [:]
        for rank in 0..<rankCount {
            let row = ranks[rank] ?? []
            let rowWidth = CGFloat(row.count) * breadth + CGFloat(max(0, row.count - 1)) * Tokens.Space.s4
            for (index, node) in row.enumerated() {
                let cross = (crossSize - rowWidth) / 2 + breadth / 2 + CGFloat(index) * (breadth + Tokens.Space.s4)
                let main = depth / 2 + CGFloat(rank) * (depth + gap)
                logicalCenters[node.id] = CGPoint(x: cross, y: main)
                centers[node.id] = point(cross: cross, main: main)
            }
        }
        self.centers = centers
        connections = diagram.edges.compactMap { edge in
            guard let start = logicalCenters[edge.source], let end = logicalCenters[edge.target] else { return nil }
            let points: [CGPoint]
            let labelPosition: CGPoint
            if let lane = skipEdges.firstIndex(where: { $0.id == edge.id }) {
                let cross = crossSize + laneWidth * (CGFloat(lane) + 0.5)
                let from = start.y + depth / 2
                let to = end.y - depth / 2
                points = [point(cross: start.x, main: from),
                          point(cross: start.x, main: from + gap / 2),
                          point(cross: cross, main: from + gap / 2),
                          point(cross: cross, main: to - gap / 2),
                          point(cross: end.x, main: to - gap / 2), point(cross: end.x, main: to)]
                labelPosition = point(cross: cross, main: (start.y + end.y) / 2)
            } else {
                let from = start.y + depth / 2
                let to = end.y - depth / 2
                points = [point(cross: start.x, main: from),
                          point(cross: start.x, main: from + gap / 4),
                          point(cross: end.x, main: to - gap / 4), point(cross: end.x, main: to)]
                labelPosition = point(cross: (start.x + end.x) / 2, main: (from + to) / 2)
            }
            var path = Path()
            path.addLines(points)
            var arrow = Path()
            if let tip = points.last, points.count >= 2 {
                let previous = points[points.count - 2]
                let angle = atan2(tip.y - previous.y, tip.x - previous.x)
                let length = Tokens.Space.s1_5
                arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: tip.x - length * cos(angle) + length / 2 * sin(angle),
                                         y: tip.y - length * sin(angle) - length / 2 * cos(angle)))
                arrow.addLine(to: CGPoint(x: tip.x - length * cos(angle) - length / 2 * sin(angle),
                                         y: tip.y - length * sin(angle) + length / 2 * cos(angle)))
                arrow.closeSubpath()
            }
            return Connection(id: edge.id, path: path, arrow: arrow, label: edge.label,
                              labelPosition: labelPosition, route: points)
        }
    }

    private static func textHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        ceil((text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                                            attributes: [.font: font]).height)
    }
}
