import AppKit
import QuickLookUI
import CommanderCore

final class MainContent: NSView, NSSplitViewDelegate {
    let toolbar = NSStackView(), locations = NSStackView(), functionBar = NSStackView()
    let split = NSSplitView()
    let status = label("Bereit",size:11,color:.secondaryLabelColor)
    let progress = NSProgressIndicator()
    let cancel = ActionButton("Abbrechen",symbol:"xmark.circle",action:{})
    let pause = ActionButton("Pause",symbol:"pause.fill",action:{})
    let queueButton = ActionButton("Aufträge",symbol:"list.bullet.rectangle",action:{})
    let quick = QLPreviewView(frame:.zero,style:.normal)!
    var firstLayout = true
    var quickVisible = false { didSet { quick.isHidden = !quickVisible; needsLayout = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        toolbar.orientation = .horizontal; toolbar.spacing = 10; toolbar.alignment = .centerY
        locations.orientation = .horizontal; locations.spacing = 10
        functionBar.orientation = .horizontal; functionBar.distribution = .fillEqually; functionBar.spacing = 4
        split.isVertical = true; split.dividerStyle = .thin; split.delegate = self
        progress.style = .bar; progress.controlSize = .small; progress.isDisplayedWhenStopped = false;progress.minValue = 0;progress.maxValue = 1
        quick.isHidden = true; cancel.isHidden = true;pause.isHidden = true
        [toolbar,locations,split,functionBar,status,progress,cancel,pause,queueButton,quick].forEach { addSubview($0) }
    }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
    }
    override func layout() {
        super.layout(); let w = bounds.width,h = bounds.height
        toolbar.frame = NSRect(x:14,y:h-44,width:w-28,height:34)
        locations.frame = NSRect(x:14,y:h-80,width:w-28,height:28)
        let q: CGFloat = quickVisible ? min(330,w*0.28) : 0
        split.frame = NSRect(x:0,y:71,width:w-q,height:max(1,h-158))
        if firstLayout && w > 0 && h > 0 && split.arrangedSubviews.count == 2 { firstLayout = false; split.setPosition((split.isVertical ? split.bounds.width : split.bounds.height)/2,ofDividerAt:0) }
        quick.frame = NSRect(x:w-q,y:71,width:q,height:max(1,h-158))
        functionBar.frame = NSRect(x:10,y:34,width:w-20,height:30)
        progress.frame = NSRect(x:12,y:10,width:115,height:12)
        status.frame = NSRect(x:140,y:7,width:max(20,w-510),height:18)
        pause.frame = NSRect(x:w-365,y:3,width:110,height:26)
        cancel.frame = NSRect(x:w-255,y:3,width:120,height:26)
        queueButton.frame = NSRect(x:w-135,y:3,width:125,height:26)
    }
    func splitView(_ splitView:NSSplitView,canCollapseSubview subview:NSView)->Bool { false }
    func splitView(_ splitView:NSSplitView,constrainSplitPosition proposedPosition:CGFloat,ofSubviewAt dividerIndex:Int)->CGFloat {
        let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let minimum:CGFloat = splitView.isVertical ? min(280,length*0.35) : min(160,length*0.35)
        return max(minimum,min(proposedPosition,length-minimum))
    }
}

final class MainWindow: NSWindowController, NSWindowDelegate {
    let content = MainContent(frame:NSRect(x:0,y:0,width:1280,height:780))
    let left: PaneView
    let right: PaneView
    var active: PaneView
    var other: PaneView { active === left ? right : left }
    let jobs: JobQueue
    var secondaryWindows: [NSWindowController] = []
    var undoSteps: [UndoStep] = []
    var renameUndo: [RenameItem]?
    var cutURLs: [URL] = []
    var cutPasteboardChange = -1
    var linked = false
    let locationsMenu = NSPopUpButton(frame:.zero,pullsDown:false)
    let favoriteMenu = NSPopUpButton(frame:.zero,pullsDown:false)
    let cache: URL
    var onRebuildMenus: (() -> Void)?
    var operationWindow: OperationQueueController?
    var programLauncher: ((ProgramLaunchRequest) -> Void)?
    var keySearchController: SearchController? { secondaryWindows.compactMap { $0 as? SearchController }.first { $0.window === NSApp.keyWindow } }
    var pendingWork:Int { secondaryWindows.compactMap { $0 as? SearchController }.filter(\.isSearching).count + jobs.pending + secondaryWindows.compactMap { $0 as? RemoteWindow }.reduce(0) { $0+$1.jobs.pending } }
    var canTerminate: Bool {
        secondaryWindows.compactMap { $0 as? SearchController }.allSatisfy { !$0.isSearching } && jobs.canClose && secondaryWindows.compactMap { $0 as? RemoteWindow }.allSatisfy { $0.jobs.pending == 0 } &&
            !jobs.scheduler.snapshots.filter(\.isPending).contains { snapshot in jobs.journal?.entry(snapshot.id)?.intent.sources.contains { FileSystem.isInside($0,cache) } == true }
    }

