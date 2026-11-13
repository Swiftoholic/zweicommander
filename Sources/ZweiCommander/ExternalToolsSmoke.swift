import AppKit
import CommanderCore

extension AppDelegate {
    func runExternalToolsSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            var cleanup:()->Void = {}
            @MainActor func check(_ value:Bool,_ name:String) { checks += 1;print("EXTERNAL TOOLS UI \(value ? "PASS" : "FAIL") "+name);if !value { failures.append(name);print("EXTERNAL TOOLS UI CONTEXT active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none") front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")") } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { cleanup();print("EXTERNAL TOOLS SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async { for _ in 0..<600 { if predicate() { return };try? await Task.sleep(nanoseconds:25_000_000) };cleanup();print("EXTERNAL TOOLS SMOKE FAIL timeout "+name);exit(1) }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active window") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func key(_ window:NSWindow,_ text:String,_ modifiers:NSEvent.ModifierFlags) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0),"key") }
            @MainActor func capture(_ window:NSWindow,_ name:String) throws { let view = require(window.contentView,"content");view.layoutSubtreeIfNeeded();view.displayIfNeeded();let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap");view.cacheDisplay(in:view.bounds,to:bitmap);try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+"-EigeneWerkzeuge-"+name+".png")) }
            func identity(_ url:URL) -> String { FileSystem.canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent).path }
            let suiteName = "local.zweicommander.tests.tools."+UUID().uuidString
            let defaults = require(UserDefaults(suiteName:suiteName),"test defaults")
            let previousDefaults = Preferences.externalToolsTestDefaults,normal = UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:],clipboard = NSPasteboard.general.changeCount
            Preferences.externalToolsTestDefaults = defaults
            cleanup = { defaults.removePersistentDomain(forName:suiteName);defaults.synchronize();Preferences.externalToolsTestDefaults = previousDefaults }
            do {
                await wait("initial listings") { !self.main.left.isLoading && !self.main.right.isLoading }
                let folder = FileSystem.canonical(root.appendingPathComponent("Links")),a = folder.appendingPathComponent("A Grüße.txt"),b = folder.appendingPathComponent("B.txt"),program = folder.appendingPathComponent("Tool.sh"),log = folder.appendingPathComponent("Calls.txt"),foreign = folder.appendingPathComponent("Never-created")
                try Data("A".utf8).write(to:a);try Data("B".utf8).write(to:b)
                try Data("#!/bin/sh\n/usr/bin/printf 'name=%s\\n' \"$1\" >> \"$2\"\n/usr/bin/printf '<%s>\\n' \"$@\"\n".utf8).write(to:program);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:program.path)
                let empty = try ExternalToolLibrary().encoded();defaults.set(empty,forKey:Preferences.externalToolsKey)
                check(try Preferences.externalToolLibrary().tools.isEmpty,"new tool store begins empty without legacy favorite migration")
                defaults.set(Data("{\"version\":9,\"tools\":[]}".utf8),forKey:Preferences.externalToolsKey)
                do { try Preferences.saveExternalTools(ExternalToolLibrary());check(false,"future tool store is protected") } catch { check(defaults.data(forKey:Preferences.externalToolsKey) != empty,"future tool store is protected") }
                defaults.set("unreadable",forKey:Preferences.externalToolsKey)
                do { _ = try Preferences.externalToolLibrary();check(false,"wrong typed tool store is preserved") } catch { check(defaults.string(forKey:Preferences.externalToolsKey) == "unreadable","wrong typed tool store is preserved") }
                defaults.set(empty,forKey:Preferences.externalToolsKey);self.main.left.refresh();await wait("tool fixture listing") { !self.main.left.isLoading && self.main.left.visibleEntries.contains { identity($0.url) == identity(a) } };self.main.left.sortKey = "name";self.main.left.ascending = true;self.main.left.applyFilter();await wait("tool fixture order") { !self.main.left.isSorting };self.main.setActive(self.main.left);await activate(self.main.window!);self.main.left.select([a,b]);self.main.window?.makeFirstResponder(self.main.left.table)
                check(self.main.externalToolContext()?.selection.count == 2,"local tool context freezes the ordered actual selection")
                self.main.showExternalTools();let manager = require(self.main.secondaryWindows.last as? ExternalToolsController,"manager"),managerWindow = require(manager.window,"manager window");manager.confirmDiscard = { true };await activate(managerWindow)
                check(manager.library.tools.isEmpty && !manager.preview.isEnabled,"empty manager has no accidental executable or preview")
                manager.add.performClick(nil);manager.save.performClick(nil)
                check((try Preferences.externalToolLibrary()).tools.isEmpty && manager.status.stringValue.contains("Ungültiges"),"new tool cannot be saved until a target is explicitly chosen")
                manager.titleField.stringValue = "Textwerkzeug";manager.categoryField.stringValue = "Prüfung";manager.targetField.stringValue = program.path;manager.arguments.string = ExternalToolArgumentLines.encode(["{name}",log.path,"two words","line\nbreak","; /usr/bin/touch "+foreign.path]);manager.perSelection.state = .on;manager.toolbar.state = .on;manager.slot.selectItem(at:2)
                check(managerWindow.performKeyEquivalent(with:key(managerWindow,"s",.command)),"Command S saves a tool through the native editor")
                let stored = try Preferences.externalToolLibrary(),tool = require(stored.tools.first,"saved tool")
                check(stored.tools.count == 1 && tool.category == "Prüfung" && tool.shortcutSlot == 2 && tool.perSelection && tool.showInToolbar,"category toolbar slot and separate arguments persist together")
                check(manager.titleField.visibleRect.height > 20 && manager.targetField.visibleRect.height > 20,"manager opens with name and target fields visible without scrolling")
                check(!FileSystem.exists(log) && !FileSystem.exists(foreign),"editing and saving launch no program and perform no argument expansion")
                check(self.main.externalToolDescriptors.contains { $0.id == tool.id && $0.slot == 2 && $0.showInToolbar && $0.enabled },"descriptor rendering exposes the configured tool without launching it")
                check(self.main.content.toolbar.arrangedSubviews.contains { $0.identifier?.rawValue == "externalTool:"+tool.id.uuidString },"saved tool appears in the real main toolbar")
                for (theme,name) in [(1,"Hell"),(2,"Dunkel")] { Preferences.state.theme = theme;self.main.applyTheme();try? await Task.sleep(nanoseconds:100_000_000);check(managerWindow.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (theme == 1 ? .aqua : .darkAqua),"tool manager follows "+name+" appearance");try capture(managerWindow,name) }
                manager.close();await activate(self.main.window!);self.main.window?.makeFirstResponder(self.main.left.table)
                check(self.main.externalToolSlotEnabled(2),"configured slot is enabled in a local file pane")
                self.main.window?.makeFirstResponder(self.main.left.filterField);check(!self.main.externalToolSlotEnabled(2),"typing blocks tool shortcuts from stealing input");self.main.window?.makeFirstResponder(self.main.left.table)
                self.main.launchExternalToolSlot(2);let launch = require(self.main.secondaryWindows.last as? ExternalToolLaunchController,"launcher");await activate(launch.window!);await wait("tool call preview") { !launch.isPreparing }
                check(launch.plan?.invocations.count == 2 && launch.start.isEnabled,"slot opens two reviewed per-selection invocations")
                check(launch.plan?.invocations.first?.arguments.contains("line\nbreak") == true && launch.text.string.contains("two words"),"preview retains individual quoted arguments and literal newlines")
                check(!FileSystem.exists(log) && !FileSystem.exists(foreign),"opening the preview does not execute arguments")
                check(self.main.keyWorkflowWindow === launch.window && !self.main.externalToolSlotEnabled(2),"preview isolates shortcuts from the obscured file pane")
                try Data("changed".utf8).write(to:a);launch.start.performClick(nil)
                check(launch.lastError != nil && !launch.isRunning && !FileSystem.exists(log),"changed selected file invalidates the preview before any process starts")
                launch.prepare();await wait("refreshed tool call") { !launch.isPreparing }
                check(launch.window!.performKeyEquivalent(with:key(launch.window!,"\r",.command)),"Command Return explicitly starts the reviewed executable job")
                await wait("two real tool calls") { launch.result != nil || launch.lastError != nil && !launch.isRunning }
                check(launch.result?.succeeded == true && launch.result?.completed == 2,"real queued executable completes both frozen invocations")
                let calls = try String(contentsOf:log,encoding:.utf8)
                check(calls == "name="+a.lastPathComponent+"\nname="+b.lastPathComponent+"\n","only the intended selected names reach the program in visible order")
                check(!FileSystem.exists(foreign),"shell-looking argument text never becomes a second command")
                check(launch.text.string.contains("ERGEBNIS") && !launch.start.isEnabled,"process output remains visible and a repeated run requires a fresh preview")
                launch.close();await activate(self.main.window!);self.main.window?.makeFirstResponder(self.main.left.table)
                self.main.launchExternalTool(tool.id);let stale = require(self.main.secondaryWindows.last as? ExternalToolLaunchController,"stale preview");await activate(stale.window!);await wait("stale definition preview") { !stale.isPreparing }
                var changed = stored;changed.tools[0].title = "Changed in another window";try Preferences.saveExternalTools(changed);stale.start.performClick(nil)
                let afterStale = try String(contentsOf:log,encoding:.utf8)
                check(stale.lastError?.contains("Werkzeugliste") == true && afterStale == calls,"edited library invalidates an already prepared invocation")
                stale.close();try Preferences.saveExternalTools(stored);await activate(self.main.window!);self.main.window?.makeFirstResponder(self.main.left.table)
                let gate = DispatchSemaphore(value:0),blocker = self.main.jobs.submit("Werkzeug-Prüfbarriere",work:{ token,_ in while gate.wait(timeout:.now()+0.025) != .success { try token.check() };return true },completion:{ _ in });defer { gate.signal() }
                await wait("queue barrier") { self.main.jobs.scheduler.snapshots.contains { $0.id == blocker && $0.state == .running } }
                self.main.launchExternalTool(tool.id);let queued = require(self.main.secondaryWindows.last as? ExternalToolLaunchController,"queued preview");await activate(queued.window!);await wait("queued preview") { !queued.isPreparing };queued.execute()
                let beforeQueuedStart = try String(contentsOf:log,encoding:.utf8)
                check(queued.isRunning && beforeQueuedStart == calls,"queued tool waits without executing behind an active operation")
                try Preferences.saveExternalTools(changed);gate.signal();await wait("queued definition rejection") { !queued.isRunning }
                let afterQueuedStart = try String(contentsOf:log,encoding:.utf8)
                check(queued.lastError?.contains("Werkzeugliste") == true && afterQueuedStart == calls,"library revalidation also runs after a queue wait")
                queued.close();try Preferences.saveExternalTools(stored);await activate(self.main.window!);self.main.window?.makeFirstResponder(self.main.left.table)
                self.main.showExternalTools();let conflict = require(self.main.secondaryWindows.last as? ExternalToolsController,"conflicting editor");conflict.confirmDiscard = { true };await activate(conflict.window!);try Preferences.saveExternalTools(changed);conflict.titleField.stringValue = "stale manager edit";conflict.saveLibrary()
                let afterConflict = try Preferences.externalToolLibrary()
                check(conflict.status.stringValue.contains("anderen Fenster") && afterConflict.tools[0].title == changed.tools[0].title,"manager save cannot overwrite another window's committed changes")
                conflict.close();try Preferences.saveExternalTools(stored)
                let app = folder.appendingPathComponent("Synthetic.app"),appExecutable = app.appendingPathComponent("Contents/MacOS/Tool");try FileManager.default.createDirectory(at:appExecutable.deletingLastPathComponent(),withIntermediateDirectories:true);try Data("#!/bin/sh\nexit 0\n".utf8).write(to:appExecutable);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:appExecutable.path)
                try PropertyListSerialization.data(fromPropertyList:["CFBundleExecutable":"Tool","CFBundleIdentifier":"local.zweicommander.synthetic.tool","CFBundlePackageType":"APPL"],format:.xml,options:0).write(to:app.appendingPathComponent("Contents/Info.plist"))
                let appTool = ExternalTool(title:"App fixture",kind:.application,target:app.path,arguments:["--argument","two words"],perSelection:true,opensSelection:true),context = ExternalToolContext(activeDirectory:folder,focused:a,selection:[a,b])
                let appLaunch = ExternalToolLaunchController(tool:appTool,context:context);self.main.secondaryWindows.append(appLaunch);appLaunch.showWindow(nil);await activate(appLaunch.window!);await wait("app preview") { !appLaunch.isPreparing };var documents:[[URL]] = [],appArguments:[[String]] = []
                appLaunch.onApplicationLaunch = { _,call,done in documents.append(call.documents);appArguments.append(call.arguments);done(nil) };appLaunch.execute();await wait("app launch boundary") { !appLaunch.isRunning }
                check(appLaunch.result?.completed == 2 && documents.map { $0.map(identity) } == [[identity(a)],[identity(b)]],"application boundary receives each frozen document separately")
                check(appArguments == [["--argument","two words"],["--argument","two words"]] && appLaunch.text.string.contains("von macOS verwaltet"),"application preview distinguishes document URLs arguments and system managed working directory")
                appLaunch.close();let expectedRaw = try Preferences.externalToolsSnapshot().raw;self.main.presentExternalTool(appTool,context:context,expectedRaw:expectedRaw);let delayed = require(self.main.secondaryWindows.last as? ExternalToolLaunchController,"delayed app");await activate(delayed.window!);await wait("delayed app preview") { !delayed.isPreparing };var callbacks:[(Error?)->Void] = []
                delayed.onApplicationLaunch = { _,_,done in callbacks.append(done) };delayed.execute();check(delayed.isLaunchingApplication && callbacks.count == 1,"pending app callback is tracked as application launch work")
                try Preferences.saveExternalTools(changed);callbacks[0](nil);await wait("late app definition validation") { !delayed.isRunning }
                check(delayed.result?.completed == 1 && delayed.result?.planned == 2 && delayed.result?.error?.contains("Werkzeugliste") == true && callbacks.count == 1,"a changed library stops later app callbacks and reports the confirmed partial count")
                delayed.close();try Preferences.saveExternalTools(stored)
                let cancelled = ExternalToolLaunchController(tool:appTool,context:context);self.main.secondaryWindows.append(cancelled);cancelled.showWindow(nil);await activate(cancelled.window!);await wait("cancel app preview") { !cancelled.isPreparing };var pending:[(Error?)->Void] = []
                cancelled.onApplicationLaunch = { _,_,done in pending.append(done) };cancelled.execute();cancelled.cancelRun();pending[0](nil);try? await Task.sleep(nanoseconds:100_000_000)
                check(!cancelled.isRunning && pending.count == 1 && cancelled.status.stringValue.contains("macOS"),"cancelling app dispatch suppresses late callbacks without claiming to stop launched apps")
                cancelled.close()
                check(NSPasteboard.general.changeCount == clipboard,"tool configuration and invocation checks preserve the general clipboard")
                check((normal as NSDictionary).isEqual(to:UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:]),"tool tests never persist personal settings")
                cleanup();print("EXTERNAL TOOLS SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");fflush(stdout);exit(failures.isEmpty ? 0 : 1)
            } catch { cleanup();print("EXTERNAL TOOLS SMOKE FAIL "+error.localizedDescription);fflush(stdout);exit(1) }
        }
    }
}
