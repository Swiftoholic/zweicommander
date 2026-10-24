import AppKit
import CommanderCore

final class LayoutProfilesController:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate {
    let table = operationTable([("name","Arbeitsbereich",205),("key","Kürzel",85)])
    let folders = operationTable([("side","Seite",65),("name","Ordner / Tab",335),("state","Status",180)])
    let name = input(),summary = label("",size:11,color:.secondaryLabelColor),status = label("",size:12)
    let replace = checkbox("Ungesperrte Ordnertabs ersetzen",on:true),geometry = checkbox("Fenstergröße und Position übernehmen",on:true)
    let save = ActionButton("Neuer Arbeitsbereich aus beiden Seiten",action:{}),update = ActionButton("Mit aktuellen Einstellungen aktualisieren",action:{})
    let rename = ActionButton("Umbenennen",action:{}),remove = ActionButton("Entfernen",action:{}),up = ActionButton("↑",action:{}),down = ActionButton("↓",action:{})
    let open = ActionButton("Arbeitsbereich öffnen",symbol:"rectangle.split.2x1",action:{})
    private(set) var library = LayoutLibrary(),selectedID:UUID?,preview:LayoutProfile?,previewContext:LayoutContext?,availability:[Bool] = []
    private var rows:[(String,LayoutTab)] = [],readable = false,generation = UUID()
    var capture:((String)throws->LayoutProfile)?,context:(()->LayoutContext?)?,onApply:((LayoutProfile,Bool,Bool)throws->Void)?,onChange:(()->Void)?
    init(capture:@escaping(String)throws->LayoutProfile,context:@escaping()->LayoutContext?,apply:@escaping(LayoutProfile,Bool,Bool)throws->Void) {
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:980,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = "Arbeitsbereiche und Layouts";w.minSize = NSSize(width:980,height:650);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self;self.capture = capture;self.context = context;onApply = apply
        let root = OperationContent(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        let heading = label("Arbeitsbereiche & Layouts",size:22,weight:.semibold);heading.frame = NSRect(x:22,y:600,width:936,height:30);heading.autoresizingMask = [.width,.minYMargin];root.addSubview(heading)
        let note = label("Lokale Ordnertabs, Ansichten, Filter, Sperren und Fensteranordnung gemeinsam speichern.\nServer, Archive und Sammlungen bleiben sitzungsbezogen; vorhandene geschützte Tabs bleiben beim Wechsel erhalten.",size:11,color:.secondaryLabelColor)
        note.frame = NSRect(x:22,y:555,width:936,height:38);note.maximumNumberOfLines = 2;note.autoresizingMask = [.width,.minYMargin];root.addSubview(note)
        name.frame = NSRect(x:22,y:515,width:320,height:28);name.placeholderString = "Name des Arbeitsbereichs";name.setAccessibilityLabel("Name des Arbeitsbereichs");name.toolTip = "⌘L fokussiert den Namen für Speichern oder Umbenennen.";name.autoresizingMask = [.minYMargin];root.addSubview(name)
        save.frame = NSRect(x:354,y:514,width:345,height:30);save.autoresizingMask = [.minYMargin];save.perform = { [weak self] in self?.saveCurrent() };root.addSubview(save)
        rename.frame = NSRect(x:712,y:514,width:128,height:30);rename.autoresizingMask = [.minYMargin];rename.perform = { [weak self] in self?.renameSelected() };root.addSubview(rename)
        summary.frame = NSRect(x:326,y:470,width:632,height:36);summary.maximumNumberOfLines = 2;summary.autoresizingMask = [.width,.minYMargin];root.addSubview(summary)
        table.delegate = self;table.dataSource = self;folders.delegate = self;folders.dataSource = self
        table.setAccessibilityLabel("Gespeicherte Arbeitsbereiche");folders.setAccessibilityLabel("Ordnertabs des Arbeitsbereichs")
        let list = operationScroll(table);list.frame = NSRect(x:22,y:184,width:288,height:318);list.autoresizingMask = [.height];root.addSubview(list)
        let detail = operationScroll(folders);detail.frame = NSRect(x:326,y:184,width:632,height:276);detail.autoresizingMask = [.width,.height];root.addSubview(detail)
        up.perform = { [weak self] in self?.move(-1) };down.perform = { [weak self] in self?.move(1) };remove.perform = { [weak self] in self?.removeSelected() }
        let edits = row([up,down,remove]);edits.frame = NSRect(x:22,y:143,width:288,height:30);root.addSubview(edits)
        update.frame = NSRect(x:326,y:143,width:350,height:30);update.perform = { [weak self] in self?.updateCurrent() };root.addSubview(update)
        replace.frame = NSRect(x:326,y:106,width:632,height:26);geometry.frame = NSRect(x:326,y:77,width:632,height:26);root.addSubview(replace);root.addSubview(geometry)
        replace.toolTip = "Ersetzt nur ungesperrte normale Ordnertabs. Passende gesperrte Tabs werden wiederverwendet; ihre Sperrart bleibt erhalten. Server, Archive und Sammlungen bleiben offen."
        geometry.toolTip = "Gespeicherte Fensterposition und Größe übernehmen. Nicht mehr vorhandene Bildschirme werden auf einen verfügbaren Bildschirm abgebildet."
        status.frame = NSRect(x:22,y:41,width:936,height:35);status.maximumNumberOfLines = 2;status.lineBreakMode = .byWordWrapping;status.autoresizingMask = [.width];root.addSubview(status)
        let refresh = ActionButton("Neu prüfen",symbol:"arrow.clockwise",action:{ [weak self] in self?.reload() });refresh.setHelp("Neu prüfen","Arbeitsbereiche und Ordnerstatus neu laden. Fehlende Ordner bleiben Teil des Arbeitsbereichs.",shortcut:"⌘R")
        let close = ActionButton("Schließen",action:{ [weak self] in self?.close() });close.keyEquivalent = "\u{1b}";close.keyEquivalentModifierMask = []
        open.perform = { [weak self] in self?.submit() };open.setHelp(open.title,"Beide Seiten und die angezeigte Anordnung wiederherstellen. Dateien bleiben unverändert.",shortcut:"⌘↩")
        let actions = row([refresh,close,open]);actions.frame = NSRect(x:22,y:6,width:936,height:30);actions.autoresizingMask = [.width];root.addSubview(actions)
        save.setHelp(save.title,"Aktuelle lokale Ordnertabs beider Seiten und das Layout unter einem neuen Namen speichern.")
        update.setHelp(update.title,"Den gewählten Arbeitsbereich durch die aktuellen Tabs, Filter und das aktuelle Layout ersetzen.")
        rename.setHelp(rename.title,"Nur den Arbeitsbereichsnamen ändern.");remove.setHelp(remove.title,"Nur das gespeicherte Profil entfernen; geöffnete Tabs und Dateien bleiben erhalten.")
        up.setHelp("Nach oben","Arbeitsbereich in der Liste nach oben verschieben. Die ersten neun Plätze besitzen eigene belegbare Kürzel.");down.setHelp("Nach unten","Arbeitsbereich in der Liste nach unten verschieben.")
        w.workflowKeys = { [weak self,weak w] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"\r",.command) { self.submit();return true }
            if WorkflowKeys.matches(event,"r",.command) { self.reload();return true }
            if WorkflowKeys.matches(event,"l",.command) { w?.makeFirstResponder(self.name);self.name.selectText(nil);return true };return false
        }
        w.initialFirstResponder = name;w.center();reload()
    }
    required init?(coder:NSCoder) { fatalError() }
    var selected:LayoutProfile? { library.profiles.first { $0.id == selectedID } }
    func reload(select id:UUID? = nil) {
        generation = UUID();preview = nil;previewContext = nil;open.isEnabled = false
        do {
            library = try Preferences.layouts();readable = true;selectedID = id ?? selectedID
            if !library.profiles.contains(where:{ $0.id == selectedID }) { selectedID = library.profiles.first?.id }
            table.reloadData()
            if let index = library.profiles.firstIndex(where:{ $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) } else { table.deselectAll(nil) }
            refreshSelection()
        } catch { readable = false;library = LayoutLibrary();selectedID = nil;rows = [];summary.stringValue = "";table.reloadData();folders.reloadData();failed(error);updateButtons() }
    }
    private func updateButtons() {
        save.isEnabled = readable;let has = readable && selected != nil;[update,rename,remove].forEach { $0.isEnabled = has }
        let index = library.profiles.firstIndex { $0.id == selectedID };up.isEnabled = index.map { $0 > 0 } == true;down.isEnabled = index.map { $0+1 < library.profiles.count } == true
    }
    private func refreshSelection() {
        generation = UUID();let token = generation;preview = nil;previewContext = nil;availability = [];open.isEnabled = false;updateButtons()
        guard let value = selected else { rows = [];summary.stringValue = "";folders.reloadData();status.stringValue = "Name eingeben und die aktuellen lokalen Tabs beider Seiten speichern.";status.textColor = .secondaryLabelColor;return }
        name.stringValue = value.name;rows = value.left.tabs.map { ("Links",$0) }+value.right.tabs.map { ("Rechts",$0) };folders.reloadData()
        summary.stringValue = (value.layout.vertical ? "Nebeneinander" : "Übereinander")+" · \(Int((value.layout.ratio*100).rounded())) : \(Int(((1-value.layout.ratio)*100).rounded())) · "+(value.layout.presentation == .both ? "Beide Seiten" : value.layout.presentation == .left ? "Nur links" : "Nur rechts")+"\nAktiv: "+(value.layout.active == .left ? "links" : "rechts")+" · Schnellansicht "+(value.layout.quickVisible ? "ein" : "aus")+" · Verknüpftes Navigieren "+(value.layout.linked ? "ein" : "aus")
        let workspace = context?();status.stringValue = "Ordnerstatus wird geprüft …";status.textColor = .secondaryLabelColor
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let available = (value.left.tabs+value.right.tabs).map { FileSystem.isDirectory(URL(fileURLWithPath:$0.path)) }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == token else { return };self.preview = value;self.previewContext = workspace;self.availability = available;self.open.isEnabled = true;self.folders.reloadData()
                let missing = available.filter { !$0 }.count
                self.status.stringValue = "\(value.left.tabs.count) Tabs links · \(value.right.tabs.count) rechts"+(missing > 0 ? " · \(missing) nicht verfügbare Ordner bleiben als Tabs erhalten." : " · Alle Ordner verfügbar.")
                self.status.textColor = missing > 0 ? .systemOrange : .labelColor
            }
        }
    }
    func saveCurrent() {
        do { guard readable,let value = try capture?(name.stringValue) else { return };try Preferences.editLayouts { try $0.put(value) };onChange?();reload(select:value.id) } catch { failed(error) }
    }
    private func editSelected(_ edit:(inout LayoutProfile)throws->Void) {
        guard let old = selected else { return }
        do { try Preferences.editLayouts { library in
            guard library.profiles.first(where:{ $0.id == old.id }) == old else { throw CommanderError.message("Dieser Arbeitsbereich wurde inzwischen geändert. Mit ⌘R neu laden.") }
            var value = old;try edit(&value);try library.put(value)
        };onChange?();reload(select:old.id) } catch { failed(error) }
    }
    func renameSelected() { let title = name.stringValue;editSelected { $0.name = title } }
    func updateCurrent() { editSelected { value in guard var next = try capture?(value.name) else { return };next.id = value.id;value = next } }
    func move(_ offset:Int) {
        guard let selected else { return }
        do { try Preferences.editLayouts { library in guard library == self.library else { throw CommanderError.message("Die Liste wurde inzwischen geändert. Mit ⌘R neu laden.") };try library.move(selected.id,by:offset) };onChange?();reload(select:selected.id) } catch { failed(error) }
    }
    func removeSelected() {
        guard let selected else { return }
        do { try Preferences.editLayouts { library in guard library.profiles.first(where:{ $0.id == selected.id }) == selected else { throw CommanderError.message("Dieser Arbeitsbereich wurde inzwischen geändert. Mit ⌘R neu laden.") };library.profiles.removeAll { $0.id == selected.id } };onChange?();selectedID = nil;reload() } catch { failed(error) }
    }
    func submit() {
        guard open.isEnabled,let value = preview,let workspace = previewContext else { return }
        do {
            guard try Preferences.layouts().profiles.first(where:{ $0.id == value.id }) == value,context?() == workspace else { reload();status.stringValue = "Arbeitsbereich, Tabs oder Anordnung wurden geändert. Bitte die neue Vorschau prüfen und erneut öffnen.";status.textColor = .systemOrange;return }
            try onApply?(value,replace.state == .on,geometry.state == .on);close()
        } catch { failed(error) }
    }
    private func failed(_ error:Error) { generation = UUID();preview = nil;previewContext = nil;open.isEnabled = false;status.stringValue = error.localizedDescription;status.textColor = .systemRed }
    func windowWillClose(_ notification:Notification) { generation = UUID();capture = nil;context = nil;onApply = nil;onChange = nil }
    func numberOfRows(in tableView:NSTableView) -> Int { tableView === table ? library.profiles.count : rows.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
        if tableView === table { guard library.profiles.indices.contains(row) else { return nil };return label(column?.identifier.rawValue == "key" ? (row < 9 ? CommandHelp.shortcut("workspace\(row+1)") : "") : library.profiles[row].name) }
        guard rows.indices.contains(row) else { return nil };let item = rows[row],key = column?.identifier.rawValue
        let state = availability.indices.contains(row) ? (availability[row] ? (item.1.lockMode == .none ? "Verfügbar" : item.1.lockMode.title) : "Nicht verfügbar · bleibt") : "Wird geprüft …"
        let field = label(key == "side" ? item.0 : key == "name" ? item.1.title ?? item.1.path : state);field.toolTip = item.1.path+"\n"+item.1.lockMode.title+(item.1.filter.isEmpty ? "" : "\nFilter: "+item.1.filter);return field
    }
    func tableViewSelectionDidChange(_ notification:Notification) { guard notification.object as? NSTableView === table else { return };selectedID = library.profiles.indices.contains(table.selectedRow) ? library.profiles[table.selectedRow].id : nil;refreshSelection() }
}
