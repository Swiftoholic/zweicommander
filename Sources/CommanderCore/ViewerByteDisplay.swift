import Foundation

public struct ViewerByteDisplay {
    public let text:String,offset:Int64,count:Int
    let positions:[NSRange]
    public init(_ window:ViewerByteWindow,binary:Bool = false,token:CancellationToken = .init()) throws {
        try token.check()
        guard window.data.count <= (binary ? 8*1024 : 16*1024) else { throw CommanderError.message("Die Hex-/Binäranzeige benötigt eine kleinere Seite.") }
        let bytes = Array(window.data),step = binary ? 8 : 16,digits = binary ? 8 : 2
        var output = "",ranges:[NSRange] = []
        for begin in stride(from:0,to:bytes.count,by:step) {
            try token.check();let end = min(begin+step,bytes.count),prefix = String(format:"%012llX  ",window.offset+Int64(begin)),base = output.utf16.count+prefix.utf16.count
            let values = bytes[begin..<end].map { binary ? String(repeating:"0",count:8-String($0,radix:2).count)+String($0,radix:2) : String(format:"%02X",$0) }.joined(separator:" ")
            let ascii = bytes[begin..<end].map { $0 >= 32 && $0 < 127 ? String(UnicodeScalar($0)) : "." }.joined()
            ranges += (0..<(end-begin)).map { NSRange(location:base+$0*(digits+1),length:digits) }
            output += prefix+values.padding(toLength:step*(digits+1),withPad:" ",startingAt:0)+" "+ascii+(end < bytes.count ? "\n" : "")
        }
        text = output;offset = window.offset;count = window.data.count;positions = ranges
    }
    public func range(for match:ViewerMatch) -> NSRange? {
        let start = max(0,match.offset-offset),end = min(Int64(count)-1,match.offset-offset+Int64(match.length)-1)
        guard start >= 0,end >= start,end < count else { return nil }
        let first = positions[Int(start)],last = positions[Int(end)];return NSRange(location:first.location,length:last.location+last.length-first.location)
    }
}
