import Foundation

public struct TransferFilter: Codable, Equatable {
    public var include = "*"
    public var exclude = ""
    public var excludedFolders = ""
    public var regularExpressions = false
    public var recursive = true
    public var keepEmptyFolders = true
    public var structureOnly = false
    public var minimumSize: Int64?
    public var maximumSize: Int64?
    public var modifiedFrom: Date?
    public var modifiedBefore: Date?
    public var modifiedAge: TransferAgeRange?
    public init() {}
    public var isActive: Bool { self != Self() }
    public var hasMetadataConditions: Bool { !structureOnly && (minimumSize != nil || maximumSize != nil || modifiedFrom != nil || modifiedBefore != nil || modifiedAge != nil) }
    public func validate() throws { _ = try CompiledTransferFilter(self) }
}

struct TransferPatterns {
    let expressions: [NSRegularExpression]
    init(_ text: String, regex: Bool, emptyMatchesAll: Bool) throws {
        guard text.utf8.count <= 4096 else { throw CommanderError.message("Filter darf höchstens 4096 UTF-8-Bytes enthalten.") }
        let text = text.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let parts = regex ? (text.isEmpty ? [] : [text]) : text.components(separatedBy:";").map { $0.trimmingCharacters(in:.whitespaces) }.filter { !$0.isEmpty }
        var patterns = parts
        if patterns.isEmpty && emptyMatchesAll { patterns = [regex ? ".*" : "*"] }
        guard patterns.count <= 128 else { throw CommanderError.message("Höchstens 128 Muster pro Filterfeld verwenden.") }
        expressions = try patterns.map { value in
            let pattern: String
            if regex { pattern = value }
            else {
                guard !value.contains("/"),!value.contains("\n"),!value.contains("\r") else { throw CommanderError.message("Dateimuster enthalten nur Namen, keine Pfade. Mehrere Muster mit ; trennen.") }
                let value = value == "*.*" ? "*" : value
                pattern = "\\A"+NSRegularExpression.escapedPattern(for:value).replacingOccurrences(of:"\\*",with:".*").replacingOccurrences(of:"\\?",with:".")+"\\z"
            }
            do { return try NSRegularExpression(pattern:pattern,options:[.caseInsensitive,.dotMatchesLineSeparators]) }
            catch { throw CommanderError.message("Ungültiger Filter: "+error.localizedDescription) }
        }
    }
    func matches(_ name: String) -> Bool {
        let name = name.precomposedStringWithCanonicalMapping
        return expressions.contains { $0.firstMatch(in:name,range:NSRange(name.startIndex...,in:name)) != nil }
    }
}

