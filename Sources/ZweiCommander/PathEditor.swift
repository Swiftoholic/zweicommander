import AppKit
import CommanderCore

enum FolderAddress {
    static func resolve(_ text:String,relativeTo base:URL) throws -> URL {
        guard !text.contains("\n"),!text.contains("\r"),!text.contains("\0") else { throw CommanderError.message("Bitte genau einen Ordnerpfad eingeben.") }
        if text.lowercased().hasPrefix("file:") {
            guard let url = URL(string:text),url.isFileURL,url.host == nil || url.host == "" || url.host == "localhost",url.query == nil,url.fragment == nil else { throw CommanderError.message("Die Datei-Adresse ist ungültig.") }
            return URL(fileURLWithPath:url.path).standardizedFileURL
        }
        guard !text.contains("://") else { throw CommanderError.message("Hier einen lokalen oder bereits verbundenen Ordner eingeben.") }
        let path = (text as NSString).expandingTildeInPath
        return (path.hasPrefix("/") ? URL(fileURLWithPath:path) : base.appendingPathComponent(path)).standardizedFileURL
    }
    static func folders(in directory:URL,prefix:String = "",showHidden:Bool) throws -> (items:[AddressSuggestion],limited:Bool) {
        let fm = FileManager.default,options:FileManager.DirectoryEnumerationOptions = showHidden || prefix.hasPrefix(".") ? [] : [.skipsHiddenFiles]
        let children = try fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.isDirectoryKey,.isSymbolicLinkKey],options:options)
        var items: [AddressSuggestion] = []
        for rawChild in children {
            let child = rawChild.standardizedFileURL
            guard child.lastPathComponent.range(of:prefix,options:[.anchored,.caseInsensitive,.diacriticInsensitive]) != nil || prefix.isEmpty else { continue }
            let values = try? child.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
            guard values?.isDirectory == true || (values?.isSymbolicLink == true && FileSystem.isDirectory(child)) else { continue }
            items.append(AddressSuggestion(url:child,title:child.lastPathComponent,detail:"Unterordner von „"+(directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent)+"“"))
        }
        items.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return (Array(items.prefix(200)),items.count > 200)
    }
}

