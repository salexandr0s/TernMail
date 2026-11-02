import AppKit

/// Reads the hosted window's native accessibility graph for page layout checks.
@MainActor enum WorkspaceAuditAccessibility {
    static func elements(in root: NSView) -> [Element] {
        var seen = Set<ObjectIdentifier>()
        func visit(_ item: Any) -> [Element] {
            guard let object = item as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            if let view = object as? NSView {
                guard !view.isHiddenOrHasHiddenAncestor else { return [] }
                var ancestor: NSView? = view
                while let current = ancestor {
                    guard current.alphaValue > 0.01 else { return [] }
                    ancestor = current.superview
                }
            }
            let element = Element(object: object)
            let children = element.children + NSAccessibility.unignoredChildren(from: element.children)
                + ((object as? NSView)?.subviews ?? [])
            return [element] + children.flatMap(visit)
        }
        return visit(root)
    }

    static func matching(_ identifier: String, in window: NSWindow) -> [Element] {
        guard let root = window.contentView else { return [] }
        return elements(in: root).filter { $0.identifier == identifier && $0.isVisible(in: window) }
    }

    static func frame(of identifier: String, in window: NSWindow) -> NSRect? {
        matching(identifier, in: window).map { $0.frame(in: window) }.reduce(Optional<NSRect>.none) { union, frame in
            union.map { $0.union(frame) } ?? frame
        }
    }

    @MainActor struct Element {
        let object: NSObject

        private func value(_ key: String) -> Any? {
            object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
        }

        var children: [Any] {
            value("accessibilityChildren") as? [Any] ?? object.accessibilityAttributeValue(.children) as? [Any] ?? []
        }
        var identifier: String? {
            value("accessibilityIdentifier") as? String ?? object.accessibilityAttributeValue(.identifier) as? String
        }
        var label: String? {
            value("accessibilityLabel") as? String ?? object.accessibilityAttributeValue(.description) as? String
                ?? object.accessibilityAttributeValue(.title) as? String
        }
        var role: String? {
            value("accessibilityRole") as? String ?? object.accessibilityAttributeValue(.role) as? String
        }
        var isSelected: Bool {
            value("isAccessibilitySelected") as? Bool
                ?? object.accessibilityAttributeValue(.selected) as? Bool ?? false
        }
        func diagnosticDescription(in window: NSWindow) -> String {
            let enabled = value("isAccessibilityEnabled") as? Bool
                ?? object.accessibilityAttributeValue(.enabled) as? Bool
            return "\(type(of: object)) id=\(identifier ?? "none") role=\(role ?? "none") frame=\(frame(in: window)) visible=\(isVisible(in: window)) enabled=\(enabled.map(String.init) ?? "unknown") press=\(supportsPress) actions=\(object.accessibilityActionNames())"
        }
        var supportsPress: Bool {
            object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
                || object.accessibilityActionNames().contains(.press)
        }

        func frame(in window: NSWindow) -> NSRect {
            let screenFrame: NSRect
            if let frame = value("accessibilityFrame") as? NSValue { screenFrame = frame.rectValue }
            else if let origin = object.accessibilityAttributeValue(.position) as? NSValue,
                    let size = object.accessibilityAttributeValue(.size) as? NSValue {
                screenFrame = NSRect(origin: origin.pointValue, size: size.sizeValue)
            } else { return .zero }
            return window.convertFromScreen(screenFrame)
        }

        func isVisible(in window: NSWindow) -> Bool {
            let frame = frame(in: window)
            return !frame.isEmpty && window.contentLayoutRect.insetBy(dx: -1, dy: -1).contains(frame)
        }

        func hasHitTarget(in window: NSWindow) -> Bool {
            guard isVisible(in: window), let content = window.contentView else { return false }
            let bounds = frame(in: window)
            let point = NSPoint(x: bounds.midX, y: bounds.midY)
            let root = content.superview ?? content
            let routedPoint = root.superview?.convert(point, from: nil) ?? point
            guard let hit = root.hitTest(routedPoint) else { return false }
            return hit === content || hit.isDescendant(of: content)
        }

        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            if object.responds(to: selector), let implementation = object.method(for: selector) {
                // SwiftUI AX nodes expose AppKit's public BOOL action through this ABI.
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                return unsafeBitCast(implementation, to: Press.self)(object, selector)
            }
            guard object.accessibilityActionNames().contains(.press) else { return false }
            object.accessibilityPerformAction(.press)
            return true
        }
    }
}
