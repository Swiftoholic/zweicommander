import AppKit
import CommanderCore

extension AppDelegate {
    func runArchiveEditSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            @MainActor func check(_ value:Bool,_ name:String) { checks += 1;print("ARCHIVE EDIT UI \(value ? "PASS" : "FAIL") "+name);if !value { failures.append(name);print("ARCHIVE EDIT UI CONTEXT active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none")") } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("ARCHIVE EDIT SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async { for _ in 0..<700 { if predicate() { return };try? await Task.sleep(nanoseconds:30_000_000) };print("ARCHIVE EDIT SMOKE FAIL timeout "+name);exit(1) }
            @MainActor func ready(_ editor:ArchiveEditController) async { await wait("editor preparation") { !editor.isPreparing && !editor.isWorking } }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active editor") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func key(_ window:NSWindow,_ text:String,_ flags:NSEvent.ModifierFlags = []) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0),"key event") }
            @MainActor func select(_ editor:ArchiveEditController,_ path:String) { if let row = editor.rows.firstIndex(where:{$0.originalPath == path}) { editor.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);editor.window?.makeFirstResponder(editor.table) } }
            @MainActor func capture(_ window:NSWindow,_ suffix:String) throws { let view = require(window.contentView,"content");view.layoutSubtreeIfNeeded();view.displayIfNeeded();let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap");view.cacheDisplay(in:view.bounds,to:bitmap);try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+suffix+".png")) }
            @MainActor func editable(_ view:NSView) -> NSTextField? { if let field = view as? NSTextField,field.isEditable { return field };for child in view.subviews { if let field = editable(child) { return field } };return nil }
            do {
                let links = FileSystem.canonical(root.appendingPathComponent("Links")),docs = links.appendingPathComponent("Input/Docs"),added = links.appendingPathComponent("Added/Extra.txt"),collision = links.appendingPathComponent("Added/Keep.txt"),archive = links.appendingPathComponent("Bearbeiten.zip")
                try FileManager.default.createDirectory(at:docs,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:added.deletingLastPathComponent(),withIntermediateDirectories:true)
                for (name,body) in [("Keep.txt","keep"),("Old.txt","rename"),("Remove.txt","remove")] { try Data(body.utf8).write(to:docs.appendingPathComponent(name)) }
                try Data("extra".utf8).write(to:added);try Data("collision".utf8).write(to:collision);try ArchiveService.pack([docs],to:archive)
                let original = try Data(contentsOf:archive),clipboard = NSPasteboard.general.changeCount
                self.main.active.navigate(links);self.main.active.refresh();await wait("main listing") { !self.main.active.isLoading && self.main.active.canUseDisplayedEntries && self.main.active.visibleEntries.contains { $0.name == archive.lastPathComponent } }
                self.main.active.select([archive]);await activate(self.main.window!);self.main.active.focus();self.main.saveState()
                let state = try JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences.state)) as! [String:Any]
                check(self.main.archiveCommandEnabled("archiveEdit") == true,"local regular archive enables editing")
                self.main.showArchiveEditor();let editor = require(self.main.secondaryWindows.last as? ArchiveEditController,"archive editor"),window = require(editor.window as? WorkflowWindow,"workflow window")
                await activate(window);await ready(editor)
                check(editor.plan?.format == .zip && editor.rows.count == 4,"checked original inventory includes files and directory")
                check(editor.plan?.hasChanges == false && !editor.apply.isEnabled,"unchanged inventory cannot publish")
                check(editor.add.toolTip?.contains("⌘O") == true && editor.apply.toolTip?.contains("⌘↩") == true,"hover help exposes scoped shortcuts")
                check(!window.canPerformCommand("trash") && !window.canPerformCommand("move"),"editor blocks hidden pane mutations")
                check(window.performKeyEquivalent(with:key(window,"f",.command)) && editor.filter.currentEditor() is NSTextView,"Command F focuses the result filter")
                editor.filter.stringValue = "Keep";editor.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:editor.filter))
                check(editor.rows.count == 1 && editor.rows[0].path == "Docs/Keep.txt","path filter narrows only the review rows")
                editor.filter.stringValue = "";editor.filterRows();window.makeFirstResponder(editor.table)
                select(editor,"Docs/Old.txt")
                check(window.performKeyEquivalent(with:key(window,String(UnicodeScalar(NSF2FunctionKey)!))),"F2 opens a scoped rename sheet")
                let renameSheet = require(window.attachedSheet,"rename sheet"),field = require(editable(renameSheet.contentView!),"rename field")
                if let text = field.currentEditor() as? NSTextView { text.selectAll(nil);text.insertText("Manual/Renamed.txt",replacementRange:text.selectedRange()) } else { field.stringValue = "Manual/Renamed.txt" }
                renameSheet.makeFirstResponder(nil);window.endSheet(renameSheet,returnCode:.alertFirstButtonReturn)
                await wait("staged rename") { editor.renames["Docs/Old.txt"] == "Manual/Renamed.txt" };await ready(editor)
                check(editor.plan?.rows.contains(where:{$0.originalPath == "Docs/Old.txt" && $0.path == "Manual/Renamed.txt" && $0.action == .rename}) == true,"rename is staged as an explicit member path change")
                check(try Data(contentsOf:archive) == original,"staged rename leaves original archive byte-identical")
                await activate(window);select(editor,"Docs/Remove.txt")
                check(window.performKeyEquivalent(with:key(window,"\u{7f}")),"Delete stages selected archive removal")
                await ready(editor)
                check(editor.plan?.rows.filter{$0.action == .remove}.count == 1,"removal remains visible and counted in the review")
                try editor.stageAdd([added],under:"New");await ready(editor)
                check(editor.plan?.rows.contains(where:{$0.path == "New/Extra.txt" && $0.action == .add}) == true,"local addition targets a relative archive folder")
                check(editor.summary.stringValue.contains("1 hinzufügen") && editor.summary.stringValue.contains("1 entfernen"),"summary counts all staged action kinds")
                check(editor.plan?.outputCount == 4 && editor.plan?.totalBytes == 15,"result inventory and bytes include retained and added content")
                check(try Data(contentsOf:archive) == original,"combined staging has not modified archive bytes")
                editor.filter.stringValue = "Keep";editor.filterRows()
                check(editor.rows.count == 1 && editor.plan?.changedCount == 3 && editor.apply.isEnabled,"filtered review cannot hide changes from execution counts")
                editor.filter.stringValue = "";editor.filterRows();window.makeFirstResponder(editor.table)
                for (theme,name) in [(1,"Hell"),(2,"Dunkel")] {
                    Preferences.state.theme = theme;self.main.applyTheme();try? await Task.sleep(nanoseconds:150_000_000)
                    check(window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (theme == 1 ? .aqua : .darkAqua),"archive editor follows "+name+" appearance")
                    try capture(window,"-Archivbearbeitung-"+name)
                }
                window.contentView?.layoutSubtreeIfNeeded()
                check(editor.scroll.frame.maxY < editor.filter.frame.minY && editor.info.frame.maxY < editor.formatInfo.frame.minY,"table and review controls do not overlap")
                await activate(window);window.makeFirstResponder(editor.table)
                check(window.performKeyEquivalent(with:key(window,"\r",.command)) && editor.reviewAlert != nil,"Command Return opens final reviewed confirmation")
                let review = require(editor.reviewAlert,"final confirmation")
                check(review.informativeText.contains("1 entfernen") && window.attachedSheet === review.window,"final confirmation retains removal count and attached sheet scope")
                check(try Data(contentsOf:archive) == original,"opening final confirmation still leaves original unchanged")
                window.endSheet(review.window,returnCode:.alertSecondButtonReturn);await wait("cancel review") { editor.reviewAlert == nil }
                check(editor.plan?.hasChanges == true && !editor.isWorking,"canceling confirmation retains staged changes without a job")
                editor.discardChanges();await ready(editor)
                check(editor.plan?.hasChanges == false && editor.additions.isEmpty && editor.renames.isEmpty && editor.removals.isEmpty,"discard clears only the staged edit")
                try editor.stageAdd([collision],under:"Docs");await ready(editor)
                check(editor.plan == nil && !editor.apply.isEnabled && editor.info.textColor == .systemRed,"path collision disables publication with inline diagnosis")
                check(try Data(contentsOf:archive) == original,"failed validation preserves exact original bytes")
                editor.discardChanges();await ready(editor)
                var unsafe = false;do { try editor.stageAdd([added],under:"../Outside") } catch { unsafe = true }
                check(unsafe && editor.additions.isEmpty,"unsafe relative folder input cannot stage an addition")
                editor.prepare();editor.cancelWork();try? await Task.sleep(nanoseconds:200_000_000)
                check(!editor.isPreparing && editor.plan == nil && !editor.apply.isEnabled,"canceling preparation rejects late plans")
                editor.prepare();await ready(editor);try editor.stageRename("Docs/Old.txt",to:"Manual/Renamed.txt");await ready(editor);editor.stageRemove(["Docs/Remove.txt"]);await ready(editor);try editor.stageAdd([added],under:"New");await ready(editor)
                await activate(window);editor.apply.performClick(nil);let confirm = require(editor.reviewAlert,"execution confirmation");window.endSheet(confirm.window,returnCode:.alertFirstButtonReturn)
                await wait("job accepted") { editor.isWorking || editor.plan?.hasChanges == false }
                await wait("archive job completed") { !editor.isWorking && !editor.isPreparing && editor.plan?.hasChanges == false }
                let catalog = try ArchiveCatalog.read(archive),files = Set(catalog.members.filter{$0.isRegularFile}.map(\.path)),data = Dictionary(uniqueKeysWithValues:try ArchiveService.readMembers(archive,matching:files.contains))
                check(data["Docs/Keep.txt"] == Data("keep".utf8) && data["Manual/Renamed.txt"] == Data("rename".utf8),"queued native edit preserves retained and renamed bytes")
                check(data["New/Extra.txt"] == Data("extra".utf8) && data["Docs/Remove.txt"] == nil && data["Docs/Old.txt"] == nil,"queued native edit applies additions and reviewed removals")
                check(self.main.undoSteps.count == 1 && self.main.undoSteps.first?.backup != nil,"successful edit joins shared file undo")
                if let backup = self.main.undoSteps.first?.backup { check(try Data(contentsOf:backup) == original,"original archive backup is byte-identical") } else { check(false,"original archive backup is byte-identical") }
                check(editor.plan?.hasChanges == false && !editor.apply.isEnabled,"completed editor rebases onto the new checked archive")
                let errors = FileOperations.undo(self.main.undoSteps);check(errors.isEmpty,"shared undo accepts the unchanged edited archive")
                check(try Data(contentsOf:archive) == original,"shared undo restores the exact original archive")
                editor.close();check(window.isVisible == false,"closing editor leaves no active workspace")
                check(NSPasteboard.general.changeCount == clipboard,"archive editing leaves the user's clipboard untouched")
                let after = try JSONSerialization.jsonObject(with:JSONEncoder().encode(Preferences.state)) as! [String:Any]
                check((state["left"] as? NSArray) == (after["left"] as? NSArray) && (state["right"] as? NSArray) == (after["right"] as? NSArray),"archive editing leaves normal pane tab locations unchanged")
                print("ARCHIVE EDIT SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");fflush(stdout);exit(failures.isEmpty ? 0 : 1)
            } catch { print("ARCHIVE EDIT SMOKE FAIL "+error.localizedDescription);fflush(stdout);exit(1) }
        }
    }
}
