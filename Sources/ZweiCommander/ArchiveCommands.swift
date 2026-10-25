import AppKit
import CommanderCore

extension MainWindow {
    func archiveCommandEnabled(_ id:String) -> Bool? {
        if NSApp.keyWindow?.firstResponder is NSTextView,["clipboardCopy","clipboardCut","clipboardPaste","undo","selectAll"].contains(id) { return nil }
        if ["pack","extract"].contains(id) {
            guard NSApp.keyWindow === window,active.canUseDisplayedEntries,!active.pathField.sessionActive,active.remote == nil,other.remote == nil,!other.readOnly,other.tab.collection == nil else { return false }
            return id == "pack" ? active.archive == nil && !active.selectedURLs.isEmpty : active.archive != nil || active.selectedURLs.count == 1 && active.selectionSeed?.isRegularFile == true
        }
        if ["archiveContainer","archivePassword"].contains(id) { return active.archive != nil && NSApp.keyWindow === window && !active.pathField.sessionActive }
        if ["copy","move"].contains(id),other.archive != nil { return false }
        guard active.archive != nil else { return nil }
        if ["copyPath","copySelectionTable"].contains(id) { return active.canUseDisplayedEntries && !active.pathField.sessionActive }
        if id == "copy" { return active.canUseDisplayedEntries && !active.pathField.sessionActive && !active.selectedURLs.isEmpty && !active.visibleEntries.filter { active.selectedURLs.contains($0.url) }.contains(where:{ $0.isSymbolicLink || (!$0.isDirectory && !$0.isRegularFile) }) && other.remote == nil && !other.readOnly && other.tab.collection == nil }
        if ["edit","move","trash","newFolder","newFile","rename","batchRename","hash","verifyHash","split","join","attributes","export","folderSize","flat","compare","duplicates","terminal","shell","symlink","favorite","rememberView","folderViews","search","clipboardCut","clipboardCopy","clipboardPaste","collection","newCollection","saveCollection","copyURLs","copyShellPaths","saveSelectionFile","loadSelectionFile","tree","linked"].contains(id) { return false }
        return nil
    }
    @discardableResult func handleArchiveCommand(_ id:String) throws -> Bool {
        if archiveCommandEnabled(id) == false { content.status.stringValue = "Die Archivansicht ist schreibgeschützt. Mit F5 oder ⌥F6 in einen neuen lokalen Ordner entpacken.";return true }
        guard let archive = active.archive else { return false }
        switch id {
        case "copy","extract":showArchiveExtraction(session:archive,selection:active.selectedURLs.map(archive.path),base:archive.path(active.currentURL));return true
        case "archiveContainer":active.leaveArchive(container:true);return true
        case "archivePassword":askArchivePassword(archive.catalog.source.lastPathComponent) { [weak self,weak archive] value in guard let archive else { return };archive.password = value;self?.archiveQuickURL = nil;self?.reloadArchive(archive) };return true
        case "refresh":reloadArchive(archive);return true
        case "sameFolder":let source = active;other.openArchiveSession(archive,at:source.currentURL);source.focus();return true
        case "preview":preview(active.selectedURLs);return true
        case "quickView":
            content.quickVisible.toggle();archiveQuickURL = nil
            if content.quickVisible,let url = active.selectedURLs.first { openArchiveMember(url,preview:true,quick:true) } else { content.quick.previewItem = nil };return true
        case "properties":
            let values = active.visibleEntries.filter { active.selectedURLs.contains($0.url) }
            showText("Archiveigenschaften",values.map { $0.name+"\n"+archive.describe($0.url)+"\n"+$0.kind+"\n"+bytes($0.size) }.joined(separator:"\n\n"));return true
        case "reveal":NSWorkspace.shared.activateFileViewerSelecting([archive.catalog.source]);return true
        case "copyPath","copySelectionTable":
            let values = active.visibleEntries.filter { active.selectedURLs.contains($0.url) },text:String
            if id == "copyPath" { text = values.isEmpty ? active.locationText : values.map { archive.describe($0.url) }.joined(separator:"\n") }
            else {
                func escape(_ text:String) -> String { text.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\t",with:"\\t").replacingOccurrences(of:"\r",with:"\\r").replacingOccurrences(of:"\n",with:"\\n") }
                let date = ISO8601DateFormatter();text = (["Name\tBytes\tGeändert\tArt\tPfad"]+values.map { [$0.name,$0.isDirectory ? "" : String($0.size),$0.modified == .distantPast ? "" : date.string(from:$0.modified),$0.kind,archive.describe($0.url)].map(escape).joined(separator:"\t") }).joined(separator:"\n")
            }
            selectionPasteboard.clearContents();selectionPasteboard.setString(text,forType:.string);content.status.stringValue = "Archivadresse kopiert";return true
        default:return false
        }
    }
    func showArchivePack(_ sources:[URL]) {
        let fileExtension = Preferences.state.importedProfile?.defaultArchiveExtension ?? "zip",format = ArchiveFormat.allCases.first { $0.fileExtension == fileExtension } ?? .zip
        let name = (sources.count == 1 ? ArchiveCatalog.folderName(for:sources[0]) : "Archiv")+"."+format.fileExtension
        showArchiveSetup(mode:.pack(sources),destination:other.currentURL.appendingPathComponent(name))
    }
    func showArchiveExtraction(session:ArchiveFolderSession,selection:[String],base:String) {
        showArchiveSetup(mode:.extract(session.catalog.source,session.catalog,selection.isEmpty ? nil : selection,base),destination:other.currentURL.appendingPathComponent(session.catalog.suggestedFolderName),password:session.password)
    }
    func showArchiveSetup(mode:ArchiveSetupMode,destination:URL,password:String = "") {
        let cache = self.cache
        let controller = ArchiveSetupController(mode:mode,destination:destination,secret:password,validateDestination:{ url in
            guard url.isFileURL,!FileSystem.isInside(url,cache) else { throw CommanderError.message("Bitte ein Ziel außerhalb temporärer Archivansichten wählen.") }
        })
        controller.onSubmit = { [weak self] plan,password,start in guard let self else { return false };return self.enqueueArchive(plan,password:password,start:start) }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
    @discardableResult func enqueueArchive(_ plan:ArchivePrepared,password:String,start:Bool) -> Bool {
        let secret = ArchiveSecret(password),title:String
        switch plan { case .pack:title = "Archiv erstellen";case .extract:title = "Archiv entpacken" }
        let id = jobs.submitReported(title+" · "+plan.destination.lastPathComponent,start:start,notifyQueuedCancellation:true,body:{ token,reporter in
            defer { secret.value = "" }
            switch plan { case .pack(let value):try value.execute(token:token,progress:{ reporter.report($0) })
            case .extract(let value):try ArchiveService.extract(value,password:secret.value,token:token,progress:{ reporter.report($0) }) }
        },completion:{ [weak self] result in
            secret.value = "";guard let self else { return }
            self.refresh()
            switch result { case .success:self.content.status.stringValue = "\(title) abgeschlossen: "+plan.destination.path
            case .failure(let error):self.content.status.stringValue = error.localizedDescription }
        })
        showOperations(select:id);return true
    }
}
