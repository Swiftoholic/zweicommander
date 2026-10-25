import Foundation

struct DiffTextLine {
    let text:String,ending:String,key:String,keyEnding:String,fingerprint:Int
    init(_ text:String,_ ending:String,options:FileDiffOptions) {
        self.text = text;self.ending = ending
        var value = text
        if options.ignoreWhitespace { value = String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })) }
        if options.ignoreCase { value = value.folding(options:.caseInsensitive,locale:Locale(identifier:"en_US_POSIX")) }
        key = value;keyEnding = options.ignoreLineEndings ? "" : ending
        var hasher = Hasher();hasher.combine(key);hasher.combine(keyEnding);fingerprint = hasher.finalize()
    }
    static func split(_ text:String,options:FileDiffOptions,limits:FileDiffLimits,token:CancellationToken) throws -> [Self] {
        var result:[Self] = [],body = "",lineBytes = 0,checked = 0
        let scalars = text.unicodeScalars;var index = scalars.startIndex
        func append(_ ending:String) throws {
            guard result.count < limits.maximumLines else { throw CommanderError.message("Die Textdatei enthält zu viele Zeilen für einen vollständigen Vergleich.") }
            result.append(Self(body,ending,options:options));body = "";lineBytes = 0
        }
        while index < scalars.endIndex {
            if checked % 4096 == 0 { try token.check() };checked += 1
            let scalar = scalars[index];index = scalars.index(after:index)
            if scalar.value == 13 {
                var ending = "\r"
                if index < scalars.endIndex,scalars[index].value == 10 { ending = "\r\n";index = scalars.index(after:index) }
                try append(ending)
            } else if scalar.value == 10 { try append("\n") }
            else {
                body.unicodeScalars.append(scalar);lineBytes += scalar.utf8.count
                guard lineBytes <= limits.maximumLineBytes else { throw CommanderError.message("Eine Textzeile ist zu lang für die Vergleichsansicht. Binärvergleich verwenden.") }
            }
        }
        if !body.isEmpty { try append("") };try token.check();return result
    }
}

private enum DiffEdit { case equal(Int,Int),remove(Int),add(Int) }
private struct DiffBudget {
    let maximum:Int,token:CancellationToken
    var used = 0,nextCheck = 0
    mutating func tick(_ cost:Int = 1) throws {
        used += cost;guard used <= maximum else { throw CommanderError.message("Der vollständige Textvergleich überschreitet das Rechenbudget. Kleinere Dateien oder Binärvergleich wählen; es wird kein Teilvergleich angezeigt.") }
        if used >= nextCheck { try token.check();nextCheck = used+256 }
    }
    mutating func equal(_ a:DiffTextLine,_ b:DiffTextLine) throws -> Bool {
        try tick();guard a.fingerprint == b.fingerprint else { return false }
        try tick(1+(a.key.utf8.count+b.key.utf8.count)/64);return a.key == b.key && a.keyEnding == b.keyEnding
    }
}

enum DiffTextAlgorithm {
    static func compare(_ a:[DiffTextLine],_ b:[DiffTextLine],limits:FileDiffLimits,token:CancellationToken) throws -> [FileDiffRow] {
        var budget = DiffBudget(maximum:limits.maximumWork,token:token),prefix = 0,suffix = 0
        while prefix < min(a.count,b.count),try budget.equal(a[prefix],b[prefix]) { prefix += 1 }
        while suffix < min(a.count,b.count)-prefix,try budget.equal(a[a.count-1-suffix],b[b.count-1-suffix]) { suffix += 1 }
        let n = a.count-prefix-suffix,m = b.count-prefix-suffix
        var edits = (0..<prefix).map { DiffEdit.equal($0,$0) }
        if n == 0 { edits += (0..<m).map { .add(prefix+$0) } }
        else if m == 0 { edits += (0..<n).map { .remove(prefix+$0) } }
        else { edits += try middle(a,b,base:prefix,n:n,m:m,limits:limits,budget:&budget) }
        edits += (0..<suffix).map { .equal(a.count-suffix+$0,b.count-suffix+$0) }
        var rows:[FileDiffRow] = [],removed:[Int] = [],added:[Int] = []
        func row(_ left:Int?,_ right:Int?,_ kind:FileDiffKind) throws {
            guard rows.count < limits.maximumRows else { throw CommanderError.message("Zu viele Zeilen für eine vollständige Vergleichsansicht; es wird kein Teilvergleich angezeigt.") }
            rows.append(.init(id:rows.count,kind:kind,leftPosition:left.map{$0+1},rightPosition:right.map{$0+1},leftLength:left == nil ? 0 : 1,rightLength:right == nil ? 0 : 1,leftText:left.map{a[$0].text},rightText:right.map{b[$0].text},leftEnding:left.map{a[$0].ending},rightEnding:right.map{b[$0].ending}))
        }
        func flush() throws {
            for index in 0..<max(removed.count,added.count) {
                let left = index < removed.count ? removed[index] : nil,right = index < added.count ? added[index] : nil
                try row(left,right,left == nil ? .added : right == nil ? .removed : .changed)
            };removed.removeAll(keepingCapacity:true);added.removeAll(keepingCapacity:true)
        }
        for edit in edits {
            try budget.tick()
            switch edit { case .equal(let x,let y):try flush();try row(x,y,.equal);case .remove(let x):removed.append(x);case .add(let y):added.append(y) }
        }
        try flush();try token.check();return rows
    }
    /// Myers' shortest edit script. Only active diagonals are retained, with explicit work and memory caps.
    private static func middle(_ a:[DiffTextLine],_ b:[DiffTextLine],base:Int,n:Int,m:Int,limits:FileDiffLimits,budget:inout DiffBudget) throws -> [DiffEdit] {
        let maximum = n+m,offset = maximum+1
        var vector = [Int](repeating:-1,count:2*maximum+3),trace:[[Int]] = [],cells = 0
        vector[offset+1] = 0
        for distance in 0...maximum {
            try budget.tick();let width = 2*distance+3
            guard cells <= limits.maximumTraceCells-width else { throw CommanderError.message("Die Unterschiede benötigen zu viel Vergleichsspeicher. Kleinere Dateien oder Binärvergleich wählen; das Ergebnis wurde vollständig verworfen.") }
            trace.append(Array(vector[(offset-distance-1)...(offset+distance+1)]));cells += width
            for diagonal in stride(from:-distance,through:distance,by:2) {
                try budget.tick();let position = offset+diagonal
                var x = diagonal == -distance || diagonal != distance && vector[position-1] < vector[position+1] ? vector[position+1] : vector[position-1]+1
                var y = x-diagonal
                while x < n,y < m,try budget.equal(a[base+x],b[base+y]) { x += 1;y += 1 }
                vector[position] = x
                if x >= n,y >= m {
                    var result:[DiffEdit] = [],x = n,y = m
                    for d in stride(from:distance,through:0,by:-1) {
                        let values = trace[d],k = x-y
                        func get(_ key:Int) -> Int { values[key+d+1] }
                        let previous = k == -d || k != d && get(k-1) < get(k+1) ? k+1 : k-1
                        let previousX = get(previous),previousY = previousX-previous
                        while x > previousX,y > previousY { try budget.tick();x -= 1;y -= 1;result.append(.equal(base+x,base+y)) }
                        if d > 0 { if x == previousX { y -= 1;result.append(.add(base+y)) } else { x -= 1;result.append(.remove(base+x)) } }
                    }
                    return result.reversed()
                }
            }
        }
        throw CommanderError.message("Der Dateivergleich konnte kein vollständiges Ergebnis erzeugen.")
    }
}
