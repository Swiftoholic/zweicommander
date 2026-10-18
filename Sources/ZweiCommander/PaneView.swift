import AppKit
import CommanderCore

final class FolderTab {
    let id = UUID()
    var url: URL
    var title: String?
    var locked = false
    var history: [URL]
    var position = 0
    var collection: [URL]?
    var archiveRoot: URL?
    var archiveOrigin: URL?
    var view: FolderViewSettings?
    init(_ url: URL) { self.url = url; history = [url] }
}
final class FileTable: NSTableView {
    weak var pane: PaneView?
    override func becomeFirstResponder() -> Bool { pane?.activate(); return super.becomeFirstResponder() }
    override func mouseDown(with event: NSEvent) { pane?.activate(); super.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) {
        pane?.activate()
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0 && !selectedRowIndexes.contains(r) { selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false) }
        super.rightMouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command,.control,.option]).isEmpty {
            switch event.keyCode {
            case 48: pane?.onSwitch?(); return
            case 36, 76: pane?.openSelection(); return
            case 51: pane?.goParent(); return
            case 49: pane?.onPreview?(pane?.selectedURLs ?? []); return
            case 53: pane?.clearFilter(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

final class PaneView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let table = FileTable()
    let grid = FileGrid()
    let scroll = NSScrollView()
    let pathField = input()
    let filterField = NSSearchField()
    let filterRegex = checkbox(".*")
    let status = label("", size: 11, color: .secondaryLabelColor)
    let marker = NSView()
    let tabsScroll = NSScrollView()
    let tabsStack = NSStackView()
    let nav = NSStackView()
    let viewMode = NSPopUpButton()
    let sortMode = NSPopUpButton()
    let sortDirection = ActionButton("",symbol:"arrow.up.arrow.down",action:{})
    let viewBar = NSStackView()
    let tree = FolderTree()
    var treeVisible = false { didSet { tree.isHidden = !treeVisible; needsLayout = true } }
    var tabs: [FolderTab] = []
    var tabIndex = 0
    var tab: FolderTab { tabs[tabIndex] }
    var currentURL: URL { tab.url }
    var readOnly: Bool { tab.archiveRoot != nil }
    var entries: [FileEntry] = []
    var visibleEntries: [FileEntry] = []
    var showHidden = false
    var displayMode: PaneDisplayMode = .details
    var thumbnails: Bool { displayMode == .thumbnails }
    var defaultView: FolderViewSettings?
    var changingView = false
    var syncingSelection = false
    var isActive = false { didSet { marker.layer?.backgroundColor = (isActive ? NSColor.controlAccentColor : .separatorColor).cgColor; applyImportedAppearance() } }
    var foldersFirst = true
    var importedProfile: SettingsProfile?
    private struct ColumnState { let id: String; let title: String; let width: CGFloat; let hidden: Bool }
    private var beforeImport: (columns: [ColumnState], sort: String, ascending: Bool, tree: Bool, foldersFirst: Bool)?
    var sortKey = "name", ascending = true
    var generation = 0
    var watcher: DispatchSourceFileSystemObject?
    var delayedRefresh: DispatchWorkItem?
    var onActivate: ((PaneView) -> Void)?
    var onNavigate: ((PaneView, URL, URL) -> Void)?
    var onSwitch: (() -> Void)?
    var onPreview: (([URL]) -> Void)?
    var onOpenArchive: ((URL, PaneView) -> Void)?
    var onDrop: (([URL], URL) -> Void)?
    var onCollectionDrop: (([URL]) -> Void)?
    var onSelection: (([URL]) -> Void)?
    var onCommand: ((String) -> Void)?
    var onState: (() -> Void)?
    var icons: [String: NSImage] = [:]
    var selectionIndexes: IndexSet {
        get { displayMode == .icons ? IndexSet(grid.selectionIndexPaths.map(\.item)) : table.selectedRowIndexes }
        set {
            syncingSelection = true
            table.selectRowIndexes(newValue,byExtendingSelection:false)
            grid.selectionIndexPaths = Set(newValue.map { IndexPath(item:$0,section:0) })
            syncingSelection = false;updateStatus()
        }
    }
    var selectedURLs: [URL] { selectionIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0].url : nil } }

    init(url: URL, savedTabs: [SavedTab] = []) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        var restoredActive: UUID?
        tabs = savedTabs.compactMap { item in
            let u = URL(fileURLWithPath: item.path)
            guard FileSystem.isDirectory(u) else { return nil }
            let t = FolderTab(u); t.title = item.title; t.locked = item.locked
            if let view = item.view,(try? view.validate()) != nil { t.view = view }
            if item.selected == true { restoredActive = t.id };return t
        }
        if tabs.isEmpty { tabs = [FolderTab(url)] }
        if let restoredActive,let index = tabs.firstIndex(where: { $0.id == restoredActive }) { tabIndex = index }
        marker.wantsLayer = true
        table.pane = self; table.delegate = self; table.dataSource = self
        table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 25
        table.style = .plain; table.intercellSpacing = NSSize(width: 8,height: 2)
        table.target = self; table.doubleAction = #selector(doubleClick)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (id,title,width) in [("name","Name",CGFloat(260)),("ext","Endung",55),("size","Größe",85),("modified","Geändert",155),("kind","Art",130),("attributes","Attribute",80),("permissions","Rechte",65),("path","Ordner",260)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); c.title = title; c.width = width; c.minWidth = 40
            c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            c.isHidden = ["kind","attributes","permissions","path"].contains(id)
            table.addTableColumn(c)
        }
        if !Preferences.testMode { table.autosaveName = "ZweiCommander.columns"; table.autosaveTableColumns = true }
        let menu = NSMenu()
        for (title,command) in [("Öffnen","open"),("Vorschau","preview"),("Im Finder zeigen","reveal"),("Kopieren …","copy"),("Verschieben …","move"),("Umbenennen …","rename"),("Mehrfachumbenennen …","batchRename"),("In den Papierkorb …","trash"),("Pfad kopieren","copyPath"),("Eigenschaften …","properties")] {
            let item = NSMenuItem(title: title, action: #selector(contextCommand(_:)), keyEquivalent: ""); item.target = self; item.representedObject = command; menu.addItem(item)
        }
        table.menu = menu
        configureIconView()
        let columns = NSMenu()
        for c in table.tableColumns { let i = NSMenuItem(title: c.title, action: #selector(toggleColumn(_:)), keyEquivalent: ""); i.target = self; i.representedObject = c; i.state = c.isHidden ? .off : .on; columns.addItem(i) }
        table.headerView?.menu = columns
        table.registerForDraggedTypes([.fileURL]); table.setDraggingSourceOperationMask(.copy, forLocal: false); table.setDraggingSourceOperationMask(.copy, forLocal: true)
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        pathField.target = self; pathField.action = #selector(pathEntered); pathField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        pathField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let back = ActionButton("", symbol: "chevron.left") { [weak self] in self?.history(-1) }; back.toolTip = "Zurück"
        let forward = ActionButton("", symbol: "chevron.right") { [weak self] in self?.history(1) }; forward.toolTip = "Vorwärts"
        let up = ActionButton("", symbol: "arrow.up") { [weak self] in self?.goParent() }; up.toolTip = "Übergeordneter Ordner"
        let home = ActionButton("", symbol: "house") { [weak self] in self?.navigate(FileManager.default.homeDirectoryForCurrentUser) }; home.toolTip = "Benutzerordner"
        nav.orientation = .horizontal; nav.spacing = 4
        [back,forward,up,home,pathField].forEach { nav.addArrangedSubview($0) }
        tabsStack.orientation = .horizontal; tabsStack.spacing = 4; tabsStack.alignment = .centerY
        tabsScroll.documentView = tabsStack; tabsScroll.hasHorizontalScroller = true; tabsScroll.autohidesScrollers = true;tabsScroll.drawsBackground = false
        viewMode.addItems(withTitles:PaneDisplayMode.allCases.map(\.title));viewMode.target = self;viewMode.action = #selector(viewModeChanged)
        viewMode.toolTip = "Darstellung dieses Tabs"
        sortMode.addItems(withTitles:["Name","Endung","Größe","Geändert","Art","Attribute","Rechte","Ordner"]);sortMode.target = self;sortMode.action = #selector(sortModeChanged)
        sortMode.toolTip = "Sortieren nach"
        sortDirection.perform = { [weak self] in self?.sortDirectionChanged() };sortDirection.toolTip = "Sortierrichtung wechseln"
        viewBar.orientation = .horizontal;viewBar.spacing = 7
        [viewMode,sortMode,sortDirection].forEach { viewBar.addArrangedSubview($0) }
        filterField.placeholderString = "Schnellfilter · Name, *.pdf oder RegEx"
        filterField.delegate = self; filterField.sendsSearchStringImmediately = true
        filterRegex.target = self; filterRegex.action = #selector(filterChanged)
        tree.isHidden = true; tree.onChoose = { [weak self] url in self?.navigate(url) }
        [marker,tabsScroll,nav,viewBar,scroll,filterField,filterRegex,status,tree].forEach { addSubview($0) }
        rebuildTabs(); refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { watcher?.cancel() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            marker.layer?.backgroundColor = (isActive ? NSColor.controlAccentColor : .separatorColor).cgColor
        }
        applyImportedAppearance()
    }
    var listFont: NSFont {
        guard let profile = importedProfile else { return .systemFont(ofSize:12) }
        return NSFont(name:profile.fontName,size:profile.fontSize) ?? .systemFont(ofSize:profile.fontSize)
    }
    func configure(profile: SettingsProfile, isLeft: Bool) {
        changingView = true;defer { changingView = false }
        if importedProfile == nil {
            beforeImport = (table.tableColumns.map { ColumnState(id:$0.identifier.rawValue,title:$0.title,width:$0.width,hidden:$0.isHidden) },sortKey,ascending,treeVisible,foldersFirst)
        }
        importedProfile = profile; foldersFirst = profile.foldersFirst
        table.autosaveTableColumns = false
        for c in table.tableColumns { c.isHidden = !profile.columns.contains { $0.id == c.identifier.rawValue } }
        let glyphWidth = ("0000000000" as NSString).size(withAttributes:[.font:listFont]).width/10
        for (index,column) in profile.columns.enumerated() {
            guard let c = table.tableColumn(withIdentifier:.init(column.id)),let oldIndex = table.tableColumns.firstIndex(of:c) else { continue }
            c.title = column.title; c.width = max(55,CGFloat(column.characterWidth)*glyphWidth)
            table.moveColumn(oldIndex,toColumn:index)
        }
        let sort = isLeft ? profile.leftSort : profile.rightSort
        sortKey = sort.key; ascending = sort.ascending
        treeVisible = isLeft ? profile.leftTree : profile.rightTree
        rebuildColumnMenu()
        applyImportedAppearance(); applyFilter()
    }
    func restoreConfigurationBeforeImport() {
        guard let saved = beforeImport else { return }
        changingView = true;defer { changingView = false }
        importedProfile = nil; table.autosaveTableColumns = false
        for (index,state) in saved.columns.enumerated() {
            guard let c = table.tableColumn(withIdentifier:.init(state.id)),let oldIndex = table.tableColumns.firstIndex(of:c) else { continue }
            c.title = state.title; c.width = state.width; c.isHidden = state.hidden
            table.moveColumn(oldIndex,toColumn:index)
        }
        sortKey = saved.sort; ascending = saved.ascending; treeVisible = saved.tree; foldersFirst = saved.foldersFirst
        table.backgroundColor = .controlBackgroundColor; scroll.backgroundColor = .controlBackgroundColor
        grid.backgroundColors = [.controlBackgroundColor]
        table.usesAlternatingRowBackgroundColors = true
        table.autosaveTableColumns = !Preferences.testMode
        beforeImport = nil; rebuildColumnMenu(); applyFilter()
    }
    private func rebuildColumnMenu() {
        let columns = NSMenu()
        for c in table.tableColumns { let i = NSMenuItem(title:c.title,action:#selector(toggleColumn(_:)),keyEquivalent:"");i.target = self;i.representedObject = c;i.state = c.isHidden ? .off : .on;columns.addItem(i) }
        table.headerView?.menu = columns
    }
    func applyImportedAppearance() {
        guard let profile = importedProfile else { return }
        let color = (isActive ? profile.background : profile.inactiveBackground) ?? profile.background
        table.backgroundColor = color?.nsColor ?? .controlBackgroundColor
        grid.backgroundColors = [table.backgroundColor]
        scroll.backgroundColor = table.backgroundColor
        table.usesAlternatingRowBackgroundColors = false
    }
    override func layout() {
        super.layout(); let w = bounds.width, h = bounds.height
        marker.frame = NSRect(x: 0,y: h-3,width: w,height: 3)
        tabsScroll.frame = NSRect(x: 8,y: h-35,width: max(1,w-16),height: 28)
        nav.frame = NSRect(x: 7,y: h-72,width: max(1,w-14),height: 30)
        viewBar.frame = NSRect(x:7,y:h-103,width:max(1,w-14),height:27)
        let treeWidth: CGFloat = treeVisible ? min(165,w*0.32) : 0
        tree.frame = NSRect(x: 0,y: 59,width: treeWidth,height: max(1,h-169))
        scroll.frame = NSRect(x: treeWidth,y: 59,width: max(1,w-treeWidth),height: max(1,h-169))
        filterField.frame = NSRect(x: 8,y: 29,width: max(1,w-67),height: 24)
        filterRegex.frame = NSRect(x: w-53,y: 29,width: 45,height: 24)
        status.frame = NSRect(x: 10,y: 6,width: max(1,w-20),height: 18)
    }
    func activate() { onActivate?(self) }
    func focus() { activate(); window?.makeFirstResponder(displayMode == .icons ? grid : table) }
    func rebuildTabs() {
        tabsStack.arrangedSubviews.forEach { tabsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i,t) in tabs.enumerated() {
            let title = (t.locked ? "🔒 " : "") + (t.title ?? (t.url.lastPathComponent.isEmpty ? "/" : t.url.lastPathComponent))
            let b = FolderTabButton(title:title,tab:t,pane:self)
            b.bezelStyle = .recessed; b.state = i == tabIndex ? .on : .off; b.toolTip = t.url.path
            b.font = .systemFont(ofSize: 12, weight: i == tabIndex ? .semibold : .regular)
            tabsStack.addArrangedSubview(b)
        }
        tabsStack.addArrangedSubview(ActionButton("+", action: { [weak self] in self?.newTab() }))
        tabsStack.addArrangedSubview(ActionButton("×", action: { [weak self] in self?.closeTab() }))
        tabsStack.frame = NSRect(origin: .zero, size: NSSize(width: max(180,tabsStack.fittingSize.width),height: 28))
        if tabsStack.arrangedSubviews.indices.contains(tabIndex) { tabsStack.scrollToVisible(tabsStack.arrangedSubviews[tabIndex].frame) }
        onState?()
    }
    func newTab(url: URL? = nil) {
        let t = FolderTab(url ?? currentURL);t.view = tab.view
        if let root = tab.archiveRoot, FileSystem.isInside(t.url,root) { t.archiveRoot = root; t.archiveOrigin = tab.archiveOrigin }
        tabs.append(t); tabIndex = tabs.count-1;restoreTabView(); rebuildTabs(); refresh(); focus()
    }
    func closeTab() { guard tabs.count > 1, !tab.locked else { NSSound.beep(); return }; tabs.remove(at: tabIndex); tabIndex = max(0,tabIndex-1);restoreTabView(); rebuildTabs(); refresh();focus() }
    func navigate(_ url: URL, linked: Bool = false) {
        let u = url.standardizedFileURL
        guard FileSystem.isDirectory(u) else { showFailure(CommanderError.message("Ordner nicht gefunden: \(u.path)")); return }
        let old = currentURL
        if tab.locked && u != old { newTab(url: u); return }
        if let root = tab.archiveRoot, !FileSystem.isInside(u, root) { tab.archiveRoot = nil; tab.archiveOrigin = nil }
        tab.url = u; tab.collection = nil; filterField.stringValue = ""
        tab.history = Array(tab.history.prefix(tab.position+1)); tab.history.append(u); tab.position = tab.history.count-1
        restoreTabView();rebuildTabs(); refresh(); focus()
        if !linked { onNavigate?(self,old,u) }
    }
    func history(_ offset: Int) {
        let i = tab.position+offset; guard i >= 0 && i < tab.history.count else { return }
        if tab.locked && tab.history[i] != currentURL { newTab(url:tab.history[i]);return }
        tab.position = i; tab.url = tab.history[i]; tab.collection = nil
        if let root = tab.archiveRoot, !FileSystem.isInside(tab.url, root) { tab.archiveRoot = nil; tab.archiveOrigin = nil }
        restoreTabView();rebuildTabs(); refresh(); focus()
    }
    func goParent() {
        if tab.archiveRoot == currentURL, let origin = tab.archiveOrigin { navigate(origin.deletingLastPathComponent()); return }
        navigate(currentURL.deletingLastPathComponent())
    }
    func showCollection(_ urls: [URL], title: String) { newTab(); tab.collection = urls; tab.title = title;restoreTabView(); rebuildTabs(); refresh() }
    func addToCollection(_ urls: [URL]) {
        guard var values = tab.collection else { return }
        for url in urls where !values.contains(url) { values.append(url) }
        tab.collection = values; refresh()
    }
    func removeFromCollection() {
        guard let values = tab.collection else { return }
        let chosen = Set(selectedURLs); tab.collection = values.filter { !chosen.contains($0) }; refresh()
    }
    func showArchive(root: URL, original: URL) { newTab(url: root); tab.archiveRoot = root; tab.archiveOrigin = original; tab.title = original.lastPathComponent;restoreTabView(); rebuildTabs(); refresh() }
    @objc func pathEntered() {
        activate(); let path = (pathField.stringValue as NSString).expandingTildeInPath
        navigate(path.hasPrefix("/") ? URL(fileURLWithPath: path) : currentURL.appendingPathComponent(path))
    }
    func refresh() {
        generation += 1; let g = generation, url = currentURL, hidden = showHidden, collection = tab.collection
        let selected = Set(selectedURLs)
        pathField.stringValue = url.path; pathField.toolTip = readOnly ? "Temporäre Archivansicht · schreibgeschützt" : url.path
        status.stringValue = "Lese Ordner …"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try collection.map { $0.compactMap { try? FileEntry(url: $0) } } ?? FileSystem.list(url, showHidden: hidden) }
            DispatchQueue.main.async {
                guard let self, self.generation == g else { return }
                switch result {
                case .success(let entries): self.entries = entries; self.applyFilter(); self.select(selected); self.watch(url)
                case .failure(let error): self.entries = []; self.visibleEntries = []; self.table.reloadData();self.grid.reloadData(); self.status.stringValue = error.localizedDescription
                }
            }
        }
    }
    func watch(_ url: URL) {
        watcher?.cancel(); watcher = nil
        guard tab.collection == nil else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write,.delete,.rename,.attrib], queue: .main)
        source.setEventHandler { [weak self] in
            self?.delayedRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refresh() }
            self?.delayedRefresh = work; DispatchQueue.main.asyncAfter(deadline: .now()+0.25, execute: work)
        }
        source.setCancelHandler { close(fd) }; source.resume(); watcher = source
    }
    private func selectionPath(_ url: URL,parents: inout [String:URL]) -> String {
        // Resolve parent aliases such as /var, but keep a selected link itself.
        let parent = url.deletingLastPathComponent(),key = parent.path
        let canonical: URL
        if let saved = parents[key] { canonical = saved }
        else { canonical = FileSystem.canonical(parent);parents[key] = canonical }
        return canonical.appendingPathComponent(url.lastPathComponent).path
    }
    func select(_ urls: Set<URL>) {
        guard !urls.isEmpty else { selectionIndexes = [];return }
        var parents: [String:URL] = [:]
        let paths = Set(urls.map { selectionPath($0,parents:&parents) })
        selectionIndexes = IndexSet(visibleEntries.indices.filter { paths.contains(selectionPath(visibleEntries[$0].url,parents:&parents)) })
    }
    func applyFilter() {
        do {
            let selection = Set(selectedURLs)
            let filter = try NameFilter(filterField.stringValue, regex: filterRegex.state == .on)
            visibleEntries = FileSystem.sorted(entries.filter { filter.matches($0.name) }, key: sortKey, ascending: ascending,foldersFirst:foldersFirst)
            filterField.textColor = .labelColor;syncingSelection = true;table.reloadData();grid.reloadData();syncingSelection = false;select(selection)
            let keys = ["name","ext","size","modified","kind","attributes","permissions","path"]
            sortMode.selectItem(at:keys.firstIndex(of:sortKey) ?? 0);sortDirection.toolTip = ascending ? "Aufsteigend · Klicken für absteigend" : "Absteigend · Klicken für aufsteigend"
        } catch { filterField.textColor = .systemRed; status.stringValue = "Ungültiger regulärer Ausdruck" }
    }
    func clearFilter() { filterField.stringValue = ""; applyFilter() }
    @objc func filterChanged() { activate(); applyFilter() }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === filterField { filterChanged() } }
    func updateStatus() {
        let chosen = selectionIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil }
        let total = chosen.filter { !$0.isDirectory }.reduce(Int64(0)) { $0+$1.size }
        let prefix = readOnly ? "Archiv · " : ""
        status.stringValue = "\(prefix)\(visibleEntries.count) Objekte · \(chosen.count) ausgewählt" + (chosen.isEmpty ? "" : " · \(bytes(total))")
        onSelection?(selectedURLs)
    }
    @objc func doubleClick() { guard table.clickedRow >= 0 else { return }; openSelection() }
    func openSelection() {
        guard let url = selectedURLs.first, let entry = try? FileEntry(url: url) else { return }
        if entry.isDirectory && !entry.isPackage { navigate(url) }
        else if ArchiveService.isArchive(url) { onOpenArchive?(url,self) }
        else { NSWorkspace.shared.open(url) }
    }
    @objc func contextCommand(_ sender: NSMenuItem) { if let command = sender.representedObject as? String { onCommand?(command) } }
    @objc func toggleColumn(_ sender: NSMenuItem) { if let c = sender.representedObject as? NSTableColumn, c.identifier.rawValue != "name" { c.isHidden.toggle(); sender.state = c.isHidden ? .off : .on;rememberTabView() } }
    func numberOfRows(in tableView: NSTableView) -> Int { visibleEntries.count }
    func tableViewSelectionDidChange(_ notification: Notification) { if !syncingSelection { updateStatus() } }
    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !changingView,let d = tableView.sortDescriptors.first else { return }; sortKey = d.key ?? "name"; ascending = d.ascending; applyFilter();rememberTabView()
    }
    func tableViewColumnDidResize(_ notification: Notification) { if defaultView != nil { rememberTabView() } }
    func tableViewColumnDidMove(_ notification: Notification) { if defaultView != nil { rememberTabView() } }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleEntries.indices.contains(row), let tableColumn else { return nil }
        let e = visibleEntries[row], id = tableColumn.identifier.rawValue
        if id == "name" {
            let cell = NSTableCellView(); let image = NSImageView(); let text = label(e.name, size: 12)
            text.font = listFont
            text.textColor = importedProfile?.foreground?.nsColor ?? .labelColor
            if let rule = importedProfile?.fileColors.first(where:{$0.matches(e.name)}) { text.textColor = rule.color.nsColor }
            let iconSize: CGFloat = thumbnails ? 40 : 18
            image.frame = NSRect(x: 2,y: thumbnails ? 6 : 3,width: iconSize,height: iconSize)
            image.image = fileIcon(e,preview:thumbnails)
            text.frame = NSRect(x: iconSize+9,y: thumbnails ? 16 : 3,width: max(30,tableColumn.width-iconSize-14),height: 19); text.autoresizingMask = [.width]
            cell.addSubview(image); cell.addSubview(text); cell.imageView = image; cell.textField = text
            cell.toolTip = e.url.path + (e.isSymbolicLink ? " (Verknüpfung)" : ""); return cell
        }
        let value: String
        switch id {
        case "ext": value = e.fileExtension
        case "size": value = e.isDirectory ? "—" : bytes(e.size)
        case "modified": value = displayDate.string(from: e.modified)
        case "kind": value = e.kind
        case "permissions": value = String(format: "%03o",e.permissions)
        case "attributes":
            value = e.attributeText
        case "path": value = e.url.deletingLastPathComponent().path
        default: value = ""
        }
        let text = label(value, size: 11, color: .secondaryLabelColor)
        if let profile = importedProfile { text.font = listFont; text.textColor = profile.foreground?.nsColor ?? .secondaryLabelColor }
        if id == "attributes" { text.toolTip = "macOS: D Ordner, L Verknüpfung, H versteckter Name, R ohne Besitzer-Schreibbit" }
        if id == "size" { text.alignment = .right }; return text
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { visibleEntries[row].url as NSURL }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard !readOnly else { return [] }; tableView.setDropRow(-1, dropOperation: .on); return .copy
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        acceptFiles(info.draggingPasteboard)
    }
    var savedTabs: [SavedTab] { tabs.filter { $0.archiveRoot == nil && $0.collection == nil }.map { SavedTab(path:$0.url.path,title:$0.title,locked:$0.locked,view:$0.view,selected:tabIndex > 0 && $0 === tab ? true : nil) } }
}

