import Foundation
import Darwin

public enum LaunchSide: String, Equatable { case left, right }

public struct LaunchTarget: Equatable {
    public let directory: URL
    public let selection: URL?
    private let directoryVersion: RenameVersion
    private let selectionVersion: RenameVersion?

    private init(directory: URL, selection: URL?) throws {
        let normalized = FileSystem.canonical(directory)
        self.directory = normalized
        self.selection = selection.map { normalized.appendingPathComponent($0.lastPathComponent) }
        directoryVersion = try RenameVersion.read(self.directory)
        guard directoryVersion.isDirectory else { throw CommanderError.message("Startziel ist kein Ordner.") }
        selectionVersion = try self.selection.map(RenameVersion.read)
    }

    fileprivate static func resolve(_ text: String, relativeTo base: URL) throws -> LaunchTarget {
        let url = try path(text, relativeTo: base)
        let version = try RenameVersion.read(url)
        if version.isDirectory { return try LaunchTarget(directory: url, selection: nil) }
        guard version.isRegularFile || version.mode & S_IFMT == S_IFLNK else {
            throw CommanderError.message("Startziele müssen Ordner, Dateien oder Verknüpfungen sein.")
        }
        return try LaunchTarget(directory: url.deletingLastPathComponent(), selection: url)
    }

    fileprivate func selecting(_ text: String) throws -> LaunchTarget {
        let candidate = try Self.path(text, relativeTo: directory)
        guard FileSystem.canonical(candidate.deletingLastPathComponent()).path == directory.path else {
            throw CommanderError.message("Die Startmarkierung muss direkt im angegebenen Ordner liegen.")
        }
        return try LaunchTarget(directory: directory, selection: candidate)
    }

    fileprivate static func path(_ text: String, relativeTo base: URL) throws -> URL {
        guard !text.isEmpty, text.utf8.count <= 16_384, !text.contains("\0") else {
            throw CommanderError.message("Leerer oder zu langer Startpfad.")
        }
        if text.hasPrefix("file:") {
            guard let components = URLComponents(string: text), components.scheme == "file",
                  components.user == nil, components.password == nil, components.port == nil,
                  components.query == nil, components.fragment == nil,
                  components.host == nil || components.host == "" || components.host == "localhost",
                  let url = components.url, url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else {
                throw CommanderError.message("Nur lokale file://-Startadressen ohne Anmeldung oder Zusatzparameter verwenden.")
            }
            return url.standardizedFileURL
        }
        guard text.hasPrefix("/") || !text.contains("://"), !text.hasPrefix("~") || text == "~" || text.hasPrefix("~/") else {
            throw CommanderError.message("Ein lokaler Dateipfad wird benötigt; ~ steht nur für den eigenen Benutzerordner.")
        }
        if text == "~" { return FileManager.default.homeDirectoryForCurrentUser }
        if text.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(text.dropFirst(2))).standardizedFileURL
        }
        return (text.hasPrefix("/") ? URL(fileURLWithPath: text) : base.appendingPathComponent(text)).standardizedFileURL
    }

    public func validate() throws {
        guard try RenameVersion.read(directory).sameObject(directoryVersion),
              try selection.map({ try RenameVersion.read($0) == selectionVersion }) ?? true else {
            throw CommanderError.message("Ein Startziel wurde inzwischen ersetzt oder verändert. Startaufruf wiederholen.")
        }
    }
}

public struct LaunchRequest: Equatable {
    public let left: LaunchTarget?
    public let right: LaunchTarget?
    public let active: LaunchSide?
    public let newTabs: Bool
    public var isEmpty: Bool { left == nil && right == nil && active == nil && !newTabs }

    /// Parses arguments after argv[0]. It never opens a window or writes settings.
    public static func parse(_ arguments: [String], directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) throws -> LaunchRequest {
        guard arguments.count <= 32, arguments.reduce(0, { $0 + $1.utf8.count }) <= 65_536,
              arguments.allSatisfy({ !$0.contains("\0") }), directory.isFileURL else {
            throw CommanderError.message("Zu viele oder ungültige Startparameter.")
        }
        var options: [String: String] = [:], positional: [String] = [], newTabs = false, literals = false, i = 0
        let values: Set<String> = ["--left", "--right", "--select-left", "--select-right", "--active", "--import-settings", "--export-settings-profile"]
        while i < arguments.count {
            let value = arguments[i]
            if literals { positional.append(value) }
            else if value == "--" { literals = true }
            else if value == "--new-tabs" {
                guard !newTabs else { throw CommanderError.message("--new-tabs wurde mehrfach angegeben.") };newTabs = true
            } else if values.contains(value) {
                guard options[value] == nil, i + 1 < arguments.count, !arguments[i + 1].isEmpty,
                      !arguments[i + 1].hasPrefix("--") else {
                    throw CommanderError.message("Fehlender Wert oder mehrfacher Startparameter: " + value)
                }
                i += 1;options[value] = arguments[i]
            } else if value.range(of: "^-psn_[0-9]+_[0-9]+$", options: .regularExpression) != nil { }
            else if value.hasPrefix("-") { throw CommanderError.message("Unbekannter Startparameter: " + value) }
            else { positional.append(value) }
            i += 1
        }
        guard positional.count <= 2, options["--export-settings-profile"] == nil || options["--import-settings"] != nil else {
            throw CommanderError.message("Höchstens zwei Startpfade angeben; Profil-Export benötigt einen INI-Import.")
        }
        if !positional.isEmpty {
            guard options["--left"] == nil, positional.count < 2 || options["--right"] == nil else {
                throw CommanderError.message("Startpfade entweder als Position oder mit --left/--right angeben.")
            }
            options["--left"] = positional[0]
            if positional.count == 2 { options["--right"] = positional[1] }
        }
        var left = try options["--left"].map { try LaunchTarget.resolve($0, relativeTo: directory) }
        var right = try options["--right"].map { try LaunchTarget.resolve($0, relativeTo: directory) }
        for (key, target) in [("--select-left", left), ("--select-right", right)] where options[key] != nil {
            guard let target else { throw CommanderError.message(key + " benötigt einen Startpfad für diese Seite.") }
            let selected = try target.selecting(options[key]!)
            if key == "--select-left" { left = selected } else { right = selected }
        }
        let active = options["--active"].flatMap(LaunchSide.init(rawValue:))
        guard options["--active"] == nil || active != nil else { throw CommanderError.message("--active erwartet left oder right.") }
        guard !newTabs || left != nil || right != nil else { throw CommanderError.message("--new-tabs benötigt mindestens einen Startpfad.") }
        return LaunchRequest(left: left, right: right, active: active, newTabs: newTabs)
    }

    public func validate() throws { try left?.validate();try right?.validate() }

    public static let usage = """
    ZweiCommander [--left PFAD] [--right PFAD] [--select-left NAME] [--select-right NAME]
                  [--active left|right] [--new-tabs]
    ZweiCommander [PFAD-LINKS [PFAD-RECHTS]]

    Ordner werden auf der angegebenen Seite geöffnet. Dateien und Verknüpfungen
    werden in ihrem übergeordneten Ordner markiert. --select-left/--select-right
    markieren ein direkt enthaltenes Objekt. Relative Pfade, ~ und lokale file://-
    Adressen werden unterstützt. --new-tabs erhält die aktuellen Tabs; gesperrte
    und besondere Tabs bleiben auch ohne diese Option erhalten.

    --help          Diese Hilfe ohne App-Start anzeigen.
    --version       Die Programmversion ohne App-Start anzeigen.
    """
}
