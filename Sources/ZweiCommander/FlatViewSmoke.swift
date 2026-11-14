import AppKit
import CommanderCore

extension AppDelegate {
    func runFlatViewSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ okay:Bool,_ name:String) { checks += 1;print("FLAT VIEW UI \(okay ? "PASS" : "FAIL") "+name);if !okay { failures.append(name) } }
            @MainActor func wait(_ name:String,_ condition:()->Bool) async {
                for _ in 0..<500 { if condition() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("FLAT VIEW SMOKE FAIL timeout "+name);fflush(stdout);exit(1)
            }
            func contains(_ urls:[URL]?,_ target:URL) -> Bool {
                let path = FileSystem.canonical(target.deletingLastPathComponent()).appendingPathComponent(target.lastPathComponent).path
                return urls?.contains { FileSystem.canonical($0.deletingLastPathComponent()).appendingPathComponent($0.lastPathComponent).path == path } ?? false
            }
            let main = self.main!,pane = main.left,window = main.window!
            let personal = UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:]
            let source = FileSystem.canonical(root.appendingPathComponent("Links")),other = source.appendingPathComponent("Child"),hidden = source.appendingPathComponent(".hidden.txt")
            @MainActor func settle() async { await wait("pane listings") { !pane.isLoading && !pane.isSorting } }
            @MainActor func reset() async {
                main.linked = false;pane.tabs = [FolderTab(source)];pane.tabIndex = 0
                pane.showHidden = false;pane.restoreTabView();pane.rebuildTabs();pane.refresh();pane.focus();await settle()
            }
            @MainActor func begin() async -> (DispatchSemaphore,UUID) {
                let gate = DispatchSemaphore(value:0)
                let blocker = main.jobs.scheduler.enqueue("Prüfsperre",body:{ token,_ in
                    while gate.wait(timeout:.now()+0.05) == .timedOut { try token.check() }
                })
                await wait("queue barrier") { main.jobs.active?.id == blocker }
                let before = Set(main.jobs.scheduler.snapshots.map(\.id));main.command("flat")
                guard let job = main.jobs.scheduler.snapshots.last(where:{ !before.contains($0.id) && $0.title == "Flache Ansicht" }) else {
                    gate.signal();print("FLAT VIEW SMOKE FAIL missing actual flat command");exit(1)
                }
                return (gate,job.id)
            }
            @MainActor func drain(_ gate:DispatchSemaphore) async {
                var finished = false
                main.jobs.submit("Prüfbestätigung",work:{ _,_ in true },completion:{ _ in finished = true })
                gate.signal();await wait("queued callbacks") { finished && main.jobs.pending == 0 };await settle()
            }
            do {
                try FileManager.default.createDirectory(at:other,withIntermediateDirectories:true)
                let file = source.appendingPathComponent("flat.txt")
                try Data("flat fixture\n".utf8).write(to:file);try Data("hidden fixture\n".utf8).write(to:hidden)
                window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                await wait("active main window") { NSApp.isActive && window.isKeyWindow };await reset()
                check(pane.tab.collection == nil && pane.currentURL == source,"flat request starts in the displayed local folder")

                var request = await begin()
                check(main.jobs.scheduler.snapshots.first(where:{ $0.id == request.1 })?.state == .waiting,"actual flat command waits behind an existing queue job")
                pane.navigate(other);await settle();let target = pane.tab.id
                await drain(request.0)
                check(pane.tab.id == target && pane.currentURL == other && pane.tab.collection == nil && pane.tabs.count == 1,"late flat success cannot replace a different folder")

                await reset();request = await begin();pane.newTab(url:other);await settle();let newTab = pane.tab.id
                await drain(request.0)
                check(pane.tab.id == newTab && pane.currentURL == other && pane.tab.collection == nil && pane.tabs.count == 2,"late flat success cannot replace a different tab")

                await reset();request = await begin();pane.navigate(other);pane.navigate(source);await settle()
                await drain(request.0)
                check(pane.currentURL == source && pane.tab.collection == nil && pane.tabs.count == 1,"a folder round trip invalidates its earlier request")

                await reset();let original = pane.tab.id;pane.newTab(url:other);let alternate = pane.tab.id;pane.selectTab(original);await settle()
                request = await begin();pane.selectTab(alternate);pane.selectTab(original);await settle();await drain(request.0)
                check(pane.tab.id == original && pane.tab.collection == nil && pane.tabs.count == 2,"a tab round trip invalidates its earlier request")

                await reset();Preferences.state.showHidden = true;pane.showHidden = false;request = await begin()
                pane.showHidden = true;pane.refresh();await settle();await drain(request.0)
                check(contains(pane.tab.collection,file) && pane.tabs.count == 2,"ordinary listing refresh does not discard a current flat result")
                check(pane.tab.collection != nil && !contains(pane.tab.collection,hidden),"queued flat scan uses the pane hidden-file option captured at submission")

                await reset();Preferences.state.showHidden = false;pane.showHidden = true;request = await begin();await drain(request.0)
                check(contains(pane.tab.collection,hidden),"flat scan uses the active pane option independently of global defaults")

                await reset();request = await begin();window.close();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await drain(request.0)
                check(pane.tab.collection == nil && pane.tabs.count == 1,"closing and reopening the main window invalidates old flat results")

                await reset();request = await begin();main.jobs.scheduler.cancel(request.1);await drain(request.0)
                check(pane.tab.collection == nil && pane.tabs.count == 1 && main.jobs.scheduler.snapshots.first(where:{ $0.id == request.1 })?.state == .cancelled,"cancelling a queued flat request publishes no collection")

                await reset()
                let scanned = DispatchSemaphore(value:0),finish = DispatchSemaphore(value:0)
                main.flatViewAfterScanForTesting = { _ in scanned.signal();_ = finish.wait(timeout:.now()+15) }
                let beforeRunning = Set(main.jobs.scheduler.snapshots.map(\.id));main.command("flat")
                guard let running = main.jobs.scheduler.snapshots.last(where:{ !beforeRunning.contains($0.id) && $0.title == "Flache Ansicht" }) else { throw CommanderError.message("Laufende Flachansicht fehlt.") }
                await wait("post-scan boundary") { scanned.wait(timeout:.now()) == .success }
                main.jobs.scheduler.cancel(running.id);finish.signal()
                await drain(DispatchSemaphore(value:0));main.flatViewAfterScanForTesting = nil
                check(pane.tab.collection == nil && pane.tabs.count == 1 && main.jobs.scheduler.snapshots.first(where:{ $0.id == running.id })?.state == .cancelled,"accepted running cancellation after the scan cannot publish a successful collection")

                await reset();request = await begin();main.right.focus();let otherResponder = window.firstResponder;await drain(request.0)
                check(contains(pane.tab.collection,file) && main.active === main.right && window.firstResponder === otherResponder,"flat results open in their source pane without stealing the other pane's focus")

                await reset();request = await begin();pane.beginPathEditing();let editor = window.firstResponder;await drain(request.0)
                check(pane.tab.collection == nil && pane.tabs.count == 1 && pane.pathField.sessionActive && window.firstResponder === editor,"flat results preserve a newer path editing session")
                pane.endPathEditing(restoreFocus:true)

                await reset();request = await begin();pane.select([file]);pane.beginInlineRename();await drain(request.0)
                check(pane.tab.collection == nil && pane.tabs.count == 1 && pane.inlineRename.isEditing,"flat results preserve a newer inline rename")
                pane.inlineRename.cancel(restoreFocus:true)

                await reset();request = await begin();pane.select([file]);main.showAttributes()
                guard let attributes = main.secondaryWindows.last as? AttributesController,let protected = attributes.window else { throw CommanderError.message("Geschütztes Eigenschaftsfenster fehlt.") }
                protected.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                await wait("protected window") { protected.isKeyWindow && NSApp.isActive }
                await drain(request.0)
                check(pane.tab.collection == nil && pane.tabs.count == 1 && main.keyWorkflowWindow === protected,"flat results cannot change the file pane behind a protected workflow")
                attributes.close();window.makeKeyAndOrderFront(nil);pane.focus()

                let removed = root.appendingPathComponent("Removed")
                try FileManager.default.createDirectory(at:removed,withIntermediateDirectories:true)
                await reset();pane.navigate(removed);await settle();request = await begin()
                pane.navigate(source);await settle();try FileManager.default.removeItem(at:removed);await drain(request.0)
                check(pane.currentURL == source && pane.tab.collection == nil && pane.tabs.count == 1 && main.jobs.scheduler.snapshots.first(where:{ $0.id == request.1 })?.state == .failed,"a failed stale scan cannot display an unrelated modal or collection")

                await reset();request = await begin();main.command("flat");await drain(request.0)
                check(pane.tabs.count == 2 && contains(pane.tab.collection,file),"two queued requests from one context publish only its first valid result")

                await reset();pane.tab.lockMode = .fixed;let fixed = pane.tab;request = await begin();await drain(request.0)
                check(pane.tabs.count == 2 && pane.tabs.contains(where:{ $0 === fixed && $0.lockMode == .fixed && $0.url == source }) && contains(pane.tab.collection,file),"flat results preserve a fixed source tab in a separate collection")
                check(try Data(contentsOf:file) == Data("flat fixture\n".utf8) && Data(contentsOf:hidden) == Data("hidden fixture\n".utf8) && (personal as NSDictionary).isEqual(to:UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:]),"flat context tests preserve source bytes and personal settings")
            } catch { check(false,error.localizedDescription) }
            print("FLAT VIEW SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");fflush(stdout);exit(failures.isEmpty ? 0 : 1)
        }
    }
}
