import AppKit
import CommanderCore

final class RemoteTransferController: NSWindowController,NSWindowDelegate,NSTableViewDelegate,NSTableViewDataSource {
    var connection: RemoteConnection
    let direction: RemoteDirection,location: String,local: URL,sources: [URL],selection: [RemoteEntry]
    let table = operationTable([("name","Relativer Pfad",450),("kind","Art",120),("size","Größe",160)])
    let status = label("Dateibaum wird geprüft …",size:12,color:.secondaryLabelColor)
    let start = ActionButton("Starten",symbol:"play.fill",action:{}),queue = ActionButton("Vormerken",symbol:"text.badge.plus",action:{}),refresh = ActionButton("Neu prüfen",symbol:"arrow.clockwise",action:{})
    private(set) var plan: RemoteTransferPlan?
    private var preparation = CancellationToken(),generation = 0,preparing = false
    private var pending: Bool?
    var onSubmit: ((RemoteTransferPlan,Bool)->Bool)?
    init(connection: RemoteConnection,direction: RemoteDirection,path: String,local: URL,sources: [URL] = [],entries: [RemoteEntry] = []) {
        self.connection = connection;self.direction = direction;location = path;self.local = local;self.sources = sources;selection = entries
        let window = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:850,height:570),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = direction == .upload ? "Auf Server hochladen" : "Vom Server herunterladen";window.minSize = NSSize(width:760,height:510);window.isReleasedWhenClosed = false
        super.init(window:window);window.delegate = self
        let root = OperationContent(frame:window.contentView!.bounds);root.autoresizingMask = [.width,.height];window.contentView = root
        let heading = label(window.title,size:22,weight:.semibold);heading.frame = NSRect(x:22,y:518,width:800,height:32);heading.autoresizingMask = [.minYMargin,.width];root.addSubview(heading)
        let target = label((direction == .upload ? "Ziel: "+connection.host+":"+path : "Ziel: "+local.path),size:12)
        target.frame = NSRect(x:22,y:480,width:800,height:27);target.autoresizingMask = [.minYMargin,.width];target.toolTip = target.stringValue;root.addSubview(target)
        status.maximumNumberOfLines = 3;status.lineBreakMode = .byWordWrapping;status.frame = NSRect(x:22,y:409,width:806,height:62);status.autoresizingMask = [.minYMargin,.width];root.addSubview(status)
        table.delegate = self;table.dataSource = self
        let scroll = operationScroll(table);scroll.frame = NSRect(x:22,y:126,width:806,height:270);scroll.autoresizingMask = [.width,.height];root.addSubview(scroll)
        let note = label("Bestehende Zielnamen sperren den Auftrag. Verknüpfungen werden nicht verfolgt.\nBei Upload-Abbruch können neue Teilinhalte auf dem Server bleiben. Remote-Aufträge gelten für diese Sitzung.",size:11,color:.secondaryLabelColor)
        note.maximumNumberOfLines = 3;note.frame = NSRect(x:22,y:64,width:806,height:52);note.autoresizingMask = [.width];root.addSubview(note)
        let close = ActionButton("Schließen",action:{ [weak self] in self?.close() })
        let actions = row([refresh,close,queue,start]);actions.frame = NSRect(x:20,y:18,width:808,height:34);root.addSubview(actions)
        refresh.perform = { [weak self] in self?.prepare() };start.perform = { [weak self] in self?.submit(true) };queue.perform = { [weak self] in self?.submit(false) }
        WorkflowKeys.bind(queue,key:"\r",modifiers:[.command,.shift],title:"⌘⇧↩",detail:"Geprüften Remote-Auftrag in die gemeinsame Warteschlange aufnehmen.")
        start.keyEquivalent = "\r";start.keyEquivalentModifierMask = [];start.setHelp("Starten","Geprüften Remote-Dateiplan starten.",shortcut:"↩ / ⌘↩")
        refresh.setHelp("Neu prüfen","Lokale Dateien und Serverbestand erneut erfassen.",shortcut:"⌘R")
        close.keyEquivalent = "\u{1b}";close.keyEquivalentModifierMask = []
        window.workflowKeys = { [weak self] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"r",.command) { self.prepare();return true }
            if WorkflowKeys.matches(event,"\r",.command) { self.submit(true);return true }
            if WorkflowKeys.matches(event,"\r",[.command,.shift]) { self.submit(false);return true }
            return false
        }
        window.initialFirstResponder = table;window.center();prepare()
    }
    required init?(coder:NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { generation += 1;preparation.cancel();pending = nil;connection.password = "";onSubmit = nil }
    func prepare() {
        generation += 1;let version = generation;preparation.cancel();let token = CancellationToken();preparation = token;preparing = true;pending = nil
        plan = nil;start.isEnabled = false;queue.isEnabled = false;table.reloadData();status.textColor = .secondaryLabelColor;status.stringValue = "Dateibaum und vorhandene Ziele werden geprüft …"
        let connection = self.connection,direction = self.direction,local = self.local,path = location,sources = self.sources,selection = self.selection
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () throws -> RemoteTransferPlan in
                let session = try RemoteService.transport(connection,token:token)
                return direction == .upload ? try RemotePlanner.upload(session,sources:sources,to:path,token:token) : try RemotePlanner.download(session,entries:selection,path:path,to:local,token:token)
            }
            DispatchQueue.main.async {
                guard let self,self.generation == version,!token.isCancelled else { return };self.preparing = false
                switch result {
                case .success(let plan):self.plan = plan;self.table.reloadData();self.start.isEnabled = true;self.queue.isEnabled = true;self.status.stringValue = "\(plan.rootNames.count) Auswahlobjekte · \(plan.files) Dateien · \(plan.nodes.count-plan.files) Ordner · "+bytes(plan.bytes)+"\nKeine belegten Zielnamen. Vor dem Ausführen wird der Bestand nochmals geprüft."
                    if let pending = self.pending { self.pending = nil;self.submit(pending) }
                case .failure(let error):self.pending = nil;self.status.stringValue = error.localizedDescription;self.status.toolTip = error.localizedDescription;self.status.textColor = .systemOrange
                }
            }
        }
    }
    func submit(_ now: Bool) {
        guard let plan else { if preparing { pending = now };return }
        guard onSubmit?(plan,now) == true else { return };close()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { plan?.nodes.count ?? 0 }
    func tableView(_ tableView: NSTableView,viewFor column: NSTableColumn?,row: Int) -> NSView? {
        guard let plan,plan.nodes.indices.contains(row) else { return nil };let node = plan.nodes[row]
        let value = column?.identifier.rawValue == "name" ? node.relative : column?.identifier.rawValue == "kind" ? (node.entry.isDirectory ? "Ordner" : "Datei") : node.entry.isDirectory ? "—" : bytes(node.entry.size)
        let field = label(value);field.toolTip = node.relative;return field
    }
}
