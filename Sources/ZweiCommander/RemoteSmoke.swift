import AppKit
import CommanderCore

extension AppDelegate {
    func runRemoteSmoke(root: URL,prefix: String,reload: Bool) {
        Task { @MainActor in
            var checks = 0,failures: [String] = []
            func check(_ value: Bool,_ name: String) { checks += 1;print("REMOTE UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value: T?,_ name: String) -> T { guard let value else { print("REMOTE SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name: String,_ predicate: ()->Bool) async {
                for _ in 0..<300 { if predicate() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("REMOTE SMOKE STATE transfers "+self.main.jobs.scheduler.snapshots.map { $0.state.rawValue+": "+$0.detail }.joined(separator:" | "))
                print("REMOTE SMOKE STATE lists "+self.main.secondaryWindows.compactMap { $0 as? RemoteWindow }.flatMap { $0.browse.scheduler.snapshots }.map { $0.state.rawValue+": "+$0.detail }.joined(separator:" | "))
                print("REMOTE SMOKE FAIL timeout "+name);exit(1)
            }
            @MainActor func activate(_ window: NSWindow) async {
                window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("foreground window") { window.isKeyWindow && NSApp.isActive }
            }
            @MainActor func key(_ window: NSWindow,_ text: String,_ modifiers: NSEvent.ModifierFlags) -> NSEvent {
                require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:text == "\r" ? 36 : 0),"key event")
            }
            @MainActor func capture(_ window: NSWindow,_ suffix: String) async {
                try? await Task.sleep(nanoseconds:200_000_000)
                guard let view = window.contentView else { return };view.layoutSubtreeIfNeeded();view.display()
                guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return };view.cacheDisplay(in:view.bounds,to:rep)
                try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+suffix+".png"))
            }
            await wait("initial panes") { !self.main.left.isLoading && !self.main.right.isLoading }
            let defaults = require(Preferences.remoteProfileTestDefaults,"isolated remote preferences"),store = Preferences.remoteProfiles
            main.remoteConnect()
            let form = require(main.secondaryWindows.last as? RemoteConnectionController,"profile window"),window = require(form.window,"connection window")
            await activate(window)
            if reload {
                let profile = require(try? store.library().profiles.first,"persisted profile")
                check(profile.name == "Lokales Testprofil" && profile.usesKeychain,"profile metadata survives a separate application process")
                check(Preferences.remoteTestPasswords.values.isEmpty,"new process has no synthetic password in profile preferences")
                form.reload(select:profile.id);form.selectProfile()
                check(form.host.stringValue == "127.0.0.1" && form.password.stringValue.isEmpty,"loading a saved profile never reveals its password in the form")
                var connected = false;form.onConnect = { _,_ in connected = true }
                form.connectNow();await wait("missing credential feedback") { !form.isWorking }
                check(!connected && form.status.stringValue.contains("Passwort fehlt"),"missing keychain credential stays inline without opening a server window")
                form.password.stringValue = "synthetic-reentered";form.save.performClick(nil);await wait("credential update") { !form.isWorking }
                check((try? store.library().profiles.count) == 1 && form.selected?.id == profile.id,"saving a reentered password updates the existing profile")
                check(Preferences.remoteTestPasswords.values[profile.credentialAccount] == "synthetic-reentered","reentered password reaches only the credential store")
                check(!(String(data:require(defaults.data(forKey:Preferences.remoteProfilesKey),"profile data"),encoding:.utf8) ?? "").contains("synthetic-reentered"),"updated metadata remains free of password contents")
                form.remove.performClick(nil);await wait("delete sheet") { form.confirmation != nil }
                check(window.attachedSheet != nil && form.confirmation?.informativeText.contains("Serverdateien bleiben erhalten") == true,"profile deletion uses a native review sheet with its actual scope")
                form.confirmation?.buttons[1].performClick(nil);await wait("cancel deletion") { form.confirmation == nil && window.attachedSheet == nil }
                check((try? store.library().profiles.count) == 1 && !Preferences.remoteTestPasswords.values.isEmpty,"cancelling profile deletion preserves metadata and credential")
                form.remove.performClick(nil);await wait("second delete sheet") { form.confirmation != nil };form.confirmation?.buttons[0].performClick(nil)
                await wait("profile deletion") { !form.isWorking && form.confirmation == nil && window.attachedSheet == nil && (try? store.library().profiles.isEmpty) == true }
                check(Preferences.remoteTestPasswords.values.isEmpty && form.profiles.numberOfItems == 1,"confirmed deletion removes the exact profile and its matching credential")
                form.kind.selectItem(at:0);form.protocolChanged()
                check(!form.password.isEnabled && !form.remember.isEnabled && form.identity.isEnabled && form.port.stringValue == "22","SFTP exposes key authentication and switches the default port")
                form.host.stringValue = "server.example";form.user.stringValue = "tester";form.port.stringValue = "bad"
                await activate(window)
                check(window.performKeyEquivalent(with:key(window,"\r",.command)),"connection Command Return is scoped to its own window")
                check(form.status.stringValue.contains("Ungültige") && !connected,"invalid connection data stays editable and cannot start a hidden main-pane action")
                let before = require(defaults.data(forKey:Preferences.remoteProfilesKey),"empty profile document")
                let damaged = Data("{broken".utf8);defaults.set(damaged,forKey:Preferences.remoteProfilesKey);form.reload()
                check(!form.save.isEnabled && defaults.data(forKey:Preferences.remoteProfilesKey) == damaged,"corrupt connection metadata disables saving and remains byte-for-byte intact")
                defaults.set(before,forKey:Preferences.remoteProfilesKey)
            } else {
                check(form.kind.indexOfSelectedItem == 1 && form.profiles.numberOfItems == 1,"new connection form defaults to verified FTPS with an empty local library")
                form.name.stringValue = "Lokales Testprofil";form.kind.selectItem(at:2);form.protocolChanged();form.host.stringValue = "127.0.0.1";form.user.stringValue = "tester"
                form.port.stringValue = require(try? String(contentsOf:root.appendingPathComponent("Server/port.txt"),encoding:.utf8),"fixture port")
                form.remember.state = .on;form.password.stringValue = "synthetic-only"
                check(window.performKeyEquivalent(with:key(window,"s",.command)),"Command S saves from the real connection window")
                await wait("profile saved") { !form.isWorking && form.selected != nil }
                let profile = require(form.selected,"saved profile")
                check(profile.usesKeychain && form.profiles.numberOfItems == 2,"native save adds a named profile and its credential reference")
                check(Preferences.remoteTestPasswords.values[profile.credentialAccount] == "synthetic-only" && form.password.stringValue.isEmpty,"saving sends the password to the credential store and clears the visible field")
                let data = require(defaults.data(forKey:Preferences.remoteProfilesKey),"saved profile bytes")
                check(!String(decoding:data,as:UTF8.self).contains("synthetic-only"),"connection preferences contain no password")
                check(form.save.toolTip?.contains("⌘S") == true && form.connect.toolTip?.contains("⌘↩") == true,"connection actions explain their keyboard bindings")
                window.appearance = NSAppearance(named:.aqua);await capture(window,"-Serverprofile-Hell")
                window.appearance = NSAppearance(named:.darkAqua);await capture(window,"-Serverprofile-Dunkel")
                let other = RemoteConnectionController();main.secondaryWindows.append(other);other.reload(select:profile.id);other.selectProfile();other.host.stringValue = "other.example"
                var changedEndpoint: RemoteConnection?
                other.onConnect = { connection,_ in changedEndpoint = connection };other.connectNow();await wait("edited endpoint") { !other.isWorking && changedEndpoint != nil }
                check(changedEndpoint?.password.isEmpty == true,"changing the server in a loaded profile never sends the previous password to it")
                await activate(window);form.connect.performClick(nil)
                await wait("server browser") { !form.isWorking && self.main.secondaryWindows.contains { $0 is RemoteWindow } }
                let browser = require(main.secondaryWindows.compactMap { $0 as? RemoteWindow }.last,"remote browser"),browserWindow = require(browser.window,"browser window")
                await activate(browserWindow);await wait("server listing") { browser.listedPath == "/" && browser.browse.pending == 0 }
                check(browser.transfers === main.jobs && browser.entries.contains { $0.name == "Eingang" && $0.isDirectory },"server browser reads the actual fixture and shares the main job queue")
                check(!browser.downloadButton.isEnabled && browser.uploadButton.isEnabled,"download requires a visible selection while upload can choose local sources")
                check(browserWindow.performKeyEquivalent(with:key(browserWindow,"l",.command)),"browser Command L focuses the server address")
                let editor = require(browser.path.currentEditor() as? NSTextView,"server path editor");editor.selectAll(nil);editor.insertText("/unconfirmed",replacementRange:editor.selectedRange())
                check(!browser.uploadButton.isEnabled && !browser.downloadButton.isEnabled,"unconfirmed address edits disable transfers from the previous server listing")
                editor.selectAll(nil);editor.insertText("/",replacementRange:editor.selectedRange());browserWindow.makeFirstResponder(browser.table)
                await wait("confirmed server listing") { browser.browse.pending == 0 && browser.path.isEnabled && browser.path.stringValue == browser.listedPath }
                browser.local.stringValue = root.appendingPathComponent("Downloads").path
                let index = require(browser.entries.firstIndex { $0.name == "Eingang" },"server folder")
                browser.table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false)
                await wait("remote selection actions") { browser.downloadButton.isEnabled }
                check(browser.downloadButton.isEnabled,"selecting a remote folder enables its download review")
                browser.table.keyDown(with:key(browserWindow,String(UnicodeScalar(NSF5FunctionKey)!),[]))
                let review = require(main.secondaryWindows.last as? RemoteTransferController,"download review"),reviewWindow = require(review.window,"review window")
                await activate(reviewWindow);await wait("recursive download plan") { review.plan != nil }
                check(review.plan?.rootNames == ["Eingang"] && review.plan?.files == 2,"download preview enumerates the complete selected folder before writing")
                check(!FileSystem.exists(root.appendingPathComponent("Downloads/Eingang")) && main.jobs.pending == 0,"opening a transfer preview changes no local files")
                check(review.start.toolTip?.contains("⌘↩") == true && review.queue.toolTip?.contains("⌘⇧↩") == true,"remote review advertises the same start and queue shortcuts as local transfers")
                reviewWindow.appearance = NSAppearance(named:.aqua);await capture(reviewWindow,"-Remote-Download-Hell")
                reviewWindow.appearance = NSAppearance(named:.darkAqua);await capture(reviewWindow,"-Remote-Download-Dunkel")
                check(reviewWindow.performKeyEquivalent(with:key(reviewWindow,"\r",[.command,.shift])),"Command Shift Return queues the checked remote folder")
                await wait("queued download") { self.main.jobs.scheduler.snapshots.contains { $0.state == .waiting } }
                check(!main.canTerminate && !FileSystem.exists(root.appendingPathComponent("Downloads/Eingang")),"queued remote work is session-only and cannot be silently lost on application quit")
                let job = require(main.jobs.scheduler.snapshots.first { $0.state == .waiting },"waiting remote job")
                check(main.jobs.journal?.entry(job.id) == nil,"remote session and credentials are never added to the local-copy journal")
                main.showOperations(select:job.id);let queueWindow = require(main.operationWindow?.window,"queue window")
                await activate(queueWindow)
                check(queueWindow.performKeyEquivalent(with:key(queueWindow,"\r",[])),"queue Return starts the selected waiting remote transfer")
                await wait("actual folder download") { self.main.jobs.pending == 0 }
                check((try? String(contentsOf:root.appendingPathComponent("Downloads/Eingang/Infos/Grüße.txt"),encoding:.utf8)) == "Remote content ✔\n","queued download writes the exact nested file contents")
                check(FileSystem.isDirectory(root.appendingPathComponent("Downloads/Eingang/Leer")),"recursive download preserves empty folders")
                check(main.jobs.scheduler.snapshots.first { $0.id == job.id }?.state == .completed,"remote result and byte progress finish in the shared queue")
                browser.downloadButton.performClick(nil);let blocked = require(main.secondaryWindows.last as? RemoteTransferController,"conflict preview")
                await wait("target conflict") { blocked.status.stringValue.contains("belegt") }
                check(blocked.plan == nil && !blocked.start.isEnabled && !blocked.queue.isEnabled,"existing local target blocks both immediate and queued remote download")
                blocked.close()
                await activate(browserWindow);browserWindow.makeFirstResponder(browser.table)
                var selectedThroughChooser = false
                browser.uploadSelection = { _,receive in selectedThroughChooser = true;receive([root.appendingPathComponent("Links/Projekt")]) }
                browser.table.keyDown(with:key(browserWindow,String(UnicodeScalar(NSF6FunctionKey)!),[]))
                await wait("chosen upload preview") { self.main.secondaryWindows.last is RemoteTransferController }
                let upload = require(main.secondaryWindows.last as? RemoteTransferController,"upload review"),uploadWindow = require(upload.window,"upload window")
                await activate(uploadWindow);await wait("recursive upload plan") { upload.plan != nil }
                check(selectedThroughChooser && upload.plan?.rootNames == ["Projekt"] && upload.plan?.files == 3,"upload preview enumerates nested files including empty files")
                check(!FileSystem.exists(root.appendingPathComponent("Server/Projekt")),"upload preview creates no remote target")
                check(uploadWindow.performKeyEquivalent(with:key(uploadWindow,"\r",.command)),"Command Return starts the checked remote upload")
                await wait("actual recursive upload") { self.main.jobs.pending == 0 && browser.browse.pending == 0 }
                check((try? String(contentsOf:root.appendingPathComponent("Server/Projekt/Unterordner/Grüße.txt"),encoding:.utf8)) == "Upload content ✔\n","queued upload writes the exact nested server contents")
                check(FileSystem.isDirectory(root.appendingPathComponent("Server/Projekt/Leer")) && (try? Data(contentsOf:root.appendingPathComponent("Server/Projekt/Null.bin")).isEmpty) == true,"upload preserves empty directories and zero-byte files")
                check(FileSystem.exists(root.appendingPathComponent("Links/Projekt/Unterordner/Grüße.txt")),"recursive uploads preserve all local source files")
                await activate(browserWindow);browserWindow.appearance = NSAppearance(named:.aqua);await capture(browserWindow,"-Serverfenster-Hell")
                browserWindow.appearance = NSAppearance(named:.darkAqua);await capture(browserWindow,"-Serverfenster-Dunkel")
                check(browser.downloadButton.toolTip?.contains("F5") == true && browser.uploadButton.toolTip?.contains("F6") == true,"server transfer buttons expose contextual function keys")
                check(main.canTerminate,"completed remote work does not prevent a regular application quit")
            }
            defaults.synchronize()
            print("REMOTE SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
