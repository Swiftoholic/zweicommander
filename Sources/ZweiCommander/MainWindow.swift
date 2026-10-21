import AppKit
import QuickLookUI
import CommanderCore

final class MainContent: CommanderSurface, NSSplitViewDelegate {
    let toolbar = NSStackView(), functionBar = NSStackView(), utilityBar = NSStackView()
    let toolbarScroll = NSScrollView()
    let toolbarMore = ActionButton("",symbol:"ellipsis.circle",action:{})
    let split = CommanderSplitView(), rail = SplitActionRail(frame:.zero)
    let commandMode = NSPopUpButton(), commandField = input(placeholder:"Ordnerpfad")
    let commandGo = ActionButton("",symbol:"return",action:{}), terminal = ActionButton("",symbol:"terminal",action:{})
    let status = label("Bereit",size:11,color:.secondaryLabelColor)
    let progress = NSProgressIndicator()
    let cancel = ActionButton("Abbrechen",symbol:"xmark.circle",action:{})
    let pause = ActionButton("Pause",symbol:"pause.fill",action:{})
    let queueButton = ActionButton("Aufträge",symbol:"list.bullet.rectangle",action:{})
    let quick = QLPreviewView(frame:.zero,style:.normal)!
    var firstLayout = true
    var quickVisible = false { didSet { quick.isHidden = !quickVisible;needsLayout = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        toolbar.orientation = .horizontal;toolbar.spacing = 3;toolbar.alignment = .centerY;toolbar.detachesHiddenViews = true
        utilityBar.orientation = .horizontal;utilityBar.spacing = 5;utilityBar.alignment = .centerY
        toolbarScroll.drawsBackground = false;toolbarScroll.documentView = toolbar;toolbarScroll.hasHorizontalScroller = false
        toolbarMore.flat = true;toolbarMore.setHelp("Weitere Werkzeugleistenbefehle","Befehle öffnen, die nicht mehr ins Fenster passen, oder die Werkzeugleiste anpassen.")
        functionBar.orientation = .horizontal;functionBar.distribution = .fillEqually;functionBar.spacing = 1
        split.isVertical = true;split.dividerStyle = .thin;split.delegate = self
        commandMode.addItems(withTitles:["Pfad","Befehl"]);commandMode.controlSize = .small
        commandMode.toolTip = "Pfad öffnet einen Ordner. Befehl führt zsh im aktiven Ordner aus."
        commandField.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        commandGo.flat = true;commandGo.setHelp("Eingabe ausführen","Die Eingabe im links gewählten Modus ausführen.")
        terminal.flat = true;CommandHelp.apply(terminal,id:"terminal")
        progress.style = .bar;progress.controlSize = .small;progress.isDisplayedWhenStopped = false;progress.minValue = 0;progress.maxValue = 1
        quick.isHidden = true;cancel.isHidden = true;pause.isHidden = true
        [pause,cancel,queueButton].forEach { $0.flat = true;$0.font = .systemFont(ofSize:11) }
        pause.setHelp("Pause","Den laufenden Dateivorgang pausieren oder fortsetzen.");cancel.setHelp("Abbrechen","Den laufenden Vorgang abbrechen. Bereits fertiggestellte Schritte bleiben erhalten.")
        queueButton.setHelp("Aufträge","Wartende, laufende und frühere Dateivorgänge ansehen.",shortcut:CommandHelp.shortcut("operations"))
        [toolbarScroll,toolbarMore,utilityBar,split,rail,quick,functionBar,commandMode,commandField,commandGo,terminal,status,progress,cancel,pause,queueButton].forEach { addSubview($0) }
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout();let w = bounds.width,h = bounds.height
        let toolbarHeight: CGFloat = Preferences.appearanceSettings().toolbarLabels ? 50 : 32
        toolbarScroll.frame = NSRect(x:5,y:h-toolbarHeight,width:max(1,w-256),height:toolbarHeight)
        toolbarMore.frame = NSRect(x:w-249,y:h-toolbarHeight+(toolbarHeight-28)/2,width:28,height:28)
        utilityBar.frame = NSRect(x:w-212,y:h-toolbarHeight,width:207,height:toolbarHeight)
        layoutToolbar(width:toolbarScroll.bounds.width,height:toolbarHeight)
        let q: CGFloat = quickVisible ? min(330,w*0.28) : 0
        split.frame = NSRect(x:0,y:78,width:max(1,w-q),height:max(1,h-toolbarHeight-78))
        if firstLayout && w > 0 && h > 0 && split.arrangedSubviews.count == 2 { firstLayout = false;split.setPosition(((split.isVertical ? split.bounds.width : split.bounds.height)-split.dividerThickness)/2,ofDividerAt:0) }
        quick.frame = NSRect(x:w-q,y:78,width:q,height:split.frame.height)
        functionBar.frame = NSRect(x:2,y:25,width:max(1,w-4),height:25)
        commandMode.frame = NSRect(x:5,y:52,width:84,height:23)
        commandField.frame = NSRect(x:92,y:52,width:max(1,w-157),height:23)
        commandGo.frame = NSRect(x:w-61,y:52,width:26,height:23);terminal.frame = NSRect(x:w-31,y:52,width:26,height:23)
        progress.frame = NSRect(x:7,y:8,width:95,height:10)
        status.frame = NSRect(x:108,y:4,width:max(20,w-465),height:17)
        pause.frame = NSRect(x:w-351,y:2,width:98,height:22);cancel.frame = NSRect(x:w-251,y:2,width:112,height:22);queueButton.frame = NSRect(x:w-137,y:2,width:132,height:22)
        positionRail()
    }
    func layoutToolbar(width:CGFloat,height:CGFloat) {
        var used: CGFloat = 0,overflow = false,pendingSeparator: NSView?
        for view in toolbar.arrangedSubviews {
            if view is NSBox { view.isHidden = true;pendingSeparator = view;continue }
            let itemWidth = max(24,view.intrinsicContentSize.width),gap: CGFloat = used > 0 ? (pendingSeparator == nil ? 3 : 7) : 0
            let visible = !overflow && used+gap+itemWidth <= width
            view.isHidden = !visible
            if visible { pendingSeparator?.isHidden = used == 0;used += gap+itemWidth } else { overflow = true }
            pendingSeparator = nil
        }
        toolbar.frame = NSRect(x:0,y:0,width:max(1,used),height:height)
    }
    func positionRail() {
        let panes = split.arrangedSubviews
        rail.isHidden = panes.count != 2 || panes.contains(where: \.isHidden)
        window?.invalidateCursorRects(for:split);window?.invalidateCursorRects(for:rail)
        guard !rail.isHidden else { return };rail.vertical = split.isVertical
        rail.frame = convert(split.actionStripFrame,from:split);rail.needsLayout = true
    }
    func splitViewDidResizeSubviews(_ notification: Notification) { positionRail() }
    func splitView(_ splitView:NSSplitView,canCollapseSubview subview:NSView)->Bool { false }
    func splitView(_ splitView:NSSplitView,effectiveRect proposedEffectiveRect:NSRect,forDrawnRect drawnRect:NSRect,ofDividerAt dividerIndex:Int)->NSRect {
        split.resizeGrip(in:drawnRect)
    }
    func splitView(_ splitView:NSSplitView,constrainSplitPosition proposedPosition:CGFloat,ofSubviewAt dividerIndex:Int)->CGFloat {
        let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let minimum: CGFloat = splitView.isVertical ? min(280,length*0.35) : min(160,length*0.35)
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
    let themeMenu = NSPopUpButton(frame:.zero,pullsDown:false)
    let favoriteMenu = NSPopUpButton(frame:.zero,pullsDown:false)
    let cache: URL
    var onRebuildMenus: (() -> Void)?
    var operationWindow: OperationQueueController?
    var programLauncher: ((ProgramLaunchRequest) -> Void)?
    var keyCompareController: CompareController? { secondaryWindows.compactMap { $0 as? CompareController }.first { $0.window === NSApp.keyWindow || (NSApp.keyWindow?.sheetParent != nil && $0.window === NSApp.keyWindow?.sheetParent) } }
    var keySearchController: SearchController? { secondaryWindows.compactMap { $0 as? SearchController }.first { $0.window === NSApp.keyWindow } }
    var pendingWork:Int { secondaryWindows.compactMap { $0 as? CompareController }.filter { $0.isComparing || $0.isPreparingPlan }.count + secondaryWindows.compactMap { $0 as? SearchController }.filter(\.isSearching).count + jobs.pending + secondaryWindows.compactMap { $0 as? RemoteWindow }.reduce(0) { $0+$1.jobs.pending } }
    var canTerminate: Bool {
        !left.inlineRename.hasPendingCommit && !right.inlineRename.hasPendingCommit &&
        secondaryWindows.compactMap { $0 as? CompareController }.allSatisfy { !$0.isComparing && !$0.isPreparingPlan } && secondaryWindows.compactMap { $0 as? SearchController }.allSatisfy { !$0.isSearching } && jobs.canClose && secondaryWindows.compactMap { $0 as? RemoteWindow }.allSatisfy { $0.jobs.pending == 0 } &&
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
            pane.onRename = { [weak self,weak pane] item,request in self?.renameInline(item,in:pane,request:request) }
            pane.onState = { [weak self] in self?.saveState();self?.updateChromeState() }
            pane.onSelection = { [weak self, weak pane] urls in
                guard let self else { return };self.updateChromeState()
                if pane === self.active,self.content.quickVisible { self.content.quick.previewItem = urls.first.map { $0 as NSURL } }
            }
            pane.onNavigate = { [weak self] p,old,new in self?.followNavigation(p,from:old,to:new) }
            pane.refresh()
        }
        buildToolbar();refreshLocations();setActive(left)
        content.toolbarMore.perform = { [weak self] in guard let self else { return };self.toolbarOverflowMenu().popUp(positioning:nil,at:NSPoint(x:0,y:0),in:self.content.toolbarMore) }
        content.rail.configure([("Seiten tauschen","arrow.left.arrow.right.square","swap"),("Ordner vergleichen","doc.text.magnifyingglass","compare"),("Gleicher Ordner","folder.fill","sameFolder"),("Verknüpft navigieren","link","linked"),("Anordnung wechseln","rectangle.split.2x1","orientation"),("Ein-/Zweifensteransicht","sidebar.left","onePane"),("In den Papierkorb …","trash","trash")]) { [weak self] in self?.command($0) }
        content.commandMode.target = self;content.commandMode.action = #selector(commandModeChanged)
        content.commandField.target = self;content.commandField.action = #selector(commandEntered)
        content.commandGo.perform = { [weak self] in self?.commandEntered() }
        content.terminal.perform = { [weak self] in self?.openTerminal() }
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
        let labels = Preferences.appearanceSettings().toolbarLabels
        content.toolbar.arrangedSubviews.forEach { content.toolbar.removeArrangedSubview($0);$0.removeFromSuperview() }
        var previousGroup: Int?
        for id in Preferences.toolbarSettings().items {
            guard let item = ToolbarCommand.all.first(where: { $0.id == id }) else { continue }
            if let previousGroup,previousGroup != item.group { let separator = NSBox();separator.boxType = .separator;separator.widthAnchor.constraint(equalToConstant:1).isActive = true;separator.heightAnchor.constraint(equalToConstant:labels ? 35 : 20).isActive = true;content.toolbar.addArrangedSubview(separator) }
            previousGroup = item.group
            let b = ActionButton(labels ? item.title : "",symbol:item.symbol,action:{ [weak self] in self?.command(id) })
            b.flat = true;b.verticalLabel = labels;b.font = .systemFont(ofSize:10);b.symbolTint = item.tint;b.identifier = .init(id);CommandHelp.apply(b,id:id,title:item.title)
            b.setContentCompressionResistancePriority(.required,for:.horizontal);content.toolbar.addArrangedSubview(b)
        }
        favoriteMenu.target = self;favoriteMenu.action = #selector(favoriteChosen);favoriteMenu.controlSize = .small
        if !favoriteMenu.constraints.contains(where: { $0.firstAttribute == .width }) { favoriteMenu.widthAnchor.constraint(equalToConstant:115).isActive = true }
        if favoriteMenu.superview == nil { content.utilityBar.addArrangedSubview(favoriteMenu) }
        themeMenu.removeAllItems();themeMenu.addItems(withTitles:["System","Hell","Dunkel"]);themeMenu.controlSize = .small;themeMenu.toolTip = "Erscheinungsbild";themeMenu.setAccessibilityLabel("Erscheinungsbild")
        themeMenu.target = self;themeMenu.action = #selector(themeChosen);if !themeMenu.constraints.contains(where: { $0.firstAttribute == .width }) { themeMenu.widthAnchor.constraint(equalToConstant:86).isActive = true }
        if themeMenu.superview == nil { content.utilityBar.addArrangedSubview(themeMenu) }
        if content.functionBar.arrangedSubviews.isEmpty {
            for (title,symbol,cmd) in [("F3 Ansehen","eye","preview"),("F4 Bearbeiten","pencil","edit"),("F5 Kopieren","doc.on.doc","copy"),("F6 Verschieben","arrow.right.doc.on.clipboard","move"),("F7 Neuer Ordner","folder.badge.plus","newFolder"),("F8 Papierkorb","trash","trash")] {
                let b = ActionButton(title,symbol:symbol,action:{ [weak self] in self?.command(cmd) });b.flat = true;b.identifier = .init(cmd);b.font = .systemFont(ofSize:11);b.symbolTint = cmd == "trash" ? .systemRed : cmd == "newFolder" ? .systemOrange : .systemBlue;content.functionBar.addArrangedSubview(b)
            }
        }
        themeMenu.selectItem(at:max(0,min(2,Preferences.state.theme)))
        updateFunctionLabels();updateChromeState();content.needsLayout = true
    }
    @objc func themeChosen() { Preferences.state.theme = themeMenu.indexOfSelectedItem;applyTheme();Preferences.save();onRebuildMenus?() }
    @objc func commandModeChanged() {
        content.commandField.stringValue = content.commandMode.indexOfSelectedItem == 0 ? active.currentURL.path : ""
        content.commandField.placeholderString = content.commandMode.indexOfSelectedItem == 0 ? "Ordnerpfad" : "zsh-Befehl im aktiven Ordner"
        content.commandField.toolTip = content.commandMode.indexOfSelectedItem == 0 ? "Enter öffnet diesen Ordner" : "Enter führt den Befehl mit deinen Benutzerrechten im aktiven Ordner aus"
    }
    @objc func commandEntered() {
        defer { updateChromeState() }
        let text = content.commandField.stringValue
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        if content.commandMode.indexOfSelectedItem == 0 {
            let path = (text as NSString).expandingTildeInPath
            active.navigate(path.hasPrefix("/") ? URL(fileURLWithPath:path) : active.currentURL.appendingPathComponent(path))
        } else if ensureWritable(active) { executeShellCommand(text,in:active.currentURL) }
    }
    func updateChromeState() {
        guard isWindowLoaded else { return }
        left.updateNavigationHelp();right.updateNavigationHelp()
        if content.commandMode.indexOfSelectedItem == 0,!(content.commandField.currentEditor() is NSTextView) { content.commandField.stringValue = active.currentURL.path }
        for case let button as NSButton in content.toolbar.arrangedSubviews {
            let id = button.identifier?.rawValue
            if let button = button as? ActionButton,let id { CommandHelp.apply(button,id:id,title:ToolbarCommand.all.first { $0.id == id }?.title) }
            if let id,["back","forward"].contains(id),let navigation = active.navigationButtons[id] { button.isEnabled = navigation.isEnabled;button.toolTip = navigation.toolTip }
            button.state = (id == "details" && active.displayMode == .details) || (id == "thumbnails" && active.displayMode == .thumbnails) || (id == "icons" && active.displayMode == .icons) || (id == "tree" && active.treeVisible) || (id == "quickView" && content.quickVisible) ? .on : .off
        }
        for button in content.rail.buttons { let id = button.identifier?.rawValue ?? "";button.state = id == "linked" && linked ? .on : .off;CommandHelp.apply(button,id:id) }
        updateFunctionLabels()
    }
    func updateFunctionLabels() {
        let values:[String:(String,String)] = ["preview":("F3","Ansehen"),"edit":("F4","Bearbeiten"),"copy":("F5","Kopieren"),"move":("F6","Verschieben"),"newFolder":("F7","Neuer Ordner"),"trash":("F8","Papierkorb")]
        for case let button as NSButton in content.functionBar.arrangedSubviews {
            guard let id = button.identifier?.rawValue,let value = values[id] else { continue }
            if let button = button as? ActionButton { CommandHelp.apply(button,id:id) }
            var key = (Preferences.state.shortcuts[id] ?? value.0).lowercased()
            if key == "space" { key = "Leertaste" }
            for (word,symbol) in [("cmd+","⌘"),("shift+","⇧"),("option+","⌥"),("alt+","⌥"),("control+","⌃"),("ctrl+","⌃")] { key = key.replacingOccurrences(of:word,with:symbol) }
            if id == "copy" || id == "move" {
                let target = content.split.isVertical ? (active === left ? "→ Rechts" : "← Links") : (active === left ? "↓ Unten" : "↑ Oben")
                button.title = key.uppercased()+" "+target+" "+value.1.lowercased()
                if id == "copy",other.tab.collection != nil { button.title = key.uppercased()+" "+(target.components(separatedBy:" ").first ?? "→")+" Zur Sammlung" }
                button.toolTip = "\(active.selectedURLs.count) ausgewählt · Quelle: \(active.currentURL.path)\nZiel: \(other.currentURL.path)"
                if id == "copy",other.tab.collection != nil { button.toolTip = "Verweise zur Dateisammlung hinzufügen. Die Originaldateien bleiben an ihrem bisherigen Ort." }
                button.setAccessibilityLabel(button.title+" · "+(button.toolTip ?? other.currentURL.path))
                button.isEnabled = !active.selectedURLs.isEmpty && (id == "copy" ? !other.readOnly : !active.readOnly && !other.readOnly && other.tab.collection == nil)
                if !button.isEnabled { button.toolTip = (button.toolTip ?? "")+"\n"+(active.selectedURLs.isEmpty ? "Zuerst Dateien oder Ordner auswählen." : "Für diesen Vorgang werden beschreibbare Ordner benötigt.") }
            } else { button.title = key.uppercased()+" "+value.1 }
        }
    }
    @objc func volumesChanged() { refreshLocations() }
    @objc func secondaryWindowClosed(_ notification:Notification) {
        guard let window = notification.object as? NSWindow else { return }
        secondaryWindows.removeAll { $0.window === window }
    }
    func refreshLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var places:[(String,URL)] = [("Benutzerordner",home),("Schreibtisch",home.appendingPathComponent("Desktop")),("Dokumente",home.appendingPathComponent("Documents")),("Downloads",home.appendingPathComponent("Downloads")),("Programme",URL(fileURLWithPath:"/Applications")),("Macintosh HD",URL(fileURLWithPath:"/"))]
        if let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:[.volumeIsBrowsableKey],options:[.skipHiddenVolumes]) {
            places += volumes.filter { $0.path != "/" }.map { ($0.lastPathComponent,$0) }
        }
        let drivePlaces = places.filter { !["Schreibtisch","Dokumente","Programme"].contains($0.0) }
        for pane in [left,right] { pane.locations.configure(drivePlaces);pane.locations.select(pane.currentURL) }
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
    @objc func favoriteChosen() {
        defer { favoriteMenu.selectItem(at:0) }
        guard let value = favoriteMenu.selectedItem?.representedObject as? String else { return }
        if value == "editFavorites" { showFavorites() }
        else if let id = UUID(uuidString:value) { do { try openFavorite(id) } catch { showFailure(error) } }
    }
    func setActive(_ pane:PaneView) { active = pane; left.isActive = pane === left; right.isActive = pane === right; window?.subtitle = (pane === left ? "Links" : "Rechts")+" · "+pane.currentURL.path;updateChromeState() }
    func saveState() { Preferences.state.left = left.savedTabs; Preferences.state.right = right.savedTabs; Preferences.state.vertical = content.split.isVertical; Preferences.save() }
    func applyTheme() {
        NSApp.appearance = Preferences.state.theme == 1 ? NSAppearance(named:.aqua) : Preferences.state.theme == 2 ? NSAppearance(named:.darkAqua) : nil
        themeMenu.selectItem(at:max(0,min(2,Preferences.state.theme)))
        for pane in [left,right] { pane.applyImportedAppearance() }
        content.updateSurface();content.needsDisplay = true
    }
    func applyAppearanceSettings() {
        for pane in [left,right] { pane.applyImportedAppearance();pane.needsLayout = true }
        buildToolbar();refreshLocations();content.needsLayout = true
    }
    func followNavigation(_ pane:PaneView,from old:URL,to new:URL) {
        saveState(); guard linked else { return }
        let target = pane === left ? right : left
        let candidate:URL
        if new.deletingLastPathComponent() == old { candidate = target.currentURL.appendingPathComponent(new.lastPathComponent) }
        else if old.deletingLastPathComponent() == new { candidate = target.currentURL.deletingLastPathComponent() }
        else { return }
        if FileSystem.isDirectory(candidate) { target.navigate(candidate,linked:true); pane.focus() }
    }
    func renameInline(_ item:RenameItem,in pane:PaneView?,request:UUID) {
        jobs.submitReported("Umbenennen · "+item.source.lastPathComponent,notifyQueuedCancellation:true,body:{ token,reporter in
            try RenameEngine.apply([item],token:token) { reporter.report("Umbenennen · "+$0.name) }
        },completion:{ [weak self,weak pane] result in
            guard let self else { return }
            switch result {
            case .success(let undo):
                self.renameUndo = undo;self.undoSteps = []
                self.reflectRenames([item])
                if pane?.inlineRename.sessionID == request { pane?.inlineRename.completed(.success(())) }
                self.refresh()
            case .failure(let error):
                if pane?.inlineRename.sessionID == request { pane?.inlineRename.completed(.failure(error)) }
                else if case CommanderError.cancelled = error {} else { self.content.status.stringValue = error.localizedDescription }
            }
        })
    }
    func reflectRenames(_ items:[RenameItem]) {
        let targets = Dictionary(uniqueKeysWithValues:items.filter(\.changed).map { ($0.source.path,$0.target) })
        guard !targets.isEmpty else { return }
        var parents: [String:URL] = [:]
        func renamed(_ url:URL) -> URL {
            let parent = url.deletingLastPathComponent(),key = parent.path
            let canonical = parents[key] ?? FileSystem.canonical(parent);parents[key] = canonical
            return targets[canonical.appendingPathComponent(url.lastPathComponent).path] ?? url
        }
        for side in [left,right] {
            let collection = side.tab.collection,selected = side.rawSelectedURLs
            for tab in side.tabs { if let values = tab.collection { tab.collection = values.map(renamed) } }
            let updated = Set(selected.map(renamed))
            if updated != selected || collection != side.tab.collection { side.requestSelection(updated) }
        }
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
        if !canTerminate { _ = dialog("Dateiaufträge sind offen",message:"Laufende Vorgänge einschließlich Suchen, vorgemerkte Synchronisationen und Aufträge aus temporären Archivansichten erst abschließen oder entfernen. Gespeicherte wartende Kopier- und Verschiebeaufträge bleiben beim Beenden erhalten.",buttons:["OK"]); return false }
        saveState(); return true
    }
    func windowWillClose(_ notification:Notification) { saveState() }
}
