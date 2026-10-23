import AppKit
import CommanderCore

final class RecoveryController: NSWindowController,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate {
    let jobs: JobQueue
    let table = operationTable([("name","Datei / Ordner",215),("kind","Art",105),("size","Daten",145),("date","Gesichert am",145),("path","Ursprünglicher Ort / Ziel",420)])
    let search = NSSearchField()
    let kind = NSPopUpButton()
    let summary = label("Lade Wiederherstellung …",size:12,color:.secondaryLabelColor)
    let detail = label("",size:12)
    let primary = ActionButton("Wiederherstellen …",symbol:"arrow.uturn.backward",action:{})
    let discard = ActionButton("Verwerfen …",symbol:"trash",action:{})
    let forget = ActionButton("Eintrag entfernen …",action:{})
    let reveal = ActionButton("Im Finder zeigen",symbol:"folder",action:{})
    let reload = ActionButton("Aktualisieren",symbol:"arrow.clockwise",action:{})
    private(set) var rows: [RecoveryItem] = []
    private var allRows: [RecoveryItem] = []
    private var selectedID: UUID?
    private var generation = 0
    private var timer: Timer?
    private(set) var isLoading = false
    private(set) var confirmation: NSAlert?
    var onContinue: ((RecoveryItem)->Void)?
    var onPreview: ((URL)->Void)?
    var onDidChange: (() -> Void)?
    var selected: RecoveryItem? { rows.first { $0.id == selectedID } }
    var canModify: Bool { !isLoading && jobs.pending == 0 && jobs.journalError == nil && jobs.history != nil }
    init(_ jobs: JobQueue) {
        self.jobs = jobs
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:1000,height:580),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        w.title = "Wiederherstellung · Sicherungen und Teilkopien";w.minSize = NSSize(width:940,height:540);w.isReleasedWhenClosed = false
        super.init(window:w)
        let root = OperationContent(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        let title = label("Wiederherstellung",size:22,weight:.semibold);title.frame = NSRect(x:22,y:530,width:700,height:32);title.autoresizingMask = [.minYMargin,.width];root.addSubview(title)
        summary.frame = NSRect(x:22,y:501,width:956,height:23);summary.autoresizingMask = [.minYMargin,.width];root.addSubview(summary)
        search.frame = NSRect(x:22,y:462,width:660,height:28);search.autoresizingMask = [.minYMargin,.width];search.placeholderString = "Name oder Pfad filtern · ⌘F";search.delegate = self;search.setAccessibilityLabel("Sicherungen und Teilkopien filtern");root.addSubview(search)
        kind.frame = NSRect(x:700,y:462,width:278,height:28);kind.autoresizingMask = [.minYMargin,.minXMargin];kind.addItems(withTitles:["Alle · ⌘1","Sicherungen · ⌘2","Teilkopien · ⌘3"]);kind.target = self;kind.action = #selector(filterChanged);kind.setAccessibilityLabel("Art der Wiederherstellungsdaten");root.addSubview(kind)
        table.delegate = self;table.dataSource = self;table.target = self;table.doubleAction = #selector(activateSelected)
        let scroll = operationScroll(table);scroll.frame = NSRect(x:22,y:199,width:956,height:251);scroll.autoresizingMask = [.width,.height];root.addSubview(scroll)
        detail.frame = NSRect(x:22,y:98,width:956,height:91);detail.autoresizingMask = [.width];detail.lineBreakMode = .byWordWrapping;detail.maximumNumberOfLines = 5;root.addSubview(detail)
        let buttons = row([primary,reveal,discard,forget]);buttons.frame = NSRect(x:20,y:57,width:956,height:34);buttons.autoresizingMask = [.width];root.addSubview(buttons)
        reload.frame = NSRect(x:22,y:15,width:150,height:30);root.addSubview(reload)
        let hint = label("↩ Prüfen · Leertaste Vorschau · ⌘F Filter · ⌘R Aktualisieren · ⌘⌫ Verwerfen",size:11,color:.secondaryLabelColor);hint.frame = NSRect(x:188,y:20,width:790,height:22);hint.autoresizingMask = [.width];root.addSubview(hint)
        primary.perform = { [weak self] in self?.activateSelected() };reveal.perform = { [weak self] in if let item = self?.selected { NSWorkspace.shared.activateFileViewerSelecting([item.stored]) } }
        discard.perform = { [weak self] in self?.discardSelected() };forget.perform = { [weak self] in self?.forgetSelected() };reload.perform = { [weak self] in self?.refresh() }
        primary.setHelp("Wiederherstellen / Fortsetzen","Zuerst den gewählten Eintrag und sein Ziel prüfen.",shortcut:"↩ / ⌘↩")
        discard.setHelp("Verwerfen","Ausgewählte Sicherung oder Teilkopie nach Rückfrage in den Papierkorb verschieben.",shortcut:"⌘⌫")
        forget.setHelp("Eintrag entfernen","Nur die nicht verfügbare Beschreibung entfernen. Dateien bleiben erhalten.",shortcut:"⌘⇧⌫")
        reload.setHelp("Aktualisieren","Verfügbarkeit der gespeicherten Daten neu prüfen.",shortcut:"⌘R")
        w.workflowKeys = { [weak self] in self?.handleKey($0) ?? false }
        (table as? CommanderTableView)?.workflowKeys = { [weak self] in self?.handleKey($0) ?? false }
        timer = Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in if self?.window?.isVisible == true { self?.updateActions() } }
        w.initialFirstResponder = table;w.center();refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    func refresh() {
        generation += 1;let current = generation
        guard let history = jobs.history else { summary.stringValue = jobs.journalError ?? "Wiederherstellung ist in dieser Sitzung nicht verfügbar.";summary.textColor = .systemOrange;updateActions();return }
        isLoading = true;summary.stringValue = "Sicherungen und Teilkopien werden geprüft …";updateActions()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let rows = history.inspect()
            DispatchQueue.main.async {
                guard let self,self.generation == current else { return }
                self.isLoading = false;self.allRows = rows;self.applyFilter()
            }
        }
    }
    @objc func filterChanged() { applyFilter() }
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
    func applyFilter() {
        rows = allRows.filter { item in
            (kind.indexOfSelectedItem == 0 || (kind.indexOfSelectedItem == 1 ? item.kind == .backup : item.kind == .partial)) && (search.stringValue.isEmpty || item.original.path.localizedCaseInsensitiveContains(search.stringValue) || item.source?.path.localizedCaseInsensitiveContains(search.stringValue) == true)
        }
        let previous = selectedID;table.reloadData()
        if let previous,let index = rows.firstIndex(where: { $0.id == previous }) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);selectedID = previous }
        else if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);selectedID = rows[0].id }
        else { selectedID = nil }
        let backups = allRows.filter { $0.kind == .backup }.count,partials = allRows.count-backups
        summary.stringValue = allRows.isEmpty ? "Noch keine Sicherungen oder fortsetzbaren Teilkopien vorhanden." : "\(backups) Sicherungen · \(partials) Teilkopien · \(rows.count) sichtbar"
        summary.textColor = .secondaryLabelColor;updateActions()
    }
    func updateActions() {
        let item = selected
        primary.title = item?.kind == .partial ? "Fortsetzen prüfen …" : "Wiederherstellen …"
        primary.isEnabled = canModify && item?.available == true;discard.isEnabled = primary.isEnabled
        forget.isEnabled = canModify && item?.available == false;reveal.isEnabled = item?.available == true
        if let item {
            detail.stringValue = (item.kind == .partial ? "Quelle: "+(item.source?.path ?? "")+"\nZiel: "+item.original.path : "Wiederherstellen nach: "+item.original.path)+"\n"+item.note+(jobs.pending > 0 ? "\nDateiaufträge zuerst abschließen oder entfernen." : "")
            detail.toolTip = detail.stringValue+"\nAblage: "+item.stored.path
        } else { detail.stringValue = "Beim Ersetzen angelegte Sicherungen und fortsetzbare Kopien erscheinen hier. Fortsetzbar sind Kopien ab 4 MiB mit bis zu 2.000 Objekten ohne Verknüpfungen. Die vorhandenen Bytes werden vor der Weiterverwendung geprüft." }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectedID = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].id : nil;updateActions() }
    @objc func activateSelected() {
        guard canModify,primary.isEnabled,let item = selected,let history = jobs.history else { return }
        if item.kind == .partial { onContinue?(item);return }
        jobs.submit("Sicherung prüfen",work:{ _,_ in try history.planRestore(item.id) },completion:{ [weak self] result in
            switch result { case .success(let plan):self?.reviewRestore(plan);case .failure(let error):self?.summary.stringValue = error.localizedDescription;self?.updateActions() }
        })
    }
    func reviewRestore(_ plan: BackupRestorePlan) {
        guard let window,window.attachedSheet == nil else { return }
        let alert = NSAlert();alert.messageText = "Sicherung wiederherstellen?"
        alert.informativeText = plan.item.original.path+"\n\n"+(plan.replacesExisting ? "Der aktuelle Inhalt wird zuerst als neue Sicherung aufbewahrt. Anschließend wird die gewählte Sicherung wiederhergestellt." : "Der frühere Inhalt wird am ursprünglichen Ort wiederhergestellt.")
        alert.addButton(withTitle:"Wiederherstellen");alert.addButton(withTitle:"Abbrechen");alert.buttons[0].keyEquivalent = "\r";alert.buttons[1].keyEquivalent = "\u{1b}"
        confirmation = alert
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self else { return };self.confirmation = nil
            guard response == .alertFirstButtonReturn,let history = self.jobs.history else { return }
            self.jobs.submit("Sicherung wiederherstellen",work:{ token,_ in try history.restore(plan,token:token) },completion:{ [weak self] result in
                self?.refresh();self?.onDidChange?();if case .failure(let error) = result { showFailure(error) }
            })
        }
    }
    func discardSelected() {
        guard canModify,discard.isEnabled,let item = selected,let history = jobs.history,let window,window.attachedSheet == nil else { return }
        let alert = NSAlert();alert.messageText = item.kind == .partial ? "Teilkopie verwerfen?" : "Sicherung verwerfen?"
        alert.informativeText = item.original.path+"\n\nDie gespeicherten Daten werden in den Papierkorb verschoben. Quelle und aktuelles Ziel bleiben erhalten."
        alert.addButton(withTitle:"In den Papierkorb");alert.addButton(withTitle:"Abbrechen");confirmation = alert
        alert.beginSheetModal(for:window) { [weak self] response in
            self?.confirmation = nil;guard response == .alertFirstButtonReturn else { return }
            self?.jobs.submit("Wiederherstellungsdaten verwerfen",work:{ _,_ in try history.discard(item.id) },completion:{ [weak self] result in self?.refresh();if case .failure(let error) = result { showFailure(error) } })
        }
    }
    func forgetSelected() {
        guard canModify,forget.isEnabled,let item = selected,let history = jobs.history else { return }
        guard dialog("Nicht verfügbaren Eintrag entfernen?",message:item.original.path+"\n\nEs wird ausschließlich die Beschreibung entfernt. Dateien werden weder gesucht noch gelöscht.",buttons:["Eintrag entfernen","Abbrechen"]) == 0 else { return }
        jobs.submit("Eintrag entfernen",work:{ _,_ in try history.forgetUnavailable(item.id) },completion:{ [weak self] result in self?.refresh();if case .failure(let error) = result { showFailure(error) } })
    }
    func handleKey(_ event: NSEvent) -> Bool {
        if WorkflowKeys.matches(event,"f",.command) { window?.makeFirstResponder(search);search.selectText(nil);return true }
        if WorkflowKeys.matches(event,"r",.command) { refresh();return true }
        for (key,index) in [("1",0),("2",1),("3",2)] where WorkflowKeys.matches(event,key,.command) { kind.selectItem(at:index);applyFilter();window?.makeFirstResponder(table);return true }
        if WorkflowKeys.matches(event,"\r",.command) { activateSelected();return true }
        guard !(window?.firstResponder is NSTextView) else { return false }
        if WorkflowKeys.matches(event,"\r") { activateSelected();return true }
        if WorkflowKeys.matches(event," ") { if let item = selected,item.available { onPreview?(item.stored) };return true }
        if WorkflowKeys.matches(event,"\u{7f}",.command) { discardSelected();return true }
        if WorkflowKeys.matches(event,"\u{7f}",[.command,.shift]) { forgetSelected();return true }
        if WorkflowKeys.matches(event,"\u{1b}") { close();return true }
        return false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil };let item = rows[row],value: String
        switch column?.identifier.rawValue {
        case "name":value = item.original.lastPathComponent
        case "kind":value = item.kind == .backup ? "Sicherung" : "Teilkopie"
        case "size":value = item.kind == .partial ? bytes(item.bytes)+" / "+bytes(item.totalBytes) : item.note == "Ordnersicherung" ? "Ordner" : bytes(item.bytes)
        case "date":value = displayDate.string(from:item.created)
        default:value = item.original.deletingLastPathComponent().path
        }
        let field = label(value,color:item.available ? .labelColor : .secondaryLabelColor);field.toolTip = item.original.path+"\n"+item.note;return field
    }
}

extension MainWindow {
    func showRecovery() {
        if recoveryWindow == nil {
            let controller = RecoveryController(jobs)
            controller.onContinue = { [weak self] in self?.continuePartial($0) }
            controller.onPreview = { [weak self] in self?.preview([$0]) }
            controller.onDidChange = { [weak self] in self?.refresh() }
            recoveryWindow = controller
        }
        recoveryWindow?.refresh();recoveryWindow?.showWindow(nil)
    }
    func continuePartial(_ item: RecoveryItem) {
        guard let intent = jobs.history?.partialIntent(item.id) else { return }
        let cache = self.cache
        let controller = TransferSetupController(sources:intent.sources,destination:intent.destination,kind:intent.kind,validateDestination:{ url in
            guard !FileSystem.isInside(url,cache) else { throw CommanderError.message("Temporäre Archivordner sind schreibgeschützt.") }
        })
        controller.apply(intent,notice:"Teilkopie vorhanden: "+bytes(item.bytes)+". Vorhandene Bytes werden vor dem Fortsetzen mit der Quelle verglichen. Ziele und Konflikte vor dem Start prüfen.")
        controller.onSubmit = { [weak self] plan,start in self?.enqueueTransfer(plan,start:start) ?? false }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
}
