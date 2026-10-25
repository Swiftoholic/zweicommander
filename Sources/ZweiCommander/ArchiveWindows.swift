import AppKit
import CommanderCore

enum ArchivePrepared {
    case pack(ArchivePackPlan),extract(ArchiveExtractionPlan)
    var rows:[ArchiveMember] { switch self { case .pack(let value):return value.rows;case .extract(let value):return value.rows } }
    var destination:URL { switch self { case .pack(let value):return value.destination;case .extract(let value):return value.destination } }
    var totalBytes:Int64 { switch self { case .pack(let value):return value.totalBytes;case .extract(let value):return value.totalBytes } }
    func validate() throws { switch self { case .pack(let value):try value.validate();case .extract(let value):try value.validate() } }
}
enum ArchiveSetupMode { case pack([URL]),extract(URL,ArchiveCatalog?,[String]?,String) }

final class ArchiveSetupController:NSWindowController,NSWindowDelegate,NSTextFieldDelegate,NSTableViewDataSource,NSTableViewDelegate {
    let mode:ArchiveSetupMode,destination:NSTextField
    let format = NSPopUpButton(),compression = NSPopUpButton(),password = NSSecureTextField(string:"")
    let selectedOnly = checkbox("Nur markierte Archiveinträge entpacken",on:true)
    let table = operationTable([("name","Pfad im Ergebnis",480),("kind","Art",110),("size","Größe",110)])
    let info = label("Inhalt wird geprüft …",size:12),optionsInfo = label("",size:11,color:.secondaryLabelColor)
    let start = ActionButton("Starten",symbol:"play.fill",action:{}),queue = ActionButton("Vormerken",symbol:"text.badge.plus",action:{})
    private(set) var prepared:ArchivePrepared?,rows:[ArchiveMember] = [],isPreparing = false
    private var generation = UUID(),token = CancellationToken(),delay:DispatchWorkItem?,inputs:[String] = []
    let validateDestination:(URL)throws->Void
    var onSubmit:((ArchivePrepared,String,Bool)->Bool)?
    var packing:Bool { if case .pack = mode { return true };return false }
    init(mode:ArchiveSetupMode,destination:URL,secret:String = "",validateDestination:@escaping(URL)throws->Void) {
        self.mode = mode;self.destination = input(destination.path);self.validateDestination = validateDestination
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:860,height:610),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = { if case .pack = mode { return "Archiv erstellen" };return "Archiv entpacken" }();w.minSize = NSSize(width:860,height:610);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        let root = OperationContent(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        let heading = label(w.title,size:22,weight:.semibold);heading.frame = NSRect(x:22,y:560,width:816,height:32);heading.autoresizingMask = [.minYMargin,.width];root.addSubview(heading)
        let source:String
        switch mode { case .pack(let sources):source = "\(sources.count) ausgewählte Quellen · Originale bleiben erhalten"
        case .extract(let url,_,_,_):source = url.lastPathComponent+" · Ausgabe in einen neuen Ordner" }
        let note = label(source,size:12);note.frame = NSRect(x:22,y:530,width:816,height:24);note.autoresizingMask = [.minYMargin,.width];root.addSubview(note)
        let caption = label(packing ? "Archivdatei" : "Neuer Zielordner",weight:.medium);caption.frame = NSRect(x:22,y:493,width:135,height:24);caption.autoresizingMask = [.minYMargin];root.addSubview(caption)
        self.destination.frame = NSRect(x:158,y:490,width:578,height:28);self.destination.delegate = self;self.destination.autoresizingMask = [.minYMargin,.width];self.destination.toolTip = "⌘L · Vollständiges Ziel bearbeiten. Vorhandene Ziele werden nicht ersetzt.";root.addSubview(self.destination)
        let choose = ActionButton("Wählen …",symbol:"folder",action:{ [weak self] in self?.chooseDestination() });choose.frame = NSRect(x:744,y:489,width:94,height:30);choose.autoresizingMask = [.minYMargin,.minXMargin];choose.setHelp("Ziel wählen","Zielname beziehungsweise Elternordner wählen.",shortcut:"⌘⇧L");root.addSubview(choose)
        format.addItems(withTitles:ArchiveFormat.allCases.map(\.title));compression.addItems(withTitles:(0...9).map { $0 == 0 ? "0 · Unkomprimiert" : "\($0)" });compression.selectItem(at:6)
        let defaultExtension = Preferences.state.importedProfile?.defaultArchiveExtension ?? "zip"
        format.selectItem(at:ArchiveFormat.allCases.firstIndex { $0.fileExtension == defaultExtension } ?? 0)
        compression.selectItem(at:ArchiveFormat.allCases[format.indexOfSelectedItem] == .sevenZip ? Preferences.state.importedProfile?.sevenZipCompressionLevel ?? 6 : Preferences.state.importedProfile?.zipCompressionLevel ?? 6)
        let options = packing ? row([label("Format"),format,label("Kompression"),compression]) : row([label("Passwort (optional)"),password])
        options.frame = NSRect(x:22,y:445,width:816,height:28);options.autoresizingMask = [.width,.minYMargin];root.addSubview(options)
        password.stringValue = secret;password.delegate = self;password.toolTip = "Nur für diesen Vorgang. Keine Speicherung in Einstellungen, Profilen oder dem Auftragsjournal."
        password.widthAnchor.constraint(greaterThanOrEqualToConstant:360).isActive = true
        format.target = self;format.action = #selector(formatChanged);compression.target = self;compression.action = #selector(optionChanged)
        selectedOnly.frame = NSRect(x:22,y:410,width:816,height:26);selectedOnly.autoresizingMask = [.width,.minYMargin];selectedOnly.isHidden = packing
        if case .extract(_,_,let selection,_) = mode { selectedOnly.isEnabled = selection?.isEmpty == false;selectedOnly.state = selection?.isEmpty == false ? .on : .off }
        selectedOnly.target = self;selectedOnly.action = #selector(optionChanged);selectedOnly.toolTip = "Bei Auswahl bleiben die Namen relativ zum angezeigten Archivordner erhalten. Ohne Auswahl wird das vollständige Archiv entpackt.";root.addSubview(selectedOnly)
        optionsInfo.frame = NSRect(x:22,y:383,width:816,height:24);optionsInfo.autoresizingMask = [.width,.minYMargin];root.addSubview(optionsInfo)
        table.dataSource = self;table.delegate = self;table.setAccessibilityLabel("Geplanter Archivinhalt")
        let list = operationScroll(table);list.frame = NSRect(x:22,y:128,width:816,height:248);list.autoresizingMask = [.width,.height];root.addSubview(list)
        info.frame = NSRect(x:22,y:82,width:816,height:39);info.maximumNumberOfLines = 2;info.lineBreakMode = .byWordWrapping;info.autoresizingMask = [.width];root.addSubview(info)
        let safety = label("Vorhandene Ziele bleiben erhalten. Bis zu 500 Vorschauzeilen; die vollständige Auswahl wird verarbeitet.\nArchivsitzungsaufträge und Passwörter werden nicht für einen Neustart gespeichert.",size:11,color:.secondaryLabelColor)
        safety.frame = NSRect(x:22,y:40,width:816,height:36);safety.maximumNumberOfLines = 2;safety.autoresizingMask = [.width];root.addSubview(safety)
        let refresh = ActionButton("Neu prüfen",symbol:"arrow.clockwise",action:{ [weak self] in self?.prepare() });refresh.setHelp("Neu prüfen","Quellen, Archiveinträge und Ziel erneut einlesen.",shortcut:"⌘R")
        let cancel = ActionButton("Abbrechen",action:{ [weak self] in self?.close() });cancel.keyEquivalent = "\u{1b}";cancel.keyEquivalentModifierMask = []
        start.perform = { [weak self] in self?.submit(true) };queue.perform = { [weak self] in self?.submit(false) }
        start.setHelp("Starten","Die geprüfte Vorschau ausführen.",shortcut:"⌘↩");queue.setHelp("Vormerken","Die geprüfte Vorschau in dieser Sitzung vormerken.",shortcut:"⌘⇧↩")
        let actions = row([refresh,cancel,queue,start]);actions.frame = NSRect(x:22,y:5,width:816,height:30);actions.autoresizingMask = [.width];root.addSubview(actions)
        w.workflowKeys = { [weak self,weak w] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"\r",.command) { self.submit(true);return true }
            if WorkflowKeys.matches(event,"\r",[.command,.shift]) { self.submit(false);return true }
            if WorkflowKeys.matches(event,"l",.command) { w?.makeFirstResponder(self.destination);self.destination.selectText(nil);return true }
            if WorkflowKeys.matches(event,"l",[.command,.shift]) { self.chooseDestination();return true }
            if WorkflowKeys.matches(event,"r",.command) { self.prepare();return true };return false
        }
        w.initialFirstResponder = self.destination;w.center();updateOptions();prepare()
    }
    required init?(coder:NSCoder) { fatalError() }
    private var currentInputs:[String] { [destination.stringValue,String(format.indexOfSelectedItem),String(compression.indexOfSelectedItem),password.stringValue,String(selectedOnly.state.rawValue)] }
    func controlTextDidChange(_ notification:Notification) { invalidate();delay?.cancel();let work = DispatchWorkItem { [weak self] in self?.prepare() };delay = work;DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work) }
    private func invalidate() { token.cancel();generation = UUID();prepared = nil;rows = [];table.reloadData();start.isEnabled = false;queue.isEnabled = false;info.stringValue = "Änderungen werden geprüft …";info.textColor = .secondaryLabelColor }
    @objc func optionChanged() { updateOptions();prepare() }
    @objc func formatChanged() {
        let chosen = ArchiveFormat.allCases[format.indexOfSelectedItem],url = URL(fileURLWithPath:destination.stringValue)
        destination.stringValue = url.deletingLastPathComponent().appendingPathComponent(ArchiveCatalog.folderName(for:url)+"."+chosen.fileExtension).path
        compression.selectItem(at:chosen == .sevenZip ? Preferences.state.importedProfile?.sevenZipCompressionLevel ?? 6 : Preferences.state.importedProfile?.zipCompressionLevel ?? 6);optionChanged()
    }
    private func updateOptions() { compression.isEnabled = packing && ArchiveFormat.allCases[format.indexOfSelectedItem] != .tarGzip;optionsInfo.stringValue = packing ? "ZIP und 7z: Stufe 0–9 · TAR + GZip: Systemvorgabe · Keine Verschlüsselung" : "Maximal 100 GB entpackte Daten · Keine Verknüpfungen oder Spezialdateien" }
    func prepare() {
        delay?.cancel();invalidate();token = CancellationToken();let task = generation,token = token,values = currentInputs,mode = mode,validate = validateDestination
        inputs = values;isPreparing = true
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () -> ArchivePrepared in
                let text = (values[0] as NSString).expandingTildeInPath
                guard text.hasPrefix("/"),!text.contains("\0") else { throw CommanderError.message("Bitte einen vollständigen lokalen Zielpfad angeben.") }
                let destination = URL(fileURLWithPath:text);try validate(destination);try token.check()
                switch mode {
                case .pack(let urls):return .pack(try ArchivePackPlan(sources:urls,to:destination,format:ArchiveFormat.allCases[Int(values[1]) ?? 0],compressionLevel:Int(values[2]) ?? 6,token:token))
                case .extract(let url,let existing,let selection,let base):
                    let catalog = try existing ?? ArchiveCatalog.read(url,password:values[3],token:token);try token.check()
                    return .extract(try ArchiveExtractionPlan(catalog:catalog,to:destination,selection:values[4] == String(NSControl.StateValue.on.rawValue) ? selection : nil,relativeTo:values[4] == String(NSControl.StateValue.on.rawValue) ? base : ""))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == task,!token.isCancelled else { return };self.isPreparing = false
                switch result {
                case .success(let prepared):self.prepared = prepared;self.rows = Array(prepared.rows.prefix(500));self.table.reloadData();self.start.isEnabled = true;self.queue.isEnabled = true;self.info.stringValue = "\(prepared.rows.count) Einträge · \(bytes(prepared.totalBytes))\nZiel: "+prepared.destination.path;self.info.textColor = .labelColor
                case .failure(let error):self.info.stringValue = error.localizedDescription;self.info.textColor = .systemRed
                }
            }
        }
    }
    func submit(_ immediately:Bool) {
        guard currentInputs == inputs else { prepare();return };guard let prepared,!isPreparing else { return }
        let values = inputs,stamp = generation,validate = validateDestination
        isPreparing = true;start.isEnabled = false;queue.isEnabled = false;info.stringValue = "Vorschau wird vor der Übernahme erneut geprüft …"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try validate(prepared.destination);try prepared.validate() }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == stamp,self.currentInputs == values else { return };self.isPreparing = false
                switch result {
                case .success:if self.onSubmit?(prepared,values[3],immediately) == true { self.close() } else { self.start.isEnabled = true;self.queue.isEnabled = true }
                case .failure(let error):self.prepare();self.info.stringValue = "Quelle oder Ziel wurde geändert. Neue Vorschau prüfen.\n"+error.localizedDescription;self.info.textColor = .systemOrange
                }
            }
        }
    }
    func chooseDestination() {
        if packing { let panel = NSSavePanel();panel.directoryURL = URL(fileURLWithPath:destination.stringValue).deletingLastPathComponent();panel.nameFieldStringValue = URL(fileURLWithPath:destination.stringValue).lastPathComponent;if panel.runModal() == .OK,let url = panel.url { destination.stringValue = url.path;prepare() } }
        else { let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.prompt = "Elternordner wählen";if panel.runModal() == .OK,let url = panel.url { destination.stringValue = url.appendingPathComponent(URL(fileURLWithPath:destination.stringValue).lastPathComponent).path;prepare() } }
    }
    func windowWillClose(_ notification:Notification) { token.cancel();delay?.cancel();generation = UUID();password.stringValue = "";inputs = [];onSubmit = nil }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? { guard rows.indices.contains(row) else { return nil };let item = rows[row];return label(column?.identifier.rawValue == "name" ? item.path : column?.identifier.rawValue == "kind" ? item.isDirectory ? "Ordner" : "Datei" : item.isDirectory ? "—" : bytes(item.size)) }
}

