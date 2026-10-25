import AppKit
import CommanderCore

private final class FileDiffSurface:CommanderSurface {
    var arrange:((NSSize)->Void)?
    override func layout() { super.layout();arrange?(bounds.size) }
}

final class FileDiffController:NSWindowController,NSWindowDelegate,NSTextFieldDelegate,NSTableViewDataSource,NSTableViewDelegate {
    let leftPath = input(),rightPath = input(),chooseLeft = ActionButton("Wählen …",symbol:"doc",action:{}),chooseRight = ActionButton("Wählen …",symbol:"doc",action:{})
    let mode = NSPopUpButton(),encoding = NSPopUpButton(),ignoreCase = checkbox("Groß-/Kleinschreibung ignorieren"),ignoreWhitespace = checkbox("Leerraum ignorieren"),ignoreEndings = checkbox("Zeilenenden ignorieren",on:true)
    let refresh = ActionButton("Vergleichen",symbol:"arrow.left.arrow.right",action:{}),stop = ActionButton("Abbrechen",action:{}),swap = ActionButton("Tauschen",symbol:"arrow.triangle.swap",action:{})
    let previous = ActionButton("Vorheriger Unterschied",symbol:"arrow.up",action:{}),next = ActionButton("Nächster Unterschied",symbol:"arrow.down",action:{}),differencesOnly = checkbox("Nur Unterschiede")
    let table = operationTable([("kind","Ergebnis",78),("leftPosition","Links",65),("left","Linker Inhalt",430),("rightPosition","Rechts",65),("right","Rechter Inhalt",430)])
    let info = label("",size:12),position = label("",size:11,color:.secondaryLabelColor),safety = label("Schreibgeschützter Vergleich · Bis 16 MiB und 100.000 Textzeilen je Datei · Begrenztes Rechenbudget",size:11,color:.secondaryLabelColor)
    let leftText = CommanderTextView(),rightText = CommanderTextView(),leftDetail = label("Links",weight:.medium),rightDetail = label("Rechts",weight:.medium)
    private(set) var result:FileDiffResult?,visibleRows:[FileDiffRow] = [],isComparing = false
    private var token = CancellationToken(),generation = UUID(),closed = false
    private let worker = DispatchQueue(label:"local.zweicommander.file-diff",qos:.userInitiated)
    var onFinished:(()->Void)?
    init(left:URL,right:URL) {
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:1180,height:800),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title = "Dateien vergleichen";w.minSize = NSSize(width:1050,height:710);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        leftPath.stringValue = left.path;rightPath.stringValue = right.path
        mode.addItems(withTitles:FileDiffMode.allCases.map(\.title));encoding.addItems(withTitles:FileDiffEncoding.allCases.map(\.title))
        let surface = FileDiffSurface(frame:w.contentView!.bounds);surface.autoresizingMask = [.width,.height];w.contentView = surface
        let heading = label("Dateivergleich",size:22,weight:.semibold),leftCaption = label("Links",weight:.medium),rightCaption = label("Rechts",weight:.medium),modeCaption = label("Modus"),encodingCaption = label("Kodierung")
        let readOnly = label("Dateiinhalte bleiben unverändert",size:11,color:.secondaryLabelColor)
        let scroll = operationScroll(table),leftScroll = detailScroll(leftText),rightScroll = detailScroll(rightText)
        [heading,leftCaption,rightCaption,modeCaption,encodingCaption,readOnly,leftPath,rightPath,chooseLeft,chooseRight,mode,encoding,ignoreCase,ignoreWhitespace,ignoreEndings,refresh,stop,swap,previous,next,differencesOnly,position,scroll,leftDetail,rightDetail,leftScroll,rightScroll,info,safety].forEach { surface.addSubview($0) }
        table.dataSource = self;table.delegate = self;table.rowHeight = 28;table.intercellSpacing = NSSize(width:4,height:0);table.setAccessibilityLabel("Dateivergleich mit Zeilen oder Bytepositionen")
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (column,width) in zip(table.tableColumns,[CGFloat(78),65,430,65,430]) { column.width = width }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        leftPath.delegate = self;rightPath.delegate = self
        leftPath.setAccessibilityLabel("Linke Vergleichsdatei");rightPath.setAccessibilityLabel("Rechte Vergleichsdatei")
        mode.setAccessibilityLabel("Dateivergleichsmodus");encoding.setAccessibilityLabel("Textkodierung für beide Vergleichsdateien")
        leftPath.toolTip = "⌘L · Vollständiger lokaler Pfad einer regulären Datei";rightPath.toolTip = "⌘⇧L · Rechte Vergleichsdatei bearbeiten"
        mode.toolTip = "Automatisch verwendet gültigen UTF-8-/UTF-16-Text, sonst einen Binärvergleich nach Byteposition. Eine gewählte Textkodierung gilt für beide Seiten."
        encoding.toolTip = "Explizite Kodierung für beide Dateien. Automatisch erkennt UTF-8 sowie UTF-16 mit Byte Order Mark."
        ignoreWhitespace.toolTip = "Alle Leerraumzeichen innerhalb der Zeilen beim Vergleich auslassen. Originaltext bleibt sichtbar."
        ignoreEndings.toolTip = "LF, CRLF, CR und einen fehlenden letzten Zeilenumbruch beim Zeilenvergleich gleich behandeln."
        differencesOnly.toolTip = "Gleiche Zeilen oder Bytebereiche ausblenden; das vollständige Ergebnis bleibt erhalten."
        chooseLeft.perform = { [weak self] in self?.choose(true) };chooseRight.perform = { [weak self] in self?.choose(false) }
        refresh.perform = { [weak self] in self?.beginCompare() };stop.perform = { [weak self] in self?.cancel() };swap.perform = { [weak self] in self?.swapFiles() }
        previous.perform = { [weak self] in self?.jump(backward:true) };next.perform = { [weak self] in self?.jump(backward:false) }
        for control:NSControl in [mode,encoding,ignoreCase,ignoreWhitespace,ignoreEndings] { control.target = self;control.action = #selector(optionsChanged) }
        differencesOnly.target = self;differencesOnly.action = #selector(filterChanged)
        chooseLeft.setHelp("Linke Datei wählen","Eine lokale Datei für die linke Seite wählen.")
        chooseRight.setHelp("Rechte Datei wählen","Eine lokale Datei für die rechte Seite wählen.")
        refresh.setHelp("Vergleichen","Beide Dateien erneut vollständig innerhalb der angezeigten Grenzen lesen.",shortcut:"⌘R / ⌘↩")
        stop.setHelp("Abbrechen","Laufenden Vergleich verwerfen. Dateien werden nicht verändert.",shortcut:"Esc")
        previous.setHelp("Vorheriger Unterschied","Zum vorherigen zusammenhängenden Unterschied springen; am Anfang wird zum letzten gesprungen.",shortcut:"⌘⌥↑ / ⇧F7")
        next.setHelp("Nächster Unterschied","Zum nächsten zusammenhängenden Unterschied springen; am Ende wird zum ersten gesprungen.",shortcut:"⌘⌥↓ / F7")
        swap.setHelp("Seiten tauschen","Beide Dateipfade tauschen und neu vergleichen.",shortcut:"⌘U")
        surface.arrange = { [weak self] size in
            guard let self else { return };let width = size.width-44,h = size.height,half = (width-14)/2
            heading.frame = NSRect(x:22,y:h-49,width:width,height:31)
            leftCaption.frame = NSRect(x:22,y:h-93,width:55,height:25);self.leftPath.frame = NSRect(x:82,y:h-96,width:size.width-214,height:28);self.chooseLeft.frame = NSRect(x:size.width-124,y:h-97,width:102,height:30)
            rightCaption.frame = NSRect(x:22,y:h-131,width:55,height:25);self.rightPath.frame = NSRect(x:82,y:h-134,width:size.width-214,height:28);self.chooseRight.frame = NSRect(x:size.width-124,y:h-135,width:102,height:30)
            modeCaption.frame = NSRect(x:22,y:h-173,width:47,height:24);self.mode.frame = NSRect(x:73,y:h-176,width:194,height:28)
            encodingCaption.frame = NSRect(x:279,y:h-173,width:75,height:24);self.encoding.frame = NSRect(x:357,y:h-176,width:340,height:28)
            self.refresh.frame = NSRect(x:size.width-258,y:h-177,width:128,height:30);self.stop.frame = NSRect(x:size.width-122,y:h-177,width:100,height:30)
            self.ignoreCase.frame = NSRect(x:22,y:h-214,width:285,height:26);self.ignoreWhitespace.frame = NSRect(x:312,y:h-214,width:190,height:26);self.ignoreEndings.frame = NSRect(x:507,y:h-214,width:230,height:26)
            readOnly.frame = NSRect(x:746,y:h-211,width:max(0,width-724),height:22)
            self.previous.frame = NSRect(x:22,y:h-254,width:177,height:30);self.next.frame = NSRect(x:207,y:h-254,width:170,height:30);self.differencesOnly.frame = NSRect(x:392,y:h-253,width:180,height:26)
            self.position.frame = NSRect(x:580,y:h-249,width:max(80,size.width-730),height:22);self.swap.frame = NSRect(x:size.width-122,y:h-254,width:100,height:30)
            scroll.frame = NSRect(x:22,y:291,width:width,height:max(125,h-557))
            self.leftDetail.frame = NSRect(x:22,y:261,width:half,height:22);self.rightDetail.frame = NSRect(x:36+half,y:261,width:half,height:22)
            leftScroll.frame = NSRect(x:22,y:84,width:half,height:171);rightScroll.frame = NSRect(x:36+half,y:84,width:half,height:171)
            self.info.frame = NSRect(x:22,y:37,width:width,height:39);self.safety.frame = NSRect(x:22,y:10,width:width,height:22)
        }
        info.maximumNumberOfLines = 2;info.lineBreakMode = .byWordWrapping
        w.workflowKeys = { [weak self,weak w] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"r",.command) || WorkflowKeys.matches(event,"\r",.command) { self.beginCompare();return true }
            if WorkflowKeys.matches(event,"l",.command) { w?.makeFirstResponder(self.leftPath);self.leftPath.selectText(nil);return true }
            if WorkflowKeys.matches(event,"l",[.command,.shift]) { w?.makeFirstResponder(self.rightPath);self.rightPath.selectText(nil);return true }
            if WorkflowKeys.matches(event,"u",.command) { self.swapFiles();return true }
            if WorkflowKeys.matches(event,String(UnicodeScalar(NSDownArrowFunctionKey)!),[.command,.option]) || WorkflowKeys.matches(event,String(UnicodeScalar(NSF7FunctionKey)!)) { self.jump(backward:false);return true }
            if WorkflowKeys.matches(event,String(UnicodeScalar(NSUpArrowFunctionKey)!),[.command,.option]) || WorkflowKeys.matches(event,String(UnicodeScalar(NSF7FunctionKey)!),.shift) { self.jump(backward:true);return true }
            if WorkflowKeys.matches(event,"\u{1b}") { if self.isComparing { self.cancel() } else { self.close() };return true }
            for (index,kind) in FileDiffMode.allCases.enumerated() where WorkflowKeys.matches(event,String(index+1),.command) { self.mode.selectItem(at:index);self.optionsChanged();self.info.toolTip = kind.title;return true }
            return false
        }
        surface.needsLayout = true;w.center();updateActions();beginCompare()
    }
    required init?(coder:NSCoder) { fatalError() }
    private func detailScroll(_ text:CommanderTextView) -> NSScrollView {
        let scroll = NSScrollView();scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.autohidesScrollers = true;scroll.borderType = .bezelBorder
        text.isEditable = false;text.isRichText = false;text.isSelectable = true;text.font = .monospacedSystemFont(ofSize:12,weight:.regular);text.textContainerInset = NSSize(width:10,height:10);text.isAutomaticLinkDetectionEnabled = false;text.autoresizingMask = [.width];text.updateColors();scroll.documentView = text;return scroll
    }
    func options() -> FileDiffOptions {
        var value = FileDiffOptions();value.mode = FileDiffMode.allCases[max(0,mode.indexOfSelectedItem)];value.encoding = FileDiffEncoding.allCases[max(0,encoding.indexOfSelectedItem)]
        value.ignoreCase = ignoreCase.state == .on;value.ignoreWhitespace = ignoreWhitespace.state == .on;value.ignoreLineEndings = ignoreEndings.state == .on;return value
    }
    func controlTextDidChange(_ notification:Notification) { invalidate();info.stringValue = "Dateipfad geändert · erneut vergleichen" }
    @objc func optionsChanged() { invalidate();beginCompare() }
    private func invalidate() {
        token.cancel();generation = UUID();isComparing = false;clearReport();updateActions()
    }
    private func clearReport() {
        result = nil;visibleRows = [];leftText.string = "";rightText.string = "";leftDetail.stringValue = "Links";rightDetail.stringValue = "Rechts";position.stringValue = "";table.reloadData()
    }
    func beginCompare() {
        guard !closed else { return };invalidate();token = CancellationToken();let token = token,task = generation,options = options(),l = leftPath.stringValue,r = rightPath.stringValue
        guard l.hasPrefix("/"),r.hasPrefix("/"),!l.contains("\0"),!r.contains("\0") else { info.stringValue = "Bitte zwei vollständige lokale Dateipfade angeben.";info.textColor = .systemRed;return }
        isComparing = true;info.stringValue = "Vergleich wird vorbereitet …";info.textColor = .secondaryLabelColor;updateActions()
        worker.async { [weak self] in
            let result = Result { try FileDiffService.compare(URL(fileURLWithPath:(l as NSString).expandingTildeInPath),URL(fileURLWithPath:(r as NSString).expandingTildeInPath),options:options,token:token,progress:{ value in
                DispatchQueue.main.async { [weak self] in guard let self,self.generation == task,!self.closed else { return };self.info.stringValue = value.stage.title }
            }) }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == task,!self.closed else { return };self.isComparing = false
                switch result {
                case .success(let report):self.result = report;self.filterChanged();self.info.textColor = .labelColor
                case .failure(let error):self.clearReport();self.info.stringValue = token.isCancelled ? "Vergleich abgebrochen · Dateien unverändert" : error.localizedDescription;self.info.textColor = token.isCancelled ? .secondaryLabelColor : .systemRed
                }
                self.updateActions();self.onFinished?()
            }
        }
    }
    func cancel() { guard isComparing else { return };token.cancel();stop.isEnabled = false;info.stringValue = "Vergleich wird abgebrochen …" }
    func swapFiles() { guard !isComparing else { return };let old = leftPath.stringValue;leftPath.stringValue = rightPath.stringValue;rightPath.stringValue = old;beginCompare() }
    private func choose(_ left:Bool) {
        let panel = NSOpenPanel();panel.canChooseDirectories = false;panel.canChooseFiles = true;panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath:(left ? leftPath : rightPath).stringValue).deletingLastPathComponent()
        if panel.runModal() == .OK,let url = panel.url { (left ? leftPath : rightPath).stringValue = url.path;beginCompare() }
    }
    @discardableResult func validateCurrentResult() -> Bool {
        guard let result else { return false }
        do { try result.validateSources();return true } catch { clearReport();info.stringValue = "Quelle geändert · erneut vergleichen. "+error.localizedDescription;info.textColor = .systemOrange;updateActions();return false }
    }
    @objc func filterChanged() {
        guard let result else { return };let selected = visibleRows.indices.contains(table.selectedRow) ? visibleRows[table.selectedRow].id : nil
        visibleRows = result.rows.filter { differencesOnly.state == .off || $0.kind != .equal };table.reloadData()
        if let selected,let index = visibleRows.firstIndex(where:{$0.id == selected}) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        info.stringValue = summary(result);updateActions()
    }
    private func summary(_ report:FileDiffResult) -> String {
        if report.mode == .binary { return "Binär nach Byteposition · \(report.differentBytes ?? 0) abweichende Bytes · \(report.differenceStarts.count) Unterschiedsbereiche\nBereiche enthalten bis zu 32 Bytes Hex-Vorschau; alle \(bytes(max(report.left.bytes,report.right.bytes))) wurden verglichen." }
        let state = report.byteIdentical ? "Dateien bytegleich" : report.isEqual ? "Nach Textregeln gleich · Dateibytes unterscheiden sich" : "\(report.changedRows) geändert · \(report.addedRows) nur rechts · \(report.removedRows) nur links"
        return "Text · \(report.leftLineCount ?? 0) / \(report.rightLineCount ?? 0) Zeilen · \(report.differenceStarts.count) Unterschiedsbereiche\n"+state
    }
    private func updateActions() {
        let enabled = !isComparing && !closed,hasDifferences = result?.differenceStarts.isEmpty == false
        for control:NSControl in [leftPath,rightPath,chooseLeft,chooseRight,mode,refresh,swap] { control.isEnabled = enabled }
        for control:NSControl in [encoding,ignoreCase,ignoreWhitespace,ignoreEndings] { control.isEnabled = enabled && options().mode != .binary }
        stop.isEnabled = isComparing;previous.isEnabled = enabled && hasDifferences;next.isEnabled = previous.isEnabled;differencesOnly.isEnabled = enabled && result != nil
    }
    func jump(backward:Bool) {
        guard validateCurrentResult(),let result,!result.differenceStarts.isEmpty else { return }
        let current = visibleRows.indices.contains(table.selectedRow) ? visibleRows[table.selectedRow].id : (backward ? Int.max : -1),starts = result.differenceStarts
        let chosen = backward ? starts.last(where:{$0 < current}) ?? starts.last! : starts.first(where:{$0 > current}) ?? starts.first!
        guard let row = visibleRows.firstIndex(where:{$0.id == chosen}) else { return };table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);table.scrollRowToVisible(row);window?.makeFirstResponder(table)
    }
    func numberOfRows(in tableView:NSTableView) -> Int { visibleRows.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
        guard visibleRows.indices.contains(row),let report = result else { return nil };let entry = visibleRows[row],key = column?.identifier.rawValue ?? "",value:String
        switch key {
        case "kind":value = entry.kind.title
        case "leftPosition","rightPosition":let number = key == "leftPosition" ? entry.leftPosition : entry.rightPosition;value = number.map { report.mode == .binary ? String(format:"0x%X",$0) : String($0) } ?? "—"
        default:
            let left = key == "left",text = left ? entry.leftText : entry.rightText,ending = left ? entry.leftEnding : entry.rightEnding
            value = text.map { String($0.prefix(1000)).replacingOccurrences(of:"\t",with:"⇥")+($0.count > 1000 ? " …" : "")+(report.mode == .text && !report.options.ignoreLineEndings ? "  ["+endingName(ending ?? "")+"]" : "") } ?? "—"
        }
        let cell = label(value,size:12,color:entry.kind == .equal ? .secondaryLabelColor : .labelColor);cell.toolTip = value;cell.lineBreakMode = .byTruncatingTail
        if ["left","right"].contains(key) { cell.font = .monospacedSystemFont(ofSize:12,weight:.regular) }
        if key == "kind" { cell.textColor = entry.kind == .removed ? .systemRed : entry.kind == .added ? .systemGreen : entry.kind == .changed ? .systemOrange : .secondaryLabelColor }
        return cell
    }
    private func endingName(_ value:String) -> String { switch value { case "\r\n":return "CRLF";case "\r":return "CR";case "\n":return "LF";default:return "Kein Zeilenumbruch" } }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard visibleRows.indices.contains(table.selectedRow),validateCurrentResult(),let report = result else { leftText.string = "";rightText.string = "";return }
        let entry = visibleRows[table.selectedRow]
        func detail(_ left:Bool) -> (String,String) {
            let pos = left ? entry.leftPosition : entry.rightPosition,body = left ? entry.leftText : entry.rightText,ending = left ? entry.leftEnding : entry.rightEnding,length = left ? entry.leftLength : entry.rightLength
            guard let pos,let body else { return (left ? "Links · fehlt" : "Rechts · fehlt","") }
            let title = (left ? "Links" : "Rechts")+(report.mode == .binary ? String(format:" · Offset 0x%X · %d Bytes",pos,length) : " · Zeile \(pos) · "+endingName(ending ?? ""))
            return (title,body)
        }
        let a = detail(true),b = detail(false);leftDetail.stringValue = a.0;rightDetail.stringValue = b.0;leftText.string = a.1;rightText.string = b.1
        if let group = report.differenceStarts.lastIndex(where:{$0 <= entry.id}),entry.kind != .equal { position.stringValue = "Unterschied \(group+1) von \(report.differenceStarts.count)" } else { position.stringValue = entry.kind.title }
    }
    func windowDidBecomeKey(_ notification:Notification) { if result != nil { _ = validateCurrentResult() } }
    func windowWillClose(_ notification:Notification) { closed = true;token.cancel();generation = UUID();isComparing = false;clearReport();onFinished = nil;updateActions() }
}
