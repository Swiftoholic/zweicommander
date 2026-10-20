import AppKit

final class CommanderSplitView: NSSplitView {
    static let gripThickness: CGFloat = 5
    override var dividerThickness: CGFloat { 36 }
    var dividerFrame: NSRect {
        guard arrangedSubviews.count == 2,!arrangedSubviews.contains(where: \.isHidden) else { return .zero }
        let first = arrangedSubviews[0].frame
        return isVertical ? NSRect(x:first.maxX,y:bounds.minY,width:dividerThickness,height:bounds.height) : NSRect(x:bounds.minX,y:first.maxY,width:bounds.width,height:dividerThickness)
    }
    func resizeGrip(in rect:NSRect) -> NSRect {
        guard !rect.isEmpty else { return .zero }
        return isVertical ? NSRect(x:rect.minX,y:rect.minY,width:Self.gripThickness,height:rect.height) : NSRect(x:rect.minX,y:rect.minY,width:rect.width,height:Self.gripThickness)
    }
    var actionStripFrame: NSRect {
        let rect = dividerFrame,offset = Self.gripThickness+1
        guard !rect.isEmpty else { return .zero }
        return isVertical ? NSRect(x:rect.minX+offset,y:rect.minY,width:rect.width-offset,height:rect.height) : NSRect(x:rect.minX,y:rect.minY+offset,width:rect.width,height:rect.height-offset)
    }
    override func drawDivider(in rect: NSRect) {
        let palette = CommanderPalette.current(in:self)
        palette.chrome.setFill();rect.fill(using:.sourceOver)
        palette.separator.withAlphaComponent(0.55).setFill()
        if isVertical {
            for x in [rect.minX,rect.minX+Self.gripThickness,rect.maxX-1] { NSRect(x:x,y:rect.minY,width:1,height:rect.height).fill(using:.sourceOver) }
        } else {
            for y in [rect.minY,rect.minY+Self.gripThickness,rect.maxY-1] { NSRect(x:rect.minX,y:y,width:rect.width,height:1).fill(using:.sourceOver) }
        }
    }
    override func resetCursorRects() {
        let grip = resizeGrip(in:dividerFrame)
        if !grip.isEmpty { addCursorRect(grip,cursor:isVertical ? .resizeLeftRight : .resizeUpDown) }
    }
    override func mouseDown(with event:NSEvent) {
        guard resizeGrip(in:dividerFrame).contains(convert(event.locationInWindow,from:nil)) else { return }
        super.mouseDown(with:event)
    }
}

final class SplitActionRail: CommanderSurface {
    var vertical = true { didSet { needsLayout = true } }
    var buttons: [ActionButton] = []
    override func resetCursorRects() { addCursorRect(bounds,cursor:.arrow) }
    override func cursorUpdate(with event:NSEvent) { NSCursor.arrow.set() }
    override func draw(_ dirtyRect:NSRect) {
        super.draw(dirtyRect);CommanderPalette.current(in:self).separator.withAlphaComponent(0.55).setFill()
        let edge = vertical ? NSRect(x:bounds.maxX-1,y:bounds.minY,width:1,height:bounds.height) : NSRect(x:bounds.minX,y:bounds.minY,width:bounds.width,height:1)
        edge.fill(using:.sourceOver)
    }
    func configure(_ items: [(String,String,String)],perform: @escaping (String)->Void) {
        for (title,symbol,id) in items {
            let b = ActionButton("",symbol:symbol,action:{ perform(id) });b.flat = true;b.identifier = .init(id);CommandHelp.apply(b,id:id,title:title)
            b.symbolTint = id == "sameFolder" ? .systemOrange : id == "trash" ? .systemRed : id == "compare" ? .systemPurple : .systemBlue
            buttons.append(b);addSubview(b)
        }
    }
    override func layout() {
        super.layout()
        let extent = vertical ? bounds.height : bounds.width
        let step = min(28,max(0,(extent-28)/CGFloat(max(1,buttons.count-1))))
        var previous: CGFloat = -step+14
        for (i,b) in buttons.enumerated() {
            let id = b.identifier?.rawValue
            let desired: CGFloat
            switch id {
            case "swap": desired = 38
            case "compare": desired = extent*0.23
            case "sameFolder": desired = extent*0.43
            case "linked": desired = extent*0.43+28
            case "orientation": desired = extent*0.63
            case "onePane": desired = extent*0.63+28
            default: desired = extent-16
            }
            let center = max(previous+step,min(desired,extent-14-CGFloat(buttons.count-1-i)*step));previous = center
            b.frame = vertical ? NSRect(x:(bounds.width-24)/2,y:extent-center-12,width:24,height:24) : NSRect(x:center-12,y:(bounds.height-24)/2,width:24,height:24)
        }
    }
}

