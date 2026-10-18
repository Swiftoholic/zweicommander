import Foundation
import ImageIO

public enum RenameTextTarget: String, Codable, CaseIterable { case full, name, fileExtension }
public enum RenameDateSource: String, Codable, CaseIterable { case modified, created }

public struct RenameRule: Codable, Equatable {
    public var pattern = "{name}"
    public var extensionPattern: String?
    public var search = ""
    public var replacement = ""
    public var regex = false
    public var ignoreCase = false
    public var searchTarget: RenameTextTarget = .full
    public var start = 1
    public var step = 1
    public var digits = 3
    public var resetPerFolder = false
    public var letterCase = 0
    public var caseTarget: RenameTextTarget = .full
    public var dateFormat = "yyyy-MM-dd"
    public var dateSource: RenameDateSource = .modified
    public var useUTC = false
    public init() {}
    enum CodingKeys: String,CodingKey {
        case pattern,extensionPattern,search,replacement,regex,ignoreCase,searchTarget,start,step,digits,resetPerFolder,letterCase,caseTarget,dateFormat,dateSource,useUTC
    }
    public init(from decoder: Decoder) throws {
        self.init();let c = try decoder.container(keyedBy:CodingKeys.self)
        pattern = try c.decodeIfPresent(String.self,forKey:.pattern) ?? pattern
        extensionPattern = try c.decodeIfPresent(String.self,forKey:.extensionPattern)
        search = try c.decodeIfPresent(String.self,forKey:.search) ?? search;replacement = try c.decodeIfPresent(String.self,forKey:.replacement) ?? replacement
        regex = try c.decodeIfPresent(Bool.self,forKey:.regex) ?? regex;ignoreCase = try c.decodeIfPresent(Bool.self,forKey:.ignoreCase) ?? ignoreCase
        searchTarget = try c.decodeIfPresent(RenameTextTarget.self,forKey:.searchTarget) ?? searchTarget
        start = try c.decodeIfPresent(Int.self,forKey:.start) ?? start;step = try c.decodeIfPresent(Int.self,forKey:.step) ?? step;digits = try c.decodeIfPresent(Int.self,forKey:.digits) ?? digits
        resetPerFolder = try c.decodeIfPresent(Bool.self,forKey:.resetPerFolder) ?? resetPerFolder
        letterCase = try c.decodeIfPresent(Int.self,forKey:.letterCase) ?? letterCase;caseTarget = try c.decodeIfPresent(RenameTextTarget.self,forKey:.caseTarget) ?? caseTarget
        dateFormat = try c.decodeIfPresent(String.self,forKey:.dateFormat) ?? dateFormat;dateSource = try c.decodeIfPresent(RenameDateSource.self,forKey:.dateSource) ?? dateSource
        useUTC = try c.decodeIfPresent(Bool.self,forKey:.useUTC) ?? useUTC
    }
    public func validate() throws { _ = try CompiledRenameRule(self) }
}

private enum NamePart {
    case literal(String)
    case token(String,Int?,Int?)
}
private struct NameTemplate {
    var parts: [NamePart] = []
    var tokens: Set<String> = []
    init(_ pattern: String) throws {
        let characters = Array(pattern);var index = 0,literal = ""
        func invalid() -> CommanderError { .message("Ungültiger Platzhalter. Erlaubt: {name}, {full}, {ext}, {n}, {date}, {parent}, {width}, {height}, {taken}; Ausschnitte z. B. {name:2:5}. Klammern mit {{ und }} schreiben.") }
        while index < characters.count {
            let c = characters[index]
            if c == "{" || c == "}" {
                if index+1 < characters.count,characters[index+1] == c { literal.append(c);index += 2;continue }
                guard c == "{",let end = characters[(index+1)...].firstIndex(of:"}") else { throw invalid() }
                if !literal.isEmpty { parts.append(.literal(literal));literal = "" }
                let value = String(characters[(index+1)..<end]),pieces = value.split(separator:":",omittingEmptySubsequences:false).map(String.init)
                guard let token = pieces.first,["name","full","ext","n","date","parent","width","height","taken"].contains(token),pieces.count <= 3 else { throw invalid() }
                var start: Int?,length: Int?
                if pieces.count > 1 {
                    guard ["name","full","ext"].contains(token),let number = Int(pieces[1]),number > 0,number <= 4096 else { throw invalid() };start = number-1
                    if pieces.count == 3 { guard let number = Int(pieces[2]),number > 0,number <= 4096 else { throw invalid() };length = number }
                }
                parts.append(.token(token,start,length));tokens.insert(token);index = end+1
            } else { literal.append(c);index += 1 }
        }
        if !literal.isEmpty { parts.append(.literal(literal)) }
    }
    func render(_ values: [String:String]) -> String {
        parts.map { part in
            switch part {
            case .literal(let value): return value
            case .token(let token,let start,let length):
                let value = values[token] ?? ""
                guard let start else { return value }
                let characters = Array(value);guard start < characters.count else { return "" }
                return String(characters[start..<min(characters.count,start+(length ?? characters.count))])
            }
        }.joined()
    }
}

