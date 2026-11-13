import Foundation
import Darwin
import CryptoKit
import CommanderCore

extension CoreTests {
    private func processScript(_ body:String) throws -> URL { let path = try file("Process-"+UUID().uuidString,"#!/bin/sh\n"+body+"\n");XCTAssertEqual(chmod(path.path,0o700),0);return path }
    private func processFailure(_ body:()throws->String) -> Error? { do { _ = try body();return nil } catch { return error } }
    private func processPhysicalPath(_ url:URL) throws -> String { var path = [CChar](repeating:0,count:Int(MAXPATHLEN));guard realpath(url.path,&path) != nil else { throw CommanderError.message("Physical test path is unavailable") };return String(cString:path) }
    func testProcessRunnerPreservesUTF8ArgumentsThroughLegacyAPI() throws {
        let values = ["Grüße 🍎","line\nbreak","two words","","$HOME","`literal`"]
        let output = try ProcessRunner.run("/usr/bin/printf",arguments:["%s\\0"]+values)
        XCTAssertEqual(Array(output.utf8),Array((values.joined(separator:"\0")+"\0").utf8))
    }
    func testProcessRunnerBinaryAndUnicodeInputRoundTripsAsExactBytes() throws {
        let input = Data((0...255).map(UInt8.init))+Data("Grüße 🍎\n\0end".utf8)
        let output = try ProcessRunner.run("/usr/bin/base64",arguments:[],input:input)
        XCTAssertEqual(output.components(separatedBy:.whitespacesAndNewlines).joined(),input.base64EncodedString())
    }
    func testProcessRunnerNilAndEmptyInputBothDeliverEOF() throws {
        for input in [Optional<Data>.none,Data()] {
            let output = try ProcessRunner.run("/usr/bin/wc",arguments:["-c"],input:input,timeout:2)
            XCTAssertEqual(output.trimmingCharacters(in:.whitespacesAndNewlines),"0")
        }
    }
    func testProcessRunnerLargeInputAndOutputBeforeReadingCannotDeadlock() throws {
        let input = Data(repeating:123,count:3*1024*1024)+Data("Unicode Grüße\n".utf8)
        let program = "import sys,hashlib; sys.stdout.buffer.write(b'x'*262144); sys.stdout.flush(); data=sys.stdin.buffer.read(); print('\\nbytes='+str(len(data))); print('sha256='+hashlib.sha256(data).hexdigest())"
        let output = try ProcessRunner.run("/usr/bin/python3",arguments:["-c",program],input:input,timeout:10)
        let digest = SHA256.hash(data:input).map { String(format:"%02x",$0) }.joined()
        XCTAssertTrue(output.hasPrefix(String(repeating:"x",count:262144)));XCTAssertTrue(output.contains("bytes=\(input.count)"));XCTAssertTrue(output.contains("sha256="+digest))
    }
    func testProcessRunnerInputEOFIsClosedAfterAllBytesWereTransferred() throws {
        let input = Data(repeating:65,count:2*1024*1024),output = try ProcessRunner.run("/usr/bin/python3",arguments:["-c","import sys; data=sys.stdin.buffer.read(); print(len(data)); print('EOF')"],input:input,timeout:10)
        XCTAssertEqual(output,"2097152\nEOF\n")
    }
    func testProcessRunnerCancellationWhileStdinBackpressuresIsResponsive() throws {
        let input = Data(repeating:65,count:8*1024*1024),token = CancellationToken(),program = try processScript("/usr/bin/printf started\nexec /bin/sleep 5"),started = Date()
        DispatchQueue.global().asyncAfter(deadline:.now()+0.2) { token.cancel() }
        let error = processFailure { try ProcessRunner.run(program.path,arguments:[],input:input,token:token,timeout:10) }
        if let error,case CommanderError.cancelled = error { XCTAssertTrue(true) } else { XCTAssertTrue(false,"Cancellation was not preserved through the legacy API") }
        XCTAssertTrue(Date().timeIntervalSince(started) < 3)
    }
    func testProcessRunnerTimeoutWhileStdinBackpressuresIsResponsive() throws {
        let input = Data(repeating:65,count:8*1024*1024),program = try processScript("exec /bin/sleep 5"),started = Date()
        let error = processFailure { try ProcessRunner.run(program.path,arguments:[],input:input,timeout:0.25) }
        XCTAssertTrue(error?.localizedDescription.contains("Zeitlimit") == true);XCTAssertTrue(Date().timeIntervalSince(started) < 3)
    }
    func testProcessRunnerEarlyInputCloseThrowsWithoutSIGPIPEOrDeadlock() throws {
        let input = Data(repeating:65,count:8*1024*1024),program = try processScript("exec 0<&-\nexit 0"),started = Date()
        let error = processFailure { try ProcessRunner.run(program.path,arguments:[],input:input,timeout:2) }
        XCTAssertTrue(error?.localizedDescription.contains("Standardeingabe") == true);XCTAssertTrue(Date().timeIntervalSince(started) < 2)
        XCTAssertEqual(try ProcessRunner.run("/usr/bin/printf",arguments:["still alive"]),"still alive")
    }
    func testProcessRunnerEarlyFailureRetainsStatusAndStderrDuringInputWrite() throws {
        let program = try processScript("/usr/bin/printf 'short diagnostic' >&2\nexit 7"),input = Data(repeating:65,count:8*1024*1024)
        let error = processFailure { try ProcessRunner.run(program.path,arguments:[],input:input,timeout:2) }
        XCTAssertTrue(error?.localizedDescription.contains("7") == true);XCTAssertTrue(error?.localizedDescription.contains("short diagnostic") == true)
    }
    func testProcessRunnerLegacyWrapperWaitsForInheritedOutputWriter() throws {
        let program = try processScript("(/bin/sleep 0.2; /usr/bin/printf 'late output') &\nexit 0"),started = Date()
        XCTAssertEqual(try ProcessRunner.run(program.path,arguments:[],timeout:3),"late output");XCTAssertTrue(Date().timeIntervalSince(started) >= 0.15)
    }
    func testProcessRunnerLegacyWrapperBoundsLateDescendantOutput() throws {
        let marker = root.appendingPathComponent("Legacy child finished"),program = try processScript("(/bin/sleep 0.1; /bin/dd if=/dev/zero bs=1048576 count=64 2>/dev/null; /usr/bin/touch \"$1\") &\nexit 0")
        let error = processFailure { try ProcessRunner.run(program.path,arguments:[marker.path],timeout:20) }
        XCTAssertTrue(error?.localizedDescription.contains("32 MiB") == true);XCTAssertTrue((error?.localizedDescription.utf8.count ?? 0) <= 4*1024*1024+512);Thread.sleep(forTimeInterval:0.2);XCTAssertFalse(FileSystem.exists(marker))
    }
    func testProcessRunnerWorkingDirectorySupportsExplicitAliasAndSpaces() throws {
        let directory = try folder("Working directory"),alias = root.appendingPathComponent("Alias");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:directory)
        let output = try ProcessRunner.run("/bin/pwd",arguments:["-P"],directory:alias)
        XCTAssertEqual(output.trimmingCharacters(in:.whitespacesAndNewlines),try processPhysicalPath(directory))
        let program = try processScript("/usr/bin/printf literal");let targetAlias = root.appendingPathComponent("Program alias");try FileManager.default.createSymbolicLink(at:targetAlias,withDestinationURL:program)
        XCTAssertEqual(try ProcessRunner.run(targetAlias.path,arguments:[],directory:alias),"literal")
    }
    func testProcessRunnerNilDirectoryInheritsCurrentWorkingDirectory() throws {
        let output = try ProcessRunner.run("/bin/pwd",arguments:["-P"])
        XCTAssertEqual(output.trimmingCharacters(in:.whitespacesAndNewlines),try processPhysicalPath(URL(fileURLWithPath:FileManager.default.currentDirectoryPath)))
    }
    func testProcessRunnerCancellationBeforeLaunchDoesNotCreateMarker() throws {
        let marker = root.appendingPathComponent("Unexpected start"),program = try processScript("/usr/bin/touch \"$1\""),token = CancellationToken();token.cancel()
        let error = processFailure { try ProcessRunner.run(program.path,arguments:[marker.path],input:Data("input".utf8),token:token) }
        if let error,case CommanderError.cancelled = error { XCTAssertTrue(true) } else { XCTAssertTrue(false) };XCTAssertFalse(FileSystem.exists(marker))
    }
    func testProcessRunnerRejectsInvalidTimeoutAndEmbeddedNulls() throws {
        for timeout in [0,Double.nan,Double.infinity,-1] { XCTAssertThrowsError(try ProcessRunner.run("/usr/bin/printf",arguments:[],timeout:timeout)) }
        XCTAssertThrowsError(try ProcessRunner.run("/usr/bin/printf\0extra",arguments:[]));XCTAssertThrowsError(try ProcessRunner.run("/usr/bin/printf",arguments:["bad\0argument"]))
        XCTAssertThrowsError(try ProcessRunner.run("/usr/bin/printf",arguments:[],directory:URL(string:"https://example.invalid/")!))
    }
    func testProcessRunnerInheritedStdinReaderRemainsBoundedAfterParentExit() throws {
        let program = try processScript("(/bin/sleep 5) <&0 >/dev/null 2>&1 &\nexit 0"),input = Data(repeating:65,count:8*1024*1024),started = Date()
        let error = processFailure { try ProcessRunner.run(program.path,arguments:[],input:input,timeout:0.25) }
        XCTAssertTrue(error?.localizedDescription.contains("Zeitlimit") == true,error?.localizedDescription ?? "No timeout error");XCTAssertTrue(Date().timeIntervalSince(started) < 3)
    }
    func testProcessRunnerOutputLimitStillAppliesWhileInputIsBlocked() throws {
        let input = Data(repeating:65,count:8*1024*1024),program = "import sys; sys.stdout.buffer.write(b'x'*(64*1024*1024)); sys.stdout.flush(); sys.stdin.buffer.read()"
        let error = processFailure { try ProcessRunner.run("/usr/bin/python3",arguments:["-c",program],input:input,timeout:20) }
        XCTAssertTrue(error?.localizedDescription.contains("32 MiB") == true);XCTAssertTrue((error?.localizedDescription.utf8.count ?? 0) <= 4*1024*1024+512)
    }
    func testProcessRunnerRetainedWorkingDirectoryDoesNotDependOnOpenStandardInput() throws {
        let saved = fcntl(STDIN_FILENO,F_DUPFD_CLOEXEC,3);guard saved >= 0 else { throw CommanderError.message("Standardinput fixture could not be retained") };defer { _ = dup2(saved,STDIN_FILENO);close(saved) }
        close(STDIN_FILENO)
        let output = try ProcessRunner.run("/bin/pwd",arguments:["-P"],directory:root)
        XCTAssertEqual(output.trimmingCharacters(in:.whitespacesAndNewlines),try processPhysicalPath(root))
    }
}
