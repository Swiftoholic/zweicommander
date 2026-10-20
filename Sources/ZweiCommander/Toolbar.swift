import AppKit
import CommanderCore

struct ToolbarCommand {
    let id: String, title: String, symbol: String
    let group: Int
    let tint: NSColor
    static let all: [ToolbarCommand] = [
        .init(id:"back",title:"Zurück",symbol:"arrow.left",group:0,tint:.systemBlue),
        .init(id:"forward",title:"Vorwärts",symbol:"arrow.right",group:0,tint:.systemBlue),
        .init(id:"pack",title:"Packen",symbol:"archivebox",group:1,tint:.systemOrange),
        .init(id:"extract",title:"Entpacken",symbol:"shippingbox",group:1,tint:.systemOrange),
        .init(id:"filter",title:"Filter",symbol:"line.3.horizontal.decrease",group:2,tint:.systemOrange),
        .init(id:"tree",title:"Ordnerbaum",symbol:"list.bullet.indent",group:2,tint:.systemBlue),
        .init(id:"details",title:"Details",symbol:"list.bullet.rectangle",group:3,tint:.systemBlue),
        .init(id:"thumbnails",title:"Miniaturbilder",symbol:"photo.on.rectangle",group:3,tint:.systemTeal),
        .init(id:"icons",title:"Symbole",symbol:"square.grid.2x2",group:3,tint:.systemTeal),
        .init(id:"search",title:"Suchen",symbol:"magnifyingglass",group:4,tint:.systemBlue),
        .init(id:"compare",title:"Vergleichen",symbol:"arrow.left.arrow.right",group:4,tint:.systemBlue),
        .init(id:"batchRename",title:"Mehrfachumbenennen",symbol:"textformat.abc",group:4,tint:.systemPurple),
        .init(id:"quickView",title:"Schnellansicht",symbol:"sidebar.right",group:5,tint:.systemOrange),
        .init(id:"refresh",title:"Neu laden",symbol:"arrow.clockwise",group:5,tint:.systemGreen)
    ]
    static let defaults = all.filter { $0.group != 0 }.map(\.id)
}

struct ToolbarSettings: Codable, Equatable {
    var schemaVersion = 1
    var items = ToolbarCommand.defaults
    func validate() throws {
        let allowed = Set(ToolbarCommand.all.map(\.id))
        guard schemaVersion == 1,items.count == Set(items).count,Set(items).isSubset(of:allowed) else {
            throw CommanderError.message("Die Werkzeugleisten-Konfiguration wird von dieser Version nicht unterstützt.")
        }
    }
}

extension Preferences {
    static let toolbarKey = "ZweiCommander.toolbar.v1"
    static var toolbarTestDefaults: UserDefaults?
    private static var toolbarDefaults: UserDefaults? { testMode ? toolbarTestDefaults : .standard }
    static func toolbarSettings() -> ToolbarSettings {
        guard let data = toolbarDefaults?.data(forKey:toolbarKey),let settings = try? JSONDecoder().decode(ToolbarSettings.self,from:data),
              (try? settings.validate()) != nil else { return ToolbarSettings() }
        return settings
    }
    static func saveToolbar(_ settings: ToolbarSettings) throws {
        try settings.validate()
        if let old = toolbarDefaults?.object(forKey:toolbarKey) {
            guard let data = old as? Data,let value = try? JSONDecoder().decode(ToolbarSettings.self,from:data),
                  (try? value.validate()) != nil else { throw CommanderError.message("Die gespeicherte Werkzeugleiste ist nicht lesbar und wurde nicht ersetzt.") }
        }
        toolbarDefaults?.set(try JSONEncoder().encode(settings),forKey:toolbarKey)
    }
}

