import Foundation
import CryptoKit

public enum PaneDisplayMode: String, Codable, CaseIterable {
    case details, thumbnails, icons
    public var title: String {
        switch self { case .details: return "Details"; case .thumbnails: return "Vorschauliste"; case .icons: return "Symbole" }
    }
}

public struct ViewColumn: Codable, Equatable {
    public var id: String
    public var width: Double
    public var hidden: Bool
    public init(id: String, width: Double, hidden: Bool) { self.id = id;self.width = width;self.hidden = hidden }
}

public struct FolderViewSettings: Codable, Equatable {
    public static let columnIDs: Set<String> = ["name","ext","size","modified","kind","attributes","permissions","path"]
    public var display: PaneDisplayMode
    public var sortKey: String
    public var ascending: Bool
    public var foldersFirst: Bool
    public var treeVisible: Bool
    public var columns: [ViewColumn]?
    public init(display: PaneDisplayMode = .details, sortKey: String = "name", ascending: Bool = true, foldersFirst: Bool = true, treeVisible: Bool = false, columns: [ViewColumn]? = nil) {
        self.display = display;self.sortKey = sortKey;self.ascending = ascending;self.foldersFirst = foldersFirst;self.treeVisible = treeVisible;self.columns = columns
    }
    public func validate() throws {
        guard Self.columnIDs.contains(sortKey) else { throw CommanderError.message("Unbekannte Sortierspalte.") }
        if let columns {
            guard columns.count == Self.columnIDs.count,Set(columns.map(\.id)) == Self.columnIDs,
                  columns.allSatisfy({ $0.width.isFinite && (40...2000).contains($0.width) }),
                  columns.first(where: { $0.id == "name" })?.hidden == false else {
                throw CommanderError.message("Ungültige Spalten der Ordneransicht.")
            }
        }
    }
}

public struct FolderViewRule: Codable, Equatable, Identifiable {
    public var id: UUID
    public var path: String
    public var includeSubfolders: Bool
    public var settings: FolderViewSettings
    public init(id: UUID = UUID(), folder: URL, includeSubfolders: Bool, settings: FolderViewSettings) {
        self.id = id;path = folder.standardizedFileURL.path;self.includeSubfolders = includeSubfolders;self.settings = settings
    }
}

public enum FavoriteKind: String, Codable { case folder, application }
public struct WorkspaceFavorite: Codable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var path: String
    public var kind: FavoriteKind
    public var opensSelection: Bool
    public init(id: UUID = UUID(), title: String, url: URL, kind: FavoriteKind, opensSelection: Bool = false) {
        self.id = id;self.title = title;path = url.standardizedFileURL.path;self.kind = kind;self.opensSelection = opensSelection
    }
    public func validate() throws {
        try WorkspaceLibrary.validatePath(path)
        guard !title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.utf8.count <= 240,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              kind != .application || URL(fileURLWithPath:path).pathExtension.lowercased() == "app",
              kind == .application || !opensSelection else { throw CommanderError.message("Ungültiger Favorit. Name, Ziel und Programmoption prüfen.") }
    }
}