struct CompiledTransferFilter {
    private let include: TransferPatterns, exclude: TransferPatterns, folders: TransferPatterns
    private let filter: TransferFilter
    private let youngestDate: Date?,oldestDate: Date?
    init(_ filter: TransferFilter,referenceDate: Date = Date()) throws {
        self.filter = filter
        var youngest: Date?,oldest: Date?
        if !filter.structureOnly {
            guard filter.minimumSize.map({ $0 >= 0 }) ?? true,filter.maximumSize.map({ $0 >= 0 }) ?? true else { throw CommanderError.message("Dateigrößen dürfen nicht negativ sein.") }
            if let lower = filter.minimumSize,let upper = filter.maximumSize,lower > upper { throw CommanderError.message("Die kleinste Dateigröße darf nicht über der größten liegen.") }
            guard filter.modifiedFrom.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,filter.modifiedBefore.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { throw CommanderError.message("Ungültiges Änderungsdatum.") }
            if let lower = filter.modifiedFrom,let upper = filter.modifiedBefore,lower >= upper { throw CommanderError.message("Das Ende des Datumsbereichs muss nach dem Anfang liegen.") }
            if let age = filter.modifiedAge {
                try age.validate()
                guard filter.modifiedFrom == nil,filter.modifiedBefore == nil else { throw CommanderError.message("Feste Zeitpunkte und relatives Alter getrennt verwenden.") }
                guard referenceDate.timeIntervalSinceReferenceDate.isFinite else { throw CommanderError.message("Ungültige Bezugszeit für das Dateialter.") }
                youngest = referenceDate.addingTimeInterval(-Double(try age.minimum?.seconds() ?? 0))
                oldest = try age.maximum.map { referenceDate.addingTimeInterval(-Double(try $0.seconds())) }
            }
        }
        youngestDate = youngest;oldestDate = oldest
        include = try TransferPatterns(filter.structureOnly ? "*" : filter.include,regex:filter.structureOnly ? false : filter.regularExpressions,emptyMatchesAll:true)
        exclude = try TransferPatterns(filter.structureOnly ? "" : filter.exclude,regex:filter.structureOnly ? false : filter.regularExpressions,emptyMatchesAll:false)
        folders = try TransferPatterns(filter.recursive ? filter.excludedFolders : "",regex:false,emptyMatchesAll:false)
    }
    func includesFile(_ name: String) -> Bool { include.matches(name) && !exclude.matches(name) }
    func includesMetadata(size: Int64,modified: Date,isLink: Bool) -> Bool {
        guard filter.hasMetadataConditions else { return true }
        guard !isLink else { return false }
        if let minimum = filter.minimumSize,size < minimum { return false }
        if let maximum = filter.maximumSize,size > maximum { return false }
        if let lower = filter.modifiedFrom,modified < lower { return false }
        if let upper = filter.modifiedBefore,modified >= upper { return false }
        if let youngestDate,modified > youngestDate { return false }
        if let oldestDate,modified < oldestDate { return false }
        return true
    }
    func excludesFolder(_ name: String) -> Bool { folders.matches(name) }
}

public enum TransferSize {
    /// Decimal units use 1000, binary units (KiB/MiB/...) use 1024. No grouping separators.
    public static func parse(_ input: String) throws -> Int64? {
        let text = input.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.isEmpty { return nil }
        guard text.utf8.count <= 128 else { throw CommanderError.message("Größenangabe ist zu lang.") }
        let expression = try NSRegularExpression(pattern:"\\A([0-9]{1,30}(?:[.,][0-9]{1,18})?)\\s*(B|KB|KIB|MB|MIB|GB|GIB|TB|TIB)?\\z",options:.caseInsensitive)
        guard let match = expression.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),let digits = Range(match.range(at:1),in:text) else { throw CommanderError.message("Größe als Zahl mit B, KB, MB, GB oder KiB, MiB, GiB eingeben, z. B. 1,5 MB.") }
        let unit = Range(match.range(at:2),in:text).map { String(text[$0]).uppercased() } ?? "B"
        let factors: [String:Int64] = ["B":1,"KB":1000,"KIB":1024,"MB":1_000_000,"MIB":1_048_576,"GB":1_000_000_000,"GIB":1_073_741_824,"TB":1_000_000_000_000,"TIB":1_099_511_627_776]
        let number = NSDecimalNumber(string:String(text[digits]).replacingOccurrences(of:",",with:"."),locale:Locale(identifier:"en_US_POSIX"))
        let factor = NSDecimalNumber(value:factors[unit]!),maximum = NSDecimalNumber(value:Int64.max)
        guard number != .notANumber,number.compare(maximum.dividing(by:factor)) != .orderedDescending else { throw CommanderError.message("Dateigröße liegt außerhalb des unterstützten Bereichs.") }
        let value = number.multiplying(by:factor)
        let whole = value.rounding(accordingToBehavior:NSDecimalNumberHandler(roundingMode:.down,scale:0,raiseOnExactness:false,raiseOnOverflow:false,raiseOnUnderflow:false,raiseOnDivideByZero:false))
        guard value == whole,value.compare(maximum) != .orderedDescending else { throw CommanderError.message("Dateigröße muss eine ganze Anzahl Bytes ergeben.") }
        return value.int64Value
    }
}
