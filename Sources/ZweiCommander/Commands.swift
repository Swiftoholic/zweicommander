import AppKit
import CommanderCore

extension MainWindow {
    func command(_ id:String) {
        if let compare = keyCompareController,!["help","settings","operations"].contains(id) { compare.command(id);return }
        if let search = keySearchController,!["help","settings","operations"].contains(id) { search.command(id);return }
        if id == "closeTab",let key = NSApp.keyWindow,key !== window { key.performClose(nil); return }
        defer { updateChromeState();content.needsLayout = true }
        do {
            switch id {
            case "open": active.openSelection()
            case "preview": preview(active.selectedURLs)
            case "quickView": content.quickVisible.toggle(); content.quick.previewItem = active.selectedURLs.first.map { $0 as NSURL }
            case "edit":
                guard ensureWritable(active),let url = requireSelection()?.first else { return }
                NSWorkspace.shared.open([url],withApplicationAt:URL(fileURLWithPath:"/System/Applications/TextEdit.app"),configuration:.init()) { _,error in if let error { DispatchQueue.main.async { showFailure(error) } } }
            case "copy":
                if let urls = requireSelection() {
                    if other.tab.collection != nil { other.addToCollection(urls) }
                    else if ensureWritable(other) { transfer(urls,to:other.currentURL,kind:.copy) }
                }
            case "move":
                guard other.tab.collection == nil else { _ = dialog("Dateisammlung",message:"Mit Kopieren werden Verweise zur Sammlung hinzugefügt. Verschieben benötigt einen normalen Zielordner.",buttons:["OK"]);return }
                if ensureWritable(active),ensureWritable(other),let urls = requireSelection() { transfer(urls,to:other.currentURL,kind:.move) }
            case "trash":
                guard ensureWritable(active),let urls = requireSelection() else { return }
                guard dialog("In den Papierkorb verschieben?",message:"\(urls.count) Objekte:\n"+urls.prefix(8).map(\.lastPathComponent).joined(separator:"\n"),buttons:["Papierkorb","Abbrechen"]) == 0 else { return }
                jobs.submit("Papierkorb",work:{ token,_ in FileOperations.trash(urls,token:token) },completion:{ [weak self] in self?.complete($0) })
            case "newFolder":
                guard ensureWritable(active),let name = prompt("Neuer Ordner",value:"Neuer Ordner") else { return }
                try FileOperations.newDirectory(in:active.currentURL,name:name); active.refresh()
            case "newFile":
                guard ensureWritable(active),let name = prompt("Neue Datei",value:"Neu.txt") else { return }
                _ = try FileOperations.newFile(in:active.currentURL,name:name); active.refresh()
            case "rename":
                guard ensureWritable(active),let url = requireSelection()?.first,let name = prompt("Umbenennen",value:url.lastPathComponent) else { return }
                var rule = RenameRule(); rule.pattern = name; if !url.pathExtension.isEmpty { rule.pattern = "{full}"; rule.search = url.lastPathComponent; rule.replacement = name }
                let items = try RenameEngine.preview([url],rule:rule); renameUndo = try RenameEngine.apply(items); undoSteps = []; refresh()
            case "batchRename": batchRename()
            case "search": search()
            case "duplicates": duplicates()
            case "compare": compare()
            case "pack": pack()
            case "extract": extract()
            case "hash": hashes()
            case "verifyHash": verifyHashes()
            case "split": splitFile()
            case "join": joinFile()
            case "properties": properties()
            case "attributes": attributes()
            case "export":
                let panel = NSSavePanel(); panel.nameFieldStringValue = "Dateiliste.tsv"; panel.directoryURL = active.currentURL
                if panel.runModal() == .OK,let url = panel.url { try FileTools.exportTSV(active.visibleEntries).write(to:url,atomically:true,encoding:.utf8) }
            case "folderSize":
                let urls = active.selectedURLs.isEmpty ? [active.currentURL] : active.selectedURLs
                jobs.submit("Ordnergrößen",work:{ token,progress in try urls.map { url in
                    progress(url.lastPathComponent)
                    if FileSystem.isDirectory(url),!FileSystem.isSymlink(url) { let s = try FileSystem.directorySize(url,token:token); return "\(url.path)\n\(bytes(s.bytes)) · \(s.files) Dateien" }
                    return "\(url.path)\n\(bytes(try FileEntry(url:url).size))"
                }.joined(separator:"\n\n") },completion:{ [weak self] result in switch result { case .success(let s): self?.showText("Ordnergrößen",s); case .failure(let e): showFailure(e) } })
            case "refresh": refresh()
            case "hidden": Preferences.state.showHidden.toggle(); left.showHidden = Preferences.state.showHidden; right.showHidden = Preferences.state.showHidden; saveState(); refresh()
            case "tree": active.treeVisible.toggle();active.rememberTabView()
            case "details": active.changeDisplay(.details)
            case "thumbnails": active.changeDisplay(.thumbnails)
            case "icons": active.changeDisplay(.icons)
            case "rememberView": try rememberFolderView()
            case "folderViews": showFolderViews()
            case "orientation": content.split.isVertical.toggle(); content.firstLayout = true; content.needsLayout = true; saveState()
            case "onePane": right.isHidden.toggle(); content.split.adjustSubviews(); left.focus()
            case "linked": linked.toggle(); content.status.stringValue = linked ? "Verknüpftes Navigieren aktiv" : "Verknüpftes Navigieren aus"
            case "swap":
                let tabs = left.tabs,index = left.tabIndex; left.tabs = right.tabs; left.tabIndex = right.tabIndex; right.tabs = tabs; right.tabIndex = index
                left.restoreTabView();right.restoreTabView()
                left.rebuildTabs(); right.rebuildTabs(); refresh()
            case "sameFolder": other.navigate(active.currentURL); active.focus()
            case "flat":
                let root = active.currentURL, pane = active
                jobs.submit("Flache Ansicht",work:{ token,_ in var urls:[URL] = []; try FileSystem.walk(root,showHidden:Preferences.state.showHidden,token:token) { urls.append($0) }; return urls },completion:{ [weak pane] result in switch result { case .success(let urls): pane?.showCollection(urls,title:"Flach · "+root.lastPathComponent); case .failure(let e): showFailure(e) } })
            case "newTab": active.newTab()
            case "duplicateTab": active.duplicateTab()
            case "closeOtherTabs": active.closeOtherTabs()
            case "nextTab": active.stepTab(1)
            case "previousTab": active.stepTab(-1)
            case "moveTabLeft": active.moveTab(active.tab.id,to:active.tabIndex-1)
            case "moveTabRight": active.moveTab(active.tab.id,to:active.tabIndex+1)
            case "closeTab": if active.tabs.count > 1 { active.closeTab() } else { window?.performClose(nil) }
            case "lockTab": active.tab.locked.toggle(); active.rebuildTabs()
            case "nameTab": if let name = prompt("Tab benennen",value:active.tab.title ?? active.currentURL.lastPathComponent) { active.tab.title = name.isEmpty ? nil : name; active.rebuildTabs() }
            case "collection": if let urls = requireSelection() { active.showCollection(urls,title:"Dateisammlung") }
            case "newCollection": active.showCollection([],title:"Dateisammlung")
            case "removeCollectionItem": active.removeFromCollection()
            case "saveCollection":
                let panel = NSSavePanel(); panel.nameFieldStringValue = "Sammlung.zwei.json"; panel.directoryURL = active.currentURL
                if panel.runModal() == .OK,let url = panel.url { try JSONEncoder().encode(active.visibleEntries.map { $0.url.path }).write(to:url,options:.atomic) }
            case "loadCollection":
                let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
                if panel.runModal() == .OK,let url = panel.url { let paths = try JSONDecoder().decode([String].self,from:Data(contentsOf:url)); active.showCollection(paths.map { URL(fileURLWithPath:$0) },title:url.deletingPathExtension().lastPathComponent) }
            case "path": active.beginPathEditing()
            case "filter": active.activate(); window?.makeFirstResponder(active.filterField)
            case "parent": active.goParent()
            case "back": active.history(-1)
            case "forward": active.history(1)
            case "home": active.navigate(FileManager.default.homeDirectoryForCurrentUser)
            case "selectAll": if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.selectAll(nil) } else { active.selectionIndexes = IndexSet(active.visibleEntries.indices) }
            case "invertSelection": active.selectionIndexes = IndexSet(active.visibleEntries.indices).subtracting(active.selectionIndexes)
            case "selectPattern":
                if let pattern = prompt("Nach Muster auswählen",value:"*.pdf",message:"* steht für beliebig viele Zeichen, ? für ein Zeichen.") { let filter = try NameFilter(pattern); active.select(Set(active.visibleEntries.filter { filter.matches($0.name) }.map(\.url))) }
            case "clipboardCopy", "clipboardCut":
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { if id == "clipboardCopy" { editor.copy(nil) } else { editor.cut(nil) }; return }
                guard let urls = requireSelection() else { return }; if id == "clipboardCut" && !ensureWritable(active) { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(urls as [NSURL]); cutURLs = id == "clipboardCut" ? urls : []; cutPasteboardChange = NSPasteboard.general.changeCount
            case "clipboardPaste":
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.paste(nil); return }
                guard ensureWritable(active),let urls = NSPasteboard.general.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty else { return }
                let move = cutPasteboardChange == NSPasteboard.general.changeCount && cutURLs == urls
                transfer(urls,to:active.currentURL,kind:move ? .move : .copy); cutURLs = []
            case "copyPath": NSPasteboard.general.clearContents(); NSPasteboard.general.setString((active.selectedURLs.isEmpty ? [active.currentURL] : active.selectedURLs).map(\.path).joined(separator:"\n"),forType:.string)
            case "reveal": NSWorkspace.shared.activateFileViewerSelecting(active.selectedURLs.isEmpty ? [active.currentURL] : active.selectedURLs)
            case "favorite": try toggleFavorite()
            case "editFavorites": showFavorites()
            case "undo":
                if let editor = NSApp.keyWindow?.firstResponder as? NSTextView { editor.undoManager?.undo(); return }
                if let items = renameUndo {
                    jobs.submitReported("Umbenennung zurücknehmen",notifyQueuedCancellation:true,body:{ token,reporter in
                        try RenameEngine.apply(items,token:token) { progress in if progress.completed == 0 || progress.completed == progress.total { reporter.report("Namen zurücknehmen · "+progress.name) } }
                    },completion:{ [weak self] result in
                        switch result {
                        case .success: self?.renameUndo = nil
                        case .failure(let error): if case CommanderError.cancelled = error {} else { showFailure(error) }
                        }
                        self?.refresh()
                    })
                }
                else if !undoSteps.isEmpty {
                    let steps = undoSteps
                    jobs.submit("Rückgängig",work:{ _,_ in FileOperations.undo(steps) },completion:{ [weak self] result in
                        if case .success(let errors) = result { if !errors.isEmpty { self?.showText("Rückgängig · Hinweise",errors.joined(separator:"\n")) } else { self?.undoSteps = [] } }
                        self?.refresh()
                    })
                }
            case "terminal": openTerminal()
            case "shell": shell()
            case "connect": connectServer()
            case "remote": remoteConnect()
            case "sftp": sftpTerminal()
            case "symlink":
                guard ensureWritable(other),let url = requireSelection()?.first,let name = prompt("Symbolische Verknüpfung",value:url.lastPathComponent+" Link",message:"Zielordner: "+other.currentURL.path) else { return }
                try FileSystem.validateName(name); try FileManager.default.createSymbolicLink(at:other.currentURL.appendingPathComponent(name),withDestinationURL:url); refresh()
            case "settings": settings()
            case "importSettings": importSettings()
            case "importReport":
                if let profile = Preferences.state.importedProfile { showText("Einstellungsimport",importReport(profile)) }
                else { _ = dialog("Noch keine INI-Einstellungen importiert",buttons:["OK"]) }
            case "restoreImport": restoreBeforeSettingsImport()
            case "log": showText("Vorgangsprotokoll",jobs.log.isEmpty ? "Noch keine Vorgänge in dieser Sitzung." : jobs.log.joined(separator:"\n\n"))
            case "operations": showOperations()
            case "help": showText("ZweiCommander · Bedienung",helpText)
            default: break
            }
        } catch { showFailure(error) }
    }
    func batchRename() {
        guard ensureWritable(active),let urls = requireSelection() else { return }
        guard urls.count <= RenameEngine.maximumItems else { showFailure(CommanderError.message("Höchstens 10.000 Objekte auswählen."));return }
        let controller = RenameController(sources:urls,digits:Preferences.state.importedProfile?.renameCounterDigits ?? 3)
        controller.onSubmit = { [weak self,weak controller] items in
            guard let self else { return UUID() }
            return self.jobs.submitReported("Mehrfachumbenennen",notifyQueuedCancellation:true,body:{ token,reporter in
                var last = Date.distantPast
                return try RenameEngine.apply(items,token:token) { update in
                    guard Date().timeIntervalSince(last) >= 0.08 || update.completed == update.total else { return };last = Date()
                    let phase = update.phase == .staging ? "Bereite vor" : update.phase == .publishing ? "Benenne um" : "Stelle wieder her"
                    let text = "\(phase) · \(update.completed)/\(update.total) · "+update.name
                    let fraction = update.total == 0 ? 1 : (update.phase == .staging ? 0 : 0.5)+Double(update.completed)/Double(update.total)*0.5
                    reporter.report(text,fraction:fraction);DispatchQueue.main.async { controller?.updateProgress(text) }
                }
            },completion:{ [weak self,weak controller] result in
                if case .success(let undo) = result { self?.renameUndo = undo;self?.undoSteps = [] }
                controller?.finished(result);self?.refresh()
            })
        }
        controller.onCancel = { [weak self] id in self?.jobs.scheduler.cancel(id);self?.jobs.publish() }
        controller.onReport = { [weak self] text in self?.showText("Umbenennungsbericht",text) }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
    func reportView(_ text:String) -> NSScrollView {
        let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:650,height:260)); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = NSTextView(frame:scroll.bounds); view.isEditable = false; view.isRichText = false; view.font = .monospacedSystemFont(ofSize:11,weight:.regular); view.string = text; view.autoresizingMask = [.width]; scroll.documentView = view; return scroll
    }
}
