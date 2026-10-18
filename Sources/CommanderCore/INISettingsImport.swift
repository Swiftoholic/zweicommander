import Foundation
import CryptoKit

/// Reads data only. Windows paths, commands, plug-ins and account files are never executed.
public struct INIDocument {
    public private(set) var sections: [String: [String: String]] = [:]
    public init(data: Data) throws {
        guard data.count <= 4 * 1024 * 1024 else { throw CommanderError.message("INI-Datei ist größer als 4 MB.") }
        let text: String?
        if data.starts(with: [0xff, 0xfe]) { text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xfe, 0xff]) { text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) }
        guard let text else { throw CommanderError.message("Unbekannte INI-Zeichenkodierung.") }
        var current = ""
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{feff}")))
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                if sections[current] == nil { sections[current] = [:] }
            } else if let equals = line.firstIndex(of: "=") {
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                sections[current, default: [:]][key] = value
            }
        }
    }
    public subscript(_ section: String, _ key: String) -> String? { sections[section.lowercased()]?[key.lowercased()] }
    public func integer(_ section: String, _ key: String, fallback: Int = 0) -> Int { self[section, key].flatMap(Int.init) ?? fallback }
    public func flag(_ section: String, _ key: String, fallback: Bool = false) -> Bool {
        guard let value = self[section, key] else { return fallback }
        return ["1", "-1", "true", "yes"].contains(value.lowercased())
    }
}

public struct ImportedRGB: Codable, Equatable {
    public let red: Double, green: Double, blue: Double
    public init?(windowsColor: Int) {
        guard windowsColor >= 0 && windowsColor <= 0xffffff else { return nil }
        red = Double(windowsColor & 255) / 255
        green = Double((windowsColor >> 8) & 255) / 255
        blue = Double((windowsColor >> 16) & 255) / 255
    }
    public var hex: String { String(format: "#%02X%02X%02X", Int((red*255).rounded()), Int((green*255).rounded()), Int((blue*255).rounded())) }
}
public struct ImportedColumn: Codable, Equatable {
    public let id: String, title: String
    public let characterWidth: Int
}
public struct ImportedFileColor: Codable, Equatable {
    public let patterns: [String]
    public let color: ImportedRGB
    public func matches(_ name: String) -> Bool { patterns.contains { (try? NameFilter($0).matches(name)) == true } }
}
public struct ImportedPlugin: Codable, Equatable {
    public let name: String, category: String
    public let enabled: Bool
    public let extensions: [String]
}
public struct ImportedSort: Codable, Equatable {
    public var key: String
    public var ascending: Bool
}
public struct SettingsProfile: Codable, Equatable {
    public let schemaVersion: Int
    public let sourceSHA256: String
    public let colorScheme: String
    public let darkAppearance: Bool
    public let showHidden: Bool
    public let verticalPanels: Bool
    public let foldersFirst: Bool
    public let leftTree: Bool, rightTree: Bool
    public let leftSort: ImportedSort, rightSort: ImportedSort
    public let fontName: String
    public let fontSize: Double
    public let background: ImportedRGB?, inactiveBackground: ImportedRGB?, foreground: ImportedRGB?
    public let columns: [ImportedColumn]
    public let fileColors: [ImportedFileColor]
    public let shortcuts: [String: String]
    public let viewerShortcuts: [String: String]
    public let plugins: [ImportedPlugin]
    public let officeContentSearch: Bool
    public let renameCounterDigits: Int
    public let zipCompressionLevel: Int
    public let sevenZipCompressionLevel: Int
    public let defaultArchiveExtension: String
    public let notes: [String]
}

