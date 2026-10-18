import AppKit
import CommanderCore

extension AppDelegate {
    func runAgeSmoke(root: URL,prefix: String,reload: Bool) {
        var failures: [String] = [],checks = 0
        func check(_ condition: Bool,_ name: String) { checks += 1;print("AGE UI \(condition ? "PASS" : "FAIL") \(name)");if !condition { failures.append(name) } }
        func finish() { print("AGE SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");if !failures.isEmpty { exit(1) };NSApp.terminate(nil) }
        func waitFor(_ condition: @escaping () -> Bool,then: @escaping () -> Void,attempt: Int = 0) {
            if condition() { then();return };guard attempt < 150 else { print("AGE SMOKE FAIL timed out");exit(1) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitFor(condition,then:then,attempt:attempt+1) }
        }
        func capture(_ window: NSWindow?,_ suffix: String) {
            guard let view = window?.contentView else { return };view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return };view.cacheDisplay(in:view.bounds,to:rep)
            try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
        }
        func select(_ popup: NSPopUpButton,_ index: Int) { popup.selectItem(at:index);_ = popup.sendAction(popup.action,to:popup.target) }
        func paths(_ setup: TransferSetupController) -> Set<String> { Set((0..<setup.previewCount).compactMap { setup.previewObject(at:$0)?.relativePath }) }
        let source = root.appendingPathComponent("Links/Projekt"),target = root.appendingPathComponent("Rechts"),marker = root.appendingPathComponent("saved-age-reference.txt")
        let rule = TransferAgeRange(minimum:.init(1,unit:.days),maximum:.init(1,unit:.weeks))
        let expected: Set<String> = ["Projekt","Projekt/passend.txt","Projekt/Unterordner","Projekt/Unterordner/kind.txt"]
        guard let journal = main.jobs.journal,Preferences.copyProfileTestDefaults != nil else { print("AGE SMOKE FAIL isolated storage missing");exit(1) }
        if reload {
            let library = try! Preferences.copyProfiles(),entry = journal.entries.first!
            check(library.profiles.count == 1 && library.profiles[0].filter.modifiedAge == rule,"relative profile survives separate process")
            check(entry.intent.filter.modifiedAge == rule && main.jobs.scheduler.snapshots.first?.state == .review,"journal restores relative intent for review")
            check(main.jobs.active == nil && !FileSystem.exists(target.appendingPathComponent("Projekt")),"relative recovery never starts automatically")
            guard let setup = main.reviewTransfer(entry.id) else { exit(1) }
            let prior = Double(try! String(contentsOf:marker,encoding:.utf8))!
            let newExpected = expected.union(["Projekt/alt.txt"])
            waitFor({ setup.plan?.filter.modifiedAge == rule },then:{
                check(setup.plan!.ageReference!.timeIntervalSince1970 > prior,"review obtains a new reference time")
                check(paths(setup) == newExpected && setup.plan?.bytes == 14,"fresh review sees source newly inside age range")
                check(setup.criteriaInfo.stringValue == "Relatives Alter aktiv" && setup.criteriaInfo.toolTip?.contains("Bezugszeit dieses Plans") == true,"active age and reference time visible")
                setup.criteriaButton.performClick(nil);let sheet = setup.criteriaWindow!
                check(sheet.dateMode.indexOfSelectedItem == 1 && sheet.ageMinimum.stringValue == "1" && sheet.ageMaximum.stringValue == "1" && sheet.ageMinimumUnit.indexOfSelectedItem == 2 && sheet.ageMaximumUnit.indexOfSelectedItem == 3,"saved amounts and mixed units restored in sheet")
                select(sheet.dateMode,0)
                check(!sheet.fromEnabled.isHidden && sheet.ageMaximum.isHidden,"switching to fixed times reveals date controls")
                sheet.cancel.performClick(nil);check(setup.plan?.filter.modifiedAge == rule,"cancel preserves relative rule")
                setup.structureOnly.performClick(nil)
                waitFor({ setup.plan?.filter.structureOnly == true },then:{
                    check(setup.plan?.ageReference == nil && setup.plan?.bytes == 0 && !setup.criteriaButton.isEnabled,"structure copy suspends relative age")
                    setup.structureOnly.performClick(nil)
                    waitFor({ setup.plan?.filter.structureOnly == false && setup.plan?.bytes == 14 },then:{
                        check(setup.keepEmpty.state == .off && paths(setup) == newExpected,"leaving structure copy restores age and empty-folder rule")
                        setup.objectsButton.performClick(nil);capture(setup.window,"-Relatives-Alter-Profil")
                        setup.startButton.performClick(nil)
                        waitFor({ self.main.jobs.pending == 0 },then:{
                            let state = self.main.jobs.scheduler.snapshots.last!
                            check(state.state == .completed && state.transferredBytes == 14,"reviewed relative transfer completes with exact bytes")
                            check(journal.entry(entry.id) == nil && journal.entries.first?.intent.filter.modifiedAge == rule,"new reviewed job atomically supersedes previous intent")
                            check((try? String(contentsOf:target.appendingPathComponent("Projekt/passend.txt"),encoding:.utf8)) == "match" && (try? String(contentsOf:target.appendingPathComponent("Projekt/alt.txt"),encoding:.utf8)) == "older" && (try? String(contentsOf:target.appendingPathComponent("Projekt/Unterordner/kind.txt"),encoding:.utf8)) == "kind","relative copy publishes expected contents")
                            check(!FileSystem.exists(target.appendingPathComponent("Projekt/jung.txt")) && !FileSystem.exists(target.appendingPathComponent("Projekt/zukunft.txt")) && !FileSystem.exists(target.appendingPathComponent("Projekt/Cache")) && !FileSystem.exists(target.appendingPathComponent("Projekt/klein.txt")),"age name size and subtree exclusions preserved")
                            check((try? Preferences.copyProfiles()) == library,"using and editing a profile never alters its saved rules")
                            self.main.transfer([source],to:root.appendingPathComponent("Sicherung"),kind:.copy)
                            let other = self.main.secondaryWindows.last as! TransferSetupController
                            waitFor({ other.plan != nil },then:{
                                check(other.filter.modifiedAge == nil && other.selectedProfileID == nil,"new copy starts without implicit relative profile")
                                let index = other.profilePopup.itemArray.firstIndex(where: { $0.title == "Letzte Woche" })!;select(other.profilePopup,index)
                                waitFor({ other.plan?.filter.modifiedAge == rule },then:{
                                    check(paths(other) == newExpected && other.profileStatus.stringValue == "Gespeichert","explicit profile loading re-evaluates relative rules")
                                    other.close();self.main.jobs.clearFinished();check(journal.entries.isEmpty,"relative history can be cleared");finish()
                                })
                            })
                        })
                    })
                })
            });return
        }
        main.transfer([source],to:target,kind:.copy)
        let setup = main.secondaryWindows.last as! TransferSetupController
        waitFor({ setup.plan != nil },then:{
            setup.criteriaButton.performClick(nil);let sheet = setup.criteriaWindow!
            check(sheet.dateMode.indexOfSelectedItem == 0 && sheet.ageMinimum.isHidden,"fixed date mode remains the default")
            select(sheet.dateMode,1)
            check(sheet.from.isHidden && !sheet.ageMinimum.isHidden && sheet.ageMinimumUnit.indexOfSelectedItem == 2,"native age mode shows optional fields and units")
            sheet.ageMinimum.stringValue = "-1";sheet.ageMaximum.stringValue = "7";sheet.apply.performClick(nil)
            check(setup.window?.attachedSheet != nil && !sheet.info.stringValue.isEmpty && setup.filter.modifiedAge == nil,"invalid age input leaves current plan intact")
            sheet.ageMinimum.stringValue = "8";sheet.apply.performClick(nil)
            check(setup.window?.attachedSheet != nil && !sheet.info.stringValue.isEmpty,"reversed age range rejected inline")
            sheet.ageMinimum.stringValue = "1";sheet.ageMaximum.stringValue = "1";select(sheet.ageMaximumUnit,3)
            sheet.minimum.stringValue = "2 B";capture(sheet.window,"-Relatives-Alter");sheet.apply.performClick(nil)
            waitFor({ setup.plan?.filter.modifiedAge == rule },then:{
                check(setup.window?.attachedSheet == nil && setup.filter.modifiedFrom == nil && setup.filter.modifiedBefore == nil,"relative mode clears fixed timestamps")
                setup.excludedFolders.stringValue = "Cache";setup.include.stringValue = "*.txt";setup.keepEmpty.performClick(nil);setup.mergeFolders.performClick(nil)
                waitFor({ setup.plan?.filter.keepEmptyFolders == false && setup.plan?.filter.excludedFolders == "Cache" && setup.plan?.merge != nil },then:{
                    check(paths(setup) == expected && setup.plan?.bytes == 9,"relative age combines with file and subtree rules")
                    check(setup.plan?.ageReference != nil && setup.criteriaInfo.toolTip?.contains("Bezugszeit dieses Plans") == true,"preview reference exposed for verification")
                    setup.profileSaveAs.performClick(nil);let naming = setup.profileNameWindow!;naming.name.stringValue = "Letzte Woche";naming.save.performClick(nil)
                    let library = try! Preferences.copyProfiles(),data = try! library.encoded(),json = try! JSONSerialization.jsonObject(with:data) as! [String:Any]
                    check(library.profiles.first?.filter.modifiedAge == rule && json["version"] as? Int == 2,"relative profile stored in compatible versioned format")
                    check(!String(decoding:data,as:UTF8.self).contains("ZweiCommander-ui-") && !String(decoding:data,as:UTF8.self).contains("ageReference"),"profile stores relative rule without paths or frozen clock")
                    let reference = setup.plan!.ageReference!
                    setup.queueButton.performClick(nil)
                    check(self.main.jobs.scheduler.snapshots.last?.state == .waiting && self.main.jobs.scheduler.isHeld,"relative transfer queued without starting")
                    check(journal.entries.first?.intent.filter.modifiedAge == rule && (try! JSONSerialization.jsonObject(with:Data(contentsOf:journal.file)) as! [String:Any])["version"] as? Int == 2,"relative intent uses protected journal format")
                    check(self.main.canTerminate && !FileSystem.exists(target.appendingPathComponent("Projekt")),"saved relative queue permits orderly quit without writes")
                    try! String(reference.timeIntervalSince1970).write(to:marker,atomically:true,encoding:.utf8)
                    try! FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(-3*86400)],ofItemAtPath:source.appendingPathComponent("alt.txt").path)
                    finish()
                })
            })
        })
    }
}
