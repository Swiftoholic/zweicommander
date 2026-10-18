import AppKit
import CommanderCore

final class ActionButton: NSButton {
    var perform: (() -> Void)?
    convenience init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title; self.perform = action; target = self; self.action = #selector(invoke)
        bezelStyle = .rounded; controlSize = .small
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: title); imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
    }
    @objc private func invoke() { perform?() }
}

func label(_ text: String, size: CGFloat = 12, color: NSColor = .labelColor, weight: NSFont.Weight = .regular) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    field.lineBreakMode = .byTruncatingMiddle
    return field
}
func input(_ value: String = "", placeholder: String = "") -> NSTextField {
    let field = NSTextField(string: value); field.placeholderString = placeholder
    field.font = .systemFont(ofSize: 13); field.isEditable = true; field.isSelectable = true
    return field
}
func checkbox(_ title: String, on: Bool = false) -> NSButton { let b = NSButton(checkboxWithTitle: title, target: nil, action: nil); b.state = on ? .on : .off; return b }
func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .horizontal; s.spacing = spacing; s.alignment = .centerY; return s
}
func column(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    let s = NSStackView(views: views); s.orientation = .vertical; s.spacing = spacing; s.alignment = .leading; return s
}
func form(_ rows: [(String, NSView)], width: CGFloat = 520) -> NSView {
    var y: CGFloat = 0
    let heights = rows.map { max(26, $0.1 is NSScrollView ? 150 : 26) as CGFloat }
    let height = heights.reduce(0,+) + CGFloat(rows.count - 1) * 12
    let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    for (i, pair) in rows.enumerated() {
        let h = heights[i]; y += h
        let title = label(pair.0); title.frame = NSRect(x: 0, y: height-y+4, width: 145, height: 20)
        pair.1.frame = NSRect(x: 150, y: height-y, width: width-150, height: h)
        root.addSubview(title); root.addSubview(pair.1); y += 12
    }
    return root
}
@discardableResult func dialog(_ title: String, message: String = "", accessory: NSView? = nil, buttons: [String] = ["OK", "Abbrechen"]) -> Int {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.alertStyle = .informational
    if let accessory { alert.accessoryView = accessory }
    for button in buttons { alert.addButton(withTitle: button) }
    return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
}
func showFailure(_ error: Error) { _ = dialog("Vorgang nicht abgeschlossen", message: error.localizedDescription, buttons: ["OK"]) }
func prompt(_ title: String, value: String = "", message: String = "") -> String? {
    let field = input(value); field.frame = NSRect(x: 0, y: 0, width: 460, height: 26)
    return dialog(title, message: message, accessory: field) == 0 ? field.stringValue : nil
}
func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
let displayDate: DateFormatter = { let d = DateFormatter(); d.dateStyle = .medium; d.timeStyle = .short; return d }()

final class TextWindow: NSWindowController, NSWindowDelegate {
    let textView = NSTextView()
    var onClose: (() -> Void)?
    init(title: String, text: String, editable: Bool = false) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 560), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        w.title = title; w.isReleasedWhenClosed = false
        super.init(window: w); w.delegate = self
        let scroll = NSScrollView(frame: w.contentView!.bounds); scroll.autoresizingMask = [.width,.height]
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        textView.frame = scroll.bounds; textView.autoresizingMask = [.width]
        textView.isEditable = editable; textView.isRichText = false; textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.string = text; scroll.documentView = textView; w.contentView?.addSubview(scroll)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }
    func windowWillClose(_ notification: Notification) { onClose?() }
}

struct SavedTab: Codable { var path: String; var title: String?; var locked: Bool }
struct SavedState: Codable {
    var left: [SavedTab] = []
    var right: [SavedTab] = []
    var favorites: [String] = []
    var showHidden = false
    var vertical = true
    var theme = 0
    var shortcuts: [String: String] = [:]
    var importedProfile: SettingsProfile?
}
enum Preferences {
    static var state = load()
    static var testMode = false
    static func decode(_ data: Data) -> SavedState? {
        // Older builds stored the same profile schema under a different property name.
        guard var json = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return nil }
        if json["importedProfile"] == nil {
            let candidates = json.compactMap { key,value -> (String,[String:Any])? in
                guard let profile = value as? [String:Any],profile["sourceSHA256"] is String,profile["columns"] is [[String:Any]],profile["viewerShortcuts"] is [String:String] else { return nil }
                return (key,profile)
            }
            if candidates.count == 1,let (key,profile) = candidates.first { json.removeValue(forKey:key);json["importedProfile"] = profile }
        }
        guard let normalized = try? JSONSerialization.data(withJSONObject:json) else { return nil }
        return try? JSONDecoder().decode(SavedState.self,from:normalized)
    }
    static func load() -> SavedState {
        guard let data = UserDefaults.standard.data(forKey: "ZweiCommander.state.v1"), let value = decode(data) else { return SavedState() }
        return value
    }
    static var beforeImport: Data? {
        if let data = UserDefaults.standard.data(forKey:"ZweiCommander.beforeSettingsImport") { return data }
        let keys = UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("ZweiCommander.before") && $0.hasSuffix("Import") }
        return keys.count == 1 ? keys.first.flatMap { UserDefaults.standard.data(forKey:$0) } : nil
    }
    static func save() {
        if !testMode, let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: "ZweiCommander.state.v1") }
    }
    static func apply(_ profile: SettingsProfile) {
        if !testMode, beforeImport == nil,
           let old = try? JSONEncoder().encode(state) { UserDefaults.standard.set(old, forKey: "ZweiCommander.beforeSettingsImport") }
        state.importedProfile = profile
        state.showHidden = profile.showHidden
        state.theme = profile.darkAppearance ? 2 : 1
        state.vertical = profile.verticalPanels
        state.shortcuts.merge(profile.shortcuts, uniquingKeysWith: { _, imported in imported })
        save()
    }
    static func restoreBeforeImport() -> Bool {
        guard let old = beforeImport,let value = decode(old) else { return false }
        state = value; save(); return true
    }
}

