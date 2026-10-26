import AppKit
import CommanderCore

extension MainWindow {
    var mediaMetadataURLs:[URL] {
        guard NSApp.keyWindow === window,window?.attachedSheet == nil,!active.pathField.sessionActive,!active.inlineRename.isEditing,!(window?.firstResponder is NSTextView),active.canUseDisplayedEntries,active.archive == nil,active.remote == nil else { return [] }
        let selected = Set(active.selectedURLs),ordered = active.visibleEntries.filter { selected.contains($0.url) }
        guard (1...100).contains(ordered.count),ordered.count == selected.count,ordered.allSatisfy({ $0.url.isFileURL && $0.isRegularFile && !$0.isSymbolicLink && !active.isSessionTemporary($0.url) }) else { return [] }
        return ordered.map(\.url)
    }
    var mediaMetadataCommandEnabled:Bool { !mediaMetadataURLs.isEmpty }
    func showMediaMetadata() {
        let urls = mediaMetadataURLs;guard !urls.isEmpty else { content.status.stringValue = "1–100 lokale reguläre Dateien auswählen; Mediendaten sind für Server, Archivmitglieder und Verknüpfungen nicht verfügbar.";return }
        let controller = MediaMetadataController(files:urls);secondaryWindows.append(controller);controller.showWindow(nil)
    }
}

