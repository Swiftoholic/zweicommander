import AppKit
import CommanderCore

private final class ArchiveSurface:CommanderSurface {
    var arrange:((NSSize)->Void)?
    override func layout() { super.layout();arrange?(bounds.size) }
}

extension ArchiveSetupController {
    func buildArchiveInterface(_ w:NSWindow) {
        let root = ArchiveSurface(frame:w.contentView!.bounds);root.autoresizingMask = [.width,.height];w.contentView = root
        heading.stringValue = w.title;destinationCaption.stringValue = packing ? "Archivdatei" : "Zielordner"
        switch mode { case .pack(let sources):sourceInfo.stringValue = "\(sources.count) ausgewählte Quellen · Originale bleiben erhalten"
        case .extract(let url,_,_,_):sourceInfo.stringValue = url.lastPathComponent+" · Neuer oder vorhandener Zielordner" }
        [heading,sourceInfo,destinationCaption,destination,choose,selectedOnly,optionsInfo,info,safety,refresh,cancel,queue,start,conflictsOnly,previousConflict,nextConflict,pageInfo,previousPage,nextPage].forEach { root.addSubview($0) }
        let options = packing ? row([label("Format"),format,label("Kompression"),compression]) : row([label("Passwort (optional)"),password]);root.addSubview(options)
        let policies = row([label("Bei Namenskonflikten",weight:.medium),policy]);policies.isHidden = packing;root.addSubview(policies)
        policy.widthAnchor.constraint(greaterThanOrEqualToConstant:290).isActive = true;policy.setAccessibilityLabel("Archivkonflikte behandeln")
        password.widthAnchor.constraint(greaterThanOrEqualToConstant:360).isActive = true;password.setAccessibilityLabel("Passwort für das zu entpackende Archiv")
        password.toolTip = "Nur für diesen Vorgang. Keine Speicherung in Einstellungen, Profilen oder dem Auftragsjournal."
        destination.setAccessibilityLabel(packing ? "Neue Archivdatei" : "Zielordner zum Entpacken");destination.toolTip = "⌘L · Ziel bearbeiten. Ein vorhandener Ordner wird vor dem Start auf Konflikte geprüft."
        selectedOnly.isHidden = packing;selectedOnly.toolTip = "Mit Auswahl bleiben die Namen relativ zum angezeigten Archivordner erhalten. Ohne Auswahl wird das vollständige Archiv entpackt."
        choose.perform = { [weak self] in self?.chooseDestination() };choose.setHelp("Ziel wählen","Einen Zielordner auswählen oder anlegen.",shortcut:"⌘⇧L")
        refresh.perform = { [weak self] in self?.prepare() };refresh.setHelp("Neu prüfen","Archiv und Ziel neu einlesen; bisherige Einzelentscheidungen werden zurückgesetzt.",shortcut:"⌘R")
        cancel.perform = { [weak self] in self?.close() };cancel.keyEquivalent = "\u{1b}";cancel.keyEquivalentModifierMask = []
        start.perform = { [weak self] in self?.submit(true) };queue.perform = { [weak self] in self?.submit(false) }
        start.setHelp("Starten","Nach Klärung aller Konflikte die geprüfte Auswahl entpacken.",shortcut:"⌘↩");queue.setHelp("Vormerken","Den geprüften Plan für diese Sitzung vormerken.",shortcut:"⌘⇧↩")
        previousConflict.perform = { [weak self] in self?.focusConflict(backward:true) };nextConflict.perform = { [weak self] in self?.focusConflict(backward:false) }
        previousConflict.setHelp("Vorheriger Konflikt","Zum vorherigen offenen Konflikt springen, auch außerhalb der aktuellen Vorschauseite.",shortcut:"⌘⌥↑")
        nextConflict.setHelp("Nächster Konflikt","Zum nächsten offenen Konflikt springen, auch außerhalb der aktuellen Vorschauseite.",shortcut:"⌘⌥↓")
        previousPage.perform = { [weak self] in self?.changePage(-1) };nextPage.perform = { [weak self] in self?.changePage(1) }
        previousPage.setHelp("Vorherige Seite","Die vorherigen bis zu 500 Einträge anzeigen.");nextPage.setHelp("Nächste Seite","Die nächsten bis zu 500 Einträge anzeigen.")
        conflictsOnly.setAccessibilityLabel("Nur Archivkonflikte anzeigen");conflictsOnly.toolTip = "Alle Namens- und Typkonflikte zeigen. Einzelentscheidungen bleiben beim Umschalten erhalten."
        policy.toolTip = "⌘1 Einzeln · ⌘2 Überspringen · ⌘3 Überschreiben · ⌘4 Nur ältere · ⌘5 Beide behalten. Eine Sammelregel setzt Einzelentscheidungen zurück."
        info.maximumNumberOfLines = 2;info.lineBreakMode = .byWordWrapping;safety.maximumNumberOfLines = 3;safety.lineBreakMode = .byWordWrapping
        safety.stringValue = packing ? "Die neue Archivdatei ersetzt kein vorhandenes Ziel.\nArchivaufträge gelten für diese Sitzung; Passwörter werden nicht gespeichert." : "Überschriebene Dateien bleiben unter „Wiederherstellung“ gesichert. Bei Abbruch werden unveränderte Schritte zurückgesetzt.\nArchivaufträge gelten für diese Sitzung; Passwörter werden nicht gespeichert."
        let scroll = operationScroll(table);root.addSubview(scroll)
        root.arrange = { [weak self] size in
            guard let self else { return };let width = size.width-44,h = size.height
            self.heading.frame = NSRect(x:22,y:h-50,width:width,height:32);self.sourceInfo.frame = NSRect(x:22,y:h-80,width:width,height:24)
            self.destinationCaption.frame = NSRect(x:22,y:h-117,width:118,height:24);self.destination.frame = NSRect(x:145,y:h-120,width:width-225,height:28);self.choose.frame = NSRect(x:size.width-116,y:h-121,width:94,height:30)
            options.frame = NSRect(x:22,y:h-165,width:width,height:28);self.selectedOnly.frame = NSRect(x:22,y:h-200,width:width,height:26)
            policies.frame = NSRect(x:22,y:h-235,width:width,height:28);self.optionsInfo.frame = NSRect(x:22,y:h-(self.packing ? 199 : 263),width:width,height:24)
            let toolbar = h-(self.packing ? 231 : 300)
            self.conflictsOnly.frame = NSRect(x:22,y:toolbar,width:130,height:26);self.previousConflict.frame = NSRect(x:158,y:toolbar,width:160,height:28);self.nextConflict.frame = NSRect(x:324,y:toolbar,width:155,height:28)
            self.pageInfo.frame = NSRect(x:size.width-355,y:toolbar+3,width:245,height:22);self.previousPage.frame = NSRect(x:size.width-102,y:toolbar,width:36,height:28);self.nextPage.frame = NSRect(x:size.width-60,y:toolbar,width:36,height:28)
            scroll.frame = NSRect(x:22,y:155,width:width,height:max(90,toolbar-163))
            self.info.frame = NSRect(x:22,y:109,width:width,height:41);self.safety.frame = NSRect(x:22,y:57,width:width,height:46)
            self.refresh.frame = NSRect(x:22,y:17,width:130,height:30);self.cancel.frame = NSRect(x:size.width-356,y:17,width:100,height:30);self.queue.frame = NSRect(x:size.width-248,y:17,width:110,height:30);self.start.frame = NSRect(x:size.width-130,y:17,width:108,height:30)
        };root.needsLayout = true
    }
    func configureArchiveKeys(_ w:WorkflowWindow) {
        w.workflowKeys = { [weak self,weak w] event in
            guard let self else { return false }
            if WorkflowKeys.matches(event,"\r",.command) { self.submit(true);return true }
            if WorkflowKeys.matches(event,"\r",[.command,.shift]) { self.submit(false);return true }
            if WorkflowKeys.matches(event,"l",.command) { w?.makeFirstResponder(self.destination);self.destination.selectText(nil);return true }
            if WorkflowKeys.matches(event,"l",[.command,.shift]) { self.chooseDestination();return true }
            if WorkflowKeys.matches(event,"r",.command) { self.prepare();return true }
            if !self.packing {
                for index in ArchiveConflictPolicy.allCases.indices where WorkflowKeys.matches(event,String(index+1),.command) { self.policy.selectItem(at:index);self.policyChanged();return true }
                if WorkflowKeys.matches(event,String(UnicodeScalar(NSDownArrowFunctionKey)!),[.command,.option]) { self.focusConflict(backward:false);return true }
                if WorkflowKeys.matches(event,String(UnicodeScalar(NSUpArrowFunctionKey)!),[.command,.option]) { self.focusConflict(backward:true);return true }
                if WorkflowKeys.matches(event,"d",.command) { self.openSelectedDecision();return true }
            }
            return false
        }
    }
}
