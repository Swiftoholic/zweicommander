import AppKit
import CommanderCore

extension Preferences {
    static let layoutsKey = "ZweiCommander.layouts.v1",lastLayoutKey = "ZweiCommander.lastLayout.v1"
    static var layoutTestDefaults:UserDefaults?
    private static var layoutDefaults:UserDefaults? { testMode ? layoutTestDefaults : .standard }
    private static var memoryLayouts = LayoutLibrary(),memoryLastLayout:WorkspaceLayout?
    static func layouts() throws -> LayoutLibrary {
        guard let defaults = layoutDefaults else { return memoryLayouts }
        guard let value = defaults.object(forKey:layoutsKey) else { return LayoutLibrary() }
        guard let data = value as? Data else { throw CommanderError.message("Gespeicherte Arbeitsbereiche sind nicht lesbar. Vorhandene Daten bleiben erhalten.") }
        return try LayoutLibrary.decode(data)
    }
    @discardableResult static func editLayouts<T>(_ edit:(inout LayoutLibrary)throws->T) throws -> T {
        var value = try layouts();let result = try edit(&value),data = try value.encoded()
        if let defaults = layoutDefaults { defaults.set(data,forKey:layoutsKey) } else { memoryLayouts = value };return result
    }
    static func lastLayout() throws -> WorkspaceLayout? {
        guard let defaults = layoutDefaults else { return memoryLastLayout }
        guard let value = defaults.object(forKey:lastLayoutKey) else { return nil }
        guard let data = value as? Data else { throw CommanderError.message("Die gespeicherte Fensteranordnung ist nicht lesbar und bleibt erhalten.") };return try WorkspaceLayout.decode(data)
    }
    static func saveLastLayout(_ value:WorkspaceLayout) throws {
        _ = try lastLayout();let data = try value.encoded()
        if let defaults = layoutDefaults { defaults.set(data,forKey:lastLayoutKey) } else { memoryLastLayout = value }
    }
}

extension PaneView {
    /// Returns true when the request has been handled without changing this tab's location.
    func routeLockedNavigation(_ destination:URL) -> Bool {
        guard destination != currentURL else { return false }
        switch tab.lockMode {
        case .none,.closeOnly:return false
        case .fixed:
            status.stringValue = "Dieser Tab hält seinen Ordner fest. Sperre im Tabmenü ändern oder einen neuen Tab öffnen.";status.toolTip = currentURL.path;return true
        case .newTab:
            if let remote,!destination.isFileURL { _ = openRemote(remote.connection,path:destination.path) } else { newTab(url:destination) };return true
        }
    }
    func setTabLock(_ mode:TabLockMode) { tab.lockMode = mode;rebuildTabs();status.stringValue = "Tabsperre: "+mode.title }
    func layoutPane() throws -> LayoutPane {
        let group = try groupPane(),local = tabs.filter { $0.remote == nil && $0.archiveRoot == nil && $0.collection == nil && !isSessionTemporary($0.url) }
        let values = zip(local,group.folders).map { item,folder -> LayoutTab in
            var view = folder.view ?? FolderViewSettings();if view.columns == nil { view.columns = viewSettings.columns }
            return LayoutTab(path:folder.path,title:folder.title,lockMode:item.lockMode,view:view,filter:item.id == tab.id ? filterField.stringValue : item.filter,filterRegex:item.id == tab.id ? filterRegex.state == .on : item.filterRegex)
        }
        let pane = LayoutPane(tabs:values,selected:group.selected);try pane.validate();return pane
    }
    func restoreLayoutPane(_ pane:LayoutPane,replacing:Bool) {
        endPathEditing(restoreFocus:false)
        let kept = replacing ? tabs.filter { $0.locked || $0.remote != nil || $0.archiveRoot != nil || $0.collection != nil || isSessionTemporary($0.url) } : tabs
        if replacing { for item in tabs where !kept.contains(where:{ $0 === item }) { rememberClosedTab(item) } }
        var reused = Set<UUID>(),incoming:[FolderTab] = []
        for saved in pane.tabs {
            let item:FolderTab
            if replacing,let existing = kept.first(where:{ $0.locked && $0.remote == nil && $0.archiveRoot == nil && $0.collection == nil && $0.url.standardizedFileURL.path == saved.path && !reused.contains($0.id) }) {
                item = existing;reused.insert(item.id)
            } else { item = FolderTab(URL(fileURLWithPath:saved.path));item.lockMode = saved.lockMode }
            item.title = saved.title;item.view = saved.view;item.sessionViewPinned = true;item.filter = saved.filter;item.filterRegex = saved.filterRegex;incoming.append(item)
        }
        let chosen = incoming[pane.selected]
        tabs = kept.filter { !reused.contains($0.id) }+incoming;tabIndex = tabs.firstIndex { $0 === chosen }!
        restoreTabView();rebuildTabs();refresh()
    }
}

struct LayoutContext:Equatable { let tabs:TabGroupContext,layout:WorkspaceLayout,drafts:[String?] }

