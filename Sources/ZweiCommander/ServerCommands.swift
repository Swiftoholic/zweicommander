import AppKit
import CommanderCore

extension MainWindow {
    var usesServerPanes: Bool { left.remote != nil || right.remote != nil }
    func serverCommandEnabled(_ id: String) -> Bool? {
        guard usesServerPanes else { return nil }
        if NSApp.keyWindow?.firstResponder is NSTextView,["clipboardCopy","clipboardCut","clipboardPaste","undo","selectAll"].contains(id) { return true }
        if ["copy","move"].contains(id) {
            guard (active.remote != nil) != (other.remote != nil) else { return false }
            let source = id == "copy" ? active : other,local = active.remote == nil ? active : other,server = active.remote == nil ? other : active
            return server.remoteReady && !local.readOnly && local.tab.collection == nil && !source.selectedURLs.isEmpty && (source.remote == nil || !source.selectedRemoteEntries.contains(where:{$0.isLink}))
        }
        if ["compare","symlink","pack","extract","linked"].contains(id) { return false }
        guard active.remote != nil else { return nil }
        if ["rename","trash"].contains(id) { let values = active.selectedRemoteEntries;return active.remoteReady && !values.isEmpty && !values.contains(where:{$0.isLink}) && (id != "rename" || values.count == 1) }
        if id == "newFolder" { return active.remoteReady }
        if id == "properties" { return !active.selectedRemoteEntries.isEmpty }
        return ["open","refresh","hidden","details","thumbnails","icons","orientation","onePane","swap","sameFolder","newTab","duplicateTab","closeOtherTabs","nextTab","previousTab","moveTabLeft","moveTabRight","closeTab","lockTab","nameTab","path","filter","parent","back","forward","home","selectAll","invertSelection","selectPattern","copyPath","editFavorites","help","settings","customizeToolbar","importSettings","importReport","restoreImport","log","operations","recovery","pauseTransfers","stopTransfers","remote","connect","sftp"].contains(id)
    }
    func serverTransferTitle(_ id: String) -> String? {
        guard usesServerPanes,["copy","move"].contains(id) else { return nil }
        guard (active.remote != nil) != (other.remote != nil) else { return "Server → Server nicht verfügbar" }
        return (id == "copy" ? active : other).remote == nil ? "Hochladen" : "Herunterladen"
    }
    @discardableResult func handleServerCommand(_ id: String) throws -> Bool {
        if usesServerPanes,["copy","move"].contains(id) {
            guard serverCommandEnabled(id) == true else { return true }
            let source = id == "copy" ? active : other,target = id == "copy" ? other : active
            let server = source.remote == nil ? target : source,local = source.remote == nil ? source : target
            guard let connection = server.remote?.connection else { return true }
            showRemoteTransfer(connection,direction:source.remote == nil ? .upload : .download,path:server.currentURL.path,local:local.currentURL,sources:source.remote == nil ? source.selectedURLs : [],entries:source.remote == nil ? [] : source.selectedRemoteEntries)
            return true
        }
        guard let remote = active.remote else { return false }
        switch id {
        case "rename","newFolder","trash":
            let mode: RemoteMutationKind = id == "rename" ? .rename : id == "trash" ? .delete : .createDirectory
            let pane = active,tabID = active.tab.id
            let connection = remote.connection,controller = RemoteActionController(connection,kind:mode,directory:active.currentURL.path,entries:id == "newFolder" ? [] : active.selectedRemoteEntries)
            controller.onSubmit = { [weak self,weak pane] plan in
                guard let self else { return false }
                let id = self.jobs.submitReported(mode == .delete ? "Server löschen" : mode == .rename ? "Server umbenennen" : "Serverordner erstellen",notifyQueuedCancellation:true,body:{ token,reporter in
                    try RemoteMutation.execute(plan,using:RemoteService.transport(connection,token:token),token:token) { done,total,path in reporter.report("\(done)/\(total) · "+path,fraction:Double(done)/Double(max(1,total))) }
                },completion:{ [weak self,weak pane] result in
                    if case .success = result,let pane,pane.tab.id == tabID,let target = plan.target { pane.requestSelection([connection.address(target)]) }
                    if case .failure(let error) = result { self?.content.status.stringValue = error.localizedDescription }
                    self?.refresh()
                })
                self.showOperations(select:id);return true
            }
            secondaryWindows.append(controller);controller.showWindow(nil);return true
        case "sameFolder":_ = other.openRemote(remote.connection,path:active.currentURL.path);active.focus();return true
        case "properties":showText("Servereigenschaften",active.selectedRemoteEntries.map { $0.name+"\n"+remote.connection.address(RemoteService.child(active.currentURL.path,$0.name)).absoluteString+"\n"+($0.isDirectory ? "Ordner" : bytes($0.size)) }.joined(separator:"\n\n"));return true
        default:return false
        }
    }
    func showRemoteTransfer(_ connection: RemoteConnection,direction: RemoteDirection,path: String,local: URL,sources: [URL],entries: [RemoteEntry]) {
        let controller = RemoteTransferController(connection:connection,direction:direction,path:path,local:local,sources:sources,entries:entries)
        controller.onSubmit = { [weak self] plan,start in
            guard let self else { return false }
            let id = self.jobs.submitReported((plan.direction == .upload ? "Upload" : "Download")+" · "+connection.host,start:start,items:plan.initialItems,notifyQueuedCancellation:true,body:{ token,reporter in
                try RemotePlanner.execute(plan,using:RemoteService.transport(connection,token:token),token:token,progress:reporter.transfer)
            },completion:{ [weak self] result in
                if case .failure(let error) = result { self?.content.status.stringValue = error.localizedDescription }
                self?.refresh()
            })
            self.showOperations(select:id);return true
        }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
}