final class LocationStrip: NSScrollView {
    let stack = NSStackView()
    var onChoose: ((URL)->Void)?
    private var items: [(String,URL)] = []
    private var current: URL?
    override init(frame: NSRect) {
        super.init(frame:frame);drawsBackground = false;hasHorizontalScroller = false;autohidesScrollers = true
        stack.orientation = .horizontal;stack.spacing = 2;stack.alignment = .centerY;documentView = stack
    }
    required init?(coder:NSCoder) { fatalError() }
    func configure(_ places: [(String,URL)]) {
        items = places
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0);$0.removeFromSuperview() }
        for (name,url) in items {
            let symbol = url.path == "/" ? "internaldrive" : url.path.hasPrefix("/Volumes/") ? "externaldrive" : "folder"
            let b = ActionButton(name,symbol:symbol,action:{ [weak self] in self?.onChoose?(url) });b.flat = true;b.font = .systemFont(ofSize:11);b.setHelp(name,"Diesen Ort auf dieser Seite öffnen.\n"+url.path);b.identifier = .init(url.path)
            b.widthAnchor.constraint(equalToConstant:min(150,max(58,b.intrinsicContentSize.width))).isActive = true
            b.heightAnchor.constraint(equalToConstant:23).isActive = true;stack.addArrangedSubview(b)
        }
        stack.frame = NSRect(x:0,y:0,width:max(bounds.width,stack.fittingSize.width),height:24);select(current)
    }
    func select(_ url: URL?) {
        current = url
        let path = url?.standardizedFileURL.path ?? ""
        let match = items.enumerated().filter { path == $0.element.1.path || path.hasPrefix($0.element.1.path == "/" ? "/" : $0.element.1.path+"/") }.max { $0.element.1.path.count < $1.element.1.path.count }?.offset
        for (i,view) in stack.arrangedSubviews.enumerated() { (view as? NSButton)?.state = i == match ? .on : .off }
    }
    override func layout() { super.layout();stack.frame.size = NSSize(width:max(bounds.width,stack.fittingSize.width),height:24) }
}

