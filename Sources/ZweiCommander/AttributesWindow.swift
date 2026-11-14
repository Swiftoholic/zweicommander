import AppKit
import CommanderCore

final class AttributesController:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate {
    let permissions = input(placeholder:"Unverändert · z. B. 644 oder 0755")
    let createdMode = NSPopUpButton(),modifiedMode = NSPopUpButton(),accessedMode = NSPopUpButton(),timeZone = NSPopUpButton()
    let createdValue = input(),modifiedValue = input(),accessedValue = input()
    let files = checkbox("Dateien",on:true),folders = checkbox("Ordner",on:true),recursive = checkbox("Unterordner einbeziehen",on:false),regex = checkbox("RegEx",on:false)
    let include = input("*",placeholder:"Namensmuster"),exclude = input(placeholder:"Namen ausschließen"),excludedFolders = input(placeholder:"Unterordner ausschließen")
    let criteria = ActionButton("Größe / Datum …",action:{}),refresh = ActionButton("Neu prüfen",symbol:"arrow.clockwise",action:{})
    let reviewFilter = input(placeholder:"Vorschau nach Pfad filtern"),table = CommanderTableView(),scroll = NSScrollView()
    let summary = label("",size:15,weight:.semibold),info = label("",size:12,color:.secondaryLabelColor),result = label("",size:11,color:.secondaryLabelColor)
    let start = ActionButton("Änderungen anwenden",symbol:"play.fill",action:{}),queue = ActionButton("Vormerken",action:{}),cancel = ActionButton("Schließen",action:{}),undo = ActionButton("Letzte Änderung zurücknehmen",symbol:"arrow.uturn.backward",action:{})
    let sources:[URL]
    private(set) var plan:AttributePlan?,rows:[AttributeRow] = [],isPreparing = false,isWorking = false,closed = false
    private(set) var lastReport:AttributeReport?,receipts:[AttributeReceipt] = []
    var onSubmit:((AttributePlan,Bool)->UUID?)?,onCancel:((UUID)->Void)?,onAfterMutation:(()->Void)?
    private var filter = TransferFilter(),skipped = Set<String>(),generation = 0,token = CancellationToken(),jobID:UUID?,editWork:DispatchWorkItem?
    private let worker = DispatchQueue(label:"local.zweicommander.attribute-review",qos:.userInitiated)
    init(sources:[URL]) {
        self.sources = sources;filter.recursive = false
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:1150,height:800),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = "Rechte und Zeitstempel · Änderungen prüfen";w.minSize = NSSize(width:1060,height:740);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        let root = OperationContent(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        func top(_ view:NSView,_ x:CGFloat,_ y:CGFloat,_ width:CGFloat,_ height:CGFloat = 28,_ stretch:Bool = false) { view.frame = NSRect(x:x,y:y,width:width,height:height);view.autoresizingMask = [.minYMargin];if stretch { view.autoresizingMask.insert(.width) };root.addSubview(view) }
        top(label("Rechte und Zeitstempel",size:21,weight:.semibold),20,750,1110,32,true)
        top(label("Nur gewählte Felder ändern. Vorschau und Auswahl gelten für den vollständigen Auftrag.",size:11,color:.secondaryLabelColor),20,720,1110,24,true)
        top(label("POSIX-Rechte",weight:.medium),20,680,130);top(permissions,155,680,310)
        top(files,490,680,100);top(folders,600,680,100);top(recursive,730,680,255)
        top(label("Zeitzone",weight:.medium),20,640,130);timeZone.addItems(withTitles:["Lokal · "+TimeZone.current.identifier,"UTC"]);top(timeZone,155,640,310)
        top(label("Verschieben: vorzeichenbehaftete Sekunden, 3600 = eine Stunde; keine Kalender-/Sommerzeitkorrektur.",size:11,color:.secondaryLabelColor),490,640,640,28,true)
        for (title,mode,value,y) in [("Erstellt",createdMode,createdValue,600.0),("Geändert",modifiedMode,modifiedValue,560.0),("Letzter Zugriff",accessedMode,accessedValue,520.0)] {
            top(label(title,weight:.medium),20,y,130);mode.addItems(withTitles:["Unverändert","Zeitpunkt setzen","Um Sekunden verschieben"]);top(mode,155,y,310);top(value,490,y,640,28,true)
            mode.target = self;mode.action = #selector(ruleControlChanged);value.delegate = self
        }
        top(label("Namensfilter",weight:.medium),20,478,130);top(include,155,478,310);top(exclude,490,478,350,28,true);top(regex,860,478,100)
        top(label("Unterordner",weight:.medium),20,438,130);top(excludedFolders,155,438,310);top(criteria,490,438,200);top(refresh,860,438,270);refresh.autoresizingMask = [.minYMargin,.minXMargin]
        top(summary,20,397,1110,27,true);top(reviewFilter,20,360,1110,28,true)
        table.dataSource = self;table.delegate = self;table.rowHeight = 35;table.usesAlternatingRowBackgroundColors = true;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id,title,width) in [("include","",CGFloat(32)),("name","Objekt / Pfad",360),("before","Vorher",300),("after","Nachher / Hinweis",400)] { let column = NSTableColumn(identifier:.init(id));column.title = title;column.width = width;column.minWidth = id == "include" ? 32 : 150;table.addTableColumn(column) }
        scroll.frame = NSRect(x:20,y:170,width:1110,height:176);scroll.autoresizingMask = [.width,.height];scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.borderType = .bezelBorder;root.addSubview(scroll)
        info.frame = NSRect(x:20,y:125,width:1110,height:37);info.maximumNumberOfLines = 2;info.lineBreakMode = .byWordWrapping;info.autoresizingMask = [.width];root.addSubview(info)
        result.frame = NSRect(x:20,y:86,width:1110,height:34);result.maximumNumberOfLines = 2;result.lineBreakMode = .byWordWrapping;result.autoresizingMask = [.width];root.addSubview(result)
        let limits = label("Links und Spezialdateien bleiben erhalten. Eigentümer, Gruppen und ACLs werden nicht geändert. Rücknahme gilt für unveränderte Objekte mit verfügbaren Belegen in diesem Fenster.",size:10,color:.secondaryLabelColor);limits.frame = NSRect(x:20,y:55,width:1110,height:29);limits.maximumNumberOfLines = 2;limits.lineBreakMode = .byWordWrapping;limits.autoresizingMask = [.width];root.addSubview(limits)
        for (button,x,width) in [(cancel,20.0,120.0),(undo,155.0,300.0),(queue,730.0,170.0),(start,920.0,210.0)] { button.frame = NSRect(x:x,y:16,width:width,height:29);if button === queue || button === start { button.autoresizingMask = [.minXMargin] };root.addSubview(button) }
        for field in [permissions,include,exclude,excludedFolders,reviewFilter] { field.delegate = self }
        for control in [files,folders,recursive,regex,timeZone] as [NSControl] { control.target = self;control.action = #selector(ruleControlChanged) }
        refresh.perform = { [weak self] in self?.prepare() };criteria.perform = { [weak self] in self?.editCriteria() }
        start.perform = { [weak self] in self?.submit(true) };queue.perform = { [weak self] in self?.submit(false) };cancel.perform = { [weak self] in self?.cancelWork() };undo.perform = { [weak self] in self?.undoChanges() }
        WorkflowKeys.bind(start,key:"\r",modifiers:.command,title:"⌘↩",detail:"Den angezeigten, geprüften Änderungsplan anwenden.")
        WorkflowKeys.bind(queue,key:"\r",modifiers:[.command,.shift],title:"⌘⇧↩",detail:"Diesen geprüften Plan für diese Sitzung vormerken.")
        refresh.setHelp("Neu prüfen","Objekte, Dateifilter und geplante Eigenschaften neu prüfen.",shortcut:"⌘R")
        criteria.setHelp("Größe / Datum","Dateifilter für Größe, Änderungsdatum oder relatives Alter einstellen.",shortcut:"⌘⌥O")
        undo.setHelp("Letzte Änderung zurücknehmen","Nur unveränderte, erreichbare Objekte der letzten Ausführung zurücknehmen.",shortcut:"⌘Z außerhalb von Textfeldern")
        permissions.toolTip = "Leeres Feld behält die Rechte. Drei oder vier Oktalziffern, 0000 bis 7777. Derselbe Wert gilt für alle ausgewählten Dateien und Ordner. ⌘L"
        recursive.toolTip = "Unterordner mit vollständiger Dateiliste erfassen. Höchstens 10.000 Objekte und 100 Unterordnerebenen."
        reviewFilter.toolTip = "Nur die sichtbare Vorschau filtern; die vollständige Auswahl bleibt im Plan. ⌘F"
        cancel.setHelp("Schließen / Stoppen","Vorbereitung abbrechen; einen laufenden Auftrag zum Stoppen anfordern.",shortcut:"Esc")
        table.workflowKeys = { [weak self] event in if WorkflowKeys.matches(event," ") { self?.toggleSelectedRow();return true };return false }
        w.workflowKeys = { [weak self] in self?.handleKey($0) ?? false };w.initialFirstResponder = permissions;w.center();updateTimeInputs();prepare()
    }
    required init?(coder:NSCoder) { fatalError() }
    func currentRule() throws -> AttributeRule {
        var rule = AttributeRule();rule.permissions = try AttributeRule.parsePermissions(permissions.stringValue);rule.files = files.state == .on;rule.folders = folders.state == .on
        rule.filter = filter;rule.filter.include = include.stringValue;rule.filter.exclude = exclude.stringValue;rule.filter.excludedFolders = excludedFolders.stringValue;rule.filter.regularExpressions = regex.state == .on;rule.filter.recursive = recursive.state == .on
        let zone = timeZone.indexOfSelectedItem == 1 ? TimeZone(secondsFromGMT:0)! : TimeZone.current
        func change(_ mode:NSPopUpButton,_ field:NSTextField) throws -> AttributeTimeChange {
            if mode.indexOfSelectedItem == 0 { return .unchanged }
            if mode.indexOfSelectedItem == 1 { return .absolute(try AttributeTimestamp.parse(field.stringValue,timeZone:zone)) }
            let text = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            guard text.utf8.count <= 21,let seconds = Int64(text),String(seconds) == text || "+"+String(seconds) == text else { throw CommanderError.message("Zeitverschiebung als ganze Sekunden mit optionalem Vorzeichen eingeben.") };return .shift(seconds:seconds)
        }
        rule.created = try change(createdMode,createdValue);rule.modified = try change(modifiedMode,modifiedValue);rule.accessed = try change(accessedMode,accessedValue);try rule.validate();return rule
    }
    func updateTimeInputs() { for (mode,field) in [(createdMode,createdValue),(modifiedMode,modifiedValue),(accessedMode,accessedValue)] { field.isEnabled = !isWorking && mode.indexOfSelectedItem != 0;field.placeholderString = mode.indexOfSelectedItem == 2 ? "z. B. -3600 oder +3600" : "JJJJ-MM-TT HH:mm:ss" } }
    @objc func ruleControlChanged() { updateTimeInputs();schedulePreparation() }
    func controlTextDidChange(_ notification:Notification) { if notification.object as? NSTextField === reviewFilter { filterRows() } else { schedulePreparation() } }
    func schedulePreparation() {
        guard !closed,!isWorking else { return };editWork?.cancel();generation += 1;token.cancel();plan = nil;rows = [];table.reloadData();isPreparing = true;info.stringValue = "Eingaben geändert · Vorschau wird neu geprüft …";updateActions()
        let work = DispatchWorkItem { [weak self] in self?.prepare() };editWork = work;DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work)
    }
    func prepare() {
        guard !closed,!isWorking else { return };editWork?.cancel();editWork = nil;generation += 1;token.cancel();token = CancellationToken();let token = token,generation = generation,sources = sources,skipped = skipped
        plan = nil;rows = [];table.reloadData();isPreparing = true;info.textColor = .secondaryLabelColor;info.stringValue = "Objekte und Eigenschaften werden geprüft …";updateActions()
        let rule:AttributeRule
        do { rule = try currentRule() } catch { isPreparing = false;info.textColor = .systemRed;info.stringValue = error.localizedDescription;info.toolTip = info.stringValue;updateActions();return }
        worker.async { [weak self] in
            let result = Result { () throws -> AttributePlan in let full = try AttributePlan.prepare(sources:sources,rule:rule,token:token);return try full.selecting(paths:Set(full.rows.filter(\.canSelect).map(\.id)).subtracting(skipped)) }
            DispatchQueue.main.async {
                guard let self,!self.closed,self.generation == generation,!token.isCancelled else { return };self.isPreparing = false
                switch result {
                case .success(let plan):self.plan = plan;self.filterRows();self.info.stringValue = plan.canApply ? "Plan bereit · Häkchen bestimmen die tatsächlich geänderten Objekte." : rule.hasChanges ? "Keine passende Änderung ausgewählt." : "Gewünschte Rechte oder Zeitstempel eingeben. Leere Felder bleiben unverändert."
                case .failure(let error):self.info.textColor = .systemRed;self.info.stringValue = error.localizedDescription;self.info.toolTip = self.info.stringValue
                }
                self.updateActions()
            }
        }
    }
    func filterRows() {
        let text = reviewFilter.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);rows = plan?.rows.filter { text.isEmpty || $0.source.path.localizedCaseInsensitiveContains(text) } ?? [];table.reloadData()
        summary.stringValue = "\(plan?.selectedRows.count ?? 0) Änderungen ausgewählt · \(rows.count) von \(plan?.rows.count ?? 0) Objekten sichtbar"
    }
    @objc func toggleRow(_ sender:NSButton) { guard rows.indices.contains(sender.tag) else { return };toggle(rows[sender.tag]) }
    func toggleSelectedRow() { guard rows.indices.contains(table.selectedRow) else { return };toggle(rows[table.selectedRow]) }
    private func toggle(_ row:AttributeRow) {
        guard !isWorking,!isPreparing,row.canSelect,let plan else { return };if row.selected { skipped.insert(row.id) } else { skipped.remove(row.id) }
        do { self.plan = try plan.selecting(paths:Set(plan.rows.filter(\.canSelect).map(\.id)).subtracting(skipped));filterRows();updateActions() } catch { info.textColor = .systemRed;info.stringValue = error.localizedDescription }
    }
    func editCriteria() {
        guard !closed,!isWorking else { return };var value = filter;value.recursive = recursive.state == .on
        let editor = TransferCriteriaController(value);editor.onApply = { [weak self] in self?.filter = $0;self?.prepare() }
        guard let parent = window,let sheet = editor.window else { return };parent.beginSheet(sheet) { [editor] _ in _ = editor }
    }
    func updateActions() {
        let ready = !closed && !isPreparing && !isWorking && plan?.canApply == true
        start.isEnabled = ready;queue.isEnabled = ready;refresh.isEnabled = !isWorking;criteria.isEnabled = !isWorking;undo.isEnabled = !closed && !isPreparing && !isWorking && !receipts.isEmpty
        for control in [permissions,createdMode,modifiedMode,accessedMode,timeZone,files,folders,recursive,include,exclude,excludedFolders,regex] as [NSControl] { control.isEnabled = !isWorking }
        updateTimeInputs();cancel.title = isWorking || isPreparing ? "Stoppen" : "Schließen"
    }
    func submit(_ immediately:Bool) {
        guard !closed,!isPreparing,!isWorking,let plan,plan.canApply else { return }
        guard let id = onSubmit?(plan,immediately) else { info.textColor = .systemRed;info.stringValue = "Der geprüfte Auftrag konnte nicht übernommen werden.";return }
        jobID = id;isWorking = true;info.textColor = .secondaryLabelColor;info.stringValue = immediately ? "Auftrag gestartet · fertige Änderungen bleiben bei Abbruch erhalten." : "Auftrag vorgemerkt · Änderungen gelten erst beim Start.";updateActions()
    }
    func finished(_ report:AttributeReport) {
        guard !closed else { return };jobID = nil;isWorking = false;var summaryReport = report;summaryReport.receipts = [];lastReport = summaryReport;receipts = report.receipts;onAfterMutation?()
        result.stringValue = "\(report.completed.count) abgeschlossen · \(report.skipped.count) ausgelassen · \(report.errors.count) Fehler"+(report.errors.first.map { "\n"+$0 } ?? "");result.toolTip = report.errors.joined(separator:"\n");result.textColor = report.errors.isEmpty ? .secondaryLabelColor : .systemRed
        skipped = [];plan = nil;info.stringValue = "Auftrag beendet · Für weitere Änderungen erneut prüfen.";summary.stringValue = "\(report.completed.count) abgeschlossen · letzte geprüfte Vorschau";table.reloadData();updateActions()
    }
    func finished(_ result:Result<AttributeReport,Error>) { switch result { case .success(let report):finished(report);case .failure(let error):var report = AttributeReport();report.errors = [error.localizedDescription];finished(report) } }
    func undoChanges() {
        guard undo.isEnabled,!receipts.isEmpty else { return };generation += 1;token.cancel();token = CancellationToken();let token = token,receipts = receipts,generation = generation;isWorking = true;updateActions();info.stringValue = "Unveränderte Objekte werden für die Rücknahme geprüft …"
        worker.async { [weak self] in let report = AttributeEngine.undo(receipts,token:token);DispatchQueue.main.async {
            guard let self,!self.closed,self.generation == generation else { return };self.isWorking = false;self.receipts = report.receipts;self.onAfterMutation?()
            self.result.stringValue = "\(report.completed.count) Eigenschaften zurückgenommen · \(report.errors.count) Fehler"+(report.errors.first.map { "\n"+$0 } ?? "");self.result.toolTip = report.errors.joined(separator:"\n");self.result.textColor = report.errors.isEmpty ? .secondaryLabelColor : .systemRed;self.plan = nil;self.rows = [];self.table.reloadData();self.summary.stringValue = "Rücknahme beendet · \(self.receipts.count) Belege verbleiben";self.info.stringValue = "Für einen weiteren Änderungsplan erneut prüfen.";self.updateActions()
        } }
    }
    func cancelWork() {
        if isWorking { if let jobID { onCancel?(jobID) } else { token.cancel() };if isWorking { info.stringValue = "Stoppen angefordert · fertige Änderungen bleiben erhalten." };return }
        if isPreparing { generation += 1;token.cancel();editWork?.cancel();editWork = nil;isPreparing = false;plan = nil;rows = [];table.reloadData();info.stringValue = "Vorbereitung abgebrochen.";updateActions();return };close()
    }
    func handleKey(_ event:NSEvent) -> Bool {
        if WorkflowKeys.matches(event,"r",.command) { if refresh.isEnabled { prepare() };return true }
        if WorkflowKeys.matches(event,"l",.command) { if permissions.isEnabled { window?.makeFirstResponder(permissions);permissions.selectText(nil) };return true }
        if WorkflowKeys.matches(event,"f",.command) { window?.makeFirstResponder(reviewFilter);reviewFilter.selectText(nil);return true }
        if WorkflowKeys.matches(event,"o",[.command,.option]) { editCriteria();return true }
        if WorkflowKeys.matches(event,"\r",.command) { submit(true);return true }
        if WorkflowKeys.matches(event,"\r",[.command,.shift]) { submit(false);return true }
        if WorkflowKeys.matches(event,"z",.command),!(window?.firstResponder is NSTextView) { undoChanges();return true }
        return false
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { if isWorking { cancelWork();return false };return true }
    override func cancelOperation(_ sender:Any?) { cancelWork() }
    override func close() { guard !isWorking else { cancelWork();return };stop();super.close() }
    func windowWillClose(_ notification:Notification) { stop() }
    private func stop() { closed = true;generation += 1;token.cancel();editWork?.cancel();editWork = nil;plan = nil;receipts = [];lastReport?.receipts = [];onSubmit = nil;onCancel = nil;onAfterMutation = nil }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil };let value = rows[row]
        if column?.identifier.rawValue == "include" { let check = NSButton(checkboxWithTitle:"",target:self,action:#selector(toggleRow));check.tag = row;check.state = value.selected ? .on : .off;check.isEnabled = plan != nil && value.canSelect && !isPreparing && !isWorking;check.setAccessibilityLabel("Eigenschaften ändern: "+value.source.lastPathComponent);return check }
        let text:String
        if column?.identifier.rawValue == "name" { text = value.source.path }
        else if column?.identifier.rawValue == "before" { text = description(permissions:value.before.permissions,created:value.before.created,modified:value.before.modified,accessed:value.before.accessed) }
        else if let reason = value.reason { text = reason }
        else if let after = value.after { text = description(permissions:after.permissions,created:after.created,modified:after.modified,accessed:after.accessed) }
        else { text = "Unverändert" }
        let field = label(text,size:11,color:value.reason != nil ? .secondaryLabelColor : .labelColor);field.toolTip = text;field.maximumNumberOfLines = 2;field.lineBreakMode = .byTruncatingMiddle;return field
    }
    private func description(permissions:UInt16,created:AttributeTimestamp,modified:AttributeTimestamp,accessed:AttributeTimestamp) -> String {
        let formatter = DateFormatter();formatter.locale = Locale(identifier:"en_US_POSIX");formatter.timeZone = timeZone.indexOfSelectedItem == 1 ? TimeZone(secondsFromGMT:0)! : .current;formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return String(format:"%04o",permissions)+" · Erstellt "+formatter.string(from:created.date)+"\nGeändert "+formatter.string(from:modified.date)+" · Zugriff "+formatter.string(from:accessed.date)
    }
}
