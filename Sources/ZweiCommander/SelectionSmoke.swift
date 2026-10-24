import AppKit
import CommanderCore

extension AppDelegate {
    func runSelectionSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("SELECTION UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("SELECTION SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<350 { if predicate() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("SELECTION SMOKE FAIL timeout "+name+" active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none")");exit(1)
            }
            let main = self.main!,pane = main.left,window = require(main.window,"main window"),folder = root.appendingPathComponent("Links")
            let generalChange = NSPasteboard.general.changeCount,board = NSPasteboard(name:.init("local.zweicommander.tests."+UUID().uuidString))
            main.selectionPasteboard = board
            @MainActor func settle() async { await wait("settled listing") { !pane.isLoading && !pane.isSorting && !main.right.isLoading && !main.right.isSorting } }
            @MainActor func activate(_ value:NSWindow) async { value.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active window") { NSApp.isActive && value.isKeyWindow } }
            @MainActor func key(_ value:NSWindow,_ text:String,_ modifiers:NSEvent.ModifierFlags = []) -> NSEvent {
                let character = modifiers.contains(.shift) ? text.uppercased() : text
                return require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:value.windowNumber,context:nil,characters:character,charactersIgnoringModifiers:character,isARepeat:false,keyCode:text == "\r" ? 36 : text == "\u{1b}" ? 53 : 0),"key event")
            }
            @MainActor func menuKey(_ text:String,_ modifiers:NSEvent.ModifierFlags) -> Bool { NSApp.mainMenu?.performKeyEquivalent(with:key(window,text,modifiers)) == true }
            @MainActor func names() -> Set<String> { Set(pane.selectedURLs.map(\.lastPathComponent)) }
            @MainActor func select(_ values:Set<String>) { pane.select(Set(pane.visibleEntries.filter { values.contains($0.name) }.map(\.url))) }
            @MainActor func patternWindow() async -> SelectionController {
                await activate(window);pane.focus();main.command("selectPattern")
                let form = require(main.secondaryWindows.last as? SelectionController,"selection preview")
                await activate(require(form.window,"selection window"));return form
            }
            @MainActor func type(_ value:String,into form:SelectionController) async {
                form.window?.makeFirstResponder(form.pattern)
                let editor = require(form.pattern.currentEditor() as? NSTextView,"pattern editor")
                editor.setSelectedRange(NSRange(location:0,length:(editor.string as NSString).length));editor.insertText(value,replacementRange:editor.selectedRange())
                await wait("pattern preview") { form.result != nil || form.status.textColor == .systemRed }
            }
            @MainActor func capture(_ form:SelectionController,_ suffix:String) {
                let view = require(form.window?.contentView,"preview view");view.layoutSubtreeIfNeeded();view.displayIfNeeded()
                let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"preview bitmap");view.cacheDisplay(in:view.bounds,to:bitmap)
                do { try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+suffix+".png")) } catch { check(false,"preview capture") }
            }
            await settle();await activate(window);pane.focus();window.title = "ZweiCommander · Auswahl und Zwischenablage prüfen"
            let originalTab = pane.tab.id,all = Set(pane.visibleEntries.map(\.name)),fileNames = Set(pane.visibleEntries.filter { !$0.isDirectory }.map(\.name))
            check(all.count == 9 && fileNames.count == 7,"isolated files and folders loaded")
            check(menuKey("a",[.command,.option]) && names() == fileNames,"Command Option A selects files without folders")
            check(menuKey("a",[.command,.option,.shift]) && names().isEmpty,"Command Option Shift A clears selection")
            select(["Ordner","Plan.txt"]);main.command("invertFiles")
            check(names() == fileNames.subtracting(["Plan.txt"]).union(["Ordner"]),"file inversion preserves selected folders")
            check(menuKey("a",[.command,.shift]) && names() == ["Plan.txt","Plan.backup"],"whole-list inversion shortcut remains distinct from Command A")
            select(["Plan.txt"]);pane.focusedEntryURL = folder.appendingPathComponent("Plan.txt")
            check(menuKey("e",[.command,.option]) && names() == ["Plan.txt","Other.TXT","it's $file.txt","line\nbreak.txt"],"same-extension shortcut adds case-insensitive matches")
            check(menuKey("e",[.command,.option,.shift]) && names().isEmpty,"same-extension shortcut removes its matches")
            select(["Plan.txt"]);pane.focusedEntryURL = folder.appendingPathComponent("Plan.txt")
            check(menuKey("n",[.command,.option]) && names() == ["Plan.txt","Plan.md"],"same-stem shortcut adds other extensions")
            check(menuKey("n",[.command,.option,.shift]) && names().isEmpty,"same-stem shortcut removes its matches")
            select(["README"]);main.command("sameExtension");check(names() == ["README"],"extensionless files form a separate group")
            select(["Ordner"]);check(main.selectionCommandEnabled("sameExtension") == false,"folder focus disables extension matching")
            select(["Plan.txt","Grüße.pdf"])
            check(menuKey("s",[.command,.option]) && pane.tab.selectionMemory?.urls.count == 2,"Command Option S remembers this tab selection")
            main.command("deselectAll");check(menuKey("r",[.command,.option]) && names() == ["Plan.txt","Grüße.pdf"],"Command Option R restores remembered selection")
            pane.sortKey = "name";pane.ascending = false;pane.applyFilter();await settle();main.command("deselectAll");main.command("restoreSelection")
            check(names() == ["Plan.txt","Grüße.pdf"],"remembered addresses survive reordered rows")
            pane.filterField.stringValue = "*.pdf";pane.applyFilter();await settle();main.command("restoreSelection")
            check(names() == ["Grüße.pdf"] && pane.visibleEntries.count == 1,"restore intersects the active filter")
            pane.clearFilter();await settle();main.command("restoreSelection");check(names().count == 2,"hidden-by-filter memory remains available when filter clears")
            pane.newTab(url:folder);await settle();check(main.selectionCommandEnabled("restoreSelection") == false && pane.tab.selectionMemory == nil,"new tab has independent selection memory")
            pane.closeTab();await settle();check(pane.tab.id == originalTab && main.selectionCommandEnabled("restoreSelection") == true,"closing temporary tab returns to original memory")
            pane.navigate(folder.appendingPathComponent("Ordner"));await settle();check(main.selectionCommandEnabled("restoreSelection") == false,"other folder cannot restore this folder's marks")
            pane.navigate(folder);await settle();main.command("restoreSelection");check(names() == ["Plan.txt","Grüße.pdf"],"returning to the folder restores its remembered marks")
            let chosen:[String] = ["Plan.txt","it's $file.txt","line\nbreak.txt"]
            select(Set(chosen));let entries = pane.visibleEntries.filter { chosen.contains($0.name) }
            for (title,id,format) in MainWindow.selectionCopyCommands {
                main.command(id);check(board.string(forType:.string) == (try? format.render(entries)),title+" uses selected display order")
            }
            check(menuKey("c",[.command,.option]) && board.string(forType:.string) == entries.map(\.name).joined(separator:"\n"),"name-copy shortcut dispatches through native menu")
            check(menuKey("c",[.command,.shift]) && board.string(forType:.string) == entries.map { $0.url.path }.joined(separator:"\n"),"existing path-copy shortcut is preserved")
            main.command("deselectAll");main.command("copyPath");check(board.string(forType:.string) == pane.locationText,"path copy falls back to current folder")
            check(main.selectionCommandEnabled("copyNames") == false,"other text formats require selected entries")
            let copyMenu = require(pane.table.menu?.items.first { $0.title == "Text kopieren" }?.submenu,"copy context menu")
            check(copyMenu.items.count == 6 && copyMenu.items.allSatisfy { $0.toolTip?.isEmpty == false },"all six context formats include hover help")
            check(pane.grid.menu?.items.first { $0.title == "Text kopieren" }?.submenu?.items.compactMap { $0.representedObject as? String } == copyMenu.items.compactMap { $0.representedObject as? String },"icon and detail views share context commands")
            let export = root.appendingPathComponent("Auswahl.zwei-selection.json")
            select(["Plan.txt","Grüße.pdf"]);var chooserCalls = 0
            main.selectionFileChooser = { saving,directory in chooserCalls += 1;check(directory == pane.currentURL,"selection chooser starts in current local directory");return export }
            main.command("saveSelectionFile")
            let document = try? SelectionDocument.decode(Data(contentsOf:export))
            check(Set(document?.urls.map(\.lastPathComponent) ?? []) == ["Plan.txt","Grüße.pdf"],"save command writes a versioned selection document")
            main.command("deselectAll");main.command("loadSelectionFile");check(names() == ["Plan.txt","Grüße.pdf"] && chooserCalls == 2,"load command restores matching visible addresses")
            main.selectionFileChooser = { _,_ in nil };main.command("loadSelectionFile");check(names().count == 2,"cancelled chooser preserves selection")
            do {
                try SelectionDocument([root.appendingPathComponent("missing")]).encoded().write(to:export);try main.loadSelection(from:export)
                check(names() == ["Plan.txt","Grüße.pdf"] && main.content.status.stringValue.contains("bleibt erhalten"),"document without visible matches preserves existing selection")
                try Data("{broken".utf8).write(to:export)
                do { try main.loadSelection(from:export);check(false,"malformed selection file rejected") } catch { check(names().count == 2,"malformed selection file leaves current marks unchanged") }
                try SelectionDocument([]).encoded().write(to:export);try main.loadSelection(from:export);check(names().isEmpty,"explicit empty selection document clears marks")
            } catch { check(false,"selection file I/O: "+error.localizedDescription) }
            main.selectionFileChooser = nil
            pane.changeDisplay(.icons);await settle();main.command("selectFiles")
            check(names() == fileNames && pane.grid.selectionIndexPaths.count == 7,"selection commands synchronize native icon view")
            pane.changeDisplay(.details);await settle();check(pane.table.selectedRowIndexes.count == 7,"returning to details retains selection")
            main.command("deselectAll")
            check(menuKey("s",[.command,.shift]),"existing pattern shortcut opens preview")
            let cancelled = require(main.secondaryWindows.last as? SelectionController,"preview from shortcut"),cancelWindow = require(cancelled.window,"preview window")
            await activate(cancelWindow)
            check(cancelled.result?.count == 9 && names().isEmpty,"initial preview leaves actual selection unchanged")
            check(cancelWindow.performKeyEquivalent(with:key(cancelWindow,"l",.command)),"Command L focuses the pattern")
            main.command("selectAll");check((cancelled.pattern.currentEditor() as? NSTextView)?.selectedRange().length == 1,"Command A edits pattern text while preview is active")
            let fileMenu = require(copyMenu.items.first,"copy item");check(!validateMenuItem(fileMenu),"preview window disables obscured pane commands")
            check(cancelWindow.performKeyEquivalent(with:key(cancelWindow,"\u{1b}")) && cancelWindow.isVisible == false && names().isEmpty,"Escape dismisses preview without changing marks")
            await activate(window);pane.focus()
            let invalid = await patternWindow();await type("[",into:invalid);invalid.regex.performClick(nil)
            check(invalid.result == nil && !invalid.apply.isEnabled && invalid.status.stringValue.contains("prüfen"),"invalid regex is explained inline and disables apply")
            invalid.regex.performClick(nil);invalid.files.performClick(nil);invalid.folders.performClick(nil)
            check(invalid.result == nil && !invalid.apply.isEnabled,"excluding files and folders disables apply")
            invalid.close();await activate(window);pane.focus()
            for (index,expected) in [Set(["Plan.txt","Other.TXT","it's $file.txt","line\nbreak.txt"]),Set(["Plan.md","Plan.txt","Other.TXT","it's $file.txt","line\nbreak.txt"]),Set(["Plan.md"]),Set(["Plan.txt"])].enumerated() {
                select(["Plan.txt","Plan.md"])
                let form = await patternWindow(),formWindow = require(form.window,"mode window")
                if index == 1 { select(["Plan.md"]);form.prepare() }
                await type("*.txt",into:form)
                check(formWindow.performKeyEquivalent(with:key(formWindow,String(index+1),.command)) && form.combination == SelectionCombine.allCases[index],"preview mode \(index+1) shortcut")
                check(names() == (index == 1 ? ["Plan.md"] : ["Plan.txt","Plan.md"]),"mode \(index+1) remains an uncommitted preview")
                check(formWindow.performKeyEquivalent(with:key(formWindow,"\r",.command)) && !formWindow.isVisible,"mode \(index+1) applies through Command Return")
                check(names() == expected,"mode \(index+1) applies exact result")
                await activate(window);pane.focus()
            }
            select(["Plan.txt"]);let stale = await patternWindow();await type("*.pdf",into:stale)
            select(["Plan.md"]);stale.submit()
            check(stale.window?.isVisible == true && names() == ["Plan.md"] && stale.status.stringValue.contains("erneut übernehmen"),"changed selection refreshes review before apply")
            stale.submit();check(names() == ["Grüße.pdf"] && stale.window?.isVisible == false,"reviewed refreshed preview can be applied")
            await activate(window);pane.focus();let moved = await patternWindow()
            pane.newTab(url:folder);await settle();moved.submit()
            check(moved.result == nil && !moved.apply.isEnabled && moved.window?.isVisible == true,"changed tab invalidates a previous preview")
            moved.close();pane.closeTab();await settle();await activate(window);pane.focus()
            pane.filterField.stringValue = "*.pdf";pane.applyFilter();await settle();let filtered = await patternWindow()
            check(filtered.result?.count == 1 && filtered.table.numberOfRows == 1,"pattern preview is limited to currently visible entries")
            filtered.close();pane.clearFilter();await settle();await activate(window);pane.focus()
            main.command("path");let marks = names();main.command("selectFiles")
            check(pane.pathField.sessionActive && names() == marks && main.selectionCommandEnabled("selectFiles") == false,"address editing cannot change file selection via global shortcuts")
            pane.endPathEditing(restoreFocus:true)
            let form = await patternWindow();await type("*.txt;*.pdf",into:form)
            for (index,title) in [(1,"Hell"),(2,"Dunkel")] {
                main.themeMenu.selectItem(at:index);main.themeChosen();try? await Task.sleep(nanoseconds:250_000_000)
                check(form.window?.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (index == 1 ? .aqua : .darkAqua),"selection preview follows "+title+" appearance")
                capture(form,"-Auswahl-"+title)
            }
            form.close();await activate(window);pane.focus()
            pane.showCollection([folder.appendingPathComponent("Plan.txt"),folder.appendingPathComponent("Grüße.pdf")],title:"Auswahlprüfung");await settle()
            main.command("selectFiles");main.command("saveSelection");main.command("deselectAll");main.command("restoreSelection")
            check(names() == ["Plan.txt","Grüße.pdf"] && pane.tab.selectionMemory?.scope.hasPrefix("collection:") == true,"collection selections use an independent tab scope")
            pane.closeTab();await settle();pane.showArchive(root:folder,original:root.appendingPathComponent("Beispiel.zip"));await settle();main.command("selectFiles")
            check(pane.readOnly && names() == fileNames,"read-only archive listings still support selection")
            pane.closeTab();await settle()
            let port = require((try? String(contentsOf:root.appendingPathComponent("Server/port.txt"),encoding:.utf8)).flatMap(Int.init),"FTP port")
            let connection = require(try? RemoteConnection(kind:.ftp,host:"127.0.0.1",user:"fixture",password:"synthetic-selection-only",port:port),"FTP connection")
            pane.openRemote(connection,path:"/Auswahl");await settle();await activate(window);pane.focus();main.command("selectFiles")
            check(names() == ["Plan.txt","Plan.md","Other.TXT"] && pane.selectedURLs.allSatisfy { !$0.isFileURL },"selection commands operate actual server list addresses")
            main.command("saveSelection");main.command("deselectAll");main.command("restoreSelection");check(names().count == 3,"server tab remembers and restores its selection")
            main.command("copyURLs");let remoteText = board.string(forType:.string) ?? ""
            check(remoteText.contains("ftp://127.0.0.1:") && !remoteText.contains("fixture") && !remoteText.contains("synthetic-selection-only"),"server clipboard addresses contain no login or password")
            check(main.selectionCommandEnabled("copyShellPaths") == false,"shell argument format is disabled for server objects")
            main.command("copyShellPaths");check(board.string(forType:.string) == remoteText,"disabled server shell command preserves clipboard text")
            let remoteForm = await patternWindow();await type("*.md",into:remoteForm);remoteForm.submit()
            check(names() == ["Plan.md"],"same pattern preview applies to server rows")
            await activate(window);pane.focus()
            do { try main.saveSelection(to:export);main.command("deselectAll");try main.loadSelection(from:export);check(names() == ["Plan.md"],"server selection document round trip retains remote identity") } catch { check(false,"server selection document round trip") }
            pane.navigate(connection.address("/Auswahl/Ordner"));await settle();check(main.selectionCommandEnabled("restoreSelection") == false,"server folder change does not reuse root marks")
            pane.navigate(connection.address("/Auswahl"));await settle();main.command("restoreSelection");check(names().count == 3,"returning to server root restores its memory")
            pane.closeTab();await settle();await activate(window);pane.focus()
            check(pane.tab.id == originalTab,"closing server tab preserves original local tab")
            let mass = root.appendingPathComponent("Masse");pane.newTab(url:mass);await settle();main.command("deselectAll");let bulk = await patternWindow()
            check(bulk.result?.count == 3000 && bulk.table.numberOfRows == 500,"bounded preview includes the full 3000-entry result")
            bulk.submit();check(pane.selectedURLs.count == 3000,"bulk preview applies every result beyond the displayed 500 rows")
            pane.closeTab();await settle();await activate(window);pane.focus()
            select(["Plan.txt","Grüße.pdf"]);main.command("saveSelection")
            do { try FileManager.default.removeItem(at:folder.appendingPathComponent("Grüße.pdf")) } catch { check(false,"remove isolated fixture") }
            pane.refresh();await settle();main.command("restoreSelection");check(names() == ["Plan.txt"],"restore ignores a file removed since selection was remembered")
            let saved = String(decoding:try! JSONEncoder().encode(Preferences.state),as:UTF8.self)
            check(!saved.contains("selectionMemory") && !saved.contains("synthetic-selection-only"),"runtime selection memories and credentials are absent from saved app state")
            check(NSPasteboard.general.changeCount == generalChange,"all text-copy checks leave the user's general clipboard untouched")
            board.releaseGlobally();main.selectionPasteboard = .general
            print("SELECTION SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