    init(startLeft: URL? = nil,startRight: URL? = nil) {
        jobs = JobQueue.mainQueue()
        let home = FileManager.default.homeDirectoryForCurrentUser
        left = PaneView(url:startLeft ?? home,savedTabs:startLeft == nil ? Preferences.state.left : [])
        right = PaneView(url:startRight ?? home.appendingPathComponent("Downloads"),savedTabs:startRight == nil ? Preferences.state.right : [])
        active = left
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("ZweiCommander-"+UUID().uuidString)
        try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title = "ZweiCommander"; w.subtitle = "Zwei Ansichten. Ein Arbeitsbereich."; w.minSize = NSSize(width:900,height:520); w.isReleasedWhenClosed = false
        super.init(window:w); w.delegate = self; w.contentView = content
        content.split.addArrangedSubview(left); content.split.addArrangedSubview(right)
        content.split.isVertical = Preferences.state.vertical
        content.firstLayout = true; content.needsLayout = true
        for pane in [left,right] {
            pane.showHidden = Preferences.state.showHidden
            if let profile = Preferences.state.importedProfile { pane.configure(profile:profile,isLeft:pane === left) }
            pane.initializeView()
            pane.onActivate = { [weak self] p in self?.setActive(p) }
            pane.onSwitch = { [weak self] in self?.other.focus() }
            pane.onPreview = { [weak self] urls in self?.preview(urls) }
            pane.onOpenArchive = { [weak self] url,p in self?.openArchive(url,in:p) }
            pane.onDrop = { [weak self] urls,dest in self?.transfer(urls,to:dest,kind:.copy) }
            pane.onCollectionDrop = { [weak pane] urls in pane?.addToCollection(urls) }
            pane.onCommand = { [weak self] cmd in self?.command(cmd) }
            pane.onState = { [weak self] in self?.saveState() }
            pane.onSelection = { [weak self, weak pane] urls in
                guard let self, pane === self.active, self.content.quickVisible else { return }
                self.content.quick.previewItem = urls.first.map { $0 as NSURL }
            }
            pane.onNavigate = { [weak self] p,old,new in self?.followNavigation(p,from:old,to:new) }
            pane.refresh()
        }
        buildToolbar(); refreshLocations(); setActive(left)
        jobs.onStatus = { [weak self] text,done in
            guard let self else { return }; self.content.status.stringValue = text
            let active = self.jobs.active
            self.content.cancel.isHidden = active == nil;self.content.pause.isHidden = active == nil
            self.content.pause.title = active.map { [.paused,.pausing].contains($0.state) ? "Fortsetzen" : "Pause" } ?? "Pause"
            self.content.pause.image = NSImage(systemSymbolName:self.content.pause.title == "Fortsetzen" ? "play.fill" : "pause.fill",accessibilityDescription:self.content.pause.title)
            self.content.queueButton.title = "Aufträge (\(self.jobs.pending+self.jobs.scheduler.snapshots.filter { $0.state == .review }.count))"
            self.content.progress.isHidden = self.jobs.pending == 0
            self.content.progress.isIndeterminate = done == nil
            if let done { self.content.progress.stopAnimation(nil);self.content.progress.doubleValue = done }
            else if active?.state != .paused { self.content.progress.startAnimation(nil) }
        }
        content.cancel.perform = { [weak self] in self?.jobs.cancel() }
        content.pause.perform = { [weak self] in self?.jobs.togglePause() }
        content.queueButton.perform = { [weak self] in self?.showOperations() }
        jobs.publish()
        w.center(); if !Preferences.testMode { w.setFrameAutosaveName("ZweiCommander.main") }
        NotificationCenter.default.addObserver(self,selector:#selector(volumesChanged),name:NSWorkspace.didMountNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(secondaryWindowClosed(_:)),name:NSWindow.willCloseNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(volumesChanged),name:NSWorkspace.didMountNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(volumesChanged),name:NSWorkspace.didUnmountNotification,object:nil)
        applyTheme()
    }
    required init?(coder:NSCoder) { fatalError() }
    func buildToolbar() {
        let brand = label("ZWEI",size:19,color:.controlAccentColor,weight:.heavy)
        let subtitle = label("COMMANDER",size:10,color:.secondaryLabelColor,weight:.semibold)
        let brandGroup = row([brand,subtitle],spacing:5)
        brandGroup.widthAnchor.constraint(equalToConstant:125).isActive = true
        brandGroup.heightAnchor.constraint(equalToConstant:26).isActive = true
        content.toolbar.addArrangedSubview(brandGroup)
        for (title,symbol,cmd) in [("Suchen","magnifyingglass","search"),("Vergleichen","arrow.left.arrow.right","compare"),("Umbenennen","textformat.abc","batchRename"),("Packen","archivebox","pack"),("Vorschau","sidebar.right","quickView"),("Aktualisieren","arrow.clockwise","refresh")] {
            content.toolbar.addArrangedSubview(ActionButton(title,symbol:symbol,action:{ [weak self] in self?.command(cmd) }))
        }
        locationsMenu.target = self; locationsMenu.action = #selector(locationChosen)
        favoriteMenu.target = self; favoriteMenu.action = #selector(favoriteChosen)
        locationsMenu.widthAnchor.constraint(equalToConstant:200).isActive = true
        favoriteMenu.widthAnchor.constraint(equalToConstant:210).isActive = true
        content.locations.addArrangedSubview(label("Orte",size:11,color:.secondaryLabelColor))
        content.locations.addArrangedSubview(locationsMenu)
        content.locations.addArrangedSubview(favoriteMenu)
        content.locations.addArrangedSubview(ActionButton("Favorit",symbol:"star",action:{ [weak self] in self?.command("favorite") }))
        content.locations.addArrangedSubview(ActionButton("Ansichten tauschen",symbol:"arrow.triangle.swap",action:{ [weak self] in self?.command("swap") }))
        for (title,cmd) in [("F3 Ansehen","preview"),("F4 Bearbeiten","edit"),("F5 Kopieren","copy"),("F6 Verschieben","move"),("F7 Neuer Ordner","newFolder"),("F8 Papierkorb","trash")] {
            let b = ActionButton(title,action:{ [weak self] in self?.command(cmd) }); b.identifier = .init(cmd); b.font = .systemFont(ofSize:11); content.functionBar.addArrangedSubview(b)
        }
        updateFunctionLabels()
    }
    func updateFunctionLabels() {
        let values:[String:(String,String)] = ["preview":("F3","Ansehen"),"edit":("F4","Bearbeiten"),"copy":("F5","Kopieren"),"move":("F6","Verschieben"),"newFolder":("F7","Neuer Ordner"),"trash":("F8","Papierkorb")]
        for case let button as NSButton in content.functionBar.arrangedSubviews {
            guard let id = button.identifier?.rawValue,let value = values[id] else { continue }
            var key = (Preferences.state.shortcuts[id] ?? value.0).lowercased()
            if key == "space" { key = "Leertaste" }
            for (word,symbol) in [("cmd+","⌘"),("shift+","⇧"),("option+","⌥"),("alt+","⌥"),("control+","⌃"),("ctrl+","⌃")] { key = key.replacingOccurrences(of:word,with:symbol) }
            button.title = key.uppercased()+" "+value.1
        }
    }
    @objc func volumesChanged() { refreshLocations() }
    @objc func secondaryWindowClosed(_ notification:Notification) {
        guard let window = notification.object as? NSWindow else { return }
        secondaryWindows.removeAll { $0.window === window }
    }
    func refreshLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        locationsMenu.removeAllItems()
        var places:[(String,URL)] = [("Benutzerordner",home),("Schreibtisch",home.appendingPathComponent("Desktop")),("Dokumente",home.appendingPathComponent("Documents")),("Downloads",home.appendingPathComponent("Downloads")),("Programme",URL(fileURLWithPath:"/Applications")),("Macintosh HD",URL(fileURLWithPath:"/"))]
        if let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:[.volumeIsBrowsableKey],options:[.skipHiddenVolumes]) {
            places += volumes.filter { $0.path != "/" }.map { ($0.lastPathComponent,$0) }
        }
        for (name,url) in places { locationsMenu.addItem(withTitle:name); locationsMenu.lastItem?.representedObject = url }
        favoriteMenu.removeAllItems(); favoriteMenu.addItem(withTitle:"Favoriten")
        do {
            for item in try Preferences.workspaceLibrary().favorites {
                favoriteMenu.addItem(withTitle:item.title);favoriteMenu.lastItem?.representedObject = item.id.uuidString
                favoriteMenu.lastItem?.toolTip = item.path+(item.opensSelection ? " · Ausgewählte Dateien öffnen" : "")
                favoriteMenu.lastItem?.image = NSImage(systemSymbolName:item.kind == .folder ? "folder" : "app",accessibilityDescription:nil)
            }
        } catch { favoriteMenu.addItem(withTitle:"Favoriten nicht lesbar");favoriteMenu.lastItem?.isEnabled = false;favoriteMenu.lastItem?.toolTip = error.localizedDescription }
        favoriteMenu.menu?.addItem(.separator());favoriteMenu.addItem(withTitle:"Favoriten bearbeiten …");favoriteMenu.lastItem?.representedObject = "editFavorites"
    }
    @objc func locationChosen() { if let url = locationsMenu.selectedItem?.representedObject as? URL { active.navigate(url) } }
    @objc func favoriteChosen() {
        defer { favoriteMenu.selectItem(at:0) }
        guard let value = favoriteMenu.selectedItem?.representedObject as? String else { return }
        if value == "editFavorites" { showFavorites() }
        else if let id = UUID(uuidString:value) { do { try openFavorite(id) } catch { showFailure(error) } }
    }
    func setActive(_ pane:PaneView) { active = pane; left.isActive = pane === left; right.isActive = pane === right; window?.subtitle = (pane === left ? "Links" : "Rechts")+" · "+pane.currentURL.path }
    func saveState() { Preferences.state.left = left.savedTabs; Preferences.state.right = right.savedTabs; Preferences.state.vertical = content.split.isVertical; Preferences.save() }
    func applyTheme() { NSApp.appearance = Preferences.state.theme == 1 ? NSAppearance(named:.aqua) : Preferences.state.theme == 2 ? NSAppearance(named:.darkAqua) : nil }
    func followNavigation(_ pane:PaneView,from old:URL,to new:URL) {
        saveState(); guard linked else { return }
        let target = pane === left ? right : left
        let candidate:URL
        if new.deletingLastPathComponent() == old { candidate = target.currentURL.appendingPathComponent(new.lastPathComponent) }
        else if old.deletingLastPathComponent() == new { candidate = target.currentURL.deletingLastPathComponent() }
        else { return }
        if FileSystem.isDirectory(candidate) { target.navigate(candidate,linked:true); pane.focus() }
    }
    func refresh() { left.refresh(); right.refresh(); refreshLocations() }
    func showText(_ title:String,_ text:String) { let w = TextWindow(title:title,text:text); secondaryWindows.append(w); w.showWindow(nil) }
    func preview(_ urls:[URL]) { guard let url = urls.first else { NSSound.beep(); return }; let w = PreviewController(url); secondaryWindows.append(w); w.showWindow(nil) }
    func requireSelection() -> [URL]? { let urls = active.selectedURLs; if urls.isEmpty { NSSound.beep(); return nil }; return urls }
    func ensureWritable(_ pane:PaneView) -> Bool {
        if pane.readOnly || FileSystem.isInside(pane.currentURL,cache) || pane.selectedURLs.contains(where:{FileSystem.isInside($0,cache)}) {
            showFailure(CommanderError.message("Die Archivansicht ist schreibgeschützt. Dateien zuerst in einen normalen Ordner kopieren.")); return false
        }
        return true
    }
    func complete(_ result:Result<OperationReport,Error>) {
        switch result {
        case .failure(let e): showFailure(e)
        case .success(let report):
            undoSteps = report.undo; renameUndo = nil
            let summary = "\(report.completed.count) abgeschlossen · \(report.skipped.count) übersprungen · \(report.errors.count) Fehler"
            content.status.stringValue = summary
            jobs.log.append(summary + (report.errors.isEmpty ? "" : "\n"+report.errors.joined(separator:"\n")))
            if !report.errors.isEmpty { showText("Vorgangsbericht",summary+"\n\n"+report.errors.joined(separator:"\n")) }
        }
        refresh()
    }
    func transfer(_ urls:[URL],to destination:URL,kind:TransferKind) {
        let cache = self.cache
        let controller = TransferSetupController(sources:urls,destination:destination,kind:kind,validateDestination:{ url in
            guard !FileSystem.isInside(url,cache) else { throw CommanderError.message("Temporäre Archivordner sind schreibgeschützt.") }
        })
        controller.onSubmit = { [weak self] plan,start in self?.enqueueTransfer(plan,start:start) ?? false }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
    @discardableResult func enqueueTransfer(_ plan: TransferPlan,start: Bool,replacing oldID: UUID? = nil) -> Bool {
        do {
            let id = try jobs.submitTransfer(plan,start:start,replacing:oldID,completion:{ [weak self] in self?.complete($0) })
            showOperations(select:id);return true
        } catch { showFailure(error);return false }
    }
    @discardableResult func reviewTransfer(_ id: UUID) -> TransferSetupController? {
        guard let entry = jobs.journal?.entry(id),jobs.scheduler.snapshots.first(where: { $0.id == id })?.isPending == false else { return nil }
        let sources = entry.intent.sources.filter { FileSystem.exists($0) },missing = entry.intent.sources.count-sources.count
        guard !sources.isEmpty else {
            _ = dialog("Quellen nicht verfügbar",message:"Keine der gespeicherten Quellen ist vorhanden. Bitte Datenträger verbinden und Quellen sowie Ziel prüfen. Fehlende Quellen gelten nicht automatisch als erfolgreich verschoben.",buttons:["OK"]);return nil
        }
        let cache = self.cache
        let controller = TransferSetupController(sources:sources,destination:entry.intent.destination,kind:entry.intent.kind,validateDestination:{ url in
            guard !FileSystem.isInside(url,cache) else { throw CommanderError.message("Temporäre Archivordner sind schreibgeschützt.") }
        })
        let notice = missing > 0 ? "\(missing) gespeicherte Quelle(n) fehlen und werden ausgelassen. Vorhandene Ziele und den neuen Plan prüfen." : "Neuer Dateiplan: vorhandene Ziele prüfen und Einzelentscheidungen erneut treffen. Kein Fortsetzen an einer Byteposition."
        controller.apply(entry.intent,notice:notice)
        controller.onSubmit = { [weak self] plan,start in self?.enqueueTransfer(plan,start:start,replacing:id) ?? false }
        secondaryWindows.append(controller);controller.showWindow(nil);return controller
    }
    func showOperations(select id: UUID? = nil) {
        if operationWindow == nil {
            operationWindow = OperationQueueController(jobs)
            operationWindow?.onReview = { [weak self] id in self?.reviewTransfer(id) }
        }
        if let id { operationWindow?.select(id) }
        operationWindow?.showWindow(nil)
    }
    func openArchive(_ url:URL,in pane:PaneView) {
        let dest = cache.appendingPathComponent(UUID().uuidString)
        jobs.submit("Archiv öffnen",work:{ token,progress in try ArchiveService.extract(url,to:dest,token:token,progress:progress); return dest },completion:{ [weak pane] result in
            switch result { case .success(let root): pane?.showArchive(root:root,original:url); case .failure(let e): showFailure(e) }
        })
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        if !canTerminate { _ = dialog("Dateiaufträge sind offen",message:"Laufende Vorgänge einschließlich Suchen und Aufträge aus temporären Archivansichten erst abschließen oder entfernen. Gespeicherte wartende Kopier- und Verschiebeaufträge bleiben beim Beenden erhalten.",buttons:["OK"]); return false }
        saveState(); return true
    }
    func windowWillClose(_ notification:Notification) { saveState() }
}