public enum INISettingsImport {
    private static let contentColumns = [0: "name", 6: "size", 7: "attributes", 8: "kind", 9: "modified", 2: "path"]
    public static func nativeShortcut(_ text: String) -> String? {
        let raw = text.trimmingCharacters(in: .whitespaces)
        if raw == "-1" || raw.isEmpty { return nil }
        let parts = raw.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last else { return nil }
        var modifiers: [String] = []
        for part in parts.dropLast() {
            switch part { case "ctrl": modifiers.append("cmd"); case "alt": modifiers.append("option"); case "shift": modifiers.append("shift"); default: return nil }
        }
        let special = ["space": "space", "del": "delete", "esc": "escape", "enter": "return", "left": "left", "right": "right", "up": "up", "down": "down"]
        let key: String
        if let translated = special[last] { key = translated }
        else if last.count == 1 { key = last }
        else if last.hasPrefix("f"), let n = Int(last.dropFirst()), (1...20).contains(n) { key = "f\(n)" }
        else { return nil }
        return (modifiers+[key]).joined(separator: "+")
    }
    public static func load(directory: URL) throws -> SettingsProfile {
        let root = directory.pathExtension.lowercased() == "ini" ? directory.deletingLastPathComponent() : directory
        let mainURL: URL
        if directory.pathExtension.lowercased() == "ini" { mainURL = directory }
        else {
            let candidates = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).filter {
                $0.pathExtension.lowercased() == "ini" && !$0.deletingPathExtension().lastPathComponent.contains(".")
            }
            guard candidates.count == 1,let candidate = candidates.first else { throw CommanderError.message("Bitte die Hauptdatei mit der Endung .ini auswählen.") }
            mainURL = candidate
        }
        let basename = mainURL.deletingPathExtension().lastPathComponent
        func read(_ url: URL) throws -> Data {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let data = try handle.read(upToCount: 4*1024*1024+1) ?? Data()
            guard data.count <= 4*1024*1024 else { throw CommanderError.message("INI-Datei ist größer als 4 MB.") }
            return data
        }
        let main = try read(mainURL)
        func optional(_ name: String) throws -> Data? {
            let path = root.appendingPathComponent(name)
            return FileSystem.exists(path) ? try read(path) : nil
        }
        return try parse(main: main, shortcuts: optional(basename+".shc"), search: optional(basename+".find.ini"), rename: optional(basename+".mren.ini"), packer: optional(basename+".wcx.ini"))
    }
    public static func parse(main: Data, shortcuts: Data? = nil, search: Data? = nil, rename: Data? = nil, packer: Data? = nil) throws -> SettingsProfile {
        let ini = try INIDocument(data: main)
        guard ini.sections["form"] != nil || ini.sections["mainpanel"] != nil else { throw CommanderError.message("Das Format dieser INI-Konfiguration wird nicht unterstützt.") }
        let shortcutINI = try shortcuts.map(INIDocument.init(data:))
        let searchINI = try search.map(INIDocument.init(data:))
        let renameINI = try rename.map(INIDocument.init(data:))
        let packerINI = try packer.map(INIDocument.init(data:))
        var fingerprint = SHA256(); fingerprint.update(data: main)
        for input in [shortcuts, search, rename, packer] { if let input { fingerprint.update(data: Data([0])); fingerprint.update(data: input) } }
        let profileSection = "FcDetailedViews_"+(ini["MainPanel", "LeftDetailsProfile"] ?? "fc_default_view")
        var columns: [ImportedColumn] = [], unknown: [String] = []
        for index in 1...64 {
            guard let name = ini[profileSection, "\(index)col_Name"] else { continue }
            let content = ini.integer(profileSection, "\(index)col_Content", fallback: -1)
            guard let id = contentColumns[content], ini.integer(profileSection, "\(index)col_ContentType") == 0 else { unknown.append(name); continue }
            if columns.contains(where: { $0.id == id }) { continue }
            columns.append(ImportedColumn(id: id, title: String(name.prefix(100)), characterWidth: max(4, min(200, ini.integer(profileSection, "\(index)col_Width", fallback: 20)))))
        }
        if !columns.contains(where: { $0.id == "name" }) { columns.insert(ImportedColumn(id: "name", title: "Name", characterWidth: 40), at: 0) }
        func sort(_ key: String) -> ImportedSort {
            let values = (ini["MainPanel", key] ?? "0,0,-1,0").split(separator: ",").compactMap { Int($0) }
            return ImportedSort(key: values.count > 1 ? contentColumns[values[1]] ?? "name" : "name", ascending: values.count > 2 ? values[2] != 0 : true)
        }
        func color(_ key: String) -> ImportedRGB? { ini["Form", key].flatMap(Int.init).flatMap(ImportedRGB.init(windowsColor:)) }
        var colors: [ImportedFileColor] = []
        for (_, raw) in (ini.sections["itemcolorsbyfiletype"] ?? [:]).sorted(by: { $0.key < $1.key }) {
            let pair = raw.split(separator: "|", maxSplits: 1)
            if pair.count == 2, let code = Int(pair[1]), let rgb = ImportedRGB(windowsColor: code) {
                colors.append(ImportedFileColor(patterns: pair[0].split(separator: ";").map(String.init), color: rgb))
            }
        }
        let mainActions = ["actFileView": "preview", "actViewTabNewFileCart": "newCollection", "actViewTabFileCartRemoveItem": "removeCollectionItem", "actFileCopy": "copy", "actFileMove": "move", "actFileRename": "rename", "actFileDelete": "trash", "actFileMultiRename": "batchRename"]
        let viewerActions = ["actViewModeText": "text", "actViewModeTextHex": "hex", "actViewModeBinText": "binary", "actViewModeImages": "preview", "actViewModeImageMultimedia": "multimedia", "actFileClose": "close", "actFileProperties": "metadata", "actFileReload": "reload"]
        var nativeKeys: [String: String] = [:], viewerKeys: [String: String] = [:]
        for (windows, native) in mainActions { if let raw = shortcutINI?["ShortCuts", windows], let key = nativeShortcut(raw) { nativeKeys[native] = key } }
        for (windows, native) in viewerActions { if let raw = shortcutINI?["TfcViewerForm_ShortCuts", windows], let key = nativeShortcut(raw) { viewerKeys[native] = key } }
        let pluginSection = ini.sections["tfcviewerform_plugins64"] != nil ? "TfcViewerForm_Plugins64" : "TfcViewerForm_Plugins"
        var plugins: [ImportedPlugin] = []
        let regex = try NSRegularExpression(pattern: "(?i)EXT\\s*=\\s*\"([^\"]+)\"")
        for index in 1...64 {
            guard let path = ini[pluginSection, String(index)] else { continue }
            let basename = path.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? path
            let name = (basename as NSString).deletingPathExtension
            let detect = ini[pluginSection, "\(index)_detect"] ?? ""
            let extensions = regex.matches(in: detect, range: NSRange(detect.startIndex..., in: detect)).compactMap { Range($0.range(at: 1), in: detect).map { String(detect[$0]).lowercased() } }
            plugins.append(ImportedPlugin(name: name, category: "Viewer", enabled: ini.flag(pluginSection, "\(index)_enabled", fallback: true), extensions: Array(Set(extensions)).sorted()))
        }
        for index in 1...64 {
            guard let title = ini["PackerPlugins", "Title\(index)"] else { continue }
            let file = ini["PackerPlugins", "File\(index)"] ?? ""
            plugins.append(ImportedPlugin(name: title, category: "Archiv", enabled: file.split(separator: ",").first != "0", extensions: (ini["PackerPlugins", "Ext\(index)"] ?? "").split(separator: ".").map(String.init)))
        }
        let background = color("FileListColorBkg")
        let dark = background.map { ($0.red+$0.green+$0.blue)/3 < 0.5 } ?? false
        var notes = ["Favoriten und Laufwerkszuordnungen werden nicht importiert.", "Windows-Programme, DLLs und Plug-ins werden nicht ausgeführt.", "FTP-/Cloud-Konten und Zugangsdaten gehören nicht zum Einstellungsimport.", "Spaltenbreiten werden aus Zeichenbreiten auf die macOS-Schrift umgerechnet.", "Die Spalte Attribute zeigt macOS-Eigenschaften statt Windows-Attributbits."]
        if !unknown.isEmpty { notes.append("Nicht übertragbare Spalten: "+unknown.joined(separator: ", ")) }
        let lastPacker = ini["dlgFcCopyMoveOperation_Pack", "PackLastPacker"] ?? ""
        return SettingsProfile(schemaVersion: 1, sourceSHA256: fingerprint.finalize().map { String(format: "%02x", $0) }.joined(), colorScheme: ini["Form", "ColorSchema"] ?? "", darkAppearance: dark, showHidden: ini.flag("Form", "ShowHiddenFile"), verticalPanels: ini.integer("MainPanel", "MainSplitterOrient") == 0, foldersFirst: !ini.flag("Form", "SortDirLikeFiles") && !ini.flag("Form", "SortDirAlwaysOnEnd"), leftTree: ini.flag("MainPanel", "LeftShowTree"), rightTree: ini.flag("MainPanel", "RightShowTree"), leftSort: sort("LeftSortColumn"), rightSort: sort("RightSortColumn"), fontName: ini["Form", "FileListFont_Name"] ?? "", fontSize: max(11, min(24, Double(ini["Form", "FileListFont_Size"] ?? "9").map { $0*4/3 } ?? 12)), background: background, inactiveBackground: color("FileListColorBkgInactiv"), foreground: color("FileListFont_Color"), columns: columns, fileColors: colors, shortcuts: nativeKeys, viewerShortcuts: viewerKeys, plugins: plugins, officeContentSearch: searchINI?.flag("TfcSearchFrame", "SearchOfficeXml") ?? false, renameCounterDigits: max(1, min(10, renameINI?.integer("fcFormMultiRename", "CounterDigits", fallback: 3) ?? 3)), zipCompressionLevel: max(0, min(9, packerINI?.integer("fc_internal_zip", "fcZipCompressionMode", fallback: 6) ?? 6)), sevenZipCompressionLevel: max(0, min(9, packerINI?.integer("fc_internal_7zip", "fc7ZipCompressionLevel", fallback: 6) ?? 6)), defaultArchiveExtension: lastPacker.lowercased().contains("7z") ? "7z" : "zip", notes: notes)
    }
}
