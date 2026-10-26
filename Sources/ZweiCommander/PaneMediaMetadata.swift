import AppKit
import CommanderCore


extension PaneView {
    func configureMediaCell(_ cell:FileCellView,entry:FileEntry,field:MediaMetadataField) {
        let version = mediaGeneration
        func install(_ value:PaneMediaMetadataCache.Value,into cell:FileCellView) {
            switch value {
            case .ready(let metadata):cell.textField?.stringValue = field.text(metadata) ?? "—";cell.toolTip = field.text(metadata).map { field.title+": "+$0 } ?? "Feld nicht im unterstützten Dateikopf vorhanden."
            case .failed(let error):cell.textField?.stringValue = "—";cell.toolTip = "Nicht verfügbar: "+error
            }
        }
        if let value = mediaCache.request(entry,generation:version,completion:{ [weak self] _ in
            guard let self,self.mediaGeneration == version,let identity = entry.mediaIdentity else { return }
            let rows = IndexSet(self.visibleEntries.indices.filter { self.visibleEntries[$0].mediaIdentity == identity })
            let columns = IndexSet(self.table.tableColumns.indices.filter { !self.table.tableColumns[$0].isHidden && MediaMetadataField(rawValue:self.table.tableColumns[$0].identifier.rawValue) != nil })
            guard !rows.isEmpty,!columns.isEmpty else { return }
            self.table.reloadData(forRowIndexes:rows,columnIndexes:columns)
        }) { install(value,into:cell) }
        else { cell.textField?.stringValue = "…";cell.toolTip = "Mediendaten werden im Hintergrund gelesen." }
    }
}
