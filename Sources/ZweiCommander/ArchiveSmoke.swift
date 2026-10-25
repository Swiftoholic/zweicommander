import AppKit
import CommanderCore

extension AppDelegate {
    func runArchiveSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("ARCHIVE UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("ARCHIVE SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<750 { if predicate() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("ARCHIVE SMOKE FAIL timeout "+name+" · "+self.main.jobs.scheduler.snapshots.map { $0.state.rawValue+": "+$0.detail }.joined(separator:" | "));exit(1)
            }
            let main = self.main!,left = main.left,right = main.right,window = require(main.window,"main window"),clipboard = NSPasteboard.general.changeCount
            let links = root.appendingPathComponent("Links"),source = links.appendingPathComponent("Quellen"),bundle = links.appendingPathComponent("Bundle.zip"),encrypted = links.appendingPathComponent("Encrypted.zip"),output = root.appendingPathComponent("Rechts")
            @MainActor func activate(_ value:NSWindow) async { value.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active window") { NSApp.isActive && value.isKeyWindow } }
            @MainActor func event(_ value:NSWindow,_ text:String,_ modifiers:NSEvent.ModifierFlags = [],code:UInt16 = 0) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:value.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code),"key event") }
            @MainActor func menu(_ text:String,_ modifiers:NSEvent.ModifierFlags = []) -> Bool { NSApp.mainMenu?.performKeyEquivalent(with:event(window,text,modifiers)) == true }
            @MainActor func configured(_ id:String) -> Bool {
                let fallback = Self.menuDefinitions.flatMap { $0.1 }.first { $0.1 == id }?.2 ?? ""
                guard let key = Self.parseShortcut(Preferences.state.shortcuts[id] ?? fallback) else { return false }
                let code:UInt16 = key.0 == "[" ? 33 : key.0 == "]" ? 30 : key.0 == " " ? 49 : 0
                return NSApp.mainMenu?.performKeyEquivalent(with:event(window,key.0,key.1,code:code)) == true
            }
            @MainActor func select(_ pane:PaneView,_ names:Set<String>) { pane.select(Set(pane.visibleEntries.filter { names.contains($0.name) }.map(\.url))) }
            @MainActor func settle() async { await wait("listings and jobs") { main.jobs.pending == 0 && main.jobs.log.count >= main.jobs.scheduler.snapshots.filter(\.isFinished).count && !left.isLoading && !right.isLoading && !left.isSorting && !right.isSorting } }
            @MainActor func prepared(_ form:ArchiveSetupController) async { await wait("archive preview") { form.prepared != nil && !form.isPreparing } }
            @MainActor func form() async -> ArchiveSetupController { let value = require(main.secondaryWindows.last as? ArchiveSetupController,"archive form");await activate(require(value.window,"form window"));await prepared(value);return value }
            @MainActor func capture(_ view:NSView,_ name:String,_ table:NSTableView,light:Bool) {
                view.layoutSubtreeIfNeeded();view.displayIfNeeded();let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap");view.cacheDisplay(in:view.bounds,to:bitmap)
                do { try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+name+".png")) } catch { check(false,"capture archive window") }
                let header = require(table.headerView,"header"),rect = view.convert(NSRect(x:5,y:3,width:70,height:16),from:header);var pixels = 0
                for x in Int(rect.minX)..<Int(rect.maxX) { for y in Int(rect.minY)..<Int(rect.maxY) { if let color = bitmap.colorAt(x:x,y:Int(view.bounds.height)-y-1),color.alphaComponent > 0.99 { let value = CommanderPalette.luminance(color);if light ? value < 0.25 : value > 0.6 { pixels += 1 } } } }
                check(pixels > 20,light ? "light archive columns remain readable" : "dark archive columns remain readable")
            }
            do {
                let nestedSource = links.appendingPathComponent("NestedSource"),nested = source.appendingPathComponent("inner.zip")
                try ArchiveService.pack([nestedSource],to:nested);try ArchiveService.pack([source],to:bundle)
                _ = try ProcessRunner.run("/usr/bin/zip",arguments:["-q","-P","synthetic-archive-ui",encrypted.path,"secret.txt"],directory:links.appendingPathComponent("EncryptedSource"))
                main.refresh();await settle();await activate(window);left.focus();window.title = "ZweiCommander · Archive prüfen"
                let board = NSPasteboard(name:.init("local.zweicommander.archive-tests."+UUID().uuidString));main.selectionPasteboard = board;defer { board.clearContents() }
                let localID = left.tab.id,localTabs = left.savedTabs.count
                select(left,["Quellen"]);check(menu(String(UnicodeScalar(NSF5FunctionKey)!),.option),"Option F5 opens the native pack preview")
                let pack = await form(),packWindow = require(pack.window as? WorkflowWindow,"pack workflow")
                check(pack.packing && pack.prepared?.rows.contains { $0.path == "Quellen/Docs/lesen.txt" } == true,"pack preview lists actual source descendants")
                check(pack.prepared?.rows.contains { $0.path == "Quellen/Leer" && $0.isDirectory } == true,"pack preview includes empty source directories")
                check(pack.compression.indexOfSelectedItem == Preferences.state.importedProfile?.zipCompressionLevel ?? 6,"pack preview keeps imported ZIP compression")
                check(packWindow.performKeyEquivalent(with:event(packWindow,"l",.command)) && pack.destination.currentEditor() != nil,"Command L focuses the archive destination")
                packWindow.makeFirstResponder(pack.table);pack.format.selectItem(at:1);pack.formatChanged();await prepared(pack)
                check(pack.destination.stringValue.hasSuffix(".7z") && pack.compression.isEnabled,"changing archive format updates the suffix and compression controls")
                pack.format.selectItem(at:2);pack.formatChanged();await prepared(pack);check(pack.destination.stringValue.hasSuffix(".tar.gz") && !pack.compression.isEnabled,"TAR GZip explicitly uses system compression")
                pack.format.selectItem(at:0);pack.formatChanged();pack.destination.stringValue = output.appendingPathComponent("Created.zip").path;pack.prepare();await prepared(pack)
                let hidden = left.tabs.count;main.command("newTab");check(left.tabs.count == hidden,"archive workflow blocks hidden file-pane commands")
                check(!FileSystem.exists(output.appendingPathComponent("Created.zip")),"pack preview does not create an archive")
                check(packWindow.performKeyEquivalent(with:event(packWindow,"\r",.command)),"Command Return submits the archive pack plan")
                await wait("pack form closes") { pack.window?.isVisible == false };await settle()
                check(FileSystem.exists(output.appendingPathComponent("Created.zip")),"native pack plan publishes the chosen archive")
                check((try ArchiveCatalog.read(output.appendingPathComponent("Created.zip"))).member(at:"Quellen/Docs/lesen.txt") != nil,"created archive has the planned contents")
                main.operationWindow?.close();await activate(window);left.selectTab(localID);await settle();select(left,["Bundle.zip"])
                main.showArchivePack([source]);let stale = await form();stale.destination.stringValue = output.appendingPathComponent("Stale.zip").path;stale.prepare();await prepared(stale)
                try Data("new source\n".utf8).write(to:source.appendingPathComponent("added.txt"));stale.submit(true);await wait("stale pack preview") { !stale.isPreparing && stale.prepared != nil }
                check(stale.window?.isVisible == true && !FileSystem.exists(output.appendingPathComponent("Stale.zip")),"changed pack sources require a new preview before submission")
                check(stale.prepared?.rows.contains { $0.path == "Quellen/added.txt" } == true,"refreshed pack preview includes newly added source files");stale.close();await activate(window);left.focus()
                let beforeCache = try FileManager.default.contentsOfDirectory(atPath:main.cache.path)
                check(menu("o",.command),"Command O opens the selected archive")
                await wait("archive tab") { left.archive != nil };await settle();await activate(window);left.focus()
                let session = require(left.archive,"archive session"),archiveTab = left.tab.id
                check(left.tabs.count == localTabs+1 && left.tab.archiveRoot == session.root,"archive opens beside the preserved local tab")
                check(try FileManager.default.contentsOfDirectory(atPath:main.cache.path) == beforeCache,"opening archive reads headers without extracting contents")
                check(left.entries.allSatisfy { !$0.url.isFileURL } && left.entries.contains { $0.name == "Quellen" && $0.isDirectory },"archive entries use virtual addresses and header metadata")
                check(left.savedTabs.count == localTabs && !left.savedTabs.contains { $0.path.contains("zwei-archive") },"archive tabs are excluded from restart state")
                check(left.breadcrumb.components.first?.1.title == "Bundle.zip" && left.locationText.contains("Bundle.zip ▸ /"),"archive address names the container instead of a temporary UUID")
                select(left,["Quellen"]);left.table.keyDown(with:event(window,"\r",code:36));await settle()
                check(session.path(left.currentURL) == "Quellen","Enter navigates within the virtual archive")
                select(left,["Docs"]);left.openSelection();await settle();check(left.visibleEntries.contains { $0.name == "lesen.txt" },"implicit archive folders share the ordinary file list")
                let navigationShortcuts = Preferences.state.shortcuts
                let backMenu = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.representedObject as? String == "back" }
                check(backMenu?.allowsAutomaticKeyEquivalentLocalization == true,"default navigation allows system keyboard localization")
                Preferences.state.shortcuts["back"] = "cmd+[";Preferences.state.shortcuts["forward"] = "cmd+]";self.buildMenus()
                let explicit = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.representedObject as? String == "back" }
                check(explicit?.allowsAutomaticKeyEquivalentLocalization == false,"explicit navigation bindings retain their assigned keys")
                check(configured("back"),"configured shortcut dispatches archive history");await settle();check(session.path(left.currentURL) == "Quellen","archive history returns to the previous internal folder")
                check(configured("forward"),"configured shortcut dispatches forward history");await settle();check(session.path(left.currentURL) == "Quellen/Docs","archive forward history restores the internal path")
                Preferences.state.shortcuts = navigationShortcuts;self.buildMenus()
                left.filterField.stringValue = "*.txt";left.filterChanged();await settle();check(left.visibleEntries.map(\.name) == ["lesen.txt"],"standard wildcard filtering applies to archive entries");left.clearFilter()
                left.changeDisplay(.icons);select(left,["lesen.txt"]);check(!left.grid.selectionIndexPaths.isEmpty,"archive icon view shares real selection identity")
                let entry = require(left.selectionSeed,"archive file"),(_,imageRequest) = left.fileImages.load(entry,preview:true,completion:{ _ in });check(imageRequest == nil,"virtual archive icons do not inspect unrelated local paths");left.changeDisplay(.details)
                check(main.archiveCommandEnabled("rename") == false && main.archiveCommandEnabled("move") == false && main.archiveCommandEnabled("trash") == false,"archive mutation commands remain disabled")
                check(main.archiveCommandEnabled("clipboardCopy") == false && main.archiveCommandEnabled("copyURLs") == false && main.archiveCommandEnabled("copyShellPaths") == false,"archive members are not offered as local clipboard files or shell paths")
                let row = require(left.visibleEntries.firstIndex { $0.name == "lesen.txt" },"selected archive row")
                check(left.tableView(left.table,pasteboardWriterForRow:row) == nil && left.collectionView(left.grid,pasteboardWriterForItemAt:IndexPath(item:row,section:0)) == nil,"archive drag sources do not advertise virtual members as local files")
                main.command("copyPath");check(board.string(forType:.string)?.contains("Bundle.zip ▸ /Quellen/Docs/lesen.txt") == true && board.string(forType:.string)?.contains("zwei-archive") == false,"path copy produces a meaningful archive member address")
                check(menu("l",.command),"Command L starts archive address editing")
                check(left.pathField.currentEditor() is NSTextView && main.archiveCommandEnabled("clipboardCopy") == nil,"archive path editor keeps native text clipboard commands")
                left.pathField.stringValue = "/Quellen/Docs/Sub";left.pathField.submit();await wait("archive path commit") { !left.pathField.sessionActive };await settle()
                check(session.path(left.currentURL) == "Quellen/Docs/Sub","archive address editor resolves internal folders")
                main.content.commandMode.selectItem(at:0);main.content.commandField.stringValue = "..";main.commandEntered();await settle();check(session.path(left.currentURL) == "Quellen/Docs","bottom path field navigates relative archive addresses")
                main.command("tabFixedLock");let fixed = left.currentURL;left.navigate(session.root);check(left.currentURL == fixed,"fixed lock keeps an internal archive folder")
                main.command("tabNewLock");left.navigate(session.root);await settle();check(left.tab.id != archiveTab && left.archive === session,"new-tab lock preserves the original archive tab and session")
                left.closeTab();left.selectTab(archiveTab);main.command("tabUnlock");await settle();select(left,["lesen.txt"])
                var opened:URL?,previewed = false;main.archiveFileHandler = { opened = $0;previewed = $1 }
                check(configured("preview"),"configured preview shortcut dispatches lazy archive preview")
                await wait("materialized preview") { opened != nil };await settle()
                let materialized = require(opened,"preview file")
                check(try previewed && String(contentsOf:materialized,encoding:.utf8) == "archive text\n","preview extracts the selected actual file content")
                check((try FileManager.default.attributesOfItem(atPath:materialized.path)[.posixPermissions] as? NSNumber)?.intValue == 0o400,"preview file is private and read-only")
                check(session.materialized.count == 1 && !FileSystem.exists(materialized.deletingLastPathComponent().appendingPathComponent("skip.bin")),"preview does not unpack unrelated archive members")
                main.command("quickView");await settle()
                check(main.content.quickVisible && (main.content.quick.previewItem as? NSURL)?.path == materialized.path,"side preview lazily displays the selected archive file")
                check(session.materialized.count == 1,"side preview reuses the existing checked member copy")
                select(left,["Sub"]);await settle();check(main.content.quick.previewItem == nil,"selecting an archive folder clears the side preview without extracting it")
                main.command("quickView");select(left,["lesen.txt"]);await settle();await activate(window);left.focus()
                opened = nil;left.openSelection();await wait("archive external open") { opened != nil };check(!previewed && opened == materialized,"opening an archive file reuses its checked temporary copy")
                check(menu(String(UnicodeScalar(NSF5FunctionKey)!)),"F5 opens selected archive extraction")
                let extract = await form(),extractWindow = require(extract.window as? WorkflowWindow,"extract workflow")
                check(!extract.packing && extract.selectedOnly.state == .on && extract.prepared?.rows.map(\.path) == ["lesen.txt"],"F5 preview preserves paths relative to the current archive folder")
                check(extract.password.cell is NSSecureTextFieldCell,"extraction password uses a secure native field")
                check(extract.prepared?.merge != nil && extract.prepared?.destination == output && !FileSystem.exists(output.appendingPathComponent("lesen.txt")),"F5 reviews the existing opposite folder without extracting during preview")
                extract.destination.stringValue = output.appendingPathComponent("Auswahl").path;extract.prepare();await prepared(extract)
                Preferences.state.theme = 1;main.applyTheme();try? await Task.sleep(nanoseconds:150_000_000);capture(require(extract.window?.contentView,"extract content"),"-Entpacken-Hell",extract.table,light:true)
                Preferences.state.theme = 2;main.applyTheme();try? await Task.sleep(nanoseconds:150_000_000);capture(require(extract.window?.contentView,"extract content"),"-Entpacken-Dunkel",extract.table,light:false)
                await activate(extractWindow)
                check(extractWindow.performKeyEquivalent(with:event(extractWindow,"\r",[.command,.shift])),"Command Shift Return queues the extraction plan")
                await wait("queued archive plan") { main.jobs.scheduler.snapshots.contains { $0.state == .waiting } && extract.window?.isVisible == false }
                check(!FileSystem.exists(output.appendingPathComponent("Auswahl")),"queued archive extraction waits for explicit start")
                let queue = require(main.operationWindow,"operation queue"),queueWindow = require(queue.window as? WorkflowWindow,"queue workflow");await activate(queueWindow)
                check(queueWindow.performKeyEquivalent(with:event(queueWindow,"\r")),"Enter starts the selected queued archive job");await settle()
                check((try String(contentsOf:output.appendingPathComponent("Auswahl/lesen.txt"),encoding:.utf8)) == "archive text\n" && !FileSystem.exists(output.appendingPathComponent("Auswahl/Quellen")),"queued extraction publishes only the planned relative file")
                check((try ArchiveCatalog.read(bundle)).member(at:"Quellen/Docs/lesen.txt") != nil,"extracting leaves the source archive unchanged");queue.close();await activate(window);left.focus()
                check(menu(String(UnicodeScalar(NSF6FunctionKey)!),.option),"Option F6 opens archive extraction")
                let all = await form();all.selectedOnly.state = .off;all.optionChanged();await prepared(all)
                check(all.prepared?.rows.contains { $0.path == "Quellen/Docs/skip.bin" } == true,"full extraction preview includes unselected archive contents")
                all.destination.stringValue = output.appendingPathComponent("Auswahl").path;all.prepare();await wait("occupied extraction target") { !all.isPreparing }
                check(all.prepared?.merge != nil && all.start.isEnabled && all.queue.isEnabled,"existing destination prepares a merge when incoming paths have no conflicts")
                let occupiedText = try String(contentsOf:output.appendingPathComponent("Auswahl/lesen.txt"),encoding:.utf8);check(occupiedText == "archive text\n","blocked extraction preserves the existing destination");all.close();await activate(window)
                left.navigate(session.address("Quellen"));await settle();select(left,["inner.zip"]);left.openSelection();await wait("nested archive") { left.archive !== session && left.archive != nil };await settle()
                check(left.archive?.parent === session && left.entries.contains { $0.name == "NestedSource" },"nested archive is opened by extracting only its container member")
                check(left.locationText.contains("Bundle.zip ▸ inner.zip"),"nested address keeps outer and inner container names")
                check(menu(String(UnicodeScalar(NSUpArrowFunctionKey)!),[.command,.option]),"Command Option Up returns to the archive container");await settle()
                check(left.archive === session && session.path(left.currentURL) == "Quellen" && left.selectedURLs.first?.lastPathComponent == "inner.zip","leaving nested archive restores its parent and member selection")
                main.command("sameFolder");await settle();check(right.archive === session && main.active === left,"same-folder command shares the archive session across panes")
                check(main.archiveCommandEnabled("copy") == false,"archive-to-archive mutation is unavailable")
                let rightLocal = require(right.tabs.first { $0.archive == nil && $0.remote == nil },"right local tab");right.selectTab(rightLocal.id);await settle();left.focus()
                left.navigate(session.root);await settle();main.command("parent");await settle();check(left.tab.id == localID && left.selectedURLs.first?.lastPathComponent == "Bundle.zip","parent at archive root restores the original local container tab")
                select(left,["Encrypted.zip"]);left.openSelection();await wait("encrypted archive metadata") { left.archive != nil && left.archive !== session };await settle();select(left,["secret.txt"])
                opened = nil;main.preview(left.selectedURLs);await wait("password prompt") { main.secondaryWindows.contains { $0 is ArchivePasswordController } }
                let passwordForm = require(main.secondaryWindows.last as? ArchivePasswordController,"archive password"),passwordWindow = require(passwordForm.window as? WorkflowWindow,"password workflow");await activate(passwordWindow)
                check(passwordForm.password.cell is NSSecureTextFieldCell,"lazy encrypted preview asks through a secure native form")
                passwordForm.password.stringValue = "synthetic-archive-ui";check(passwordWindow.performKeyEquivalent(with:event(passwordWindow,"\r",.command)),"Command Return retries an encrypted member with the entered password")
                await wait("encrypted file preview") { opened != nil };await settle();check((try String(contentsOf:require(opened,"encrypted preview"),encoding:.utf8)) == "encrypted text\n","correct archive password opens the actual encrypted member")
                let encoded = String(decoding:try JSONEncoder().encode(Preferences.state),as:UTF8.self)
                check(!encoded.contains("synthetic-archive-ui") && !encoded.contains("zwei-archive") && !encoded.contains(main.cache.path),"restart state excludes archive passwords virtual addresses and cache contents")
                check(passwordForm.password.stringValue.isEmpty,"closing password form clears its secure field")
                left.selectTab(archiveTab);await settle();left.navigate(session.address("Quellen/Docs"));await settle()
                let replacement = output.appendingPathComponent("Replacement.zip");try ArchiveService.pack([links.appendingPathComponent("NestedSource")],to:replacement)
                try FileManager.default.removeItem(at:bundle);try FileManager.default.copyItem(at:replacement,to:bundle);left.refresh();await settle()
                check(!left.canUseDisplayedEntries && left.entries.isEmpty,"externally replaced archive blocks stale member actions")
                main.command("refresh");await settle();check(session.path(left.currentURL).isEmpty && left.entries.contains { $0.name == "NestedSource" },"Command R reloads changed archive and resets removed internal folders")
                main.archiveFileHandler = nil;main.command("archiveContainer");await settle()
            } catch { check(false,error.localizedDescription) }
            check(NSPasteboard.general.changeCount == clipboard,"archive checks leave general clipboard untouched")
            print("ARCHIVE SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
