import Foundation

public struct MediaMetadataIdentity: Hashable {
    public let key:String
    public init(_ url:URL) throws {
        guard url.isFileURL,[nil,"","localhost"].contains(url.host?.lowercased()),url.user == nil,url.password == nil,url.port == nil,url.query == nil,url.fragment == nil else { throw CommanderError.message("Ein eindeutiger lokaler Datei-URL ohne fremden Servernamen wird benötigt.") }
        let value = try RenameVersion.read(url)
        guard value.isRegularFile else { throw CommanderError.message("Mediendaten benötigen eine lokale reguläre Datei ohne Verknüpfung.") }
        key = url.standardizedFileURL.path+"|\(value.device):\(value.inode):\(value.mode):\(value.size):\(value.modifiedSeconds):\(value.modifiedNanos):\(value.changedSeconds):\(value.changedNanos)"
    }
}

public struct MediaMetadata: Equatable {
    public let identity:MediaMetadataIdentity
    public var format = ""
    public var duration:Double?
    public var width:Int?,height:Int?
    public var title:String?,artist:String?,album:String?,year:Int?,track:Int?
    public var taken:Date?,camera:String?
    public var notes:[String] = []
    public init(identity:MediaMetadataIdentity) { self.identity = identity }
    public var hasValues:Bool { duration != nil || width != nil || title != nil || artist != nil || album != nil || year != nil || track != nil || taken != nil || camera != nil }
    public static func boundedText(_ text:String,limit:Int = 512) -> String? {
        var output = "",bytes = 0
        for scalar in text.unicodeScalars {
            let value = CharacterSet.controlCharacters.contains(scalar) || CharacterSet(charactersIn:"\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}").contains(scalar) ? " " : String(scalar)
            guard bytes+value.utf8.count <= limit else { break };output += value;bytes += value.utf8.count
        }
        let result = output.precomposedStringWithCanonicalMapping.trimmingCharacters(in:.whitespacesAndNewlines);return result.isEmpty ? nil : result
    }
    public static func filenameComponent(_ text:String) throws -> String {
        guard let text = boundedText(text) else { throw CommanderError.message("Das Metadatenfeld enthält keinen verwendbaren Dateinamen.") }
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn:"/:\\\"<>|?*"))
        let value = text.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        guard let bounded = boundedText(value,limit:120)?.trimmingCharacters(in:CharacterSet(charactersIn:" .")),!bounded.isEmpty else { throw CommanderError.message("Das Metadatenfeld enthält keinen verwendbaren Dateinamen.") }
        return bounded
    }
    public func renameValue(_ token:String,dateFormatter:DateFormatter) throws -> String {
        var value:String?
        switch token {
        case "title":value = title
        case "artist":value = artist
        case "album":value = album
        case "year":value = year.map(String.init)
        case "track":value = track.map(String.init)
        case "duration":value = duration.map { String(Int64($0.rounded())) }
        case "camera":value = camera
        case "width":value = width.map(String.init)
        case "height":value = height.map(String.init)
        case "taken":value = taken.map { dateFormatter.string(from:$0) }
        default:break
        }
        guard let value else { throw CommanderError.message("Mediendatenfeld {"+token+"} fehlt. Die Zeile bleibt unverändert.") }
        return try Self.filenameComponent(value)
    }
}

public enum MediaMetadataField:String,CaseIterable {
    case duration = "mediaDuration",dimensions = "mediaDimensions",title = "mediaTitle",artist = "mediaArtist",album = "mediaAlbum",year = "mediaYear",track = "mediaTrack",taken = "mediaTaken",camera = "mediaCamera"
    public var title:String {
        switch self { case .duration:return "Dauer";case .dimensions:return "Auflösung";case .title:return "Medientitel";case .artist:return "Interpret";case .album:return "Album";case .year:return "Jahr";case .track:return "Titelnummer";case .taken:return "Aufgenommen";case .camera:return "Kamera" }
    }
    public func text(_ value:MediaMetadata) -> String? {
        switch self {
        case .duration:guard let duration = value.duration else { return nil };let seconds = Int64(duration.rounded());return String(format:"%lld:%02lld:%02lld",seconds/3600,seconds/60%60,seconds%60)
        case .dimensions:guard let width = value.width,let height = value.height else { return nil };return "\(width) × \(height)"
        case .title:return value.title
        case .artist:return value.artist
        case .album:return value.album
        case .year:return value.year.map(String.init)
        case .track:return value.track.map(String.init)
        case .taken:guard let date = value.taken else { return nil };let formatter = DateFormatter();formatter.locale = Locale(identifier:"en_US_POSIX");formatter.timeZone = TimeZone(secondsFromGMT:0);formatter.dateFormat = "yyyy-MM-dd HH:mm:ss";return formatter.string(from:date)
        case .camera:return value.camera
        }
    }
    public func number(_ value:MediaMetadata) -> Double? {
        switch self { case .duration:return value.duration;case .dimensions:return value.width.map { Double($0)*Double(value.height ?? 0) };case .year:return value.year.map(Double.init);case .track:return value.track.map(Double.init);case .taken:return value.taken?.timeIntervalSince1970;default:return nil }
    }
}
