import AppKit
import CommanderCore

extension Preferences {
    static let tabGroupsKey = "ZweiCommander.tabGroups.v1"
    static var tabGroupsTestDefaults: UserDefaults?
    private static var testTabGroups = TabGroupLibrary()
    private static var tabGroupsDefaults: UserDefaults? { testMode ? tabGroupsTestDefaults : .standard }
    static func tabGroups() throws -> TabGroupLibrary {
        guard let defaults = tabGroupsDefaults else { return testTabGroups }
        guard let object = defaults.object(forKey:tabGroupsKey) else { return TabGroupLibrary() }
        guard let data = object as? Data else { throw CommanderError.message("Die gespeicherten Tabgruppen sind nicht lesbar. Vorhandene Daten bleiben erhalten.") }
        return try TabGroupLibrary.decode(data)
    }
    @discardableResult static func editTabGroups<Value>(_ edit:(inout TabGroupLibrary)throws->Value) throws -> Value {
        var library = try tabGroups();let value = try edit(&library),data = try library.encoded()
        if let defaults = tabGroupsDefaults { defaults.set(data,forKey:tabGroupsKey) } else { testTabGroups = library };return value
    }
}

extension FolderTab {
    func copyForSession() -> FolderTab {
        let copy = FolderTab(url);copy.title = title;copy.locked = locked;copy.history = history;copy.position = position;copy.view = view;copy.sessionViewPinned = true
        copy.collection = collection;copy.archiveRoot = archiveRoot;copy.archiveOrigin = archiveOrigin
        if let remote { copy.remote = RemoteFolderSession(remote.connection) };return copy
    }
}

extension PaneView {
    var tabGroupContext:[TabSessionState] { tabs.map { TabSessionState(id:$0.id,path:$0.url.absoluteString,title:$0.title,locked:$0.locked,view:$0.id == tab.id ? viewSettings : $0.view,kind:$0.remote != nil ? "remote" : $0.archiveRoot != nil || isSessionTemporary($0.url) ? "archive" : $0.collection != nil ? "collection" : "folder") } }
    func isSessionTemporary(_ url:URL) -> Bool { sessionCacheRoot.map { FileSystem.isInside(url,$0) } ?? false }
    func noteTabActivation() {
        guard tabs.indices.contains(tabIndex) else { return }
        let current = tab.id,live = Set(tabs.map(\.id));recentTabIDs.removeAll { $0 == current || !live.contains($0) };recentTabIDs.insert(current,at:0)
        if remote == nil,tab.archiveRoot == nil,tab.collection == nil { lastLocalTabID = current }
    }
    var lastUsedTabID:UUID? { recentTabIDs.first { id in id != tab.id && tabs.contains { $0.id == id } } }
    func visitLastTab() { if let id = lastUsedTabID { selectTab(id) } }
    func rememberClosedTab(_ value:FolderTab) {
        guard value.remote == nil,value.archiveRoot == nil,!isSessionTemporary(value.url) else { return }
        if value.id == tab.id { value.view = viewSettings;value.sessionViewPinned = true }
        closedTabs.removeAll { $0.id == value.id };closedTabs.append(value)
        if closedTabs.count > 30 { closedTabs.removeFirst(closedTabs.count-30) }
    }
    @discardableResult func reopenLastTab() -> Bool {
        guard let index = closedTabs.lastIndex(where:{ $0.collection != nil || FileSystem.isDirectory($0.url) }) else {
            status.stringValue = "Die geschlossenen Ordner sind derzeit nicht verfügbar. Sie bleiben für später vorgemerkt.";return false
        }
        let value = closedTabs.remove(at:index);tabs.append(value);selectTab(value.id);return true
    }
    func groupPane() throws -> TabGroupPane {
        let local = tabs.filter { $0.remote == nil && $0.archiveRoot == nil && $0.collection == nil && !isSessionTemporary($0.url) }
        let selected = local.firstIndex { $0.id == tab.id } ?? local.firstIndex { $0.id == lastLocalTabID } ?? 0
        let workspace = try? Preferences.workspaceLibrary()
        func snapshot(_ item:FolderTab) -> FolderViewSettings {
            if item.id == tab.id { return viewSettings }
            if !item.sessionViewPinned,let rule = workspace?.view(for:item.url) { return rule.settings }
            return item.view ?? defaultView ?? FolderViewSettings()
        }
        let value = TabGroupPane(folders:local.map { TabGroupFolder(path:$0.url.standardizedFileURL.path,title:$0.title,locked:$0.locked,view:snapshot($0)) },selected:selected)
        return value
    }
    func addGroupPane(_ group:TabGroupPane,replacing:Bool) {
        // The group window has already checked and filtered both panes off the main thread.
        let incoming = group.folders.enumerated().map { index,value -> (Int,FolderTab) in
            let url = URL(fileURLWithPath:value.path)
            let item = FolderTab(url);item.title = value.title;item.locked = value.locked;item.view = value.view;item.sessionViewPinned = value.view != nil;return (index,item)
        }
        guard !incoming.isEmpty else { return }
        endPathEditing(restoreFocus:false)
        if replacing {
            let removed = tabs.filter { !$0.locked && $0.remote == nil && $0.archiveRoot == nil && $0.collection == nil }
            for item in removed { rememberClosedTab(item) }
            let ids = Set(removed.map(\.id));tabs.removeAll { ids.contains($0.id) }
        }
        tabs.append(contentsOf:incoming.map(\.1));let chosen = incoming.first { $0.0 == group.selected }?.1 ?? incoming[0].1
        tabIndex = tabs.firstIndex { $0.id == chosen.id }!;selectTab(chosen.id)
    }
}

