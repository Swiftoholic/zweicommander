import Foundation
import Darwin
import CryptoKit

public struct AttributeTimestamp: Equatable, Codable {
    public let seconds: Int64
    public let nanoseconds: Int32
    public var date: Date { Date(timeIntervalSince1970:Double(seconds)+Double(nanoseconds)/1e9) }
    public init(seconds:Int64,nanoseconds:Int32 = 0) throws {
        guard (-2_082_844_800...253_402_300_799).contains(seconds),(0..<1_000_000_000).contains(nanoseconds) else { throw attributeError("Zeitpunkt liegt außerhalb von 1904 bis 9999.") }
        self.seconds = seconds;self.nanoseconds = nanoseconds
    }
    init(_ value:timespec) { seconds = Int64(value.tv_sec);nanoseconds = Int32(value.tv_nsec) }
    var native:timespec { timespec(tv_sec:Int(seconds),tv_nsec:Int(nanoseconds)) }
    func shifted(_ amount:Int64) throws -> Self { let result = seconds.addingReportingOverflow(amount);guard !result.overflow else { throw attributeError("Zeitverschiebung ist zu groß.") };return try Self(seconds:result.partialValue,nanoseconds:nanoseconds) }
    public static func parse(_ text:String,timeZone:TimeZone) throws -> Self {
        let value = text.trimmingCharacters(in:.whitespacesAndNewlines)
        let expression = try NSRegularExpression(pattern:"\\A([0-9]{4})-([0-9]{2})-([0-9]{2}) ([0-9]{2}):([0-9]{2}):([0-9]{2})\\z")
        guard let match = expression.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)) else { throw attributeError("Datum als JJJJ-MM-TT HH:mm:ss eingeben.") }
        let numbers = (1...6).map { Int((value as NSString).substring(with:match.range(at:$0)))! }
        guard (1904...9999).contains(numbers[0]),(1...12).contains(numbers[1]),(1...31).contains(numbers[2]),(0...23).contains(numbers[3]),(0...59).contains(numbers[4]),(0...59).contains(numbers[5]) else { throw attributeError("Ungültiger Datumsteil.") }
        var calendar = Calendar(identifier:.gregorian);calendar.timeZone = timeZone
        let components = DateComponents(year:numbers[0],month:numbers[1],day:numbers[2],hour:numbers[3],minute:numbers[4],second:numbers[5])
        let fields:Set<Calendar.Component> = [.year,.month,.day,.hour,.minute,.second]
        func matches(_ date:Date) -> Bool { let c = calendar.dateComponents(fields,from:date);return c.year == components.year && c.month == components.month && c.day == components.day && c.hour == components.hour && c.minute == components.minute && c.second == components.second }
        guard let date = calendar.date(from:components),matches(date) else { throw attributeError("Dieses lokale Datum existiert nicht. Datum oder UTC wählen.") }
        if let transition = timeZone.nextDaylightSavingTimeTransition(after:date.addingTimeInterval(-172_800)),transition < date.addingTimeInterval(172_800) {
            let delta = abs(timeZone.secondsFromGMT(for:transition.addingTimeInterval(-1))-timeZone.secondsFromGMT(for:transition.addingTimeInterval(1)))
            if delta > 0,(matches(date.addingTimeInterval(Double(delta))) || matches(date.addingTimeInterval(-Double(delta)))) { throw attributeError("Dieses lokale Datum ist durch die Zeitumstellung doppeldeutig. UTC verwenden.") }
        }
        return try Self(seconds:Int64(date.timeIntervalSince1970.rounded()))
    }
}

public enum AttributeTimeChange: Equatable {
    case unchanged
    case absolute(AttributeTimestamp)
    case shift(seconds:Int64)
    var isChanged:Bool { self != .unchanged }
    func apply(_ value:AttributeTimestamp) throws -> AttributeTimestamp { switch self { case .unchanged:return value;case .absolute(let date):return try AttributeTimestamp(seconds:date.seconds,nanoseconds:date.nanoseconds);case .shift(let seconds):return try value.shifted(seconds) } }
}

