import AppKit
import CommanderCore

extension MainWindow {
    func search() {
        let pane = active,target = other,controller = SearchController(root:pane.currentURL)
        controller.onOpen = { [weak self,weak pane] hit in
            guard let self,let pane else { return }
            guard FileSystem.exists(hit.url) else { showFailure(CommanderError.message("Der Suchtreffer ist nicht mehr vorhanden."));return }
            if hit.member != nil { self.openArchive(hit.url,in:pane) }
            else if FileSystem.isDirectory(hit.url) { pane.navigate(hit.url);self.window?.makeKeyAndOrderFront(nil) }
            else { NSWorkspace.shared.open(hit.url) }
        }
        controller.onPreview = { [weak self] url in self?.preview([url]) }
        controller.onReveal = { [weak self,weak pane] url in
            guard let self,let pane else { return }
            guard FileSystem.exists(url) else { showFailure(CommanderError.message("Der Suchtreffer ist nicht mehr vorhanden."));return }
            pane.reveal(url);self.window?.makeKeyAndOrderFront(nil)
        }
        controller.onCopy = { [weak self,weak target] urls in
            guard let self,let target,self.ensureWritable(target) else { return };self.transfer(urls,to:target.currentURL,kind:.copy)
        }
        controller.onCollection = { [weak self,weak pane] urls in pane?.showCollection(urls,title:"Suchergebnisse");self?.window?.makeKeyAndOrderFront(nil) }
        controller.onReport = { [weak self] report in self?.showText("Suchhinweise",report) }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
    func duplicates() {
        let root = active.currentURL,pane = active
        guard dialog("Duplikate suchen",message:"Dateien unter \(root.path) werden zuerst nach Größe, dann anhand von SHA-256 verglichen. Es wird nichts gelöscht.",buttons:["Suchen","Abbrechen"]) == 0 else { return }
        jobs.submit("Duplikatsuche",work:{ token,progress in try SearchService.duplicates(root,token:token,progress:progress) },completion:{ [weak self,weak pane] result in
            switch result {
            case .success(let groups):
                pane?.showCollection(groups.flatMap {$0},title:"Duplikate")
                self?.showText("Duplikatgruppen",groups.isEmpty ? "Keine identischen Dateien gefunden." : groups.enumerated().map { "Gruppe \($0.offset+1)\n"+$0.element.map(\.path).joined(separator:"\n") }.joined(separator:"\n\n"))
            case .failure(let e): showFailure(e)
            }
        })
    }
    func compare() {
        guard !left.readOnly,!right.readOnly,left.tab.collection == nil,right.tab.collection == nil else { showFailure(CommanderError.message("Zum Vergleichen bitte zwei normale Ordner verwenden."));return }
        let controller = CompareController(left:left.currentURL,right:right.currentURL),cache = self.cache
        controller.validatePaths = { l,r in guard !FileSystem.isInside(l,cache),!FileSystem.isInside(r,cache) else { throw CommanderError.message("Temporäre Archivordner sind schreibgeschützt.") } }
        controller.onPreview = { [weak self] in self?.preview([$0]) }
        controller.onReveal = { [weak self] url,isLeft in guard let self else { return };(isLeft ? self.left : self.right).reveal(url);self.window?.makeKeyAndOrderFront(nil) }
        controller.onReport = { [weak self] in self?.showText("Synchronisation · Bericht",$0) }
        controller.onCancel = { [weak self] id in self?.jobs.scheduler.cancel(id) }
        controller.onSubmit = { [weak self,weak controller] plan,start in
            guard let self else { return UUID() }
            return self.jobs.submitReported("Ordner synchronisieren",start:start,items:plan.initialItems,notifyQueuedCancellation:true,body:{ token,reporter in
                FolderSyncEngine.execute(plan,token:token,progress:{ value in
                    reporter.transfer(value)
                    DispatchQueue.main.async { controller?.updateProgress(value.detail) }
                })
            },completion:{ [weak self,weak controller] result in
                controller?.finished(result)
                if case .success(let report) = result { self?.undoSteps = report.undo;self?.renameUndo = nil;self?.jobs.log.append("Synchronisierung: \(report.completed.count) Schritte · \(report.errors.count) Fehler") }
                self?.refresh()
            })
        }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
    func pack() {
        guard let urls = requireSelection(),ensureWritable(other) else { return };showArchivePack(urls)
    }
    func extract() {
        guard let url = requireSelection()?.first,ensureWritable(other) else { return }
        showArchiveSetup(mode:.extract(url,nil,nil,""),destination:other.currentURL.appendingPathComponent(ArchiveCatalog.folderName(for:url)))
    }
    func hashes() {
        guard let urls = requireSelection() else { return }
        let algorithm = NSPopUpButton(); algorithm.addItems(withTitles:HashAlgorithm.allCases.map(\.rawValue))
        guard dialog("Prüfsummen berechnen",accessory:form([("Algorithmus",algorithm)]),buttons:["Berechnen","Abbrechen"]) == 0 else { return }
        let selected = HashAlgorithm.allCases[algorithm.indexOfSelectedItem]
        jobs.submit("Prüfsummen",work:{ token,progress in try urls.map { url -> (URL,String) in progress(url.lastPathComponent); return (url,try Checksums.hash(url,algorithm:selected,token:token)) } },completion:{ [weak self] result in
            switch result {
            case .failure(let e): showFailure(e)
            case .success(let values):
                let report = values.map { $0.1+"  "+$0.0.path }.joined(separator:"\n")
                self?.showText(selected.rawValue+" · Prüfsummen",report)
                guard dialog("Prüfsummenliste speichern?",message:"Die Liste kann später mit „Prüfsummen prüfen“ kontrolliert werden.",buttons:["Speichern …","Nur anzeigen"]) == 0 else { return }
                let panel = NSSavePanel(); panel.directoryURL = urls[0].deletingLastPathComponent(); panel.nameFieldStringValue = "Pruefsummen."+selected.rawValue.lowercased().replacingOccurrences(of:"-",with:"")
                if panel.runModal() == .OK,let dest = panel.url {
                    do {
                        let parent = dest.deletingLastPathComponent()
                        guard values.allSatisfy({ FileSystem.isInside($0.0,parent) && !$0.0.path.contains("\n") }) else { throw CommanderError.message("Die Liste muss in einem gemeinsamen übergeordneten Ordner der geprüften Dateien liegen. Dateinamen dürfen keinen Zeilenumbruch enthalten.") }
                        let text = try values.map { try $0.1+"  "+FileSystem.relativePath(of:$0.0,inside:parent) }.joined(separator:"\n")+"\n"
                        try text.write(to:dest,atomically:true,encoding:.utf8); self?.refresh()
                    } catch { showFailure(error) }
                }
            }
        })
    }
    func verifyHashes() {
        guard let url = requireSelection()?.first else { return }
        let algorithm = NSPopUpButton(); algorithm.addItems(withTitles:HashAlgorithm.allCases.map(\.rawValue))
        if let i = HashAlgorithm.allCases.firstIndex(where: { $0.rawValue.lowercased().replacingOccurrences(of:"-",with:"") == url.pathExtension.lowercased() }) { algorithm.selectItem(at:i) }
        guard dialog("Prüfsummenliste prüfen",message:url.lastPathComponent,accessory:form([("Algorithmus",algorithm)]),buttons:["Prüfen","Abbrechen"]) == 0 else { return }
        let selected = HashAlgorithm.allCases[algorithm.indexOfSelectedItem]
        jobs.submit("Prüfsummen prüfen",work:{ token,_ in try Checksums.verify(url,algorithm:selected,token:token).joined(separator:"\n") },completion:{ [weak self] result in switch result { case .success(let report): self?.showText("Prüfsummenprüfung",report); case .failure(let e): showFailure(e) } })
    }
    func splitFile() {
        guard let url = requireSelection()?.first,ensureWritable(other) else { return }
        let size = input("100"),target = input(other.currentURL.appendingPathComponent(url.lastPathComponent+" Teile").path)
        guard dialog("Datei teilen",message:"Erstellt Teilstücke und eine SHA-256-gesicherte Teileliste. Die Originaldatei bleibt erhalten.",accessory:form([("Teilgröße (MiB)",size),("Neuer Zielordner",target)]),buttons:["Teilen","Abbrechen"]) == 0 else { return }
        guard let mb = Int64(size.stringValue),mb > 0,mb <= Int64.max/(1024*1024) else { showFailure(CommanderError.message("Ungültige Teilgröße.")); return }
        let dest = URL(fileURLWithPath:target.stringValue)
        jobs.submit("Datei teilen",work:{ token,progress in try FileTools.split(url,to:dest,chunkBytes:mb*1024*1024,token:token,progress:progress) },completion:{ [weak self] result in if case .failure(let e) = result { showFailure(e) }; self?.refresh() })
    }
    func joinFile() {
        guard let manifest = requireSelection()?.first,ensureWritable(other) else { return }
        do {
            let info = try JSONDecoder().decode(SplitManifest.self,from:Data(contentsOf:manifest))
            let panel = NSSavePanel(); panel.directoryURL = other.currentURL; panel.nameFieldStringValue = info.originalName
            panel.message = "Teileliste: "+manifest.lastPathComponent
            guard panel.runModal() == .OK,let dest = panel.url else { return }
            jobs.submit("Datei zusammenfügen",work:{ token,progress in try FileTools.join(manifest,to:dest,token:token,progress:progress) },completion:{ [weak self] result in if case .failure(let e) = result { showFailure(e) }; self?.refresh() })
        } catch { showFailure(CommanderError.message("Bitte die beim Teilen erzeugte Datei „parts.zwei.json“ auswählen.\n"+error.localizedDescription)) }
    }
    func properties() {
        let urls = active.selectedURLs.isEmpty ? [active.currentURL] : active.selectedURLs
        let text = urls.map { url -> String in
            guard let e = try? FileEntry(url:url) else { return url.path+"\nNicht lesbar" }
            let attributes = (try? FileManager.default.attributesOfItem(atPath:url.path)) ?? [:]
            let binary = (try? BinaryInspector.describe(url)) ?? nil
            return "\(e.name)\nPfad: \(url.path)\nArt: \(e.kind)\nGröße: \(bytes(e.size))\nGeändert: \(displayDate.string(from:e.modified))\nRechte: \(String(format:"%03o",e.permissions))\nBesitzer: \(attributes[.ownerAccountName] ?? "—")\nGruppe: \(attributes[.groupOwnerAccountName] ?? "—")"+(e.isSymbolicLink ? "\nVerknüpfung → "+((try? FileManager.default.destinationOfSymbolicLink(atPath:url.path)) ?? "?") : "")+(binary.map { "\n\nDATEISTRUKTUR\n"+$0 } ?? "")
        }.joined(separator:"\n\n")
        showText("Eigenschaften",text)
    }
    func attributes() {
        guard ensureWritable(active),let urls = requireSelection() else { return }
        let mode = input("",placeholder:"z. B. 644"), date = input("",placeholder:"2026-10-17 15:30:00")
        guard dialog("Rechte und Änderungsdatum",message:"Gilt nur für die ausgewählten Objekte, nicht rekursiv. Leere Felder bleiben unverändert. Verknüpfungen sind ausgeschlossen.",accessory:form([("POSIX-Rechte (oktal)",mode),("Datum (lokale Zeit)",date)]),buttons:["Anwenden","Abbrechen"]) == 0 else { return }
        do {
            var attrs:[FileAttributeKey:Any] = [:]
            if !mode.stringValue.isEmpty { guard let number = Int(mode.stringValue,radix:8),number >= 0,number <= 0o777 else { throw CommanderError.message("Rechte müssen zwischen 000 und 777 liegen.") }; attrs[.posixPermissions] = number }
            if !date.stringValue.isEmpty { let parser = DateFormatter(); parser.locale = Locale(identifier:"en_US_POSIX"); parser.dateFormat = "yyyy-MM-dd HH:mm:ss"; parser.isLenient = false; guard let value = parser.date(from:date.stringValue) else { throw CommanderError.message("Ungültiges Datum.") }; attrs[.modificationDate] = value }
            for url in urls { guard !FileSystem.isSymlink(url) else { throw CommanderError.message("Verknüpfung ausgeschlossen: "+url.path) } }
            for url in urls { try FileManager.default.setAttributes(attrs,ofItemAtPath:url.path) }
            refresh()
        } catch { showFailure(error) }
    }
}
