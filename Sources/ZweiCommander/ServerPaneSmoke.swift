import AppKit
import CommanderCore

extension AppDelegate {
    func runServerPaneSmoke(root: URL,prefix: String) {
        Task { @MainActor in
            var checks = 0,failures: [String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("SERVER PANE \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("SERVER PANE SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<750 { if predicate() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("SERVER PANE SMOKE FAIL timeout "+name+" · "+self.main.jobs.scheduler.snapshots.map { $0.state.rawValue+": "+$0.detail }.joined(separator:" | "));exit(1)
            }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active window") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func key(_ window:NSWindow,_ text:String,_ modifiers:NSEvent.ModifierFlags = []) -> NSEvent {
                require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:text == "\r" ? 36 : 0),"key event")
            }
            @MainActor func select(_ pane:PaneView,_ names:Set<String>) { pane.select(Set(pane.visibleEntries.filter { names.contains($0.name) }.map(\.url))) }
            @MainActor func settle() async { await wait("finished pane jobs") { self.main.jobs.pending == 0 && self.main.jobs.log.count >= self.main.jobs.scheduler.snapshots.filter(\.isFinished).count && !self.main.left.isLoading && !self.main.right.isLoading && !self.main.left.isSorting && !self.main.right.isSorting } }
            @MainActor func capture(_ suffix:String) {
                let view = require(self.main.window?.contentView,"server snapshot content");view.layoutSubtreeIfNeeded();view.displayIfNeeded()
                let rep = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"server snapshot bitmap");view.cacheDisplay(in:view.bounds,to:rep)
                for pane in [self.main.left,self.main.right] {
                    let header = require(pane.table.headerView,"server column header"),light = !pane.palette.dark
                    let rect = view.convert(NSRect(x:6,y:3,width:60,height:16),from:header)
                    var pixels = 0
                    for x in Int(rect.minX)..<Int(rect.maxX) {
                        for y in Int(rect.minY)..<Int(rect.maxY) {
                            if let color = rep.colorAt(x:x,y:Int(view.bounds.height)-y-1),color.alphaComponent > 0.99 {
                                let value = CommanderPalette.luminance(color)
                                if light ? value < 0.25 : value > 0.6 { pixels += 1 }
                            }
                        }
                    }
                    _ = require(pixels > 20 ? true : nil,"readable rendered server column titles")
                }
                let data = require(rep.representation(using:.png,properties:[:]),"server snapshot PNG")
                do { try data.write(to:URL(fileURLWithPath:prefix+suffix+".png")) } catch { print("SERVER PANE SMOKE FAIL screenshot");exit(1) }
            }
            await settle()
            let main = self.main!,left = main.left,right = main.right,window = require(main.window,"main window")
            window.title = "ZweiCommander · Server-Tabs prüfen"
            left.newTab(url:root.appendingPathComponent("Links/Projekt"));await settle()
            let localTabs = left.savedTabs,rightLocation = right.currentURL
            main.remoteConnect();let form = require(main.secondaryWindows.last as? RemoteConnectionController,"connection form"),formWindow = require(form.window,"connection window")
            await activate(formWindow)
            check(form.destination.indexOfSelectedItem == 0,"connection defaults to a tab in the active pane")
            form.kind.selectItem(at:2);form.protocolChanged();form.host.stringValue = "127.0.0.1";form.user.stringValue = "fixture";form.password.stringValue = "synthetic-pane-only"
            form.port.stringValue = require(try? String(contentsOf:root.appendingPathComponent("Server/port.txt"),encoding:.utf8),"FTP port")
            check(formWindow.performKeyEquivalent(with:key(formWindow,"\r",.command)),"Command Return uses the actual connection form")
            await wait("server tab") { left.remote != nil && !left.isLoading };await activate(window);left.focus();await settle()
            check(left.tabs.count == localTabs.count+1 && right.currentURL == rightLocation,"server opens beside preserved local tabs and leaves the opposite pane unchanged")
            check(main.secondaryWindows.compactMap { $0 as? RemoteWindow }.isEmpty,"default connection uses the main file pane")
            check(left.entries.contains { $0.name == "Eingang" && $0.isDirectory } && left.entries.allSatisfy { !$0.url.isFileURL },"shared file list reads actual server entries as remote addresses")
            check(left.savedTabs.map(\.path) == localTabs.map(\.path) && left.savedTabs.last?.selected == true,"session-only server tab preserves the previously selected local tab for restart")
            let persisted = String(decoding:try! JSONEncoder().encode(Preferences.state),as:UTF8.self)
            check(!persisted.contains("synthetic-pane-only") && !persisted.contains("ftp://"),"saved application state contains neither server sessions nor credentials")
            left.filterField.stringValue = "Eing*";left.filterChanged();await settle()
            check(left.visibleEntries.map(\.name) == ["Eingang"],"ordinary wildcard filter applies to server entries")
            left.filterField.stringValue = "[";left.filterRegex.state = .on;left.filterChanged()
            check(!left.canUseDisplayedEntries && left.visibleEntries.isEmpty,"invalid server filter blocks file actions")
            left.clearFilter();left.sortKey = "size";left.ascending = false;left.applyFilter();await settle()
            let files = left.visibleEntries.filter { !$0.isDirectory }
            check(files.map(\.size) == files.map(\.size).sorted(by:>),"standard numeric size sorting works for remote metadata")
            let alpha = require(left.entries.first { $0.name == "Alpha.txt" },"server test file")
            let (_,request) = left.fileImages.load(alpha,preview:true,completion:{ _ in })
            check(request == nil,"server icons never read or preview a coincident local path")
            left.changeDisplay(.icons);select(left,["Alpha.txt"])
            check(left.selectedURLs == [alpha.url] && !left.grid.selectionIndexPaths.isEmpty,"symbol view shares server selection and address identity")
            left.changeDisplay(.details);select(left,["Alpha.txt"])
            check(main.serverCommandEnabled("preview") == false && main.serverCommandEnabled("reveal") == false && main.serverCommandEnabled("shell") == false,"local preview, Finder and shell commands are unavailable for a server selection")
            let oldJobs = main.jobs.scheduler.snapshots.count;main.command("newFile")
            check(main.jobs.scheduler.snapshots.count == oldJobs && right.currentURL == rightLocation,"unsupported local file actions cannot operate a hidden local folder")
            let trashItem = require(left.table.menu?.items.first { $0.representedObject as? String == "trash" },"server delete menu")
            _ = left.validateMenuItem(trashItem)
            check(trashItem.title.contains("Endgültig"),"server context menu names permanent deletion explicitly")
            check(NSApp.mainMenu?.performKeyEquivalent(with:key(window,String(UnicodeScalar(NSF2FunctionKey)!))) == true,"F2 dispatches through the actual main menu")
            let rename = require(main.secondaryWindows.last as? RemoteActionController,"server rename"),renameWindow = require(rename.window,"rename window")
            await activate(renameWindow);rename.name.stringValue = "Zulu.bin";rename.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
            await wait("rename collision") { rename.status.stringValue.contains("belegt") }
            check(rename.plan == nil && !rename.start.isEnabled && FileSystem.exists(root.appendingPathComponent("Server/Alpha.txt")),"occupied rename target blocks execution and preserves the source")
            rename.name.stringValue = "Alpha neu.txt";rename.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));await wait("rename plan") { rename.plan != nil }
            check(renameWindow.performKeyEquivalent(with:key(renameWindow,"\r",.command)),"Command Return starts the reviewed server rename")
            await settle()
            check((try? String(contentsOf:root.appendingPathComponent("Server/Alpha neu.txt"),encoding:.utf8)) == "Alpha content\n" && !FileSystem.exists(root.appendingPathComponent("Server/Alpha.txt")),"server rename changes the actual name without changing file contents")
            await activate(window);left.focus()
            check(NSApp.mainMenu?.performKeyEquivalent(with:key(window,String(UnicodeScalar(NSF7FunctionKey)!))) == true,"F7 opens server directory creation")
            let create = require(main.secondaryWindows.last as? RemoteActionController,"server mkdir"),createWindow = require(create.window,"mkdir window")
            await activate(createWindow);create.name.stringValue = "Testordner";create.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification));await wait("mkdir plan") { create.plan != nil }
            check(!FileSystem.exists(root.appendingPathComponent("Server/Testordner")),"directory preview creates no server object")
            _ = createWindow.performKeyEquivalent(with:key(createWindow,"\r",.command));await settle()
            check(FileSystem.isDirectory(root.appendingPathComponent("Server/Testordner")),"reviewed F7 action creates the actual remote directory")
            await activate(window);left.focus();select(left,["Testordner"]);main.command("trash")
            let cancelled = require(main.secondaryWindows.last as? RemoteActionController,"cancelled delete")
            await wait("delete preview") { cancelled.plan != nil }
            check(cancelled.plan?.folders == 1 && cancelled.start.keyEquivalent.isEmpty,"delete preview counts the tree and has no plain Return destructive shortcut")
            cancelled.close()
            check(FileSystem.isDirectory(root.appendingPathComponent("Server/Testordner")),"cancelling the deletion review preserves all server objects")
            await activate(window);left.focus();select(left,["Alpha neu.txt","Testordner"])
            check(NSApp.mainMenu?.performKeyEquivalent(with:key(window,String(UnicodeScalar(NSF8FunctionKey)!))) == true,"F8 opens a permanent server deletion review")
            let deletion = require(main.secondaryWindows.last as? RemoteActionController,"server deletion"),deleteWindow = require(deletion.window,"delete window")
            await activate(deleteWindow);await wait("complete deletion plan") { deletion.plan != nil }
            check(deletion.plan?.files == 1 && deletion.plan?.folders == 1,"deletion review describes exactly the selected file and folder")
            _ = deleteWindow.performKeyEquivalent(with:key(deleteWindow,"\r",.command));await settle()
            check(!FileSystem.exists(root.appendingPathComponent("Server/Alpha neu.txt")) && !FileSystem.exists(root.appendingPathComponent("Server/Testordner")) && FileSystem.exists(root.appendingPathComponent("Server/Zulu.bin")),"explicit deletion removes only the reviewed server selection")
            await activate(window);left.focus();select(left,["Eingang"])
            check(main.serverTransferTitle("copy") == "Herunterladen" && main.serverTransferTitle("move") == "Hochladen","F5 and F6 describe the correct directions for an active server pane")
            check(NSApp.mainMenu?.performKeyEquivalent(with:key(window,String(UnicodeScalar(NSF5FunctionKey)!))) == true,"F5 opens a download review from the server pane")
            let download = require(main.secondaryWindows.last as? RemoteTransferController,"pane download"),downloadWindow = require(download.window,"download window")
            await activate(downloadWindow);await wait("download tree") { download.plan != nil }
            check(download.plan?.localDirectory == right.currentURL && download.plan?.files == 2,"download preview uses the visible opposite local folder and full tree")
            _ = downloadWindow.performKeyEquivalent(with:key(downloadWindow,"\r",.command));await settle()
            check((try? String(contentsOf:root.appendingPathComponent("Rechts/Eingang/Infos/Grüße.txt"),encoding:.utf8)) == "Remote content ✔\n" && FileSystem.isDirectory(root.appendingPathComponent("Rechts/Eingang/Leer")),"download from the main pane writes exact nested contents to the opposite pane")
            await activate(window);select(right,["Projekt"]);left.focus()
            check(NSApp.mainMenu?.performKeyEquivalent(with:key(window,String(UnicodeScalar(NSF6FunctionKey)!))) == true,"F6 uses the opposite local selection for upload")
            let upload = require(main.secondaryWindows.last as? RemoteTransferController,"pane upload"),uploadWindow = require(upload.window,"upload window")
            await activate(uploadWindow);await wait("upload tree") { upload.plan != nil }
            check(upload.plan?.rootNames == ["Projekt"] && upload.plan?.files == 3,"upload preview uses the selected local tree without a second file picker")
            _ = uploadWindow.performKeyEquivalent(with:key(uploadWindow,"\r",[.command,.shift]));await wait("waiting pane upload") { main.jobs.scheduler.snapshots.contains { $0.state == .waiting } }
            check(!main.canTerminate && !FileSystem.exists(root.appendingPathComponent("Server/Projekt")),"pane upload shares the held queue and prevents losing session work on quit")
            let queueWindow = require(main.operationWindow?.window,"common queue");await activate(queueWindow)
            _ = queueWindow.performKeyEquivalent(with:key(queueWindow,"\r"));await settle()
            check((try? String(contentsOf:root.appendingPathComponent("Server/Projekt/Unterordner/Grüße.txt"),encoding:.utf8)) == "Upload content ✔\n","main pane upload writes the exact reviewed remote contents")
            check(FileSystem.exists(root.appendingPathComponent("Rechts/Projekt/Unterordner/Grüße.txt")),"F6 upload preserves the local source tree")
            await activate(window);right.focus()
            check(main.serverTransferTitle("copy") == "Hochladen" && main.serverTransferTitle("move") == "Herunterladen","switching focus reverses labels while retaining explicit transfer directions")
            left.focus();let oldAddress = left.currentURL;left.beginPathEditing();left.pathField.stringValue = "/";left.pathField.requestSuggestions(selectFirst:true)
            await wait("remote address suggestions") { !left.pathField.isQuerying && left.pathField.suggestions.contains { $0.title == "Eingang" } }
            check(left.pathField.suggestions.allSatisfy { !$0.url.isFileURL && $0.url.host == "127.0.0.1" },"address completion queries the connected server instead of the local disk")
            left.pathField.stringValue = "/not-present";left.pathField.submit();await wait("remote path error") { left.pathField.validationMessage != nil }
            check(left.currentURL == oldAddress && main.serverCommandEnabled("copy") == false,"invalid server address remains editable and blocks actions on the previous listing")
            left.endPathEditing();let rootButton = require(left.breadcrumb.childButtons.first,"server breadcrumb")
            left.breadcrumb.showChildren(of:rootButton.0,from:rootButton.1);await wait("remote breadcrumb children") { left.breadcrumb.dropdown.rows.contains { $0.title == "Eingang" } }
            check(left.breadcrumb.dropdown.rows.allSatisfy { !$0.url.isFileURL },"breadcrumb child chooser uses actual server folders")
            left.breadcrumb.dropdown.dismiss();left.duplicateTab();await settle()
            check(left.remote != nil && left.tabs.last?.remote !== left.tabs[left.tabs.count-2].remote,"duplicating a server tab preserves its connection with independent tab state")
            left.closeTab();await settle();await activate(window);left.focus();main.command("sameFolder");await settle()
            check(right.remote != nil && right.currentURL == left.currentURL && right.savedTabs.first?.path == rightLocation.path,"same-folder action opens a server tab on the other side without discarding local tabs")
            check(main.serverCommandEnabled("copy") == false && main.serverCommandEnabled("move") == false,"two server panes cannot accidentally invoke a local or server-to-server transfer")
            let before = main.secondaryWindows.count;main.command("copy")
            check(main.secondaryWindows.count == before,"unavailable server-to-server copying opens no hidden local operation")
            for theme in [1,2] {
                main.themeMenu.selectItem(at:theme);main.themeChosen()
                try? await Task.sleep(nanoseconds:200_000_000);await settle()
                for pane in [left,right] {
                    let background = pane.table.backgroundColor
                    _ = require(CommanderPalette.contrast(pane.fileTextColor("Zulu.bin"),background) >= 4.5 ? true : nil,"readable server text after theme change")
                    _ = require((theme == 1 ? CommanderPalette.luminance(background) > 0.8 : CommanderPalette.luminance(background) < 0.3) ? true : nil,"server content follows chosen theme")
                }
                capture(theme == 1 ? "-Server-Tabs-Hell" : "-Server-Tabs-Dunkel")
            }
            let restored = require(left.tabs.first { $0.remote == nil },"preserved local tab");left.selectTab(restored.id);await settle();left.focus()
            check(main.serverCommandEnabled("newFile") == nil && left.currentURL.isFileURL,"returning to a local tab restores its ordinary local commands")
            check(right.currentURL.scheme == "ftp" && FileSystem.exists(root.appendingPathComponent("Server/Zulu.bin")),"local tab switching preserves the connected opposite server and untouched files")
            await settle();check(main.canTerminate,"completed server actions and browsing allow a normal quit")
            print("SERVER PANE SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
