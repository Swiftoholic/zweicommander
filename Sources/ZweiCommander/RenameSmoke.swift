import AppKit
import CommanderCore

extension AppDelegate {
    func runRenameSmoke(root: URL,prefix: String,reload: Bool) {
        var failures: [String] = [],checks = 0
        func check(_ value: Bool,_ name: String) { checks += 1;print("RENAME UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
        func finish() {
            _ = Preferences.renameTestDefaults?.synchronize();print("RENAME SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
        func waitFor(_ condition: @escaping ()->Bool,then: @escaping ()->Void,attempt: Int = 0) {
            if condition() { then();return };guard attempt < 150 else { print("RENAME SMOKE FAIL timed out");exit(1) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitFor(condition,then:then,attempt:attempt+1) }
        }
        func choose(_ popup: NSPopUpButton,_ index: Int) { popup.selectItem(at:index);_ = popup.sendAction(popup.action,to:popup.target) }
        func capture(_ window: NSWindow?,_ suffix: String) {
            guard let view = window?.contentView else { return };view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return };view.cacheDisplay(in:view.bounds,to:rep)
            try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
        }
        func setup(_ urls: [URL]) -> RenameController {
            self.main.left.select(Set(urls));self.main.left.focus();self.main.command("batchRename")
            guard let controller = self.main.secondaryWindows.last as? RenameController else { print("RENAME SMOKE FAIL controller missing");exit(1) };return controller
        }
        func names(_ controller: RenameController) -> Set<String> { Set(controller.preview?.rows.compactMap(\.targetName) ?? []) }
        func loadProfile(_ controller: RenameController,_ name: String) {
            guard let index = controller.profilePopup.itemArray.firstIndex(where: { $0.title == name }) else { print("RENAME SMOKE FAIL profile missing");exit(1) };choose(controller.profilePopup,index)
        }
        let folder = root.appendingPathComponent("Links"),urls = ["Äpfel.TXT","Birne.txt","Kirsche.txt"].map { folder.appendingPathComponent($0) }
        let originalNames = Set(urls.map(\.lastPathComponent)),renamedNames: Set<String> = ["007-aepfel.md","009-birne.md","011-kirsche.md"]
        guard let defaults = Preferences.renameTestDefaults else { print("RENAME SMOKE FAIL isolated settings missing");exit(1) }
        let controller = setup(urls)
        if reload {
            let saved = try! Preferences.renameProfiles()
            check(saved.profiles.count == 2 && saved.profiles.contains(where: { $0.name == "Serienamen" && $0.rule.step == 2 }),"profiles survive separate process")
            check(controller.selectedProfileID == nil && (try? controller.rule())?.pattern == "{name}","fresh rename never loads a profile implicitly")
            loadProfile(controller,"Serienamen")
            waitFor({ controller.preview?.canApply == true },then:{
                check(names(controller) == renamedNames && controller.profileStatus.stringValue == "Gespeichert","explicit profile restores all fields and target names")
                controller.step.stringValue = "0";controller.rebuild()
                check(!controller.apply.isEnabled,"invalidating a field immediately blocks apply")
                waitFor({ controller.info.textColor == .systemRed },then:{
                    check(controller.preview == nil && !controller.info.stringValue.isEmpty,"invalid counter reported inline")
                    loadProfile(controller,"Serienamen")
                    waitFor({ controller.preview?.canApply == true },then:{
                        capture(controller.window,"-Umbenennen-Profil");controller.apply.performClick(nil)
                        waitFor({ !controller.isWorking && self.main.jobs.pending == 0 },then:{
                            let actual = Set((try! FileSystem.list(folder,showHidden:true)).map(\.name))
                            check(renamedNames.isSubset(of:actual) && actual.isDisjoint(with:originalNames),"native rename publishes all expected names")
                            check((try? String(contentsOf:folder.appendingPathComponent("007-aepfel.md"),encoding:.utf8)) == "fruit-A" &&
                                  (try? String(contentsOf:folder.appendingPathComponent("009-birne.md"),encoding:.utf8)) == "fruit-B" &&
                                  (try? String(contentsOf:folder.appendingPathComponent("011-kirsche.md"),encoding:.utf8)) == "fruit-C","renamed file contents are unchanged")
                            check(self.main.renameUndo?.count == 3 && controller.info.stringValue.contains("3 Objekte"),"native completion retains a versioned undo plan")
                            check(!controller.apply.isEnabled && controller.choices.allSatisfy { renamedNames.contains($0.url.lastPathComponent) },"finished window tracks current paths without reapplying stale preview")
                            controller.close();self.main.left.focus();self.main.command("undo")
                            waitFor({ self.main.jobs.pending == 0 && self.main.renameUndo == nil },then:{
                                let actual = Set((try! FileSystem.list(folder,showHidden:true)).map(\.name))
                                check(originalNames.isSubset(of:actual) && actual.isDisjoint(with:renamedNames),"main undo restores every original name")
                                check(!actual.contains(where: { $0.hasPrefix(".zweicommander-rename-") }),"successful rename and undo leave no temporary names")
                                waitFor({ Set(self.main.left.visibleEntries.map(\.name)).isSuperset(of:originalNames) },then:{
                                    let stale = setup(urls);stale.pattern.stringValue = "stale-{name}";stale.prepare()
                                    waitFor({ stale.preview?.canApply == true },then:{
                                        try! Data("edited after preview".utf8).write(to:urls[1]);stale.apply.performClick(nil)
                                        waitFor({ !stale.isWorking && self.main.jobs.pending == 0 },then:{
                                            check(stale.info.textColor == .systemRed && stale.report.isEnabled,"stale source blocks execution with accessible report")
                                            check(urls.allSatisfy { FileSystem.exists($0) } && !FileSystem.exists(folder.appendingPathComponent("stale-Äpfel.TXT")),"stale plan changes no source names")
                                            check((try? String(contentsOf:urls[1],encoding:.utf8)) == "edited after preview","external edit is retained")
                                            stale.close();queuedCancellation()
                                        })
                                    })
                                })
                            })
                        })
                    })
                })
            })
            func queuedCancellation() {
                let gate = DispatchSemaphore(value:0)
                let blocker = self.main.jobs.submit("Test block",work:{ token,_ in while gate.wait(timeout:.now()+0.01) == .timedOut { try token.check() } },completion:{ _ in })
                let queued = setup(urls);queued.pattern.stringValue = "queued-{name}";queued.prepare()
                waitFor({ queued.preview?.canApply == true && self.main.jobs.active?.id == blocker },then:{
                    queued.apply.performClick(nil)
                    check(queued.isWorking && !queued.windowShouldClose(queued.window!) && !self.main.canTerminate,"queued rename is tracked and blocks closing")
                    queued.cancel.performClick(nil)
                    waitFor({ !queued.isWorking },then:{
                        check(queued.info.stringValue.contains("Abgebrochen") && self.main.jobs.active?.id == blocker,"cancel button targets only its waiting rename")
                        gate.signal()
                        waitFor({ self.main.jobs.pending == 0 },then:{
                            check(self.main.jobs.scheduler.snapshots.first(where: { $0.id == blocker })?.state == .completed && urls.allSatisfy { FileSystem.exists($0) },"other job completes and cancelled rename has no effects")
                            queued.close();metadataAndProfiles()
                        })
                    })
                })
            }
            func metadataAndProfiles() {
                let pictureFolder = folder.appendingPathComponent("Bilder")
                self.main.left.navigate(pictureFolder)
                waitFor({ self.main.left.visibleEntries.count == 2 && self.main.left.status.stringValue.contains("Objekte") },then:{
                    let picture = pictureFolder.appendingPathComponent("Bild.png"),link = pictureFolder.appendingPathComponent("Bild-Link.png")
                    let images = setup([picture,link]);loadProfile(images,"Bildmaße")
                    waitFor({ images.preview != nil },then:{
                        check(images.preview?.errorCount == 1 && names(images).contains("288x168-Bild.png") && !images.apply.isEnabled,"image dimensions render while linked image is rejected")
                        let row = images.choices.firstIndex(where: { $0.url.lastPathComponent == "Bild-Link.png" })!
                        (images.table.view(atColumn:0,row:row,makeIfNecessary:true) as! NSButton).performClick(nil)
                        waitFor({ images.preview?.canApply == true },then:{
                            check(images.preview?.rows.count == 1,"excluding metadata failure enables remaining image")
                            images.pattern.stringValue = "{taken}";images.prepare()
                            waitFor({ images.preview?.errorCount == 1 },then:{
                                check(!images.apply.isEnabled && images.preview?.rows.first?.error?.contains("EXIF") == true,"missing EXIF date remains a visible row error")
                                let data = defaults.data(forKey:Preferences.renameProfilesKey)!
                                defaults.set(Data("{broken".utf8),forKey:Preferences.renameProfilesKey);images.refreshProfiles()
                                check(!images.profileSaveAs.isEnabled && images.profileStatus.stringValue == "Profile nicht lesbar","damaged profiles disable writes inline")
                                do { try Preferences.editRenameProfiles { try $0.save(name:"Bad",rule:RenameRule()) };check(false,"damaged profile bytes preserved") }
                                catch { check(defaults.data(forKey:Preferences.renameProfilesKey) == Data("{broken".utf8),"damaged profile bytes preserved") }
                                defaults.set("wrong type",forKey:Preferences.renameProfilesKey)
                                do { _ = try Preferences.renameProfiles();check(false,"wrong storage type rejected") } catch { check(defaults.string(forKey:Preferences.renameProfilesKey) == "wrong type","wrong storage type rejected") }
                                defaults.set(data,forKey:Preferences.renameProfilesKey);images.refreshProfiles();loadProfile(images,"Bildmaße")
                                waitFor({ images.preview?.canApply == true },then:{
                                    images.profileRemove.performClick(nil)
                                    waitFor({ images.window?.attachedSheet != nil },then:{
                                        images.deleteAlert!.buttons[1].performClick(nil)
                                        waitFor({ images.window?.attachedSheet == nil },then:{
                                            check((try! Preferences.renameProfiles()).profiles.count == 2,"profile deletion cancel retains both rules")
                                            images.profileRemove.performClick(nil)
                                            waitFor({ images.window?.attachedSheet != nil },then:{
                                                images.deleteAlert!.buttons[0].performClick(nil)
                                                waitFor({ (try! Preferences.renameProfiles()).profiles.count == 1 },then:{
                                                    check((try! Preferences.renameProfiles()).profiles.first?.name == "Serienamen" && images.selectedProfileID == nil,"confirmed deletion removes only selected profile")
                                                    check(images.pattern.stringValue == "{width}x{height}-{name}" && FileSystem.isSymlink(link),"profile deletion preserves current fields and file link")
                                                    capture(images.window,"-Umbenennen-Bilddaten");images.close()
                                                    check(!FileSystem.exists(pictureFolder.appendingPathComponent("288x168-Bild.png")),"preview-only metadata checks never rename files")
                                                    finish()
                                                })
                                            })
                                        })
                                    })
                                })
                            })
                        })
                    })
                })
            }
            return
        }
        waitFor({ controller.preview != nil },then:{
            check(controller.table.numberOfRows == 3 && controller.preview?.changedCount == 0 && !controller.apply.isEnabled,"native preview starts with unchanged selected files")
            controller.pattern.stringValue = "first-{name}";controller.rebuild();controller.pattern.stringValue = "second-{name}";controller.rebuild()
            check(!controller.apply.isEnabled && controller.preview == nil,"editing clears the previous executable preview immediately")
            waitFor({ controller.preview?.canApply == true },then:{
                check(controller.preview!.rows.allSatisfy { $0.targetName?.hasPrefix("second-") == true },"latest debounced generation wins")
                controller.regex.state = .on;controller.search.stringValue = "[";controller.prepare()
                waitFor({ controller.preview == nil && controller.info.textColor == .systemRed },then:{
                    check(!controller.apply.isEnabled && !controller.info.stringValue.isEmpty,"invalid regex is shown inline")
                    controller.regex.state = .off;controller.search.stringValue = "";controller.pattern.stringValue = "same";controller.separateExtension.state = .on;controller.extensionPattern.stringValue = "txt";controller.prepare()
                    waitFor({ controller.preview?.errorCount == 3 },then:{
                        check(!controller.apply.isEnabled && controller.preview?.rows.allSatisfy { $0.error != nil } == true,"collision marks every affected file")
                        (controller.table.view(atColumn:0,row:0,makeIfNecessary:true) as! NSButton).performClick(nil)
                        waitFor({ controller.preview?.rows.count == 2 },then:{
                            check(controller.choices.filter(\.enabled).count == 2,"native per-row checkbox excludes a source")
                            controller.selectNone.performClick(nil)
                            waitFor({ controller.preview?.rows.isEmpty == true },then:{
                                check(!controller.apply.isEnabled,"empty rename selection cannot execute")
                                controller.selectAll.performClick(nil);controller.pattern.stringValue = "{n}-{name}";controller.start.stringValue = "7";controller.step.stringValue = "2";controller.digits.stringValue = "3";controller.extensionPattern.stringValue = "md";controller.prepare()
                                waitFor({ controller.preview?.canApply == true },then:{
                                    check(controller.extensionPattern.isEnabled && controller.preview?.rows.count == 3,"separate extension and step counter have a live preview")
                                    let old = controller.choices.map(\.id);choose(controller.order,5)
                                    waitFor({ controller.preview?.canApply == true },then:{
                                        check(controller.choices.map(\.id) == Array(old.reversed()) && controller.preview?.rows.first?.targetName?.hasPrefix("007-") == true,"reversing order changes numbering source")
                                        controller.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);controller.down.performClick(nil)
                                        waitFor({ controller.preview?.canApply == true },then:{
                                            check(controller.choices[1].id == old.last,"move-row button changes counter order")
                                            choose(controller.order,1)
                                            controller.extensionPattern.stringValue = "";controller.prepare()
                                            waitFor({ controller.preview?.canApply == true },then:{
                                                check(names(controller).allSatisfy { !$0.contains(".") },"empty separate extension removes suffix")
                                                controller.extensionPattern.stringValue = "md";controller.search.stringValue = "ä";controller.replacement.stringValue = "ae";controller.ignoreCase.state = .on;controller.searchTarget.selectItem(at:1);controller.letterCase.selectItem(at:1);controller.caseTarget.selectItem(at:1);controller.prepare()
                                                waitFor({ controller.preview?.canApply == true },then:{
                                                    check(names(controller) == renamedNames,"targeted replacement and casing yield expected full names")
                                                    controller.settingsButtons[1].performClick(nil);capture(controller.window,"-Umbenennen-Ersetzen")
                                                    controller.settingsButtons[2].performClick(nil);capture(controller.window,"-Umbenennen-Datum")
                                                    controller.settingsButtons[0].performClick(nil);capture(controller.window,"-Mehrfachumbenennen");controller.profileSaveAs.performClick(nil)
                                                    let naming = controller.profileNameWindow!;naming.name.stringValue = "";naming.save.performClick(nil)
                                                    check(controller.window?.attachedSheet != nil && !naming.info.stringValue.isEmpty,"invalid profile name stays in native sheet")
                                                    naming.name.stringValue = "Serienamen";naming.save.performClick(nil)
                                                    let library = try! Preferences.renameProfiles(),data = try! library.encoded()
                                                    check(library.profiles.count == 1 && library.profiles.first?.rule == (try? controller.rule()) && !String(decoding:data,as:UTF8.self).contains(root.path),"profile persists complete rule without selected paths")
                                                    let other = setup(urls)
                                                    waitFor({ other.preview != nil },then:{
                                                        check(other.selectedProfileID == nil && other.profilePopup.itemArray.contains(where: { $0.title == "Serienamen" }),"second window sees profile without implicit loading")
                                                        loadProfile(other,"Serienamen")
                                                        waitFor({ other.preview?.canApply == true },then:{
                                                            check(names(other) == renamedNames,"other window explicitly loads saved rule")
                                                            other.pattern.stringValue = "ungespeichert-{name}";other.rebuild()
                                                            controller.dateFormat.stringValue = "yyyyMMdd";controller.rebuild();controller.profileSave.performClick(nil)
                                                            check(other.pattern.stringValue == "ungespeichert-{name}" && other.profileStatus.stringValue == "Geändert","profile update preserves another window's unsaved fields")
                                                            other.close();controller.pattern.stringValue = "{width}x{height}-{name}";controller.separateExtension.state = .off;controller.search.stringValue = "";controller.letterCase.selectItem(at:0);controller.prepare()
                                                            waitFor({ controller.preview?.errorCount == 3 },then:{
                                                                check(controller.profileSaveAs.isEnabled,"valid metadata rule can be saved independently of selected file types")
                                                                controller.profileSaveAs.performClick(nil);let sheet = controller.profileNameWindow!;sheet.name.stringValue = "Bildmaße";sheet.save.performClick(nil)
                                                                check((try! Preferences.renameProfiles()).profiles.count == 2,"second reusable metadata profile saved")
                                                                controller.close()
                                                                check(urls.allSatisfy { FileSystem.exists($0) } && renamedNames.allSatisfy { !FileSystem.exists(folder.appendingPathComponent($0)) },"closing previews never applies a file change")
                                                                finish()
                                                            })
                                                        })
                                                    })
                                                })
                                            })
                                        })
                                    })
                                })
                            })
                        })
                    })
                })
            })
        })
    }
}
