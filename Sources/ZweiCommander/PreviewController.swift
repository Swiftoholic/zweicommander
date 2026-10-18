import AppKit
import QuickLookUI
import CommanderCore

final class PreviewController: NSWindowController {
    let url: URL
    let quick = QLPreviewView(frame: .zero, style: .normal)!
    let scroll = NSScrollView()
    let text = NSTextView()
    let mode = NSSegmentedControl(labels: ["Vorschau", "Text", "Hex", "Binär", "Dateistruktur"], trackingMode: .selectOne, target: nil, action: nil)
    var eventMonitor: Any?
    init(_ url: URL) {
        self.url = url
        let w = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 850,height: 600), styleMask: [.titled,.closable,.resizable,.miniaturizable], backing: .buffered, defer: false)
        w.title = "Vorschau · " + url.lastPathComponent; w.isReleasedWhenClosed = false
        super.init(window: w)
        let root = NSView(frame: w.contentView!.bounds); root.autoresizingMask = [.width,.height]
        mode.frame = NSRect(x: 16,y: 558,width: 590,height: 28); mode.autoresizingMask = [.minYMargin]; mode.selectedSegment = 0; mode.target = self; mode.action = #selector(previewModeChanged)
        quick.frame = NSRect(x: 0,y: 0,width: 850,height: 546); quick.autoresizingMask = [.width,.height]; quick.previewItem = url as NSURL
        scroll.frame = quick.frame; scroll.autoresizingMask = [.width,.height]; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.isHidden = true
        text.frame = scroll.bounds; text.autoresizingMask = [.width]; text.isEditable = false; text.isRichText = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12,weight: .regular); text.textContainerInset = NSSize(width: 16,height: 16); text.isAutomaticLinkDetectionEnabled = false
        scroll.documentView = text
        root.addSubview(quick); root.addSubview(scroll); root.addSubview(mode); w.contentView = root; w.center()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self,NSApp.keyWindow === self.window else { return event }
            let bindings = Preferences.state.importedProfile?.viewerShortcuts ?? ["text":"t","hex":"h","binary":"b","preview":"i","close":"escape"]
            let flags = event.modifierFlags.intersection([.command,.control,.option,.shift])
            for (action,shortcut) in bindings {
                guard let parsed = AppDelegate.parseShortcut(shortcut),parsed.1 == flags,event.charactersIgnoringModifiers?.lowercased() == parsed.0 else { continue }
                switch action {
                case "close": self.window?.performClose(nil)
                case "text": self.mode.selectedSegment = 1;self.previewModeChanged()
                case "hex": self.mode.selectedSegment = 2;self.previewModeChanged()
                case "binary": self.mode.selectedSegment = 3;self.previewModeChanged()
                case "metadata": self.mode.selectedSegment = 4;self.previewModeChanged()
                case "preview", "multimedia": self.mode.selectedSegment = 0;self.previewModeChanged()
                case "reload": self.quick.refreshPreviewItem();self.previewModeChanged()
                default:return event
                }
                return nil
            }
            return event
        }
        if Preferences.state.importedProfile?.plugins.contains(where:{$0.enabled && $0.name.lowercased() == "fileinfo"}) == true,
           ["exe","dll","sys","efi","wlx","wlx64","wcx","wcx64","dylib"].contains(url.pathExtension.lowercased()) { mode.selectedSegment = 4;previewModeChanged() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let eventMonitor { NSEvent.removeMonitor(eventMonitor) } }
    @objc func previewModeChanged() {
        let selected = mode.selectedSegment
        quick.isHidden = selected != 0; scroll.isHidden = selected == 0
        guard selected != 0 else { return }
        text.string = "Lese Datei …"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result: String
            do {
                guard !FileSystem.isDirectory(self.url) else { throw CommanderError.message("Text- und Hexansicht sind nur für Dateien verfügbar.") }
                if selected == 4 {
                    result = try BinaryInspector.describe(self.url) ?? "Kein unterstützter PE-/Mach-O-Binärkopf. Die allgemeinen Dateieigenschaften stehen unter Datei → Eigenschaften."
                } else if selected == 1 && DocumentText.supports(self.url) {
                    result = try DocumentText.extract(self.url)
                } else {
                let handle = try FileHandle(forReadingFrom: self.url); defer { try? handle.close() }
                let limit = selected == 1 ? 4*1024*1024 : 256*1024
                let data = try handle.read(upToCount: limit) ?? Data()
                let fullSize = (try? FileEntry(url: self.url).size) ?? Int64(data.count)
                let prefix = fullSize > data.count ? "[Auszug: erste \(bytes(Int64(data.count))) von \(bytes(fullSize))]\n\n" : ""
                if selected == 1 { result = prefix + (String(data: data,encoding: .utf8) ?? String(data: data,encoding: .utf16) ?? String(data: data,encoding: .isoLatin1) ?? "Unbekannte Zeichenkodierung") }
                else {
                    let buffer = Array(data); var lines: [String] = []
                    let step = selected == 2 ? 16 : 8
                    for offset in stride(from: 0,to: buffer.count,by: step) {
                        let part = buffer[offset..<min(offset+step,buffer.count)]
                        let values = part.map { selected == 2 ? String(format:"%02X",$0) : String(repeating:"0",count:8-String($0,radix:2).count)+String($0,radix:2) }.joined(separator:" ")
                        let ascii = part.map { $0 >= 32 && $0 < 127 ? String(UnicodeScalar($0)) : "." }.joined()
                        lines.append(String(format:"%08X  ",offset)+values.padding(toLength:selected == 2 ? 48 : 72,withPad:" ",startingAt:0)+"  "+ascii)
                    }
                    result = prefix+lines.joined(separator:"\n")
                }
                }
            } catch { result = error.localizedDescription }
            DispatchQueue.main.async { if self.mode.selectedSegment == selected { self.text.string = result } }
        }
    }
}
