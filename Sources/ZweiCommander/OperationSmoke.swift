import AppKit
import CommanderCore

extension AppDelegate {
    func runOperationsSmoke(root: URL,prefix: String) {
        var failures: [String] = [],checks = 0
        func check(_ condition: Bool,_ name: String) { checks += 1;print("OPS UI \(condition ? "PASS" : "FAIL") \(name)");if !condition { failures.append(name) } }
        func capture(_ window: NSWindow?,_ suffix: String) {
            guard let view = window?.contentView else { return };view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
            view.cacheDisplay(in:view.bounds,to:rep)
            try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
        }
        func waitFor(_ condition: @escaping () -> Bool,completion: @escaping () -> Void,attempt: Int = 0) {
            if condition() { completion();return }
            guard attempt < 100 else { print("OPS SMOKE FAIL timed out");exit(1) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitFor(condition,completion:completion,attempt:attempt+1) }
        }
        let left = root.appendingPathComponent("Links"),right = root.appendingPathComponent("Rechts")
        let source = left.appendingPathComponent("Testdaten.bin"),note = left.appendingPathComponent("Projektinfo.txt"),excluded = left.appendingPathComponent("Nicht kopieren.txt")
        main.transfer([source,note,excluded],to:right,kind:.copy)
        guard let setup = main.secondaryWindows.last as? TransferSetupController else { print("OPS SMOKE FAIL setup missing");exit(1) }
        waitFor({ setup.plan != nil },completion:{
            check(setup.plan?.entries.count == 3,"planned source rows")
            if let row = setup.plan?.entries.firstIndex(where:{$0.source == excluded}),let checkbox = setup.table.view(atColumn:0,row:row,makeIfNecessary:true) as? NSButton {
                checkbox.performClick(nil);check(checkbox.state == .off,"visible selection checkbox")
            } else { check(false,"visible selection checkbox") }
            check(setup.excluded.contains(excluded) && setup.startButton.isEnabled,"exclude row and enable submit")
            capture(setup.window,"-Kopierdialog")
            setup.queueButton.performClick(nil)
            let first = self.main.jobs.scheduler.snapshots.last!.id
            check(self.main.jobs.scheduler.isHeld && self.main.jobs.scheduler.snapshots.last?.state == .waiting,"hold queued transfer")
            check(self.main.jobs.scheduler.snapshots.last?.items.count == 2,"planned items in queue")
            do {
                let second = try TransferPlanner.prepare([note],to:root.appendingPathComponent("Sicherung"),kind:.copy,policy:.stop)
                let third = try TransferPlanner.prepare([note],to:root.appendingPathComponent("Entwurf"),kind:.copy,policy:.stop)
                self.main.enqueueTransfer(second,start:false);self.main.enqueueTransfer(third,start:false)
            } catch { print("OPS SMOKE FAIL "+error.localizedDescription);exit(1) }
            let queue = self.main.operationWindow!,third = self.main.jobs.scheduler.snapshots.last!.id
            queue.select(third);queue.up.performClick(nil)
            let waiting = self.main.jobs.scheduler.snapshots.filter { $0.state == .waiting }.map(\.id)
            check(waiting.count == 3 && waiting[1] == third,"reorder waiting row")
            queue.remove.performClick(nil)
            check(self.main.jobs.scheduler.snapshots.first { $0.id == third }?.state == .cancelled,"remove waiting row")
            queue.select(first)
            // Pause before the worker's first checkpoint; the core tests separately pause during native data copying.
            self.main.jobs.scheduler.start(first);self.main.jobs.scheduler.pause()
            waitFor({ self.main.jobs.scheduler.snapshots.first { $0.id == first }?.state == .paused },completion:{
                queue.refresh();check(queue.pause.title == "Fortsetzen","acknowledged paused state")
                check(!FileSystem.exists(right.appendingPathComponent("Testdaten.bin")),"paused destination unpublished")
                capture(queue.window,"-Auftraege")
                queue.pause.performClick(nil)
                waitFor({ self.main.jobs.pending == 0 },completion:{
                    queue.refresh()
                    let snapshots = self.main.jobs.scheduler.snapshots
                    check(snapshots.filter { $0.state == .completed }.count == 2,"resume and drain queue")
                    check(FileSystem.exists(right.appendingPathComponent("Testdaten.bin")) && FileSystem.exists(right.appendingPathComponent("Projektinfo.txt")),"selected files copied")
                    check(!FileSystem.exists(right.appendingPathComponent("Nicht kopieren.txt")),"excluded file untouched")
                    check(!FileSystem.exists(root.appendingPathComponent("Entwurf/Projektinfo.txt")),"removed job has no side effects")
                    check(snapshots.first { $0.id == first }?.fraction == 1 && snapshots.first { $0.id == first }?.items.allSatisfy { $0.state == .completed } == true,"completed byte progress and item states")
                    capture(queue.window,"-Abgeschlossen")
                    print("OPS SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
                    if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
                })
            })
        })
    }
}
