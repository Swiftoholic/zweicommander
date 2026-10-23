import AppKit
import CommanderCore

extension AppDelegate {
    func runProfilesSmoke(root: URL,prefix: String,reload: Bool) {
        var failures: [String] = [],checks = 0
        let originalUserData = UserDefaults.standard.data(forKey:Preferences.copyProfilesKey)
        func check(_ value: Bool,_ name: String) { checks += 1;print("PROFILE UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
        func waitFor(_ condition: @escaping () -> Bool,then: @escaping () -> Void,attempt: Int = 0) {
            if condition() { then();return }
            guard attempt < 100 else { print("PROFILE SMOKE FAIL timed out");exit(1) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitFor(condition,then:then,attempt:attempt+1) }
        }
        func capture(_ window: NSWindow?,_ suffix: String) {
            guard let view = window?.contentView else { return };view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return };view.cacheDisplay(in:view.bounds,to:rep)
            try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
        }
        func library() -> CopyProfileLibrary { do { return try Preferences.copyProfiles() } catch { print("PROFILE SMOKE FAIL "+error.localizedDescription);exit(1) } }
        func finish() {
            check(UserDefaults.standard.data(forKey:Preferences.copyProfilesKey) == originalUserData,"real profile preferences untouched")
            _ = Preferences.copyProfileTestDefaults?.synchronize()
            print("PROFILE SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
        let source = root.appendingPathComponent("Links/Projekt"),destination = root.appendingPathComponent("Rechts"),target = destination.appendingPathComponent("Projekt")
        let lower = Date(timeIntervalSince1970:1_700_006_460),upper = Date(timeIntervalSince1970:1_700_006_580),profileName = "Dokumente 4–8 B"
        let expected: Set<String> = ["Projekt","Projekt/mittel.txt","Projekt/Unterordner","Projekt/Unterordner/neu.md"]
        main.transfer([source],to:destination,kind:.copy)
        guard let setup = main.secondaryWindows.last as? TransferSetupController,Preferences.copyProfileTestDefaults != nil else { print("PROFILE SMOKE FAIL isolated suite or setup missing");exit(1) }
        func paths() -> Set<String> { Set((0..<setup.previewCount).compactMap { setup.previewObject(at:$0)?.relativePath }) }
        func selectSaved() {
            guard let index = setup.profilePopup.itemArray.firstIndex(where: { $0.title == profileName }) else { print("PROFILE SMOKE FAIL saved menu missing");exit(1) }
            setup.profilePopup.selectItem(at:index);_ = setup.profilePopup.sendAction(setup.profilePopup.action,to:setup.profilePopup.target)
        }
        func afterExecution() {
            let state = self.main.jobs.scheduler.snapshots.last
            check(state?.state == .completed && state?.transferredBytes == 9,"profile-driven merge completes with exact bytes")
            check((try? String(contentsOf:target.appendingPathComponent("mittel.txt"),encoding:.utf8)) == "alt","existing target preserved")
            check((try? String(contentsOf:target.appendingPathComponent("mittel (2).txt"),encoding:.utf8)) == "abcd" && (try? String(contentsOf:target.appendingPathComponent("Unterordner/neu.md"),encoding:.utf8)) == "# neu","matching file contents copied")
            check((try? String(contentsOf:target.appendingPathComponent("extra.txt"),encoding:.utf8)) == "extra" && !FileSystem.exists(target.appendingPathComponent("klein.txt")) && !FileSystem.exists(target.appendingPathComponent("alt.txt")) && !FileSystem.exists(target.appendingPathComponent("ende.txt")),"excluded dates and sizes leave target extras intact")
            self.main.transfer([source],to:root.appendingPathComponent("Sicherung"),kind:.move)
            guard let move = self.main.secondaryWindows.last as? TransferSetupController else { exit(1) }
            waitFor({ move.plan != nil },then:{
                check(move.profilePopup.isEnabled && move.profileSaveAs.isEnabled && !move.profileSave.isEnabled && move.criteriaButton.isEnabled && move.filter == TransferFilter(),"profiles and metadata filters available for moves")
                move.close();finish()
            })
        }
        func reloadSaved() {
            let id = try? String(contentsOf:root.appendingPathComponent("saved-profile-id.txt"),encoding:.utf8)
            check(library().profiles.count == 1 && library().profiles.first?.id.uuidString == id,"profile identity survives a separate app process")
            check(setup.selectedProfileID == nil && setup.filter == TransferFilter() && setup.mergeFolders.state == .off,"new copy never applies a profile automatically")
            selectSaved()
            waitFor({ setup.plan?.filter.minimumSize == 4 },then:{
                check(paths() == expected && setup.plan?.bytes == 9,"reloaded profile restores exact matching tree")
                check(setup.policy.indexOfSelectedItem == 2 && setup.mergeFolders.state == .on && setup.profileStatus.stringValue == "Gespeichert","global conflict rule and merge restored")
                setup.criteriaButton.performClick(nil)
                guard let criteria = setup.criteriaWindow else { exit(1) }
                check(criteria.minimum.stringValue == "4 B" && criteria.maximum.stringValue == "8 B" && criteria.fromEnabled.state == .on && criteria.beforeEnabled.state == .on && criteria.from.dateValue == lower && criteria.before.dateValue == upper,"saved size and date fields restored")
                criteria.cancel.performClick(nil)
                check(setup.window?.attachedSheet == nil && paths() == expected,"cancelling criteria retains the plan")
                setup.structureOnly.performClick(nil)
                waitFor({ setup.plan?.filter.structureOnly == true },then:{
                    check(!setup.criteriaButton.isEnabled && setup.plan?.bytes == 0 && (0..<setup.previewCount).allSatisfy { setup.previewObject(at:$0)?.kind == .directory },"structure mode suspends metadata constraints")
                    check(!library().profiles[0].filter.structureOnly,"editing controls never changes the saved profile implicitly")
                    setup.structureOnly.performClick(nil)
                    waitFor({ setup.plan?.filter.structureOnly == false && setup.plan?.bytes == 9 },then:{
                        check(paths() == expected && setup.keepEmpty.state == .off && setup.profileStatus.stringValue == "Gespeichert","leaving structure mode restores the profile's empty-folder rule")
                        setup.objectsButton.performClick(nil);capture(setup.window,"-Kopierprofil")
                        setup.queueButton.performClick(nil)
                        check(self.main.jobs.scheduler.isHeld && self.main.jobs.scheduler.snapshots.last?.state == .waiting,"loaded profile queued without premature writes")
                        self.main.operationWindow!.start.performClick(nil)
                        waitFor({ self.main.jobs.pending == 0 },then:afterExecution)
                    })
                })
            })
        }
        func saveProfile() {
            check(paths() == expected && setup.plan?.bytes == 9,"name size date and subtree filters combine")
            setup.profileSaveAs.performClick(nil)
            guard let naming = setup.profileNameWindow else { exit(1) }
            naming.save.performClick(nil)
            check(setup.window?.attachedSheet != nil && !naming.info.stringValue.isEmpty && library().profiles.isEmpty,"empty profile name blocks save")
            naming.name.stringValue = profileName;naming.save.performClick(nil)
            check(setup.window?.attachedSheet == nil && library().profiles.count == 1 && setup.selectedProfileID != nil && setup.profileStatus.stringValue == "Gespeichert","save-as stores and selects a profile")
            let id = setup.selectedProfileID!
            setup.include.stringValue = "*.txt";setup.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:setup.include))
            check(setup.plan == nil && setup.profileStatus.stringValue == "Ungespeicherte Änderungen","editing marks rules dirty and invalidates the plan")
            setup.profileSave.performClick(nil)
            check(library().profile(id)?.filter.include == "*.txt" && library().profiles.count == 1,"save updates the selected identity")
            setup.include.stringValue = "*.txt;*.md";setup.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:setup.include));setup.profileSave.performClick(nil);setup.prepare()
            let saved = try! library().encoded()
            setup.profileSaveAs.performClick(nil)
            let duplicate = setup.profileNameWindow!;duplicate.name.stringValue = profileName.lowercased();duplicate.save.performClick(nil)
            check(setup.window?.attachedSheet != nil && !duplicate.info.stringValue.isEmpty && (try? library().encoded()) == saved,"duplicate names cannot overwrite a profile")
            duplicate.cancel.performClick(nil)
            self.main.transfer([source],to:root.appendingPathComponent("Sicherung"),kind:.copy)
            let other = self.main.secondaryWindows.last as! TransferSetupController
            setup.profileSaveAs.performClick(nil);let temporary = setup.profileNameWindow!;temporary.name.stringValue = "Vorübergehend";temporary.save.performClick(nil)
            check(other.profilePopup.numberOfItems == 3 && library().profiles.count == 2,"profile menus refresh in another open dialog")
            let timer = Timer(timeInterval:0.05,repeats:true) { timer in
                guard let window = NSApp.modalWindow else { return }
                func button(_ view: NSView) -> NSButton? {
                    if let result = view as? NSButton,result.title == "Entfernen" { return result }
                    return view.subviews.compactMap { button($0) }.first
                }
                if let root = window.contentView,let remove = button(root) { timer.invalidate();remove.performClick(nil) }
            }
            RunLoop.main.add(timer,forMode:.modalPanel)
            setup.profileRemove.performClick(nil);timer.invalidate()
            check(library().profiles.count == 1 && other.profilePopup.numberOfItems == 2 && setup.selectedProfileID == nil,"confirmed profile removal synchronizes open dialogs")
            other.close();selectSaved()
            let data = Preferences.copyProfileTestDefaults!.data(forKey:Preferences.copyProfilesKey)!
            Preferences.copyProfileTestDefaults!.set(Data("broken".utf8),forKey:Preferences.copyProfilesKey);setup.refreshProfiles()
            check(!setup.profileSaveAs.isEnabled && !setup.profilePopup.isEnabled && setup.profileStatus.stringValue == "Profile nicht lesbar","corrupt profile storage cannot be silently replaced")
            Preferences.copyProfileTestDefaults!.set(data,forKey:Preferences.copyProfilesKey);setup.refreshProfiles()
            let text = String(decoding:data,as:UTF8.self)
            check(!text.contains("ZweiCommander-ui-") && !text.contains("individualDecisions") && library().profile(id)?.filter.modifiedBefore == upper,"profile data contains rules without paths or per-file decisions")
            check(!FileSystem.exists(target.appendingPathComponent("mittel (2).txt")) && (try? String(contentsOf:target.appendingPathComponent("mittel.txt"),encoding:.utf8)) == "alt","profile editing performs no file transfers")
            try! id.uuidString.write(to:root.appendingPathComponent("saved-profile-id.txt"),atomically:true,encoding:.utf8)
            finish()
        }
        func configure() {
            setup.include.stringValue = "*.txt;*.md";setup.excludedFolders.stringValue = "Cache";setup.keepEmpty.performClick(nil)
            setup.mergeFolders.performClick(nil);setup.policy.selectItem(at:2);_ = setup.policy.sendAction(setup.policy.action,to:setup.policy.target)
            waitFor({ setup.plan?.filter.keepEmptyFolders == false && setup.plan?.merge != nil && setup.plan?.policy == .keepBoth },then:saveProfile)
        }
        waitFor({ setup.plan != nil },then:{
            if reload { reloadSaved();return }
            check(library().profiles.isEmpty && setup.profilePopup.numberOfItems == 1 && !setup.profileSave.isEnabled && setup.profileSaveAs.isEnabled,"empty profile library has explicit save-as")
            setup.criteriaButton.performClick(nil)
            guard let criteria = setup.criteriaWindow else { exit(1) }
            check(setup.window?.attachedSheet === criteria.window && !criteria.from.isEnabled && !criteria.before.isEnabled,"native criteria sheet and optional dates")
            criteria.minimum.stringValue = "10 MB";criteria.maximum.stringValue = "1 KB";criteria.apply.performClick(nil)
            check(setup.window?.attachedSheet != nil && !criteria.info.stringValue.isEmpty && setup.plan?.filter.minimumSize == nil,"invalid size range leaves original plan intact")
            criteria.minimum.stringValue = "nonsense";criteria.apply.performClick(nil)
            check(setup.window?.attachedSheet != nil && !criteria.info.stringValue.isEmpty,"invalid size syntax rejected inline")
            criteria.minimum.stringValue = "4 B";criteria.maximum.stringValue = "8 B";criteria.fromEnabled.performClick(nil);criteria.beforeEnabled.performClick(nil)
            check(criteria.from.isEnabled && criteria.before.isEnabled,"native date toggles enable pickers")
            criteria.from.dateValue = upper;criteria.before.dateValue = lower;criteria.apply.performClick(nil)
            check(setup.window?.attachedSheet != nil && setup.plan?.filter.modifiedFrom == nil,"invalid date range leaves original plan intact")
            criteria.from.dateValue = lower;criteria.before.dateValue = upper;_ = criteria.before.sendAction(criteria.before.action,to:criteria.before.target);capture(criteria.window,"-Groesse-Datum");criteria.apply.performClick(nil)
            waitFor({ setup.plan?.filter.minimumSize == 4 && setup.plan?.filter.modifiedFrom == lower },then:{
                check(setup.window?.attachedSheet == nil && setup.plan?.filter.maximumSize == 8 && setup.plan?.filter.modifiedBefore == upper,"criteria sheet applies validated bounds")
                configure()
            })
        })
    }
}
