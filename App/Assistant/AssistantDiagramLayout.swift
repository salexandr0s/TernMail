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
        let labelBounds: CGRect?
        /// The corner points of `path`. Tests check them against node bounds.
        let route: [CGPoint]
    }
    let size: CGSize
    let nodeBounds: [String: CGRect]
    let connections: [Connection]

    private struct LabelTrack {
        var ranges: [ClosedRange<CGFloat>]
        var extent: CGFloat
    }

    private struct LabelSlot {
        let cross: CGFloat
        let track: Int
    }

    init(diagram: AssistantDiagram) {
        let nodeWidth = Tokens.Space.s16 + Tokens.Space.s10 + Tokens.Space.s4
        let font = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .medium)
        let nodeSizes: [String: CGSize] = Dictionary(uniqueKeysWithValues: diagram.nodes.map { node in
            let textWidth = nodeWidth - Tokens.Space.s1_5 * 2
                - (node.shape == .decision ? Tokens.Space.s4 : 0)
            let height = max(Tokens.Space.s8,
                             Self.textHeight(node.label, width: textWidth, font: font) + Tokens.Space.s1_5 * 2)
            return (node.id, CGSize(width: nodeWidth, height: height))
        })
        let labelFont = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .medium)
        let labelSizes: [Int: CGSize] = Dictionary(uniqueKeysWithValues: diagram.edges.compactMap { edge -> (Int, CGSize)? in
            guard let label = edge.label else { return nil }
            let width = min(Tokens.Space.s16 + Tokens.Space.s8,
                            max(Tokens.Space.s8, ceil((label as NSString).size(withAttributes: [.font: labelFont]).width)
                                + Tokens.Space.s2))
            return (edge.id, CGSize(width: width,
                                   height: Self.textHeight(label, width: width - Tokens.Space.s2, font: labelFont)
                                       + Tokens.Space.s1))
        })
        let horizontal = diagram.direction == .LR || diagram.direction == .RL
        let reversed = diagram.direction == .BT || diagram.direction == .RL
        let ranks = Dictionary(grouping: diagram.nodes, by: { diagram.ranks[$0.id] ?? 0 })
        let rankCount = (diagram.ranks.values.max() ?? 0) + 1
        let rankDepths: [CGFloat] = (0..<rankCount).map { rank in
            (ranks[rank] ?? []).compactMap { nodeSizes[$0.id] }.map { horizontal ? $0.width : $0.height }.max() ?? 0
        }
        let rankBreadths: [CGFloat] = (0..<rankCount).map { rank in
            let row = ranks[rank] ?? []
            return row.compactMap { nodeSizes[$0.id] }.reduce(0) { $0 + (horizontal ? $1.height : $1.width) }
                + CGFloat(max(0, row.count - 1)) * Tokens.Space.s3
        }
        let maximumLabelCross = labelSizes.values.map { horizontal ? $0.height : $0.width }.max() ?? 0
        let crossSize = max(rankBreadths.max() ?? 0,
                            maximumLabelCross + Tokens.Space.s4)
        var crossCenters: [String: CGFloat] = [:]
        for rank in 0..<rankCount {
            var cursor = (crossSize - rankBreadths[rank]) / 2
            for node in ranks[rank] ?? [] {
                guard let nodeSize = nodeSizes[node.id] else { continue }
                let breadth = horizontal ? nodeSize.height : nodeSize.width
                crossCenters[node.id] = cursor + breadth / 2
                cursor += breadth + Tokens.Space.s3
            }
        }

        // Labels with overlapping cross-axis ranges use different tracks in
        // their rank gap. Measuring padding here keeps the visible cards clear.
        var labelTracks: [Int: [LabelTrack]] = [:]
        var labelSlots: [Int: LabelSlot] = [:]
        for edge in diagram.edges {
            guard let labelSize = labelSizes[edge.id], let rank = diagram.ranks[edge.source],
                  diagram.ranks[edge.target] == rank + 1,
                  let source = crossCenters[edge.source], let target = crossCenters[edge.target] else { continue }
            let crossExtent = horizontal ? labelSize.height : labelSize.width
            let mainExtent = horizontal ? labelSize.width : labelSize.height
            let cross = min(crossSize - crossExtent / 2, max(crossExtent / 2, (source + target) / 2))
            let range = (cross - crossExtent / 2 - Tokens.Space.s1)...(cross + crossExtent / 2 + Tokens.Space.s1)
            var tracks = labelTracks[rank] ?? []
            let track = tracks.firstIndex { $0.ranges.allSatisfy { !$0.overlaps(range) } } ?? tracks.count
            if track == tracks.count { tracks.append(LabelTrack(ranges: [], extent: mainExtent)) }
            tracks[track].ranges.append(range)
            tracks[track].extent = max(tracks[track].extent, mainExtent)
            labelTracks[rank] = tracks
            labelSlots[edge.id] = LabelSlot(cross: cross, track: track)
        }
        func trackExtent(_ tracks: [LabelTrack]) -> CGFloat {
            tracks.reduce(0) { $0 + $1.extent } + CGFloat(tracks.count + 1) * Tokens.Space.s1
        }
        let gaps = (0..<max(0, rankCount - 1)).map { rank in
            max(Tokens.Space.s5, trackExtent(labelTracks[rank] ?? []))
        }
        let skipEdges = diagram.edges.filter {
            (diagram.ranks[$0.target] ?? 0) > (diagram.ranks[$0.source] ?? 0) + 1
        }
        let maximumSkipLabelMain = skipEdges.compactMap { labelSizes[$0.id] }
            .map { horizontal ? $0.width : $0.height }.max() ?? 0
        let contentMainSize = rankDepths.reduce(0, +) + gaps.reduce(0, +)
        let mainSize = max(contentMainSize, maximumSkipLabelMain + Tokens.Space.s4)
        var mainCenters: [CGFloat] = []
        var mainCursor = (mainSize - contentMainSize) / 2
        for rank in 0..<rankCount {
            mainCenters.append(mainCursor + rankDepths[rank] / 2)
            mainCursor += rankDepths[rank] + (gaps.indices.contains(rank) ? gaps[rank] : 0)
        }
        var laneCenters: [Int: CGFloat] = [:]
        var totalCross = crossSize
        for edge in skipEdges {
            let extent = labelSizes[edge.id].map { horizontal ? $0.height : $0.width } ?? 0
            let laneWidth = max(Tokens.Space.s4, extent) + Tokens.Space.s2
            laneCenters[edge.id] = totalCross + laneWidth / 2
            totalCross += laneWidth
        }
        size = horizontal ? CGSize(width: mainSize, height: totalCross) : CGSize(width: totalCross, height: mainSize)
        func point(cross: CGFloat, main: CGFloat) -> CGPoint {
            let position = reversed ? mainSize - main : main
            return horizontal ? CGPoint(x: position, y: cross) : CGPoint(x: cross, y: position)
        }
        var logicalCenters: [String: CGPoint] = [:]
        var nodeBounds: [String: CGRect] = [:]
        for rank in 0..<rankCount {
            for node in ranks[rank] ?? [] {
                guard let cross = crossCenters[node.id], let nodeSize = nodeSizes[node.id] else { continue }
                let main = mainCenters[rank]
                logicalCenters[node.id] = CGPoint(x: cross, y: main)
                let center = point(cross: cross, main: main)
                nodeBounds[node.id] = CGRect(x: center.x - nodeSize.width / 2, y: center.y - nodeSize.height / 2,
                                            width: nodeSize.width, height: nodeSize.height)
            }
        }
        self.nodeBounds = nodeBounds
        connections = diagram.edges.compactMap { edge -> Connection? in
            guard let start = logicalCenters[edge.source], let end = logicalCenters[edge.target],
                  let sourceSize = nodeSizes[edge.source], let targetSize = nodeSizes[edge.target],
                  let sourceRank = diagram.ranks[edge.source], let targetRank = diagram.ranks[edge.target] else { return nil }
            let from = start.y + (horizontal ? sourceSize.width : sourceSize.height) / 2
            let to = end.y - (horizontal ? targetSize.width : targetSize.height) / 2
            let gapStart = mainCenters[sourceRank] + rankDepths[sourceRank] / 2
            let gapEnd = mainCenters[targetRank] - rankDepths[targetRank] / 2
            let sourceGap = gaps[sourceRank]
            let targetGap = gaps[targetRank - 1]
            let points: [CGPoint]
            let labelPosition: CGPoint
            if let cross = laneCenters[edge.id] {
                points = [point(cross: start.x, main: from),
                          point(cross: start.x, main: gapStart + sourceGap / 2),
                          point(cross: cross, main: gapStart + sourceGap / 2),
                          point(cross: cross, main: gapEnd - targetGap / 2),
                          point(cross: end.x, main: gapEnd - targetGap / 2), point(cross: end.x, main: to)]
                let halfLabel = labelSizes[edge.id].map { (horizontal ? $0.width : $0.height) / 2 } ?? 0
                let middle = min(mainSize - halfLabel - Tokens.Space.s1,
                                 max(halfLabel + Tokens.Space.s1, (start.y + end.y) / 2))
                labelPosition = point(cross: cross, main: middle)
            } else if let slot = labelSlots[edge.id], let tracks = labelTracks[sourceRank] {
                let before = tracks.prefix(slot.track).reduce(0) { $0 + $1.extent + Tokens.Space.s1 }
                let main = gapStart + (sourceGap - trackExtent(tracks)) / 2
                    + Tokens.Space.s1 + before + tracks[slot.track].extent / 2
                labelPosition = point(cross: slot.cross, main: main)
                points = [point(cross: start.x, main: from), labelPosition, point(cross: end.x, main: to)]
            } else {
                points = [point(cross: start.x, main: from),
                          point(cross: start.x, main: gapStart + sourceGap / 4),
                          point(cross: end.x, main: gapEnd - targetGap / 4), point(cross: end.x, main: to)]
                labelPosition = point(cross: (start.x + end.x) / 2, main: (gapStart + gapEnd) / 2)
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
            let labelBounds = labelSizes[edge.id].map {
                CGRect(x: labelPosition.x - $0.width / 2, y: labelPosition.y - $0.height / 2,
                       width: $0.width, height: $0.height)
            }
            return Connection(id: edge.id, path: path, arrow: arrow, label: edge.label,
                              labelBounds: labelBounds, route: points)
        }
    }

    private static func textHeight(_ text: String, width: CGFloat, font: NSFont) -> CGFloat {
        ceil((text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                                            attributes: [.font: font]).height)
    }
}
