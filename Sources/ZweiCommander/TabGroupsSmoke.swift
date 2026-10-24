import AppKit
import CommanderCore

extension AppDelegate {
    func runTabGroupsSmoke(root:URL,prefix:String,reload:Bool) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ condition:Bool,_ name:String) { checks += 1;print("TABS UI \(condition ? "PASS" : "FAIL") \(name)");if !condition { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("TABS SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<350 { if predicate() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("TABS SMOKE FAIL timeout "+name);exit(1)
            }
            let main = self.main!,left = main.left,right = main.right,window = require(main.window,"main window"),boardChange = NSPasteboard.general.changeCount
            @MainActor func settle() async { await wait("listings") { !left.isLoading && !left.isSorting && !right.isLoading && !right.isSorting } }
            @MainActor func activate(_ value:NSWindow) async { value.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active window") { NSApp.isActive && value.isKeyWindow } }
            @MainActor func key(_ w:NSWindow,_ character:String,_ modifiers:NSEvent.ModifierFlags) -> NSEvent {
                let text = modifiers.contains(.shift) ? character.uppercased() : character
                return require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:w.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:character == "\r" ? 36 : character == "\t" ? 48 : 0),"key event")
            }
            @MainActor func menu(_ character:String,_ modifiers:NSEvent.ModifierFlags) -> Bool { NSApp.mainMenu?.performKeyEquivalent(with:key(window,character,modifiers)) == true }
            @MainActor func manager() async -> TabGroupsController {
                await activate(window);left.focus();main.command("tabGroups");let form = require(main.secondaryWindows.last as? TabGroupsController,"tab groups")
                await activate(require(form.window,"group window"));return form
            }
            @MainActor func preview(_ form:TabGroupsController) async { await wait("group preview") { form.preview != nil && !form.availability.isEmpty } }
            @MainActor func apply(_ form:TabGroupsController) async { form.submit();await wait("group applied") { form.window?.isVisible == false };await settle() }
            @MainActor func capture(_ form:TabGroupsController,_ suffix:String) -> NSBitmapImageRep {
                let view = require(form.window?.contentView,"group content");view.layoutSubtreeIfNeeded();view.displayIfNeeded()
                let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"group bitmap");view.cacheDisplay(in:view.bounds,to:bitmap)
                do { try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+suffix+".png")) } catch { check(false,"group capture") }
                return bitmap
            }
            @MainActor func readableHeaders(_ bitmap:NSBitmapImageRep,_ form:TabGroupsController,light:Bool) -> Bool {
                let view = require(form.window?.contentView,"group content")
                return [form.table,form.folders].allSatisfy { table in
                    guard let header = table.headerView else { return false };let rect = view.convert(NSRect(x:5,y:3,width:60,height:16),from:header)
                    var pixels = 0
                    for x in Int(rect.minX)..<Int(rect.maxX) { for y in Int(rect.minY)..<Int(rect.maxY) {
                        if let color = bitmap.colorAt(x:x,y:Int(view.bounds.height)-y-1),color.alphaComponent > 0.99 {
                            let luminance = CommanderPalette.luminance(color);if light ? luminance < 0.25 : luminance > 0.6 { pixels += 1 }
                        }
                    } };return pixels > 20
                }
            }
            await settle();await activate(window);left.focus();window.title = "ZweiCommander · Tabgruppen prüfen"
            do {
                if reload {
                    let library = try Preferences.tabGroups();check(library.groups.count == 1,"one group survives a new app process")
                    let group = require(library.groups.first,"saved group")
                    check(group.name == "Arbeitsplatz" && group.left.folders.count == 2 && group.right.folders.count == 1,"both ordered panes survive restart")
                    check(group.left.folders.first?.title == "Projekt" && group.left.folders.first?.locked == true,"tab title and lock survive restart")
                    check(group.left.folders.first?.view?.display == .icons && group.left.selected == 1,"view and chosen tab survive restart")
                    let form = await manager();await preview(form)
                    check(form.open.isEnabled && form.replace.state == .off,"reloaded group defaults to adding tabs")
                    let before = left.tabs.count;await apply(form)
                    check(left.tabs.count == before+2 && left.currentURL.lastPathComponent == "A","reloaded group opens the saved active folder")
                    check(right.tabs.count == 2 && main.active === left,"restart load appends both panes and restores source focus")
                    check(left.tabs.contains { $0.title == "Projekt" && $0.locked && $0.view?.display == .icons },"reloaded group restores named locked tab view")
                    check(NSPasteboard.general.changeCount == boardChange,"reload leaves general clipboard untouched")
                } else {
                    check((try Preferences.tabGroups()).groups.isEmpty,"isolated group store starts empty")
                    let original = left.tab.id,folder = root.appendingPathComponent("Links"),a = folder.appendingPathComponent("A"),b = folder.appendingPathComponent("B")
                    left.newTab(url:a);let aID = left.tab.id;left.tab.title = "Alpha";left.changeDisplay(.icons);left.navigate(b);await settle()
                    let history = left.tab.history;left.newTab(url:folder);let third = left.tab.id;await settle()
                    check(left.lastUsedTabID == aID,"activation remembers the previous tab")
                    check(menu("\t",.control) && left.tab.id == aID,"Control Tab visits the last active tab")
                    check(menu("\t",.control) && left.tab.id == third,"Control Tab toggles between the two last tabs")
                    left.closeTab(aID);await settle();check(left.tab.id == third && left.closedTabs.last?.id == aID,"closing an inactive tab preserves current tab")
                    check(menu("z",[.command,.option]),"reopen shortcut is dispatched")
                    await settle();check(left.tab.id == aID && left.tab.title == "Alpha" && left.tab.history == history,"reopen restores tab identity title and navigation history")
                    check(left.displayMode == .icons,"reopen restores the saved tab view")
                    let closedBefore = left.closedTabs.count,ephemeral = FolderTab(main.cache);ephemeral.archiveRoot = main.cache
                    left.rememberClosedTab(ephemeral);check(left.closedTabs.count == closedBefore,"temporary archive tabs are excluded from closed-tab history")
                    ephemeral.archiveRoot = nil;left.tabs.append(ephemeral)
                    check(!(try left.groupPane()).folders.contains { $0.path == main.cache.path },"cache paths remain excluded even after archive metadata was lost")
                    left.tabs.removeAll { $0 === ephemeral };left.rebuildTabs()
                    left.tab.locked = true;left.closeTab();check(left.tab.id == aID && left.tabs.count == 3,"locked tab cannot be closed")
                    left.tab.locked = false;left.closeTab();await settle();left.newTab(url:root.appendingPathComponent("Vanished"));left.closeTab();await settle()
                    check(left.reopenLastTab() && left.tab.id == aID,"unavailable last folder does not block an earlier closed tab")
                    check(left.closedTabs.contains { $0.url.lastPathComponent == "Vanished" },"unavailable closed tab remains available for later retry")
                    left.selectTab(original);await settle();left.focus();left.focusedEntryURL = a;left.select([a])
                    check(menu("\r",.command),"Command Return opens focused folder in a new tab")
                    await settle();check(FileSystem.canonical(left.currentURL) == FileSystem.canonical(a) && main.active === left,"new-folder tab becomes current on source side")
                    left.selectTab(original);await settle();left.select([a]);left.focusedEntryURL = a;let rightBefore = right.tabs.count
                    check(menu("\r",[.command,.option]),"Command Option Return opens folder on opposite side")
                    await settle();check(right.currentURL == a && right.tabs.count == rightBefore && main.active === left,"opposite open reuses unlocked tab and retains source focus")
                    check(menu("o",[.command,.option]),"opposite new-tab shortcut is dispatched")
                    await settle();check(right.tabs.count == rightBefore+1 && main.active === left,"opposite new-tab action appends without moving source focus")
                    left.changeDisplay(.icons);let view = left.viewSettings;left.tab.title = "Kopie";let copyCount = right.tabs.count
                    check(menu("u",[.command,.option]),"copy-tab shortcut is dispatched")
                    await settle();check(right.tabs.count == copyCount+1 && right.tab.id != left.tab.id && right.tab.title == "Kopie","copy tab gets a new identity and preserves title")
                    check(right.viewSettings == view && main.active === left,"copy tab preserves visible view and source focus")
                    var folderRules = try Preferences.workspaceLibrary();try folderRules.remember(.init(display:.details),folder:folder,includeSubfolders:false);try Preferences.saveWorkspace(folderRules)
                    left.changeDisplay(.icons);main.command("copyTabToOther");await settle()
                    check(right.displayMode == .icons,"explicit copied view takes priority over an automatic folder rule")
                    right.navigate(a);right.navigate(folder);await settle();check(right.displayMode == .details,"navigating to another folder re-enables its automatic view rule")
                    window.makeFirstResponder(left.pathField);left.beginPathEditing();let editCount = right.tabs.count;main.command("copyTabToOther")
                    check(right.tabs.count == editCount && main.tabCommandEnabled("tabGroups") == false,"address draft prevents tab commands")
                    left.endPathEditing();left.focus();await settle()
                    let seed = FolderTab(folder);seed.title = "Projekt";seed.locked = true;seed.sessionViewPinned = true;var icons = FolderViewSettings();icons.display = .icons;seed.view = icons
                    let second = FolderTab(a);second.title = "Quellen";left.tabs = [seed,second];left.tabIndex = 1;left.restoreTabView();left.rebuildTabs();left.refresh()
                    right.tabs = [FolderTab(root.appendingPathComponent("Rechts"))];right.tabIndex = 0;right.restoreTabView();right.rebuildTabs();right.refresh();await settle();left.focus()
                    let form = await manager();form.name.stringValue = "Arbeitsplatz";form.saveCurrent();await preview(form)
                    check(form.library.groups.count == 1 && form.open.isEnabled,"both panes save into a selectable group")
                    let saved = require(form.selected,"saved group")
                    check(saved.left.selected == 1 && saved.left.folders.first?.locked == true && saved.left.folders.first?.view?.display == .icons,"capture retains selected tab lock and actual view")
                    check(form.replace.state == .off && form.folders.numberOfRows == 3,"preview shows all folders and defaults to append")
                    let groupWindow = require(form.window,"workflow window")
                    check((groupWindow as? WorkflowWindow)?.performKeyEquivalent(with:key(groupWindow,"l",.command)) == true && form.name.currentEditor() != nil,"workflow Command L focuses group name")
                    let panesBefore = left.tabs.map(\.id);main.command("reopenTab");main.command("openInOther");check(left.tabs.map(\.id) == panesBefore,"workflow blocks hidden file-pane actions")
                    form.name.stringValue = "Umbenannt";form.renameSelected();await preview(form);check(form.selected?.name == "Umbenannt","rename changes group without replacing folder state")
                    form.name.stringValue = "Zweite Gruppe";form.saveCurrent();await preview(form);check(form.library.groups.count == 2,"second group is added")
                    let secondID = require(form.selectedID,"second group ID");form.move(-1);await preview(form);check(form.library.groups.first?.id == secondID,"groups reorder and selection follows identity")
                    form.removeSelected();await preview(form);check(form.library.groups.count == 1 && form.selected?.id == saved.id,"removing a group preserves other group and live tabs")
                    form.name.stringValue = "Arbeitsplatz";form.renameSelected();await preview(form)
                    let ids = left.tabs.map(\.id);let rightIDs = right.tabs.map(\.id)
                    await apply(form);check(left.tabs.count == ids.count+2 && right.tabs.count == rightIDs.count+1,"default group load appends tabs on both sides")
                    check(left.currentURL == a && main.active === left,"group load restores selected folder and source focus")
                    let replaceForm = await manager();await preview(replaceForm)
                    let collection = FolderTab(folder);collection.collection = [a];collection.title = "Sammlung"
                    left.tabs.append(collection);left.rebuildTabs();let locked = Set(left.tabs.filter(\.locked).map(\.id));replaceForm.reload();await preview(replaceForm)
                    replaceForm.replace.state = .on;replaceForm.modeChanged();await preview(replaceForm);await apply(replaceForm)
                    check(locked.isSubset(of:Set(left.tabs.map(\.id))) && left.tabs.contains { $0.id == collection.id },"replace preserves every locked and collection tab")
                    check(left.tabs.count == locked.count+3 && right.tabs.count == 1,"replace removes only unlocked ordinary tabs before adding group")
                    check(!left.closedTabs.isEmpty,"tabs removed by group replacement can be reopened")
                    let stale = await manager();await preview(stale);let count = left.tabs.count
                    left.tab.title = "Geändert";stale.submit();check(left.tabs.count == count && stale.window?.isVisible == true,"changed tab state requires a fresh preview before applying")
                    await preview(stale);stale.reload();await preview(stale)
                    var changed = try Preferences.tabGroups();var group = require(changed.groups.first,"group");group.name = "Extern";try changed.put(group)
                    Preferences.tabGroupsTestDefaults?.set(try changed.encoded(),forKey:Preferences.tabGroupsKey);stale.submit()
                    check(left.tabs.count == count && stale.window?.isVisible == true,"changed saved group cannot apply stale preview")
                    await preview(stale);stale.name.stringValue = "Arbeitsplatz";stale.renameSelected();await preview(stale)
                    Preferences.state.theme = 1;main.applyTheme();try? await Task.sleep(nanoseconds:150_000_000);let light = capture(stale,"-Tabgruppen-Hell")
                    check(stale.window?.contentView?.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .aqua,"tab groups use full light appearance")
                    check(readableHeaders(light,stale,light:true),"light group preview has readable column titles")
                    Preferences.state.theme = 2;main.applyTheme();try? await Task.sleep(nanoseconds:150_000_000);let dark = capture(stale,"-Tabgruppen-Dunkel")
                    check(stale.window?.contentView?.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua,"tab groups use full dark appearance")
                    check(readableHeaders(dark,stale,light:false),"dark group preview has readable column titles")
                    stale.close();await activate(window);left.focus()
                    let good = require(Preferences.tabGroupsTestDefaults?.data(forKey:Preferences.tabGroupsKey),"stored document")
                    Preferences.tabGroupsTestDefaults?.set(Data("{broken".utf8),forKey:Preferences.tabGroupsKey)
                    let damaged = await manager();check(!damaged.save.isEnabled && !damaged.open.isEnabled,"damaged stored group data disables mutation and loading")
                    damaged.name.stringValue = "Kein Ersatz";damaged.saveCurrent();check(Preferences.tabGroupsTestDefaults?.data(forKey:Preferences.tabGroupsKey) == Data("{broken".utf8),"damaged group document is never overwritten")
                    damaged.close();Preferences.tabGroupsTestDefaults?.set(Data("{\"schemaVersion\":999,\"groups\":[]}".utf8),forKey:Preferences.tabGroupsKey)
                    let future = await manager();check(!future.save.isEnabled,"future stored schema remains protected");future.close();Preferences.tabGroupsTestDefaults?.set(good,forKey:Preferences.tabGroupsKey)
                    let missing = await manager();await preview(missing);var missingLibrary = try Preferences.tabGroups();var missingGroup = require(missingLibrary.groups.first,"group")
                    missingGroup.left.folders = [TabGroupFolder(path:root.appendingPathComponent("NotMounted").path)];missingGroup.left.selected = 0;try missingLibrary.put(missingGroup)
                    Preferences.tabGroupsTestDefaults?.set(try missingLibrary.encoded(),forKey:Preferences.tabGroupsKey);missing.reload();await preview(missing)
                    check(!missing.open.isEnabled && missing.availability.contains(false),"missing entire side disables group load without discarding saved paths")
                    missing.close();Preferences.tabGroupsTestDefaults?.set(good,forKey:Preferences.tabGroupsKey)
                    await activate(window);left.focus();let remembered = left.lastUsedTabID;main.command("swap");right.focus()
                    check(right.lastUsedTabID == remembered,"pane swap preserves tab activation order")
                    check(AppDelegate.parseShortcut("ctrl+tab")?.0 == "\t" && CommandHelp.shortcut("lastTab") == "⌃⇥","tab shortcut parsing and visible help agree")
                    check(try AppDelegate.shortcutOverrides("newTab=\n") == ["newTab":""],"empty shortcut override explicitly disables a default shortcut")
                    do { _ = try AppDelegate.shortcutOverrides("newTab=cmd+q");check(false,"reserved app shortcut rejected") } catch { check(true,"reserved app shortcut rejected") }
                    do { _ = try AppDelegate.shortcutOverrides("newTab=cmd+t\nnewTab=cmd+g");check(false,"duplicate command override rejected") } catch { check(true,"duplicate command override rejected") }
                    do { _ = try AppDelegate.shortcutOverrides("lastTab=cmd+t");check(false,"shortcut collision with another default rejected") } catch { check(true,"shortcut collision with another default rejected") }
                    check(NSPasteboard.general.changeCount == boardChange,"tab and group checks leave general clipboard untouched")
                }
            } catch { check(false,error.localizedDescription) }
            print("TABS SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
