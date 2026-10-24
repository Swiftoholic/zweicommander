import AppKit
import CommanderCore

extension AppDelegate {
    func runLayoutSmoke(root:URL,prefix:String,reload:Bool) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("LAYOUT UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("LAYOUT SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<350 { if predicate() { return };try? await Task.sleep(nanoseconds:40_000_000) };print("LAYOUT SMOKE FAIL timeout "+name);exit(1)
            }
            let main = self.main!,left = main.left,right = main.right,w = require(main.window,"main window"),boardChange = NSPasteboard.general.changeCount
            let folder = root.appendingPathComponent("Links"),a = folder.appendingPathComponent("A"),b = folder.appendingPathComponent("B"),destination = root.appendingPathComponent("Rechts"),offline = root.appendingPathComponent("NichtVerbunden")
            func same(_ first:URL,_ second:URL) -> Bool { FileSystem.canonical(first) == FileSystem.canonical(second) }
            @MainActor func settle() async { await wait("listings") { !left.isLoading && !left.isSorting && !right.isLoading && !right.isSorting } }
            @MainActor func activate(_ value:NSWindow) async { value.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active window") { NSApp.isActive && value.isKeyWindow } }
            @MainActor func event(_ window:NSWindow,_ text:String,_ modifiers:NSEvent.ModifierFlags) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:text == "\r" ? 36 : 0),"key event") }
            @MainActor func menu(_ text:String,_ modifiers:NSEvent.ModifierFlags) -> Bool { NSApp.mainMenu?.performKeyEquivalent(with:event(w,text,modifiers)) == true }
            @MainActor func manager() async -> LayoutProfilesController {
                await activate(w);main.active.focus();check(menu("l",[.command,.option]),"workspace manager shortcut dispatches")
                let form = require(main.secondaryWindows.last as? LayoutProfilesController,"workspace manager");await activate(require(form.window,"manager window"));return form
            }
            @MainActor func preview(_ form:LayoutProfilesController) async { await wait("workspace preview") { form.preview != nil && !form.availability.isEmpty } }
            @MainActor func capture(_ form:LayoutProfilesController,_ suffix:String) -> NSBitmapImageRep {
                let view = require(form.window?.contentView,"layout content");view.layoutSubtreeIfNeeded();view.displayIfNeeded();let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"layout bitmap");view.cacheDisplay(in:view.bounds,to:bitmap)
                do { try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+suffix+".png")) } catch { check(false,"capture") };return bitmap
            }
            @MainActor func readableHeaders(_ bitmap:NSBitmapImageRep,_ form:LayoutProfilesController,light:Bool) -> Bool {
                let view = require(form.window?.contentView,"layout content")
                return [form.table,form.folders].allSatisfy { table in
                    guard let header = table.headerView else { return false };let rect = view.convert(NSRect(x:5,y:3,width:60,height:16),from:header);var pixels = 0
                    for x in Int(rect.minX)..<Int(rect.maxX) { for y in Int(rect.minY)..<Int(rect.maxY) { if let color = bitmap.colorAt(x:x,y:Int(view.bounds.height)-y-1),color.alphaComponent > 0.99 { let l = CommanderPalette.luminance(color);if light ? l < 0.25 : l > 0.6 { pixels += 1 } } } };return pixels > 20
                }
            }
            await settle();await activate(w);main.active.focus();w.title = "ZweiCommander · Arbeitsbereiche prüfen"
            do {
                if reload {
                    check(left.tabs.count == 2 && same(left.currentURL,offline),"unavailable selected tab survives a new process")
                    check(left.tab.lockMode == .fixed && left.tab.filter == "*.txt","offline tab retains its lock mode and filter")
                    check(right.tab.lockMode == .closeOnly && right.filterRegex.state == .on && right.filterField.stringValue == "Plan|Lesen","active tab filter and close-only lock survive restart")
                    check(!main.content.split.isVertical && left.isHidden && !right.isHidden && main.active === right,"orientation single-right pane and active side survive restart")
                    check(abs(main.content.preferredSplitRatio-0.62) < 0.01 && main.content.quickVisible && main.linked,"split ratio quick preview and linked navigation survive restart")
                    check(left.displayMode == .icons && left.treeVisible,"selected unavailable tab keeps view and tree")
                    let library = try Preferences.layouts();check(library.profiles.count == 1 && library.profiles[0].name == "Arbeit","workspace library survives a new process")
                    let frame = require((try Preferences.lastLayout())?.frame,"last frame"),actual = w.frame
                    check(abs(actual.width-frame.width) < 2 && abs(actual.height-frame.height) < 2,"normal restart restores window size")
                    check(menu("1",[.command,.control]),"workspace slot shortcut dispatches after restart");await settle()
                    check(same(left.currentURL,b) && left.filterField.stringValue == "*.md","workspace shortcut restores the selected tab and filter")
                    check(left.tabs.contains { same($0.url,offline) && $0.lockMode == .fixed },"switching workspace preserves the existing locked offline tab")
                    check(right.tab.lockMode == .closeOnly && main.active === right,"workspace shortcut retains protected right tab and active side")
                    let form = await manager();await preview(form);check(form.open.isEnabled && form.table.numberOfRows == 1,"reloaded workspace opens in its manager");form.close()
                } else {
                    check((try Preferences.layouts()).profiles.isEmpty,"workspace tests start in an isolated empty library")
                    var legacy = SavedState();legacy.left = [SavedTab(path:a.path,title:"Alt",locked:true,view:nil,selected:nil)]
                    let legacyData = try JSONEncoder().encode(legacy),decoded = require(Preferences.decode(legacyData),"legacy session")
                    let legacyPane = PaneView(url:folder,savedTabs:decoded.left)
                    check(legacyPane.tab.lockMode == .newTab && legacyPane.tab.title == "Alt","legacy session locks migrate to new-tab protection without losing tab names")
                    var futureSession = try JSONSerialization.jsonObject(with:legacyData) as! [String:Any],futureTabs = futureSession["left"] as! [[String:Any]];futureTabs[0]["lockMode"] = "future-mode";futureSession["left"] = futureTabs
                    let unknown = require(Preferences.decode(try JSONSerialization.data(withJSONObject:futureSession)),"future tab mode")
                    let unknownPane = PaneView(url:folder,savedTabs:unknown.left)
                    check(unknownPane.tab.lockMode == .newTab && same(unknownPane.currentURL,a),"unknown session lock modes preserve the legacy protective lock and location")
                    left.focus();let originalID = left.tab.id;main.command("tabCloseLock");main.command("closeTab")
                    check(w.isVisible && left.tabs.count == 1,"last protected tab cannot close the file window through Command W")
                    let available = (main.content.split.isVertical ? main.content.split.bounds.width : main.content.split.bounds.height)-main.content.split.dividerThickness
                    main.content.split.setPosition(available*0.57,ofDividerAt:0)
                    check(abs(main.content.preferredSplitRatio-0.57) < 0.01,"native divider movement updates the stored split ratio")
                    w.setContentSize(NSSize(width:1140,height:720));main.content.layoutSubtreeIfNeeded()
                    try? await Task.sleep(nanoseconds:350_000_000)
                    check(abs(main.content.preferredSplitRatio-0.57) < 0.01,"resizing the window preserves the chosen split ratio")
                    check(abs(((try Preferences.lastLayout())?.ratio ?? 0)-0.57) < 0.01,"native resize callbacks automatically persist the current arrangement")
                    left.navigate(a);await settle()
                    check(left.tab.id == originalID && left.tab.lockMode == .closeOnly && same(left.currentURL,a),"close-only lock permits navigation in the same tab")
                    left.newTab(url:folder);left.selectTab(originalID);left.closeTab();check(left.tabs.contains { $0.id == originalID },"close-only lock prevents closing")
                    main.command("tabUnlock");left.navigate(folder);await settle();main.command("tabFixedLock")
                    let fixedHistory = left.tab.history,fixedPosition = left.tab.position,count = left.tabs.count;left.navigate(a)
                    check(left.tab.id == originalID && same(left.currentURL,folder) && left.tabs.count == count,"fixed folder lock refuses a different location")
                    left.history(-1);check(left.tab.history == fixedHistory && left.tab.position == fixedPosition,"fixed folder lock refuses history navigation without moving its cursor")
                    left.newTab(url:a);await settle();check(left.tab.id != originalID && left.tab.lockMode == .none,"explicit new tab remains possible next to a fixed tab")
                    left.closeTab();left.selectTab(originalID);main.command("tabNewLock");let oldHistory = left.tab.history;left.navigate(a);await settle()
                    check(left.tab.id != originalID && left.tabs.first(where:{ $0.id == originalID }).map { same($0.url,folder) } == true,"new-tab lock routes folder navigation to another tab")
                    check(left.tabs.first(where:{ $0.id == originalID })?.history == oldHistory,"new-tab lock preserves original navigation history")
                    left.closeTab();left.selectTab(originalID);main.command("lockTab");check(left.tab.lockMode == .none,"legacy lock toggle safely unlocks a protected tab")
                    left.newTab(url:a);await settle();let first = left.tab;left.filterField.stringValue = "*.txt";left.applyFilter();left.newTab(url:b);await settle()
                    check(left.filterField.stringValue.isEmpty,"new tab starts with its own empty filter")
                    left.selectTab(first.id);await settle();check(left.filterField.stringValue == "*.txt" && left.visibleEntries.map(\.name) == ["Plan.txt"],"switching tabs restores each tab filter and actual results")
                    left.filterField.stringValue = "[.]md$";left.filterRegex.state = .on;left.applyFilter();main.command("copyTabToOther");await settle()
                    check(right.filterField.stringValue == "[.]md$" && right.filterRegex.state == .on && right.visibleEntries.map(\.name) == ["Plan.md"],"copying a tab preserves its regex filter")
                    left.duplicateTab();await settle();check(left.filterRegex.state == .on && left.filterField.stringValue == "[.]md$","duplicating a tab preserves its filter")
                    let pinned = FolderTab(a);pinned.title = "Quellen";pinned.lockMode = .fixed;pinned.view = .init(display:.icons,sortKey:"modified",ascending:false,treeVisible:true);pinned.sessionViewPinned = true
                    let selected = FolderTab(b);selected.title = "Texte";selected.view = .init(display:.details,sortKey:"name");selected.sessionViewPinned = true;selected.filter = "*.md"
                    left.tabs = [pinned,selected];left.tabIndex = 1;left.restoreTabView();left.rebuildTabs();left.refresh()
                    let rightTab = FolderTab(destination);rightTab.lockMode = .closeOnly;rightTab.view = .init(display:.thumbnails);rightTab.sessionViewPinned = true
                    right.tabs = [rightTab];right.tabIndex = 0;right.restoreTabView();right.rebuildTabs();right.refresh();await settle()
                    var layout = WorkspaceLayout();layout.vertical = false;layout.ratio = 0.62;layout.presentation = .right;layout.active = .right;layout.quickVisible = true;layout.linked = true;layout.frame = WorkspaceFrame(x:w.frame.minX,y:w.frame.minY,width:1100,height:740)
                    try main.applyLayout(layout);main.saveState();check(left.isHidden && !right.isHidden && main.active === right,"single-pane layout shows the saved active right side")
                    right.onSwitch?();check(main.active === right,"Tab does not move keyboard focus into a hidden pane")
                    main.command("onePane");main.content.layoutSubtreeIfNeeded();check(!left.isHidden && !right.isHidden,"single-pane toggle restores both sides")
                    main.command("onePane");main.content.layoutSubtreeIfNeeded();check(left.isHidden && main.active === right,"single-pane toggle follows the active side")
                    left.tabIndex = 0;left.restoreTabView();left.layoutSubtreeIfNeeded()
                    let flow = require(left.grid.collectionViewLayout as? NSCollectionViewFlowLayout,"icon layout")
                    check(flow.itemSize.width+flow.sectionInset.left+flow.sectionInset.right < left.grid.bounds.width,"hidden icon grid retains valid item dimensions")
                    left.tabIndex = 1;left.restoreTabView();left.rebuildTabs();left.refresh();await settle();right.focus()
                    let form = await manager();form.name.stringValue = "Arbeit";form.saveCurrent();await preview(form)
                    let saved = require(form.selected,"saved workspace");check(saved.left.tabs.count == 2 && saved.left.selected == 1 && saved.right.tabs.count == 1,"workspace captures ordered tabs and selected indices on both sides")
                    check(saved.left.tabs[0].lockMode == .fixed && saved.right.tabs[0].lockMode == .closeOnly && saved.left.tabs[1].filter == "*.md","workspace captures detailed locks views and filters")
                    check((saved.left.tabs+saved.right.tabs).allSatisfy { $0.view.columns?.count == 8 },"workspace captures all columns for active and inactive tabs")
                    check(saved.layout.presentation == .right && saved.layout.active == .right && !saved.layout.vertical && saved.layout.quickVisible && saved.layout.linked,"workspace captures full arrangement and preview state")
                    check(abs(saved.layout.ratio-0.62) < 0.01 && saved.layout.frame?.width == 1100,"workspace captures split ratio and window geometry")
                    check(form.replace.state == .on && form.geometry.state == .on && form.folders.numberOfRows == 3,"workspace manager shows both panes and explicit restore choices")
                    let fw = require(form.window as? WorkflowWindow,"workflow window");check(fw.performKeyEquivalent(with:event(fw,"l",.command)) && form.name.currentEditor() != nil,"workspace Command L focuses the name editor")
                    let ids = left.tabs.map(\.id);main.command("workspace1");check(left.tabs.map(\.id) == ids,"workflow blocks hidden workspace hotkeys")
                    form.name.stringValue = "Zwischenname";form.renameSelected();await preview(form);check(form.selected?.name == "Zwischenname","workspace rename preserves stored layout")
                    form.name.stringValue = "Zweiter";form.saveCurrent();await preview(form);let secondID = form.selectedID;form.move(-1);await preview(form)
                    check(form.library.profiles.first?.id == secondID,"workspace ordering changes the shortcut slots")
                    form.removeSelected();await preview(form);form.name.stringValue = "Arbeit";form.renameSelected();await preview(form);check(form.library.profiles.count == 1 && form.selected?.id == saved.id,"removing a workspace preserves other profiles and identity")
                    form.updateCurrent();await preview(form);check(form.selected?.left.tabs == saved.left.tabs,"updating workspace stores current tab snapshots")
                    left.filterField.stringValue = "*.txt";left.applyFilter();form.submit();check(form.window?.isVisible == true,"changed tab filter invalidates the workspace preview");await preview(form)
                    left.filterField.stringValue = "*.md";left.applyFilter();form.reload();await preview(form)
                    try Preferences.editLayouts { library in var value = library.profiles[0];value.name = "Extern";try library.put(value) };form.submit();check(form.window?.isVisible == true,"externally changed workspace invalidates the preview");await preview(form)
                    form.name.stringValue = "Arbeit";form.renameSelected();await preview(form)
                    Preferences.state.theme = 1;main.applyTheme();try? await Task.sleep(nanoseconds:150_000_000);let light = capture(form,"-Arbeitsbereiche-Hell")
                    check(readableHeaders(light,form,light:true),"light workspace manager has readable column headers")
                    Preferences.state.theme = 2;main.applyTheme();try? await Task.sleep(nanoseconds:150_000_000);let dark = capture(form,"-Arbeitsbereiche-Dunkel")
                    check(readableHeaders(dark,form,light:false),"dark workspace manager has readable column headers");form.close();await activate(w);right.focus()
                    let collection = FolderTab(folder);collection.collection = [a];let archive = FolderTab(main.cache);archive.archiveRoot = main.cache
                    let connection = try RemoteConnection(kind:.ftp,host:"127.0.0.1",user:"fixture",password:"synthetic-layout-only",port:9),server = FolderTab(URL(string:"ftp://127.0.0.1/")!);server.remote = RemoteFolderSession(connection)
                    left.tabs.append(contentsOf:[collection,archive]);right.tabs.append(server);left.newTab(url:folder);await settle();right.focus()
                    let restore = try Preferences.layouts().profiles[0];try main.applyWorkspace(restore);await settle()
                    check(left.tabs.contains { $0 === pinned } && right.tabs.contains { $0 === rightTab },"workspace switch reuses matching locked tabs")
                    check(left.tabs.contains { $0 === collection } && left.tabs.contains { $0 === archive } && right.tabs.contains { $0 === server },"workspace switch preserves collections archive and server tabs")
                    let leftCount = left.tabs.count,rightCount = right.tabs.count;try main.applyWorkspace(restore);await settle()
                    check(left.tabs.count == leftCount && right.tabs.count == rightCount,"repeated workspace switching does not accumulate duplicate protected tabs")
                    check(left.closedTabs.contains { same($0.url,folder) },"replaced ordinary tabs remain in session reopen history")
                    check(menu("1",[.command,.control]),"Command Control 1 activates the first workspace slot");await settle();check(same(left.currentURL,b) && main.active === right,"workspace keyboard switch restores active tabs and focus")
                    var misplaced = restore;misplaced.layout.frame = WorkspaceFrame(x:50_000,y:50_000,width:1400,height:950);try main.applyWorkspace(misplaced);await settle()
                    check(NSScreen.screens.contains { $0.visibleFrame.intersection(w.frame).width >= min(w.frame.width,$0.visibleFrame.width)-2 },"workspace from an absent monitor is placed on a current screen")
                    try main.applyWorkspace(restore);await settle();await activate(w);right.focus();right.beginPathEditing()
                    check(main.workspaceCommandEnabled("workspace1") == false,"address draft disables workspace switching")
                    do { try main.applyWorkspace(restore);check(false,"workspace apply refuses uncommitted address input") } catch { check(true,"workspace apply refuses uncommitted address input") };right.endPathEditing();right.focus()
                    let good = require(Preferences.layoutTestDefaults?.data(forKey:Preferences.layoutsKey),"workspace data")
                    for data in [Data("{broken".utf8),Data("{\"schemaVersion\":99,\"profiles\":[]}".utf8)] {
                        Preferences.layoutTestDefaults?.set(data,forKey:Preferences.layoutsKey);let damaged = await manager();check(!damaged.save.isEnabled && !damaged.open.isEnabled,"unreadable or future workspace data disables mutation")
                        damaged.name.stringValue = "Kein Ersatz";damaged.saveCurrent();check(Preferences.layoutTestDefaults?.data(forKey:Preferences.layoutsKey) == data,"unreadable or future workspace bytes remain unchanged");damaged.close()
                    }
                    Preferences.layoutTestDefaults?.set(good,forKey:Preferences.layoutsKey);await activate(w);right.focus()
                    let last = require(Preferences.layoutTestDefaults?.data(forKey:Preferences.lastLayoutKey),"last layout data")
                    for data in [Data("{broken".utf8),Data("{\"schemaVersion\":99,\"vertical\":true,\"ratio\":0.5,\"presentation\":\"both\",\"active\":\"left\",\"quickVisible\":false,\"linked\":false}".utf8)] {
                        Preferences.layoutTestDefaults?.set(data,forKey:Preferences.lastLayoutKey);main.saveState();check(Preferences.layoutTestDefaults?.data(forKey:Preferences.lastLayoutKey) == data && main.layoutPersistenceError != nil,"unreadable or future automatic layout is preserved")
                    }
                    Preferences.layoutTestDefaults?.set(last,forKey:Preferences.lastLayoutKey)
                    let missing = FolderTab(offline);missing.lockMode = .fixed;missing.filter = "*.txt";missing.view = .init(display:.icons,treeVisible:true);missing.sessionViewPinned = true
                    left.tabs = [missing,FolderTab(a)];left.tabIndex = 0;left.restoreTabView();left.rebuildTabs();left.refresh()
                    right.tabs = [rightTab];right.tabIndex = 0;rightTab.filter = "Plan|Lesen";rightTab.filterRegex = true;right.restoreTabView();right.rebuildTabs();right.refresh();await settle()
                    try main.applyLayout(layout);main.saveState();let data = try JSONEncoder().encode(Preferences.state);Preferences.layoutTestDefaults?.set(data,forKey:"session")
                    check(left.savedTabs.count == 2 && left.savedTabs.first?.path == offline.path,"automatic session retains unavailable local tabs")
                    check(String(decoding:data,as:UTF8.self).contains("fixed") && !String(decoding:data,as:UTF8.self).contains("synthetic-layout-only"),"automatic session contains lock modes and excludes remote credentials")
                    check((try Preferences.lastLayout())?.presentation == .right,"automatic arrangement is persisted with the session")
                }
            } catch { check(false,error.localizedDescription) }
            check(NSPasteboard.general.changeCount == boardChange,"workspace tests leave general clipboard untouched")
            print("LAYOUT SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
