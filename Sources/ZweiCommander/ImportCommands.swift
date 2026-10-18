import AppKit
import CommanderCore

extension MainWindow {
    func applySettingsProfile(_ profile: SettingsProfile) {
        Preferences.apply(profile)
        left.showHidden = profile.showHidden; right.showHidden = profile.showHidden
        left.configure(profile:profile,isLeft:true); right.configure(profile:profile,isLeft:false)
        for pane in [left,right] { pane.defaultView = pane.viewSettings;pane.tab.view = pane.viewSettings;pane.restoreTabView() }
        content.split.isVertical = profile.verticalPanels; content.firstLayout = true; content.needsLayout = true
        applyTheme(); updateFunctionLabels(); onRebuildMenus?(); refresh()
        content.status.stringValue = "INI-Einstellungen übernommen · "+profile.colorScheme
    }
    func importSettings() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.message = "INI-Hauptdatei oder Settings-Ordner auswählen. Favoriten- und Laufwerkspfade werden ausgelassen."
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do {
            let profile = try INISettingsImport.load(directory:url)
            guard dialog("INI-Einstellungen übernehmen",message:"Anzeige, Spalten, Bedienung und unterstützte Vorgaben werden übernommen. Die bisherigen ZweiCommander-Einstellungen werden zur Wiederherstellung gespeichert.",accessory:reportView(importReport(profile)),buttons:["Übernehmen","Abbrechen"]) == 0 else { return }
            applySettingsProfile(profile)
        } catch { showFailure(error) }
    }
    func importReport(_ profile: SettingsProfile) -> String {
        var lines = ["EINSTELLUNGSIMPORT", "Farbschema: "+profile.colorScheme, "Versteckte Dateien: \(profile.showHidden ? "sichtbar" : "ausgeblendet")", "Spalten: "+profile.columns.map(\.title).joined(separator:", "), "Schrift: \(profile.fontName), nativ \(Int(profile.fontSize)) pt (Systemschrift als Ersatz)", "Inhaltssuche in Office-Dateien: \(profile.officeContentSearch ? "aktiviert" : "deaktiviert")", "Zählerstellen beim Umbenennen: \(profile.renameCounterDigits)", "Archivvorgabe: .\(profile.defaultArchiveExtension)", "", "BEDIENUNG"]
        lines += profile.shortcuts.sorted { $0.key < $1.key }.map { $0.key+" = "+$0.value }
        lines += ["", "PLUG-IN-FUNKTIONEN"]
        for plugin in profile.plugins {
            let status: String
            switch plugin.name.lowercased() {
            case "fileinfo": status = "Native PE-/Mach-O-Köpfe und PE-Versionsinformationen; keine vollständige Symbol-/Ressourcenoberfläche"
            case "ulister": status = "Quick Look für die visuelle Vorschau; Office-XML-Textauszug; weitere Oracle-Formate abhängig von macOS-Vorschauanbietern"
            case "total7zip", "fc7zip": status = "Native 7z-Erstellung/-Extraktion; keine Archivverschlüsselung beim Erstellen"
            case "fczip": status = "ZIP-Erstellung/-Extraktion, einschließlich JAR/WAR/EAR-Container"
            case "fcrar": status = "RAR-Lesen über macOS-libarchive; Formatvarianten nicht alle geprüft"
            default: status = "Konfigurationsnachweis; Windows-Binärdatei wird nicht geladen"
            }
            lines.append("\(plugin.enabled ? "AKTIV" : "INAKTIV") · \(plugin.name): \(status)")
        }
        lines += ["", "HINWEISE"]+profile.notes
        lines += ["", "Quellkonfiguration SHA-256: "+profile.sourceSHA256]
        return lines.joined(separator:"\n")
    }
    func restoreBeforeSettingsImport() {
        guard pendingWork == 0 else { return }
        guard Preferences.restoreBeforeImport() else { _ = dialog("Keine gespeicherten Einstellungen vor dem Import vorhanden",buttons:["OK"]); return }
        for pane in [left,right] {
            pane.restoreConfigurationBeforeImport()
            pane.showHidden = Preferences.state.showHidden
            pane.defaultView = pane.viewSettings;pane.tab.view = pane.viewSettings;pane.restoreTabView()
        }
        content.split.isVertical = Preferences.state.vertical; content.firstLayout = true; content.needsLayout = true
        applyTheme(); updateFunctionLabels(); onRebuildMenus?(); refresh()
    }
}
