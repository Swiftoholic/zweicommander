import AppKit
import CommanderCore

final class ArchiveEditController:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate {
    let source:URL,table = CommanderTableView(),scroll = NSScrollView()
    let add = ActionButton("Hinzufügen …",symbol:"plus",action:{}),rename = ActionButton("Umbenennen …",symbol:"pencil",action:{}),remove = ActionButton("Entfernen",symbol:"minus",action:{})
    let reset = ActionButton("Änderungen verwerfen",action:{}),refresh = ActionButton("Neu prüfen",symbol:"arrow.clockwise",action:{})
    let apply = ActionButton("Änderungen übernehmen …",action:{}),queue = ActionButton("Vormerken …",action:{}),cancel = ActionButton("Abbrechen",action:{})
    let prefix = input(placeholder:"Optionaler Archivordner für neue Dateien"),filter = input(placeholder:"Einträge filtern")
    let info = label("Lese Archiv …",size:12),summary = label("",size:12),formatInfo = label("",size:11,color:.secondaryLabelColor)
    private(set) var plan:ArchiveEditPlan?,rows:[ArchiveEditRow] = [],isPreparing = false,isWorking = false
    private(set) var additions:[ArchiveEditAddition] = [],renames:[String:String] = [:],removals = Set<String>()
    private var token = CancellationToken(),generation = UUID(),delayed:DispatchWorkItem?
    var jobID:UUID?,reviewAlert:NSAlert?,onSubmit:((ArchiveEditPlan,Bool,ArchiveEditController)->UUID?)?,onCancel:((UUID)->Void)?
    init(source:URL) {
        self.source = source
        let window = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:1120,height:740),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "Archiv bearbeiten · "+source.lastPathComponent;window.minSize = NSSize(width:1000,height:660);window.isReleasedWhenClosed = false
        super.init(window:window);window.delegate = self
        buildInterface(window);window.workflowKeys = { [weak self] in self?.handleKey($0) ?? false };window.center();prepare()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func buildInterface(_ window:NSWindow) {
        let root = CommanderSurface();window.contentView = root
        func top(_ view:NSView,_ x:CGFloat,_ y:CGFloat,_ width:CGFloat,_ height:CGFloat = 28,_ stretch:Bool = false) { view.frame = NSRect(x:x,y:y,width:width,height:height);view.autoresizingMask = stretch ? [.minYMargin,.width] : [.minYMargin];root.addSubview(view) }
        top(label("Archiv bearbeiten",size:21,weight:.semibold),22,684,1076,32,true)
        let path = label(source.path,size:11,color:.secondaryLabelColor);path.lineBreakMode = .byTruncatingMiddle;path.toolTip = source.path;top(path,22,654,1076,24,true)
        top(add,22,609,160,30);top(rename,192,609,160,30);top(remove,362,609,140,30);top(reset,518,609,220,30);top(refresh,914,609,184,30);refresh.autoresizingMask = [.minYMargin,.minXMargin]
        top(label("Hinzufügen unter",size:12),22,569,145);top(prefix,171,569,927,28,true)
        top(filter,22,529,1076,28,true);filter.delegate = self
        for (id,title,width) in [("action","Änderung",125.0),("old","Bisheriger Pfad",350.0),("path","Neuer Archivpfad",390.0),("size","Größe",145.0)] {
            let column = NSTableColumn(identifier:.init(id));column.title = title;column.width = width;column.minWidth = 70;table.addTableColumn(column)
        }
        table.delegate = self;table.dataSource = self;table.allowsMultipleSelection = true;table.rowHeight = 28;table.usesAlternatingRowBackgroundColors = true
        scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.frame = NSRect(x:22,y:191,width:1076,height:322);scroll.autoresizingMask = [.width,.height];root.addSubview(scroll)
        summary.frame = NSRect(x:22,y:150,width:1076,height:30);summary.autoresizingMask = [.width];root.addSubview(summary)
        formatInfo.frame = NSRect(x:22,y:117,width:1076,height:28);formatInfo.autoresizingMask = [.width];root.addSubview(formatInfo)
        info.frame = NSRect(x:22,y:74,width:1076,height:34);info.autoresizingMask = [.width];info.lineBreakMode = .byTruncatingMiddle;root.addSubview(info)
        for (button,x,width) in [(apply,22.0,260.0),(queue,294.0,200.0),(cancel,914.0,184.0)] { button.frame = NSRect(x:x,y:24,width:width,height:32);button.autoresizingMask = button === cancel ? [.minXMargin] : [];root.addSubview(button) }
        add.perform = { [weak self] in self?.chooseAdditions() };rename.perform = { [weak self] in self?.askRename() };remove.perform = { [weak self] in self?.removeSelected() }
        reset.perform = { [weak self] in self?.discardChanges() };refresh.perform = { [weak self] in self?.prepare() };apply.perform = { [weak self] in self?.review(start:true) };queue.perform = { [weak self] in self?.review(start:false) };cancel.perform = { [weak self] in self?.cancelWork() }
        add.setHelp("Hinzufügen","Lokale Dateien oder Ordner vormerken. Bestehende Dateipfade müssen vorher umbenannt oder entfernt werden.",shortcut:"⌘O")
        rename.setHelp("Umbenennen","Einen vorhandenen Eintrag einschließlich Unterordnern auf einen relativen Archivpfad verschieben.",shortcut:"F2")
        remove.setHelp("Entfernen","Ausgewählte Einträge zur Entfernung vormerken. Das Originalarchiv bleibt bis zur geprüften Übernahme unverändert.",shortcut:"⌫")
        reset.setHelp("Änderungen verwerfen","Nur die vorgemerkten Änderungen verwerfen.")
        refresh.setHelp("Neu prüfen","Original und hinzugefügte Quellen erneut einlesen.",shortcut:"⌘R")
        apply.setHelp("Änderungen übernehmen","Zusammenfassung prüfen, neue Archivdatei erstellen und nach Inhaltsprüfung mit Originalsicherung übernehmen.",shortcut:"⌘↩")
        queue.setHelp("Vormerken","Nach Prüfung in die gemeinsame Warteschlange aufnehmen.",shortcut:"⌘⇧↩")
        cancel.setHelp("Abbrechen","Vorbereitung oder eigenen Archivauftrag abbrechen.",shortcut:"Esc")
        prefix.toolTip = "Relativer Ordner innerhalb des Archivs, ohne führenden Schrägstrich und ohne .."
        filter.toolTip = "Vorschau nach altem oder neuem Archivpfad filtern · ⌘F"
    }
    var selectedRows:[ArchiveEditRow] { table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil } }
    func prepare() {
        guard !isWorking else { return };delayed?.cancel();token.cancel();token = CancellationToken();generation = UUID();let stamp = generation,token = token
        plan = nil;isPreparing = true;info.stringValue = "Prüfe Archiv und vorgemerkte Quellen …";info.textColor = .secondaryLabelColor;updateControls()
        let source = source,renames = renames,removals = removals,additions = additions
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try ArchiveEditPlan(source:source,renames:renames,removals:removals,additions:additions,token:token) }
            DispatchQueue.main.async {
                guard let self,self.generation == stamp,!token.isCancelled else { return };self.isPreparing = false
                switch result {
                case .success(let plan):self.plan = plan;self.info.stringValue = plan.hasChanges ? "Änderungen geprüft · Noch nicht übernommen" : "Originalarchiv geprüft · Änderungen vormerken";self.info.textColor = .secondaryLabelColor
                case .failure(let error):self.info.stringValue = error.localizedDescription;self.info.toolTip = error.localizedDescription;self.info.textColor = .systemRed
                };self.filterRows();self.updateControls()
            }
        }
    }
    func filterRows() {
        let query = filter.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        rows = (plan?.rows ?? []).filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) || ($0.originalPath?.localizedCaseInsensitiveContains(query) ?? false) }
        table.reloadData()
        if let plan {
            let changed = plan.rows.filter { $0.action != .keep },added = changed.filter { $0.action == .add }.count,renamed = changed.filter { $0.action == .rename }.count,removed = changed.filter { $0.action == .remove }.count
            summary.stringValue = "\(added) hinzufügen · \(renamed) umbenennen · \(removed) entfernen · Ergebnis: \(plan.outputCount) Einträge, \(bytes(plan.totalBytes))"
            formatInfo.stringValue = plan.format.title+" · Vollständige Inhaltsprüfung · Original als wiederherstellbare Sicherung · Nur unterstützte Metadaten"
            formatInfo.toolTip = plan.containerNote
        } else { summary.stringValue = "Keine ausführbare Vorschau";formatInfo.stringValue = "Das Originalarchiv bleibt unverändert." }
        updateControls()
    }
    func controlTextDidChange(_ notification:Notification) { if notification.object as? NSTextField === filter { filterRows() } }
    func updateControls() {
        let idle = !isPreparing && !isWorking
        add.isEnabled = idle;rename.isEnabled = idle && selectedRows.count == 1 && selectedRows[0].action != .remove && (selectedRows[0].originalPath != nil || additions.contains(where:{$0.path == selectedRows[0].path}))
        remove.isEnabled = idle && !selectedRows.isEmpty && selectedRows.allSatisfy { row in row.action != .remove && (row.originalPath != nil || additions.contains(where:{$0.path == row.path})) }
        refresh.isEnabled = !isWorking;reset.isEnabled = idle && (!additions.isEmpty || !renames.isEmpty || !removals.isEmpty)
        apply.isEnabled = idle && plan?.hasChanges == true;queue.isEnabled = apply.isEnabled;prefix.isEnabled = idle;filter.isEnabled = !isWorking;cancel.isEnabled = isPreparing || isWorking
    }
    func stageAdd(_ urls:[URL],under folder:String = "") throws {
        guard !isWorking else { return }
        let prefix = folder.isEmpty ? "" : try ArchiveEditPlanPath.checked(folder)+"/"
        additions += urls.map { ArchiveEditAddition(source:$0,path:prefix+$0.lastPathComponent) };prepare()
    }
    func stageRename(_ path:String,to target:String) throws {
        guard !isWorking else { return };_ = try ArchiveEditPlanPath.checked(target)
        if let index = additions.firstIndex(where:{$0.path == path}) { additions[index] = ArchiveEditAddition(source:additions[index].source,path:target);prepare();return }
        let displayed = plan?.rows.first(where:{$0.originalPath == path})?.path ?? renames[path] ?? path
        for (key,value) in renames where key != path && ArchiveEditPlanPath.contains(path,key) && ArchiveEditPlanPath.contains(displayed,value) { renames[key] = target+String(value.dropFirst(displayed.count)) }
        if path == target { renames.removeValue(forKey:path) } else { renames[path] = target }
        prepare()
    }
    func stageRemove(_ paths:Set<String>) {
        guard !isWorking else { return }
        for path in paths {
            renames = renames.filter { !ArchiveEditPlanPath.contains(path,$0.key) }
            removals.insert(path)
        };prepare()
    }
    func discardChanges() { guard !isWorking else { return };additions = [];renames = [:];removals = [];prepare() }
    func chooseAdditions() {
        guard add.isEnabled,let window else { return };let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = true;panel.allowsMultipleSelection = true
        panel.beginSheetModal(for:window) { [weak self] response in guard response == .OK,let self else { return };do { try self.stageAdd(panel.urls,under:self.prefix.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)) } catch { self.showError(error) } }
    }
    func askRename() {
        guard rename.isEnabled,let row = selectedRows.first,let window else { return };let original = row.originalPath ?? row.path
        let alert = NSAlert();alert.messageText = "Archivpfad ändern";alert.informativeText = "Ein relativer Pfad kann auch einen anderen Archivordner angeben. Untereinträge eines Ordners wechseln mit."
        let field = input(row.path);field.frame = NSRect(x:0,y:0,width:570,height:26);alert.accessoryView = field;alert.addButton(withTitle:"Vormerken");alert.addButton(withTitle:"Abbrechen")
        alert.beginSheetModal(for:window) { [weak self] response in guard response == .alertFirstButtonReturn,let self else { return };do { try self.stageRename(original,to:field.stringValue) } catch { self.showError(error) } }
        alert.window.makeFirstResponder(field);field.selectText(nil)
    }
    func removeSelected() {
        guard remove.isEnabled else { return }
        let selected = selectedRows
        for row in selected where row.originalPath == nil {
            guard additions.contains(where:{$0.path == row.path}) else { info.stringValue = "Zum Verwerfen eines neu hinzugefügten Ordners dessen obersten Eintrag auswählen.";return }
            additions.removeAll { $0.path == row.path }
        }
        stageRemove(Set(selected.compactMap(\.originalPath)))
    }
    func review(start:Bool) {
        guard apply.isEnabled,let plan,let window else { return }
        let alert = NSAlert();reviewAlert = alert;alert.messageText = start ? "Archivänderungen übernehmen?" : "Archivänderungen vormerken?"
        alert.informativeText = summary.stringValue+"\n\nDie neue Datei wird vollständig gelesen und mit den vorgesehenen Inhalten und Metadaten verglichen. Das Original wird erst danach als wiederherstellbare Sicherung beiseitegelegt.\n\n"+plan.containerNote
        alert.addButton(withTitle:start ? "Übernehmen" : "Vormerken");alert.addButton(withTitle:"Abbrechen")
        alert.beginSheetModal(for:window) { [weak self] response in guard let self else { return };self.reviewAlert = nil;if response == .alertFirstButtonReturn { self.submit(plan,start:start) } }
    }
    func submit(_ value:ArchiveEditPlan,start:Bool) {
        guard !isPreparing,!isWorking,plan?.hasChanges == true else { return }
        do { try value.validate();guard let id = onSubmit?(value,start,self) else { return };jobID = id;isWorking = true;info.stringValue = start ? "Archivauftrag gestartet …" : "Archivauftrag vorgemerkt";updateControls() } catch { showError(error) }
    }
    func finished(_ result:Result<OperationReport,Error>) {
        isWorking = false;jobID = nil
        switch result {
        case .success(let report):
            if report.errors.isEmpty { additions = [];renames = [:];removals = [];prepare() }
            else { info.stringValue = report.errors.joined(separator:" · ");info.toolTip = info.stringValue;info.textColor = .systemRed;plan = nil;filterRows() }
        case .failure(let error):showError(error)
        };updateControls()
    }
    func showError(_ error:Error) { info.stringValue = error.localizedDescription;info.toolTip = info.stringValue;info.textColor = .systemRed }
    func cancelWork() {
        if isWorking,let jobID { onCancel?(jobID);info.stringValue = "Archivauftrag wird abgebrochen …" }
        else if isPreparing { token.cancel();generation = UUID();isPreparing = false;plan = nil;info.stringValue = "Vorbereitung abgebrochen · Original unverändert";filterRows() }
        updateControls()
    }
    func handleKey(_ event:NSEvent) -> Bool {
        if WorkflowKeys.matches(event,"f",.command) { window?.makeFirstResponder(filter);filter.selectText(nil);return true }
        guard !(window?.firstResponder is NSTextView) else { return false }
        if WorkflowKeys.matches(event,"o",.command),add.isEnabled { chooseAdditions();return true }
        if WorkflowKeys.matches(event,"r",.command),refresh.isEnabled { prepare();return true }
        if WorkflowKeys.matches(event,"\r",[.command,.shift]),queue.isEnabled { review(start:false);return true }
        if WorkflowKeys.matches(event,"\r",.command),apply.isEnabled { review(start:true);return true }
        if WorkflowKeys.matches(event,String(UnicodeScalar(NSF2FunctionKey)!)),rename.isEnabled { askRename();return true }
        if WorkflowKeys.matches(event,"\u{7f}"),remove.isEnabled { removeSelected();return true }
        if WorkflowKeys.matches(event,"\u{1b}") { if isWorking || isPreparing { cancelWork() } else { close() };return true }
        return false
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { !isWorking }
    func windowWillClose(_ notification:Notification) { token.cancel();generation = UUID();delayed?.cancel() }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification:Notification) { updateControls() }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
        let row = rows[row],key = column?.identifier.rawValue,value:String
        switch key { case "action":value = row.action.rawValue;case "old":value = row.originalPath ?? "—";case "size":value = row.member.isDirectory ? "Ordner" : bytes(row.member.size);default:value = row.action == .remove ? "—" : row.path }
        let field = label(value,size:12);field.lineBreakMode = .byTruncatingMiddle;field.toolTip = value
        if row.action == .remove { field.textColor = .systemRed } else if row.action != .keep { field.textColor = .systemBlue };return field
    }
}
private enum ArchiveEditPlanPath {
    static func contains(_ root:String,_ child:String) -> Bool { root == child || child.hasPrefix(root+"/") }
    static func checked(_ value:String) throws -> String {
        guard !value.isEmpty,value.utf8.count <= 16_384,value.split(separator:"/").count <= 100,try ArchiveService.safePath(value) == value else { throw CommanderError.message("Bitte einen relativen Archivpfad ohne .. eingeben.") };return value
    }
}
