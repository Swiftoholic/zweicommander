import Foundation

public enum ProcessRunner {
    public static func run(_ executable:String,arguments:[String],directory:URL? = nil,input:Data? = nil,token:CancellationToken = .init(),timeout:TimeInterval = 300) throws -> String {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("zwei-output-"+UUID().uuidString)
        _ = try FileOperations.newFile(in:output.deletingLastPathComponent(),name:output.lastPathComponent)
        defer { try? FileManager.default.removeItem(at:output) }
        let handle = try FileHandle(forWritingTo:output); defer { try? handle.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath:executable); process.arguments = arguments; process.currentDirectoryURL = directory
        process.standardOutput = handle; process.standardError = handle
        let pipe = input == nil ? nil : Pipe()
        process.standardInput = pipe?.fileHandleForReading ?? FileHandle.nullDevice
        try process.run()
        if let input,let pipe { try pipe.fileHandleForWriting.write(contentsOf:input); try pipe.fileHandleForWriting.close() }
        let started = Date()
        while process.isRunning {
            let tooMuchOutput = ((try? FileEntry(url:output).size) ?? 0) > 32*1024*1024
            if token.isCancelled || Date().timeIntervalSince(started) > timeout || tooMuchOutput {
                process.terminate()
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval:0.05) }
                if process.isRunning { kill(process.processIdentifier,SIGKILL) }
                process.waitUntilExit()
                if token.isCancelled { throw CommanderError.cancelled }
                if tooMuchOutput { throw CommanderError.message("Prozess wegen mehr als 32 MB Textausgabe beendet.") }
                throw CommanderError.message("Zeitlimit für externen Prozess erreicht.")
            }
            Thread.sleep(forTimeInterval:0.1)
        }
        try handle.synchronize()
        let reader = try FileHandle(forReadingFrom:output); defer { try? reader.close() }
        let data = try reader.read(upToCount:4*1024*1024) ?? Data()
        let text = String(decoding:data,as:UTF8.self)
        guard process.terminationStatus == 0 else { throw CommanderError.message("Prozess endete mit Status \(process.terminationStatus):\n"+text) }
        return text + ((try? FileEntry(url:output).size) ?? 0 > 4*1024*1024 ? "\n[Ausgabe auf 4 MB begrenzt]" : "")
    }
}
