import AppKit
import SwiftUI

struct AssistantDiagramView: View {
    let diagram: AssistantDiagram
    let source: String
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showsSource = false
    @State private var showsFullDiagram = false
    @State private var graphViewportWidth: CGFloat?

    var body: some View {
        let layout = AssistantDiagramLayout(diagram: diagram)
        let overflowsWidth = graphViewportWidth.map { layout.size.width > $0 } ?? false
        let isPreview = overflowsWidth || layout.size.height + Tokens.Space.s1 > Tokens.AssistantFormatting.diagramPreviewHeight
        VStack(alignment: .leading, spacing: Tokens.AssistantFormatting.blockGap) {
            HStack(spacing: Tokens.Space.s1) {
                Label("Flowchart", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(Tokens.AssistantFormatting.metadataFont).foregroundStyle(.secondary)
                Spacer(minLength: Tokens.Space.s1)
                if isPreview, !showsSource {
                    Button("Open full diagram") { showsFullDiagram = true }
                        .font(Tokens.AssistantFormatting.metadataFont)
                        .buttonStyle(.borderless).controlSize(.small)
                        .accessibilityLabel("Open full diagram")
                }
                Button(showsSource ? "Show diagram" : "Show source", systemImage: showsSource ? "point.3.connected.trianglepath.dotted" : "chevron.left.forwardslash.chevron.right") {
                    showsSource.toggle()
                }
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .controlSize(.small)
                .help(showsSource ? "Show diagram" : "Show source")
                Button("Copy diagram source", systemImage: "doc.on.doc") {
                    NSPasteboard.general.replaceContents(with: source)
                }
                .frame(width: Tokens.Space.s6, height: Tokens.Space.s6)
                .labelStyle(.iconOnly).buttonStyle(.borderless).controlSize(.small)
                .help("Copy diagram source")
            }
            if showsSource {
                ScrollView([.horizontal, .vertical]) {
                    Text(source).font(Tokens.AssistantFormatting.codeFont)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.bottom, Tokens.Space.s1)
                }
                .frame(height: sourceHeight)
            } else {
                GeometryReader { viewport in
                    ScrollView([.horizontal, .vertical]) {
                        graph(layout)
                            .padding(.bottom, Tokens.Space.s1)
                            .frame(minWidth: viewport.size.width)
                    }
                }
                .frame(height: min(layout.size.height + Tokens.Space.s1, Tokens.AssistantFormatting.diagramPreviewHeight))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { graphViewportWidth = $0 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Flowchart")
                .accessibilityValue(diagram.accessibleDescription)
                .accessibilityHint(isPreview ? "Scrollable preview. Open the full diagram to use a larger view." : "")
            }
        }
        .lineSpacing(0)
        .padding(Tokens.AssistantFormatting.inset)
        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.AssistantFormatting.cornerRadius))
        .ternOutline(radius: Tokens.AssistantFormatting.cornerRadius)
        .sheet(isPresented: $showsFullDiagram) { fullDiagram(layout) }
    }

    private var sourceHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        let height = ceil((source as NSString).size(withAttributes: [.font: font]).height) + Tokens.Space.s1
        return min(Tokens.AssistantFormatting.diagramPreviewHeight, max(Tokens.Space.s6, height))
    }

    private func fullDiagram(_ layout: AssistantDiagramLayout) -> some View {
        VStack(spacing: Tokens.AssistantFormatting.blockGap) {
            HStack {
                Label("Flowchart", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(Tokens.AssistantFormatting.titleFont)
                Spacer()
                Button("Close") { showsFullDiagram = false }
                    .buttonStyle(.bordered).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            GeometryReader { viewport in
                ScrollView([.horizontal, .vertical]) {
                    graph(layout)
                        .padding(Tokens.AssistantFormatting.inset)
                        .frame(minWidth: viewport.size.width, minHeight: viewport.size.height)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Full flowchart")
                .accessibilityValue(diagram.accessibleDescription)
            }
        }
        .padding(Tokens.AssistantFormatting.inset)
        .frame(width: min(Tokens.Assistant.contentWidth, max(Tokens.Assistant.sidebarMinWidth, layout.size.width + Tokens.Space.s4)),
               height: min(Tokens.Layout.windowHeight - Tokens.Space.s16,
                           max(Tokens.AssistantFormatting.diagramPreviewHeight + Tokens.Space.s16, layout.size.height + Tokens.Space.s16)))
        .background(Tokens.Surface.primary)
    }

    private func graph(_ layout: AssistantDiagramLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.connections) { connection in
                connection.path
                    .stroke(contrast == .increased ? Color.primary : Color.secondary,
                            style: StrokeStyle(lineWidth: Tokens.Border.hairline, lineCap: .round, lineJoin: .round))
                connection.arrow.fill(contrast == .increased ? Color.primary : Color.secondary)
            }
            ForEach(layout.connections) { connection in
                if let label = connection.label, let bounds = connection.labelBounds {
                    Text(label)
                        .font(Tokens.AssistantFormatting.metadataFont.weight(.medium)).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Tokens.Space.s1)
                        .padding(.vertical, Tokens.Space.s0_5)
                        .frame(width: bounds.width, height: bounds.height)
                        .background(Tokens.Surface.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                        .position(x: bounds.midX, y: bounds.midY)
                }
            }
            ForEach(diagram.nodes) { node in
                if let bounds = layout.nodeBounds[node.id] {
                    nodeView(node)
                        .frame(width: bounds.width, height: bounds.height)
                        .position(x: bounds.midX, y: bounds.midY)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private func nodeView(_ node: AssistantDiagram.Node) -> some View {
        HStack(spacing: Tokens.Space.s1) {
            if node.shape == .decision {
                Image(systemName: "diamond").font(Tokens.AssistantFormatting.metadataFont)
                    .frame(width: Tokens.Space.s3)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            Text(node.label).font(Tokens.AssistantFormatting.supportingFont.weight(.medium))
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(Tokens.Space.s1_5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(node.shape == .decision ? Tokens.Assistant.userBubble : Tokens.Surface.primary,
                    in: RoundedRectangle(cornerRadius: node.shape == .rounded ? Tokens.Radius.lg : Tokens.Radius.sm))
        .ternOutline(radius: node.shape == .rounded ? Tokens.Radius.lg : Tokens.Radius.sm)
    }
}
