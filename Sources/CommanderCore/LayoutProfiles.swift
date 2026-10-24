import Foundation

public enum TabLockMode:String,Codable,CaseIterable {
    case none,closeOnly,fixed,newTab
    public var title:String {
        switch self { case .none:return "Keine Sperre";case .closeOnly:return "Nur Schließen verhindern";case .fixed:return "Ordner festhalten";case .newTab:return "Ordnerwechsel in neuem Tab" }
    }
    public var preventsClosing:Bool { self != .none }
}

public enum WorkspaceSide:String,Codable { case left,right }
public enum WorkspacePresentation:String,Codable,CaseIterable { case both,left,right }

public struct WorkspaceFrame:Codable,Equatable {
    public var x:Double,y:Double,width:Double,height:Double
    public init(x:Double,y:Double,width:Double,height:Double) { self.x = x;self.y = y;self.width = width;self.height = height }
    public func validate() throws {
        guard [x,y,width,height].allSatisfy(\.isFinite),abs(x) <= 100_000,abs(y) <= 100_000,(400...16_384).contains(width),(300...16_384).contains(height) else { throw CommanderError.message("Die gespeicherte Fensterposition oder Fenstergröße ist ungültig.") }
    }
    /// Screens use native desktop coordinates; an unplugged screen cannot hide the restored window.
    public func fitted(to screens:[WorkspaceFrame],minimumWidth:Double = 900,minimumHeight:Double = 520) -> Self {
        let usable = screens.filter { [$0.x,$0.y,$0.width,$0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0 }
        guard let first = usable.first else { return self }
        func intersection(_ screen:Self) -> Double { max(0,min(x+width,screen.x+screen.width)-max(x,screen.x))*max(0,min(y+height,screen.y+screen.height)-max(y,screen.y)) }
        let screen = usable.dropFirst().reduce(first) { intersection($1) > intersection($0) ? $1 : $0 }
        let w = min(max(width,minimumWidth),screen.width),h = min(max(height,minimumHeight),screen.height)
        return Self(x:max(screen.x,min(x,screen.x+screen.width-w)),y:max(screen.y,min(y,screen.y+screen.height-h)),width:w,height:h)
    }
}

public struct WorkspaceLayout:Codable,Equatable {
    public var schemaVersion = 1
    public var vertical = true
    public var ratio:Double = 0.5
    public var presentation:WorkspacePresentation = .both
    public var active:WorkspaceSide = .left
    public var quickVisible = false
    public var linked = false
    public var frame:WorkspaceFrame?
    public init() {}
    public func validate() throws {
        guard schemaVersion == 1 else { throw CommanderError.message("Diese Layoutversion wird nicht unterstützt. Vorhandene Daten bleiben erhalten.") }
        guard ratio.isFinite,(0.1...0.9).contains(ratio),presentation != .left || active == .left,presentation != .right || active == .right else { throw CommanderError.message("Ungültige Fensterteilung oder unsichtbare aktive Seite.") }
        try frame?.validate()
    }
    public func encoded() throws -> Data { try validate();return try JSONEncoder().encode(self) }
    public static func decode(_ data:Data) throws -> Self {
        guard data.count <= 16_384 else { throw CommanderError.message("Die gespeicherte Anordnung ist zu groß.") }
        let value = try JSONDecoder().decode(Self.self,from:data);try value.validate();return value
    }
}

public struct LayoutTab:Codable,Equatable {
    public var path:String,title:String?,lockMode:TabLockMode,view:FolderViewSettings,filter:String,filterRegex:Bool
    public init(path:String,title:String? = nil,lockMode:TabLockMode = .none,view:FolderViewSettings = .init(),filter:String = "",filterRegex:Bool = false) {
        self.path = path;self.title = title;self.lockMode = lockMode;self.view = view;self.filter = filter;self.filterRegex = filterRegex
    }
    public static func validatePath(_ path:String) throws {
        guard path.hasPrefix("/"),path.utf8.count <= 16_384,!path.contains("\0") else { throw CommanderError.message("Arbeitsbereiche benötigen vollständige lokale Ordnerpfade bis 16.384 UTF-8-Bytes.") }
        if path != "/" {
            guard path.split(separator:"/",omittingEmptySubsequences:false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CommanderError.message("Ordnerpfade müssen normalisiert sein.") }
        }
    }
    public func validate() throws {
        try Self.validatePath(path);try view.validate()
        if let title { guard title.utf8.count <= 240,!title.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw CommanderError.message("Tabnamen dürfen höchstens 240 UTF-8-Bytes und keine Steuerzeichen enthalten.") } }
        guard filter.utf8.count <= 4096,!filter.contains("\0") else { throw CommanderError.message("Der gespeicherte Filter ist zu lang oder enthält ein Nullzeichen.") }
        _ = try NameFilter(filter,regex:filterRegex)
    }
}

