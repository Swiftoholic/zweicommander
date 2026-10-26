import AppKit
import CommanderCore

extension AppDelegate {
    func runMirrorSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            @MainActor func check(_ value:Bool,_ name:String) { checks += 1;print("MIRROR UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name);print("MIRROR UI CONTEXT active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none") front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")") } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("MIRROR SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async { for _ in 0..<800 { if predicate() { return };try? await Task.sleep(nanoseconds:25_000_000) };print("MIRROR SMOKE FAIL timeout "+name);exit(1) }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active test window") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func ready(_ viewer:MirrorReviewController) async { await wait("mirror review") { !viewer.isPreparing && viewer.plan != nil } }
            @MainActor func key(_ window:NSWindow,_ value:String,_ flags:NSEvent.ModifierFlags = []) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:value,charactersIgnoringModifiers:value,isARepeat:false,keyCode:0),"key event") }
            @MainActor func capture(_ window:NSWindow,_ name:String) throws { let view = require(window.contentView,"view");view.layoutSubtreeIfNeeded();view.displayIfNeeded();let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap");view.cacheDisplay(in:view.bounds,to:bitmap);try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+name+".png")) }
            func write(_ relative:String,_ value:String) throws { let url = root.appendingPathComponent(relative);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(value.utf8).write(to:url) }
            func read(_ relative:String) -> String? { try? String(contentsOf:root.appendingPathComponent(relative),encoding:.utf8) }
            do {
                await wait("main listings") { !self.main.left.isLoading && !self.main.right.isLoading };self.main.saveState()
                let state = try JSONEncoder().encode(Preferences.state),tabs = try JSONEncoder().encode([self.main.left.savedTabs,self.main.right.savedTabs]),clipboard = NSPasteboard.general.changeCount
                try write("Links/New.txt","new source");try write("Links/Changed.txt","new shared");try write("Rechts/Changed.txt","old shared");try write("Rechts/Extra.txt","extra data");try write("Rechts/ExtraFolder/deep.txt","nested extra");try write("Rechts/Cache/private.txt","excluded");try write("Rechts/Keep.bin","not selected");try write("Rechts/.secret.txt","hidden")
                self.main.compare();let controller = require(self.main.secondaryWindows.last as? CompareController,"comparison controller")
                check(controller.onSubmitMirror != nil,"comparison workspace connects mirror execution to the common queue")
                var options = CompareOptions();options.include = "*.txt";options.excludedFolders = "Cache";options.showHidden = false;controller.setOptions(options);controller.beginCompare()
                await wait("comparison") { !controller.isComparing && !controller.isPreparingPlan && controller.comparison != nil }
                check(controller.plan?.steps.count == 2,"ordinary synchronization still prepares only its two copy steps")
                let shortcuts = Preferences.state.shortcuts;Preferences.state.shortcuts["compare"] = "cmd+shift+m";controller.refreshFileCompareHelp()
                let preservesCustom = controller.mirrorButton.keyEquivalent.isEmpty && controller.mirrorButton.toolTip?.contains("⌘⇧M") == false
                Preferences.state.shortcuts = shortcuts;controller.refreshFileCompareHelp()
                check(controller.mirrorButton.isEnabled && preservesCustom && controller.mirrorButton.keyEquivalent.lowercased() == "m","mirror review preserves custom commands and restores its local shortcut help")
                await activate(controller.window!)
                check(controller.window!.performKeyEquivalent(with:key(controller.window!,"M",[.command,.shift])),"Command Shift M opens the local mirror review")
                await wait("mirror sheet") { controller.mirrorWindow?.window?.sheetParent != nil }
                let review = require(controller.mirrorWindow,"mirror controller"),window = require(review.window as? WorkflowWindow,"workflow window");await ready(review);await activate(window)
                check(review.plan?.direction == .leftToRight,"initial mirror direction is explicit and left to right")
                check(review.plan?.copies.steps.count == 2,"mirror copies new and changed files")
                check(Set(review.plan?.removals.map(\.path) ?? []) == Set(["Extra.txt","ExtraFolder"]),"target-only file and complete folder are separate reviewed removals")
                check(review.rows.contains { $0.path == "ExtraFolder/deep.txt" && $0.kind == 1 },"every retained subtree member is visible in the removal preview")
                check(review.confirmRemovals.state == .off && !review.start.isEnabled && !review.queue.isEnabled,"removals require explicit confirmation before start or queue")
                check(window.performKeyEquivalent(with:key(window,"\r",.command)) && window.sheetParent != nil && !controller.isWorking,"Command Return cannot bypass removal confirmation")
                check(read("Rechts/Extra.txt") == "extra data" && read("Rechts/New.txt") == nil,"opening and unconfirmed submission leave targets unchanged")
                check(window.performKeyEquivalent(with:key(window,"f",.command)) && review.filter.currentEditor() is NSTextView,"Command F focuses the mirror preview filter")
                window.makeFirstResponder(review.table);review.filter.stringValue = "deep.txt";review.filterRows()
                check(review.visibleRows.count == 1 && review.plan?.removals.count == 2,"preview filtering never changes the complete removal plan")
                review.filter.stringValue = "";review.scope.selectItem(at:2);review.filterRows()
                check(review.visibleRows.allSatisfy { $0.kind == 1 } && review.visibleRows.count == 3,"removal filter contains both the subtree and its member")
                let row = require(review.visibleRows.firstIndex { $0.path == "ExtraFolder/deep.txt" },"descendant preview row")
                let choice = require(review.table.view(atColumn:0,row:row,makeIfNecessary:true) as? NSButton,"native selection checkbox");choice.performClick(nil);await ready(review)
                check(review.plan?.skippedPaths == ["ExtraFolder/deep.txt"],"native child exclusion belongs to the frozen plan")
                check(review.plan?.removals.map(\.path) == ["Extra.txt"] && review.plan?.retained.contains(where:{$0.path == "ExtraFolder"}) == true,"excluding a child retains its enclosing folder")
                check(!review.start.isEnabled && review.confirmRemovals.state == .off,"selection changes invalidate the previous removal confirmation")
                review.reset.performClick(nil);await ready(review);review.scope.selectItem(at:0);review.filterRows()
                check(review.plan?.removals.count == 2 && review.plan?.skippedPaths.isEmpty == true,"reset rebuilds all reviewed actions")
                check(window.performKeyEquivalent(with:key(window,"2",.command)),"Command 2 chooses the reverse mirror direction");await ready(review)
                check(review.plan?.direction == .rightToLeft && review.plan?.removals.map(\.path) == ["New.txt"],"reverse direction recalculates extras on the other side")
                check(review.confirmRemovals.state == .off && !review.start.isEnabled,"reversing direction requires a new removal confirmation")
                check(window.performKeyEquivalent(with:key(window,"1",.command)),"Command 1 restores left to right");await ready(review)
                check(review.plan?.direction == .leftToRight && review.plan?.removals.count == 2,"forward direction restores the correct two removals")
                for (theme,name) in [(1,"Hell"),(2,"Dunkel")] {
                    Preferences.state.theme = theme;self.main.applyTheme();try? await Task.sleep(nanoseconds:120_000_000)
                    check(window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (theme == 1 ? .aqua : .darkAqua),"mirror review follows "+name+" appearance");try capture(window,"-Spiegelung-"+name)
                }
                window.contentView?.layoutSubtreeIfNeeded()
                check(review.filter.frame.maxX < review.scope.frame.minX && review.confirmRemovals.frame.maxY < review.table.enclosingScrollView!.frame.minY && review.info.frame.minY > review.start.frame.maxY,"mirror controls preview and confirmation do not overlap")
                check(self.main.keyWorkflowWindow === window && !self.main.keyWorkflowWindow!.canPerformCommand("trash"),"active mirror sheet blocks destructive commands for the obscured file panes")
                review.confirmRemovals.performClick(nil)
                check(review.confirmRemovals.state == .on && review.start.isEnabled && review.queue.isEnabled,"explicit confirmation enables only the ready reviewed plan")
                let originalPlan = require(review.plan,"submitted plan");review.start.performClick(nil)
                check(review.closed && review.plan == nil && review.rows.isEmpty,"submitted review releases its preview and closes its sheet")
                await wait("mirror queue completion") { !controller.isWorking && self.main.jobs.pending == 0 }
                check(controller.info.textColor != .systemRed,"actual shared queue completes the mirror operation")
                check(read("Rechts/New.txt") == "new source" && read("Rechts/Changed.txt") == "new shared","copy phase publishes both reviewed files")
                check(read("Rechts/Extra.txt") == nil && !FileSystem.exists(root.appendingPathComponent("Rechts/ExtraFolder")),"removal phase removes only the reviewed extra names")
                check(read("Rechts/Keep.bin") == "not selected" && read("Rechts/Cache/private.txt") == "excluded" && read("Rechts/.secret.txt") == "hidden","nonmatching hidden and excluded targets remain untouched")
                check((try? String(contentsOf:originalPlan.removals.first(where:{$0.path == "Extra.txt"})!.stored,encoding:.utf8)) == "extra data","removed file remains available in its same-parent backup")
                check((try? String(contentsOf:originalPlan.removals.first(where:{$0.path == "ExtraFolder"})!.stored.appendingPathComponent("deep.txt"),encoding:.utf8)) == "nested extra","removed directory preserves its complete original payload")
                let removed = self.main.undoSteps.filter { $0.mirrorRemoval != nil }
                check(removed.count == 2,"common operation report exposes both removal undo receipts")
                check(self.main.jobs.history?.inspect().filter { $0.note.contains("Entfernungssicherung") && $0.available }.count == 2,"both removal receipts are present in durable recovery")
                check(FileOperations.undo(removed).isEmpty && read("Rechts/Extra.txt") == "extra data" && read("Rechts/ExtraFolder/deep.txt") == "nested extra","file and directory removals can be undone without overwriting")
                check(controller.comparison == nil && !controller.mirrorButton.isEnabled,"completed plans require a fresh comparison")
                controller.close()
                // A larger review remains complete; native table virtualization shows rows beyond 500.
                for index in 0..<520 { try write("Large/Rechts/Extra-\(String(format:"%04d",index)).txt","synthetic") };try FileManager.default.createDirectory(at:root.appendingPathComponent("Large/Links"),withIntermediateDirectories:true)
                let largeComparison = try CompareService.compare(root.appendingPathComponent("Large/Links"),root.appendingPathComponent("Large/Rechts"))
                let largeReview = MirrorReviewController(largeComparison);self.main.secondaryWindows.append(largeReview);self.main.window?.beginSheet(largeReview.window!,completionHandler:{ _ in });await ready(largeReview)
                check(largeReview.rows.count == 520 && largeReview.plan?.removals.count == 520,"large mirror review retains all 520 actions")
                largeReview.table.scrollRowToVisible(519);largeReview.window?.contentView?.layoutSubtreeIfNeeded()
                check((largeReview.table.view(atColumn:2,row:519,makeIfNecessary:true) as? NSTextField)?.stringValue == "Extra-0519.txt","native table displays an action beyond the first 500 rows")
                largeReview.refresh.performClick(nil);largeReview.window?.performClose(nil);try? await Task.sleep(nanoseconds:100_000_000)
                check(largeReview.closed && largeReview.plan == nil && largeReview.rows.isEmpty && self.main.window?.attachedSheet == nil,"native close during recheck ends its sheet and discards late results")
                check(NSPasteboard.general.changeCount == clipboard,"mirror review leaves the user clipboard untouched")
                let after = try JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences.state)) as! [String:Any],before = try JSONSerialization.jsonObject(with:state) as! [String:Any]
                let currentTabs = try JSONSerialization.jsonObject(with:JSONEncoder().encode([self.main.left.savedTabs,self.main.right.savedTabs])) as! NSArray
                let previousTabs = try JSONSerialization.jsonObject(with:tabs) as! NSArray
                check((before["left"] as? NSArray) == (after["left"] as? NSArray) && (before["right"] as? NSArray) == (after["right"] as? NSArray) && currentTabs == previousTabs,"mirror operations preserve live and saved pane tabs")
                print("MIRROR SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");fflush(stdout);exit(failures.isEmpty ? 0 : 1)
            } catch { print("MIRROR SMOKE FAIL "+error.localizedDescription);fflush(stdout);exit(1) }
        }
    }
}
