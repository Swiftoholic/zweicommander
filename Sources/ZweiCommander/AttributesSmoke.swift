import AppKit
import CommanderCore
import Darwin

extension AppDelegate {
    func runAttributesSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            @MainActor func check(_ value:Bool,_ name:String) { checks += 1;print("ATTRIBUTES UI \(value ? "PASS" : "FAIL") "+name);if !value { failures.append(name);print("ATTRIBUTES UI CONTEXT active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none")") } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("ATTRIBUTES SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async { for _ in 0..<700 { if predicate() { return };try? await Task.sleep(nanoseconds:30_000_000) };print("ATTRIBUTES SMOKE FAIL timeout "+name);exit(1) }
            @MainActor func ready(_ editor:AttributesController) async { await wait("attribute preview") { !editor.isPreparing && !editor.isWorking } }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active attributes window") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func key(_ window:NSWindow,_ text:String,_ flags:NSEvent.ModifierFlags = []) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0),"key") }
            @MainActor func capture(_ window:NSWindow,_ name:String) throws { let view = require(window.contentView,"content");view.layoutSubtreeIfNeeded();view.displayIfNeeded();let image = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap");view.cacheDisplay(in:view.bounds,to:image);try require(image.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+"-Rechte-Zeitstempel-"+name+".png")) }
            @MainActor func toggle(_ editor:AttributesController,_ name:String) { guard let index = editor.rows.firstIndex(where:{$0.source.lastPathComponent == name}) else { print("ATTRIBUTES SMOKE FAIL missing row "+name);exit(1) };let button = NSButton();button.tag = index;editor.toggleRow(button) }
            func handles(_ source:URL) throws -> Int {
                var expected = stat();guard lstat(source.path,&expected) == 0 else { throw CommanderError.message("FD-Lebensdauerprüfung: Quelldatei fehlt.") }
                let needed = proc_pidinfo(getpid(),PROC_PIDLISTFDS,0,nil,0)
                guard needed > 0 else { throw CommanderError.message("FD-Lebensdauerprüfung: Prozessliste nicht lesbar.") }
                var entries = [proc_fdinfo](repeating:proc_fdinfo(),count:Int(needed)/MemoryLayout<proc_fdinfo>.stride+64)
                let used = entries.withUnsafeMutableBytes { proc_pidinfo(getpid(),PROC_PIDLISTFDS,0,$0.baseAddress,Int32($0.count)) }
                guard used > 0,Int(used) < entries.count*MemoryLayout<proc_fdinfo>.stride else { throw CommanderError.message("FD-Lebensdauerprüfung: Prozessliste unvollständig.") }
                return entries.prefix(Int(used)/MemoryLayout<proc_fdinfo>.stride).filter { entry in var value = stat();return fstat(entry.proc_fd,&value) == 0 && value.st_dev == expected.st_dev && value.st_ino == expected.st_ino }.count
            }
            @MainActor func queuedRestricted(_ source:URL) async throws -> AttributesController {
                self.main.active.navigate(source.deletingLastPathComponent());self.main.active.refresh()
                await wait("FD fixture listing") { !self.main.active.isLoading && self.main.active.canUseDisplayedEntries && self.main.active.visibleEntries.contains(where:{$0.name == source.lastPathComponent}) }
                await activate(self.main.window!);let entry = require(self.main.active.visibleEntries.first(where:{$0.name == source.lastPathComponent}),"FD fixture entry");self.main.active.select([entry.url]);self.main.active.focus();self.main.attributes()
                let controller = require(self.main.secondaryWindows.last as? AttributesController,"FD fixture controller");await ready(controller)
                controller.permissions.stringValue = "0000";controller.prepare();await ready(controller);controller.submit(true);await ready(controller)
                guard controller.lastReport?.errors.isEmpty == true,controller.receipts.count == 1 else { throw CommanderError.message("FD-Lebensdauerprüfung: Teständerung in Warteschlange fehlgeschlagen.") }
                return controller
            }
            do {
                await wait("initial lists") { !self.main.left.isLoading && !self.main.right.isLoading }
                let links = root.appendingPathComponent("Links"),tree = links.appendingPathComponent("AttrTree"),a = tree.appendingPathComponent("A.txt"),b = tree.appendingPathComponent("B.txt"),ignored = tree.appendingPathComponent("Keep.bin"),cached = tree.appendingPathComponent("Cache/C.txt"),alias = tree.appendingPathComponent("Alias.txt")
                try FileManager.default.createDirectory(at:cached.deletingLastPathComponent(),withIntermediateDirectories:true)
                for (url,text) in [(a,"Alpha"),(b,"Beta"),(ignored,"Bin"),(cached,"Cache")] { try Data(text.utf8).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o644,.modificationDate:Date(timeIntervalSince1970:1_700_000_000)],ofItemAtPath:url.path) }
                try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:b)
                let clipboard = NSPasteboard.general.changeCount,saved = UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:]
                self.main.active.navigate(links);self.main.active.refresh();await wait("fixture listing") { !self.main.active.isLoading && self.main.active.canUseDisplayedEntries && self.main.active.visibleEntries.contains(where:{$0.name == tree.lastPathComponent}) }
                self.main.active.select([tree]);await activate(self.main.window!);self.main.active.focus();self.main.attributes()
                let editor = require(self.main.secondaryWindows.last as? AttributesController,"attributes controller"),window = require(editor.window as? WorkflowWindow,"workflow window")
                await activate(window);await ready(editor)
                check(editor.plan?.rows.count == 1 && editor.plan?.canApply == false,"initial direct selection has no implicit changes")
                check(!editor.start.isEnabled && !editor.queue.isEnabled,"empty change rules cannot start or queue")
                check(editor.onSubmit != nil && editor.onCancel != nil,"native attribute workspace joins shared job and cancellation hooks")
                check(editor.start.toolTip?.contains("⌘↩") == true && editor.criteria.toolTip?.contains("⌘⌥O") == true,"button hover help exposes scoped shortcuts")
                check(!window.canPerformCommand("trash") && !window.canPerformCommand("move"),"attribute workspace cannot modify the obscured file pane")
                check(window.performKeyEquivalent(with:key(window,"l",.command)) && editor.permissions.currentEditor() is NSTextView,"Command L focuses the permission input")
                editor.permissions.stringValue = "0600";editor.recursive.state = .on;editor.folders.state = .off;editor.include.stringValue = "*.txt";editor.excludedFolders.stringValue = "Cache"
                editor.modifiedMode.selectItem(at:2);editor.modifiedValue.stringValue = "+3600";editor.createdMode.selectItem(at:2);editor.createdValue.stringValue = "-60";editor.accessedMode.selectItem(at:1);editor.accessedValue.stringValue = "2024-01-01 12:30:00";editor.timeZone.selectItem(at:1);editor.updateTimeInputs();editor.prepare();await ready(editor)
                check(editor.plan?.rows.count == 6 && editor.plan?.selectedRows.count == 2,"recursive review expands files while retaining ignored rows")
                check(editor.plan?.rows.first(where:{$0.source.lastPathComponent == "Alias.txt"})?.canSelect == false,"link row remains visible and cannot authorize a change")
                check(editor.plan?.rows.contains(where:{$0.source.lastPathComponent == "C.txt"}) == false,"excluded folder is not traversed")
                let previewA = require(editor.plan?.selectedRows.first(where:{$0.source.lastPathComponent == "A.txt"}),"A preview")
                check(previewA.after?.permissions == 0o600 && previewA.after?.modified.seconds == 1_700_003_600,"before and after values bind permissions and relative modification time")
                check(previewA.after?.created.seconds == previewA.before.created.seconds-60 && previewA.after?.created.nanoseconds == previewA.before.created.nanoseconds,"relative creation shift preserves subsecond precision")
                check(previewA.after?.accessed.seconds == 1_704_112_200,"absolute access time uses the explicitly selected UTC zone")
                check(try AttributeSnapshot.read(a).permissions == 0o644 && AttributeSnapshot.read(a).modified.seconds == 1_700_000_000,"preview leaves original permissions and dates unchanged")
                check(window.performKeyEquivalent(with:key(window,"f",.command)) && editor.reviewFilter.currentEditor() is NSTextView,"Command F focuses the preview filter")
                editor.reviewFilter.stringValue = "A.txt";editor.filterRows()
                check(editor.rows.count == 1 && editor.plan?.selectedRows.count == 2,"visible filtering cannot silently deselect hidden planned changes")
                editor.reviewFilter.stringValue = "";editor.filterRows();toggle(editor,"B.txt")
                check(editor.plan?.selectedRows.map { $0.source.lastPathComponent } == ["A.txt"],"row checkbox excludes exactly the reviewed file")
                editor.permissions.stringValue = "888";editor.prepare();await ready(editor)
                check(editor.plan == nil && !editor.start.isEnabled && editor.info.textColor == .systemRed,"invalid octal permissions invalidate the executable preview")
                editor.permissions.stringValue = "0600";editor.modifiedMode.selectItem(at:1);editor.modifiedValue.stringValue = "2024-02-30 10:00:00";editor.prepare();await ready(editor)
                check(editor.plan == nil && !editor.queue.isEnabled,"invalid calendar date cannot enter the queue")
                editor.modifiedMode.selectItem(at:2);editor.modifiedValue.stringValue = "+3600";editor.prepare();editor.permissions.stringValue = "invalid";editor.prepare();try? await Task.sleep(nanoseconds:250_000_000)
                check(editor.plan == nil && !editor.isPreparing && !editor.start.isEnabled,"late valid preparation cannot overwrite newer invalid edits")
                editor.permissions.stringValue = "0600";editor.prepare();await ready(editor)
                check(editor.plan?.selectedRows.count == 1,"explicit row exclusion survives a fresh rule preview")
                editor.prepare();editor.cancelWork();try? await Task.sleep(nanoseconds:180_000_000)
                check(!editor.isPreparing && editor.plan == nil && !editor.queue.isEnabled,"canceling preparation discards pending executable results")
                editor.prepare();await ready(editor)
                window.makeFirstResponder(editor.table)
                for (theme,name) in [(1,"Hell"),(2,"Dunkel")] { Preferences.state.theme = theme;self.main.applyTheme();try? await Task.sleep(nanoseconds:120_000_000);check(window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (theme == 1 ? .aqua : .darkAqua),"attribute workspace follows "+name+" appearance");try capture(window,name) }
                check(editor.scroll.frame.maxY < editor.reviewFilter.frame.minY && editor.result.frame.maxY < editor.info.frame.minY,"review table and status controls remain separate")
                let expected = require(editor.plan,"executable plan"),expectedA = require(expected.selectedRows.first,"selected A"),baseline = Set(self.main.jobs.scheduler.snapshots.map(\.id))
                await activate(window);window.makeFirstResponder(editor.table)
                check(window.performKeyEquivalent(with:key(window,"\r",[.command,.shift])),"Command Shift Return queues the actual attribute workflow")
                await wait("queued attribute job") { editor.isWorking && self.main.jobs.scheduler.snapshots.contains(where:{!baseline.contains($0.id) && $0.state == .waiting}) }
                let job = require(self.main.jobs.scheduler.snapshots.first(where:{!baseline.contains($0.id)}),"queued job")
                check(!editor.start.isEnabled && !editor.permissions.isEnabled && job.items.count == 1,"queued job freezes the exact chosen object and rule fields")
                check(try AttributeSnapshot.read(a).permissions == 0o644,"queued attribute job has not changed file metadata")
                self.main.jobs.scheduler.start(job.id);await ready(editor)
                let report = require(editor.lastReport,"completed report"),actual = try AttributeSnapshot.read(a)
                check(report.errors.isEmpty && report.completed.count == 1 && editor.receipts.count == 1,"shared queue completes with a guarded session receipt")
                check(actual.permissions == 0o600 && actual.modified == expectedA.after?.modified && actual.created == expectedA.after?.created && actual.accessed == expectedA.after?.accessed,"native execution applies exactly the previewed time fields and permissions")
                check(try AttributeSnapshot.read(b).permissions == 0o644 && AttributeSnapshot.read(b).modified.seconds == 1_700_000_000,"unchecked file retains its original metadata")
                check(try AttributeSnapshot.read(ignored).permissions == 0o644 && AttributeSnapshot.read(cached).permissions == 0o644,"name and folder exclusions remain unchanged after queued execution")
                check(editor.undo.isEnabled && !editor.start.isEnabled,"completed state offers guarded undo without repeating already-applied changes")
                await activate(window);window.makeFirstResponder(editor.permissions);editor.permissions.selectText(nil)
                check(!editor.handleKey(key(window,"z",.command)) && editor.receipts.count == 1,"text editing keeps Command Z without triggering metadata undo")
                window.makeFirstResponder(editor.table)
                check(window.performKeyEquivalent(with:key(window,"z",.command)),"Command Z outside text fields starts the workspace undo")
                await ready(editor)
                let restored = try AttributeSnapshot.read(a)
                check(editor.receipts.isEmpty && restored.permissions == expectedA.before.permissions && restored.created == expectedA.before.created && restored.modified == expectedA.before.modified && restored.accessed == expectedA.before.accessed,"guarded undo restores exact preview metadata including nanoseconds")
                check(try Data(contentsOf:a) == Data("Alpha".utf8) && Data(contentsOf:b) == Data("Beta".utf8),"attribute changes and undo preserve file bytes")
                editor.prepare();await ready(editor);await activate(window);window.makeFirstResponder(editor.table)
                let beforeCancellation = Set(self.main.jobs.scheduler.snapshots.map(\.id));editor.queue.performClick(nil)
                await wait("second queued attribute job") { editor.isWorking && self.main.jobs.scheduler.snapshots.contains(where:{!beforeCancellation.contains($0.id) && $0.state == .waiting}) }
                let cancelled = require(self.main.jobs.scheduler.snapshots.first(where:{!beforeCancellation.contains($0.id)}),"cancellation job");editor.cancelWork();await ready(editor)
                check(self.main.jobs.scheduler.snapshots.first(where:{$0.id == cancelled.id})?.state == .cancelled,"workspace Stop cancels its waiting job through the shared queue")
                check(editor.lastReport?.errors.isEmpty == false && !editor.isWorking,"queued cancellation delivers a terminal result to the native workspace")
                check(try AttributeSnapshot.read(a).permissions == restored.permissions && AttributeSnapshot.read(b).permissions == 0o644,"canceling a queued plan leaves reviewed files unchanged")
                check(!editor.start.isEnabled && editor.receipts.isEmpty,"cancelled queue result cannot retain an executable plan or fabricate undo receipts")
                editor.prepare();editor.close();try? await Task.sleep(nanoseconds:180_000_000)
                check(editor.closed && !window.isVisible && editor.plan == nil,"closing cancels preparation and cannot publish a late plan")
                let lifetime = root.appendingPathComponent("FDLifetime"),undoFile = lifetime.appendingPathComponent("Undo.txt"),closeFile = lifetime.appendingPathComponent("Close.txt")
                try FileManager.default.createDirectory(at:lifetime,withIntermediateDirectories:true);try Data("undo lifetime".utf8).write(to:undoFile);try Data("close lifetime".utf8).write(to:closeFile)
                let undoEditor = try await queuedRestricted(undoFile)
                check(try handles(undoFile) == 1 && undoEditor.lastReport?.receipts.isEmpty == true && undoEditor.lastReport?.completed.count == 1,"summary report retains no descriptors beyond the single live undo receipt")
                undoEditor.undoChanges();await ready(undoEditor);await wait("released undone metadata descriptor") { (try? handles(undoFile)) == 0 }
                check(try handles(undoFile) == 0 && undoEditor.receipts.isEmpty && undoEditor.lastReport?.completed.count == 1,"fully undone batch releases its actual file descriptor while preserving summary fields")
                undoEditor.close()
                let closeEditor = try await queuedRestricted(closeFile)
                check(try handles(closeFile) == 1 && closeEditor.receipts.count == 1,"restrictive file retains exactly one descriptor before workspace close")
                closeEditor.close();await wait("released closed metadata descriptor") { (try? handles(closeFile)) == 0 }
                check(try handles(closeFile) == 0 && closeEditor.closed && self.main.secondaryWindows.contains(where:{$0 === closeEditor}),"closed controller retained by the main window releases all receipt descriptors")
                check(NSPasteboard.general.changeCount == clipboard,"attributes workflow leaves the general clipboard untouched")
                check((saved as NSDictionary).isEqual(to:UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:]),"attributes workflow does not persist personal settings")
                print("ATTRIBUTES SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");fflush(stdout);exit(failures.isEmpty ? 0 : 1)
            } catch { print("ATTRIBUTES SMOKE FAIL "+error.localizedDescription);fflush(stdout);exit(1) }
        }
    }
}
