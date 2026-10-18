import AppKit
import CommanderCore

extension AppDelegate {
    func runCompareSmoke(root: URL,prefix: String,reload: Bool) {
        var failures: [String] = [],checks = 0
        func check(_ value: Bool,_ name: String) { checks += 1;print("COMPARE UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
        func finish() { _ = Preferences.compareTestDefaults?.synchronize();print("COMPARE SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");if !failures.isEmpty { exit(1) };NSApp.terminate(nil) }
        func waitFor(_ condition: @escaping ()->Bool,then: @escaping ()->Void,attempt: Int = 0) {
            if condition() { then();return };guard attempt < 150 else { print("COMPARE SMOKE FAIL timed out");exit(1) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitFor(condition,then:then,attempt:attempt+1) }
        }
        func choose(_ popup: NSPopUpButton,_ index: Int) { popup.selectItem(at:index);_ = popup.sendAction(popup.action,to:popup.target) }
        func capture(_ window: NSWindow?,_ suffix: String) {
            guard let view = window?.contentView else { check(false,"snapshot view available");return };view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { check(false,"snapshot bitmap available");return };view.cacheDisplay(in:view.bounds,to:bitmap)
            try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
        }
        func loadProfile(_ controller: CompareController,_ name: String) {
            guard let index = controller.profilePopup.itemArray.firstIndex(where:{ $0.title == name }) else { print("COMPARE SMOKE FAIL profile missing");exit(1) };choose(controller.profilePopup,index)
        }
        func select(_ controller: CompareController,_ path: String) {
            guard let row = controller.visibleRows.firstIndex(where:{ $0.id == path }) else { print("COMPARE SMOKE FAIL row missing "+path);exit(1) };controller.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        }
        let left = root.appendingPathComponent("Links"),right = root.appendingPathComponent("Rechts"),newTarget = right.appendingPathComponent("Neu.txt"),changedTarget = right.appendingPathComponent("Bericht.txt")
        guard let defaults = Preferences.compareTestDefaults else { print("COMPARE SMOKE FAIL isolated settings missing");exit(1) }
        self.main.window?.makeKeyAndOrderFront(nil);self.main.command("compare")
        let controller = self.main.secondaryWindows.compactMap { $0 as? CompareController }.last!
        check(controller.window?.isVisible == true && controller.comparison == nil && !controller.reviewButton.isEnabled,"compare command opens native workspace without an executable plan")
        check(controller.leftPath.stringValue == left.path && controller.rightPath.stringValue == right.path && controller.selectedProfileID == nil,"workspace uses both current pane roots without implicit profile")
        func cancellationAndProfiles() {
            var cancelled = false
            controller.onCompareProgress = {
                guard !cancelled else { return };cancelled = true
                check(controller.isComparing && !controller.compareButton.isEnabled && !self.main.canTerminate,"running comparison locks criteria and participates in close protection")
                controller.cancelButton.performClick(nil)
            }
            controller.beginCompare()
            waitFor({ !controller.isComparing && cancelled },then:{
                controller.onCompareProgress = nil
                check(controller.comparison == nil && controller.plan == nil && !controller.reviewButton.isEnabled && controller.info.stringValue.contains("abgebrochen"),"cancelled comparison cannot expose a partial executable preview")
                let original = defaults.data(forKey:Preferences.compareProfilesKey)!
                defaults.set(Data("{broken".utf8),forKey:Preferences.compareProfilesKey);controller.refreshProfiles()
                check(!controller.profileSaveAs.isEnabled && controller.profileStatus.stringValue == "Profile nicht lesbar","corrupt comparison profile storage disables writes inline")
                do { try Preferences.editCompareProfiles { try $0.save(name:"Overwrite",options:CompareOptions()) };check(false,"corrupt profile bytes preserved") }
                catch { check(defaults.data(forKey:Preferences.compareProfilesKey) == Data("{broken".utf8),"corrupt profile bytes preserved") }
                defaults.set("wrong type",forKey:Preferences.compareProfilesKey)
                do { _ = try Preferences.compareProfiles();check(false,"wrong storage type rejected") }
                catch { check(defaults.string(forKey:Preferences.compareProfilesKey) == "wrong type","wrong storage type rejected") }
                defaults.set(original,forKey:Preferences.compareProfilesKey);controller.refreshProfiles();loadProfile(controller,"Projektabgleich")
                controller.profileRemove.performClick(nil)
                waitFor({ controller.deleteAlert?.window.sheetParent != nil },then:{
                    let alert = controller.deleteAlert!;controller.window?.endSheet(alert.window,returnCode:.alertSecondButtonReturn);alert.window.orderOut(nil)
                    waitFor({ controller.window?.attachedSheet == nil },then:{
                        check((try? Preferences.compareProfiles().profiles.count) == 2,"cancelled profile deletion leaves library unchanged")
                        controller.profileRemove.performClick(nil)
                        waitFor({ controller.deleteAlert?.window.sheetParent != nil },then:{
                            let alert = controller.deleteAlert!;controller.window?.endSheet(alert.window,returnCode:.alertFirstButtonReturn);alert.window.orderOut(nil)
                            waitFor({ (try? Preferences.compareProfiles().profiles.count) == 1 },then:{
                                check(controller.include.stringValue == "*.txt" && controller.leftPath.stringValue == left.path,"profile deletion retains current rules and root paths")
                                controller.close();finish()
                            })
                        })
                    })
                })
            })
        }
        func stalePlan() {
            controller.beginCompare()
            waitFor({ !controller.isPreparingPlan && controller.plan != nil },then:{
                try! Data("EDIT".utf8).write(to:left.appendingPathComponent("Bericht.txt"));controller.reviewButton.performClick(nil)
                waitFor({ controller.reviewWindow?.window?.sheetParent != nil },then:{
                    controller.reviewWindow!.start.performClick(nil)
                    waitFor({ !controller.isWorking && self.main.jobs.pending == 0 },then:{
                        check(controller.info.textColor == .systemRed && controller.reportButton.isEnabled,"stale sync plan fails inline with a report")
                        check(!FileSystem.exists(newTarget) && (try? String(contentsOf:changedTarget,encoding:.utf8)) == "alt","stale source is rejected before any target mutation")
                        check((try? String(contentsOf:left.appendingPathComponent("Bericht.txt"),encoding:.utf8)) == "EDIT","external source edit remains intact")
                        var report = "";controller.onReport = { report = $0 };controller.reportButton.performClick(nil)
                        check(report.contains("Quelle seit Vergleich verändert") && report.contains("0 abgeschlossen"),"native report explains the failed preflight")
                        cancellationAndProfiles()
                    })
                })
            })
        }
        if reload {
            check((try? Preferences.compareProfiles().profiles.count) == 2,"comparison profiles survive a separate app process")
            loadProfile(controller,"Projektabgleich")
            check(controller.include.stringValue == "*.txt" && controller.excludedFolders.stringValue == "Cache*" && controller.tolerance.stringValue == "2","explicit profile restores matching mode filters and tolerance")
            check(controller.leftPath.stringValue == left.path && controller.rightPath.stringValue == right.path,"loading profile preserves both current root paths")
            controller.beginCompare()
            waitFor({ !controller.isPreparingPlan && controller.plan != nil },then:{
                check(controller.directions["Bericht.txt"] == .leftToRight && controller.directions["Nur rechts.txt"] == .rightToLeft,"profile rebuilds suggestions instead of persisting old per-row decisions")
                check(controller.plan?.steps.count == 5 && controller.plan?.steps.filter(\.replacing).count == 1,"plan includes exact selected copies and required parent directory")
                controller.reviewButton.performClick(nil)
                waitFor({ controller.reviewWindow?.window?.sheetParent != nil },then:{
                    let review = controller.reviewWindow!;check(review.table.numberOfRows == 5,"review lists all concrete source and destination steps")
                    capture(review.window,"-Synchronisationsplan");review.queue.performClick(nil)
                    waitFor({ controller.isWorking && self.main.jobs.pending == 1 },then:{
                        check(!self.main.canTerminate && !controller.windowShouldClose(controller.window!) && !controller.reviewButton.isEnabled,"queued session sync locks its workspace and blocks quitting")
                        check(!FileSystem.exists(newTarget) && self.main.jobs.active == nil,"queued plan performs no filesystem writes")
                        controller.cancelButton.performClick(nil)
                        waitFor({ !controller.isWorking && self.main.jobs.pending == 0 },then:{
                            check(!FileSystem.exists(newTarget) && controller.plan == nil,"own queued cancellation finishes once without copying")
                            controller.beginCompare()
                            waitFor({ !controller.isPreparingPlan && controller.plan != nil },then:{
                                controller.reviewButton.performClick(nil)
                                waitFor({ controller.reviewWindow?.window?.sheetParent != nil },then:{
                                    controller.reviewWindow!.start.performClick(nil)
                                    waitFor({ !controller.isWorking && self.main.jobs.pending == 0 },then:{
                                        check((try? String(contentsOf:changedTarget,encoding:.utf8)) == "neu" && (try? String(contentsOf:newTarget,encoding:.utf8)) == "neu links","native execution copies and replaces exact selected left files")
                                        check((try? String(contentsOf:left.appendingPathComponent("Nur rechts.txt"),encoding:.utf8)) == "rechts" && (try? String(contentsOf:right.appendingPathComponent("Nur rechts.txt"),encoding:.utf8)) == "rechts","mixed directions copy right-only file without deleting original")
                                        check((try? String(contentsOf:right.appendingPathComponent("Unterordner/Kind.txt"),encoding:.utf8)) == "Kind","required parent and selected child are created")
                                        check((try? String(contentsOf:left.appendingPathComponent("Konflikt.txt"),encoding:.utf8)) == "Datei" && (try? String(contentsOf:right.appendingPathComponent("Konflikt.txt/Kind.txt"),encoding:.utf8)) == "behalten","blocked type conflict and descendants remain unchanged")
                                        check(self.main.undoSteps.count == 4 && self.main.undoSteps.contains { $0.backup != nil },"completed native sync retains file undo and replaced content backup")
                                        check(controller.plan == nil && !controller.reviewButton.isEnabled && controller.info.stringValue.contains("5 Schritte"),"completed workspace requires fresh comparison before another execution")
                                        self.main.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                                        waitFor({ NSApp.keyWindow === self.main.window },then:{
                                            self.main.command("undo")
                                            waitFor({ self.main.jobs.pending == 0 && self.main.undoSteps.isEmpty },then:{
                                                check((try? String(contentsOf:changedTarget,encoding:.utf8)) == "alt" && !FileSystem.exists(newTarget),"main undo restores old target and removes copied files")
                                                check(FileSystem.isDirectory(right.appendingPathComponent("Unterordner")) && !FileSystem.exists(right.appendingPathComponent("Unterordner/Kind.txt")),"undo preserves created directory while reverting its file")
                                                stalePlan()
                                            })
                                        })
                                    })
                                })
                            })
                        })
                    })
                })
            })
            return
        }
        controller.include.stringValue = "*.txt";controller.exclude.stringValue = "Weg*";controller.excludedFolders.stringValue = "Cache*";controller.hidden.state = .off;controller.strategy.selectItem(at:2);controller.beginCompare()
        waitFor({ !controller.isPreparingPlan && controller.plan != nil },then:{
            check(controller.rows.first { $0.id == "Gleich.txt" }?.state == .equal && controller.rows.first { $0.id == "Bericht.txt" }?.state == .different,"native content comparison distinguishes equal and changed files")
            check(!controller.rows.contains { $0.id.contains("Cache") || $0.id.contains("Weg") || $0.id.hasPrefix(".") },"native filters prune excluded folders names and hidden files")
            check(controller.rows.first { $0.id == "Konflikt.txt" }?.state == .typeConflict && controller.rows.first { $0.id == "Konflikt.txt/Kind.txt" }?.state == .blocked,"native comparison exposes blocking ancestor type conflict")
            check(controller.directions["Nur rechts.txt"] == .rightToLeft && controller.directions["Neu.txt"] == .leftToRight,"newer-and-missing preset suggests both copy directions")
            choose(controller.statusFilter,4);check(controller.visibleRows.count == 2,"status filter shows type conflict and blocked child")
            choose(controller.statusFilter,0);controller.resultFilter.stringValue = "Bericht";controller.filterRows();check(controller.visibleRows.count == 1,"path filter preserves full comparison under the visible list")
            controller.resultFilter.stringValue = "";controller.filterRows();select(controller,"Bericht.txt")
            var preview: URL?;controller.onPreview = { preview = $0 };controller.previewRight.performClick(nil)
            check(preview?.lastPathComponent == "Bericht.txt" && preview?.deletingLastPathComponent().lastPathComponent == "Rechts","right preview action uses right comparison source")
            controller.revealLeft.performClick(nil)
            waitFor({ self.main.left.selectedURLs.contains { $0.lastPathComponent == "Bericht.txt" } },then:{
                check(FileSystem.canonical(self.main.left.currentURL) == FileSystem.canonical(left),"mark action selects row file in its corresponding pane")
                NSApp.activate(ignoringOtherApps:true);controller.window?.makeKeyAndOrderFront(nil)
                waitFor({ self.main.keyCompareController === controller },then:{
                    controller.window?.makeFirstResponder(controller.table);self.main.command("trash")
                    check(!controller.canPerformCommand("trash") && FileSystem.exists(changedTarget),"unsupported main delete command cannot act on another pane selection")
                    let actionColumn = controller.table.tableColumns.firstIndex { $0.identifier.rawValue == "action" }!,row = controller.table.selectedRow
                    let popup = controller.table.view(atColumn:actionColumn,row:row,makeIfNecessary:true) as! NSPopUpButton
                    choose(popup,2)
                    waitFor({ !controller.isPreparingPlan && controller.plan != nil },then:{
                        check(controller.directions["Bericht.txt"] == .rightToLeft,"per-row native popup changes copy direction")
                        controller.skip.performClick(nil)
                        waitFor({ !controller.isPreparingPlan && controller.plan != nil },then:{
                            check(controller.directions["Bericht.txt"] == .skip && controller.plan?.steps.filter(\.replacing).isEmpty == true,"selection skip removes replacement from executable preview")
                            check(controller.selectedRows.map(\.id) == ["Bericht.txt"],"changing the selection decision preserves selected result identity")
                            capture(controller.window,"-Ordnervergleich");controller.reviewButton.performClick(nil)
                            waitFor({ controller.reviewWindow?.window?.sheetParent != nil },then:{
                                check(!FileSystem.exists(newTarget) && controller.reviewWindow?.plan.steps.count == 4,"review is a concrete non-writing preview")
                                waitFor({ self.main.keyCompareController === controller },then:{
                                    self.main.command("trash")
                                    check(!controller.canPerformCommand("trash") && !controller.canPerformCommand("refresh") && FileSystem.exists(changedTarget),"review sheet routes menu validation to its comparison workspace")
                                    self.main.command("closeTab")
                                waitFor({ controller.window?.attachedSheet == nil },then:{
                                    check(!controller.isWorking && !FileSystem.exists(newTarget),"cancelling review performs no copy")
                                    controller.profileSaveAs.performClick(nil);let naming = controller.profileNameWindow!
                                    naming.name.stringValue = "";naming.save.performClick(nil);check(!naming.info.stringValue.isEmpty && controller.window?.attachedSheet != nil,"invalid profile name stays in native naming sheet")
                                    naming.name.stringValue = "Projektabgleich";naming.save.performClick(nil)
                                    let library = try! Preferences.compareProfiles(),data = try! library.encoded()
                                    check(library.profiles.count == 1 && library.profiles[0].options == (try? controller.options()),"profile saves complete comparison options and strategy")
                                    check(!String(decoding:data,as:UTF8.self).contains(root.path) && !String(decoding:data,as:UTF8.self).contains("Bericht.txt"),"profile saves neither root paths nor per-file decisions")
                                    let other = CompareController(left:right,right:left);self.main.secondaryWindows.append(other);other.showWindow(nil);other.include.stringValue = "unsaved*"
                                    controller.tolerance.stringValue = "2";controller.profileSave.performClick(nil)
                                    check(other.include.stringValue == "unsaved*" && other.profilePopup.itemArray.contains { $0.title == "Projektabgleich" },"profile notifications preserve other windows unsaved rules")
                                    var options = CompareOptions();options.strategy = .missingBoth;options.mode = .sizeAndDate;controller.setOptions(options)
                                    check(controller.plan == nil && !controller.reviewButton.isEnabled,"changing rules immediately invalidates executable preview")
                                    controller.profileSaveAs.performClick(nil);let second = controller.profileNameWindow!;second.name.stringValue = "Nur Fehlende";second.save.performClick(nil)
                                    check((try? Preferences.compareProfiles().profiles.count) == 2,"separate comparison profiles retain different modes and strategies")
                                    controller.tolerance.stringValue = "invalid";controller.beginCompare();check(!controller.isComparing && controller.info.textColor == .systemRed,"invalid tolerance is reported before a scan starts")
                                    other.close();controller.close();finish()
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
