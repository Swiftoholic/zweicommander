import AppKit
import CommanderCore

final class ArchiveFolderSession {
    var catalog:ArchiveCatalog,password:String
    let root:URL,label:String,parent:ArchiveFolderSession?,returnURL:URL?
    var materialized:[String:URL] = [:]
    init(_ catalog:ArchiveCatalog,password:String = "",parent:ArchiveFolderSession? = nil,returnURL:URL? = nil) {
        self.catalog = catalog;self.password = password;self.parent = parent;self.returnURL = returnURL
        root = URL(string:"zwei-archive://"+UUID().uuidString.lowercased()+"/")!
        label = parent.map { $0.label+" ▸ "+catalog.source.lastPathComponent } ?? catalog.source.path
    }
    deinit { password = "" }
    var depth:Int { (parent?.depth ?? 0)+1 }
    func contains(_ url:URL) -> Bool { url.scheme == root.scheme && url.host == root.host && url.user == nil && url.password == nil && url.port == nil && url.query == nil && url.fragment == nil }
    func path(_ url:URL) -> String { String(url.path.drop(while:{$0 == "/"})) }
    func address(_ path:String) -> URL { path.isEmpty ? root : path.split(separator:"/").reduce(root) { $0.appendingPathComponent(String($1)) } }
    func describe(_ url:URL) -> String { label+" ▸ /"+path(url) }
    func resolve(_ text:String,relativeTo base:URL) throws -> URL {
        let url:URL
        if text.contains("://") { guard let parsed = URL(string:text),contains(parsed) else { throw CommanderError.message("Diese Adresse gehört nicht zum geöffneten Archiv.") };url = parsed }
        else {
            guard !text.contains("\0"),!text.hasPrefix("~"),!text.lowercased().hasPrefix("file:") else { throw CommanderError.message("Hier einen Pfad innerhalb des Archivs eingeben.") }
            let components = (text.hasPrefix("/") ? text : base.path+"/"+text).split(separator:"/")
            var result:[String] = []
            for part in components { if part == "." { continue };if part == ".." { if !result.isEmpty { result.removeLast() } } else { result.append(String(part)) } }
            url = address(result.joined(separator:"/"))
        }
        guard catalog.isDirectory(path(url)) else { throw CommanderError.message("Archivordner nicht gefunden.") };return url
    }
}

