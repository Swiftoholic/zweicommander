import AppKit
import CommanderCore

final class FileGrid: NSCollectionView {
    weak var pane: PaneView?
    override func becomeFirstResponder() -> Bool { pane?.activate();let result = super.becomeFirstResponder();DispatchQueue.main.async { [weak self] in self?.pane?.redrawFileFocus() };return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder();DispatchQueue.main.async { [weak self] in self?.pane?.redrawFileFocus() };return result }
    override func mouseDown(with event: NSEvent) {
        let index = indexPathForItem(at:convert(event.locationInWindow,from:nil));pane?.activate();super.mouseDown(with:event);if let index { pane?.focusEntry(at:index.item) }
        if event.clickCount == 2 { pane?.openSelection() }
    }
    override func rightMouseDown(with event: NSEvent) {
        pane?.activate()
        if let index = indexPathForItem(at:convert(event.locationInWindow,from:nil)),!selectionIndexPaths.contains(index) { selectionIndexPaths = [index];pane?.updateStatus() }
        super.rightMouseDown(with:event)
    }
    override func keyDown(with event: NSEvent) {
        if pane?.remote != nil,event.keyCode == 117,event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty { pane?.onCommand?("trash");return }
        if event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
            switch event.keyCode {
            case 48: pane?.onSwitch?();return
            case 36,76: pane?.openSelection();return
            case 51: pane?.goParent();return
            case 49: pane?.onPreview?(pane?.selectedURLs ?? []);return
            case 53: pane?.clearFilter();return
            default: break
            }
        }
        super.keyDown(with:event);if let index = selectionIndexPaths.sorted(by:{$0.item < $1.item}).first { pane?.focusEntry(at:index.item) }
    }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect)
        if pane?.dropOnBackground == true,pane?.dropHint != nil { pane?.palette.accent.setStroke();let ring = NSBezierPath(rect:visibleRect.insetBy(dx:2,dy:2));ring.lineWidth = 2;ring.stroke() }
    }
    override func draggingExited(_ sender:NSDraggingInfo?) { pane?.endFileDrop();super.draggingExited(sender) }
    override func draggingEnded(_ sender:NSDraggingInfo) { pane?.endFileDrop();super.draggingEnded(sender) }
}

final class FileIconItem: NSCollectionViewItem {
    var entryURL: URL?
    var iconRequest: Operation?
    override func prepareForReuse() { super.prepareForReuse();iconRequest?.cancel();iconRequest = nil;entryURL = nil }
    deinit { iconRequest?.cancel() }
    var normalColor: NSColor = .labelColor
    weak var pane: PaneView?
    override func loadView() {
        view = NSView(frame:NSRect(x:0,y:0,width:126,height:112));view.wantsLayer = true;view.layer?.cornerRadius = 7
        let image = NSImageView(frame:NSRect(x:29,y:40,width:68,height:64));image.imageScaling = .scaleProportionallyUpOrDown
        let title = label("",size:12);title.frame = NSRect(x:5,y:3,width:116,height:36);title.maximumNumberOfLines = 2;title.alignment = .center
        title.cell?.wraps = true;title.lineBreakMode = .byTruncatingMiddle
        view.addSubview(image);view.addSubview(title);imageView = image;textField = title
    }
    override var isSelected: Bool { didSet { updateSelection() } }
    override var highlightState: NSCollectionViewItem.HighlightState { didSet { updateSelection() } }
    func updateSelection() {
        guard let pane else { return };let p = pane.palette
        view.layer?.backgroundColor = (isSelected ? (pane.isFileListFocused ? p.accent : p.inactiveSelection) : .clear).cgColor
        textField?.textColor = isSelected ? (pane.isFileListFocused ? .white : p.text) : normalColor
        let drop = !pane.dropOnBackground && pane.dropTargetURL == entryURL,focus = pane.isFileListFocused && pane.focusedEntryURL == entryURL
        view.layer?.borderWidth = drop ? 2 : focus ? 1.5 : 0
        view.layer?.borderColor = (drop ? p.accent : isSelected ? NSColor.white.withAlphaComponent(0.9) : p.accent).cgColor
    }
}

