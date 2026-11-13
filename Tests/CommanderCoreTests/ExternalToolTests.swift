import Foundation
import Darwin
import CommanderCore

private final class ExternalToolTestResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value:Result<ExternalToolExecutionResult,Error>?
    func set(_ value:Result<ExternalToolExecutionResult,Error>) { lock.lock();self.value = value;lock.unlock() }
    func get() -> Result<ExternalToolExecutionResult,Error>? { lock.lock();defer { lock.unlock() };return value }
}

extension CoreTests {
    private func toolFile(_ name:String,_ body:String = "example") throws -> URL { let value = try file(name,body);return FileSystem.canonical(value.deletingLastPathComponent()).appendingPathComponent(value.lastPathComponent) }
    private func toolFolder(_ name:String) throws -> URL { FileSystem.canonical(try folder(name)) }
    private func tool(_ arguments:[String] = []) -> ExternalTool { ExternalTool(title:"Prüfwerkzeug",target:"/usr/bin/printf",arguments:arguments) }
    private func context(_ selection:[URL] = [],focused:URL? = nil,inactive:URL? = nil) -> ExternalToolContext { ExternalToolContext(activeDirectory:root,inactiveDirectory:inactive,focused:focused,selection:selection) }
    private func script(_ name:String = "Programm",_ body:String) throws -> URL { let url = try toolFile(name,"#!/bin/sh\n"+body+"\n");try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.path);return url }
    private func app() throws -> URL { let url = try toolFolder("Test.app/Contents/MacOS").deletingLastPathComponent().deletingLastPathComponent();let executable = try script("Test.app/Contents/MacOS/Start","exit 0");let plist:[String:Any] = ["CFBundleExecutable":executable.lastPathComponent,"CFBundleIdentifier":"local.zweicommander.synthetic.tool","CFBundlePackageType":"APPL"];try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0).write(to:url.appendingPathComponent("Contents/Info.plist"));return url }
    func testExternalToolsRoundTripPreservesIdentityOrderAndCategories() throws {
        var a = tool(["{file}"]),b = tool(["{active}"]);a.category = "Text";a.shortcutSlot = 3;a.showInToolbar = true;b.title = "Zweites Werkzeug";b.enabled = false
        var library = ExternalToolLibrary(tools:[a,b]);library.move(b.id,by:-1)
        let restored = try ExternalToolLibrary.decode(library.encoded());XCTAssertEqual(restored,library);XCTAssertEqual(restored.tools.map(\.id),[b.id,a.id]);XCTAssertEqual(restored.tools.last?.shortcutSlot,3)
    }
    func testExternalToolsRejectFutureCorruptAndUnknownFields() throws {
        let good = try ExternalToolLibrary(tools:[tool()]).encoded();var object = try JSONSerialization.jsonObject(with:good) as! [String:Any]
        object["version"] = 2;XCTAssertThrowsError(try ExternalToolLibrary.decode(JSONSerialization.data(withJSONObject:object)))
        object["version"] = 1;object["future"] = true;XCTAssertThrowsError(try ExternalToolLibrary.decode(JSONSerialization.data(withJSONObject:object)))
        object.removeValue(forKey:"future");var records = object["tools"] as! [[String:Any]];records[0]["password"] = "synthetic";object["tools"] = records;XCTAssertThrowsError(try ExternalToolLibrary.decode(JSONSerialization.data(withJSONObject:object)))
        XCTAssertThrowsError(try ExternalToolLibrary.decode(Data("{broken".utf8)));XCTAssertThrowsError(try ExternalToolLibrary.decode(Data(good.dropLast())))
    }
    func testExternalToolsRejectDuplicateAndEscapedJSONKeys() throws {
        XCTAssertThrowsError(try ExternalToolLibrary.decode(Data("{\"version\":1,\"version\":1,\"tools\":[]}".utf8)))
        XCTAssertThrowsError(try ExternalToolLibrary.decode(Data("{\"version\":1,\"ver\\u0073ion\":1,\"tools\":[]}".utf8)))
        let good = String(decoding:try ExternalToolLibrary(tools:[tool()]).encoded(),as:UTF8.self)
        let duplicate = good.replacingOccurrences(of:"\"enabled\" : true",with:"\"enabled\":true,\"enabled\":false")
        XCTAssertTrue(duplicate != good);XCTAssertThrowsError(try ExternalToolLibrary.decode(Data(duplicate.utf8)))
    }
    func testExternalToolsRejectUnsupportedJSONEncodingAndDeepDocuments() throws {
        let text = "{\"version\":1,\"tools\":[]}";XCTAssertThrowsError(try ExternalToolLibrary.decode(text.data(using:.utf16)!))
        XCTAssertThrowsError(try ExternalToolLibrary.decode(Data([0xef,0xbb,0xbf])+Data(text.utf8)))
        XCTAssertThrowsError(try ExternalToolLibrary.decode(Data("{\"version\":1,\"tools\":[] ,\"x\": [[[[[[[[[[0]]]]]]]]]]}".utf8)))
        XCTAssertThrowsError(try ExternalToolLibrary.decode(Data(repeating:32,count:1_048_577)))
    }
    func testExternalToolsValidateUniqueIDsAndSlotsWithoutChangingLibrary() throws {
        let a = tool();var b = a;b.title = "B";XCTAssertThrowsError(try ExternalToolLibrary(tools:[a,b]).encoded())
        b.id = UUID();var first = a;first.shortcutSlot = 2;b.shortcutSlot = 2
        var library = ExternalToolLibrary(tools:[first]);let before = library
        XCTAssertThrowsError(try library.put(b));XCTAssertEqual(library,before)
        b.shortcutSlot = 10;XCTAssertThrowsError(try b.validate())
        library.move(first.id,by:Int.min);XCTAssertEqual(library,before)
    }
    func testExternalToolsValidateDefinitionLimitsAndAbsoluteTargets() throws {
        var value = tool();value.target = "printf";XCTAssertThrowsError(try value.validate());value.target = "/tmp/../tmp/tool";XCTAssertThrowsError(try value.validate())
        value = tool();value.title = "Bad\nName";XCTAssertThrowsError(try value.validate());value = tool();value.title = String(repeating:"é",count:121);XCTAssertThrowsError(try value.validate())
        value = tool();value.arguments = Array(repeating:"a",count:129);XCTAssertThrowsError(try value.validate());value = tool();value.arguments = [String(repeating:"a",count:8193)];XCTAssertThrowsError(try value.validate())
        value = tool();value.timeoutSeconds = 0;XCTAssertThrowsError(try value.validate());value.timeoutSeconds = 3601;XCTAssertThrowsError(try value.validate())
        XCTAssertThrowsError(try ExternalToolLibrary(tools:(0...100).map { ExternalTool(title:String($0),target:"/bin/echo") }).encoded())
    }
    func testExternalToolsPreserveLiteralArgumentsWithoutShellExpansion() throws {
        let literals = ["two words","\"quoted\"","'single'","$HOME","$(echo surprise)","`echo surprise`","*?.txt","Grüße 🍎","line\nbreak","", "  padded  "]
        let plan = try ExternalToolPlanner.prepare(tool(literals),context:context());XCTAssertEqual(plan.invocations[0].arguments,literals)
    }
    func testExternalToolsExpandDirectoryFocusedAndFileVariablesIndependently() throws {
        let chosen = try toolFile("Foto Grüße.txt"),focus = try toolFile("Anderer.md"),other = try toolFolder("Gegenseite")
        let plan = try ExternalToolPlanner.prepare(tool(["{active}","{inactive}","{focused}","{file}","{name}","{stem}","{ext}","prefix={name}"]),context:context([chosen],focused:focus,inactive:other))
        XCTAssertEqual(plan.invocations[0].arguments,[FileSystem.canonical(root).path,other.path,focus.path,chosen.path,chosen.lastPathComponent,"Foto Grüße","txt","prefix=Foto Grüße.txt"])
    }
    func testExternalToolsExpandSelectionAsSeparateArgumentsInGivenOrder() throws {
        let a = try toolFile("Grüße one.txt"),b = try toolFile("two'quote.txt")
        let plan = try ExternalToolPlanner.prepare(tool(["before","{selection}","between","{names}","after"]),context:context([b,a]))
        XCTAssertEqual(plan.invocations[0].arguments,["before",b.path,a.path,"between",b.lastPathComponent,a.lastPathComponent,"after"])
        let empty = try ExternalToolPlanner.prepare(tool(["before","{selection}","after"]),context:context());XCTAssertEqual(empty.invocations[0].arguments,["before","after"])
    }
    func testExternalToolsRejectListInterpolationAndUnknownVariables() throws {
        for text in ["prefix={selection}","{names}.txt","{unknown}","unterminated {file","bad }", "{Selection}"] { XCTAssertThrowsError(try tool([text]).validate()) }
        var value = tool();value.workingDirectory = "{selection}";XCTAssertThrowsError(try value.validate())
        XCTAssertThrowsError(try ExternalToolPlanner.prepare(tool(["{inactive}"]),context:context()))
        XCTAssertThrowsError(try ExternalToolPlanner.prepare(tool(["{file}"]),context:context()))
    }
    func testExternalToolsEscapeBracesAndPreserveZeroArguments() throws {
        let plan = try ExternalToolPlanner.prepare(tool(["{{literal}}","{{file}}","a}}b{{c"]),context:context());XCTAssertEqual(plan.invocations[0].arguments,["{literal}","{file}","a}b{c"])
        XCTAssertEqual(try ExternalToolPlanner.prepare(tool(),context:context()).invocations[0].arguments,[])
    }
    func testExternalToolArgumentLinesRoundTripNewlinesAndEmptyArguments() throws {
        let values = ["","a\nb","a\rb","a\tb","\\n","  spaced  ","\"quoted\"","é🍎"]
        XCTAssertEqual(try ExternalToolArgumentLines.decode(ExternalToolArgumentLines.encode(values)),values)
        XCTAssertEqual(try ExternalToolArgumentLines.decode(""),[])
        XCTAssertThrowsError(try ExternalToolArgumentLines.decode("bad\\q"));XCTAssertThrowsError(try ExternalToolArgumentLines.decode("bad\\"));XCTAssertThrowsError(try ExternalToolArgumentLines.decode("a\0b"))
    }
    func testExternalToolsPerSelectionUsesOneFilePerInvocation() throws {
        let a = try toolFile("A.txt"),b = try toolFile("B.md");var value = tool(["{file}","{name}","{focused}"]);value.perSelection = true
        let plan = try ExternalToolPlanner.prepare(value,context:context([b,a],focused:a));XCTAssertEqual(plan.invocations.count,2);XCTAssertEqual(plan.invocations[0].arguments,[b.path,"B.md",a.path]);XCTAssertEqual(plan.invocations[1].arguments,[a.path,"A.txt",a.path])
    }
    func testExternalToolsPerSelectionRequiresBoundedNonemptySelection() throws {
        var value = tool();value.perSelection = true;XCTAssertThrowsError(try ExternalToolPlanner.prepare(value,context:context()))
        let files = try (0...100).map { try toolFile("Many/\($0)") };XCTAssertThrowsError(try ExternalToolPlanner.prepare(value,context:context(files)))
    }
    func testExternalToolsRejectDuplicateSelectionsAndVirtualURLs() throws {
        let a = try toolFile("A");XCTAssertThrowsError(try ExternalToolPlanner.prepare(tool(),context:context([a,a])))
        XCTAssertThrowsError(try ExternalToolPlanner.prepare(tool(),context:context([URL(string:"remote:/file")!])))
        XCTAssertThrowsError(try ExternalToolPlanner.prepare(tool(),context:ExternalToolContext(activeDirectory:URL(string:"archive:/file")!)))
        var foreign = URLComponents();foreign.scheme = "file";foreign.host = "server.invalid";foreign.path = root.path
        XCTAssertThrowsError(try ExternalToolPlanner.prepare(tool(),context:ExternalToolContext(activeDirectory:foreign.url!)))
        var value = tool();value.enabled = false;XCTAssertThrowsError(try ExternalToolPlanner.prepare(value,context:context()))
    }
    func testExternalToolsRejectMissingNonExecutableAndSymlinkPrograms() throws {
        var value = tool();value.target = root.appendingPathComponent("Missing").path;XCTAssertThrowsError(try ExternalToolPlanner.prepare(value,context:context()))
        let plain = try toolFile("Plain","text");value.target = plain.path;XCTAssertThrowsError(try ExternalToolPlanner.prepare(value,context:context()))
        let alias = root.appendingPathComponent("Alias");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:URL(fileURLWithPath:"/usr/bin/printf"));value.target = alias.path;XCTAssertThrowsError(try ExternalToolPlanner.prepare(value,context:context()))
    }
    func testExternalToolsRejectSpecialInputsWithoutOpeningThem() throws {
        let fifo = root.appendingPathComponent("Pipe");XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        XCTAssertThrowsError(try ExternalToolPlanner.prepare(tool(["{selection}"]),context:context([fifo])))
    }
    func testExternalToolsExpandAndValidateWorkingDirectory() throws {
        let other = try toolFolder("Folder with spaces");var value = tool();value.workingDirectory = "{inactive}"
        XCTAssertEqual(try ExternalToolPlanner.prepare(value,context:context(inactive:other)).invocations[0].directory.path,other.path)
        value.workingDirectory = "relative";XCTAssertThrowsError(try ExternalToolPlanner.prepare(value,context:context()))
        value.workingDirectory = root.appendingPathComponent("Missing").path;XCTAssertThrowsError(try ExternalToolPlanner.prepare(value,context:context()))
    }
    func testExternalToolsRejectExpandedArgumentsBeyondProcessBudget() throws {
        let value = tool(Array(repeating:String(repeating:"x",count:2048),count:128));try value.validate();XCTAssertThrowsError(try ExternalToolPlanner.prepare(value,context:context()))
        let files = try (0..<513).map { try toolFile("Many/\($0)") };XCTAssertThrowsError(try ExternalToolPlanner.prepare(tool(["{selection}","{selection}"]),context:context(files)))
    }
    func testExternalToolsSourceReplacementInvalidatesWholePlanBeforeLaunch() throws {
        let marker = root.appendingPathComponent("Started"),program = try script("Runner","/usr/bin/touch \"$1\""),source = try toolFile("Input","first")
        var value = ExternalTool(title:"Guard",target:program.path,arguments:[marker.path,"{file}"]);value.perSelection = true
        let plan = try ExternalToolPlanner.prepare(value,context:context([source]));try FileManager.default.removeItem(at:source);try Data("other".utf8).write(to:source)
        XCTAssertThrowsError(try ExternalToolPlanner.execute(plan));XCTAssertFalse(FileSystem.exists(marker))
    }
    func testExternalToolsChangedProgramInvalidatesFrozenPreview() throws {
        let executable = try script("Runner","exit 0"),plan = try ExternalToolPlanner.prepare(ExternalTool(title:"Guard",target:executable.path),context:context())
        try Data("#!/bin/sh\nexit 2\n".utf8).write(to:executable);XCTAssertThrowsError(try ExternalToolPlanner.validate(plan))
    }
    func testExternalToolsWorkingParentReplacementIsDetected() throws {
        let current = try toolFolder("Current"),context = ExternalToolContext(activeDirectory:current),plan = try ExternalToolPlanner.prepare(tool(),context:context)
        try FileManager.default.moveItem(at:current,to:root.appendingPathComponent("Moved"));try FileManager.default.createSymbolicLink(at:current,withDestinationURL:root.appendingPathComponent("Moved"));XCTAssertThrowsError(try ExternalToolPlanner.validate(plan))
    }
    func testExternalToolsExecutableReceivesExactArgumentsAndWorkingDirectory() throws {
        let directory = try toolFolder("Working space"),executable = try script("Inspect","/usr/bin/printf 'cwd=%s\\n' \"$PWD\"\n/usr/bin/printf '%s\\0' \"$@\""),outside = root.appendingPathComponent("Never created")
        let arguments = ["two words","\"quotes\"","line\nbreak","Grüße 🍎","","; /usr/bin/touch "+outside.path,"$(/usr/bin/touch "+outside.path+")"]
        var value = ExternalTool(title:"Inspect",target:executable.path,arguments:arguments);value.workingDirectory = directory.path
        let result = try ExternalToolPlanner.execute(ExternalToolPlanner.prepare(value,context:context()))
        let expected = "AUFRUF 1\ncwd="+directory.path+"\n"+arguments.joined(separator:"\0")+"\0\n"
        XCTAssertTrue(result.succeeded);XCTAssertEqual(Array(result.output.utf8),Array(expected.utf8));XCTAssertFalse(FileSystem.exists(outside))
    }
    func testExternalToolsNonzeroExitStopsLaterInvocationsAndReportsPartialWork() throws {
        let a = try toolFile("First"),b = try toolFile("Fail"),c = try toolFile("Last"),log = root.appendingPathComponent("Log"),executable = try script("Runner","if [ \"$1\" = Fail ]; then /usr/bin/printf 'failure details'; exit 7; fi\n/usr/bin/printf '%s\\n' \"$1\" >> \"$2\"")
        var value = ExternalTool(title:"Partial",target:executable.path,arguments:["{name}",log.path]);value.perSelection = true
        let result = try ExternalToolPlanner.execute(ExternalToolPlanner.prepare(value,context:context([a,b,c])))
        XCTAssertEqual(result.completed,1);XCTAssertEqual(result.planned,3);XCTAssertFalse(result.succeeded);XCTAssertTrue(result.error?.contains("7") == true);XCTAssertTrue(result.output.contains("failure details"));XCTAssertEqual(try read(log),"First\n")
    }
    func testExternalToolsOwnFirstFileChangesDoNotInvalidateIndependentLaterCalls() throws {
        let a = try toolFile("A"),b = try toolFile("B"),executable = try script("Runner","/usr/bin/printf changed >> \"$1\"")
        var value = ExternalTool(title:"Change",target:executable.path,arguments:["{file}"]);value.perSelection = true
        let result = try ExternalToolPlanner.execute(ExternalToolPlanner.prepare(value,context:context([a,b])))
        XCTAssertTrue(result.succeeded);XCTAssertEqual(result.completed,2);XCTAssertEqual(try read(a),"examplechanged");XCTAssertEqual(try read(b),"examplechanged")
    }
    func testExternalToolsAllPlannedInputsAreCheckedBeforeAnyInvocation() throws {
        let a = try toolFile("A"),b = try toolFile("B"),log = root.appendingPathComponent("Log"),executable = try script("Runner","/usr/bin/printf started >> \"$1\"")
        var value = ExternalTool(title:"Guard",target:executable.path,arguments:[log.path,"{file}"]);value.perSelection = true
        let plan = try ExternalToolPlanner.prepare(value,context:context([a,b]));try FileManager.default.removeItem(at:b)
        XCTAssertThrowsError(try ExternalToolPlanner.execute(plan));XCTAssertFalse(FileSystem.exists(log))
    }
    func testExternalToolsCancellationBeforeLaunchPreservesFiles() throws {
        let token = CancellationToken(),marker = root.appendingPathComponent("Marker"),executable = try script("Runner","/usr/bin/touch \"$1\"")
        let plan = try ExternalToolPlanner.prepare(ExternalTool(title:"Cancel",target:executable.path,arguments:[marker.path]),context:context());token.cancel()
        XCTAssertThrowsError(try ExternalToolPlanner.execute(plan,token:token));XCTAssertFalse(FileSystem.exists(marker))
    }
    func testExternalToolsCancellationStopsRunningProcess() throws {
        let executable = try script("Runner","exec /bin/sleep 5"),plan = try ExternalToolPlanner.prepare(ExternalTool(title:"Cancel",target:executable.path),context:context()),token = CancellationToken(),started = Date()
        DispatchQueue.global().asyncAfter(deadline:.now()+0.25) { token.cancel() }
        let result = try ExternalToolPlanner.execute(plan,token:token);XCTAssertTrue(result.cancelled);XCTAssertEqual(result.completed,0);XCTAssertTrue(Date().timeIntervalSince(started) < 4)
    }
    func testExternalToolsTimeoutStopsRunningProcess() throws {
        let executable = try script("Runner","exec /bin/sleep 4");var value = ExternalTool(title:"Timeout",target:executable.path);value.timeoutSeconds = 1
        let started = Date(),result = try ExternalToolPlanner.execute(ExternalToolPlanner.prepare(value,context:context()))
        XCTAssertFalse(result.succeeded);XCTAssertTrue(result.error?.contains("Zeitlimit") == true);XCTAssertTrue(Date().timeIntervalSince(started) < 3.5)
    }
    func testExternalToolsApplicationDocumentsAndArgumentsStaySeparate() throws {
        let application = try app(),a = try toolFile("Document one.txt"),b = try toolFile("Document two.txt")
        let value = ExternalTool(title:"App",kind:.application,target:application.path,arguments:["--mode","two words"],opensSelection:true)
        let plan = try ExternalToolPlanner.prepare(value,context:context([b,a]));XCTAssertEqual(plan.invocations[0].documents.map(\.path),[b.path,a.path]);XCTAssertEqual(plan.invocations[0].arguments,["--mode","two words"])
        XCTAssertTrue(plan.preview.contains("von macOS verwaltet"));XCTAssertThrowsError(try ExternalToolPlanner.execute(plan))
    }
    func testExternalToolsRejectApplicationWorkingDirectoryAndMissingDocuments() throws {
        let application = try app();var value = ExternalTool(title:"App",kind:.application,target:application.path,workingDirectory:"/tmp");XCTAssertThrowsError(try value.validate())
        value.workingDirectory = "{active}";value.opensSelection = true;XCTAssertThrowsError(try ExternalToolPlanner.prepare(value,context:context()))
        value.kind = .executable;XCTAssertThrowsError(try value.validate())
    }
    func testExternalToolsChangedApplicationManifestInvalidatesPreview() throws {
        let application = try app(),value = ExternalTool(title:"App",kind:.application,target:application.path),plan = try ExternalToolPlanner.prepare(value,context:context())
        let info = application.appendingPathComponent("Contents/Info.plist");try Data("changed".utf8).write(to:info);XCTAssertThrowsError(try ExternalToolPlanner.validate(plan))
    }
    func testExternalToolsPerDocumentApplicationPreviewIsFrozen() throws {
        let application = try app(),a = try toolFile("A"),b = try toolFile("B");var value = ExternalTool(title:"App",kind:.application,target:application.path,opensSelection:true);value.perSelection = true
        let plan = try ExternalToolPlanner.prepare(value,context:context([a,b]));XCTAssertEqual(plan.invocations.map { $0.documents.map(\.path) },[[a.path],[b.path]])
        try Data("changed".utf8).write(to:b);XCTAssertThrowsError(try ExternalToolPlanner.validate(plan))
    }
    func testExternalToolsProgramChangedBetweenInvocationsStopsLaterLaunches() throws {
        let a = try toolFile("A"),b = try toolFile("B"),log = root.appendingPathComponent("Log"),executable = try script("Runner","/usr/bin/printf '%s\\n' \"$1\" >> \"$2\"")
        var value = ExternalTool(title:"Guard",target:executable.path,arguments:["{name}",log.path]);value.perSelection = true
        let plan = try ExternalToolPlanner.prepare(value,context:context([a,b]))
        let result = try ExternalToolPlanner.execute(plan,progress:{ completed,_ in if completed == 1 { try? Data("#!/bin/sh\nexit 9\n".utf8).write(to:executable) } })
        XCTAssertEqual(result.completed,1);XCTAssertEqual(result.planned,2);XCTAssertFalse(result.succeeded);XCTAssertEqual(try read(log),"A\n")
    }
    func testExternalToolsReplacedProgramParentCannotLaunchForeignProgram() throws {
        let executable = try script("Tools/Runner","exit 0"),marker = root.appendingPathComponent("Foreign started"),plan = try ExternalToolPlanner.prepare(ExternalTool(title:"Guard",target:executable.path,arguments:[marker.path]),context:context())
        try FileManager.default.moveItem(at:executable.deletingLastPathComponent(),to:root.appendingPathComponent("Original tools"))
        _ = try script("Tools/Runner","/usr/bin/touch \"$1\"")
        XCTAssertThrowsError(try ExternalToolPlanner.execute(plan));XCTAssertFalse(FileSystem.exists(marker))
    }
    func testExternalToolsChangedDefinitionCheckPreventsAnyExecution() throws {
        let marker = root.appendingPathComponent("Marker"),executable = try script("Runner","/usr/bin/touch \"$1\""),plan = try ExternalToolPlanner.prepare(ExternalTool(title:"Guard",target:executable.path,arguments:[marker.path]),context:context())
        XCTAssertThrowsError(try ExternalToolPlanner.execute(plan,validateExecution:{ throw CommanderError.message("Definition changed") }));XCTAssertFalse(FileSystem.exists(marker))
    }
    func testExternalToolsCancellationTerminatesInheritedChildProcessGroup() throws {
        let marker = root.appendingPathComponent("Child finished"),executable = try script("Runner","(/bin/sleep 1; /usr/bin/touch \"$1\") &\nwait"),token = CancellationToken(),plan = try ExternalToolPlanner.prepare(ExternalTool(title:"Cancel group",target:executable.path,arguments:[marker.path]),context:context())
        DispatchQueue.global().asyncAfter(deadline:.now()+0.2) { token.cancel() }
        let result = try ExternalToolPlanner.execute(plan,token:token);Thread.sleep(forTimeInterval:1.1)
        XCTAssertTrue(result.cancelled);XCTAssertFalse(FileSystem.exists(marker))
    }
    func testExternalToolsPauseStopsChildGroupAndDoesNotConsumeTimeout() throws {
        let log = root.appendingPathComponent("Progress"),executable = try script("Runner","/usr/bin/printf started > \"$1\"\n/bin/sleep 0.5\n/usr/bin/printf finished >> \"$1\"")
        var value = ExternalTool(title:"Pause",target:executable.path,arguments:[log.path]);value.timeoutSeconds = 1
        let plan = try ExternalToolPlanner.prepare(value,context:context()),token = CancellationToken(),box = ExternalToolTestResultBox(),group = DispatchGroup();group.enter()
        DispatchQueue.global().async { box.set(Result { try ExternalToolPlanner.execute(plan,token:token) });group.leave() }
        let startDeadline = Date().addingTimeInterval(2);while !FileSystem.exists(log),Date() < startDeadline { Thread.sleep(forTimeInterval:0.01) };token.pause()
        let pauseDeadline = Date().addingTimeInterval(2);while !token.isWaitingForResume,Date() < pauseDeadline { Thread.sleep(forTimeInterval:0.01) }
        XCTAssertTrue(token.isWaitingForResume);let before = try read(log);Thread.sleep(forTimeInterval:1.1);XCTAssertEqual(try read(log),before);token.resume()
        XCTAssertEqual(group.wait(timeout:.now()+3),.success);let result = try box.get()?.get();XCTAssertTrue(result?.succeeded == true);XCTAssertEqual(try read(log),"startedfinished")
    }
    func testExternalToolsCancellationWhilePausedDoesNotLeaveWaitingProcess() throws {
        let executable = try script("Runner","exec /bin/sleep 5"),plan = try ExternalToolPlanner.prepare(ExternalTool(title:"Pause cancel",target:executable.path),context:context()),token = CancellationToken(),box = ExternalToolTestResultBox(),group = DispatchGroup();group.enter()
        DispatchQueue.global().async { box.set(Result { try ExternalToolPlanner.execute(plan,token:token) });group.leave() }
        Thread.sleep(forTimeInterval:0.1);token.pause();let deadline = Date().addingTimeInterval(2);while !token.isWaitingForResume,Date() < deadline { Thread.sleep(forTimeInterval:0.01) }
        XCTAssertTrue(token.isWaitingForResume);token.cancel();XCTAssertEqual(group.wait(timeout:.now()+2),.success);XCTAssertTrue(try box.get()?.get().cancelled == true)
    }
    func testExternalToolsDoNotInheritUnrelatedApplicationDescriptors() throws {
        let source = try toolFile("Private descriptor"),fd = open(source.path,O_RDONLY);XCTAssertTrue(fd >= 0);defer { close(fd) }
        let inherited = fcntl(fd,F_DUPFD,200);XCTAssertTrue(inherited >= 200);defer { close(inherited) }
        let executable = try script("Runner","if [ -e /dev/fd/\"$1\" ]; then /usr/bin/printf leaked; else /usr/bin/printf closed; fi")
        let plan = try ExternalToolPlanner.prepare(ExternalTool(title:"Descriptor check",target:executable.path,arguments:[String(inherited)]),context:context())
        let result = try ExternalToolPlanner.execute(plan);XCTAssertTrue(result.succeeded);XCTAssertTrue(result.output.contains("closed"));XCTAssertFalse(result.output.contains("leaked"))
    }
    func testExternalToolsWaitForInheritedOutputAfterDirectChildExit() throws {
        let executable = try script("Runner","(/bin/sleep 0.2; /usr/bin/printf 'late descendant output') &\nexit 0"),plan = try ExternalToolPlanner.prepare(ExternalTool(title:"Late output",target:executable.path),context:context()),started = Date()
        let result = try ExternalToolPlanner.execute(plan)
        XCTAssertTrue(result.succeeded);XCTAssertTrue(result.output.contains("late descendant output"));XCTAssertTrue(Date().timeIntervalSince(started) >= 0.15)
    }
    func testExternalToolsBoundLateDescendantOutputAndStopItsProcessGroup() throws {
        let marker = root.appendingPathComponent("Wrote 64 MiB"),executable = try script("Runner","(/bin/sleep 0.2; /bin/dd if=/dev/zero bs=1048576 count=64 2>/dev/null; /usr/bin/touch \"$1\") &\nexit 0")
        var value = ExternalTool(title:"Bound output",target:executable.path,arguments:[marker.path]);value.timeoutSeconds = 20
        let result = try ExternalToolPlanner.execute(ExternalToolPlanner.prepare(value,context:context()));Thread.sleep(forTimeInterval:0.2)
        XCTAssertFalse(result.succeeded);XCTAssertEqual(result.completed,0);XCTAssertTrue(result.error?.contains("32 MiB") == true);XCTAssertTrue(result.output.utf8.count <= 4*1024*1024+100);XCTAssertTrue((result.error?.utf8.count ?? 0) < 200);XCTAssertFalse(FileSystem.exists(marker))
    }
    func testExternalToolsHeldCapturePipeStillHonorsTimeoutAfterParentExit() throws {
        let executable = try script("Runner","(/bin/sleep 5) &\nexit 0");var value = ExternalTool(title:"Held output",target:executable.path);value.timeoutSeconds = 1
        let started = Date(),result = try ExternalToolPlanner.execute(ExternalToolPlanner.prepare(value,context:context()))
        XCTAssertFalse(result.succeeded);XCTAssertEqual(result.completed,0);XCTAssertTrue(result.error?.contains("Zeitlimit") == true);XCTAssertTrue(Date().timeIntervalSince(started) < 3)
    }
    func testExternalToolsHeldCapturePipeCanBeCancelledAfterParentExit() throws {
        let marker = root.appendingPathComponent("Child escaped"),executable = try script("Runner","(/bin/sleep 1; /usr/bin/touch \"$1\") &\nexit 0"),token = CancellationToken(),plan = try ExternalToolPlanner.prepare(ExternalTool(title:"Cancel orphan",target:executable.path,arguments:[marker.path]),context:context())
        DispatchQueue.global().asyncAfter(deadline:.now()+0.2) { token.cancel() }
        let result = try ExternalToolPlanner.execute(plan,token:token);Thread.sleep(forTimeInterval:1.1)
        XCTAssertTrue(result.cancelled);XCTAssertEqual(result.completed,0);XCTAssertFalse(FileSystem.exists(marker))
    }
    func testExternalToolsExplicitlyRedirectedBackgroundWorkDoesNotHoldCapture() throws {
        let marker = root.appendingPathComponent("Redirected child finished"),executable = try script("Runner","(/bin/sleep 1; /usr/bin/touch \"$1\") >/dev/null 2>&1 &\nexit 0")
        let result = try ExternalToolPlanner.execute(ExternalToolPlanner.prepare(ExternalTool(title:"Redirected background",target:executable.path,arguments:[marker.path]),context:context()))
        XCTAssertTrue(result.succeeded);XCTAssertFalse(FileSystem.exists(marker));Thread.sleep(forTimeInterval:1.2);XCTAssertTrue(FileSystem.exists(marker))
    }
    func testExternalToolsClosedCaptureDoesNotMaskLaterDirectChildFailure() throws {
        let executable = try script("Runner","exec >/dev/null 2>&1\n/bin/sleep 0.2\nexit 7"),started = Date()
        let result = try ExternalToolPlanner.execute(ExternalToolPlanner.prepare(ExternalTool(title:"Closed capture",target:executable.path),context:context()))
        XCTAssertFalse(result.succeeded);XCTAssertEqual(result.completed,0);XCTAssertTrue(result.error?.contains("7") == true);XCTAssertTrue(Date().timeIntervalSince(started) >= 0.15)
    }
    func testExternalToolsDetachedCaptureWriterCannotRetainUnboundedOutputOrHang() throws {
        let pidFile = root.appendingPathComponent("Detached child pid"),executable = try script("Runner","/usr/bin/python3 -c 'import os,sys,time; os.setsid(); open(sys.argv[1],\"w\").write(str(os.getpid())); time.sleep(30)' \"$1\" &\nexit 0")
        var value = ExternalTool(title:"Detached capture",target:executable.path,arguments:[pidFile.path]);value.timeoutSeconds = 1
        let started = Date(),result = try ExternalToolPlanner.execute(ExternalToolPlanner.prepare(value,context:context()))
        if let pid = Int32(try read(pidFile)),getpgid(pid) == pid { defer { kill(pid,SIGKILL) };XCTAssertFalse(result.succeeded);XCTAssertTrue(result.error?.contains("Zeitlimit") == true);XCTAssertTrue(Date().timeIntervalSince(started) < 4) }
        else { throw CommanderError.message("Detached fixture process did not report its identity") }
    }
}
