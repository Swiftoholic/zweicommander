import AppKit
import CommanderCore

extension MainWindow {
    func search() {
        let name = input("",placeholder:"z. B. *.pdf"), content = input("",placeholder:"Text in UTF-8/UTF-16-Dateien"), minimum = input("0"), maximum = input(""), days = input("")
        let regex = checkbox("Regulärer Ausdruck"), hidden = checkbox("Versteckte Dateien",on:Preferences.state.showHidden), archives = checkbox("Auch Dateinamen in Archiven")
        let office = checkbox("DOCX, XLSX, ODT und PPTX lesen",on:Preferences.state.importedProfile?.officeContentSearch ?? true)
        let root = active.currentURL, pane = active
        guard dialog("Dateien suchen",message:"Rekursiv in \(root.path). Text und ausgewählte Office-XML-Inhalte bis 32 MB; Archivsuche prüft Dateinamen.",accessory:form([("Name / Muster",name),("",regex),("Enthaltener Text",content),("Office-Inhalte",office),("Mindestgröße (KB)",minimum),("Höchstgröße (KB)",maximum),("Letzte Tage",days),("",hidden),("",archives)]),buttons:["Suchen","Abbrechen"]) == 0 else { return }
        var options = SearchOptions(); options.name = name.stringValue; options.regex = regex.state == .on; options.content = content.stringValue; options.showHidden = hidden.state == .on; options.searchArchives = archives.state == .on
        options.searchOfficeDocuments = office.state == .on
        guard let min = Int64(minimum.stringValue),min >= 0,min <= Int64.max/1024 else { showFailure(CommanderError.message("Ungültige Mindestgröße.")); return }; options.minimumSize = min*1024
        if !maximum.stringValue.isEmpty { guard let max = Int64(maximum.stringValue),max >= min,max <= Int64.max/1024 else { showFailure(CommanderError.message("Ungültige Höchstgröße.")); return }; options.maximumSize = max*1024 }
        if !days.stringValue.isEmpty { guard let d = Double(days.stringValue),d >= 0,d.isFinite else { showFailure(CommanderError.message("Ungültige Tageszahl.")); return }; options.modifiedAfter = Date().addingTimeInterval(-d*86400) }
        jobs.submit("Suche",work:{ token,progress in try SearchService.search(root,options:options,token:token,progress:{ progress("\($0) Einträge geprüft") }) },completion:{ [weak self,weak pane] result in
            switch result {
            case .success(let report):
                pane?.showCollection(report.urls,title:"Suche · "+(options.name.isEmpty ? "Ergebnisse" : options.name))
                self?.content.status.stringValue = "\(report.urls.count) Treffer · \(report.scanned) Einträge geprüft"
                if !report.warnings.isEmpty || !report.archiveMatches.isEmpty { self?.showText("Suchbericht","Treffer in Archiven:\n"+report.archiveMatches.joined(separator:"\n")+"\n\nHinweise:\n"+report.warnings.joined(separator:"\n")) }
            case .failure(let error): showFailure(error)
            }
        })
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
        let l = left.currentURL,r = right.currentURL
        guard !left.readOnly,!right.readOnly else { showFailure(CommanderError.message("Zum Synchronisieren bitte normale Ordner verwenden.")); return }
        let content = checkbox("Dateiinhalte mit SHA-256 vergleichen",on:true)
        guard dialog("Ordner vergleichen",message:"Links: \(l.path)\nRechts: \(r.path)\nOhne Inhaltsprüfung werden Größe und Änderungszeit verglichen.",accessory:form([("Prüfung",content)]),buttons:["Vergleichen","Abbrechen"]) == 0 else { return }
        let checkContent = content.state == .on
        jobs.submit("Ordnervergleich",work:{ token,progress in try CompareService.compare(l,r,content:checkContent,token:token,progress:progress) },completion:{ [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e): showFailure(e)
            case .success(let items):
                let different = items.filter { $0.state != .equal }
                let report = different.map { "\($0.state.rawValue.padding(toLength:15,withPad:" ",startingAt:0)) \($0.relativePath)" }.joined(separator:"\n")
                let answer = dialog("Vergleich: \(different.count) Unterschiede",message:"Links: \(l.path)\nRechts: \(r.path)\nDie gewählte Richtung ergänzt und ersetzt Dateien. Zusätzliche Dateien im Ziel bleiben erhalten. Ersetzte Dateien werden als versteckte Sicherungen aufbewahrt.",accessory:self.reportView(report.isEmpty ? "Alle verglichenen Dateien stimmen überein." : report),buttons:["Links → Rechts","Rechts → Links","Nur Bericht","Abbrechen"])
                if answer == 2 { self.showText("Ordnervergleich",report); return }
                guard answer == 0 || answer == 1 else { return }
                do {
                    let plan = try CompareService.plan(items,left:l,right:r,leftToRight:answer == 0)
                    guard !plan.isEmpty else { _ = dialog("Keine Änderungen nötig",buttons:["OK"]); return }
                    guard dialog("Synchronisierung ausführen?",message:"\(plan.count) Schritte. Bitte die Zielpfade prüfen.",accessory:self.reportView(plan.map { ($0.destinationStamp == nil ? "NEU       " : "ERSETZEN  ")+$0.destination.path }.joined(separator:"\n")),buttons:["Synchronisieren","Abbrechen"]) == 0 else { return }
                    self.jobs.submit("Synchronisieren",work:{ token,progress in CompareService.synchronize(plan,token:token,progress:progress) },completion:{ [weak self] in self?.complete($0) })
                } catch { showFailure(error) }
            }
        })
    }
    func pack() {
        guard let urls = requireSelection(),ensureWritable(other) else { return }
        let panel = NSSavePanel(); panel.directoryURL = other.currentURL; panel.nameFieldStringValue = (urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent : "Archiv")+"."+(Preferences.state.importedProfile?.defaultArchiveExtension ?? "zip")
        panel.message = "Endung .zip, .7z oder .tar.gz auswählen. Verknüpfungen werden nicht übernommen."
        guard panel.runModal() == .OK,let dest = panel.url else { return }
        guard !FileSystem.exists(dest) else { showFailure(CommanderError.message("Bitte einen neuen Archivnamen verwenden.")); return }
        let sevenZip = dest.pathExtension.lowercased() == "7z"
        let level = sevenZip ? Preferences.state.importedProfile?.sevenZipCompressionLevel ?? 6 : Preferences.state.importedProfile?.zipCompressionLevel ?? 6
        jobs.submit("Archiv erstellen",work:{ token,progress in try ArchiveService.pack(urls,to:dest,tarGzip:dest.lastPathComponent.hasSuffix(".tar.gz"),sevenZip:sevenZip,compressionLevel:level,token:token,progress:progress) },completion:{ [weak self] result in if case .failure(let e) = result { showFailure(e) }; self?.refresh() })
    }
    func extract() {
        guard let url = requireSelection()?.first,ensureWritable(other) else { return }
        let target = input(other.currentURL.appendingPathComponent(url.deletingPathExtension().lastPathComponent).path), password = NSSecureTextField(string:"")
        guard dialog("Archiv entpacken",message:"Es wird ein neuer Zielordner angelegt. ZIP, TAR sowie von macOS unterstützte 7z-/RAR-Varianten. Maximal 100 GB entpackte Daten je Vorgang.",accessory:form([("Zielordner",target),("Passwort (optional)",password)]),buttons:["Entpacken","Abbrechen"]) == 0 else { return }
        let dest = URL(fileURLWithPath:(target.stringValue as NSString).expandingTildeInPath), secret = password.stringValue
        jobs.submit("Archiv entpacken",work:{ token,progress in try ArchiveService.extract(url,to:dest,password:secret,token:token,progress:progress) },completion:{ [weak self] result in if case .failure(let e) = result { showFailure(e) }; self?.refresh() })
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