final class PathEditor: NSTextField {
    var onCancel: (()->Void)?
    var onChoose: ((URL)->Void)?
    var recentFolders: [URL] = []
    var showHiddenFolders = false
    private(set) var baseURL = URL(fileURLWithPath:"/")
    private(set) var sessionActive = false
    private(set) var validationMessage: String?
    private(set) var isQuerying = false
    let dropdown = AddressDropdown()
    private var generation = 0
    private var pending: DispatchWorkItem?
    var suggestions: [AddressSuggestion] { dropdown.rows }
    override init(frame:NSRect) {
        super.init(frame:frame)
        setAccessibilityLabel("Ordneradresse")
        placeholderString = "Ordnerpfad · Tab ergänzt"
        dropdown.onChoose = { [weak self] item in self?.open(item.url) }
        dropdown.onDismiss = { [weak self] in self?.invalidateQuery() }
        toolTip = "Ordneradresse · ⌘L\nAbsolute oder relative Pfade, ~ und file://-Adressen. ↓ zeigt Vorschläge, Tab ergänzt, Enter öffnet."
        setAccessibilityHelp(toolTip)
    }
    required init?(coder:NSCoder) { fatalError() }
    func begin(at url:URL,history:[URL],showHidden:Bool) {
        if !sessionActive { stringValue = url.path }
        invalidateQuery();dropdown.close();baseURL = url;recentFolders = history;showHiddenFolders = showHidden;sessionActive = true;clearError()
        toolTip = "Ordneradresse · "+CommandHelp.shortcut("path")+"\nAbsolute oder relative Pfade, ~ und file://-Adressen. ↓ zeigt Vorschläge, Tab ergänzt, Enter öffnet.";setAccessibilityHelp(toolTip)
    }
    func end() {
        sessionActive = false;invalidateQuery();dropdown.close();clearError()
    }
    private func invalidateQuery() { generation += 1;pending?.cancel();pending = nil;isQuerying = false }
    private func clearError() { validationMessage = nil;textColor = .labelColor;setAccessibilityHelp(toolTip) }
    func edited() {
        guard sessionActive else { return };clearError();requestSuggestions(debounce:true)
    }
    func requestSuggestions(debounce:Bool = false,selectFirst:Bool = false,completeFirst:Bool = false) {
        guard sessionActive else { return }
        invalidateQuery();dropdown.close();let request = generation,text = stringValue,base = baseURL,hidden = showHiddenFolders
        if text.isEmpty {
            var seen = Set<String>()
            let rows = recentFolders.reversed().filter { seen.insert($0.standardizedFileURL.path).inserted }.prefix(30).map { AddressSuggestion(url:$0,title:$0.lastPathComponent.isEmpty ? "/" : $0.lastPathComponent,detail:($0.path as NSString).abbreviatingWithTildeInPath,history:true) }
            dropdown.show(under:self,title:"Zuletzt besucht",rows:Array(rows),message:rows.isEmpty ? "Einen Ordnerpfad eingeben" : nil)
            if selectFirst { dropdown.moveSelection(1) };if completeFirst { completeSelection() };return
        }
        let resolved: URL
        do { resolved = try FolderAddress.resolve(text,relativeTo:base) } catch { showError(error.localizedDescription);return }
        let children = text.hasSuffix("/") || text == "~" || (selectFirst && text == base.path)
        // Keep a typed dot prefix before URL normalization turns "." into the base folder.
        let inputPath = text.lowercased().hasPrefix("file:") ? resolved.path : (text as NSString).expandingTildeInPath
        let prefix = children ? "" : (inputPath as NSString).lastPathComponent
        let directory: URL
        do { directory = children ? resolved : try FolderAddress.resolve((inputPath as NSString).deletingLastPathComponent,relativeTo:base) }
        catch { showError(error.localizedDescription);return }
        isQuerying = true
        if !debounce { dropdown.show(under:self,title:"Ordner werden gesucht …") }
        let work = DispatchWorkItem { [weak self] in
            let result = Result { try FolderAddress.folders(in:directory,prefix:prefix,showHidden:hidden) }
            DispatchQueue.main.async {
                guard let self,self.sessionActive,self.generation == request,self.stringValue == text,self.window?.isVisible == true else { return }
                self.isQuerying = false
                switch result {
                case .success(let value):
                    self.dropdown.show(under:self,title:value.limited ? "200 Ordnervorschläge · zum Eingrenzen weitertippen" : "Ordner",rows:value.items,message:value.items.isEmpty ? "Keine passenden Ordner · Pfad weiter eingeben" : nil)
                    if selectFirst { self.dropdown.moveSelection(1) }
                    if completeFirst { self.completeSelection() }
                case .failure:
                    self.dropdown.show(under:self,title:"Ordner",message:"Dieser Pfad ist noch nicht lesbar · weiter eingeben")
                }
            }
        }
        pending = work
        DispatchQueue.global(qos:.userInitiated).asyncAfter(deadline:.now()+(debounce ? 0.14 : 0),execute:work)
    }
    @discardableResult func handle(_ selector:Selector) -> Bool {
        guard sessionActive else { return false }
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            if dropdown.isVisible { invalidateQuery();dropdown.close();clearError() } else { onCancel?() };return true
        case #selector(NSResponder.moveDown(_:)):
            if dropdown.isVisible && !isQuerying { dropdown.moveSelection(1) } else { requestSuggestions(selectFirst:true) };return true
        case #selector(NSResponder.moveUp(_:)):
            if dropdown.isVisible && !isQuerying { dropdown.moveSelection(-1);return true };return false
        case #selector(NSResponder.insertTab(_:)),#selector(NSResponder.complete(_:)):
            if dropdown.isVisible && !isQuerying { completeSelection() } else { requestSuggestions(completeFirst:true) };return true
        case #selector(NSResponder.insertNewline(_:)):
            if dropdown.isVisible && dropdown.selectedIndex >= 0 && !isQuerying { dropdown.chooseSelected() } else { submit() };return true
        default: return false
        }
    }
    func completeSelection() {
        let index = dropdown.selectedIndex >= 0 ? dropdown.selectedIndex : 0
        guard suggestions.indices.contains(index) else { NSSound.beep();return }
        stringValue = suggestions[index].url.path;if !stringValue.hasSuffix("/") { stringValue += "/" };clearError()
        if let editor = currentEditor() as? NSTextView { editor.string = stringValue;editor.setSelectedRange(NSRange(location:(stringValue as NSString).length,length:0)) }
        requestSuggestions()
    }
    func submit() {
        guard sessionActive else { return }
        do { open(try FolderAddress.resolve(stringValue,relativeTo:baseURL)) } catch { showError(error.localizedDescription) }
    }
    private func open(_ url:URL) {
        guard sessionActive else { return }
        invalidateQuery();dropdown.close();let request = generation,text = stringValue
        isQuerying = true
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in
            guard let self,self.sessionActive,self.generation == request,self.isQuerying else { return }
            self.dropdown.show(under:self,title:"Ordner wird geöffnet …")
        }
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result = Result { () -> URL in
                var isDirectory:ObjCBool = false
                guard FileManager.default.fileExists(atPath:url.path,isDirectory:&isDirectory) else { throw CommanderError.message("Ordner nicht gefunden oder nicht erreichbar. Adresse prüfen und erneut öffnen.") }
                guard isDirectory.boolValue else { throw CommanderError.message("Diese Adresse bezeichnet eine Datei. Bitte einen Ordner wählen.") }
                _ = try FileManager.default.contentsOfDirectory(atPath:url.path)
                return url
            }
            DispatchQueue.main.async {
                guard let self,self.sessionActive,self.generation == request,self.stringValue == text,self.window?.isVisible == true else { return }
                self.isQuerying = false
                switch result { case .success(let value): self.onChoose?(value);case .failure(let error): self.showError(error.localizedDescription) }
            }
        }
    }
    private func showError(_ message:String) {
        validationMessage = message;textColor = .systemRed;setAccessibilityHelp(message)
        dropdown.show(under:self,title:"Adresse prüfen",message:message,error:true)
    }
    override func cancelOperation(_ sender:Any?) { _ = handle(#selector(NSResponder.cancelOperation(_:))) }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow();if window == nil { end() } }
}
