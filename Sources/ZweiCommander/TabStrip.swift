import AppKit

final class FolderTabButton: NSButton, NSDraggingSource {
    private var hoverTracking: NSTrackingArea?
    private var hovered = false
    private var fileDrop = false
    private let hoverOpen = HoverOpen()
    static let dragType = NSPasteboard.PasteboardType("local.zweicommander.folder-tab")
    weak var pane: PaneView?
    let tabID: UUID
    let closeButton = ActionButton("",symbol:"xmark",action:{})
    init(title: String,tab: FolderTab,pane: PaneView) {
        tabID = tab.id;self.pane = pane;super.init(frame:.zero);self.title = title
        target = self;action = #selector(choose);controlSize = .small;registerForDraggedTypes([Self.dragType,.fileURL])
        isBordered = false
        closeButton.flat = true;closeButton.symbolTint = .secondaryLabelColor;CommandHelp.apply(closeButton,id:"closeTab",title:"Diesen Tab schließen")
        closeButton.setAccessibilityLabel("Tab schließen: "+title);closeButton.perform = { [weak self] in guard let self else { return };self.pane?.closeTab(self.tabID) }
        closeButton.isHidden = tab.locked || pane.tabs.count == 1;addSubview(closeButton)
        let menu = NSMenu()
        for (title,command) in [("Tab duplizieren","duplicateTab"),("Auf andere Seite kopieren","copyTabToOther"),("Geschlossenen Tab wieder öffnen","reopenTab"),("Tabgruppen …","tabGroups"),("Tab schließen","closeTab"),("Andere Tabs schließen","closeOtherTabs"),("Tab sperren/entsperren","lockTab"),("Tab benennen …","nameTab"),("Nach links verschieben","moveTabLeft"),("Nach rechts verschieben","moveTabRight")] {
            let item = NSMenuItem(title:title,action:#selector(run(_:)),keyEquivalent:"");item.target = self;item.representedObject = command;menu.addItem(item)
        }
        self.menu = menu
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(title:String,tab:FolderTab,active:Bool) {
        self.title = title;state = active ? .on : .off;font = .systemFont(ofSize:12,weight:active ? .semibold : .regular)
        closeButton.isHidden = tab.locked || pane?.tabs.count == 1;closeButton.setAccessibilityLabel("Tab schließen: "+title)
        toolTip = tab.remote == nil ? tab.url.path+"\nDateien hier ablegen; kurzes Verweilen öffnet den Tab." : tab.url.absoluteString+"\nServer-Tab für diese Sitzung. F5/F6 übertragen zwischen den beiden Seiten."
        invalidateIntrinsicContentSize();needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas();if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInActiveApp,.inVisibleRect],owner:self,userInfo:nil);hoverTracking = area;addTrackingArea(area)
    }
    override func mouseEntered(with event:NSEvent) { hovered = true;needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hovered = false;needsDisplay = true }
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes:[.font:font ?? NSFont.systemFont(ofSize:11)]).width
        return NSSize(width:max(80,min(220,width+45)),height:25)
    }
    override func layout() { super.layout();closeButton.frame = NSRect(x:bounds.width-23,y:2,width:20,height:21) }
    override func draw(_ dirtyRect: NSRect) {
        let p = CommanderPalette.current(in:self),selected = state == .on
        (selected ? p.activeTab : hovered ? p.hover : p.chrome).setFill();bounds.fill(using:.sourceOver)
        if selected { (pane?.isActive == true ? p.accent : p.separator).setFill();NSRect(x:0,y:0,width:bounds.width,height:2).fill(using:.sourceOver) }
        p.separator.setFill();NSRect(x:bounds.maxX-1,y:0,width:1,height:bounds.height).fill(using:.sourceOver)
        if fileDrop { p.accent.setStroke();let ring = NSBezierPath(rect:bounds.insetBy(dx:1.5,dy:1.5));ring.lineWidth = 2;ring.stroke() }
        let paragraph = NSMutableParagraphStyle();paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key:Any] = [.font:font ?? NSFont.systemFont(ofSize:11),.foregroundColor:p.text,.paragraphStyle:paragraph]
        (title as NSString).draw(in:NSRect(x:7,y:(bounds.height-16)/2,width:max(1,bounds.width-(closeButton.isHidden ? 13 : 31)),height:16),withAttributes:attributes)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();needsDisplay = true }
    @objc func choose() { pane?.selectTab(tabID) }
    @objc func run(_ item: NSMenuItem) {
        guard let pane,let command = item.representedObject as? String else { return }
        pane.selectTab(tabID)
        // Closing a contextual tab never closes the application window.
        if command == "closeTab" { pane.closeTab() } else { pane.onCommand?(command) }
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching:[.leftMouseUp,.leftMouseDragged]) {
            if next.type == .leftMouseUp { choose();return }
            if hypot(next.locationInWindow.x-start.x,next.locationInWindow.y-start.y) > 5 {
                let writer = NSPasteboardItem();writer.setString(tabID.uuidString,forType:Self.dragType)
                let item = NSDraggingItem(pasteboardWriter:writer)
                let image = NSImage(size:bounds.size);image.lockFocus();draw(bounds);image.unlockFocus()
                item.setDraggingFrame(bounds,contents:image);beginDraggingSession(with:[item],event:next,source:self);return
            }
        }
    }
    func draggingSession(_ session: NSDraggingSession,sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func draggedID(_ sender: NSDraggingInfo) -> UUID? {
        guard let source = sender.draggingSource as? FolderTabButton,source.pane === pane,
              let value = sender.draggingPasteboard.string(forType:Self.dragType),let id = UUID(uuidString:value),
              pane?.tabs.contains(where: { $0.id == id }) == true else { return nil };return id
    }
    override func draggingEntered(_ sender:NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender:NSDraggingInfo) -> NSDragOperation {
        if draggedID(sender) != nil { return .move }
        guard let pane,let target = pane.tabs.first(where:{ $0.id == tabID }),target.archiveRoot == nil,target.remote == nil,!pane.fileURLs(sender.draggingPasteboard).isEmpty else { clearFileDrop();return [] }
        fileDrop = true;needsDisplay = true
        pane.dropHint = target.collection == nil ? "Kopieren in Tab „"+(target.title ?? target.url.lastPathComponent)+"“ · Loslassen öffnet die Vorschau" : "Verweise zum Sammlungstab hinzufügen"
        pane.updateStatus()
        if pane.tab.id != tabID {
            hoverOpen.update(tabID.uuidString) { [weak self,weak pane] in guard let self,self.fileDrop else { return };pane?.selectTab(self.tabID) }
        }
        return .copy
    }
    private func clearFileDrop() { hoverOpen.cancel();if fileDrop { fileDrop = false;needsDisplay = true;pane?.endFileDrop() } }
    override func draggingExited(_ sender:NSDraggingInfo?) { clearFileDrop() }
    override func draggingEnded(_ sender:NSDraggingInfo) { clearFileDrop() }
    override func performDragOperation(_ sender:NSDraggingInfo) -> Bool {
        defer { clearFileDrop() }
        guard let pane else { return false }
        if let id = draggedID(sender),let old = pane.tabs.firstIndex(where:{ $0.id == id }),let target = pane.tabs.firstIndex(where:{ $0.id == tabID }) {
            let after = convert(sender.draggingLocation,from:nil).x >= bounds.midX,insertion = target+(after ? 1 : 0)
            pane.moveTab(id,to:insertion-(old < insertion ? 1 : 0));return true
        }
        return pane.acceptFiles(sender.draggingPasteboard,tabID:tabID)
    }

}

