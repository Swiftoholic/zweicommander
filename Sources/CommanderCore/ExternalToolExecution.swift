import Foundation
import Darwin

public struct ExternalToolContext {
    public let activeDirectory: URL
    public let inactiveDirectory: URL?
    public let focused: URL?
    public let selection: [URL]
    public init(activeDirectory:URL,inactiveDirectory:URL? = nil,focused:URL? = nil,selection:[URL] = []) {
        self.activeDirectory = activeDirectory;self.inactiveDirectory = inactiveDirectory;self.focused = focused;self.selection = selection
    }
}
struct ExternalToolObservation {
    let url:URL,version:RenameVersion
    let directoryIdentityOnly:Bool
    func validate() throws {
        let current = try RenameVersion.read(url)
        guard directoryIdentityOnly ? version.sameObject(current) && current.isDirectory : current == version else {
            throw CommanderError.message("Werkzeugziel, Arbeitsordner oder Dateiauswahl wurde seit der Vorschau verändert: "+url.lastPathComponent)
        }
    }
}
public struct ExternalToolInvocation {
    public let arguments:[String]
    public let directory:URL
    public let documents:[URL]
    let observations:[ExternalToolObservation]
    public var preview:String { preview(systemDirectory:false) }
    public func preview(systemDirectory:Bool) -> String {
        let encoder = JSONEncoder();func quoted(_ value:String) -> String { String(data:try! encoder.encode(value),encoding:.utf8)! }
        return (systemDirectory ? "Arbeitsordner: von macOS verwaltet" : "Arbeitsordner: "+directory.path)+"\nArgumente (jeweils einzeln):\n"+arguments.enumerated().map { "\($0.offset+1): "+quoted($0.element) }.joined(separator:"\n")+(documents.isEmpty ? "" : "\nDokumente:\n"+documents.map { quoted($0.path) }.joined(separator:"\n"))
    }
}
public struct ExternalToolPlan {
    public let tool:ExternalTool
    public let target:URL
    public let invocations:[ExternalToolInvocation]
    let common:[ExternalToolObservation]
    public var preview:String { tool.title+"\nProgramm: "+target.path+"\n\(invocations.count) Aufruf(e) · "+(tool.kind == .executable ? "Programmdatei" : "macOS-App")+"\n\n"+invocations.enumerated().map { "AUFRUF \($0.offset+1)\n"+$0.element.preview(systemDirectory:tool.kind == .application) }.joined(separator:"\n\n") }
}
public struct ExternalToolExecutionResult {
    public let completed:Int,planned:Int
    public let cancelled:Bool
    public let output:String
    public let error:String?
    public var succeeded:Bool { completed == planned && !cancelled && error == nil }
    public init(completed:Int,planned:Int,cancelled:Bool,output:String,error:String?) { self.completed = completed;self.planned = planned;self.cancelled = cancelled;self.output = output;self.error = error }
}

