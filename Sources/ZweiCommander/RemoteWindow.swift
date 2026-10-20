import AppKit
import CommanderCore

final class RemoteWindow:NSWindowController,NSTableViewDelegate,NSTableViewDataSource,NSWindowDelegate {
    let connection:RemoteConnection
    let table = CommanderTableView(),scroll = NSScrollView(),path = input("/"),local = input(),status = label("Bereit",size:11,color:.secondaryLabelColor)
    let jobs = JobQueue()
    var entries:[RemoteEntry] = []
    var listedPath = "/"
    var onFilesChanged:(()->Void)?
    var buttons:[NSButton] = []
    init(_ connection:RemoteConnection,localDirectory:URL) {
        self.connection = connection
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:550),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = connection.kind.rawValue+" · "+connection.user+"@"+connection.host; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:720,height:400)
        super.init(window:window); window.delegate = self
        let root = NSView(frame:window.contentView!.bounds); window.contentView = root
        path.frame = NSRect(x:100,y:508,width:700,height:26); path.autoresizingMask = [.width,.minYMargin]; path.target = self; path.action = #selector(refresh)
        let remoteLabel = label("Serverordner"); remoteLabel.frame = NSRect(x:16,y:512,width:80,height:20); remoteLabel.autoresizingMask = [.minYMargin]
        local.stringValue = localDirectory.path; local.frame = NSRect(x:100,y:472,width:700,height:26); local.autoresizingMask = [.width,.minYMargin]
        let localLabel = label("Lokal"); localLabel.frame = NSRect(x:16,y:476,width:80,height:20); localLabel.autoresizingMask = [.minYMargin]
        let actions = row([
            ActionButton("Übergeordnet",symbol:"arrow.up",action:{ [weak self] in guard let self else { return }; self.path.stringValue = (self.listedPath as NSString).deletingLastPathComponent; if self.path.stringValue.isEmpty { self.path.stringValue = "/" }; self.refresh() }),
            ActionButton("Aktualisieren",symbol:"arrow.clockwise",action:{ [weak self] in self?.refresh() }),
            ActionButton("Herunterladen",symbol:"arrow.down",action:{ [weak self] in self?.download() }),
            ActionButton("Hochladen …",symbol:"arrow.up.doc",action:{ [weak self] in self?.upload() }),
            ActionButton("Abbrechen",symbol:"xmark.circle",action:{ [weak self] in self?.jobs.cancel() })
        ])
        actions.frame = NSRect(x:16,y:432,width:788,height:30); actions.autoresizingMask = [.width,.minYMargin]
        buttons = actions.arrangedSubviews.compactMap {$0 as? NSButton}; buttons.removeLast()
        for (id,title,width) in [("name","Name",CGFloat(450)),("type","Art",160),("size","Größe",140)] { let c = NSTableColumn(identifier:.init(id)); c.title = title; c.width = width; table.addTableColumn(c) }
        table.delegate = self; table.dataSource = self; table.rowHeight = 25; table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = true; table.target = self; table.doubleAction = #selector(openDirectory)
        scroll.frame = NSRect(x:0,y:36,width:820,height:384); scroll.autoresizingMask = [.width,.height]; scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        status.frame = NSRect(x:16,y:10,width:788,height:20); status.autoresizingMask = [.width]
        [remoteLabel,path,localLabel,local,actions,scroll,status].forEach { root.addSubview($0) }
        jobs.onStatus = { [weak self] text,_ in self?.status.stringValue = text }
        window.center(); refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    func busy(_ value:Bool) { buttons.forEach { $0.isEnabled = !value }; path.isEnabled = !value; local.isEnabled = !value }
    @objc func refresh() {
        guard jobs.pending == 0 else { return }
        let location = path.stringValue; busy(true)
        jobs.submit("Serverliste lesen",work:{ [connection] token,_ in try RemoteService.list(connection,path:location,token:token) },completion:{ [weak self] result in
            guard let self else { return }; self.busy(false)
            switch result { case .success(let entries): self.entries = entries; self.listedPath = location; self.table.reloadData(); self.status.stringValue = "\(entries.count) Objekte · \(self.connection.kind.rawValue)"
            case .failure(let e): self.path.stringValue = self.listedPath; showFailure(CommanderError.message(e.localizedDescription+(self.connection.kind == .sftp ? "\n\nSFTP benötigt einen SSH-Schlüssel/ssh-agent und einen bereits geprüften Hostschlüssel. Die Ersteinrichtung ist über „SFTP im Terminal“ möglich." : ""))) }
        })
    }
    @objc func openDirectory() {
        guard jobs.pending == 0,table.clickedRow >= 0,entries.indices.contains(table.clickedRow) else { return }
        let entry = entries[table.clickedRow]; if entry.isDirectory { path.stringValue = RemoteService.child(listedPath,entry.name); refresh() }
    }
    func download() {
        let selected = table.selectedRowIndexes.compactMap { entries.indices.contains($0) ? entries[$0] : nil }
        guard !selected.isEmpty else { return }
        let directory = URL(fileURLWithPath:(local.stringValue as NSString).expandingTildeInPath),remote = listedPath
        guard FileSystem.isDirectory(directory) else { showFailure(CommanderError.message("Lokalen Zielordner prüfen.")); return }
        guard dialog("Dateien herunterladen",message:"\(selected.count) Dateien nach \(directory.path). Bestehende Dateien werden nicht überschrieben.",buttons:["Herunterladen","Abbrechen"]) == 0 else { return }
        busy(true)
        jobs.submit("Download",work:{ [connection] token,progress in var count = 0; for entry in selected { try token.check(); progress(entry.name); _ = try RemoteService.download(connection,path:remote,entry:entry,to:directory,token:token); count += 1 }; return count },completion:{ [weak self] result in
            self?.busy(false); self?.onFilesChanged?(); switch result { case .success(let count): self?.status.stringValue = "\(count) Dateien heruntergeladen"; case .failure(let e): showFailure(e) }
        })
    }
    func upload() {
        let panel = NSOpenPanel(); panel.directoryURL = URL(fileURLWithPath:local.stringValue); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }; let urls = panel.urls,remote = listedPath
        guard dialog("Dateien auf Server hochladen?",message:"\(urls.count) Dateien nach \(connection.host):\(remote). Bestehende Namen werden abgewiesen. Bei Verbindungsabbruch können unvollständige Dateien auf dem Server verbleiben.",buttons:["Hochladen","Abbrechen"]) == 0 else { return }
        busy(true)
        jobs.submit("Upload",work:{ [connection] token,progress in for url in urls { try token.check(); progress(url.lastPathComponent); try RemoteService.upload(connection,source:url,path:remote,token:token) } },completion:{ [weak self] result in
            self?.busy(false); if case .failure(let e) = result { showFailure(e) }; self?.refresh()
        })
    }
    func numberOfRows(in tableView:NSTableView)->Int { entries.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let entry = entries[row]
        switch tableColumn?.identifier.rawValue { case "name": return label((entry.isDirectory ? "▸ " : "")+entry.name); case "type":return label(entry.isDirectory ? "Ordner" : entry.isLink ? "Verknüpfung" : "Datei",color:.secondaryLabelColor); default:return label(entry.isDirectory ? "—" : bytes(entry.size),color:.secondaryLabelColor) }
    }
    func windowShouldClose(_ sender:NSWindow)->Bool { if jobs.pending > 0 { _ = dialog("Transfer läuft",message:"Bitte zuerst den Transfer abschließen oder abbrechen.",buttons:["OK"]); return false }; return true }
}

