import AppKit
import CommanderCore

extension AppDelegate {
    func runPackageIntegrationSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("PACKAGE INTEGRATION UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name);print("PACKAGE INTEGRATION UI CONTEXT active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none") front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")") } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("PACKAGE INTEGRATION SMOKE FAIL missing "+name);exit(1) };return value }
            func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<500 { if predicate() { return };try? await Task.sleep(nanoseconds:30_000_000) }
                print("PACKAGE INTEGRATION SMOKE FAIL timeout "+name);exit(1)
            }
            func activate(_ window:NSWindow) async {
                window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                await wait("active window") { NSApp.isActive && window.isKeyWindow }
            }
            func item(_ id:String) -> NSMenuItem? { NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.representedObject as? String == id } }
            func identity(_ url:URL) -> String { url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path }
            func select(_ url:URL) { self.main.left.selectionIndexes = IndexSet(self.main.left.visibleEntries.indices.filter { identity(self.main.left.visibleEntries[$0].url) == identity(url) });self.main.left.focus() }
            func key(_ window:NSWindow,_ value:String,_ flags:NSEvent.ModifierFlags) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:value,charactersIgnoringModifiers:value,isARepeat:false,keyCode:0),"native key") }
            let shortcuts = Preferences.state.shortcuts,clipboard = NSPasteboard.general.changeCount
            do {
                await wait("initial lists") { !self.main.left.isLoading && !self.main.right.isLoading }
                let left = root.appendingPathComponent("Links"),text = left.appendingPathComponent("Text.txt"),picture = left.appendingPathComponent("Bild.png"),archive = left.appendingPathComponent("Archiv.zip")
                try Data("synthetic archive contents\n".utf8).write(to:text)
                let bitmap = require(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:6,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:16,bitsPerPixel:32),"synthetic bitmap")
                for y in 0..<6 { for x in 0..<4 { bitmap.setColor(.systemBlue,atX:x,y:y) } }
                try require(bitmap.representation(using:.png,properties:[:]),"synthetic PNG").write(to:picture)
                try ArchiveService.pack([text],to:archive)
                let archiveBefore = try Data(contentsOf:archive),imageBefore = try Data(contentsOf:picture)
                self.main.left.refresh();await wait("fixture listing") { !self.main.left.isLoading && self.main.left.visibleEntries.contains { identity($0.url) == identity(archive) } }
                self.main.saveState()
                let stateBefore = try JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences.state)) as! [String:Any]
                Preferences.state.shortcuts = [:];self.buildMenus()
                check(AppDelegate.resolvedShortcut("archiveEdit") == "cmd+shift+e","archive editing has a discoverable default shortcut")
                check(AppDelegate.resolvedShortcut("mediaMetadata") == "cmd+option+i","media information has a discoverable default shortcut")
                check(try AppDelegate.shortcutOverrides("").isEmpty,"new defaults fit the existing complete shortcut map")
                let occupied = ["search":"cmd+shift+e","properties":"cmd+option+i"]
                check(AppDelegate.resolvedShortcut("archiveEdit",overrides:occupied).isEmpty && AppDelegate.resolvedShortcut("mediaMetadata",overrides:occupied).isEmpty,"new defaults yield to existing user bindings")
                check(AppDelegate.resolvedShortcut("search",overrides:occupied) == "cmd+shift+e" && AppDelegate.resolvedShortcut("properties",overrides:occupied) == "cmd+option+i","existing custom commands retain their exact bindings")
                check(AppDelegate.resolvedShortcut("archiveEdit",overrides:["archiveEdit":""]).isEmpty && AppDelegate.resolvedShortcut("mediaMetadata",overrides:["mediaMetadata":""]).isEmpty,"explicitly disabled new shortcuts stay disabled")
                check(AppDelegate.resolvedShortcut("archiveEdit",overrides:["archiveEdit":"cmd+ctrl+e"]) == "cmd+ctrl+e","an explicit archive shortcut is retained")
                do { _ = try AppDelegate.shortcutOverrides("archiveEdit=cmd+f");check(false,"duplicate explicit shortcut rejected") } catch { check(true,"duplicate explicit shortcut rejected") }
                Preferences.state.shortcuts = occupied;self.buildMenus()
                check(item("archiveEdit")?.keyEquivalent.isEmpty == true && item("mediaMetadata")?.keyEquivalent.isEmpty == true,"actual menus preserve occupied user shortcuts")
                check(CommandHelp.shortcut("archiveEdit").isEmpty && CommandHelp.shortcut("mediaMetadata").isEmpty,"hover help does not advertise unavailable shortcuts")
                Preferences.state.shortcuts = [:];self.buildMenus()
                let archiveItem = require(item("archiveEdit"),"archive edit menu"),metadataItem = require(item("mediaMetadata"),"metadata menu"),window = require(self.main.window,"main window")
                check(archiveItem.keyEquivalent == "E" && archiveItem.keyEquivalentModifierMask == [.command,.shift],"archive menu installs the native shifted key equivalent")
                check(metadataItem.keyEquivalent == "i" && metadataItem.keyEquivalentModifierMask == [.command,.option],"metadata menu installs the native key equivalent")
                await activate(window);select(picture);window.makeFirstResponder(self.main.left.table)
                check(self.validateMenuItem(metadataItem),"a current local regular file enables media information")
                window.makeFirstResponder(self.main.left.filterField);self.main.left.filterField.selectText(nil)
                check(!self.validateMenuItem(metadataItem) && !self.validateMenuItem(archiveItem),"editing text blocks new file actions")
                window.makeFirstResponder(self.main.left.table)
                let beforeMetadata = self.main.secondaryWindows.count
                check(NSApp.mainMenu?.performKeyEquivalent(with:key(window,"i",[.command,.option])) == true,"Command Option I dispatches through the real menu")
                await wait("metadata window") { self.main.secondaryWindows.count == beforeMetadata+1 && self.main.secondaryWindows.last?.window?.isVisible == true }
                let inspector = require(self.main.secondaryWindows.last,"metadata controller"),inspectorWindow = require(inspector.window,"metadata window")
                await activate(inspectorWindow)
                check(self.main.keyWorkflowWindow === inspectorWindow && !self.validateMenuItem(archiveItem) && !self.validateMenuItem(require(item("trash"),"trash menu")),"media information cannot act on the obscured file pane")
                inspector.close();await activate(window);select(archive);window.makeFirstResponder(self.main.left.table)
                check(self.validateMenuItem(archiveItem),"a selected local archive enables archive editing")
                let beforeArchive = self.main.secondaryWindows.count
                check(NSApp.mainMenu?.performKeyEquivalent(with:key(window,"E",[.command,.shift])) == true,"Command Shift E dispatches through the real menu")
                await wait("archive editor") { self.main.secondaryWindows.count == beforeArchive+1 && self.main.secondaryWindows.last?.window?.isVisible == true }
                let editor = require(self.main.secondaryWindows.last,"archive editor"),editorWindow = require(editor.window,"archive editor window")
                await activate(editorWindow)
                check(self.main.keyWorkflowWindow === editorWindow && !self.validateMenuItem(metadataItem) && !self.validateMenuItem(require(item("move"),"move menu")),"archive editing cannot dispatch commands to the hidden pane")
                editor.close();await activate(window)
                final class CloseGate:NSObject,NSWindowDelegate {
                    var allow = false,requests = 0
                    func windowShouldClose(_ sender:NSWindow) -> Bool { requests += 1;return allow }
                }
                let gate = CloseGate(),sheet = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:360,height:140),styleMask:[.titled,.closable],backing:.buffered,defer:false)
                sheet.isReleasedWhenClosed = false;sheet.delegate = gate;window.beginSheet(sheet,completionHandler:{ _ in });await activate(sheet)
                sheet.performClose(nil)
                check(window.attachedSheet === sheet && gate.requests == 1,"native sheet close respects a delegate that refuses closing")
                gate.allow = true;sheet.performClose(nil);await wait("native sheet closed") { window.attachedSheet == nil }
                check(gate.requests == 2 && !sheet.isVisible,"native sheet close ends the sheet when its delegate allows closing")
                await activate(window)
                self.main.compare();let comparison = require(self.main.secondaryWindows.last as? CompareController,"comparison controller")
                check(comparison.onSubmitMirror != nil && comparison.onSubmit != nil && comparison.onCancel != nil,"copy synchronization and mirroring share the actual queue and cancellation hooks")
                await activate(require(comparison.window,"comparison window"))
                check(!self.validateMenuItem(archiveItem) && !self.validateMenuItem(metadataItem),"folder comparison keeps the new file commands scoped")
                comparison.close();await activate(window)
                check(try Data(contentsOf:archive) == archiveBefore && Data(contentsOf:picture) == imageBefore && Data(contentsOf:text) == Data("synthetic archive contents\n".utf8),"read-only inspection and unopened edit plans preserve all fixture bytes")
                check(NSPasteboard.general.changeCount == clipboard,"integrated workflows leave the user's general clipboard untouched")
                let stateAfter = try JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences.state)) as! [String:Any]
                check((stateBefore["left"] as? NSArray) == (stateAfter["left"] as? NSArray) && (stateBefore["right"] as? NSArray) == (stateAfter["right"] as? NSArray),"new workspaces preserve saved pane tabs")
            } catch { check(false,error.localizedDescription) }
            Preferences.state.shortcuts = shortcuts;self.buildMenus()
            print("PACKAGE INTEGRATION SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");fflush(stdout);exit(failures.isEmpty ? 0 : 1)
        }
    }
}
