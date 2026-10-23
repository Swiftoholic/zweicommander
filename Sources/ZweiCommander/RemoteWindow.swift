import AppKit
import CommanderCore

final class RemoteWindow: NSWindowController,NSTableViewDelegate,NSTableViewDataSource,NSWindowDelegate,NSTextFieldDelegate {
    var connection: RemoteConnection
    let transfers: JobQueue
    let browse = JobQueue()
    let table = operationTable([("name","Name",440),("type","Art",150),("size","Größe",140)])
    let path = input("/"),local = input(),status = label("Bereit",size:12,color:.secondaryLabelColor)
    let downloadButton = ActionButton("Herunterladen",symbol:"arrow.down",action:{}),uploadButton = ActionButton("Hochladen …",symbol:"arrow.up.doc",action:{})
    private(set) var entries: [RemoteEntry] = []
    private(set) var listedPath: String?
    private var buttons: [NSControl] = []
    private var listing = false
    var onFilesChanged: (()->Void)?
    var onReview: ((RemoteTransferController)->Void)?
    var onQueue: (()->Void)?
    var onPlanSubmitted: ((UUID)->Void)?
    var uploadSelection: ((URL,@escaping ([URL])->Void)->Void)?
    init(_ connection: RemoteConnection,localDirectory: URL,path: String = "/",jobs: JobQueue) {
        self.connection = connection;transfers = jobs
        let window = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:920,height:590),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = connection.kind.rawValue+" · "+connection.user+"@"+connection.host;window.minSize = NSSize(width:840,height:480);window.isReleasedWhenClosed = false
        super.init(window:window);window.delegate = self
        let root = OperationContent(frame:window.contentView!.bounds);root.autoresizingMask = [.width,.height];window.contentView = root
        self.path.stringValue = path;self.path.frame = NSRect(x:116,y:536,width:780,height:28);self.path.autoresizingMask = [.width,.minYMargin];self.path.target = self;self.path.action = #selector(refresh);self.path.delegate = self
        self.path.toolTip = "Serverordner eingeben und mit Enter öffnen. ⌘L fokussiert den Pfad."
        local.stringValue = localDirectory.path;local.frame = NSRect(x:116,y:496,width:780,height:28);local.autoresizingMask = [.width,.minYMargin];local.toolTip = "Lokaler Zielordner für Downloads und Startordner für die Upload-Auswahl."
        for (title,y) in [("Serverordner",540),("Lokal",500)] { let field = label(title);field.frame = NSRect(x:18,y:y,width:94,height:20);field.autoresizingMask = [.minYMargin];root.addSubview(field) }
        downloadButton.perform = { [weak self] in self?.download() };uploadButton.perform = { [weak self] in self?.upload() }
        let up = ActionButton("Übergeordnet",symbol:"arrow.up",action:{ [weak self] in guard let self,let current = self.listedPath else { return };self.path.stringValue = current == "/" ? "/" : (current as NSString).deletingLastPathComponent;self.refresh() })
        let reload = ActionButton("Aktualisieren",symbol:"arrow.clockwise",action:{ [weak self] in self?.refresh() })
        let queue = ActionButton("Aufträge",symbol:"list.bullet.rectangle",action:{ [weak self] in self?.onQueue?() })
        let cancel = ActionButton("Liste abbrechen",symbol:"xmark.circle",action:{ [weak self] in self?.browse.cancel() })
        let actions = row([up,reload,downloadButton,uploadButton,queue,cancel]);actions.frame = NSRect(x:16,y:450,width:888,height:32);actions.autoresizingMask = [.width,.minYMargin];root.addSubview(actions)
        up.setHelp("Übergeordnet","Zum übergeordneten Serverordner wechseln.",shortcut:"⌘↑");reload.setHelp("Aktualisieren","Serverliste neu lesen.",shortcut:"⌘R")
        downloadButton.setHelp("Herunterladen","Ausgewählte Dateien und Ordner nach einer Vorschau herunterladen.",shortcut:"F5")
        uploadButton.setHelp("Hochladen","Lokale Dateien und ganze Ordner auswählen und vor dem Hochladen prüfen.",shortcut:"F6")
        queue.setHelp("Aufträge","Gemeinsame Warteschlange mit Pause, Abbruch und Reihenfolge öffnen.",shortcut:CommandHelp.shortcut("operations"))
        buttons = [up,reload,downloadButton,uploadButton,self.path,local]
        table.delegate = self;table.dataSource = self;table.allowsMultipleSelection = true;table.target = self;table.doubleAction = #selector(openDirectory)
        let scroll = operationScroll(table);scroll.frame = NSRect(x:0,y:70,width:920,height:368);scroll.autoresizingMask = [.width,.height];root.addSubview(scroll)
        status.frame = NSRect(x:18,y:10,width:884,height:50);status.autoresizingMask = [.width];status.maximumNumberOfLines = 3;status.lineBreakMode = .byWordWrapping
        [self.path,local,status].forEach(root.addSubview)
        browse.onStatus = { [weak self] text,_ in if self?.listing == true { self?.status.stringValue = text } }
        window.workflowKeys = { [weak self] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"l",.command) { window.makeFirstResponder(self.path);self.path.selectText(nil);return true }
            if WorkflowKeys.matches(event,"r",.command) { self.refresh();return true }
            if WorkflowKeys.matches(event,String(UnicodeScalar(NSUpArrowFunctionKey)!),.command) { up.perform?();return true }
            if WorkflowKeys.matches(event,String(UnicodeScalar(NSF5FunctionKey)!)) { self.download();return true }
            if WorkflowKeys.matches(event,String(UnicodeScalar(NSF6FunctionKey)!)) { self.upload();return true }
            return false
        }
        (table as? CommanderTableView)?.workflowKeys = window.workflowKeys
        window.initialFirstResponder = table;window.center();refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func updateActions() {
        buttons.forEach { $0.isEnabled = !listing }
        let current = listedPath != nil && path.stringValue == listedPath
        downloadButton.isEnabled = !listing && current && !table.selectedRowIndexes.isEmpty
        uploadButton.isEnabled = !listing && current
    }
    func controlTextDidChange(_ obj: Notification) { updateActions() }
    func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
    @objc func refresh() {
        guard !listing else { return }
        do {
            let location = try RemoteService.normalized(path.stringValue);path.stringValue = location;listing = true;updateActions();status.textColor = .secondaryLabelColor
            browse.submit("Serverliste lesen",work:{ [connection] token,_ in try RemoteService.list(connection,path:location,token:token) },completion:{ [weak self] result in
                guard let self else { return };self.listing = false
                switch result {
                case .success(let entries):self.entries = entries;self.listedPath = location;self.table.reloadData();self.status.stringValue = "\(entries.count) Objekte · Ordnerübertragungen mit Vorschau · F5 Download · F6 Upload"
                case .failure(let error):self.status.stringValue = error.localizedDescription;self.status.toolTip = error.localizedDescription;self.status.textColor = .systemOrange
                }
                self.updateActions()
            })
        } catch { status.stringValue = error.localizedDescription;status.textColor = .systemOrange;updateActions() }
    }
    @objc func openDirectory() {
        let index = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard !listing,path.stringValue == listedPath,entries.indices.contains(index),entries[index].isDirectory,!entries[index].isLink else { return }
        path.stringValue = RemoteService.child(listedPath!,entries[index].name);refresh()
    }
    func download() {
        guard downloadButton.isEnabled,let remote = listedPath else { return }
        let selected = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        review(direction:.download,path:remote,sources:[],entries:selected)
    }
    func upload() {
        guard uploadButton.isEnabled,let remote = listedPath,let window else { return }
        let initial = URL(fileURLWithPath:(local.stringValue as NSString).expandingTildeInPath)
        let receive: ([URL])->Void = { [weak self] urls in guard !urls.isEmpty else { return };self?.review(direction:.upload,path:remote,sources:urls,entries:[]) }
        if let uploadSelection { uploadSelection(initial,receive);return }
        let panel = NSOpenPanel();panel.directoryURL = initial;panel.canChooseDirectories = true;panel.canChooseFiles = true;panel.allowsMultipleSelection = true;panel.prompt = "Übertragung prüfen"
        panel.beginSheetModal(for:window) { response in if response == .OK { receive(panel.urls) } }
    }
    func review(direction: RemoteDirection,path: String,sources: [URL],entries: [RemoteEntry]) {
        let directory = URL(fileURLWithPath:(local.stringValue as NSString).expandingTildeInPath)
        let controller = RemoteTransferController(connection:connection,direction:direction,path:path,local:directory,sources:sources,entries:entries)
        controller.onSubmit = { [weak self,connection,transfers] plan,start in
            let id = transfers.submitReported((plan.direction == .upload ? "Upload" : "Download")+" · "+connection.host,start:start,items:plan.initialItems,notifyQueuedCancellation:true,body:{ token,reporter in
                let session = try RemoteService.transport(connection,token:token)
                return try RemotePlanner.execute(plan,using:session,token:token,progress:reporter.transfer)
            },completion:{ [weak self] result in
                self?.onFilesChanged?()
                if let self,self.window?.isVisible == true {
                    switch result { case .success(let value):self.status.stringValue = "\(value.files) Dateien übertragen · "+bytes(value.bytes);case .failure(let error):self.status.stringValue = error.localizedDescription;self.status.toolTip = error.localizedDescription;self.status.textColor = .systemOrange }
                    if plan.direction == .upload,self.listedPath == plan.remoteDirectory { self.refresh() }
                }
            })
            self?.onPlanSubmitted?(id);return true
        }
        onReview?(controller)
    }
    func windowWillClose(_ notification: Notification) { browse.cancel();connection.password = "" }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil };let entry = entries[row]
        let value = column?.identifier.rawValue == "name" ? (entry.isDirectory ? "▸ " : "")+entry.name : column?.identifier.rawValue == "type" ? entry.isLink ? "Verknüpfung" : entry.isDirectory ? "Ordner" : "Datei" : entry.isDirectory ? "—" : bytes(entry.size)
        return label(value)
    }
}
extension MainWindow {
    func remoteConnect() {
        if let existing = secondaryWindows.compactMap({ $0 as? RemoteConnectionController }).first(where: { $0.window?.isVisible == true }) { existing.showWindow(nil);return }
        let controller = RemoteConnectionController()
        controller.onConnect = { [weak self] connection,path in self?.showRemote(connection,path:path) }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
    @discardableResult func showRemote(_ connection: RemoteConnection,path: String) -> RemoteWindow {
        let controller = RemoteWindow(connection,localDirectory:active.currentURL,path:path,jobs:jobs)
        controller.onFilesChanged = { [weak self] in self?.refresh() };controller.onQueue = { [weak self] in self?.showOperations() }
        controller.onReview = { [weak self] review in self?.secondaryWindows.append(review);review.showWindow(nil) }
        secondaryWindows.append(controller);controller.showWindow(nil);return controller
    }
}
