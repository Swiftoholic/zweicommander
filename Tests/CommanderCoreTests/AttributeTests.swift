import Foundation
import Darwin
import CommanderCore

extension CoreTests {
    private func attributeRule(mode:UInt16? = nil,modified:AttributeTimeChange = .unchanged,recursive:Bool = false) -> AttributeRule { var rule = AttributeRule();rule.permissions = mode;rule.modified = modified;rule.filter.recursive = recursive;return rule }
    private func attributeStat(_ url:URL) throws -> stat { var value = stat();guard lstat(url.path,&value) == 0 else { throw CommanderError.message("Teststat fehlgeschlagen") };return value }
    private func attributeURL(_ url:URL) -> URL { var path = [CChar](repeating:0,count:Int(MAXPATHLEN));_ = realpath(url.deletingLastPathComponent().path,&path);return URL(fileURLWithPath:String(cString:path)).appendingPathComponent(url.lastPathComponent) }
    private func attributeSetTimes(_ url:URL) throws {
        let fd = open(url.path,O_RDONLY|O_NOFOLLOW);guard fd >= 0 else { throw CommanderError.message("Testdatei nicht lesbar") };defer { close(fd) }
        var list = attrlist();list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT);list.commonattr = attrgroup_t(ATTR_CMN_CRTIME|ATTR_CMN_MODTIME|ATTR_CMN_ACCTIME)
        var values = [timespec(tv_sec:1_500_000_000,tv_nsec:123_456_789),timespec(tv_sec:1_600_000_000,tv_nsec:234_567_891),timespec(tv_sec:1_550_000_000,tv_nsec:345_678_912)]
        guard values.withUnsafeMutableBytes({fsetattrlist(fd,&list,$0.baseAddress,$0.count,0)}) == 0 else { throw CommanderError.message("Testzeiten nicht gesetzt") }
    }
    func testAttributePermissionsValidateExactOctalInput() throws {
        XCTAssertEqual(try AttributeRule.parsePermissions(" 0644 "),0o644);XCTAssertEqual(try AttributeRule.parsePermissions("7777"),0o7777);XCTAssertEqual(try AttributeRule.parsePermissions(""),nil)
        for invalid in ["64","8","888","0x644","-1","+644","10000","６４４"] { XCTAssertThrowsError(try AttributeRule.parsePermissions(invalid)) }
    }
    func testAttributeAbsoluteTimeUsesSelectedZoneAndRejectsInvalidCalendarDates() throws {
        let utc = TimeZone(secondsFromGMT:0)!,vienna = TimeZone(identifier:"Europe/Vienna")!
        XCTAssertEqual(try AttributeTimestamp.parse("2024-01-01 00:00:00",timeZone:utc).seconds,1_704_067_200)
        XCTAssertEqual(try AttributeTimestamp.parse("2024-01-01 01:00:00",timeZone:vienna),try AttributeTimestamp.parse("2024-01-01 00:00:00",timeZone:utc))
        for text in ["2024-02-30 10:00:00","2023-02-29 10:00:00","2024-01-01 24:00:00","2024-01-01 10:60:00","2024-01-01","0001-01-01 00:00:00"] { XCTAssertThrowsError(try AttributeTimestamp.parse(text,timeZone:utc)) }
    }
    func testAttributeLocalTimeRejectsDSTGapAndRepeatedWallTime() throws {
        let zone = TimeZone(identifier:"Europe/Vienna")!
        XCTAssertThrowsError(try AttributeTimestamp.parse("2024-03-31 02:30:00",timeZone:zone))
        XCTAssertThrowsError(try AttributeTimestamp.parse("2024-10-27 02:30:00",timeZone:zone))
        XCTAssertEqual(try AttributeTimestamp.parse("2024-10-27 03:30:00",timeZone:zone).seconds,1_729_996_200)
    }
    func testAttributeTimestampBoundsRejectInvalidFractionAndDecodedAbsolute() throws {
        XCTAssertThrowsError(try AttributeTimestamp(seconds:0,nanoseconds:-1));XCTAssertThrowsError(try AttributeTimestamp(seconds:0,nanoseconds:1_000_000_000));XCTAssertThrowsError(try AttributeTimestamp(seconds:Int64.max))
        let decoded = try JSONDecoder().decode(AttributeTimestamp.self,from:Data("{\"seconds\":9223372036854775807,\"nanoseconds\":0}".utf8));var rule = AttributeRule();rule.created = .absolute(decoded);XCTAssertThrowsError(try rule.validate())
    }
    func testAttributePreviewIsReadOnlyAndNoChangeRuleHasNoExecutableRows() throws {
        let source = try file("a.txt","original");try attributeSetTimes(source);let before = try attributeStat(source)
        let plan = try AttributePlan.prepare(sources:[source],rule:AttributeRule())
        XCTAssertFalse(plan.canApply);XCTAssertEqual(plan.rows.count,1);XCTAssertFalse(plan.rows[0].canSelect)
        let after = try attributeStat(source);XCTAssertEqual(before.st_mode,after.st_mode);XCTAssertEqual(before.st_mtimespec.tv_nsec,after.st_mtimespec.tv_nsec);XCTAssertEqual(try read(source),"original")
    }
    func testAttributePreviewExposesBeforeAfterAndStableProgressIdentities() throws {
        let source = try file("a.txt");try attributeSetTimes(source);let plan = try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600,modified:.shift(seconds:3600)))
        XCTAssertTrue(plan.canApply);XCTAssertEqual(plan.rows[0].after?.permissions,0o600);XCTAssertEqual(plan.rows[0].after?.modified.seconds,1_600_003_600);XCTAssertEqual(plan.rows[0].after?.modified.nanoseconds,234_567_891)
        XCTAssertEqual(plan.initialItems.map(\.id),plan.initialItems.map(\.id));XCTAssertTrue(plan.initialItems.allSatisfy { !$0.isByteTracked && $0.totalBytes == 0 })
    }
    func testAttributeDirectDirectoryDoesNotExpandWithoutRecursion() throws {
        let directory = try folder("Tree");try file("Tree/Child.txt");let plan = try AttributePlan.prepare(sources:[directory],rule:attributeRule(mode:0o700))
        XCTAssertEqual(plan.rows.map { $0.source.lastPathComponent },["Tree"]);XCTAssertEqual(plan.selectedRows.count,1)
    }
    func testAttributeRecursiveFiltersKeepExcludedBranchesAndObjectTypes() throws {
        let directory = try folder("Tree");try file("Tree/a.txt","abcd");try file("Tree/short.txt","x");try file("Tree/b.bin","abcd");try file("Tree/Sub/c.txt","abcd");try file("Tree/Cache/hidden.txt","abcd")
        var rule = attributeRule(mode:0o600,recursive:true);rule.folders = false;rule.filter.include = "*.txt";rule.filter.minimumSize = 3;rule.filter.excludedFolders = "Cache"
        let plan = try AttributePlan.prepare(sources:[directory],rule:rule)
        XCTAssertEqual(Set(plan.selectedRows.map { $0.source.lastPathComponent }),Set(["a.txt","c.txt"]));XCTAssertFalse(plan.rows.contains { $0.source.lastPathComponent == "hidden.txt" })
        let report = AttributeEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(report.completed.count,2)
        XCTAssertEqual(try attributeStat(root.appendingPathComponent("Tree/Cache/hidden.txt")).st_mode & 0o777,0o644)
    }
    func testAttributeMetadataFiltersUseFrozenPreviewDate() throws {
        let old = try file("old.txt","old"),fresh = try file("fresh.txt","new");let reference = Date(timeIntervalSince1970:1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate:reference.addingTimeInterval(-7200)],ofItemAtPath:old.path);try FileManager.default.setAttributes([.modificationDate:reference.addingTimeInterval(-60)],ofItemAtPath:fresh.path)
        var rule = attributeRule(mode:0o600);rule.filter.modifiedFrom = reference.addingTimeInterval(-3600);rule.filter.modifiedBefore = reference
        let plan = try AttributePlan.prepare(sources:[old,fresh],rule:rule,referenceDate:reference);XCTAssertEqual(plan.selectedRows.map(\.source),[attributeURL(fresh)]);XCTAssertEqual(plan.preparedAt,reference)
    }
    func testAttributeLinksAndSpecialFilesRemainVisibleButNeverSelected() throws {
        let directory = try folder("Tree"),outside = try file("outside/private.txt","untouched");try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent("Link"),withDestinationURL:outside);XCTAssertEqual(mkfifo(directory.appendingPathComponent("Pipe").path,0o600),0);try file("Tree/Regular.txt")
        let plan = try AttributePlan.prepare(sources:[directory],rule:attributeRule(mode:0o700,recursive:true));XCTAssertEqual(plan.rows.count,4);XCTAssertFalse(plan.rows.first { $0.source.lastPathComponent == "Link" }!.canSelect);XCTAssertFalse(plan.rows.first { $0.source.lastPathComponent == "Pipe" }!.canSelect)
        let report = AttributeEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(try read(outside),"untouched");XCTAssertEqual(try attributeStat(outside).st_mode & 0o777,0o644)
    }
    func testAttributePerRowSelectionIsImmutableAndCannotIntroducePaths() throws {
        let a = try file("a.txt"),b = try file("b.txt"),plan = try AttributePlan.prepare(sources:[a,b],rule:attributeRule(mode:0o600)),chosen = try plan.selecting(paths:[attributeURL(a).path])
        XCTAssertEqual(plan.selectedRows.count,2);XCTAssertEqual(chosen.selectedRows.map(\.source),[attributeURL(a)]);XCTAssertThrowsError(try plan.selecting(paths:[root.appendingPathComponent("foreign").path]))
        let report = AttributeEngine.execute(chosen);XCTAssertEqual(report.completed,[attributeURL(a)]);XCTAssertEqual(report.skipped,[attributeURL(b)]);XCTAssertEqual(try attributeStat(b).st_mode & 0o777,0o644)
    }
    func testAttributeOverlappingRecursiveSelectionsAreDeduplicated() throws {
        let parent = try folder("Tree"),child = try file("Tree/Sub/child.txt");let plan = try AttributePlan.prepare(sources:[parent,child,parent],rule:attributeRule(mode:0o700,recursive:true))
        XCTAssertEqual(plan.rows.count,3);XCTAssertEqual(Set(plan.rows.map(\.id)).count,3)
    }
    func testAttributeSelectedHardlinkAliasesAreRejectedBeforeExecution() throws {
        let a = try file("a.txt","shared"),b = root.appendingPathComponent("b.txt");try FileManager.default.linkItem(at:a,to:b)
        XCTAssertThrowsError(try AttributePlan.prepare(sources:[a,b],rule:attributeRule(mode:0o600)));XCTAssertEqual(try attributeStat(a).st_mode & 0o777,0o644)
    }
    func testAttributeStaleLaterFileBlocksWholePlanBeforeEarlierChanges() throws {
        let a = try file("a.txt","A"),b = try file("b.txt","B"),plan = try AttributePlan.prepare(sources:[a,b],rule:attributeRule(mode:0o600));try Data("changed".utf8).write(to:b)
        let report = AttributeEngine.execute(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.completed.isEmpty);XCTAssertEqual(try attributeStat(a).st_mode & 0o777,0o644);XCTAssertEqual(try read(b),"changed")
    }
    func testAttributeNewTreeMemberInvalidatesCompletePlan() throws {
        let parent = try folder("Tree");try file("Tree/a.txt");let plan = try AttributePlan.prepare(sources:[parent],rule:attributeRule(mode:0o700,recursive:true));try file("Tree/new.txt","foreign")
        let report = AttributeEngine.execute(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.completed.isEmpty);XCTAssertEqual(try attributeStat(root.appendingPathComponent("Tree/a.txt")).st_mode & 0o777,0o644)
    }
    func testAttributeReplacedParentAndSymlinkCannotRedirectWrites() throws {
        let source = try file("Selected/a.txt","A"),outside = try file("Outside/a.txt","outside"),plan = try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600))
        try FileManager.default.moveItem(at:root.appendingPathComponent("Selected"),to:root.appendingPathComponent("Moved"));try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("Selected"),withDestinationURL:outside.deletingLastPathComponent())
        let report = AttributeEngine.execute(plan);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try attributeStat(outside).st_mode & 0o777,0o644);XCTAssertEqual(try attributeStat(root.appendingPathComponent("Moved/a.txt")).st_mode & 0o777,0o644)
    }
    func testAttributeChangedFileAtProgressBoundaryIsNotMutated() throws {
        let source = try file("a.txt","before"),plan = try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600));var injected = false
        let report = AttributeEngine.execute(plan,progress:{ value in if value.items.contains(where:{$0.state == .running}),!injected { injected = true;try! Data("changed".utf8).write(to:source) } })
        XCTAssertTrue(injected);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try attributeStat(source).st_mode & 0o777,0o644);XCTAssertEqual(try read(source),"changed")
    }
    func testAttributeCancellationPreservesCompletedReceiptAndLeavesRemainingFile() throws {
        let a = try file("a.txt","A"),b = try file("b.txt","B"),plan = try AttributePlan.prepare(sources:[a,b],rule:attributeRule(mode:0o600)),token = CancellationToken()
        let report = AttributeEngine.execute(plan,token:token,progress:{ value in if value.items.contains(where:{$0.state == .completed}) { token.cancel() } })
        XCTAssertEqual(report.completed,[attributeURL(a)]);XCTAssertEqual(report.receipts.count,1);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(try attributeStat(b).st_mode & 0o777,0o644)
        XCTAssertTrue(AttributeEngine.undo(report.receipts).errors.isEmpty);XCTAssertEqual(try attributeStat(a).st_mode & 0o777,0o644)
    }
    func testAttributeCancellationBeforePreparationOrExecutionMutatesNothing() throws {
        let source = try file("a.txt"),token = CancellationToken();token.cancel();XCTAssertThrowsError(try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600),token:token))
        let plan = try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600)),report = AttributeEngine.execute(plan,token:token);XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.receipts.isEmpty);XCTAssertEqual(try attributeStat(source).st_mode & 0o777,0o644)
    }
    func testAttributeNativeTimesPreserveNanosecondsAndFileBytes() throws {
        let source = try file("a.txt","unchanged bytes");try attributeSetTimes(source)
        var rule = attributeRule(mode:0o600,modified:.shift(seconds:3600));rule.created = .shift(seconds:-60);rule.accessed = .absolute(try AttributeTimestamp(seconds:1_450_000_000,nanoseconds:987_654_321))
        let report = AttributeEngine.execute(try AttributePlan.prepare(sources:[source],rule:rule));XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));let actual = try attributeStat(source)
        XCTAssertEqual(actual.st_birthtimespec.tv_sec,1_499_999_940);XCTAssertEqual(actual.st_birthtimespec.tv_nsec,123_456_789);XCTAssertEqual(actual.st_mtimespec.tv_sec,1_600_003_600);XCTAssertEqual(actual.st_mtimespec.tv_nsec,234_567_891);XCTAssertEqual(actual.st_atimespec.tv_sec,1_450_000_000);XCTAssertEqual(actual.st_atimespec.tv_nsec,987_654_321);XCTAssertEqual(actual.st_mode & 0o7777,0o600);XCTAssertEqual(try read(source),"unchanged bytes")
    }
    func testAttributePermissionOnlyKeepsAllTimeFields() throws {
        let source = try file("a.txt");try attributeSetTimes(source);let before = try attributeStat(source),report = AttributeEngine.execute(try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600))),after = try attributeStat(source)
        XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(before.st_birthtimespec.tv_sec,after.st_birthtimespec.tv_sec);XCTAssertEqual(before.st_birthtimespec.tv_nsec,after.st_birthtimespec.tv_nsec);XCTAssertEqual(before.st_mtimespec.tv_sec,after.st_mtimespec.tv_sec);XCTAssertEqual(before.st_mtimespec.tv_nsec,after.st_mtimespec.tv_nsec);XCTAssertEqual(before.st_atimespec.tv_sec,after.st_atimespec.tv_sec);XCTAssertEqual(before.st_atimespec.tv_nsec,after.st_atimespec.tv_nsec)
    }
    func testAttributeEarlierModificationDoesNotImplicitlyReplaceCreationOrAccessTime() throws {
        let source = try file("a.txt");try attributeSetTimes(source);let before = try attributeStat(source),report = AttributeEngine.execute(try AttributePlan.prepare(sources:[source],rule:attributeRule(modified:.absolute(try AttributeTimestamp(seconds:1_400_000_000,nanoseconds:765_432_109))))),after = try attributeStat(source)
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(before.st_birthtimespec.tv_sec,after.st_birthtimespec.tv_sec);XCTAssertEqual(before.st_birthtimespec.tv_nsec,after.st_birthtimespec.tv_nsec);XCTAssertEqual(before.st_atimespec.tv_sec,after.st_atimespec.tv_sec);XCTAssertEqual(before.st_atimespec.tv_nsec,after.st_atimespec.tv_nsec);XCTAssertEqual(after.st_mtimespec.tv_sec,1_400_000_000)
    }
    func testAttributeUndoRestoresExactSupportedFieldsWithoutChangingBytes() throws {
        let source = try file("a.txt","original");try attributeSetTimes(source);let before = try attributeStat(source)
        var rule = attributeRule(mode:0o600,modified:.shift(seconds:3600));rule.created = .shift(seconds:30)
        let report = AttributeEngine.execute(try AttributePlan.prepare(sources:[source],rule:rule)),undo = AttributeEngine.undo(report.receipts);XCTAssertTrue(undo.errors.isEmpty,undo.errors.joined(separator:"\n"));let after = try attributeStat(source)
        XCTAssertEqual(before.st_mode,after.st_mode);XCTAssertEqual(before.st_birthtimespec.tv_sec,after.st_birthtimespec.tv_sec);XCTAssertEqual(before.st_birthtimespec.tv_nsec,after.st_birthtimespec.tv_nsec);XCTAssertEqual(before.st_mtimespec.tv_sec,after.st_mtimespec.tv_sec);XCTAssertEqual(before.st_mtimespec.tv_nsec,after.st_mtimespec.tv_nsec);XCTAssertEqual(try read(source),"original")
    }
    func testAttributeUndoRejectsChangedFileEvenWithRestoredSizeAndModificationTime() throws {
        let source = try file("a.txt","old!");let report = AttributeEngine.execute(try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600))),after = try AttributeSnapshot.read(source)
        try Data("new!".utf8).write(to:source);try FileManager.default.setAttributes([.modificationDate:after.modified.date],ofItemAtPath:source.path)
        let undo = AttributeEngine.undo(report.receipts);XCTAssertFalse(undo.errors.isEmpty);XCTAssertEqual(try attributeStat(source).st_mode & 0o777,0o600);XCTAssertEqual(try read(source),"new!")
    }
    func testAttributeUndoRejectsReplacementSymlinkAndPreservesOutsideObject() throws {
        let source = try file("a.txt","source"),outside = try file("outside.txt","outside"),report = AttributeEngine.execute(try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600)))
        try FileManager.default.removeItem(at:source);try FileManager.default.createSymbolicLink(at:source,withDestinationURL:outside)
        XCTAssertFalse(AttributeEngine.undo(report.receipts).errors.isEmpty);XCTAssertEqual(try attributeStat(outside).st_mode & 0o777,0o644);XCTAssertEqual(try read(outside),"outside")
    }
    func testAttributeBoundedPlanRejectsExcessiveSelectionAndDepth() throws {
        let many = (0...AttributePlan.maximumItems).map { root.appendingPathComponent(String($0)) };XCTAssertThrowsError(try AttributePlan.prepare(sources:many,rule:attributeRule(mode:0o600)))
        let directory = try folder("Deep");var child = directory;for _ in 0...AttributePlan.maximumDepth { child.appendPathComponent("d");try FileManager.default.createDirectory(at:child,withIntermediateDirectories:false) }
        XCTAssertThrowsError(try AttributePlan.prepare(sources:[directory],rule:attributeRule(mode:0o700,recursive:true)))
    }
    func testAttributeEmptyDirectoriesAreIncludedWithoutInventingFiles() throws {
        let directory = try folder("Tree/Empty"),plan = try AttributePlan.prepare(sources:[directory],rule:attributeRule(mode:0o700,recursive:true));XCTAssertEqual(plan.rows.count,1);let report = AttributeEngine.execute(plan);XCTAssertTrue(report.errors.isEmpty);XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path),[])
    }
    func testAttributeOverflowProducesVisibleNonSelectableRow() throws {
        let source = try file("a.txt"),plan = try AttributePlan.prepare(sources:[source],rule:attributeRule(modified:.shift(seconds:Int64.max)))
        XCTAssertFalse(plan.canApply);XCTAssertNotNil(plan.rows[0].reason);XCTAssertFalse(plan.rows[0].canSelect)
    }
    func testAttributeReadonlyAndInvalidTypeRulesCannotAuthorizeChanges() throws {
        var rule = AttributeRule();rule.files = false;rule.folders = false;XCTAssertThrowsError(try rule.validate());rule.files = true;rule.permissions = 0o10000;XCTAssertThrowsError(try rule.validate());rule.permissions = 0o600;rule.filter.structureOnly = true;XCTAssertThrowsError(try rule.validate())
        XCTAssertThrowsError(try AttributePlan.prepare(sources:[URL(string:"ftp://example.invalid/a")!],rule:attributeRule(mode:0o600)));XCTAssertThrowsError(try AttributePlan.prepare(sources:[URL(fileURLWithPath:"/")],rule:attributeRule(mode:0o600)))
    }
    func testAttributeRestrictiveModeAppliesDescendantsBeforeDirectory() throws {
        let directory = try folder("Tree"),child = try file("Tree/a.txt","keep");defer { _ = chmod(directory.path,0o755);_ = chmod(child.path,0o644) }
        let plan = try AttributePlan.prepare(sources:[directory],rule:attributeRule(mode:0o000,recursive:true));let report = AttributeEngine.execute(plan)
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(report.completed.last,attributeURL(directory));XCTAssertEqual(try attributeStat(directory).st_mode & 0o777,0)
        let undone = AttributeEngine.undo(report.receipts);XCTAssertTrue(undone.errors.isEmpty,undone.errors.joined(separator:"\n"));XCTAssertEqual(try attributeStat(directory).st_mode & 0o777,0o755);XCTAssertEqual(try attributeStat(child).st_mode & 0o777,0o644)
    }
    func testAttributeCompletedProgressParentMoveRetainsActualReceiptPath() throws {
        let a = try file("Selected/a.txt","A"),b = try file("Selected/b.txt","B"),outside = try file("Outside/a.txt","outside"),plan = try AttributePlan.prepare(sources:[a,b],rule:attributeRule(mode:0o600));var moved = false
        let report = AttributeEngine.execute(plan,progress:{ value in
            if !moved,value.items.contains(where:{$0.state == .completed}) { moved = true;try! FileManager.default.moveItem(at:self.root.appendingPathComponent("Selected"),to:self.root.appendingPathComponent("Moved"));try! FileManager.default.createSymbolicLink(at:self.root.appendingPathComponent("Selected"),withDestinationURL:outside.deletingLastPathComponent()) }
        })
        let actual = root.appendingPathComponent("Moved/a.txt");XCTAssertTrue(moved);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.completed,[attributeURL(actual)]);XCTAssertEqual(report.receipts.map(\.source),[attributeURL(actual)]);XCTAssertEqual(try attributeStat(outside).st_mode & 0o777,0o644);XCTAssertEqual(try attributeStat(root.appendingPathComponent("Moved/b.txt")).st_mode & 0o777,0o644)
        XCTAssertTrue(AttributeEngine.undo(report.receipts).errors.isEmpty);XCTAssertEqual(try attributeStat(actual).st_mode & 0o777,0o644)
    }
    func testAttributeFinalProgressParentMoveRebasesReceiptBeforeReturning() throws {
        let source = try file("Selected/a.txt","A"),plan = try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600));var moved = false
        let report = AttributeEngine.execute(plan,progress:{ value in if !moved,value.detail == "Eigenschaftsänderungen abgeschlossen" { moved = true;try! FileManager.default.moveItem(at:self.root.appendingPathComponent("Selected"),to:self.root.appendingPathComponent("Moved")) } })
        let actual = root.appendingPathComponent("Moved/a.txt");XCTAssertTrue(moved);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.receipts.map(\.source),[attributeURL(actual)]);XCTAssertEqual(report.completed,[attributeURL(actual)]);XCTAssertTrue(AttributeEngine.undo(report.receipts).errors.isEmpty);XCTAssertEqual(try attributeStat(actual).st_mode & 0o777,0o644)
    }
    func testAttributeCompletedRootDirectoryMoveRebasesAllChildReceipts() throws {
        let directory = try folder("Selected"),child = try file("Selected/a.txt","A"),plan = try AttributePlan.prepare(sources:[directory],rule:attributeRule(mode:0o700,recursive:true));var moved = false
        let report = AttributeEngine.execute(plan,progress:{ value in if !moved,value.items.allSatisfy({$0.state == .completed}) { moved = true;try! FileManager.default.moveItem(at:directory,to:self.root.appendingPathComponent("Moved")) } })
        XCTAssertTrue(moved);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(Set(report.receipts.map { $0.source.path }),Set([attributeURL(root.appendingPathComponent("Moved")).path,attributeURL(root.appendingPathComponent("Moved/a.txt")).path]));XCTAssertFalse(FileSystem.exists(child));let undo = AttributeEngine.undo(report.receipts);XCTAssertEqual(undo.errors.count,1);XCTAssertEqual(undo.completed,[attributeURL(root.appendingPathComponent("Moved/a.txt"))]);XCTAssertEqual(try attributeStat(root.appendingPathComponent("Moved")).st_mode & 0o777,0o700);XCTAssertEqual(try attributeStat(root.appendingPathComponent("Moved/a.txt")).st_mode & 0o777,0o644)
    }
    func testAttributeExternalWriteAfterCompletedCallbackDoesNotAcquireFreshUndoSeal() throws {
        let source = try file("a.txt","old!"),plan = try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600));var changed = false
        let report = AttributeEngine.execute(plan,progress:{ value in if !changed,value.items.contains(where:{$0.state == .completed}) { changed = true;try! Data("new!".utf8).write(to:source) } })
        XCTAssertTrue(changed);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.receipts.count,1);XCTAssertFalse(AttributeEngine.undo(report.receipts).errors.isEmpty);XCTAssertEqual(try read(source),"new!");XCTAssertEqual(try attributeStat(source).st_mode & 0o777,0o600)
    }
    func testAttributeInitiallyUnreadableFileHasExplicitNonSelectablePreviewRow() throws {
        let source = try file("a.txt","keep");XCTAssertEqual(chmod(source.path,0),0);defer { _ = chmod(source.path,0o644) }
        let plan = try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600));XCTAssertFalse(plan.canApply);XCTAssertFalse(plan.rows[0].canSelect);XCTAssertTrue(plan.rows[0].reason?.contains("nicht lesbar") == true);XCTAssertEqual(try attributeStat(source).st_mode & 0o777,0)
    }
    func testAttributeRestrictiveDescriptorReservationFailurePrecedesAllMutations() throws {
        let sources = try (0..<40).map { try file(String(format:"%02d.txt",$0),"keep") },plan = try AttributePlan.prepare(sources:sources,rule:attributeRule(mode:0o000))
        var limits = rlimit();XCTAssertEqual(getrlimit(RLIMIT_NOFILE,&limits),0);var reduced = limits;reduced.rlim_cur = 32
        guard setrlimit(RLIMIT_NOFILE,&reduced) == 0 else { throw CommanderError.message("Descriptor-Testgrenze nicht gesetzt") };defer { _ = setrlimit(RLIMIT_NOFILE,&limits) }
        let report = AttributeEngine.execute(plan);XCTAssertEqual(setrlimit(RLIMIT_NOFILE,&limits),0)
        XCTAssertFalse(report.errors.isEmpty);XCTAssertTrue(report.completed.isEmpty);XCTAssertTrue(report.receipts.isEmpty)
        for source in sources { XCTAssertEqual(try attributeStat(source).st_mode & 0o777,0o644) }
    }
    func testAttributeUndoGuardsExplicitAccessTimeAgainstLaterAccessChanges() throws {
        let source = try file("a.txt","keep");var rule = AttributeRule();rule.accessed = .absolute(try AttributeTimestamp(seconds:1_400_000_000))
        let report = AttributeEngine.execute(try AttributePlan.prepare(sources:[source],rule:rule));XCTAssertTrue(report.errors.isEmpty)
        let fd = open(source.path,O_RDONLY);guard fd >= 0 else { throw CommanderError.message("Testdatei nicht lesbar") };defer { close(fd) }
        var list = attrlist();list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT);list.commonattr = attrgroup_t(ATTR_CMN_ACCTIME);var access = timespec(tv_sec:1_400_000_100,tv_nsec:0);XCTAssertEqual(fsetattrlist(fd,&list,&access,MemoryLayout<timespec>.size,0),0)
        let undone = AttributeEngine.undo(report.receipts);XCTAssertFalse(undone.errors.isEmpty);XCTAssertEqual(try attributeStat(source).st_atimespec.tv_sec,1_400_000_100)
    }
    func testAttributeLeafMoveWithSameSizeRestoredMtimeEditCannotResealUndo() throws {
        let source = try file("a.txt","old!");try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_000)],ofItemAtPath:source.path)
        let moved = root.appendingPathComponent("Renamed.txt"),plan = try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600));var changed = false
        let report = AttributeEngine.execute(plan,progress:{ value in if !changed,value.items.contains(where:{$0.state == .completed}) {
            changed = true;try! Data("new!".utf8).write(to:source);try! FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSince1970:1_700_000_000)],ofItemAtPath:source.path);try! FileManager.default.moveItem(at:source,to:moved)
        } })
        XCTAssertTrue(changed);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.receipts.map(\.source),[attributeURL(moved)]);XCTAssertFalse(AttributeEngine.undo(report.receipts).errors.isEmpty);XCTAssertEqual(try read(moved),"new!");XCTAssertEqual(try attributeStat(moved).st_mode & 0o777,0o600)
    }
    func testAttributeEarlierCompletedLeafMoveOnLaterCallbackIsReportedAndRebased() throws {
        let a = try file("a.txt","A"),b = try file("b.txt","B"),moved = root.appendingPathComponent("Moved-A.txt"),plan = try AttributePlan.prepare(sources:[a,b],rule:attributeRule(mode:0o600));var renamed = false
        let report = AttributeEngine.execute(plan,progress:{ value in if !renamed,value.detail == "Eigenschaften ändern · b.txt" { renamed = true;try! FileManager.default.moveItem(at:a,to:moved) } })
        XCTAssertTrue(renamed);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.completed,[attributeURL(moved)]);XCTAssertEqual(report.receipts.map(\.source),[attributeURL(moved)]);XCTAssertEqual(try attributeStat(b).st_mode & 0o777,0o644)
        XCTAssertFalse(AttributeEngine.undo(report.receipts).errors.isEmpty);XCTAssertEqual(try attributeStat(moved).st_mode & 0o777,0o600);XCTAssertEqual(try read(moved),"A")
    }
    func testAttributeCompletedLeafDeletionProducesConflictInsteadOfSuccess() throws {
        let source = try file("a.txt","keep"),plan = try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600));var deleted = false
        let report = AttributeEngine.execute(plan,progress:{ value in if !deleted,value.items.contains(where:{$0.state == .completed}) { deleted = true;try! FileManager.default.removeItem(at:source) } })
        XCTAssertTrue(deleted);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.receipts.count,1);XCTAssertFalse(FileSystem.exists(source));XCTAssertFalse(AttributeEngine.undo(report.receipts).errors.isEmpty)
    }
    func testAttributeFinalCallbackDeletionCannotReturnSuccess() throws {
        let source = try file("a.txt","keep"),plan = try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600));var deleted = false
        let report = AttributeEngine.execute(plan,progress:{ value in if !deleted,value.detail == "Eigenschaftsänderungen abgeschlossen" { deleted = true;try! FileManager.default.removeItem(at:source) } })
        XCTAssertTrue(deleted);XCTAssertFalse(report.errors.isEmpty);XCTAssertEqual(report.receipts.count,1);XCTAssertFalse(FileSystem.exists(source))
    }
    func testAttributeUndoFinalCallbackMoveReturnsActualCompletedPathAndConflict() throws {
        let source = try file("a.txt","keep"),moved = root.appendingPathComponent("Restored-Moved.txt"),report = AttributeEngine.execute(try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600)));var renamed = false
        let undone = AttributeEngine.undo(report.receipts,progress:{ value in if !renamed,value.detail == "Rücknahme abgeschlossen" { renamed = true;try! FileManager.default.moveItem(at:source,to:moved) } })
        XCTAssertTrue(renamed);XCTAssertFalse(undone.errors.isEmpty);XCTAssertEqual(undone.completed,[attributeURL(moved)]);XCTAssertFalse(FileSystem.exists(source));XCTAssertEqual(try attributeStat(moved).st_mode & 0o777,0o644);XCTAssertEqual(try read(moved),"keep")
    }
    func testAttributeUndoCompletedLeafDeletionProducesConflict() throws {
        let source = try file("a.txt","keep"),report = AttributeEngine.execute(try AttributePlan.prepare(sources:[source],rule:attributeRule(mode:0o600)));var deleted = false
        let undone = AttributeEngine.undo(report.receipts,progress:{ value in if !deleted,value.detail.hasPrefix("Eigenschaften zurückgenommen ·") { deleted = true;try! FileManager.default.removeItem(at:source) } })
        XCTAssertTrue(deleted);XCTAssertFalse(undone.errors.isEmpty);XCTAssertFalse(FileSystem.exists(source))
    }
    func testAttributeRecursiveReadOnlyModeRetainsDescendantUndoAfterReturn() throws {
        let directory = try folder("Tree"),sub = try folder("Tree/Sub"),child = try file("Tree/Sub/a.txt","keep");defer { _ = chmod(directory.path,0o755);_ = chmod(sub.path,0o755);_ = chmod(child.path,0o644) }
        let report = AttributeEngine.execute(try AttributePlan.prepare(sources:[directory],rule:attributeRule(mode:0o400,recursive:true)))
        XCTAssertTrue(report.errors.isEmpty,report.errors.joined(separator:"\n"));XCTAssertEqual(report.receipts.count,3)
        let undone = AttributeEngine.undo(report.receipts);XCTAssertTrue(undone.errors.isEmpty,undone.errors.joined(separator:"\n"));XCTAssertEqual(undone.completed.count,3);XCTAssertEqual(try attributeStat(directory).st_mode & 0o777,0o755);XCTAssertEqual(try attributeStat(sub).st_mode & 0o777,0o755);XCTAssertEqual(try attributeStat(child).st_mode & 0o777,0o644);XCTAssertEqual(try read(child),"keep")
    }
}
