import AppKit
import QuickLookUI
import CommanderCore

private enum ViewerPayload {
    case quick(ViewerFile),folder(URL),page(ViewerFile,ViewerByteWindow,ViewerTextWindow?,ViewerByteDisplay?)
    case special(ViewerFile,String,String)
}

final class PreviewController:NSWindowController,NSWindowDelegate,NSTextFieldDelegate {
    private(set) var url:URL
    let files:[URL]
    let quick = QLPreviewView(frame:.zero,style:.normal)!,scroll = ViewerScrollView(),text = CommanderTextView()
    let mode = NSSegmentedControl(labels:["Vorschau","Text","Hex","Binär","Dateistruktur"],trackingMode:.selectOne,target:nil,action:nil)
    let previousFile = ActionButton("Vorherige Datei",symbol:"chevron.left",action:{}),nextFile = ActionButton("Nächste Datei",symbol:"chevron.right",action:{})
    let previousPage = ActionButton("Vorherige Seite",symbol:"arrow.up",action:{}),nextPage = ActionButton("Nächste Seite",symbol:"arrow.down",action:{})
    let offset = input("0"),go = ActionButton("Gehe zu",action:{}),encoding = NSPopUpButton()
    let find = input(placeholder:"Exakter Text oder Hexbytes"),findMode = NSPopUpButton(),wrap = checkbox("Am Ende weiter",on:true)
    let previousMatch = ActionButton("Zurück",symbol:"chevron.up",action:{}),nextMatch = ActionButton("Weiter",symbol:"chevron.down",action:{})
    let cancel = ActionButton("Abbrechen",action:{}),reload = ActionButton("Neu laden",symbol:"arrow.clockwise",action:{})
    let sourceInfo = label("",size:11,color:.secondaryLabelColor),rangeInfo = label("",size:12),status = label("",size:11,color:.secondaryLabelColor)
    private(set) var isLoading = false,isSearching = false,closed = false
    private(set) var file:ViewerFile?,byteWindow:ViewerByteWindow?,textWindow:ViewerTextWindow?,byteDisplay:ViewerByteDisplay?,match:ViewerMatch?
    private(set) var special = false,pageOffset:Int64 = 0
    var eventMonitor:Any?
    private let worker = DispatchQueue(label:"local.zweicommander.viewer",qos:.userInitiated)
    private var readToken = CancellationToken(),searchToken = CancellationToken(),readGeneration = UUID(),searchGeneration = UUID()
    private var localRange:NSRange?
    private(set) var searchRequest = UUID()
    init(_ url:URL,files:[URL] = []) {
        self.url = url.standardizedFileURL
        var seen = Set<URL>();var ordered = files.filter { $0.isFileURL }.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        if !ordered.contains(self.url) { ordered.insert(self.url,at:0) };self.files = ordered
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:1080,height:720),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        w.title = "Vorschau · "+url.lastPathComponent;w.minSize = NSSize(width:1000,height:600);w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self
        buildInterface(w);configureKeys(w);w.center()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] in self?.handleImportedKey($0) == true ? nil : $0 }
        if Preferences.state.importedProfile?.plugins.contains(where:{$0.enabled && $0.name.lowercased() == "fileinfo"}) == true,
           ["exe","dll","sys","efi","wlx","wlx64","wcx","wcx64","dylib"].contains(url.pathExtension.lowercased()) { mode.selectedSegment = 4 }
        previewModeChanged()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
    var pageLength:Int { mode.selectedSegment == 1 ? 64*1024 : mode.selectedSegment == 2 ? 4096 : 2048 }
    private func resetSearchPosition() { searchRequest = UUID();match = nil;localRange = nil;text.setSelectedRange(NSRange(location:0,length:0)) }
    @objc func previewModeChanged() { pageOffset = 0;resetSearchPosition();loadPage() }
    @objc func encodingChanged() { resetSearchPosition();loadPage() }
    @objc func searchKindChanged() { searchToken.cancel();searchGeneration = UUID();isSearching = false;resetSearchPosition();status.stringValue = isLoading ? "Lese begrenzten Ausschnitt …" : "Suchangaben geändert · Suche beginnt an der aktuellen Seite";status.textColor = .secondaryLabelColor;updateControls() }
    func controlTextDidChange(_ notification:Notification) { if notification.object as? NSTextField === find { searchKindChanged() } }
    func reloadFile() { file = nil;pageOffset = 0;resetSearchPosition();quick.refreshPreviewItem();loadPage() }
    func changeFile(_ delta:Int) {
        guard !closed,let index = files.firstIndex(of:url),files.indices.contains(index+delta) else { return }
        url = files[index+delta];file = nil;pageOffset = 0;resetSearchPosition()
        window?.title = "Vorschau · "+url.lastPathComponent;loadPage()
    }
    func changePage(_ delta:Int) {
        guard !special,let bytes = byteWindow else { return }
        pageOffset = delta > 0 ? bytes.end : max(0,bytes.offset-Int64(pageLength));resetSearchPosition();loadPage()
    }
    func jump() {
        let value = (offset.currentEditor()?.string ?? offset.stringValue).trimmingCharacters(in:.whitespacesAndNewlines),number = value.lowercased().hasPrefix("0x") ? Int64(value.dropFirst(2),radix:16) : Int64(value)
        guard !special,let file,let number,number >= 0,number <= file.size else { status.stringValue = "Byteoffset ab 0, dezimal oder als 0x… eingeben; höchstens Dateigröße.";status.textColor = .systemOrange;return }
        pageOffset = number;resetSearchPosition();loadPage()
    }
    func cancelWork() {
        readToken.cancel();searchToken.cancel();readGeneration = UUID();searchGeneration = UUID();isLoading = false;isSearching = false
        resetSearchPosition()
        if byteWindow == nil { text.string = "Lesen abgebrochen. Mit ⌘R neu laden." }
        status.stringValue = "Abgebrochen";status.textColor = .secondaryLabelColor;updateControls()
    }
    func loadPage(highlight:ViewerMatch? = nil,request:UUID? = nil) {
        guard !closed else { return }
        readToken.cancel();searchToken.cancel();readGeneration = UUID();searchGeneration = UUID();readToken = CancellationToken()
        let stamp = readGeneration,token = readToken,url = url,selected = mode.selectedSegment,start = pageOffset,choice = ViewerEncoding.allCases[max(0,encoding.indexOfSelectedItem)],length = pageLength,existing = file
        isLoading = true;isSearching = false;special = false;byteWindow = nil;textWindow = nil;byteDisplay = nil;text.string = "Lese Datei …";quick.previewItem = nil
        quick.isHidden = selected != 0;scroll.isHidden = selected == 0;sourceInfo.stringValue = url.path;sourceInfo.toolTip = url.path
        status.stringValue = "Lese begrenzten Ausschnitt …";status.textColor = .secondaryLabelColor;rangeInfo.stringValue = "";updateControls()
        worker.async { [weak self] in
            let result = Result { () throws -> ViewerPayload in
                try token.check()
                if selected == 0 { let entry = try FileEntry(url:url);if entry.isDirectory && !entry.isSymbolicLink { return .folder(url) } }
                let file = try existing ?? ViewerFile(url);try file.validate()
                if selected == 0 { return .quick(file) }
                if selected == 4 {
                    let value = try BinaryInspector.describe(url,token:token) ?? "Kein unterstützter PE-/Mach-O-Binärkopf. Allgemeine Dateieigenschaften: Datei → Eigenschaften."
                    try token.check();try file.validate();return .special(file,Self.bounded(value),"Dateistruktur · Suche im angezeigten Bericht")
                }
                if selected == 1,DocumentText.supports(url) {
                    let value = try DocumentText.extract(url,maxBytes:4*1024*1024,token:token)
                    try token.check();try file.validate();return .special(file,Self.bounded(value),"Office-Dokumenttext · Suche im angezeigten Text · keine Bytezuordnung")
                }
                if selected == 1 { let page = try file.textWindow(offset:min(start,file.size),length:length,encoding:choice,token:token);return .page(file,page.bytes,page,nil) }
                let bytes = try file.read(offset:min(start,file.size),length:length,token:token),display = try ViewerByteDisplay(bytes,binary:selected == 3,token:token)
                return .page(file,bytes,nil,display)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,!self.closed,self.readGeneration == stamp,!token.isCancelled,self.url == url else { return };self.isLoading = false
                switch result {
                case .success(let value):self.install(value,highlight:request == self.searchRequest ? highlight : nil)
                case .failure(let error):self.file = nil;self.text.string = error.localizedDescription;self.status.stringValue = error.localizedDescription;self.status.textColor = .systemRed;self.rangeInfo.stringValue = "Vorschau nicht verfügbar";self.quick.isHidden = true;self.scroll.isHidden = false
                }
                self.updateControls()
            }
        }
    }
    private static func bounded(_ value:String) -> String {
        let body = value as NSString;var end = 64*1024
        guard body.length > end else { return value }
        if (0xD800...0xDBFF).contains(body.character(at:end-1)),(0xDC00...0xDFFF).contains(body.character(at:end)) { end -= 1 }
        return body.substring(to:end)+"\n\n[Anzeigeauszug: Bericht oder Dokumenttext ist länger. Die Suche gilt nur für diesen Auszug.]"
    }
    private func install(_ value:ViewerPayload,highlight:ViewerMatch?) {
        switch value {
        case .quick(let file):self.file = file;quick.previewItem = url as NSURL;rangeInfo.stringValue = "Systemvorschau · "+bytes(file.size);status.stringValue = "⌘1–5 Ansicht · ⌘⌥←/→ Datei wechseln"
        case .folder(let url):file = nil;quick.previewItem = url as NSURL;rangeInfo.stringValue = "Systemvorschau · Ordner";status.stringValue = "Text-, Hex- und Binäransichten sind für reguläre Dateien verfügbar."
        case .special(let file,let body,let caption):self.file = file;special = true;text.string = body;rangeInfo.stringValue = caption;status.stringValue = "Begrenzter Bericht · ⌘F sucht im angezeigten Text";findMode.selectItem(at:0)
        case .page(let file,let window,let page,let display):
            self.file = file;byteWindow = window;textWindow = page;byteDisplay = display;pageOffset = window.offset;offset.stringValue = String(window.offset)
            text.string = page?.text ?? display?.text ?? ""
            let range = window.data.isEmpty ? "Byteposition \(window.offset) von \(file.size) (Dateiende)" : "Bytebereich \(window.offset)–\(window.end-1) von \(file.size)"
            rangeInfo.stringValue = range+" · "+bytes(file.size)+(page.map { " · "+$0.encoding.title } ?? "")
            status.stringValue = page?.hadDecodingErrors == true ? "Ungültige Zeichenfolgen wurden ersetzt. Eine andere Kodierung kann helfen." : "Nur diese Seite wird angezeigt · Die Text-/Hexsuche durchsucht die ganze Datei exakt."
            status.textColor = page?.hadDecodingErrors == true ? .systemOrange : .secondaryLabelColor
            text.scrollRangeToVisible(NSRange(location:0,length:0))
            if let highlight { self.highlight(highlight) }
        }
        if let index = files.firstIndex(of:url) { sourceInfo.stringValue = "\(index+1)/\(files.count) · "+url.path }
    }
    func findMatch(backward:Bool) {
        guard !closed,!isLoading,!isSearching,let file,mode.selectedSegment != 0,!find.stringValue.isEmpty else { return }
        if special { findInDisplayedText(backward:backward);return }
        searchToken.cancel();searchToken = CancellationToken();searchGeneration = UUID()
        let token = searchToken,stamp = searchGeneration,request = searchRequest,value = find.stringValue,hex = findMode.indexOfSelectedItem == 1,choice = ViewerEncoding.allCases[max(0,encoding.indexOfSelectedItem)],wrap = wrap.state == .on
        let start = match.map { backward ? $0.offset : min(file.size,$0.offset+1) } ?? (backward ? min(file.size,pageOffset+1) : pageOffset)
        isSearching = true;status.stringValue = "Durchsuche ganze Datei …";status.textColor = .secondaryLabelColor;updateControls()
        worker.async { [weak self] in
            let result = Result { () throws -> ViewerMatch? in
                let needle = try hex ? ViewerNeedle(hex:value) : ViewerNeedle(text:value,encoding:file.resolvedEncoding(choice,token:token))
                var last = Date.distantPast
                return try file.find(needle,from:start,direction:backward ? .backward : .forward,wrap:wrap,token:token,progress:{ done,total in
                    guard Date().timeIntervalSince(last) > 0.1 else { return };last = Date()
                    DispatchQueue.main.async { [weak self] in guard let self,!self.closed,self.searchGeneration == stamp else { return };self.status.stringValue = "Durchsuche ganze Datei · \(bytes(done)) / \(bytes(total))" }
                })
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,!self.closed,self.searchGeneration == stamp,!token.isCancelled else { return };self.isSearching = false
                switch result {
                case .success(let found):
                    if let found {
                        if hex,self.mode.selectedSegment == 1 { self.mode.selectedSegment = 2 }
                        self.showMatch(found,request:request)
                    } else { self.status.stringValue = "Kein Treffer";self.status.textColor = .systemOrange }
                case .failure(let error):self.status.stringValue = error.localizedDescription;self.status.textColor = .systemRed
                }
                self.updateControls()
            }
        }
    }
    func showMatch(_ value:ViewerMatch,request:UUID) {
        guard !closed,request == searchRequest else { return };match = value;pageOffset = value.offset;loadPage(highlight:value,request:request)
    }
    private func findInDisplayedText(backward:Bool) {
        guard let file else { return }
        do {
            try file.validate();let body = text.string as NSString,query = find.stringValue
            let start = localRange.map { backward ? $0.location : min(body.length,$0.location+1) } ?? (backward ? body.length : 0)
            if let found = try ViewerTextSearch.find(in:text.string,text:query,from:start,direction:backward ? .backward : .forward,wrap:wrap.state == .on) { localRange = found.range;text.setSelectedRange(found.range);text.scrollRangeToVisible(found.range);status.stringValue = "Treffer im angezeigten Text"+(found.wrapped ? " · Suche fortgesetzt" : "") }
            else { status.stringValue = "Kein Treffer im angezeigten Text";status.textColor = .systemOrange }
        } catch { status.stringValue = error.localizedDescription;status.textColor = .systemRed }
    }
    private func highlight(_ value:ViewerMatch) {
        status.stringValue = "Treffer bei Byte \(value.offset) · \(value.length) Bytes"+(value.wrapped ? " · Suche am Dateiende fortgesetzt" : "")
        if let byteWindow,value.offset+Int64(value.length) > byteWindow.end { status.stringValue += " · Treffer reicht über diese Seite hinaus" }
        guard let range = textWindow?.range(for:value) ?? byteDisplay?.range(for:value) else { return }
        text.setSelectedRange(range);text.scrollRangeToVisible(range)
    }
    func updateControls() {
        let busy = isLoading || isSearching,paged = mode.selectedSegment > 0 && mode.selectedSegment < 4 && !special
        previousPage.isEnabled = !busy && paged && (byteWindow?.offset ?? 0) > 0;nextPage.isEnabled = !busy && paged && byteWindow.map { $0.end < $0.fileSize } == true
        offset.isEnabled = !busy && paged && file != nil;go.isEnabled = offset.isEnabled
        encoding.isEnabled = mode.selectedSegment == 1 && !special
        find.isEnabled = mode.selectedSegment != 0;findMode.isEnabled = find.isEnabled && !special
        for button in [previousMatch,nextMatch] { button.isEnabled = !busy && file != nil && find.isEnabled && !find.stringValue.isEmpty }
        wrap.isEnabled = find.isEnabled;cancel.isEnabled = busy
        let index = files.firstIndex(of:url) ?? 0;previousFile.isEnabled = index > 0;nextFile.isEnabled = index+1 < files.count
    }
    func windowWillClose(_ notification:Notification) {
        closed = true;isLoading = false;isSearching = false;readToken.cancel();searchToken.cancel();readGeneration = UUID();searchGeneration = UUID();file = nil;byteWindow = nil;textWindow = nil;byteDisplay = nil;resetSearchPosition();text.string = "";quick.previewItem = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor);self.eventMonitor = nil }
    }
}
