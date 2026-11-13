import AppKit
import CommanderCore

extension AppDelegate {
    func runLaunchSmoke(root: URL, prefix: String) {
        Task { @MainActor in
            var checks = 0, failures: [String] = []
            @MainActor func check(_ condition: Bool, _ name: String) {
                checks += 1;print("LAUNCH UI \(condition ? "PASS" : "FAIL") " + name)
                if !condition { failures.append(name) }
            }
            @MainActor func wait(_ name: String, _ predicate: () -> Bool) async throws {
                for _ in 0..<400 { if predicate() { return };try await Task.sleep(nanoseconds:25_000_000) }
                throw CommanderError.message("Zeitlimit: " + name)
            }
            func identity(_ url: URL) -> String { FileSystem.canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent).path }
            do {
                let clipboard = NSPasteboard.general.changeCount
                let domain = UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:]
                let left = FileSystem.canonical(root.appendingPathComponent("Links")),right = FileSystem.canonical(root.appendingPathComponent("Rechts"))
                let newLeft = left.appendingPathComponent("Start links"),newRight = right.appendingPathComponent("Start rechts")
                try FileManager.default.createDirectory(at:newLeft,withIntermediateDirectories:false)
                try FileManager.default.createDirectory(at:newRight,withIntermediateDirectories:false)
                let file = newLeft.appendingPathComponent("Grüße $ (1).txt"),hidden = newRight.appendingPathComponent(".ausgewählt")
                try Data("left source".utf8).write(to:file);try Data("hidden source".utf8).write(to:hidden)
                try await wait("initial lists") { !self.main.left.isLoading && !self.main.right.isLoading }
                self.main.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
                try await wait("active main window") { NSApp.isActive && self.main.window?.isKeyWindow == true }
                let locked = self.main.left.tab,otherTab = self.main.right.tab
                self.main.left.setTabLock(.fixed);self.main.right.setTabLock(.closeOnly)
                let originalLeft = locked.url,oldCount = self.main.left.tabs.count,rightCount = self.main.right.tabs.count
                self.main.linked = true;self.main.right.isHidden = true
                let request = try LaunchRequest.parse(["--left",file.path,"--right",newRight.path,"--select-right",hidden.lastPathComponent,"--active","right"])
                try self.main.applyLaunchRequest(request)
                try await wait("target lists and selection") {
                    !self.main.left.isLoading && !self.main.right.isLoading && !self.main.left.isSorting && !self.main.right.isSorting &&
                    self.main.left.selectedURLs.map(identity) == [identity(file)] && self.main.right.selectedURLs.map(identity) == [identity(hidden)]
                }
                check(self.main.left.tabs.count == oldCount+1,"a fixed tab is preserved while the left start target opens in a new tab")
                check(locked.url == originalLeft && locked.lockMode == .fixed,"the locked original folder and lock mode remain unchanged")
                check(self.main.right.tabs.count == rightCount && self.main.right.tab === otherTab,"an unlocked location of a close-protected tab is reused")
                check(otherTab.lockMode == .closeOnly,"reuse retains close protection")
                check(FileSystem.canonical(self.main.left.currentURL).path == FileSystem.canonical(newLeft).path && FileSystem.canonical(self.main.right.currentURL).path == FileSystem.canonical(newRight).path,"both launch directories are applied to their named sides")
                check(self.main.active === self.main.right,"the explicit active side receives focus")
                check(!self.main.left.isHidden && !self.main.right.isHidden,"explicit launch destinations become visible")
                check(self.main.linked,"linked navigation is retained after independent start targets")
                check(self.main.right.showHidden,"an explicitly selected hidden file is made visible on its side")
                check(self.main.left.selectedURLs.map(identity) == [identity(file)],"file arguments select their exact leaf without opening it")
                check(self.main.right.selectedURLs.map(identity) == [identity(hidden)],"explicit selection consumes the pending request after listing")
                let beforeNew = self.main.left.tabs.count
                try self.main.applyLaunchRequest(LaunchRequest.parse(["--left",newLeft.path,"--new-tabs"]))
                try await wait("additional tab") { !self.main.left.isLoading && self.main.left.tabs.count == beforeNew+1 }
                check(self.main.left.tabs.count == beforeNew+1,"new-tabs explicitly appends even for an existing location")
                check(self.main.active === self.main.left,"a single left target defaults to the left active side")
                let beforeActiveOnly = [self.main.left.tabs.count,self.main.right.tabs.count]
                try self.main.applyLaunchRequest(LaunchRequest.parse(["--active","right"]))
                check(self.main.active === self.main.right,"an active-only request changes focus")
                check([self.main.left.tabs.count,self.main.right.tabs.count] == beforeActiveOnly,"an active-only request does not add or replace tabs")
                let pathsBefore = [self.main.left.currentURL,self.main.right.currentURL]
                let invalidated = try LaunchRequest.parse(["--left",file.path,"--right",newRight.path])
                try Data("changed externally".utf8).write(to:file)
                do { try self.main.applyLaunchRequest(invalidated);check(false,"changed launch targets reject the entire request") }
                catch { check(true,"changed launch targets reject the entire request") }
                check([self.main.left.currentURL,self.main.right.currentURL] == pathsBefore,"validation fails before either pane navigates")
                self.main.left.beginPathEditing()
                do { try self.main.applyLaunchRequest(LaunchRequest.parse(["--left",left.path]));check(false,"draft path editing blocks external navigation") }
                catch { check(true,"draft path editing blocks external navigation") }
                self.main.left.endPathEditing(restoreFocus:false)
                let link = newLeft.appendingPathComponent("Verknüpfung")
                try FileManager.default.createSymbolicLink(atPath:link.path,withDestinationPath:"missing-target")
                try self.main.applyLaunchRequest(LaunchRequest.parse([link.path]))
                try await wait("link selection") { !self.main.left.isLoading && self.main.left.selectedURLs.map(identity) == [identity(link)] }
                check(self.main.left.selectedURLs.map(identity) == [identity(link)],"a dangling link is selected without following or opening it")
                let sameParentRequest = try LaunchRequest.parse(["--left",newLeft.absoluteString,"--select-left",file.lastPathComponent])
                try self.main.applyLaunchRequest(sameParentRequest)
                try await wait("file URL selection") { !self.main.left.isLoading && self.main.left.selectedURLs.map(identity) == [identity(file)] }
                check(FileSystem.canonical(self.main.left.currentURL).path == FileSystem.canonical(newLeft).path,"file URL launch targets reach the actual folder")
                check(self.main.left.selectedURLs.map(identity) == [identity(file)],"relative selectors retain quoted Unicode filenames")
                check(try Data(contentsOf:hidden) == Data("hidden source".utf8),"startup navigation does not modify selected file contents")
                check(NSPasteboard.general.changeCount == clipboard,"startup navigation preserves the general clipboard")
                check((domain as NSDictionary).isEqual(to:UserDefaults.standard.persistentDomain(forName:"local.zweicommander.app") ?? [:]),"test launches do not persist personal settings")
                self.main.content.layoutSubtreeIfNeeded()
                if let image = self.main.content.bitmapImageRepForCachingDisplay(in:self.main.content.bounds) {
                    self.main.content.cacheDisplay(in:self.main.content.bounds,to:image)
                    try image.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:prefix+"-Startparameter.png"))
                }
                print("LAUNCH SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");fflush(stdout);exit(failures.isEmpty ? 0 : 1)
            } catch { print("LAUNCH SMOKE FAIL " + error.localizedDescription);fflush(stdout);exit(1) }
        }
    }
}
