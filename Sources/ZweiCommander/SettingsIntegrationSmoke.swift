import AppKit
import CommanderCore

extension AppDelegate {
    func runSettingsIntegrationSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            let suite = "local.zweicommander.tests."+UUID().uuidString
            guard let defaults = UserDefaults(suiteName:suite) else { exit(1) }
            @MainActor func check(_ condition:Bool,_ name:String) { checks += 1;print("SETTINGS INTEGRATION UI \(condition ? "PASS" : "FAIL") "+name);if !condition { failures.append(name) } }
            @MainActor func cleanup() { SettingsBackupStorage.restartPending = false;defaults.removePersistentDomain(forName:suite);_ = defaults.synchronize() }
            @MainActor func blocked(_ name:String,_ action:()throws->Void) {
                do { try action();check(false,name) }
                catch { check(error.localizedDescription.contains("neu starten"),name) }
            }
            do {
                let personal = UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:]
                let passwords = Preferences.remoteTestPasswords.values
                Preferences.primaryTestDefaults = defaults;Preferences.workspaceTestDefaults = defaults;Preferences.appearanceTestDefaults = defaults;Preferences.toolbarTestDefaults = defaults
                Preferences.copyProfileTestDefaults = defaults;Preferences.renameTestDefaults = defaults;Preferences.searchTestDefaults = defaults;Preferences.compareTestDefaults = defaults
                Preferences.tabGroupsTestDefaults = defaults;Preferences.layoutTestDefaults = defaults;Preferences.externalToolsTestDefaults = defaults;Preferences.remoteProfileTestDefaults = defaults
                let state = try JSONEncoder().encode(Preferences.state)
                defaults.set(state,forKey:SettingsBackupStores.state);defaults.set(state,forKey:SettingsBackupStores.beforeImport)
                let before = defaults.persistentDomain(forName:suite) ?? [:]
                let store = Preferences.remoteProfiles,connection = try RemoteConnection(kind:.ftps,host:"server.example",user:"tester",port:21)
                var library = RemoteProfileLibrary();let remote = try library.save(name:"Fixture",connection:connection,path:"/",usesKeychain:true)
                SettingsBackupStorage.restartPending = true
                blocked("appearance writes stop while restored preferences await restart") { try Preferences.saveAppearance(AppearanceSettings()) }
                blocked("toolbar writes stop while restored preferences await restart") { try Preferences.saveToolbar(ToolbarSettings()) }
                blocked("workspace writes stop while restored preferences await restart") { try Preferences.saveWorkspace(WorkspaceLibrary()) }
                blocked("copy profiles cannot overwrite a restored store") { try Preferences.editCopyProfiles { _ in } }
                blocked("rename profiles cannot overwrite a restored store") { try Preferences.editRenameProfiles { _ in } }
                blocked("search profiles cannot overwrite a restored store") { try Preferences.editSearchProfiles { _ in } }
                blocked("comparison profiles cannot overwrite a restored store") { try Preferences.editCompareProfiles { _ in } }
                blocked("tab groups cannot overwrite a restored store") { try Preferences.editTabGroups { _ in } }
                blocked("layout profiles cannot overwrite a restored store") { try Preferences.editLayouts { _ in } }
                blocked("last layout cannot overwrite a restored store") { try Preferences.saveLastLayout(WorkspaceLayout()) }
                blocked("external tools cannot overwrite a restored store") { try Preferences.saveExternalTools(ExternalToolLibrary()) }
                blocked("remote save stops before credential mutation") { _ = try store.save(name:"Changed",connection:connection,path:"/",remember:true,password:"synthetic-password") }
                blocked("remote removal stops before credential mutation") { try store.remove(remote) }
                Preferences.state.theme = (Preferences.state.theme+1)%3;Preferences.save()
                check(defaults.data(forKey:SettingsBackupStores.state) == state,"ordinary state autosave cannot replace the restored payload")
                let memory = try JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences.state)) as! NSDictionary
                guard let original = Preferences.state.importedProfile else { throw CommanderError.message("Künstliches Importprofil fehlt.") }
                var profileJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(original)) as! [String:Any]
                profileJSON["showHidden"] = !original.showHidden
                Preferences.apply(try JSONDecoder().decode(SettingsProfile.self,from:JSONSerialization.data(withJSONObject:profileJSON)))
                check(memory == (try JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences.state)) as! NSDictionary),"a stale INI action cannot alter the restored in-memory state")
                check(!Preferences.restoreBeforeImport(),"a stale pre-import restore is rejected until restart")
                self.main.saveState()
                check(memory == (try JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences.state)) as! NSDictionary),"main-window autosave leaves restored state untouched")
                let pending = self.main.pendingLayoutSave;self.main.scheduleLayoutSave()
                check(self.main.pendingLayoutSave === pending,"layout debounce does not schedule a stale write")
                check(try AppDelegate.shortcutOverrides("").isEmpty,"all new defaults fit the complete shortcut map")
                check(AppDelegate.resolvedShortcut("externalTool1",overrides:["search":"cmd+option+1"]).isEmpty,"tool slots yield to an existing explicit command binding")
                check(AppDelegate.resolvedShortcut("externalTool1",overrides:["externalTool1":""]).isEmpty,"an explicitly disabled tool slot stays disabled")
                check(AppDelegate.resolvedShortcut("externalTools",overrides:["search":"cmd+option+t"]).isEmpty,"tool management yields to an existing binding")
                check(AppDelegate.resolvedShortcut("attributes",overrides:["search":"cmd+shift+i"]).isEmpty && AppDelegate.resolvedShortcut("settingsBackup",overrides:["search":"cmd+shift+,"]).isEmpty,"new properties and backup defaults yield to existing bindings")
                check(Preferences.remoteTestPasswords.values == passwords,"blocked profile mutations leave credential storage untouched")
                check((before as NSDictionary).isEqual(to:defaults.persistentDomain(forName:suite) ?? [:]),"every blocked writer preserves the complete restored preference domain")
                check((personal as NSDictionary).isEqual(to:UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:]),"integration checks leave personal preferences untouched")
                SettingsBackupStorage.restartPending = false;Preferences.save()
                let written = try JSONSerialization.jsonObject(with:defaults.data(forKey:SettingsBackupStores.state)!) as! NSDictionary
                check(written == memory,"ordinary persistence resumes after the restart boundary is cleared")
                print("SETTINGS INTEGRATION SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");cleanup();fflush(stdout);exit(failures.isEmpty ? 0 : 1)
            } catch { print("SETTINGS INTEGRATION SMOKE FAIL "+error.localizedDescription);cleanup();fflush(stdout);exit(1) }
        }
    }
}
