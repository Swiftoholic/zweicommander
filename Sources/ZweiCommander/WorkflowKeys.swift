import AppKit

enum WorkflowKeys {
    static func matches(_ event: NSEvent,_ key: String,_ modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard event.modifierFlags.intersection([.command,.shift,.option,.control]) == modifiers else { return false }
        let character = event.charactersIgnoringModifiers?.lowercased()
        if key == "\r",character == "\u{3}" { return true }
        if key == "\u{7f}",character == String(UnicodeScalar(NSDeleteFunctionKey)!) { return true }
        return character == key.lowercased()
    }
    static func bind(_ button: ActionButton,key: String,modifiers: NSEvent.ModifierFlags,title: String,detail: String) {
        button.keyEquivalent = key;button.keyEquivalentModifierMask = modifiers;button.setHelp(button.title,detail,shortcut:title)
    }
}

/// Secondary workspaces consume their own shortcuts and cannot operate an obscured file pane.
final class WorkflowWindow: NSWindow {
    var workflowKeys: ((NSEvent)->Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isKeyWindow,attachedSheet == nil,event.window == nil || event.window === self,workflowKeys?(event) == true { return true }
        return super.performKeyEquivalent(with:event)
    }
    func canPerformCommand(_ id: String) -> Bool {
        if ["operations","recovery","pauseTransfers","stopTransfers","help","settings"].contains(id) { return attachedSheet == nil }
        if id == "closeTab" { return attachedSheet == nil }
        if ["clipboardCopy","clipboardCut","clipboardPaste","undo","selectAll"].contains(id) { return (NSApp.keyWindow?.sheetParent === self ? NSApp.keyWindow?.firstResponder : firstResponder) is NSTextView }
        return false
    }
    func performEditingCommand(_ id: String) -> Bool {
        guard let editor = (NSApp.keyWindow?.sheetParent === self ? NSApp.keyWindow?.firstResponder : firstResponder) as? NSTextView else { return false }
        switch id {
        case "clipboardCopy":editor.copy(nil)
        case "clipboardCut":editor.cut(nil)
        case "clipboardPaste":editor.paste(nil)
        case "undo":editor.undoManager?.undo()
        case "selectAll":editor.selectAll(nil)
        default:return false
        }
        return true
    }
}

extension MainWindow {
    var keyWorkflowWindow: WorkflowWindow? {
        if let workflow = NSApp.keyWindow as? WorkflowWindow { return workflow }
        return NSApp.keyWindow?.sheetParent as? WorkflowWindow
    }
}

extension TransferSetupController {
    func configureTransferKeys() {
        (window as? WorkflowWindow)?.workflowKeys = { [weak self] in self?.handleTransferKey($0) ?? false }
        WorkflowKeys.bind(queueButton,key:"\r",modifiers:[.command,.shift],title:"⌘⇧↩",detail:"Geprüften Dateiplan in die Warteschlange aufnehmen.")
        startButton.setHelp(startButton.title,"Geprüften Dateiplan starten.",shortcut:"↩ / ⌘↩")
        refreshButton.setHelp("Neu prüfen","Quellen und Ziel erneut prüfen.",shortcut:"⌘R")
        optionsButton.setHelp("Weitere Optionen","Profile, Dateifilter und Ordnerregeln ein- oder ausblenden.",shortcut:"⌘⌥O")
        include.toolTip = (include.toolTip ?? "")+"\n⌘⌥F öffnet die Optionen und fokussiert diesen Filter."
        destination.toolTip = "Zielordner · ⌘L";destinationChoose.setHelp("Ziel wählen","Zielordner auswählen.",shortcut:"⌘⇧L")
        selectionButton.setHelp("Auswahl","Auswahlobjekte prüfen.",shortcut:"⌘1");objectsButton.setHelp("Geplante Objekte","Alle geplanten Dateien und Konflikte prüfen.",shortcut:"⌘2")
    }
    func handleTransferKey(_ event: NSEvent) -> Bool {
        if WorkflowKeys.matches(event,"\r",.command) { requestKeyboardSubmit(true);return true }
        if WorkflowKeys.matches(event,"\r",[.command,.shift]) { requestKeyboardSubmit(false);return true }
        if WorkflowKeys.matches(event,"l",.command) { window?.makeFirstResponder(destination);destination.selectText(nil);return true }
        if WorkflowKeys.matches(event,"l",[.command,.shift]) { chooseDestination();return true }
        if WorkflowKeys.matches(event,"r",.command) { prepare();return true }
        if WorkflowKeys.matches(event,"o",[.command,.option]) { toggleOptions();return true }
        if WorkflowKeys.matches(event,"f",[.command,.option]) { if !optionsExpanded { toggleOptions() };window?.makeFirstResponder(include);include.selectText(nil);return true }
        for (key,index) in [("1",0),("2",1)] where WorkflowKeys.matches(event,key,.command) {
            tabs.selectTabViewItem(at:index);updateTabButtons();window?.makeFirstResponder(index == 0 ? table : filesTable);return true
        }
        return false
    }
}

