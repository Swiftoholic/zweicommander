import AppKit
import CommanderCore

extension AppDelegate {
    func runWorkspaceSmoke(root: URL,prefix: String,reload: Bool) {
        var failures: [String] = [],checks = 0
        func check(_ value: Bool,_ name: String) { checks += 1;print("WORKSPACE UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
        func finish() {
            _ = Preferences.workspaceTestDefaults?.synchronize()
            print("WORKSPACE SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
        func waitFor(_ condition: @escaping () -> Bool,then: @escaping () -> Void,attempt: Int = 0) {
            if condition() { then();return };guard attempt < 100 else { print("WORKSPACE SMOKE FAIL timed out");exit(1) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitFor(condition,then:then,attempt:attempt+1) }
        }
        func capture(_ window: NSWindow?,_ suffix: String) {
            guard let view = window?.contentView else { return };view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return };view.cacheDisplay(in:view.bounds,to:rep)
            try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
        }
        func choose(_ popup: NSPopUpButton,_ index: Int) { popup.selectItem(at:index);_ = popup.sendAction(popup.action,to:popup.target) }
        let pane = main.left,folder = root.appendingPathComponent("Links"),photos = folder.appendingPathComponent("Fotos"),child = photos.appendingPathComponent("Unterordner")
        let text = pane.visibleEntries.first(where: { $0.name == "Notizen.txt" })?.url ?? folder.appendingPathComponent("Notizen.txt")
        let image = pane.visibleEntries.first(where: { $0.name == "Vorschau.png" })?.url ?? folder.appendingPathComponent("Vorschau.png")
        guard let defaults = Preferences.workspaceTestDefaults else { print("WORKSPACE SMOKE FAIL isolated storage missing");exit(1) }
        func verifyIconCopy(then: @escaping () -> Void) {
            pane.changeDisplay(.icons);pane.select([text,image]);self.main.command("copy")
            let setup = self.main.secondaryWindows.last as! TransferSetupController
            waitFor({ setup.plan != nil },then:{
                check(Set(setup.plan!.entries.map { FileSystem.canonical($0.source) }) == Set([text,image].map { FileSystem.canonical($0) }),"copy command plans the selected icon files")
                setup.startButton.performClick(nil)
                waitFor({ self.main.jobs.pending == 0 },then:{
                    let target = root.appendingPathComponent("Rechts")
                    check(self.main.jobs.scheduler.snapshots.last?.state == .completed &&
                          (try? Data(contentsOf:target.appendingPathComponent("Vorschau.png"))) == (try? Data(contentsOf:image)) &&
                          (try? String(contentsOf:target.appendingPathComponent("Notizen.txt"),encoding:.utf8)) == "Grüße aus Wien\n",
                          "native icon copy publishes exact selected file contents")
                    self.main.operationWindow?.close();then()
                })
            })
        }
        if reload {
            let library = try! Preferences.workspaceLibrary()
            check(library.favorites.map(\.title) == ["Texteditor","Bilder & Projekte"],"favorite names and order survive separate process")
            check(library.favorites.first?.opensSelection == true && library.views.count == 2,"program mode and folder rules survive restart")
            check(pane.tabs.count == 2 && pane.tabIndex == 1 && pane.currentURL == photos,"tab order and selected tab restored")
            check(pane.tabs.first?.locked == true && pane.tabs.last?.title == "Bilder","tab lock and custom name restored")
            check(pane.displayMode == .icons && pane.scroll.documentView === pane.grid && pane.sortKey == "modified" && !pane.ascending,"automatic folder view restored before display")
            check(main.right.displayMode == .thumbnails && main.right.table.rowHeight == 52,"other pane retains independent saved view")
            let manager = FavoritesController(folder:folder);main.secondaryWindows.append(manager);manager.showWindow(nil)
            let app = library.favorites.first!
            manager.reload(select:app.id)
            check(manager.name.stringValue == "Texteditor" && manager.opensSelection.state == .on,"editor restores selected program fields")
            let saved = defaults.data(forKey:Preferences.workspaceKey)!
            defaults.set(Data("{broken".utf8),forKey:Preferences.workspaceKey);manager.reload()
            check(!manager.apply.isEnabled && manager.info.textColor == .systemRed,"damaged library blocks editing inline")
            manager.name.stringValue = "Never written";manager.saveEditor()
            check(defaults.data(forKey:Preferences.workspaceKey) == Data("{broken".utf8),"failed edit preserves damaged bytes")
            defaults.set(saved,forKey:Preferences.workspaceKey);manager.reload(select:app.id);manager.close()
            pane.navigate(child)
            waitFor({ pane.currentURL == child && pane.status.stringValue.contains("Objekte") },then:{
                check(pane.displayMode == .thumbnails && pane.sortKey == "size","more specific child rule wins on navigation")
                pane.history(-1)
                waitFor({ pane.currentURL == photos && pane.displayMode == .icons },then:{
                    check(!pane.ascending && pane.sortKey == "modified","history reapplies parent folder rule")
                    let views = FolderViewsController();self.main.secondaryWindows.append(views);views.showWindow(nil)
                    check(views.rules.count == 2,"view manager lists persisted rules")
                    let index = views.rules.firstIndex(where: { $0.path == child.path })!
                    views.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);views.remove.performClick(nil)
                    check((try! Preferences.workspaceLibrary()).views.count == 1,"view manager removes only selected rule")
                    let parentIndex = views.rules.firstIndex(where: { $0.path == photos.path })!
                    views.table.selectRowIndexes(IndexSet(integer:parentIndex),byExtendingSelection:false);views.scope.performClick(nil)
                    check((try! Preferences.workspaceLibrary()).views.first?.includeSubfolders == false,"view manager changes subtree scope")
                    capture(views.window,"-Ordneransichten");views.close()
                    pane.navigate(child)
                    waitFor({ pane.currentURL == child && pane.status.stringValue.contains("Objekte") },then:{
                        check(pane.displayMode == .icons && pane.sortKey == "size","removed rule and scope fall back to saved manual tab view")
                        check((try! Preferences.workspaceLibrary()).favorites == library.favorites,"view edits preserve all favorite entries")
                        finish()
                    })
                })
            });return
        }
        check(pane.visibleEntries.count == 5 && pane.displayMode == .details,"workspace starts with details and fixture files")
        pane.select([folder.appendingPathComponent("Notizen.txt")])
        check(pane.selectedURLs == [text],"selection resolves parent aliases without following selected links")
        pane.select([text,image]);choose(pane.viewMode,2);main.content.layoutSubtreeIfNeeded()
        check(pane.displayMode == .icons && pane.scroll.documentView === pane.grid,"native icon view is attached")
        check(Set(pane.selectedURLs) == [text,image] && pane.grid.selectionIndexPaths.count == 2,"selection survives details to icons")
        pane.focus();check(main.window?.firstResponder === pane.grid,"icon view receives keyboard focus")
        main.command("selectAll");check(pane.selectedURLs.count == 5,"select all addresses icon items")
        main.command("invertSelection");check(pane.selectedURLs.isEmpty,"invert selection addresses icon items")
        pane.select([text,image]);choose(pane.sortMode,2);pane.sortDirection.performClick(nil)
        check(pane.sortKey == "size" && !pane.ascending && Set(pane.selectedURLs) == [text,image],"icon sorting preserves file identities")
        pane.filterField.stringValue = "*.txt";pane.applyFilter()
        check(pane.visibleEntries.count == 1 && pane.selectedURLs == [text],"icon filter retains only matching selected files")
        pane.clearFilter();pane.select([text])
        let firstIcon = pane.visibleEntries[0].url
        pane.select([firstIcon])
        let rightKey = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        pane.grid.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:main.window!.windowNumber,context:nil,characters:rightKey,charactersIgnoringModifiers:rightKey,isARepeat:false,keyCode:124)!)
        check(pane.selectedURLs.count == 1 && pane.selectedURLs.first != firstIcon,"arrow key moves native icon selection")
        pane.select([text])
        main.command("quickView")
        check((main.content.quick.previewItem as? NSURL) as URL? == text,"quick preview follows icon selection")
        main.command("quickView")
        var previewed: [URL] = [];let preview = pane.onPreview
        pane.onPreview = { previewed = $0 }
        let space = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:main.window!.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49)!
        pane.grid.keyDown(with:space);pane.onPreview = preview
        check(previewed == [text],"space key uses the selected icon for preview")
        guard let itemIndex = pane.visibleEntries.firstIndex(where: { $0.url == image }) else { check(false,"image fixture exists in listing");finish();return }
        let item = pane.collectionView(pane.grid,itemForRepresentedObjectAt:IndexPath(item:itemIndex,section:0))
        check(item.imageView?.image?.size.width == 144 && item.textField?.stringValue == "Vorschau.png","icon item decodes a bounded image thumbnail and name")
        let pasteboard = NSPasteboard.withUniqueName();pasteboard.writeObjects([text as NSURL])
        var dropped: [URL] = [],destination: URL?;let drop = pane.onDrop
        pane.onDrop = { dropped = $0;destination = $1 }
        check(pane.acceptFiles(pasteboard) && dropped == [text] && destination == folder,"icon drop uses the pane destination")
        pane.onDrop = drop
        choose(pane.viewMode,1)
        check(pane.thumbnails && pane.table.rowHeight == 52 && pane.selectedURLs == [text],"thumbnail list restores selection")
        main.command("details");check(pane.displayMode == .details && pane.table.rowHeight == 21,"details command restores compact rows")
        let sameURL = PaneView(url:folder,savedTabs:[
            SavedTab(path:root.appendingPathComponent("Missing").path,title:nil,locked:false,view:nil,selected:nil),
            SavedTab(path:folder.path,title:"Gleich",locked:false,view:.init(display:.icons),selected:nil),
            SavedTab(path:folder.path,title:"Gleich",locked:true,view:.init(display:.thumbnails),selected:true)])
        sameURL.initializeView()
        check(sameURL.tabs.count == 2 && sameURL.tabIndex == 1 && sameURL.tab.locked && sameURL.displayMode == .thumbnails,"duplicate URLs and missing earlier tabs restore the exact selected tab")
        let legacy: [String:Any] = ["left":[["path":folder.path,"locked":false]],"right":[],"favorites":[],"showHidden":false,"vertical":true,"theme":0,"shortcuts":[:]]
        let legacyState = Preferences.decode(try! JSONSerialization.data(withJSONObject:legacy))
        check(legacyState?.left.count == 1 && legacyState?.left.first?.view == nil,"previous session format remains readable")
        var unknownView = legacy
        unknownView["left"] = [["path":folder.path,"locked":true,"view":["display":"future-view"],"selected":"unknown"]]
        let preserved = Preferences.decode(try! JSONSerialization.data(withJSONObject:unknownView))
        check(preserved?.left.first?.path == folder.path && preserved?.left.first?.locked == true && preserved?.left.first?.view == nil,"unknown optional view fields preserve saved folders")
        let first = pane.tab;first.locked = true
        pane.newTab(url:photos);pane.tab.title = "Bilder";let second = pane.tab
        pane.duplicateTab();let duplicate = pane.tab
        check(pane.tabs.count == 3 && duplicate !== second && duplicate.history == second.history && !duplicate.locked,"duplicate keeps navigation without copying lock")
        pane.moveTab(second.id,to:0)
        check(pane.tabs.first === second && pane.tab === duplicate,"reordering keeps active tab identity")
        pane.moveTab(second.id,to:1);pane.selectTab(second.id);pane.closeOtherTabs()
        check(pane.tabs.count == 2 && pane.tabs.first === first && pane.tab === second,"close others preserves locked tabs")
        pane.stepTab(1);check(pane.tab === first,"next tab wraps to first")
        pane.stepTab(-1);check(pane.tab === second,"previous tab wraps back")
        let tabButton = pane.tabsStack.arrangedSubviews[pane.tabIndex] as! FolderTabButton
        let menuItem = tabButton.menu!.items.first(where: { $0.representedObject as? String == "duplicateTab" })!
        tabButton.run(menuItem)
        check(pane.tabs.count == 3 && pane.currentURL == photos,"tab context action duplicates intended tab")
        pane.closeTab();pane.selectTab(second.id)
        pane.changeDisplay(.details)
        var library = try! Preferences.workspaceLibrary()
        try! library.remember(.init(display:.icons,sortKey:"modified",ascending:false),folder:photos,includeSubfolders:true)
        try! library.remember(.init(display:.thumbnails,sortKey:"size"),folder:child,includeSubfolders:false)
        try! Preferences.saveWorkspace(library);main.applyFolderViews()
        check(pane.displayMode == .icons && !pane.ascending,"saved rule applies to current folder")
        main.right.changeDisplay(.thumbnails)
        pane.navigate(folder.appendingPathComponent("Fotos-Extra"))
        waitFor({ pane.status.stringValue.contains("Objekte") },then:{
            check(pane.displayMode == .details,"sibling with shared name prefix does not inherit rule")
            pane.navigate(photos);pane.focus()
            waitFor({ pane.status.stringValue.contains("Objekte") },then:{
                check(pane.displayMode == .icons,"returning to folder reapplies automatic view")
                let manager = FavoritesController(folder:folder);self.main.secondaryWindows.append(manager);manager.showWindow(nil)
                manager.addFavorite(url:photos,kind:.folder)
                check(manager.library.favorites.count == 1 && manager.path.stringValue == photos.path,"favorite editor adds and selects folder")
                let favoriteID = manager.selectedID!;manager.name.stringValue = "Bilder & Projekte";manager.apply.performClick(nil)
                check((try! Preferences.workspaceLibrary()).favorites.first?.title == "Bilder & Projekte","folder favorite name is editable")
                manager.addFavorite(url:photos,kind:.folder);check(manager.library.favorites.count == 1,"same folder is not added twice")
                manager.name.stringValue = "";manager.apply.performClick(nil)
                check(manager.info.textColor == .systemRed && (try! Preferences.workspaceLibrary()).favorites.first?.title == "Bilder & Projekte","invalid editor input preserves saved favorite")
                manager.reload(select:favoriteID)
                manager.addFavorite(url:URL(fileURLWithPath:"/System/Applications/TextEdit.app"),kind:.application)
                manager.name.stringValue = "Texteditor";manager.opensSelection.state = .on;manager.apply.performClick(nil);manager.up.performClick(nil)
                check((try! Preferences.workspaceLibrary()).favorites.map(\.title) == ["Texteditor","Bilder & Projekte"],"program favorites can be named configured and reordered")
                capture(manager.window,"-Favoriten");manager.close();self.main.refreshLocations()
                check(self.main.favoriteMenu.itemArray.contains(where: { $0.title == "Texteditor" }) && self.main.favoriteMenu.itemArray.contains(where: { $0.title == "Favoriten bearbeiten …" }),"favorite popup exposes entries and management")
                let savedLibrary = try! Preferences.workspaceLibrary(),app = savedLibrary.favorites.first!
                var launched: ProgramLaunchRequest?;self.main.programLauncher = { launched = $0 }
                pane.navigate(folder)
                waitFor({ pane.status.stringValue.contains("Objekte") },then:{
                    pane.select([text,image]);try! self.main.openFavorite(app.id)
                    check(launched?.files == pane.selectedURLs && launched?.application.path == app.path,"program favorite passes selected URLs as structured arguments")
                    pane.select([])
                    do { try self.main.openFavorite(app.id);check(false,"program selection required") } catch { check(true,"program selection required") }
                    self.main.programLauncher = nil
                    verifyIconCopy {
                    try! self.main.openFavorite(favoriteID)
                    check(pane.currentURL == photos && pane.displayMode == .icons,"folder favorite navigates and applies automatic view")
                    pane.showCollection([text],title:"Testsammlung")
                    waitFor({ pane.visibleEntries.count == 1 },then:{
                        pane.changeDisplay(.icons)
                        var collectionDrop: [URL] = [];let oldCollectionDrop = pane.onCollectionDrop;pane.onCollectionDrop = { collectionDrop = $0 }
                        check(pane.acceptFiles(pasteboard) && collectionDrop == [text],"collection drop keeps reference semantics in icon view")
                        pane.onCollectionDrop = oldCollectionDrop
                        pane.duplicateTab();pane.tab.collection = [];pane.closeTab();pane.closeTab()
                        pane.showArchive(root:root.appendingPathComponent("ArchivRoot"),original:root.appendingPathComponent("Beispiel.zip"))
                        pane.changeDisplay(.icons)
                        check(pane.readOnly && !pane.acceptFiles(pasteboard),"icon archive view rejects incoming drops")
                        check(pane.savedTabs.count == 2,"archive and collection tabs are not persisted")
                        pane.closeTab();pane.selectTab(second.id)
                        self.main.saveState()
                        let session = try! JSONEncoder().encode(Preferences.state)
                        defaults.set(session,forKey:"session")
                        let restored = Preferences.decode(session)!
                        check(restored.left.count == 2 && restored.left[1].selected == true && restored.right.first?.view?.display == .thumbnails,"session encodes selected tab and independent view")
                        check((try! Preferences.workspaceLibrary()) == savedLibrary,"view navigation and program use preserve favorite library")
                        waitFor({ pane.status.stringValue.contains("Objekte") && pane.visibleEntries.contains(where: { $0.name == "Berge.png" }) },then:{
                            capture(self.main.window,"-Symbolansicht");finish()
                        })
                    })
                    }
                })
            })
        })
    }
}
