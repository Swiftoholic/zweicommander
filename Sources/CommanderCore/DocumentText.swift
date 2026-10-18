import Foundation

public enum DocumentText {
    public static let extensions: Set<String> = ["docx", "xlsx", "odt", "pptx"]
    public static func supports(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }
    public static func extract(_ url: URL, maxBytes: Int = 32*1024*1024, token: CancellationToken = .init()) throws -> String {
        let type = url.pathExtension.lowercased()
        guard extensions.contains(type) else { throw CommanderError.message("Kein unterstütztes Office-XML-Dokument.") }
        let members = try ArchiveService.readMembers(url, maxBytes: maxBytes, token: token) { name in
            let path = name.lowercased()
            switch type {
            case "docx":
                return path == "word/document.xml" || (path.hasPrefix("word/") && ["header", "footer", "footnotes", "endnotes"].contains { path.hasPrefix("word/"+$0) } && path.hasSuffix(".xml"))
            case "xlsx": return path == "xl/sharedstrings.xml" || path == "xl/workbook.xml" || (path.hasPrefix("xl/worksheets/sheet") && path.hasSuffix(".xml"))
            case "pptx": return path.hasPrefix("ppt/slides/slide") && path.hasSuffix(".xml")
            case "odt": return path == "content.xml"
            default: return false
            }
        }
        guard !members.isEmpty else { throw CommanderError.message("Kein lesbarer Office-Dokumenttext gefunden.") }
        return try members.sorted { $0.0 < $1.0 }.map { _,data in
            try token.check()
            return try parseXML(data)
        }.joined(separator: "\n")
    }
    public static func parseXML(_ data: Data) throws -> String {
        let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        guard let source, !source.localizedCaseInsensitiveContains("<!DOCTYPE"), !source.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw CommanderError.message("XML mit Dokumenttyp- oder Entity-Deklarationen wird nicht verarbeitet.")
        }
        let parser = XMLParser(data: data), collector = TextCollector()
        parser.delegate = collector; parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        guard parser.parse() else { throw CommanderError.message("Dokument-XML ist beschädigt: "+(parser.parserError?.localizedDescription ?? "Parserfehler")) }
        return collector.text
    }
}
private final class TextCollector: NSObject, XMLParserDelegate {
    var text = ""
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let local = elementName.components(separatedBy: ":").last ?? elementName
        if ["p", "tr", "row", "c", "si", "table-cell", "table-row", "sld", "br"].contains(local) { text += "\n" }
    }
}
