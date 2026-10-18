import AppKit
import CommanderCore

extension AppDelegate {
    func runMergeSmoke(root: URL,prefix: String) {
        var failures: [String] = [],checks = 0
        func check(_ condition: Bool,_ name: String) { checks += 1;print("MERGE UI \(condition ? "PASS" : "FAIL") \(name)");if !condition { failures.append(name) } }
        func waitFor(_ condition: @escaping () -> Bool,then: @escaping () -> Void,attempt: Int = 0) {
            if condition() { then();return }
            guard attempt < 100 else { print("MERGE SMOKE FAIL timed out");exit(1) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitFor(condition,then:then,attempt:attempt+1) }
        }
        func capture(_ window: NSWindow?,_ suffix: String) {
            guard let view = window?.contentView else { return };view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return };view.cacheDisplay(in:view.bounds,to:rep)
            try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
        }
        let left = root.appendingPathComponent("Links"),right = root.appendingPathComponent("Rechts"),source = left.appendingPathComponent("Projekt"),target = right.appendingPathComponent("Projekt")
        func text(_ relative: String) -> String? { try? String(contentsOf:target.appendingPathComponent(relative),encoding:.utf8) }
        main.transfer([source],to:right,kind:.copy)
        guard let setup = main.secondaryWindows.last as? TransferSetupController else { print("MERGE SMOKE FAIL setup missing");exit(1) }
        func row(_ name: String) -> Int? { (0..<setup.previewCount).first { setup.previewObject(at:$0)?.source.lastPathComponent == name } }
        func choose(_ name: String,_ decision: MergeDecision) {
            guard let index = row(name),let popup = setup.filesTable.view(atColumn:1,row:index,makeIfNecessary:true) as? NSPopUpButton,
                  let choice = popup.itemArray.firstIndex(where: { $0.representedObject as? String == decision.rawValue }) else { check(false,"native decision menu for "+name);return }
            popup.selectItem(at:choice);_ = popup.sendAction(popup.action,to:popup.target)
            check(setup.plan?.merge?.action(for:source.appendingPathComponent(name))?.decision == decision,"native decision applied: "+name)
        }
        func finished() {
            let queue = self.main.operationWindow!;queue.refresh()
            let snapshot = self.main.jobs.scheduler.snapshots.last
            check(snapshot?.state == .completed,"merge completed")
            check(text("neu.txt") == "neu\n" && text("Unterordner/neu.md") == "# neu\n","new and nested files copied")
            check(text("nur-im-Ziel.txt") == "extra\n","extra target file preserved")
            check(text("lassen.txt") == "alt lassen\n","skipped target file preserved")
            check(text("beide.txt") == "alt beide\n" && text("beide (2).txt") == "neu beide\n","frozen alternate name used")
            check(text("ersetzen.txt") == "neu ersetzen\n","replacement published")
            let backups = ((try? FileManager.default.contentsOfDirectory(at:target,includingPropertiesForKeys:nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(".zweicommander-backup-") }
            check(backups.count == 1 && (try? String(contentsOf:backups[0],encoding:.utf8)) == "alt ersetzen\n","previous replacement backed up")
            check((try? FileManager.default.destinationOfSymbolicLink(atPath:target.appendingPathComponent("Typkonflikt").path)) == root.appendingPathComponent("Privat").path && !FileSystem.exists(root.appendingPathComponent("Privat/gesperrt.txt")),"directory-link conflict never traversed")
            check(!FileSystem.exists(target.appendingPathComponent("ausgelassen.bin")) && FileSystem.exists(target.appendingPathComponent("LeererOrdner")),"filter and empty-folder rules retained")
            check(snapshot?.items.filter { $0.state == .skipped }.count == 3 && snapshot?.fraction == 1 && snapshot?.transferredBytes == setup.plan?.bytes,"per-object states and measured bytes")
            capture(queue.window,"-Zusammengefuehrt")
            self.main.transfer([source],to:root.appendingPathComponent("Sicherung"),kind:.move)
            guard let move = self.main.secondaryWindows.last as? TransferSetupController else { print("MERGE SMOKE FAIL move setup missing");exit(1) }
            waitFor({ move.plan != nil },then:{
                check(!move.mergeFolders.isEnabled && move.plan?.merge == nil,"move merge option disabled")
                move.close();check(FileSystem.exists(source) && !FileSystem.exists(root.appendingPathComponent("Sicherung/Projekt")),"move preview has no effects")
                print("MERGE SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
                if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
            })
        }
        func configureConflicts() {
            check(setup.plan?.merge?.unresolvedCount == 4 && !setup.startButton.isEnabled && !setup.queueButton.isEnabled,"unresolved conflicts block submission")
            check(!((0..<setup.previewCount).contains { setup.previewObject(at:$0)?.source.lastPathComponent == "ausgelassen.bin" }),"filter reflected in merge preview")
            setup.objectsButton.performClick(nil)
            check(setup.filesTable.tableColumns.map(\.identifier.rawValue) == ["path","action","size","targetSize","sourceDate","targetDate"],"source and target metadata columns")
            if let index = row("ersetzen.txt"),let action = setup.plan?.merge?.action(for:source.appendingPathComponent("ersetzen.txt")),let sourceDate = setup.filesTable.view(atColumn:4,row:index,makeIfNecessary:true) as? NSTextField,
               let targetDate = setup.filesTable.view(atColumn:5,row:index,makeIfNecessary:true) as? NSTextField {
                check(action.sourceInfo.modified > action.targetInfo!.modified && sourceDate.stringValue != targetDate.stringValue,"newer source and target dates visible")
            } else { check(false,"date metadata visible") }
            if let index = row("Typkonflikt"),let popup = setup.filesTable.view(atColumn:1,row:index,makeIfNecessary:true) as? NSPopUpButton {
                check(popup.numberOfItems == 2 && setup.plan?.merge?.action(for:source.appendingPathComponent("Typkonflikt"))?.allowedDecisions == [.pending,.skip],"type conflict limited to skip")
            } else { check(false,"type conflict native control") }
            choose("lassen.txt",.skip);choose("beide.txt",.keepBoth);choose("ersetzen.txt",.replace);choose("Typkonflikt",.skip)
            check(setup.plan?.merge?.unresolvedCount == 0 && setup.startButton.isEnabled && setup.queueButton.isEnabled,"all decisions enable submission")
            setup.selectionButton.performClick(nil)
            if let checkbox = setup.table.view(atColumn:0,row:0,makeIfNecessary:true) as? NSButton {
                checkbox.performClick(nil);check(setup.previewCount == 0 && !setup.startButton.isEnabled,"deselect root clears effective plan")
                checkbox.performClick(nil);check(setup.previewCount > 0 && setup.startButton.isEnabled && setup.plan?.merge?.action(for:source.appendingPathComponent("lassen.txt"))?.decision == .skip,"reselect retains individual decisions")
            } else { check(false,"root selection control") }
            setup.objectsButton.performClick(nil)
            check(text("ersetzen.txt") == "alt ersetzen\n" && !FileSystem.exists(target.appendingPathComponent("neu.txt")),"preview performs no writes")
            capture(setup.window,"-Zusammenfuehren")
            setup.queueButton.performClick(nil)
            let snapshot = self.main.jobs.scheduler.snapshots.last
            check(self.main.jobs.scheduler.isHeld && snapshot?.state == .waiting && snapshot?.title.hasPrefix("Zusammenführen") == true,"merge queued without execution")
            check(snapshot?.items.count == setup.plan?.merge?.actions.count && snapshot?.totalBytes == setup.plan?.bytes,"queue reflects resolved plan")
            self.main.operationWindow!.start.performClick(nil)
            waitFor({ self.main.jobs.pending == 0 },then:finished)
        }
        waitFor({ setup.plan != nil },then:{
            check(setup.mergeFolders.state == .off && setup.plan?.merge == nil,"whole-object mode remains default")
            setup.mergeFolders.performClick(nil)
            waitFor({ setup.plan?.merge != nil },then:{
                check(setup.policy.itemTitle(at:0) == "Einzeln entscheiden","individual conflict mode visible")
                setup.include.stringValue = "*.txt;*.md";setup.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:setup.include));setup.prepare()
                waitFor({ setup.plan?.merge != nil && setup.plan?.filter.include == "*.txt;*.md" },then:configureConflicts)
            })
        })
    }
}
