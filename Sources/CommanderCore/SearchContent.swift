import Foundation

/// Content matching is bounded independently of directory traversal. The ICU progress
/// callback can interrupt matching itself, including a pathological backtracking query.
struct CompiledSearchContent {
    static let regexByteLimit = 1_048_576
    static let regexTimeLimit:TimeInterval = 0.1
    let options:SearchOptions,expression:NSRegularExpression?,needle:Data
    init(_ options:SearchOptions) throws {
        self.options = options
        guard !options.contentNegated || !options.content.isEmpty else { throw CommanderError.message("Für „nicht enthalten“ einen Suchinhalt angeben.") }
        guard options.contentMode == .literal || !options.content.isEmpty else { throw CommanderError.message("Für RegEx oder Hex einen Suchinhalt angeben.") }
        switch options.contentMode {
        case .literal:expression = nil;needle = Data()
        case .regularExpression:
            guard !options.wholeWords else { throw CommanderError.message("Bei Inhalts-RegEx Wortgrenzen im Ausdruck mit \\b angeben.") }
            expression = try NSRegularExpression(pattern:options.content,options:options.caseSensitive ? [] : [.caseInsensitive]);needle = Data()
        case .hex:
            guard !options.wholeWords,!options.searchOfficeDocuments,options.encoding == .automatic else { throw CommanderError.message("Hexsuche liest Rohbytes: ganze Wörter, Office-Text und Textkodierung ausschalten.") }
            let digits = options.content.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            guard !digits.isEmpty,digits.count % 2 == 0,digits.allSatisfy({ CharacterSet(charactersIn:"0123456789abcdefABCDEF").contains($0) }) else { throw CommanderError.message("Hexfolge als vollständige Bytepaare angeben, zum Beispiel 00 FF 2A. Leerraum ist erlaubt; Platzhalter sind nicht möglich.") }
            let text = String(String.UnicodeScalarView(digits));var bytes:[UInt8] = [],position = text.startIndex
            while position < text.endIndex { let end = text.index(position,offsetBy:2);bytes.append(UInt8(text[position..<end],radix:16)!);position = end }
            needle = Data(bytes);expression = nil
        }
    }
    func snippet(in text:String,token:CancellationToken) throws -> String? {
        try token.check();let match:Range<String.Index>?
        if let expression {
            guard text.utf8.count <= Self.regexByteLimit else { throw CommanderError.message("Inhalts-RegEx übersprungen: höchstens 1 MiB Text je Datei.") }
            let start = ProcessInfo.processInfo.systemUptime;var found:NSRange?,cancelled = false,timedOut = false
            expression.enumerateMatches(in:text,options:[.reportProgress,.reportCompletion],range:NSRange(text.startIndex..<text.endIndex,in:text)) { result,_,stop in
                if token.isCancelled { cancelled = true;stop.pointee = true;return }
                if ProcessInfo.processInfo.systemUptime-start > Self.regexTimeLimit { timedOut = true;stop.pointee = true;return }
                if let result { found = result.range;stop.pointee = true }
            }
            if cancelled { throw CommanderError.cancelled }
            if timedOut { throw CommanderError.message("Inhalts-RegEx wegen hoher Rechenzeit unterbrochen (100 ms je Datei). Ausdruck vereinfachen.") }
            try token.check();match = found.flatMap { Range($0,in:text) } ?? (found == nil ? nil : text.startIndex..<text.startIndex)
        } else {
            let compare:String.CompareOptions = options.caseSensitive ? [.literal] : [.caseInsensitive,.literal]
            let word = CharacterSet.alphanumerics.union(.nonBaseCharacters).union(CharacterSet(charactersIn:"_"))
            func isWord(_ ch:Character) -> Bool { ch.unicodeScalars.contains { word.contains($0) } }
            var start = text.startIndex,found:Range<String.Index>?
            while start < text.endIndex,let value = text.range(of:options.content,options:compare,range:start..<text.endIndex) {
                try token.check()
                if !options.wholeWords || ((value.lowerBound == text.startIndex || !isWord(text[text.index(before:value.lowerBound)])) && (value.upperBound == text.endIndex || !isWord(text[value.upperBound]))) { found = value;break }
                start = text.index(after:value.lowerBound)
            }
            match = found
        }
        if options.contentNegated { return match == nil ? "Suchinhalt nicht enthalten · Text geprüft" : nil }
        guard let match else { return nil }
        let lower = text.index(match.lowerBound,offsetBy:-60,limitedBy:text.startIndex) ?? text.startIndex
        let upper = text.index(lower,offsetBy:240,limitedBy:text.endIndex) ?? text.endIndex
        return String(text[lower..<upper]).replacingOccurrences(of:"\r",with:" ").replacingOccurrences(of:"\n",with:" ")
    }
}