final class TreeNode {
    let url: URL; var children: [TreeNode]?
    init(_ url: URL) { self.url = url }
    func load() -> [TreeNode] {
        if let children { return children }
        let items = ((try? FileSystem.list(url, showHidden: false)) ?? []).filter { $0.isDirectory && !$0.isSymbolicLink && !$0.isPackage }
        let value = FileSystem.sorted(items).map { TreeNode($0.url) }; children = value; return value
    }
}
final class FolderTree: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    var roots = [TreeNode(FileManager.default.homeDirectoryForCurrentUser), TreeNode(URL(fileURLWithPath:"/Volumes")), TreeNode(URL(fileURLWithPath:"/"))]
    var onChoose: ((URL) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); let c = NSTableColumn(identifier: .init("tree")); c.width = 165
        outline.addTableColumn(c); outline.outlineTableColumn = c; outline.headerView = nil; outline.rowHeight = 24
        outline.delegate = self; outline.dataSource = self; outline.target = self; outline.doubleAction = #selector(choose)
        documentView = outline; hasVerticalScroller = true; autohidesScrollers = true
    }
    required init?(coder: NSCoder) { fatalError() }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? TreeNode)?.load().count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? TreeNode)?.load()[index] ?? roots[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { true }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TreeNode else { return nil }; return label(node.url.path == "/" ? "Macintosh HD" : node.url.lastPathComponent, size: 11)
    }
    @objc func choose() { guard outline.clickedRow >= 0 else { return }; if let item = outline.item(atRow: outline.clickedRow) as? TreeNode { onChoose?(item.url) } }
}