final class BreadcrumbBar: NSView {
    var active = false { didSet { updateColors() } }
    var showHiddenFolders = false
    var onChoose: ((URL)->Void)?
    var onEdit: (()->Void)?
    private(set) var components: [(URL,ActionButton)] = []
    private(set) var childButtons: [(URL,ActionButton)] = []
    let more = ActionButton("…",action:{})
    let dropdown = AddressDropdown()
    private var request = 0
    private weak var openAnchor: ActionButton?
    private var acceptingDrop = false
    var url: URL? { didSet { if oldValue != url { rebuild() } } }
    override init(frame: NSRect) {
        super.init(frame:frame);wantsLayer = false;more.flat = true
        more.setHelp("Übergeordnete Ordner","Die vollständige Ordnerhierarchie anzeigen, auch ausgeblendete Pfadsegmente.")
        more.perform = { [weak self] in self?.showAncestors() };addSubview(more)
        dropdown.onChoose = { [weak self] item in self?.request += 1;self?.onChoose?(item.url) }
        dropdown.onDismiss = { [weak self] in self?.request += 1;self?.openAnchor = nil }
        registerForDraggedTypes([.fileURL]);setAccessibilityLabel("Ordnerpfad")
    }
    required init?(coder:NSCoder) { fatalError() }
    private func rebuild() {
        request += 1;dropdown.close();openAnchor = nil
        (components+childButtons).forEach { $0.1.removeFromSuperview() };components = [];childButtons = []
        toolTip = (url?.path ?? "")+"\nLeeren Bereich anklicken oder ⌘L drücken, um die Adresse zu bearbeiten."
        menu = contextMenu(for:url)
        if var current = url {
            var urls = [current]
            while current.path != "/" { let parent = current.deletingLastPathComponent();if parent == current { break };urls.insert(parent,at:0);current = parent }
            for url in urls {
                let title = url.path == "/" ? "/" : url.lastPathComponent
                let button = ActionButton(title,action:{ [weak self] in self?.onChoose?(url) });button.flat = true;button.font = .systemFont(ofSize:11)
                button.setHelp(title,"Diesen Ordner öffnen.\n"+url.path);button.menu = contextMenu(for:url)
                addSubview(button);components.append((url,button))
                let arrow = ActionButton("",symbol:"chevron.right",action:{})
                arrow.flat = true;arrow.symbolTint = .secondaryLabelColor;arrow.setHelp("Unterordner von "+title,"Unterordner auswählen, ohne die Adresse einzutippen.\n"+url.path)
                arrow.perform = { [weak self,weak arrow] in if let arrow { self?.showChildren(of:url,from:arrow) } }
                addSubview(arrow);childButtons.append((url,arrow))
            }
        }
        updateColors();needsLayout = true
    }
    func showChildren(of folder:URL,from button:ActionButton) {
        if dropdown.isVisible && openAnchor === button { request += 1;dropdown.close();openAnchor = nil;return }
        request += 1;let generation = request,original = url,hidden = showHiddenFolders;openAnchor = button
        dropdown.show(under:button,title:"Unterordner werden gelesen …",keyboard:true)
        DispatchQueue.global(qos:.userInitiated).async { [weak self,weak button] in
            let result = Result { try FolderAddress.folders(in:folder,showHidden:hidden) }
            DispatchQueue.main.async {
                guard let self,let button,self.request == generation,self.url == original,self.dropdown.isVisible else { return }
                switch result {
                case .success(let value):
                    self.dropdown.show(under:button,title:value.limited ? "200 Unterordner · zum Eingrenzen Adresse bearbeiten" : "Unterordner · "+(folder.lastPathComponent.isEmpty ? "/" : folder.lastPathComponent),rows:value.items,message:value.items.isEmpty ? "Keine Unterordner" : nil,keyboard:true)
                    if let index = value.items.firstIndex(where:{ $0.url == self.url || self.url?.path.hasPrefix($0.url.path+"/") == true }) { self.dropdown.select(index) }
                case .failure(let error): self.dropdown.show(under:button,title:"Unterordner",message:error.localizedDescription,error:true,keyboard:true)
                }
            }
        }
    }
    @objc private func chooseAncestor(_ item: NSMenuItem) { if let url = item.representedObject as? URL { onChoose?(url) } }
    private func showAncestors() {
        request += 1;dropdown.close()
        let menu = NSMenu()
        for (url,_) in components { let item = NSMenuItem(title:url.path,action:#selector(chooseAncestor(_:)),keyEquivalent:"");item.target = self;item.representedObject = url;menu.addItem(item) }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:bounds.height),in:self)
    }
    func contextMenu(for folder:URL?) -> NSMenu {
        let menu = NSMenu()
        for (title,action) in [("Adresse bearbeiten",#selector(editAddress(_:))),("Ordnerpfad kopieren",#selector(copyAddress(_:))),("Ordner im Finder öffnen",#selector(openInFinder(_:)))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:"");item.target = self;item.representedObject = folder;menu.addItem(item)
        }
        return menu
    }
    @objc private func editAddress(_ item:NSMenuItem) { dropdown.close();onEdit?() }
    @objc private func copyAddress(_ item:NSMenuItem) {
        guard let folder = item.representedObject as? URL else { return }
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(folder.path,forType:.string)
    }
    @objc private func openInFinder(_ item:NSMenuItem) { if let folder = item.representedObject as? URL { NSWorkspace.shared.open(folder) } }
    override func layout() {
        super.layout();let available = max(0,bounds.width-4)
        let widths = components.map { min(170,$0.1.intrinsicContentSize.width)+18 }
        var start = 0,total = widths.reduce(0,+)
        while start < components.count-1 && total > available-(start == 0 ? 0 : 26) { total -= widths[start];start += 1 }
        more.isHidden = start == 0;more.frame = NSRect(x:2,y:0,width:24,height:bounds.height)
        var x: CGFloat = start == 0 ? 2 : 27
        for (i,item) in components.enumerated() {
            let arrow = childButtons[i].1
            item.1.isHidden = i < start;arrow.isHidden = i < start
            guard i >= start else { continue }
            let width = min(170,min(item.1.intrinsicContentSize.width,max(1,bounds.width-x-20)))
            item.1.frame = NSRect(x:x,y:0,width:width,height:bounds.height);x += width
            arrow.frame = NSRect(x:x,y:0,width:min(18,max(0,bounds.width-x-2)),height:bounds.height);x += 18
        }
    }
    override func mouseDown(with event:NSEvent) { request += 1;dropdown.close();onEdit?() }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.iBeam) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();if window == nil { request += 1;dropdown.close() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();updateColors() }
    override func draw(_ dirtyRect: NSRect) {
        let p = CommanderPalette.current(in:self);(active ? p.activePath : p.chrome).setFill();bounds.fill(using:.sourceOver)
        if acceptingDrop { p.accent.setStroke();let ring = NSBezierPath(rect:bounds.insetBy(dx:1,dy:1));ring.lineWidth = 2;ring.stroke() }
    }
    func updateColors() {
        let p = CommanderPalette.current(in:self);layer?.backgroundColor = (active ? p.activePath : p.chrome).cgColor
        ([more]+components.map { $0.1 }+childButtons.map { $0.1 }).forEach { $0.state = active ? .on : .off;$0.needsDisplay = true };needsDisplay = true
    }
    func droppedFolder(from pasteboard:NSPasteboard) -> URL? {
        guard let values = pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],values.count == 1,values[0].isFileURL else { return nil }
        var directory:ObjCBool = false
        return FileManager.default.fileExists(atPath:values[0].path,isDirectory:&directory) && directory.boolValue ? values[0] : nil
    }
    override func draggingEntered(_ sender:NSDraggingInfo) -> NSDragOperation { acceptingDrop = droppedFolder(from:sender.draggingPasteboard) != nil;needsDisplay = true;return acceptingDrop ? .link : [] }
    override func draggingUpdated(_ sender:NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender:NSDraggingInfo?) { acceptingDrop = false;needsDisplay = true }
    override func performDragOperation(_ sender:NSDraggingInfo) -> Bool {
        acceptingDrop = false;needsDisplay = true
        guard let folder = droppedFolder(from:sender.draggingPasteboard) else { return false };onChoose?(folder);return true
    }
}
