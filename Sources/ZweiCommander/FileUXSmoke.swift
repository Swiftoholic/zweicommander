import AppKit
import CommanderCore

private final class FileDragFixture: NSObject,NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation = NSPoint.zero
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(_ pasteboard:NSPasteboard,window:NSWindow) { draggingPasteboard = pasteboard;draggingDestinationWindow = window }
    func slideDraggedImage(to screenPoint:NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination:URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options:NSDraggingItemEnumerationOptions,for view:NSView?,classes:[AnyClass],searchOptions:[NSPasteboard.ReadingOptionKey:Any],using block:(NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void) {}
}

extension AppDelegate {
    func runFileUXSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("FILE UX \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("FILE UX SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<250 { if predicate() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("FILE UX SMOKE FAIL timed out "+name);exit(1)
            }
            let pane = main.left,editor = pane.inlineRename,window = require(main.window,"window"),folder = root.appendingPathComponent("Links")
            let source = folder.appendingPathComponent("Bericht.txt"),renamed = folder.appendingPathComponent("Bericht final.txt"),destination = folder.appendingPathComponent("Ziel"),incoming = root.appendingPathComponent("Außen/Eingang.txt")
            @MainActor func same(_ a:URL?,_ b:URL) -> Bool { a.map { FileSystem.canonical($0).path == FileSystem.canonical(b).path } == true }
            @MainActor func select(_ url:URL) { pane.select([url]);pane.focus();main.content.layoutSubtreeIfNeeded() }
            @MainActor func begin(_ url:URL) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);select(url);main.command("rename");await wait("rename preparation") { editor.isEditing && !editor.isPreparing } }
            @MainActor func type(_ value:String) {
                let text = require(editor.field.currentEditor() as? NSTextView,"rename field editor")
                text.setSelectedRange(NSRange(location:0,length:(text.string as NSString).length));text.insertText(value,replacementRange:text.selectedRange())
            }
            @MainActor func key(_ selector:Selector) { require(editor.field.currentEditor() as? NSTextView,"rename field editor").doCommand(by:selector) }
            @MainActor func capture(_ suffix:String) {
                let places = [("System",URL(fileURLWithPath:"/")),("Projekte",folder),("Sicherung",root.appendingPathComponent("Rechts"))]
                for side in [pane,main.right] { side.locations.configure(places);side.locations.select(side.currentURL) }
                main.content.layoutSubtreeIfNeeded();main.content.displayIfNeeded()
                let rep = require(main.content.bitmapImageRepForCachingDisplay(in:main.content.bounds),"bitmap");main.content.cacheDisplay(in:main.content.bounds,to:rep)
                do { try require(rep.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+suffix+".png")) } catch { print("FILE UX SMOKE FAIL capture");exit(1) }
            }
            window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            await wait("initial listing") { !pane.isLoading && !pane.isSorting && pane.visibleEntries.count == 5 }
            let other = main.right,otherSelection = folder.appendingPathComponent("Konflikt.txt")
            other.navigate(folder);await wait("other pane listing") { !other.isLoading && !other.isSorting }
            other.select([otherSelection])
            await begin(source)
            check(editor.field.currentEditor() != nil && pane.scroll.frame.intersects(editor.frame),"F2 places an editable name over the file list")
            check((editor.field.currentEditor() as? NSTextView)?.selectedRange() == NSRange(location:0,length:7),"the initial selection excludes the filename extension")
            type("Bericht verworfen.txt");key(#selector(NSResponder.cancelOperation(_:)))
            check(!editor.isEditing && FileSystem.exists(source) && !FileSystem.exists(folder.appendingPathComponent("Bericht verworfen.txt")),"Escape discards an edited name without changing files")
            await begin(source);type(renamed.lastPathComponent);key(#selector(NSResponder.insertNewline(_:)))
            await wait("rename completion") { !editor.isEditing && self.main.jobs.pending == 0 && pane.visibleEntries.contains { $0.name == renamed.lastPathComponent } }
            check(!FileSystem.exists(source) && (try? String(contentsOf:renamed,encoding:.utf8)) == "Original\n","Enter renames the actual file and preserves its contents")
            check(pane.selectedURLs.count == 1 && same(pane.selectedURLs.first,renamed),"the renamed file remains selected after reload")
            await wait("other pane rename refresh") { !other.isLoading && !other.isSorting }
            check(other.selectedURLs.count == 1 && same(other.selectedURLs.first,otherSelection),"renaming preserves an unrelated selection in the other pane of the same folder")
            check(main.renameUndo?.count == 1,"inline renaming participates in session undo")
            main.command("undo");await wait("undo") { self.main.jobs.pending == 0 && FileSystem.exists(source) && pane.visibleEntries.contains { $0.name == "Bericht.txt" } }
            check(!FileSystem.exists(renamed) && (try? String(contentsOf:source,encoding:.utf8)) == "Original\n","undo restores the previous name")
            await begin(source);type("../outside.txt");key(#selector(NSResponder.insertNewline(_:)))
            check(editor.error != nil && editor.isEditing && main.jobs.pending == 0,"invalid names remain editable without submitting an operation")
            check(FileSystem.exists(source) && !FileSystem.exists(root.appendingPathComponent("outside.txt")),"path traversal is never interpreted as a filename")
            type("Konflikt.txt");key(#selector(NSResponder.insertNewline(_:)))
            await wait("conflict error") { editor.error?.contains("existiert") == true && !editor.isWorking }
            check(editor.isEditing && main.secondaryWindows.isEmpty,"an existing target is explained at the name without opening a modal dialog")
            check((try? String(contentsOf:folder.appendingPathComponent("Konflikt.txt"),encoding:.utf8)) == "Erhalten\n" && FileSystem.exists(source),"a conflicting name changes neither source nor target")
            key(#selector(NSResponder.cancelOperation(_:)))
            await begin(source)
            do { try Data("Extern geändert\n".utf8).write(to:source) } catch { print("FILE UX SMOKE FAIL fixture");exit(1) }
            type("Veraltet.txt");key(#selector(NSResponder.insertNewline(_:)))
            await wait("stale source") { editor.error?.contains("verändert") == true && !editor.isWorking }
            check(editor.isEditing && !FileSystem.exists(folder.appendingPathComponent("Veraltet.txt")),"external changes during editing reject the original rename snapshot")
            check((try? String(contentsOf:source,encoding:.utf8)) == "Extern geändert\n","external file contents are preserved")
            key(#selector(NSResponder.cancelOperation(_:)))
            await wait("watcher refresh") { !pane.isLoading && !pane.isSorting }
            let directory = folder.appendingPathComponent("Ordner.mit.Punkt")
            other.showCollection([directory,otherSelection],title:"Verweise")
            await wait("other collection") { !other.isLoading && !other.isSorting && other.visibleEntries.count == 2 };other.select([otherSelection])
            await begin(directory)
            check((editor.field.currentEditor() as? NSTextView)?.selectedRange().length == directory.lastPathComponent.count,"folder names with dots are selected in full")
            type("Ordner neu");key(#selector(NSResponder.insertNewline(_:)))
            await wait("folder rename") { !editor.isEditing && self.main.jobs.pending == 0 && FileSystem.exists(folder.appendingPathComponent("Ordner neu")) }
            check(!FileSystem.exists(directory),"directories rename through the same version-checked operation")
            await wait("renamed collection") { !other.isLoading && !other.isSorting }
            check(other.tab.collection?.contains(where:{ same($0,folder.appendingPathComponent("Ordner neu")) }) == true && other.visibleEntries.count == 2,"collection references follow the renamed folder")
            check(other.selectedURLs.count == 1 && same(other.selectedURLs.first,otherSelection),"updating collection references preserves an unrelated selection")
            pane.focus();main.command("undo")
            await wait("collection undo") { self.main.renameUndo == nil && self.main.jobs.pending == 0 && FileSystem.exists(directory) && !pane.isLoading && !pane.isSorting && !other.isLoading && !other.isSorting }
            check(other.tab.collection?.contains(where:{ same($0,directory) }) == true && other.visibleEntries.count == 2,"collection references also follow an undone rename")
            check(other.selectedURLs.count == 1 && same(other.selectedURLs.first,otherSelection) && same(pane.selectedURLs.first,directory),"undo keeps the renamed item and the other pane selection marked")
            other.navigate(root.appendingPathComponent("Rechts"));await wait("restore other pane") { !other.isLoading && !other.isSorting }
            pane.changeDisplay(.icons);await begin(source)
            check(editor.isEditing && pane.scroll.frame.intersects(editor.frame),"inline renaming also appears over an icon caption")
            type("Symbolname.txt");key(#selector(NSResponder.cancelOperation(_:)))
            check(FileSystem.exists(source) && !FileSystem.exists(folder.appendingPathComponent("Symbolname.txt")),"Escape in icon view also leaves the name unchanged")
            pane.changeDisplay(.details);pane.select([source,folder.appendingPathComponent("Konflikt.txt")]);main.command("rename")
            check(!editor.isEditing && pane.selectedURLs.count == 2,"multiple selection cannot silently rename an arbitrary first item")
            window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);pane.focus()
            pane.focusedEntryURL = source;pane.redrawFileFocus()
            // macOS may decline background activation; selection styling must follow its actual key-window state.
            check(window.firstResponder === pane.table && pane.focusedEntryURL == source && pane.selectedURLs.count == 2 && pane.isFileListFocused == window.isKeyWindow,"keyboard focus remains separate from the multi-selection and follows native window activation")
            main.right.focus();try? await Task.sleep(nanoseconds:80_000_000)
            check(!pane.isFileListFocused && pane.selectedURLs.count == 2,"inactive panes retain their selected files without keyboard focus")
            let index = require(pane.visibleEntries.firstIndex { same($0.url,source) },"selected row"),column = pane.table.column(withIdentifier:.init("name"))
            let cell = require(pane.table.view(atColumn:column,row:index,makeIfNecessary:true) as? FileCellView,"selected cell")
            check(cell.textField?.textColor == pane.palette.text,"inactive selections use readable text instead of active white captions")
            pane.focus()
            let pb = NSPasteboard.withUniqueName();defer { pb.releaseGlobally() };pb.writeObjects([incoming as NSURL])
            let drag = FileDragFixture(pb,window:window)
            let row = require(pane.visibleEntries.firstIndex { $0.name == "Ziel" },"folder row")
            check(pane.tableView(pane.table,validateDrop:drag,proposedRow:row,proposedDropOperation:.on) == .copy,"a directory row advertises a copy drop")
            check(same(pane.dropTargetURL,destination) && !pane.dropOnBackground && pane.dropHint?.contains("Ziel") == true,"the exact destination receives a border and a copy hint")
            pane.table.draggingExited(drag);try? await Task.sleep(nanoseconds:900_000_000)
            check(same(pane.currentURL,folder) && pane.dropHint == nil,"leaving a folder cancels its pending hover navigation")
            var dropped:[URL] = [],target:URL?;let normalDrop = pane.onDrop
            pane.onDrop = { dropped = $0;target = $1 }
            check(pane.tableView(pane.table,acceptDrop:drag,row:row,dropOperation:.on) && dropped == [incoming] && same(target,destination),"a table drop addresses the hovered subfolder")
            check(!FileSystem.exists(destination.appendingPathComponent("Eingang.txt")),"accepting a drop only requests the existing copy preview")
            pane.changeDisplay(.icons)
            let gridRow = require(pane.visibleEntries.firstIndex { $0.name == "Ziel" },"icon folder")
            pane.grid.layoutSubtreeIfNeeded()
            let frame = require(pane.grid.layoutAttributesForItem(at:IndexPath(item:gridRow,section:0)),"folder icon geometry").frame
            drag.draggingLocation = pane.grid.convert(NSPoint(x:frame.midX,y:frame.midY),to:nil)
            var proposed = IndexPath(item:0,section:0) as NSIndexPath,operation = NSCollectionView.DropOperation.before
            let gridOperation = withUnsafeMutablePointer(to:&proposed) { pointer in pane.collectionView(pane.grid,validateDrop:drag,proposedIndexPath:AutoreleasingUnsafeMutablePointer(pointer),dropOperation:&operation) }
            check(gridOperation == .copy && operation == .on && proposed.item == gridRow && same(pane.dropTargetURL,destination),"hovering an icon resolves the folder even when AppKit proposes insertion")
            check(pane.collectionView(pane.grid,acceptDrop:drag,indexPath:IndexPath(item:gridRow,section:0),dropOperation:.on) && same(target,destination),"icon drops use the same folder destination")
            drag.draggingLocation = .zero
            pane.changeDisplay(.details)
            dropped = [];target = nil
            _ = pane.tableView(pane.table,validateDrop:drag,proposedRow:row,proposedDropOperation:.on)
            await wait("folder spring opening") { same(pane.currentURL,destination) && !pane.isLoading && !pane.isSorting }
            check(dropped.isEmpty && target == nil,"holding over a folder opens it without starting a copy")
            check(pane.tab.history.count > 1,"hover-opened folders remain reachable through normal history")
            pane.navigate(folder);await wait("back to base") { !pane.isLoading && !pane.isSorting }
            let originalID = pane.tab.id,tabFolder = root.appendingPathComponent("Rechts/TabZiel")
            pane.newTab(url:tabFolder);let targetID = pane.tab.id;pane.selectTab(originalID)
            await wait("original tab") { !pane.isLoading && !pane.isSorting }
            let tabButton = require(pane.tabsStack.arrangedSubviews.compactMap { $0 as? FolderTabButton }.first { $0.tabID == targetID },"drop tab")
            check(tabButton.draggingEntered(drag) == .copy,"an inactive folder tab accepts file URLs")
            check(tabButton.performDragOperation(drag) && pane.tab.id == originalID && same(target,tabFolder),"dropping immediately targets an inactive tab without switching it")
            _ = tabButton.draggingEntered(drag);tabButton.draggingExited(drag);try? await Task.sleep(nanoseconds:900_000_000)
            check(pane.tab.id == originalID,"leaving an inactive tab cancels its hover switch")
            _ = tabButton.draggingEntered(drag)
            await wait("tab spring switch") { pane.tab.id == targetID && !pane.isLoading && !pane.isSorting }
            check(pane.tabsStack.arrangedSubviews.contains { $0 === tabButton },"switching tabs keeps the live drop target view intact")
            check(tabButton.performDragOperation(drag) && same(target,tabFolder),"the same tab still accepts the drop after hover switching")
            pane.tab.archiveRoot = tabFolder
            check(tabButton.draggingEntered(drag).isEmpty && !tabButton.performDragOperation(drag),"archive tabs reject incoming file drops")
            pane.tab.archiveRoot = nil;pane.selectTab(originalID);await wait("original tab reload") { !pane.isLoading && !pane.isSorting }
            pane.onDrop = normalDrop
            let actualRow = require(pane.visibleEntries.firstIndex { $0.name == "Ziel" },"copy folder")
            check(pane.tableView(pane.table,acceptDrop:drag,row:actualRow,dropOperation:.on),"a real folder drop opens the transfer setup")
            let setup = require(main.secondaryWindows.last as? TransferSetupController,"copy setup")
            await wait("drop plan") { setup.plan != nil }
            check(same(setup.plan?.destination,destination),"the transfer preview retains the exact hovered destination")
            setup.startButton.performClick(nil);await wait("drop copy") { self.main.jobs.pending == 0 && FileSystem.exists(destination.appendingPathComponent("Eingang.txt")) }
            check((try? String(contentsOf:destination.appendingPathComponent("Eingang.txt"),encoding:.utf8)) == "Drop-Inhalt\n" && FileSystem.exists(incoming),"confirming the drop preview copies exact contents and keeps the source")
            pane.showCollection([],title:"Referenzen");let collectionID = pane.tab.id
            await wait("collection") { !pane.isLoading && !pane.isSorting }
            let priorRequests = main.jobs.scheduler.snapshots.count
            check(pane.acceptFiles(pb) && pane.tab.collection?.count == 1,"collection drops add references")
            check(main.jobs.scheduler.snapshots.count == priorRequests && FileSystem.exists(incoming),"a collection drop never submits a file transfer")
            pane.selectTab(originalID);await wait("folder before inactive collection") { !pane.isLoading && !pane.isSorting }
            pb.clearContents();pb.writeObjects([source as NSURL])
            check(pane.acceptFiles(pb,tabID:collectionID) && pane.tab.id == originalID && pane.tabs.first { $0.id == collectionID }?.collection?.count == 2,"an inactive collection tab receives its own references")
            let empty = NSPasteboard.withUniqueName();defer { empty.releaseGlobally() }
            check(pane.updateFileDrop(empty,folder:destination).isEmpty && pane.dropHint == nil,"unsupported pasteboard contents show no drop destination")
            let cancellable = try! FileEntry(url:root.appendingPathComponent("Abbruch.png"));var lateImage = false
            let (_,imageRequest) = pane.fileImages.load(cancellable,preview:true) { _ in lateImage = true };imageRequest?.cancel()
            try? await Task.sleep(nanoseconds:200_000_000)
            check(!lateImage,"cancelled image requests cannot update reused cells")
            pane.changeDisplay(.icons)
            let imageIndex = require(pane.visibleEntries.firstIndex { $0.name == "Bild.png" },"image row")
            let imagePath = IndexPath(item:imageIndex,section:0)
            main.content.layoutSubtreeIfNeeded();pane.grid.scrollToItems(at:[imagePath],scrollPosition:.nearestHorizontalEdge)
            await wait("asynchronous thumbnail") { pane.grid.layoutSubtreeIfNeeded();return pane.grid.item(at:imagePath)?.imageView?.image?.size.width == 144 }
            check(pane.grid.item(at:imagePath)?.imageView?.image?.size.width == 144,"image thumbnails are decoded asynchronously at a bounded size")
            pane.changeDisplay(.details)
            for theme in [1,2] {
                main.themeMenu.selectItem(at:theme);main.themeChosen();await begin(source)
                type("Bericht Entwurf.txt");capture(theme == 1 ? "-Dateiliste-Hell" : "-Dateiliste-Dunkel");editor.cancel(restoreFocus:true)
            }
            var beats = 0,last = ProcessInfo.processInfo.systemUptime,maxGap:TimeInterval = 0
            let timer = Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { _ in let now = ProcessInfo.processInfo.systemUptime;maxGap = max(maxGap,now-last);last = now;beats += 1 }
            pane.navigate(root.appendingPathComponent("Groß"))
            await wait("large folder") { !pane.isLoading && !pane.isSorting && pane.visibleEntries.count == 3000 }
            timer.invalidate()
            print("FILE UX METRIC directory=3000 ui_ticks=\(beats) longest_gap=\(maxGap)")
            check(beats > 0 && maxGap < 0.75,"the native event loop continues during large directory loading and sorting")
            check(pane.visibleEntries.count == 3000 && pane.visibleEntries.first?.name == "Datei 0.txt" && pane.visibleEntries.last?.name == "Datei 2999.txt","large listings finish with a complete naturally sorted result")
            let largeFile = root.appendingPathComponent("Groß/Datei 2345.txt");pane.select([largeFile])
            check(same(pane.selectedURLs.first,largeFile),"large selections use the prepared path index")
            pane.refresh();await wait("large background refresh") { !pane.isLoading && !pane.isSorting }
            check(pane.selectedURLs.count == 1 && same(pane.selectedURLs.first,largeFile),"background refresh preserves selections outside the first loading batch")
            pane.select([root.appendingPathComponent("Groß/Datei 0.txt")]);pane.reveal(largeFile)
            await wait("reveal in current folder") { !pane.isLoading && !pane.isSorting }
            check(pane.selectedURLs.count == 1 && same(pane.selectedURLs.first,largeFile),"revealing an item in the current folder survives view restoration")
            pane.navigate(folder);await wait("reveal origin") { !pane.isLoading && !pane.isSorting }
            pane.reveal(largeFile);await wait("reveal in another folder") { !pane.isLoading && !pane.isSorting }
            check(same(pane.currentURL,largeFile.deletingLastPathComponent()) && pane.selectedURLs.count == 1 && same(pane.selectedURLs.first,largeFile),"revealing an item in another folder selects it after the asynchronous load")
            pane.filterField.stringValue = "Datei 12*.txt";pane.applyFilter();await wait("large filter") { !pane.isSorting }
            check(!pane.visibleEntries.isEmpty && pane.visibleEntries.allSatisfy { $0.name.hasPrefix("Datei 12") },"large folder filters publish only matching entries")
            pane.filterField.stringValue = "[";pane.filterRegex.state = .on;pane.applyFilter()
            check(!pane.canUseDisplayedEntries && pane.visibleEntries.isEmpty,"an invalid filter never leaves stale actionable entries")
            pane.clearFilter();pane.navigate(folder)
            await wait("navigation cancels old load") { !pane.isLoading && !pane.isSorting && same(pane.currentURL,folder) }
            try? await Task.sleep(nanoseconds:150_000_000)
            check(pane.visibleEntries.count == 5 && !pane.visibleEntries.contains { $0.name.hasPrefix("Datei ") },"late results from another directory cannot replace the current listing")
            await begin(source);type("Entwurf bleibt.txt");pane.refresh();await wait("refresh during rename") { !pane.isLoading && !pane.isSorting }
            check(editor.isEditing && editor.field.stringValue == "Entwurf bleibt.txt","a background refresh preserves an uncommitted inline name")
            pane.navigate(destination);await wait("navigation during rename") { !pane.isLoading && !pane.isSorting }
            check(!editor.isEditing && FileSystem.exists(source) && !FileSystem.exists(folder.appendingPathComponent("Entwurf bleibt.txt")),"navigating away cancels an uncommitted rename")
            pane.tab.archiveRoot = destination;pane.beginInlineRename()
            check(!editor.isEditing,"read-only archive views cannot start inline editing");pane.tab.archiveRoot = nil
            print("FILE UX SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
