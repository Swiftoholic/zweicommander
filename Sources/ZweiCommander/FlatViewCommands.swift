import AppKit
import CommanderCore

extension MainWindow {
    @discardableResult func showFlatView() -> UUID? {
        let pane = active
        guard !SettingsBackupStorage.persistenceSuspended,pane.remote == nil,pane.archive == nil,
              window?.isVisible == true else { return nil }
        let root = pane.currentURL,tabID = pane.tab.id,tabVersion = pane.tab.locationVersion,
            paneVersion = pane.locationVersion,windowVersion = flatViewWindowVersion,
            collection = pane.tab.collection,hidden = pane.showHidden
        let afterScan = Preferences.testMode ? flatViewAfterScanForTesting : nil
        return jobs.submit("Flache Ansicht",work:{ token,_ in
            var urls:[URL] = []
            try FileSystem.walk(root,showHidden:hidden,token:token) { urls.append($0) }
            try token.check();afterScan?(token);return (urls:urls,token:token)
        },completion:{ [weak self,weak pane] result in
            guard let self,let pane,self.window?.isVisible == true,self.flatViewWindowVersion == windowVersion,
                  pane.locationVersion == paneVersion,pane.tab.id == tabID,pane.tab.locationVersion == tabVersion,
                  pane.currentURL == root,pane.tab.collection == collection,pane.remote == nil,pane.archive == nil,
                  !pane.pathField.sessionActive,!pane.inlineRename.isEditing,self.keyWorkflowWindow == nil,
                  !(self.active === pane && self.window?.firstResponder is NSTextView) else { return }
            switch result {
            case .success(let scan):
                guard !scan.token.isCancelled else { return }
                pane.showCollection(scan.urls,title:"Flach · "+root.lastPathComponent,activate:self.active === pane && self.window?.isKeyWindow == true)
            case .failure(CommanderError.cancelled): self.content.status.stringValue = "Flache Ansicht abgebrochen."
            case .failure(let error): showFailure(error)
            }
        })
    }
}
