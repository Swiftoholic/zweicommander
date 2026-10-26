import AppKit
import ImageIO
import CommanderCore

private final class MediaMetadataSmokeLifetime { var touches = 0 }

extension AppDelegate {
    func runMediaMetadataSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            @MainActor func check(_ value:Bool,_ name:String) { checks += 1;print("MEDIA METADATA UI \(value ? "PASS" : "FAIL") "+name);if !value { failures.append(name);print("MEDIA METADATA UI CONTEXT active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none") front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")") } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("MEDIA METADATA SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async { for _ in 0..<500 { if predicate() { return };try? await Task.sleep(nanoseconds:30_000_000) };print("MEDIA METADATA SMOKE FAIL timeout "+name);exit(1) }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active window") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func key(_ window:NSWindow,_ text:String,_ flags:NSEvent.ModifierFlags) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0),"key") }
            @MainActor func capture(_ window:NSWindow,_ name:String) throws { let view = require(window.contentView,"view");view.layoutSubtreeIfNeeded();view.displayIfNeeded();let image = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap");view.cacheDisplay(in:view.bounds,to:image);try require(image.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+"-Medieninformationen-"+name+".png")) }
            func integer(_ value:UInt64,_ count:Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded:value >> ($0*8)) }) }
            func wav() -> Data { let fmt = integer(1,2)+integer(1,2)+integer(8000,4)+integer(16000,4)+integer(2,2)+integer(16,2);let body = Data("WAVEfmt ".utf8)+integer(16,4)+fmt+Data("data".utf8)+integer(32000,4)+Data(repeating:0,count:32000);return Data("RIFF".utf8)+integer(UInt64(body.count),4)+body }
            func tags(_ title:String) -> Data {
                func size(_ value:Int) -> Data { Data((0..<4).map { UInt8((value >> ((3-$0)*7)) & 127) }) }
                var body = Data();for (id,text) in [("TIT2",title),("TPE1","Testinterpret"),("TLEN","7000")] { let payload = Data([3])+Data(text.utf8);body.append(Data(id.utf8)+size(payload.count)+Data([0,0])+payload) }
                return Data([0x49,0x44,0x33,4,0,0])+size(body.count)+body
            }
            do {
                await wait("initial listing") { !self.main.left.isLoading && !self.main.right.isLoading }
                let folder = FileSystem.canonical(root.appendingPathComponent("Links")),wave = folder.appendingPathComponent("01-Ton.wav"),audio = folder.appendingPathComponent("02-Lied.mp3"),picture = folder.appendingPathComponent("03-Bild.png"),plain = folder.appendingPathComponent("04-Text.txt"),link = folder.appendingPathComponent("05-Link.wav")
                try wav().write(to:wave);try tags("Künstlicher Titel").write(to:audio);try Data("Kein Medium".utf8).write(to:plain);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:wave)
                let pixels = Data(repeating:128,count:24),provider = require(CGDataProvider(data:pixels as CFData),"pixels"),image = require(CGImage(width:3,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:12,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent),"test image"),writer = require(CGImageDestinationCreateWithURL(picture as CFURL,"public.png" as CFString,1,nil),"image writer")
                CGImageDestinationAddImage(writer,image,nil);guard CGImageDestinationFinalize(writer) else { throw CommanderError.message("Künstliches Bild nicht gespeichert.") }
                let clipboard = NSPasteboard.general.changeCount,defaults = UserDefaults(suiteName:"local.zweicommander.app")!,saved = defaults.persistentDomain(forName:"local.zweicommander.app") ?? [:]
                self.main.left.refresh();await wait("synthetic files") { !self.main.left.isLoading && self.main.left.visibleEntries.contains(where:{ $0.name == wave.lastPathComponent }) };self.main.setActive(self.main.left);self.main.left.sortKey = "name";self.main.left.ascending = true;self.main.left.applyFilter();await wait("initial order") { !self.main.left.isSorting };await activate(self.main.window!);self.main.left.select([wave,audio]);self.main.window?.makeFirstResponder(self.main.left.table)
                let subscriberCache = PaneMediaMetadataCache(),subscriberEntry = try FileEntry(url:wave)
                var delivered:[Int] = [],subscriberDuration:Double?
                weak var obsoleteLifetime:MediaMetadataSmokeLifetime?
                do {
                    let lifetime = MediaMetadataSmokeLifetime();obsoleteLifetime = lifetime
                    _ = subscriberCache.request(subscriberEntry,generation:1,completion:{ [lifetime] _ in lifetime.touches += 1;delivered.append(-1) })
                }
                let oldSubscriberWasRetained = obsoleteLifetime != nil
                for index in 0..<64 {
                    _ = subscriberCache.request(subscriberEntry,generation:1,completion:{ value in delivered.append(index);if case .ready(let metadata) = value { subscriberDuration = metadata.duration } })
                }
                check(oldSubscriberWasRetained && obsoleteLifetime == nil,"replacing pending identity subscriptions releases obsolete closure lifetimes")
                await wait("newest identity subscriber") { delivered == [63] }
                check(subscriberDuration == 2 && delivered == [63],"64 synchronous requests notify the latest subscriber with one bounded callback")
                check(MediaMetadataField.allCases.allSatisfy { self.main.left.table.tableColumn(withIdentifier:.init($0.rawValue))?.isHidden == true },"all nine optional columns begin hidden")
                check(self.main.mediaMetadataCommandEnabled && self.main.mediaMetadataURLs == [wave,audio],"command freezes visible order of local regular selections")
                self.main.showMediaMetadata();let inspector = require(self.main.secondaryWindows.last as? MediaMetadataController,"inspector"),window = require(inspector.window as? WorkflowWindow,"workflow window");await activate(window);await wait("WAV result") { !inspector.isLoading }
                check(inspector.files == [wave,audio] && inspector.index == 0,"inspector retains a frozen ordered selection")
                check(inspector.metadata?.duration == 2 && inspector.error == nil,"WAV duration is shown from checked headers")
                check(inspector.rows.contains(where:{ $0.0 == "Album" && $0.1.contains("nicht im Dateikopf") }),"absent tags have an explicit missing-field label")
                check(!self.main.mediaMetadataCommandEnabled,"inspector does not dispatch commands to the obscured file pane")
                check(!inspector.previous.isEnabled && inspector.next.isEnabled,"file boundaries enable only valid navigation")
                check(window.performKeyEquivalent(with:key(window,String(UnicodeScalar(NSRightArrowFunctionKey)!),[.command,.option])),"Command Option Right navigates the frozen selection");await wait("ID3 result") { !inspector.isLoading }
                check(inspector.metadata?.title == "Künstlicher Titel" && inspector.metadata?.artist == "Testinterpret","ID3 Unicode title and artist are visible")
                check(inspector.metadata?.duration == 7 && inspector.metadata?.notes.contains(where:{ $0.contains("TLEN") }) == true,"declared MP3 duration identifies its tag source")
                check(inspector.previous.isEnabled && !inspector.next.isEnabled,"last-file navigation boundary is truthful")
                try tags("Neuer Titel").write(to:audio)
                check(window.performKeyEquivalent(with:key(window,"r",.command)),"Command R reloads current media headers");await wait("fresh title") { !inspector.isLoading }
                check(inspector.metadata?.title == "Neuer Titel","reload discards the old file identity and values")
                inspector.load();inspector.cancelRead();try? await Task.sleep(nanoseconds:150_000_000)
                check(!inspector.isLoading && inspector.metadata == nil && inspector.status.stringValue.contains("abgebrochen"),"cancelled reads cannot publish a late result")
                inspector.reload.performClick(nil);await wait("reload after cancellation") { !inspector.isLoading }
                check(inspector.metadata?.title == "Neuer Titel","explicit reload recovers after cancellation")
                check(window.performKeyEquivalent(with:key(window,String(UnicodeScalar(NSLeftArrowFunctionKey)!),[.command,.option])),"Command Option Left returns to the previous file");await wait("previous WAV") { !inspector.isLoading }
                check(inspector.metadata?.duration == 2,"file navigation resets all previous tag values")
                for (theme,name) in [(1,"Hell"),(2,"Dunkel")] { Preferences.state.theme = theme;self.main.applyTheme();try? await Task.sleep(nanoseconds:120_000_000);check(window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (theme == 1 ? .aqua : .darkAqua),"inspector follows "+name+" appearance");try capture(window,name) }
                check(inspector.limits.frame.maxY < inspector.status.frame.minY && inspector.source.frame.minY > inspector.previous.frame.maxY,"inspector controls and limit information do not overlap")
                inspector.load();inspector.close();try? await Task.sleep(nanoseconds:150_000_000)
                check(inspector.closed && inspector.metadata == nil && !inspector.isLoading,"closing discards pending reads and displayed values")
                let unsupported = MediaMetadataController(files:[plain]);self.main.secondaryWindows.append(unsupported);unsupported.showWindow(nil);await activate(unsupported.window!);await wait("unsupported file") { !unsupported.isLoading }
                check(unsupported.error != nil && unsupported.metadata == nil && unsupported.status.stringValue.contains("nicht verfügbar"),"unsupported files differ from supported files with absent tags");unsupported.close()
                let blocked = MediaMetadataController(files:[link]);self.main.secondaryWindows.append(blocked);blocked.showWindow(nil);await activate(blocked.window!);await wait("link refusal") { !blocked.isLoading }
                check(blocked.error != nil && blocked.metadata == nil,"symbolic links are refused rather than traversed");blocked.close()
                self.main.left.refresh();await wait("fresh metadata identities") { !self.main.left.isLoading };await activate(self.main.window!);self.main.left.select([wave]);self.main.window?.makeFirstResponder(self.main.left.table)
                let pane = self.main.left,column = require(pane.table.tableColumn(withIdentifier:.init("mediaDuration")),"duration column");column.isHidden = false;pane.table.reloadData()
                let row = require(pane.visibleEntries.firstIndex(where:{ $0.url == wave }),"WAV row"),columnIndex = pane.table.tableColumns.firstIndex(of:column)!
                @MainActor func currentCell(_ row:Int,_ column:Int) -> FileCellView? { pane.table.view(atColumn:column,row:row,makeIfNecessary:true) as? FileCellView }
                await wait("asynchronous media cell") { currentCell(row,columnIndex)?.textField?.stringValue == "0:00:02" }
                check(currentCell(row,columnIndex)?.toolTip?.contains("Dauer") == true,"visible media cells load asynchronously with explanatory help")
                check(Set(pane.selectedURLs) == [wave],"asynchronous cell updates preserve file selection")
                pane.sortKey = "mediaDuration";pane.applyFilter();await wait("metadata sorting") { !pane.isSorting }
                let waveIndex = require(pane.visibleEntries.firstIndex(where:{ $0.url == wave }),"sorted WAV"),audioIndex = require(pane.visibleEntries.firstIndex(where:{ $0.url == audio }),"sorted audio")
                check(waveIndex < audioIndex,"metadata duration sorting compares numeric values")
                check(Set(pane.selectedURLs) == [wave],"asynchronous metadata sorting preserves selected file identities")
                pane.sortKey = "mediaTitle";pane.applyFilter();pane.sortKey = "name";pane.applyFilter();await wait("latest sort") { !pane.isSorting }
                check(pane.visibleEntries.map(\.name) == FileSystem.sorted(pane.entries).map(\.name),"a later normal sort discards an obsolete metadata sort")
                let repeated = folder.appendingPathComponent("09-Wiederholt.wav");try wav().write(to:repeated);pane.refresh();await wait("repeated row listing") { !pane.isLoading && pane.visibleEntries.contains(where:{ $0.url == repeated }) }
                let repeatedRow = require(pane.visibleEntries.firstIndex(where:{ $0.url == repeated }),"repeated row")
                for field in MediaMetadataField.allCases { pane.table.tableColumn(withIdentifier:.init(field.rawValue))?.isHidden = false }
                let mediaColumns = pane.table.tableColumns.indices.filter { MediaMetadataField(rawValue:pane.table.tableColumns[$0].identifier.rawValue) != nil }
                for _ in 0..<8 { pane.table.reloadData();for column in mediaColumns { _ = currentCell(repeatedRow,column) } }
                await wait("current nine metadata cells") { mediaColumns.allSatisfy { guard let value = currentCell(repeatedRow,$0)?.textField?.stringValue else { return false };return !value.isEmpty && value != "…" } }
                check(currentCell(repeatedRow,columnIndex)?.textField?.stringValue == "0:00:02" && mediaColumns.count == 9,"eight nine-column reloads refresh every current metadata cell without stuck loading")
                let legacy = FolderViewSettings(columns:FolderViewSettings.baseColumnIDs.sorted().map { ViewColumn(id:$0,width:100,hidden:$0 != "name") });pane.applyView(legacy);await wait("legacy view") { !pane.isSorting }
                check(MediaMetadataField.allCases.allSatisfy { pane.table.tableColumn(withIdentifier:.init($0.rawValue))?.isHidden == true },"legacy eight-column views keep optional metadata hidden")
                self.main.window?.makeFirstResponder(pane.filterField);pane.filterField.selectText(nil)
                check(!self.main.mediaMetadataCommandEnabled,"text entry prevents file metadata commands from stealing input")
                self.main.window?.makeFirstResponder(pane.table);pane.select([link])
                check(!self.main.mediaMetadataCommandEnabled,"link selections disable the metadata menu command")
                pane.select([wave]);self.main.window?.makeFirstResponder(pane.table)
                let rename = RenameController(sources:[audio]);self.main.secondaryWindows.append(rename);rename.showWindow(nil);await activate(rename.window!);rename.window?.makeFirstResponder(rename.table);rename.pattern.stringValue = "{artist}-{title}";rename.prepare();await wait("media rename preview") { rename.preview?.rows.first?.targetName == "Testinterpret-Neuer Titel.mp3" }
                check(rename.preview?.canApply == true,"batch rename previews sanitized media tokens")
                check(rename.tokens.itemTitles.contains("{artist}") && rename.tokens.toolTip?.contains("120") == true,"rename token menu documents bounded metadata components")
                rename.pattern.stringValue = "{album}";rename.prepare();await wait("missing rename metadata") { rename.preview?.errorCount == 1 }
                check(rename.preview?.canApply == false,"missing rename metadata stays a row error without enabling changes");rename.close()
                check(try Data(contentsOf:wave) == wav() && (try MediaMetadataReader.read(audio).title) == "Neuer Titel","inspection and rename previews preserve original file bytes")
                check(NSPasteboard.general.changeCount == clipboard,"metadata UI leaves the user clipboard untouched")
                check((saved as NSDictionary).isEqual(to:defaults.persistentDomain(forName:"local.zweicommander.app") ?? [:]),"metadata tests do not persist personal user settings")
                print("MEDIA METADATA SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");fflush(stdout);exit(failures.isEmpty ? 0 : 1)
            } catch { print("MEDIA METADATA SMOKE FAIL "+error.localizedDescription);fflush(stdout);exit(1) }
        }
    }
}
