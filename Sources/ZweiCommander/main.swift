import AppKit
import CommanderCore

final class AppDelegate:NSObject,NSApplicationDelegate,NSMenuItemValidation {
    var main:MainWindow!
    static let menuDefinitions:[(String,[(String,String,String)])] = [
        ("Datei",[("Öffnen","open","cmd+o"),("Vorschau","preview","F3"),("Mit TextEdit bearbeiten","edit","F4"),("Neuer Ordner …","newFolder","F7"),("Neue Datei …","newFile","shift+F4"),("—","",""),("Kopieren …","copy","F5"),("Verschieben …","move","F6"),("Umbenennen …","rename","F2"),("Mehrfachumbenennen …","batchRename","cmd+shift+m"),("In den Papierkorb …","trash","F8"),("—","",""),("Archiv erstellen …","pack","option+F5"),("Archiv entpacken …","extract","option+F6"),("Symbolische Verknüpfung …","symlink",""),("Eigenschaften","properties","cmd+i"),("Rechte und Datum …","attributes","")]),
        ("Bearbeiten",[("Rückgängig","undo","cmd+z"),("Ausschneiden","clipboardCut","cmd+x"),("Kopieren","clipboardCopy","cmd+c"),("Einfügen …","clipboardPaste","cmd+v"),("Pfad kopieren","copyPath","cmd+shift+c"),("—","",""),("Alles auswählen","selectAll","cmd+a"),("Auswahl umkehren","invertSelection","cmd+shift+a"),("Nach Muster auswählen …","selectPattern","cmd+shift+s")]),
        ("Ansicht",[("Aktualisieren","refresh","cmd+r"),("Versteckte Dateien","hidden","cmd+shift+."),("Ordnerbaum","tree","cmd+shift+t"),("Große Vorschaubilder","thumbnails","cmd+2"),("Schnellvorschau","quickView","cmd+y"),("Anordnung wechseln","orientation","cmd+option+h"),("Ein-/Zweifensteransicht","onePane","cmd+shift+1"),("Fensterinhalte tauschen","swap","cmd+u"),("Gleicher Ordner im anderen Fenster","sameFolder","cmd+shift+u"),("Verknüpftes Navigieren","linked",""),("Flache Ansicht","flat","cmd+b"),("Schnellfilter","filter","cmd+shift+f")]),
        ("Gehe zu",[("Pfad eingeben","path","cmd+l"),("Übergeordneter Ordner","parent","cmd+up"),("Zurück","back","cmd+["),("Vorwärts","forward","cmd+]"),("Benutzerordner","home","cmd+shift+h"),("Im Finder zeigen","reveal","cmd+shift+r"),("Favorit hinzufügen/entfernen","favorite","cmd+d"),("Terminal öffnen","terminal","cmd+shift+p"),("Mit Netzwerkvolume verbinden …","connect","cmd+k"),("FTP / SFTP verbinden …","remote","cmd+shift+k"),("SFTP im Terminal …","sftp","")]),
        ("Tabs",[("Neuer Tab","newTab","cmd+t"),("Tab schließen","closeTab","cmd+w"),("Tab sperren/entsperren","lockTab",""),("Tab benennen …","nameTab",""),("Leere Dateisammlung","newCollection",""),("Aus Sammlung entfernen","removeCollectionItem",""),("Auswahl als Dateisammlung","collection",""),("Dateisammlung speichern …","saveCollection",""),("Dateisammlung öffnen …","loadCollection","")]),
        ("Werkzeuge",[("Dateien suchen …","search","cmd+f"),("Duplikate suchen …","duplicates",""),("Ordner vergleichen / synchronisieren …","compare","cmd+shift+d"),("Ordnergröße berechnen","folderSize",""),("Prüfsummen berechnen …","hash",""),("Prüfsummenliste prüfen …","verifyHash",""),("Datei teilen …","split",""),("Teileliste zusammenfügen …","join",""),("Dateiliste exportieren …","export",""),("Shell-Befehl …","shell",""),("Vorgangsprotokoll","log","")]),
        ("Aufträge",[("Warteschlange anzeigen","operations","cmd+shift+j")]),
        ("Hilfe",[("Bedienung und Funktionsstand","help","F1"),("INI-Einstellungen importieren …","importSettings",""),("Importierte Einstellungen anzeigen","importReport",""),("Einstellungen vor dem Import wiederherstellen","restoreImport","")])
    ]
    func applicationDidFinishLaunching(_ notification:Notification) {
        let args = CommandLine.arguments
        let smoke = args.firstIndex(of:"--smoke-test")
        let operationsSmoke = args.firstIndex(of:"--operations-smoke")
        let filtersSmoke = args.firstIndex(of:"--filters-smoke")
        let mergeSmoke = args.firstIndex(of:"--merge-smoke")
        Preferences.testMode = smoke != nil || operationsSmoke != nil || filtersSmoke != nil || mergeSmoke != nil
        if Preferences.testMode { Preferences.state = SavedState() }
        if let index = args.firstIndex(of:"--import-settings"),args.indices.contains(index+1) {
            do {
                let profile = try INISettingsImport.load(directory:URL(fileURLWithPath:args[index+1]))
                Preferences.apply(profile)
                if let export = args.firstIndex(of:"--export-settings-profile"),args.indices.contains(export+1) {
                    let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
                    try encoder.encode(profile).write(to:URL(fileURLWithPath:args[export+1]),options:.atomic)
                }
                print("INI-Einstellungen importiert: \(profile.columns.count) Spalten, \(profile.plugins.filter(\.enabled).count) aktive Plug-in-Einträge. Pfadzuordnungen ausgelassen.")
            } catch { fputs("Einstellungsimport fehlgeschlagen: \(error.localizedDescription)\n",stderr);exit(2) }
        }
        let root = (smoke ?? operationsSmoke ?? filtersSmoke ?? mergeSmoke).flatMap { args.indices.contains($0+1) ? URL(fileURLWithPath:args[$0+1]) : nil }
        main = MainWindow(startLeft:root?.appendingPathComponent("Links"),startRight:root?.appendingPathComponent("Rechts"))
        main.onRebuildMenus = { [weak self] in self?.buildMenus(); self?.main.updateFunctionLabels() }
        buildMenus(); main.showWindow(nil); main.left.focus()
        NSApp.activate(ignoringOtherApps:true)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.main.content.layoutSubtreeIfNeeded()
            let split = self.main.content.split
            split.setPosition((split.isVertical ? split.bounds.width : split.bounds.height)/2,ofDividerAt:0)
        }
        if let smoke, args.indices.contains(smoke+2) {
            let imagePath = args[smoke+2]
            DispatchQueue.main.asyncAfter(deadline:.now()+2) { [weak self] in
                guard let self else { return }
                self.main.content.layoutSubtreeIfNeeded()
                self.runSmoke(imagePath:imagePath)
            }
        }
        if let operationsSmoke,args.indices.contains(operationsSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runOperationsSmoke(root:root,prefix:args[operationsSmoke+2]) }
        }
        if let filtersSmoke,args.indices.contains(filtersSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runFiltersSmoke(root:root,prefix:args[filtersSmoke+2]) }
        }
        if let mergeSmoke,args.indices.contains(mergeSmoke+2),let root {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { self.runMergeSmoke(root:root,prefix:args[mergeSmoke+2]) }
        }
    }
    static func parseShortcut(_ text:String) -> (String,NSEvent.ModifierFlags)? {
        if text.isEmpty { return ("",[]) }
        let pieces = text.lowercased().split(separator:"+").map(String.init)
        guard let last = pieces.last else { return nil }
        var flags:NSEvent.ModifierFlags = []
        for piece in pieces.dropLast() {
            switch piece { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "option","alt": flags.insert(.option); case "ctrl","control": flags.insert(.control); default:return nil }
        }
        let key:String
        if last.hasPrefix("f"),let n = Int(last.dropFirst()),(1...20).contains(n) { key = String(UnicodeScalar(Int(NSF1FunctionKey)+n-1)!) }
        else if last == "up" { key = String(UnicodeScalar(NSUpArrowFunctionKey)!) }
        else if last == "down" { key = String(UnicodeScalar(NSDownArrowFunctionKey)!) }
        else if last == "left" { key = String(UnicodeScalar(NSLeftArrowFunctionKey)!) }
        else if last == "right" { key = String(UnicodeScalar(NSRightArrowFunctionKey)!) }
        else if last == "space" { key = " " }
        else if last == "delete" { key = "\u{7f}" }
        else if last == "escape" { key = "\u{1b}" }
        else if last == "return" { key = "\r" }
        else if last.count == 1 { key = last }
        else { return nil }
        return (key,flags)
    }
    func buildMenus() {
        let bar = NSMenu(); NSApp.mainMenu = bar
        let appMenu = NSMenu(); let appItem = NSMenuItem(); appItem.submenu = appMenu; bar.addItem(appItem)
        let about = appMenu.addItem(withTitle:"Über ZweiCommander",action:#selector(about),keyEquivalent:""); about.target = self
        let settings = appMenu.addItem(withTitle:"Einstellungen …",action:#selector(dispatch(_:)),keyEquivalent:","); settings.representedObject = "settings"; settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"ZweiCommander ausblenden",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        appMenu.addItem(withTitle:"ZweiCommander beenden",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        for (title,commands) in Self.menuDefinitions {
            let menu = NSMenu(title:title), top = NSMenuItem(title:title,action:nil,keyEquivalent:""); top.submenu = menu; bar.addItem(top)
            for (label,id,defaultKey) in commands {
                if id.isEmpty { menu.addItem(.separator()); continue }
                let key = Preferences.state.shortcuts[id] ?? defaultKey, parsed = Self.parseShortcut(key) ?? ("",[])
                let item = NSMenuItem(title:label,action:#selector(dispatch(_:)),keyEquivalent:parsed.0); item.keyEquivalentModifierMask = parsed.1; item.target = self; item.representedObject = id; menu.addItem(item)
            }
        }
        let windowMenu = NSMenu(title:"Fenster"), top = NSMenuItem(title:"Fenster",action:nil,keyEquivalent:""); top.submenu = windowMenu; bar.insertItem(top,at:bar.items.count-1)
        windowMenu.addItem(withTitle:"Minimieren",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windowMenu.addItem(withTitle:"Zoom",action:#selector(NSWindow.performZoom(_:)),keyEquivalent:"")
        NSApp.windowsMenu = windowMenu
    }
    @objc func dispatch(_ sender:NSMenuItem) { if let id = sender.representedObject as? String { main.command(id) } }
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        guard let id = item.representedObject as? String else { return true }
        if id == "removeCollectionItem" { return main?.active.tab.collection != nil && NSApp.keyWindow === main?.window }
        if item.keyEquivalentModifierMask.isEmpty, item.keyEquivalent == " ", NSApp.keyWindow?.firstResponder is NSTextView { return false }
        return true
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"ZweiCommander",.applicationVersion:"0.5.0",.version:"5",.credits:NSAttributedString(string:"Dateimanager für macOS.\nSwift · AppKit · macOS-Systembibliotheken")]) }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if main?.pendingWork ?? 0 > 0 { _ = dialog("Dateivorgänge laufen",message:"Bitte erst die laufenden Vorgänge abschließen oder abbrechen.",buttons:["OK"]); return .terminateCancel }
        main?.saveState(); return .terminateNow
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool { main.showWindow(nil); return true }
    func applicationWillTerminate(_ notification:Notification) {
        main?.saveState()
        if let cache = main?.cache { try? FileManager.default.removeItem(at:cache) }
    }
    func applicationDidBecomeActive(_ notification:Notification) { if main != nil { main.refresh() } }
    func runSmoke(imagePath:String) {
        var failures:[String] = []
        func check(_ condition:Bool,_ name:String) { print("UI \(condition ? "PASS" : "FAIL") \(name)"); if !condition { failures.append(name) } }
        check(main.left.visibleEntries.count == 9 && main.right.visibleEntries.count == 3,"directory listing")
        print("UI geometry left=\(main.left.frame) right=\(main.right.frame) split=\(main.content.split.frame)")
        check(main.left.frame.width > 300 && main.right.frame.width > 300,"two visible panes")
        main.left.filterField.stringValue = "*.txt"; main.left.applyFilter()
        check(main.left.visibleEntries.count == 3,"wildcard quick filter")
        main.left.clearFilter()
        main.right.focus(); check(main.active === main.right,"pane focus")
        main.left.focus(); check(main.active === main.left,"pane switching")
        main.command("tree"); main.content.layoutSubtreeIfNeeded(); check(!main.left.tree.isHidden,"folder tree")
        main.command("tree")
        main.command("orientation"); main.content.layoutSubtreeIfNeeded()
        check(!main.content.split.isVertical && main.left.frame.height > 180 && main.right.frame.height > 180,"horizontal panes")
        main.command("orientation"); main.content.layoutSubtreeIfNeeded()
        main.command("quickView"); main.content.layoutSubtreeIfNeeded(); check(main.content.quickVisible && main.left.frame.width > 250,"quick preview layout")
        main.command("quickView"); main.content.layoutSubtreeIfNeeded()
        let originalTabs = main.left.tabs.count
        main.left.newTab(); check(main.left.tabs.count == originalTabs+1,"new tab")
        main.left.closeTab(); check(main.left.tabs.count == originalTabs,"close tab")
        let keys = Self.menuDefinitions.flatMap { $0.1 }.filter { !$0.2.isEmpty }.map { $0.2.lowercased() }
        check(Set(keys).count == keys.count,"unique default shortcuts")
        main.left.showCollection([],title:"Sammlungstest")
        main.left.addToCollection([main.right.currentURL.appendingPathComponent("Lesen.txt")])
        check(main.left.tab.collection?.count == 1,"collection references")
        main.left.tab.collection = [];main.left.closeTab()
        if let profile = Preferences.state.importedProfile {
            var previous = (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences.state))) as? [String:Any] ?? [:]
            previous["previousProfile"] = previous.removeValue(forKey:"importedProfile")
            let migrated = (try? JSONSerialization.data(withJSONObject:previous)).flatMap { Preferences.decode($0) }
            check(migrated?.importedProfile == profile && migrated?.shortcuts == Preferences.state.shortcuts,"previous profile schema preserved")
            let columns = main.left.table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue }
            check(columns == profile.columns.map(\.id),"imported columns")
            check(main.left.showHidden == profile.showHidden && main.left.importedProfile == profile,"imported appearance and hidden files")
            check(Preferences.state.shortcuts["newCollection"] == profile.shortcuts["newCollection"],"imported shortcuts")
            main.left.restoreConfigurationBeforeImport()
            check(main.left.importedProfile == nil && main.left.table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue } == ["name","ext","size","modified"],"restore original columns")
            main.left.configure(profile:profile,isLeft:true)
            check(main.left.table.tableColumns.filter { !$0.isHidden }.map { $0.identifier.rawValue } == profile.columns.map(\.id),"reapply imported columns")
        }
        Preferences.state.theme = 1; main.applyTheme()
        check(main.content.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .aqua,"light appearance")
        Preferences.state.theme = 2; main.applyTheme()
        check(main.content.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua,"dark appearance")
        Preferences.state.theme = Preferences.state.importedProfile.map { $0.darkAppearance ? 2 : 1 } ?? 0; main.applyTheme()
        DispatchQueue.main.asyncAfter(deadline:.now()+1) { [weak self] in
            guard let self else { return }
            self.main.content.layoutSubtreeIfNeeded()
            if let rep = self.main.content.bitmapImageRepForCachingDisplay(in:self.main.content.bounds) {
                self.main.content.cacheDisplay(in:self.main.content.bounds,to:rep)
                if let data = rep.representation(using:.png,properties:[:]) { try? data.write(to:URL(fileURLWithPath:imagePath)) }
            }
            print("SMOKE \(failures.isEmpty ? "PASS" : "FAIL")")
            if !failures.isEmpty { exit(1) }
            NSApp.terminate(nil)
        }
    }
}

if let index = CommandLine.arguments.firstIndex(of:"--inspect-binary"),CommandLine.arguments.indices.contains(index+1) {
    do { print(try BinaryInspector.describe(URL(fileURLWithPath:CommandLine.arguments[index+1])) ?? "Kein PE-/Mach-O-Binärformat.");exit(0) }
    catch { fputs(error.localizedDescription+"\n",stderr);exit(2) }
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
