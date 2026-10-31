import AppKit
import MessageContent

struct RecipientSuggestion {
    let completion: String
    let title: String
    let subtitle: String
    let address: EmailAddress?
}

/// A nonactivating child window leaves typing and input-method composition in the token field.
@MainActor
final class RecipientSuggestionsPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel = RecipientCompletionWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private weak var owner: NSWindow?
    /// The field the suggestions are for. It shares VoiceOver focus with the list.
    private weak var field: NSTokenField?
    private(set) var rows: [RecipientSuggestion] = []
    var onChoose: ((RecipientSuggestion) -> Void)?
    var onDismiss: (() -> Void)?
    var image: ((EmailAddress) -> NSImage?)?
    var isVisible: Bool { panel.isVisible }
    var selected: RecipientSuggestion? {
        rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
    }

    override init() {
        super.init()
        panel.isReleasedWhenClosed = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.backgroundColor = .windowBackgroundColor
        panel.contentView = scroll
        panel.setAccessibilityLabel("Recipient suggestions")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = table
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = Tokens.Radius.md
        scroll.layer?.masksToBounds = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("recipient"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.rowHeight = Tokens.Space.s8 + Tokens.Space.s1
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.backgroundColor = .windowBackgroundColor
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(chooseClickedRow)
        table.setAccessibilityLabel("Recipient suggestions")
        NotificationCenter.default.addObserver(self, selector: #selector(windowResigned(_:)), name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationResigned), name: NSApplication.didResignActiveNotification, object: nil)
    }

    func show(_ rows: [RecipientSuggestion], for field: NSTokenField, selectFirst: Bool) {
        guard let window = field.window, let editor = field.currentEditor() as? NSTextView,
              !editor.hasMarkedText(), !rows.isEmpty else { close(); return }
        let sameRows = self.rows.map(\.completion) == rows.map(\.completion)
        let oldSelected = table.selectedRow
        self.rows = rows
        table.reloadData()
        let selected = sameRows ? oldSelected : (selectFirst ? 0 : -1)
        table.selectRowIndexes(selected >= 0 ? IndexSet(integer: selected) : [], byExtendingSelection: false)
        let fieldRect = window.convertToScreen(field.convert(field.bounds, to: nil))
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? fieldRect
        let width = min(Tokens.Popover.width, max(visible.width - Tokens.Space.s8, Tokens.Layout.sidebarMinWidth))
        let documentHeight = table.rect(ofRow: rows.count - 1).maxY
        let height = min(Tokens.Popover.maxListHeight, documentHeight)
        let x = min(max(visible.minX + Tokens.Space.s4, fieldRect.minX), visible.maxX - width - Tokens.Space.s4)
        let below = fieldRect.minY - height - Tokens.Space.s1
        let preferredY = below >= visible.minY + Tokens.Space.s4 ? below : fieldRect.maxY + Tokens.Space.s1
        let y = max(visible.minY + Tokens.Space.s4, min(preferredY, visible.maxY - height - Tokens.Space.s4))
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        table.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        scroll.tile()
        table.setFrameSize(NSSize(width: scroll.contentSize.width, height: documentHeight))
        table.tableColumns.first?.width = scroll.contentSize.width
        if owner !== window { owner?.removeChildWindow(panel); owner = window; window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        // VoiceOver stays in the field and follows the highlighted row from there.
        if self.field !== field { self.field?.setAccessibilitySharedFocusElements(nil) }
        self.field = field
        field.setAccessibilitySharedFocusElements([table])
    }

    func close() {
        panel.orderOut(nil)
        owner?.removeChildWindow(panel)
        owner = nil
        field?.setAccessibilitySharedFocusElements(nil)
        field = nil
        rows = []
        table.reloadData()
    }

    func moveSelection(by step: Int) {
        guard !rows.isEmpty else { return }
        let next = table.selectedRow < 0 ? (step > 0 ? 0 : rows.count - 1) : min(rows.count - 1, max(0, table.selectedRow + step))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func refreshAvatars() {
        table.enumerateAvailableRowViews { row, _ in row.needsDisplay = true; row.subviews.forEach { $0.needsDisplay = true } }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell = RecipientSuggestionCell()
        cell.suggestion = rows[row]
        cell.image = image
        cell.selected = table.selectedRow == row
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.enumerateAvailableRowViews { row, index in
            for cell in row.subviews.compactMap({ $0 as? RecipientSuggestionCell }) { cell.selected = index == self.table.selectedRow }
        }
        // The panel never takes focus, so VoiceOver hears about the highlighted row from here.
        NSAccessibility.post(element: table, notification: .selectedRowsChanged)
    }

    @objc private func chooseClickedRow() {
        guard rows.indices.contains(table.clickedRow) else { return }
        onChoose?(rows[table.clickedRow])
    }

    @objc private func windowResigned(_ notification: Notification) {
        if (notification.object as? NSWindow) === owner { onDismiss?() }
    }

    @objc private func applicationResigned() { onDismiss?() }
}

@MainActor
private final class RecipientCompletionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RecipientSuggestionCell: NSView {
    /// The row's text is ready for VoiceOver before the row is drawn.
    var suggestion: RecipientSuggestion? {
        didSet {
            let text = suggestion.map { [$0.title, $0.subtitle].filter { !$0.isEmpty }.joined(separator: " ") }
            toolTip = text
            setAccessibilityElement(text != nil)
            setAccessibilityRole(.staticText)
            setAccessibilityValue(text)
            needsDisplay = true
        }
    }
    var image: ((EmailAddress) -> NSImage?)?
    var selected = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let suggestion else { return }
        let avatar = NSRect(x: Tokens.Space.s2, y: bounds.midY - Tokens.Space.s5 / 2, width: Tokens.Space.s5, height: Tokens.Space.s5)
        if let address = suggestion.address {
            RecipientAvatarDrawing.draw(image: image?(address), address: address, in: avatar)
        } else {
            NSImage(systemSymbolName: "person.3", accessibilityDescription: nil)?.draw(in: avatar)
        }
        let emphasized = (superview as? NSTableRowView)?.isEmphasized == true
        let selectedColor = emphasized ? NSColor.alternateSelectedControlTextColor : .unemphasizedSelectedTextColor
        let color = selected ? selectedColor : .labelColor
        let secondary = selected ? selectedColor : .secondaryLabelColor
        let start = avatar.maxX + Tokens.Space.s2
        let titleY = suggestion.subtitle.isEmpty ? bounds.midY - Tokens.Space.s4 / 2 : Tokens.Space.s0_5
        let titleRect = NSRect(x: start, y: titleY, width: max(0, bounds.width - start - Tokens.Space.s3), height: Tokens.Space.s4)
        let subtitleRect = titleRect.offsetBy(dx: 0, dy: Tokens.Space.s4)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (suggestion.title as NSString).draw(in: titleRect, withAttributes: [.font: NSFont.preferredFont(forTextStyle: .callout), .foregroundColor: color, .paragraphStyle: paragraph])
        (suggestion.subtitle as NSString).draw(in: subtitleRect, withAttributes: [.font: NSFont.preferredFont(forTextStyle: .caption1), .foregroundColor: secondary, .paragraphStyle: paragraph])
    }
}
