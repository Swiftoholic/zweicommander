import AppKit
import CommanderCore

extension AppDelegate {
    func runSettingsBackupSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            let suite = "local.zweicommander.tests."+UUID().uuidString
            guard let testDefaults = UserDefaults(suiteName:suite) else { print("SETTINGS BACKUP SMOKE FAIL temporary defaults");exit(1) }
            @MainActor func cleanup() { testDefaults.removePersistentDomain(forName:suite);_ = testDefaults.synchronize() }
            @MainActor func check(_ value:Bool,_ name:String) { checks += 1;print("SETTINGS BACKUP UI \(value ? "PASS" : "FAIL") "+name);if !value { failures.append(name);print("SETTINGS BACKUP UI CONTEXT active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none")") } }
            @MainActor func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("SETTINGS BACKUP SMOKE FAIL missing "+name);cleanup();exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async { for _ in 0..<500 { if predicate() { return };try? await Task.sleep(nanoseconds:30_000_000) };print("SETTINGS BACKUP SMOKE FAIL timeout "+name);cleanup();exit(1) }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active window") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func key(_ window:NSWindow,_ text:String,_ flags:NSEvent.ModifierFlags) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0),"native key") }
            @MainActor func capture(_ window:NSWindow,_ name:String) throws { let view = require(window.contentView,"view");view.layoutSubtreeIfNeeded();view.displayIfNeeded();let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap");view.cacheDisplay(in:view.bounds,to:bitmap);try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+"-Einstellungssicherung-"+name+".png")) }
            do {
                let personal = UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:],clipboard = NSPasteboard.general.changeCount,passwords = Preferences.remoteTestPasswords.values
                var state = SavedState();state.left = [SavedTab(path:root.appendingPathComponent("Links").path,title:"Synthetischer Tab",locked:false,view:FolderViewSettings(),selected:nil)];state.right = [SavedTab(path:root.appendingPathComponent("Rechts").path,title:nil,locked:false,view:nil,selected:nil)]
                let encoder = JSONEncoder(),stateData = try encoder.encode(state)
                let stores:[String:Data] = [SettingsBackupStores.state:stateData,SettingsBackupStores.beforeImport:stateData,"ZweiCommander.appearance.v1":try encoder.encode(AppearanceSettings()),"ZweiCommander.toolbar.v1":try encoder.encode(ToolbarSettings()),"ZweiCommander.workspace.v1":try WorkspaceLibrary().encoded(),"ZweiCommander.copyProfiles.v1":try CopyProfileLibrary().encoded(),"ZweiCommander.renameProfiles.v1":try RenameProfileLibrary().encoded(),"ZweiCommander.searchProfiles.v1":try SearchProfileLibrary().encoded(),"ZweiCommander.compareProfiles.v1":try CompareProfileLibrary().encoded(),"ZweiCommander.remoteProfiles.v1":try RemoteProfileLibrary().encoded(),"ZweiCommander.tabGroups.v1":try TabGroupLibrary().encoded(),"ZweiCommander.layouts.v1":try LayoutLibrary().encoded(),"ZweiCommander.lastLayout.v1":try WorkspaceLayout().encoded(),SettingsBackupStores.tools:Data(#"{"version":1,"tools":[]}"#.utf8)]
                var initial = stores.reduce(into:[String:Any]()) { $0[$1.key] = $1.value };initial["unowned"] = "preserve this value";testDefaults.setPersistentDomain(initial,forName:suite);_ = testDefaults.synchronize()
                let storage = SettingsBackupStorage(defaults:testDefaults,domainName:suite,rollbackDirectory:root.appendingPathComponent("Private-Sicherungen"),requiresRestart:false),document = try storage.exportDocument()
                check(document.stores.count == 14,"all fourteen own stores including external tools are exported")
                check(document.stores == stores,"export preserves every original payload byte")
                check(document.stores["unowned"] == nil,"unowned preferences do not enter exported settings")
                let source = root.appendingPathComponent("Sicherung.json"),empty = root.appendingPathComponent("Standard.json"),invalid = root.appendingPathComponent("Kaputt.json"),exported = root.appendingPathComponent("Exportiert.json")
                try SettingsBackupFile.writeNew(document.encoded(),to:source);try SettingsBackupFile.writeNew(SettingsBackupDocument(stores:[:]).encoded(),to:empty);try Data("{broken".utf8).write(to:invalid)
                var canRestore = true,receipt:SettingsBackupRestoreReceipt?,chosen = source
                let controller = SettingsBackupController(storage:storage,canRestore:{ canRestore });controller.fileChooser = { save in save ? exported : chosen };controller.onApplied = { receipt = $0 }
                self.main.secondaryWindows.append(controller);controller.showWindow(nil);let window = require(controller.window as? WorkflowWindow,"settings workflow");await activate(window)
                check(!controller.apply.isEnabled && controller.plan == nil,"fresh settings window cannot restore without a reviewed file")
                check(controller.privacy.stringValue.contains("Werkzeugargumente") && controller.privacy.stringValue.contains("Schlüsselbund"),"privacy text explains local paths and arguments and excluded keychain passwords")
                check(window.performKeyEquivalent(with:key(window,"l",.command)) && window.firstResponder is NSTextView,"Command L focuses the backup path editor")
                check(window.performKeyEquivalent(with:key(window,"l",[.command,.shift])),"Command Shift L opens the injected native file chooser")
                await wait("same-state review") { !controller.isReading && controller.plan != nil }
                check(controller.plan?.rows.count == 14 && controller.plan?.changedCount == 0,"unchanged backup lists all areas with no false changes")
                check(!controller.apply.isEnabled,"unchanged complete backup does not enable a no-op restore")
                window.makeFirstResponder(controller.file)
                let editor = require(controller.file.currentEditor() as? NSTextView,"backup path field editor");editor.insertText(source.path+"-changed",replacementRange:NSRange(location:0,length:editor.string.utf16.count))
                await wait("edited path invalidates preview") { controller.plan == nil }
                check(!controller.apply.isEnabled,"editing a backup path immediately invalidates its old executable preview")
                controller.choose.performClick(nil);await wait("chosen path replanned") { !controller.isReading && controller.plan != nil }
                check(controller.plan?.changedCount == 0,"choosing a file supersedes a pending path edit recheck")
                check(self.main.keyWorkflowWindow === window && !window.canPerformCommand("copy"),"settings workflow blocks commands to the obscured file pane")
                controller.save.performClick(nil)
                check(FileManager.default.fileExists(atPath:exported.path),"actual export button creates a local settings file")
                check(try storage.read(exported).stores == stores,"native export roundtrip retains all fourteen stores")
                let exportBytes = try Data(contentsOf:exported);controller.save.performClick(nil)
                check(try Data(contentsOf:exported) == exportBytes && controller.status.stringValue.contains("existiert bereits"),"existing export filenames remain intact with an actionable error")
                chosen = invalid;controller.choose.performClick(nil);await wait("invalid file") { !controller.isReading }
                check(controller.plan == nil && !controller.apply.isEnabled,"corrupt file discards the previous executable preview")
                check((try storage.exportDocument()).stores == stores,"corrupt backup preview cannot alter current settings")
                chosen = empty;controller.choose.performClick(nil);await wait("empty/default backup") { !controller.isReading && controller.plan != nil }
                check(controller.plan?.changedCount == 14 && controller.plan?.rows.allSatisfy { $0.change == .remove } == true,"empty valid backup explicitly previews resetting every stored area")
                controller.apply.performClick(nil);await wait("restore confirmation") { controller.confirmation != nil && window.attachedSheet != nil }
                check(controller.confirmation?.informativeText.contains("Neustart") == true,"restore requires a sheet that explains restart and saved prior state")
                controller.confirmation?.buttons[1].performClick(nil);await wait("cancelled sheet") { controller.confirmation == nil && window.attachedSheet == nil };await activate(window)
                check((try storage.exportDocument()).stores == stores && !controller.applied,"cancelling restore keeps every preference byte unchanged")
                var edited = initial;var appearance = AppearanceSettings();appearance.compact = false;edited["ZweiCommander.appearance.v1"] = try encoder.encode(appearance);edited.removeValue(forKey:"ZweiCommander.workspace.v1");edited["ZweiCommander.lastLayout.v1"] = "unreadable old type"
                testDefaults.setPersistentDomain(edited,forName:suite);_ = testDefaults.synchronize();chosen = source;controller.choose.performClick(nil);await wait("mixed changes") { !controller.isReading && controller.plan != nil }
                check(controller.plan?.rows.first(where:{ $0.key == "ZweiCommander.appearance.v1" })?.change == .replace,"review distinguishes replacement of existing settings")
                check(controller.plan?.rows.first(where:{ $0.key == "ZweiCommander.workspace.v1" })?.change == .add,"review distinguishes restoring an absent area")
                check(controller.plan?.rows.first(where:{ $0.key == "ZweiCommander.lastLayout.v1" })?.change == .repair,"review identifies unreadable existing preference types")
                check(controller.plan?.rows.filter { $0.change == .unchanged }.count == 11,"review retains unchanged areas in the same complete plan")
                canRestore = false;controller.requestRestore()
                check(controller.confirmation == nil && !controller.applied,"a newly started operation can block restore after preview")
                canRestore = true
                for (theme,name) in [(1,"Hell"),(2,"Dunkel")] {
                    Preferences.state.theme = theme;self.main.applyTheme();try? await Task.sleep(nanoseconds:120_000_000)
                    check(window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (theme == 1 ? .aqua : .darkAqua),"settings window follows "+name+" appearance");try capture(window,name)
                }
                check(controller.status.frame.maxY < controller.table.enclosingScrollView!.frame.minY && controller.privacy.frame.minY > controller.file.frame.maxY,"explanations and controls remain separate without overlapping table rows")
                // Change an owned store after preview: the confirmed restore must refuse it.
                var changedCopy = CopyProfileLibrary();_ = try changedCopy.save(name:"Neue Regel",filter:TransferFilter(),policy:.stop,mergeFolders:false);testDefaults.set(try changedCopy.encoded(),forKey:"ZweiCommander.copyProfiles.v1");_ = testDefaults.synchronize()
                controller.apply.performClick(nil);await wait("stale confirmation") { controller.confirmation != nil };controller.confirmation?.buttons[0].performClick(nil);await wait("stale restore rejected") { controller.confirmation == nil && !controller.isApplying }
                check(!controller.applied && controller.status.stringValue.contains("seit der Vorschau"),"a concurrent owned preference change invalidates the confirmed plan")
                check(testDefaults.data(forKey:"ZweiCommander.copyProfiles.v1") == (try changedCopy.encoded()),"stale restore preserves the newer profile bytes")
                // Repair the fixture's unreadable type, so the previous state is also importable as JSON.
                testDefaults.set(try WorkspaceLayout().encoded(),forKey:"ZweiCommander.lastLayout.v1");_ = testDefaults.synchronize();await activate(window)
                check(window.performKeyEquivalent(with:key(window,"r",.command)),"Command R rechecks the backup against current preferences")
                await wait("fresh restore plan") { !controller.isReading && controller.plan != nil }
                controller.apply.performClick(nil);await wait("fresh confirmation") { controller.confirmation != nil };controller.confirmation?.buttons[0].performClick(nil);await wait("applied restore") { controller.applied && !controller.isApplying }
                check(receipt != nil && controller.plan == nil && !controller.apply.isEnabled,"confirmed restore completes once and consumes the preview")
                check((try storage.exportDocument()).stores == stores,"confirmed restore reproduces all fourteen original setting stores")
                check(testDefaults.string(forKey:"unowned") == "preserve this value","whole-domain commit preserves unrelated user-default values")
                let previous = try storage.read(require(receipt,"receipt").rollbackURL)
                check(previous.stores["ZweiCommander.copyProfiles.v1"] == (try changedCopy.encoded()),"previous valid state remains a normal reviewable settings backup")
                check(previous.stores["ZweiCommander.workspace.v1"] == nil,"previous backup preserves absence as well as stored bytes")
                let rollbackFiles = try FileManager.default.contentsOfDirectory(at:storage.rollbackDirectory,includingPropertiesForKeys:nil)
                check(rollbackFiles.contains { $0.pathExtension == "plist" } && rollbackFiles.contains { $0.pathExtension == "json" },"exact private original and importable backup are both retained")
                check(rollbackFiles.allSatisfy { ((try? FileManager.default.attributesOfItem(atPath:$0.path)[.posixPermissions]) as? NSNumber)?.intValue == 0o600 },"retained previous-setting files are readable only by their owner")
                check(!SettingsBackupStorage.restartPending && !SettingsBackupStorage.isRestoring,"isolated settings tests never request a real application restart")
                check(controller.file.isEnabled == false && controller.save.isEnabled == false,"applied window cannot overwrite restored settings through another action")
                controller.close();await wait("closed workflow") { !window.isVisible }
                check(NSPasteboard.general.changeCount == clipboard,"settings backup leaves the user clipboard untouched")
                check(Preferences.remoteTestPasswords.values == passwords,"settings backup never reads or changes remote password storage")
                check((personal as NSDictionary).isEqual(to:UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:]),"personal application preferences remain byte-for-byte untouched")
                check(try Data(contentsOf:source) == document.encoded(),"review and restore do not modify the selected backup file")
                print("SETTINGS BACKUP SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");cleanup();fflush(stdout);exit(failures.isEmpty ? 0 : 1)
            } catch { print("SETTINGS BACKUP SMOKE FAIL "+error.localizedDescription);cleanup();fflush(stdout);exit(1) }
        }
    }
}
