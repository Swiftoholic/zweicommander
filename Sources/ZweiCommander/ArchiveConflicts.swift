import AppKit
import CommanderCore

private let archiveDate:DateFormatter = { let value = DateFormatter();value.dateStyle = .short;value.timeStyle = .short;return value }()

extension ArchiveSetupController {
    @objc func policyChanged() {
        guard policy.indexOfSelectedItem >= 0 else { return }
        if let merge = prepared?.merge { replacePrepared(.merge(merge.applying(ArchiveConflictPolicy.allCases[policy.indexOfSelectedItem]))) } else { prepare() }
    }
    @objc func filterConflicts() { previewPage = 0;updatePreview() }
    func changePage(_ offset:Int) { previewPage += offset;updatePreview();if !rows.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);table.scrollRowToVisible(0) } }
    func updateConflictButtons() {
        let merge = prepared?.merge,pending = merge?.unresolvedCount ?? 0
        policy.isEnabled = merge != nil && !isPreparing
        conflictsOnly.isEnabled = (merge?.conflictCount ?? 0) > 0
        for button in [conflictsOnly,previousConflict,nextConflict] { button.isHidden = packing }
        previousConflict.isEnabled = pending > 0;nextConflict.isEnabled = pending > 0
        previousPage.isEnabled = previewPage > 0;nextPage.isEnabled = (previewPage+1)*500 < filteredIndexes.count
    }
    func updatePreview() {
        guard let prepared else { updateConflictButtons();return }
        let merge = prepared.merge,all = prepared.rows
        filteredIndexes = all.indices.filter { merge == nil || conflictsOnly.state == .off || merge!.actions[$0].conflict }
        previewPage = min(max(0,previewPage),max(0,(filteredIndexes.count-1)/500))
        visibleIndexes = Array(filteredIndexes.dropFirst(previewPage*500).prefix(500));rows = visibleIndexes.map { all[$0] }
        let columns:[(String,String,CGFloat)] = merge == nil ? [("name","Pfad im Ergebnis",480),("kind","Art",110),("size","Größe",110)] : [("name","Pfad im Archiv",190),("decision","Entscheidung",220),("size","Archivgröße",80),("targetSize","Zielgröße",80),("sourceDate","Archivdatum",120),("targetDate","Zieldatum",120),("target","Zielpfad",180)]
        if table.tableColumns.map(\.identifier.rawValue) != columns.map({$0.0}) {
            table.columnAutoresizingStyle = .noColumnAutoresizing
            for column in table.tableColumns { table.removeTableColumn(column) }
            for (id,title,width) in columns { let column = NSTableColumn(identifier:.init(id));column.title = title;column.width = width;column.minWidth = id == "decision" ? 180 : id == "target" ? 150 : 65;table.addTableColumn(column) }
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        }
        table.reloadData();let pending = merge?.unresolvedCount ?? 0
        start.isEnabled = !isPreparing && pending == 0;queue.isEnabled = start.isEnabled
        pageInfo.stringValue = filteredIndexes.isEmpty ? "Keine Einträge" : "\(previewPage*500+1)–\(previewPage*500+rows.count) von \(filteredIndexes.count)"
        let summary = merge.map { "\($0.conflictCount) Konflikte · \($0.unresolvedCount) offen · \($0.skippedCount) übersprungen" } ?? (packing ? "Neue Archivdatei" : "Neuer Zielordner")
        info.stringValue = "\(all.count) Einträge · \(bytes(prepared.totalBytes)) · "+summary+"\nZiel: "+prepared.destination.path
        info.textColor = pending > 0 ? .systemOrange : .labelColor;updateConflictButtons()
    }
    func focusConflict(backward:Bool) {
        guard let merge = prepared?.merge else { return }
        let open = merge.actions.indices.filter { merge.actions[$0].conflict && merge.actions[$0].decision == .pending }
        guard !open.isEmpty else { return }
        let current = visibleIndexes.indices.contains(table.selectedRow) ? visibleIndexes[table.selectedRow] : (backward ? Int.max : -1)
        let chosen = backward ? open.last(where:{$0 < current}) ?? open.last! : open.first(where:{$0 > current}) ?? open.first!
        if let position = filteredIndexes.firstIndex(of:chosen) { previewPage = position/500 } else { conflictsOnly.state = .off;previewPage = chosen/500 }
        updatePreview();guard let row = visibleIndexes.firstIndex(of:chosen) else { return }
        table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);table.scrollRowToVisible(row);window?.makeFirstResponder(table)
    }
    func openSelectedDecision() {
        guard table.selectedRow >= 0,let column = table.tableColumns.firstIndex(where:{$0.identifier.rawValue == "decision"}),let popup = table.view(atColumn:column,row:table.selectedRow,makeIfNecessary:true) as? NSPopUpButton else { focusConflict(backward:false);return }
        popup.performClick(nil)
    }
    func applyDecision(_ path:String,_ choice:ArchiveConflictDecision) throws {
        guard let merge = prepared?.merge else { throw CommanderError.message("Die Vorschau ist nicht mehr verfügbar.") }
        let selection = table.selectedRow >= 0 && visibleIndexes.indices.contains(table.selectedRow) ? visibleIndexes[table.selectedRow] : nil
        replacePrepared(.merge(try merge.resolving(path,with:choice)))
        if let selection,let row = visibleIndexes.firstIndex(of:selection) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false) }
    }
    @objc func conflictChosen(_ sender:NSPopUpButton) {
        guard let path = sender.identifier?.rawValue,let choice = sender.selectedItem?.representedObject as? String else { return }
        do {
            switch choice { case "pending":try applyDecision(path,.pending);case "skip":try applyDecision(path,.skip);case "replace":try applyDecision(path,.replace);case "both":try applyDecision(path,.keepBoth);case "rename":showRename(path);default:break }
        } catch { updatePreview();info.stringValue = error.localizedDescription;info.textColor = .systemOrange }
    }
    func showRename(_ path:String) {
        guard let merge = prepared?.merge,let action = merge.action(for:path),let parent = window else { return }
        let initial = ((action.alternatePath ?? action.member.path) as NSString).lastPathComponent
        let controller = ArchiveRenameController(original:(path as NSString).lastPathComponent,name:initial)
        controller.onSubmit = { [weak self] name in guard let self,self.prepared?.merge != nil else { throw CommanderError.message("Die Vorschau ist nicht mehr verfügbar.") };try self.applyDecision(path,.rename(name)) }
        controller.onClose = { [weak self] in self?.renameController = nil;self?.updatePreview() }
        renameController = controller;parent.beginSheet(controller.window!);controller.window?.makeFirstResponder(controller.name);controller.name.selectText(nil)
    }
    func archiveCell(column:String,row:Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil };let member = rows[row]
        func text(_ value:String,_ color:NSColor = .labelColor) -> NSTextField { let view = label(value,size:12,color:color);view.lineBreakMode = .byTruncatingMiddle;view.toolTip = value;return view }
        guard let merge = prepared?.merge,visibleIndexes.indices.contains(row) else { return text(column == "name" ? member.path : column == "kind" ? member.isDirectory ? "Ordner" : "Datei" : member.isDirectory ? "—" : bytes(member.size)) }
        let action = merge.actions[visibleIndexes[row]]
        switch column {
        case "name":return text(member.path,merge.isSkipped(action) ? .secondaryLabelColor : .labelColor)
        case "decision":
            guard action.conflict else { return text(merge.description(of:action),.secondaryLabelColor) }
            let popup = NSPopUpButton();popup.identifier = .init(member.path);popup.target = self;popup.action = #selector(conflictChosen)
            for (title,id) in [("Entscheiden …","pending"),("Überspringen","skip"),("Beide behalten","both"),("Umbenennen …","rename")] { popup.addItem(withTitle:title);popup.lastItem?.representedObject = id }
            if action.canReplace { popup.addItem(withTitle:"Überschreiben mit Sicherung");popup.lastItem?.representedObject = "replace" }
            let id:String;switch action.decision { case .pending:id = "pending";case .skip:id = "skip";case .replace:id = "replace";case .keepBoth:id = "both";case .rename:id = "rename" }
            popup.selectItem(at:popup.itemArray.firstIndex { $0.representedObject as? String == id } ?? 0)
            popup.setAccessibilityLabel("Konflikt: "+member.path);popup.toolTip = merge.description(of:action)+"\n⌘D öffnet die Entscheidung des ausgewählten Konflikts."
            return popup
        case "size":return text(member.isDirectory ? "—" : bytes(member.size))
        case "targetSize":
            guard let target = action.targetInfo else { return text("—") }
            switch target.kind { case .file:return text(bytes(target.bytes));case .directory:return text("Ordner");case .link:return text("Verknüpfung");case .other:return text("Spezialdatei") }
        case "sourceDate":return text(member.modified == .distantPast ? "—" : archiveDate.string(from:member.modified))
        case "targetDate":return text(action.targetInfo.map { archiveDate.string(from:$0.modified) } ?? "—")
        case "target":let value = text(merge.targetPath(for:action));value.toolTip = merge.destination.appendingPathComponent(merge.targetPath(for:action)).path;return value
        default:return nil
        }
    }
}