extension PaneView {
    var archive:ArchiveFolderSession? { tab.archive }
    func openArchiveSession(_ session:ArchiveFolderSession,at url:URL? = nil) {
        if tab.archiveRoot == nil,remote == nil { lastLocalTabID = tab.id };endPathEditing(restoreFocus:false)
        let value = FolderTab(url ?? session.root);value.archive = session;value.archiveRoot = session.root;value.archiveOrigin = session.catalog.source;value.title = session.catalog.source.lastPathComponent
        var view = archive == nil ? defaultView ?? FolderViewSettings() : viewSettings;view.treeVisible = false;value.view = view;value.sessionViewPinned = true
        tabs.append(value);tabIndex = tabs.count-1;restoreTabView();rebuildTabs();refresh();focus()
    }
    func navigateArchive(_ url:URL,history:Bool = true) {
        guard let archive else { return }
        if url.isFileURL {
            if routeLockedNavigation(url) { return }
            guard FileSystem.isDirectory(url) else { status.stringValue = "Lokaler Ordner nicht gefunden.";return };newTab(url:url);return
        }
        guard archive.contains(url),archive.catalog.isDirectory(archive.path(url)) else { status.stringValue = "Archivordner nicht gefunden.";return }
        if routeLockedNavigation(url) { return }
        tab.url = url;tab.filter = "";tab.filterRegex = false;tab.sessionViewPinned = false
        if history { tab.history = Array(tab.history.prefix(tab.position+1));tab.history.append(url);tab.position = tab.history.count-1 }
        restoreTabView();rebuildTabs();refresh();focus()
    }
    func leaveArchive(container:Bool = false) {
        guard let session = archive else { return }
        if tab.lockMode == .fixed { status.stringValue = "Dieser Tab hält seinen Archivordner fest.";return }
        if let parent = session.parent,let returnURL = session.returnURL {
            if let value = tabs.first(where:{ $0.archive === parent && $0.url == returnURL }) { selectTab(value.id) } else { openArchiveSession(parent,at:returnURL) }
            requestSelection([returnURL.appendingPathComponent(session.catalog.source.lastPathComponent)]);refresh()
        } else {
            let source = session.catalog.source
            if let value = tabs.first(where:{ $0.archive == nil && $0.remote == nil && $0.collection == nil && FileSystem.canonical($0.url) == FileSystem.canonical(source.deletingLastPathComponent()) }) { selectTab(value.id) } else { newTab(url:source.deletingLastPathComponent()) }
            requestSelection([source]);refresh()
        }
    }
    func configureArchiveAddress(_ session:ArchiveFolderSession) {
        let catalog = session.catalog
        breadcrumb.addressDescription = { [session] in session.describe($0) };breadcrumb.rootTitle = session.catalog.source.lastPathComponent
        pathField.addressResolver = { [session] in try session.resolve($0,relativeTo:$1) }
        let provider:PathEditor.FolderProvider = { [session] url,prefix,hidden,token in
            try token.check();try catalog.validateSource()
            let values = try catalog.contents(of:session.path(url),showHidden:hidden || prefix.hasPrefix(".")).filter { $0.isDirectory && !$0.isLink && (prefix.isEmpty || ($0.path as NSString).lastPathComponent.range(of:prefix,options:[.anchored,.caseInsensitive,.diacriticInsensitive]) != nil) }
            return (Array(values.prefix(200)).map { AddressSuggestion(url:session.address($0.path),title:($0.path as NSString).lastPathComponent,detail:"Archivordner · "+catalog.source.lastPathComponent) },values.count > 200)
        }
        pathField.folderProvider = provider;breadcrumb.folderProvider = provider
        pathField.directoryValidator = { [session] url,token in try token.check();try catalog.validateSource();guard session.contains(url),catalog.isDirectory(session.path(url)) else { throw CommanderError.message("Archivordner nicht gefunden.") } }
    }
}

