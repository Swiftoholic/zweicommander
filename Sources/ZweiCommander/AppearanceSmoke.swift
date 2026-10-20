import AppKit
import CommanderCore

extension AppDelegate {
    func runAppearanceSmoke(root: URL,prefix: String,reload: Bool) {
        var failures: [String] = [],checks = 0
        func check(_ value: Bool,_ name: String) { checks += 1;print("APPEARANCE UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
        func require<T>(_ value: T?,_ name: String) -> T {
            guard let value else { print("APPEARANCE SMOKE FAIL missing \(name)");exit(1) };return value
        }
        func saveAppearance(_ value: AppearanceSettings) {
            do { try Preferences.saveAppearance(value) } catch { print("APPEARANCE SMOKE FAIL saving isolated appearance settings");exit(1) }
        }
        func finish() {
            Preferences.appearanceTestDefaults?.synchronize()
            print("APPEARANCE SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
        func waitFor(_ condition: @escaping ()->Bool,then: @escaping ()->Void,attempt: Int = 0) {
            if condition() { then();return };guard attempt < 100 else { print("APPEARANCE SMOKE FAIL timed out");exit(1) }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.1) { waitFor(condition,then:then,attempt:attempt+1) }
        }
        func theme(_ index: Int) { main.themeMenu.selectItem(at:index);_ = main.themeMenu.sendAction(main.themeMenu.action,to:main.themeMenu.target) }
        func capture(_ window: NSWindow?,_ name: String) -> NSBitmapImageRep? {
            guard let view = window?.contentView else { return nil };view.layoutSubtreeIfNeeded();view.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return nil };view.cacheDisplay(in:view.bounds,to:rep)
            guard let data = rep.representation(using:.png,properties:[:]) else { return nil }
            do { try data.write(to:URL(fileURLWithPath:prefix+name+".png"));return rep } catch { return nil }
        }
        func listPixel(_ rep: NSBitmapImageRep?,_ pane: PaneView) -> NSColor? {
            guard let rep else { return nil }
            let point = main.content.convert(NSPoint(x:pane.scroll.frame.midX,y:pane.scroll.frame.midY),from:pane)
            return rep.colorAt(x:Int(point.x),y:Int(main.content.bounds.height-point.y-1))
        }
        func headerHasText(_ rep: NSBitmapImageRep?,light: Bool) -> Bool {
            guard let rep,let header = main.left.table.headerView else { return false }
            let rect = main.content.convert(NSRect(x:6,y:3,width:60,height:16),from:header)
            var pixels = 0
            for x in Int(rect.minX)..<Int(rect.maxX) {
                for y in Int(rect.minY)..<Int(rect.maxY) {
                    if let color = rep.colorAt(x:x,y:Int(main.content.bounds.height)-y-1),color.alphaComponent > 0.99 {
                        let value = CommanderPalette.luminance(color)
                        if light ? value < 0.25 : value > 0.6 { pixels += 1 }
                    }
                }
            }
            return pixels > 20
        }
        let pane = main.left,folder = root.appendingPathComponent("Links"),other = main.right.currentURL
        let text = pane.visibleEntries.first(where: { $0.name == "Besprechung.txt" })?.url ?? folder.appendingPathComponent("Besprechung.txt"),documents = folder.appendingPathComponent("Dokumente"),photos = folder.appendingPathComponent("Fotos")
        guard let defaults = Preferences.appearanceTestDefaults else { print("APPEARANCE SMOKE FAIL isolated defaults missing");exit(1) }
        let places = [("System",URL(fileURLWithPath:"/")),("Projekte",folder),("Sicherung",other)]
        for p in [main.left,main.right] { p.locations.configure(places);p.locations.select(p.currentURL) }
        if reload {
            let settings = Preferences.appearanceSettings()
            check(!settings.compact && settings.fontSize == 14,"density and font survive a separate process")
            check(!settings.toolbarLabels && !settings.importedColors,"toolbar and palette options survive restart")
            check(pane.table.rowHeight == 28 && pane.listFont.pointSize == 14,"persisted metrics are applied at launch")
            check(main.content.toolbar.arrangedSubviews.compactMap { $0 as? ActionButton }.allSatisfy { $0.title.isEmpty },"persisted icon-only toolbar is rebuilt")
            theme(1)
            check(CommanderPalette.luminance(pane.table.backgroundColor) > 0.8,"persisted settings still permit fully light content")
            let saved = require(defaults.data(forKey:Preferences.appearanceKey),"persisted appearance")
            defaults.set(Data("{broken".utf8),forKey:Preferences.appearanceKey)
            do { try Preferences.saveAppearance(AppearanceSettings());check(false,"corrupt appearance data blocks saving") } catch { check(true,"corrupt appearance data blocks saving") }
            check(defaults.data(forKey:Preferences.appearanceKey) == Data("{broken".utf8),"corrupt data is preserved byte for byte")
            var unknown = settings;unknown.schemaVersion = 99
            let data = require(try? JSONEncoder().encode(unknown),"future schema fixture");defaults.set(data,forKey:Preferences.appearanceKey)
            do { try Preferences.saveAppearance(settings);check(false,"future appearance versions block replacement") } catch { check(defaults.data(forKey:Preferences.appearanceKey) == data,"future appearance versions block replacement") }
            defaults.set(saved,forKey:Preferences.appearanceKey)
            check((try? JSONDecoder().decode(AppearanceSettings.self,from:saved)) == settings,"supported settings remain recoverable")
            finish();return
        }
        check(pane.visibleEntries.count == 9 && pane.table.rowHeight == 21,"compact file list opens with all fixture files")
        check(main.left.locations !== main.right.locations && main.left.locations.stack.arrangedSubviews.count == 3,"each pane has its own location strip")
        let profile = pane.importedProfile
        pane.select([text]);theme(1)
        func runLightChecks() {
            check(CommanderPalette.luminance(pane.table.backgroundColor) > 0.8 && CommanderPalette.luminance(main.right.table.backgroundColor) > 0.8,"light mode replaces both imported dark backgrounds")
            check(pane.grid.backgroundColors.first == pane.table.backgroundColor && pane.scroll.backgroundColor == pane.table.backgroundColor,"list and icon surfaces share the light palette")
            check(CommanderPalette.contrast(pane.fileTextColor(text.lastPathComponent),pane.table.backgroundColor) >= 4.5,"light file text retains readable contrast")
            check(pane.selectedURLs == [text] && pane.importedProfile == profile,"theme changes preserve selection and imported configuration")
            let light = capture(main.window,"-Hell")
            check(headerHasText(light,light:true),"light table header contains readable dark column titles")
            check(listPixel(light,pane).map { $0.alphaComponent > 0.99 && CommanderPalette.luminance($0) > 0.8 } == true,"light snapshot contains an opaque light file area")
            check(listPixel(light,main.right).map { $0.alphaComponent > 0.99 && CommanderPalette.luminance($0) > 0.8 } == true,"inactive light pane is also rendered light")
            theme(2)
            func runDarkChecks() {
                check(CommanderPalette.luminance(pane.table.backgroundColor) < 0.3,"dark palette reaches the file content")
                check(CommanderPalette.contrast(pane.fileTextColor(text.lastPathComponent),pane.table.backgroundColor) >= 4.5,"dark file text retains readable contrast")
                let palette = pane.palette
                check(CommanderPalette.contrast(palette.readable(.yellow,on:.white),.white) >= 4.5,"low-contrast file colors are repaired for a light background")
                let medium = NSColor(srgbRed:0.55,green:0.55,blue:0.55,alpha:1)
                check(CommanderPalette.contrast(palette.readable(nil,on:medium),medium) >= 4.5 && CommanderPalette.contrast(palette.readable(.yellow,on:medium),medium) >= 4.5,"medium gray imports retain readable standard and file-type text")
                var settings = AppearanceSettings();settings.importedColors = false;saveAppearance(settings);main.applyAppearanceSettings()
                for p in [main.left,main.right] { p.locations.configure(places);p.locations.select(p.currentURL) }
                check(CommanderPalette.luminance(pane.table.backgroundColor) > CommanderPalette.luminance(main.right.table.backgroundColor),"active dark pane is lighter than the inactive pane")
                main.right.focus()
                check(CommanderPalette.luminance(main.right.table.backgroundColor) > CommanderPalette.luminance(pane.table.backgroundColor) && main.right.breadcrumb.active && !pane.breadcrumb.active,"active shading and path highlight follow the focused pane")
                pane.focus();main.content.layoutSubtreeIfNeeded()
                let dark = capture(main.window,"-Dunkel")
                check(headerHasText(dark,light:false),"dark table header contains readable light column titles")
                check(listPixel(dark,pane).map { $0.alphaComponent > 0.99 && CommanderPalette.luminance($0) < 0.3 } == true,"dark snapshot contains an opaque graphite file area")
                check(main.themeMenu.indexOfSelectedItem == 2,"toolbar rebuilding preserves the displayed theme choice")
                pane.changeDisplay(.icons)
                check(pane.selectedURLs == [text] && pane.scroll.documentView === pane.grid,"icon view retains the selected file")
                theme(1)
                let index = require(pane.visibleEntries.firstIndex(where: { $0.url == text }),"selected icon file")
                let item = require(pane.collectionView(pane.grid,itemForRepresentedObjectAt:IndexPath(item:index,section:0)) as? FileIconItem,"icon item")
                check(item.pane === pane && CommanderPalette.contrast(item.normalColor,pane.table.backgroundColor) >= 4.5,"icon captions use the current readable palette")
                pane.changeDisplay(.details)
                check(pane.selectedURLs == [text] && pane.table.rowHeight == 21,"returning to details restores compact metrics and selection")
                main.command("path")
                check(!pane.pathField.isHidden && pane.breadcrumb.isHidden && main.window?.firstResponder is NSTextView,"Cmd+L exposes and focuses the path editor")
                (pane.pathField.currentEditor() as? NSTextView)?.doCommand(by:#selector(NSResponder.cancelOperation(_:)))
                check(pane.pathField.isHidden && !pane.breadcrumb.isHidden && pane.currentURL == folder,"Escape restores the breadcrumb without navigation")
                main.command("path");pane.pathField.stringValue = documents.path;pane.pathEntered()
                waitFor({ pane.currentURL == documents && pane.visibleEntries.isEmpty },then:{
                    check(self.main.right.currentURL == other && pane.pathField.isHidden,"path entry navigates only its own pane")
                    require(pane.breadcrumb.components.first(where: { $0.0 == folder }),"ancestor breadcrumb").1.performClick(nil)
                    waitFor({ pane.currentURL == folder && pane.visibleEntries.count == 9 },then:{
                        check(pane.breadcrumb.url == folder,"a real breadcrumb button opens its ancestor")
                        require(pane.locations.stack.arrangedSubviews.compactMap { $0 as? ActionButton }.first(where: { $0.title == "Sicherung" }),"location button").performClick(nil)
                        waitFor({ pane.currentURL == other && pane.visibleEntries.count == 3 },then:{
                            check(self.main.right.currentURL == other,"location buttons navigate their associated pane")
                            self.main.content.commandMode.selectItem(at:0);self.main.commandModeChanged();self.main.content.commandField.stringValue = folder.path;self.main.content.commandGo.performClick(nil)
                            waitFor({ pane.currentURL == folder && pane.visibleEntries.count == 9 },then:{
                                check(self.main.content.commandMode.indexOfSelectedItem == 0,"bottom path mode opens a folder through its action button")
                                pane.newTab(url:documents);let closingID = pane.tab.id
                                pane.newTab(url:photos);let retainedID = pane.tab.id
                                let closing = require(pane.tabsStack.arrangedSubviews.compactMap { $0 as? FolderTabButton }.first(where: { $0.tabID == closingID }),"inactive tab")
                                closing.closeButton.performClick(nil)
                                check(pane.tab.id == retainedID && !pane.tabs.contains(where: { $0.id == closingID }),"closing an inactive tab preserves the selected tab identity")
                                pane.tab.locked = true;pane.rebuildTabs()
                                check(require(pane.tabsStack.arrangedSubviews.compactMap { $0 as? FolderTabButton }.first(where: { $0.tabID == retainedID }),"locked tab").closeButton.isHidden,"locked tabs hide their close button")
                                pane.tab.locked = false;pane.closeTab()
                                require(self.main.content.rail.buttons.first(where: { $0.identifier?.rawValue == "linked" }),"linked rail action").performClick(nil)
                                check(self.main.linked,"middle rail toggles linked navigation")
                                self.main.command("linked")
                                require(self.main.content.rail.buttons.first(where: { $0.identifier?.rawValue == "orientation" }),"orientation rail action").performClick(nil);self.main.content.layoutSubtreeIfNeeded()
                                check(!self.main.content.split.isVertical && !self.main.content.rail.vertical && self.main.content.rail.frame.height == 28,"middle actions follow horizontal pane arrangement")
                                self.main.command("orientation");self.main.content.layoutSubtreeIfNeeded()
                                check(self.main.content.rail.vertical && self.main.content.rail.frame.width == 28,"vertical arrangement restores the narrow action rail")
                                self.main.command("onePane");self.main.content.layoutSubtreeIfNeeded()
                                check(self.main.right.isHidden && self.main.content.rail.isHidden,"single-pane view hides the middle rail")
                                self.main.command("onePane");self.main.content.layoutSubtreeIfNeeded()
                                self.main.window?.setContentSize(NSSize(width:900,height:500));self.main.content.layoutSubtreeIfNeeded()
                                check(pane.scroll.frame.height > 200 && pane.filterField.frame.minX > pane.status.frame.maxX,"compact minimum-size layout keeps list and filter separate")
                                check(self.main.content.utilityBar.frame.maxX <= self.main.content.bounds.width && self.main.themeMenu.frame.width > 60,"theme and favorites remain available in a narrow window")
                                self.main.command("quickView");self.main.content.layoutSubtreeIfNeeded()
                                check(pane.frame.width > 200 && self.main.content.quick.frame.width > 200,"preview and both panes fit the minimum window width")
                                self.main.command("quickView");self.main.window?.setContentSize(NSSize(width:1280,height:780));self.main.content.layoutSubtreeIfNeeded()
                                let point = self.main.content.convert(NSPoint(x:14,y:50),from:self.main.content.rail)
                                check(self.main.content.hitTest(point) !== self.main.content.rail,"empty rail space does not intercept splitter dragging")
                                self.verifyAppearanceWindows(root:root,prefix:prefix,check:check,then:{
                                    self.main.window?.makeKeyAndOrderFront(nil);pane.focus();theme(0)
                                    check(NSApp.appearance == nil,"system mode releases the explicit app appearance")
                                    self.main.window?.appearance = NSAppearance(named:.aqua)
                                    DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
                                        check(CommanderPalette.luminance(pane.table.backgroundColor) > 0.8,"inherited appearance changes refresh light content without a manual rebuild")
                                        self.main.window?.appearance = NSAppearance(named:.darkAqua)
                                        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
                                            check(CommanderPalette.luminance(pane.table.backgroundColor) < 0.3,"inherited appearance changes also refresh dark content")
                                            self.main.window?.appearance = nil
                                            settings.compact = false;settings.fontSize = 14;settings.toolbarLabels = false;settings.importedColors = false
                                            saveAppearance(settings);self.main.applyAppearanceSettings();theme(1)
                                            check(pane.table.rowHeight == 28 && pane.listFont.pointSize == 14,"comfortable density and larger type update live")
                                            check(self.main.content.toolbar.arrangedSubviews.compactMap { $0 as? ActionButton }.allSatisfy { $0.title.isEmpty && !$0.verticalLabel },"icon-only toolbar applies to every action")
                                            self.main.content.commandMode.selectItem(at:1);self.main.commandModeChanged();self.main.content.commandField.stringValue = "printf 'appearance-command-ok'";self.main.content.commandGo.performClick(nil)
                                            waitFor({ self.main.jobs.pending == 0 && self.main.secondaryWindows.contains(where: { ($0 as? TextWindow)?.textView.string == "appearance-command-ok" }) },then:{
                                                check(pane.currentURL == folder && self.main.jobs.scheduler.snapshots.last?.state == .completed,"explicit command mode runs zsh and shows its output")
                                                self.main.secondaryWindows.compactMap { $0 as? TextWindow }.forEach { $0.close() };finish()
                                            })
                                        }
                                    }
                                })
                            })
                        })
                    })
                })
            }
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { runDarkChecks() }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { runLightChecks() }
    }
    private func verifyAppearanceWindows(root: URL,prefix: String,check: (Bool,String)->Void,then: ()->Void) {
        let folder = root.appendingPathComponent("Links"),file = folder.appendingPathComponent("Besprechung.txt")
        let search = SearchController(root:folder),rename = RenameController(sources:[file]),compare = CompareController(left:folder,right:root.appendingPathComponent("Rechts")),text = TextWindow(title:"Darstellung",text:"Neutrale Testdatei")
        let preview = PreviewController(file);preview.mode.selectedSegment = 1;preview.previewModeChanged()
        let controllers: [NSWindowController] = [search,rename,compare,text,preview]
        controllers.forEach { $0.showWindow(nil) }
        for theme in [1,2] {
            Preferences.state.theme = theme;main.applyTheme()
            let light = theme == 1
            let tables = [search.table,rename.table,compare.table]
            check(tables.allSatisfy { light ? CommanderPalette.luminance($0.backgroundColor) > 0.8 : CommanderPalette.luminance($0.backgroundColor) < 0.3 },light ? "search rename and comparison tables switch to light content" : "open workspace tables switch back to dark content")
            check([text.textView,preview.text].allSatisfy { light ? CommanderPalette.luminance($0.backgroundColor) > 0.8 : CommanderPalette.luminance($0.backgroundColor) < 0.3 },light ? "text and preview windows use light document surfaces" : "text and preview windows follow the dark palette")
        }
        controllers.forEach { $0.close() };then()
    }
}