extension OperationQueueController {
    func configureQueueKeys() {
        (window as? WorkflowWindow)?.workflowKeys = { [weak self] in self?.handleQueueKey($0) ?? false }
        (table as? CommanderTableView)?.workflowKeys = { [weak self] in self?.handleQueueKey($0) ?? false }
        refreshQueueShortcutHelp()
        review.setHelp("Erneut prüfen","Ausgewählten gespeicherten Auftrag vor einem erneuten Start prüfen.",shortcut:"⌘R / ↩")
        start.setHelp("Starten / als Nächstes","Ausgewählten wartenden Auftrag als Nächstes starten.",shortcut:"↩")
        up.setHelp("Nach oben","Wartenden Auftrag nach oben verschieben.",shortcut:"⌥↑");down.setHelp("Nach unten","Wartenden Auftrag nach unten verschieben.",shortcut:"⌥↓")
        remove.setHelp("Entfernen","Nur den ausgewählten wartenden Auftrag entfernen; keine Dateien löschen.",shortcut:"⌫")
        table.doubleAction = #selector(activateSelected);table.target = self
    }
    @objc func activateSelected() { if review.isEnabled { review.perform?() } else if start.isEnabled { start.perform?() } }
    func refreshQueueShortcutHelp() {
        let signature = ["recovery","pauseTransfers","stopTransfers"].map(CommandHelp.shortcut).joined(separator:";")
        guard signature != shortcutHelpSignature else { return };shortcutHelpSignature = signature
        recoveryButton.setHelp("Sicherungen / Teilkopien","Wiederherstellbare Sicherungen und Teilkopien verwalten.",shortcut:CommandHelp.shortcut("recovery"))
        pause.setHelp("Pause / Fortsetzen","Laufende Übertragung und nachfolgende Aufträge pausieren oder fortsetzen.",shortcut:"Leertaste / "+CommandHelp.shortcut("pauseTransfers"))
        cancel.setHelp("Abbrechen","Laufenden Auftrag abbrechen; fertige Schritte bleiben erhalten.",shortcut:CommandHelp.shortcut("stopTransfers"))
    }
    func handleQueueKey(_ event: NSEvent) -> Bool {
        guard !(window?.firstResponder is NSTextView) else { return false }
        if WorkflowKeys.matches(event," ") { if pause.isEnabled { pause.perform?() };return true }
        if WorkflowKeys.matches(event,"\r") { activateSelected();return true }
        if WorkflowKeys.matches(event,"r",.command) { if review.isEnabled { review.perform?() };return true }
        if WorkflowKeys.matches(event,String(UnicodeScalar(NSUpArrowFunctionKey)!),.option) { if up.isEnabled { up.perform?() };return true }
        if WorkflowKeys.matches(event,String(UnicodeScalar(NSDownArrowFunctionKey)!),.option) { if down.isEnabled { down.perform?() };return true }
        if WorkflowKeys.matches(event,"\u{7f}") { if remove.isEnabled { remove.perform?() };return true }
        return false
    }
}
