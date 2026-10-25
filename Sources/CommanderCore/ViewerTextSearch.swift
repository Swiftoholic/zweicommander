import Foundation

public struct ViewerTextMatch:Equatable {
    public let range:NSRange,wrapped:Bool
}
/// Search the bounded displayed report, using start-position ranges rather than
/// truncating candidate text at the previous match. Overlapping hits remain reachable.
public enum ViewerTextSearch {
    public static func find(in value:String,text:String,from offset:Int,direction:ViewerSearchDirection = .forward,wrap:Bool = true,token:CancellationToken = .init()) throws -> ViewerTextMatch? {
        try token.check();let body = value as NSString,needle = text as NSString
        guard body.length <= 256*1024,needle.length > 0,needle.length <= ViewerNeedle.maximumBytes,offset >= 0,offset <= body.length else { throw CommanderError.message("Ungültiger Suchtext, Textausschnitt oder Suchbeginn.") }
        guard needle.length <= body.length else { return nil }
        let lastStart = body.length-needle.length+1,pivot = min(offset,lastStart)
        let ranges = direction == .forward ? [pivot..<lastStart,0..<pivot] : [0..<pivot,pivot..<lastStart]
        for (phase,starts) in ranges.prefix(wrap ? 2 : 1).enumerated() where !starts.isEmpty {
            try token.check()
            let cover = NSRange(location:starts.lowerBound,length:starts.count+needle.length-1),options:NSString.CompareOptions = direction == .backward ? [.literal,.backwards] : [.literal]
            let range = body.range(of:text,options:options,range:cover);try token.check()
            if range.location != NSNotFound { return ViewerTextMatch(range:range,wrapped:phase > 0) }
        }
        return nil
    }
}
