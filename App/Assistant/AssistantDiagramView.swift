import AppKit
import SwiftUI

struct AssistantDiagramView: View {
    let diagram: AssistantDiagram
    let source: String
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showsSource = false

    var body: some View {
        let layout = AssistantDiagramLayout(diagram: diagram)
        VStack(alignment: .leading, spacing: Tokens.Space.s3) {
            HStack(spacing: Tokens.Space.s2) {
                Label("Flowchart", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer(minLength: Tokens.Space.s2)
                Button(showsSource ? "Show diagram" : "Show source", systemImage: showsSource ? "point.3.connected.trianglepath.dotted" : "chevron.left.forwardslash.chevron.right") {
                    showsSource.toggle()
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .help(showsSource ? "Show diagram" : "Show source")
                Button("Copy diagram source", systemImage: "doc.on.doc") {
                    NSPasteboard.general.replaceContents(with: source)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Copy diagram source")
            }
            if showsSource {
                ScrollView(.horizontal) {
                    Text(source).font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.bottom, Tokens.Space.s2)
                }
            } else {
                GeometryReader { viewport in
                    ScrollView(.horizontal) {
                        graph(layout)
                            .padding(.bottom, Tokens.Space.s2)
                            .frame(minWidth: viewport.size.width)
                    }
                }
                .frame(height: layout.size.height + Tokens.Space.s2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Flowchart")
                .accessibilityValue(diagram.accessibleDescription)
            }
        }
        .lineSpacing(0)
        .padding(Tokens.Space.s3)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .ternOutline(radius: Tokens.Radius.md)
    }

    private func graph(_ layout: AssistantDiagramLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.connections) { connection in
                connection.path
                    .stroke(contrast == .increased ? Color.primary : Color.secondary,
                            style: StrokeStyle(lineWidth: Tokens.Border.hairline, lineCap: .round, lineJoin: .round))
                connection.arrow.fill(contrast == .increased ? Color.primary : Color.secondary)
                if let label = connection.label {
                    Text(label)
                        .font(.caption2.weight(.medium)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Tokens.Space.s1)
                        .padding(.vertical, Tokens.Space.s0_5)
                        .frame(width: layout.labelWidth)
                        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                        .position(connection.labelPosition)
                }
            }
            ForEach(diagram.nodes) { node in
                nodeView(node)
                    .frame(width: layout.nodeSize.width, height: layout.nodeSize.height)
                    .position(layout.centers[node.id] ?? .zero)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private func nodeView(_ node: AssistantDiagram.Node) -> some View {
        VStack(spacing: Tokens.Space.s1) {
            if node.shape == .decision {
                Image(systemName: "diamond").font(.caption2).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            Text(node.label).font(.callout.weight(.medium))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(node.shape == .decision ? Tokens.Assistant.userBubble : Tokens.Surface.primary,
                    in: RoundedRectangle(cornerRadius: node.shape == .rounded ? Tokens.Radius.lg : Tokens.Radius.sm))
        .ternOutline(radius: node.shape == .rounded ? Tokens.Radius.lg : Tokens.Radius.sm)
    }
}