final class ToolbarEditorController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let table = CommanderTableView()
    let up = ActionButton("Nach oben",symbol:"arrow.up",action:{})
    let down = ActionButton("Nach unten",symbol:"arrow.down",action:{})
    let reset = ActionButton("Standard",action:{})
    let save = ActionButton("Übernehmen",action:{})
    private(set) var order: [String]
    private(set) var enabled: Set<String>
    var onApply: ((ToolbarSettings) throws -> Void)?
    init(_ settings: ToolbarSettings) {
        order = settings.items+ToolbarCommand.all.map(\.id).filter { !settings.items.contains($0) };enabled = Set(settings.items)
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:540,height:530),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        w.title = "Werkzeugleiste anpassen";w.isReleasedWhenClosed = false
        super.init(window:w)
        let root = CommanderSurface(frame:w.contentView!.bounds);w.contentView = root
        let hint = label("Befehle einblenden und in die gewünschte Reihenfolge bringen.",size:12)
        hint.frame = NSRect(x:20,y:486,width:500,height:24);root.addSubview(hint)
        for (id,title,width) in [("enabled","",CGFloat(42)),("title","Befehl",450)] {
            let column = NSTableColumn(identifier:.init(id));column.title = title;column.width = width;table.addTableColumn(column)
        }
        table.delegate = self;table.dataSource = self;table.rowHeight = 27;table.allowsEmptySelection = false
        let scroll = NSScrollView(frame:NSRect(x:20,y:96,width:500,height:376));scroll.documentView = table;scroll.hasVerticalScroller = true;root.addSubview(scroll)
        up.frame = NSRect(x:20,y:57,width:124,height:28);down.frame = NSRect(x:151,y:57,width:124,height:28)
        up.perform = { [weak self] in self?.move(-1) };down.perform = { [weak self] in self?.move(1) }
        reset.frame = NSRect(x:20,y:16,width:100,height:28);reset.perform = { [weak self] in self?.restoreDefaults() }
        let cancel = ActionButton("Abbrechen",action:{ [weak self] in self?.close() });cancel.frame = NSRect(x:285,y:16,width:110,height:28);cancel.keyEquivalent = "\u{1b}"
        save.frame = NSRect(x:405,y:16,width:115,height:28);save.keyEquivalent = "\r";save.perform = { [weak self] in self?.apply() }
        [up,down,reset,cancel,save].forEach { root.addSubview($0) }
        table.selectRowIndexes([0],byExtendingSelection:false);updateButtons();w.center()
    }
    required init?(coder:NSCoder) { fatalError() }
    func numberOfRows(in tableView:NSTableView) -> Int { order.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
        guard order.indices.contains(row),let item = ToolbarCommand.all.first(where: { $0.id == order[row] }) else { return nil }
        if column?.identifier.rawValue == "enabled" {
            let button = checkbox("",on:enabled.contains(item.id));button.tag = row;button.target = self;button.action = #selector(toggle(_:));button.setAccessibilityLabel(item.title+" einblenden");return button
        }
        return label(item.title)
    }
    @objc func toggle(_ sender:NSButton) { guard order.indices.contains(sender.tag) else { return };let id = order[sender.tag];if sender.state == .on { enabled.insert(id) } else { enabled.remove(id) } }
    func tableViewSelectionDidChange(_ notification:Notification) { updateButtons() }
    func updateButtons() { up.isEnabled = table.selectedRow > 0;down.isEnabled = table.selectedRow >= 0 && table.selectedRow < order.count-1 }
    func move(_ offset:Int) {
        let source = table.selectedRow,target = source+offset
        guard order.indices.contains(source),order.indices.contains(target) else { return }
        order.swapAt(source,target);table.reloadData();table.selectRowIndexes(IndexSet(integer:target),byExtendingSelection:false);table.scrollRowToVisible(target);updateButtons()
    }
    func restoreDefaults() {
        let settings = ToolbarSettings();order = settings.items+ToolbarCommand.all.map(\.id).filter { !settings.items.contains($0) };enabled = Set(settings.items)
        table.reloadData();table.selectRowIndexes([0],byExtendingSelection:false);updateButtons()
    }
    func apply() {
        var settings = ToolbarSettings();settings.items = order.filter { enabled.contains($0) }
        do { try onApply?(settings);close() } catch { showFailure(error) }
    }
}

extension MainWindow {
    func customizeToolbar() {
        let editor = ToolbarEditorController(Preferences.toolbarSettings())
        editor.onApply = { [weak self] settings in try Preferences.saveToolbar(settings);self?.buildToolbar() }
        secondaryWindows.append(editor);editor.showWindow(nil)
    }
    func toolbarOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        for case let button as ActionButton in content.toolbar.arrangedSubviews where button.isHidden {
            guard let id = button.identifier?.rawValue,let command = ToolbarCommand.all.first(where: { $0.id == id }) else { continue }
            let item = NSMenuItem(title:command.title,action:#selector(toolbarMenuChosen(_:)),keyEquivalent:"");item.target = self;item.representedObject = id
            item.state = button.state;item.isEnabled = button.isEnabled;item.image = NSImage(systemSymbolName:command.symbol,accessibilityDescription:nil);menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let item = NSMenuItem(title:"Werkzeugleiste anpassen …",action:#selector(toolbarMenuChosen(_:)),keyEquivalent:"");item.target = self;item.representedObject = "customizeToolbar";menu.addItem(item)
        menu.autoenablesItems = false;return menu
    }
    @objc private func toolbarMenuChosen(_ sender:NSMenuItem) { if let id = sender.representedObject as? String { command(id) } }
}
