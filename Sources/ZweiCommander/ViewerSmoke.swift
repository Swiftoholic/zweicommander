import AppKit
import Darwin
import CommanderCore

extension AppDelegate {
    func runViewerSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("VIEWER UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("VIEWER SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<500 { if predicate() { return };try? await Task.sleep(nanoseconds:30_000_000) }
                print("VIEWER SMOKE FAIL timeout "+name+" active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none")");exit(1)
            }
            @MainActor func ready(_ viewer:PreviewController) async { await wait("viewer result") { !viewer.isLoading && !viewer.isSearching } }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active viewer") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func key(_ window:NSWindow,_ value:String,_ flags:NSEvent.ModifierFlags = []) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:value,charactersIgnoringModifiers:value,isARepeat:false,keyCode:0),"key") }
            @MainActor func capture(_ window:NSWindow,_ name:String) throws {
                let view = require(window.contentView,"view");view.layoutSubtreeIfNeeded();view.displayIfNeeded();let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap")
                view.cacheDisplay(in:view.bounds,to:bitmap);try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+name+".png"))
            }
            @MainActor func show(_ url:URL,files:[URL] = []) async -> PreviewController {
                let viewer = PreviewController(url,files:files);self.main.secondaryWindows.append(viewer);viewer.showWindow(nil);await activate(viewer.window!);await ready(viewer);return viewer
            }
            @MainActor func query(_ viewer:PreviewController,_ value:String,hex:Bool = false) {
                viewer.find.stringValue = value;viewer.findMode.selectItem(at:hex ? 1 : 0);viewer.searchKindChanged()
            }
            do {
                await wait("main listing") { !self.main.left.isLoading && !self.main.right.isLoading }
                let folder = root.appendingPathComponent("Links"),large = folder.appendingPathComponent("Gross.txt"),utf16 = folder.appendingPathComponent("Unicode.txt"),legacy = folder.appendingPathComponent("Alt.txt")
                var data = Data(String(repeating:"alpha\n",count:10_922).utf8);let first = Int64(data.count);data.append(Data("needle\n".utf8));data.append(Data(String(repeating:"beta\n",count:17_000).utf8));let second = Int64(data.count);data.append(Data("needle\nEnde\n".utf8));try data.write(to:large)
                try (Data([0xFF,0xFE])+"Grüße 😀\nZweite Zeile\n".data(using:.utf16LittleEndian)!).write(to:utf16);try Data([0x80,0x20,0x47,0x72,0xFC,0xDF,0x65]).write(to:legacy)
                let clipboard = NSPasteboard.general.changeCount,preferences = try JSONEncoder().encode(Preferences.state)
                let viewer = await show(large,files:[large,utf16,legacy]),window = require(viewer.window as? WorkflowWindow,"workflow window")
                check(viewer.file?.size == Int64(data.count) && viewer.quick.previewItem != nil,"Quick Look remains available after a checked regular-file open")
                check(viewer.files == [large,utf16,legacy] && viewer.nextFile.isEnabled && !viewer.previousFile.isEnabled,"visible file order and navigation boundaries are retained")
                check(window.performKeyEquivalent(with:key(window,"2",.command)),"Command 2 selects text");await ready(viewer)
                check(viewer.byteWindow?.offset == 0 && (viewer.byteWindow?.data.count ?? 0) <= 64*1024,"text loads a bounded first byte window")
                check(viewer.rangeInfo.stringValue.contains(String(data.count)) && viewer.rangeInfo.stringValue.contains("Bytebereich"),"byte range and full file size are truthful")
                check(viewer.nextPage.isEnabled && !viewer.previousPage.isEnabled,"page controls reflect first-window boundaries")
                check(window.performKeyEquivalent(with:key(window,String(UnicodeScalar(NSDownArrowFunctionKey)!),[.command,.option])),"Command Option Down requests the next page");await ready(viewer)
                check(viewer.byteWindow?.offset == 65_536 && viewer.previousPage.isEnabled,"next page reaches contents beyond the former prefix")
                check(window.performKeyEquivalent(with:key(window,String(UnicodeScalar(NSUpArrowFunctionKey)!),[.command,.option])),"Command Option Up requests the previous page");await ready(viewer)
                check(viewer.byteWindow?.offset == 0,"previous page returns to the beginning")
                check(window.performKeyEquivalent(with:key(window,"l",.command)) && viewer.offset.currentEditor() is NSTextView,"Command L focuses the byte offset")
                viewer.offset.stringValue = "0x10000";viewer.go.performClick(nil);await ready(viewer)
                check(viewer.byteWindow?.offset == 65_536,"hexadecimal byte position is accepted")
                viewer.offset.stringValue = "-1";viewer.go.performClick(nil)
                check(viewer.byteWindow?.offset == 65_536 && viewer.status.textColor == .systemOrange,"invalid offset stays inline without replacing the page")
                viewer.offset.stringValue = "0";viewer.go.performClick(nil);await ready(viewer)
                check(window.performKeyEquivalent(with:key(window,"f",.command)) && viewer.find.currentEditor() is NSTextView,"Command F focuses exact search")
                check(!viewer.handleImportedKey(key(window,"h")) && viewer.mode.selectedSegment == 1,"imported single-letter shortcuts do not steal text entry")
                query(viewer,"needle");viewer.nextMatch.performClick(nil);await ready(viewer)
                check(viewer.match?.offset == first,"whole-file text search finds a word crossing the read boundary")
                check((viewer.text.string as NSString).substring(with:viewer.text.selectedRange()) == "needle","found text is selected at the right Unicode range")
                check(window.performKeyEquivalent(with:key(window,"g",.command)),"Command G advances the search");await ready(viewer)
                check(viewer.match?.offset == second,"next match scans beyond the displayed window")
                check(window.performKeyEquivalent(with:key(window,"g",[.command,.shift])),"Command Shift G searches backwards");await ready(viewer)
                check(viewer.match?.offset == first,"reverse search returns the preceding occurrence")
                viewer.previousMatch.performClick(nil);await ready(viewer)
                check(viewer.match?.offset == second && viewer.match?.wrapped == true,"reverse search wraps across the file boundary")
                viewer.wrap.state = .off;viewer.nextMatch.performClick(nil);await ready(viewer)
                check(viewer.status.stringValue == "Kein Treffer" && viewer.match?.offset == second,"disabled wrapping reports no later match")
                viewer.wrap.state = .on;query(viewer,"6E 65 65 64 6C 65",hex:true);viewer.nextMatch.performClick(nil);await ready(viewer)
                check(viewer.mode.selectedSegment == 2 && viewer.match?.offset == second,"hex search switches a text page to a byte view")
                check((viewer.byteWindow?.data.count ?? 0) <= 4096 && viewer.text.string.contains("6E 65 65 64 6C 65"),"hex output stays small and highlights the exact bytes")
                query(viewer,"GG",hex:true);viewer.nextMatch.performClick(nil);await ready(viewer)
                check(viewer.status.textColor == .systemRed && viewer.status.stringValue.contains("Hexsuche"),"invalid hex input produces an inline error")
                check(window.performKeyEquivalent(with:key(window,"4",.command)),"Command 4 selects binary");await ready(viewer)
                check((viewer.byteWindow?.data.count ?? 0) <= 2048 && viewer.text.string.contains("01100001"),"binary pages remain bounded and display bit values")
                check(window.performKeyEquivalent(with:key(window,String(UnicodeScalar(NSRightArrowFunctionKey)!),[.command,.option])),"Command Option Right changes file");await ready(viewer)
                check(viewer.url == utf16 && viewer.previousFile.isEnabled,"file navigation uses the supplied next file")
                _ = window.performKeyEquivalent(with:key(window,"2",.command));await ready(viewer)
                check(viewer.textWindow?.encoding == .utf16LE && viewer.text.string.contains("Grüße 😀"),"automatic encoding detects UTF-16 and preserves Unicode")
                viewer.nextFile.performClick(nil);await ready(viewer)
                check(viewer.url == legacy && !viewer.nextFile.isEnabled && viewer.textWindow?.hadDecodingErrors == true,"last file boundary and invalid UTF-8 are visible")
                viewer.encoding.selectItem(at:ViewerEncoding.allCases.firstIndex(of:.windows1252)!);viewer.encodingChanged();await ready(viewer)
                check(viewer.text.string == "€ Grüße" && viewer.textWindow?.hadDecodingErrors == false,"explicit Windows-1252 renders legacy text")
                check(window.performKeyEquivalent(with:key(window,"5",.command)),"Command 5 selects file structure");await ready(viewer)
                check(viewer.special && !viewer.go.isEnabled && !viewer.encoding.isEnabled && viewer.rangeInfo.stringValue.contains("Bericht"),"structure mode labels its search scope without fictitious byte offsets")
                let word = root.appendingPathComponent("Office/word");try FileManager.default.createDirectory(at:word,withIntermediateDirectories:true)
                try Data("<document><p>Hallo Dokument</p></document>".utf8).write(to:word.appendingPathComponent("document.xml"));let docx = folder.appendingPathComponent("Dokument.docx");try ArchiveService.pack([word],to:docx)
                let document = await show(docx);document.mode.selectedSegment = 1;document.previewModeChanged();await ready(document)
                check(document.special && document.text.string.contains("Hallo Dokument") && document.rangeInfo.stringValue.contains("keine Bytezuordnung"),"Office XML text remains available with a truthful scope")
                query(document,"Dokument");document.nextMatch.performClick(nil)
                check((document.text.string as NSString).substring(with:document.text.selectedRange()) == "Dokument","special-report search selects within the displayed text")
                document.close();await activate(window)
                let folderPreview = await show(folder)
                check(folderPreview.quick.previewItem != nil && folderPreview.rangeInfo.stringValue.contains("Ordner") && !folderPreview.go.isEnabled,"system preview of directories remains available without a byte reader")
                folderPreview.close();await activate(window)
                for (theme,name) in [(1,"Hell"),(2,"Dunkel")] {
                    Preferences.state.theme = theme;self.main.applyTheme();try? await Task.sleep(nanoseconds:120_000_000)
                    check(window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (theme == 1 ? .aqua : .darkAqua),"viewer follows "+name+" appearance")
                    viewer.mode.selectedSegment = 2;viewer.previewModeChanged();await ready(viewer);try capture(window,"-Viewer-"+name)
                }
                window.contentView?.layoutSubtreeIfNeeded()
                check(viewer.find.frame.maxX < viewer.previousMatch.frame.minX && viewer.go.frame.maxX < viewer.encoding.frame.minX && viewer.scroll.frame.maxY < viewer.rangeInfo.frame.minY,"viewer controls and document area do not overlap")
                viewer.encoding.selectItem(at:0);viewer.mode.selectedSegment = 1;viewer.previewModeChanged();viewer.mode.selectedSegment = 2;viewer.previewModeChanged();await ready(viewer)
                check(viewer.mode.selectedSegment == 2 && viewer.byteDisplay != nil && viewer.textWindow == nil,"rapid mode changes discard stale text results")
                viewer.close()
                check(viewer.closed && viewer.file == nil && viewer.byteWindow == nil && viewer.text.string.isEmpty && viewer.quick.previewItem == nil && viewer.eventMonitor == nil,"closing releases file identities text data Quick Look and event monitoring")
                let stale = await show(large);stale.mode.selectedSegment = 1;stale.previewModeChanged();await ready(stale)
                try Data("changed after preview".utf8).write(to:large);stale.nextPage.performClick(nil);await ready(stale)
                check(stale.file == nil && stale.status.textColor == .systemRed && !stale.text.string.contains("alpha\n"),"changed source cannot display an old next page")
                stale.reload.performClick(nil);await ready(stale)
                check(stale.text.string == "changed after preview","explicit reload accepts the newly reviewed file")
                stale.close()
                let fifo = folder.appendingPathComponent("Pipe");check(mkfifo(fifo.path,0o600) == 0,"synthetic FIFO prepared")
                let blocked = await show(fifo);blocked.mode.selectedSegment = 1;blocked.previewModeChanged();await ready(blocked)
                check(blocked.file == nil && blocked.status.textColor == .systemRed,"special-file preview is refused without blocking")
                blocked.close()
                let closing = await show(large);closing.mode.selectedSegment = 1;closing.previewModeChanged();closing.close();try? await Task.sleep(nanoseconds:150_000_000)
                check(closing.closed && !closing.isLoading && !closing.isSearching && closing.text.string.isEmpty && closing.file == nil,"closing during an asynchronous read cannot revive its result")
                check(NSPasteboard.general.changeCount == clipboard,"viewer leaves the user clipboard untouched")
                let after = try JSONEncoder().encode(Preferences.state),beforeObject = try JSONSerialization.jsonObject(with:preferences) as! [String:Any],afterObject = try JSONSerialization.jsonObject(with:after) as! [String:Any]
                check((beforeObject["left"] as? NSArray) == (afterObject["left"] as? NSArray) && (beforeObject["right"] as? NSArray) == (afterObject["right"] as? NSArray),"viewer navigation does not rewrite saved pane tabs")
                print("VIEWER SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");fflush(stdout);exit(failures.isEmpty ? 0 : 1)
            } catch { print("VIEWER SMOKE FAIL "+error.localizedDescription);fflush(stdout);exit(1) }
        }
    }
}
