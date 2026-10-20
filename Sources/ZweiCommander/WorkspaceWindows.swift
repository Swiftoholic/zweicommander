import AppKit
import UniformTypeIdentifiers
import CommanderCore

private final class WorkspaceSurface: NSView {
    override init(frame: NSRect) { super.init(frame:frame);wantsLayer = true;updateBackground() }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();updateBackground() }
    private func updateBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = CommanderPalette.current(in:self).chrome.cgColor }
    }
}

final class FavoritesController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let table = CommanderTableView(),name = input(),path = input(),kind = label(""),opensSelection = checkbox("Ausgewählte Dateien mit diesem Programm öffnen")
    let info = label("",size:11,color:.secondaryLabelColor)
    let apply = ActionButton("Übernehmen",action:{}),up = ActionButton("↑",action:{}),down = ActionButton("↓",action:{}),remove = ActionButton("Entfernen",action:{})
    var library = WorkspaceLibrary()
    var selectedID: UUID?
    var onChange: (() -> Void)?
    let currentFolder: URL
    init(folder: URL) {
        currentFolder = folder
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:490),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        w.title = "Favoriten bearbeiten";w.minSize = NSSize(width:820,height:490);w.isReleasedWhenClosed = false
        super.init(window:w)
        let root = WorkspaceSurface(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        let scroll = NSScrollView(frame:NSRect(x:18,y:94,width:380,height:370));scroll.autoresizingMask = [.width,.height]
        for (id,title,width) in [("title","Name",CGFloat(210)),("kind","Typ",120)] { let c = NSTableColumn(identifier:.init(id));c.title = title;c.width = width;table.addTableColumn(c) }
        table.delegate = self;table.dataSource = self;table.rowHeight = 28;table.allowsEmptySelection = true;scroll.documentView = table;scroll.hasVerticalScroller = true;root.addSubview(scroll)
        let editor = form([("Name",name),("Ziel",path),("Typ",kind)],width:385);editor.frame.origin = NSPoint(x:415,y:318);editor.autoresizingMask = [.minXMargin,.minYMargin];root.addSubview(editor)
        opensSelection.frame = NSRect(x:415,y:268,width:385,height:40);opensSelection.autoresizingMask = [.minXMargin,.minYMargin];root.addSubview(opensSelection)
        apply.frame = NSRect(x:674,y:224,width:126,height:30);apply.autoresizingMask = [.minXMargin,.minYMargin];root.addSubview(apply);apply.perform = { [weak self] in self?.saveEditor() }
        let buttons = row([ActionButton("Aktueller Ordner",action:{ [weak self] in guard let self else { return };self.addFavorite(url:self.currentFolder,kind:.folder) }),
                           ActionButton("Ordner …",action:{ [weak self] in self?.choose(.folder) }),ActionButton("Programm …",action:{ [weak self] in self?.choose(.application) }),up,down,remove])
        buttons.frame = NSRect(x:18,y:50,width:784,height:30);root.addSubview(buttons)
        up.perform = { [weak self] in self?.move(-1) };down.perform = { [weak self] in self?.move(1) };remove.perform = { [weak self] in self?.deleteSelected() }
        info.frame = NSRect(x:18,y:14,width:784,height:28);info.autoresizingMask = [.width];info.maximumNumberOfLines = 2;root.addSubview(info)
        reload();w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func reload(select id: UUID? = nil) {
        do {
            library = try Preferences.workspaceLibrary();table.reloadData()
            selectedID = id ?? selectedID
            if let index = library.favorites.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
            else { selectedID = nil;table.deselectAll(nil) }
            loadEditor();info.stringValue = "Name und Ziel mit Übernehmen speichern. Reihenfolge und Entfernen werden sofort gespeichert.";info.textColor = .secondaryLabelColor
        } catch { failed(error);apply.isEnabled = false }
    }
    func failed(_ error: Error) { info.stringValue = error.localizedDescription;info.textColor = .systemRed }
    var selected: WorkspaceFavorite? { library.favorites.first { $0.id == selectedID } }
    func loadEditor() {
        let item = selected;name.stringValue = item?.title ?? "";path.stringValue = item?.path ?? ""
        kind.stringValue = item.map { $0.kind == .folder ? "Ordner" : "Programm" } ?? "Keine Auswahl"
        opensSelection.state = item?.opensSelection == true ? .on : .off;opensSelection.isEnabled = item?.kind == .application
        name.isEnabled = item != nil;path.isEnabled = item != nil;apply.isEnabled = item != nil;remove.isEnabled = item != nil
        let index = library.favorites.firstIndex(where: { $0.id == selectedID })
        up.isEnabled = index.map { $0 > 0 } ?? false;down.isEnabled = index.map { $0+1 < library.favorites.count } ?? false
    }
    func choose(_ kind: FavoriteKind) {
        let panel = NSOpenPanel();panel.canChooseDirectories = kind == .folder;panel.canChooseFiles = kind == .application;panel.allowsMultipleSelection = false
        if kind == .application { panel.allowedContentTypes = [.applicationBundle] }
        if panel.runModal() == .OK,let url = panel.url { addFavorite(url:url,kind:kind) }
    }
    func addFavorite(url: URL,kind: FavoriteKind) {
        do {
            let url = url.standardizedFileURL
            try MainWindow.validateFavoriteTarget(url,kind:kind)
            var value = try Preferences.workspaceLibrary()
            if let existing = value.favorites.first(where: { $0.path == url.path && $0.kind == kind }) { reload(select:existing.id);return }
            let item = WorkspaceFavorite(title:kind == .application ? url.deletingPathExtension().lastPathComponent : (url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent),url:url,kind:kind)
            try value.put(item);try Preferences.saveWorkspace(value);onChange?();reload(select:item.id)
        } catch { failed(error) }
    }
    func saveEditor() {
        guard var item = selected else { return }
        do {
            let url = URL(fileURLWithPath:(path.stringValue as NSString).expandingTildeInPath).standardizedFileURL
            guard path.stringValue.hasPrefix("/") || path.stringValue.hasPrefix("~/") else { throw CommanderError.message("Ein vollständiger Zielpfad wird benötigt.") }
            try MainWindow.validateFavoriteTarget(url,kind:item.kind)
            item.title = name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);item.path = url.path;item.opensSelection = item.kind == .application && opensSelection.state == .on
            var value = try Preferences.workspaceLibrary()
            guard value.favorites.contains(where: { $0.id == item.id }) else { throw CommanderError.message("Dieser Favorit wurde inzwischen entfernt. Liste neu öffnen.") }
            try value.put(item);try Preferences.saveWorkspace(value);onChange?();reload(select:item.id)
        } catch { failed(error) }
    }
    func move(_ offset: Int) {
        guard let id = selectedID else { return }
        do { var value = try Preferences.workspaceLibrary();value.moveFavorite(id,by:offset);try Preferences.saveWorkspace(value);onChange?();reload(select:id) } catch { failed(error) }
    }
    func deleteSelected() {
        guard let id = selectedID else { return }
        do { var value = try Preferences.workspaceLibrary();value.favorites.removeAll { $0.id == id };try Preferences.saveWorkspace(value);selectedID = nil;onChange?();reload() } catch { failed(error) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { library.favorites.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        guard library.favorites.indices.contains(row) else { return nil };let item = library.favorites[row]
        let text = label(tableColumn?.identifier.rawValue == "title" ? item.title : (item.kind == .folder ? "Ordner" : item.opensSelection ? "Programm · Auswahl" : "Programm"))
        text.toolTip = item.path;return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) { selectedID = library.favorites.indices.contains(table.selectedRow) ? library.favorites[table.selectedRow].id : nil;loadEditor() }
}

final class FolderViewsController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let table = CommanderTableView(),scope = checkbox("Auch in Unterordnern anwenden"),info = label("",size:11,color:.secondaryLabelColor)
    let remove = ActionButton("Gespeicherte Ansicht entfernen",action:{})
    var rules: [FolderViewRule] = []
    var onChange: (() -> Void)?
    init() {
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:740,height:420),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.title = "Gespeicherte Ordneransichten";w.isReleasedWhenClosed = false
        super.init(window:w)
        w.contentView = WorkspaceSurface(frame:w.contentView!.bounds)
        let scroll = NSScrollView(frame:NSRect(x:18,y:108,width:704,height:292));scroll.hasVerticalScroller = true;scroll.documentView = table
        for (id,title,width) in [("path","Ordner",CGFloat(440)),("display","Ansicht",220)] { let c = NSTableColumn(identifier:.init(id));c.title = title;c.width = width;table.addTableColumn(c) }
        table.delegate = self;table.dataSource = self;table.rowHeight = 28;w.contentView?.addSubview(scroll)
        scope.frame = NSRect(x:18,y:68,width:360,height:26);scope.target = self;scope.action = #selector(changeScope);w.contentView?.addSubview(scope)
        remove.frame = NSRect(x:430,y:66,width:292,height:30);remove.perform = { [weak self] in self?.deleteSelected() };w.contentView?.addSubview(remove)
        info.frame = NSRect(x:18,y:14,width:704,height:38);info.maximumNumberOfLines = 2;w.contentView?.addSubview(info);reload();w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    var selected: FolderViewRule? { rules.indices.contains(table.selectedRow) ? rules[table.selectedRow] : nil }
    func reload() {
        do {
            rules = try Preferences.workspaceLibrary().views.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending };table.reloadData()
            scope.isEnabled = false;remove.isEnabled = false
            info.stringValue = "Die speziellste passende Ordneransicht hat Vorrang. Neue Ansichten über Ansicht → Ordneransicht merken."
        } catch { info.stringValue = error.localizedDescription;info.textColor = .systemRed }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }
    func tableView(_ tableView: NSTableView,viewFor tableColumn: NSTableColumn?,row: Int) -> NSView? {
        let rule = rules[row];let text = label(tableColumn?.identifier.rawValue == "path" ? rule.path : rule.settings.display.title+(rule.includeSubfolders ? " · Unterordner" : ""))
        text.toolTip = rule.path;return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) { scope.isEnabled = selected != nil;remove.isEnabled = selected != nil;scope.state = selected?.includeSubfolders == true ? .on : .off }
    @objc func changeScope() {
        guard let rule = selected else { return }
        do {
            var value = try Preferences.workspaceLibrary()
            guard let index = value.views.firstIndex(where: { $0.id == rule.id }) else { reload();return }
            value.views[index].includeSubfolders = scope.state == .on;try Preferences.saveWorkspace(value);onChange?();reload()
        } catch { info.stringValue = error.localizedDescription;info.textColor = .systemRed }
    }
    func deleteSelected() {
        guard let rule = selected else { return }
        do { var value = try Preferences.workspaceLibrary();value.views.removeAll { $0.id == rule.id };try Preferences.saveWorkspace(value);onChange?();reload() }
        catch { info.stringValue = error.localizedDescription;info.textColor = .systemRed }
    }
}