public struct LayoutPane:Codable,Equatable {
    public var tabs:[LayoutTab],selected:Int
    public init(tabs:[LayoutTab],selected:Int = 0) { self.tabs = tabs;self.selected = selected }
    public func validate() throws {
        guard (1...100).contains(tabs.count),tabs.indices.contains(selected) else { throw CommanderError.message("Jede Seite benötigt 1 bis 100 lokale Ordnertabs und einen gültigen aktiven Tab.") }
        try tabs.forEach { try $0.validate() }
    }
}

public struct LayoutProfile:Codable,Equatable,Identifiable {
    public var id:UUID,name:String,left:LayoutPane,right:LayoutPane,layout:WorkspaceLayout
    public init(id:UUID = UUID(),name:String,left:LayoutPane,right:LayoutPane,layout:WorkspaceLayout = .init()) { self.id = id;self.name = name;self.left = left;self.right = right;self.layout = layout }
    public func validate() throws { try left.validate();try right.validate();try layout.validate() }
}

public struct LayoutLibrary:Codable,Equatable {
    public static let maximumBytes = 4*1024*1024
    public private(set) var schemaVersion = 1
    public var profiles:[LayoutProfile] = []
    public init() {}
    private struct Document:Codable { let schemaVersion:Int,profiles:[LayoutProfile] }
    public init(from decoder:Decoder) throws { let document = try Document(from:decoder);schemaVersion = document.schemaVersion;profiles = document.profiles;try validate() }
    public func encode(to encoder:Encoder) throws { try validate();try Document(schemaVersion:schemaVersion,profiles:profiles).encode(to:encoder) }
    static func cleanName(_ name:String) throws -> String {
        guard !name.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else { throw CommanderError.message("Der Arbeitsbereichsname darf keine Steuerzeichen enthalten.") }
        let value = name.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !value.isEmpty,value.utf8.count <= 240 else { throw CommanderError.message("Arbeitsbereichsname: 1 bis 240 UTF-8-Bytes.") };return value
    }
    public func validate() throws { _ = try validatedData() }
    private func validatedData() throws -> Data {
        guard schemaVersion == 1 else { throw CommanderError.message("Diese Version der Arbeitsbereiche wird nicht unterstützt. Vorhandene Daten bleiben erhalten.") }
        guard profiles.count <= 50 else { throw CommanderError.message("Höchstens 50 Arbeitsbereiche speichern.") }
        var ids = Set<UUID>(),names = Set<String>(),payload = 0
        for profile in profiles {
            let name = try Self.cleanName(profile.name),key = name.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX")).precomposedStringWithCanonicalMapping
            guard name.utf8.elementsEqual(profile.name.utf8),ids.insert(profile.id).inserted,names.insert(key).inserted else { throw CommanderError.message("Arbeitsbereiche benötigen eindeutige bereinigte Namen und Kennungen.") }
            try profile.validate();payload += name.utf8.count
            for tab in profile.left.tabs+profile.right.tabs { payload += tab.path.utf8.count+(tab.title?.utf8.count ?? 0)+tab.filter.utf8.count }
            guard payload <= Self.maximumBytes else { throw CommanderError.message("Die Arbeitsbereichsdatei ist größer als 4 MiB.") }
        }
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys,.prettyPrinted]
        let data = try encoder.encode(Document(schemaVersion:schemaVersion,profiles:profiles))
        guard data.count <= Self.maximumBytes else { throw CommanderError.message("Die Arbeitsbereichsdatei ist größer als 4 MiB.") };return data
    }
    public func encoded() throws -> Data { try validatedData() }
    public static func decode(_ data:Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CommanderError.message("Die Arbeitsbereichsdatei ist größer als 4 MiB.") };return try JSONDecoder().decode(Self.self,from:data)
    }
    public mutating func put(_ profile:LayoutProfile) throws {
        var value = profile;value.name = try Self.cleanName(value.name);var next = self
        if let index = next.profiles.firstIndex(where:{ $0.id == value.id }) { next.profiles[index] = value } else { next.profiles.append(value) }
        try next.validate();self = next
    }
    public mutating func move(_ id:UUID,by offset:Int) throws {
        try validate();guard let old = profiles.firstIndex(where:{ $0.id == id }) else { throw CommanderError.message("Der Arbeitsbereich wurde inzwischen entfernt.") }
        let target = old.addingReportingOverflow(offset);guard !target.overflow,profiles.indices.contains(target.partialValue),old != target.partialValue else { return }
        var next = self;let value = next.profiles.remove(at:old);next.profiles.insert(value,at:target.partialValue);try next.validate();self = next
    }
}
