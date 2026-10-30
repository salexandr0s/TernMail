import Foundation

/// A small, inert Mermaid subset. Unsupported input stays visible as source code.
struct AssistantDiagram: Equatable {
    enum Direction: String { case TD, TB, BT, LR, RL }
    enum Shape: Equatable { case rectangle, rounded, decision }
    struct Node: Identifiable, Equatable {
        let id: String
        var label: String
        var shape: Shape
        var isDeclared: Bool
    }
    struct Edge: Identifiable, Equatable {
        let id: Int
        let source: String
        let target: String
        let label: String?
    }

    let direction: Direction
    let nodes: [Node]
    let edges: [Edge]
    /// Longest-path ranks keep every arrow moving toward its destination.
    let ranks: [String: Int]

    static func parse(_ source: String) -> AssistantDiagram? {
        guard source.utf8.count <= 8_192 else { return nil }
        let lines = source.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count <= 40, let first = lines.first else { return nil }
        let header = first.trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            .split(whereSeparator: \.isWhitespace)
        guard header.count == 2, ["flowchart", "graph"].contains(String(header[0])),
              let direction = Direction(rawValue: String(header[1])) else { return nil }
        var nodes: [Node] = []
        var edges: [Edge] = []
        for line in lines.dropFirst() {
            var scanner = Scanner(text: line)
            guard let firstNode = scanner.node(), register(firstNode, in: &nodes) else { return nil }
            var previous = firstNode.id
            while !scanner.isAtEnd {
                if scanner.take(";") { guard scanner.isAtEnd else { return nil }; break }
                guard scanner.take("-->") else { return nil }
                let label: String?
                if scanner.take("|") {
                    guard let value = scanner.label(until: "|", limit: 32) else { return nil }
                    label = value
                } else { label = nil }
                guard let next = scanner.node(), register(next, in: &nodes), previous != next.id,
                      edges.count < 12 else { return nil }
                // Duplicate edges with conflicting labels are ambiguous, so show the source.
                guard !edges.contains(where: { $0.source == previous && $0.target == next.id }) else { return nil }
                edges.append(Edge(id: edges.count, source: previous, target: next.id, label: label))
                previous = next.id
            }
        }
        guard nodes.count >= 2, !edges.isEmpty,
              let ranks = rank(nodes: nodes, edges: edges) else { return nil }
        return AssistantDiagram(direction: direction, nodes: nodes, edges: edges, ranks: ranks)
    }

    var accessibleDescription: String {
        let labels = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.label) })
        let relationships = edges.map { edge in
            let condition = edge.label.map { ", \($0)," } ?? ""
            return "\(labels[edge.source] ?? edge.source)\(condition) leads to \(labels[edge.target] ?? edge.target)."
        }
        let isolated = nodes.filter { node in
            !edges.contains { $0.source == node.id || $0.target == node.id }
        }.map { "\($0.label), unconnected." }
        return (relationships + isolated).joined(separator: " ")
    }

    private static func register(_ node: Node, in nodes: inout [Node]) -> Bool {
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            if node.isDeclared {
                guard !nodes[index].isDeclared || nodes[index] == node else { return false }
                nodes[index] = node
            }
        } else {
            guard nodes.count < 8 else { return false }
            nodes.append(node)
        }
        return true
    }

    private static func rank(nodes: [Node], edges: [Edge]) -> [String: Int]? {
        var incoming = Dictionary(uniqueKeysWithValues: nodes.map { node in
            (node.id, edges.filter { $0.target == node.id }.count)
        })
        var ranks = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        var queue = nodes.filter { incoming[$0.id] == 0 }.map(\.id)
        var processed = 0
        while processed < queue.count {
            let source = queue[processed]
            processed += 1
            for edge in edges where edge.source == source {
                ranks[edge.target] = max(ranks[edge.target] ?? 0, (ranks[source] ?? 0) + 1)
                incoming[edge.target, default: 0] -= 1
                if incoming[edge.target] == 0 { queue.append(edge.target) }
            }
        }
        return processed == nodes.count ? ranks : nil
    }

    private struct Scanner {
        var text: Substring
        init(text: String) { self.text = Substring(text) }
        var isAtEnd: Bool { text.allSatisfy(\.isWhitespace) }

        mutating func take(_ token: String) -> Bool {
            trim()
            guard text.hasPrefix(token) else { return false }
            text.removeFirst(token.count)
            return true
        }

        mutating func node() -> Node? {
            trim()
            guard let first = text.first, first.isASCII, first.isLetter else { return nil }
            let identifier = text.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            guard identifier.count <= 32 else { return nil }
            text.removeFirst(identifier.count)
            trim()
            let shape: Shape
            let close: Character
            if take("[") { shape = .rectangle; close = "]" }
            else if take("(") { shape = .rounded; close = ")" }
            else if take("{") { shape = .decision; close = "}" }
            else { return Node(id: String(identifier), label: String(identifier), shape: .rectangle, isDeclared: false) }
            guard let value = label(until: close, limit: 80) else { return nil }
            return Node(id: String(identifier), label: value, shape: shape, isDeclared: true)
        }

        mutating func label(until close: Character, limit: Int) -> String? {
            guard let end = text.firstIndex(of: close) else { return nil }
            var value = String(text[..<end]).trimmingCharacters(in: .whitespaces)
            text = text[text.index(after: end)...]
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst(); value.removeLast()
            }
            let forbidden = CharacterSet(charactersIn: "<>[]{}()|`\\\"")
                .union(.controlCharacters)
            guard !value.isEmpty, value.count <= limit,
                  value.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
            return value
        }

        private mutating func trim() { text = text.drop(while: \.isWhitespace) }
    }
}
