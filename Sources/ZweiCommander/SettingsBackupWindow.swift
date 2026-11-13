import AppKit
import CommanderCore

final class SettingsBackupController:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate {
    let storage:SettingsBackupStorage,canRestore:()->Bool
    let file = input(placeholder:"Eine ZweiCommander-Einstellungssicherung auswählen"),table = CommanderTableView()
    let choose = ActionButton("Datei wählen …",symbol:"folder",action:{}),save = ActionButton("Aktuelle Einstellungen sichern …",symbol:"square.and.arrow.down",action:{})
    let refresh = ActionButton("Neu prüfen",symbol:"arrow.clockwise",action:{}),apply = ActionButton("Wiederherstellen …",symbol:"arrow.uturn.backward",action:{})
    let restart = ActionButton("Jetzt neu starten",symbol:"arrow.clockwise.circle",action:{}),close = ActionButton("Schließen",action:{})
    let status = label("",size:12,color:.secondaryLabelColor),privacy = label("",size:11,color:.secondaryLabelColor)
    private(set) var plan:SettingsBackupRestorePlan?,confirmation:NSAlert?,isReading = false,isApplying = false,applied = false
    private var generation = 0,token = CancellationToken()
    var onApplied:((SettingsBackupRestoreReceipt)->Void)?,fileChooser:((Bool)->URL?)?
    init(storage:SettingsBackupStorage,canRestore:@escaping()->Bool = { true }) {
        self.storage = storage;self.canRestore = canRestore
        let window = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:880,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Einstellungen sichern und wiederherstellen";window.minSize = NSSize(width:780,height:620);window.isReleasedWhenClosed = false
        super.init(window:window);window.delegate = self
        let root = OperationContent(frame:window.contentView!.bounds);root.autoresizingMask = [.width,.height];window.contentView = root
        let heading = label("Einstellungen sichern und wiederherstellen",size:22,weight:.semibold);heading.frame = NSRect(x:22,y:596,width:836,height:32);heading.autoresizingMask = [.width,.minYMargin];root.addSubview(heading)
        privacy.stringValue = "Sicherungen enthalten lokale Pfade, Serverprofile und eigene Werkzeugargumente. Passwörter aus dem Schlüsselbund, Aufträge und Wiederherstellungsdateien gehören nicht dazu."
        privacy.maximumNumberOfLines = 3;privacy.lineBreakMode = .byWordWrapping;privacy.cell?.usesSingleLineMode = false;privacy.frame = NSRect(x:22,y:535,width:836,height:50);privacy.autoresizingMask = [.width,.minYMargin];root.addSubview(privacy)
        file.frame = NSRect(x:22,y:495,width:650,height:28);file.autoresizingMask = [.width,.minYMargin];file.target = self;file.action = #selector(pathCommitted);file.delegate = self;file.toolTip = "Lokale Sicherungsdatei · ⌘L";root.addSubview(file)
        choose.frame = NSRect(x:682,y:495,width:176,height:28);choose.autoresizingMask = [.minXMargin,.minYMargin];choose.perform = { [weak self] in self?.chooseFile() };root.addSubview(choose)
        save.frame = NSRect(x:22,y:451,width:302,height:28);save.autoresizingMask = [.minYMargin];save.perform = { [weak self] in self?.exportFile() };root.addSubview(save)
        refresh.frame = NSRect(x:690,y:451,width:168,height:28);refresh.autoresizingMask = [.minXMargin,.minYMargin];refresh.perform = { [weak self] in self?.prepare() };root.addSubview(refresh)
        for (id,title,width) in [("title","Einstellungsbereich",CGFloat(305)),("change","Nach Wiederherstellung",245),("before","Bisher",100),("after","Sicherung",100)] {
            let column = NSTableColumn(identifier:.init(id));column.title = title;column.width = width;table.addTableColumn(column)
        }
        table.delegate = self;table.dataSource = self;table.rowHeight = 26;table.allowsMultipleSelection = true
        let scroll = NSScrollView(frame:NSRect(x:22,y:170,width:836,height:266));scroll.autoresizingMask = [.width,.height];scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;root.addSubview(scroll)
        status.maximumNumberOfLines = 4;status.lineBreakMode = .byWordWrapping;status.cell?.usesSingleLineMode = false;status.frame = NSRect(x:22,y:82,width:836,height:76);status.autoresizingMask = [.width];root.addSubview(status)
        close.frame = NSRect(x:22,y:22,width:128,height:30);close.perform = { [weak self] in self?.close() };close.keyEquivalent = "\u{1b}";root.addSubview(close)
        restart.frame = NSRect(x:514,y:22,width:166,height:30);restart.autoresizingMask = [.minXMargin];restart.isHidden = true;restart.perform = { SettingsBackupStorage.onRestartRequested?() };root.addSubview(restart)
        apply.frame = NSRect(x:690,y:22,width:168,height:30);apply.autoresizingMask = [.minXMargin];apply.perform = { [weak self] in self?.requestRestore() };root.addSubview(apply)
        WorkflowKeys.bind(apply,key:"\r",modifiers:.command,title:"⌘↩",detail:"Die geprüfte vollständige Wiederherstellung nach Rückfrage übernehmen.")
        choose.setHelp("Datei wählen","Eine lokale Einstellungssicherung zur Vorschau öffnen.",shortcut:"⌘⇧L");refresh.setHelp("Neu prüfen","Sicherungsdatei und aktuellen Einstellungsstand neu vergleichen.",shortcut:"⌘R")
        save.setHelp("Aktuelle Einstellungen sichern","Alle eigenen Einstellungsbereiche in eine neue lokale JSON-Datei sichern.",shortcut:"⌘S")
        window.workflowKeys = { [weak self] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"l",.command) { self.window?.makeFirstResponder(self.file);self.file.selectText(nil);return true }
            if WorkflowKeys.matches(event,"l",[.command,.shift]) { self.chooseFile();return true }
            if WorkflowKeys.matches(event,"r",.command) { self.prepare();return true }
            if WorkflowKeys.matches(event,"s",.command) { self.exportFile();return true }
            if WorkflowKeys.matches(event,"\r",.command) { self.requestRestore();return true };return false
        }
        window.initialFirstResponder = table;window.center();updateButtons();status.stringValue = "Aktuelle Einstellungen sichern oder eine vorhandene Sicherung zur Vorschau auswählen."
    }
    required init?(coder:NSCoder) { fatalError() }
    func windowShouldClose(_ sender:NSWindow) -> Bool { !isApplying }
    func windowWillClose(_ notification:Notification) { generation += 1;token.cancel();onApplied = nil }
    @objc func pathCommitted() { prepare() }
    func controlTextDidChange(_ notification:Notification) {
        guard notification.object as? NSTextField === file,!isApplying,!applied else { return }
        generation += 1;let version = generation;token.cancel();isReading = false;plan = nil;table.reloadData();updateButtons()
        status.textColor = .secondaryLabelColor;status.stringValue = "Dateipfad geändert. Die Sicherung wird neu geprüft …"
        DispatchQueue.main.asyncAfter(deadline:.now()+0.35) { [weak self] in guard let self,self.generation == version else { return };self.prepare() }
    }
    func chooseFile() {
        guard !isApplying,!applied else { return }
        let destination:URL?
        if let fileChooser { destination = fileChooser(false) }
        else { let panel = NSOpenPanel();panel.allowsMultipleSelection = false;panel.canChooseDirectories = false;panel.message = "Lokale Einstellungssicherung auswählen. Es wird zunächst nur die Vorschau geöffnet.";destination = panel.runModal() == .OK ? panel.url : nil }
        if let destination { file.stringValue = destination.path;prepare() }
    }
    func prepare() {
        guard !isApplying,!applied else { return };generation += 1;let version = generation;token.cancel();let token = CancellationToken();self.token = token
        plan = nil;table.reloadData();isReading = true;updateButtons();status.textColor = .secondaryLabelColor;status.stringValue = "Sicherungsdatei und Einstellungsbereiche werden geprüft …"
        let text = file.stringValue,storage = self.storage
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () throws -> SettingsBackupDocument in
                guard !text.isEmpty,text.hasPrefix("/"),!text.contains("\0") else { throw CommanderError.message("Den vollständigen Pfad einer lokalen Sicherungsdatei eingeben.") }
                return try storage.read(URL(fileURLWithPath:text),token:token)
            }
            DispatchQueue.main.async {
                guard let self,self.generation == version,!token.isCancelled else { return };self.isReading = false
                do {
                    let document = try result.get();self.plan = try storage.prepare(document);self.table.reloadData()
                    self.status.stringValue = "\(self.plan!.changedCount) von \(SettingsBackupStores.keys.count) Einstellungsbereichen werden geändert. In der Sicherung fehlende Bereiche werden auf Standard zurückgesetzt. Erst die Bestätigung übernimmt diesen vollständigen Stand."
                } catch { self.show(error) }
                self.updateButtons()
            }
        }
    }
    func exportFile() {
        guard !isApplying,!applied else { return }
        do {
            let document = try storage.exportDocument(),destination:URL?
            if let fileChooser { destination = fileChooser(true) }
            else { let panel = NSSavePanel();let date = DateFormatter();date.dateFormat = "yyyyMMdd-HHmmss";panel.nameFieldStringValue = "ZweiCommander-Einstellungen-"+date.string(from:Date())+".json";panel.message = "Die Datei enthält lokale Pfade, Serverprofile und eigene Werkzeugargumente. Einen neuen Dateinamen wählen.";destination = panel.runModal() == .OK ? panel.url : nil }
            guard let destination else { return };try SettingsBackupFile.writeNew(document.encoded(),to:destination)
            status.textColor = .secondaryLabelColor;status.stringValue = "\(document.stores.count) gespeicherte Einstellungsbereiche lokal gesichert.\n"+destination.path
        } catch { show(error) }
    }
    func requestRestore() {
        guard let plan,!isReading,!isApplying,!applied,plan.changedCount > 0,canRestore(),let window,window.attachedSheet == nil else { return }
        let alert = NSAlert();alert.messageText = "Einstellungen vollständig wiederherstellen?"
        alert.informativeText = "\(plan.changedCount) Einstellungsbereiche werden ersetzt oder zurückgesetzt. Der bisherige Stand wird zuvor privat gesichert. Danach ist ein Neustart erforderlich, damit Tabs und Fensteranordnung geladen werden. Schlüsselbund-Passwörter bleiben unverändert."
        alert.addButton(withTitle:"Wiederherstellen");alert.addButton(withTitle:"Abbrechen");confirmation = alert
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self else { return };self.confirmation = nil
            guard response == .alertFirstButtonReturn else { return };self.applyReviewed(plan)
        }
    }
    func applyReviewed(_ reviewed:SettingsBackupRestorePlan) {
        guard !isReading,!isApplying,!applied,canRestore() else { return };isApplying = true;updateButtons()
        do {
            let receipt = try storage.restore(reviewed);isApplying = false;applied = true;plan = nil;restart.isHidden = !storage.requiresRestart
            status.textColor = .secondaryLabelColor;status.stringValue = "Einstellungen vollständig wiederhergestellt. Jetzt neu starten.\nDer bisherige Stand bleibt lokal gesichert: "+receipt.rollbackURL.path;onApplied?(receipt)
        } catch { isApplying = false;show(error) }
        updateButtons()
    }
    private func updateButtons() {
        let enabled = !isApplying && !applied;file.isEnabled = enabled;choose.isEnabled = enabled;save.isEnabled = enabled;refresh.isEnabled = enabled
        apply.isEnabled = enabled && !isReading && (plan?.changedCount ?? 0) > 0 && canRestore();close.isEnabled = !isApplying
    }
    private func show(_ error:Error) { status.textColor = .systemOrange;status.stringValue = error.localizedDescription;status.toolTip = error.localizedDescription }
    func numberOfRows(in tableView:NSTableView) -> Int { plan?.rows.count ?? 0 }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
        guard let plan,plan.rows.indices.contains(row) else { return nil };let value = plan.rows[row],field:NSTextField
        switch column?.identifier.rawValue { case "title":field = label(value.title);case "change":field = label(value.change.title);case "before":field = label(value.currentBytes.map { bytes(Int64($0)) } ?? "—");default:field = label(value.incomingBytes.map { bytes(Int64($0)) } ?? "Standard") }
        field.toolTip = field.stringValue;return field
    }
}
