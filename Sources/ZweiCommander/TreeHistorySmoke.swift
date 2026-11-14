import AppKit
import Darwin
import CommanderCore

extension AppDelegate {
    func runTreeHistorySmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("TREE HISTORY UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("TREE HISTORY SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<350 { if predicate() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("TREE HISTORY SMOKE FAIL timeout "+name);exit(1)
            }
            let main = self.main!,left = main.left,right = main.right,window = require(main.window,"window"),boardChange = NSPasteboard.general.changeCount
            let fixture = root.appendingPathComponent("TreeHistory"),branches = fixture.appendingPathComponent("Branches"),locked = branches.appendingPathComponent("Locked"),growing = branches.appendingPathComponent("Growing")
            let l = fixture.appendingPathComponent("Left"),r = fixture.appendingPathComponent("Right"),la = l.appendingPathComponent("A"),ld = la.appendingPathComponent("Deep"),ra = r.appendingPathComponent("A"),rd = ra.appendingPathComponent("Deep")
            @MainActor func settle() async { await wait("listings") { !left.isLoading && !left.isSorting && !right.isLoading && !right.isSorting } }
            @MainActor func capture(_ suffix:String) {
                main.content.layoutSubtreeIfNeeded();main.content.displayIfNeeded()
                guard !prefix.isEmpty,let image = main.content.bitmapImageRepForCachingDisplay(in:main.content.bounds) else { return }
                main.content.cacheDisplay(in:main.content.bounds,to:image);try? image.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
            }
            do {
                guard !FileSystem.exists(fixture) else { throw CommanderError.message("Prüfordner muss frisch sein.") }
                for folder in [ld,rd,growing,locked.appendingPathComponent("Child")] { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true) }
                defer { chmod(locked.path,0o700);try? FileManager.default.removeItem(at:fixture) }
                window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                main.linked = false;left.navigate(l);right.navigate(r);await settle()
                left.tree.roots = [TreeNode(branches)];left.treeVisible = true;main.content.layoutSubtreeIfNeeded()
                let tree = left.tree,branch = tree.roots[0]
                tree.outline.expandItem(branch)
                await wait("root tree") { !branch.loading && branch.children?.count == 2 }
                check(branch.error == nil && tree.outline.isItemExpanded(branch),"ordinary branch expands without an error")
                let growNode = require(branch.children?.first { $0.url == growing },"growing branch"),lockedNode = require(branch.children?.first { $0.url == locked },"locked branch")
                tree.outline.expandItem(growNode)
                await wait("empty branch") { !growNode.loading && growNode.children?.isEmpty == true }
                let empty = tree.outline.view(atColumn:0,row:tree.outline.row(forItem:growNode)+1,makeIfNecessary:true) as? NSTextField
                check(empty?.stringValue == "Keine sichtbaren Unterordner","empty branch has an explicit successful empty state")
                let added = growing.appendingPathComponent("Added");try FileManager.default.createDirectory(at:added,withIntermediateDirectories:false)
                left.refresh();await wait("created child") { !growNode.loading && growNode.children?.contains { $0.url == added } == true }
                check(growNode.children?.count == 1,"normal pane refresh invalidates an expanded cached branch")
                tree.outline.collapseItem(growNode);try FileManager.default.removeItem(at:added)
                let replacement = growing.appendingPathComponent("Replacement");try FileManager.default.createDirectory(at:replacement,withIntermediateDirectories:false)
                tree.outline.expandItem(growNode)
                await wait("reexpanded branch") { !growNode.loading && growNode.children?.map(\.url) == [replacement] }
                check(growNode.children?.first?.url == replacement,"re-expansion reads current filesystem children")
                check(chmod(locked.path,0) == 0,"synthetic unreadable branch prepared")
                tree.outline.expandItem(lockedNode)
                await wait("permission error") { !lockedNode.loading && lockedNode.error != nil }
                let errorRow = tree.outline.row(forItem:lockedNode)+1,errorButton = tree.outline.view(atColumn:0,row:errorRow,makeIfNecessary:true) as? NSButton
                check(errorButton?.title.contains("Nicht lesbar") == true && !(errorButton?.toolTip ?? "").isEmpty,"unreadable tree branch exposes a native retry control and diagnostic")
                check(lockedNode.children == nil && tree.outline.item(atRow:errorRow) is TreeBranchStatus,"unreadable branch never appears as successful empty contents")
                capture("-Tree-Error")
                check(chmod(locked.path,0o700) == 0,"synthetic branch permissions restored")
                errorButton?.performClick(nil)
                await wait("retry restored branch") { !lockedNode.loading && lockedNode.error == nil && lockedNode.children?.count == 1 }
                check(lockedNode.children?.first?.url.lastPathComponent == "Child","native retry reloads a repaired branch")
                let moved = branches.appendingPathComponent("Moved");try FileManager.default.moveItem(at:locked,to:moved)
                tree.load(lockedNode,force:true);await wait("missing branch") { !lockedNode.loading && lockedNode.error != nil }
                check(lockedNode.children == nil,"disappeared branch exposes an error instead of its old children")
                try FileManager.default.moveItem(at:moved,to:locked)
                let missingRow = tree.outline.row(forItem:lockedNode)+1;tree.outline.selectRowIndexes(IndexSet(integer:missingRow),byExtendingSelection:false)
                let enter = require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36),"retry key")
                window.makeFirstResponder(tree.outline);tree.outline.keyDown(with:enter)
                check(lockedNode.loading,"native Enter retries the selected failed branch")
                await wait("keyboard retry") { !lockedNode.loading && lockedNode.error == nil && lockedNode.children?.count == 1 }
                check(tree.outline.isItemExpanded(branch) && tree.outline.isItemExpanded(growNode),"branch refresh preserves existing expansion")
                let origin = tree.outline.visibleRect.origin;tree.refreshExpanded();await wait("final branch refresh") { !branch.loading && !growNode.loading && !lockedNode.loading }
                check(tree.outline.visibleRect.origin == origin,"tree refresh preserves the scroll position")
                capture("-Tree-Retry")
                var leftEvents = 0,rightEvents = 0
                let leftObserver = left.onNavigate,rightObserver = right.onNavigate
                left.onNavigate = { pane,old,new in leftEvents += 1;leftObserver?(pane,old,new) }
                right.onNavigate = { pane,old,new in rightEvents += 1;rightObserver?(pane,old,new) }
                defer { left.onNavigate = leftObserver;right.onNavigate = rightObserver;main.linked = false }
                main.linked = true
                left.navigate(la);await settle()
                check(left.currentURL.path == la.path && right.currentURL.path == ra.path && leftEvents == 1 && rightEvents == 0,"linked descent notifies once without a callback cascade")
                left.navigate(ld);await settle();let history = left.tab.history
                check(right.currentURL.path == rd.path && leftEvents == 2 && rightEvents == 0,"second linked descent preserves exactly one source notification")
                left.navigationButtons["back"]?.performClick(nil);await settle()
                check(left.currentURL.path == la.path && right.currentURL.path == ra.path && leftEvents == 3 && rightEvents == 0,"back follows both panes exactly once")
                left.navigationButtons["forward"]?.performClick(nil);await settle()
                check(left.currentURL.path == ld.path && right.currentURL.path == rd.path && leftEvents == 4 && rightEvents == 0,"forward follows both panes exactly once")
                left.history(to:require(history.firstIndex(of:l),"base history"));await settle()
                check(left.currentURL.path == l.path && right.currentURL.path == r.path && leftEvents == 5 && rightEvents == 0,"direct history jump follows multiple parent levels")
                check(left.tab.history == history,"history navigation retains the forward timeline")
                left.beginPathEditing();left.pathField.stringValue = "";left.pathField.edited()
                await wait("history suggestions") { left.pathField.dropdown.isVisible && left.pathField.suggestions.contains { $0.history && $0.url == ld } }
                left.pathField.dropdown.choose(require(left.pathField.suggestions.firstIndex { $0.history && $0.url == ld },"deep history choice"))
                await wait("direct history choice") { left.currentURL.path == ld.path && right.currentURL.path == rd.path && !left.pathField.sessionActive };await settle()
                check(leftEvents == 6 && rightEvents == 0 && left.tab.history == history,"history suggestion uses the same indexed route without truncating history")
                let beforeFixed = left.tab,position = left.tab.position,count = left.tabs.count
                left.setTabLock(.fixed);left.history(-1);await settle()
                check(left.tab === beforeFixed && left.tab.position == position && left.tabs.count == count && left.currentURL.path == ld.path && right.currentURL.path == rd.path && leftEvents == 6,"fixed source tab refuses history without notifications or history changes")
                left.setTabLock(.newTab);left.history(-1);await settle()
                check(left.tab !== beforeFixed && beforeFixed.position == position && beforeFixed.url == ld && left.currentURL.path == la.path && right.currentURL.path == ra.path && leftEvents == 7 && rightEvents == 0,"new-tab lock opens history target and links once while preserving locked tab")
                left.setTabLock(.newTab);let lockedSource = left.tab;left.navigate(ld);await settle()
                check(left.tab !== lockedSource && lockedSource.url == la && right.currentURL.path == rd.path && leftEvents == 8 && rightEvents == 0,"ordinary navigation through a new-tab lock also links exactly once")
                left.setTabLock(.none);main.linked = false;left.navigate(la);left.navigate(ld);await settle();main.linked = true;right.setTabLock(.fixed);let beforeFixedTarget = leftEvents;left.history(-1);await settle()
                check(left.currentURL.path == la.path && right.currentURL.path == rd.path && leftEvents == beforeFixedTarget+1 && rightEvents == 0,"fixed opposite tab is preserved during linked history")
                main.linked = false;right.setTabLock(.none);left.navigate(l);right.navigate(r);await settle();rightEvents = 0;main.linked = true
                right.setTabLock(.newTab);let lockedTarget = right.tab,beforeTargetEvents = leftEvents;left.navigate(la);await settle()
                check(right.tab !== lockedTarget && lockedTarget.url == r && right.currentURL.path == ra.path && leftEvents == beforeTargetEvents+1 && rightEvents == 0,"opposite new-tab lock follows without reflecting another event")
                right.setTabLock(.none);main.linked = false;right.showCollection([],title:"Prüfsammlung");await settle();let collectionID = right.tab.id,collectionURL = right.currentURL
                main.linked = true;left.navigate(ld);await settle()
                check(right.tab.id == collectionID && right.currentURL == collectionURL && right.tab.collection != nil,"linked local navigation preserves an opposite collection context")
                main.linked = false;right.newTab(url:r);right.tab.archiveRoot = r;right.tab.archiveOrigin = fixture.appendingPathComponent("Archive.zip");right.refresh();await settle()
                let archiveID = right.tab.id;main.linked = true;left.history(-1);await settle()
                check(right.tab.id == archiveID && right.currentURL.path == r.path && right.tab.archiveRoot == r,"linked history preserves an opposite archive context")
                main.linked = false;right.tab.archiveRoot = nil;right.tab.archiveOrigin = nil;right.navigate(r);left.navigate(l);await settle()
                let vanished = l.appendingPathComponent("Vanished");try FileManager.default.createDirectory(at:vanished,withIntermediateDirectories:false);left.navigate(vanished);left.navigate(l);await settle();try FileManager.default.removeItem(at:vanished)
                let beforeMissing = left.tab.position,missingEvents = leftEvents;left.history(-1);await settle()
                check(left.currentURL.path == l.path && left.tab.position == beforeMissing && leftEvents == missingEvents && left.status.stringValue.contains("nicht mehr verfügbar"),"missing history target preserves location and position with a visible error")
                let sameEvents = leftEvents;left.history(0);left.history(Int.max);left.history(Int.min)
                check(leftEvents == sameEvents && left.currentURL.path == l.path,"no-op and invalid history offsets emit no navigation")
                check(NSPasteboard.general.changeCount == boardChange,"tree and history operations leave general clipboard untouched")
            } catch { check(false,"fixture: "+error.localizedDescription) }
            print("TREE HISTORY SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