extension MainWindow {
    func remoteConnect() {
        let kind = NSPopUpButton(); kind.addItems(withTitles:RemoteProtocol.allCases.map(\.rawValue))
        let host = input(),user = input(NSUserName()),password = NSSecureTextField(string:""),port = input("",placeholder:"SFTP: 22 · FTP/FTPS: 21")
        guard dialog("FTP / SFTP verbinden",message:"SFTP verwendet deinen SSH-Schlüssel bzw. ssh-agent und bekannte Hostschlüssel. FTPS prüft das TLS-Zertifikat. Anmeldedaten werden nur für dieses Fenster im Speicher gehalten.",accessory:form([("Protokoll",kind),("Server",host),("Benutzer",user),("FTP-Passwort",password),("Port",port)]),buttons:["Verbinden","Abbrechen"]) == 0 else { return }
        let selected = RemoteProtocol.allCases[kind.indexOfSelectedItem]
        do {
            let p = port.stringValue.isEmpty ? (selected == .sftp ? 22 : 21) : Int(port.stringValue) ?? 0
            let connection = try RemoteConnection(kind:selected,host:host.stringValue,user:user.stringValue,password:password.stringValue,port:p)
            let window = RemoteWindow(connection,localDirectory:active.currentURL); window.onFilesChanged = { [weak self] in self?.refresh() }; secondaryWindows.append(window); window.showWindow(nil)
        } catch { showFailure(error) }
    }
}
