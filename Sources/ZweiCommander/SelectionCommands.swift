import AppKit
import CommanderCore

extension PaneView {
    var selectionScope:String {
        if let remote { return "server:"+remote.connection.endpointID+":"+currentURL.path }
        if tab.collection != nil { return "collection:"+tab.id.uuidString }
        return "folder:"+FileSystem.canonical(currentURL).absoluteString
    }
    var selectionContext:SelectionContext { SelectionContext(scope:selectionScope,entries:visibleEntries,selected:Set(selectedURLs)) }
    var selectionSeed:FileEntry? { focusedEntryURL.flatMap { focus in visibleEntries.first { $0.url == focus } } ?? visibleEntries.first { selectedURLs.contains($0.url) } }
}

extension MainWindow {
    static let selectionCopyCommands:[(String,String,SelectionCopyFormat)] = [
        ("Namen kopieren","copyNames",.names),("Namen ohne Endung kopieren","copyStems",.stems),
        ("Vollständige Pfade kopieren","copyPath",.paths),("Datei-URLs kopieren","copyURLs",.urls),
        ("Als Shell-Argumente kopieren","copyShellPaths",.shellArguments),("Als Tabelle kopieren","copySelectionTable",.table)
    ]
    static let selectionCommands:Set<String> = ["selectFiles","deselectAll","invertFiles","sameExtension","deselectExtension","sameStem","deselectStem","saveSelection","restoreSelection","saveSelectionFile","loadSelectionFile","selectPattern"]
    func selectionCommandEnabled(_ id:String) -> Bool? {
        let format = Self.selectionCopyCommands.first { $0.1 == id }?.2
        guard Self.selectionCommands.contains(id) || format != nil else { return nil }
        guard NSApp.keyWindow === window,active.canUseDisplayedEntries,!active.pathField.sessionActive,active.remote == nil || active.remoteReady else { return false }
        if id == "copyPath" { return true }
        if format != nil { return !active.selectedURLs.isEmpty && (format != .shellArguments || active.remote == nil) }
        if ["sameExtension","deselectExtension"].contains(id) { return active.selectionSeed.map { !$0.isDirectory } ?? false }
        if ["sameStem","deselectStem"].contains(id) { return active.selectionSeed != nil }
        if ["saveSelection","saveSelectionFile"].contains(id) { return !active.selectedURLs.isEmpty }
        if id == "restoreSelection" { return active.tab.selectionMemory?.scope == active.selectionScope }
        return true
    }
    @discardableResult func handleSelectionCommand(_ id:String) throws -> Bool {
        guard selectionCommandEnabled(id) != nil else { return false }
        guard selectionCommandEnabled(id) == true else { return true }
        let pane = active
        if let format = Self.selectionCopyCommands.first(where:{$0.1 == id})?.2 {
            let value:String
            if id == "copyPath",pane.selectedURLs.isEmpty { value = pane.locationText }
            else { let selected = Set(pane.selectedURLs);value = try format.render(pane.visibleEntries.filter { selected.contains($0.url) }) }
            selectionPasteboard.clearContents();selectionPasteboard.setString(value,forType:.string)
            content.status.stringValue = id == "copyPath" && pane.selectedURLs.isEmpty ? "Ordneradresse kopiert" : "\(pane.selectedURLs.count) Einträge in die Zwischenablage kopiert"
            return true
        }
        let current = Set(pane.selectedURLs),files = Set(pane.visibleEntries.filter { !$0.isDirectory }.map(\.url))
        switch id {
        case "selectFiles":pane.select(files)
        case "deselectAll":pane.select([])
        case "invertFiles":pane.select(current.subtracting(files).union(files.subtracting(current)))
        case "sameExtension","deselectExtension","sameStem","deselectStem":
            guard let seed = pane.selectionSeed else { return true }
            let matches = id.contains("Extension") ? SelectionNames.sameExtension(as:seed,in:pane.visibleEntries) : SelectionNames.sameStem(as:seed,in:pane.visibleEntries)
            pane.select(id.hasPrefix("deselect") ? current.subtracting(matches) : current.union(matches))
        case "saveSelection":pane.tab.selectionMemory = (pane.selectionScope,current);content.status.stringValue = "\(current.count) Markierungen für diesen Tab und Ordner gemerkt"
        case "restoreSelection":
            guard let saved = pane.tab.selectionMemory,saved.scope == pane.selectionScope else { return true }
            pane.select(saved.urls);content.status.stringValue = "\(pane.selectedURLs.count) von \(saved.urls.count) gemerkten Markierungen wiederhergestellt"
        case "selectPattern":
            let tabID = pane.tab.id,scope = pane.selectionScope
            let controller = SelectionController(location:pane.locationText,context:{ [weak pane] in
                guard let pane,pane.tab.id == tabID,pane.selectionScope == scope,pane.canUseDisplayedEntries,!pane.pathField.sessionActive,pane.remote == nil || pane.remoteReady else { return nil };return pane.selectionContext
            },apply:{ [weak pane] urls in pane?.select(urls);pane?.focus() })
            secondaryWindows.append(controller);controller.showWindow(nil)
        case "saveSelectionFile":if let url = chooseSelectionFile(saving:true) { try saveSelection(to:url);content.status.stringValue = "Auswahl gespeichert: \(current.count) Einträge" }
        case "loadSelectionFile":if let url = chooseSelectionFile(saving:false) { try loadSelection(from:url) }
        default:break
        }
        return true
    }
    func chooseSelectionFile(saving:Bool) -> URL? {
        let directory = active.currentURL.isFileURL ? active.currentURL : FileManager.default.homeDirectoryForCurrentUser
        if let selectionFileChooser { return selectionFileChooser(saving,directory) }
        if saving {
            let panel = NSSavePanel();panel.nameFieldStringValue = "Auswahl.zwei-selection.json";panel.directoryURL = directory
            panel.message = "Speichert die markierten Adressen. Dateiinhalte und Zugangsdaten gehören nicht zur Auswahldatei."
            return panel.runModal() == .OK ? panel.url : nil
        }
        let panel = NSOpenPanel();panel.allowsMultipleSelection = false;panel.canChooseDirectories = false;panel.directoryURL = directory
        panel.message = "Markiert nur passende, aktuell sichtbare Einträge. Dateien werden nicht geöffnet oder verändert."
        return panel.runModal() == .OK ? panel.url : nil
    }
    func saveSelection(to url:URL) throws {
        guard url.isFileURL else { throw CommanderError.message("Die Auswahldatei muss lokal gespeichert werden.") }
        try SelectionDocument(active.selectedURLs).encoded().write(to:url,options:.atomic)
    }
    func loadSelection(from url:URL) throws {
        guard url.isFileURL,let size = try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber,size.int64Value <= Int64(SelectionDocument.maximumBytes) else { throw CommanderError.message("Bitte eine lokale Auswahldatei bis 2 MiB wählen.") }
        let document = try SelectionDocument.decode(Data(contentsOf:url,options:.mappedIfSafe)),old = Set(active.selectedURLs)
        active.select(Set(document.urls))
        if !document.urls.isEmpty,active.selectedURLs.isEmpty { active.select(old);content.status.stringValue = "Keine passenden sichtbaren Einträge gefunden. Die Auswahl bleibt erhalten." }
        else { content.status.stringValue = "\(active.selectedURLs.count) von \(document.urls.count) gespeicherten Einträgen markiert" }
    }
}
