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
final class FileTable: CommanderTableView {
    weak var pane: PaneView?
    override func updateSurface() { super.updateSurface();if let pane { backgroundColor = pane.palette.list(active:pane.isActive,profile:pane.importedProfile);enclosingScrollView?.backgroundColor = backgroundColor } }
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
    let pathField = PathEditor(frame:.zero)
    let breadcrumb = BreadcrumbBar(frame:.zero)
    let locations = LocationStrip(frame:.zero)
    let filterField = NSSearchField()
    let filterRegex = checkbox(".*")
    let filterBar = CommanderSurface(frame:.zero)
    let filterInfo = label("",size:11)
    let filterClear = ActionButton("Filter aufheben",symbol:"xmark.circle",action:{})
    let stateView = PaneStateView(frame:.zero)
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
    var isActive = false { didSet { if oldValue != isActive { applyImportedAppearance() } } }
    var freeSpace: Int64?
    var foldersFirst = true
    var importedProfile: SettingsProfile?
    private struct ColumnState { let id: String; let title: String; let width: CGFloat; let hidden: Bool }
    private var beforeImport: (columns: [ColumnState], sort: String, ascending: Bool, tree: Bool, foldersFirst: Bool)?
    var sortKey = "name", ascending = true
    var generation = 0
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var filterError: String?
    private var displayedDirectory: URL?
    private var displayedTabID: UUID?
    private var displayedCollection: [URL]?
    private var replacesContents = false
    var canUseDisplayedEntries: Bool { !(isLoading && replacesContents) && loadError == nil && filterError == nil }
    var filterActive: Bool { !filterField.stringValue.isEmpty }
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
    var selectedURLs: [URL] { guard canUseDisplayedEntries else { return [] };return selectionIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0].url : nil } }

    init(url: URL, savedTabs: [SavedTab] = []) {
        super.init(frame: .zero)
        wantsLayer = false
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
        table.usesAlternatingRowBackgroundColors = false;table.rowHeight = Preferences.appearanceSettings().rowHeight
        table.style = .plain; table.intercellSpacing = NSSize(width:6,height:0)
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
        pathField.target = self;pathField.action = #selector(pathEntered);pathField.delegate = self;pathField.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        pathField.isEditable = true;pathField.isSelectable = true;pathField.isBordered = true;pathField.drawsBackground = true;pathField.isHidden = true
        pathField.onCancel = { [weak self] in self?.endPathEditing() }
        pathField.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        breadcrumb.setContentHuggingPriority(.defaultLow,for:.horizontal);breadcrumb.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        breadcrumb.onChoose = { [weak self] in self?.navigate($0) };breadcrumb.onEdit = { [weak self] in self?.beginPathEditing() }
        locations.onChoose = { [weak self] in self?.navigate($0) }
        let back = ActionButton("",symbol:"chevron.left") { [weak self] in self?.history(-1) };back.toolTip = "Zurück"
        let forward = ActionButton("",symbol:"chevron.right") { [weak self] in self?.history(1) };forward.toolTip = "Vorwärts"
        let up = ActionButton("",symbol:"arrow.up") { [weak self] in self?.goParent() };up.toolTip = "Übergeordneter Ordner"
        let home = ActionButton("",symbol:"house") { [weak self] in self?.navigate(FileManager.default.homeDirectoryForCurrentUser) };home.toolTip = "Benutzerordner"
        let edit = ActionButton("",symbol:"square.and.pencil") { [weak self] in self?.beginPathEditing() };edit.toolTip = "Pfad bearbeiten · Cmd+L"
        nav.orientation = .horizontal;nav.spacing = 1;nav.detachesHiddenViews = true
        [breadcrumb,pathField].forEach { $0.heightAnchor.constraint(equalToConstant:24).isActive = true;nav.addArrangedSubview($0) }
        for b in [back,forward,up,home,edit] { b.flat = true;b.widthAnchor.constraint(equalToConstant:23).isActive = true;b.heightAnchor.constraint(equalToConstant:24).isActive = true;b.setAccessibilityLabel(b.toolTip);nav.addArrangedSubview(b) }
        tabsStack.orientation = .horizontal; tabsStack.spacing = 1; tabsStack.alignment = .centerY
        tabsScroll.documentView = tabsStack; tabsScroll.hasHorizontalScroller = true; tabsScroll.autohidesScrollers = true;tabsScroll.drawsBackground = false
        viewMode.addItems(withTitles:PaneDisplayMode.allCases.map(\.title));viewMode.target = self;viewMode.action = #selector(viewModeChanged)
        viewMode.toolTip = "Darstellung dieses Tabs"
        sortMode.addItems(withTitles:["Name","Endung","Größe","Geändert","Art","Attribute","Rechte","Ordner"]);sortMode.target = self;sortMode.action = #selector(sortModeChanged)
        sortMode.toolTip = "Sortieren nach"
        sortDirection.perform = { [weak self] in self?.sortDirectionChanged() };sortDirection.toolTip = "Sortierrichtung wechseln"
        viewBar.orientation = .horizontal;viewBar.spacing = 7
        [viewMode,sortMode,sortDirection].forEach { viewBar.addArrangedSubview($0) }
        viewMode.controlSize = .small;sortMode.controlSize = .small;sortDirection.flat = true
        viewMode.font = .systemFont(ofSize:10);sortMode.font = .systemFont(ofSize:10)
        filterField.placeholderString = "Filter · *.pdf";filterField.controlSize = .small;filterField.font = .systemFont(ofSize:11)
        filterField.toolTip = "Schnellfilter: Namensteil oder Wildcards; .* aktiviert reguläre Ausdrücke"
        filterField.delegate = self; filterField.sendsSearchStringImmediately = true
        filterRegex.target = self; filterRegex.action = #selector(filterChanged)
        filterRegex.toolTip = "Reguläre Ausdrücke verwenden";filterRegex.setAccessibilityLabel("Filter als regulären Ausdruck auswerten")
        filterInfo.lineBreakMode = .byTruncatingTail
        filterClear.flat = true;filterClear.font = .systemFont(ofSize:11);filterClear.perform = { [weak self] in self?.clearFilter();self?.focus() }
        filterBar.addSubview(filterInfo);filterBar.addSubview(filterClear);filterBar.isHidden = true;stateView.isHidden = true
        tree.isHidden = true; tree.onChoose = { [weak self] url in self?.navigate(url) }
        [marker,locations,tabsScroll,nav,viewBar,scroll,filterField,filterRegex,status,tree,filterBar,stateView].forEach { addSubview($0) }
        rebuildTabs(); refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { watcher?.cancel() }
    private var appearanceRefresh: DispatchWorkItem?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance();appearanceRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.applyImportedAppearance() };appearanceRefresh = work;DispatchQueue.main.async(execute:work)
    }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { palette.chrome.setFill();bounds.fill(using:.sourceOver) }
    var listFont: NSFont {
        let settings = Preferences.appearanceSettings(),size = settings.fontSize == 0 ? (importedProfile?.fontSize ?? 12) : CGFloat(settings.fontSize)
        return importedProfile.flatMap { NSFont(name:$0.fontName,size:size) } ?? .systemFont(ofSize:size)
    }
    var palette: CommanderPalette { CommanderPalette.current(in:self) }
    func fileTextColor(_ name: String,secondary: Bool = false) -> NSColor {
        let p = palette
        let candidate: NSColor?
        if Preferences.appearanceSettings().importedColors {
            candidate = importedProfile?.fileColors.first(where: { $0.matches(name) })?.color.nsColor ?? (importedProfile?.darkAppearance == p.dark ? importedProfile?.foreground?.nsColor : nil)
        } else { candidate = nil }
        return p.readable(candidate,on:p.list(active:isActive,profile:importedProfile),fallback:secondary ? p.secondaryText : p.text)
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
        applyImportedAppearance()
        table.autosaveTableColumns = !Preferences.testMode
        beforeImport = nil; rebuildColumnMenu(); applyFilter()
    }
    private func rebuildColumnMenu() {
        let columns = NSMenu()
        for c in table.tableColumns { let i = NSMenuItem(title:c.title,action:#selector(toggleColumn(_:)),keyEquivalent:"");i.target = self;i.representedObject = c;i.state = c.isHidden ? .off : .on;columns.addItem(i) }
        table.headerView?.menu = columns
    }
    func applyImportedAppearance() {
        let p = palette,selection = selectionIndexes
        layer?.backgroundColor = p.chrome.cgColor;marker.layer?.backgroundColor = (isActive ? p.accent : p.separator).cgColor
        let background = p.list(active:isActive,profile:importedProfile)
        table.backgroundColor = background;scroll.backgroundColor = background;grid.backgroundColors = [background]
        table.usesAlternatingRowBackgroundColors = false
        table.rowHeight = thumbnails ? max(52,listFont.pointSize+16) : max(Preferences.appearanceSettings().rowHeight,listFont.pointSize+7)
        tree.outline.backgroundColor = background;tree.backgroundColor = background;tree.outline.rowHeight = max(Preferences.appearanceSettings().rowHeight,listFont.pointSize+7)
        breadcrumb.active = isActive;breadcrumb.updateColors()
        status.textColor = p.secondaryText
        syncingSelection = true;table.reloadData();grid.reloadData();syncingSelection = false
        selectionIndexes = selection;table.updateHeaderColors();tabsStack.subviews.forEach { $0.needsDisplay = true };updatePanePresentation();needsDisplay = true
    }
    override func layout() {
        super.layout();let w = bounds.width,h = bounds.height
        marker.frame = NSRect(x:0,y:h-1,width:w,height:1)
        locations.frame = NSRect(x:2,y:h-25,width:max(1,w-4),height:24)
        tabsScroll.frame = NSRect(x:2,y:h-51,width:max(1,w-4),height:25)
        nav.frame = NSRect(x:1,y:h-78,width:max(1,w-2),height:26)
        viewBar.frame = NSRect(x:5,y:h-102,width:max(1,w-10),height:23)
        let treeWidth: CGFloat = treeVisible ? min(165,w*0.32) : 0,filterHeight: CGFloat = filterBar.isHidden ? 0 : 28
        filterBar.frame = NSRect(x:0,y:h-130,width:w,height:28)
        filterInfo.frame = NSRect(x:7,y:4,width:max(1,w-143),height:20)
        filterClear.frame = NSRect(x:w-134,y:2,width:130,height:24)
        tree.frame = NSRect(x:0,y:27,width:treeWidth,height:max(1,h-130-filterHeight))
        scroll.frame = NSRect(x:treeWidth,y:27,width:max(1,w-treeWidth),height:max(1,h-130-filterHeight))
        stateView.frame = NSRect(x:treeWidth,y:27,width:scroll.frame.width,height:max(1,scroll.frame.height-(displayMode == .icons ? 0 : 24)))
        let filterWidth = min(170,max(105,w*0.31))
        filterField.frame = NSRect(x:w-filterWidth-31,y:2,width:filterWidth,height:22)
        filterRegex.frame = NSRect(x:w-29,y:2,width:28,height:22);filterRegex.controlSize = .mini
        status.frame = NSRect(x:5,y:4,width:max(1,w-filterWidth-41),height:18)
    }
    func beginPathEditing() {
        activate();breadcrumb.isHidden = true;pathField.isHidden = false;pathField.stringValue = currentURL.path
        nav.needsLayout = true;window?.makeFirstResponder(pathField);pathField.selectText(nil)
    }
    func endPathEditing() { pathField.isHidden = true;breadcrumb.isHidden = false;nav.needsLayout = true;focus() }
    func activate() { onActivate?(self) }
    func focus() { activate(); window?.makeFirstResponder(displayMode == .icons ? grid : table) }
    func rebuildTabs() {
        tabsStack.arrangedSubviews.forEach { tabsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i,t) in tabs.enumerated() {
            let title = (t.locked ? "🔒 " : "") + (t.title ?? (t.url.lastPathComponent.isEmpty ? "/" : t.url.lastPathComponent))
            let b = FolderTabButton(title:title,tab:t,pane:self)
            b.state = i == tabIndex ? .on : .off; b.toolTip = t.url.path
            b.font = .systemFont(ofSize: 12, weight: i == tabIndex ? .semibold : .regular)
            tabsStack.addArrangedSubview(b)
        }
        let add = ActionButton("",symbol:"plus",action:{ [weak self] in self?.newTab() });add.flat = true;add.toolTip = "Neuer Tab · Cmd+T";add.setAccessibilityLabel("Neuer Tab");tabsStack.addArrangedSubview(add)
        tabsStack.frame = NSRect(origin: .zero, size: NSSize(width: max(180,tabsStack.fittingSize.width),height:25))
        if tabsStack.arrangedSubviews.indices.contains(tabIndex) { tabsStack.scrollToVisible(tabsStack.arrangedSubviews[tabIndex].frame) }
        onState?()
    }
    func newTab(url: URL? = nil) {
        let t = FolderTab(url ?? currentURL);t.view = tab.view
        if let root = tab.archiveRoot, FileSystem.isInside(t.url,root) { t.archiveRoot = root; t.archiveOrigin = tab.archiveOrigin }
        tabs.append(t); tabIndex = tabs.count-1;restoreTabView(); rebuildTabs(); refresh(); focus()
    }
    func closeTab() { closeTab(tab.id) }
    func closeTab(_ id: UUID) {
        guard tabs.count > 1,let index = tabs.firstIndex(where: { $0.id == id }),!tabs[index].locked else { NSSound.beep();return }
        let activeID = tab.id;tabs.remove(at:index)
        tabIndex = tabs.firstIndex(where: { $0.id == activeID }) ?? min(index,tabs.count-1)
        restoreTabView();rebuildTabs();refresh();focus()
    }
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
        navigate(path.hasPrefix("/") ? URL(fileURLWithPath:path) : currentURL.appendingPathComponent(path));endPathEditing()
    }
    private var selectionRequest: (directory: URL,urls: Set<URL>)?
    func reveal(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        guard FileSystem.isDirectory(parent) else { return }
        selectionRequest = (FileSystem.canonical(parent),[url]);navigate(parent)
    }
    func refresh() {
        generation += 1; let g = generation, url = currentURL, hidden = showHidden, collection = tab.collection
        if let request = selectionRequest,request.directory != FileSystem.canonical(url) { selectionRequest = nil }
        let selected = selectionRequest?.urls ?? Set(selectedURLs)
        replacesContents = displayedDirectory != FileSystem.canonical(url) || displayedTabID != tab.id || displayedCollection != collection || loadError != nil
        isLoading = true;loadError = nil
        if replacesContents { entries = [];visibleEntries = [];table.reloadData();grid.reloadData() }
        if pathField.currentEditor() == nil { pathField.stringValue = url.path };breadcrumb.url = url;locations.select(url);pathField.toolTip = readOnly ? "Temporäre Archivansicht · schreibgeschützt" : url.path
        status.stringValue = "Lese Ordner …"
        updatePanePresentation();onSelection?(selectedURLs)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try collection.map { $0.compactMap { try? FileEntry(url:$0) } } ?? FileSystem.list(url,showHidden:hidden) }
            let available = try? url.resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity
            DispatchQueue.main.async {
                guard let self, self.generation == g else { return }
                switch result {
                case .success(let entries): self.isLoading = false;self.displayedDirectory = FileSystem.canonical(url);self.displayedTabID = self.tab.id;self.displayedCollection = collection;self.freeSpace = available.map(Int64.init);self.selectionRequest = nil;self.entries = entries; self.applyFilter(); self.select(selected); self.watch(url)
                case .failure(let error): self.isLoading = false;self.loadError = error.localizedDescription;self.entries = [];self.visibleEntries = [];self.freeSpace = nil;self.table.reloadData();self.grid.reloadData();self.updateStatus()
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
            filterError = nil
            visibleEntries = FileSystem.sorted(entries.filter { filter.matches($0.name) }, key: sortKey, ascending: ascending,foldersFirst:foldersFirst)
            filterField.textColor = .labelColor;syncingSelection = true;table.reloadData();grid.reloadData();syncingSelection = false;select(selection)
            let keys = ["name","ext","size","modified","kind","attributes","permissions","path"]
            sortMode.selectItem(at:keys.firstIndex(of:sortKey) ?? 0);sortDirection.toolTip = ascending ? "Aufsteigend · Klicken für absteigend" : "Absteigend · Klicken für aufsteigend"
        } catch { filterError = "Ungültiger regulärer Ausdruck";filterField.textColor = .systemRed;visibleEntries = [];table.reloadData();grid.reloadData();selectionIndexes = [] }
        updatePanePresentation()
    }
    func clearFilter() { filterField.stringValue = "";filterRegex.state = .off;applyFilter() }
    @objc func filterChanged() { activate(); applyFilter() }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === filterField { filterChanged() } }
    func control(_ control: NSControl,textView: NSTextView,doCommandBy commandSelector: Selector) -> Bool {
        if control === pathField,commandSelector == #selector(NSResponder.cancelOperation(_:)) { endPathEditing();return true }
        return false
    }
    func updateStatus() {
        let chosen = selectionIndexes.compactMap { visibleEntries.indices.contains($0) ? visibleEntries[$0] : nil }
        let total = chosen.filter { !$0.isDirectory }.reduce(Int64(0)) { $0+$1.size }
        let prefix = readOnly ? "Archiv · " : ""
        let count = chosen.isEmpty ? "\(visibleEntries.count) Objekte" : "\(chosen.count)/\(visibleEntries.count) Objekte"
        let size = chosen.isEmpty ? visibleEntries.filter { !$0.isDirectory }.reduce(Int64(0)) { let sum = $0.addingReportingOverflow($1.size);return sum.overflow ? Int64.max : sum.partialValue } : total
        status.stringValue = prefix+count+" · "+bytes(size)+(freeSpace.map { " · Frei "+bytes($0) } ?? "")
        status.toolTip = status.stringValue+" · \(chosen.count) ausgewählt"
        if isLoading { status.stringValue = "Lese Ordner …" }
        else if let loadError { status.stringValue = loadError;status.toolTip = loadError }
        else if let filterError { status.stringValue = filterError }
        updatePanePresentation()
        onSelection?(selectedURLs)
    }
    func updatePanePresentation() {
        let wasHidden = filterBar.isHidden
        filterBar.isHidden = !filterActive && filterError == nil
        filterInfo.stringValue = filterError ?? "Filter aktiv · \(visibleEntries.count) von \(entries.count) Objekten"
        filterInfo.toolTip = "Filter: "+filterField.stringValue
        filterInfo.textColor = filterError == nil ? palette.text : .systemRed
        stateView.background = palette.list(active:isActive,profile:importedProfile)
        stateView.heading.textColor = palette.readable(nil,on:stateView.background)
        stateView.detail.textColor = palette.readable(nil,on:stateView.background,fallback:palette.secondaryText)
        if isLoading && (replacesContents || visibleEntries.isEmpty) { stateView.show("Ordner wird geladen …",detail:"Die Dateiliste wird eingelesen.") }
        else if let loadError { stateView.show("Ordner konnte nicht geöffnet werden",detail:loadError,button:"Erneut versuchen",perform:{ [weak self] in self?.refresh() }) }
        else if let filterError { stateView.show(filterError,detail:"Passe den Ausdruck an oder hebe den Filter auf.",button:"Filter aufheben",perform:{ [weak self] in self?.clearFilter();self?.focus() }) }
        else if visibleEntries.isEmpty && filterActive { stateView.show("Keine Treffer",detail:"Kein angezeigtes Objekt passt zum aktuellen Filter.",button:"Filter aufheben",perform:{ [weak self] in self?.clearFilter();self?.focus() }) }
        else if visibleEntries.isEmpty { stateView.show(tab.collection == nil ? "Ordner ist leer" : "Dateisammlung ist leer",detail:tab.collection != nil ? "Ziehe Dateien in diese Sammlung, um Verweise hinzuzufügen." : showHidden ? "In diesem Ordner sind keine Objekte vorhanden." : "Es sind keine sichtbaren Objekte vorhanden. Versteckte Dateien sind ausgeblendet.") }
        else { stateView.isHidden = true }
        if wasHidden != filterBar.isHidden { needsLayout = true }
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
            let cell = FileCellView(frame:NSRect(x:0,y:0,width:tableColumn.width,height:table.rowHeight));cell.pane = self;let image = NSImageView();let text = label(e.name,size:listFont.pointSize)
            text.font = listFont;cell.normalColor = fileTextColor(e.name);text.textColor = cell.normalColor
            let iconSize: CGFloat = thumbnails ? 40 : 16,textHeight = ceil(listFont.pointSize*1.35)
            image.frame = NSRect(x:2,y:(table.rowHeight-iconSize)/2,width:iconSize,height:iconSize);image.image = fileIcon(e,preview:thumbnails)
            text.frame = NSRect(x:iconSize+7,y:(table.rowHeight-textHeight)/2,width:max(10,tableColumn.width-iconSize-12),height:textHeight);text.autoresizingMask = [.width]
            cell.addSubview(image);cell.addSubview(text);cell.imageView = image;cell.textField = text
            cell.toolTip = e.url.path+(e.isSymbolicLink ? " (Verknüpfung)" : "");return cell
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
        let cell = FileCellView(frame:NSRect(x:0,y:0,width:tableColumn.width,height:table.rowHeight));cell.pane = self;cell.normalColor = fileTextColor(e.name,secondary:true)
        let text = label(value,size:listFont.pointSize,color:cell.normalColor);text.font = listFont
        text.frame = NSRect(x:2,y:(table.rowHeight-ceil(listFont.pointSize*1.35))/2,width:max(1,tableColumn.width-4),height:ceil(listFont.pointSize*1.35));text.autoresizingMask = [.width]
        if id == "attributes" { text.toolTip = "macOS: D Ordner, L Verknüpfung, H versteckter Name, R ohne Besitzer-Schreibbit" }
        if id == "size" { text.alignment = .right };cell.addSubview(text);cell.textField = text;return cell
    }
    func tableView(_ tableView: NSTableView,rowViewForRow row: Int) -> NSTableRowView? { let view = FileRowView();view.pane = self;return view }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? { guard canUseDisplayedEntries,visibleEntries.indices.contains(row) else { return nil };return visibleEntries[row].url as NSURL }
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