public struct AttributeRule: Equatable {
    public var permissions:UInt16?
    public var created:AttributeTimeChange = .unchanged
    public var modified:AttributeTimeChange = .unchanged
    public var accessed:AttributeTimeChange = .unchanged
    public var files = true
    public var folders = true
    public var filter:TransferFilter
    public init() { var filter = TransferFilter();filter.recursive = false;self.filter = filter }
    public var hasChanges:Bool { permissions != nil || created.isChanged || modified.isChanged || accessed.isChanged }
    public func validate() throws {
        guard permissions.map({ $0 <= 0o7777 }) ?? true,files || folders,!filter.structureOnly else { throw attributeError("Rechte zwischen 0000 und 7777 und mindestens eine Objektart wählen. Strukturkopie gilt hier nicht.") }
        try filter.validate()
        // Validate supplied absolute times, including values obtained through Codable elsewhere.
        for change in [created,modified,accessed] { if case .absolute(let value) = change { _ = try AttributeTimestamp(seconds:value.seconds,nanoseconds:value.nanoseconds) } }
    }
    public static func parsePermissions(_ input:String) throws -> UInt16? {
        let value = input.trimmingCharacters(in:.whitespacesAndNewlines);guard !value.isEmpty else { return nil }
        guard (3...4).contains(value.count),value.utf8.allSatisfy({ (48...55).contains($0) }),let result = UInt16(value,radix:8),result <= 0o7777 else { throw attributeError("Rechte als drei oder vier Oktalziffern eingeben, z. B. 644 oder 0755.") };return result
    }
}

public struct AttributeSnapshot: Equatable {
    public let permissions:UInt16
    public let created:AttributeTimestamp,modified:AttributeTimestamp,accessed:AttributeTimestamp
    public let isDirectory:Bool,isRegularFile:Bool
    public let bytes:Int64
    let version:RenameVersion
    init(_ value:stat) {
        version = RenameVersion(value);permissions = UInt16(value.st_mode & 0o7777);created = .init(value.st_birthtimespec);modified = .init(value.st_mtimespec);accessed = .init(value.st_atimespec)
        isDirectory = version.isDirectory;isRegularFile = version.isRegularFile;bytes = Int64(value.st_size)
    }
    public static func read(_ url:URL) throws -> Self { guard url.isFileURL,!url.path.contains("\0") else { throw attributeError("Ein lokaler Dateipfad wird benötigt.") };var value = stat();guard lstat(url.path,&value) == 0 else { throw attributeFailure(url.lastPathComponent) };return Self(value) }
    static func read(_ fd:Int32) throws -> Self { var value = stat();guard fstat(fd,&value) == 0 else { throw attributeFailure("Dateiobjekt") };return Self(value) }
    static func read(_ fd:Int32,_ name:String) throws -> Self { var value = stat();guard fstatat(fd,name,&value,AT_SYMLINK_NOFOLLOW) == 0 else { throw attributeFailure(name) };return Self(value) }
}

public struct AttributeValues: Equatable {
    public let permissions:UInt16
    public let created:AttributeTimestamp,modified:AttributeTimestamp,accessed:AttributeTimestamp
    init(_ snapshot:AttributeSnapshot,rule:AttributeRule) throws { permissions = rule.permissions ?? snapshot.permissions;created = try rule.created.apply(snapshot.created);modified = try rule.modified.apply(snapshot.modified);accessed = try rule.accessed.apply(snapshot.accessed) }
    init(_ snapshot:AttributeSnapshot) { permissions = snapshot.permissions;created = snapshot.created;modified = snapshot.modified;accessed = snapshot.accessed }
}

public struct AttributeRow:Identifiable {
    public var id:String { source.path }
    public let source:URL,before:AttributeSnapshot,after:AttributeValues?
    public let reason:String?
    public let selected:Bool
    public var canSelect:Bool { reason == nil && after != nil && after != AttributeValues(before) }
    var root:Int,relative:String
    func selecting(_ selected:Bool) -> Self { Self(source:source,before:before,after:after,reason:reason,selected:selected,root:root,relative:relative) }
}

struct AttributeAnchor { let path:URL,version:RenameVersion }
struct AttributeRoot { let source:URL,anchors:[AttributeAnchor] }
struct AttributeObservation { let source:URL,root:Int,relative:String,snapshot:AttributeSnapshot,children:[String]? }

