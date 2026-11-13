import AppKit
import CommanderCore

final class ExternalToolsController:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate,NSTextViewDelegate {
    private(set) var snapshot:ExternalToolsSnapshot,library:ExternalToolLibrary
    let context:ExternalToolContext?
    let table = CommanderTableView(),titleField = input(),categoryField = input(),targetField = input(),directoryField = input("{active}"),timeoutField = input("300")
    let kind = NSPopUpButton(),slot = NSPopUpButton(),arguments = CommanderTextView()
    let enabled = checkbox("Aktiviert",on:true),perSelection = checkbox("Ein Aufruf je markiertem Objekt"),opensSelection = checkbox("Ausgewählte Dateien als Dokumente öffnen"),toolbar = checkbox("In der Werkzeugleiste anzeigen")
    let add = ActionButton("Neu",symbol:"plus",action:{}),remove = ActionButton("Entfernen",symbol:"minus",action:{}),up = ActionButton("Nach oben",symbol:"arrow.up",action:{}),down = ActionButton("Nach unten",symbol:"arrow.down",action:{})
    let save = ActionButton("Speichern",action:{}),preview = ActionButton("Aufruf prüfen …",symbol:"eye",action:{}),reload = ActionButton("Neu laden",symbol:"arrow.clockwise",action:{})
    let status = label("",size:12),selectionInfo = label("",size:11,color:.secondaryLabelColor)
    var onApply:((ExternalToolLibrary,ExternalToolsSnapshot)throws->ExternalToolsSnapshot)?
    var onPreview:((ExternalTool,ExternalToolContext)->Void)?
    var confirmDiscard:(()->Bool)?
    private var editingID:UUID?,isLoading = false,isSelecting = false,dirtyEditor = false
    init(snapshot:ExternalToolsSnapshot,context:ExternalToolContext?) {
        self.snapshot = snapshot;library = snapshot.library;self.context = context
        let window = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:1120,height:780),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "Eigene Werkzeuge";window.minSize = NSSize(width:1000,height:700);window.isReleasedWhenClosed = false
        super.init(window:window);window.delegate = self
        let root = OperationContent(frame:window.contentView!.bounds);root.autoresizingMask = [.width,.height];window.contentView = root
        let heading = label("Eigene Werkzeuge",size:21,weight:.semibold);heading.frame = NSRect(x:22,y:730,width:800,height:32);heading.autoresizingMask = [.minYMargin];root.addSubview(heading)
        let hint = label("Programme und Apps mit getrennten Argumenten konfigurieren. Vor jedem Start den tatsächlichen Aufruf prüfen.",size:12)
        hint.frame = NSRect(x:22,y:700,width:1076,height:24);hint.autoresizingMask = [.width,.minYMargin];root.addSubview(hint)
        for (id,title,width) in [("title","Werkzeug",CGFloat(180)),("category","Kategorie",90)] { let column = NSTableColumn(identifier:.init(id));column.title = title;column.width = width;table.addTableColumn(column) }
        table.delegate = self;table.dataSource = self;table.rowHeight = 29;table.allowsEmptySelection = true;table.usesAlternatingRowBackgroundColors = true
        let list = operationScroll(table);list.frame = NSRect(x:22,y:150,width:280,height:530);list.autoresizingMask = [.height];root.addSubview(list)
        add.frame = NSRect(x:22,y:110,width:90,height:29);remove.frame = NSRect(x:120,y:110,width:182,height:29)
        up.frame = NSRect(x:22,y:72,width:136,height:29);down.frame = NSRect(x:166,y:72,width:136,height:29)
        add.perform = { [weak self] in self?.addTool() };remove.perform = { [weak self] in self?.removeTool() };up.perform = { [weak self] in self?.move(-1) };down.perform = { [weak self] in self?.move(1) }
        [add,remove,up,down].forEach { root.addSubview($0) }
        let editorScroll = NSScrollView(frame:NSRect(x:326,y:150,width:772,height:530));editorScroll.autoresizingMask = [.width,.height];editorScroll.hasVerticalScroller = true;editorScroll.borderType = .bezelBorder
        let document = CommanderSurface(frame:NSRect(x:0,y:0,width:750,height:680));document.autoresizingMask = [.width];editorScroll.documentView = document;root.addSubview(editorScroll)
        editorScroll.contentView.scroll(to:NSPoint(x:0,y:max(0,document.bounds.height-editorScroll.contentSize.height)));editorScroll.reflectScrolledClipView(editorScroll.contentView)
        func field(_ title:String,_ view:NSView,_ y:CGFloat,_ height:CGFloat = 28) { let caption = label(title);caption.frame = NSRect(x:14,y:y+4,width:150,height:22);document.addSubview(caption);view.frame = NSRect(x:166,y:y,width:566,height:height);view.autoresizingMask = [.width];document.addSubview(view) }
        field("Name",titleField,636);field("Kategorie",categoryField,596);kind.addItems(withTitles:["Programmdatei","macOS-App (.app)"]);field("Startart",kind,556)
        targetField.frame = NSRect(x:166,y:516,width:426,height:28);targetField.autoresizingMask = [.width];document.addSubview(targetField)
        let targetCaption = label("Programm / App");targetCaption.frame = NSRect(x:14,y:520,width:150,height:22);document.addSubview(targetCaption)
        let choose = ActionButton("Wählen …",symbol:"folder",action:{ [weak self] in self?.chooseTarget() });choose.frame = NSRect(x:602,y:516,width:130,height:28);choose.autoresizingMask = [.minXMargin];document.addSubview(choose)
        let argumentScroll = NSScrollView();argumentScroll.hasVerticalScroller = true;argumentScroll.borderType = .bezelBorder;arguments.isRichText = false;arguments.isEditable = true;arguments.font = .monospacedSystemFont(ofSize:12,weight:.regular);arguments.delegate = self;arguments.textContainerInset = NSSize(width:6,height:6);argumentScroll.documentView = arguments;field("Argumente",argumentScroll,336,166)
        let argumentHint = label("Eine Zeile je Argument. \\n = Zeilenumbruch, \\\\ = Backslash, \\e = leeres Argument. Anführungszeichen bleiben erhalten.",size:11,color:.secondaryLabelColor);argumentHint.frame = NSRect(x:166,y:285,width:566,height:44);argumentHint.maximumNumberOfLines = 3;argumentHint.lineBreakMode = .byWordWrapping;argumentHint.cell?.usesSingleLineMode = false;argumentHint.autoresizingMask = [.width];document.addSubview(argumentHint)
        arguments.frame = argumentScroll.contentView.bounds;arguments.autoresizingMask = [.width]
        field("Arbeitsordner",directoryField,248);field("Zeitlimit (Sekunden)",timeoutField,208);slot.addItems(withTitles:["Kein Kürzelplatz"]+(1...9).map { "Werkzeugplatz \($0)" });field("Tastenkürzel",slot,168)
        enabled.frame = NSRect(x:166,y:126,width:150,height:26);toolbar.frame = NSRect(x:326,y:126,width:400,height:26);perSelection.frame = NSRect(x:166,y:88,width:540,height:26);opensSelection.frame = NSRect(x:166,y:50,width:540,height:26)
        [enabled,toolbar,perSelection,opensSelection].forEach { document.addSubview($0);$0.target = self;$0.action = #selector(controlChanged) }
        kind.target = self;kind.action = #selector(kindChanged);slot.target = self;slot.action = #selector(controlChanged)
        for field in [titleField,categoryField,targetField,directoryField,timeoutField] { field.delegate = self }
        arguments.toolTip = "{active}, {inactive}, {focused}, {file}, {name}, {stem}, {ext}. {selection} und {names} stehen jeweils allein in einer Argumentzeile. {{ und }} erzeugen geschweifte Klammern. Keine automatische Shell-Auswertung."
        directoryField.toolTip = "Vollständiger Ordner oder Platzhalter, z. B. {active} oder {inactive}. Bei macOS-Apps verwaltet das System den Arbeitsordner."
        targetField.toolTip = "Eine lokale ausführbare Datei oder eine macOS-App ausdrücklich auswählen."
        status.frame = NSRect(x:326,y:104,width:772,height:36);status.autoresizingMask = [.width];status.maximumNumberOfLines = 2;status.lineBreakMode = .byWordWrapping;status.cell?.usesSingleLineMode = false;root.addSubview(status)
        selectionInfo.stringValue = context.map { "Vorschau verwendet die beim Öffnen erfasste lokale Auswahl: \($0.selection.count) Objekt(e)." } ?? "Für eine Aufrufvorschau zuerst einen lokalen Ordnertab aktivieren und das Werkzeugfenster neu öffnen."
        selectionInfo.frame = NSRect(x:326,y:64,width:772,height:32);selectionInfo.autoresizingMask = [.width];root.addSubview(selectionInfo)
        reload.frame = NSRect(x:22,y:20,width:140,height:29);reload.perform = { [weak self] in self?.reloadLibrary() }
        preview.frame = NSRect(x:640,y:20,width:175,height:29);preview.autoresizingMask = [.minXMargin];preview.perform = { [weak self] in self?.previewTool() }
        save.frame = NSRect(x:825,y:20,width:130,height:29);save.autoresizingMask = [.minXMargin];save.perform = { [weak self] in self?.saveLibrary() }
        let close = ActionButton("Schließen",action:{ [weak self] in self?.window?.performClose(nil) });close.frame = NSRect(x:965,y:20,width:133,height:29);close.autoresizingMask = [.minXMargin]
        [reload,preview,save,close].forEach { root.addSubview($0) }
        save.setHelp("Speichern","Alle Werkzeugdefinitionen lokal speichern. Kein Programm wird gestartet.",shortcut:"⌘S");preview.setHelp("Aufruf prüfen","Die aktuellen Argumente mit der eingefrorenen Auswahl prüfen; Start erfolgt erst im Vorschaufenster.",shortcut:"⌘↩");reload.setHelp("Neu laden","Gespeicherte Werkzeugliste erneut lesen.",shortcut:"⌘R")
        add.setHelp("Neu","Eine eigene Werkzeugdefinition anlegen.",shortcut:"⌘N");remove.setHelp("Entfernen","Nur die Definition entfernen. Die Programmdatei bleibt erhalten.")
        window.workflowKeys = { [weak self] event in guard let self else { return false };if WorkflowKeys.matches(event,"s",.command) { self.saveLibrary();return true };if WorkflowKeys.matches(event,"n",.command) { self.addTool();return true };if WorkflowKeys.matches(event,"r",.command) { self.reloadLibrary();return true };if WorkflowKeys.matches(event,"\r",.command) { self.previewTool();return true };if event.keyCode == 53 { self.window?.performClose(nil);return true };return false }
        if !library.tools.isEmpty { table.selectRowIndexes([0],byExtendingSelection:false) } else { loadEditor(nil) };window.center()
    }
    required init?(coder:NSCoder) { fatalError() }
    var hasChanges:Bool { dirtyEditor || library != snapshot.library }
    @objc private func controlChanged() { guard !isLoading else { return };dirtyEditor = true;status.stringValue = "Ungespeicherte Änderungen";status.textColor = .secondaryLabelColor }
    @objc private func kindChanged() { if kind.indexOfSelectedItem == 1 { directoryField.stringValue = "{active}" } else { opensSelection.state = .off };directoryField.isEnabled = kind.indexOfSelectedItem == 0;opensSelection.isEnabled = kind.indexOfSelectedItem == 1;controlChanged() }
    func controlTextDidChange(_ notification:Notification) { controlChanged() }
    func textDidChange(_ notification:Notification) { controlChanged() }
    private func loadEditor(_ tool:ExternalTool?) {
        isLoading = true;defer { isLoading = false };editingID = tool?.id;titleField.stringValue = tool?.title ?? "";categoryField.stringValue = tool?.category ?? "";targetField.stringValue = tool?.target ?? "";arguments.string = ExternalToolArgumentLines.encode(tool?.arguments ?? []);directoryField.stringValue = tool?.workingDirectory ?? "{active}";timeoutField.stringValue = String(tool?.timeoutSeconds ?? 300);kind.selectItem(at:tool?.kind == .application ? 1 : 0);slot.selectItem(at:tool?.shortcutSlot ?? 0);enabled.state = tool?.enabled == false ? .off : .on;perSelection.state = tool?.perSelection == true ? .on : .off;opensSelection.state = tool?.opensSelection == true ? .on : .off;toolbar.state = tool?.showInToolbar == true ? .on : .off
        for field in [titleField,categoryField,targetField,directoryField,timeoutField] { field.isEnabled = tool != nil };arguments.isEditable = tool != nil;kind.isEnabled = tool != nil;slot.isEnabled = tool != nil
        for button in [enabled,perSelection,opensSelection,toolbar] { button.isEnabled = tool != nil };directoryField.isEnabled = tool != nil && tool?.kind != .application;opensSelection.isEnabled = tool?.kind == .application
        dirtyEditor = false;updateButtons()
    }
    func draft() throws -> ExternalTool {
        guard let id = editingID,let seconds = Int(timeoutField.stringValue) else { throw CommanderError.message("Ein Werkzeug auswählen und ein ganzzahliges Zeitlimit angeben.") }
        let tool = ExternalTool(id:id,title:titleField.stringValue,category:categoryField.stringValue,kind:kind.indexOfSelectedItem == 1 ? .application : .executable,target:targetField.stringValue,arguments:try ExternalToolArgumentLines.decode(arguments.string),workingDirectory:directoryField.stringValue,perSelection:perSelection.state == .on,opensSelection:opensSelection.state == .on,showInToolbar:toolbar.state == .on,shortcutSlot:slot.indexOfSelectedItem == 0 ? nil : slot.indexOfSelectedItem,enabled:enabled.state == .on,timeoutSeconds:seconds)
        try tool.validate();return tool
    }
    private func stageEditor() throws { if editingID != nil { try library.put(draft());dirtyEditor = false } }
    private func fail(_ error:Error) { status.stringValue = error.localizedDescription;status.toolTip = status.stringValue;status.textColor = .systemOrange }
    func addTool() { do { try stageEditor();guard library.tools.count < 100 else { throw CommanderError.message("Höchstens 100 Werkzeuge sind möglich.") };let tool = ExternalTool(title:"Neues Werkzeug",target:"");library.tools.append(tool);table.reloadData();table.selectRowIndexes([library.tools.count-1],byExtendingSelection:false);loadEditor(tool);window?.makeFirstResponder(titleField);titleField.selectText(nil) } catch { fail(error) } }
    func removeTool() { guard let id = editingID else { return };let previous = table.selectedRow;library.tools.removeAll { $0.id == id };editingID = nil;dirtyEditor = false;table.reloadData();if library.tools.isEmpty { loadEditor(nil) } else { let index = min(max(0,previous),library.tools.count-1);table.selectRowIndexes([index],byExtendingSelection:false);loadEditor(library.tools[index]) };status.stringValue = "Definition entfernt · noch nicht gespeichert" }
    func move(_ offset:Int) { do { try stageEditor();guard let id = editingID else { return };library.move(id,by:offset);table.reloadData();if let index = library.tools.firstIndex(where:{ $0.id == id }) { table.selectRowIndexes([index],byExtendingSelection:false) };updateButtons() } catch { fail(error) } }
    func saveLibrary() { do { try stageEditor();try library.validate();guard let onApply else { throw CommanderError.message("Speichern ist nicht verbunden.") };snapshot = try onApply(library,snapshot);status.stringValue = "\(library.tools.count) Werkzeuge lokal gespeichert";status.textColor = .secondaryLabelColor;table.reloadData() } catch { fail(error) } }
    func reloadLibrary() { guard canDiscard() else { return };do { snapshot = try Preferences.externalToolsSnapshot();library = snapshot.library;editingID = nil;dirtyEditor = false;table.reloadData();if library.tools.isEmpty { loadEditor(nil) } else { table.selectRowIndexes([0],byExtendingSelection:false);loadEditor(library.tools[0]) };status.stringValue = "Gespeicherte Werkzeuge neu geladen" } catch { fail(error) } }
    func previewTool() { do { guard let context else { throw CommanderError.message("Das Fenster für eine Vorschau aus einem aktiven lokalen Ordnertab öffnen.") };let tool = try draft();onPreview?(tool,context) } catch { fail(error) } }
    private func chooseTarget() { let panel = NSOpenPanel();panel.canChooseDirectories = false;panel.canChooseFiles = true;panel.treatsFilePackagesAsDirectories = false;panel.resolvesAliases = true;panel.message = "Eine Programmdatei oder macOS-App auswählen. Es wird noch nichts gestartet.";guard panel.runModal() == .OK,let url = panel.url else { return };let target = url.resolvingSymlinksInPath();targetField.stringValue = target.path;kind.selectItem(at:target.pathExtension.lowercased() == "app" ? 1 : 0);kindChanged() }
    private func updateButtons() { let index = table.selectedRow;remove.isEnabled = editingID != nil;up.isEnabled = index > 0;down.isEnabled = index >= 0 && index < library.tools.count-1;preview.isEnabled = editingID != nil && context != nil;save.isEnabled = !library.tools.isEmpty || snapshot.library.tools != [] }
    private func canDiscard() -> Bool { !hasChanges || (confirmDiscard?() ?? (dialog("Ungespeicherte Werkzeugänderungen verwerfen?",buttons:["Verwerfen","Abbrechen"]) == 0)) }
    func windowShouldClose(_ sender:NSWindow) -> Bool { canDiscard() }
    func numberOfRows(in tableView:NSTableView) -> Int { library.tools.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? { guard library.tools.indices.contains(row) else { return nil };let tool = library.tools[row],field = label(column?.identifier.rawValue == "category" ? tool.category : tool.title,color:tool.enabled ? .labelColor : .secondaryLabelColor);field.toolTip = tool.target;return field }
    func tableViewSelectionDidChange(_ notification:Notification) { guard !isSelecting else { return };let next = library.tools.indices.contains(table.selectedRow) ? library.tools[table.selectedRow] : nil;guard next?.id != editingID else { updateButtons();return };do { try stageEditor();loadEditor(next) } catch { isSelecting = true;if let id = editingID,let old = library.tools.firstIndex(where:{ $0.id == id }) { table.selectRowIndexes([old],byExtendingSelection:false) };isSelecting = false;fail(error) } }
}
