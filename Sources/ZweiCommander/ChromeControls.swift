import AppKit

final class CommanderSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 30 }
    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in:rect)
    }
}

final class SplitActionRail: CommanderSurface {
    var vertical = true { didSet { needsLayout = true } }
    var buttons: [ActionButton] = []
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point);return hit === self ? nil : hit
    }
    func configure(_ items: [(String,String,String)],perform: @escaping (String)->Void) {
        for (title,symbol,id) in items {
            let b = ActionButton("",symbol:symbol,action:{ perform(id) });b.flat = true;b.toolTip = title;b.identifier = .init(id);b.setAccessibilityLabel(title)
            buttons.append(b);addSubview(b)
        }
    }
    override func layout() {
        super.layout()
        for (i,b) in buttons.enumerated() {
            b.frame = vertical ? NSRect(x:3,y:bounds.height-30-CGFloat(i)*34,width:24,height:26) : NSRect(x:8+CGFloat(i)*34,y:2,width:26,height:26)
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
            let b = ActionButton(name,symbol:symbol,action:{ [weak self] in self?.onChoose?(url) });b.flat = true;b.font = .systemFont(ofSize:11);b.toolTip = url.path;b.identifier = .init(url.path)
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
    var onChoose: ((URL)->Void)?
    var onEdit: (()->Void)?
    private(set) var components: [(URL,ActionButton)] = []
    let more = ActionButton("…",action:{})
    var url: URL? { didSet { rebuild() } }
    override init(frame: NSRect) {
        super.init(frame:frame);wantsLayer = false;more.flat = true;more.toolTip = "Übergeordnete Ordner";more.setAccessibilityLabel("Übergeordnete Ordner")
        more.perform = { [weak self] in self?.showAncestors() };addSubview(more)
    }
    required init?(coder:NSCoder) { fatalError() }
    private func rebuild() {
        components.forEach { $0.1.removeFromSuperview() };components = [];toolTip = url?.path
        if var current = url {
            var urls = [current]
            while current.path != "/" { let parent = current.deletingLastPathComponent();if parent == current { break };urls.insert(parent,at:0);current = parent }
            for (i,url) in urls.enumerated() {
                let title = (url.path == "/" ? "/" : url.lastPathComponent)+(i == urls.count-1 ? "" : " ›")
                let b = ActionButton(title,action:{ [weak self] in self?.onChoose?(url) });b.flat = true;b.font = .systemFont(ofSize:11);b.toolTip = url.path;b.setAccessibilityLabel(url.path);addSubview(b);components.append((url,b))
            }
        }
        updateColors();needsLayout = true
    }
    @objc private func chooseAncestor(_ item: NSMenuItem) { if let url = item.representedObject as? URL { onChoose?(url) } }
    private func showAncestors() {
        let menu = NSMenu()
        for (url,_) in components { let item = NSMenuItem(title:url.path,action:#selector(chooseAncestor(_:)),keyEquivalent:"");item.target = self;item.representedObject = url;menu.addItem(item) }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:bounds.height),in:self)
    }
    override func layout() {
        super.layout();let available = max(0,bounds.width-4)
        var start = 0,total = components.reduce(CGFloat(0)) { $0+min(185,$1.1.intrinsicContentSize.width) }
        while start < components.count-1 && total > available-26 { total -= min(185,components[start].1.intrinsicContentSize.width);start += 1 }
        more.isHidden = start == 0;more.frame = NSRect(x:2,y:0,width:24,height:bounds.height)
        var x: CGFloat = start == 0 ? 2 : 27
        for (i,item) in components.enumerated() {
            item.1.isHidden = i < start
            guard i >= start else { continue }
            let width = min(185,min(item.1.intrinsicContentSize.width,max(1,bounds.width-x-2)))
            item.1.frame = NSRect(x:x,y:0,width:width,height:bounds.height);x += width
        }
    }
    override func mouseDown(with event: NSEvent) { if event.clickCount == 2 { onEdit?() } else { super.mouseDown(with:event) } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();updateColors() }
    override func draw(_ dirtyRect: NSRect) { let p = CommanderPalette.current(in:self);(active ? p.activePath : p.chrome).setFill();bounds.fill(using:.sourceOver) }
    func updateColors() {
        let p = CommanderPalette.current(in:self);layer?.backgroundColor = (active ? p.activePath : p.chrome).cgColor
        ([more]+components.map { $0.1 }).forEach { $0.state = active ? .on : .off;$0.needsDisplay = true };needsDisplay = true
    }
}

final class PathEditor: NSTextField {
    var onCancel: (()->Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
