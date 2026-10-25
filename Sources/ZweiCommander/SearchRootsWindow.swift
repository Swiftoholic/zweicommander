import AppKit
import CommanderCore

final class SearchRootsController:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate {
    private(set) var roots:[URL]
    let table = operationTable([("path","Suchordner – jeder Eintrag ist ein vollständiger Pfad",700)])
    let candidate = input(placeholder:"Vollständigen Pfad als einzelnen Suchort hinzufügen")
    let add = ActionButton("Hinzufügen",symbol:"plus",action:{}),choose = ActionButton("Ordner wählen …",symbol:"folder",action:{})
    let remove = ActionButton("Entfernen",symbol:"minus",action:{}),apply = ActionButton("Übernehmen",action:{}),cancel = ActionButton("Abbrechen",action:{})
    let info = label("Bis zu 100 lokale Ordner. Überlappende Suchbäume und doppelte Treffer werden beim Suchen abgeglichen.",size:12,color:.secondaryLabelColor)
    var onApply:(([URL])throws->Void)?,onClose:(()->Void)?
    init(_ roots:[URL]) {
        self.roots = roots
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:820,height:440),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.title = "Suchorte verwalten";w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self;let root = OperationContent(frame:w.contentView!.bounds);w.contentView = root
        let heading = label("Suchorte",size:21,weight:.semibold);heading.frame = NSRect(x:22,y:390,width:776,height:30);root.addSubview(heading)
        candidate.frame = NSRect(x:22,y:345,width:600,height:28);candidate.setAccessibilityLabel("Einzelner zusätzlicher Suchordner");root.addSubview(candidate)
        add.frame = NSRect(x:632,y:343,width:166,height:30);root.addSubview(add)
        table.delegate = self;table.dataSource = self;table.allowsMultipleSelection = true;table.intercellSpacing = NSSize(width:4,height:0);table.setAccessibilityLabel("Liste der Suchordner")
        let scroll = operationScroll(table);scroll.frame = NSRect(x:22,y:134,width:776,height:198);root.addSubview(scroll)
        choose.frame = NSRect(x:22,y:91,width:210,height:30);remove.frame = NSRect(x:242,y:91,width:155,height:30);root.addSubview(choose);root.addSubview(remove)
        info.frame = NSRect(x:22,y:46,width:776,height:39);info.maximumNumberOfLines = 2;root.addSubview(info)
        cancel.frame = NSRect(x:548,y:11,width:115,height:30);apply.frame = NSRect(x:673,y:11,width:125,height:30);root.addSubview(cancel);root.addSubview(apply)
        add.perform = { [weak self] in self?.addTyped() };choose.perform = { [weak self] in self?.chooseFolders() };remove.perform = { [weak self] in self?.removeSelected() }
        apply.perform = { [weak self] in self?.submit() };cancel.perform = { [weak self] in self?.close() };cancel.keyEquivalent = "\u{1b}";cancel.keyEquivalentModifierMask = []
        choose.setHelp("Ordner wählen","Mehrere Ordner gleichzeitig zur Ortsliste hinzufügen.",shortcut:"⌘O");apply.setHelp("Übernehmen","Die Ortsliste übernehmen. Suchprofile speichern ausschließlich Regeln.",shortcut:"⌘↩")
        w.workflowKeys = { [weak self,weak w] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"\r",.command) { self.submit();return true }
            if WorkflowKeys.matches(event,"o",.command) { self.chooseFolders();return true }
            if WorkflowKeys.matches(event,"l",.command) { w?.makeFirstResponder(self.candidate);self.candidate.selectText(nil);return true }
            if WorkflowKeys.matches(event,"\u{7f}"),w?.firstResponder === self.table { self.removeSelected();return true }
            return false
        };w.initialFirstResponder = candidate;refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    func addRoots(_ values:[URL]) throws {
        var options = SearchOptions();options.recursive = false
        roots = try SearchService.searchRoots(roots+values,options:options);candidate.stringValue = "";info.textColor = .secondaryLabelColor;refresh()
    }
    func addTyped() {
        do { let path = (candidate.stringValue as NSString).expandingTildeInPath;guard path.hasPrefix("/") else { throw CommanderError.message("Einen vollständigen lokalen Pfad angeben.") };try addRoots([URL(fileURLWithPath:path)]) }
        catch { info.stringValue = error.localizedDescription;info.textColor = .systemRed }
    }
    func chooseFolders() {
        let panel = NSOpenPanel();panel.canChooseDirectories = true;panel.canChooseFiles = false;panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { do { try addRoots(panel.urls) } catch { info.stringValue = error.localizedDescription;info.textColor = .systemRed } }
    }
    func removeSelected() { let indexes = table.selectedRowIndexes;roots = roots.enumerated().filter { !indexes.contains($0.offset) }.map(\.element);refresh() }
    private func refresh() { table.reloadData();apply.isEnabled = !roots.isEmpty;remove.isEnabled = !table.selectedRowIndexes.isEmpty;info.stringValue = "\(roots.count) von 100 Suchorten · Überlappende Suchbäume werden abgeglichen. Die Liste verwendet keine Pfad-Trennzeichen." }
    func submit() { do { guard !roots.isEmpty else { return };try onApply?(roots);close() } catch { info.stringValue = error.localizedDescription;info.textColor = .systemRed } }
    override func close() { if let w = window { w.sheetParent?.endSheet(w) };super.close() }
    func windowWillClose(_ notification:Notification) { onApply = nil;let action = onClose;onClose = nil;action?() }
    func tableViewSelectionDidChange(_ notification:Notification) { remove.isEnabled = !table.selectedRowIndexes.isEmpty }
    func numberOfRows(in tableView:NSTableView) -> Int { roots.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        guard roots.indices.contains(row) else { return nil };let cell = label(roots[row].path.debugDescription,size:12);cell.lineBreakMode = .byTruncatingMiddle;cell.toolTip = roots[row].path;return cell
    }
}

final class SearchWorkspaceWindow:NSWindow {
    var searchKeys:((NSEvent)->Bool)?
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        if isKeyWindow,attachedSheet == nil,event.window == nil || event.window === self,searchKeys?(event) == true { return true }
        return super.performKeyEquivalent(with:event)
    }
}
