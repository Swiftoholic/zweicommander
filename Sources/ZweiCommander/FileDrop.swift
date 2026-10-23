import AppKit
import CommanderCore

/// Opening a hovered destination never submits a file operation.
final class HoverOpen {
    static let delay: TimeInterval = 0.8
    private var key: String?
    private var pending: DispatchWorkItem?
    private var revision = 0
    func update(_ key:String?,open:@escaping()->Void) {
        guard self.key != key else { return };cancel();self.key = key
        guard key != nil else { return };let revision = self.revision
        let work = DispatchWorkItem { [weak self] in guard let self,self.revision == revision else { return };self.pending = nil;open() }
        pending = work;DispatchQueue.main.asyncAfter(deadline:.now()+Self.delay,execute:work)
    }
    func cancel() { revision += 1;pending?.cancel();pending = nil;key = nil }
    deinit { pending?.cancel() }
}

extension PaneView {
    func fileURLs(_ pasteboard:NSPasteboard) -> [URL] {
        if let cached = dropPasteboardCache,cached.name == pasteboard.name,cached.change == pasteboard.changeCount { return cached.urls }
        let urls = (pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []).filter(\.isFileURL)
        dropPasteboardCache = (pasteboard.name,pasteboard.changeCount,urls);return urls
    }
    func dropFolder(at index:Int) -> URL? {
        guard canUseDisplayedEntries,tab.collection == nil,visibleEntries.indices.contains(index) else { return nil }
        let entry = visibleEntries[index]
        return entry.isDirectory && !entry.isPackage && !entry.isSymbolicLink ? entry.url : nil
    }
    func updateFileDrop(_ pasteboard:NSPasteboard,folder:URL?) -> NSDragOperation {
        guard !readOnly,!fileURLs(pasteboard).isEmpty else { endFileDrop();return [] }
        let destination = tab.collection == nil ? folder ?? currentURL : nil
        if dropHint != nil,dropTargetURL == destination,dropOnBackground == (folder == nil || tab.collection != nil) { return .copy }
        dropTargetURL = destination;dropOnBackground = folder == nil || tab.collection != nil
        dropHint = tab.collection != nil ? "Verweise zur Dateisammlung hinzufügen" : "Kopieren nach „"+(destination?.lastPathComponent.isEmpty == false ? destination!.lastPathComponent : "/")+"“ · Loslassen öffnet die Vorschau"
        if let folder,tab.collection == nil {
            let tabID = tab.id,base = currentURL
            hoverOpen.update(folder.path) { [weak self] in
                guard let self,self.tab.id == tabID,self.currentURL == base,self.dropTargetURL == folder,!self.readOnly else { return }
                self.navigate(folder);self.endFileDrop()
            }
        } else { hoverOpen.cancel() }
        redrawFileFocus();updateStatus();return .copy
    }
    func endFileDrop() { let changed = dropHint != nil;hoverOpen.cancel();dropTargetURL = nil;dropOnBackground = false;dropHint = nil;dropPasteboardCache = nil;if changed { redrawFileFocus();updateStatus() } }
    @discardableResult func acceptFiles(_ pasteboard:NSPasteboard,into folder:URL? = nil,tabID:UUID? = nil) -> Bool {
        defer { endFileDrop() }
        let urls = fileURLs(pasteboard)
        guard !urls.isEmpty,let targetTab = tabs.first(where:{ $0.id == (tabID ?? tab.id) }),targetTab.archiveRoot == nil,targetTab.remote == nil else { return false }
        if var collection = targetTab.collection {
            for url in urls where !collection.contains(url) { collection.append(url) }
            if targetTab === tab,let onCollectionDrop { onCollectionDrop(urls) } else { targetTab.collection = collection;if targetTab === tab { refresh() } }
        } else { onDrop?(urls,folder ?? targetTab.url) }
        return true
    }
}
