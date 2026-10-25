import AppKit
import CommanderCore

private final class ViewerSurface:CommanderSurface {
    var arrange:((NSSize)->Void)?
    override func layout() { super.layout();arrange?(bounds.size) }
}
final class ViewerScrollView:NSScrollView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();updateSurface() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();updateSurface() }
    private func updateSurface() { backgroundColor = CommanderPalette.current(in:self).activeList }
}

extension PreviewController {
    func buildInterface(_ window:WorkflowWindow) {
        let root = ViewerSurface(frame:window.contentView!.bounds);root.autoresizingMask = [.width,.height];window.contentView = root
        mode.selectedSegment = 0;mode.target = self;mode.action = #selector(previewModeChanged)
        encoding.addItems(withTitles:ViewerEncoding.allCases.map(\.title));encoding.target = self;encoding.action = #selector(encodingChanged)
        findMode.addItems(withTitles:["Text","Hex"]);findMode.target = self;findMode.action = #selector(searchKindChanged)
        find.delegate = self;find.target = self;find.action = #selector(findRequested);offset.target = self;offset.action = #selector(goRequested)
        sourceInfo.lineBreakMode = .byTruncatingMiddle;rangeInfo.lineBreakMode = .byTruncatingTail;status.lineBreakMode = .byTruncatingTail
        scroll.documentView = text;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.borderType = .bezelBorder
        text.isEditable = false;text.isRichText = false;text.isSelectable = true;text.isAutomaticLinkDetectionEnabled = false
        text.font = .monospacedSystemFont(ofSize:12,weight:.regular);text.textContainerInset = NSSize(width:12,height:12);text.updateColors()
        text.isHorizontallyResizable = true;text.isVerticallyResizable = true;text.autoresizingMask = [.width];text.minSize = .zero;text.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = text.maxSize;text.textContainer?.widthTracksTextView = false
        let offsetLabel = label("Byteoffset",size:12)
        [quick,scroll,mode,previousFile,nextFile,sourceInfo,previousPage,nextPage,offsetLabel,offset,go,encoding,findMode,find,previousMatch,nextMatch,wrap,cancel,reload,rangeInfo,status].forEach { root.addSubview($0) }
        previousFile.perform = { [weak self] in self?.changeFile(-1) };nextFile.perform = { [weak self] in self?.changeFile(1) }
        previousPage.perform = { [weak self] in self?.changePage(-1) };nextPage.perform = { [weak self] in self?.changePage(1) }
        go.perform = { [weak self] in self?.jump() };reload.perform = { [weak self] in self?.reloadFile() };cancel.perform = { [weak self] in self?.cancelWork() }
        previousMatch.perform = { [weak self] in self?.findMatch(backward:true) };nextMatch.perform = { [weak self] in self?.findMatch(backward:false) }
        previousFile.setHelp("Vorherige Datei","Die vorherige Datei der übergebenen sichtbaren Liste öffnen.",shortcut:"⌘⌥←")
        nextFile.setHelp("Nächste Datei","Die nächste Datei der übergebenen sichtbaren Liste öffnen.",shortcut:"⌘⌥→")
        previousPage.setHelp("Vorherige Seite","Den vorherigen begrenzten Byteausschnitt lesen.",shortcut:"⌘⌥↑")
        nextPage.setHelp("Nächste Seite","Den nächsten begrenzten Byteausschnitt lesen.",shortcut:"⌘⌥↓")
        previousMatch.setHelp("Vorheriger Treffer","Exakte Text- oder Bytefolge rückwärts suchen.",shortcut:"⌘⇧G / ⇧F3")
        nextMatch.setHelp("Nächster Treffer","Exakte Text- oder Bytefolge vorwärts suchen.",shortcut:"⌘G / F3")
        reload.setHelp("Neu laden","Eine geänderte Datei neu prüfen und die aktuelle Ansicht laden.",shortcut:"⌘R")
        cancel.setHelp("Abbrechen","Laufendes Lesen oder Suchen abbrechen.",shortcut:"Esc während der Arbeit")
        go.setHelp("Gehe zu Byteoffset","Dezimal oder 0x-Hexzahl; die erste Dateiposition ist 0.",shortcut:"⌘L, dann ↩")
        find.toolTip = "⌘F · Exakter Text in gewählter Kodierung oder Hexbytes (z. B. 48 65 6C 6C 6F). Ganze Datei, ausgenommen klar bezeichnete Dokument-/Strukturberichte."
        find.setAccessibilityLabel("Suchtext oder Hexbytes in der Vorschau");findMode.setAccessibilityLabel("Suchart der Vorschau")
        offset.toolTip = "⌘L · Byteoffset ab 0, dezimal oder als 0x…";offset.setAccessibilityLabel("Byteoffset der Vorschau")
        encoding.toolTip = "Textkodierung für Anzeige und exakte Textsuche. Automatisch erkennt UTF-8-/UTF-16-BOM, sonst UTF-8.";encoding.setAccessibilityLabel("Textkodierung der Vorschau")
        wrap.toolTip = "Nach Dateiende oder Dateianfang im übrigen Bereich weitersuchen. Die Bytefolge wird nicht über das Dateiende verbunden."
        mode.toolTip = "⌘1 Systemvorschau · ⌘2 Text · ⌘3 Hex · ⌘4 Binär · ⌘5 Dateistruktur"
        root.arrange = { [weak self] size in
            guard let self else { return };let w = size.width,h = size.height
            self.mode.frame = NSRect(x:16,y:h-48,width:530,height:28)
            self.previousFile.frame = NSRect(x:w-372,y:h-49,width:174,height:30);self.nextFile.frame = NSRect(x:w-190,y:h-49,width:174,height:30)
            self.sourceInfo.frame = NSRect(x:16,y:h-80,width:w-32,height:23)
            self.previousPage.frame = NSRect(x:16,y:h-120,width:145,height:30);self.nextPage.frame = NSRect(x:168,y:h-120,width:140,height:30)
            offsetLabel.frame = NSRect(x:320,y:h-117,width:78,height:23);self.offset.frame = NSRect(x:400,y:h-117,width:160,height:26);self.go.frame = NSRect(x:568,y:h-120,width:85,height:30)
            self.encoding.frame = NSRect(x:675,y:h-119,width:w-691,height:28)
            self.findMode.frame = NSRect(x:16,y:h-158,width:100,height:28);self.find.frame = NSRect(x:124,y:h-156,width:w-732,height:26)
            self.previousMatch.frame = NSRect(x:w-598,y:h-159,width:88,height:30);self.nextMatch.frame = NSRect(x:w-502,y:h-159,width:88,height:30)
            self.wrap.frame = NSRect(x:w-404,y:h-157,width:174,height:26);self.cancel.frame = NSRect(x:w-224,y:h-159,width:96,height:30);self.reload.frame = NSRect(x:w-120,y:h-159,width:104,height:30)
            self.rangeInfo.frame = NSRect(x:16,y:h-191,width:w-32,height:25)
            let content = NSRect(x:16,y:48,width:w-32,height:h-255);self.quick.frame = content;self.scroll.frame = content
            self.text.minSize = self.scroll.contentSize
            self.text.frame.size = NSSize(width:max(self.text.frame.width,self.scroll.contentSize.width),height:max(self.text.frame.height,self.scroll.contentSize.height))
            self.status.frame = NSRect(x:16,y:12,width:w-32,height:27)
        };root.needsLayout = true
    }
    @objc func findRequested() { findMatch(backward:false) }
    @objc func goRequested() { jump() }
    func configureKeys(_ window:WorkflowWindow) { window.workflowKeys = { [weak self] in self?.handleViewerKey($0) ?? false } }
    func handleViewerKey(_ event:NSEvent) -> Bool {
        guard !closed,NSApp.keyWindow === window,window?.attachedSheet == nil else { return false }
        if WorkflowKeys.matches(event,"w",.command) { close();return true }
        if WorkflowKeys.matches(event,"\u{1b}") { if isLoading || isSearching { cancelWork() } else { close() };return true }
        if WorkflowKeys.matches(event,"r",.command) { reloadFile();return true }
        if WorkflowKeys.matches(event,"f",.command) { if mode.selectedSegment == 0 { mode.selectedSegment = 1;previewModeChanged() };window?.makeFirstResponder(find);find.selectText(nil);return true }
        if WorkflowKeys.matches(event,"l",.command) { if offset.isEnabled { window?.makeFirstResponder(offset);offset.selectText(nil) };return true }
        if WorkflowKeys.matches(event,"g",.command) || WorkflowKeys.matches(event,String(UnicodeScalar(NSF3FunctionKey)!)) { findMatch(backward:false);return true }
        if WorkflowKeys.matches(event,"g",[.command,.shift]) || WorkflowKeys.matches(event,String(UnicodeScalar(NSF3FunctionKey)!),.shift) { findMatch(backward:true);return true }
        for (key,delta) in [(NSLeftArrowFunctionKey,-1),(NSRightArrowFunctionKey,1)] where WorkflowKeys.matches(event,String(UnicodeScalar(key)!),[.command,.option]) { changeFile(delta);return true }
        for (key,button,delta) in [(NSUpArrowFunctionKey,previousPage,-1),(NSDownArrowFunctionKey,nextPage,1)] where WorkflowKeys.matches(event,String(UnicodeScalar(key)!),[.command,.option]) { if button.isEnabled { changePage(delta) };return true }
        for number in 1...5 where WorkflowKeys.matches(event,String(number),.command) { mode.selectedSegment = number-1;previewModeChanged();return true }
        return false
    }
    func handleImportedKey(_ event:NSEvent) -> Bool {
        guard !closed,NSApp.keyWindow === window,window?.attachedSheet == nil else { return false }
        let editing = (window?.firstResponder as? NSTextView)?.isEditable == true || window?.firstResponder is NSTextField
        if editing { return handleViewerKey(event) }
        let bindings = Preferences.state.importedProfile?.viewerShortcuts ?? ["text":"t","hex":"h","binary":"b","preview":"i","close":"escape"]
        let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
        for (action,shortcut) in bindings {
            guard let parsed = AppDelegate.parseShortcut(shortcut),parsed.1 == flags,event.charactersIgnoringModifiers?.lowercased() == parsed.0 else { continue }
            switch action {
            case "close":close()
            case "text":mode.selectedSegment = 1;previewModeChanged()
            case "hex":mode.selectedSegment = 2;previewModeChanged()
            case "binary":mode.selectedSegment = 3;previewModeChanged()
            case "metadata":mode.selectedSegment = 4;previewModeChanged()
            case "preview","multimedia":mode.selectedSegment = 0;previewModeChanged()
            case "reload":reloadFile()
            default:return false
            }
            return true
        }
        return handleViewerKey(event)
    }
}
