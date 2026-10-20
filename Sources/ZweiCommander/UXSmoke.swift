import AppKit
import CommanderCore

extension AppDelegate {
    func runUXSmoke(root:URL,prefix:String,reload:Bool) {
        Task { @MainActor in
            var failures: [String] = [],checks = 0
            func check(_ value:Bool,_ name:String) { checks += 1;print("UX UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("UX SMOKE FAIL missing \(name)");exit(1) };return value }
            @MainActor func waitFor(_ condition:()->Bool,_ name:String) async {
                for _ in 0..<150 { if condition() { return };try? await Task.sleep(nanoseconds:100_000_000) }
                print("UX SMOKE FAIL timed out: \(name)");exit(1)
            }
            @MainActor func capture(_ window:NSWindow?,_ suffix:String) {
                if window === main.window {
                    let places = [("System",URL(fileURLWithPath:"/")),("Projekte",root.appendingPathComponent("Links")),("Sicherung",root.appendingPathComponent("Rechts"))]
                    for pane in [main.left,main.right] { pane.locations.configure(places);pane.locations.select(pane.currentURL) }
                }
                let view = require(window?.contentView,"capture view");view.layoutSubtreeIfNeeded();view.displayIfNeeded()
                let rep = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap");view.cacheDisplay(in:view.bounds,to:rep)
                do { try require(rep.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+suffix+".png")) } catch { print("UX SMOKE FAIL capture");exit(1) }
            }
            @MainActor func button(_ id:String) -> NSButton { require(main.content.functionBar.arrangedSubviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == id },"function button "+id) }
            @MainActor func toolbarIDs() -> [String] { main.content.toolbar.arrangedSubviews.compactMap { ($0 as? NSButton)?.identifier?.rawValue } }
            @MainActor func finish() {
                Preferences.toolbarTestDefaults?.synchronize();print("UX SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
                if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
            }
            let defaults = require(Preferences.toolbarTestDefaults,"isolated toolbar defaults")
            let expectedToolbar = ["quickView","search","back"]
            if reload {
                check(Preferences.toolbarSettings().items == expectedToolbar,"custom toolbar order survives a separate app process")
                check(toolbarIDs() == expectedToolbar,"persisted toolbar is rebuilt on launch")
                let saved = require(defaults.data(forKey:Preferences.toolbarKey),"saved toolbar")
                defaults.set(Data("{broken".utf8),forKey:Preferences.toolbarKey)
                do { try Preferences.saveToolbar(ToolbarSettings());check(false,"corrupt toolbar blocks replacement") } catch { check(true,"corrupt toolbar blocks replacement") }
                check(defaults.data(forKey:Preferences.toolbarKey) == Data("{broken".utf8),"corrupt toolbar remains unchanged")
                var future = ToolbarSettings();future.schemaVersion = 99
                let data = require(try? JSONEncoder().encode(future),"future toolbar fixture");defaults.set(data,forKey:Preferences.toolbarKey)
                do { try Preferences.saveToolbar(ToolbarSettings());check(false,"future toolbar blocks replacement") } catch { check(defaults.data(forKey:Preferences.toolbarKey) == data,"future toolbar blocks replacement") }
                check(Preferences.toolbarSettings() == ToolbarSettings(),"unknown toolbar can display a safe default without saving it")
                defaults.set(saved,forKey:Preferences.toolbarKey);finish();return
            }
            let pane = main.left,right = root.appendingPathComponent("Rechts"),left = root.appendingPathComponent("Links")
            await waitFor({ !pane.isLoading && !main.right.isLoading },"initial panes")
            let note = require(pane.entries.first { $0.name == "Notizen.txt" }?.url,"source note")
            let budget = require(pane.entries.first { $0.name == "Budget.csv" }?.url,"source budget")
            let total = pane.entries.count
            pane.select([note]);pane.focus()
            check(button("copy").title.contains("→ Rechts") && button("move").title.contains("→ Rechts"),"left selection shows rightward copy and move destinations")
            check(button("copy").isEnabled && button("copy").toolTip?.contains(main.right.currentURL.path) == true,"transfer action exposes the real destination")
            main.right.showCollection([],title:"Sammlung");pane.focus()
            await waitFor({ !main.right.isLoading },"empty target collection")
            check(button("copy").title.contains("Zur Sammlung") && !button("move").isEnabled,"collection target distinguishes references from moving files")
            button("copy").performClick(nil)
            await waitFor({ !main.right.isLoading && main.right.visibleEntries.count == 1 },"collection reference")
            check(main.right.tab.collection?.count == 1 && FileSystem.exists(note),"collection action adds a reference while preserving the original")
            main.right.closeTab();pane.focus();await waitFor({ !main.right.isLoading },"restore target folder")
            pane.refresh()
            check(pane.selectedURLs.count == 1 && button("copy").isEnabled && pane.stateView.isHidden,"background refresh preserves selection and usable file actions")
            await waitFor({ !pane.isLoading },"background refresh")
            pane.select([]);check(!button("copy").isEnabled && !button("move").isEnabled,"empty selection disables both transfer buttons")
            main.right.select([right.appendingPathComponent("Notizen.txt")]);main.right.focus()
            check(button("copy").title.contains("← Links"),"right focus reverses the copy direction")
            main.command("orientation");main.content.layoutSubtreeIfNeeded();check(button("copy").title.contains("↑ Oben"),"horizontal panes show the upward destination")
            let targetAbove = main.content.convert(pane.bounds,from:pane).midY > main.content.convert(main.right.bounds,from:main.right).midY
            check(targetAbove,"horizontal transfer label matches the physical target position")
            pane.focus();check(button("move").title.contains("↓ Unten"),"upper pane shows the downward destination")
            main.command("orientation")
            main.window?.setContentSize(NSSize(width:900,height:600));main.content.layoutSubtreeIfNeeded()
            let menu = main.toolbarOverflowMenu()
            let hidden = main.content.toolbar.arrangedSubviews.compactMap { $0 as? NSButton }.filter(\.isHidden)
            check(!hidden.isEmpty && menu.items.count == hidden.count+2,"narrow window moves every overflow action to the menu")
            check(menu.items.last?.title == "Werkzeugleiste anpassen …","toolbar customization remains available at minimum width")
            let visible = main.content.toolbar.arrangedSubviews.filter { !$0.isHidden }
            check(visible.allSatisfy { main.content.toolbar.convert($0.bounds,from:$0).maxX <= main.content.toolbarScroll.bounds.width+1 },"visible toolbar controls fit without clipping")
            if let index = menu.items.firstIndex(where: { $0.representedObject as? String == "refresh" }) { menu.performActionForItem(at:index) }
            await waitFor({ !pane.isLoading && !main.right.isLoading },"overflow refresh")
            check(pane.entries.count == total,"overflow command reaches the normal command handler")
            main.window?.setContentSize(NSSize(width:1280,height:780));main.content.layoutSubtreeIfNeeded()
            check(toolbarIDs() == ToolbarCommand.defaults,"default toolbar keeps panel navigation in each pane")
            check(ToolbarCommand.all.first { $0.id == "thumbnails" }?.title == "Miniaturbilder" && ToolbarCommand.all.first { $0.id == "quickView" }?.title == "Schnellansicht","preview modes have distinct labels")
            pane.filterField.stringValue = "*.txt";pane.filterChanged()
            check(!pane.filterBar.isHidden && pane.filterInfo.stringValue.contains("1 von \(total)"),"active filter displays visible and total object counts")
            check(main.right.visibleEntries.count == main.right.entries.count,"quick filter leaves the other pane unchanged")
            pane.select([note]);main.themeMenu.selectItem(at:1);main.themeChosen();try? await Task.sleep(nanoseconds:200_000_000)
            capture(main.window,"-UX-Hell")
            main.themeMenu.selectItem(at:2);main.themeChosen();try? await Task.sleep(nanoseconds:200_000_000)
            capture(main.window,"-UX-Dunkel")
            pane.filterField.stringValue = "kein-treffer-*.xyz";pane.filterChanged();main.content.layoutSubtreeIfNeeded()
            check(pane.visibleEntries.isEmpty && pane.stateView.heading.stringValue == "Keine Treffer","empty filter result explains why files disappeared")
            check(pane.stateView.action.title == "Filter aufheben" && !button("copy").isEnabled,"empty result offers recovery and blocks transfer")
            check(pane.scroll.frame.maxY <= pane.filterBar.frame.minY+1,"filter banner does not overlap the file list")
            capture(main.window,"-UX-Keine-Treffer")
            main.window?.setContentSize(NSSize(width:900,height:520));main.command("orientation");main.content.layoutSubtreeIfNeeded()
            check(pane.stateView.subviews.filter { !$0.isHidden }.allSatisfy { pane.stateView.bounds.contains($0.frame) },"small horizontal pane keeps empty-state controls inside its file area")
            check(!pane.filterClear.isHidden && pane.filterBar.frame.maxY <= pane.viewBar.frame.minY+1,"filter recovery remains available in a small horizontal pane")
            capture(main.window,"-UX-Klein-Leer")
            main.command("orientation");main.window?.setContentSize(NSSize(width:1280,height:780));main.content.layoutSubtreeIfNeeded()
            pane.stateView.action.performClick(nil)
            check(pane.visibleEntries.count == total && pane.filterBar.isHidden && main.window?.firstResponder === pane.table,"empty-state action clears the filter and restores keyboard focus")
            pane.select([note]);pane.filterField.stringValue = "[";pane.filterRegex.state = .off;pane.filterRegex.performClick(nil)
            check(pane.filterError != nil && pane.stateView.heading.stringValue == "Ungültiger regulärer Ausdruck","invalid regex is explained in the file area")
            check(pane.selectedURLs.isEmpty && !button("copy").isEnabled,"invalid regex cannot act on stale selected rows")
            pane.filterClear.performClick(nil)
            check(pane.filterRegex.state == .off && pane.filterError == nil && pane.visibleEntries.count == total,"clear action resets both the pattern and regex mode")
            let empty = left.appendingPathComponent("Leer")
            pane.navigate(empty)
            check(pane.isLoading && pane.stateView.heading.stringValue == "Ordner wird geladen …","navigation immediately exposes a loading state")
            await waitFor({ !pane.isLoading },"empty folder")
            check(pane.stateView.heading.stringValue == "Ordner ist leer" && pane.stateView.action.isHidden,"empty folder differs from a filtered result")
            main.content.layoutSubtreeIfNeeded()
            let dropPoint = main.content.convert(NSPoint(x:pane.stateView.frame.midX,y:pane.stateView.frame.midY),from:pane)
            check(main.content.hitTest(dropPoint)?.isDescendant(of:pane.scroll) == true,"empty-state text leaves the underlying file drop surface reachable")
            do { try FileManager.default.removeItem(at:empty) } catch { print("UX SMOKE FAIL empty fixture removal");exit(1) }
            pane.refresh();await waitFor({ !pane.isLoading },"unavailable folder")
            check(pane.loadError != nil && pane.stateView.action.title == "Erneut versuchen","read failure exposes a retry action")
            do { try FileManager.default.createDirectory(at:empty,withIntermediateDirectories:true) } catch { print("UX SMOKE FAIL fixture recreation");exit(1) }
            pane.stateView.action.performClick(nil);await waitFor({ !pane.isLoading },"retry")
            check(pane.loadError == nil && pane.stateView.heading.stringValue == "Ordner ist leer","retry recovers when the folder becomes available")
            pane.navigate(left);pane.navigate(empty);pane.navigate(left)
            await waitFor({ !pane.isLoading && pane.entries.count == total },"rapid navigation")
            check(pane.stateView.isHidden && pane.currentURL.path == left.path,"older asynchronous results cannot replace the latest folder")
            pane.select([note,budget]);pane.focus()
            main.transfer([note,budget],to:right,kind:.copy)
            let setup = require(main.secondaryWindows.last as? TransferSetupController,"copy setup")
            await waitFor({ setup.plan != nil },"initial copy plan")
            check(!setup.optionsExpanded && setup.advancedScroll.isHidden && require(setup.window?.contentView,"copy content").bounds.height < 650,"copy dialog opens in a compact basic state")
            check(setup.sourceInfo.stringValue.contains("2 Objekte") && setup.sourceInfo.toolTip?.components(separatedBy:"\n").contains(where: { FileSystem.canonical(URL(fileURLWithPath:$0)) == FileSystem.canonical(note) }) == true,"copy summary identifies the selected source objects")
            check(setup.destination.stringValue == right.path,"copy destination matches the opposite pane")
            check(!setup.conflictButton.isHidden && !setup.startButton.isEnabled && !setup.queueButton.isEnabled,"stop-on-conflict blocks both submission paths before any change")
            setup.conflictButton.performClick(nil)
            check(setup.table.selectedRow >= 0 && setup.tabs.indexOfTabViewItem(require(setup.tabs.selectedTabViewItem,"copy tab")) == 0,"conflict action selects the occupied target in the preview")
            capture(setup.window,"-UX-Kopieren-Konflikt")
            setup.policy.selectItem(at:2);_ = setup.policy.sendAction(setup.policy.action,to:setup.policy.target)
            await waitFor({ setup.plan?.policy == .keepBoth },"keep-both plan")
            check(setup.startButton.isEnabled && setup.conflictInfo.stringValue.contains("Beide behalten"),"explicit conflict policy makes the outcome visible and enables copying")
            setup.optionsButton.performClick(nil)
            check(setup.optionsExpanded && !setup.advancedScroll.isHidden && setup.destination.stringValue == right.path,"expanding options preserves the destination")
            check(setup.tabs.frame.height >= 75 && setup.tabs.frame.maxY < setup.selectionButton.frame.minY,"expanded controls preserve a separate preview area")
            setup.window?.setContentSize(NSSize(width:760,height:560));setup.window?.contentView?.layoutSubtreeIfNeeded()
            check(setup.tabs.frame.maxY < setup.selectionButton.frame.minY && setup.advancedScroll.frame.minY > setup.selectionButton.frame.maxY && setup.startButton.frame.maxX < 760,"minimum transfer window keeps options, preview and submit controls separate")
            capture(setup.window,"-UX-Kopieren-Klein")
            setup.window?.setContentSize(NSSize(width:840,height:840));setup.window?.contentView?.layoutSubtreeIfNeeded()
            setup.include.stringValue = "*.txt";setup.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:setup.include))
            check(setup.plan == nil && !setup.startButton.isEnabled,"editing a rule invalidates the previous plan immediately")
            await waitFor({ setup.plan?.filter.include == "*.txt" },"automatic filter replanning")
            check(setup.previewCount == 1 && setup.optionsSummary.stringValue.contains("Filter aktiv"),"edited rules replan automatically and show their active state")
            capture(setup.window,"-UX-Kopieren-Optionen")
            setup.optionsButton.performClick(nil)
            check(!setup.optionsExpanded && setup.optionsSummary.stringValue.contains("Filter aktiv") && setup.plan?.filter.include == "*.txt","collapsed options retain and disclose the active filter")
            setup.destination.stringValue = "";setup.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:setup.destination))
            await waitFor({ setup.info.stringValue.contains("absoluten Zielpfad") },"empty destination")
            check(setup.plan == nil && !setup.startButton.isEnabled,"empty destination cannot silently resolve to the process directory")
            setup.destination.stringValue = right.path;setup.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:setup.destination))
            await waitFor({ setup.plan != nil && setup.startButton.isEnabled },"restored destination")
            capture(setup.window,"-UX-Kopieren")
            setup.startButton.performClick(nil)
            await waitFor({ main.jobs.pending == 0 },"real copy")
            let rightText = (try? FileManager.default.contentsOfDirectory(at:right,includingPropertiesForKeys:nil).filter { $0.pathExtension == "txt" }) ?? []
            check(rightText.count == 2 && (try? String(contentsOf:right.appendingPathComponent("Notizen.txt"))) == "Vorhandene Notizen\n","keep-both preserves the existing target and creates an additional file")
            check(FileSystem.exists(note) && !FileSystem.exists(right.appendingPathComponent("Budget.csv")),"collapsed copy filter is honored by the real transfer")
            main.transfer([budget],to:right,kind:.move)
            let move = require(main.secondaryWindows.last as? TransferSetupController,"move setup")
            await waitFor({ move.plan != nil },"move plan")
            check(move.optionsButton.isHidden && move.advancedScroll.isHidden && move.startButton.title == "Verschieben","move dialog shows its supported basic controls")
            move.tabs.selectTabViewItem(at:1)
            let actionColumn = require(move.filesTable.tableColumns.firstIndex { $0.identifier.rawValue == "action" },"move action column")
            let actionCell = move.filesTable.view(atColumn:actionColumn,row:0,makeIfNecessary:true) as? NSTextField
            check(actionCell?.stringValue == "Datei verschieben","move preview uses the actual operation name")
            move.startButton.performClick(nil);await waitFor({ main.jobs.pending == 0 },"real move")
            check(!FileSystem.exists(budget) && (try? String(contentsOf:right.appendingPathComponent("Budget.csv"))) == "Posten;Betrag\nPlan;42\n","compact move dialog transfers the actual selected file")
            main.command("customizeToolbar")
            let editor = require(main.secondaryWindows.last as? ToolbarEditorController,"toolbar editor")
            let original = Preferences.toolbarSettings()
            for index in editor.order.indices {
                let id = editor.order[index],desired = expectedToolbar.contains(id)
                if editor.enabled.contains(id) != desired { require(editor.table.view(atColumn:0,row:index,makeIfNecessary:true) as? NSButton,"toolbar checkbox").performClick(nil) }
            }
            for (target,id) in expectedToolbar.enumerated() {
                let index = require(editor.order.firstIndex(of:id),"toolbar row");editor.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)
                for _ in target..<index { editor.up.performClick(nil) }
            }
            check(Preferences.toolbarSettings() == original,"toolbar edits do not write before Apply")
            editor.save.performClick(nil)
            check(Preferences.toolbarSettings().items == expectedToolbar && toolbarIDs() == expectedToolbar,"native toolbar controls save the selected commands and order")
            main.command("customizeToolbar")
            let cancelled = require(main.secondaryWindows.last as? ToolbarEditorController,"second toolbar editor");cancelled.reset.performClick(nil);cancelled.close()
            check(Preferences.toolbarSettings().items == expectedToolbar,"cancelling a draft preserves the saved toolbar")
            check(!main.content.toolbarMore.isHidden,"customization stays reachable with a minimal toolbar")
            finish()
        }
    }
}