struct CompiledRenameRule {
    let rule: RenameRule
    private let name: NameTemplate
    private let ext: NameTemplate?
    private let expression: NSRegularExpression?
    init(_ rule: RenameRule) throws {
        guard [rule.pattern,rule.extensionPattern ?? "",rule.search,rule.replacement].allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              (1...20).contains(rule.digits),rule.step != 0,(0...3).contains(rule.letterCase),
              !rule.dateFormat.isEmpty,rule.dateFormat.count <= 120,!rule.dateFormat.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CommanderError.message("Ungültige Umbenennungsregel: Muster begrenzen, 1–20 Zählerstellen, Schritt ungleich null und ein Datumsformat verwenden.")
        }
        self.rule = rule;name = try NameTemplate(rule.pattern);ext = try rule.extensionPattern.map { try NameTemplate($0) }
        if ext != nil && (name.tokens.contains("full") || name.tokens.contains("ext")) {
            throw CommanderError.message("Bei separater Endung im Namensmuster {name} verwenden; {full} und {ext} gehören dann nicht in den Namen.")
        }
        expression = rule.regex && !rule.search.isEmpty ? try NSRegularExpression(pattern:rule.search,options:rule.ignoreCase ? [.caseInsensitive] : []) : nil
    }
    func filename(_ source: URL,version: RenameVersion,index: Int) throws -> String {
        let full = source.lastPathComponent,isDirectory = version.isDirectory
        let extensionName = isDirectory ? "" : source.pathExtension
        let stem = extensionName.isEmpty ? full : source.deletingPathExtension().lastPathComponent
        let offset = index.multipliedReportingOverflow(by:rule.step)
        let counter = rule.start.addingReportingOverflow(offset.partialValue)
        guard !offset.overflow,!counter.overflow else { throw CommanderError.message("Der Zähler läuft über. Start, Schritt oder Auswahl verkleinern.") }
        let format = DateFormatter();format.locale = Locale(identifier:"en_US_POSIX");format.calendar = Calendar(identifier:.gregorian)
        format.timeZone = rule.useUTC ? TimeZone(secondsFromGMT:0) : .current;format.dateFormat = rule.dateFormat
        var values = ["name":stem,"full":full,"ext":extensionName,"parent":source.deletingLastPathComponent().lastPathComponent,
                      "n":String(format:"%0*lld",rule.digits,Int64(counter.partialValue)),
                      "date":format.string(from:rule.dateSource == .modified ? version.modified : version.created)]
        let tokens = name.tokens.union(ext?.tokens ?? [])
        if !tokens.isDisjoint(with:["width","height","taken"]) {
            guard version.isRegularFile,version.size <= 64*1024*1024,
                  let image = CGImageSourceCreateWithURL(source as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image,0,[kCGImageSourceShouldCache:false] as CFDictionary) as? [CFString:Any] else {
                throw CommanderError.message("Bilddaten fehlen: eine reguläre Bilddatei bis 64 MiB wird benötigt; Verknüpfungen werden nicht gelesen.")
            }
            if tokens.contains("width") || tokens.contains("height") {
                guard let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                      width.intValue > 0,height.intValue > 0 else { throw CommanderError.message("Bildabmessungen fehlen.") }
                values["width"] = width.stringValue;values["height"] = height.stringValue
            }
            if tokens.contains("taken") {
                let exif = properties[kCGImagePropertyExifDictionary] as? [CFString:Any]
                let parser = DateFormatter();parser.locale = Locale(identifier:"en_US_POSIX");parser.calendar = Calendar(identifier:.gregorian);parser.timeZone = TimeZone(secondsFromGMT:0);parser.dateFormat = "yyyy:MM:dd HH:mm:ss";parser.isLenient = false
                guard let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String,let date = parser.date(from:text),parser.string(from:date) == text else { throw CommanderError.message("EXIF-Aufnahmedatum fehlt oder ist ungültig.") }
                format.timeZone = TimeZone(secondsFromGMT:0);values["taken"] = format.string(from:date)
            }
        }
        var result = name.render(values)
        if !isDirectory {
            if let ext {
                let suffix = ext.render(values)
                guard !suffix.contains("."),!suffix.contains("/"),!suffix.contains("\0") else { throw CommanderError.message("Eine separate Endung ohne Punkt oder Pfadtrenner verwenden.") }
                if !suffix.isEmpty { result += "."+suffix }
            } else if !name.tokens.contains("ext") && !name.tokens.contains("full") && !extensionName.isEmpty { result += "."+extensionName }
        }
        result = transform(result,target:rule.searchTarget,isDirectory:isDirectory) { text in
            if let expression { return expression.stringByReplacingMatches(in:text,range:NSRange(text.startIndex...,in:text),withTemplate:rule.replacement) }
            return rule.search.isEmpty ? text : text.replacingOccurrences(of:rule.search,with:rule.replacement,options:rule.ignoreCase ? [.caseInsensitive] : [])
        }
        result = transform(result,target:rule.caseTarget,isDirectory:isDirectory) { text in
            switch rule.letterCase { case 1: return text.lowercased();case 2: return text.uppercased();case 3: return text.capitalized;default: return text }
        }
        try FileSystem.validateName(result);return result
    }
    private func transform(_ text: String,target: RenameTextTarget,isDirectory: Bool,edit: (String)->String) -> String {
        guard target != .full else { return edit(text) }
        let url = URL(fileURLWithPath:text),suffix = isDirectory ? "" : url.pathExtension
        let stem = suffix.isEmpty ? text : String(text.dropLast(suffix.count+1))
        if target == .name { return edit(stem)+(suffix.isEmpty ? "" : "."+suffix) }
        guard !suffix.isEmpty else { return text };let updated = edit(suffix);return stem+(updated.isEmpty ? "" : "."+updated)
    }
}
