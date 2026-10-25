import AppKit
import CommanderCore

extension AppDelegate {
    func runToolsIntegrationSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var count = 0,failures:[String] = []
            func check(_ okay:Bool,_ message:String) { count += 1;print("TOOLS INTEGRATION UI \(okay ? "PASS" : "FAIL") \(message)");if !okay { failures.append(message) } }
            func require<T>(_ value:T?,_ message:String) -> T { guard let value else { print("TOOLS INTEGRATION SMOKE FAIL missing "+message);exit(1) };return value }
            @MainActor func wait(_ name:String,_ condition:()->Bool) async {
                for _ in 0..<400 { if condition() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("TOOLS INTEGRATION SMOKE FAIL timeout "+name);exit(1)
            }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active window") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func settle() async { await wait("pane listings") { !self.main.left.isLoading && !self.main.right.isLoading && !self.main.left.isSorting && !self.main.right.isSorting } }
            @MainActor func item(_ id:String,_ menu:NSMenu? = nil) -> NSMenuItem? {
                for entry in (menu ?? NSApp.mainMenu)?.items ?? [] { if entry.representedObject as? String == id { return entry };if let submenu = entry.submenu,let found = item(id,submenu) { return found } };return nil
            }
            func identity(_ url:URL) -> URL { FileSystem.canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent) }
            func same(_ value:URL?,_ expected:URL) -> Bool { value.map { identity($0) == identity(expected) } ?? false }
            let main = self.main!,window = require(main.window,"main window"),left = main.left,right = main.right
            let savedShortcuts = Preferences.state.shortcuts,clipboard = NSPasteboard.general.changeCount
            defer { Preferences.state.shortcuts = savedShortcuts }
            do {
                let fixture = FileSystem.canonical(root)
                let a = fixture.appendingPathComponent("Links/a.txt"),b = fixture.appendingPathComponent("Links/b.txt"),c = fixture.appendingPathComponent("Rechts/c.txt"),folder = fixture.appendingPathComponent("Links/Folder"),link = fixture.appendingPathComponent("Links/alias.txt")
                try Data("first\n".utf8).write(to:a);try Data("second\n".utf8).write(to:b);try Data("third\n".utf8).write(to:c)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:a)
                main.refresh();await settle();await activate(window);left.focus()
                check(Self.resolvedShortcut("fileCompare",overrides:[:]) == "cmd+option+v","new file comparison has a dedicated default shortcut")
                let custom = ["move":"cmd+option+v"]
                check(Self.resolvedShortcut("fileCompare",overrides:custom).isEmpty && Self.resolvedShortcut("move",overrides:custom) == "cmd+option+v","new default preserves an existing user shortcut")
                check(Self.resolvedShortcut("fileCompare",overrides:["fileCompare":""]).isEmpty,"explicitly disabled file comparison stays disabled")
                check(Self.resolvedShortcut("fileCompare",overrides:["fileCompare":"cmd+ctrl+v"]) == "cmd+ctrl+v","explicit file comparison override is retained")
                check(try Self.shortcutOverrides("move=cmd+option+v")["move"] == "cmd+option+v","shortcut editor accepts a previous binding without stealing it")
                do { _ = try Self.shortcutOverrides("move=cmd+option+v\nfileCompare=cmd+option+v");check(false,"explicit duplicate shortcuts rejected") } catch { check(true,"explicit duplicate shortcuts rejected") }
                Preferences.state.shortcuts = custom;self.buildMenus()
                check(item("fileCompare")?.keyEquivalent.isEmpty == true && item("move")?.keyEquivalent == "v","actual menus keep the configured command on its key")
                check(CommandHelp.shortcut("fileCompare").isEmpty,"hover help follows the available shortcut")
                main.compare();let comparison = require(main.secondaryWindows.last as? CompareController,"folder comparison")
                main.search();let search = require(main.secondaryWindows.last as? SearchController,"search workspace")
                check(comparison.fileCompare.toolTip?.contains("⌘⌥V") == false && search.compareButton.toolTip?.contains("⌘⌥V") == false,"workspace buttons preserve disabled default shortcuts in their help")
                let searchWindow = require(search.window,"search window");await activate(searchWindow);search.editRoots()
                let roots = require(search.rootsController,"roots sheet"),rootsWindow = require(roots.window as? WorkflowWindow,"scoped roots window");await activate(rootsWindow)
                check(main.keyWorkflowWindow === rootsWindow && rootsWindow.sheetParent === searchWindow,"active workflow sheet is scoped before its non-workflow parent")
                check(!self.validateMenuItem(require(item("trash"),"trash menu")) && !self.validateMenuItem(require(item("move"),"move menu")),"root management cannot dispatch destructive commands to the hidden file pane")
                roots.cancel.performClick(nil);await wait("closed roots sheet") { searchWindow.attachedSheet == nil }
                Preferences.state.shortcuts = [:];self.buildMenus()
                check(comparison.fileCompare.toolTip?.contains("⌘⌥V") == true && search.compareButton.toolTip?.contains("⌘⌥V") == true,"open workspaces update shortcut help when menus are rebuilt")
                search.close();comparison.close();await activate(window);left.focus()
                @MainActor func select(_ pane:PaneView,_ urls:Set<URL>) {
                    let wanted = Set(urls.map(identity));pane.selectionIndexes = IndexSet(pane.visibleEntries.indices.filter { wanted.contains(identity(pane.visibleEntries[$0].url)) })
                }
                select(left,[a,b]);window.makeFirstResponder(left.table)
                check(same(main.fileComparisonURLs?.0,a) && same(main.fileComparisonURLs?.1,b),"two active-pane files use visible ordering")
                let compareItem = require(item("fileCompare"),"file compare menu")
                check(self.validateMenuItem(compareItem),"main menu enables a valid local file pair")
                window.makeFirstResponder(left.filterField);left.filterField.selectText(nil)
                check(main.fileComparisonURLs == nil && !self.validateMenuItem(compareItem),"text input keeps file comparison disabled")
                window.makeFirstResponder(left.table);select(left,[a]);select(right,[c]);right.focus()
                check(same(main.fileComparisonURLs?.0,a) && same(main.fileComparisonURLs?.1,c),"one file per side keeps left and right meanings")
                left.focus();select(left,[a,folder]);window.makeFirstResponder(left.table)
                check(main.fileComparisonURLs == nil,"directory selections are never treated as file pairs")
                select(left,[a,link]);check(main.fileComparisonURLs == nil,"linked selections are not silently followed")
                select(left,[a,b]);let before = main.secondaryWindows.count
                let event = require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.command,.option],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"v",charactersIgnoringModifiers:"v",isARepeat:false,keyCode:9),"key event")
                check(NSApp.mainMenu?.performKeyEquivalent(with:event) == true,"Command Option V dispatches through the actual menu")
                await wait("comparison opened") { main.secondaryWindows.count == before+1 && main.secondaryWindows.last?.window?.isVisible == true }
                let diff = require(main.secondaryWindows.last?.window,"comparison window");await activate(diff)
                check(main.keyWorkflowWindow === diff && !self.validateMenuItem(require(item("trash"),"trash menu")),"file comparison cannot act on an obscured file pane")
                diff.performClose(nil);await activate(window);left.focus()
                main.preview([a]);let viewer = require(main.secondaryWindows.last as? PreviewController,"viewer")
                check(viewer.url == a,"main pane preview receives the chosen file")
                viewer.close();await activate(window)
                check(try Data(contentsOf:a) == Data("first\n".utf8) && Data(contentsOf:b) == Data("second\n".utf8) && Data(contentsOf:c) == Data("third\n".utf8),"comparison and preview leave all source bytes unchanged")
                check(NSPasteboard.general.changeCount == clipboard,"combined workflows leave the user's clipboard unchanged")
                Preferences.state.shortcuts = savedShortcuts;self.buildMenus()
            } catch { check(false,error.localizedDescription) }
            print("TOOLS INTEGRATION SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(count) checks");fflush(stdout);exit(failures.isEmpty ? 0 : 1)
        }
    }
}
