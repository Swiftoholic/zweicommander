import AppKit
import CommanderCore

extension AppDelegate {
    func runFileDiffSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("FILE DIFF UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("FILE DIFF SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<400 { if predicate() { return };try? await Task.sleep(nanoseconds:40_000_000) }
                print("FILE DIFF SMOKE FAIL timeout "+name+" active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "none")");exit(1)
            }
            @MainActor func activate(_ window:NSWindow) async { window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);await wait("active window") { NSApp.isActive && window.isKeyWindow } }
            @MainActor func key(_ window:NSWindow,_ text:String,_ modifiers:NSEvent.ModifierFlags = []) -> NSEvent { require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:0),"key event") }
            @MainActor func settled(_ form:FileDiffController) async { await wait("file comparison") { !form.isComparing } }
            @MainActor func capture(_ window:NSWindow,_ name:String) throws {
                let view = require(window.contentView,"content view");view.layoutSubtreeIfNeeded();view.displayIfNeeded();let bitmap = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"bitmap")
                view.cacheDisplay(in:view.bounds,to:bitmap);try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+name+".png"))
            }
            @MainActor func item(_ id:String) -> NSMenuItem? { NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first { $0.representedObject as? String == id } }
            @MainActor func select(_ pane:PaneView,_ names:Set<String>) { pane.select(Set(pane.visibleEntries.filter { names.contains($0.name) }.map(\.url)));pane.focus() }
            let main = self.main!,window = require(main.window,"main window"),left = root.appendingPathComponent("Links"),right = root.appendingPathComponent("Rechts")
            let alphaLeft = left.appendingPathComponent("Alpha.txt"),alphaRight = right.appendingPathComponent("Alpha.txt"),betaLeft = left.appendingPathComponent("Beta.txt"),betaRight = right.appendingPathComponent("Beta.txt")
            let blobLeft = left.appendingPathComponent("Blob.bin"),blobRight = right.appendingPathComponent("Blob.bin"),manyLeft = left.appendingPathComponent("Many.txt"),manyRight = right.appendingPathComponent("Many.txt")
            let alphaA = Data("Kopf\nAlt\nMitte\nNur links\nEnde\n".utf8),alphaB = Data("Start\nKopf\nNeu\nMitte\nEnde\nSchluss\n".utf8),clipboard = NSPasteboard.general.changeCount
            do {
                try FileManager.default.createDirectory(at:left,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:right,withIntermediateDirectories:true)
                try alphaA.write(to:alphaLeft);try alphaB.write(to:alphaRight);try Data("alpha \nBETA\r\n".utf8).write(to:betaLeft);try Data("ALPHA\nbeta\n".utf8).write(to:betaRight)
                try Data([0,1,2,3]).write(to:blobLeft);try Data([0,9,8,3,4,5]).write(to:blobRight)
                let common = (0..<1000).map { "Zeile \($0)\n" }.joined();try Data((common+"alt\n"+common).utf8).write(to:manyLeft);try Data((common+"neu\n"+common).utf8).write(to:manyRight)
                try Data("nur links".utf8).write(to:left.appendingPathComponent("OnlyLeft.txt"));try FileManager.default.createSymbolicLink(at:left.appendingPathComponent("Link.txt"),withDestinationURL:alphaLeft)
                main.left.navigate(left);main.right.navigate(right)
                await wait("pane listings") { !main.left.isLoading && !main.right.isLoading && !main.left.isSorting && !main.right.isSorting && main.left.visibleEntries.contains {$0.name == "Alpha.txt"} }
                await activate(window);let menu = require(item("fileCompare"),"file comparison menu")
                check(menu.keyEquivalent.lowercased() == "v" && menu.keyEquivalentModifierMask.intersection([.command,.option,.shift,.control]) == [.command,.option],"file comparison has a system-compatible Command Option V shortcut")
                main.right.select([]);select(main.left,["Alpha.txt","Link.txt"]);check(!self.validateMenuItem(menu),"main menu refuses a link as comparison input")
                select(main.left,["Alpha.txt","Beta.txt"]);check(self.validateMenuItem(menu),"two selected regular files enable comparison")
                main.command("fileCompare");let first = require(main.secondaryWindows.last as? FileDiffController,"selected files comparison")
                check(first.isComparing && !first.refresh.isEnabled,"comparison starts asynchronously with guarded controls");await settled(first)
                check(Set([URL(fileURLWithPath:first.leftPath.stringValue).lastPathComponent,URL(fileURLWithPath:first.rightPath.stringValue).lastPathComponent]) == ["Alpha.txt","Beta.txt"],"two active-pane files populate both comparison sides")
                first.close();check(first.result == nil && first.visibleRows.isEmpty,"closing releases the retained comparison report")
                await activate(window);select(main.right,["Alpha.txt"]);select(main.left,["Alpha.txt"])
                check(self.validateMenuItem(menu),"one selected file per side enables comparison")
                check(NSApp.mainMenu?.performKeyEquivalent(with:key(window,"v",[.command,.option])) == true,"native main menu dispatches Command Option V")
                let form = require(main.secondaryWindows.last as? FileDiffController,"cross-pane comparison"),diffWindow = require(form.window as? WorkflowWindow,"diff window")
                await settled(form);await activate(diffWindow)
                check(form.result?.left.url.lastPathComponent == "Alpha.txt" && form.result?.right.url.lastPathComponent == "Alpha.txt" && form.result?.left.url.deletingLastPathComponent() != form.result?.right.url.deletingLastPathComponent(),"cross-pane selection preserves both real source locations")
                check(form.result?.changedRows == 1 && form.result?.addedRows == 2 && form.result?.removedRows == 1 && form.result?.differenceStarts.count == 4,"native result contains changed added removed and equal lines")
                check(form.table.tableColumns.map(\.identifier.rawValue) == ["kind","leftPosition","left","rightPosition","right"],"comparison displays paired content and independent positions")
                check(diffWindow.performKeyEquivalent(with:key(diffWindow,String(UnicodeScalar(NSDownArrowFunctionKey)!),[.command,.option])) && form.table.selectedRow == 0,"Command Option Down selects the first difference")
                let firstDifference = form.table.selectedRow
                check(diffWindow.performKeyEquivalent(with:key(diffWindow,String(UnicodeScalar(NSF7FunctionKey)!))) && form.table.selectedRow > firstDifference,"F7 advances to the next difference")
                check(diffWindow.performKeyEquivalent(with:key(diffWindow,String(UnicodeScalar(NSF7FunctionKey)!),.shift)) && form.table.selectedRow == firstDifference,"Shift F7 returns to the previous difference")
                check(diffWindow.performKeyEquivalent(with:key(diffWindow,String(UnicodeScalar(NSUpArrowFunctionKey)!),[.command,.option])) && form.table.selectedRow > firstDifference,"previous difference wraps to the last range")
                let total = form.visibleRows.count;form.differencesOnly.performClick(nil)
                check(form.visibleRows.count < total && form.visibleRows.allSatisfy {$0.kind != .equal},"differences-only hides equal rows without dropping the report")
                form.next.performClick(nil);check(form.position.stringValue.contains("Unterschied"),"difference navigation works in the filtered result")
                form.differencesOnly.performClick(nil)
                if let row = form.visibleRows.firstIndex(where:{$0.kind == .changed}) {
                    form.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)
                    check(form.leftText.string == "Alt" && form.rightText.string == "Neu" && form.leftDetail.stringValue.contains("Zeile"),"selected change exposes full original line contents")
                } else { check(false,"changed row detail") }
                diffWindow.contentView?.layoutSubtreeIfNeeded()
                check(form.table.rect(ofColumn:4).maxX <= form.table.visibleRect.maxX+1,"paired columns fit the initial comparison window")
                for (theme,name) in [(1,"Hell"),(2,"Dunkel")] {
                    Preferences.state.theme = theme;main.applyTheme();try? await Task.sleep(nanoseconds:150_000_000)
                    check(diffWindow.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (theme == 1 ? .aqua : .darkAqua),"file comparison follows "+name+" appearance");try capture(diffWindow,"-Dateivergleich-"+name)
                }
                check(form.leftPath.frame.maxX < form.chooseLeft.frame.minX && form.info.frame.maxY < form.leftText.enclosingScrollView!.frame.minY,"comparison path controls and detail footer do not overlap")
                check(diffWindow.performKeyEquivalent(with:key(diffWindow,"l",.command)) && form.leftPath.currentEditor() is NSTextView,"Command L edits the left source")
                check(!self.validateMenuItem(menu),"a comparison window cannot dispatch underlying pane comparison commands")
                check(diffWindow.performKeyEquivalent(with:key(diffWindow,"l",[.command,.shift])) && form.rightPath.currentEditor() is NSTextView,"Command Shift L edits the right source")
                form.rightPath.stringValue = root.appendingPathComponent("missing.txt").path;form.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:form.rightPath))
                check(form.result == nil && !form.next.isEnabled,"editing a source immediately invalidates the old report")
                form.beginCompare();await settled(form);check(form.result == nil && form.info.textColor == .systemRed,"missing source fails inline without a partial result")
                form.rightPath.stringValue = alphaRight.path;form.beginCompare();await settled(form)
                try Data("external edit\n".utf8).write(to:alphaLeft);form.next.performClick(nil)
                check(form.result == nil && !form.next.isEnabled && form.info.textColor == .systemOrange,"a later source edit invalidates difference navigation")
                check((try Data(contentsOf:alphaLeft)) == Data("external edit\n".utf8),"source revalidation preserves the external edit")
                try alphaA.write(to:alphaLeft);await activate(diffWindow)
                check(diffWindow.performKeyEquivalent(with:key(diffWindow,"r",.command)),"Command R requests a fresh comparison");await settled(form)
                check(form.result?.differenceStarts.count == 4,"refresh rebuilds a complete result from current files")
                form.leftPath.stringValue = blobLeft.path;form.rightPath.stringValue = blobRight.path;form.mode.selectItem(at:2);form.optionsChanged();await settled(form)
                check(form.result?.mode == .binary && form.result?.differentBytes == 4 && form.result?.rows.last?.rightPosition == 4,"binary comparison reports exact changed bytes and tail offsets")
                check(!form.encoding.isEnabled && !form.ignoreCase.isEnabled && !form.ignoreWhitespace.isEnabled,"binary mode disables irrelevant text rules")
                form.mode.selectItem(at:1);form.optionsChanged();await settled(form)
                check(form.result == nil && form.info.textColor == .systemRed,"forcing text on invalid binary bytes gives a clear error")
                form.mode.selectItem(at:0);form.optionsChanged();await settled(form)
                check(form.result?.mode == .binary,"automatic mode detects binary content")
                form.leftPath.stringValue = betaLeft.path;form.rightPath.stringValue = betaRight.path;form.mode.selectItem(at:1);form.beginCompare();await settled(form)
                check(form.result?.isEqual == false,"text rules begin with visible case and whitespace differences")
                form.ignoreCase.performClick(nil);await settled(form);check(form.result?.isEqual == false,"ignoring case keeps a whitespace difference visible")
                form.ignoreWhitespace.performClick(nil);await settled(form);check(form.result?.isEqual == true && form.result?.byteIdentical == false,"native text rule controls distinguish normalized equality from exact bytes")
                form.ignoreEndings.performClick(nil);await settled(form);check(form.result?.isEqual == false,"line-ending control exposes CRLF versus LF")
                let oldLeft = form.leftPath.stringValue,oldRight = form.rightPath.stringValue
                check(diffWindow.performKeyEquivalent(with:key(diffWindow,"u",.command)),"Command U swaps comparison sides");await settled(form)
                check(form.leftPath.stringValue == oldRight && form.rightPath.stringValue == oldLeft,"swapping retains both paths and recalculates")
                form.leftPath.stringValue = manyLeft.path;form.rightPath.stringValue = manyRight.path;form.beginCompare();form.cancel();await settled(form)
                check(form.result == nil && form.info.stringValue.contains("abgebrochen"),"cancelled work never exposes an executable or partial comparison")
                form.beginCompare();await settled(form)
                check(form.result?.rows.count == 2001 && form.table.numberOfRows == 2001 && form.result?.differenceStarts.count == 1,"large paired lists preserve the complete result beyond two thousand rows")
                form.beginCompare();form.close();try? await Task.sleep(nanoseconds:250_000_000)
                check(!form.isComparing && form.result == nil && form.visibleRows.isEmpty && form.leftText.string.isEmpty && form.rightText.string.isEmpty && form.window?.isVisible == false,"closing cancels work clears large buffers and rejects late callbacks")
                await activate(window);main.compare()
                let comparison = require(main.secondaryWindows.last as? CompareController,"folder comparison");comparison.beginCompare()
                await wait("folder comparison") { !comparison.isComparing && !comparison.isPreparingPlan && comparison.comparison != nil }
                await activate(require(comparison.window,"folder comparison window"))
                if let row = comparison.visibleRows.firstIndex(where:{$0.relativePath == "Alpha.txt"}) {
                    comparison.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);comparison.window?.makeFirstResponder(comparison.table)
                    check(comparison.fileCompare.isEnabled && comparison.canPerformCommand("fileCompare"),"folder comparison enables file diff for a complete regular file pair")
                    let count = main.secondaryWindows.count;comparison.fileCompare.performClick(nil)
                    await wait("folder-row diff") { main.secondaryWindows.count > count }
                    let child = require(main.secondaryWindows.last as? FileDiffController,"folder row comparison");await settled(child)
                    check(child.result?.differenceStarts.count == 4,"folder-row action opens the actual two-file comparison");child.close()
                } else { check(false,"folder-row file pair");check(false,"folder-row action") }
                if let row = comparison.visibleRows.firstIndex(where:{$0.relativePath == "OnlyLeft.txt"}) { comparison.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);check(!comparison.fileCompare.isEnabled,"one-sided folder results cannot start a two-file diff") } else { check(false,"one-sided folder result") }
                comparison.close();await activate(window)
                main.left.showCollection([alphaLeft,betaLeft],title:"Diff-Sammlung");await wait("collection") { !main.left.isLoading && main.left.visibleEntries.count == 2 };select(main.left,["Alpha.txt","Beta.txt"])
                check(!self.validateMenuItem(menu),"collection tabs do not masquerade as a local pane comparison source");main.left.closeTab()
                check(try Data(contentsOf:alphaLeft) == alphaA && Data(contentsOf:alphaRight) == alphaB,"all comparison actions preserve source contents")
                check(NSPasteboard.general.changeCount == clipboard,"file comparison checks leave the user's clipboard untouched")
            } catch { check(false,"unexpected error: "+error.localizedDescription) }
            print("FILE DIFF SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks");exit(failures.isEmpty ? 0 : 1)
        }
    }
}
