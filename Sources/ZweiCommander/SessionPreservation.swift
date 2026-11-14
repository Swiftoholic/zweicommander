import Foundation
import CommanderCore

struct SessionViewRecovery {
    let tab:FolderTab,previous:SavedTab
    let preservation:SessionFieldPreservation?
    init(tab:FolderTab,previous:SavedTab) throws {
        self.tab = tab;self.previous = previous
        if let old = previous.preservation {
            let current = SavedTab(path:tab.url.path,title:tab.title,locked:tab.locked,view:tab.view,selected:nil,lockMode:tab.lockMode,filter:tab.filter,filterRegex:tab.filterRegex)
            let baseline = try tab.sessionPreservation ?? current.currentFieldPreservation()
            preservation = try baseline.restoringFields(["view"],from:old)
        } else { preservation = tab.sessionPreservation }
    }
    func apply() {
        tab.sessionPreservation = preservation
        tab.view = previous.view;tab.sessionReplacedFields.remove("view")
        if previous.explicitlyReplacedFields.contains("view") || previous.preservation == nil { tab.sessionReplacedFields.insert("view") }
        tab.sessionViewBeforeImport = nil
    }
}

extension PaneView {
    func rememberSessionViewBeforeImport() {
        guard tab.sessionViewBeforeImport == nil else { return }
        var previous = SavedTab(path:tab.url.path,title:tab.title,locked:tab.locked,view:tab.view,selected:nil)
        previous.preservation = tab.sessionPreservation;previous.explicitlyReplacedFields = tab.sessionReplacedFields;tab.sessionViewBeforeImport = previous
    }
    func prepareSessionViewRecovery(_ previous:[SavedTab]) throws -> [SessionViewRecovery] {
        var result:[SessionViewRecovery] = []
        // The exact live object remains authoritative across reordering or close/reopen.
        let recoverableClosed = closedTabs.filter { $0.sessionViewBeforeImport != nil }
        for item in tabs+recoverableClosed where item.remote == nil && item.archiveRoot == nil && item.collection == nil && !isSessionTemporary(item.url) {
            if let old = item.sessionViewBeforeImport { result.append(try .init(tab:item,previous:old));continue }
            let candidates = previous.filter { $0.path == item.url.path && $0.title == item.title }
            if candidates.count > 1,candidates.contains(where:{ $0.preservation?.containsUnrecognizedData(in:"view") == true }) {
                throw CommanderError.message("Die frühere Ansicht lässt sich mehreren gleich benannten Tabs zuordnen. Die aktuelle Sitzung und die Vor-Import-Sicherung bleiben unverändert. Diese älteren Ansichtsoptionen können hier nicht eindeutig wiederhergestellt werden.")
            }
            if candidates.count == 1 { result.append(try .init(tab:item,previous:candidates[0])) }
        }
        return result
    }
}