extension MainWindow {
    static func validateFavoriteTarget(_ url: URL,kind: FavoriteKind) throws {
        if kind == .folder {
            guard FileSystem.isDirectory(url) else { throw CommanderError.message("Der Zielordner ist nicht verfügbar.") }
        } else {
            guard url.pathExtension.lowercased() == "app",FileSystem.isDirectory(url),(try? url.resourceValues(forKeys:[.isApplicationKey]).isApplication) == true else {
                throw CommanderError.message("Ein vorhandenes macOS-Programm (.app) auswählen.")
            }
        }
    }
    func showFavorites() {
        let controller = FavoritesController(folder:active.currentURL);controller.onChange = { [weak self] in self?.refreshLocations() }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
    func openFavorite(_ id: UUID) throws {
        guard let item = try Preferences.workspaceLibrary().favorites.first(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath:item.path);try Self.validateFavoriteTarget(url,kind:item.kind)
        if item.kind == .folder { active.navigate(url);return }
        let request = try ProgramLaunchRequest(favorite:item,selection:active.selectedURLs)
        if let programLauncher { programLauncher(request);return }
        let configuration = NSWorkspace.OpenConfiguration()
        if request.files.isEmpty {
            NSWorkspace.shared.openApplication(at:request.application,configuration:configuration) { _,error in if let error { DispatchQueue.main.async { showFailure(error) } } }
        } else {
            NSWorkspace.shared.open(request.files,withApplicationAt:request.application,configuration:configuration) { _,error in if let error { DispatchQueue.main.async { showFailure(error) } } }
        }
    }
    func toggleFavorite() throws {
        guard !active.readOnly,!FileSystem.isInside(active.currentURL,cache),active.tab.collection == nil else { throw CommanderError.message("Favoriten benötigen einen normalen, dauerhaften Ordner.") }
        var value = try Preferences.workspaceLibrary()
        if let item = value.favorites.first(where: { $0.kind == .folder && $0.path == active.currentURL.path }) { value.favorites.removeAll { $0.id == item.id } }
        else { let url = active.currentURL;try value.put(WorkspaceFavorite(title:url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,url:url,kind:.folder)) }
        try Preferences.saveWorkspace(value);refreshLocations()
    }
    func rememberFolderView() throws {
        guard active.tab.collection == nil,!active.readOnly,!FileSystem.isInside(active.currentURL,cache) else { throw CommanderError.message("Ordneransichten können nur für normale Ordner gespeichert werden.") }
        let scope = checkbox("Auch in Unterordnern anwenden"),url = active.currentURL,settings = active.viewSettings
        scope.frame = NSRect(x:0,y:0,width:440,height:28)
        if let existing = try Preferences.workspaceLibrary().views.first(where: { $0.path == url.path }) { scope.state = existing.includeSubfolders ? .on : .off }
        if dialog("Ordneransicht merken",message:url.path+"\n\n"+settings.display.title+" · Sortierung, Ordnerbaum und Spalten werden gespeichert.",accessory:scope,buttons:["Speichern","Abbrechen"]) == 0 {
            var value = try Preferences.workspaceLibrary();try value.remember(settings,folder:url,includeSubfolders:scope.state == .on);try Preferences.saveWorkspace(value)
            content.status.stringValue = "Ordneransicht gespeichert";applyFolderViews()
        }
    }
    func applyFolderViews() { for pane in [left,right] { pane.restoreTabView() };saveState() }
    func showFolderViews() {
        let controller = FolderViewsController();controller.onChange = { [weak self] in self?.applyFolderViews() }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
}