final class ArchivePasswordController:NSWindowController,NSWindowDelegate {
    let password = NSSecureTextField(string:"");var onSubmit:((String)->Void)?
    init(name:String,error:String?) {
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:540,height:225),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.title = "Archiv öffnen";w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self;let root = OperationContent(frame:w.contentView!.bounds);w.contentView = root
        let title = label(name,size:18,weight:.semibold);title.frame = NSRect(x:22,y:181,width:496,height:26);root.addSubview(title)
        let info = label((error ?? "Passwort für dieses Archiv eingeben.")+"\nPasswörter bleiben nur in dieser Sitzung.",size:12);info.maximumNumberOfLines = 3;info.lineBreakMode = .byWordWrapping;info.frame = NSRect(x:22,y:100,width:496,height:73);root.addSubview(info)
        password.placeholderString = "Archivpasswort";password.frame = NSRect(x:22,y:60,width:496,height:28);password.setAccessibilityLabel("Archivpasswort");root.addSubview(password)
        let cancel = ActionButton("Abbrechen",action:{ [weak self] in self?.close() });cancel.keyEquivalent = "\u{1b}";cancel.keyEquivalentModifierMask = []
        let open = ActionButton("Erneut öffnen",action:{ [weak self] in self?.submit() });open.keyEquivalent = "\r";open.keyEquivalentModifierMask = []
        let actions = row([cancel,open]);actions.frame = NSRect(x:22,y:14,width:496,height:30);root.addSubview(actions)
        w.workflowKeys = { [weak self] in if WorkflowKeys.matches($0,"\r",.command) { self?.submit();return true };return false };w.initialFirstResponder = password;w.center()
    }
    required init?(coder:NSCoder) { fatalError() }
    func submit() { let value = password.stringValue;onSubmit?(value);close() }
    func windowWillClose(_ notification:Notification) { password.stringValue = "";onSubmit = nil }
}
