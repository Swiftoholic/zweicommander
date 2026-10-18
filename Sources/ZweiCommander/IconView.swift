import AppKit
import ImageIO
import CommanderCore

final class FileGrid: NSCollectionView {
    weak var pane: PaneView?
    override func becomeFirstResponder() -> Bool { pane?.activate();return super.becomeFirstResponder() }
    override func mouseDown(with event: NSEvent) {
        pane?.activate();super.mouseDown(with:event)
        if event.clickCount == 2 { pane?.openSelection() }
    }
    override func rightMouseDown(with event: NSEvent) {
        pane?.activate()
        if let index = indexPathForItem(at:convert(event.locationInWindow,from:nil)),!selectionIndexPaths.contains(index) { selectionIndexPaths = [index];pane?.updateStatus() }
        super.rightMouseDown(with:event)
    }
    override func keyDown(with event: NSEvent) {
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
        super.keyDown(with:event)
    }
}

final class FileIconItem: NSCollectionViewItem {
    var normalColor: NSColor = .labelColor
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
        view.layer?.backgroundColor = (isSelected ? NSColor.selectedContentBackgroundColor : .clear).cgColor
        textField?.textColor = isSelected ? .alternateSelectedControlTextColor : normalColor
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
        item.imageView?.image = fileIcon(entry,preview:true)
        if let iconItem = item as? FileIconItem {
            iconItem.normalColor = importedProfile?.fileColors.first(where: { $0.matches(entry.name) })?.color.nsColor ?? importedProfile?.foreground?.nsColor ?? .labelColor
            iconItem.updateSelection()
        }
        item.view.setAccessibilityLabel(entry.name);item.view.setAccessibilityRole(.button)
        return item
    }
    func fileIcon(_ entry: FileEntry,preview: Bool) -> NSImage {
        let key = entry.url.path+"|\(entry.modified.timeIntervalSince1970)|\(entry.size)|\(preview)"
        if let cached = icons[key] { return cached }
        var result = NSWorkspace.shared.icon(forFile:entry.url.path)
        if preview,!entry.isDirectory,!entry.isSymbolicLink,entry.size < 10_000_000,
           ["png","jpg","jpeg","gif","heic","tif","tiff","webp"].contains(entry.fileExtension.lowercased()),
           let source = CGImageSourceCreateWithURL(entry.url as CFURL,nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:144] as CFDictionary) {
            result = NSImage(cgImage:image,size:NSSize(width:image.width,height:image.height))
        }
        if icons.count > 1500 { icons.removeAll() };icons[key] = result;return result
    }
    func collectionView(_ collectionView: NSCollectionView,didSelectItemsAt indexPaths: Set<IndexPath>) { if !syncingSelection { updateStatus() } }
    func collectionView(_ collectionView: NSCollectionView,didDeselectItemsAt indexPaths: Set<IndexPath>) { if !syncingSelection { updateStatus() } }
    func collectionView(_ collectionView: NSCollectionView,pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard visibleEntries.indices.contains(indexPath.item) else { return nil };return visibleEntries[indexPath.item].url as NSURL
    }
    func collectionView(_ collectionView: NSCollectionView,validateDrop draggingInfo: NSDraggingInfo,proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        readOnly ? [] : .copy
    }
    func collectionView(_ collectionView: NSCollectionView,acceptDrop draggingInfo: NSDraggingInfo,indexPath: IndexPath,dropOperation: NSCollectionView.DropOperation) -> Bool {
        acceptFiles(draggingInfo.draggingPasteboard)
    }
    @discardableResult func acceptFiles(_ pasteboard: NSPasteboard) -> Bool {
        guard !readOnly,let urls = pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty else { return false }
        if tab.collection != nil { onCollectionDrop?(urls) } else { onDrop?(urls,currentURL) };return true
    }
}
