import AppKit
import CommanderCore

final class CompareController: NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate {
    let leftPath = input(),rightPath = input(),chooseLeft = ActionButton("Wählen …",action:{}),chooseRight = ActionButton("Wählen …",action:{})
    let mode = NSPopUpButton(),tolerance = input("1"),include = input("*"),exclude = input(),excludedFolders = input()
    let recursive = checkbox("Unterordner",on:true),hidden = checkbox("Versteckte Einträge",on:true)
    let strategy = NSPopUpButton(),applyStrategy = ActionButton("Vorschlag anwenden",action:{})
    let profilePopup = NSPopUpButton(),profileSave = ActionButton("Speichern",action:{}),profileSaveAs = ActionButton("Speichern als …",action:{}),profileRemove = ActionButton("Löschen …",action:{})
    let profileStatus = label("Eigene Regeln",size:11,color:.secondaryLabelColor)
    let compareButton = ActionButton("Vergleichen",symbol:"arrow.left.arrow.right",action:{}),cancelButton = ActionButton("Abbrechen",action:{}),reviewButton = ActionButton("Plan prüfen …",action:{})
    let table = CommanderTableView(),resultFilter = input(placeholder:"Vergleichsliste nach Pfad filtern"),statusFilter = NSPopUpButton()
    let toRight = ActionButton("Auswahl →",action:{}),toLeft = ActionButton("← Auswahl",action:{}),skip = ActionButton("Auswahl auslassen",action:{})
    let previewLeft = ActionButton("Links ansehen",action:{}),previewRight = ActionButton("Rechts ansehen",action:{}),revealLeft = ActionButton("Links markieren",action:{}),revealRight = ActionButton("Rechts markieren",action:{})
    let info = label("Ordner und Vergleichsregeln wählen, dann Vergleichen.",size:12,color:.secondaryLabelColor),summary = label("",size:12,color:.secondaryLabelColor),detail = label("",size:11,color:.secondaryLabelColor)
    let progress = NSProgressIndicator(),reportButton = ActionButton("Bericht",action:{})
    private(set) var comparison: FolderComparison?,plan: FolderSyncPlan?,rows: [ComparisonItem] = [],visibleRows: [ComparisonItem] = [],directions: [String:SyncDirection] = [:]
    private(set) var isComparing = false,isWorking = false,isPreparingPlan = false,selectedProfileID: UUID?
    var profileNameWindow: CopyProfileNameController?,deleteAlert: NSAlert?,reviewWindow: SyncReviewController?
    var onSubmit: ((FolderSyncPlan,Bool)->UUID)?,onCancel: ((UUID)->Void)?,onPreview: ((URL)->Void)?,onReveal: ((URL,Bool)->Void)?,onReport: ((String)->Void)?
    var onCompareProgress: (() -> Void)?
    var validatePaths: ((URL,URL) throws -> Void)?
    private let worker = DispatchQueue(label:"local.zweicommander.compare",qos:.userInitiated)
    private var token = CancellationToken(),generation = 0,planGeneration = 0,delayed: DispatchWorkItem?,jobID: UUID?
    private var controls: [NSControl] = [],observer: NSObjectProtocol?,library = CompareProfileLibrary(),profileError: String?,lastReport = ""
    init(left: URL,right: URL) {
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:1180,height:835),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title = "Ordner vergleichen und synchronisieren";w.minSize = NSSize(width:1140,height:800);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        let root = OperationContent(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        func top(_ view: NSView,_ x: CGFloat,_ y: CGFloat,_ width: CGFloat,_ height: CGFloat = 26,_ stretch: Bool = false) {
            view.frame = NSRect(x:x,y:y,width:width,height:height);view.autoresizingMask = stretch ? [.minYMargin,.width] : [.minYMargin];root.addSubview(view)
        }
        top(label("Ordnervergleich",size:21,weight:.semibold),22,786,1136,30,true)
        top(profilePopup,22,743,300,28);top(profileSave,332,743,105,28);top(profileSaveAs,447,743,145,28);top(profileRemove,602,743,110,28);top(profileStatus,731,743,427,26,true)
        top(label("Links",weight:.medium),22,704,80);top(leftPath,108,704,899,26,true);top(chooseLeft,1021,703,137,28)
        top(label("Rechts",weight:.medium),22,666,80);top(rightPath,108,666,899,26,true);top(chooseRight,1021,665,137,28)
        for button in [chooseLeft,chooseRight] { button.autoresizingMask = [.minYMargin,.minXMargin] }
        mode.addItems(withTitles:["Inhalte mit SHA-256","Größe und Änderungszeit","Nur Dateigröße"])
        top(label("Prüfung",weight:.medium),22,625,80);top(mode,108,624,320,28);top(label("Zeittoleranz (s)",size:12),450,625,140);top(tolerance,597,625,80);top(recursive,700,625,155);top(hidden,875,625,283)
        top(label("Dateinamen",size:12),22,586,80);top(include,108,586,260);top(label("Auslassen",size:12),388,586,90);top(exclude,484,586,240);top(label("Ordner auslassen",size:12),747,586,150);top(excludedFolders,903,586,255,26,true)
        strategy.addItems(withTitles:["Links → Rechts","Rechts → Links","Neuere und fehlende in beide Richtungen","Nur fehlende in beide Richtungen"])
        top(label("Vorschlag",size:12),22,545,80);top(strategy,108,544,540,28);top(applyStrategy,665,543,220,30)
        top(label("Kein Löschen zusätzlicher Dateien · Ersetzen mit Sicherung",size:11,color:.secondaryLabelColor),22,511,1136,23,true)
        statusFilter.addItems(withTitles:["Alle Zeilen","Unterschiede","Nur links","Nur rechts","Konflikte","Gleiche"])
        top(resultFilter,22,470,330,27);top(statusFilter,366,469,220,28);top(compareButton,774,468,185,30);top(cancelButton,973,468,185,30)
        compareButton.autoresizingMask = [.minYMargin,.minXMargin];cancelButton.autoresizingMask = [.minYMargin,.minXMargin]
        table.delegate = self;table.dataSource = self;table.allowsMultipleSelection = true;table.rowHeight = 30;table.usesAlternatingRowBackgroundColors = true;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id,title,width) in [("path","Relativer Pfad",CGFloat(250)),("state","Vergleich",165),("leftSize","Links",85),("leftDate","Links geändert",145),("action","Kopierentscheidung",175),("rightSize","Rechts",85),("rightDate","Rechts geändert",145)] {
            let c = NSTableColumn(identifier:.init(id));c.title = title;c.width = width;c.minWidth = 65
            if id != "action" { c.sortDescriptorPrototype = NSSortDescriptor(key:id,ascending:true) };table.addTableColumn(c)
        }
        let scroll = NSScrollView(frame:NSRect(x:22,y:213,width:1136,height:242));scroll.autoresizingMask = [.width,.height];scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.borderType = .bezelBorder;root.addSubview(scroll)
        let selectionBar = row([toRight,toLeft,skip,previewLeft,previewRight,revealLeft,revealRight],spacing:8)
        selectionBar.frame = NSRect(x:22,y:169,width:1136,height:30);selectionBar.autoresizingMask = [.width];root.addSubview(selectionBar)
        summary.frame = NSRect(x:22,y:133,width:1136,height:27);summary.autoresizingMask = [.width];root.addSubview(summary)
        detail.frame = NSRect(x:22,y:103,width:1136,height:23);detail.autoresizingMask = [.width];root.addSubview(detail)
        info.frame = NSRect(x:22,y:53,width:900,height:40);info.maximumNumberOfLines = 2;info.autoresizingMask = [.width];root.addSubview(info)
        reviewButton.frame = NSRect(x:973,y:60,width:185,height:30);reviewButton.autoresizingMask = [.minXMargin];root.addSubview(reviewButton)
        reportButton.frame = NSRect(x:1033,y:18,width:125,height:28);reportButton.autoresizingMask = [.minXMargin];root.addSubview(reportButton)
        progress.frame = NSRect(x:22,y:25,width:990,height:12);progress.autoresizingMask = [.width];progress.style = .bar;progress.isIndeterminate = true;progress.isHidden = true;root.addSubview(progress)
        leftPath.stringValue = left.path;rightPath.stringValue = right.path
        chooseLeft.perform = { [weak self] in self?.pickRoot(true) };chooseRight.perform = { [weak self] in self?.pickRoot(false) }
        compareButton.perform = { [weak self] in self?.beginCompare() };cancelButton.perform = { [weak self] in self?.cancel() };reviewButton.perform = { [weak self] in self?.review() }
        applyStrategy.perform = { [weak self] in self?.applySuggestions() };toRight.perform = { [weak self] in self?.setSelected(.leftToRight) };toLeft.perform = { [weak self] in self?.setSelected(.rightToLeft) };skip.perform = { [weak self] in self?.setSelected(.skip) }
        previewLeft.perform = { [weak self] in self?.previewSide(true) };previewRight.perform = { [weak self] in self?.previewSide(false) }
        revealLeft.perform = { [weak self] in self?.revealSide(true) };revealRight.perform = { [weak self] in self?.revealSide(false) }
        reportButton.perform = { [weak self] in if let self { self.onReport?(self.lastReport) } }
        profilePopup.target = self;profilePopup.action = #selector(chooseProfile);profileSave.perform = { [weak self] in self?.saveProfile() };profileSaveAs.perform = { [weak self] in self?.saveProfileAs() };profileRemove.perform = { [weak self] in self?.removeProfile() }
        controls = [leftPath,rightPath,chooseLeft,chooseRight,mode,tolerance,include,exclude,excludedFolders,recursive,hidden,strategy,applyStrategy,profilePopup,profileSave,profileSaveAs,profileRemove]
        for field in [leftPath,rightPath,tolerance,include,exclude,excludedFolders,resultFilter] { field.delegate = self }
        for control: NSControl in [mode,recursive,hidden] { control.target = self;control.action = #selector(edited) }
        strategy.target = self;strategy.action = #selector(strategyChanged);statusFilter.target = self;statusFilter.action = #selector(filterChanged)
        observer = NotificationCenter.default.addObserver(forName:Preferences.compareProfilesChanged,object:nil,queue:.main) { [weak self] _ in self?.refreshProfiles() }
        refreshProfiles();updateActions();cancelButton.isEnabled = false;reportButton.isEnabled = false;w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { token.cancel();delayed?.cancel();if let observer { NotificationCenter.default.removeObserver(observer) } }
    func options() throws -> CompareOptions {
        var value = CompareOptions();value.mode = ComparisonMode.allCases[mode.indexOfSelectedItem];value.strategy = SyncStrategy.allCases[strategy.indexOfSelectedItem]
        guard let tolerance = Int(tolerance.stringValue.trimmingCharacters(in:.whitespaces)) else { throw CommanderError.message("Zeittoleranz als ganze Zahl eingeben.") };value.timeTolerance = tolerance
        value.include = include.stringValue;value.exclude = exclude.stringValue;value.excludedFolders = excludedFolders.stringValue;value.recursive = recursive.state == .on;value.showHidden = hidden.state == .on
        try value.validate();return value
    }
    func setOptions(_ value: CompareOptions) {
        mode.selectItem(at:ComparisonMode.allCases.firstIndex(of:value.mode)!);strategy.selectItem(at:SyncStrategy.allCases.firstIndex(of:value.strategy)!)
        tolerance.stringValue = String(value.timeTolerance);include.stringValue = value.include;exclude.stringValue = value.exclude;excludedFolders.stringValue = value.excludedFolders
        recursive.state = value.recursive ? .on : .off;hidden.state = value.showHidden ? .on : .off;invalidate();updateProfileState()
    }
    private func invalidate() {
        guard !isWorking else { return };generation += 1;token.cancel();delayed?.cancel();planGeneration += 1
        comparison = nil;plan = nil;isPreparingPlan = false;reviewButton.isEnabled = false
    }
    @objc func edited() { guard !isComparing,!isWorking else { return };invalidate();info.stringValue = "Regeln geändert · erneut vergleichen";table.reloadData();updateProfileState();updateActions() }
    @objc func strategyChanged() { updateProfileState() }
    func controlTextDidChange(_ notification: Notification) { if notification.object as? NSTextField === resultFilter { filterRows() } else { edited() } }
    func beginCompare() {
        guard !isComparing,!isWorking else { return }
        do {
            let options = try options(),l = leftPath.stringValue,r = rightPath.stringValue
            guard l.hasPrefix("/"),r.hasPrefix("/"),!l.contains("\0"),!r.contains("\0") else { throw CommanderError.message("Beide Ordner als absolute Pfade angeben.") }
            let left = URL(fileURLWithPath:l),right = URL(fileURLWithPath:r);try validatePaths?(left,right)
            invalidate();isComparing = true;let generation = self.generation,token = CancellationToken();self.token = token
            rows = [];visibleRows = [];directions = [:];table.reloadData();lastReport = "";reportButton.isEnabled = false;setBusy();info.textColor = .secondaryLabelColor;info.stringValue = "Vergleich läuft …"
            worker.async { [weak self] in
                var last = Date.distantPast
                let result = Result { try CompareService.compare(left,right,options:options,token:token,progress:{ detail in
                    guard Date().timeIntervalSince(last) >= 0.1 else { return };last = Date()
                    DispatchQueue.main.sync { guard let self,self.generation == generation else { return };self.info.stringValue = detail;self.onCompareProgress?() }
                }) }
                DispatchQueue.main.async {
                    guard let self,self.generation == generation else { return };self.isComparing = false;self.setBusy()
                    switch result {
                    case .success(let value): self.comparison = value;self.rows = value.items;self.directions = value.suggestions(options.strategy);self.filterRows();self.schedulePlan()
                    case .failure(let error): if case CommanderError.cancelled = error { self.info.stringValue = "Vergleich abgebrochen · keine ausführbare Vorschau" } else { self.showError(error) }
                    }
                }
            }
        } catch { showError(error) }
    }
    func schedulePlan() {
        guard let comparison,!isComparing,!isWorking else { return };delayed?.cancel();plan = nil;reviewButton.isEnabled = false;planGeneration += 1
        let generation = planGeneration,directions = self.directions;isPreparingPlan = true;updateSummary()
        let work = DispatchWorkItem { [weak self] in self?.worker.async {
            let result = Result { try comparison.plan(directions) }
            DispatchQueue.main.async {
                guard let self,self.planGeneration == generation,!self.isWorking else { return };self.isPreparingPlan = false
                switch result {
                case .success(let plan): self.plan = plan;self.info.textColor = .secondaryLabelColor;self.info.stringValue = plan.steps.isEmpty ? "Keine Kopierschritte gewählt." : "Vorschau bereit · vor Ausführung Plan prüfen"
                case .failure(let error): self.showError(error)
                }
                self.updateSummary();self.updateActions()
            }
        } }
        delayed = work;DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
    }
    func applySuggestions() { guard let comparison,!isWorking,!isComparing else { return };directions = comparison.suggestions(SyncStrategy.allCases[strategy.indexOfSelectedItem]);filterRows();schedulePlan() }
    func setSelected(_ direction: SyncDirection) {
        guard comparison != nil,!isWorking,!isComparing else { return }
        for row in selectedRows where row.allowedDirections.contains(direction) { directions[row.id] = direction }
        filterRows();schedulePlan()
    }
    @objc func changeDirection(_ sender: NSPopUpButton) {
        guard comparison != nil,!isWorking,!isComparing,visibleRows.indices.contains(sender.tag),let raw = sender.selectedItem?.representedObject as? String,let direction = SyncDirection(rawValue:raw) else { return }
        let row = visibleRows[sender.tag];guard row.allowedDirections.contains(direction) else { return };directions[row.id] = direction
        if !table.selectedRowIndexes.contains(sender.tag) { table.selectRowIndexes(IndexSet(integer:sender.tag),byExtendingSelection:false) };schedulePlan()
    }
    private func setBusy() {
        let busy = isComparing || isWorking;controls.forEach { $0.isEnabled = !busy };compareButton.isEnabled = !busy;cancelButton.isEnabled = busy
        progress.isHidden = !busy;if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        window?.standardWindowButton(.closeButton)?.isEnabled = !isWorking;table.reloadData();updateProfileState();updateActions()
    }
    func review() {
        guard !isWorking,!isComparing,!isPreparingPlan,let plan,!plan.steps.isEmpty,let window else { return }
        let controller = SyncReviewController(plan);reviewWindow = controller
        controller.onStart = { [weak self] start in self?.submit(plan,start:start) };window.beginSheet(controller.window!)
    }
    private func submit(_ plan: FolderSyncPlan,start: Bool) {
        guard !isWorking,!isComparing,self.plan != nil,let onSubmit else { return };isWorking = true;setBusy();info.stringValue = start ? "Synchronisierung startet …" : "Synchronisierung wartet in der Warteschlange …";jobID = onSubmit(plan,start)
    }
    func updateProgress(_ text: String) { if isWorking { info.stringValue = text } }
    func finished(_ result: Result<OperationReport,Error>) {
        isWorking = false;jobID = nil;setBusy();invalidate();table.reloadData()
        switch result {
        case .success(let report):
            lastReport = "\(report.completed.count) abgeschlossen · \(report.errors.count) Fehler\n"+report.errors.joined(separator:"\n")
            info.stringValue = "\(report.completed.count) Schritte abgeschlossen · erneut vergleichen";info.textColor = report.errors.isEmpty ? .secondaryLabelColor : .systemRed;reportButton.isEnabled = !report.errors.isEmpty
        case .failure(let error): lastReport = error.localizedDescription;info.stringValue = "Auftrag abgebrochen · erneut vergleichen";reportButton.isEnabled = true
        }
        updateSummary();updateActions()
    }
    func cancel() { if isWorking,let jobID { onCancel?(jobID) } else if isComparing { token.cancel();cancelButton.isEnabled = false;info.stringValue = "Vergleich wird abgebrochen …" } }
    override func cancelOperation(_ sender: Any?) { cancel() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isWorking }
    override func close() { guard !isWorking else { return };invalidate();reviewWindow?.close();profileNameWindow?.close();super.close() }
    func windowWillClose(_ notification: Notification) { token.cancel();generation += 1;planGeneration += 1;delayed?.cancel() }
    private func showError(_ error: Error) { info.stringValue = error.localizedDescription;info.toolTip = info.stringValue;info.textColor = .systemRed }
    private func pickRoot(_ left: Bool) {
        let panel = NSOpenPanel();panel.canChooseFiles = false;panel.canChooseDirectories = true;panel.allowsMultipleSelection = false
        if panel.runModal() == .OK,let url = panel.url { (left ? leftPath : rightPath).stringValue = url.path;edited() }
    }
    var selectedRows: [ComparisonItem] { table.selectedRowIndexes.compactMap { visibleRows.indices.contains($0) ? visibleRows[$0] : nil } }
    @objc func filterChanged() { filterRows() }
    func filterRows() {
        let selected = Set(selectedRows.map(\.id)),filter = resultFilter.stringValue,status = statusFilter.indexOfSelectedItem
        visibleRows = rows.filter { row in
            guard filter.isEmpty || row.relativePath.localizedCaseInsensitiveContains(filter) else { return false }
            switch status { case 1:return row.state != .equal;case 2:return row.state == .leftOnly;case 3:return row.state == .rightOnly;case 4:return row.isBlocked;case 5:return row.state == .equal;default:return true }
        }
        if let sort = table.sortDescriptors.first {
            visibleRows.sort { a,b in
                let compare: ComparisonResult
                switch sort.key {
                case "state":compare = a.state.rawValue.localizedStandardCompare(b.state.rawValue)
                case "leftSize","rightSize":let x = (sort.key == "leftSize" ? a.left : a.right)?.size ?? -1,y = (sort.key == "leftSize" ? b.left : b.right)?.size ?? -1;compare = x == y ? .orderedSame : x < y ? .orderedAscending : .orderedDescending
                case "leftDate","rightDate":let x = (sort.key == "leftDate" ? a.left : a.right)?.modified ?? .distantPast,y = (sort.key == "leftDate" ? b.left : b.right)?.modified ?? .distantPast;compare = x.compare(y)
                default:compare = a.relativePath.localizedStandardCompare(b.relativePath)
                }
                let result = compare == .orderedSame ? a.id.compare(b.id) : compare;return sort.ascending ? result == .orderedAscending : result == .orderedDescending
            }
        }
        table.reloadData();table.selectRowIndexes(IndexSet(visibleRows.indices.filter { selected.contains(visibleRows[$0].id) }),byExtendingSelection:false);updateSummary();updateActions()
    }
    func tableView(_ tableView: NSTableView,sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { filterRows() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    private func updateActions() {
        let canEdit = comparison != nil && !isComparing && !isWorking,selected = selectedRows,one = selected.count == 1
        toRight.isEnabled = canEdit && selected.contains { $0.allowedDirections.contains(.leftToRight) };toLeft.isEnabled = canEdit && selected.contains { $0.allowedDirections.contains(.rightToLeft) };skip.isEnabled = canEdit && !selected.isEmpty
        previewLeft.isEnabled = one && selected[0].left?.isRegularFile == true;previewRight.isEnabled = one && selected[0].right?.isRegularFile == true
        revealLeft.isEnabled = one && selected[0].left != nil;revealRight.isEnabled = one && selected[0].right != nil
        applyStrategy.isEnabled = canEdit;reviewButton.isEnabled = canEdit && !isPreparingPlan && plan?.steps.isEmpty == false
        detail.stringValue = one ? selected[0].relativePath+" · "+selected[0].state.rawValue : "Entscheidungen gelten pro Zeile · Elternordner werden bei Bedarf mit angelegt"
    }
    private func updateSummary() {
        let pending = directions.values.filter { $0 == .pending }.count,conflicts = rows.filter(\.isBlocked).count
        summary.stringValue = "\(visibleRows.count) von \(rows.count) Zeilen · \(conflicts) Konflikte · \(pending) Entscheidungen offen"+(plan.map { " · \($0.steps.count) Kopierschritte · \(bytes($0.bytes))" } ?? "")
    }
    private func previewSide(_ left: Bool) { guard selectedRows.count == 1,let entry = left ? selectedRows[0].left : selectedRows[0].right,entry.isRegularFile else { return };onPreview?(entry.url) }
    private func revealSide(_ left: Bool) { guard selectedRows.count == 1,let entry = left ? selectedRows[0].left : selectedRows[0].right else { return };onReveal?(entry.url,left) }
    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int) -> NSView? {
        guard visibleRows.indices.contains(row) else { return nil };let entry = visibleRows[row],id = column?.identifier.rawValue ?? "path"
        if id == "action" {
            let popup = NSPopUpButton();let direction = directions[entry.id] ?? .skip
            for value in (direction == .pending ? [.pending]+entry.allowedDirections : entry.allowedDirections) {
                popup.addItem(withTitle:Self.title(value));popup.lastItem?.representedObject = value.rawValue
            }
            popup.selectItem(at:popup.itemArray.firstIndex { ($0.representedObject as? String) == direction.rawValue } ?? 0)
            popup.tag = row;popup.target = self;popup.action = #selector(changeDirection);popup.isEnabled = comparison != nil && !isComparing && !isWorking && entry.allowedDirections.count > 1;return popup
        }
        let text: String
        switch id {
        case "state":text = entry.state.rawValue
        case "leftSize","rightSize":let value = id == "leftSize" ? entry.left : entry.right;text = value.map { $0.isDirectory ? "Ordner" : bytes($0.size) } ?? "—"
        case "leftDate","rightDate":text = (id == "leftDate" ? entry.left : entry.right).map { displayDate.string(from:$0.modified) } ?? "—"
        default:text = entry.relativePath
        }
        let field = label(text,size:12,color:entry.isBlocked ? .systemOrange : .labelColor);field.toolTip = text;field.lineBreakMode = .byTruncatingMiddle;return field
    }
    static func title(_ direction: SyncDirection) -> String { switch direction { case .skip:return "Auslassen";case .pending:return "Entscheiden …";case .leftToRight:return "Links → Rechts";case .rightToLeft:return "Rechts → Links" } }
    func canPerformCommand(_ id: String) -> Bool {
        let editing = NSApp.keyWindow?.firstResponder is NSTextView
        if window?.attachedSheet != nil { return id == "closeTab" || (editing && ["clipboardCopy","clipboardCut","clipboardPaste","undo","selectAll"].contains(id)) }
        switch id { case "closeTab":return !isWorking;case "refresh","compare":return !isWorking && !isComparing;case "selectAll","help","settings","operations","recovery","pauseTransfers","stopTransfers":return true;case "clipboardCopy","clipboardCut","clipboardPaste","undo":return editing;case "preview":return selectedRows.count == 1 && (selectedRows[0].left?.isRegularFile == true || selectedRows[0].right?.isRegularFile == true);default:return false }
    }
    func command(_ id: String) {
        guard canPerformCommand(id) else { return };let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        switch id { case "closeTab":
            if let sheet = window?.attachedSheet {
                if sheet === reviewWindow?.window { reviewWindow?.close() }
                else if sheet === profileNameWindow?.window { profileNameWindow?.close() }
                else { window?.endSheet(sheet,returnCode:.alertSecondButtonReturn);sheet.orderOut(nil) }
            } else { window?.performClose(nil) }
        case "refresh","compare":beginCompare();case "selectAll":if let editor { editor.selectAll(nil) } else { table.selectAll(nil) };case "clipboardCopy":editor?.copy(nil);case "clipboardCut":editor?.cut(nil);case "clipboardPaste":editor?.paste(nil);case "undo":editor?.undoManager?.undo();case "preview":previewSide(selectedRows[0].left?.isRegularFile == true);default:break }
    }
    func refreshProfiles() {
        do {
            library = try Preferences.compareProfiles();profileError = nil;if let id = selectedProfileID,library.profile(id) == nil { selectedProfileID = nil }
            profilePopup.removeAllItems();profilePopup.addItem(withTitle:"Eigene Regeln")
            for profile in library.profiles { profilePopup.addItem(withTitle:profile.name);profilePopup.lastItem?.representedObject = profile.id.uuidString }
            profilePopup.selectItem(at:profilePopup.itemArray.firstIndex { ($0.representedObject as? String) == selectedProfileID?.uuidString } ?? 0)
        } catch { profileError = error.localizedDescription };updateProfileState()
    }
    private func updateProfileState() {
        let editable = !isWorking && !isComparing && profileError == nil,valid = (try? options()) != nil
        profileSave.isEnabled = editable && valid && selectedProfileID != nil;profileSaveAs.isEnabled = editable && valid;profileRemove.isEnabled = editable && selectedProfileID != nil;profilePopup.isEnabled = editable
        if let profileError { profileStatus.stringValue = "Profile nicht lesbar";profileStatus.toolTip = profileError;profileStatus.textColor = .systemRed }
        else { profileStatus.textColor = .secondaryLabelColor;profileStatus.stringValue = selectedProfileID.flatMap { library.profile($0) }.map { (try? options()) == $0.options ? "Gespeichert" : "Geändert" } ?? "Eigene Regeln" }
    }
    @objc func chooseProfile() {
        guard !isWorking,!isComparing else { return }
        if let raw = profilePopup.selectedItem?.representedObject as? String,let id = UUID(uuidString:raw),let profile = library.profile(id) { selectedProfileID = id;setOptions(profile.options) } else { selectedProfileID = nil };updateProfileState();table.reloadData();updateActions()
    }
    func saveProfile() {
        guard let id = selectedProfileID,let profile = library.profile(id),!isWorking,!isComparing else { return }
        do { let value = try options();try Preferences.editCompareProfiles { _ = try $0.save(name:profile.name,options:value,replacing:id) };refreshProfiles() } catch { profileStatus.stringValue = error.localizedDescription }
    }
    func saveProfileAs() {
        guard !isWorking,!isComparing,(try? options()) != nil,let window else { return }
        let controller = CopyProfileNameController(title:"Vergleichsprofil speichern",message:"Regeln und Vorschlag speichern · keine Ordner oder Einzelentscheidungen");profileNameWindow = controller
        controller.onSave = { [weak self] name in guard let self else { return };let value = try self.options();self.selectedProfileID = try Preferences.editCompareProfiles { try $0.save(name:name,options:value) };self.refreshProfiles() };window.beginSheet(controller.window!)
    }
    func removeProfile() {
        guard !isWorking,!isComparing,let id = selectedProfileID,let profile = library.profile(id),let window else { return }
        let alert = NSAlert();alert.messageText = "Vergleichsprofil löschen?";alert.informativeText = profile.name;alert.addButton(withTitle:"Löschen");alert.addButton(withTitle:"Abbrechen");deleteAlert = alert
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .alertFirstButtonReturn else { return }
            do { try Preferences.editCompareProfiles { try $0.remove(id) };self.selectedProfileID = nil;self.refreshProfiles() } catch { self.profileStatus.stringValue = error.localizedDescription }
        }
    }
}

final class SyncReviewController: NSWindowController,NSTableViewDataSource,NSTableViewDelegate {
    let plan: FolderSyncPlan,table = CommanderTableView(),start = ActionButton("Starten",symbol:"play.fill",action:{}),queue = ActionButton("Vormerken",action:{}),cancel = ActionButton("Abbrechen",action:{})
    var onStart: ((Bool)->Void)?
    init(_ plan: FolderSyncPlan) {
        self.plan = plan;let w = NSWindow(contentRect:NSRect(x:0,y:0,width:1030,height:550),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);w.title = "Synchronisationsplan prüfen";w.minSize = NSSize(width:940,height:450);w.isReleasedWhenClosed = false
        super.init(window:w);let root = OperationContent(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        let title = label("\(plan.steps.count) Schritte · \(bytes(plan.bytes)) · Ersetzen mit Sicherung: \(plan.steps.filter(\.replacing).count)",size:17,weight:.semibold);title.frame = NSRect(x:20,y:494,width:990,height:32);title.autoresizingMask = [.width,.minYMargin];root.addSubview(title)
        let hint = label("Zusätzliche Dateien bleiben erhalten. Fertige Schritte bleiben bei Abbruch erhalten.\nVorgemerkte Synchronisationen gelten nur für diese Sitzung.",size:11,color:.secondaryLabelColor);hint.maximumNumberOfLines = 2;hint.frame = NSRect(x:20,y:458,width:990,height:28);hint.autoresizingMask = [.width,.minYMargin];root.addSubview(hint)
        table.dataSource = self;table.delegate = self;table.rowHeight = 29;table.usesAlternatingRowBackgroundColors = true;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id,title,width) in [("action","Schritt",CGFloat(195)),("source","Quelle",350),("target","Ziel",390),("size","Größe",100)] { let c = NSTableColumn(identifier:.init(id));c.title = title;c.width = width;table.addTableColumn(c) }
        let scroll = NSScrollView(frame:NSRect(x:20,y:65,width:990,height:380));scroll.autoresizingMask = [.width,.height];scroll.documentView = table;scroll.hasHorizontalScroller = true;scroll.hasVerticalScroller = true;scroll.borderType = .bezelBorder;root.addSubview(scroll)
        for (button,x) in [(cancel,20.0),(queue,690.0),(start,855.0)] { button.frame = NSRect(x:x,y:20,width:155,height:30);button.autoresizingMask = button === cancel ? [] : [.minXMargin];root.addSubview(button) }
        cancel.perform = { [weak self] in self?.close() };start.perform = { [weak self] in self?.close();self?.onStart?(true) };queue.perform = { [weak self] in self?.close();self?.onStart?(false) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func close() { if let window,let parent = window.sheetParent { parent.endSheet(window) };super.close() }
    func numberOfRows(in tableView: NSTableView) -> Int { plan.steps.count }
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int) -> NSView? {
        guard plan.steps.indices.contains(row) else { return nil };let step = plan.steps[row],text: String
        switch column?.identifier.rawValue { case "action":text = step.isDirectory ? "Ordner anlegen" : step.replacing ? "Ersetzen mit Sicherung" : "Neu kopieren";case "source":text = step.source.path;case "target":text = step.destination.path;default:text = bytes(step.bytes) }
        let view = label(text,size:12);view.toolTip = text;view.lineBreakMode = .byTruncatingMiddle;return view
    }
}
