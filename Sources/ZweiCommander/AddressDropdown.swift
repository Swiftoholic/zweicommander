import AppKit

struct AddressSuggestion {
    let url: URL
    let title: String
    let detail: String
    var history = false
}

private final class AddressPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class AddressTable: NSTableView {
    var choose: ((Int)->Void)?
    private var hoverTracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas();if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect:.zero,options:[.mouseMoved,.activeInActiveApp,.inVisibleRect],owner:self,userInfo:nil);hoverTracking = area;addTrackingArea(area)
    }
    override func mouseMoved(with event:NSEvent) {
        let index = row(at:convert(event.locationInWindow,from:nil))
        if index >= 0 && index != selectedRow { selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
    }
    override func mouseDown(with event:NSEvent) {
        let index = row(at:convert(event.locationInWindow,from:nil))
        if index >= 0 { choose?(index) }
    }
}

private final class AddressRow: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
    override func drawSelection(in dirtyRect:NSRect) {
        CommanderPalette.current(in:self).activePath.setFill();bounds.fill(using:.sourceOver)
    }
}

private final class AddressCell: NSTableCellView {
    let icon = NSImageView(),name = label("",size:12),detail = label("",size:10,color:.secondaryLabelColor)
    override init(frame:NSRect) {
        super.init(frame:frame);[icon,name,detail].forEach { addSubview($0) }
        name.lineBreakMode = .byTruncatingMiddle;detail.lineBreakMode = .byTruncatingMiddle
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout();icon.frame = NSRect(x:10,y:11,width:16,height:16)
        name.frame = NSRect(x:34,y:19,width:max(1,bounds.width-42),height:16)
        detail.frame = NSRect(x:34,y:3,width:max(1,bounds.width-42),height:14)
    }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();updateColors() }
    func updateColors() {
        let selected = backgroundStyle == .emphasized,p = CommanderPalette.current(in:self)
        name.textColor = selected ? .white : p.text;detail.textColor = selected ? NSColor.white.withAlphaComponent(0.86) : p.secondaryText
        icon.contentTintColor = selected ? .white : .systemBlue
    }
}

