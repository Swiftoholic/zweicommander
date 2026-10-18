import Foundation

public struct TransferFilter: Codable, Equatable {
    public var include = "*"
    public var exclude = ""
    public var excludedFolders = ""
    public var regularExpressions = false
    public var recursive = true
    public var keepEmptyFolders = true
    public var structureOnly = false
    public init() {}
    public var isActive: Bool { self != Self() }
}

private struct TransferPatterns {
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
    init(_ filter: TransferFilter) throws {
        include = try TransferPatterns(filter.structureOnly ? "*" : filter.include,regex:filter.structureOnly ? false : filter.regularExpressions,emptyMatchesAll:true)
        exclude = try TransferPatterns(filter.structureOnly ? "" : filter.exclude,regex:filter.structureOnly ? false : filter.regularExpressions,emptyMatchesAll:false)
        folders = try TransferPatterns(filter.recursive ? filter.excludedFolders : "",regex:false,emptyMatchesAll:false)
    }
    func includesFile(_ name: String) -> Bool { include.matches(name) && !exclude.matches(name) }
    func excludesFolder(_ name: String) -> Bool { folders.matches(name) }
}
