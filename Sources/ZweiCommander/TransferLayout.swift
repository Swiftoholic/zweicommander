import AppKit
import CommanderCore

final class TransferSurface: CommanderSurface {
    var arrange: ((NSSize)->Void)?
    override func layout() { super.layout();arrange?(bounds.size) }
}

extension TransferSetupController {
    func buildTransferInterface(_ window:NSWindow) {
        let root = TransferSurface(frame:window.contentView!.bounds);root.autoresizingMask = [.width,.height];window.contentView = root
        heading.stringValue = kind == .copy ? "Dateien kopieren" : "Dateien verschieben"
        [heading,sourceInfo,destinationCaption,destination,destinationChoose,policyCaption,policy,conflictInfo,conflictButton,optionsButton,optionsSummary,advancedScroll,selectionButton,objectsButton,refreshButton,tabs,info,safety,cancelButton,queueButton,startButton].forEach { root.addSubview($0) }
        destination.delegate = self;destination.target = self;destination.action = #selector(rebuild);destination.setAccessibilityLabel("Zielordner")
        destinationChoose.perform = { [weak self] in self?.chooseDestination() }
        policy.addItems(withTitles:["Abbrechen bei Konflikt","Überspringen","Beide behalten","Ersetzen mit Sicherung"]);policy.target = self;policy.action = #selector(rebuild);policy.setAccessibilityLabel("Regel bei Namenskonflikten")
        conflictButton.perform = { [weak self] in self?.showConflicts() };conflictButton.isHidden = true
        optionsButton.flat = true;optionsButton.perform = { [weak self] in self?.toggleOptions() };optionsButton.setAccessibilityLabel("Weitere Übertragungsoptionen einblenden")
        optionsButton.isHidden = false;optionsSummary.isHidden = false
        advancedScroll.documentView = advancedDocument;advancedScroll.hasVerticalScroller = true;advancedScroll.autohidesScrollers = false;advancedScroll.scrollerStyle = .legacy;advancedScroll.drawsBackground = false;advancedScroll.borderType = .lineBorder;advancedScroll.isHidden = true
        buildAdvancedOptions()
        table.delegate = self;table.dataSource = self;filesTable.delegate = self;filesTable.dataSource = self
        for column in filesTable.tableColumns where column.identifier.rawValue.hasSuffix("Date") { column.minWidth = 145 }
        tabs.tabViewType = .noTabsNoBorder;tabs.delegate = self
        for (id,title,table) in [("selection","Auswahl",table),("files","Geplante Objekte",filesTable)] {
            let item = NSTabViewItem(identifier:id);item.label = title
            let scroll = NSScrollView(frame:NSRect(x:0,y:0,width:796,height:200));scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.autohidesScrollers = true;scroll.borderType = .bezelBorder
            item.view = scroll;tabs.addTabViewItem(item)
        }
        for button in [selectionButton,objectsButton] { button.setButtonType(.pushOnPushOff) }
        selectionButton.perform = { [weak self] in self?.tabs.selectTabViewItem(at:0);self?.updateTabButtons() }
        objectsButton.perform = { [weak self] in self?.tabs.selectTabViewItem(at:1);self?.updateTabButtons() }
        updateTabButtons()
        refreshButton.perform = { [weak self] in self?.prepare() }
        cancelButton.perform = { [weak self] in self?.close() };cancelButton.keyEquivalent = "\u{1b}"
        queueButton.title = "Zur Warteschlange";queueButton.perform = { [weak self] in self?.submit(false) }
        startButton.title = kind == .copy ? "Kopieren" : "Verschieben";startButton.keyEquivalent = "\r";startButton.perform = { [weak self] in self?.submit(true) }
        safety.lineBreakMode = .byWordWrapping;safety.maximumNumberOfLines = 2
        root.arrange = { [weak self] in self?.layoutTransfer($0) };root.needsLayout = true
        updateRoute(sources)
    }
    private func buildAdvancedOptions() {
        profilePopup.target = self;profilePopup.action = #selector(chooseProfile)
        profileSave.perform = { [weak self] in self?.saveProfile() };profileSaveAs.perform = { [weak self] in self?.saveProfileAs() };profileRemove.perform = { [weak self] in self?.removeProfile() }
        resetButton.perform = { [weak self] in self?.resetFilters() };criteriaButton.perform = { [weak self] in self?.showCriteria() }
        let profileCaption = label("Profil",weight:.medium);profileCaption.identifier = .init("profileCaption")
        [profileCaption,profilePopup,profileSave,profileSaveAs,profileRemove,profileStatus,include,exclude,excludedFolders,recursive,keepEmpty,structureOnly,regex,mergeFolders,criteriaButton,criteriaInfo,resetButton].forEach { advancedDocument.addSubview($0) }
        for (id,title) in [("includeCaption","Einschließen"),("excludeCaption","Ausschließen"),("foldersCaption","Ordner auslassen")] {
            let caption = label(title,weight:.medium);caption.identifier = .init(id);advancedDocument.addSubview(caption)
        }
        for field in [include,exclude,excludedFolders] { field.delegate = self;field.target = self;field.action = #selector(rebuild) }
        include.setAccessibilityLabel("Dateien einschließen");exclude.setAccessibilityLabel("Dateien ausschließen");excludedFolders.setAccessibilityLabel("Unterordner auslassen")
        include.toolTip = "Dateinamen mit * und ? filtern; mehrere Muster mit ; trennen.";exclude.toolTip = include.toolTip;excludedFolders.toolTip = "Ordnernamen mit Wildcards; z. B. .git;node_modules;Cache*"
        for button in [recursive,keepEmpty,structureOnly,regex,mergeFolders] { button.target = self;button.action = #selector(filterOptionChanged) }
    }
    func layoutTransfer(_ size:NSSize) {
        let w = size.width,h = size.height,pad: CGFloat = 22,width = w-2*pad
        let expanded = optionsExpanded
        heading.frame = NSRect(x:pad,y:h-(expanded ? 44 : 50),width:width,height:28)
        sourceInfo.frame = NSRect(x:pad,y:h-(expanded ? 71 : 79),width:width,height:22)
        destinationCaption.frame = NSRect(x:pad,y:h-(expanded ? 105 : 116),width:50,height:26)
        destination.frame = NSRect(x:pad+56,y:h-(expanded ? 105 : 116),width:width-178,height:26)
        destinationChoose.frame = NSRect(x:w-pad-112,y:h-(expanded ? 106 : 117),width:112,height:28)
        policyCaption.frame = NSRect(x:pad,y:h-(expanded ? 139 : 152),width:150,height:26)
        policy.frame = NSRect(x:pad+156,y:h-(expanded ? 139 : 152),width:min(310,width-156),height:28)
        conflictInfo.frame = NSRect(x:pad,y:h-(expanded ? 166 : 180),width:width-145,height:23)
        conflictButton.frame = NSRect(x:w-pad-139,y:h-(expanded ? 166 : 180),width:139,height:26)
        optionsButton.frame = NSRect(x:pad,y:h-(expanded ? 196 : 215),width:156,height:28)
        optionsSummary.frame = NSRect(x:pad+164,y:h-(expanded ? 193 : 212),width:width-164,height:22)
        let advancedHeight: CGFloat = expanded ? min(270,max(110,(h-342)*0.58)) : 0
        advancedScroll.frame = NSRect(x:pad,y:h-201-advancedHeight,width:width,height:advancedHeight)
        layoutAdvanced(width:width-18)
        let header = h-(expanded ? 233 : 252)-advancedHeight
        let previewBottom: CGFloat = expanded ? 104 : 137
        selectionButton.frame = NSRect(x:pad,y:header,width:115,height:28)
        objectsButton.frame = NSRect(x:pad+123,y:header,width:180,height:28)
        refreshButton.frame = NSRect(x:w-pad-130,y:header,width:130,height:28)
        tabs.frame = NSRect(x:pad,y:previewBottom,width:width,height:max(75,header-previewBottom-5))
        info.frame = NSRect(x:pad,y:expanded ? 80 : 105,width:width,height:24)
        safety.frame = NSRect(x:pad,y:expanded ? 49 : 59,width:width,height:expanded ? 27 : 40)
        cancelButton.frame = NSRect(x:pad,y:18,width:112,height:30)
        queueButton.frame = NSRect(x:w-pad-335,y:18,width:185,height:30)
        startButton.frame = NSRect(x:w-pad-140,y:18,width:140,height:30)
    }
    private func layoutAdvanced(width:CGFloat) {
        advancedDocument.frame = NSRect(x:0,y:0,width:max(1,width),height:270)
        func place(_ view:NSView,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat = 26) { view.frame = NSRect(x:x,y:y,width:max(1,w),height:h) }
        func caption(_ id:String,_ y:CGFloat) { if let view = advancedDocument.subviews.first(where: { $0.identifier?.rawValue == id }) { place(view,10,y,116) } }
        caption("profileCaption",234);place(profilePopup,130,234,210,28);place(profileSave,346,234,84,28);place(profileSaveAs,436,234,132,28);place(profileRemove,574,234,90,28)
        place(profileStatus,130,211,width-140,20)
        for (id,field,y) in [("includeCaption",include,178.0),("excludeCaption",exclude,144.0),("foldersCaption",excludedFolders,110.0)] { caption(id,y);place(field,130,y,width-140) }
        place(recursive,10,76,223);place(keepEmpty,248,76,245)
        place(structureOnly,10,44,165);place(regex,182,44,186);place(mergeFolders,380,44,245)
        place(criteriaButton,10,7,162,28);place(criteriaInfo,180,9,width-365,24);place(resetButton,width-178,7,168,28)
    }
    func toggleOptions() {
        window?.endEditing(for:nil)
        optionsExpanded.toggle();advancedScroll.isHidden = !optionsExpanded
        optionsButton.image = NSImage(systemSymbolName:optionsExpanded ? "chevron.down" : "chevron.right",accessibilityDescription:nil)
        optionsButton.setAccessibilityLabel(optionsExpanded ? "Weitere Übertragungsoptionen ausblenden" : "Weitere Übertragungsoptionen einblenden")
        if let window {
            let old = window.frame,desired = old.height+(optionsExpanded ? 250 : -250),limit = window.screen?.visibleFrame ?? old
            let height = min(limit.height,max(window.minSize.height,desired))
            window.setFrame(NSRect(x:old.minX,y:max(limit.minY,old.maxY-height),width:old.width,height:height),display:true)
            window.contentView?.needsLayout = true;window.contentView?.layoutSubtreeIfNeeded()
            if optionsExpanded { advancedDocument.scroll(NSPoint(x:0,y:advancedDocument.bounds.height)) }
        }
    }
    func updateRoute(_ chosen:[URL]) {
        guard !chosen.isEmpty else { sourceInfo.stringValue = "Keine Objekte ausgewählt";sourceInfo.toolTip = nil;return }
        let parents = Set(chosen.map { $0.deletingLastPathComponent().path })
        let origin = parents.count == 1 ? chosen.first!.deletingLastPathComponent().lastPathComponent : "\(parents.count) Ordnern"
        sourceInfo.stringValue = "\(chosen.count) \(chosen.count == 1 ? "Objekt" : "Objekte") aus \(origin)"
        sourceInfo.toolTip = chosen.prefix(12).map(\.path).joined(separator:"\n")
    }
    func updateOptionsSummary() {
        var parts: [String] = []
        if selectedProfileID != nil { parts.append(profilePopup.titleOfSelectedItem ?? "Profil aktiv") }
        if filter.isActive { parts.append("Filter aktiv") }
        if mergeFolders.state == .on { parts.append("Ordner zusammenführen") }
        optionsSummary.stringValue = parts.isEmpty ? "Profile, Dateifilter und Ordnerregeln" : parts.joined(separator:" · ")
        optionsSummary.textColor = parts.isEmpty ? .secondaryLabelColor : .labelColor;optionsSummary.toolTip = optionsSummary.stringValue
    }
    func showConflicts() {
        if plan?.merge != nil {
            tabs.selectTabViewItem(at:1)
            if let row = (0..<previewCount).first(where: { index in guard let source = previewObject(at:index)?.source else { return false };return plan?.merge?.action(for:source)?.conflict == true }) { filesTable.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);filesTable.scrollRowToVisible(row) }
        } else {
            tabs.selectTabViewItem(at:0)
            if let row = plan?.entries.firstIndex(where: { $0.conflict && !excluded.contains($0.source) }) { table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);table.scrollRowToVisible(row) }
        }
        updateTabButtons()
    }
}
