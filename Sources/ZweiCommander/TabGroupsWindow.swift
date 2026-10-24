import AppKit
import CommanderCore

struct TabSessionState: Equatable {
    let id:UUID,path:String,title:String?,locked:Bool,view:FolderViewSettings?,kind:String
}
struct TabGroupContext: Equatable {
    let left:[TabSessionState],right:[TabSessionState]
    let leftSelected:UUID?,rightSelected:UUID?
}

final class TabGroupsController: NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate {
    let table = operationTable([("name","Tabgruppe",250)])
    let folders = operationTable([("side","Seite",70),("name","Ordner / Tab",330),("state","Status",140)])
    let name = input(),status = label("",size:12),replace = checkbox("Ungesperrte Ordnertabs ersetzen")
    let save = ActionButton("Neue Gruppe aus beiden Seiten",action:{})
    let update = ActionButton("Mit aktuellen Tabs aktualisieren",action:{})
    let rename = ActionButton("Umbenennen",action:{}),remove = ActionButton("Entfernen",action:{})
    let up = ActionButton("↑",action:{}),down = ActionButton("↓",action:{})
    let open = ActionButton("Tabgruppe öffnen",symbol:"folder",action:{})
    private(set) var library = TabGroupLibrary(),selectedID:UUID?,preview:TabGroupProfile?,previewContext:TabGroupContext?
    private(set) var availability:[Bool] = []
    private var rows:[(String,TabGroupFolder)] = [],generation = UUID(),readable = false
    var capture:((String)throws->TabGroupProfile)?,context:(()->TabGroupContext)?,onApply:((TabGroupProfile,Bool)->Void)?
    init(capture:@escaping(String)throws->TabGroupProfile,context:@escaping()->TabGroupContext,apply:@escaping(TabGroupProfile,Bool)->Void) {
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:930,height:590),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = "Tabgruppen";w.minSize = NSSize(width:930,height:590);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self;self.capture = capture;self.context = context;onApply = apply
        let root = OperationContent(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        let heading = label("Tabgruppen",size:22,weight:.semibold);heading.frame = NSRect(x:22,y:541,width:880,height:30);heading.autoresizingMask = [.width,.minYMargin];root.addSubview(heading)
        let note = label("Ordner beider Seiten mit Reihenfolge, Tabnamen, Sperren und Ansichten lokal merken.\nServer-, Archiv- und Sammlungstabs werden nicht in Gruppen gespeichert.",size:11,color:.secondaryLabelColor)
        note.frame = NSRect(x:22,y:494,width:880,height:38);note.maximumNumberOfLines = 2;note.autoresizingMask = [.width,.minYMargin];root.addSubview(note)
        name.placeholderString = "Name der Tabgruppe";name.setAccessibilityLabel("Name der Tabgruppe");name.toolTip = "Name für eine neue Gruppe oder zum Umbenennen. ⌘L fokussiert dieses Feld."
        name.frame = NSRect(x:22,y:455,width:340,height:28);name.autoresizingMask = [.minYMargin];root.addSubview(name)
        save.frame = NSRect(x:376,y:454,width:260,height:30);save.autoresizingMask = [.minYMargin];save.perform = { [weak self] in self?.saveCurrent() };root.addSubview(save)
        rename.frame = NSRect(x:650,y:454,width:120,height:30);rename.autoresizingMask = [.minYMargin];rename.perform = { [weak self] in self?.renameSelected() };root.addSubview(rename)
        let list = operationScroll(table);list.frame = NSRect(x:22,y:158,width:265,height:282);list.autoresizingMask = [.height];root.addSubview(list)
        let detail = operationScroll(folders);detail.frame = NSRect(x:303,y:158,width:605,height:282);detail.autoresizingMask = [.width,.height];root.addSubview(detail)
        table.dataSource = self;table.delegate = self;folders.dataSource = self;folders.delegate = self
        table.setAccessibilityLabel("Gespeicherte Tabgruppen");folders.setAccessibilityLabel("Ordner der ausgewählten Tabgruppe")
        up.perform = { [weak self] in self?.move(-1) };down.perform = { [weak self] in self?.move(1) };remove.perform = { [weak self] in self?.removeSelected() }
        let edit = row([up,down,remove]);edit.frame = NSRect(x:22,y:119,width:265,height:30);root.addSubview(edit)
        update.frame = NSRect(x:303,y:119,width:290,height:30);update.perform = { [weak self] in self?.updateCurrent() };root.addSubview(update)
        replace.frame = NSRect(x:303,y:83,width:605,height:28);replace.target = self;replace.action = #selector(modeChanged);replace.toolTip = "Ersetzt nur ungesperrte normale Ordnertabs. Gesperrte Tabs, Server, Archive und Sammlungen bleiben geöffnet.";root.addSubview(replace)
        status.frame = NSRect(x:22,y:46,width:886,height:34);status.autoresizingMask = [.width];status.maximumNumberOfLines = 2;status.lineBreakMode = .byWordWrapping;root.addSubview(status)
        let refresh = ActionButton("Neu prüfen",symbol:"arrow.clockwise",action:{ [weak self] in self?.reload() });refresh.setHelp("Neu prüfen","Gespeicherte Gruppe, aktuelle Tabs und verfügbare Ordner erneut prüfen.",shortcut:"⌘R")
        let close = ActionButton("Schließen",action:{ [weak self] in self?.close() });close.keyEquivalent = "\u{1b}";close.keyEquivalentModifierMask = []
        open.perform = { [weak self] in self?.submit() };open.setHelp("Tabgruppe öffnen","Die angezeigten verfügbaren Ordner auf beiden Seiten öffnen.",shortcut:"⌘↩")
        let actions = row([refresh,close,open]);actions.frame = NSRect(x:22,y:7,width:886,height:32);actions.autoresizingMask = [.width];root.addSubview(actions)
        save.setHelp(save.title,"Die aktuellen normalen Ordnertabs beider Seiten als neue Gruppe speichern.")
        update.setHelp(update.title,"Ordner, Ansichten, Namen und Sperren der ausgewählten Gruppe durch die aktuellen Tabs beider Seiten ersetzen.")
        rename.setHelp(rename.title,"Nur den Gruppennamen ändern; gespeicherte Ordner beibehalten.")
        remove.setHelp(remove.title,"Nur die gespeicherte Gruppe entfernen. Geöffnete Tabs und Dateien bleiben erhalten.")
        up.setHelp("Nach oben","Gruppe in der Liste nach oben verschieben.");down.setHelp("Nach unten","Gruppe in der Liste nach unten verschieben.")
        w.workflowKeys = { [weak self,weak w] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"\r",.command) { if self.open.isEnabled { self.submit() };return true }
            if WorkflowKeys.matches(event,"r",.command) { self.reload();return true }
            if WorkflowKeys.matches(event,"l",.command) { w?.makeFirstResponder(self.name);self.name.selectText(nil);return true }
            return false
        }
        w.initialFirstResponder = name;w.center();reload()
    }
    required init?(coder:NSCoder) { fatalError() }
    var selected:TabGroupProfile? { library.groups.first { $0.id == selectedID } }
    func reload(select id:UUID? = nil) {
        generation = UUID();preview = nil;previewContext = nil;availability = [];rows = [];open.isEnabled = false
        do {
            library = try Preferences.tabGroups();readable = true;selectedID = id ?? selectedID
            if !library.groups.contains(where:{ $0.id == selectedID }) { selectedID = library.groups.first?.id }
            table.reloadData()
            if let index = library.groups.firstIndex(where:{ $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) } else { table.deselectAll(nil) }
            refreshSelection()
        } catch { readable = false;library = TabGroupLibrary();selectedID = nil;table.reloadData();folders.reloadData();failed(error);updateButtons() }
    }
    private func updateButtons() {
        save.isEnabled = readable;let has = readable && selected != nil
        [update,rename,remove].forEach { $0.isEnabled = has }
        let index = library.groups.firstIndex { $0.id == selectedID };up.isEnabled = has && index.map { $0 > 0 } == true;down.isEnabled = has && index.map { $0+1 < library.groups.count } == true
    }
    private func refreshSelection() {
        generation = UUID();let token = generation;preview = nil;previewContext = nil;availability = [];open.isEnabled = false;updateButtons()
        guard let group = selected else { rows = [];folders.reloadData();status.stringValue = "Noch keine Tabgruppe. Einen Namen eingeben und die aktuellen Ordner speichern.";status.textColor = .secondaryLabelColor;return }
        name.stringValue = group.name;rows = group.left.folders.map { ("Links",$0) }+group.right.folders.map { ("Rechts",$0) };folders.reloadData()
        status.stringValue = "Ordner werden geprüft …";status.textColor = .secondaryLabelColor
        let workspace = context?()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let available = (group.left.folders+group.right.folders).map { FileSystem.isDirectory(URL(fileURLWithPath:$0.path)) }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == token else { return }
                self.preview = group;self.previewContext = workspace;self.availability = available;self.folders.reloadData()
                let left = available.prefix(group.left.folders.count).filter { $0 }.count,right = available.dropFirst(group.left.folders.count).filter { $0 }.count,missing = available.filter { !$0 }.count
                self.open.isEnabled = left > 0 && right > 0
                self.status.stringValue = "\(left) links · \(right) rechts verfügbar"+(missing > 0 ? " · \(missing) nicht verfügbare Ordner werden ausgelassen." : " · Alle Ordner verfügbar.")+(self.open.isEnabled ? "" : "\nMindestens ein verfügbarer Ordner je Seite wird benötigt.")
                self.status.textColor = missing > 0 ? .systemOrange : .labelColor
            }
        }
    }
    @objc func modeChanged() { refreshSelection() }
    func saveCurrent() {
        do {
            guard readable,let value = try capture?(name.stringValue) else { return }
            try Preferences.editTabGroups { try $0.put(value) };reload(select:value.id)
        } catch { failed(error) }
    }
    private func editSelected(_ edit:(inout TabGroupProfile)throws->Void) {
        guard let old = selected else { return }
        do {
            try Preferences.editTabGroups { library in
                guard library.groups.first(where:{ $0.id == old.id }) == old else { throw CommanderError.message("Die Gruppe wurde inzwischen geändert. Mit ⌘R neu laden und prüfen.") }
                var next = old;try edit(&next);try library.put(next)
            };reload(select:old.id)
        } catch { failed(error) }
    }
    func renameSelected() { let title = name.stringValue;editSelected { $0.name = title } }
    func updateCurrent() {
        editSelected { group in
            guard var next = try capture?(group.name) else { return };next.id = group.id;group = next
        }
    }
    func move(_ offset:Int) {
        guard let group = selected else { return }
        do { try Preferences.editTabGroups { library in
            guard library.groups == self.library.groups else { throw CommanderError.message("Die Liste wurde inzwischen geändert. Mit ⌘R neu laden.") };try library.move(group.id,by:offset)
        };reload(select:group.id) } catch { failed(error) }
    }
    func removeSelected() {
        guard let group = selected else { return }
        do { try Preferences.editTabGroups { library in
            guard library.groups.first(where:{ $0.id == group.id }) == group else { throw CommanderError.message("Die Gruppe wurde inzwischen geändert. Mit ⌘R neu laden.") };library.groups.removeAll { $0.id == group.id }
        };selectedID = nil;reload() } catch { failed(error) }
    }
    func submit() {
        guard open.isEnabled,let group = preview,let workspace = previewContext else { return }
        do {
            guard try Preferences.tabGroups().groups.first(where:{ $0.id == group.id }) == group,context?() == workspace else {
                reload();status.stringValue = "Gruppe oder geöffnete Tabs wurden geändert. Die Vorschau wird erneuert; bitte anschließend erneut öffnen.";status.textColor = .systemOrange;return
            }
            let token = UUID(),expected = availability,replacing = replace.state == .on;generation = token;open.isEnabled = false;status.stringValue = "Ordner werden vor dem Öffnen erneut geprüft …"
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                let available = (group.left.folders+group.right.folders).map { FileSystem.isDirectory(URL(fileURLWithPath:$0.path)) }
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.generation == token else { return }
                    do {
                        guard try Preferences.tabGroups().groups.first(where:{ $0.id == group.id }) == group,self.context?() == workspace else {
                            self.reload();self.status.stringValue = "Gruppe oder geöffnete Tabs wurden geändert. Bitte die neue Vorschau prüfen und erneut öffnen.";self.status.textColor = .systemOrange;return
                        }
                        guard available == expected else { self.refreshSelection();self.status.stringValue = "Die verfügbaren Ordner haben sich geändert. Bitte die neue Vorschau prüfen und erneut öffnen.";self.status.textColor = .systemOrange;return }
                        func filtered(_ pane:TabGroupPane,_ flags:ArraySlice<Bool>) -> TabGroupPane {
                            let values = zip(pane.folders.enumerated(),flags).filter { $0.1 }.map { $0.0 }
                            return TabGroupPane(folders:values.map(\.element),selected:values.firstIndex { $0.offset == pane.selected } ?? 0)
                        }
                        var ready = group;ready.left = filtered(group.left,available.prefix(group.left.folders.count));ready.right = filtered(group.right,available.dropFirst(group.left.folders.count))
                        self.onApply?(ready,replacing);self.close()
                    } catch { self.failed(error) }
                }
            }
        } catch { failed(error);open.isEnabled = false }
    }
    private func failed(_ error:Error) { generation = UUID();preview = nil;previewContext = nil;open.isEnabled = false;status.stringValue = error.localizedDescription;status.textColor = .systemRed }
    func windowWillClose(_ notification:Notification) { generation = UUID();capture = nil;context = nil;onApply = nil }
    func numberOfRows(in tableView:NSTableView) -> Int { tableView === table ? library.groups.count : rows.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
        if tableView === table { guard library.groups.indices.contains(row) else { return nil };return label(library.groups[row].name) }
        guard rows.indices.contains(row) else { return nil };let item = rows[row],key = column?.identifier.rawValue
        let text = key == "side" ? item.0 : key == "name" ? (item.1.title ?? item.1.path) : (availability.indices.contains(row) ? (availability[row] ? (item.1.locked ? "Verfügbar · gesperrt" : "Verfügbar") : "Nicht verfügbar") : "Wird geprüft …")
        let field = label(text);field.lineBreakMode = .byTruncatingMiddle;field.toolTip = item.1.path;return field
    }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard notification.object as? NSTableView === table else { return }
        selectedID = library.groups.indices.contains(table.selectedRow) ? library.groups[table.selectedRow].id : nil;refreshSelection()
    }
}