extension MainWindow {
    var layoutState:WorkspaceLayout {
        var value = WorkspaceLayout();value.vertical = content.split.isVertical;value.ratio = Double(content.preferredSplitRatio)
        value.presentation = left.isHidden ? .right : right.isHidden ? .left : .both;value.active = active === left ? .left : .right
        value.quickVisible = content.quickVisible;value.linked = linked
        if let frame = window?.frame { value.frame = WorkspaceFrame(x:frame.minX,y:frame.minY,width:frame.width,height:frame.height) };return value
    }
    var layoutContext:LayoutContext { LayoutContext(tabs:TabGroupContext(left:left.tabGroupContext,right:right.tabGroupContext,leftSelected:left.tab.id,rightSelected:right.tab.id),layout:layoutState,drafts:[left.pathField.sessionActive ? left.pathField.stringValue : nil,right.pathField.sessionActive ? right.pathField.stringValue : nil,left.inlineRename.isEditing ? left.inlineRename.field.stringValue : nil,right.inlineRename.isEditing ? right.inlineRename.field.stringValue : nil]) }
    func captureLayout(_ name:String) throws -> LayoutProfile {
        let value = LayoutProfile(name:name,left:try left.layoutPane(),right:try right.layoutPane(),layout:layoutState);try value.validate();return value
    }
    func applyLayout(_ layout:WorkspaceLayout,geometry:Bool = true) throws {
        try layout.validate();content.split.isVertical = layout.vertical;content.preferredSplitRatio = CGFloat(layout.ratio)
        left.isHidden = layout.presentation == .right;right.isHidden = layout.presentation == .left
        content.quickVisible = layout.quickVisible;linked = layout.linked
        if geometry,let frame = layout.frame {
            let screens = NSScreen.screens.map { let r = $0.visibleFrame;return WorkspaceFrame(x:r.minX,y:r.minY,width:r.width,height:r.height) }
            let fitted = frame.fitted(to:screens);window?.setFrame(NSRect(x:fitted.x,y:fitted.y,width:fitted.width,height:fitted.height),display:true)
        }
        content.firstLayout = true;content.needsLayout = true;content.layoutSubtreeIfNeeded()
        (layout.active == .left ? left : right).focus();updateChromeState()
    }
    func applyWorkspace(_ value:LayoutProfile,replacing:Bool = true,geometry:Bool = true) throws {
        guard !left.pathField.sessionActive,!right.pathField.sessionActive,!left.inlineRename.isEditing,!right.inlineRename.isEditing else { throw CommanderError.message("Offene Pfad- oder Namenseingaben vor dem Arbeitsbereichswechsel abschließen oder abbrechen.") }
        try value.validate();isApplyingWorkspace = true;defer { isApplyingWorkspace = false;saveState() }
        left.restoreLayoutPane(value.left,replacing:replacing);right.restoreLayoutPane(value.right,replacing:replacing)
        try applyLayout(value.layout,geometry:geometry)
        content.status.stringValue = "Arbeitsbereich „\(value.name)“ geöffnet. Nicht verfügbare Ordner bleiben als Tabs erhalten."
    }
    func restoreLastLayout() {
        do { if let layout = try Preferences.lastLayout() { try applyLayout(layout) } } catch { layoutPersistenceError = error.localizedDescription;content.status.stringValue = error.localizedDescription }
    }
    func scheduleLayoutSave() {
        guard layoutPersistenceReady,!isApplyingWorkspace else { return };pendingLayoutSave?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.saveState() };pendingLayoutSave = task;DispatchQueue.main.asyncAfter(deadline:.now()+0.25,execute:task)
    }
    func focusOtherVisiblePane() { if !other.isHidden { other.focus() } }
    func toggleSinglePane() {
        if left.isHidden || right.isHidden { left.isHidden = false;right.isHidden = false } else { left.isHidden = active === right;right.isHidden = active === left }
        content.needsLayout = true;content.layoutSubtreeIfNeeded();active.focus();saveState()
    }
    static let workspaceCommands:Set<String> = Set(["workspaces","tabUnlock","tabCloseLock","tabFixedLock","tabNewLock"]+(1...9).map { "workspace\($0)" })
    func workspaceCommandEnabled(_ id:String) -> Bool? {
        guard Self.workspaceCommands.contains(id) else { return nil }
        guard NSApp.keyWindow === window,!left.pathField.sessionActive,!right.pathField.sessionActive,!left.inlineRename.isEditing,!right.inlineRename.isEditing,!(window?.firstResponder is NSTextView) else { return false }
        if id.hasPrefix("workspace"),let slot = Int(id.dropFirst(9)) { return ((try? Preferences.layouts().profiles.count) ?? 0) >= slot }
        return true
    }
    @discardableResult func handleWorkspaceCommand(_ id:String) throws -> Bool {
        guard workspaceCommandEnabled(id) != nil else { return false };guard workspaceCommandEnabled(id) == true else { return true }
        if id == "workspaces" {
            let form = LayoutProfilesController(capture:{ [weak self] name in guard let self else { throw CommanderError.message("Dateifenster nicht mehr verfügbar.") };return try self.captureLayout(name) },context:{ [weak self] in self?.layoutContext },apply:{ [weak self] value,replace,geometry in try self?.applyWorkspace(value,replacing:replace,geometry:geometry) })
            form.onChange = { [weak self] in self?.onRebuildMenus?() };secondaryWindows.append(form);form.showWindow(nil)
        } else if let mode = ["tabUnlock":TabLockMode.none,"tabCloseLock":.closeOnly,"tabFixedLock":.fixed,"tabNewLock":.newTab][id] { active.setTabLock(mode) }
        else if let slot = Int(id.dropFirst(9)),let library = try? Preferences.layouts(),library.profiles.indices.contains(slot-1) { try applyWorkspace(library.profiles[slot-1]) }
        return true
    }
    func windowDidResize(_ notification:Notification) { scheduleLayoutSave() }
    func windowDidMove(_ notification:Notification) { scheduleLayoutSave() }
}
