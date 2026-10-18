import AppKit
import CommanderCore

struct RenameChoice {
    let id = UUID()
    var url: URL
    var enabled = true
}

final class RenameController: NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate,NSTabViewDelegate {
    let pattern = input("{name}"),extensionPattern = input("{ext}"),separateExtension = checkbox("Endung separat bearbeiten")
    let start = input("1"),step = input("1"),digits = input("3"),resetPerFolder = checkbox("Zähler je Ordner neu beginnen")
    let search = input(),replacement = input(),regex = checkbox("Regulärer Ausdruck"),ignoreCase = checkbox("Groß-/Kleinschreibung ignorieren")
    let searchTarget = NSPopUpButton(),letterCase = NSPopUpButton(),caseTarget = NSPopUpButton()
    let dateFormat = input("yyyy-MM-dd"),dateSource = NSPopUpButton(),useUTC = checkbox("Datum in UTC")
    let tokens = NSPopUpButton(),settingsTabs = NSTabView(),order = NSPopUpButton()
    let settingsButtons = [ActionButton("Name und Zähler",action:{}),ActionButton("Suchen und Ersetzen",action:{}),ActionButton("Datum und Schreibweise",action:{})]
    let profilePopup = NSPopUpButton(),profileSave = ActionButton("Speichern",action:{}),profileSaveAs = ActionButton("Speichern als …",action:{}),profileRemove = ActionButton("Löschen …",action:{})
    let profileStatus = label("Eigene Einstellungen",size:11,color:.secondaryLabelColor)
    let table = NSTableView(),info = label("Vorschau wird vorbereitet …",size:12,color:.secondaryLabelColor)
    let apply = ActionButton("Umbenennen",symbol:"checkmark",action:{}),cancel = ActionButton("Schließen",action:{}),refreshButton = ActionButton("Vorschau aktualisieren",symbol:"arrow.clockwise",action:{})
    let selectAll = ActionButton("Alle",action:{}),selectNone = ActionButton("Keine",action:{}),up = ActionButton("↑",action:{}),down = ActionButton("↓",action:{}),reset = ActionButton("Regeln zurücksetzen",action:{}),report = ActionButton("Bericht",action:{})
    private(set) var choices: [RenameChoice]
    private(set) var preview: RenamePreview?
    private(set) var selectedProfileID: UUID?
    private(set) var isWorking = false
    var profileNameWindow: CopyProfileNameController?
    var deleteAlert: NSAlert?
    var onSubmit: (([RenameItem]) -> UUID)?
    var onCancel: ((UUID) -> Void)?
    var onReport: ((String) -> Void)?
    private var jobID: UUID?
    private var rows: [UUID:RenamePreviewRow] = [:]
    private var preparation = CancellationToken(),generation = 0,delayed: DispatchWorkItem?
    private var observer: NSObjectProtocol?
    private var library = RenameProfileLibrary(),profileError: String?,lastError: String?
    private var controls: [NSControl] = []
    init(sources: [URL],digits: Int = 3) {
        choices = sources.map { RenameChoice(url:$0) }
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:780),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = "Mehrfachumbenennen · Vorschau";w.minSize = NSSize(width:1080,height:740);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        self.digits.stringValue = String(digits)
        let root = OperationContent(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        func top(_ view: NSView,_ x: CGFloat,_ y: CGFloat,_ width: CGFloat,_ height: CGFloat = 26,_ stretch: Bool = false) {
            view.frame = NSRect(x:x,y:y,width:width,height:height);view.autoresizingMask = stretch ? [.minYMargin,.width] : [.minYMargin];root.addSubview(view)
        }
        top(label("Mehrfachumbenennen",size:20,weight:.semibold),22,733,1056,30,true)
        top(profilePopup,22,691,300,28);top(profileSave,332,691,105,28);top(profileSaveAs,447,691,145,28);top(profileRemove,602,691,110,28);top(profileStatus,727,692,351,26,true)
        profilePopup.target = self;profilePopup.action = #selector(chooseProfile)
        profileSave.perform = { [weak self] in self?.saveProfile() };profileSaveAs.perform = { [weak self] in self?.saveProfileAs() };profileRemove.perform = { [weak self] in self?.removeProfile() }
        let namePane = NSView(frame:NSRect(x:0,y:0,width:1030,height:165)),replacePane = NSView(frame:namePane.frame),datePane = NSView(frame:namePane.frame)
        func put(_ root: NSView,_ view: NSView,_ x: CGFloat,_ y: CGFloat,_ width: CGFloat,_ height: CGFloat = 26) {
            view.frame = NSRect(x:x,y:y,width:width,height:height);root.addSubview(view)
        }
        put(namePane,label("Namensmuster"),15,117,135);put(namePane,pattern,160,115,560)
        tokens.addItems(withTitles:["Platzhalter einfügen","{name}","{full}","{ext}","{n}","{date}","{parent}","{name:2:5}","{width}","{height}","{taken}"]);tokens.target = self;tokens.action = #selector(insertToken)
        put(namePane,tokens,740,114,270,28)
        put(namePane,separateExtension,15,77,280);put(namePane,extensionPattern,320,77,220)
        put(namePane,label("Ohne Punkt · leer entfernt die Endung",size:11,color:.secondaryLabelColor),560,78,440)
        put(namePane,label("Start"),15,35,40);put(namePane,start,58,33,120);put(namePane,label("Schritt"),195,35,48);put(namePane,step,249,33,120)
        put(namePane,label("Stellen"),387,35,56);put(namePane,self.digits,450,33,90);put(namePane,resetPerFolder,565,34,390)
        put(replacePane,label("Suchen"),15,117,135);put(replacePane,search,160,115,850)
        put(replacePane,label("Ersetzen durch"),15,77,135);put(replacePane,replacement,160,75,850)
        put(replacePane,regex,160,33,205);put(replacePane,ignoreCase,370,33,310)
        searchTarget.addItems(withTitles:["Ganzer Name","Nur Name ohne Endung","Nur Endung"]);put(replacePane,searchTarget,710,32,300,28)
        put(datePane,label("Datumsformat"),15,117,135);put(datePane,dateFormat,160,115,390)
        dateSource.addItems(withTitles:["Änderungsdatum","Erstellungsdatum"]);put(datePane,dateSource,570,114,235,28);put(datePane,useUTC,825,115,185)
        put(datePane,label("Schreibweise"),15,77,135);letterCase.addItems(withTitles:["Unverändert","kleinbuchstaben","GROSSBUCHSTABEN","Wortanfänge groß"]);put(datePane,letterCase,160,75,390,28)
        caseTarget.addItems(withTitles:["Ganzer Name","Nur Name ohne Endung","Nur Endung"]);put(datePane,caseTarget,570,75,440,28)
        put(datePane,label("{width}/{height}: Bildabmessungen · {taken}: EXIF-Aufnahmedatum, ohne Zeitzonenumrechnung. Fehlende Bilddaten ergeben einen Zeilenfehler.",size:11,color:.secondaryLabelColor),15,24,995,35)
        for (title,pane) in [("Name und Zähler",namePane),("Suchen und Ersetzen",replacePane),("Datum und Schreibweise",datePane)] { let item = NSTabViewItem();item.label = title;item.view = pane;settingsTabs.addTabViewItem(item) }
        settingsTabs.tabViewType = .noTabsNoBorder;settingsTabs.delegate = self
        for (index,button) in settingsButtons.enumerated() {
            button.setButtonType(.pushOnPushOff);button.perform = { [weak self] in self?.settingsTabs.selectTabViewItem(at:index) }
        }
        let settingsBar = row(settingsButtons,spacing:8);top(settingsBar,22,645,1056,29,true)
        top(settingsTabs,22,478,1056,160,true);updateSettingsButtons()
        top(selectAll,22,436,80,28);top(selectNone,110,436,80,28);top(up,205,436,40,28);top(down,250,436,40,28)
        order.addItems(withTitles:["Reihenfolge ändern …","Name aufsteigend","Name absteigend","Änderungsdatum aufsteigend","Änderungsdatum absteigend","Reihenfolge umkehren"])
        top(order,305,436,330,28);order.target = self;order.action = #selector(reorder)
        top(refreshButton,820,436,258,28);refreshButton.autoresizingMask = [.minYMargin,.minXMargin]
        selectAll.perform = { [weak self] in self?.setAll(true) };selectNone.perform = { [weak self] in self?.setAll(false) }
        up.perform = { [weak self] in self?.moveRow(-1) };down.perform = { [weak self] in self?.moveRow(1) };refreshButton.perform = { [weak self] in self?.prepare() }
        table.delegate = self;table.dataSource = self;table.rowHeight = 29;table.usesAlternatingRowBackgroundColors = true;table.allowsMultipleSelection = false;table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id,title,width) in [("include","",CGFloat(42)),("source","Bisheriger Name",235),("target","Neuer Name",270),("status","Status",285),("parent","Ordner",340)] { let c = NSTableColumn(identifier:.init(id));c.title = title;c.width = width;c.minWidth = 40;table.addTableColumn(c) }
        let scroll = NSScrollView(frame:NSRect(x:22,y:132,width:1056,height:292));scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.autoresizingMask = [.width,.height];scroll.borderType = .bezelBorder;root.addSubview(scroll)
        info.frame = NSRect(x:22,y:77,width:1056,height:44);info.maximumNumberOfLines = 2;info.autoresizingMask = [.width];root.addSubview(info)
        let hint = label("Nur angehakte Zeilen zählen. Vorschau prüft Namen; vor dem Ausführen werden Quellen und Ziele erneut geprüft.",size:11,color:.secondaryLabelColor)
        hint.frame = NSRect(x:22,y:53,width:1056,height:20);hint.autoresizingMask = [.width];root.addSubview(hint)
        for (button,x,width) in [(cancel,22.0,125.0),(reset,157,190),(report,359,100),(apply,908,170)] {
            button.frame = NSRect(x:x,y:14,width:width,height:30);if button === apply { button.autoresizingMask = [.minXMargin] };root.addSubview(button)
        }
        apply.perform = { [weak self] in self?.submit() };cancel.perform = { [weak self] in self?.cancelOrClose() }
        reset.perform = { [weak self] in self?.setRule(RenameRule());self?.selectedProfileID = nil;self?.refreshProfiles();self?.schedulePreview() }
        report.perform = { [weak self] in if let error = self?.lastError { self?.onReport?(error) } };report.isEnabled = false
        controls = [pattern,extensionPattern,separateExtension,start,step,self.digits,resetPerFolder,search,replacement,regex,ignoreCase,searchTarget,letterCase,caseTarget,dateFormat,dateSource,useUTC,tokens,order,profilePopup,profileSave,profileSaveAs,profileRemove,selectAll,selectNone,up,down,reset,refreshButton]
        for field in [pattern,extensionPattern,start,step,self.digits,search,replacement,dateFormat] { field.delegate = self;field.target = self;field.action = #selector(rebuild) }
        for control: NSControl in [separateExtension,resetPerFolder,regex,ignoreCase,searchTarget,letterCase,caseTarget,dateSource,useUTC] { control.target = self;control.action = #selector(rebuild) }
        observer = NotificationCenter.default.addObserver(forName:Preferences.renameProfilesChanged,object:nil,queue:.main) { [weak self] _ in self?.refreshProfiles() }
        refreshProfiles();prepare();w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { preparation.cancel();delayed?.cancel();if let observer { NotificationCenter.default.removeObserver(observer) } }
    func rule() throws -> RenameRule {
        guard let start = Int(start.stringValue.trimmingCharacters(in:.whitespaces)),let step = Int(step.stringValue.trimmingCharacters(in:.whitespaces)),let digits = Int(digits.stringValue.trimmingCharacters(in:.whitespaces)) else { throw CommanderError.message("Start, Schritt und Stellen als ganze Zahlen eingeben.") }
        var value = RenameRule();value.pattern = pattern.stringValue;value.extensionPattern = separateExtension.state == .on ? extensionPattern.stringValue : nil
        value.start = start;value.step = step;value.digits = digits;value.resetPerFolder = resetPerFolder.state == .on
        value.search = search.stringValue;value.replacement = replacement.stringValue;value.regex = regex.state == .on;value.ignoreCase = ignoreCase.state == .on;value.searchTarget = RenameTextTarget.allCases[searchTarget.indexOfSelectedItem]
        value.letterCase = letterCase.indexOfSelectedItem;value.caseTarget = RenameTextTarget.allCases[caseTarget.indexOfSelectedItem]
        value.dateFormat = dateFormat.stringValue;value.dateSource = RenameDateSource.allCases[dateSource.indexOfSelectedItem];value.useUTC = useUTC.state == .on;try value.validate();return value
    }
    func setRule(_ rule: RenameRule) {
        pattern.stringValue = rule.pattern;separateExtension.state = rule.extensionPattern == nil ? .off : .on;extensionPattern.stringValue = rule.extensionPattern ?? "{ext}"
        start.stringValue = String(rule.start);step.stringValue = String(rule.step);digits.stringValue = String(rule.digits);resetPerFolder.state = rule.resetPerFolder ? .on : .off
        search.stringValue = rule.search;replacement.stringValue = rule.replacement;regex.state = rule.regex ? .on : .off;ignoreCase.state = rule.ignoreCase ? .on : .off;searchTarget.selectItem(at:RenameTextTarget.allCases.firstIndex(of:rule.searchTarget)!)
        letterCase.selectItem(at:rule.letterCase);caseTarget.selectItem(at:RenameTextTarget.allCases.firstIndex(of:rule.caseTarget)!)
        dateFormat.stringValue = rule.dateFormat;dateSource.selectItem(at:RenameDateSource.allCases.firstIndex(of:rule.dateSource)!);useUTC.state = rule.useUTC ? .on : .off
    }
    @objc func rebuild() { schedulePreview() }
    func controlTextDidChange(_ notification: Notification) { schedulePreview() }
    func schedulePreview() {
        guard !isWorking else { return }
        invalidate();updateProfileState();info.stringValue = "Vorschau wird aktualisiert …"
        let work = DispatchWorkItem { [weak self] in self?.prepare() };delayed = work;DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work)
    }
    private func invalidate() { delayed?.cancel();preparation.cancel();generation += 1;preview = nil;rows = [:];apply.isEnabled = false;table.reloadData() }
    func prepare() {
        guard !isWorking else { return };invalidate();extensionPattern.isEnabled = separateExtension.state == .on
        lastError = nil;report.isEnabled = false;info.textColor = .secondaryLabelColor
        do {
            let rule = try rule(),selected = choices.filter(\.enabled),token = CancellationToken(),generation = self.generation
            preparation = token;info.stringValue = "Prüfe \(selected.count) Objekte …";updateProfileState()
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                let result = Result { try RenameEngine.plan(selected.map(\.url),rule:rule,token:token) }
                DispatchQueue.main.async {
                    guard let self,self.generation == generation,!self.isWorking else { return }
                    switch result {
                    case .success(let preview):
                        self.preview = preview;self.rows = Dictionary(uniqueKeysWithValues:zip(selected,preview.rows).map { ($0.0.id,$0.1) });self.table.reloadData()
                        self.apply.isEnabled = preview.canApply
                        self.info.stringValue = "\(selected.count) ausgewählt · \(preview.changedCount) Änderungen · \(preview.errorCount) Fehler"
                        self.info.textColor = preview.errorCount == 0 ? .secondaryLabelColor : .systemRed
                    case .failure(let error): self.showError(error)
                    }
                }
            }
        } catch { showError(error) }
    }
    private func showError(_ error: Error) { info.stringValue = error.localizedDescription;info.toolTip = info.stringValue;info.textColor = .systemRed;apply.isEnabled = false }
    @objc func insertToken() {
        guard tokens.indexOfSelectedItem > 0,let token = tokens.selectedItem?.title else { return }
        pattern.stringValue += token;tokens.selectItem(at:0);schedulePreview()
    }
    func setAll(_ enabled: Bool) { guard !isWorking else { return };for index in choices.indices { choices[index].enabled = enabled };schedulePreview() }
    func toggle(_ id: UUID) { guard !isWorking,let index = choices.firstIndex(where: { $0.id == id }) else { return };choices[index].enabled.toggle();schedulePreview() }
    func moveRow(_ offset: Int) {
        let index = table.selectedRow,target = index+offset;guard !isWorking,choices.indices.contains(index),choices.indices.contains(target) else { return }
        let row = choices.remove(at:index);choices.insert(row,at:target);schedulePreview();table.selectRowIndexes(IndexSet(integer:target),byExtendingSelection:false)
    }
    @objc func reorder() {
        guard !isWorking else { return };let action = order.indexOfSelectedItem;order.selectItem(at:0)
        if action == 5 { choices.reverse() }
        else if action == 1 || action == 2 {
            choices.sort { a,b in let result = a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent);return result == .orderedSame ? a.url.path < b.url.path : action == 1 ? result == .orderedAscending : result == .orderedDescending }
        } else if action == 3 || action == 4 {
            let dates = Dictionary(uniqueKeysWithValues:choices.map { ($0.id,(try? FileEntry(url:$0.url).modified) ?? .distantPast) })
            choices.sort { a,b in dates[a.id] == dates[b.id] ? a.url.path < b.url.path : action == 3 ? dates[a.id]! < dates[b.id]! : dates[a.id]! > dates[b.id]! }
        } else { return };schedulePreview()
    }
    func submit() {
        guard !isWorking,let preview,preview.canApply,let onSubmit else { return }
        isWorking = true;delayed?.cancel();preparation.cancel();apply.isEnabled = false
        controls.forEach { $0.isEnabled = false };table.reloadData();window?.standardWindowButton(.closeButton)?.isEnabled = false;cancel.title = "Auftrag abbrechen"
        info.textColor = .secondaryLabelColor;info.stringValue = "Umbenennung ist eingereiht …";jobID = onSubmit(preview.items)
    }
    func updateProgress(_ text: String) { if isWorking { info.stringValue = text } }
    func finished(_ result: Result<[RenameItem],Error>) {
        isWorking = false;jobID = nil;controls.forEach { $0.isEnabled = true };cancel.title = "Schließen";window?.standardWindowButton(.closeButton)?.isEnabled = true
        invalidate();refreshProfiles();extensionPattern.isEnabled = separateExtension.state == .on
        switch result {
        case .success(let undo):
            let targets = Dictionary(uniqueKeysWithValues:undo.map { ($0.target.path,$0.source) })
            var parents: [String:URL] = [:]
            for index in choices.indices {
                let url = choices[index].url,parent = url.deletingLastPathComponent()
                let canonical = parents[parent.path] ?? FileSystem.canonical(parent);parents[parent.path] = canonical
                let key = canonical.appendingPathComponent(url.lastPathComponent).path
                if let current = targets[key] { choices[index].url = current }
            }
            table.reloadData()
            info.stringValue = "\(undo.count) Objekte umbenannt · Rückgängig über Cmd+Z im Hauptfenster";info.textColor = .secondaryLabelColor
        case .failure(let error):
            lastError = error.localizedDescription;report.isEnabled = true;info.toolTip = lastError
            if case CommanderError.cancelled = error { info.stringValue = "Abgebrochen · vorbereitete Namensänderungen wurden zurückgesetzt";info.textColor = .secondaryLabelColor }
            else { showError(error) }
        }
    }
    func cancelOrClose() { if isWorking,let id = jobID { onCancel?(id) } else { close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isWorking }
    private func updateSettingsButtons() {
        let index = settingsTabs.selectedTabViewItem.map { settingsTabs.indexOfTabViewItem($0) } ?? 0
        for (offset,button) in settingsButtons.enumerated() { button.state = offset == index ? .on : .off }
    }
    func tabView(_ tabView: NSTabView,didSelect tabViewItem: NSTabViewItem?) { updateSettingsButtons() }
    override func close() { guard !isWorking else { return };preparation.cancel();delayed?.cancel();super.close() }
    func numberOfRows(in tableView: NSTableView) -> Int { choices.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        guard choices.indices.contains(row) else { return nil };let choice = choices[row],preview = rows[choice.id]
        if tableColumn?.identifier.rawValue == "include" {
            let button = ActionButton("",action:{ [weak self] in self?.toggle(choice.id) });button.setButtonType(.switch);button.state = choice.enabled ? .on : .off;button.isEnabled = !isWorking;return button
        }
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "source": text = choice.url.lastPathComponent
        case "target": text = choice.enabled ? preview?.targetName ?? "—" : "—"
        case "parent": text = choice.url.deletingLastPathComponent().path
        default: text = !choice.enabled ? "Ausgelassen" : preview?.error ?? (preview.map { $0.item?.changed == true ? "Wird umbenannt" : "Unverändert" } ?? (isWorking ? "Auftrag läuft" : "Vorschau aktualisieren"))
        }
        let field = label(text,size:12,color:preview?.error == nil ? .labelColor : .systemRed);field.toolTip = preview?.error ?? text;return field
    }
    func refreshProfiles() {
        do {
            library = try Preferences.renameProfiles();profileError = nil
            if let id = selectedProfileID,library.profile(id) == nil { selectedProfileID = nil }
            profilePopup.removeAllItems();profilePopup.addItem(withTitle:"Eigene Einstellungen")
            for profile in library.profiles { profilePopup.addItem(withTitle:profile.name);profilePopup.lastItem?.representedObject = profile.id.uuidString }
            let index = profilePopup.itemArray.firstIndex { ($0.representedObject as? String) == selectedProfileID?.uuidString } ?? 0
            profilePopup.selectItem(at:index)
        } catch { profileError = error.localizedDescription }
        updateProfileState()
    }
    private func updateProfileState() {
        let valid = (try? rule()) != nil
        profileSave.isEnabled = !isWorking && profileError == nil && selectedProfileID != nil && valid
        profileSaveAs.isEnabled = !isWorking && profileError == nil && valid
        profileRemove.isEnabled = !isWorking && profileError == nil && selectedProfileID != nil
        profilePopup.isEnabled = !isWorking && profileError == nil
        profileStatus.textColor = profileError == nil ? .secondaryLabelColor : .systemRed
        if let profileError { profileStatus.stringValue = "Profile nicht lesbar";profileStatus.toolTip = profileError }
        else if let id = selectedProfileID,let profile = library.profile(id) { profileStatus.stringValue = (try? rule()) == profile.rule ? "Gespeichert" : "Geändert" }
        else { profileStatus.stringValue = "Eigene Einstellungen" }
    }
    @objc func chooseProfile() {
        guard !isWorking else { return }
        if let text = profilePopup.selectedItem?.representedObject as? String,let id = UUID(uuidString:text),let profile = library.profile(id) { selectedProfileID = id;setRule(profile.rule) }
        else { selectedProfileID = nil }
        schedulePreview()
    }
    func saveProfile() {
        guard let id = selectedProfileID,let profile = library.profile(id),!isWorking else { return }
        do { let value = try rule();try Preferences.editRenameProfiles { _ = try $0.save(name:profile.name,rule:value,replacing:id) };refreshProfiles() }
        catch { profileStatus.stringValue = error.localizedDescription;profileStatus.toolTip = error.localizedDescription }
    }
    func saveProfileAs() {
        guard !isWorking,(try? rule()) != nil,let window else { return }
        let sheet = CopyProfileNameController(title:"Umbenennungsprofil speichern",message:"Aktuelle Namensregeln speichern");profileNameWindow = sheet
        sheet.onSave = { [weak self] name in guard let self else { return };let value = try self.rule();self.selectedProfileID = try Preferences.editRenameProfiles { try $0.save(name:name,rule:value) };self.refreshProfiles() }
        window.beginSheet(sheet.window!)
    }
    func removeProfile() {
        guard !isWorking,let id = selectedProfileID,let profile = library.profile(id),let window else { return }
        let alert = NSAlert();alert.messageText = "Umbenennungsprofil löschen?";alert.informativeText = profile.name;alert.addButton(withTitle:"Löschen");alert.addButton(withTitle:"Abbrechen");deleteAlert = alert
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self,response == .alertFirstButtonReturn else { return }
            do { try Preferences.editRenameProfiles { try $0.remove(id) };self.selectedProfileID = nil;self.refreshProfiles() }
            catch { self.profileStatus.stringValue = error.localizedDescription }
        }
    }
}
