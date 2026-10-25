import AppKit
import CommanderCore

extension AppDelegate {
    func runAdvancedSearchSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("ADVANCED SEARCH UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("ADVANCED SEARCH SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ value:()->Bool) async {
                for _ in 0..<1000 { if value() { return };try? await Task.sleep(nanoseconds:20_000_000) }
                print("ADVANCED SEARCH SMOKE FAIL timeout "+name+" active=\(NSApp.isActive)");exit(1)
            }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active window") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func key(_ window:NSWindow,_ text:String,_ flags:NSEvent.ModifierFlags = []) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0),"event") }
            @MainActor func search(_ controller:SearchController) async { controller.beginSearch();await wait("search result") { !controller.isSearching && controller.report != nil } }
            @MainActor func capture(_ window:NSWindow,_ suffix:String) throws {
                let view = require(window.contentView,"root view");view.layoutSubtreeIfNeeded();view.displayIfNeeded();let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap");view.cacheDisplay(in:view.bounds,to:bitmap)
                try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+suffix+".png"))
            }
            func write(_ url:URL,_ text:String) throws { try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(text.utf8).write(to:url) }
            do {
                let left = root.appendingPathComponent("Links/Suchort; Eins"),right = root.appendingPathComponent("Rechts/Zweiter Ort"),deep = left.appendingPathComponent("Unterordner")
                try write(left.appendingPathComponent("A.txt"),"Grüße Projekt 42\n");try write(left.appendingPathComponent("B.txt"),"Ohne Kennzahl\n");try write(deep.appendingPathComponent("Deep.txt"),"Projekt 73\n");try write(right.appendingPathComponent("C.txt"),"Projekt 99\n")
                try Data([0,0xFF,0x2A,1]).write(to:right.appendingPathComponent("Bytes.bin"));try Data([0xAA,0xBB,0xCC]).write(to:right.appendingPathComponent("Other.bin"))
                let clipboard = NSPasteboard.general.changeCount,controller = SearchController(root:left)
                main.secondaryWindows.append(controller);controller.showWindow(nil);let window = require(controller.window as? SearchWorkspaceWindow,"search window");await activate(window)
                check(controller.allHits.isEmpty && !controller.isSearching,"advanced workspace opens without running a search")
                check(controller.contentMode.numberOfItems == 3 && controller.contentNegated.state == .off,"native content modes distinguish literal regex and hex")
                check(controller.content.toolTip?.contains("100 ms") == true && controller.maximumDepth.toolTip?.contains("0:") == true,"limits and depth semantics are visible in help")
                try controller.setRoots([left,right]);check(try controller.currentRoots().count == 2 && controller.rootsButton.title.contains("2"),"multiple roots are separate URL values despite punctuation in a path")
                check(window.performKeyEquivalent(with:key(window,"l",[.command,.shift])),"Command Shift L opens root management")
                let form = require(controller.rootsController,"root manager"),formWindow = require(form.window as? WorkflowWindow,"root manager window");await activate(formWindow)
                check(window.attachedSheet === formWindow && form.roots.count == 2,"root manager is a native scoped sheet")
                form.candidate.stringValue = left.path;form.add.performClick(nil);check(form.roots.count == 2,"duplicate root is deduplicated without splitting a semicolon path")
                form.candidate.stringValue = root.appendingPathComponent("Missing").path;form.add.performClick(nil)
                check(form.info.textColor == .systemRed && form.roots.count == 2,"missing root stays inline without changing accepted roots")
                form.candidate.stringValue = deep.path;form.add.performClick(nil);check(form.roots.count == 3,"explicit deeper root is retained for bounded searches")
                let deepRow = require(form.roots.firstIndex { FileSystem.canonical($0) == FileSystem.canonical(deep) },"deeper root row");form.table.selectRowIndexes(IndexSet(integer:deepRow),byExtendingSelection:false);form.remove.performClick(nil)
                check(form.roots.count == 2,"removing a root only edits the search list")
                check(formWindow.performKeyEquivalent(with:key(formWindow,"\r",.command)),"Command Return applies the root list")
                await wait("closed roots") { window.attachedSheet == nil };await activate(window)
                check(try controller.currentRoots().count == 2,"accepted root list stays separate from search rules")
                check(window.performKeyEquivalent(with:key(window,"l",.command)) && controller.rootPath.currentEditor() != nil,"Command L focuses the primary root editor")
                check(window.performKeyEquivalent(with:key(window,"f",[.command,.option])) && controller.content.currentEditor() != nil,"Command Option F focuses the content query")
                check(window.performKeyEquivalent(with:key(window,"2",.command)) && controller.contentMode.indexOfSelectedItem == 1 && !controller.wholeWords.isEnabled,"Command 2 selects regex with explicit word-boundary semantics")
                controller.content.stringValue = "Projekt\\s+\\d+";controller.kind.selectItem(at:1)
                check(window.performKeyEquivalent(with:key(window,"\r",.command)),"Command Return starts the multi-root search")
                await wait("regex results") { !controller.isSearching && controller.report != nil }
                check(Set(controller.allHits.map(\.name)) == ["A.txt","Deep.txt","C.txt"],"regex searches both roots and nested content")
                check(Set(controller.allHits.map(\.id)).count == 3 && controller.allHits.allSatisfy { $0.snippet.contains("Projekt") },"results keep distinct identities and actual snippets")
                check(window.subtitle.contains("2 Suchorte"),"workspace identifies the combined root set")
                controller.maximumDepth.stringValue = "0";await search(controller)
                check(Set(controller.allHits.map(\.name)) == ["A.txt","C.txt"],"depth zero searches direct entries in each root")
                controller.table.selectAll(nil);var compared:(URL,URL)?;controller.onFileCompare = { compared = ($0,$1) }
                check(controller.compareButton.isEnabled && controller.canPerformCommand("fileCompare"),"two regular local results enable file comparison")
                await activate(window);check(window.performKeyEquivalent(with:key(window,"d",[.command,.option])) && compared != nil,"comparison keyboard action uses the two selected results")
                controller.content.stringValue = "[";controller.beginSearch()
                check(!controller.isSearching && controller.info.textColor == .systemRed && controller.allHits.count == 2,"invalid regex preserves earlier results with inline error")
                check(window.performKeyEquivalent(with:key(window,"3",.command)) && !controller.encoding.isEnabled && controller.office.state == .off,"Command 3 selects raw hex and excludes text conversion")
                controller.name.stringValue = "*.bin";controller.content.stringValue = "00 FF 2A";controller.maximumDepth.stringValue = "";await search(controller)
                check(controller.allHits.map(\.name) == ["Bytes.bin"] && controller.allHits[0].snippet.contains("Byteoffset 0"),"hex query reads actual zero and high bytes")
                controller.contentNegated.performClick(nil);await search(controller)
                check(controller.allHits.map(\.name) == ["Other.bin"] && controller.allHits[0].snippet.contains("nicht enthalten"),"negated hex returns only fully examined nonmatching files")
                controller.maximumDepth.stringValue = "1";controller.edited();controller.profileSaveAs.performClick(nil)
                let naming = require(controller.profileNameWindow,"profile name sheet");naming.name.stringValue = "Mehrere Orte und Hex";naming.save.performClick(nil)
                await wait("closed profile sheet") { window.attachedSheet == nil };await activate(window)
                let library = try Preferences.searchProfiles(),data = try library.encoded(),document = try JSONSerialization.jsonObject(with:data) as! [String:Any]
                check(document["version"] as? Int == 2 && library.profiles.count == 1,"advanced profile uses explicit document version two")
                check(library.profiles[0].options == (try controller.options()),"profile preserves mode negation depth and existing rules")
                check(!String(decoding:data,as:UTF8.self).contains(left.path) && !String(decoding:data,as:UTF8.self).contains(right.path),"profile excludes all search locations")
                controller.setOptions(SearchOptions());let profileIndex = require(controller.profilePopup.itemArray.firstIndex { $0.title == "Mehrere Orte und Hex" },"saved profile")
                controller.profilePopup.selectItem(at:profileIndex);controller.chooseProfile()
                check(controller.contentMode.indexOfSelectedItem == 2 && controller.contentNegated.state == .on && controller.maximumDepth.stringValue == "1","native profile reload restores advanced controls")
                check(try controller.currentRoots().count == 2,"loading rules leaves the chosen root list intact")
                controller.editRoots();let empty = require(controller.rootsController,"second root manager"),emptyWindow = require(empty.window,"second root window");await activate(emptyWindow)
                empty.table.selectAll(nil);empty.remove.performClick(nil);check(empty.roots.isEmpty && !empty.apply.isEnabled,"an empty root list cannot be applied")
                empty.cancel.performClick(nil);await wait("cancelled empty list") { window.attachedSheet == nil };check(try controller.currentRoots().count == 2,"cancelling root changes preserves both locations")
                for (mode,suffix) in [(1,"Hell"),(2,"Dunkel")] {
                    Preferences.state.theme = mode;main.applyTheme();try? await Task.sleep(nanoseconds:150_000_000)
                    check(window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (mode == 1 ? .aqua : .darkAqua),"advanced workspace follows "+suffix+" appearance");try capture(window,"-Erweiterte-Suche-"+suffix)
                }
                check(controller.rootPath.frame.maxX < controller.chooseRoot.frame.minX && controller.contentMode.frame.maxX < controller.content.frame.minX && controller.contentNegated.frame.maxX < controller.maximumDepth.frame.minX,"advanced controls have separate readable frames")
                for index in 0..<160 { try write(left.appendingPathComponent("Abbruch/\(index).cancel"),"stopmarker") }
                var cancelOptions = SearchOptions();cancelOptions.name = "*.cancel";cancelOptions.content = "stopmarker";cancelOptions.kind = .files;controller.setOptions(cancelOptions)
                var streamed = false,protected = false
                controller.onResultsChanged = { if !streamed && !controller.allHits.isEmpty { streamed = true;protected = !controller.start.isEnabled && controller.stop.isEnabled && !self.main.canTerminate;controller.cancelSearch() } }
                await search(controller);controller.onResultsChanged = nil
                check(streamed && protected,"streamed advanced search freezes rules and protects running work")
                check(controller.report?.cancelled == true && !controller.allHits.isEmpty && controller.allHits.count < 160,"cancel retains a bounded partial result list")
                check(try FileManager.default.contentsOfDirectory(atPath:left.appendingPathComponent("Abbruch").path).count == 160,"cancelling search changes no source files")
                check(NSPasteboard.general.changeCount == clipboard,"advanced checks leave the user's clipboard untouched")
                controller.close()
                if failures.isEmpty { print("ADVANCED SEARCH SMOKE PASS \(checks) checks");exit(0) };print("ADVANCED SEARCH SMOKE FAIL \(checks) checks");exit(1)
            } catch { print("ADVANCED SEARCH SMOKE FAIL "+error.localizedDescription);exit(1) }
        }
    }
}
