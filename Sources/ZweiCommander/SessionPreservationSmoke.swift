import AppKit
import CommanderCore

extension AppDelegate {
    /// Synthetic defaults only. The harness enables testMode before MainWindow exists.
    func runSessionPreservationSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            let suite = "local.zweicommander.tests."+UUID().uuidString
            guard Preferences.testMode,let defaults = UserDefaults(suiteName:suite) else { print("SESSION PRESERVATION SMOKE FAIL isolated defaults");exit(1) }
            let oldState = Preferences.state,oldPrimary = Preferences.primaryTestDefaults,oldWorkspace = Preferences.workspaceTestDefaults,oldLayout = Preferences.layoutTestDefaults
            let personal = UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:],clipboard = NSPasteboard.general.changeCount,passwords = Preferences.remoteTestPasswords.values
            @MainActor func cleanup() {
                Preferences.primaryTestDefaults = oldPrimary;Preferences.workspaceTestDefaults = oldWorkspace;Preferences.layoutTestDefaults = oldLayout
                _ = Preferences.load();Preferences.state = oldState
                defaults.removePersistentDomain(forName:suite);_ = defaults.synchronize()
            }
            @MainActor func check(_ value:Bool,_ name:String) { checks += 1;print("SESSION PRESERVATION UI \(value ? "PASS" : "FAIL") "+name);if !value { failures.append(name) } }
            @MainActor func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("SESSION PRESERVATION SMOKE FAIL missing "+name);cleanup();exit(1) };return value }
            @MainActor func bytes() -> Data { require(defaults.data(forKey:SettingsBackupStores.state),"saved session") }
            @MainActor func tree() throws -> [String:SessionJSON] { require(try SessionJSON.parse(bytes()).fields,"saved root") }
            @MainActor func retained(_ id:String) throws -> [String:SessionJSON] {
                let root = try tree(),all = (root["left"]?.elements ?? [])+(root["right"]?.elements ?? [])
                return require(all.first { (try? $0.fields?["futureID"]?.decoded(String.self)) == id }?.fields,"retained tab")
            }
            do {
                let a = root.appendingPathComponent("Sitzung A"),b = root.appendingPathComponent("Sitzung B")
                try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:b,withIntermediateDirectories:true)
                var state = SavedState();state.left = [SavedTab(path:a.path,title:"Erster",locked:false,view:nil,selected:nil),SavedTab(path:a.path,title:"Zweiter",locked:true,view:nil,selected:true),SavedTab(path:b.path,title:nil,locked:false,view:nil,selected:nil)]
                state.right = [SavedTab(path:b.path,title:nil,locked:false,view:nil,selected:nil)]
                var fixture = try SessionJSON.parse(state.encoded()).fields!,tabs = fixture["left"]!.elements!
                var first = tabs[0].fields!;first["view"] = try SessionJSON.parse(Data(#"{"display":"future-mode","sortKey":"future-field"}"#.utf8));first["lockMode"] = try SessionJSON.parse(Data(#""future-mode""#.utf8))
                first["filter"] = try SessionJSON.parse(Data(#"["future-filter"]"#.utf8));first["filterRegex"] = try SessionJSON.parse(Data(#""automatic""#.utf8));first["selected"] = try SessionJSON.parse(Data(#"{"future":true}"#.utf8));first["futureID"] = try SessionJSON.parse(Data(#""first""#.utf8));tabs[0] = .object(first)
                var second = tabs[1].fields!;second["lockMode"] = try SessionJSON.parse(Data(#""future-protected""#.utf8));second["futureID"] = try SessionJSON.parse(Data(#""second""#.utf8));tabs[1] = .object(second)
                fixture["left"] = .array(tabs);fixture["futureSession"] = try SessionJSON.parse(Data(#"{"number":12345678901234567890123456789012345678901234567890,"mode":"later"}"#.utf8))
                let original = try SessionJSON.object(fixture).encoded();defaults.set(original,forKey:SettingsBackupStores.state)
                Preferences.primaryTestDefaults = defaults;Preferences.workspaceTestDefaults = defaults;Preferences.layoutTestDefaults = defaults;Preferences.state = Preferences.load()
                let pane = main.left,other = main.right,restored = PaneView(url:a,savedTabs:Preferences.state.left),restoredRight = PaneView(url:b,savedTabs:Preferences.state.right)
                pane.tabs = restored.tabs;pane.tabIndex = restored.tabIndex;other.tabs = restoredRight.tabs;other.tabIndex = restoredRight.tabIndex
                pane.restoreTabView();other.restoreTabView();pane.rebuildTabs();other.rebuildTabs()
                check(pane.tabs.count == 3 && pane.tab.title == "Zweiter","future session keeps duplicate paths order and usable selected tab")
                check(pane.tabs[1].lockMode == .newTab && pane.tabs[0].lockMode == .none,"unknown lock modes retain the legacy protective fallback")
                check(pane.tabs[0].view == nil && pane.tabs[0].filter.isEmpty,"unsupported view and filter use compatible local fallback")
                main.saveState();let rootAfter = try tree(),firstAfter = try retained("first")
                check(rootAfter["futureSession"] == fixture["futureSession"],"actual Main saveState preserves unknown root values and exact large numbers")
                for key in ["view","lockMode","filter","filterRegex","selected"] { check(firstAfter[key] == first[key],"ordinary native autosave preserves unsupported "+key) }
                check(main.content.status.stringValue.contains("bleiben erhalten"),"main window explains compatible preservation instead of silently dropping options")
                let unchangedReload = Preferences.load(),unchangedPane = PaneView(url:a,savedTabs:unchangedReload.left)
                check(unchangedPane.tabs.count == 3 && unchangedPane.tab.title == "Zweiter" && unchangedPane.tabs[0].view == nil,"a fresh native pane reloads the compatible fallback and selected tab")
                check(try unchangedReload.left[0].sessionJSON().fields?["view"] == first["view"],"ordinary save and reload preserve the unsupported view subtree")
                Preferences.state.theme = 2;Preferences.state.showHidden = true;main.saveState()
                check(try tree()["theme"]?.decoded(Int.self) == 2 && tree()["showHidden"]?.decoded(Bool.self) == true,"unrelated supported appearance settings remain mutable")
                let firstTab = pane.tabs[0];pane.moveTab(firstTab.id,to:2);main.saveState()
                check(try retained("first")["view"] == first["view"] && retained("second")["lockMode"] == second["lockMode"],"reordering identical paths cannot exchange their opaque fields")
                pane.selectTab(firstTab.id);pane.closeTab(firstTab.id);check(!pane.tabs.contains { $0 === firstTab },"compatible unlocked tab can close normally")
                check(pane.reopenLastTab() && pane.tab === firstTab,"closed native tab reopens with the same retained context")
                main.saveState();check(try retained("first")["view"] == first["view"],"explicit close and reopen retain unsupported view while applying the chosen tab selection")
                let copy = firstTab.copyForSession();other.tabs.append(copy);main.saveState()
                let right = try tree()["right"]!.elements!
                check(right.contains { $0.fields?["futureID"] == first["futureID"] && $0.fields?["view"] == first["view"] },"cross-pane session copy carries its own opaque context")
                other.tabs.removeAll { $0 === copy }
                pane.changeDisplay(.icons);main.saveState()
                check(try retained("first")["view"]?.fields?["display"]?.decoded(String.self) == "icons","explicit native display change replaces the unsupported view")
                check(try retained("first")["lockMode"] == first["lockMode"],"view edit leaves unrelated unknown lock option intact")
                pane.setTabLock(.fixed);pane.filterField.stringValue = "*.txt";pane.filterRegex.state = .off;pane.filterChanged();main.saveState()
                check(try retained("first")["lockMode"]?.decoded(String.self) == "fixed","explicit native lock edit replaces unknown lock mode")
                check(try retained("first")["filter"]?.decoded(String.self) == "*.txt" && retained("first")["filterRegex"] == nil,"explicit native filter edit replaces unsupported filter options")
                pane.selectTab(pane.tabs.first { $0 !== firstTab }!.id,explicit:true);main.saveState()
                check(try retained("first")["selected"] == nil,"explicit user tab choice replaces unknown selection marker")
                Preferences.state = Preferences.load();let fresh = PaneView(url:a,savedTabs:Preferences.state.left)
                check(fresh.tabs.contains { $0.title == "Erster" && $0.lockMode == .fixed && $0.view?.display == .icons && $0.filter == "*.txt" },"fresh native pane loads supported edits from the persisted session")
                check(try tree()["futureSession"] == fixture["futureSession"],"reloading session keeps unrelated future root data")
                var protected = first;protected["locked"] = try SessionJSON.parse(Data("true".utf8));protected["futureID"] = try SessionJSON.parse(Data(#""workspace""#.utf8))
                var workspaceFixture = fixture;workspaceFixture["left"] = .array([.object(protected)])
                let protectedState = try SavedState.decode(SessionJSON.object(workspaceFixture).encoded()),protectedPane = PaneView(url:a,savedTabs:protectedState.left)
                pane.tabs = protectedPane.tabs;pane.tabIndex = 0;pane.restoreTabView();let protectedTab = pane.tab
                let profile = LayoutProfile(name:"Kompatibel",left:LayoutPane(tabs:[LayoutTab(path:a.path,title:"Arbeitsbereich",lockMode:.none,view:FolderViewSettings(display:.thumbnails),filter:"*.md")],selected:0),right:LayoutPane(tabs:[LayoutTab(path:b.path)],selected:0),layout:main.layoutState)
                try main.applyWorkspace(profile,geometry:false);main.saveState()
                check(pane.tab === protectedTab && pane.tab.lockMode == .newTab,"explicit workspace reuses an existing protected tab and retains its lock")
                check(try retained("workspace")["view"]?.fields?["display"]?.decoded(String.self) == "thumbnails" && retained("workspace")["filter"]?.decoded(String.self) == "*.md","explicit workspace view and filter edits persist over unsupported old options")
                check(try retained("workspace")["lockMode"] == first["lockMode"],"workspace reuse preserves the unrelated unsupported protected lock mode")
                let profileSettings = try INISettingsImport.parse(main:Data("[Form]\nFontSize=12\n".utf8))
                let preImportPane = PaneView(url:a,savedTabs:protectedState.left);pane.tabs = preImportPane.tabs;pane.tabIndex = 0;pane.restoreTabView();main.saveState()
                main.applySettingsProfile(profileSettings);main.saveState()
                check(try retained("workspace")["view"]?.fields?["sortKey"]?.decoded(String.self) != "future-field","explicit INI import persists its supported view over the old unsupported view")
                main.restoreBeforeSettingsImport();main.saveState()
                check(try retained("workspace")["view"] == first["view"],"pre-import recovery restores the exact old opaque native tab view")
                let beforeAmbiguous = bytes()
                do { _ = try pane.prepareSessionViewRecovery(protectedState.left+protectedState.left);check(false,"ambiguous old opaque views cannot be assigned by guess") }
                catch { check(bytes() == beforeAmbiguous,"ambiguous old opaque views fail before any preference write") }
                do { _ = try SettingsBackupStorage(defaults:defaults,domainName:suite,requiresRestart:false).exportDocument();check(false,"strict backup refuses unsupported retained session data") }
                catch { check(true,"strict backup refuses unsupported retained session data") }
                let valid = try SavedState().encoded()
                for invalid:Any in [Data("{broken".utf8),"wrong stored type",["future":"object"]] {
                    defaults.set(invalid,forKey:SettingsBackupStores.state);Preferences.state = Preferences.load();main.saveState()
                    check((NSDictionary(dictionary:["value":defaults.object(forKey:SettingsBackupStores.state)!])).isEqual(to:["value":invalid]),"unreadable required session data cannot be replaced by fallback autosave")
                    check(Preferences.sessionPersistenceNotice?.contains("nicht lesbar") == true,"unreadable session has a visible recovery explanation")
                    let liveProfile = pane.importedProfile;main.applySettingsProfile(profileSettings)
                    check(pane.importedProfile == liveProfile && main.content.status.stringValue.contains("nicht lesbar"),"blocked INI import preserves the live view and reports the recovery guard truthfully")
                }
                defaults.set(valid,forKey:SettingsBackupStores.beforeImport)
                check(Preferences.restoreBeforeImport() && defaults.data(forKey:SettingsBackupStores.state) == valid,"explicit pre-import recovery clears the narrow unreadable-session guard")
                defaults.set("unknown raw backup",forKey:SettingsBackupStores.beforeImport);main.applySettingsProfile(profileSettings)
                check(defaults.string(forKey:SettingsBackupStores.beforeImport) == "unknown raw backup" && main.content.status.stringValue.contains("Vor-Import"),"an existing unreadable pre-import backup is preserved and blocks false import success")
                check((personal as NSDictionary).isEqual(to:UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:]),"native regression leaves personal preferences untouched")
                check(NSPasteboard.general.changeCount == clipboard && Preferences.remoteTestPasswords.values == passwords,"native regression does not change clipboard or credentials")
                cleanup()
                if failures.isEmpty { print("SESSION PRESERVATION SMOKE PASS \(checks) checks");exit(0) }
                print("SESSION PRESERVATION SMOKE FAIL "+failures.joined(separator:"; "));exit(1)
            } catch { cleanup();print("SESSION PRESERVATION SMOKE FAIL "+error.localizedDescription);exit(1) }
        }
    }
}
