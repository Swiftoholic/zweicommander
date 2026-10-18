import AppKit
import CommanderCore

private let operationDate: DateFormatter = { let value = DateFormatter();value.dateFormat = "dd.MM.yyyy HH:mm";return value }()

final class OperationContent: NSView {
    override init(frame: NSRect) {
        super.init(frame:frame);wantsLayer = true;updateBackground()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();updateBackground() }
}

private func operationTable(_ columns: [(String,String,CGFloat)]) -> NSTableView {
    let table = NSTableView(); table.rowHeight = 29; table.usesAlternatingRowBackgroundColors = true
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.allowsMultipleSelection = false
    for (id,title,width) in columns { let c = NSTableColumn(identifier:.init(id));c.title = title;c.width = width;c.minWidth = 45;table.addTableColumn(c) }
    return table
}
private func operationScroll(_ table: NSTableView) -> NSScrollView {
    let scroll = NSScrollView();scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.autohidesScrollers = true;scroll.borderType = .bezelBorder;return scroll
}

final class TransferSetupController: NSWindowController,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate,NSWindowDelegate,NSTabViewDelegate {
    let sources: [URL], kind: TransferKind
    let destination: NSTextField
    let policy = NSPopUpButton()
    let mergeFolders = checkbox("Ordner zusammenführen")
    let include = input("*",placeholder:"*.txt;*.md")
    let exclude = input(placeholder:"*.tmp;*.bak")
    let excludedFolders = input(placeholder:".git;node_modules;Cache*")
    let recursive = checkbox("Unterordner einbeziehen",on:true)
    let keepEmpty = checkbox("Leere Ordner übernehmen",on:true)
    let structureOnly = checkbox("Nur Ordnerstruktur")
    let regex = checkbox("Dateimuster als RegEx")
    let resetButton = ActionButton("Filter zurücksetzen",action:{})
    let profilePopup = NSPopUpButton()
    let profileSave = ActionButton("Speichern",action:{})
    let profileSaveAs = ActionButton("Speichern als …",action:{})
    let profileRemove = ActionButton("Löschen …",action:{})
    let profileStatus = label("Eigene Einstellungen",size:11,color:.secondaryLabelColor)
    let criteriaButton = ActionButton("Größe / Datum …",symbol:"line.3.horizontal.decrease",action:{})
    let criteriaInfo = label("Keine zusätzlichen Grenzen",size:11,color:.secondaryLabelColor)
    var criteria = TransferFilter()
    var criteriaWindow: TransferCriteriaController?
    var profileNameWindow: CopyProfileNameController?
    private(set) var selectedProfileID: UUID?
    private var loadedProfiles = CopyProfileLibrary()
    private var profileReadError: String?
    private var profileObserver: NSObjectProtocol?
    private var keepEmptyBeforeStructure: NSControl.StateValue?
    let tabs = NSTabView()
    let selectionButton = ActionButton("Auswahl",symbol:"checklist",action:{})
    let objectsButton = ActionButton("Geplante Objekte",symbol:"list.bullet",action:{})
    let table = operationTable([("include","",45),("name","Auswahlobjekt",290),("size","Größe",100),("count","Objekte",80),("target","Ziel / Hinweis",400)])
    let filesTable = operationTable([("path","Relativer Pfad",220),("action","Aktion",215),("size","Quelle",75),("targetSize","Ziel",75),("sourceDate","Quelle geändert",155),("targetDate","Ziel geändert",155)])
    let info = label("Erfasse Dateien …",color:.secondaryLabelColor)
    let safety = label("",size:11,color:.secondaryLabelColor)
    let startButton = ActionButton("Starten",symbol:"play.fill",action:{})
    let queueButton = ActionButton("Vormerken",symbol:"text.badge.plus",action:{})
    var plan: TransferPlan?
    var excluded: Set<URL> = []
    private var preparation = CancellationToken()
    private var generation = 0
    private var previewEntries: [PlannedTransfer] = []
    private var previewMerge: MergePlan?
    private var previewOffsets: [Int] = []
    private(set) var previewCount = 0
    var onSubmit: ((TransferPlan,Bool) -> Bool)?
    var recoveryNotice: String?
    let validateDestination: (URL) throws -> Void
    init(sources: [URL],destination: URL,kind: TransferKind,validateDestination: @escaping (URL) throws -> Void) {
        self.sources = sources;self.kind = kind;self.destination = input(destination.path);self.validateDestination = validateDestination
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:1060,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = kind == .copy ? "Dateien kopieren · Auftrag prüfen" : "Dateien verschieben · Auftrag prüfen";w.minSize = NSSize(width:960,height:680);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        let root = OperationContent(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        func top(_ view: NSView,_ x: CGFloat,_ y: CGFloat,_ width: CGFloat,_ height: CGFloat = 26,_ stretch: Bool = false) {
            view.frame = NSRect(x:x,y:y,width:width,height:height);view.autoresizingMask = stretch ? [.minYMargin,.width] : [.minYMargin];root.addSubview(view)
        }
        top(label(kind == .copy ? "Kopierauftrag" : "Verschiebeauftrag",size:20,weight:.semibold),22,712,1016,30,true)
        top(label("Kopierprofil",weight:.medium),22,681,100)
        top(profilePopup,125,680,285,28);profilePopup.target = self;profilePopup.action = #selector(chooseProfile)
        top(profileSave,420,680,105,28);profileSave.perform = { [weak self] in self?.saveProfile() }
        top(profileSaveAs,535,680,150,28);profileSaveAs.perform = { [weak self] in self?.saveProfileAs() }
        top(profileRemove,695,680,100,28);profileRemove.perform = { [weak self] in self?.removeProfile() }
        top(profileStatus,805,681,233,26,true)
        top(label("Zielordner",weight:.medium),22,642,100)
        top(self.destination,125,642,771,26,true);self.destination.delegate = self;self.destination.target = self;self.destination.action = #selector(rebuild)
        let choose = ActionButton("Wählen …",symbol:"folder",action:{ [weak self] in self?.chooseDestination() });top(choose,906,641,132,28);choose.autoresizingMask = [.minYMargin,.minXMargin]
        top(label("Namenskonflikte",weight:.medium),22,600,125)
        policy.addItems(withTitles:["Abbrechen bei Konflikt","Überspringen","Beide behalten","Ersetzen mit Sicherung"]);top(policy,155,599,285,28);policy.target = self;policy.action = #selector(rebuild)
        top(mergeFolders,456,600,260,26);mergeFolders.target = self;mergeFolders.action = #selector(filterOptionChanged)
        let refresh = ActionButton("Plan aktualisieren",symbol:"arrow.clockwise",action:{ [weak self] in self?.prepare() });top(refresh,852,598,186,29);refresh.autoresizingMask = [.minYMargin,.minXMargin]
        for (title,field,y) in [("Dateien einschließen",include,560.0),("Dateien ausschließen",exclude,523.0),("Unterordner auslassen",excludedFolders,486.0)] {
            top(label(title,weight:.medium),22,y,155);top(field,185,y,853,26,true);field.delegate = self;field.target = self;field.action = #selector(rebuild)
        }
        let options = row([recursive,keepEmpty,structureOnly,regex],spacing:18);top(options,22,448,1016,28,true)
        for button in [recursive,keepEmpty,structureOnly,regex] { button.target = self;button.action = #selector(filterOptionChanged) }
        let rule = kind == .copy ? "Dateinamen: * und ? · mehrere Muster mit ; · Groß/Klein wird ignoriert · Unterordnermuster gelten immer als Wildcards." : "Filter und Strukturkopie sind nur beim Kopieren verfügbar. Verschieben übernimmt die vollständige Auswahl."
        top(label(rule,size:11,color:.secondaryLabelColor),22,421,1016,22,true)
        table.delegate = self;table.dataSource = self;filesTable.delegate = self;filesTable.dataSource = self
        for column in filesTable.tableColumns where column.identifier.rawValue.hasSuffix("Date") { column.minWidth = 145 }
        tabs.tabViewType = .noTabsNoBorder;tabs.delegate = self
        for (id,title,content) in [("selection","Auswahl",table),("files","Geplante Objekte",filesTable)] {
            let item = NSTabViewItem(identifier:id);item.label = title
            let pane = NSView(frame:NSRect(x:0,y:0,width:990,height:270));let scroll = operationScroll(content);scroll.frame = pane.bounds;scroll.autoresizingMask = [.width,.height];pane.addSubview(scroll);item.view = pane;tabs.addTabViewItem(item)
        }
        top(selectionButton,22,382,130,28);top(objectsButton,160,382,190,28)
        top(criteriaButton,500,382,185,28);criteriaButton.perform = { [weak self] in self?.showCriteria() }
        top(criteriaInfo,695,384,343,24,true)
        for button in [selectionButton,objectsButton] { button.setButtonType(.pushOnPushOff) }
        selectionButton.perform = { [weak self] in self?.tabs.selectTabViewItem(at:0);self?.updateTabButtons() }
        objectsButton.perform = { [weak self] in self?.tabs.selectTabViewItem(at:1);self?.updateTabButtons() }
        updateTabButtons()
        tabs.wantsLayer = true;tabs.frame = NSRect(x:22,y:110,width:1016,height:267);tabs.autoresizingMask = [.width,.height];root.addSubview(tabs)
        info.frame = NSRect(x:22,y:77,width:1016,height:24);info.autoresizingMask = [.width];root.addSubview(info)
        safety.frame = NSRect(x:22,y:52,width:1016,height:20);safety.autoresizingMask = [.width];root.addSubview(safety)
        let cancel = ActionButton("Abbrechen",action:{ [weak self] in self?.close() });cancel.frame = NSRect(x:22,y:14,width:116,height:30);root.addSubview(cancel)
        resetButton.frame = NSRect(x:148,y:14,width:165,height:30);resetButton.perform = { [weak self] in self?.resetFilters() };root.addSubview(resetButton)
        queueButton.frame = NSRect(x:748,y:14,width:140,height:30);queueButton.autoresizingMask = [.minXMargin];queueButton.perform = { [weak self] in self?.submit(false) };root.addSubview(queueButton)
        startButton.frame = NSRect(x:898,y:14,width:140,height:30);startButton.autoresizingMask = [.minXMargin];startButton.perform = { [weak self] in self?.submit(true) };root.addSubview(startButton)
        profileObserver = NotificationCenter.default.addObserver(forName:Preferences.copyProfilesChanged,object:nil,queue:.main) { [weak self] _ in self?.refreshProfiles() }
        refreshProfiles();updateFilterControls();w.center();prepare()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { preparation.cancel();if let profileObserver { NotificationCenter.default.removeObserver(profileObserver) } }
    func tabView(_ tabView: NSTabView,didSelect tabViewItem: NSTabViewItem?) { updateTabButtons() }
    private func updateTabButtons() {
        let index = tabs.selectedTabViewItem.map { tabs.indexOfTabViewItem($0) } ?? 0
        for (position,button) in [selectionButton,objectsButton].enumerated() {
            button.state = position == index ? .on : .off;button.bezelColor = position == index ? .controlAccentColor : nil
        }
    }
    func windowWillClose(_ notification: Notification) { criteriaWindow?.close();profileNameWindow?.close();preparation.cancel();generation += 1 }
    func controlTextDidChange(_ obj: Notification) { invalidatePlan();updateProfileState();info.stringValue = "Ziel oder Filter geändert · Plan aktualisieren oder Eingabetaste drücken" }
    private func invalidatePlan() {
        preparation.cancel();generation += 1;plan = nil;startButton.isEnabled = false;queueButton.isEnabled = false
        previewEntries = [];previewMerge = nil;previewOffsets = [];previewCount = 0;table.reloadData();filesTable.reloadData()
    }
    @objc func rebuild() { prepare() }
    @objc func filterOptionChanged() { updateFilterControls();prepare() }
    func updateFilterControls() {
        let copy = kind == .copy,structure = structureOnly.state == .on
        if structure { if keepEmptyBeforeStructure == nil { keepEmptyBeforeStructure = keepEmpty.state };keepEmpty.state = .on }
        else if let previous = keepEmptyBeforeStructure { keepEmpty.state = previous;keepEmptyBeforeStructure = nil }
        include.isEnabled = copy && !structure;exclude.isEnabled = include.isEnabled;regex.isEnabled = include.isEnabled
        excludedFolders.isEnabled = copy && recursive.state == .on
        recursive.isEnabled = copy;keepEmpty.isEnabled = copy && !structure;structureOnly.isEnabled = copy;resetButton.isEnabled = copy
        mergeFolders.isEnabled = copy
        criteriaButton.isEnabled = copy && !structure
        updateCriteriaInfo();updateProfileState()
        policy.item(at:0)?.title = mergeFolders.state == .on ? "Einzeln entscheiden" : "Abbrechen bei Konflikt"
        safety.stringValue = !copy ? "Verschieben nutzt die Systemoperation. Pause und Abbruch greifen am nächsten sicheren Prüfpunkt." : mergeFolders.state == .on ? "Dateien werden einzeln veröffentlicht. Fertige Schritte bleiben bei Abbruch erhalten; Ersetzen sichert jede vorherige Zieldatei." : "Jedes Auswahlobjekt wird vollständig veröffentlicht. Ersetzen sichert das bisherige Ziel; Zusammenführen ist ausgeschaltet."
        if let recoveryNotice { safety.stringValue = recoveryNotice;safety.textColor = .systemOrange;safety.toolTip = recoveryNotice }
    }
    func resetFilters() {
        include.stringValue = "*";exclude.stringValue = "";excludedFolders.stringValue = "";regex.state = .off
        recursive.state = .on;keepEmptyBeforeStructure = nil;keepEmpty.state = .on;structureOnly.state = .off;criteria = .init();updateFilterControls();prepare()
    }
    var filter: TransferFilter {
        guard kind == .copy else { return .init() }
        var value = TransferFilter();value.include = include.stringValue;value.exclude = exclude.stringValue;value.excludedFolders = excludedFolders.stringValue
        value.regularExpressions = regex.state == .on;value.recursive = recursive.state == .on;value.keepEmptyFolders = keepEmpty.state == .on;value.structureOnly = structureOnly.state == .on
        value.minimumSize = criteria.minimumSize;value.maximumSize = criteria.maximumSize;value.modifiedFrom = criteria.modifiedFrom;value.modifiedBefore = criteria.modifiedBefore;return value
    }
    func updateCriteriaInfo() {
        var parts: [String] = []
        if let value = criteria.minimumSize { parts.append("ab "+bytes(value)) }
        if let value = criteria.maximumSize { parts.append("bis "+bytes(value)) }
        if let value = criteria.modifiedFrom { parts.append("ab "+operationDate.string(from:value)) }
        if let value = criteria.modifiedBefore { parts.append("vor "+operationDate.string(from:value)) }
        let text = parts.joined(separator:" · ")
        let hasDates = criteria.modifiedFrom != nil || criteria.modifiedBefore != nil,hasSizes = criteria.minimumSize != nil || criteria.maximumSize != nil
        let caption = hasDates ? (hasSizes ? "Größe und Datum aktiv" : "Datumsbereich aktiv") : text
        criteriaInfo.stringValue = kind != .copy ? "Nur für Kopien" : structureOnly.state == .on && !parts.isEmpty ? "Grenzen bei Strukturkopie ausgesetzt" : parts.isEmpty ? "Keine zusätzlichen Grenzen" : caption
        criteriaInfo.toolTip = text.isEmpty ? "Dateigröße und Änderungsdatum sind nicht eingeschränkt." : text+"\nGilt für Dateien; symbolische Links werden bei aktiven Grenzen ausgelassen."
    }
    func showCriteria() {
        guard kind == .copy,structureOnly.state == .off,let window,window.attachedSheet == nil else { return }
        let controller = TransferCriteriaController(filter);criteriaWindow = controller
        controller.onApply = { [weak self] value in self?.criteria = value;self?.updateFilterControls();self?.prepare() }
        window.beginSheet(controller.window!)
    }
    func refreshProfiles() {
        profilePopup.removeAllItems();profilePopup.addItem(withTitle:"Eigene Einstellungen")
        do {
            loadedProfiles = try Preferences.copyProfiles();profileReadError = nil
            for profile in loadedProfiles.profiles { profilePopup.addItem(withTitle:profile.name);profilePopup.lastItem?.representedObject = profile.id.uuidString;profilePopup.lastItem?.toolTip = profile.name }
            if let selectedProfileID,let index = profilePopup.itemArray.firstIndex(where: { $0.representedObject as? String == selectedProfileID.uuidString }) { profilePopup.selectItem(at:index) }
            else { selectedProfileID = nil }
        } catch { profileReadError = error.localizedDescription }
        updateProfileState()
    }
    func updateProfileState() {
        let available = kind == .copy && profileReadError == nil
        profilePopup.isEnabled = available;profileSaveAs.isEnabled = available
        let saved = selectedProfileID.flatMap { loadedProfiles.profile($0) }
        profileSave.isEnabled = available && saved != nil;profileRemove.isEnabled = profileSave.isEnabled
        if let profileReadError { profileStatus.stringValue = "Profile nicht lesbar";profileStatus.toolTip = profileReadError;profileStatus.textColor = .systemOrange;return }
        profileStatus.textColor = .secondaryLabelColor
        let matches = saved.map { $0.filter == filter && $0.policy == ConflictPolicy.allCases[policy.indexOfSelectedItem] && $0.mergeFolders == (mergeFolders.state == .on) } ?? false
        profileStatus.stringValue = kind != .copy ? "Nur für Kopien" : saved == nil ? "Eigene Einstellungen" : matches ? "Gespeichert" : "Ungespeicherte Änderungen"
        profileStatus.toolTip = "Profile speichern Regeln und die globale Konfliktvorgabe, keine Pfade, Auswahl oder Einzelentscheidungen."
    }
    @objc func chooseProfile() {
        guard kind == .copy else { return }
        guard let raw = profilePopup.selectedItem?.representedObject as? String,let id = UUID(uuidString:raw) else { selectedProfileID = nil;updateProfileState();return }
        do {
            guard let value = try Preferences.copyProfiles().profile(id) else { refreshProfiles();return }
            selectedProfileID = id
            keepEmptyBeforeStructure = nil
            include.stringValue = value.filter.include;exclude.stringValue = value.filter.exclude;excludedFolders.stringValue = value.filter.excludedFolders
            regex.state = value.filter.regularExpressions ? .on : .off;recursive.state = value.filter.recursive ? .on : .off
            keepEmpty.state = value.filter.keepEmptyFolders ? .on : .off;structureOnly.state = value.filter.structureOnly ? .on : .off
            mergeFolders.state = value.mergeFolders ? .on : .off;policy.selectItem(at:ConflictPolicy.allCases.firstIndex(of:value.policy)!)
            criteria = value.filter;updateFilterControls();prepare()
        } catch { profileStatus.stringValue = error.localizedDescription;profileStatus.toolTip = error.localizedDescription }
    }
    func apply(_ intent: TransferIntent,notice: String) {
        recoveryNotice = notice;selectedProfileID = nil;keepEmptyBeforeStructure = nil
        let value = intent.filter
        include.stringValue = value.include;exclude.stringValue = value.exclude;excludedFolders.stringValue = value.excludedFolders
        regex.state = value.regularExpressions ? .on : .off;recursive.state = value.recursive ? .on : .off
        keepEmpty.state = value.keepEmptyFolders ? .on : .off;structureOnly.state = value.structureOnly ? .on : .off
        mergeFolders.state = intent.mergeFolders ? .on : .off;policy.selectItem(at:ConflictPolicy.allCases.firstIndex(of:intent.policy)!)
        criteria = value;updateFilterControls();prepare()
    }
    func saveProfile() {
        guard kind == .copy,let id = selectedProfileID else { return }
        do {
            let value = filter,choice = ConflictPolicy.allCases[policy.indexOfSelectedItem],merge = mergeFolders.state == .on
            try Preferences.editCopyProfiles { library in
                guard let old = library.profile(id) else { throw CommanderError.message("Profil wurde inzwischen entfernt.") }
                try library.save(name:old.name,filter:value,policy:choice,mergeFolders:merge,replacing:id)
            }
            refreshProfiles()
        } catch { profileStatus.stringValue = error.localizedDescription;profileStatus.toolTip = error.localizedDescription }
    }
    func saveProfileAs() {
        guard kind == .copy,profileReadError == nil,let window,window.attachedSheet == nil else { return }
        let controller = CopyProfileNameController();profileNameWindow = controller
        controller.onSave = { [weak self] name in
            guard let self else { return }
            let value = self.filter,choice = ConflictPolicy.allCases[self.policy.indexOfSelectedItem],merge = self.mergeFolders.state == .on
            let id = try Preferences.editCopyProfiles { try $0.save(name:name,filter:value,policy:choice,mergeFolders:merge) }
            self.selectedProfileID = id;self.refreshProfiles()
        }
        window.beginSheet(controller.window!)
    }
    func removeProfile() {
        guard kind == .copy,let id = selectedProfileID,let profile = loadedProfiles.profile(id),dialog("Kopierprofil löschen",message:"„\(profile.name)“ aus den gespeicherten Kopierregeln entfernen?",buttons:["Entfernen","Abbrechen"]) == 0 else { return }
        do { try Preferences.editCopyProfiles { try $0.remove(id) };refreshProfiles() }
        catch { profileStatus.stringValue = error.localizedDescription;profileStatus.toolTip = error.localizedDescription }
    }
    func chooseDestination() {
        let panel = NSOpenPanel();panel.canChooseFiles = false;panel.canChooseDirectories = true;panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath:destination.stringValue)
        if panel.runModal() == .OK,let url = panel.url { destination.stringValue = url.path;prepare() }
    }
    func prepare() {
        invalidatePlan();preparation = CancellationToken();let token = preparation,current = generation
        updateProfileState()
        info.stringValue = "Erfasse Dateien und prüfe Ziele …"
        let target = URL(fileURLWithPath:(destination.stringValue as NSString).expandingTildeInPath),policy = ConflictPolicy.allCases[policy.indexOfSelectedItem],sources = self.sources,kind = self.kind,filter = self.filter,mergeFolders = kind == .copy && mergeFolders.state == .on
        do { try validateDestination(target) } catch { info.stringValue = error.localizedDescription;return }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try TransferPlanner.prepare(sources,to:target,kind:kind,policy:policy,filter:filter,mergeFolders:mergeFolders,token:token) }
            DispatchQueue.main.async {
                guard let self,self.generation == current,!token.isCancelled else { return }
                switch result {
                case .success(let plan):self.plan = plan;self.table.reloadData();self.updateSummary()
                case .failure(let error):self.info.stringValue = error.localizedDescription
                }
            }
        }
    }
    func updateSummary() {
        let selected = plan?.entries.filter { !excluded.contains($0.source) } ?? []
        let selectedPlan = plan?.selecting(Set(selected.map(\.id)));previewMerge = selectedPlan?.merge
        previewEntries = selected;previewOffsets = [];previewCount = 0
        for entry in selected { previewOffsets.append(previewCount);previewCount += entry.objectCount }
        filesTable.reloadData()
        let conflicts = previewMerge.map { "\($0.unresolvedCount) offene Konflikte" } ?? "\(selected.filter(\.conflict).count) belegte Ziele"
        info.stringValue = selected.isEmpty ? "Keine Objekte ausgewählt oder kein Treffer für diesen Filter." : "\(selected.count) ausgewählt · \(selected.reduce(0) { $0+$1.fileCount }) Dateien · \(selected.reduce(0) { $0+$1.directoryCount }) Ordner · \(selected.reduce(0) { $0+$1.linkCount }) Links · \(bytes(selectedPlan?.bytes ?? 0)) · "+conflicts
        startButton.isEnabled = !selected.isEmpty && (previewMerge?.unresolvedCount ?? 0) == 0;queueButton.isEnabled = startButton.isEnabled
    }
    func previewObject(at row: Int) -> PlannedObject? {
        guard row >= 0,row < previewCount else { return nil }
        var lower = 0,upper = previewEntries.count
        while lower+1 < upper { let middle = (lower+upper)/2;if previewOffsets[middle] <= row { lower = middle } else { upper = middle } }
        return previewEntries[lower].object(at:row-previewOffsets[lower])
    }
    func submit(_ start: Bool) {
        guard let plan else { return }
        do { try validateDestination(plan.destination) } catch { showFailure(error);return }
        let selected = plan.selecting(Set(plan.entries.filter { !excluded.contains($0.source) }.map(\.id)))
        guard !selected.entries.isEmpty,(selected.merge?.unresolvedCount ?? 0) == 0 else { return }
        if onSubmit?(selected,start) == true { close() }
    }
    @objc func toggle(_ sender: NSButton) {
        guard let row = plan?.entries.indices.contains(sender.tag) == true ? plan?.entries[sender.tag] : nil else { return }
        if sender.state == .on { excluded.remove(row.source) } else { excluded.insert(row.source) };updateSummary()
    }
    @objc func changeDecision(_ sender: NSPopUpButton) {
        guard let object = previewObject(at:sender.tag),let action = plan?.merge?.action(for:object.source),let raw = sender.selectedItem?.representedObject as? String,let decision = MergeDecision(rawValue:raw) else { return }
        do { plan = try plan?.resolving(action.id,with:decision);updateSummary() } catch { showFailure(error) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === filesTable ? previewCount : plan?.entries.count ?? sources.count }
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int) -> NSView? {
        if tableView === filesTable {
            guard let object = previewObject(at:row) else { return nil }
            let action = previewMerge?.action(for:object.source)
            if column?.identifier.rawValue == "action",let action,!action.allowedDecisions.isEmpty {
                let popup = NSPopUpButton(frame:.zero,pullsDown:false);popup.controlSize = .small;popup.font = .systemFont(ofSize:11)
                for choice in action.allowedDecisions {
                    let title = choice == .keepBoth ? choice.german+": "+(action.alternateTarget?.lastPathComponent ?? "") : choice.german
                    popup.addItem(withTitle:title);popup.lastItem?.representedObject = choice.rawValue
                }
                popup.selectItem(at:action.allowedDecisions.firstIndex(of:action.decision) ?? 0);popup.tag = row;popup.target = self;popup.action = #selector(changeDecision(_:));popup.toolTip = action.target.path;return popup
            }
            let value: String
            switch column?.identifier.rawValue {
            case "path":value = object.relativePath
            case "action":value = action.flatMap { previewMerge?.description(of:$0) } ?? (object.kind == .directory ? "Ordner kopieren" : object.kind == .symbolicLink ? "Verknüpfung kopieren" : "Datei kopieren")
            case "size":value = object.kind == .file ? bytes(object.bytes) : "—"
            case "targetSize":value = action?.targetInfo.map { $0.kind == .file ? bytes($0.bytes) : $0.kind == .directory ? "Ordner" : $0.kind == .symbolicLink ? "Link" : "Spezialdatei" } ?? "—"
            case "sourceDate":value = operationDate.string(from:object.modified)
            case "targetDate":value = action?.targetInfo.map { operationDate.string(from:$0.modified) } ?? "—"
            default:value = object.source.path
            }
            let field = label(value);field.toolTip = object.source.path+(action.map { "\nZiel: "+$0.target.path } ?? "")
            if column?.identifier.rawValue.hasSuffix("Date") == true { field.font = .systemFont(ofSize:11) }
            if column?.identifier.rawValue == "sourceDate",let date = action?.targetInfo?.modified,object.modified > date { field.font = .systemFont(ofSize:11,weight:.semibold) }
            return field
        }
        let entry = plan?.entries.indices.contains(row) == true ? plan?.entries[row] : nil
        switch column?.identifier.rawValue {
        case "include":let button = NSButton(checkboxWithTitle:"",target:self,action:#selector(toggle(_:)));button.tag = row;button.state = entry.map { excluded.contains($0.source) ? .off : .on } ?? .off;button.isEnabled = entry != nil;return button
        case "name":let text = label(entry?.source.lastPathComponent ?? sources[row].lastPathComponent);text.toolTip = entry?.source.path ?? sources[row].path;return text
        case "size":return label(entry.map { bytes($0.bytes) } ?? "—",color:.secondaryLabelColor)
        case "count":return label(entry.map { String($0.objectCount) } ?? "—",color:.secondaryLabelColor)
        default:let text = label(entry.map { ($0.conflict ? "Ziel belegt · " : "")+$0.target.path } ?? "Wird geprüft …",color:entry?.conflict == true ? .systemOrange : .secondaryLabelColor);text.toolTip = entry?.target.path;return text
        }
    }
}

final class OperationQueueController: NSWindowController,NSTableViewDataSource,NSTableViewDelegate {
    let jobs: JobQueue
    let table = operationTable([("title","Auftrag",190),("state","Status",135),("progress","Fortschritt",145),("detail","Aktuelles Objekt / Ergebnis",460)])
    let itemsTable = operationTable([("source","Quelle",280),("state","Status",115),("bytes","Kopierte Daten",155),("message","Ziel / Hinweis",380)])
    let summary = label("",color:.secondaryLabelColor)
    let pause = ActionButton("Pause",symbol:"pause.fill",action:{})
    let cancel = ActionButton("Abbrechen",symbol:"xmark.circle",action:{})
    let remove = ActionButton("Entfernen",action:{})
    let up = ActionButton("Nach oben",symbol:"arrow.up",action:{})
    let down = ActionButton("Nach unten",symbol:"arrow.down",action:{})
    let start = ActionButton("Starten / als Nächstes",symbol:"play.fill",action:{})
    let review = ActionButton("Erneut prüfen …",symbol:"arrow.clockwise",action:{})
    let subtitle = label("",size:12,weight:.medium)
    var onReview: ((UUID) -> Void)?
    var snapshots: [WorkSnapshot] = []
    private var selectedID: UUID?
    private var timer: Timer?
    private var updating = false
    var selected: WorkSnapshot? { snapshots.first { $0.id == selectedID } }
    init(_ jobs: JobQueue) {
        self.jobs = jobs
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:1020,height:640),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        w.title = "Aufträge · Warteschlange";w.minSize = NSSize(width:1000,height:520);w.isReleasedWhenClosed = false
        super.init(window:w)
        let root = OperationContent(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        let title = label("Aufträge",size:22,weight:.semibold);title.frame = NSRect(x:22,y:590,width:980,height:32);title.autoresizingMask = [.minYMargin,.width];root.addSubview(title)
        summary.frame = NSRect(x:22,y:560,width:976,height:24);summary.autoresizingMask = [.minYMargin,.width];root.addSubview(summary)
        table.delegate = self;table.dataSource = self;itemsTable.delegate = self;itemsTable.dataSource = self
        let scroll = operationScroll(table);scroll.frame = NSRect(x:22,y:302,width:976,height:248);scroll.autoresizingMask = [.minYMargin,.width];root.addSubview(scroll)
        let buttons = row([pause,cancel,start,review,up,down,remove]);buttons.frame = NSRect(x:20,y:258,width:980,height:34);buttons.autoresizingMask = [.minYMargin,.width];root.addSubview(buttons)
        subtitle.frame = NSRect(x:22,y:230,width:976,height:22);subtitle.autoresizingMask = [.minYMargin,.width];root.addSubview(subtitle)
        let details = operationScroll(itemsTable);details.frame = NSRect(x:22,y:60,width:976,height:160);details.autoresizingMask = [.width,.height];root.addSubview(details)
        let clear = ActionButton("Erledigte ausblenden",action:{ [weak self] in self?.jobs.clearFinished();self?.refresh() });clear.frame = NSRect(x:22,y:16,width:192,height:30);root.addSubview(clear)
        let hint = label(jobs.journal != nil ? "Kopier- und Verschiebeaufträge bleiben lokal gespeichert. Nach einem Neustart erneut prüfen." : "Pause hält auch die nächsten Aufträge an. Andere Aufträge gelten für diese Sitzung.",size:11,color:.secondaryLabelColor);hint.frame = NSRect(x:230,y:20,width:768,height:22);hint.autoresizingMask = [.width];root.addSubview(hint)
        pause.perform = { [weak self] in self?.jobs.togglePause();self?.refresh() };cancel.perform = { [weak self] in self?.jobs.cancel() }
        start.perform = { [weak self] in guard let self else { return };self.jobs.scheduler.start(self.selectedID);self.refresh() }
        up.perform = { [weak self] in if let self,let id = self.selectedID { self.jobs.scheduler.move(id,by:-1);self.refresh() } }
        down.perform = { [weak self] in if let self,let id = self.selectedID { self.jobs.scheduler.move(id,by:1);self.refresh() } }
        remove.perform = { [weak self] in if let self,let id = self.selectedID { self.jobs.remove(id);self.refresh() } }
        review.perform = { [weak self] in if let self,let id = self.selectedID { self.onReview?(id) } }
        timer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in if self?.window?.isVisible == true { self?.refresh() } }
        refresh();w.center()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    func select(_ id: UUID) { selectedID = id;refresh() }
    func refresh() {
        updating = true;snapshots = jobs.scheduler.snapshots
        if selectedID == nil || !snapshots.contains(where:{$0.id == selectedID}) { selectedID = jobs.active?.id ?? snapshots.last?.id }
        table.reloadData()
        if let index = snapshots.firstIndex(where:{$0.id == selectedID}) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        itemsTable.reloadData();updating = false
        summary.stringValue = jobs.journalError.map { "Auftragsablage nicht verfügbar · "+$0 } ?? "\(snapshots.filter(\.isPending).count) offen · \(snapshots.filter { $0.state == .review }.count) erneut prüfen · \(snapshots.filter { $0.state == .completed }.count) abgeschlossen · \(snapshots.filter { $0.state == .failed }.count) mit Fehlern"
        summary.toolTip = summary.stringValue;summary.textColor = jobs.journalError == nil ? .secondaryLabelColor : .systemOrange
        let active = jobs.active;pause.isEnabled = active != nil && active?.id == selectedID;cancel.isEnabled = pause.isEnabled
        pause.title = active.map { [.paused,.pausing].contains($0.state) ? "Fortsetzen" : "Pause" } ?? "Pause"
        pause.image = NSImage(systemSymbolName:pause.title == "Fortsetzen" ? "play.fill" : "pause.fill",accessibilityDescription:pause.title)
        let waiting = selected?.state == .waiting;up.isEnabled = waiting;down.isEnabled = waiting;remove.isEnabled = waiting || selected?.state == .review;start.isEnabled = waiting && jobs.journalError == nil
        review.isEnabled = selected.map { !$0.isPending && jobs.journal?.entry($0.id) != nil } == true && jobs.journalError == nil
        if let entry = selected.flatMap({ jobs.journal?.entry($0.id) }),selected?.state == .review {
            subtitle.stringValue = "Letzter gemeldeter Stand vom "+operationDate.string(from:entry.updated)+" · \(entry.snapshot.items.count) von \(entry.itemCount) Objekten"
        } else { subtitle.stringValue = "Objekte des ausgewählten Auftrags · beim Zusammenführen erscheint jeder Schritt einzeln" }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating,notification.object as? NSTableView === table, snapshots.indices.contains(table.selectedRow) else { return }
        selectedID = snapshots[table.selectedRow].id;refresh()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === table ? snapshots.count : selected?.items.count ?? 0 }
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int) -> NSView? {
        let value: String, color: NSColor
        if tableView === table {
            guard snapshots.indices.contains(row) else { return nil };let job = snapshots[row]
            color = job.state == .failed ? .systemRed : job.state == .review ? .systemOrange : .labelColor
            switch column?.identifier.rawValue {
            case "title":value = job.title
            case "state":value = job.state.german
            case "progress":value = job.fraction.map { (job.state == .review ? "Bisher " : "")+String(format:"%.1f %%",$0*100) } ?? ([.waiting,.review,.cancelled,.failed].contains(job.state) ? "—" : "Wird ermittelt")
            default:value = job.detail
            }
        } else {
            guard let items = selected?.items,items.indices.contains(row) else { return nil };let item = items[row]
            color = item.state == .failed ? .systemRed : .labelColor
            switch column?.identifier.rawValue {
            case "source":value = item.source.lastPathComponent
            case "state":value = item.state.german
            case "bytes":value = item.isByteTracked ? bytes(item.bytes)+" / "+bytes(item.totalBytes) : "Systemoperation"
            default:value = item.message.isEmpty ? item.target.path : item.message
            }
        }
        let field = label(value,color:color)
        if tableView === itemsTable,let item = selected?.items[row] { field.toolTip = item.source.path+"\nZiel: "+item.target.path+"\n"+item.message }
        else { field.toolTip = value }
        return field
    }
}