extension MainWindow {
    func archiveSession(for url:URL) -> ArchiveFolderSession? { [left,right].flatMap(\.tabs).compactMap(\.archive).first { $0.contains(url) } }
    func openArchive(_ url:URL,in pane:PaneView,password:String = "") {
        if let parent = archiveSession(for:url) {
            guard parent.depth < 10 else { content.status.stringValue = "Höchstens zehn verschachtelte Archive öffnen.";return }
            let returnURL = pane.currentURL
            materializeArchiveMember(url) { [weak self,weak pane] file in guard let self,let pane else { return };self.readArchive(file,in:pane,password:password,parent:parent,returnURL:returnURL) };return
        }
        readArchive(url,in:pane,password:password)
    }
    private func readArchive(_ url:URL,in pane:PaneView,password:String,parent:ArchiveFolderSession? = nil,returnURL:URL? = nil) {
        let id = pane.tab.id,location = pane.currentURL,secret = ArchiveSecret(password)
        jobs.submitReported("Archivinhalt lesen",notifyQueuedCancellation:true,body:{ token,_ in defer { secret.value = "" };return try ArchiveCatalog.read(url,password:secret.value,token:token) },completion:{ [weak self,weak pane] result in
            guard let self,let pane else { return }
            switch result {
            case .success(let catalog):
                guard pane.tab.id == id,pane.currentURL == location else { self.content.status.stringValue = "Der Archivordner wurde inzwischen gewechselt. Archiv bei Bedarf erneut öffnen.";return }
                pane.openArchiveSession(ArchiveFolderSession(catalog,password:password,parent:parent,returnURL:returnURL))
            case .failure(let error):
                if case CommanderError.cancelled = error { self.content.status.stringValue = "Archivöffnung abgebrochen.";return }
                self.content.status.stringValue = error.localizedDescription
                if archivePasswordMayHelp(error) { self.askArchivePassword(url.lastPathComponent,error:error.localizedDescription) { [weak self,weak pane] value in guard let self,let pane else { return };self.readArchive(url,in:pane,password:value,parent:parent,returnURL:returnURL) } }
            }
        })
    }
    func materializeArchiveMember(_ url:URL,askPassword:Bool = true,completion:@escaping(URL)->Void) {
        guard let session = archiveSession(for:url),let member = session.catalog.member(at:session.path(url)),member.isRegularFile,!member.isLink else { content.status.stringValue = "Nur gewöhnliche Archivdateien können geöffnet werden.";return }
        guard member.size <= 512*1024*1024 else { content.status.stringValue = "Dateien über 512 MiB bitte mit F5 in einen lokalen Ordner entpacken.";return }
        let catalog = session.catalog,path = member.path,cached = session.materialized[path],destination = cache.appendingPathComponent(UUID().uuidString),secret = ArchiveSecret(session.password)
        jobs.submitReported("Archivdatei bereitstellen",notifyQueuedCancellation:true,body:{ token,reporter in
            defer { secret.value = "" };try token.check();try catalog.validateSource()
            if let cached,FileSystem.exists(cached) { return cached }
            let base = (path as NSString).deletingLastPathComponent,plan = try ArchiveExtractionPlan(catalog:catalog,to:destination,selection:[path],relativeTo:base,maximumBytes:512*1024*1024)
            try ArchiveService.extract(plan,password:secret.value,token:token,progress:{ reporter.report($0) })
            let file = destination.appendingPathComponent((path as NSString).lastPathComponent);try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:file.path);return file
        },completion:{ [weak self,weak session] result in
            guard let self,let session else { return };secret.value = ""
            switch result {
            case .success(let file):session.materialized[path] = file;completion(file)
            case .failure(let error):
                self.content.status.stringValue = error.localizedDescription
                if case CommanderError.cancelled = error { return }
                if askPassword,archivePasswordMayHelp(error) { self.askArchivePassword(session.catalog.source.lastPathComponent,error:error.localizedDescription) { [weak self,weak session] value in session?.password = value;self?.materializeArchiveMember(url,completion:completion) } }
            }
        })
    }
    func openArchiveMember(_ url:URL,preview:Bool,quick:Bool = false) {
        if quick {
            guard let session = archiveSession(for:url),let member = session.catalog.member(at:session.path(url)),member.isRegularFile,!member.isLink else { archiveQuickURL = nil;content.quick.previewItem = nil;return }
        }
        if quick,archiveQuickURL == url { return };if quick { archiveQuickURL = url;content.quick.previewItem = nil }
        materializeArchiveMember(url,askPassword:!quick) { [weak self] file in
            guard let self else { return }
            if quick { if self.content.quickVisible,self.active.selectedURLs.first == url { self.content.quick.previewItem = file as NSURL };return }
            if let handler = self.archiveFileHandler { handler(file,preview) }
            else if preview { self.preview([file]) } else { NSWorkspace.shared.open(file) }
        }
    }
    func reloadArchive(_ session:ArchiveFolderSession) {
        let source = session.catalog.source,secret = ArchiveSecret(session.password)
        jobs.submitReported("Archiv neu einlesen",notifyQueuedCancellation:true,body:{ token,_ in defer { secret.value = "" };return try ArchiveCatalog.read(source,password:secret.value,token:token) },completion:{ [weak self,weak session] result in
            guard let self,let session else { return };secret.value = ""
            switch result { case .success(let catalog):
                session.catalog = catalog;session.materialized = [:];self.archiveQuickURL = nil
                for pane in [self.left,self.right] { for tab in pane.tabs where tab.archive === session && !catalog.isDirectory(session.path(tab.url)) { tab.url = session.root;tab.history = [session.root];tab.position = 0;tab.filter = "";tab.filterRegex = false };pane.restoreTabView() }
                self.refresh()
            case .failure(let error):self.content.status.stringValue = error.localizedDescription }
        })
    }
    func askArchivePassword(_ name:String,error:String? = nil,submit:@escaping(String)->Void) {
        let form = ArchivePasswordController(name:name,error:error);form.onSubmit = submit;secondaryWindows.append(form);form.showWindow(nil)
    }
}

final class ArchiveSecret { var value:String;init(_ value:String) { self.value = value };deinit { value = "" } }
private func archivePasswordMayHelp(_ error:Error) -> Bool { let text = error.localizedDescription.lowercased();return ["passphrase","password","decrypt","encrypted","passwort","verschlüsselt"].contains { text.contains($0) } }
