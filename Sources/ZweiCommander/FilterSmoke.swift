import AppKit
import CommanderCore

extension AppDelegate {
    func runFiltersSmoke(root: URL,prefix: String) {
        var failures: [String] = [],checks = 0
        func check(_ condition: Bool,_ name: String) { checks += 1;print("FILTER UI \(condition ? "PASS" : "FAIL") \(name)");if !condition { failures.append(name) } }
        func waitFor(_ condition: @escaping () -> Bool,then: @escaping () -> Void,attempt: Int = 0) {
            if condition() { then();return }
            guard attempt < 100 else { print("FILTER SMOKE FAIL timed out");exit(1) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitFor(condition,then:then,attempt:attempt+1) }
        }
        func capture(_ window: NSWindow?,_ suffix: String) {
            guard let view = window?.contentView else { return };view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return };view.cacheDisplay(in:view.bounds,to:rep)
            try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
        }
        func paths(_ setup: TransferSetupController) -> Set<String> { Set((0..<setup.previewCount).compactMap { setup.previewObject(at:$0)?.relativePath }) }
        let left = root.appendingPathComponent("Links"),right = root.appendingPathComponent("Rechts"),source = left.appendingPathComponent("Projekt"),readme = left.appendingPathComponent("README.md")
        let expected: Set<String> = ["Projekt","Projekt/Alias.txt","Projekt/Notizen.md","Projekt/Quellen","Projekt/Quellen/Hallo.txt","Projekt/Quellen/Tief","Projekt/Quellen/Tief/Notiz.MD","README.md"]
        main.transfer([source,readme,left.appendingPathComponent("Weglassen.tmp")],to:right,kind:.copy)
        guard let setup = main.secondaryWindows.last as? TransferSetupController else { print("FILTER SMOKE FAIL setup missing");exit(1) }
        func finishedCopy() {
            let queue = self.main.operationWindow!
            queue.refresh();check(self.main.jobs.scheduler.snapshots.last?.state == .completed,"filtered copy completed")
            do {
                var actual: Set<String> = []
                try FileSystem.walk(right) { actual.insert(try FileSystem.relativePath(of:$0,inside:right)) }
                check(actual == expected,"copied objects equal visible preview")
                check(try Checksums.hash(source.appendingPathComponent("Quellen/Hallo.txt")) == Checksums.hash(right.appendingPathComponent("Projekt/Quellen/Hallo.txt")),"copied contents match")
                check(try FileManager.default.destinationOfSymbolicLink(atPath:right.appendingPathComponent("Projekt/Alias.txt").path) == "../Privat","link copied without traversal")
            } catch { check(false,error.localizedDescription) }
            check(FileSystem.exists(source.appendingPathComponent(".git/geheim.txt")) && FileSystem.exists(source.appendingPathComponent("Cache42/bleibt.md")) && FileSystem.exists(source.appendingPathComponent("Leer")),"excluded sources retained")
            check(self.main.jobs.scheduler.snapshots.last?.transferredBytes == setup.plan?.bytes,"measured bytes match filtered plan")
            self.main.transfer([source],to:root.appendingPathComponent("Sicherung"),kind:.move)
            guard let move = self.main.secondaryWindows.last as? TransferSetupController else { check(false,"move setup missing");exit(1) }
            waitFor({ move.plan != nil },then:{
                check(move.include.isEnabled && move.excludedFolders.isEnabled && !move.structureOnly.isEnabled && move.plan?.filter == TransferFilter(),"move filters available while structure-only stays disabled")
                check((move.plan?.entries.first?.objectCount ?? 0) > 7,"move still plans full selection")
                move.close();check(FileSystem.exists(source) && !FileSystem.exists(root.appendingPathComponent("Sicherung/Projekt")),"move preview leaves source intact")
                print("FILTER SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
                if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
            })
        }
        func enqueueFiltered() {
            setup.queueButton.performClick(nil)
            check(self.main.jobs.scheduler.isHeld && self.main.jobs.scheduler.snapshots.last?.state == .waiting,"filtered plan queued without execution")
            let queue = self.main.operationWindow!;queue.refresh();queue.start.performClick(nil)
            waitFor({ self.main.jobs.pending == 0 },then:finishedCopy)
        }
        func checkFinalPlan() {
            check(paths(setup) == expected,"filtered preview paths and ancestors")
            check(setup.plan?.entries.count == 2 && setup.previewCount == 8,"filtered preview counts")
            if let row = setup.plan?.entries.firstIndex(where:{$0.source == readme}),let button = setup.table.view(atColumn:0,row:row,makeIfNecessary:true) as? NSButton {
                button.performClick(nil);check(!paths(setup).contains("README.md") && setup.previewCount == 7,"deselection updates detailed list")
                button.performClick(nil);check(paths(setup) == expected,"reselection restores detailed list")
            } else { check(false,"visible selection control") }
            setup.objectsButton.performClick(nil)
            check(setup.objectsButton.state == .on && setup.selectionButton.state == .off && setup.filesTable.numberOfRows == 8 && setup.filesTable.view(atColumn:1,row:0,makeIfNecessary:true) is NSTextField,"native detailed file table")
            capture(setup.window,"-Kopierfilter")
            setup.include.stringValue = "*.no-match";setup.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:setup.include));setup.prepare()
            waitFor({ setup.plan != nil && setup.plan?.entries.isEmpty == true },then:{
                check(!setup.startButton.isEnabled && !setup.queueButton.isEnabled && setup.previewCount == 0,"no matches disables submission")
                setup.include.stringValue = "*.txt;*.md";setup.prepare()
                waitFor({ setup.plan != nil && setup.plan?.entries.count == 2 },then:enqueueFiltered)
            })
        }
        func configureFinalFilter() {
            setup.structureOnly.performClick(nil)
            setup.include.stringValue = "*.txt;*.md";setup.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:setup.include))
            check(setup.plan == nil && !setup.startButton.isEnabled,"editing invalidates previous plan")
            setup.exclude.stringValue = "Nicht*";setup.excludedFolders.stringValue = ".git;Cache*"
            setup.keepEmpty.performClick(nil)
            waitFor({ setup.plan?.filter.include == "*.txt;*.md" && setup.plan?.filter.keepEmptyFolders == false },then:checkFinalPlan)
        }
        waitFor({ setup.plan != nil },then:{
            check(setup.previewCount > setup.plan!.entries.count,"initial preview includes descendants")
            setup.include.stringValue = "[";setup.regex.performClick(nil)
            waitFor({ setup.info.stringValue.hasPrefix("Ungültiger Filter") },then:{
                check(setup.plan == nil && !setup.startButton.isEnabled,"invalid regex blocks execution")
                setup.resetButton.performClick(nil)
                waitFor({ setup.plan?.filter == TransferFilter() },then:{
                    check(setup.startButton.isEnabled && setup.include.stringValue == "*","reset restores unrestricted plan")
                    setup.structureOnly.performClick(nil)
                    waitFor({ setup.plan?.filter.structureOnly == true },then:{
                        check((0..<setup.previewCount).allSatisfy { setup.previewObject(at:$0)?.kind == .directory } && setup.plan?.bytes == 0,"structure preview contains folders only")
                        check(!setup.include.isEnabled && !setup.keepEmpty.isEnabled && setup.keepEmpty.state == .on,"structure controls stay consistent")
                        setup.tabs.selectTabViewItem(at:1);capture(setup.window,"-Ordnerstruktur");setup.tabs.selectTabViewItem(at:0)
                        configureFinalFilter()
                    })
                })
            })
        })
    }
}
