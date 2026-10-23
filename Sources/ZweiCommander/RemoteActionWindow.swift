import AppKit
import CommanderCore

final class RemoteActionController: NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate {
    var connection: RemoteConnection
    let kind: RemoteMutationKind,directory: String,selection: [RemoteEntry]
    let name = input(),status = label("Serverbestand wird geprüft …",size:12,color:.secondaryLabelColor)
    let table = operationTable([("path","Serverpfad",530),("kind","Art",130)])
    let start = ActionButton("Ausführen",symbol:"checkmark",action:{}),refresh = ActionButton("Neu prüfen",symbol:"arrow.clockwise",action:{})
    private(set) var plan: RemoteMutationPlan?
    private var token = CancellationToken(),generation = 0,pending: DispatchWorkItem?
    var onSubmit: ((RemoteMutationPlan)->Bool)?
    init(_ connection: RemoteConnection,kind: RemoteMutationKind,directory: String,entries: [RemoteEntry]) {
        self.connection = connection;self.kind = kind;self.directory = directory;selection = entries
        let title = kind == .delete ? "Auf Server endgültig löschen" : kind == .rename ? "Auf Server umbenennen" : "Serverordner erstellen"
        let window = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:760,height:520),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = title;window.minSize = NSSize(width:690,height:480);window.isReleasedWhenClosed = false
        super.init(window:window);window.delegate = self
        let root = OperationContent(frame:window.contentView!.bounds);root.autoresizingMask = [.width,.height];window.contentView = root
        let heading = label(title,size:22,weight:.semibold);heading.frame = NSRect(x:22,y:468,width:716,height:32);heading.autoresizingMask = [.width,.minYMargin];root.addSubview(heading)
        let location = label(connection.address(directory).absoluteString,size:12);location.frame = NSRect(x:22,y:436,width:716,height:24);location.autoresizingMask = [.width,.minYMargin];location.toolTip = location.stringValue;root.addSubview(location)
        name.stringValue = kind == .rename ? entries.first?.name ?? "" : "Neuer Ordner";name.delegate = self;name.placeholderString = "Neuer Name";name.setAccessibilityLabel("Neuer Servername")
        name.frame = NSRect(x:22,y:399,width:716,height:27);name.autoresizingMask = [.width,.minYMargin];name.isHidden = kind == .delete;root.addSubview(name)
        status.frame = NSRect(x:22,y:341,width:716,height:52);status.autoresizingMask = [.width,.minYMargin];status.maximumNumberOfLines = 3;status.lineBreakMode = .byWordWrapping;root.addSubview(status)
        table.dataSource = self;table.delegate = self;let scroll = operationScroll(table);scroll.frame = NSRect(x:22,y:116,width:716,height:213);scroll.autoresizingMask = [.width,.height];root.addSubview(scroll)
        let note = label(kind == .delete ? "Diese Auswahl wird dauerhaft auf dem Server gelöscht, einschließlich der aufgeführten Unterordner.\nKein Papierkorb und kein Rückgängig. Bei Abbruch bleiben bereits gelöschte Objekte gelöscht." : "Der Zielname muss frei sein. Bestand und Auswahl werden unmittelbar vor der Ausführung erneut geprüft.\nServeraktionen gelten für diese Sitzung und lassen sich nicht allgemein rückgängig machen.",size:11,color:kind == .delete ? .systemRed : .secondaryLabelColor)
        if kind == .rename && connection.kind != .sftp { note.stringValue += "\nFTP(S) kann das Ersetzen bei gleichzeitiger Anlage des Zielnamens nicht atomar verhindern." }
        note.frame = NSRect(x:22,y:60,width:716,height:48);note.maximumNumberOfLines = 3;note.autoresizingMask = [.width];root.addSubview(note)
        let cancel = ActionButton("Abbrechen",action:{ [weak self] in self?.close() });cancel.keyEquivalent = "\u{1b}";cancel.keyEquivalentModifierMask = []
        start.title = kind == .delete ? "Endgültig löschen" : kind == .rename ? "Umbenennen" : "Ordner erstellen"
        if kind != .delete { start.keyEquivalent = "\r";start.keyEquivalentModifierMask = [] }
        start.setHelp(start.title,kind == .delete ? "Nur den vollständig geprüften Serverbaum dauerhaft löschen." : "Geprüfte Namensänderung ausführen.",shortcut:kind == .delete ? "⌘↩" : "↩ / ⌘↩")
        refresh.setHelp("Neu prüfen","Den Serverbestand erneut erfassen.",shortcut:"⌘R")
        start.perform = { [weak self] in self?.submit() };refresh.perform = { [weak self] in self?.prepare() }
        let actions = row([refresh,cancel,start]);actions.frame = NSRect(x:20,y:15,width:718,height:32);root.addSubview(actions)
        window.workflowKeys = { [weak self] event in
            if WorkflowKeys.matches(event,"\r",.command) { self?.submit();return true }
            if WorkflowKeys.matches(event,"r",.command) { self?.prepare();return true }
            return false
        }
        window.initialFirstResponder = kind == .delete ? cancel : name;window.center();prepare()
    }
    required init?(coder:NSCoder) { fatalError() }
    func windowWillClose(_ notification:Notification) { generation += 1;pending?.cancel();token.cancel();connection.password = "";onSubmit = nil }
    func controlTextDidChange(_ notification:Notification) { prepare(debounce:true) }
    func prepare(debounce:Bool = false) {
        generation += 1;let version = generation;pending?.cancel();token.cancel();token = CancellationToken();let token = self.token
        plan = nil;start.isEnabled = false;table.reloadData();status.stringValue = "Serverbestand wird geprüft …";status.textColor = .secondaryLabelColor
        let connection = self.connection,kind = self.kind,directory = self.directory,entries = selection,name = self.name.stringValue
        let work = DispatchWorkItem { [weak self] in
            guard !token.isCancelled else { return }
            let result = Result { try RemoteMutation.prepare(RemoteService.transport(connection,token:token),kind:kind,directory:directory,entries:entries,newName:name,token:token) }
            DispatchQueue.main.async {
                guard let self,self.generation == version,!token.isCancelled else { return }
                switch result {
                case .success(let plan):self.plan = plan;self.table.reloadData();self.start.isEnabled = true;self.status.stringValue = kind == .delete ? "\(plan.files) Dateien und \(plan.folders) Ordner werden endgültig gelöscht.\nDie Vorschau hat noch keine Serverdateien geändert." : "Zielname frei · "+(plan.target ?? "")
                case .failure(let error):self.status.stringValue = error.localizedDescription;self.status.textColor = .systemOrange
                }
            }
        }
        pending = work;DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+(debounce ? 0.18 : 0),execute:work)
    }
    func submit() { guard let plan,start.isEnabled,onSubmit?(plan) == true else { return };close() }
    func numberOfRows(in tableView:NSTableView) -> Int { plan.map { $0.nodes.isEmpty ? 1 : $0.nodes.count } ?? 0 }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
        guard let plan else { return nil }
        let value: String
        if plan.nodes.isEmpty { value = column?.identifier.rawValue == "path" ? plan.target ?? "" : "Neuer Ordner" }
        else { let node = plan.nodes[row];value = column?.identifier.rawValue == "path" ? node.path+(plan.kind == .rename ? " → "+(plan.target ?? "") : "") : node.entry.isDirectory ? "Ordner" : "Datei" }
        let field = label(value);field.toolTip = value;return field
    }
}