extension MainWindow {
    static let tabCommands:Set<String> = ["tabGroups","lastTab","reopenTab","copyTabToOther","openInNewTab","openInOther","openInOtherTab"]
    func tabCommandEnabled(_ id:String) -> Bool? {
        guard Self.tabCommands.contains(id) else { return nil }
        guard NSApp.keyWindow === window,!active.pathField.sessionActive,!(NSApp.keyWindow?.firstResponder is NSTextView) else { return false }
        if id == "lastTab" { return active.lastUsedTabID != nil }
        if id == "reopenTab" { return !active.closedTabs.isEmpty }
        if ["openInNewTab","openInOther","openInOtherTab"].contains(id) {
            guard active.canUseDisplayedEntries,active.remote == nil || active.remoteReady,let entry = active.selectionSeed else { return false }
            return entry.isDirectory && !entry.isPackage && !entry.isSymbolicLink
        }
        return true
    }
    @discardableResult func handleTabCommand(_ id:String) throws -> Bool {
        guard tabCommandEnabled(id) != nil else { return false }
        guard tabCommandEnabled(id) == true else { return true }
        switch id {
        case "lastTab":active.visitLastTab()
        case "reopenTab":_ = active.reopenLastTab()
        case "tabGroups":
            let controller = TabGroupsController(capture:{ [weak self] name in
                guard let self else { throw CommanderError.message("Dateifenster nicht mehr verfügbar.") }
                return TabGroupProfile(name:name,left:try self.left.groupPane(),right:try self.right.groupPane())
            },context:{ [weak self] in TabGroupContext(left:self?.left.tabGroupContext ?? [],right:self?.right.tabGroupContext ?? [],leftSelected:self?.left.tab.id,rightSelected:self?.right.tab.id) },apply:{ [weak self] group,replace in
                guard let self else { return };let source = self.active
                self.left.addGroupPane(group.left,replacing:replace);self.right.addGroupPane(group.right,replacing:replace);source.focus();self.saveState()
            })
            secondaryWindows.append(controller);controller.showWindow(nil)
        case "copyTabToOther":
            let source = active;source.rememberTabView();let copy = source.tab.copyForSession();other.tabs.append(copy);other.selectTab(copy.id);source.focus()
        case "openInNewTab","openInOther","openInOtherTab":
            guard let entry = active.selectionSeed else { return true }
            let source = active,target = id == "openInNewTab" ? active : other
            if let remote = source.remote {
                var view = source.viewSettings;view.treeVisible = false
                let value = target.openRemote(remote.connection,path:entry.url.path);value.view = view;value.sessionViewPinned = true;target.restoreTabView()
            }
            else if let archive = source.tab.archiveRoot {
                let item = FolderTab(entry.url);item.archiveRoot = archive;item.archiveOrigin = source.tab.archiveOrigin;item.view = source.viewSettings;item.sessionViewPinned = true
                target.tabs.append(item);target.selectTab(item.id)
            }
            else if id == "openInOther" { target.navigate(entry.url) } else { target.newTab(url:entry.url) }
            if id != "openInNewTab" { source.focus() }
        default:break
        }
        return true
    }
}
