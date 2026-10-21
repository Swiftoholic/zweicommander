import AppKit
import CommanderCore

final class InlineRenameEditor: NSView,NSTextFieldDelegate {
    let field = NSTextField()
    let message = AddressDropdown()
    private(set) var source: URL?
    private(set) var tabID: UUID?
    private(set) var sessionID = UUID()
    private(set) var snapshot: RenameItem?
    private(set) var isPreparing = false
    private(set) var isWorking = false
    private(set) var error: String?
    var onCommit: ((RenameItem)->Void)?
    var onClose: ((Bool)->Void)?
    private var commitWhenReady = false
    override init(frame:NSRect) {
        super.init(frame:frame);isHidden = true
        field.delegate = self;field.isEditable = true;field.isSelectable = true;field.isBordered = true;field.drawsBackground = true
        field.setAccessibilityLabel("Dateiname bearbeiten");field.toolTip = "Enter benennt um · Escape verwirft die Eingabe. Die Endung bleibt beim ersten Markieren ausgespart."
        addSubview(field)
    }
    required init?(coder:NSCoder) { fatalError() }
    var isEditing: Bool { source != nil && !isHidden }
    var hasPendingCommit: Bool { isEditing && (isWorking || commitWhenReady) }
    func begin(_ entry:FileEntry,tab:UUID,font:NSFont) {
        cancel(restoreFocus:false);sessionID = UUID();let request = sessionID
        source = entry.url;tabID = tab;isPreparing = true;isWorking = false;commitWhenReady = false;snapshot = nil;error = nil
        field.font = font;field.stringValue = entry.name;field.isEditable = true;field.textColor = .labelColor;field.setAccessibilityHelp(field.toolTip);isHidden = false
        (superview as? PaneView)?.positionInlineRename();needsLayout = true;layoutSubtreeIfNeeded();window?.makeFirstResponder(field)
        let stem = entry.isDirectory || entry.fileExtension.isEmpty ? entry.name : (entry.name as NSString).deletingPathExtension
        (field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location:0,length:(stem as NSString).length))
        DispatchQueue.main.async { [weak self] in
            guard let self,self.sessionID == request,self.field.stringValue == entry.name else { return }
            (self.field.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location:0,length:(stem as NSString).length))
        }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let item = RenameItem(source:entry.url,target:entry.url)
            DispatchQueue.main.async {
                guard let self,self.sessionID == request,self.isEditing else { return }
                self.snapshot = item;self.isPreparing = false
                if self.commitWhenReady { self.commit() }
            }
        }
    }
    func commit() {
        guard isEditing,!isWorking else { return }
        if isPreparing { commitWhenReady = true;message.show(under:field,title:"Datei wird geprüft …");return }
        do {
            guard let snapshot else { return }
            let item = try snapshot.renaming(to:field.stringValue)
            guard item.changed else { cancel(restoreFocus:true);return }
            message.close();error = nil;isWorking = true;field.isEditable = false;onCommit?(item)
        } catch { showError(error.localizedDescription) }
    }
    func completed(_ result:Result<Void,Error>) {
        guard isEditing else { return };isWorking = false;field.isEditable = true
        switch result { case .success: cancel(restoreFocus:true);case .failure(let error): showError(error.localizedDescription) }
    }
    private func showError(_ text:String) {
        error = text;field.textColor = .systemRed;field.setAccessibilityHelp(text);window?.makeFirstResponder(field)
        message.show(under:field,title:"Name prüfen",message:text,error:true)
    }
    func cancel(restoreFocus:Bool = false) {
        let wasEditing = isEditing;sessionID = UUID();source = nil;tabID = nil;isPreparing = false;isWorking = false;commitWhenReady = false;snapshot = nil;error = nil
        message.close();isHidden = true
        if wasEditing { onClose?(restoreFocus) }
    }
    override func layout() { super.layout();field.frame = bounds }
    func controlTextDidChange(_ obj:Notification) { error = nil;field.textColor = .labelColor;field.setAccessibilityHelp(field.toolTip);message.close();commitWhenReady = false }
    func controlTextDidEndEditing(_ obj:Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self,self.isEditing,!self.isWorking,self.field.currentEditor() == nil else { return };self.cancel()
        }
    }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { if !isWorking { cancel(restoreFocus:true) };return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { commit();return true }
        return false
    }
}

extension PaneView {
    func beginInlineRename() {
        guard !readOnly,canUseDisplayedEntries,selectedURLs.count == 1,let url = selectedURLs.first,
              let index = visibleEntries.firstIndex(where:{ $0.url == url }) else { NSSound.beep();return }
        if pathField.sessionActive { endPathEditing(restoreFocus:false) }
        activate()
        if displayMode == .icons { grid.scrollToItems(at:[IndexPath(item:index,section:0)],scrollPosition:.nearestHorizontalEdge) }
        else { table.scrollRowToVisible(index) }
        focusedEntryURL = url;inlineRename.begin(visibleEntries[index],tab:tab.id,font:listFont);positionInlineRename();redrawFileFocus()
    }
    func positionInlineRename() {
        guard inlineRename.isEditing,let source = inlineRename.source,inlineRename.tabID == tab.id,
              let index = visibleEntries.firstIndex(where:{ $0.url == source }) else { return }
        let rect:NSRect
        if displayMode == .icons,let attributes = grid.layoutAttributesForItem(at:IndexPath(item:index,section:0)) {
            rect = convert(NSRect(x:attributes.frame.minX+3,y:attributes.frame.maxY-35,width:attributes.frame.width-6,height:26),from:grid)
        } else {
            guard let column = table.tableColumns.firstIndex(where:{ $0.identifier.rawValue == "name" }) else { return }
            let cell = table.frameOfCell(atColumn:column,row:index),icon:CGFloat = thumbnails ? 47 : 23
            rect = convert(NSRect(x:cell.minX+icon,y:cell.midY-12,width:max(70,cell.width-icon-3),height:24),from:table)
        }
        let area = scroll.frame
        let x = max(area.minX,min(rect.minX,area.maxX-100))
        inlineRename.frame = NSRect(x:x,y:max(area.minY,min(rect.minY,area.maxY-24)),width:min(max(100,rect.width),max(1,area.maxX-x)),height:24)
        inlineRename.layoutSubtreeIfNeeded()
    }
}