public struct AttributePlan {
    public static let maximumItems = 10_000,maximumDepth = 100,maximumParents = 128
    public let rows:[AttributeRow],rule:AttributeRule
    public let preparedAt:Date
    let roots:[AttributeRoot],observations:[AttributeObservation]
    public var selectedRows:[AttributeRow] { rows.filter(\.selected) }
    public var canApply:Bool { !selectedRows.isEmpty }
    public var initialItems:[TransferItemProgress] { selectedRows.map { TransferItemProgress(id:attributeProgressID($0.source),source:$0.source,target:$0.source,state:.waiting,bytes:0,totalBytes:0,isByteTracked:false,message:"") } }
    public func selecting(paths:Set<String>) throws -> Self {
        guard paths.isSubset(of:Set(rows.filter(\.canSelect).map(\.id))) else { throw attributeError("Auswahl enthält nicht verfügbare oder ungeprüfte Objekte.") }
        return Self(rows:rows.map { $0.selecting(paths.contains($0.id)) },rule:rule,preparedAt:preparedAt,roots:roots,observations:observations)
    }
    public static func prepare(sources:[URL],rule:AttributeRule,token:CancellationToken = .init(),referenceDate:Date = Date()) throws -> Self {
        try token.check();try rule.validate()
        guard !sources.isEmpty,sources.count <= maximumItems else { throw attributeError("1 bis 10.000 lokale Objekte auswählen.") }
        var paths = Set<String>(),normalized:[URL] = []
        for source in sources {
            guard source.isFileURL,!source.path.contains("\0"),source.path != "/" else { throw attributeError("Die Dateisystemwurzel und nicht lokale Adressen sind ausgeschlossen.") }
            let value = try attributeNormalized(source)
            try FileSystem.validateName(value.lastPathComponent)
            if paths.insert(value.path).inserted { normalized.append(value) }
        }
        if rule.filter.recursive { normalized = normalized.filter { candidate in !normalized.contains { other in other.path != candidate.path && candidate.path.hasPrefix(other.path+"/") && (try? AttributeSnapshot.read(other).isDirectory) == true } } }
        normalized.sort { $0.path < $1.path }
        guard Set(normalized.map { $0.deletingLastPathComponent().path }).count <= maximumParents else { throw attributeError("Höchstens 128 verschiedene Auswahl-Elternordner pro Plan verwenden.") }
        let compiled = try CompiledTransferFilter(rule.filter,referenceDate:referenceDate)
        var roots:[AttributeRoot] = [],observations:[AttributeObservation] = [],rows:[AttributeRow] = []
        func scan(_ source:URL,parent:Int32,name:String,root:Int,relative:String,depth:Int,excluded:Bool = false) throws {
            try token.check();guard observations.count < maximumItems,depth <= maximumDepth else { throw attributeError("Eigenschaftsplan überschreitet 10.000 Objekte oder 100 Unterordnerebenen.") }
            let before = try AttributeSnapshot.read(parent,name)
            var reason:String?,children:[String]?
            if !before.isDirectory && !before.isRegularFile { reason = "Verknüpfung oder Spezialdatei bleibt unverändert" }
            else if excluded { reason = "Unterordner ausgeschlossen" }
            else if before.isDirectory && !rule.folders || before.isRegularFile && !rule.files { reason = "Objektart ausgelassen" }
            else if !compiled.includesFile(source.lastPathComponent) || before.isDirectory && rule.filter.hasMetadataConditions || before.isRegularFile && !compiled.includesMetadata(size:before.bytes,modified:before.modified.date,isLink:false) { reason = "Durch Dateifilter ausgelassen" }
            var held:Int32 = -1;defer { if held >= 0 { close(held) } }
            if before.isDirectory || before.isRegularFile {
                held = openat(parent,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
                if held < 0 { reason = "Objekt für sichere Änderungen nicht lesbar" }
                else if try AttributeSnapshot.read(held).version != before.version { throw attributeError("Objekt wurde beim Öffnen der Vorschau geändert: "+source.path) }
            }
            if before.isDirectory,rule.filter.recursive,!excluded {
                guard held >= 0 else { throw attributeError("Unterordner nicht vollständig lesbar: "+source.path) }
                children = try attributeChildren(held)
            }
            let position = observations.count
            observations.append(AttributeObservation(source:source,root:root,relative:relative,snapshot:before,children:children))
            rows.append(AttributeRow(source:source,before:before,after:nil,reason:reason,selected:false,root:root,relative:relative))
            for name in children ?? [] {
                let child = source.appendingPathComponent(name),value = try AttributeSnapshot.read(held,name)
                try scan(child,parent:held,name:name,root:root,relative:relative.isEmpty ? name : relative+"/"+name,depth:depth+1,excluded:value.isDirectory && compiled.excludesFolder(name))
            }
            let after = try AttributeSnapshot.read(parent,name)
            guard after.version == before.version else { throw attributeError("Objekt wurde während der Vorschau geändert: "+source.path) }
            observations[position] = AttributeObservation(source:source,root:root,relative:relative,snapshot:after,children:children)
        }
        for source in normalized {
            let root = roots.count,anchors = try attributeAnchors(source.deletingLastPathComponent());roots.append(AttributeRoot(source:source,anchors:anchors))
            let parent = try attributeOpenAnchors(anchors);defer { close(parent) }
            try scan(source,parent:parent,name:source.lastPathComponent,root:root,relative:"",depth:0)
        }
        var seen = Set<String>()
        for index in rows.indices {
            let observation = observations[index],before = observation.snapshot
            guard seen.insert(observation.source.path).inserted else { throw attributeError("Ein Objekt ist mehrfach im Plan enthalten.") }
            var reason = rows[index].reason,after:AttributeValues?
            if reason == nil { do { after = try AttributeValues(before,rule:rule) } catch { reason = error.localizedDescription } }
            rows[index] = AttributeRow(source:observation.source,before:before,after:after,reason:reason,selected:reason == nil && after != AttributeValues(before),root:observation.root,relative:observation.relative)
        }
        let objects = Dictionary(grouping:rows.filter(\.selected)) { "\($0.before.version.device):\($0.before.version.inode)" }
        guard !objects.values.contains(where:{$0.count > 1}) else { throw attributeError("Mehrere Namen desselben Dateiobjekts bitte getrennt ändern.") }
        for root in roots { try attributeValidateAnchors(root.anchors) }
        return Self(rows:rows,rule:rule,preparedAt:referenceDate,roots:roots,observations:observations)
    }
}

func attributeError(_ message:String) -> CommanderError { .message(message) }
struct AttributeSystemError:LocalizedError { let name:String,code:Int32;var errorDescription:String? { name+": "+String(cString:strerror(code)) } }
func attributeFailure(_ name:String) -> AttributeSystemError { AttributeSystemError(name:name,code:errno) }
func attributeNormalized(_ source:URL) throws -> URL { var path = [CChar](repeating:0,count:Int(MAXPATHLEN));guard realpath(source.deletingLastPathComponent().path,&path) != nil else { throw attributeFailure("Auswahl-Elternordner") };return URL(fileURLWithPath:String(cString:path),isDirectory:true).appendingPathComponent(source.lastPathComponent) }
private func attributeProgressID(_ source:URL) -> UUID { var bytes = Array(SHA256.hash(data:Data(source.path.utf8)).prefix(16));bytes[6] = (bytes[6]&0x0f)|0x80;bytes[8] = (bytes[8]&0x3f)|0x80;return UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15])) }
func attributeAnchors(_ directory:URL) throws -> [AttributeAnchor] {
    var current = URL(fileURLWithPath:"/",isDirectory:true),result:[AttributeAnchor] = []
    let fd = open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC);guard fd >= 0 else { throw attributeFailure("Dateisystemwurzel") };var held = fd;defer { close(held) }
    result.append(AttributeAnchor(path:current,version:try AttributeSnapshot.read(held).version))
    for component in directory.path.split(separator:"/") {
        let name = String(component),next = openat(held,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard next >= 0 else { throw attributeFailure(name) };close(held);held = next;current.appendPathComponent(name,isDirectory:true)
        result.append(AttributeAnchor(path:current,version:try AttributeSnapshot.read(held).version))
    }
    return result
}
func attributeValidateAnchors(_ expected:[AttributeAnchor]) throws {
    guard let last = expected.last else { throw attributeError("Elternordnerbeleg fehlt.") }
    let fresh = try attributeAnchors(last.path)
    guard fresh.count == expected.count,zip(fresh,expected).allSatisfy({ $0.path == $1.path && $0.version.sameObject($1.version) }) else { throw attributeError("Ein übergeordneter Ordner wurde ersetzt oder verschoben.") }
}
