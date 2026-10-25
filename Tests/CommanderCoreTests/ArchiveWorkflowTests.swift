import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    private func archiveFixture() throws -> ArchiveCatalog {
        let archive = try unsafeArchive("catalog.zip",entries:[("Docs/Grüße.txt","hello"),("Docs/Sub/More.md","more"),("Other.bin","other"),(".hidden/note.txt","hidden")])
        return try ArchiveCatalog.read(archive)
    }
    func testArchiveCatalogSynthesizesParentsWithoutExtracting() throws {
        let catalog = try archiveFixture(),before = try FileManager.default.contentsOfDirectory(atPath:root.path)
        XCTAssertEqual(try catalog.contents(of:"").map(\.path).sorted(),["Docs","Other.bin"])
        XCTAssertEqual(try catalog.contents(of:"Docs").map(\.path).sorted(),["Docs/Grüße.txt","Docs/Sub"])
        XCTAssertEqual(try catalog.contents(of:"",showHidden:true).count,3)
        XCTAssertThrowsError(try catalog.contents(of:"missing"));XCTAssertThrowsError(try catalog.contents(of:"Other.bin"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path),before)
        XCTAssertFalse(FileSystem.exists(root.appendingPathComponent("Docs")))
    }
    func testArchiveCatalogRejectsDuplicateAndConflictingParents() throws {
        for entries in [[("a.txt","a"),("./a.txt","b")],[("a","file"),("a/b","child")]] {
            let archive = try unsafeArchive(UUID().uuidString+".zip",entries:entries);XCTAssertThrowsError(try ArchiveCatalog.read(archive))
        }
    }
    func testArchiveCatalogRejectsTraversalAndSymbolicSource() throws {
        let bad = try unsafeArchive("bad.zip",entries:[("safe.txt","ok"),("../outside","bad")]);XCTAssertThrowsError(try ArchiveCatalog.read(bad))
        let catalog = try archiveFixture(),link = root.appendingPathComponent("link.zip");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:catalog.source)
        XCTAssertThrowsError(try ArchiveCatalog.read(link))
    }
    func testArchiveCatalogCancellationAndChangedSource() throws {
        let catalog = try archiveFixture(),token = CancellationToken();token.cancel();XCTAssertThrowsError(try ArchiveCatalog.read(catalog.source,token:token))
        try Data("changed".utf8).write(to:catalog.source);XCTAssertThrowsError(try catalog.validateSource())
        XCTAssertThrowsError(try ArchiveExtractionPlan(catalog:catalog,to:root.appendingPathComponent("result")))
    }
    func testArchiveFolderNamesStripCompoundExtensions() throws {
        for name in ["Bundle.tar.gz","Bundle.TAR.BZ2","Bundle.tar.xz","Bundle.tgz","Bundle.zip","Bundle.7z"] { XCTAssertEqual(ArchiveCatalog.folderName(for:URL(fileURLWithPath:"/"+name)),"Bundle") }
    }
    func testArchiveSelectiveExtractionStripsCurrentFolderOnly() throws {
        let catalog = try archiveFixture(),target = root.appendingPathComponent("selected")
        let plan = try ArchiveExtractionPlan(catalog:catalog,to:target,selection:["Docs/Sub","Docs/Grüße.txt"],relativeTo:"Docs")
        XCTAssertEqual(plan.totalBytes,9);XCTAssertEqual(Set(plan.rows.map(\.path)),Set(["Sub","Sub/More.md","Grüße.txt"]))
        try ArchiveService.extract(plan)
        XCTAssertEqual(try read(target.appendingPathComponent("Grüße.txt")),"hello");XCTAssertEqual(try read(target.appendingPathComponent("Sub/More.md")),"more")
        XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("Docs")));XCTAssertFalse(FileSystem.exists(target.appendingPathComponent("Other.bin")))
    }
    func testArchiveSelectionIncludesDescendantsOnce() throws {
        let catalog = try archiveFixture(),plan = try ArchiveExtractionPlan(catalog:catalog,to:root.appendingPathComponent("out"),selection:["Docs","Docs/Sub/More.md","Docs"])
        XCTAssertEqual(plan.totalBytes,9);XCTAssertEqual(plan.rows.filter { !$0.isDirectory }.count,2)
        try ArchiveService.extract(plan);XCTAssertEqual(try read(plan.destination.appendingPathComponent("Docs/Sub/More.md")),"more")
    }
    func testArchiveExtractionRejectsForeignSelectionAndOccupiedTargets() throws {
        let catalog = try archiveFixture()
        for selection in [[],["missing"],["../outside"],["Other.bin"]] { XCTAssertThrowsError(try ArchiveExtractionPlan(catalog:catalog,to:root.appendingPathComponent("out"),selection:selection,relativeTo:"Docs")) }
        XCTAssertThrowsError(try ArchiveExtractionPlan(catalog:catalog,to:root.appendingPathComponent("out"),relativeTo:"Docs"))
        let occupied = try folder("occupied");XCTAssertThrowsError(try ArchiveExtractionPlan(catalog:catalog,to:occupied))
        XCTAssertThrowsError(try ArchiveExtractionPlan(catalog:catalog,to:URL(string:"ftp://example.invalid/out")!))
    }
    func testArchiveExtractionBudgetHasNoPartialOutput() throws {
        let catalog = try archiveFixture(),target = root.appendingPathComponent("out")
        XCTAssertThrowsError(try ArchiveExtractionPlan(catalog:catalog,to:target,maximumBytes:2));XCTAssertFalse(FileSystem.exists(target))
        let plan = try ArchiveExtractionPlan(catalog:catalog,to:target),token = CancellationToken();token.cancel()
        XCTAssertThrowsError(try ArchiveService.extract(plan,token:token));XCTAssertFalse(FileSystem.exists(target))
    }
    func testArchiveExtractionCancellationDuringDataRemovesStaging() throws {
        let catalog = try archiveFixture(),plan = try ArchiveExtractionPlan(catalog:catalog,to:root.appendingPathComponent("out")),token = CancellationToken()
        XCTAssertThrowsError(try ArchiveService.extract(plan,token:token,progress:{ _ in token.cancel() }))
        XCTAssertFalse(FileSystem.exists(plan.destination));XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix(".zweicommander-extract-") })
    }
    func testArchiveExtractionChangedArchiveAndTargetAreNotPublished() throws {
        let catalog = try archiveFixture(),target = root.appendingPathComponent("out"),plan = try ArchiveExtractionPlan(catalog:catalog,to:target)
        try file("out/keep.txt","keep");XCTAssertThrowsError(try ArchiveService.extract(plan));XCTAssertEqual(try read(target.appendingPathComponent("keep.txt")),"keep")
        try FileManager.default.removeItem(at:target);try Data("changed".utf8).write(to:catalog.source)
        XCTAssertThrowsError(try ArchiveService.extract(plan));XCTAssertFalse(FileSystem.exists(target))
    }
    func testArchiveExtractionConcurrentTargetIsNeverReplaced() throws {
        let catalog = try archiveFixture(),target = root.appendingPathComponent("out"),plan = try ArchiveExtractionPlan(catalog:catalog,to:target)
        var created = false
        XCTAssertThrowsError(try ArchiveService.extract(plan,progress:{ _ in if !created { created = true;try? FileManager.default.createDirectory(at:target,withIntermediateDirectories:false);try? Data("keep".utf8).write(to:target.appendingPathComponent("keep")) } }))
        XCTAssertEqual(try read(target.appendingPathComponent("keep")),"keep")
    }
    func testArchiveExtractionChangedParentCannotRedirectPublication() throws {
        let catalog = try archiveFixture(),parent = try folder("target"),saved = root.appendingPathComponent("saved"),target = parent.appendingPathComponent("out"),plan = try ArchiveExtractionPlan(catalog:catalog,to:target)
        var changed = false
        XCTAssertThrowsError(try ArchiveService.extract(plan,progress:{ _ in if !changed { changed = true;try? FileManager.default.moveItem(at:parent,to:saved);try? FileManager.default.createDirectory(at:parent,withIntermediateDirectories:false) } }))
        XCTAssertFalse(FileSystem.exists(target));XCTAssertFalse(FileSystem.exists(saved.appendingPathComponent("out")))
    }
    func testArchiveFullExtractionPreservesHiddenAndEmptyDirectories() throws {
        let source = try folder("source/empty");try file("source/.hidden","hidden");try file("source/normal","normal")
        let input = source.deletingLastPathComponent(),archive = root.appendingPathComponent("tree.tar.gz");try ArchiveService.pack([input],to:archive,tarGzip:true)
        let plan = try ArchiveExtractionPlan(catalog:ArchiveCatalog.read(archive),to:root.appendingPathComponent("out"));try ArchiveService.extract(plan)
        XCTAssertTrue(FileSystem.isDirectory(plan.destination.appendingPathComponent("source/empty")));XCTAssertEqual(try read(plan.destination.appendingPathComponent("source/.hidden")),"hidden")
    }
    func testArchivePackPlansMatchFormatAndRejectSourceTargets() throws {
        let source = try file("source/test.txt","hello")
        XCTAssertThrowsError(try ArchivePackPlan(sources:[source],to:root.appendingPathComponent("bad.rar")))
        XCTAssertThrowsError(try ArchivePackPlan(sources:[source],to:root.appendingPathComponent("bad.zip"),compressionLevel:10))
        XCTAssertThrowsError(try ArchivePackPlan(sources:[source.deletingLastPathComponent()],to:source.deletingLastPathComponent().appendingPathComponent("inside.zip")))
        XCTAssertThrowsError(try ArchivePackPlan(sources:[],to:root.appendingPathComponent("empty.zip")))
    }
    func testArchivePackPlansRoundTripEverySupportedWriter() throws {
        let source = try folder("source");try file("source/note.txt","archive plan");try folder("source/empty")
        for format in ArchiveFormat.allCases {
            let target = root.appendingPathComponent("bundle."+format.fileExtension),plan = try ArchivePackPlan(sources:[source],to:target,format:format)
            XCTAssertEqual(plan.totalBytes,12);try plan.execute()
            let extraction = try ArchiveExtractionPlan(catalog:ArchiveCatalog.read(target),to:root.appendingPathComponent("out-"+format.rawValue));try ArchiveService.extract(extraction)
            XCTAssertEqual(try read(extraction.destination.appendingPathComponent("source/note.txt")),"archive plan");XCTAssertTrue(FileSystem.isDirectory(extraction.destination.appendingPathComponent("source/empty")))
        }
    }
    func testArchivePackPlanRejectsChangedSourcesAndNewDescendants() throws {
        let source = try folder("source");try file("source/note","first");let target = root.appendingPathComponent("out.zip"),plan = try ArchivePackPlan(sources:[source],to:target)
        try file("source/new","new");XCTAssertThrowsError(try plan.execute());XCTAssertFalse(FileSystem.exists(target))
        let fresh = try ArchivePackPlan(sources:[source],to:target);try file("source/note","changed");XCTAssertThrowsError(try fresh.validate())
    }
    func testArchivePackChangedDuringWriteIsNotPublished() throws {
        let source = try file("note.txt",String(repeating:"text",count:300)),target = root.appendingPathComponent("out.zip"),plan = try ArchivePackPlan(sources:[source],to:target)
        var changed = false
        XCTAssertThrowsError(try plan.execute(progress:{ _ in if !changed { changed = true;try? Data("changed".utf8).write(to:source) } }))
        XCTAssertFalse(FileSystem.exists(target))
    }
    func testArchivePackPlanRejectsLinksDuplicateNamesAndCancellation() throws {
        let first = try file("a/note.txt"),second = try file("b/note.txt"),link = root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:first)
        XCTAssertThrowsError(try ArchivePackPlan(sources:[link],to:root.appendingPathComponent("link.zip")))
        XCTAssertThrowsError(try ArchivePackPlan(sources:[first,second],to:root.appendingPathComponent("duplicates.zip")))
        let token = CancellationToken();token.cancel();XCTAssertThrowsError(try ArchivePackPlan(sources:[first],to:root.appendingPathComponent("cancel.zip"),token:token))
    }
    func testArchiveMetadataNeverReadsCoincidentLocalFiles() throws {
        let member = ArchiveMember(path:"Folder/note.txt",size:123,isDirectory:false,modified:Date(timeIntervalSince1970:1234)),entry = FileEntry(archive:member,address:URL(string:"zwei-archive://fixture/Folder/note.txt")!)
        XCTAssertEqual(entry.size,123);XCTAssertEqual(entry.name,"note.txt");XCTAssertFalse(entry.url.isFileURL);XCTAssertTrue(entry.isRegularFile)
    }
    func testArchiveLinksRemainVisibleButOnlyRegularSelectionExtracts() throws {
        let source = try folder("source"),file = try file("source/normal.txt","normal"),archive = root.appendingPathComponent("links.tar")
        try FileManager.default.createSymbolicLink(at:source.appendingPathComponent("link"),withDestinationURL:file)
        _ = try ProcessRunner.run("/usr/bin/tar",arguments:["-cf",archive.path,"-C",source.path,"link","normal.txt"])
        let catalog = try ArchiveCatalog.read(archive);XCTAssertTrue(catalog.member(at:"link")?.isLink == true)
        XCTAssertThrowsError(try ArchiveExtractionPlan(catalog:catalog,to:root.appendingPathComponent("all")))
        let plan = try ArchiveExtractionPlan(catalog:catalog,to:root.appendingPathComponent("regular"),selection:["normal.txt"]);try ArchiveService.extract(plan)
        XCTAssertEqual(try read(plan.destination.appendingPathComponent("normal.txt")),"normal");XCTAssertFalse(FileSystem.exists(plan.destination.appendingPathComponent("link")))
    }
    func testEncryptedZIPPreviewWrongPasswordRollbackAndCorrectExtraction() throws {
        let source = try folder("source");try file("source/note.txt","encrypted fixture");let archive = root.appendingPathComponent("encrypted.zip")
        _ = try ProcessRunner.run("/usr/bin/zip",arguments:["-q","-P","synthetic-archive-password",archive.path,"note.txt"],directory:source)
        let catalog = try ArchiveCatalog.read(archive),plan = try ArchiveExtractionPlan(catalog:catalog,to:root.appendingPathComponent("out"))
        XCTAssertThrowsError(try ArchiveService.extract(plan,password:"wrong"));XCTAssertFalse(FileSystem.exists(plan.destination))
        try ArchiveService.extract(plan,password:"synthetic-archive-password");XCTAssertEqual(try read(plan.destination.appendingPathComponent("note.txt")),"encrypted fixture")
    }
    func testEmptyArchiveCreatesOnlyRequestedEmptyDestination() throws {
        let archive = try unsafeArchive("empty.zip",entries:[]),plan = try ArchiveExtractionPlan(catalog:ArchiveCatalog.read(archive),to:root.appendingPathComponent("out"))
        XCTAssertTrue(plan.rows.isEmpty);try ArchiveService.extract(plan);XCTAssertTrue(FileSystem.isDirectory(plan.destination));XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:plan.destination.path).isEmpty)
    }
    func testArchiveWorkflowsRejectForeignFileHostsAndVirtualAddresses() throws {
        let catalog = try archiveFixture()
        for url in [URL(string:"file://example.invalid/tmp/out.zip")!,URL(string:"zwei-archive://fixture/out.zip")!] {
            XCTAssertThrowsError(try ArchiveCatalog.read(url));XCTAssertThrowsError(try ArchiveExtractionPlan(catalog:catalog,to:url))
            XCTAssertThrowsError(try ArchivePackPlan(sources:[catalog.source],to:url));XCTAssertThrowsError(try ArchivePackPlan(sources:[url],to:root.appendingPathComponent("out.zip")))
        }
    }
    func testArchiveWriterUsesPrivateStagingAndPrivateFinalFile() throws {
        let source = try file("note.txt","private fixture"),target = root.appendingPathComponent("out.zip");var mode:Int?
        try ArchiveService.pack([source],to:target,progress:{ _ in
            if let name = try? FileManager.default.contentsOfDirectory(atPath:self.root.path).first(where:{ $0.hasPrefix(".zweicommander-archive-") }) { mode = (try? FileManager.default.attributesOfItem(atPath:self.root.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)?.intValue }
        })
        XCTAssertEqual(mode,0o600);XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:target.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
    func testArchiveWriterRejectsSourceReplacedWithPipeBeforeOpen() throws {
        let source = try file("note.txt","original"),saved = root.appendingPathComponent("saved.txt"),target = root.appendingPathComponent("out.zip")
        var changed = false
        XCTAssertThrowsError(try ArchiveService.pack([source],to:target,progress:{ _ in
            if !changed { changed = true;try? FileManager.default.moveItem(at:source,to:saved);_ = mkfifo(source.path,0o600) }
        }))
        XCTAssertEqual(try read(saved),"original");XCTAssertFalse(FileSystem.exists(target));XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath:root.path).contains { $0.hasPrefix(".zweicommander-archive-") })
    }
}
