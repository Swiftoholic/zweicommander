import AppKit

final class CommanderHeaderCell: NSTableHeaderCell {
    override func drawInterior(withFrame cellFrame: NSRect,in controlView: NSView) {
        NSGraphicsContext.saveGraphicsState();defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingTail
        let rect = NSRect(x:cellFrame.minX+5,y:cellFrame.midY-7,width:max(1,cellFrame.width-18),height:16)
        (stringValue as NSString).draw(in:rect,withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:CommanderPalette.current(in:controlView).text,.paragraphStyle:paragraph])
    }
}

final class FileCellView: NSTableCellView {
    weak var pane: PaneView?
    var entryURL: URL?
    var normalColor: NSColor = .labelColor
    var iconRequest: Operation?
    override func prepareForReuse() { super.prepareForReuse();iconRequest?.cancel();iconRequest = nil;entryURL = nil }
    deinit { iconRequest?.cancel() }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }
    func updateColors() {
        guard let pane else { return }
        textField?.textColor = backgroundStyle == .emphasized ? (pane.isFileListFocused ? .white : pane.palette.text) : normalColor
    }
}

final class FileRowView: NSTableRowView {
    weak var pane: PaneView?
    var entryURL: URL?
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
    override func drawBackground(in dirtyRect:NSRect) { super.drawBackground(in:dirtyRect);drawIndicators() }
    override func drawSelection(in dirtyRect:NSRect) {
        guard isSelected,let pane else { return }
        (pane.isFileListFocused ? pane.palette.accent : pane.palette.inactiveSelection).setFill();bounds.fill(using:.sourceOver);drawIndicators()
    }
    private func drawIndicators() {
        guard let pane else { return };let p = pane.palette,drop = !pane.dropOnBackground && pane.dropTargetURL == entryURL
        if drop || (pane.isFileListFocused && pane.focusedEntryURL == entryURL) {
            (drop ? p.accent : isSelected ? NSColor.white.withAlphaComponent(0.9) : p.accent).setStroke()
            let ring = NSBezierPath(rect:bounds.insetBy(dx:drop ? 1.5 : 1,dy:1));ring.lineWidth = drop ? 2 : 1;ring.stroke()
        }
    }
}

extension PaneView {
    var isFileListFocused: Bool {
        guard isActive,window?.isKeyWindow == true else { return false }
        return window?.firstResponder === table || window?.firstResponder === grid || inlineRename.isEditing
    }
    func focusEntry(at index:Int) {
        guard visibleEntries.indices.contains(index) else { return };focusedEntryURL = visibleEntries[index].url;redrawFileFocus()
    }
    func redrawFileFocus() {
        table.needsDisplay = true;grid.needsDisplay = true
        table.enumerateAvailableRowViews { view,index in
            view.needsDisplay = true
            if let row = view as? FileRowView { row.entryURL = self.visibleEntries.indices.contains(index) ? self.visibleEntries[index].url : nil }
            for column in self.table.tableColumns.indices {
                if let cell = self.table.view(atColumn:column,row:index,makeIfNecessary:false) as? FileCellView,self.visibleEntries.indices.contains(index) {
                    cell.normalColor = self.fileTextColor(self.visibleEntries[index].name,secondary:column != self.table.column(withIdentifier:.init("name")));cell.updateColors()
                }
            }
        }
        for case let item as FileIconItem in grid.visibleItems() { item.normalColor = fileTextColor(item.textField?.stringValue ?? "");item.updateSelection() }
    }
}
