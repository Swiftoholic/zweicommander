import AppKit
import CommanderCore

extension AppDelegate {
    func runSearchSmoke(root: URL,prefix: String,reload: Bool) {
        var failures: [String] = [],checks = 0
        func check(_ value: Bool,_ name: String) { checks += 1;print("SEARCH UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
        func finish() {
            _ = Preferences.searchTestDefaults?.synchronize();print("SEARCH SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
        func waitFor(_ condition: @escaping ()->Bool,then: @escaping ()->Void,attempt: Int = 0) {
            if condition() { then();return };guard attempt < 150 else { print("SEARCH SMOKE FAIL timed out");exit(1) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitFor(condition,then:then,attempt:attempt+1) }
        }
        func choose(_ popup: NSPopUpButton,_ index: Int) { popup.selectItem(at:index);_ = popup.sendAction(popup.action,to:popup.target) }
        func capture(_ controller: SearchController,_ suffix: String) {
            guard let view = controller.window?.contentView else { check(false,"snapshot view available");return }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { check(false,"snapshot bitmap available");return }
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try! bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
        }
        func loadProfile(_ controller: SearchController,_ name: String) {
            guard let index = controller.profilePopup.itemArray.firstIndex(where: { $0.title == name }) else { print("SEARCH SMOKE FAIL missing profile");exit(1) };choose(controller.profilePopup,index)
        }
        func select(_ controller: SearchController,_ name: String) {
            guard let row = controller.visibleHits.firstIndex(where: { $0.name == name }) else { print("SEARCH SMOKE FAIL missing result");exit(1) }
            controller.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
        }
        let base = root.appendingPathComponent("Links"),project = base.appendingPathComponent("Projekt"),target = root.appendingPathComponent("Rechts")
        guard let defaults = Preferences.searchTestDefaults else { print("SEARCH SMOKE FAIL missing isolated settings");exit(1) }
        self.main.left.focus();self.main.command("search")
        let controller = self.main.secondaryWindows.compactMap { $0 as? SearchController }.last!
        check(controller.window?.isVisible == true && controller.allHits.isEmpty && !controller.isSearching,"search command opens an independent empty native window")
        check(controller.rootPath.stringValue == base.path && controller.selectedProfileID == nil,"search root comes from originating pane without implicit profile")
        func archivePhase() {
            controller.setOptions(SearchOptions());controller.rootPath.stringValue = root.appendingPathComponent("Archive").path;controller.name.stringValue = "*.txt";controller.archives.state = .on
            controller.start.performClick(nil)
            waitFor({ !controller.isSearching && controller.report != nil },then:{
                check(controller.report?.archiveMatches.count == 2 && controller.report?.urls.isEmpty == true,"archive names stay distinct from real filesystem results")
                check(controller.report?.warningCount == 1 && controller.reportButton.isEnabled,"bad archive reports a bounded accessible warning")
                select(controller,"eins.txt")
                check(!controller.copyButton.isEnabled && !controller.collectionButton.isEnabled && !controller.previewButton.isEnabled,"archive member cannot be copied or previewed as an invented path")
                var opened: SearchHit?;controller.onOpen = { opened = $0 };controller.openButton.performClick(nil)
                check(opened?.url.lastPathComponent == "Paket.zip" && opened?.member == "Dokumente/eins.txt","archive open action receives the container and exact member identity")
                var warning = "";controller.onReport = { warning = $0 };controller.reportButton.performClick(nil)
                check(warning.contains("kaputt.zip") && warning.contains("Hinweise: 1"),"native warning action exposes actual scan problems")
                capture(controller,"-Suche-Archive")
                controller.content.stringValue = "unvereinbar";controller.start.performClick(nil)
                check(!controller.isSearching && controller.info.textColor == .systemRed && controller.allHits.count == 2,"incompatible archive content query leaves old results intact with inline error")
                controller.setOptions(SearchOptions());controller.rootPath.stringValue = project.path;controller.name.stringValue = "*.txt";controller.limit.stringValue = "1"
                controller.start.performClick(nil)
                waitFor({ !controller.isSearching && controller.report != nil },then:{
                    check(controller.report?.limitReached == true && controller.allHits.count == 1 && controller.info.stringValue.contains("Teilergebnisse"),"result cap is visible and never presented as a complete search")
                    controller.setOptions(SearchOptions());controller.rootPath.stringValue = base.appendingPathComponent("Office").path;controller.name.stringValue = "*.docx";controller.content.stringValue = "Finanzplanung";controller.office.state = .on;controller.start.performClick(nil)
                    waitFor({ !controller.isSearching && controller.report != nil },then:{
                        check(controller.allHits.map(\.name) == ["Termin.docx"] && controller.allHits[0].snippet.contains("Finanzplanung"),"native Office content search reads document text with a snippet")
                        finish()
                    })
                })
            })
        }
        func cancellationPhase() {
            let gate = DispatchSemaphore(value:0);var unrelatedFinished = false
            self.main.jobs.submit("Independent search check",work:{ token,_ in
                guard gate.wait(timeout:.now()+10) == .success else { throw CommanderError.message("Test gate timed out") }
                try token.check();return true
            },completion:{ result in unrelatedFinished = (try? result.get()) == true })
            controller.setOptions(SearchOptions());controller.rootPath.stringValue = root.appendingPathComponent("Viele").path;controller.name.stringValue = "*.txt"
            var sawStream = false
            controller.onResultsChanged = {
                guard !sawStream,!controller.allHits.isEmpty else { return };sawStream = true
                check(controller.isSearching && !controller.start.isEnabled && controller.stop.isEnabled,"results arrive while the search is running")
                check(!controller.name.isEnabled && self.main.pendingWork > 0 && !self.main.canTerminate,"running search freezes criteria and participates in close protection")
                controller.stop.performClick(nil)
            }
            controller.start.performClick(nil)
            waitFor({ !controller.isSearching && controller.report != nil },then:{
                controller.onResultsChanged = nil
                check(sawStream && controller.report?.cancelled == true && controller.allHits.count > 0 && controller.allHits.count < 400,"cancellation retains partial streamed results")
                check(controller.info.stringValue.contains("Abgebrochen") && controller.name.isEnabled && self.main.jobs.pending == 1,"cancelled search restores controls while unrelated job remains active")
                check((try? FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("Viele").path).count) == 400,"cancellation changes no searched files")
                gate.signal()
                waitFor({ self.main.jobs.pending == 0 && unrelatedFinished },then:{
                    check(unrelatedFinished && self.main.canTerminate,"search runs independently and its cancellation never cancels the unrelated file queue")
                    archivePhase()
                })
            })
        }
        if reload {
            let library = try! Preferences.searchProfiles()
            check(library.profiles.count == 2 && library.profiles.contains(where: { $0.name == "Projektnotizen" }),"search profiles survive a separate app process")
            loadProfile(controller,"Projektnotizen")
            check(controller.content.stringValue == "Projekt" && controller.folders.stringValue == "Cache*" && controller.profileStatus.stringValue == "Gespeichert","explicit profile restores text and exclusion criteria")
            check(controller.rootPath.stringValue == base.path,"loading a profile preserves the current search folder")
            controller.rootPath.stringValue = project.path;controller.start.performClick(nil)
            waitFor({ !controller.isSearching && controller.report != nil },then:{
                check(Set(controller.allHits.map(\.name)) == Set(["Notizen.txt","Bericht.md","Plan.TXT"]),"reloaded search profile finds the expected exact result set")
                let original = defaults.data(forKey:Preferences.searchProfilesKey)!
                defaults.set(Data("{broken".utf8),forKey:Preferences.searchProfilesKey);controller.refreshProfiles()
                check(!controller.profileSaveAs.isEnabled && controller.profileStatus.stringValue == "Profile nicht lesbar","corrupt search profile data disables writes inline")
                do { try Preferences.editSearchProfiles { try $0.save(name:"Overwrite",options:SearchOptions()) };check(false,"corrupt profile bytes preserved") }
                catch { check(defaults.data(forKey:Preferences.searchProfilesKey) == Data("{broken".utf8),"corrupt profile bytes preserved") }
                defaults.set("wrong type",forKey:Preferences.searchProfilesKey)
                do { _ = try Preferences.searchProfiles();check(false,"wrong profile storage type rejected") }
                catch { check(defaults.string(forKey:Preferences.searchProfilesKey) == "wrong type","wrong profile storage type rejected") }
                defaults.set(original,forKey:Preferences.searchProfilesKey);controller.refreshProfiles();loadProfile(controller,"Projektnotizen")
                controller.profileRemove.performClick(nil)
                waitFor({ controller.deleteAlert?.window.sheetParent != nil },then:{
                    let alert = controller.deleteAlert!;controller.window?.endSheet(alert.window,returnCode:.alertSecondButtonReturn);alert.window.orderOut(nil)
                    waitFor({ controller.window?.attachedSheet == nil },then:{
                        check((try? Preferences.searchProfiles().profiles.count) == 2,"cancelled profile deletion leaves local library unchanged")
                        controller.profileRemove.performClick(nil)
                        waitFor({ controller.deleteAlert?.window.sheetParent != nil },then:{
                            let alert = controller.deleteAlert!;controller.window?.endSheet(alert.window,returnCode:.alertFirstButtonReturn);alert.window.orderOut(nil)
                            waitFor({ (try? Preferences.searchProfiles().profiles.count) == 1 },then:{
                                check(controller.content.stringValue == "Projekt" && controller.allHits.count == 3,"deleting a profile preserves current query and session results")
                                cancellationPhase()
                            })
                        })
                    })
                })
            })
            return
        }
        controller.rootPath.stringValue = project.path;controller.hidden.state = .off;controller.name.stringValue = "*.txt;*.md";controller.content.stringValue = "Projekt";controller.excluded.stringValue = "Nicht*";controller.folders.stringValue = "Cache*"
        controller.start.performClick(nil)
        waitFor({ !controller.isSearching && controller.report != nil },then:{
            check(Set(controller.allHits.map(\.name)) == Set(["Notizen.txt","Bericht.md","Plan.TXT"]),"native recursive content query applies name masks and prunes excluded folders")
            check(controller.allHits.allSatisfy { $0.snippet.contains("Projekt") },"every content result carries its literal match context")
            check(controller.report?.warningCount == 0 && controller.info.stringValue.contains("Suche abgeschlossen"),"successful full query reports completion without warnings")
            controller.resultFilter.stringValue = "Plan";controller.filterResults()
            check(controller.visibleHits.count == 1 && controller.allHits.count == 3,"result list filtering retains the underlying search results")
            controller.resultFilter.stringValue = "";controller.filterResults();controller.table.sortDescriptors = [NSSortDescriptor(key:"name",ascending:false)]
            check(controller.visibleHits.map(\.name) == ["Plan.TXT","Notizen.txt","Bericht.md"],"native column sorting uses natural file name order")
            select(controller,"Notizen.txt");capture(controller,"-Dateisuche")
            controller.revealButton.performClick(nil)
            waitFor({ self.main.left.selectedURLs.contains { $0.lastPathComponent == "Notizen.txt" } },then:{
                check(FileSystem.canonical(self.main.left.currentURL) == FileSystem.canonical(project),"reveal navigates the originating pane and selects after its asynchronous reload")
                // A different main-pane selection must never become the copy source.
                self.main.right.focus();controller.copyButton.performClick(nil)
                guard let setup = self.main.secondaryWindows.compactMap({ $0 as? TransferSetupController }).last else { check(false,"copy setup opens");finish();return }
                waitFor({ setup.plan != nil },then:{
                    check(setup.sources.map(\.lastPathComponent) == ["Notizen.txt"],"copy setup uses selected search result despite changed active pane")
                    check(FileSystem.canonical(setup.plan!.destination) == FileSystem.canonical(target),"copy destination remains the opposite pane captured by search")
                    setup.startButton.performClick(nil)
                    waitFor({ self.main.jobs.pending == 0 && FileSystem.exists(target.appendingPathComponent("Notizen.txt")) },then:{
                        check((try? String(contentsOf:target.appendingPathComponent("Notizen.txt"),encoding:.utf8)) == "Projekt Wiese\nGrüße aus Wien\n","search result copy goes through normal planned transfer and preserves exact contents")
                        controller.table.selectAll(nil);controller.collectionButton.performClick(nil)
                        check(Set(self.main.left.tab.collection?.map(\.lastPathComponent) ?? []) == Set(["Notizen.txt","Bericht.md","Plan.TXT"]),"multi-selected real results become a pane collection")
                        select(controller,"Notizen.txt");NSApp.activate(ignoringOtherApps:true);controller.window?.makeKeyAndOrderFront(nil)
                        waitFor({ self.main.keySearchController === controller },then:{
                            controller.window?.makeFirstResponder(controller.table)
                            var routed: SearchHit?;controller.onOpen = { routed = $0 };self.main.command("open")
                            check(routed?.name == "Notizen.txt","main open shortcut routes to search selection")
                            var routedCopies: [URL] = [];controller.onCopy = { routedCopies = $0 };self.main.command("copy")
                            check(routedCopies.map(\.lastPathComponent) == ["Notizen.txt"],"main copy shortcut routes to search selection")
                            guard self.main.keySearchController === controller else { print("SEARCH SMOKE FAIL key search window lost");exit(1) }
                            self.main.command("trash")
                            check(!controller.canPerformCommand("trash") && FileSystem.exists(project.appendingPathComponent("Notizen.txt")),"unsupported destructive menu command cannot act on a different main-pane selection")
                        controller.profileSaveAs.performClick(nil);let naming = controller.profileNameWindow!
                        naming.name.stringValue = "";naming.save.performClick(nil)
                        check(controller.window?.attachedSheet != nil && !naming.info.stringValue.isEmpty,"invalid profile name remains in naming sheet")
                        naming.name.stringValue = "Projektnotizen";naming.save.performClick(nil)
                        let library = try! Preferences.searchProfiles(),data = try! library.encoded()
                        check(library.profiles.count == 1 && library.profiles[0].options == (try? controller.options()),"native profile save persists complete current search criteria")
                        check(!String(decoding:data,as:UTF8.self).contains(root.path) && !String(decoding:data,as:UTF8.self).contains("Notizen.txt"),"profile stores neither search root nor result paths")
                        let other = SearchController(root:target);self.main.secondaryWindows.append(other);other.showWindow(nil);other.name.stringValue = "unsaved*"
                        controller.content.stringValue = "Grüße";controller.profileSave.performClick(nil)
                        check(other.name.stringValue == "unsaved*" && other.profilePopup.itemArray.contains { $0.title == "Projektnotizen" },"profile update notifies other windows without replacing their unsaved query")
                        controller.content.stringValue = "Projekt";controller.profileSave.performClick(nil)
                        controller.editCriteria();let metadata = controller.criteriaWindow!
                        metadata.minimum.stringValue = "1 B";metadata.maximum.stringValue = "1 MiB";metadata.apply.performClick(nil)
                        check((try? controller.options())?.minimumSize == 1 && (try? controller.options())?.maximumSize == 1_048_576,"native shared metadata editor validates sizes for search")
                        controller.profileSave.performClick(nil)
                        controller.setOptions(SearchOptions());controller.name.stringValue = "*.zip";controller.archives.state = .on;controller.profileSaveAs.performClick(nil)
                        let archiveName = controller.profileNameWindow!;archiveName.name.stringValue = "Archive";archiveName.save.performClick(nil)
                        check((try? Preferences.searchProfiles().profiles.count) == 2,"second search profile stores a separate archive-name query")
                        let before = controller.allHits
                        controller.regex.state = .on;controller.name.stringValue = "[";controller.start.performClick(nil)
                        check(controller.info.textColor == .systemRed && !controller.isSearching && controller.allHits == before,"invalid search syntax fails before clearing previous result set")
                        capture(controller,"-Suche-Regelfehler")
                        other.close();controller.close();finish()
                        })
                    })
                })
            })
        })
    }
}
