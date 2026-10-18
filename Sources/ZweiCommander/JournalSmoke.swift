import AppKit
import CommanderCore
import Darwin

extension AppDelegate {
    func runJournalSmoke(root: URL,prefix: String,phase: String) {
        var failures: [String] = [],checks = 0
        func check(_ condition: Bool,_ name: String) { checks += 1;print("JOURNAL UI \(condition ? "PASS" : "FAIL") \(name)");if !condition { failures.append(name) } }
        func finish(_ abrupt: Bool = false) {
            print("JOURNAL SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");fflush(stdout)
            if !failures.isEmpty { exit(1) };if abrupt { _exit(0) };NSApp.terminate(nil)
        }
        func capture(_ window: NSWindow?,_ suffix: String) {
            guard let view = window?.contentView else { return };view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
            view.cacheDisplay(in:view.bounds,to:rep)
            try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
        }
        func waitFor(_ condition: @escaping () -> Bool,completion: @escaping () -> Void,attempt: Int = 0) {
            if condition() { completion();return }
            guard attempt < 150 else { print("JOURNAL SMOKE FAIL timed out");exit(1) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitFor(condition,completion:completion,attempt:attempt+1) }
        }
        let jobs = main.jobs,left = root.appendingPathComponent("Links"),right = root.appendingPathComponent("Rechts")
        if phase == "damaged" {
            check(jobs.journal == nil && jobs.journalError != nil,"damaged storage reported")
            let file = root.appendingPathComponent("Auftragsablage/journal.json")
            check((try? String(contentsOf:file,encoding:.utf8)) == "{broken","damaged bytes preserved")
            do {
                let plan = try TransferPlanner.prepare([left.appendingPathComponent("Umzug.txt")],to:right,kind:.move,policy:.stop)
                do { try jobs.submitTransfer(plan,start:true,completion:{ _ in });check(false,"transfer refused without durable storage") }
                catch { check(true,"transfer refused without durable storage") }
            } catch { print("JOURNAL SMOKE FAIL "+error.localizedDescription);exit(1) }
            check(jobs.scheduler.snapshots.isEmpty && !FileSystem.exists(right.appendingPathComponent("Umzug.txt")),"refused transfer has no effects")
            self.main.showOperations();check(self.main.operationWindow?.summary.stringValue.contains("nicht verfügbar") == true,"visible storage error")
            finish();return
        }
        guard let journal = jobs.journal,jobs.journalError == nil else { print("JOURNAL SMOKE FAIL storage unavailable: "+(jobs.journalError ?? "nil"));exit(1) }
        if phase == "save" {
            do {
                var filter = TransferFilter();filter.include = "*.txt";filter.minimumSize = 2;filter.keepEmptyFolders = false;filter.excludedFolders = "Cache"
                var plan = try TransferPlanner.prepare([left.appendingPathComponent("Projekt"),left.appendingPathComponent("Weglassen.txt")],to:right,kind:.copy,policy:.stop,filter:filter,mergeFolders:true)
                plan = plan.selecting(Set(plan.entries.filter { $0.source.lastPathComponent == "Projekt" }.map(\.id)))
                for action in plan.merge!.actions where action.conflict { plan = try plan.resolving(action.id,with:.replace) }
                check(self.main.enqueueTransfer(plan,start:false),"copy staged before scheduling")
                let move = try TransferPlanner.prepare([left.appendingPathComponent("Umzug.txt")],to:root.appendingPathComponent("Sicherung"),kind:.move,policy:.stop)
                check(self.main.enqueueTransfer(move,start:false),"move staged before scheduling")
                let list = jobs.scheduler.snapshots,copyID = list[0].id,moveID = list[1].id
                check(journal.entry(copyID)?.intent.sources.count == 1,"only selected sources persisted")
                check(journal.entry(copyID)?.intent.filter == filter,"copy criteria persisted")
                let queue = self.main.operationWindow!;queue.select(moveID);queue.up.performClick(nil)
                check(journal.entries.map(\.id) == [moveID,copyID],"queue order persisted")
                check(jobs.scheduler.isHeld && list.allSatisfy { $0.state == .waiting },"saved jobs remain held")
                check(self.main.canTerminate,"quit allowed with durable waiting transfers")
                check((try? String(contentsOf:right.appendingPathComponent("Projekt/a.txt"),encoding:.utf8)) == "old" && FileSystem.exists(left.appendingPathComponent("Umzug.txt")),"staging does not modify source or target")
                try Data("new since staging".utf8).write(to:left.appendingPathComponent("Projekt/Neu seit Vormerkung.txt"))
                capture(queue.window,"-Gespeicherte-Auftraege");finish()
            } catch { print("JOURNAL SMOKE FAIL "+error.localizedDescription);exit(1) }
            return
        }
        if phase == "reload" {
            let list = jobs.scheduler.snapshots
            check(list.count == 2 && list.allSatisfy { $0.state == .review },"unfinished transfers restored for review")
            check(journal.entries.map { $0.intent.kind } == [.move,.copy],"order and transfer kind survive process restart")
            check(jobs.active == nil && jobs.pending == 0,"no automatic restart")
            check((try? String(contentsOf:right.appendingPathComponent("Projekt/a.txt"),encoding:.utf8)) == "old" && FileSystem.exists(left.appendingPathComponent("Umzug.txt")),"restart has no transfer effects")
            self.main.showOperations()
            guard let copy = journal.entries.first(where: { $0.intent.kind == .copy }),let move = journal.entries.first(where: { $0.intent.kind == .move }),let queue = self.main.operationWindow else { exit(1) }
            queue.select(copy.id)
            check(!queue.start.isEnabled && queue.review.isEnabled && queue.remove.isEnabled,"review controls replace direct start")
            jobs.clearFinished();check(jobs.scheduler.snapshots.count == 2 && journal.entries.count == 2,"clear finished retains recovery records")
            capture(queue.window,"-Neustart-Auftraege")
            queue.review.performClick(nil)
            guard let setup = self.main.secondaryWindows.last as? TransferSetupController else { exit(1) }
            waitFor({ setup.plan != nil },completion:{
                check(setup.filter == copy.intent.filter && setup.mergeFolders.state == .on,"review restores filter and merge settings")
                check(setup.previewCount == 4,"fresh plan includes source added after staging")
                check(setup.plan?.merge?.unresolvedCount == 1 && !setup.startButton.isEnabled,"individual decisions require renewed choice")
                check(setup.safety.stringValue.contains("Neuer Dateiplan"),"review explains restart behavior")
                setup.tabs.selectTabViewItem(at:1);capture(setup.window,"-Neustart-Pruefung")
                if let row = (0..<setup.previewCount).first(where: { setup.previewObject(at:$0)?.source.lastPathComponent == "a.txt" }),let popup = setup.filesTable.view(atColumn:1,row:row,makeIfNecessary:true) as? NSPopUpButton,let index = popup.itemArray.firstIndex(where: { $0.representedObject as? String == MergeDecision.skip.rawValue }) {
                    popup.selectItem(at:index);setup.changeDecision(popup)
                    check(true,"visible renewed conflict choice")
                } else { check(false,"visible renewed conflict choice") }
                check(setup.plan?.merge?.unresolvedCount == 0 && setup.startButton.isEnabled,"renewed decision enables start")
                setup.queueButton.performClick(nil)
                let renewed = jobs.scheduler.snapshots.first { $0.state == .waiting }!
                check(renewed.id != copy.id && journal.entry(copy.id) == nil && journal.entry(renewed.id) != nil,"new reviewed plan replaces old record atomically")
                queue.select(renewed.id);queue.start.performClick(nil)
                waitFor({ jobs.pending == 0 },completion:{
                    check(jobs.scheduler.snapshots.first(where: { $0.id == renewed.id })?.state == .completed,"renewed copy completes")
                    check((try? String(contentsOf:right.appendingPathComponent("Projekt/a.txt"),encoding:.utf8)) == "old","renewed skip preserves existing target")
                    check(FileSystem.exists(right.appendingPathComponent("Projekt/Neu seit Vormerkung.txt")) && FileSystem.exists(right.appendingPathComponent("Projekt/b.txt")),"fresh matching files copied")
                    check(!FileSystem.exists(right.appendingPathComponent("Weglassen.txt")) && !FileSystem.exists(right.appendingPathComponent("Projekt/Cache")),"saved selection and filters still apply")
                    check(FileSystem.exists(left.appendingPathComponent("Umzug.txt")) && !FileSystem.exists(root.appendingPathComponent("Sicherung/Umzug.txt")),"unreviewed move never runs")
                    queue.select(move.id);queue.remove.performClick(nil)
                    check(journal.entry(move.id) == nil && FileSystem.exists(left.appendingPathComponent("Umzug.txt")),"discard recovery removes only its record")
                    jobs.clearFinished();check(journal.entries.isEmpty,"clear finished removes persisted history")
                    let generic = jobs.submitReported("Sitzungstest",start:false,body:{ _,_ in true },completion:{ _ in })
                    check(!self.main.canTerminate,"unsaved session job still blocks quit")
                    jobs.remove(generic);jobs.clearFinished()
                    do {
                        let temporary = self.main.cache.appendingPathComponent("Archivdatei.txt")
                        try Data("temporary archive contents".utf8).write(to:temporary)
                        let plan = try TransferPlanner.prepare([temporary],to:root.appendingPathComponent("Sicherung"),kind:.copy,policy:.stop)
                        let id = try jobs.submitTransfer(plan,start:false,completion:{ _ in })
                        check(!self.main.canTerminate,"temporary archive sources block quit until handled")
                        jobs.remove(id);jobs.clearFinished()
                        check(self.main.canTerminate && FileSystem.exists(temporary),"removing temporary job permits orderly cache cleanup on quit")
                    } catch { print("JOURNAL SMOKE FAIL "+error.localizedDescription);exit(1) }
                    finish()
                })
            });return
        }
        let crashLeft = root.appendingPathComponent("AbbruchLinks"),crashRight = root.appendingPathComponent("AbbruchRechts")
        let small = crashLeft.appendingPathComponent("A-Fertig.txt"),large = crashLeft.appendingPathComponent("Z-Daten.bin")
        if phase == "write-failure" {
            do {
                let target = root.appendingPathComponent("FehlerRechts"),nextTarget = root.appendingPathComponent("FehlerDanach")
                let plan = try TransferPlanner.prepare([small,large],to:target,kind:.copy,policy:.stop)
                let first = try jobs.submitTransfer(plan,start:false,completion:{ _ in })
                let next = try TransferPlanner.prepare([small],to:nextTarget,kind:.copy,policy:.stop)
                let second = try jobs.submitTransfer(next,start:false,completion:{ _ in })
                check(journal.entries.count == 2,"failure fixtures staged durably")
                var injected = false
                jobs.transferProgressObserver = { progress in
                    guard !injected,let item = progress.items.first(where: { $0.source == large }),item.state == .running,item.bytes > 0,item.bytes < item.totalBytes else { return }
                    injected = true
                    check(journal.entry(first)?.snapshot.state == .running,"running state stored before external change")
                    do { try Data("external edit".utf8).write(to:journal.file,options:.atomic);check(true,"external journal change injected during copy") }
                    catch { print("JOURNAL SMOKE FAIL "+error.localizedDescription);exit(1) }
                }
                jobs.scheduler.start(first)
                waitFor({ jobs.scheduler.snapshots.first(where: { $0.id == first })?.state == .cancelled },completion:{
                    check(jobs.journalError != nil && jobs.active == nil && jobs.scheduler.isHeld,"storage failure stops active transfer and holds queue")
                    check(jobs.scheduler.snapshots.first(where: { $0.id == second })?.state == .waiting,"next transfer remains waiting")
                    check(FileSystem.exists(target.appendingPathComponent("A-Fertig.txt")) && !FileSystem.exists(target.appendingPathComponent("Z-Daten.bin")),"completed file retained and partial copy unpublished")
                    check(!FileSystem.exists(nextTarget.appendingPathComponent("A-Fertig.txt")),"queue does not continue after storage failure")
                    check((try? String(contentsOf:journal.file,encoding:.utf8)) == "external edit","external journal data never overwritten")
                    self.main.showOperations(select:second)
                    check(self.main.operationWindow?.start.isEnabled == false && self.main.operationWindow?.summary.stringValue.contains("nicht verfügbar") == true,"storage failure visible and start disabled")
                    capture(self.main.operationWindow?.window,"-Auftrag-Speicherfehler")
                    jobs.remove(second);check(self.main.canTerminate,"quit possible after removing remaining session work");finish()
                })
            } catch { print("JOURNAL SMOKE FAIL "+error.localizedDescription);exit(1) }
            return
        }
        if phase == "crash" {
            do {
                let plan = try TransferPlanner.prepare([small,large],to:crashRight,kind:.copy,policy:.stop)
                let id = try jobs.submitTransfer(plan,start:false,completion:{ _ in print("JOURNAL SMOKE FAIL crash point not reached");exit(1) })
                check(journal.entry(id)?.snapshot.state == .waiting,"crash fixture intent durable")
                jobs.transferProgressObserver = { progress in
                    guard let item = progress.items.first(where: { $0.source == large }),item.state == .running,item.bytes > 0,item.bytes < item.totalBytes else { return }
                    let saved = journal.entry(id)!
                    check(saved.snapshot.state == .running,"running state durable before simulated exit")
                    check(saved.snapshot.items.first(where: { $0.source == large })?.bytes ?? 0 > 0,"partial byte progress durable")
                    check(saved.snapshot.items.first(where: { $0.source == small })?.state == .completed,"completed object durable")
                    check(FileSystem.exists(crashRight.appendingPathComponent("A-Fertig.txt")),"completed output published")
                    check(!FileSystem.exists(crashRight.appendingPathComponent("Z-Daten.bin")),"partial output unpublished")
                    check(FileSystem.exists(small) && FileSystem.exists(large),"copy sources preserved")
                    finish(true)
                }
                jobs.scheduler.start(id)
            } catch { print("JOURNAL SMOKE FAIL "+error.localizedDescription);exit(1) }
            return
        }
        if phase == "recover" {
            guard let entry = journal.entries.first else { print("JOURNAL SMOKE FAIL missing crash record");exit(1) }
            check(entry.snapshot.state == .running && jobs.scheduler.snapshots.first?.state == .review,"interrupted running job requires review")
            check((entry.snapshot.transferredBytes ?? 0) > 0 && (entry.snapshot.fraction ?? 1) < 1,"last partial aggregate preserved")
            check(entry.snapshot.items.first?.state == .completed,"completed object remains visible after restart")
            check(jobs.active == nil && !FileSystem.exists(crashRight.appendingPathComponent("Z-Daten.bin")),"interrupted copy does not resume automatically")
            self.main.showOperations(select:entry.id);capture(self.main.operationWindow?.window,"-Unterbrochener-Auftrag")
            let oldNumber = (try? FileManager.default.attributesOfItem(atPath:crashRight.appendingPathComponent("A-Fertig.txt").path))?[.systemFileNumber] as? NSNumber
            guard let setup = self.main.reviewTransfer(entry.id) else { exit(1) }
            waitFor({ setup.plan != nil },completion:{
                check(setup.plan?.entries.first(where: { $0.source == small })?.conflict == true,"fresh plan sees previously completed output")
                check(setup.plan?.entries.first(where: { $0.source == large })?.conflict == false,"fresh plan sees unpublished output as missing")
                setup.policy.selectItem(at:ConflictPolicy.allCases.firstIndex(of:.skip)!);setup.rebuild()
                waitFor({ setup.plan?.policy == .skip },completion:{
                    setup.startButton.performClick(nil)
                    waitFor({ jobs.pending == 0 },completion:{
                        check(jobs.scheduler.snapshots.count == 1 && jobs.scheduler.snapshots.first?.state == .completed,"reviewed replacement job completes")
                        check(journal.entry(entry.id) == nil && journal.entries.first?.snapshot.state == .completed,"old interruption superseded durably")
                        let number = (try? FileManager.default.attributesOfItem(atPath:crashRight.appendingPathComponent("A-Fertig.txt").path))?[.systemFileNumber] as? NSNumber
                        check(oldNumber != nil && oldNumber == number,"skip preserves completed file identity")
                        check((try? Checksums.hash(large)) == (try? Checksums.hash(crashRight.appendingPathComponent("Z-Daten.bin"))),"new copy matches entire source")
                        check(FileSystem.exists(small) && FileSystem.exists(large),"recovery preserves source files")
                        check(jobs.scheduler.snapshots.first?.items.map(\.state) == [.skipped,.completed],"final item states reflect fresh decisions")
                        capture(self.main.operationWindow?.window,"-Neustart-Abgeschlossen")
                        jobs.clearFinished();check(journal.entries.isEmpty,"recovered history can be cleared");finish()
                    })
                })
            });return
        }
        print("JOURNAL SMOKE FAIL unknown phase");exit(1)
    }
}
