import Foundation

public enum ProcessRunner {
    public static func run(_ executable:String,arguments:[String],directory:URL? = nil,input:Data? = nil,token:CancellationToken = .init(),timeout:TimeInterval = 300) throws -> String {
        do {
            return try NativeProcessCapture.run(executable:executable,arguments:arguments,directory:directory,input:input,token:token,timeout:timeout)
        } catch let failure as ExternalToolProcessFailure {
            if token.isCancelled { throw CommanderError.cancelled }
            throw CommanderError.message(failure.message+(failure.output.isEmpty ? "" : "\n"+failure.output))
        }
    }
}