final class MediaMetadataController:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate {
    let files:[URL]
    private(set) var index = 0,isLoading = false,closed = false
    private(set) var metadata:MediaMetadata?,error:String?,rows:[(String,String)] = []
    let table = CommanderTableView(),source = label("",size:12),status = label("",size:12),limits = label("Bild/EXIF, ID3, RIFF/WAV und MP4/MOV: begrenzte Dateiköpfe, keine Medienwiedergabe. Fehlende Felder bleiben leer. Bilddaten bis 64 MiB, Header bis 8 MiB, Budget 2 Sekunden zwischen Abschnitten. Einzelne ImageIO-Abfragen sind nicht unterbrechbar.",size:11,color:.secondaryLabelColor)
    let previous = ActionButton("Vorherige Datei",symbol:"chevron.left",action:{}),next = ActionButton("Nächste Datei",symbol:"chevron.right",action:{})
    let reload = ActionButton("Neu laden",symbol:"arrow.clockwise",action:{}),cancel = ActionButton("Abbrechen",action:{}),closeButton = ActionButton("Schließen",action:{})
    private let queue:OperationQueue = { let value = OperationQueue();value.maxConcurrentOperationCount = 1;value.qualityOfService = .userInitiated;return value }()
    private var token = CancellationToken(),generation = UUID()
    init(files:[URL]) {
        self.files = Array(files.prefix(100));let window = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:800,height:660),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "Medieninformationen";window.minSize = NSSize(width:720,height:600);window.isReleasedWhenClosed = false
        super.init(window:window);window.delegate = self
        let root = OperationContent(frame:window.contentView!.bounds);root.autoresizingMask = [.width,.height];window.contentView = root
        let heading = label("Medieninformationen",size:21,weight:.semibold);heading.frame = NSRect(x:22,y:610,width:756,height:32);heading.autoresizingMask = [.width,.minYMargin];root.addSubview(heading)
        source.frame = NSRect(x:22,y:576,width:756,height:24);source.lineBreakMode = .byTruncatingMiddle;source.autoresizingMask = [.width,.minYMargin];root.addSubview(source)
        previous.frame = NSRect(x:22,y:535,width:190,height:29);next.frame = NSRect(x:222,y:535,width:190,height:29);reload.frame = NSRect(x:572,y:535,width:206,height:29)
        previous.autoresizingMask = [.minYMargin];next.autoresizingMask = [.minYMargin];reload.autoresizingMask = [.minYMargin,.minXMargin]
        [previous,next,reload].forEach { root.addSubview($0) }
        table.delegate = self;table.dataSource = self;table.rowHeight = 30;table.usesAlternatingRowBackgroundColors = true;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id,title,width) in [("field","Feld",CGFloat(190)),("value","Wert",560)] { let column = NSTableColumn(identifier:.init(id));column.title = title;column.width = width;column.minWidth = 80;table.addTableColumn(column) }
        let scroll = NSScrollView(frame:NSRect(x:22,y:160,width:756,height:360));scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.autoresizingMask = [.width,.height];scroll.borderType = .bezelBorder;root.addSubview(scroll)
        status.frame = NSRect(x:22,y:126,width:756,height:24);status.autoresizingMask = [.width];root.addSubview(status)
        limits.frame = NSRect(x:22,y:56,width:756,height:64);limits.maximumNumberOfLines = 6;limits.toolTip = MediaMetadataReader.help;limits.autoresizingMask = [.width];root.addSubview(limits)
        cancel.frame = NSRect(x:22,y:16,width:150,height:29);closeButton.frame = NSRect(x:608,y:16,width:170,height:29);closeButton.autoresizingMask = [.minXMargin];root.addSubview(cancel);root.addSubview(closeButton)
        previous.perform = { [weak self] in self?.changeFile(-1) };next.perform = { [weak self] in self?.changeFile(1) };reload.perform = { [weak self] in self?.load() };cancel.perform = { [weak self] in self?.cancelRead() };closeButton.perform = { [weak self] in self?.close() }
        previous.setHelp("Vorherige Datei","Vorherige Datei der eingefrorenen Auswahl prüfen.",shortcut:"⌘⌥←");next.setHelp("Nächste Datei","Nächste Datei der eingefrorenen Auswahl prüfen.",shortcut:"⌘⌥→");reload.setHelp("Neu laden","Mediendaten erneut aus der aktuellen Datei lesen.",shortcut:"⌘R");cancel.setHelp("Abbrechen","Das aktuelle Ergebnis verwerfen und die Hintergrundprüfung abbrechen.",shortcut:"⌘.");closeButton.setHelp("Schließen","Das Informationsfenster schließen.",shortcut:"Esc")
        window.workflowKeys = { [weak self] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"r",.command) { self.load();return true }
            if WorkflowKeys.matches(event,".",.command) { self.cancelRead();return true }
            if WorkflowKeys.matches(event,String(UnicodeScalar(NSLeftArrowFunctionKey)!),[.command,.option]) { self.changeFile(-1);return true }
            if WorkflowKeys.matches(event,String(UnicodeScalar(NSRightArrowFunctionKey)!),[.command,.option]) { self.changeFile(1);return true }
            if event.keyCode == 53 { self.close();return true };return false
        }
        window.center();load()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { token.cancel();queue.cancelAllOperations() }
    func changeFile(_ delta:Int) { guard files.indices.contains(index+delta) else { return };index += delta;load() }
    func load() {
        guard !closed,files.indices.contains(index) else { return };token.cancel();queue.cancelAllOperations();token = CancellationToken();generation = UUID();let token = token,version = generation,url = files[index]
        metadata = nil;error = nil;rows = [];isLoading = true;status.stringValue = "Lese begrenzte Dateiköpfe …";status.textColor = .secondaryLabelColor;source.stringValue = "\(index+1)/\(files.count) · "+url.path;source.toolTip = url.path;table.reloadData();updateControls()
        queue.addOperation { [weak self] in
            let result = Result { try MediaMetadataReader.read(url,token:token) }
            DispatchQueue.main.async { [weak self] in
                guard let self,!self.closed,self.generation == version,!token.isCancelled else { return };self.isLoading = false
                switch result {
                case .success(let value):self.metadata = value;self.rows = [("Dateiformat",value.format)]+MediaMetadataField.allCases.map { ($0.title,$0.text(value) ?? "— (nicht im Dateikopf vorhanden)") };self.rows += value.notes.map { ("Hinweis",$0) };self.status.stringValue = value.hasValues ? "Dateiköpfe geprüft · Fehlende Felder bleiben leer" : "Kein auswertbares Feld im unterstützten Dateikopf";self.status.textColor = .secondaryLabelColor
                case .failure(let error):self.error = error.localizedDescription;self.rows = [("Nicht verfügbar",error.localizedDescription)];self.status.stringValue = "Mediendaten nicht verfügbar";self.status.textColor = .systemOrange
                }
                self.table.reloadData();self.updateControls()
            }
        }
    }
    func cancelRead() { token.cancel();queue.cancelAllOperations();generation = UUID();isLoading = false;metadata = nil;rows = [];status.stringValue = "Prüfung abgebrochen";status.textColor = .secondaryLabelColor;table.reloadData();updateControls() }
    private func updateControls() { previous.isEnabled = index > 0;next.isEnabled = index+1 < files.count;cancel.isEnabled = isLoading }
    func windowWillClose(_ notification:Notification) { closed = true;token.cancel();queue.cancelAllOperations();generation = UUID();metadata = nil;rows = [];isLoading = false }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? { guard rows.indices.contains(row) else { return nil };let text = label(column?.identifier.rawValue == "field" ? rows[row].0 : rows[row].1,size:12);text.isSelectable = true;text.toolTip = text.stringValue;return text }
}
