import AppKit
import CommanderCore

struct MirrorReviewRow {
    let path:String,action:String,amount:Int64,kind:Int,canChoose:Bool
}
final class MirrorReviewController:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate {
    let direction = NSSegmentedControl(labels:["Links → Rechts","Rechts → Links"],trackingMode:.selectOne,target:nil,action:nil)
    let filter = input(placeholder:"Plan nach relativem Pfad filtern"),scope = NSPopUpButton(),table = CommanderTableView()
    let refresh = ActionButton("Neu prüfen",symbol:"arrow.clockwise",action:{}),reset = ActionButton("Auswahl zurücksetzen",action:{})
    let confirmRemovals = checkbox("Die angezeigten zusätzlichen Ziele mit Sicherung entfernen",on:false)
    let start = ActionButton("Spiegelung starten",symbol:"play.fill",action:{}),queue = ActionButton("Vormerken",action:{}),cancel = ActionButton("Schließen",action:{})
    let summary = label("",size:16,weight:.semibold),paths = label("",size:11,color:.secondaryLabelColor),info = label("Prüfe Spiegelungsplan …",size:12,color:.secondaryLabelColor),detail = label("",size:11,color:.secondaryLabelColor)
    private(set) var plan:FolderMirrorPlan?,rows:[MirrorReviewRow] = [],visibleRows:[MirrorReviewRow] = [],isPreparing = false,closed = false
    private(set) var comparison:FolderComparison
    var onStart:((FolderMirrorPlan,Bool)->Void)?
    private var skipping:Set<String> = [],token = CancellationToken(),generation = 0
    private let worker = DispatchQueue(label:"local.zweicommander.mirror-review",qos:.userInitiated)
    init(_ comparison:FolderComparison,direction initialDirection:SyncDirection = .leftToRight) {
        self.comparison = comparison
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:1110,height:710),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = "Ordner spiegeln · Plan prüfen";w.minSize = NSSize(width:1000,height:620);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        let root = OperationContent(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        func top(_ view:NSView,_ x:CGFloat,_ y:CGFloat,_ width:CGFloat,_ height:CGFloat = 28,_ stretch:Bool = false) { view.frame = NSRect(x:x,y:y,width:width,height:height);view.autoresizingMask = [.minYMargin];if stretch { view.autoresizingMask.insert(.width) };root.addSubview(view) }
        top(label("Spiegelungsplan",size:21,weight:.semibold),20,660,1070,32,true)
        top(direction,20,616,400,30);top(refresh,447,616,160,30);top(reset,627,616,210,30)
        top(paths,20,579,1070,26,true);top(summary,20,542,1070,30,true)
        let hint = label("Zuerst kopieren. Zusätzliche Ziele werden anschließend in verborgene Sicherungen verschoben.\nAusgelassene Einträge und Konflikte bleiben erhalten. Fertige Schritte bleiben bei Abbruch erhalten.",size:11,color:.secondaryLabelColor);hint.maximumNumberOfLines = 2;top(hint,20,494,1070,38,true)
        top(filter,20,451,690,28,true);scope.addItems(withTitles:["Alle Schritte","Kopieren","Entfernen","Bleibt erhalten"]);top(scope,730,451,360,28);scope.autoresizingMask = [.minYMargin,.minXMargin]
        table.dataSource = self;table.delegate = self;table.rowHeight = 28;table.usesAlternatingRowBackgroundColors = true;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id,title,width) in [("include","",CGFloat(35)),("action","Aktion",210),("path","Relativer Pfad",625),("size","Größe",140)] { let column = NSTableColumn(identifier:.init(id));column.title = title;column.width = width;column.minWidth = id == "include" ? 35 : 70;table.addTableColumn(column) }
        let scroll = NSScrollView(frame:NSRect(x:20,y:184,width:1070,height:253));scroll.autoresizingMask = [.width,.height];scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.documentView = table;scroll.borderType = .bezelBorder;root.addSubview(scroll)
        confirmRemovals.frame = NSRect(x:20,y:142,width:1070,height:28);confirmRemovals.autoresizingMask = [.width];root.addSubview(confirmRemovals)
        detail.frame = NSRect(x:20,y:110,width:1070,height:25);detail.autoresizingMask = [.width];root.addSubview(detail)
        info.frame = NSRect(x:20,y:62,width:1070,height:40);info.maximumNumberOfLines = 2;info.autoresizingMask = [.width];root.addSubview(info)
        for (button,x,width) in [(cancel,20.0,160.0),(queue,720.0,170.0),(start,910.0,180.0)] { button.frame = NSRect(x:x,y:20,width:width,height:30);if button !== cancel { button.autoresizingMask = [.minXMargin] };root.addSubview(button) }
        self.direction.selectedSegment = initialDirection == .rightToLeft ? 1 : 0
        self.direction.target = self;self.direction.action = #selector(directionChanged);scope.target = self;scope.action = #selector(filterChanged);filter.delegate = self
        confirmRemovals.target = self;confirmRemovals.action = #selector(confirmationChanged)
        refresh.perform = { [weak self] in self?.prepare(recompare:true) };reset.perform = { [weak self] in self?.skipping = [];self?.prepare() }
        cancel.perform = { [weak self] in self?.close() };start.perform = { [weak self] in self?.submit(true) };queue.perform = { [weak self] in self?.submit(false) }
        refresh.setHelp("Neu prüfen","Beide Ordner erneut erfassen und einen neuen Spiegelungsplan aufbauen.",shortcut:"⌘R")
        WorkflowKeys.bind(start,key:"\r",modifiers:.command,title:"⌘↩",detail:"Nur den fertig geprüften und bestätigten Spiegelungsplan starten.")
        WorkflowKeys.bind(queue,key:"\r",modifiers:[.command,.shift],title:"⌘⇧↩",detail:"Diesen geprüften Plan für diese Sitzung vormerken.")
        cancel.setHelp("Schließen","Prüfung abbrechen und ohne neue Dateiänderungen schließen.",shortcut:"Esc")
        filter.toolTip = "Nur die Vorschau filtern; der vollständige Plan bleibt ausgewählt. ⌘F"
        confirmRemovals.toolTip = "Diese Bestätigung gilt nur für die aktuell geprüfte Richtung und Auswahl. Originale bleiben als Sicherungen für Rücknahme und Wiederherstellung erhalten."
        w.workflowKeys = { [weak self] in self?.handleKey($0) ?? false };w.center();prepare()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func directionValue() -> SyncDirection { direction.selectedSegment == 1 ? .rightToLeft : .leftToRight }
    @objc func directionChanged() { skipping = [];prepare() }
    @objc func confirmationChanged() { updateActions() }
    @objc func filterChanged() { filterRows() }
    func controlTextDidChange(_ notification:Notification) { filterRows() }
    func prepare(recompare:Bool = false) {
        guard !closed else { return };generation += 1;token.cancel();token = CancellationToken();let token = token,generation = generation,comparison = comparison,direction = directionValue(),skipping = skipping
        plan = nil;rows = [];visibleRows = [];table.reloadData();confirmRemovals.state = .off;isPreparing = true;info.stringValue = "Prüfe Spiegelungsplan …";info.textColor = .secondaryLabelColor;updateActions()
        worker.async { [weak self] in
            let result = Result { () throws -> (FolderComparison,FolderMirrorPlan) in
                let value = try recompare ? CompareService.compare(comparison.left,comparison.right,options:comparison.options,token:token) : comparison
                guard value.left.path == comparison.left.path,value.right.path == comparison.right.path else { throw CommanderError.message("Vergleichsordner wurden verschoben oder umgeleitet. Bitte im Ordnervergleich erneut auswählen.") }
                return (value,try FolderMirrorPlan.prepare(value,direction:direction,skipping:recompare ? skipping.intersection(Set(value.items.map(\.id))) : skipping,token:token))
            }
            DispatchQueue.main.async {
                guard let self,!self.closed,self.generation == generation else { return };self.isPreparing = false
                switch result {
                case .success(let (comparison,plan)):
                    self.comparison = comparison;self.plan = plan;self.skipping = plan.skippedPaths;self.rebuildRows()
                    self.info.stringValue = plan.initialItems.isEmpty ? "Keine Änderungen ausgewählt." : "Plan bereit · Richtung, einzelne Schritte und zusätzliche Ziele prüfen."
                case .failure(let error):self.info.stringValue = error.localizedDescription;self.info.textColor = .systemRed
                }
                self.updateActions()
            }
        }
    }
    private func rebuildRows() {
        guard let plan else { return }
        rows = plan.copies.steps.map { MirrorReviewRow(path:$0.path,action:$0.isDirectory ? "Ordner anlegen" : $0.replacing ? "Ersetzen mit Sicherung" : "Neu kopieren",amount:$0.bytes,kind:0,canChoose:true) }
        for removal in plan.removals {
            // Each captured descendant is visible, even when one atomic rename preserves its tree.
            for member in removal.members {
                let path = member.path.isEmpty ? removal.path : removal.path+"/"+member.path
                rows.append(MirrorReviewRow(path:path,action:member.isDirectory ? "Ordner mit Sicherung entfernen" : "Mit Sicherung entfernen",amount:member.bytes,kind:1,canChoose:true))
            }
        }
        rows += plan.retained.map { MirrorReviewRow(path:$0.path,action:$0.reason,amount:0,kind:2,canChoose:false) }
        rows += plan.skippedPaths.map { MirrorReviewRow(path:$0,action:"Durch Auswahl ausgelassen",amount:0,kind:2,canChoose:true) }
        rows.sort { $0.path == $1.path ? $0.kind < $1.kind : $0.path < $1.path };filterRows()
        paths.stringValue = plan.source.path+"  →  "+plan.destination.path;paths.toolTip = paths.stringValue
        summary.stringValue = "\(plan.copies.steps.count) Kopierschritte · \(plan.removals.count) Entfernungen · \(bytes(plan.bytes)) kopieren"
        confirmRemovals.title = "\(plan.removals.count) zusätzliche Ziele mit Sicherung entfernen (\(rows.filter { $0.kind == 1 }.count) geprüfte Objekte)"
    }
    func filterRows() {
        let value = filter.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),kind = scope.indexOfSelectedItem-1
        visibleRows = rows.filter { (kind < 0 || $0.kind == kind) && (value.isEmpty || $0.path.localizedCaseInsensitiveContains(value)) };table.reloadData()
        detail.stringValue = "\(visibleRows.count) von \(rows.count) Zeilen sichtbar · Filter ändern den Plan nicht · \(skipping.count) ausdrücklich ausgelassen"
    }
    @objc func toggleRow(_ sender:NSButton) {
        guard !isPreparing,visibleRows.indices.contains(sender.tag) else { return };let row = visibleRows[sender.tag];guard row.canChoose else { return }
        if skipping.contains(row.path) { skipping.remove(row.path) } else { skipping.insert(row.path) };prepare()
    }
    func updateActions() {
        let ready = !isPreparing && plan?.initialItems.isEmpty == false,confirmed = plan?.removals.isEmpty == true || confirmRemovals.state == .on
        start.isEnabled = ready && confirmed;queue.isEnabled = ready && confirmed;refresh.isEnabled = !isPreparing;reset.isEnabled = !isPreparing && !skipping.isEmpty;direction.isEnabled = !isPreparing;confirmRemovals.isEnabled = !isPreparing && plan?.removals.isEmpty == false
    }
    func submit(_ immediately:Bool) { guard start.isEnabled,let plan,!closed else { return };close();onStart?(plan,immediately) }
    func handleKey(_ event:NSEvent) -> Bool {
        if WorkflowKeys.matches(event,"f",.command) { window?.makeFirstResponder(filter);filter.selectText(nil);return true }
        if WorkflowKeys.matches(event,"r",.command) { if refresh.isEnabled { prepare(recompare:true) };return true }
        if WorkflowKeys.matches(event,"\r",.command) { submit(true);return true }
        if WorkflowKeys.matches(event,"\r",[.command,.shift]) { submit(false);return true }
        if WorkflowKeys.matches(event,"1",.command) || WorkflowKeys.matches(event,"2",.command) { if direction.isEnabled { direction.selectedSegment = WorkflowKeys.matches(event,"2",.command) ? 1 : 0;directionChanged() };return true }
        return false
    }
    override func cancelOperation(_ sender:Any?) { close() }
    private func stopReview() { closed = true;generation += 1;token.cancel();isPreparing = false;plan = nil;rows = [];visibleRows = [] }
    override func close() { stopReview();if let window,let parent = window.sheetParent { parent.endSheet(window) };super.close() }
    func windowWillClose(_ notification:Notification) { stopReview();if let window,let parent = window.sheetParent { parent.endSheet(window) } }
    func numberOfRows(in tableView:NSTableView) -> Int { visibleRows.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
        guard visibleRows.indices.contains(row) else { return nil };let value = visibleRows[row]
        if column?.identifier.rawValue == "include" { let check = NSButton(checkboxWithTitle:"",target:self,action:#selector(toggleRow));check.tag = row;check.state = skipping.contains(value.path) ? .off : .on;check.isEnabled = value.canChoose && !isPreparing;check.setAccessibilityLabel("Einbeziehen: "+value.path);return check }
        let text = column?.identifier.rawValue == "action" ? value.action : column?.identifier.rawValue == "path" ? value.path : value.amount > 0 ? bytes(value.amount) : "—"
        let field = label(text,size:12,color:value.kind == 1 ? .systemOrange : value.kind == 2 ? .secondaryLabelColor : .labelColor);field.toolTip = text;field.lineBreakMode = .byTruncatingMiddle;return field
    }
}
