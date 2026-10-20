import AppKit
import CommanderCore

extension AppDelegate {
    func runNavigationSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures:[String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("NAV UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("NAV SMOKE FAIL missing "+name);exit(1) };return value }
            @MainActor func wait(_ name:String,_ predicate:()->Bool) async {
                for _ in 0..<140 { if predicate() { return };try? await Task.sleep(nanoseconds:50_000_000) }
                let field = self.main.left.pathField
                print("NAV SMOKE FAIL timed out "+name+" active=\(NSApp.isActive) key=\(NSApp.keyWindow === self.main.window) editing=\(field.sessionActive) querying=\(field.isQuerying) rows=\(field.suggestions.count) popup=\(field.dropdown.isVisible)");exit(1)
            }
            let pane = main.left,field = pane.pathField,bar = pane.breadcrumb,folder = root.appendingPathComponent("Links"),other = main.right.currentURL
            let documents = folder.appendingPathComponent("Dokumente"),space = folder.appendingPathComponent("Dokumente und Bilder"),unicode = folder.appendingPathComponent("Grüße aus Wien")
            let window = require(main.window,"window")
            @MainActor func type(_ text:String) {
                let editor = require(field.currentEditor() as? NSTextView,"field editor")
                editor.setSelectedRange(NSRange(location:0,length:(editor.string as NSString).length));editor.insertText(text,replacementRange:editor.selectedRange())
            }
            @MainActor func key(_ selector:Selector) { require(field.currentEditor() as? NSTextView,"field editor").doCommand(by:selector) }
            @MainActor func hover(_ button:ActionButton,_ entered:Bool) {
                let event = require(NSEvent.enterExitEvent(with:entered ? .mouseEntered : .mouseExited,location:button.convert(NSPoint(x:5,y:5),to:nil),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,trackingNumber:0,userData:nil),"hover event")
                if entered { button.mouseEntered(with:event) } else { button.mouseExited(with:event) }
            }
            @MainActor func pixel(_ button:ActionButton) -> NSColor {
                main.content.displayIfNeeded()
                let rep = require(main.content.bitmapImageRepForCachingDisplay(in:main.content.bounds),"bitmap");main.content.cacheDisplay(in:main.content.bounds,to:rep)
                let point = main.content.convert(NSPoint(x:4,y:4),from:button)
                return require(rep.colorAt(x:Int(point.x),y:Int(main.content.bounds.height-point.y-1)),"pixel")
            }
            @MainActor func capture(_ name:String) {
                main.content.layoutSubtreeIfNeeded();main.content.displayIfNeeded()
                let popups = [field.dropdown,bar.dropdown].filter(\.isVisible)
                let view = main.content
                let rep = require(view.bitmapImageRepForCachingDisplay(in:view.bounds),"window bitmap");view.cacheDisplay(in:view.bounds,to:rep)
                // Composite app-owned child windows into a neutral fixture screenshot.
                let result = NSImage(size:view.bounds.size);result.lockFocus();rep.draw(in:view.bounds)
                for popup in popups {
                    let content = popup.contentView;content.layoutSubtreeIfNeeded();content.displayIfNeeded()
                    if let child = content.window,let bitmap = content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                        content.cacheDisplay(in:content.bounds,to:bitmap)
                        let screen = child.convertToScreen(content.convert(content.bounds,to:nil)),rect = view.convert(window.convertFromScreen(screen),from:nil)
                        bitmap.draw(in:rect)
                    }
                }
                result.unlockFocus()
                let data = require(result.tiffRepresentation.flatMap { NSBitmapImageRep(data:$0)?.representation(using:.png,properties:[:]) },"PNG")
                do { try data.write(to:URL(fileURLWithPath:prefix+name+".png")) } catch { print("NAV SMOKE FAIL screenshot");exit(1) }
            }
            window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);main.content.layoutSubtreeIfNeeded()
            pane.showHidden = false;pane.refresh()
            await wait("initial folder") { !pane.isLoading }
            let places = [("System",URL(fileURLWithPath:"/")),("Projekte",folder),("Sicherung",other)]
            for p in [pane,main.right] { p.locations.configure(places);p.locations.select(p.currentURL) }
            let toolbar = main.content.toolbar.arrangedSubviews.compactMap { $0 as? ActionButton }
            let filter = require(toolbar.first { $0.identifier?.rawValue == "filter" },"filter button")
            check(toolbar.allSatisfy { ($0.toolTip ?? "").contains("\n") && $0.accessibilityHelp() == $0.toolTip },"toolbar actions expose descriptive tooltips and accessibility help")
            let savedKey = Preferences.state.shortcuts["filter"];Preferences.state.shortcuts["filter"] = "cmd+option+f";main.updateChromeState()
            check(filter.toolTip?.contains("⌘⌥F") == true,"hover help uses the configured shortcut")
            Preferences.state.shortcuts["filter"] = savedKey;main.updateChromeState()
            for theme in [1,2] {
                main.themeMenu.selectItem(at:theme);main.themeChosen();main.content.layoutSubtreeIfNeeded()
                let button = require(main.content.toolbar.arrangedSubviews.compactMap { $0 as? ActionButton }.first { $0.identifier?.rawValue == "filter" },"rebuilt filter button")
                button.updateTrackingAreas();hover(button,false);let normal = pixel(button);hover(button,true);let highlighted = pixel(button)
                check(button.isHovered && abs(CommanderPalette.luminance(normal)-CommanderPalette.luminance(highlighted)) > 0.02,"hover visibly highlights an enabled button in theme \(theme)")
                check(button.trackingAreas.contains { $0.options.contains(.mouseEnteredAndExited) && $0.options.contains(.inVisibleRect) },"hover tracks the visible button surface in theme \(theme)")
                hover(button,false);check(!button.isHovered,"leaving the button clears hover in theme \(theme)")
            }
            let details = require(main.content.toolbar.arrangedSubviews.compactMap { $0 as? ActionButton }.first { $0.identifier?.rawValue == "details" },"details button")
            hover(details,false);let selected = pixel(details);hover(details,true)
            check(details.state == .on && abs(CommanderPalette.luminance(pixel(details))-CommanderPalette.luminance(selected)) > 0.02,"hover remains visible on an already selected control");hover(details,false)
            let copy = require(main.content.functionBar.arrangedSubviews.compactMap { $0 as? ActionButton }.first { $0.identifier?.rawValue == "copy" },"copy button")
            pane.selectionIndexes = [];hover(copy,false);let disabled = pixel(copy);hover(copy,true)
            check(!copy.isEnabled && abs(CommanderPalette.luminance(pixel(copy))-CommanderPalette.luminance(disabled)) < 0.001,"disabled controls retain their disabled appearance on hover");hover(copy,false)
            check(pane.navigationButtons["back"]?.isEnabled == false && pane.navigationButtons["back"]?.toolTip?.contains("noch keinen") == true,"unavailable history explains why its button is disabled")
            main.command("path")
            check(field.sessionActive && field.currentEditor() != nil,"address editing keeps native text focus")
            type("Dok");await wait("prefix completion") { !field.isQuerying && field.suggestions.count == 2 && field.dropdown.isVisible }
            check(field.suggestions.map(\.title) == ["Dokumente","Dokumente und Bilder"],"typing suggests matching folders in natural order")
            check(field.currentEditor() != nil && NSApp.keyWindow === window,"the suggestion window never takes the keyboard focus")
            check(!field.suggestions.contains { $0.title.hasSuffix(".txt") },"file entries are excluded from folder suggestions")
            key(#selector(NSResponder.moveDown(_:)));check(field.dropdown.selectedIndex == 0,"Down selects the first suggestion")
            key(#selector(NSResponder.moveDown(_:)));key(#selector(NSResponder.insertTab(_:)))
            await wait("tab completion") { !field.isQuerying }
            check(field.stringValue == space.path+"/" && pane.currentURL == folder && field.sessionActive,"Tab inserts the full path including spaces without navigating")
            check((field.currentEditor() as? NSTextView)?.selectedRange().location == (field.stringValue as NSString).length,"completion places the caret after the trailing slash")
            key(#selector(NSResponder.insertNewline(_:)));await wait("completed path") { pane.currentURL == space && !pane.isLoading }
            check(!field.sessionActive && field.isHidden && main.right.currentURL == other,"Enter opens the completed folder on its own side")
            pane.history(-1);await wait("history back") { pane.currentURL == folder && !pane.isLoading }
            check(pane.navigationButtons["forward"]?.isEnabled == true,"navigation updates the forward control")
            main.command("path");type("Grü");await wait("Unicode completion") { !field.isQuerying && field.suggestions.count == 1 }
            check(field.suggestions.first?.url == unicode,"Unicode folder names complete without escaping")
            field.dropdown.choose(0);await wait("clicked suggestion") { pane.currentURL == unicode && !pane.isLoading }
            check(field.isHidden,"clicking a suggestion opens its folder")
            pane.navigate(folder);await wait("return") { !pane.isLoading }
            main.command("path");type("Dok");type("Grü")
            await wait("latest query") { !field.isQuerying && field.dropdown.isVisible }
            check(field.suggestions.map(\.title) == ["Grüße aus Wien"],"a stale completion cannot replace the latest query")
            key(#selector(NSResponder.cancelOperation(_:)))
            check(field.sessionActive && !field.dropdown.isVisible && field.stringValue == "Grü","first Escape closes suggestions and preserves the draft")
            key(#selector(NSResponder.cancelOperation(_:)))
            check(!field.sessionActive && !bar.isHidden && pane.currentURL == folder,"second Escape returns to the unchanged breadcrumb")
            main.command("path");type("does-not-exist");key(#selector(NSResponder.insertNewline(_:)))
            await wait("invalid path") { field.validationMessage != nil }
            check(field.sessionActive && field.stringValue == "does-not-exist" && pane.currentURL == folder && field.currentEditor() != nil,"an invalid path stays editable without a modal dialog")
            type("Dokumente.txt");key(#selector(NSResponder.insertNewline(_:)));await wait("file rejected") { field.validationMessage?.contains("Datei") == true }
            check(pane.currentURL == folder,"a file address never becomes the folder location")
            type("./Dokumente/../Grüße aus Wien");key(#selector(NSResponder.insertNewline(_:)));await wait("relative path") { pane.currentURL == unicode && !pane.isLoading }
            check(field.isHidden,"relative paths resolve against the current folder")
            main.command("path");type(space.absoluteString);key(#selector(NSResponder.insertNewline(_:)));await wait("file URL") { pane.currentURL == space && !pane.isLoading }
            check(field.isHidden,"pasted file URLs decode spaces and navigate")
            check((try? FolderAddress.resolve("~",relativeTo:folder)) == FileManager.default.homeDirectoryForCurrentUser,"tilde paths resolve to the user home")
            check((try? FolderAddress.resolve("https://example.invalid/path",relativeTo:folder)) == nil && (try? FolderAddress.resolve("file://example.invalid/path",relativeTo:folder)) == nil,"unsupported schemes and remote file hosts are rejected")
            pane.navigate(folder);await wait("base") { !pane.isLoading }
            main.command("path");type("");await wait("history suggestions") { field.dropdown.isVisible && !field.isQuerying }
            check(field.suggestions.contains { $0.url == unicode && $0.history } && Set(field.suggestions.map { $0.url.path }).count == field.suggestions.count,"empty input offers deduplicated session history")
            type(".");await wait("hidden folders") { !field.isQuerying && field.suggestions.contains { $0.title == ".Versteckt" } }
            check(field.suggestions.contains { $0.title == ".Versteckt" },"an explicit dot prefix offers hidden folders")
            type("D");await wait("ordinary prefix") { !field.isQuerying }
            check(!field.suggestions.contains { $0.title.hasPrefix(".") },"hidden folders stay out of ordinary suggestions")
            let draft = field.stringValue;pane.refresh();await wait("background refresh") { !pane.isLoading }
            check(field.sessionActive && field.stringValue == draft,"background refresh preserves the address draft")
            pane.endPathEditing();try? await Task.sleep(nanoseconds:200_000_000)
            check(!field.dropdown.isVisible && !field.sessionActive,"ending an edit cancels pending suggestions")
            main.content.layoutSubtreeIfNeeded()
            let arrow = require(bar.childButtons.first { $0.0 == folder }?.1,"current folder arrow")
            arrow.performClick(nil);await wait("segment folders") { bar.dropdown.isVisible && bar.dropdown.rows.count >= 4 }
            check(bar.dropdown.rows.contains { $0.url == documents } && bar.dropdown.rows.contains { $0.url == space },"a segment arrow lists its direct child folders")
            check(!bar.dropdown.rows.contains { $0.title.hasPrefix(".") || $0.title.hasSuffix(".txt") },"segment lists respect hidden files and exclude ordinary files")
            check(bar.components.allSatisfy { $0.1.menu?.items.count == 3 },"every path segment offers edit, copy path and Finder actions")
            let escape = require(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53),"Escape key")
            NSApp.postEvent(escape,atStart:false);await wait("segment Escape") { !bar.dropdown.isVisible }
            check(pane.currentURL == folder && NSApp.keyWindow === window,"Escape closes the segment chooser without navigation or a focus change")
            arrow.performClick(nil);await wait("reopen segments") { bar.dropdown.rows.contains { $0.url == documents } && bar.dropdown.isVisible }
            let index = require(bar.dropdown.rows.firstIndex { $0.url == documents },"child folder row");bar.dropdown.choose(index)
            await wait("segment navigation") { pane.currentURL == documents && !pane.isLoading }
            check(bar.url == documents && pane.currentURL == documents,"choosing a segment child navigates to that folder")
            pane.navigate(folder);await wait("drop base") { !pane.isLoading }
            let pasteboard = NSPasteboard(name:.init("local.zweicommander.navigation-test"));pasteboard.clearContents();pasteboard.writeObjects([unicode as NSURL])
            check(bar.droppedFolder(from:pasteboard) == unicode,"the path bar accepts a single folder drop")
            pasteboard.clearContents();pasteboard.writeObjects([folder.appendingPathComponent("Dokumente.txt") as NSURL])
            check(bar.droppedFolder(from:pasteboard) == nil,"the path bar rejects file drops instead of moving data");pasteboard.releaseGlobally()
            main.command("path");type("Dok");pane.endPathEditing();try? await Task.sleep(nanoseconds:300_000_000)
            check(!field.dropdown.isVisible && pane.currentURL == folder,"late folder results never reopen a dismissed address")
            for theme in [1,2] {
                main.themeMenu.selectItem(at:theme);main.themeChosen();main.command("path");type("Dok");await wait("preview suggestions") { field.dropdown.isVisible && !field.isQuerying && field.suggestions.count == 2 }
                key(#selector(NSResponder.moveDown(_:)));main.content.layoutSubtreeIfNeeded()
                let button = require(main.content.toolbar.arrangedSubviews.compactMap { $0 as? ActionButton }.first { $0.identifier?.rawValue == "filter" },"preview hover")
                hover(button,true);capture(theme == 1 ? "-Navigation-Hell" : "-Navigation-Dunkel");hover(button,false);pane.endPathEditing()
            }
            window.setContentSize(NSSize(width:900,height:520));main.content.layoutSubtreeIfNeeded();bar.layoutSubtreeIfNeeded()
            check(bar.components.filter { !$0.1.isHidden }.allSatisfy { bar.bounds.contains($0.1.frame) } && bar.childButtons.filter { !$0.1.isHidden }.allSatisfy { bar.bounds.contains($0.1.frame) },"narrow panes retain nonoverlapping path controls within the bar")
            check(main.right.currentURL == other,"all address operations preserve the opposite folder")
            print("NAV SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
