import AppKit
import CommanderCore

extension AppDelegate {
    func runRecoverySmoke(root: URL,prefix: String,reload: Bool) {
        Task { @MainActor in
            var checks = 0,failures: [String] = []
            func check(_ value: Bool,_ name: String) { checks += 1;print("RECOVERY UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value: T?,_ name: String) -> T { guard let value else { print("RECOVERY SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name: String,_ predicate: ()->Bool) async {
                for _ in 0..<300 { if predicate() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("RECOVERY SMOKE FAIL timeout "+name);exit(1)
            }
            @MainActor func key(_ window: NSWindow,_ value: String,_ modifiers: NSEvent.ModifierFlags = [],code: UInt16 = 0) -> NSEvent {
                require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:value,charactersIgnoringModifiers:value,isARepeat:false,keyCode:code),"key event")
            }
            @MainActor func activate(_ window: NSWindow) async {
                window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                await wait("active workflow window") { window.isKeyWindow && NSApp.isActive }
            }
            @MainActor func type(_ field: NSTextField,_ value: String) {
                let editor = require(field.currentEditor() as? NSTextView,"field editor")
                editor.selectAll(nil);editor.insertText(value,replacementRange:editor.selectedRange())
            }
            @MainActor func capture(_ window: NSWindow,_ suffix: String) async {
                // Appearance changes and dismissed sheets need a display pass before caching layers.
                try? await Task.sleep(nanoseconds:200_000_000)
                guard let view = window.contentView else { return };view.layoutSubtreeIfNeeded();view.display()
                guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
                view.cacheDisplay(in:view.bounds,to:rep);try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
            }
            @MainActor func menuItem(_ id: String) -> NSMenuItem? {
                func find(_ menu: NSMenu?) -> NSMenuItem? { for item in menu?.items ?? [] { if item.representedObject as? String == id { return item };if let found = find(item.submenu) { return found } };return nil }
                return find(NSApp.mainMenu)
            }
            let jobs = main.jobs,history = require(main.jobs.history,"private recovery storage"),left = root.appendingPathComponent("Links"),right = root.appendingPathComponent("Rechts")
            let source = left.appendingPathComponent("Kopie.txt"),target = right.appendingPathComponent("Kopie.txt"),large = left.appendingPathComponent("Groß.bin")
            await wait("initial pane") { !self.main.left.isLoading && !self.main.right.isLoading }
            if reload {
                check(history.inspect().filter { $0.kind == .backup }.count == 1,"backup catalog survives a separate app process")
                let partial = require(history.inspect().first { $0.kind == .partial },"persisted partial")
                check(partial.bytes > 0 && partial.bytes < partial.totalBytes,"partial byte count survives a separate app process")
                check(jobs.active == nil && !FileSystem.exists(right.appendingPathComponent("Groß.bin")),"restart never executes a partial automatically")
                main.showRecovery();let recovery = require(main.recoveryWindow,"recovery workspace"),window = require(recovery.window,"recovery window")
                await activate(window);await wait("reloaded recovery rows") { !recovery.isLoading && recovery.rows.count == 2 }
                recovery.kind.selectItem(at:2);recovery.filterChanged()
                check(recovery.rows.count == 1 && recovery.selected?.id == partial.id,"partial-only filter selects the persisted copy")
                recovery.activateSelected()
                let setup = require(main.secondaryWindows.last as? TransferSetupController,"resume plan")
                await activate(require(setup.window,"resume window"));await wait("resume preview") { setup.plan != nil }
                check(setup.recoveryNotice?.contains("verglichen") == true && setup.plan?.bytes == partial.totalBytes,"resume review explains verification and plans exact total bytes")
                check(FileSystem.exists(large) && !FileSystem.exists(right.appendingPathComponent("Groß.bin")),"opening resume review changes no files")
                var result: OperationReport?
                setup.onSubmit = { plan,start in
                    do { try jobs.submitTransfer(plan,start:start,completion:{ if case .success(let report) = $0 { result = report } });return true }
                    catch { return false }
                }
                check(setup.window!.performKeyEquivalent(with:key(setup.window!,"\r",.command,code:36)),"Command Return submits the reviewed resume plan")
                await wait("actual resumed copy") { result != nil && jobs.pending == 0 }
                check(result?.errors.isEmpty == true && result?.reusedBytes == partial.bytes,"resume reports exactly the bytes reused from the prior process")
                check((try? Checksums.hash(large)) == (try? Checksums.hash(right.appendingPathComponent("Groß.bin"))),"resumed output matches the complete original")
                check(!history.inspect().contains { $0.kind == .partial },"successful publication removes its partial description")
                recovery.refresh();await activate(window);await wait("recovery after resume") { !recovery.isLoading }
                recovery.kind.selectItem(at:1);recovery.filterChanged()
                check(recovery.rows.count == 1 && recovery.primary.isEnabled,"persisted backup remains independently recoverable")
                recovery.activateSelected();await wait("restore sheet") { recovery.confirmation != nil }
                check(window.attachedSheet != nil && recovery.confirmation?.informativeText.contains("neue Sicherung") == true,"restore sheet shows preservation of the current version")
                recovery.confirmation?.buttons[0].performClick(nil)
                await wait("actual restore") { jobs.pending == 0 && (try? String(contentsOf:target,encoding:.utf8)) == "Alt\n" }
                check((try? String(contentsOf:target,encoding:.utf8)) == "Alt\n","confirmed restore returns the previous target contents")
                let replacement = history.inspect().filter { $0.kind == .backup }
                check(replacement.count == 1 && (try? String(contentsOf:replacement.first!.stored,encoding:.utf8)) == "Neu\n","current contents become a new independently restorable backup")
                recovery.refresh();await wait("replacement list") { !recovery.isLoading };await activate(window)
                recovery.discardSelected();await wait("discard review") { recovery.confirmation != nil }
                recovery.confirmation?.buttons[1].performClick(nil);await wait("cancel discard") { recovery.confirmation == nil }
                check(history.inspect().filter { $0.kind == .backup }.count == 1 && FileSystem.exists(replacement.first!.stored),"cancelling discard preserves the catalog and stored data")
                window.appearance = NSAppearance(named:.aqua);await capture(window,"-Wiederherstellung-Hell")
                window.appearance = NSAppearance(named:.darkAqua);await capture(window,"-Wiederherstellung-Dunkel")
            } else {
                let queueKey = require(menuItem("operations"),"queue menu"),recoveryKey = require(menuItem("recovery"),"recovery menu"),pauseKey = require(menuItem("pauseTransfers"),"pause menu"),stopKey = require(menuItem("stopTransfers"),"stop menu")
                check(queueKey.keyEquivalent == "J" && queueKey.keyEquivalentModifierMask == [.command,.shift],"queue retains Command Shift J")
                check(recoveryKey.keyEquivalent == "j" && recoveryKey.keyEquivalentModifierMask == [.command,.option],"recovery uses related Command Option J")
                check(pauseKey.keyEquivalent == "p" && pauseKey.keyEquivalentModifierMask == [.command,.option] && stopKey.keyEquivalent == ".","pause and cancel have dedicated discoverable menu shortcuts")
                main.left.select([source]);let originalSelection = main.left.selectedURLs
                main.transfer([left.appendingPathComponent("Projekt")],to:right,kind:.move)
                let move = require(main.secondaryWindows.last as? TransferSetupController,"move setup"),moveWindow = require(move.window,"move window")
                await activate(moveWindow);await wait("initial move plan") { move.plan != nil }
                check(!move.optionsButton.isHidden && move.include.isEnabled && !move.structureOnly.isEnabled && !move.mergeFolders.isEnabled,"move exposes supported filters and disables incompatible copy-only rules")
                check(move.profilePopup.isEnabled && move.profileSaveAs.isEnabled && move.criteriaButton.isEnabled,"move supports shared profiles and metadata criteria")
                do {
                    var filter = TransferFilter();filter.structureOnly = true
                    let id = try Preferences.editCopyProfiles { try $0.save(name:"Strukturprüfung",filter:filter,policy:.stop,mergeFolders:false) }
                    move.refreshProfiles();move.profilePopup.selectItem(at:require(move.profilePopup.itemArray.firstIndex { $0.representedObject as? String == id.uuidString },"incompatible profile"));move.chooseProfile()
                    check(move.structureOnly.state == .off && move.profileStatus.stringValue.contains("Kopieroptionen"),"move rejects incompatible saved copy options without applying them")
                } catch { check(false,"incompatible profile fixture") }
                check(moveWindow.performKeyEquivalent(with:key(moveWindow,"l",.command)),"Command L focuses the destination")
                check(move.destination.currentEditor() != nil,"destination has a real native editor")
                check(moveWindow.performKeyEquivalent(with:key(moveWindow,"f",[.command,.option])),"Command Option F opens and focuses filters")
                check(move.optionsExpanded && move.include.currentEditor() != nil,"filter shortcut expands options and gives typing focus")
                type(move.include,"[");move.regex.state = .on;move.prepare()
                _ = moveWindow.performKeyEquivalent(with:key(moveWindow,"\r",[.command,.shift],code:36))
                _ = moveWindow.performKeyEquivalent(with:key(moveWindow,"f",[.command,.option]))
                type(move.include,"a.txt");move.regex.state = .off;move.prepare()
                await wait("changed draft cancels pending submit") { move.plan?.filter.include == "a.txt" }
                check(jobs.scheduler.snapshots.isEmpty && FileSystem.exists(left.appendingPathComponent("Projekt/a.txt")),"editing after a pending keyboard submission cancels that request")
                type(move.include,"*.txt");move.excludedFolders.stringValue = "Cache";move.keepEmpty.state = .off;move.prepare()
                await wait("filtered move plan") { move.plan?.filter.include == "*.txt" && move.plan?.entries.first?.fileCount == 2 }
                check(move.safety.stringValue.contains("Quellordner") && move.safety.stringValue.contains("passende"),"filtered move makes retained source directories explicit")
                check(moveWindow.performKeyEquivalent(with:key(moveWindow,"2",.command)),"Command 2 selects the object preview")
                check(move.tabs.selectedTabViewItem?.identifier as? String == "files","preview shortcut does not change the background pane mode")
                let beforeWindows = main.secondaryWindows.count
                main.command("copy");main.command("trash")
                check(main.secondaryWindows.count == beforeWindows && main.left.selectedURLs == originalSelection,"background file commands cannot escape a workflow window")
                check(!validateMenuItem(require(menuItem("trash"),"trash item")),"destructive background menu commands are disabled")
                check(move.queueButton.toolTip?.contains("⌘⇧↩") == true && move.startButton.toolTip?.contains("⌘↩") == true,"transfer tooltips show the actual submit shortcuts")
                check(moveWindow.performKeyEquivalent(with:key(moveWindow,"\r",[.command,.shift],code:36)),"Command Shift Return queues the filtered move")
                await wait("queued move") { jobs.scheduler.snapshots.contains { $0.state == .waiting } }
                let queue = require(main.operationWindow,"queue workspace"),queueWindow = require(queue.window,"queue window")
                await activate(queueWindow);queue.refresh()
                Preferences.state.shortcuts["recovery"] = "cmd+option+b";buildMenus();queue.refresh()
                check(queue.recoveryButton.toolTip?.contains("⌘⌥B") == true,"queue help follows a remapped global shortcut")
                Preferences.state.shortcuts.removeValue(forKey:"recovery");buildMenus();queue.refresh()
                check(jobs.scheduler.isHeld && FileSystem.exists(left.appendingPathComponent("Projekt/a.txt")),"queuing with keyboard starts no file operation")
                let first = require(jobs.scheduler.snapshots.first { $0.state == .waiting }?.id,"first queued id")
                do { let plan = try TransferPlanner.prepare([left.appendingPathComponent("Warten.txt")],to:right,kind:.copy,policy:.stop);_ = try jobs.submitTransfer(plan,start:false,completion:{ _ in }) } catch { check(false,"second queue plan") }
                let second = require(jobs.scheduler.snapshots.last { $0.state == .waiting }?.id,"second queued id")
                queue.select(second);queueWindow.makeFirstResponder(queue.table)
                queue.table.keyDown(with:key(queueWindow,String(UnicodeScalar(NSUpArrowFunctionKey)!),.option,code:126));queue.refresh()
                check(jobs.scheduler.snapshots.filter { $0.state == .waiting }.first?.id == second,"Option Up reorders the selected waiting job")
                queue.table.keyDown(with:key(queueWindow,"\u{7f}",code:51));queue.refresh()
                check(jobs.scheduler.snapshots.first { $0.id == second }?.state == .cancelled && FileSystem.exists(left.appendingPathComponent("Warten.txt")),"Delete removes only the selected waiting job")
                queue.select(first);queueWindow.makeFirstResponder(queue.table)
                queue.table.keyDown(with:key(queueWindow,"\r",code:36));await wait("keyboard filtered move") { jobs.pending == 0 }
                check(!FileSystem.exists(left.appendingPathComponent("Projekt/a.txt")) && !FileSystem.exists(left.appendingPathComponent("Projekt/Unterordner/b.txt")),"Return starts the selected filtered move")
                check((try? String(contentsOf:left.appendingPathComponent("Projekt/unberührt.tmp"),encoding:.utf8)) == "TMP\n" && (try? String(contentsOf:left.appendingPathComponent("Projekt/Cache/c.txt"),encoding:.utf8)) == "Cache\n","actual filtered move retains excluded files and subtrees")
                check(FileSystem.isDirectory(left.appendingPathComponent("Projekt/Unterordner")) && (try? String(contentsOf:right.appendingPathComponent("Projekt/Unterordner/b.txt"),encoding:.utf8)) == "Beta\n","actual filtered move creates the expected destination and retains source folders")
                do { _ = try jobs.submitTransfer(try TransferPlanner.prepare([left.appendingPathComponent("Warten.txt")],to:right,kind:.copy,policy:.stop),start:false,completion:{ _ in }) } catch { check(false,"held keyboard fixture") }
                check(NSApp.mainMenu?.performKeyEquivalent(with:key(queueWindow,"p",[.command,.option])) == true,"global pause-resume shortcut starts a held queue")
                await wait("held queue resumed") { jobs.pending == 0 && FileSystem.exists(right.appendingPathComponent("Warten.txt")) }
                check((try? String(contentsOf:right.appendingPathComponent("Warten.txt"),encoding:.utf8)) == "Warten\n" && FileSystem.exists(left.appendingPathComponent("Warten.txt")),"resuming a held queue performs its exact copy")
                do {
                    let plan = try TransferPlanner.prepare([source],to:right,kind:.copy,policy:.replace)
                    _ = try jobs.submitTransfer(plan,start:true,completion:{ _ in })
                } catch { check(false,"backup copy plan") }
                await wait("actual backup copy") { jobs.pending == 0 && (try? String(contentsOf:target,encoding:.utf8)) == "Neu\n" }
                check(history.inspect().filter { $0.kind == .backup }.count == 1,"real replacement creates a durable backup entry")
                var pausedOnce = false
                jobs.transferProgressObserver = { value in if value.bytes > 0 && value.bytes < value.totalBytes && !pausedOnce { pausedOnce = true;jobs.scheduler.pause() } }
                do { _ = try jobs.submitTransfer(try TransferPlanner.prepare([large],to:right.appendingPathComponent("PauseZiel"),kind:.copy,policy:.stop),start:true,completion:{ _ in }) } catch { check(false,"Space resume fixture") }
                await wait("Space paused transfer") { jobs.active?.state == .paused };queue.refresh();await activate(queueWindow);queueWindow.makeFirstResponder(queue.table)
                queue.table.keyDown(with:key(queueWindow," ",code:49))
                await wait("Space resumes transfer") { jobs.pending == 0 }
                check((try? Checksums.hash(large)) == (try? Checksums.hash(right.appendingPathComponent("PauseZiel/Groß.bin"))),"Space resumes an acknowledged pause and completes the exact file")
                jobs.transferProgressObserver = nil;pausedOnce = false
                jobs.transferProgressObserver = { value in if value.bytes > 0 && value.bytes < value.totalBytes && !pausedOnce { pausedOnce = true;jobs.scheduler.pause() } }
                do { _ = try jobs.submitTransfer(try TransferPlanner.prepare([large],to:right,kind:.copy,policy:.stop),start:true,completion:{ _ in }) } catch { check(false,"pausable copy plan") }
                await wait("paused transfer") { jobs.active?.state == .paused };queue.refresh();await activate(queueWindow);queueWindow.makeFirstResponder(queue.table)
                check(queue.pause.title == "Fortsetzen" && queue.pause.toolTip?.contains("Leertaste") == true,"paused queue exposes its Space shortcut and current action")
                check(NSApp.mainMenu?.performKeyEquivalent(with:key(queueWindow,".",[.command,.option])) == true,"global cancel shortcut is dispatched through the native menu")
                await wait("cancelled partial") { jobs.pending == 0 };jobs.transferProgressObserver = nil
                let partial = require(history.inspect().first { $0.kind == .partial },"cancelled partial")
                check(partial.bytes > 0 && partial.bytes < partial.totalBytes && !FileSystem.exists(right.appendingPathComponent("Groß.bin")),"keyboard cancellation retains an unpublished resumable partial")
                check(NSApp.mainMenu?.performKeyEquivalent(with:key(queueWindow,"j",[.command,.option])) == true,"native recovery shortcut opens the recovery workspace")
                let recovery = require(main.recoveryWindow,"recovery workspace"),window = require(recovery.window,"recovery window")
                await activate(window);await wait("recovery catalog") { !recovery.isLoading && recovery.rows.count == 2 }
                check(recovery.rows.filter { $0.kind == .backup }.count == 1 && recovery.rows.filter { $0.kind == .partial }.count == 1,"recovery lists backups and partials independently")
                check(window.performKeyEquivalent(with:key(window,"f",.command)),"recovery Command F focuses search")
                type(recovery.search,"Kopie");check(recovery.rows.count == 1 && recovery.rows[0].kind == .backup,"recovery search filters the real catalog without changing it")
                type(recovery.search,"");window.makeFirstResponder(recovery.table)
                check(window.performKeyEquivalent(with:key(window,"3",.command)),"Command 3 selects partial copies")
                check(recovery.rows.count == 1 && recovery.selected?.id == partial.id,"kind shortcuts keep a visible selected entry")
                window.appearance = NSAppearance(named:.aqua);await capture(window,"-Teilkopien-Hell")
                window.appearance = NSAppearance(named:.darkAqua);await capture(window,"-Teilkopien-Dunkel")
                check(recovery.discard.toolTip?.contains("⌘⌫") == true && queue.review.toolTip?.contains("⌘R") == true,"recovery and queue actions explain their keyboard bindings")
                check((try? String(contentsOf:source,encoding:.utf8)) == "Neu\n" && FileSystem.exists(large),"all workflow checks preserve their copy sources")
            }
            print("RECOVERY SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
