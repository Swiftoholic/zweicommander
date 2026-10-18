import AppKit
import CommanderCore

final class TransferCriteriaController: NSWindowController,NSWindowDelegate,NSTextFieldDelegate {
    let minimum = input(placeholder:"z. B. 1 MB")
    let maximum = input(placeholder:"z. B. 10 MiB")
    let fromEnabled = checkbox("Geändert ab (einschließlich)")
    let beforeEnabled = checkbox("Geändert vor (ausschließlich)")
    let from = NSDatePicker(),before = NSDatePicker()
    let info = label("",size:11,color:.secondaryLabelColor)
    let apply = ActionButton("Übernehmen",action:{})
    let cancel = ActionButton("Abbrechen",action:{})
    var onApply: ((TransferFilter) -> Void)?
    private let original: TransferFilter
    init(_ filter: TransferFilter) {
        original = filter
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:370),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        w.title = "Dateigröße und Änderungsdatum";w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        let root = OperationContent(frame:w.contentView!.bounds);w.contentView = root
        func place(_ view: NSView,_ x: CGFloat,_ y: CGFloat,_ width: CGFloat,_ height: CGFloat = 26) { view.frame = NSRect(x:x,y:y,width:width,height:height);root.addSubview(view) }
        place(label("Zusätzliche Dateifilter",size:18,weight:.semibold),22,320,606,28)
        place(label("Mindestens",weight:.medium),22,277,115);place(minimum,145,277,185)
        place(label("Höchstens",weight:.medium),350,277,90);place(maximum,445,277,183)
        minimum.stringValue = filter.minimumSize.map { "\($0) B" } ?? "";maximum.stringValue = filter.maximumSize.map { "\($0) B" } ?? ""
        minimum.delegate = self;maximum.delegate = self
        minimum.setAccessibilityLabel("Minimale Dateigröße");maximum.setAccessibilityLabel("Maximale Dateigröße")
        place(label("Leeres Feld: keine Grenze · KB/MB/GB = 1000er-Einheiten · KiB/MiB/GiB = 1024er-Einheiten",size:11,color:.secondaryLabelColor),22,246,606,23)
        for (button,picker,y) in [(fromEnabled,from,202.0),(beforeEnabled,before,160.0)] {
            place(button,22,y,300);place(picker,350,y,278)
            picker.datePickerStyle = .textFieldAndStepper;picker.datePickerElements = [.yearMonthDay,.hourMinute];picker.drawsBackground = true
            picker.target = self;picker.action = #selector(edited)
            button.target = self;button.action = #selector(toggleDates)
        }
        fromEnabled.state = filter.modifiedFrom == nil ? .off : .on;beforeEnabled.state = filter.modifiedBefore == nil ? .off : .on
        from.dateValue = filter.modifiedFrom ?? Calendar.current.startOfDay(for:Date());before.dateValue = filter.modifiedBefore ?? Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:Date()))!
        toggleDates()
        place(label("Größe und Datum gelten gemeinsam für Dateien. Aktive Grenzen lassen symbolische Links aus.",size:11,color:.secondaryLabelColor),22,119,606,24)
        place(label("Ordner folgen den Regeln für Rekursion und leere Ordner. Gespeicherte Zeitpunkte sind fest.",size:11,color:.secondaryLabelColor),22,95,606,23)
        place(info,22,57,606,29)
        place(cancel,22,17,125,30);cancel.perform = { [weak self] in self?.close() }
        place(apply,493,17,135,30);apply.perform = { [weak self] in self?.submit() }
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc func edited() { info.stringValue = "";info.toolTip = nil }
    func controlTextDidChange(_ obj: Notification) { edited() }
    @objc func toggleDates() { from.isEnabled = fromEnabled.state == .on;before.isEnabled = beforeEnabled.state == .on;edited() }
    func submit() {
        do {
            var value = original
            value.minimumSize = try TransferSize.parse(minimum.stringValue);value.maximumSize = try TransferSize.parse(maximum.stringValue)
            value.modifiedFrom = fromEnabled.state == .on ? from.dateValue : nil;value.modifiedBefore = beforeEnabled.state == .on ? before.dateValue : nil
            try value.validate();onApply?(value);close()
        } catch { info.textColor = .systemRed;info.stringValue = error.localizedDescription;info.toolTip = info.stringValue }
    }
    override func close() { if let w = window,let parent = w.sheetParent { parent.endSheet(w) };super.close() }
}

final class CopyProfileNameController: NSWindowController {
    let name = input(placeholder:"Profilname")
    let info = label("",size:11,color:.secondaryLabelColor)
    let save = ActionButton("Speichern",action:{})
    let cancel = ActionButton("Abbrechen",action:{})
    var onSave: ((String) throws -> Void)?
    init() {
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:195),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        w.title = "Kopierprofil speichern";w.isReleasedWhenClosed = false
        super.init(window:w)
        let root = OperationContent(frame:w.contentView!.bounds);w.contentView = root
        let title = label("Aktuelle Kopierregeln speichern",size:18,weight:.semibold);title.frame = NSRect(x:22,y:150,width:476,height:28);root.addSubview(title)
        name.frame = NSRect(x:22,y:108,width:476,height:26);root.addSubview(name)
        info.frame = NSRect(x:22,y:59,width:476,height:40);root.addSubview(info)
        cancel.frame = NSRect(x:22,y:17,width:120,height:30);root.addSubview(cancel);cancel.perform = { [weak self] in self?.close() }
        save.frame = NSRect(x:373,y:17,width:125,height:30);root.addSubview(save);save.perform = { [weak self] in self?.submit() }
    }
    required init?(coder:NSCoder) { fatalError() }
    func submit() {
        do { try onSave?(name.stringValue);close() }
        catch { info.textColor = .systemRed;info.stringValue = error.localizedDescription;info.toolTip = info.stringValue }
    }
    override func close() { if let w = window,let parent = w.sheetParent { parent.endSheet(w) };super.close() }
}
