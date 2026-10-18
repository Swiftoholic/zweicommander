import AppKit
import CommanderCore

extension Preferences {
    static let workspaceKey = "ZweiCommander.workspace.v1"
    static var workspaceTestDefaults: UserDefaults?
    private static var workspaceDefaults: UserDefaults? { testMode ? workspaceTestDefaults : .standard }
    static func workspaceLibrary() throws -> WorkspaceLibrary {
        guard let data = workspaceDefaults?.data(forKey:workspaceKey) else { return WorkspaceLibrary(legacyFolders:state.favorites) }
        return try WorkspaceLibrary.decode(data)
    }
    static func saveWorkspace(_ library: WorkspaceLibrary) throws {
        let data = try library.encoded()
        workspaceDefaults?.set(data,forKey:workspaceKey)
        state.favorites = library.favorites.filter { $0.kind == .folder }.map(\.path)
        save()
    }
}

extension PaneView {
    var viewSettings: FolderViewSettings {
        FolderViewSettings(display:displayMode,sortKey:sortKey,ascending:ascending,foldersFirst:foldersFirst,treeVisible:treeVisible,
                           columns:table.tableColumns.map { ViewColumn(id:$0.identifier.rawValue,width:Double($0.width),hidden:$0.isHidden) })
    }
    func applyView(_ value: FolderViewSettings) {
        guard (try? value.validate()) != nil else { return }
        let selection = Set(selectedURLs)
        changingView = true;defer { changingView = false }
        sortKey = value.sortKey;ascending = value.ascending;foldersFirst = value.foldersFirst;treeVisible = value.treeVisible
        if let columns = value.columns {
            // A folder rule must not change the global AppKit column autosave.
            table.autosaveTableColumns = false
            for (index,saved) in columns.enumerated() {
                guard let old = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == saved.id }) else { continue }
                table.moveColumn(old,toColumn:index);let c = table.tableColumns[index];c.width = CGFloat(saved.width);c.isHidden = saved.hidden
            }
        }
        for item in table.headerView?.menu?.items ?? [] { if let c = item.representedObject as? NSTableColumn { item.state = c.isHidden ? .off : .on } }
        table.sortDescriptors = [NSSortDescriptor(key:sortKey,ascending:ascending)]
        displayMode = value.display;table.rowHeight = displayMode == .thumbnails ? 52 : 25
        if displayMode == .icons { grid.frame = scroll.contentView.bounds;scroll.documentView = grid;scroll.hasHorizontalScroller = false }
        else { scroll.documentView = table;scroll.hasHorizontalScroller = true }
        viewMode.selectItem(at:PaneDisplayMode.allCases.firstIndex(of:displayMode) ?? 0)
        applyFilter();select(selection)
    }
    func initializeView() { defaultView = viewSettings;restoreTabView() }
    func restoreTabView() {
        var settings = tab.view ?? defaultView ?? FolderViewSettings()
        if tab.collection == nil && tab.archiveRoot == nil,
           let rule = (try? Preferences.workspaceLibrary())?.view(for:currentURL) { settings = rule.settings }
        applyView(settings)
    }
    func changeDisplay(_ mode: PaneDisplayMode) {
        var value = viewSettings;value.display = mode
        applyView(value);rememberTabView();focus()
    }
    func rememberTabView() { guard !changingView else { return };tab.view = viewSettings;onState?() }
    @objc func viewModeChanged() { changeDisplay(PaneDisplayMode.allCases[viewMode.indexOfSelectedItem]) }
    @objc func sortModeChanged() {
        let keys = ["name","ext","size","modified","kind","attributes","permissions","path"]
        sortKey = keys[sortMode.indexOfSelectedItem];table.sortDescriptors = [NSSortDescriptor(key:sortKey,ascending:ascending)];applyFilter();rememberTabView()
    }
    @objc func sortDirectionChanged() { ascending.toggle();table.sortDescriptors = [NSSortDescriptor(key:sortKey,ascending:ascending)];applyFilter();rememberTabView() }
}
