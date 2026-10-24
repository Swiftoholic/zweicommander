import AppKit
import CommanderCore

struct SelectionContext {
    let scope:String,entries:[FileEntry],selected:Set<URL>
    func agrees(with other:Self) -> Bool { scope == other.scope && entries == other.entries && selected == other.selected }
}

final class SelectionController: NSWindowController,NSWindowDelegate,NSTextFieldDelegate,NSTableViewDataSource,NSTableViewDelegate {
    let pattern = input("*"),regex = checkbox("Regulärer Ausdruck"),files = checkbox("Dateien",on:true),folders = checkbox("Ordner",on:true)
    let mode = NSPopUpButton(),status = label("",size:12),location = label("",size:11,color:.secondaryLabelColor)
    let table = operationTable([("name","Name",450),("state","Ergebnis",190)])
    let apply = ActionButton("Auswahl übernehmen",symbol:"checkmark",action:{})
    var context: (()->SelectionContext?)?,onApply: ((Set<URL>)->Void)?
    private(set) var result: Set<URL>?,preview:SelectionContext?
    private var rows:[FileEntry] = [],pending:DispatchWorkItem?
    init(location:String,context:@escaping()->SelectionContext?,apply:@escaping(Set<URL>)->Void) {
        let window = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:740,height:530),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Auswahl nach Muster";window.minSize = NSSize(width:660,height:480);window.isReleasedWhenClosed = false
        super.init(window:window);window.delegate = self;self.context = context;onApply = apply
        let root = OperationContent(frame:window.contentView!.bounds);root.autoresizingMask = [.width,.height];window.contentView = root
        let heading = label("Auswahl nach Muster",size:22,weight:.semibold);heading.frame = NSRect(x:22,y:480,width:696,height:30);heading.autoresizingMask = [.width,.minYMargin];root.addSubview(heading)
        self.location.stringValue = location;self.location.toolTip = location;self.location.frame = NSRect(x:22,y:449,width:696,height:23);self.location.autoresizingMask = [.width,.minYMargin];root.addSubview(self.location)
        pattern.delegate = self;pattern.placeholderString = "*.pdf;*.txt oder Suchtext";pattern.setAccessibilityLabel("Auswahlmuster");pattern.frame = NSRect(x:22,y:410,width:696,height:28);pattern.autoresizingMask = [.width,.minYMargin];root.addSubview(pattern)
        mode.addItems(withTitles:["Auswahl ersetzen","Zur Auswahl hinzufügen","Aus Auswahl entfernen","Auswahl eingrenzen"])
        mode.toolTip = "Auswahlmodus · ⌘1 Ersetzen · ⌘2 Hinzufügen · ⌘3 Entfernen · ⌘4 Eingrenzen"
        pattern.toolTip = "Platzhalter oder Suchtext; mehrere Muster mit ; verbinden. ⌘L fokussiert das Muster, ⌘R aktualisiert die Vorschau."
        regex.toolTip = "Das gesamte Muster als regulären Ausdruck auswerten; Semikola bleiben Bestandteil des Ausdrucks."
        files.toolTip = "Sichtbare Dateien in den Mustervergleich einbeziehen."
        folders.toolTip = "Sichtbare Ordner in den Mustervergleich einbeziehen."
        [regex,files,folders,mode].forEach { $0.target = self;$0.action = #selector(optionsChanged) }
        let options = row([mode,regex,files,folders]);options.frame = NSRect(x:22,y:368,width:696,height:32);options.autoresizingMask = [.width,.minYMargin];root.addSubview(options)
        status.frame = NSRect(x:22,y:314,width:696,height:48);status.maximumNumberOfLines = 2;status.lineBreakMode = .byWordWrapping;status.autoresizingMask = [.width,.minYMargin];root.addSubview(status)
        table.dataSource = self;table.delegate = self
        let scroll = operationScroll(table);scroll.frame = NSRect(x:22,y:87,width:696,height:216);scroll.autoresizingMask = [.width,.height];root.addSubview(scroll)
        let note = label("* und ? sind Platzhalter · mehrere Muster mit ; · Groß-/Kleinschreibung wird ignoriert.\nDie Vorschau verändert keine Auswahl. Es werden ausschließlich sichtbare Einträge berücksichtigt.",size:11,color:.secondaryLabelColor)
        note.frame = NSRect(x:22,y:48,width:696,height:34);note.maximumNumberOfLines = 2;note.autoresizingMask = [.width];root.addSubview(note)
        let cancel = ActionButton("Abbrechen",action:{ [weak self] in self?.close() });cancel.keyEquivalent = "\u{1b}";cancel.keyEquivalentModifierMask = []
        self.apply.perform = { [weak self] in self?.submit() };self.apply.keyEquivalent = "\r";self.apply.keyEquivalentModifierMask = []
        self.apply.setHelp("Auswahl übernehmen","Nur die angezeigte Auswahl ändern. Dateien bleiben unverändert.",shortcut:"↩ / ⌘↩")
        let actions = row([cancel,self.apply]);actions.frame = NSRect(x:22,y:9,width:696,height:32);root.addSubview(actions)
        window.workflowKeys = { [weak self,weak window] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"\r",.command) { self.submit();return true }
            if WorkflowKeys.matches(event,"l",.command) { window?.makeFirstResponder(self.pattern);self.pattern.currentEditor()?.selectAll(nil);return true }
            if WorkflowKeys.matches(event,"r",.command) { self.prepare();return true }
            for index in 0..<4 where WorkflowKeys.matches(event,String(index+1),.command) { self.mode.selectItem(at:index);self.prepare();return true }
            return false
        }
        window.initialFirstResponder = pattern;window.center();prepare()
    }
    required init?(coder:NSCoder) { fatalError() }
    var combination:SelectionCombine { SelectionCombine.allCases[max(0,min(3,mode.indexOfSelectedItem))] }
    @objc func optionsChanged() { prepare() }
    func controlTextDidChange(_ notification:Notification) {
        pending?.cancel();result = nil;apply.isEnabled = false
        let task = DispatchWorkItem { [weak self] in self?.prepare() };pending = task;DispatchQueue.main.asyncAfter(deadline:.now()+0.14,execute:task)
    }
    func prepare() {
        pending?.cancel();result = nil;preview = nil;rows = [];apply.isEnabled = false
        defer { table.reloadData() }
        guard let value = context?() else { status.stringValue = "Der Ordner oder Tab hat sich geändert. Bitte die Auswahl hier neu öffnen.";status.textColor = .systemOrange;return }
        do {
            let rule = try SelectionRule(pattern.stringValue,regex:regex.state == .on,files:files.state == .on,folders:folders.state == .on),matches = rule.matching(value.entries)
            let result = combination.apply(current:value.selected,matches:matches,universe:Set(value.entries.map(\.url)))
            self.result = result;preview = value;rows = Array(value.entries.filter { matches.contains($0.url) || value.selected.contains($0.url) }.prefix(500));apply.isEnabled = true
            status.stringValue = "\(matches.count) Treffer · danach \(result.count) von \(value.entries.count) Einträgen ausgewählt"+(rows.count == 500 ? "\nVorschau zeigt höchstens 500 Zeilen; die Auswahl umfasst alle Treffer." : "")
            status.textColor = .labelColor
        } catch { status.stringValue = "Auswahlmuster prüfen: "+error.localizedDescription;status.textColor = .systemRed }
    }
    func submit() {
        guard let current = context?(),let preview,let result,apply.isEnabled else { prepare();return }
        guard current.agrees(with:preview) else { prepare();status.stringValue += "\nBestand oder Auswahl wurde aktualisiert. Bitte erneut übernehmen.";return }
        onApply?(result);close()
    }
    func windowWillClose(_ notification:Notification) { pending?.cancel();context = nil;onApply = nil }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int) -> NSView? {
        let entry = rows[row],field = label(column?.identifier.rawValue == "name" ? entry.name : result?.contains(entry.url) == true ? "Ausgewählt" : "Nicht ausgewählt")
        field.toolTip = column?.identifier.rawValue == "name" ? entry.url.absoluteString : field.stringValue;return field
    }
}
