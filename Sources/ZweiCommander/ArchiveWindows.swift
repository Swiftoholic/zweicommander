import AppKit
import CommanderCore

enum ArchivePrepared {
    case pack(ArchivePackPlan),extract(ArchiveExtractionPlan),merge(ArchiveMergePlan)
    var rows:[ArchiveMember] { switch self { case .pack(let value):return value.rows;case .extract(let value):return value.rows;case .merge(let value):return value.rows } }
    var destination:URL { switch self { case .pack(let value):return value.destination;case .extract(let value):return value.destination;case .merge(let value):return value.destination } }
    var totalBytes:Int64 { switch self { case .pack(let value):return value.totalBytes;case .extract(let value):return value.totalBytes;case .merge(let value):return value.totalBytes } }
    var merge:ArchiveMergePlan? { if case .merge(let value) = self { return value };return nil }
    var initialItems:[TransferItemProgress] { merge?.initialItems ?? [] }
    func validate() throws { switch self { case .pack(let value):try value.validate();case .extract(let value):try value.validate();case .merge(let value):try value.validate() } }
}
enum ArchiveSetupMode { case pack([URL]),extract(URL,ArchiveCatalog?,[String]?,String) }

final class ArchiveSetupController:NSWindowController,NSWindowDelegate,NSTextFieldDelegate,NSTableViewDataSource,NSTableViewDelegate {
    let mode:ArchiveSetupMode,destination:NSTextField
    let format = NSPopUpButton(),compression = NSPopUpButton(),password = NSSecureTextField(string:"")
    let selectedOnly = checkbox("Nur markierte Archiveinträge entpacken",on:true),conflictsOnly = checkbox("Nur Konflikte")
    let policy = NSPopUpButton(),pageInfo = label("",size:11,color:.secondaryLabelColor)
    let previousPage = ActionButton("",symbol:"chevron.left",action:{}),nextPage = ActionButton("",symbol:"chevron.right",action:{})
    let previousConflict = ActionButton("Vorheriger Konflikt",symbol:"arrow.up",action:{}),nextConflict = ActionButton("Nächster Konflikt",symbol:"arrow.down",action:{})
    let table = operationTable([("name","Pfad im Ergebnis",480),("kind","Art",110),("size","Größe",110)])
    let heading = label("",size:22,weight:.semibold),sourceInfo = label("",size:12),destinationCaption = label("",weight:.medium)
    let info = label("Inhalt wird geprüft …",size:12),optionsInfo = label("",size:11,color:.secondaryLabelColor),safety = label("",size:11,color:.secondaryLabelColor)
    let start = ActionButton("Starten",symbol:"play.fill",action:{}),queue = ActionButton("Vormerken",symbol:"text.badge.plus",action:{})
    let choose = ActionButton("Wählen …",symbol:"folder",action:{}),refresh = ActionButton("Neu prüfen",symbol:"arrow.clockwise",action:{}),cancel = ActionButton("Abbrechen",action:{})
    var prepared:ArchivePrepared?,rows:[ArchiveMember] = [],isPreparing = false
    var generation = UUID(),inputs:[String] = [],previewPage = 0,visibleIndexes:[Int] = [],filteredIndexes:[Int] = []
    var renameController:ArchiveRenameController?
    private var token = CancellationToken(),delay:DispatchWorkItem?
    let validateDestination:(URL)throws->Void
    var onSubmit:((ArchivePrepared,String,Bool)->Bool)?
    var packing:Bool { if case .pack = mode { return true };return false }
    var currentInputs:[String] { [destination.stringValue,String(format.indexOfSelectedItem),String(compression.indexOfSelectedItem),password.stringValue,String(selectedOnly.state.rawValue),String(policy.indexOfSelectedItem)] }
    init(mode:ArchiveSetupMode,destination:URL,secret:String = "",validateDestination:@escaping(URL)throws->Void) {
        self.mode = mode;self.destination = input(destination.path);self.validateDestination = validateDestination
        let packing:Bool;if case .pack = mode { packing = true } else { packing = false }
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:packing ? 860 : 1100,height:packing ? 610 : 740),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = packing ? "Archiv erstellen" : "Archiv entpacken";w.minSize = NSSize(width:packing ? 860 : 1000,height:packing ? 610 : 700);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        format.addItems(withTitles:ArchiveFormat.allCases.map(\.title));compression.addItems(withTitles:(0...9).map { $0 == 0 ? "0 · Unkomprimiert" : "\($0)" })
        let defaultExtension = Preferences.state.importedProfile?.defaultArchiveExtension ?? "zip"
        format.selectItem(at:ArchiveFormat.allCases.firstIndex { $0.fileExtension == defaultExtension } ?? 0)
        compression.selectItem(at:ArchiveFormat.allCases[format.indexOfSelectedItem] == .sevenZip ? Preferences.state.importedProfile?.sevenZipCompressionLevel ?? 6 : Preferences.state.importedProfile?.zipCompressionLevel ?? 6)
        policy.addItems(withTitles:ArchiveConflictPolicy.allCases.map(\.title));policy.target = self;policy.action = #selector(policyChanged)
        password.stringValue = secret;password.delegate = self;self.destination.delegate = self
        if case .extract(_,_,let selection,_) = mode { selectedOnly.isEnabled = selection?.isEmpty == false;selectedOnly.state = selection?.isEmpty == false ? .on : .off }
        format.target = self;format.action = #selector(formatChanged);compression.target = self;compression.action = #selector(optionChanged)
        selectedOnly.target = self;selectedOnly.action = #selector(optionChanged);conflictsOnly.target = self;conflictsOnly.action = #selector(filterConflicts)
        table.dataSource = self;table.delegate = self;table.intercellSpacing = NSSize(width:4,height:0);table.setAccessibilityLabel("Geplanter Archivinhalt")
        buildArchiveInterface(w);configureArchiveKeys(w);w.initialFirstResponder = self.destination;w.center();updateOptions();prepare()
    }
    required init?(coder:NSCoder) { fatalError() }
    func controlTextDidChange(_ notification:Notification) {
        if notification.object as? NSSecureTextField === password,prepared != nil { generation = UUID();inputs = currentInputs;isPreparing = false;updatePreview();return }
        invalidate();delay?.cancel();let work = DispatchWorkItem { [weak self] in self?.prepare() };delay = work;DispatchQueue.main.asyncAfter(deadline:.now()+0.35,execute:work)
    }
    private func invalidate() {
        token.cancel();generation = UUID();prepared = nil;rows = [];visibleIndexes = [];filteredIndexes = [];previewPage = 0;table.reloadData()
        start.isEnabled = false;queue.isEnabled = false;info.stringValue = "Änderungen werden geprüft …";info.textColor = .secondaryLabelColor;updateConflictButtons()
    }
    @objc func optionChanged() { updateOptions();prepare() }
    @objc func formatChanged() {
        let chosen = ArchiveFormat.allCases[format.indexOfSelectedItem],url = URL(fileURLWithPath:destination.stringValue)
        destination.stringValue = url.deletingLastPathComponent().appendingPathComponent(ArchiveCatalog.folderName(for:url)+"."+chosen.fileExtension).path
        compression.selectItem(at:chosen == .sevenZip ? Preferences.state.importedProfile?.sevenZipCompressionLevel ?? 6 : Preferences.state.importedProfile?.zipCompressionLevel ?? 6);optionChanged()
    }
    private func updateOptions() {
        compression.isEnabled = packing && ArchiveFormat.allCases[format.indexOfSelectedItem] != .tarGzip
        optionsInfo.stringValue = packing ? "ZIP und 7z: Stufe 0–9 · TAR + GZip: Systemvorgabe · Keine Verschlüsselung" : "Maximal 100 GB · Vorhandene Ordner werden ergänzt · Verknüpfungen und Spezialdateien werden nicht überschrieben"
    }
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
                    let catalog = try existing ?? ArchiveCatalog.read(url,password:values[3],token:token),selected = values[4] == String(NSControl.StateValue.on.rawValue) ? selection : nil
                    let relative = selected == nil ? "" : base;try token.check()
                    if FileSystem.exists(destination) { return .merge(try ArchiveMergePlan(catalog:catalog,to:destination,selection:selected,relativeTo:relative,policy:ArchiveConflictPolicy.allCases[Int(values[5]) ?? 0],token:token)) }
                    return .extract(try ArchiveExtractionPlan(catalog:catalog,to:destination,selection:selected,relativeTo:relative))
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == task,!token.isCancelled else { return };self.isPreparing = false
                switch result {
                case .success(let value):self.prepared = value;self.updatePreview()
                case .failure(let error):self.info.stringValue = error.localizedDescription;self.info.textColor = .systemRed;self.updateConflictButtons()
                }
            }
        }
    }
    func replacePrepared(_ value:ArchivePrepared) { generation = UUID();prepared = value;inputs = currentInputs;isPreparing = false;updatePreview() }
    func submit(_ immediately:Bool) {
        guard currentInputs == inputs else { prepare();return };guard let prepared,!isPreparing else { return }
        guard (prepared.merge?.unresolvedCount ?? 0) == 0 else { focusConflict(backward:false);return }
        let values = inputs,stamp = generation,validate = validateDestination
        isPreparing = true;start.isEnabled = false;queue.isEnabled = false;info.stringValue = "Vorschau wird vor der Übernahme erneut geprüft …"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { try validate(prepared.destination);try prepared.validate() }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == stamp,self.currentInputs == values else { return };self.isPreparing = false
                switch result {
                case .success:if self.onSubmit?(prepared,values[3],immediately) == true { self.close() } else { self.updatePreview() }
                case .failure(let error):self.policy.selectItem(at:0);self.prepare();self.info.stringValue = "Quelle oder Ziel wurde geändert. Neue Vorschau prüfen.\n"+error.localizedDescription;self.info.textColor = .systemOrange
                }
            }
        }
    }
    func chooseDestination() {
        if packing {
            let panel = NSSavePanel();panel.directoryURL = URL(fileURLWithPath:destination.stringValue).deletingLastPathComponent();panel.nameFieldStringValue = URL(fileURLWithPath:destination.stringValue).lastPathComponent
            if panel.runModal() == .OK,let url = panel.url { destination.stringValue = url.path;prepare() }
        } else {
            let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.canCreateDirectories = true;panel.prompt = "Zielordner wählen"
            let current = URL(fileURLWithPath:destination.stringValue);panel.directoryURL = FileSystem.isDirectory(current) ? current : current.deletingLastPathComponent()
            if panel.runModal() == .OK,let url = panel.url { destination.stringValue = url.path;prepare() }
        }
    }
    func windowWillClose(_ notification:Notification) { token.cancel();delay?.cancel();generation = UUID();renameController?.close();renameController = nil;password.stringValue = "";inputs = [];onSubmit = nil }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? { archiveCell(column:column?.identifier.rawValue ?? "",row:row) }
}
