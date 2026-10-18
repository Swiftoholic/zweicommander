import Foundation
import CoreGraphics
import ImageIO
import CommanderCore

extension CoreTests {
    func renameImage(_ name: String,exif: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(name);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let context = CGContext(data:nil,width:8,height:6,bitsPerComponent:8,bytesPerRow:32,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.jpeg" as CFString,1,nil)!
        let metadata: [CFString:Any] = exif ? [kCGImagePropertyExifDictionary:[kCGImagePropertyExifDateTimeOriginal:"2021:02:03 04:05:06"]] : [:]
        CGImageDestinationAddImage(destination,context.makeImage()!,metadata as CFDictionary);XCTAssertTrue(CGImageDestinationFinalize(destination));return url
    }
    func testRenameTemplatesSlicesEscapesAndLiteralValues() throws {
        let a = try file("Grüße{n}.TXT"),b = try file("👩‍💻abc.txt")
        var rule = RenameRule();rule.pattern = "{n}-{name:1:5}-{{name}}"
        XCTAssertEqual(try RenameEngine.preview([a],rule:rule)[0].target.lastPathComponent,"001-Grüße-{name}.TXT")
        rule.pattern = "{name}";XCTAssertEqual(try RenameEngine.preview([a],rule:rule)[0].target.lastPathComponent,a.lastPathComponent)
        rule.pattern = "{name:1:1}";XCTAssertEqual(try RenameEngine.preview([b],rule:rule)[0].target.lastPathComponent,"👩‍💻.txt")
        rule.pattern = "{parent}-{name:3}";XCTAssertTrue(try RenameEngine.preview([b],rule:rule)[0].target.lastPathComponent.hasSuffix("-bc.txt"))
    }
    func testRenameSeparateExtensionsAndTargetedTransforms() throws {
        let file = try self.file("Report OLD.TXT"),directory = try folder("Folder.old")
        var rule = RenameRule();rule.extensionPattern = "md";rule.search = "old";rule.replacement = "new";rule.ignoreCase = true;rule.searchTarget = .name;rule.letterCase = 1;rule.caseTarget = .fileExtension
        XCTAssertEqual(try RenameEngine.preview([file],rule:rule)[0].target.lastPathComponent,"Report new.md")
        rule.extensionPattern = "";XCTAssertEqual(try RenameEngine.preview([file],rule:rule)[0].target.lastPathComponent,"Report new")
        rule.extensionPattern = "md";rule.pattern = "new-{name}"
        XCTAssertEqual(try RenameEngine.preview([directory],rule:rule)[0].target.lastPathComponent,"new-Fnewer.new")
        rule.pattern = "{full}";XCTAssertThrowsError(try rule.validate())
        rule.pattern = "{name}";rule.extensionPattern = ".md";XCTAssertTrue(try RenameEngine.plan([file],rule:rule).errorCount == 1)
    }
    func testRenameCounterStepsPerFolderAndOverflow() throws {
        let a = try file("one/a.txt"),b = try file("two/b.txt"),c = try file("one/c.txt")
        var rule = RenameRule();rule.pattern = "{n}-{name}";rule.start = 10;rule.step = -2;rule.digits = 2
        XCTAssertEqual(try RenameEngine.preview([a,b,c],rule:rule).map { $0.target.lastPathComponent },["10-a.txt","08-b.txt","06-c.txt"])
        rule.resetPerFolder = true
        XCTAssertEqual(try RenameEngine.preview([a,b,c],rule:rule).map { $0.target.lastPathComponent },["10-a.txt","10-b.txt","08-c.txt"])
        rule.resetPerFolder = false;rule.start = Int.max;rule.step = 1
        let plan = try RenameEngine.plan([a,b],rule:rule);XCTAssertEqual(plan.errorCount,1);XCTAssertFalse(plan.canApply)
        rule.step = 0;XCTAssertThrowsError(try rule.validate())
    }
    func testRenameDateAndImageMetadataTokens() throws {
        let image = try renameImage("photo.jpg")
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1700000000)],ofItemAtPath:image.path)
        var rule = RenameRule();rule.pattern = "{date}-{width}x{height}-{taken}";rule.dateFormat = "yyyyMMdd_HHmmss";rule.useUTC = true
        XCTAssertEqual(try RenameEngine.preview([image],rule:rule)[0].target.lastPathComponent,"20231114_221320-8x6-20210203_040506.jpg")
        rule.pattern = "{date}";rule.dateSource = .created
        let date = try FileManager.default.attributesOfItem(atPath:image.path)[.creationDate] as! Date
        let format = DateFormatter();format.locale = Locale(identifier:"en_US_POSIX");format.timeZone = TimeZone(secondsFromGMT:0);format.dateFormat = rule.dateFormat
        XCTAssertEqual(try RenameEngine.preview([image],rule:rule)[0].target.lastPathComponent,format.string(from:date)+".jpg")
    }
    func testRenameMissingMetadataAndInvalidRulesStayVisible() throws {
        let a = try file("a.txt"),image = try renameImage("no-exif.jpg",exif:false)
        var rule = RenameRule();rule.pattern = "{taken}"
        XCTAssertEqual(try RenameEngine.plan([a,image],rule:rule).errorCount,2)
        rule.pattern = "{width}";XCTAssertEqual(try RenameEngine.plan([a,image],rule:rule).errorCount,1)
        for pattern in ["{unknown}","{name:0}","{name:2:0}","{n:2}","{name","name}"] { rule.pattern = pattern;XCTAssertThrowsError(try rule.validate()) }
        rule.pattern = "{name}";rule.regex = true;rule.search = "[";XCTAssertThrowsError(try rule.validate())
        rule.regex = false;rule.search = "";rule.digits = 0;XCTAssertThrowsError(try rule.validate())
        rule.digits = 3;rule.pattern = "../bad";XCTAssertFalse(try RenameEngine.plan([a],rule:rule).canApply)
    }
    func testRenameCollisionsAnnotateEveryConflictingRow() throws {
        let a = try file("a.txt"),b = try file("b.txt");try file("keep.txt","foreign")
        var rule = RenameRule();rule.pattern = "same"
        let duplicate = try RenameEngine.plan([a,b],rule:rule)
        XCTAssertEqual(duplicate.errorCount,2);XCTAssertFalse(duplicate.canApply);XCTAssertTrue(duplicate.rows.allSatisfy { $0.targetName == "same.txt" })
        rule.pattern = "keep";let existing = try RenameEngine.plan([a],rule:rule);XCTAssertEqual(existing.errorCount,1)
        XCTAssertThrowsError(try RenameEngine.apply(existing.items));XCTAssertEqual(try read(root.appendingPathComponent("keep.txt")),"foreign");XCTAssertEqual(try read(a),"example")
    }
    func testRenameStaleSourceBlocksAllNamesBeforeMutation() throws {
        let a = try file("a.txt"),b = try file("b.txt")
        var rule = RenameRule();rule.pattern = "new-{name}";let plan = try RenameEngine.preview([a,b],rule:rule)
        try Data("changed".utf8).write(to:b)
        XCTAssertThrowsError(try RenameEngine.apply(plan));XCTAssertTrue(FileSystem.exists(a));XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("new-a.txt")))
        XCTAssertEqual(try read(b),"changed")
    }
    func testRenameDetectsSameSizeEditsWithRestoredTimestamp() throws {
        let a = try file("a.txt","ABCD"),date = Date(timeIntervalSince1970:1700000000)
        try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:a.path)
        var rule = RenameRule();rule.pattern = "new-{name}";let plan = try RenameEngine.preview([a],rule:rule),stamp = try FileStamp(a)
        Thread.sleep(forTimeInterval:0.01)
        let handle = try FileHandle(forWritingTo:a);try handle.write(contentsOf:Data("WXYZ".utf8));try handle.close()
        try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:a.path)
        XCTAssertEqual(try FileStamp(a),stamp);XCTAssertThrowsError(try RenameEngine.apply(plan));XCTAssertEqual(try read(a),"WXYZ")
    }
    func testRenameReplacedParentAndSourceAreRejected() throws {
        let a = try file("parent/a.txt","original"),old = root.appendingPathComponent("old")
        var rule = RenameRule();rule.pattern = "new-{name}";let plan = try RenameEngine.preview([a],rule:rule)
        try FileManager.default.moveItem(at:a.deletingLastPathComponent(),to:old);try file("parent/a.txt","new object")
        XCTAssertThrowsError(try RenameEngine.apply(plan));XCTAssertEqual(try read(a),"new object");XCTAssertEqual(try read(old.appendingPathComponent("a.txt")),"original")
    }
    func testRenameCancellationRestoresStagedNames() throws {
        let a = try file("a.txt","A"),b = try file("b.txt","B"),token = CancellationToken()
        var rule = RenameRule();rule.pattern = "new-{name}";let items = try RenameEngine.preview([a,b],rule:rule)
        XCTAssertThrowsError(try RenameEngine.apply(items,token:token,progress:{ p in if p.phase == .staging && p.completed == 1 { token.cancel() } }))
        XCTAssertEqual(try read(a),"A");XCTAssertEqual(try read(b),"B")
        XCTAssertFalse(try FileSystem.list(root,showHidden:true).contains { $0.name.hasPrefix(".zweicommander-rename-") })
    }
    func testRenameCancellationRestoresPublishedCycle() throws {
        let a = try file("a","A"),b = try file("b","B"),c = try file("c","C"),token = CancellationToken()
        let items = [RenameItem(source:a,target:b),RenameItem(source:b,target:c),RenameItem(source:c,target:a)]
        XCTAssertThrowsError(try RenameEngine.apply(items,token:token,progress:{ p in if p.phase == .publishing && p.completed == 1 { token.cancel() } }))
        XCTAssertEqual(try read(a),"A");XCTAssertEqual(try read(b),"B");XCTAssertEqual(try read(c),"C")
        XCTAssertEqual(try FileSystem.list(root,showHidden:true).count,3)
    }
    func testRenameNeverOverwritesTargetCreatedDuringPublication() throws {
        let a = try file("a","A"),b = try file("b","B"),target = root.appendingPathComponent("new-b")
        var rule = RenameRule();rule.pattern = "new-{name}";let items = try RenameEngine.preview([a,b],rule:rule)
        XCTAssertThrowsError(try RenameEngine.apply(items,progress:{ p in if p.phase == .publishing && p.completed == 1 { try! Data("foreign".utf8).write(to:target) } }))
        XCTAssertEqual(try read(target),"foreign");XCTAssertEqual(try read(a),"A");XCTAssertEqual(try read(b),"B")
        XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("new-a")))
    }
    func testRenameFailedRollbackPreservesForeignAndOwnedFiles() throws {
        let a = try file("a","owned"),b = try file("b","B"),token = CancellationToken()
        var rule = RenameRule();rule.pattern = "new-{name}";let items = try RenameEngine.preview([a,b],rule:rule)
        do {
            try RenameEngine.apply(items,token:token,progress:{ p in
                if p.phase == .staging && p.completed == 1 { try! Data("foreign".utf8).write(to:a);token.cancel() }
            });XCTAssertTrue(false)
        } catch { XCTAssertTrue(error.localizedDescription.contains("Nicht vollständig zurückgesetzt")) }
        XCTAssertEqual(try read(a),"foreign");XCTAssertEqual(try read(b),"B")
        let saved = try FileSystem.list(root,showHidden:true).filter { $0.name.hasPrefix(".zweicommander-rename-") }
        XCTAssertEqual(saved.count,1);if let own = saved.first { XCTAssertEqual(try read(own.url),"owned") }
    }
    func testRenameParentRelocationReportsActualRecoveryLocation() throws {
        let a = try file("parent/a","owned"),b = try file("parent/b","B"),old = a.deletingLastPathComponent(),moved = root.appendingPathComponent("relocated")
        var rule = RenameRule();rule.pattern = "new-{name}";let items = try RenameEngine.preview([a,b],rule:rule)
        do {
            try RenameEngine.apply(items,progress:{ p in
                if p.phase == .staging && p.completed == 1 {
                    try! FileManager.default.moveItem(at:old,to:moved)
                    try! FileManager.default.createDirectory(at:old,withIntermediateDirectories:false)
                    try! Data("foreign".utf8).write(to:a)
                }
            });XCTAssertTrue(false)
        } catch { XCTAssertTrue(error.localizedDescription.contains("/relocated/.zweicommander-rename-")) }
        XCTAssertEqual(try read(a),"foreign");XCTAssertEqual(try read(moved.appendingPathComponent("b")),"B")
        let saved = try FileSystem.list(moved,showHidden:true).first { $0.name.hasPrefix(".zweicommander-rename-") }
        XCTAssertNotNil(saved);if let saved { XCTAssertEqual(try read(saved.url),"owned") }
    }
    func testRenameOpenHandleEditDuringStagingIsPreserved() throws {
        let a = try file("a","AAAA"),b = try file("b","BBBB"),handle = try FileHandle(forWritingTo:a)
        defer { try? handle.close() }
        var rule = RenameRule();rule.pattern = "new-{name}";let items = try RenameEngine.preview([a,b],rule:rule)
        XCTAssertThrowsError(try RenameEngine.apply(items,progress:{ p in
            if p.phase == .publishing && p.completed == 0 { try! handle.write(contentsOf:Data("EDIT".utf8)) }
        }))
        XCTAssertEqual(try read(a),"EDIT");XCTAssertEqual(try read(b),"BBBB")
        XCTAssertEqual(try FileSystem.list(root,showHidden:true).count,2)
    }
    func testRenameUndoRefusesEditsAndOccupiedOriginals() throws {
        let a = try file("a.txt","A"),b = try file("b.txt","B")
        var rule = RenameRule();rule.pattern = "new-{name}";let undo = try RenameEngine.apply(RenameEngine.preview([a,b],rule:rule))
        try Data("foreign".utf8).write(to:a)
        XCTAssertThrowsError(try RenameEngine.apply(undo));XCTAssertEqual(try read(a),"foreign");XCTAssertEqual(try read(undo[0].source),"A")
        try FileManager.default.removeItem(at:a);try Data("edited".utf8).write(to:undo[1].source)
        XCTAssertThrowsError(try RenameEngine.apply(undo));XCTAssertEqual(try read(undo[0].source),"A");XCTAssertEqual(try read(undo[1].source),"edited")
    }
    func testRenameLinksNestedSelectionsAndHardlinks() throws {
        let target = try file("target","untouched"),link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        var rule = RenameRule();rule.pattern = "new-{name}"
        let undo = try RenameEngine.apply(RenameEngine.preview([link],rule:rule))
        XCTAssertEqual(try read(target),"untouched");XCTAssertTrue(FileSystem.isSymlink(undo[0].source));try RenameEngine.apply(undo)
        rule.pattern = "{width}";XCTAssertEqual(try RenameEngine.plan([link],rule:rule).errorCount,1)
        let dir = try folder("folder"),child = try file("folder/a.txt")
        rule.pattern = "new-{name}";XCTAssertEqual(try RenameEngine.plan([dir,child],rule:rule).errorCount,2)
        let hardlink = root.appendingPathComponent("hardlink");try FileManager.default.linkItem(at:target,to:hardlink)
        XCTAssertEqual(try RenameEngine.plan([target,hardlink],rule:rule).errorCount,2)
    }
    func testRenameCaseOnlyCyclesAndUnchangedRows() throws {
        let a = try file("lower.txt","A"),b = try file("stay.txt","B")
        let items = [RenameItem(source:a,target:root.appendingPathComponent("LOWER.TXT")),RenameItem(source:b,target:b)]
        let undo = try RenameEngine.apply(items);XCTAssertEqual(undo.count,1);XCTAssertEqual(try read(undo[0].source),"A");XCTAssertEqual(try read(b),"B")
        try RenameEngine.apply(undo);XCTAssertEqual(try read(a),"A")
        var rule = RenameRule();rule.search = "([a-z]+)";rule.replacement = "$1-copy";rule.regex = true;rule.searchTarget = .name
        XCTAssertEqual(try RenameEngine.preview([b],rule:rule)[0].target.lastPathComponent,"stay-copy.txt")
    }
    func testRenameProfilesRoundTripUnicodeAndRulesOnly() throws {
        var library = RenameProfileLibrary(),rule = RenameRule();rule.pattern = "{taken}-{n}-{name:1:4}";rule.step = 3;rule.extensionPattern = "jpg";rule.useUTC = true
        let id = try library.save(name:"  Grüße  ",rule:rule),data = try library.encoded()
        XCTAssertEqual(try RenameProfileLibrary(data:data),library);XCTAssertFalse(String(decoding:data,as:UTF8.self).contains(root.path))
        XCTAssertEqual(library.profile(id)?.name,"Grüße");XCTAssertEqual(library.profile(id)?.rule,rule)
        var legacy = RenameRule();legacy.pattern = "{name}"
        let old = try JSONDecoder().decode(RenameRule.self,from:Data("{\"pattern\":\"{name}\"}".utf8))
        XCTAssertEqual(old,legacy)
        try library.save(name:"Aktuell",rule:legacy,replacing:id);XCTAssertEqual(library.profiles.count,1);try library.remove(id);XCTAssertTrue(library.profiles.isEmpty)
    }
    func testRenameProfileErrorsNeverReplaceExistingRules() throws {
        var library = RenameProfileLibrary();let rule = RenameRule();try library.save(name:"Äpfel",rule:rule);let original = library
        XCTAssertThrowsError(try library.save(name:"A\u{308}PFEL",rule:rule));XCTAssertEqual(library,original)
        var invalid = rule;invalid.step = 0;XCTAssertThrowsError(try library.save(name:"Bad",rule:invalid));XCTAssertEqual(library,original)
        XCTAssertThrowsError(try RenameProfileLibrary(data:Data("{broken".utf8)))
        XCTAssertThrowsError(try RenameProfileLibrary(data:Data("{\"version\":2,\"profiles\":[]}".utf8)))
        XCTAssertThrowsError(try RenameProfileLibrary(data:Data(repeating:32,count:1_048_577)))
        for index in 1..<50 { try library.save(name:"Profil \(index)",rule:rule) }
        XCTAssertThrowsError(try library.save(name:"Eines zu viel",rule:rule));XCTAssertEqual(library.profiles.count,50)
    }
    func testScopedSchedulerCancellationKeepsOtherJobs() throws {
        let scheduler = WorkScheduler(),lock = NSLock();var ran = false,completions = 0
        let removed = scheduler.enqueue("Removed",start:false,body:{ _,_ in lock.lock();ran = true;lock.unlock() },completion:{ _ in lock.lock();completions += 1;lock.unlock() })
        let other = scheduler.enqueue("Other",start:false,body:{ _,_ in })
        scheduler.cancel(removed);scheduler.cancel(removed)
        XCTAssertEqual(scheduler.snapshots.first?.state,.cancelled);XCTAssertEqual(scheduler.snapshots.last?.id,other);XCTAssertEqual(scheduler.snapshots.last?.state,.waiting)
        lock.lock();XCTAssertFalse(ran);XCTAssertEqual(completions,1);lock.unlock()
        scheduler.start();XCTAssertTrue(waitUntil { scheduler.snapshots.last?.state == .completed })
    }
    func testRenameManualPlansCannotMoveOutsideParent() throws {
        let a = try file("a.txt"),elsewhere = try folder("elsewhere")
        XCTAssertThrowsError(try RenameEngine.apply([RenameItem(source:a,target:elsewhere.appendingPathComponent("a.txt"))]))
        XCTAssertThrowsError(try RenameEngine.apply([RenameItem(source:a,target:URL(string:"https://example.invalid/a.txt")!)]))
        XCTAssertEqual(try read(a),"example")
    }
}
