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
    var normalColor: NSColor = .labelColor
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            guard let pane else { return }
            textField?.textColor = backgroundStyle == .emphasized ? (pane.isActive && pane.window?.isKeyWindow == true ? .white : pane.palette.text) : normalColor
        }
    }
}

final class FileRowView: NSTableRowView {
    weak var pane: PaneView?
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected,let pane else { return }
        let p = pane.palette
        (pane.isActive && isEmphasized ? p.accent : p.inactiveSelection).setFill();bounds.fill(using:.sourceOver)
    }
}