public enum ExternalToolPlanner {
    public static let maximumSelection = 1000,maximumInvocations = 100
    private static func local(_ url:URL) throws -> URL {
        guard url.isFileURL,url.host == nil || url.host == "" || url.host == "localhost",url.path.hasPrefix("/"),!url.path.contains("\0"),url.path.utf8.count <= 16_384 else { throw CommanderError.message("Werkzeuge benötigen lokale Dateipfade; Server- und Archivansichten werden nicht übergeben.") }
        return FileSystem.canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
    }
    private static func observe(_ url:URL,directory:Bool = false) throws -> ExternalToolObservation {
        let value = try RenameVersion.read(url)
        guard directory ? value.isDirectory : value.isDirectory || value.isRegularFile || value.mode & S_IFMT == S_IFLNK else { throw CommanderError.message("Ein Werkzeugpfad ist kein lesbares Dateiobjekt: "+url.lastPathComponent) }
        return ExternalToolObservation(url:url,version:value,directoryIdentityOnly:directory)
    }
    public static func prepare(_ tool:ExternalTool,context:ExternalToolContext,token:CancellationToken = .init()) throws -> ExternalToolPlan {
        try token.check();try tool.validate();guard tool.enabled else { throw CommanderError.message("Dieses Werkzeug ist deaktiviert.") }
        guard context.selection.count <= maximumSelection else { throw CommanderError.message("Höchstens 1.000 lokale Auswahlobjekte an ein Werkzeug übergeben.") }
        let active = try local(context.activeDirectory),inactive = try context.inactiveDirectory.map(local),focused = try context.focused.map(local),selection = try context.selection.map(local)
        guard Set(selection.map(\.path)).count == selection.count else { throw CommanderError.message("Doppelte Werkzeugauswahl.") }
        let target = try local(URL(fileURLWithPath:tool.target)),targetObservation = try observe(target,directory:tool.kind == .application)
        var common = [targetObservation,try observe(active,directory:true)]
        if let inactive { common.append(try observe(inactive,directory:true)) }
        if tool.kind == .executable {
            guard targetObservation.version.isRegularFile,FileManager.default.isExecutableFile(atPath:target.path) else { throw CommanderError.message("Eine ausführbare reguläre Programmdatei auswählen; Verknüpfungen zuerst auflösen.") }
        } else {
            let info = target.appendingPathComponent("Contents/Info.plist"),infoObservation = try observe(info)
            guard infoObservation.version.isRegularFile,infoObservation.version.size <= 1_048_576 else { throw CommanderError.message("Das App-Manifest ist keine begrenzte reguläre Datei.") }
            let fd = open(info.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);guard fd >= 0 else { throw CommanderError.message("Das App-Manifest ist nicht lesbar.") };defer { close(fd) }
            guard try recoveryFDVersion(fd) == infoObservation.version else { throw CommanderError.message("Das App-Manifest wurde ausgetauscht.") }
            let infoData = try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:1_048_577) ?? Data()
            guard infoData.count <= 1_048_576,try recoveryFDVersion(fd) == infoObservation.version,
                  let plist = try PropertyListSerialization.propertyList(from:infoData,format:nil) as? [String:Any],let name = plist["CFBundleExecutable"] as? String,
                  !name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.contains("\0") else { throw CommanderError.message("Die App besitzt keine gültige Programmdatei.") }
            try infoObservation.validate();let executable = target.appendingPathComponent("Contents/MacOS").appendingPathComponent(name),executableObservation = try observe(executable)
            guard executableObservation.version.isRegularFile,FileManager.default.isExecutableFile(atPath:executable.path) else { throw CommanderError.message("Die ausgewählte macOS-App ist nicht ausführbar.") }
            common += [infoObservation,executableObservation,try observe(executable.deletingLastPathComponent(),directory:true)]
        }
        common.append(try observe(target.deletingLastPathComponent(),directory:true))
        let cycles:[URL?]
        if tool.perSelection {
            guard !selection.isEmpty,selection.count <= maximumInvocations else { throw CommanderError.message("Für Einzelaufrufe 1 bis 100 Dateien auswählen.") };cycles = selection.map(Optional.some)
        } else { cycles = [selection.first ?? focused] }
        var calls:[ExternalToolInvocation] = []
        for current in cycles {
            try token.check();var values = ["active":active.path]
            if let inactive { values["inactive"] = inactive.path };if let focused { values["focused"] = focused.path }
            if let current { values["file"] = current.path;values["name"] = current.lastPathComponent;values["stem"] = current.deletingPathExtension().lastPathComponent;values["ext"] = current.pathExtension }
            let lists = ["selection":selection.map(\.path),"names":selection.map(\.lastPathComponent)]
            let arguments = try tool.arguments.flatMap { try ExternalToolTemplate.expand($0,values:values,lists:lists,allowLists:true) }
            guard arguments.count <= 1024,arguments.reduce(0,{ $0+$1.utf8.count+1 }) <= 131_072 else { throw CommanderError.message("Der Werkzeugaufruf überschreitet 1.024 Argumente oder 128 KiB Argumenttext.") }
            let rawDirectory = try ExternalToolTemplate.expand(tool.workingDirectory,values:values,lists:lists,allowLists:false)[0]
            guard rawDirectory.hasPrefix("/") else { throw CommanderError.message("Der expandierte Arbeitsordner muss ein vollständiger lokaler Pfad sein.") }
            let directory = try local(URL(fileURLWithPath:rawDirectory)),directoryObservation = try observe(directory,directory:true)
            var paths:Set<URL> = []
            for text in tool.arguments+[tool.workingDirectory] {
                for part in try ExternalToolTemplate.parse(text,allowLists:text != tool.workingDirectory) {
                    guard case .variable(let name) = part else { continue }
                    if ["selection","names"].contains(name) { paths.formUnion(selection) }
                    if name == "focused",let focused { paths.insert(focused) }
                    if ["file","name","stem","ext"].contains(name),let current { paths.insert(current) }
                }
            }
            let documents: [URL]
            if tool.opensSelection { guard !selection.isEmpty else { throw CommanderError.message("Zum Öffnen mit dieser App lokale Dateien auswählen.") };documents = tool.perSelection ? [current!] : selection;paths.formUnion(documents) } else { documents = [] }
            var observations = [directoryObservation]
            for url in paths.sorted(by:{ $0.path < $1.path }) { observations.append(try observe(url));observations.append(try observe(url.deletingLastPathComponent(),directory:true)) }
            calls.append(ExternalToolInvocation(arguments:arguments,directory:directory,documents:documents,observations:observations))
        }
        let plan = ExternalToolPlan(tool:tool,target:target,invocations:calls,common:common);try validate(plan);return plan
    }
    public static func validate(_ plan:ExternalToolPlan) throws {
        for observation in plan.common { try observation.validate() }
        for call in plan.invocations { for observation in call.observations { try observation.validate() } }
    }
    public static func validate(_ plan:ExternalToolPlan,invocation:Int) throws {
        guard plan.invocations.indices.contains(invocation) else { throw CommanderError.message("Unbekannter Werkzeugaufruf.") }
        for observation in plan.common+plan.invocations[invocation].observations { try observation.validate() }
    }
    public static func execute(_ plan:ExternalToolPlan,token:CancellationToken = .init(),validateExecution:()throws->Void = {},progress:(Int,Int)->Void = { _,_ in }) throws -> ExternalToolExecutionResult {
        guard plan.tool.kind == .executable else { throw CommanderError.message("macOS-Apps über den App-Starter öffnen.") }
        try token.check();try validateExecution();try validate(plan);var output = "",completed = 0,error:String?,cancelled = false
        for index in plan.invocations.indices {
            do {
                try token.check();try validateExecution();try validate(plan,invocation:index)
                let text = try ExternalToolProcess.run(plan,invocation:index,token:token)
                completed += 1;output += "AUFRUF \(index+1)\n"+text+"\n";progress(completed,plan.invocations.count)
                if output.utf8.count > 4_194_304 { output = String(decoding:output.utf8.prefix(4_194_304),as:UTF8.self)+"\n[Gesamtausgabe auf 4 MiB begrenzt]" }
            } catch let failure { cancelled = token.isCancelled;error = failure.localizedDescription;break }
        }
        return ExternalToolExecutionResult(completed:completed,planned:plan.invocations.count,cancelled:cancelled,output:output,error:error)
    }
}
