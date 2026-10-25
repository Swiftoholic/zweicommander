import AppKit
import CommanderCore

final class SearchController: NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate,NSMenuDelegate,NSMenuItemValidation {
    let rootPath = input(),name = input(placeholder:"z. B. *.txt;*.md oder Teil eines Namens")
    let excluded = input(placeholder:"z. B. *.tmp;*.bak"),folders = input(placeholder:"z. B. .git;Cache*")
    let content = input(placeholder:"Wörtlicher Text"),regex = checkbox("Name als regulärer Ausdruck")
    let recursive = checkbox("Unterordner",on:true),hidden = checkbox("Versteckte Einträge")
    let caseSensitive = checkbox("Groß-/Kleinschreibung"),wholeWords = checkbox("Ganze Wörter")
    let office = checkbox("Office-Dokumente"),archives = checkbox("Namen in Archiven")
    let kind = NSPopUpButton(),encoding = NSPopUpButton(),limit = input("10000")
    let contentMode = NSPopUpButton(),contentNegated = checkbox("Nicht enthalten"),maximumDepth = input(placeholder:"Alle")
    let rootsButton = ActionButton("Orte (1) …",action:{}),compareButton = ActionButton("Dateien vergleichen",action:{})
    private(set) var additionalRoots:[URL] = []
    var rootsController:SearchRootsController?
    var onFileCompare:((URL,URL)->Void)?
    let profilePopup = NSPopUpButton(),profileSave = ActionButton("Speichern",action:{}),profileSaveAs = ActionButton("Speichern als …",action:{}),profileRemove = ActionButton("Löschen …",action:{})
    let profileStatus = label("Eigene Suche",size:11,color:.secondaryLabelColor)
    let chooseRoot = ActionButton("Wählen …",action:{}),criteria = ActionButton("Größe und Datum …",action:{}),reset = ActionButton("Zurücksetzen",action:{})
    let criteriaStatus = label("Keine Größen- oder Zeitgrenzen",size:11,color:.secondaryLabelColor)
    let start = ActionButton("Suchen",symbol:"magnifyingglass",action:{}),stop = ActionButton("Abbrechen",action:{})
    let table = CommanderTableView(),resultFilter = input(placeholder:"Trefferliste filtern")
    let info = label("Suchordner und Regeln wählen, dann Suchen.",size:12,color:.secondaryLabelColor)
    let detail = label("",size:12,color:.secondaryLabelColor),progress = NSProgressIndicator()
    let openButton = ActionButton("Öffnen",action:{}),previewButton = ActionButton("Vorschau",action:{}),revealButton = ActionButton("Im Dateifenster",action:{})
    let copyButton = ActionButton("Kopieren …",action:{}),collectionButton = ActionButton("Als Sammlung",action:{}),pathsButton = ActionButton("Pfade kopieren",action:{}),reportButton = ActionButton("Hinweise",action:{})
    private(set) var allHits: [SearchHit] = [],visibleHits: [SearchHit] = []
    private(set) var report: SearchReport?,isSearching = false,selectedProfileID: UUID?
    var profileNameWindow: CopyProfileNameController?,deleteAlert: NSAlert?,criteriaWindow: TransferCriteriaController?
    var onResultsChanged: (() -> Void)?
    var onOpen: ((SearchHit)->Void)?,onPreview: ((URL)->Void)?,onReveal: ((URL)->Void)?,onCopy: (([URL])->Void)?,onCollection: (([URL])->Void)?,onReport: ((String)->Void)?
    private var metadata = TransferFilter(),token = CancellationToken(),generation = 0
    private var controls: [NSControl] = [],observer: NSObjectProtocol?,library = SearchProfileLibrary(),profileError: String?
    private let worker = DispatchQueue(label:"local.zweicommander.search",qos:.userInitiated)
    init(root: URL) {
        let w = SearchWorkspaceWindow(contentRect:NSRect(x:0,y:0,width:1120,height:830),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title = "Dateien suchen";w.minSize = NSSize(width:1120,height:790);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        let surface = OperationContent(frame:w.contentView!.bounds);surface.autoresizingMask = [.width,.height];w.contentView = surface
        func top(_ view: NSView,_ x: CGFloat,_ y: CGFloat,_ width: CGFloat,_ height: CGFloat = 26,_ stretch: Bool = false) {
            view.frame = NSRect(x:x,y:y,width:width,height:height);view.autoresizingMask = stretch ? [.minYMargin,.width] : [.minYMargin];surface.addSubview(view)
        }
        top(label("Dateisuche",size:21,weight:.semibold),22,782,1060,31,true)
        top(profilePopup,22,740,300,28);top(profileSave,332,740,105,28);top(profileSaveAs,447,740,145,28);top(profileRemove,602,740,110,28);top(profileStatus,730,741,368,26,true)
        top(label("Suchen in",weight:.medium),22,700,110);top(rootPath,139,700,704,26,true);top(chooseRoot,857,699,110,28);top(rootsButton,976,699,122,28);for button in [chooseRoot,rootsButton] { button.autoresizingMask = [.minXMargin,.minYMargin] }
        top(label("Name / Muster",weight:.medium),22,661,112);top(name,139,661,540,26,true);top(regex,700,661,398)
        top(label("Auslassen",weight:.medium),22,623,112);top(excluded,139,623,360);top(label("Ordner auslassen",size:12),524,623,150);top(folders,683,623,415,26,true)
        contentMode.addItems(withTitles:["Text","Inhalts-RegEx","Hexbytes"]);top(label("Inhalt",weight:.medium),22,585,115);top(contentMode,139,584,140,28);top(content,290,585,389,26,true);top(caseSensitive,700,585,230);top(wholeWords,945,585,153)
        kind.addItems(withTitles:["Dateien und Ordner","Nur Dateien","Nur Ordner"])
        encoding.addItems(withTitles:["Automatisch (UTF-8 / UTF-16 mit BOM)","UTF-8","UTF-16 Little Endian","UTF-16 Big Endian","Windows-1252"])
        top(kind,22,546,200,28);top(recursive,236,546,150);top(hidden,392,546,195);top(office,600,546,213);top(archives,835,546,263)
        top(label("Textkodierung",size:12),22,506,115);top(encoding,139,506,410,28);top(criteria,574,505,205,29);top(criteriaStatus,796,505,302,27,true)
        top(label("Max. Treffer",size:12),22,466,115);top(limit,139,466,105);top(contentNegated,260,466,174);top(label("Unterordnertiefe",size:12),448,466,120);top(maximumDepth,575,466,64);top(label("0 = direkt · leer = alle",size:11,color:.secondaryLabelColor),651,466,235)
        top(reset,913,464,185,29);reset.autoresizingMask = [.minXMargin,.minYMargin]
        top(resultFilter,22,417,440,27);top(start,778,415,155,30);top(stop,945,415,153,30)
        start.autoresizingMask = [.minXMargin,.minYMargin];stop.autoresizingMask = [.minXMargin,.minYMargin]
        for view in [regex,caseSensitive,wholeWords,archives] { view.autoresizingMask = [.minXMargin,.minYMargin] }
        table.delegate = self;table.dataSource = self;table.intercellSpacing = NSSize(width:4,height:0);table.rowHeight = 28;table.usesAlternatingRowBackgroundColors = true;table.allowsMultipleSelection = true;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id,title,width) in [("name","Name",CGFloat(200)),("size","Größe",80),("modified","Geändert",140),("location","Ordner / Archiv",330),("snippet","Textfundstelle",285)] {
            let column = NSTableColumn(identifier:.init(id));column.title = title;column.width = width;column.minWidth = 60
            column.sortDescriptorPrototype = NSSortDescriptor(key:id,ascending:true);table.addTableColumn(column)
        }
        table.target = self;table.doubleAction = #selector(openSelected)
        let menu = NSMenu();menu.delegate = self
        for (title,selector) in [("Öffnen",#selector(openSelected)),("Vorschau",#selector(previewSelected)),("Im Dateifenster zeigen",#selector(revealSelected)),("Kopieren …",#selector(copySelected)),("Als Sammlung öffnen",#selector(collectSelected)),("Pfade kopieren",#selector(copyPaths)),("Dateien vergleichen",#selector(compareSelected))] {
            let item = NSMenuItem(title:title,action:selector,keyEquivalent:"");item.target = self;menu.addItem(item)
        }
        table.menu = menu
        let scroll = NSScrollView(frame:NSRect(x:22,y:185,width:1076,height:219));scroll.autoresizingMask = [.width,.height];scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.borderType = .bezelBorder;surface.addSubview(scroll)
        detail.frame = NSRect(x:22,y:124,width:1076,height:50);detail.maximumNumberOfLines = 2;detail.autoresizingMask = [.width];detail.lineBreakMode = .byTruncatingTail;surface.addSubview(detail)
        let actions = row([openButton,previewButton,revealButton,copyButton,collectionButton,pathsButton,compareButton,reportButton],spacing:8)
        actions.frame = NSRect(x:22,y:83,width:1076,height:30);actions.autoresizingMask = [.width];surface.addSubview(actions)
        info.frame = NSRect(x:22,y:39,width:1076,height:32);info.maximumNumberOfLines = 2;info.autoresizingMask = [.width];surface.addSubview(info)
        progress.frame = NSRect(x:22,y:16,width:1076,height:12);progress.autoresizingMask = [.width];progress.style = .bar;progress.isIndeterminate = true;progress.isHidden = true;surface.addSubview(progress)
        rootPath.stringValue = root.path;hidden.state = Preferences.state.showHidden ? .on : .off;office.state = (Preferences.state.importedProfile?.officeContentSearch ?? true) ? .on : .off
        chooseRoot.perform = { [weak self] in self?.pickRoot() };rootsButton.perform = { [weak self] in self?.editRoots() };compareButton.perform = { [weak self] in self?.compareSelected() };criteria.perform = { [weak self] in self?.editCriteria() }
        reset.perform = { [weak self] in self?.setOptions(SearchOptions());self?.selectedProfileID = nil;self?.refreshProfiles() }
        start.perform = { [weak self] in self?.beginSearch() };stop.perform = { [weak self] in self?.cancelSearch() }
        openButton.perform = { [weak self] in self?.openSelected() };previewButton.perform = { [weak self] in self?.previewSelected() };revealButton.perform = { [weak self] in self?.revealSelected() }
        copyButton.perform = { [weak self] in self?.copySelected() };collectionButton.perform = { [weak self] in self?.collectSelected() };pathsButton.perform = { [weak self] in self?.copyPaths() }
        reportButton.perform = { [weak self] in self?.showReport() }
        profileSave.perform = { [weak self] in self?.saveProfile() };profileSaveAs.perform = { [weak self] in self?.saveProfileAs() };profileRemove.perform = { [weak self] in self?.removeProfile() }
        profilePopup.target = self;profilePopup.action = #selector(chooseProfile)
        controls = [rootPath,name,excluded,folders,content,regex,recursive,hidden,caseSensitive,wholeWords,office,archives,kind,encoding,limit,chooseRoot,criteria,reset,profilePopup,profileSave,profileSaveAs,profileRemove,rootsButton,contentMode,contentNegated,maximumDepth]
        for field in [rootPath,name,excluded,folders,content,limit,maximumDepth,resultFilter] { field.delegate = self }
        for control: NSControl in [regex,recursive,hidden,caseSensitive,wholeWords,office,archives,kind,encoding,contentMode,contentNegated] { control.target = self;control.action = #selector(edited) }
        observer = NotificationCenter.default.addObserver(forName:Preferences.searchProfilesChanged,object:nil,queue:.main) { [weak self] _ in self?.refreshProfiles() }
        limit.toolTip = "Gemeinsam für alle Suchorte: 1–50.000 Treffer. Zusätzlich höchstens 1.000.000 eindeutige geprüfte Einträge; Grenzen ergeben ausdrücklich Teilergebnisse."
        content.toolTip = "Text: bis 32 MiB; Inhalts-RegEx: bis 1 MiB und 100 ms Matchingzeit pro Datei. Überschreitungen erscheinen als Hinweis. Hex: vollständige Bytepaare, zum Beispiel 00 FF 2A, bis 32 MiB."
        contentMode.setAccessibilityLabel("Modus der Inhaltssuche");contentMode.toolTip = "⌘1 Text · ⌘2 Inhalts-RegEx · ⌘3 Hexbytes. RegEx unterstützt eigene Wortgrenzen und Inline-Optionen wie (?m).";contentNegated.toolTip = "Nur vollständig geprüfte Dateien ohne Inhaltstreffer anzeigen. Nicht lesbare oder zu große Dateien werden als Hinweis ausgelassen."
        maximumDepth.setAccessibilityLabel("Maximale Unterordnertiefe");maximumDepth.toolTip = "Leer: unbegrenzt. 0: nur direkte Einträge; 1: zusätzlich eine Unterordnerebene. Gilt jeweils pro Suchort und für interne Archivordner."
        rootsButton.setHelp("Suchorte","Mehrere Suchordner als getrennte Einträge verwalten. Profile enthalten ausschließlich Regeln.",shortcut:"⌘⇧L")
        start.setHelp("Suchen","Die gewählten Suchorte mit einer gemeinsamen Treffergrenze durchsuchen.",shortcut:"⌘↩")
        refreshFileCompareHelp()
        w.searchKeys = { [weak self,weak w] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"\r",.command) { self.beginSearch();return true }
            if WorkflowKeys.matches(event,"l",.command) { w?.makeFirstResponder(self.rootPath);self.rootPath.selectText(nil);return true }
            if WorkflowKeys.matches(event,"l",[.command,.shift]) { self.editRoots();return true }
            if WorkflowKeys.matches(event,"f",[.command,.option]) { w?.makeFirstResponder(self.content);self.content.selectText(nil);return true }
            if let shortcut = AppDelegate.parseShortcut(AppDelegate.resolvedShortcut("fileCompare")),!shortcut.0.isEmpty,WorkflowKeys.matches(event,shortcut.0,shortcut.1),self.canPerformCommand("fileCompare") { self.compareSelected();return true }
            for index in SearchContentMode.allCases.indices where WorkflowKeys.matches(event,String(index+1),.command) { if !self.isSearching { self.contentMode.selectItem(at:index);self.edited() };return true }
            if WorkflowKeys.matches(event,"\u{1b}") { if self.isSearching { self.cancelSearch() } else { self.close() };return true }
            return false
        }
        refreshProfiles();updateActions();updateAdvancedControls();stop.isEnabled = false;reportButton.isEnabled = false;w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func refreshFileCompareHelp() { CommandHelp.apply(compareButton,id:"fileCompare",title:"Dateien vergleichen",context:"Genau zwei ausgewählte reguläre lokale Treffer vergleichen.") }
    deinit { token.cancel();if let observer { NotificationCenter.default.removeObserver(observer) } }
    func options() throws -> SearchOptions {
        var value = SearchOptions();value.name = name.stringValue;value.regex = regex.state == .on
        value.excludedNames = excluded.stringValue;value.excludedFolders = folders.stringValue;value.recursive = recursive.state == .on
        value.contentMode = SearchContentMode.allCases[contentMode.indexOfSelectedItem];value.contentNegated = contentNegated.state == .on
        let depthText = maximumDepth.stringValue.trimmingCharacters(in:.whitespaces)
        if !depthText.isEmpty { guard let depth = Int(depthText) else { throw CommanderError.message("Unterordnertiefe als ganze Zahl von 0 bis 1000 oder leer angeben.") };value.maximumDepth = depth }
        value.content = content.stringValue;value.caseSensitive = caseSensitive.state == .on;value.wholeWords = wholeWords.state == .on
        value.showHidden = hidden.state == .on;value.searchOfficeDocuments = office.state == .on;value.searchArchives = archives.state == .on
        value.kind = SearchKind.allCases[kind.indexOfSelectedItem];value.encoding = SearchEncoding.allCases[encoding.indexOfSelectedItem]
        value.minimumSize = metadata.minimumSize ?? 0;value.maximumSize = metadata.maximumSize ?? .max
        value.modifiedAfter = metadata.modifiedFrom;value.modifiedBefore = metadata.modifiedBefore;value.modifiedAge = metadata.modifiedAge
        guard let maximum = Int(limit.stringValue.trimmingCharacters(in:.whitespaces)) else { throw CommanderError.message("Treffergrenze als ganze Zahl eingeben.") }
        value.resultLimit = maximum;try value.validate();return value
    }
    func setOptions(_ value: SearchOptions) {
        name.stringValue = value.name;regex.state = value.regex ? .on : .off;excluded.stringValue = value.excludedNames;folders.stringValue = value.excludedFolders;recursive.state = value.recursive ? .on : .off
        contentMode.selectItem(at:SearchContentMode.allCases.firstIndex(of:value.contentMode)!);contentNegated.state = value.contentNegated ? .on : .off;maximumDepth.stringValue = value.maximumDepth.map(String.init) ?? ""
        content.stringValue = value.content;caseSensitive.state = value.caseSensitive ? .on : .off;wholeWords.state = value.wholeWords ? .on : .off
        hidden.state = value.showHidden ? .on : .off;office.state = value.searchOfficeDocuments ? .on : .off;archives.state = value.searchArchives ? .on : .off
        kind.selectItem(at:SearchKind.allCases.firstIndex(of:value.kind)!);encoding.selectItem(at:SearchEncoding.allCases.firstIndex(of:value.encoding)!)
        limit.stringValue = String(value.resultLimit)
        metadata = TransferFilter();metadata.minimumSize = value.minimumSize == 0 ? nil : value.minimumSize;metadata.maximumSize = value.maximumSize == .max ? nil : value.maximumSize
        metadata.modifiedFrom = value.modifiedAfter;metadata.modifiedBefore = value.modifiedBefore;metadata.modifiedAge = value.modifiedAge;updateCriteria();updateAdvancedControls();updateProfileState()
    }
    func beginSearch() {
        guard !isSearching else { return }
        do {
            let options = try options(),roots = try currentRoots()
            _ = try SearchService.searchRoots(roots,options:options)
            token.cancel();generation += 1;let generation = self.generation,token = CancellationToken();self.token = token
            allHits = [];visibleHits = [];report = nil;table.sortDescriptors = [];table.reloadData();detail.stringValue = "";resultFilter.stringValue = ""
            isSearching = true;setWorking(true);info.textColor = .secondaryLabelColor;info.stringValue = "Suche läuft …";window?.subtitle = roots.count == 1 ? roots[0].path : "\(roots.count) Suchorte · gemeinsame Treffergrenze"
            worker.async { [weak self] in
                let result = Result { try SearchService.search(roots,options:options,token:token,onUpdate:{ update in
                    DispatchQueue.main.sync {
                        guard let self,self.generation == generation,self.isSearching else { return }
                        self.receive(update)
                    }
                }) }
                DispatchQueue.main.async {
                    guard let self,self.generation == generation else { return }
                    self.isSearching = false;self.setWorking(false)
                    switch result {
                    case .success(let report):
                        self.report = report;self.reportButton.isEnabled = report.warningCount > 0
                        let state = report.cancelled ? "Abgebrochen · Teilergebnisse" : report.limitReached ? "Treffergrenze erreicht · Teilergebnisse" : report.scanLimitReached ? "Prüfgrenze erreicht · Teilergebnisse" : "Suche abgeschlossen"
                        self.info.stringValue = "\(state) · \(report.hits.count) Treffer · \(report.scanned) geprüft · \(report.warningCount) Hinweise"
                    case .failure(let error): self.showError(error)
                    }
                    self.updateActions()
                }
            }
        } catch { showError(error) }
    }
    private func receive(_ update: SearchUpdate) {
        let count = visibleHits.count;allHits.append(contentsOf:update.hits)
        if resultFilter.stringValue.isEmpty && table.sortDescriptors.isEmpty {
            visibleHits.append(contentsOf:update.hits)
            if visibleHits.count > count { table.insertRows(at:IndexSet(integersIn:count..<visibleHits.count),withAnimation:[]) }
        } else { filterResults() }
        info.stringValue = "Suche läuft · \(update.totalHits) Treffer · \(update.scanned) geprüft · \(update.warningCount) Hinweise";updateActions();onResultsChanged?()
    }
    private func setWorking(_ working: Bool) {
        controls.forEach { $0.isEnabled = !working };start.isEnabled = !working;stop.isEnabled = working
        progress.isHidden = !working;if working { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        updateAdvancedControls();updateProfileState()
    }
    func cancelSearch() { guard isSearching else { return };token.cancel();stop.isEnabled = false;info.stringValue = "Suche wird beendet … bisherige Treffer bleiben erhalten." }
    private func showError(_ error: Error) { info.stringValue = error.localizedDescription;info.toolTip = info.stringValue;info.textColor = .systemRed }
    @objc func edited() {
        if contentMode.indexOfSelectedItem != 0 { wholeWords.state = .off }
        if contentMode.indexOfSelectedItem == 2 { office.state = .off;encoding.selectItem(at:0) }
        updateAdvancedControls();updateProfileState()
    }
    private func updateAdvancedControls() {
        let hex = contentMode.indexOfSelectedItem == 2
        wholeWords.isEnabled = !isSearching && contentMode.indexOfSelectedItem == 0;encoding.isEnabled = !isSearching && !hex;office.isEnabled = !isSearching && !hex;caseSensitive.isEnabled = !isSearching && !hex
        maximumDepth.isEnabled = !isSearching && recursive.state == .on
        content.placeholderString = hex ? "00 FF 2A oder 00FF2A" : contentMode.indexOfSelectedItem == 1 ? "Zum Beispiel (?m)^Projekt\\s+\\d+" : "Wörtlicher Text"
    }
    func currentRoots() throws -> [URL] {
        let path = (rootPath.stringValue as NSString).expandingTildeInPath
        guard path.hasPrefix("/"),!path.contains("\0") else { throw CommanderError.message("Suchordner als absoluten Pfad angeben.") }
        return [URL(fileURLWithPath:path)]+additionalRoots
    }
    func setRoots(_ roots:[URL]) throws {
        guard !isSearching,let first = roots.first,roots.count <= 100 else { throw CommanderError.message("1 bis 100 Suchordner wählen.") }
        var check = SearchOptions();check.recursive = false;_ = try SearchService.searchRoots(roots,options:check)
        rootPath.stringValue = first.path;additionalRoots = Array(roots.dropFirst());rootsButton.title = "Orte (\(roots.count)) …"
    }
    func editRoots() {
        guard !isSearching,rootsController == nil,let window else { return }
        do {
            let form = SearchRootsController(try currentRoots());form.onApply = { [weak self] in try self?.setRoots($0) };form.onClose = { [weak self] in self?.rootsController = nil }
            rootsController = form;window.beginSheet(form.window!)
        } catch { showError(error) }
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === resultFilter { filterResults() } else { updateProfileState() }
    }
    func filterResults() {
        let selected = Set(selectedHits.map(\.id)),filter = resultFilter.stringValue
        visibleHits = filter.isEmpty ? allHits : allHits.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.location.localizedCaseInsensitiveContains(filter) || $0.snippet.localizedCaseInsensitiveContains(filter) }
        if let sort = table.sortDescriptors.first {
            visibleHits.sort { a,b in
                let comparison: ComparisonResult
                switch sort.key {
                case "size": comparison = a.size == b.size ? .orderedSame : a.size < b.size ? .orderedAscending : .orderedDescending
                case "modified": comparison = a.modified.compare(b.modified)
                case "location": comparison = a.location.localizedStandardCompare(b.location)
                case "snippet": comparison = a.snippet.localizedStandardCompare(b.snippet)
                default: comparison = a.name.localizedStandardCompare(b.name)
                }
                let tie = comparison == .orderedSame ? a.id.compare(b.id) : comparison
                return sort.ascending ? tie == .orderedAscending : tie == .orderedDescending
            }
        }
        table.reloadData();table.selectRowIndexes(IndexSet(visibleHits.indices.filter { selected.contains(visibleHits[$0].id) }),byExtendingSelection:false);updateActions()
    }
    func tableView(_ tableView: NSTableView,sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { filterResults() }
    var selectedHits: [SearchHit] { table.selectedRowIndexes.compactMap { visibleHits.indices.contains($0) ? visibleHits[$0] : nil } }
    private var actionHits: [SearchHit] { selectedHits }
    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = table.clickedRow
        if visibleHits.indices.contains(row),!table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hits = selectedHits,files = !hits.isEmpty && hits.allSatisfy { $0.member == nil }
        switch item.action {
        case #selector(openSelected),#selector(revealSelected): return hits.count == 1
        case #selector(previewSelected): return files && hits.count == 1
        case #selector(compareSelected): return compareURLs != nil
        case #selector(copySelected),#selector(collectSelected): return files
        default: return !hits.isEmpty
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    private func updateActions() {
        let hits = selectedHits,one = hits.count == 1,files = !hits.isEmpty && hits.allSatisfy { $0.member == nil }
        openButton.isEnabled = one;previewButton.isEnabled = one && files;revealButton.isEnabled = one
        copyButton.isEnabled = files;collectionButton.isEnabled = files;pathsButton.isEnabled = !hits.isEmpty;compareButton.isEnabled = compareURLs != nil
        openButton.title = hits.first?.member == nil ? "Öffnen" : "Archiv öffnen"
        if let hit = hits.first { detail.stringValue = hit.location + (hit.snippet.isEmpty ? "" : "\n"+hit.snippet);detail.toolTip = detail.stringValue }
        else { detail.stringValue = "\(visibleHits.count) von \(allHits.count) Treffern sichtbar · Mehrfachauswahl mit Cmd / Umschalt" }
    }
    var compareURLs:(URL,URL)? {
        let hits = selectedHits
        guard hits.count == 2,hits.allSatisfy({ $0.member == nil && $0.url.isFileURL && !FileSystem.isSymlink($0.url) && (try? FileEntry(url:$0.url).isRegularFile) == true }) else { return nil }
        return (hits[0].url,hits[1].url)
    }
    @objc func compareSelected() { if let pair = compareURLs { onFileCompare?(pair.0,pair.1) } }
    @objc func openSelected() { let hits = actionHits;guard hits.count == 1 else { return };onOpen?(hits[0]) }
    @objc func previewSelected() { let hits = actionHits;guard hits.count == 1,hits[0].member == nil else { return };onPreview?(hits[0].url) }
    @objc func revealSelected() { let hits = actionHits;guard hits.count == 1 else { return };onReveal?(hits[0].url) }
    @objc func copySelected() { let hits = actionHits;guard !hits.isEmpty,hits.allSatisfy({ $0.member == nil }) else { return };onCopy?(hits.map(\.url)) }
    @objc func collectSelected() { let hits = actionHits;guard !hits.isEmpty,hits.allSatisfy({ $0.member == nil }) else { return };onCollection?(hits.map(\.url)) }
    @objc func copyPaths() {
        let hits = actionHits;guard !hits.isEmpty else { return }
        NSPasteboard.general.clearContents();NSPasteboard.general.setString(hits.map { $0.member == nil ? $0.url.path : $0.location }.joined(separator:"\n"),forType:.string)
    }
    func canPerformCommand(_ id: String) -> Bool {
        let hits = selectedHits,files = !hits.isEmpty && hits.allSatisfy { $0.member == nil }
        let editing = NSApp.keyWindow?.firstResponder is NSTextView
        switch id {
        case "fileCompare": return !editing && compareURLs != nil
        case "open","reveal": return hits.count == 1
        case "preview": return files && hits.count == 1
        case "copy","collection": return files
        case "clipboardCopy": return editing || files
        case "clipboardCut","clipboardPaste": return editing
        case "copyPath": return !hits.isEmpty
        case "refresh": return !isSearching
        case "selectAll","closeTab","search","help","settings","operations","recovery","pauseTransfers","stopTransfers": return true
        default: return false
        }
    }
    func command(_ id: String) {
        guard canPerformCommand(id) else { return }
        let editor = NSApp.keyWindow?.firstResponder as? NSTextView
        switch id {
        case "fileCompare": compareSelected()
        case "open": openSelected()
        case "preview": previewSelected()
        case "copy": copySelected()
        case "collection": collectSelected()
        case "reveal": NSWorkspace.shared.activateFileViewerSelecting(selectedHits.map(\.url))
        case "copyPath": copyPaths()
        case "selectAll": if let editor { editor.selectAll(nil) } else { table.selectAll(nil) }
        case "clipboardCopy":
            if let editor { editor.copy(nil) }
            else { NSPasteboard.general.clearContents();NSPasteboard.general.writeObjects(selectedHits.map { $0.url as NSURL }) }
        case "clipboardCut": editor?.cut(nil)
        case "clipboardPaste": editor?.paste(nil)
        case "closeTab": window?.performClose(nil)
        case "search": window?.makeFirstResponder(name)
        case "refresh": beginSearch()
        default: break
        }
    }
    override func cancelOperation(_ sender: Any?) { cancelSearch() }
    private func showReport() { guard let report else { return };onReport?("Hinweise: \(report.warningCount)\n"+report.warnings.joined(separator:"\n")+(report.warningCount > report.warnings.count ? "\nWeitere Hinweise wurden nicht gespeichert (Grenze: 200)." : "")) }
    private func pickRoot() {
        guard !isSearching else { return };let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath:rootPath.stringValue);if panel.runModal() == .OK,let url = panel.url { rootPath.stringValue = url.path }
    }
    func editCriteria() {
        guard !isSearching,criteriaWindow == nil else { return }
        let controller = TransferCriteriaController(metadata);criteriaWindow = controller
        controller.onApply = { [weak self] filter in self?.metadata = filter;self?.updateCriteria();self?.updateProfileState() }
        if let window { window.beginSheet(controller.window!) }
        NotificationCenter.default.addObserver(self,selector:#selector(criteriaClosed(_:)),name:NSWindow.willCloseNotification,object:controller.window)
    }
    @objc private func criteriaClosed(_ note: Notification) { criteriaWindow = nil }
    private func updateCriteria() {
        var parts: [String] = []
        if let size = metadata.minimumSize { parts.append("ab \(ByteCountFormatter.string(fromByteCount:size,countStyle:.file))") }
        if let size = metadata.maximumSize { parts.append("bis \(ByteCountFormatter.string(fromByteCount:size,countStyle:.file))") }
        if metadata.modifiedFrom != nil || metadata.modifiedBefore != nil { parts.append("Datumsbereich") }
        if metadata.modifiedAge != nil { parts.append("Relatives Alter") }
        criteriaStatus.stringValue = parts.isEmpty ? "Keine Größen- oder Zeitgrenzen" : parts.joined(separator:" · ");criteriaStatus.toolTip = criteriaStatus.stringValue
    }
    override func close() { generation += 1;token.cancel();criteriaWindow?.close();profileNameWindow?.close();rootsController?.close();super.close() }
    func windowWillClose(_ notification: Notification) { generation += 1;token.cancel();criteriaWindow?.close();profileNameWindow?.close();rootsController?.close() }
    func numberOfRows(in tableView: NSTableView) -> Int { visibleHits.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        guard visibleHits.indices.contains(row) else { return nil };let hit = visibleHits[row],text: String
        switch tableColumn?.identifier.rawValue {
        case "name": text = (hit.member == nil ? "" : "▸ ") + hit.name
        case "size": text = hit.isDirectory ? "Ordner" : ByteCountFormatter.string(fromByteCount:hit.size,countStyle:.file)
        case "modified": text = hit.member == nil ? hit.modified.formatted(date:.numeric,time:.shortened) : "—"
        case "location": text = hit.location
        default: text = hit.snippet
        }
        let view = label(text,size:12);view.toolTip = text;view.lineBreakMode = .byTruncatingMiddle;return view
    }
    func refreshProfiles() {
        do {
            library = try Preferences.searchProfiles();profileError = nil
            if let id = selectedProfileID,library.profile(id) == nil { selectedProfileID = nil }
            profilePopup.removeAllItems();profilePopup.addItem(withTitle:"Eigene Suche")
            for profile in library.profiles { profilePopup.addItem(withTitle:profile.name);profilePopup.lastItem?.representedObject = profile.id.uuidString }
            profilePopup.selectItem(at:profilePopup.itemArray.firstIndex { ($0.representedObject as? String) == selectedProfileID?.uuidString } ?? 0)
        } catch { profileError = error.localizedDescription }
        updateProfileState()
    }
    private func updateProfileState() {
        let valid = (try? options()) != nil,editable = !isSearching && profileError == nil
        profileSave.isEnabled = editable && valid && selectedProfileID != nil;profileSaveAs.isEnabled = editable && valid
        profileRemove.isEnabled = editable && selectedProfileID != nil;profilePopup.isEnabled = editable
        profileStatus.textColor = profileError == nil ? .secondaryLabelColor : .systemRed
        if let profileError { profileStatus.stringValue = "Profile nicht lesbar";profileStatus.toolTip = profileError }
        else if let id = selectedProfileID,let profile = library.profile(id) { profileStatus.stringValue = (try? options()) == profile.options ? "Gespeichert" : "Geändert" }
        else { profileStatus.stringValue = "Eigene Suche" }
    }
    @objc func chooseProfile() {
        guard !isSearching else { return }
        if let value = profilePopup.selectedItem?.representedObject as? String,let id = UUID(uuidString:value),let profile = library.profile(id) { selectedProfileID = id;setOptions(profile.options) }
        else { selectedProfileID = nil };updateProfileState()
    }
    func saveProfile() {
        guard !isSearching,let id = selectedProfileID,let profile = library.profile(id) else { return }
        do { let value = try options();try Preferences.editSearchProfiles { _ = try $0.save(name:profile.name,options:value,replacing:id) };refreshProfiles() }
        catch { profileStatus.stringValue = error.localizedDescription }
    }
    func saveProfileAs() {
        guard !isSearching,(try? options()) != nil,let window else { return }
        let sheet = CopyProfileNameController(title:"Suchprofil speichern",message:"Suchregeln speichern · Suchordner und Treffer bleiben ungespeichert");profileNameWindow = sheet
        sheet.onSave = { [weak self] name in guard let self else { return };let value = try self.options();self.selectedProfileID = try Preferences.editSearchProfiles { try $0.save(name:name,options:value) };self.refreshProfiles() }
        window.beginSheet(sheet.window!)
    }
    func removeProfile() {
        guard !isSearching,let id = selectedProfileID,let profile = library.profile(id),let window else { return }
        let alert = NSAlert();alert.messageText = "Suchprofil löschen?";alert.informativeText = profile.name;alert.addButton(withTitle:"Löschen");alert.addButton(withTitle:"Abbrechen");deleteAlert = alert
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .alertFirstButtonReturn else { return }
            do { try Preferences.editSearchProfiles { try $0.remove(id) };self.selectedProfileID = nil;self.refreshProfiles() }
            catch { self.profileStatus.stringValue = error.localizedDescription }
        }
    }
}
