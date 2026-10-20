import AppKit

extension AppDelegate {
    func runRailSmoke(root:URL,prefix:String) {
        Task { @MainActor in
            var checks = 0,failures: [String] = []
            func check(_ value:Bool,_ name:String) { checks += 1;print("RAIL UI \(value ? "PASS" : "FAIL") \(name)");if !value { failures.append(name) } }
            func require<T>(_ value:T?,_ name:String) -> T { guard let value else { print("RAIL SMOKE FAIL missing \(name)");exit(1) };return value }
            let content = main.content,split = content.split,rail = content.rail,window = require(main.window,"window")
            @MainActor func event(_ type:NSEvent.EventType,_ point:NSPoint,in view:NSView) -> NSEvent {
                require(NSEvent.mouseEvent(with:type,location:view.convert(point,to:nil),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:type == .leftMouseUp ? 0 : 1),"mouse event")
            }
            @MainActor func dragGrip() -> CGFloat {
                let grip = split.resizeGrip(in:split.dividerFrame),start = NSPoint(x:grip.midX,y:grip.midY)
                let end = NSPoint(x:start.x+(split.isVertical ? 44 : 0),y:start.y+(split.isVertical ? 0 : 44))
                let before = split.isVertical ? main.left.frame.width : main.left.frame.height
                NSApp.postEvent(event(.leftMouseUp,end,in:split),atStart:true)
                NSApp.postEvent(event(.leftMouseDragged,end,in:split),atStart:true)
                window.sendEvent(event(.leftMouseDown,start,in:split));content.layoutSubtreeIfNeeded()
                return abs((split.isVertical ? main.left.frame.width : main.left.frame.height)-before)
            }
            @MainActor func button(_ id:String) -> ActionButton { require(rail.buttons.first { $0.identifier?.rawValue == id },"button "+id) }
            @MainActor func nonoverlappingButtons() -> Bool {
                rail.buttons.allSatisfy { rail.bounds.contains($0.frame) } && rail.buttons.enumerated().allSatisfy { i,b in rail.buttons.dropFirst(i+1).allSatisfy { !$0.frame.intersects(b.frame) } }
            }
            @MainActor func capture(_ name:String) -> NSBitmapImageRep {
                let places = [("System",URL(fileURLWithPath:"/")),("Projekte",root.appendingPathComponent("Links")),("Sicherung",root.appendingPathComponent("Rechts"))]
                for pane in [main.left,main.right] { pane.locations.configure(places);pane.locations.select(pane.currentURL) }
                content.layoutSubtreeIfNeeded();content.displayIfNeeded()
                let bitmap = require(content.bitmapImageRepForCachingDisplay(in:content.bounds),"bitmap");content.cacheDisplay(in:content.bounds,to:bitmap)
                do { try require(bitmap.representation(using:.png,properties:[:]),"PNG").write(to:URL(fileURLWithPath:prefix+name+".png")) } catch { print("RAIL SMOKE FAIL capture");exit(1) }
                return bitmap
            }
            window.makeKeyAndOrderFront(nil);content.layoutSubtreeIfNeeded()
            check(rail.buttons.count == 7 && rail.buttons.allSatisfy { $0.image != nil },"all center actions have native icons")
            check(rail.frame.width == 30 && split.dividerThickness == 36,"action strip and resize grip have separate widths")
            let drawn = split.dividerFrame,grip = split.resizeGrip(in:drawn)
            let effective = content.splitView(split,effectiveRect:drawn.insetBy(dx:-3,dy:0),forDrawnRect:drawn,ofDividerAt:0)
            check(effective == grip && grip.width == 5,"native divider hit area is restricted to the five-point edge")
            check(!grip.intersects(split.actionStripFrame),"action background never belongs to the resize hit area")
            let gripPoint = content.convert(NSPoint(x:grip.midX,y:grip.midY),from:split)
            check(content.hitTest(gripPoint) === split,"resize edge routes mouse presses to the native splitter")
            let blank = NSPoint(x:rail.bounds.midX,y:rail.bounds.height*0.15),blankPoint = content.convert(blank,from:rail)
            check(content.hitTest(blankPoint) === rail,"empty strip space owns its normal pointer surface")
            let linkedButton = button("linked"),linkedPoint = content.convert(NSPoint(x:linkedButton.bounds.midX,y:linkedButton.bounds.midY),from:linkedButton)
            check(content.hitTest(linkedPoint) === linkedButton,"center action receives clicks without entering splitter tracking")
            check(nonoverlappingButtons(),"small action targets fit without overlap")
            check(button("swap").frame.midY > rail.bounds.height*0.85 && button("compare").frame.midY < rail.bounds.height*0.8,"top and compare actions occupy separate groups")
            check(button("sameFolder").frame.midY < rail.bounds.height*0.65 && button("orientation").frame.midY < rail.bounds.height*0.45,"navigation and layout groups are distributed down the strip")
            check(button("trash").frame.midY < 30 && button("trash").toolTip == "In den Papierkorb …","trash action is anchored at the bottom")
            NSCursor.resizeLeftRight.set();rail.cursorUpdate(with:event(.mouseMoved,blank,in:rail))
            check(NSCursor.current == .arrow,"entering the action strip restores the arrow after a resize cursor")
            let before = main.left.frame.width
            window.sendEvent(event(.leftMouseDown,blank,in:rail));window.sendEvent(event(.leftMouseDragged,NSPoint(x:blank.x+10,y:blank.y),in:rail));window.sendEvent(event(.leftMouseUp,NSPoint(x:blank.x+10,y:blank.y),in:rail))
            check(main.left.frame.width == before,"dragging unused action-strip space does not resize the panes")
            check(dragGrip() > 20,"dragging the real vertical edge resizes through AppKit mouse tracking")
            let resized = main.left.frame.width
            linkedButton.performClick(nil)
            check(main.linked && main.left.frame.width == resized,"linked navigation button works without moving the divider")
            linkedButton.performClick(nil);check(!main.linked && linkedButton.state == .off,"linked navigation retains its normal toggle state")
            for (index,name) in [(1,"-Mittelbalken-Hell"),(2,"-Mittelbalken-Dunkel")] {
                main.themeMenu.selectItem(at:index);main.themeChosen();try? await Task.sleep(nanoseconds:200_000_000)
                let bitmap = capture(name),point = content.convert(blank,from:rail)
                let color = bitmap.colorAt(x:Int(point.x),y:Int(content.bounds.height-point.y-1))
                let background = bitmap.colorAt(x:400,y:Int(content.bounds.height)-13)
                check(color.flatMap { color in background.map { reference in color.alphaComponent > 0.99 && reference.alphaComponent > 0.99 && abs(CommanderPalette.luminance(color)-CommanderPalette.luminance(reference)) < 0.01 } } == true,"center strip uses the opaque \(index == 1 ? "light" : "dark") toolbar surface")
            }
            button("orientation").performClick(nil);content.layoutSubtreeIfNeeded()
            check(!split.isVertical && !rail.vertical && rail.frame.height == 30,"horizontal layout keeps a distinct action strip")
            let horizontalGrip = split.resizeGrip(in:split.dividerFrame)
            check(horizontalGrip.height == 5 && !horizontalGrip.intersects(split.actionStripFrame),"horizontal resize hit area is limited to its edge")
            check(nonoverlappingButtons() && button("trash").frame.midX > rail.bounds.width-30,"horizontal groups fit with trash at the far end")
            NSCursor.resizeUpDown.set();rail.cursorUpdate(with:event(.mouseMoved,NSPoint(x:rail.bounds.width*0.15,y:rail.bounds.midY),in:rail))
            check(NSCursor.current == .arrow,"horizontal action strip also restores the normal pointer")
            check(dragGrip() > 20,"dragging the real horizontal edge resizes through AppKit mouse tracking")
            _ = capture("-Mittelbalken-Horizontal")
            button("orientation").performClick(nil);window.setContentSize(NSSize(width:900,height:520));content.layoutSubtreeIfNeeded()
            check(nonoverlappingButtons() && main.left.frame.width >= 280 && main.right.frame.width >= 280,"minimum window keeps all action groups and usable file panes")
            button("onePane").performClick(nil);content.layoutSubtreeIfNeeded()
            check(rail.isHidden && split.dividerFrame.isEmpty && split.resizeGrip(in:split.dividerFrame).isEmpty,"single-pane view removes action strip and resize area together")
            main.command("onePane");content.layoutSubtreeIfNeeded()
            check(!rail.isHidden && rail.frame.width == 30 && !split.dividerFrame.isEmpty,"two-pane view restores the separated controls")
            NSCursor.arrow.set();print("RAIL SMOKE \(failures.isEmpty ? "PASS" : "FAIL") \(checks) checks")
            if !failures.isEmpty { exit(1) };NSApp.terminate(nil)
        }
    }
}