extension ImportedRGB {
    var nsColor: NSColor { NSColor(srgbRed:red,green:green,blue:blue,alpha:1) }
}

private final class JobResult<Value> { var value: Result<Value,Error>? }
final class JobQueue {
    let scheduler = WorkScheduler()
    var onStatus: ((String, Double?) -> Void)?
    var pending: Int { scheduler.snapshots.filter(\.isPending).count }
    var log: [String] = []
    private var timer: Timer?
    init() {
        scheduler.onChange = { [weak self] in DispatchQueue.main.async { self?.publish() } }
        timer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in if self?.pending ?? 0 > 0 { self?.publish() } }
    }
    deinit { timer?.invalidate() }
    var active: WorkSnapshot? { scheduler.snapshots.first { [.running,.pausing,.paused].contains($0.state) } }
    func publish() {
        let list = scheduler.snapshots, count = list.filter(\.isPending).count
        if let current = active {
            let prefix = current.state == .paused ? "Pausiert · " : current.state == .pausing ? "Pause angefordert · " : ""
            let transfer = current.transferredBytes.map { " · "+bytes($0)+" / "+bytes(current.totalBytes ?? 0) } ?? ""
            onStatus?(prefix+current.title+" · "+current.detail+transfer,current.fraction)
        } else { onStatus?(count == 0 ? "Bereit" : "\(count) Auftrag/Aufträge warten · Start über Aufträge",count == 0 ? 1 : nil) }
    }
    @discardableResult func submit<T>(_ title: String, work: @escaping (CancellationToken, @escaping (String) -> Void) throws -> T, completion: @escaping (Result<T, Error>) -> Void) -> UUID {
        submitReported(title,body:{ token,reporter in
            var last = Date.distantPast
            return try work(token,{ detail in guard Date().timeIntervalSince(last) >= 0.1 else { return };last = Date();reporter.report(detail) })
        },completion:completion)
    }
    @discardableResult func submitReported<T>(_ title: String,start: Bool = true,items: [TransferItemProgress] = [],body: @escaping (CancellationToken,WorkReporter) throws -> T,completion: @escaping (Result<T,Error>) -> Void) -> UUID {
        let box = JobResult<T>()
        return scheduler.enqueue(title,start:start,items:items,body:{ token,reporter in
            let result = Result { try body(token,reporter) }; box.value = result
            switch result {
            case .failure(let error): throw error
            case .success(let value):
                if let report = value as? OperationReport,!report.errors.isEmpty { throw CommanderError.message(report.errors.joined(separator:"\n")) }
            }
        },completion:{ [weak self] snapshot in
            DispatchQueue.main.async {
                self?.log.append(title+": "+snapshot.state.german+" · "+snapshot.detail)
                if let result = box.value { completion(result) }
                self?.publish()
            }
        })
    }
    func cancel() { scheduler.cancel(); publish() }
    func togglePause() {
        if let state = active?.state,[.paused,.pausing].contains(state) { scheduler.resume() }
        else { scheduler.pause() }
        publish()
    }
}
extension WorkState {
    var german: String {
        switch self { case .waiting:return "Wartet";case .running:return "Läuft";case .pausing:return "Pause angefordert";case .paused:return "Pausiert";case .completed:return "Fertig";case .failed:return "Fehler";case .cancelled:return "Abgebrochen" }
    }
}
extension TransferItemState {
    var german: String {
        switch self { case .waiting:return "Wartet";case .running:return "Läuft";case .completed:return "Fertig";case .skipped:return "Übersprungen";case .failed:return "Fehler";case .cancelled:return "Nicht ausgeführt" }
    }
}
extension MergeDecision {
    var german: String {
        switch self { case .pending:return "Entscheidung fehlt";case .skip:return "Überspringen";case .keepBoth:return "Beide behalten";case .replace:return "Ersetzen mit Sicherung" }
    }
}
