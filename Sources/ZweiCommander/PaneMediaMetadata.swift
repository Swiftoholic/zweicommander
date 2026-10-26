import AppKit
import CommanderCore


extension PaneView {
    /// Column/metadata refreshes replace cells without changing the current file identities.
    func reloadTablePreservingSelection(rows:IndexSet? = nil,columns:IndexSet? = nil,change:(()->Void)? = nil) {
        let selected = rawSelectedURLs,focus = focusedEntryURL,wasSyncing = syncingSelection
        syncingSelection = true;change?()
        if let rows,let columns { table.reloadData(forRowIndexes:rows,columnIndexes:columns) } else { table.reloadData() }
        selectionIndexes = IndexSet(visibleEntries.indices.filter { selected.contains(visibleEntries[$0].url) })
        if let focus,visibleEntries.contains(where:{ $0.url == focus }) { focusedEntryURL = focus }
        syncingSelection = wasSyncing;redrawFileFocus()
    }
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
            self.reloadTablePreservingSelection(rows:rows,columns:columns)
        }) { install(value,into:cell) }
        else { cell.textField?.stringValue = "…";cell.toolTip = "Mediendaten werden im Hintergrund gelesen." }
    }
}