/// Local paths are kept in the user's settings, never in the application bundle.
public struct WorkspaceLibrary: Codable, Equatable {
    public private(set) var version = 1
    public var favorites: [WorkspaceFavorite] = []
    public var views: [FolderViewRule] = []
    public init() {}
    public init(legacyFolders: [String]) {
        var seen = Set<String>()
        favorites = legacyFolders.compactMap { path in
            guard (try? Self.validatePath(path)) != nil else { return nil }
            let url = URL(fileURLWithPath:path).standardizedFileURL
            guard seen.insert(url.path).inserted else { return nil }
            // Read-only migration must yield the same menu identities on every load.
            var bytes = Array(SHA256.hash(data:Data(url.path.utf8)).prefix(16));bytes[6] = (bytes[6]&0x0f)|0x80;bytes[8] = (bytes[8]&0x3f)|0x80
            let id = UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
            return WorkspaceFavorite(id:id,title:url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent,url:url,kind:.folder)
        }
    }
    static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"),path.utf8.count <= 16_384,!path.contains("\0"),URL(fileURLWithPath:path).standardizedFileURL.path == path else {
            throw CommanderError.message("Ein vollständiger, normalisierter Dateipfad wird benötigt.")
        }
    }
    public func validate() throws {
        guard version == 1 else { throw CommanderError.message("Diese Favoriten- und Ansichtsdatei benötigt eine neuere Programmversion.") }
        guard favorites.count <= 200,views.count <= 500,Set(favorites.map(\.id)).count == favorites.count,
              Set(views.map(\.id)).count == views.count,Set(views.map(\.path)).count == views.count else {
            throw CommanderError.message("Zu viele oder doppelte Einträge in den Arbeitsbereichseinstellungen.")
        }
        for favorite in favorites { try favorite.validate() }
        for rule in views { try Self.validatePath(rule.path);try rule.settings.validate() }
    }
    public static func decode(_ data: Data) throws -> WorkspaceLibrary {
        guard data.count <= 2_097_152 else { throw CommanderError.message("Die Arbeitsbereichseinstellungen sind zu groß.") }
        let value = try JSONDecoder().decode(Self.self,from:data);try value.validate();return value
    }
    public func encoded() throws -> Data {
        try validate();let data = try JSONEncoder().encode(self)
        guard data.count <= 2_097_152 else { throw CommanderError.message("Die Arbeitsbereichseinstellungen sind zu groß.") };return data
    }
    public func view(for folder: URL) -> FolderViewRule? {
        let path = folder.standardizedFileURL.path
        return views.filter { rule in
            path == rule.path || (rule.includeSubfolders && path.hasPrefix(rule.path == "/" ? "/" : rule.path+"/"))
        }.max { $0.path.count < $1.path.count }
    }
    public mutating func remember(_ settings: FolderViewSettings, folder: URL, includeSubfolders: Bool) throws {
        guard folder.isFileURL else { throw CommanderError.message("Ordneransichten benötigen lokale Dateipfade.") }
        var candidate = self
        let path = folder.standardizedFileURL.path
        let rule = FolderViewRule(id:views.first(where: { $0.path == path })?.id ?? UUID(),folder:folder,includeSubfolders:includeSubfolders,settings:settings)
        candidate.views.removeAll { $0.path == path };candidate.views.append(rule);try candidate.validate();self = candidate
    }
    public mutating func put(_ favorite: WorkspaceFavorite) throws {
        var candidate = self
        if let index = candidate.favorites.firstIndex(where: { $0.id == favorite.id }) { candidate.favorites[index] = favorite }
        else { candidate.favorites.append(favorite) }
        try candidate.validate();self = candidate
    }
    public mutating func moveFavorite(_ id: UUID, by offset: Int) {
        guard let old = favorites.firstIndex(where: { $0.id == id }) else { return }
        let target = old.addingReportingOverflow(offset);guard !target.overflow,favorites.indices.contains(target.partialValue) else { return }
        let item = favorites.remove(at:old);favorites.insert(item,at:target.partialValue)
    }
}

public struct ProgramLaunchRequest: Equatable {
    public let application: URL
    public let files: [URL]
    public init(favorite: WorkspaceFavorite, selection: [URL]) throws {
        try favorite.validate();guard favorite.kind == .application else { throw CommanderError.message("Ein Programmfavorit wird benötigt.") }
        guard !favorite.opensSelection || !selection.isEmpty else { throw CommanderError.message("Zuerst Dateien zum Öffnen auswählen.") }
        guard selection.allSatisfy({ $0.isFileURL && !$0.path.contains("\0") }) else { throw CommanderError.message("Nur lokale Dateipfade können übergeben werden.") }
        application = URL(fileURLWithPath:favorite.path);files = favorite.opensSelection ? selection : []
    }
}