extension PaneView {
    func selectTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        endPathEditing(restoreFocus:false)
        tabIndex = index;filterField.stringValue = "";restoreTabView();rebuildTabs();refresh();focus()
        if remote == nil,tab.archiveRoot == nil,tab.collection == nil { lastLocalTabID = tab.id }
    }
    func stepTab(_ offset: Int) { selectTab(tabs[(tabIndex+offset+tabs.count)%tabs.count].id) }
    func moveTab(_ id: UUID,to index: Int) {
        guard let old = tabs.firstIndex(where: { $0.id == id }),tabs.indices.contains(index),old != index else { return }
        let activeID = tab.id,item = tabs.remove(at:old);tabs.insert(item,at:index)
        tabIndex = tabs.firstIndex(where: { $0.id == activeID })!;rebuildTabs()
    }
    func duplicateTab() {
        let original = tab,t = FolderTab(original.url)
        t.title = original.title;t.history = original.history;t.position = original.position;t.view = original.view
        t.collection = original.collection;t.archiveRoot = original.archiveRoot;t.archiveOrigin = original.archiveOrigin
        if let remote = original.remote { t.remote = RemoteFolderSession(remote.connection) }
        tabs.insert(t,at:tabIndex+1);tabIndex += 1;restoreTabView();rebuildTabs();refresh();focus()
    }
    func closeOtherTabs() {
        let current = tab
        for item in tabs where item !== current && !item.locked { rememberClosedTab(item) }
        tabs.removeAll { $0 !== current && !$0.locked };tabIndex = tabs.firstIndex(where: { $0 === current })!
        rebuildTabs();refresh();focus()
    }
}