extension PaneView: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func configureIconView() {
        let layout = NSCollectionViewFlowLayout();layout.itemSize = NSSize(width:126,height:112);layout.minimumInteritemSpacing = 8;layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top:10,left:10,bottom:10,right:10)
        grid.collectionViewLayout = layout;grid.pane = self;grid.dataSource = self;grid.delegate = self
        grid.isSelectable = true;grid.allowsMultipleSelection = true;grid.allowsEmptySelection = true;grid.autoresizingMask = [.width]
        grid.register(FileIconItem.self,forItemWithIdentifier:.init("FileIcon"));grid.backgroundColors = [.controlBackgroundColor]
        grid.registerForDraggedTypes([.fileURL]);grid.setDraggingSourceOperationMask(.copy,forLocal:true);grid.setDraggingSourceOperationMask(.copy,forLocal:false)
        grid.menu = table.menu?.copy() as? NSMenu
    }
    func collectionView(_ collectionView: NSCollectionView,numberOfItemsInSection section: Int) -> Int { visibleEntries.count }
    func collectionView(_ collectionView: NSCollectionView,itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier:.init("FileIcon"),for:indexPath)
        guard visibleEntries.indices.contains(indexPath.item) else { return item }
        let entry = visibleEntries[indexPath.item]
        item.textField?.stringValue = entry.name;item.view.toolTip = entry.url.path+(entry.isSymbolicLink ? " (Verknüpfung)" : "")
        if let iconItem = item as? FileIconItem {
            iconItem.iconRequest?.cancel();iconItem.entryURL = entry.url
            let (image,request) = fileImages.load(entry,preview:true) { [weak iconItem] image in guard iconItem?.entryURL == entry.url else { return };iconItem?.imageView?.image = image }
            item.imageView?.image = image;iconItem.iconRequest = request
        }
        if let iconItem = item as? FileIconItem {
            iconItem.pane = self;iconItem.normalColor = fileTextColor(entry.name);iconItem.textField?.font = listFont
            iconItem.updateSelection()
        }
        item.view.setAccessibilityLabel(entry.name);item.view.setAccessibilityRole(.button)
        return item
    }
    func collectionView(_ collectionView: NSCollectionView,didSelectItemsAt indexPaths: Set<IndexPath>) { if !syncingSelection { redrawFileFocus();updateStatus() } }
    func collectionView(_ collectionView: NSCollectionView,didDeselectItemsAt indexPaths: Set<IndexPath>) { if !syncingSelection { redrawFileFocus();updateStatus() } }
    func collectionView(_ collectionView: NSCollectionView,pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard remote == nil,visibleEntries.indices.contains(indexPath.item) else { return nil };return visibleEntries[indexPath.item].url as NSURL
    }
    func collectionView(_ collectionView:NSCollectionView,validateDrop info:NSDraggingInfo,proposedIndexPath:AutoreleasingUnsafeMutablePointer<NSIndexPath>,dropOperation:UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let hit = collectionView.indexPathForItem(at:collectionView.convert(info.draggingLocation,from:nil))
        let index = hit?.item ?? (dropOperation.pointee == .on ? proposedIndexPath.pointee.item : -1),folder = dropFolder(at:index)
        if folder != nil { proposedIndexPath.pointee = IndexPath(item:index,section:0) as NSIndexPath;dropOperation.pointee = .on }
        return updateFileDrop(info.draggingPasteboard,folder:folder)
    }
    func collectionView(_ collectionView:NSCollectionView,acceptDrop info:NSDraggingInfo,indexPath:IndexPath,dropOperation:NSCollectionView.DropOperation) -> Bool {
        acceptFiles(info.draggingPasteboard,into:dropOperation == .on ? dropFolder(at:indexPath.item) : nil)
    }
}