final class ArchiveRenameController:NSWindowController,NSWindowDelegate {
    let name:NSTextField,info = label("",size:12,color:.secondaryLabelColor)
    let apply = ActionButton("Namen übernehmen",action:{}),cancel = ActionButton("Abbrechen",action:{})
    var onSubmit:((String)throws->Void)?,onClose:(()->Void)?
    init(original:String,name:String) {
        self.name = input(name)
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:560,height:210),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.title = "Beim Entpacken umbenennen";w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self;let root = OperationContent(frame:w.contentView!.bounds);w.contentView = root
        let source = label(original,size:16,weight:.semibold);source.frame = NSRect(x:22,y:160,width:516,height:25);source.lineBreakMode = .byTruncatingMiddle;root.addSubview(source)
        self.name.frame = NSRect(x:22,y:115,width:516,height:28);self.name.setAccessibilityLabel("Neuer Name beim Entpacken");root.addSubview(self.name)
        info.frame = NSRect(x:22,y:58,width:516,height:47);info.maximumNumberOfLines = 2;info.lineBreakMode = .byWordWrapping;info.stringValue = "Nur der entpackte Name ändert sich. Eine Datei oder ein Ordner mit diesem Namen wird nicht ersetzt.";root.addSubview(info)
        cancel.perform = { [weak self] in self?.close() };cancel.keyEquivalent = "\u{1b}";cancel.keyEquivalentModifierMask = [];cancel.frame = NSRect(x:245,y:15,width:110,height:30);root.addSubview(cancel)
        apply.perform = { [weak self] in self?.submit() };apply.keyEquivalent = "\r";apply.keyEquivalentModifierMask = [];apply.frame = NSRect(x:363,y:15,width:175,height:30);root.addSubview(apply)
        w.workflowKeys = { [weak self] in if WorkflowKeys.matches($0,"\r",.command) { self?.submit();return true };return false };w.initialFirstResponder = self.name
    }
    required init?(coder:NSCoder) { fatalError() }
    func submit() { do { try onSubmit?(name.stringValue);close() } catch { info.stringValue = error.localizedDescription;info.textColor = .systemRed } }
    override func close() { if let w = window { w.sheetParent?.endSheet(w) };super.close() }
    func windowWillClose(_ notification:Notification) { onSubmit = nil;let action = onClose;onClose = nil;action?() }
}