/// A nonactivating child window keeps typing and text selection in the address field.
final class AddressDropdown: NSObject,NSTableViewDataSource,NSTableViewDelegate {
    private let panel = AddressPanel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
    private let surface = CommanderSurface(frame:.zero),heading = label("",size:11,weight:.medium),footer = label("",size:10,color:.secondaryLabelColor)
    private let table = AddressTable(),scroll = NSScrollView()
    private weak var anchor: NSView?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private var keyboard = false
    private(set) var rows: [AddressSuggestion] = []
    var onChoose: ((AddressSuggestion)->Void)?
    var onDismiss: (()->Void)?
    var isVisible: Bool { panel.isVisible }
    var selectedIndex: Int { table.selectedRow }
    var contentView: NSView { surface }
    override init() {
        super.init()
        panel.isReleasedWhenClosed = false;panel.hidesOnDeactivate = true;panel.hasShadow = true;panel.backgroundColor = .windowBackgroundColor
        panel.becomesKeyOnlyIfNeeded = true;panel.isMovable = false;panel.contentView = surface
        surface.wantsLayer = true;surface.layer?.borderWidth = 1;surface.layer?.cornerRadius = 5;surface.layer?.masksToBounds = true
        let col = NSTableColumn(identifier:.init("folder"));table.addTableColumn(col);table.headerView = nil;table.rowHeight = 38;table.intercellSpacing = .zero
        table.style = .plain;table.selectionHighlightStyle = .regular;table.allowsEmptySelection = true;table.focusRingType = .none;table.dataSource = self;table.delegate = self
        table.setAccessibilityLabel("Ordnervorschläge")
        table.choose = { [weak self] index in self?.choose(index) }
        scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.autohidesScrollers = true;scroll.drawsBackground = false
        [heading,scroll,footer].forEach { surface.addSubview($0) }
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) };if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
    func show(under view:NSView,title:String,rows:[AddressSuggestion] = [],message:String? = nil,error:Bool = false,keyboard:Bool = false) {
        guard let parent = view.window,parent.isVisible,parent.isKeyWindow,NSApp.isActive else { return }
        if anchor !== view || panel.parent !== parent || !isVisible {
            close();anchor = view;self.keyboard = keyboard;parent.addChildWindow(panel,ordered:.above)
            for notification in [NSWindow.didMoveNotification,NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName:notification,object:parent,queue:.main) { [weak self] _ in self?.position() })
            }
            for notification in [NSWindow.didResignKeyNotification,NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName:notification,object:parent,queue:.main) { [weak self] _ in self?.dismiss() })
            }
            observers.append(NotificationCenter.default.addObserver(forName:NSApplication.didResignActiveNotification,object:nil,queue:.main) { [weak self] _ in self?.dismiss() })
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.keyDown]) { [weak self,weak parent,weak view] event in
                guard let self,self.isVisible else { return event }
                if event.type == .keyDown {
                    guard self.keyboard,event.modifierFlags.intersection([.command,.control,.option]).isEmpty else { return event }
                    switch event.keyCode {
                    case 125: self.moveSelection(1);return nil
                    case 126: self.moveSelection(-1);return nil
                    case 36,76: self.chooseSelected();return nil
                    case 53: self.dismiss();return nil
                    case 48: self.dismiss();return event
                    default: return event
                    }
                }
                if event.window !== self.panel {
                    // Clicking the anchor again is handled by the owner as a toggle.
                    let inside = event.window === parent && view.map { $0.bounds.contains($0.convert(event.locationInWindow,from:nil)) } == true
                    if !inside { self.dismiss() }
                }
                return event
            }
        }
        self.rows = rows;table.reloadData();table.deselectAll(nil)
        heading.stringValue = message ?? title;heading.maximumNumberOfLines = 3;heading.lineBreakMode = .byWordWrapping;heading.textColor = error ? .systemRed : CommanderPalette.current(in:surface).text
        heading.toolTip = message ?? title
        footer.stringValue = error ? "Adresse prüfen · Esc schließen" : keyboard ? "↑↓ auswählen · ↵ öffnen · Esc schließen" : "↑↓ auswählen · Tab ergänzen · ↵ öffnen · Esc schließen"
        table.backgroundColor = CommanderPalette.current(in:surface).chrome
        surface.layer?.borderColor = CommanderPalette.current(in:surface).separator.cgColor
        surface.setAccessibilityLabel(title);surface.setAccessibilityHelp(footer.stringValue)
        position();panel.orderFront(nil)
    }
    private func position() {
        guard let anchor,let parent = anchor.window else { close();return }
        let rect = parent.convertToScreen(anchor.convert(anchor.bounds,to:nil)),screen = parent.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? rect.insetBy(dx:-500,dy:-500)
        let width = min(screen.width-16,min(580,max(350,anchor.bounds.width))),headingHeight:CGFloat = rows.isEmpty ? 54 : 26,height = CGFloat(min(7,rows.count))*38+32+headingHeight
        let x = max(screen.minX+8,min(rect.minX,screen.maxX-width-8))
        let below = rect.minY-height-3,y = below >= screen.minY+8 ? below : min(screen.maxY-height-8,rect.maxY+3)
        panel.setFrame(NSRect(x:x,y:y,width:width,height:height),display:true)
        heading.frame = NSRect(x:12,y:height-headingHeight,width:width-24,height:headingHeight-7)
        scroll.frame = NSRect(x:1,y:27,width:width-2,height:CGFloat(min(7,rows.count))*38)
        footer.frame = NSRect(x:12,y:6,width:width-24,height:15)
        table.tableColumns[0].width = max(1,scroll.contentSize.width);table.frame.size.width = scroll.contentSize.width
    }
    func moveSelection(_ delta:Int) {
        guard !rows.isEmpty else { return }
        let index = selectedIndex < 0 ? (delta < 0 ? rows.count-1 : 0) : max(0,min(rows.count-1,selectedIndex+delta))
        select(index)
    }
    func select(_ index:Int) {
        guard rows.indices.contains(index) else { table.deselectAll(nil);return }
        table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);table.scrollRowToVisible(index)
    }
    func chooseSelected() { if selectedIndex >= 0 { choose(selectedIndex) } }
    func choose(_ index:Int) { guard rows.indices.contains(index) else { return };let item = rows[index];close();onChoose?(item) }
    func dismiss() { close();onDismiss?() }
    func close() {
        panel.orderOut(nil);panel.parent?.removeChildWindow(panel)
        observers.forEach { NotificationCenter.default.removeObserver($0) };observers = []
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) };eventMonitor = nil;anchor = nil
    }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableView(_ tableView:NSTableView,rowViewForRow row:Int) -> NSTableRowView? { AddressRow() }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        let cell = AddressCell(frame:.zero),item = rows[row]
        cell.name.stringValue = item.title;cell.detail.stringValue = item.detail;cell.toolTip = item.url.path
        cell.icon.image = NSImage(systemSymbolName:item.history ? "clock.arrow.circlepath" : "folder",accessibilityDescription:nil)
        cell.setAccessibilityLabel(item.title+" · "+item.detail);cell.updateColors();return cell
    }
}
