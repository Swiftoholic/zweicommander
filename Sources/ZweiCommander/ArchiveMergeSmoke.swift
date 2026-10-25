import AppKit
import CommanderCore

extension AppDelegate {
    func runArchiveMergeSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("ARCHIVE MERGE UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("ARCHIVE MERGE SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<400 { if predicate() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("ARCHIVE MERGE SMOKE FAIL timeout "+name+" active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none")");exit(1)
            }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active workflow") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func key(_ window:NSWindow,_ text:String,_ modifiers:NSEvent.ModifierFlags = []) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0),"key event") }
            @MainActor func prepared(_ form:ArchiveSetupController) async { await wait("review plan") { form.prepared != nil && !form.isPreparing } }
            @MainActor func settle() async { await wait("jobs and listings") { self.main.jobs.pending == 0 && !self.main.left.isLoading && !self.main.right.isLoading && !self.main.left.isSorting && !self.main.right.isSorting } }
            @MainActor func capture(_ window:NSWindow,_ name:String) throws {
                let view = require(window.contentView,"content view");view.layoutSubtreeIfNeeded();view.displayIfNeeded();let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap")
                view.cacheDisplay(in:view.bounds,to:bitmap);try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+name+".png"))
            }
            let main = self.main!,left = main.left,window = require(main.window,"main window"),target = root.appendingPathComponent("Rechts"),source = root.appendingPathComponent("Links/Incoming")
            let clipboard = NSPasteboard.general.changeCount
            @MainActor func form(_ catalog:ArchiveCatalog,to destination:URL) async -> ArchiveSetupController {
                let selection = (try? catalog.contents(of:"Incoming"))?.map(\.path)
                main.showArchiveSetup(mode:.extract(catalog.source,catalog,selection,"Incoming"),destination:destination)
                let value = require(main.secondaryWindows.last as? ArchiveSetupController,"archive review");await prepared(value);return value
            }
            @MainActor func choose(_ form:ArchiveSetupController,_ path:String,_ id:String) {
                guard let row = form.rows.firstIndex(where:{$0.path == path}),let column = form.table.tableColumns.firstIndex(where:{$0.identifier.rawValue == "decision"}),let popup = form.table.view(atColumn:column,row:row,makeIfNecessary:true) as? NSPopUpButton,let item = popup.itemArray.firstIndex(where:{$0.representedObject as? String == id}) else { check(false,"decision control for "+path);return }
                form.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);popup.selectItem(at:item);_ = popup.sendAction(popup.action,to:popup.target)
                check(form.prepared?.merge?.action(for:path) != nil,"native decision selected: "+path+" / "+id)
            }
            do {
                await settle();await activate(window);left.focus();window.title = "ZweiCommander · Archivkonflikte prüfen"
                let bundle = root.appendingPathComponent("Bundle.zip");try ArchiveService.pack([source],to:bundle);let catalog = try ArchiveCatalog.read(bundle)
                let review = await form(catalog,to:target),reviewWindow = require(review.window as? WorkflowWindow,"review window");await activate(reviewWindow)
                check(review.prepared?.merge?.unresolvedCount == 5 && !review.start.isEnabled && !review.queue.isEnabled,"five unresolved conflicts block both submission methods")
                check(review.table.tableColumns.map(\.identifier.rawValue) == ["name","decision","size","targetSize","sourceDate","targetDate","target"],"review exposes source target sizes dates names and individual decisions")
                check(review.policy.numberOfItems == 5 && review.policy.toolTip?.contains("⌘5") == true,"all five collective policies have keyboard help")
                check(reviewWindow.performKeyEquivalent(with:key(reviewWindow,"2",.command)) && review.prepared?.merge?.skippedCount == 6,"Command 2 skips every conflicting file or subtree")
                check(review.start.isEnabled && review.queue.isEnabled,"resolved skip rule enables submission")
                check(reviewWindow.performKeyEquivalent(with:key(reviewWindow,"4",.command)) && review.prepared?.merge?.unresolvedCount == 1,"Command 4 keeps an incompatible directory conflict for explicit review")
                check(review.prepared?.merge?.action(for:"Replace.txt")?.decision == .replace && review.prepared?.merge?.action(for:"Keep.txt")?.decision == .skip,"older-only rule compares actual source and target dates")
                check(reviewWindow.performKeyEquivalent(with:key(reviewWindow,"1",.command)) && review.prepared?.merge?.unresolvedCount == 5,"Command 1 restores individual review")
                let beforeRows = review.rows.count;review.conflictsOnly.performClick(nil)
                check(review.rows.count == 5 && review.rows.count < beforeRows,"conflict filter hides unproblematic rows")
                check(reviewWindow.performKeyEquivalent(with:key(reviewWindow,String(UnicodeScalar(NSDownArrowFunctionKey)!),[.command,.option])) && review.table.selectedRow >= 0,"Command Option Down selects an unresolved conflict")
                let first = review.table.selectedRow;review.nextConflict.performClick(nil);check(review.table.selectedRow != first,"next-conflict button advances between pending rows")
                check(reviewWindow.performKeyEquivalent(with:key(reviewWindow,String(UnicodeScalar(NSUpArrowFunctionKey)!),[.command,.option])) && review.table.selectedRow == first,"Command Option Up returns to the prior conflict")
                if let row = review.rows.firstIndex(where:{$0.path == "Replace.txt"}),let sourceDate = review.table.view(atColumn:4,row:row,makeIfNecessary:true) as? NSTextField,let targetDate = review.table.view(atColumn:5,row:row,makeIfNecessary:true) as? NSTextField {
                    check(!sourceDate.stringValue.isEmpty && sourceDate.stringValue != targetDate.stringValue,"native date columns distinguish older destination content")
                } else { check(false,"date cells") }
                if let row = review.rows.firstIndex(where:{$0.path == "Conflict"}),let popup = review.table.view(atColumn:1,row:row,makeIfNecessary:true) as? NSPopUpButton {
                    check(!popup.itemArray.contains { $0.representedObject as? String == "replace" },"directory-link conflict cannot offer overwrite")
                } else { check(false,"type conflict choices") }
                choose(review,"Keep.txt","skip");choose(review,"Both.txt","both");choose(review,"Replace.txt","replace");choose(review,"Rename.txt","rename")
                let rename = require(review.renameController,"rename sheet"),renameWindow = require(rename.window as? WorkflowWindow,"rename window");await activate(renameWindow)
                check(reviewWindow.attachedSheet === renameWindow && rename.name.stringValue == "Rename (2).txt","rename sheet starts with a frozen free name")
                rename.name.stringValue = "../escape";rename.submit()
                check(reviewWindow.attachedSheet === renameWindow && rename.info.textColor == .systemRed && review.prepared?.merge?.action(for:"Rename.txt")?.decision == .pending,"invalid rename stays inline and preserves the pending decision")
                rename.name.stringValue = "Renamed.txt";check(renameWindow.performKeyEquivalent(with:key(renameWindow,"\r",.command)),"Command Return submits the rename sheet")
                await wait("closed rename sheet") { reviewWindow.attachedSheet == nil };await activate(reviewWindow)
                check(review.prepared?.merge?.targetPath(for:review.prepared!.merge!.action(for:"Rename.txt")!) == "Renamed.txt","accepted custom name is visible in the reviewed plan")
                choose(review,"Conflict","both")
                check(review.prepared?.merge?.unresolvedCount == 0 && review.start.isEnabled && review.queue.isEnabled,"mixed per-file choices resolve the complete plan")
                review.conflictsOnly.performClick(nil);check(review.prepared?.merge?.action(for:"Replace.txt")?.decision == .replace && review.rows.count == beforeRows,"removing the filter retains individual decisions")
                check(reviewWindow.performKeyEquivalent(with:key(reviewWindow,"l",.command)) && review.destination.currentEditor() is NSTextView,"Command L focuses the destination text editor")
                check((try String(contentsOf:target.appendingPathComponent("Replace.txt"),encoding:.utf8)) == "old replace\n" && !FileSystem.exists(target.appendingPathComponent("Fresh.txt")),"all review and naming steps leave target contents unchanged")
                reviewWindow.contentView?.layoutSubtreeIfNeeded()
                check(review.table.rect(ofColumn:6).maxX <= review.table.visibleRect.maxX+1 && review.table.tableColumns[6].width >= 150,"all conflict columns including the reviewed target fit the initial window")
                for (mode,name) in [(1,"Hell"),(2,"Dunkel")] {
                    Preferences.state.theme = mode;main.applyTheme();try? await Task.sleep(nanoseconds:150_000_000)
                    check(reviewWindow.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (mode == 1 ? .aqua : .darkAqua),"conflict review follows "+name+" appearance")
                    try capture(reviewWindow,"-Archivkonflikte-"+name)
                }
                let rootView = require(reviewWindow.contentView,"review root")
                check(review.destination.frame.maxX < review.choose.frame.minX && review.info.frame.maxY < (rootView.subviews.first {$0 is NSScrollView}?.frame.minY ?? 0),"review target controls and footer do not overlap")
                review.password.stringValue = "synthetic-archive-merge";review.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:review.password))
                check(review.prepared?.merge?.unresolvedCount == 0,"changing only the password preserves reviewed decisions")
                await activate(reviewWindow);let planned = require(review.prepared?.merge,"resolved plan")
                check(reviewWindow.performKeyEquivalent(with:key(reviewWindow,"\r",[.command,.shift])),"Command Shift Return queues the resolved plan")
                await wait("queued merge") { review.window?.isVisible == false && main.jobs.scheduler.snapshots.contains { $0.state == .waiting } }
                let snapshot = require(main.jobs.scheduler.snapshots.last,"waiting job")
                check(snapshot.items.count == planned.actions.count && snapshot.totalBytes == planned.totalBytes && snapshot.items.filter {$0.state == .skipped}.count == 1,"queue shows the complete chosen object and byte plan")
                check(main.jobs.journal?.entry(snapshot.id) == nil && review.password.stringValue.isEmpty,"archive queue remains session-only and closing clears its password")
                check(!FileSystem.exists(target.appendingPathComponent("Fresh.txt")),"queued extraction does not start by itself")
                let queue = require(main.operationWindow,"queue"),queueWindow = require(queue.window as? WorkflowWindow,"queue window");await activate(queueWindow)
                check(queueWindow.performKeyEquivalent(with:key(queueWindow,"\r")),"queue Enter starts the selected archive merge");await settle()
                let done = require(main.jobs.scheduler.snapshots.last,"completed job")
                check(done.state == .completed && done.fraction == 1 && done.transferredBytes == planned.totalBytes,"merge completes with measured bytes and final progress")
                check((try String(contentsOf:target.appendingPathComponent("Keep.txt"),encoding:.utf8)) == "old keep\n","skip preserves prior content")
                check(try String(contentsOf:target.appendingPathComponent("Both.txt"),encoding:.utf8) == "old both\n" && String(contentsOf:target.appendingPathComponent("Both (2).txt"),encoding:.utf8) == "new both\n","keep-both publishes exactly the reviewed alternate")
                check((try String(contentsOf:target.appendingPathComponent("Replace.txt"),encoding:.utf8)) == "new replace\n","overwrite publishes the selected archive bytes")
                check(try String(contentsOf:target.appendingPathComponent("Renamed.txt"),encoding:.utf8) == "new rename\n" && String(contentsOf:target.appendingPathComponent("Rename.txt"),encoding:.utf8) == "old rename\n","custom rename preserves the previous name and content")
                check((try String(contentsOf:target.appendingPathComponent("Dir/new.txt"),encoding:.utf8)) == "nested\n" && FileSystem.isDirectory(target.appendingPathComponent("Empty")),"new nested and empty directories are included")
                check((try String(contentsOf:target.appendingPathComponent("only-target.txt"),encoding:.utf8)) == "target only\n","unrelated destination entries remain unchanged")
                check(FileSystem.isSymlink(target.appendingPathComponent("Conflict")) && !FileSystem.exists(root.appendingPathComponent("Outside/child.txt")) && FileSystem.exists(target.appendingPathComponent("Conflict (2)/child.txt")),"renamed directory subtree never follows the conflicting link")
                let backup = require(main.undoSteps.first {$0.backup != nil}?.backup,"replacement backup")
                check((try String(contentsOf:backup,encoding:.utf8)) == "old replace\n" && main.jobs.history?.inspect().contains {$0.kind == .backup && $0.available} == true,"overwritten content appears in persistent recovery")
                queue.close();await activate(window)
                let stale = await form(catalog,to:target);stale.policy.selectItem(at:1);stale.policyChanged();try Data("concurrent target\n".utf8).write(to:target.appendingPathComponent("Fresh.txt"))
                // An explicit overwrite observes the old reviewed version and must be rejected after this edit.
                try stale.applyDecision("Fresh.txt",.replace);let staleWindow = require(stale.window,"stale review");await activate(staleWindow);stale.submit(true)
                await wait("stale submission review") { !stale.isPreparing && stale.prepared?.merge != nil }
                check(stale.window?.isVisible == true && (stale.prepared?.merge?.unresolvedCount ?? 0) > 0,"changed target forces a refreshed review without enqueuing")
                check((try String(contentsOf:target.appendingPathComponent("Fresh.txt"),encoding:.utf8)) == "concurrent target\n","stale plan cannot replace a later edit");stale.close()
                let bulkSource = root.appendingPathComponent("Many/Incoming"),bulkZip = root.appendingPathComponent("Many.zip");try ArchiveService.pack([bulkSource],to:bulkZip)
                let bulk = await form(try ArchiveCatalog.read(bulkZip),to:root.appendingPathComponent("BulkTarget")),bulkWindow = require(bulk.window as? WorkflowWindow,"bulk review");await activate(bulkWindow)
                check(bulk.prepared?.merge?.unresolvedCount == 520 && bulk.rows.count == 500 && bulk.nextPage.isEnabled,"large conflict preview keeps every decision with a bounded page")
                bulk.nextPage.performClick(nil);check(bulk.rows.count == 20 && bulk.previousPage.isEnabled && !bulk.nextPage.isEnabled,"next page exposes remaining conflicts")
                bulk.table.deselectAll(nil);bulk.focusConflict(backward:true);check(bulk.previewPage == 1 && bulk.table.selectedRow == 19,"previous conflict can reach the last pending item")
                bulk.focusConflict(backward:false);check(bulk.previewPage == 0 && bulk.table.selectedRow == 0,"conflict navigation wraps across preview pages")
                check(bulkWindow.performKeyEquivalent(with:key(bulkWindow,"5",.command)) && bulk.prepared?.merge?.unresolvedCount == 0 && bulk.start.isEnabled,"Command 5 resolves all 520 conflicts beyond the visible page")
                check(bulkWindow.performKeyEquivalent(with:key(bulkWindow,"\u{1b}")),"Escape closes the unsubmitted bulk review")
                check(!FileSystem.exists(root.appendingPathComponent("BulkTarget/item-0000 (2).txt")),"closing a fully reviewed preview makes no writes")
                let encoded = String(decoding:try JSONEncoder().encode(Preferences.state),as:UTF8.self)
                check(!encoded.contains("synthetic-archive-merge") && !encoded.contains("ArchiveMergePlan"),"passwords and per-operation decisions never enter preferences")
            } catch { check(false,error.localizedDescription) }
            check(NSPasteboard.general.changeCount == clipboard,"merge checks leave the user's clipboard untouched")
            print("ARCHIVE MERGE SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
