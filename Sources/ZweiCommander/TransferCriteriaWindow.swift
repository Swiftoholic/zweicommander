import AppKit
import CommanderCore

final class TransferCriteriaController: NSWindowController,NSWindowDelegate,NSTextFieldDelegate {
    let minimum = input(placeholder:"z. B. 1 MB")
    let maximum = input(placeholder:"z. B. 10 MiB")
    let fromEnabled = checkbox("Geändert ab (einschließlich)")
    let beforeEnabled = checkbox("Geändert vor (ausschließlich)")
    let from = NSDatePicker(),before = NSDatePicker()
    let dateMode = NSPopUpButton()
    let ageMinimum = input(placeholder:"keine Grenze"),ageMaximum = input(placeholder:"keine Grenze")
    let ageMinimumUnit = NSPopUpButton(),ageMaximumUnit = NSPopUpButton()
    private let ageMinimumLabel = label("Mindestens so alt",weight:.medium),ageMaximumLabel = label("Höchstens so alt",weight:.medium)
    private let modeHint = label("",size:11,color:.secondaryLabelColor),referenceHint = label("",size:11,color:.secondaryLabelColor)
    let info = label("",size:11,color:.secondaryLabelColor)
    let apply = ActionButton("Übernehmen",action:{})
    let cancel = ActionButton("Abbrechen",action:{})
    var onApply: ((TransferFilter) -> Void)?
    private let original: TransferFilter
    init(_ filter: TransferFilter) {
        original = filter
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:430),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        w.title = "Dateigröße und Änderungsdatum";w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        let root = OperationContent(frame:w.contentView!.bounds);w.contentView = root
        func place(_ view: NSView,_ x: CGFloat,_ y: CGFloat,_ width: CGFloat,_ height: CGFloat = 26) { view.frame = NSRect(x:x,y:y,width:width,height:height);root.addSubview(view) }
        place(label("Zusätzliche Dateifilter",size:18,weight:.semibold),22,380,606,28)
        place(label("Mindestens",weight:.medium),22,337,115);place(minimum,145,337,185)
        place(label("Höchstens",weight:.medium),350,337,90);place(maximum,445,337,183)
        minimum.stringValue = filter.minimumSize.map { "\($0) B" } ?? "";maximum.stringValue = filter.maximumSize.map { "\($0) B" } ?? ""
        minimum.delegate = self;maximum.delegate = self
        minimum.setAccessibilityLabel("Minimale Dateigröße");maximum.setAccessibilityLabel("Maximale Dateigröße")
        place(label("Leeres Feld: keine Grenze · KB/MB/GB = 1000er-Einheiten · KiB/MiB/GiB = 1024er-Einheiten",size:11,color:.secondaryLabelColor),22,306,606,23)
        place(label("Änderungsdatum",weight:.medium),22,263,150)
        dateMode.addItems(withTitles:["Feste Zeitpunkte","Relatives Alter"]);place(dateMode,190,262,438,28)
        dateMode.target = self;dateMode.action = #selector(changeDateMode);dateMode.selectItem(at:filter.modifiedAge == nil ? 0 : 1)
        for (button,picker,y) in [(fromEnabled,from,218.0),(beforeEnabled,before,176.0)] {
            place(button,22,y,300);place(picker,350,y,278)
            picker.datePickerStyle = .textFieldAndStepper;picker.datePickerElements = [.yearMonthDay,.hourMinute];picker.drawsBackground = true
            picker.target = self;picker.action = #selector(edited)
            button.target = self;button.action = #selector(toggleDates)
        }
        fromEnabled.state = filter.modifiedFrom == nil ? .off : .on;beforeEnabled.state = filter.modifiedBefore == nil ? .off : .on
        from.dateValue = filter.modifiedFrom ?? Calendar.current.startOfDay(for:Date());before.dateValue = filter.modifiedBefore ?? Calendar.current.date(byAdding:.day,value:1,to:Calendar.current.startOfDay(for:Date()))!
        for (title,field,unit,value,y) in [(ageMinimumLabel,ageMinimum,ageMinimumUnit,filter.modifiedAge?.minimum,218.0),(ageMaximumLabel,ageMaximum,ageMaximumUnit,filter.modifiedAge?.maximum,176.0)] {
            place(title,22,y,190);place(field,220,y,155);place(unit,390,y,238,28)
            field.stringValue = value.map { String($0.amount) } ?? "";field.delegate = self;field.setAccessibilityLabel(title.stringValue)
            unit.addItems(withTitles:TransferAgeUnit.allCases.map { $0.german() });unit.selectItem(at:TransferAgeUnit.allCases.firstIndex(of:value?.unit ?? .days)!)
            unit.target = self;unit.action = #selector(edited)
        }
        place(label("Größe und Datum gelten gemeinsam für Dateien. Aktive Grenzen lassen symbolische Links aus.",size:11,color:.secondaryLabelColor),22,135,606,24)
        place(modeHint,22,111,606,24);place(referenceHint,22,87,606,24)
        place(info,22,53,606,29)
        place(cancel,22,17,125,30);cancel.perform = { [weak self] in self?.close() }
        place(apply,493,17,135,30);apply.perform = { [weak self] in self?.submit() }
        changeDateMode()
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc func edited() { info.stringValue = "";info.toolTip = nil }
    func controlTextDidChange(_ obj: Notification) { edited() }
    @objc func toggleDates() { from.isEnabled = dateMode.indexOfSelectedItem == 0 && fromEnabled.state == .on;before.isEnabled = dateMode.indexOfSelectedItem == 0 && beforeEnabled.state == .on;edited() }
    @objc func changeDateMode() {
        let relative = dateMode.indexOfSelectedItem == 1
        for view in [fromEnabled,beforeEnabled,from,before] as [NSView] { view.isHidden = relative }
        for view in [ageMinimumLabel,ageMaximumLabel,ageMinimum,ageMaximum,ageMinimumUnit,ageMaximumUnit] as [NSView] { view.isHidden = !relative }
        modeHint.stringValue = relative ? "1 Tag = 24 Stunden · 1 Woche = 7 Tage · beide Altersgrenzen einschließlich" : "Gespeicherte Zeitpunkte bleiben beim Laden eines Profils gleich."
        referenceHint.stringValue = relative ? "Bezug: Vorschauzeit · neue Vorschau berechnet neu · künftige Änderungsdaten ausgeschlossen" : "Ordner folgen den Regeln für Rekursion und leere Ordner."
        toggleDates()
    }
    func submit() {
        do {
            var value = original
            value.minimumSize = try TransferSize.parse(minimum.stringValue);value.maximumSize = try TransferSize.parse(maximum.stringValue)
            if dateMode.indexOfSelectedItem == 1 {
                let minimum = try TransferAgeLimit.parse(ageMinimum.stringValue,unit:TransferAgeUnit.allCases[ageMinimumUnit.indexOfSelectedItem])
                let maximum = try TransferAgeLimit.parse(ageMaximum.stringValue,unit:TransferAgeUnit.allCases[ageMaximumUnit.indexOfSelectedItem])
                value.modifiedAge = minimum == nil && maximum == nil ? nil : TransferAgeRange(minimum:minimum,maximum:maximum)
                value.modifiedFrom = nil;value.modifiedBefore = nil
            } else {
                value.modifiedAge = nil;value.modifiedFrom = fromEnabled.state == .on ? from.dateValue : nil;value.modifiedBefore = beforeEnabled.state == .on ? before.dateValue : nil
            }
            try value.validate();onApply?(value);close()
        } catch { info.textColor = .systemRed;info.stringValue = error.localizedDescription;info.toolTip = info.stringValue }
    }
    override func close() { if let w = window,let parent = w.sheetParent { parent.endSheet(w) };super.close() }
}

extension TransferAgeUnit {
    func german(_ amount: Int64 = 2) -> String {
        switch self { case .minutes:return amount == 1 ? "Minute" : "Minuten";case .hours:return amount == 1 ? "Stunde" : "Stunden";case .days:return amount == 1 ? "Tag" : "Tage";case .weeks:return amount == 1 ? "Woche" : "Wochen" }
    }
}
extension TransferAgeLimit { var german: String { "\(amount) "+unit.german(amount) } }

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
