import AppKit
import CommanderCore

final class RemoteFolderSession {
    var connection: RemoteConnection
    init(_ connection: RemoteConnection) { self.connection = connection }
    deinit { connection.password = "" }
    func resolve(_ text: String,relativeTo base: URL) throws -> URL {
        let path: String
        if text.contains("://") {
            guard let url = URL(string:text),url.scheme == base.scheme,url.host?.lowercased() == base.host?.lowercased(),url.port == base.port,
                  url.user == nil,url.password == nil,url.query == nil,url.fragment == nil else { throw CommanderError.message("Diese Adresse gehört nicht zur geöffneten Verbindung. Für einen anderen Server ein Verbindungsprofil öffnen.") }
            path = url.path
        } else {
            guard !text.hasPrefix("~"),!text.lowercased().hasPrefix("file:") else { throw CommanderError.message("Hier einen absoluten oder relativen Serverpfad eingeben.") }
            path = text.hasPrefix("/") ? text : RemoteService.child(base.path,text)
        }
        return connection.address(try RemoteService.normalized(path))
    }
    func folders(in url: URL,prefix: String,hidden: Bool,token: CancellationToken) throws -> (items:[AddressSuggestion],limited:Bool) {
        let connection = self.connection
        let values = try RemoteService.list(connection,path:url.path,token:token).filter { $0.isDirectory && !$0.isLink && (hidden || !$0.name.hasPrefix(".") || prefix.hasPrefix(".")) && (prefix.isEmpty || $0.name.range(of:prefix,options:[.anchored,.caseInsensitive,.diacriticInsensitive]) != nil) }
        return (Array(values.prefix(200)).map { AddressSuggestion(url:connection.address(RemoteService.child(url.path,$0.name)),title:$0.name,detail:"Serverordner · "+connection.host) },values.count > 200)
    }
}

extension PaneView {
    var remote: RemoteFolderSession? { tab.remote }
    var locationText: String { if let archive { return archive.describe(currentURL) };return remote == nil ? currentURL.path : currentURL.absoluteString }
    var remoteReady: Bool { remote != nil && canUseDisplayedEntries && !isLoading && !pathField.sessionActive }
    var selectedRemoteEntries: [RemoteEntry] {
        guard remoteReady else { return [] }
        let names = Set(selectedURLs.map(\.lastPathComponent));return tab.remoteEntries.filter { names.contains($0.name) }
    }
    @discardableResult func openRemote(_ connection: RemoteConnection,path: String) -> FolderTab {
        if remote == nil { lastLocalTabID = tab.id };endPathEditing(restoreFocus:false)
        let t = FolderTab(connection.address(path));t.remote = RemoteFolderSession(connection)
        var view = defaultView ?? FolderViewSettings();view.treeVisible = false;t.view = view
        tabs.append(t);tabIndex = tabs.count-1;filterField.stringValue = "";restoreTabView();rebuildTabs();refresh();focus();return t
    }
    func configureRemoteAddress() {
        if let archive { configureArchiveAddress(archive);return }
        breadcrumb.addressDescription = nil;breadcrumb.rootTitle = nil
        guard let remote else { pathField.addressResolver = nil;pathField.folderProvider = nil;pathField.directoryValidator = nil;breadcrumb.folderProvider = nil;return }
        pathField.addressResolver = { [remote] text,base in try remote.resolve(text,relativeTo:base) }
        let provider: PathEditor.FolderProvider = { [remote] url,prefix,hidden,token in try remote.folders(in:url,prefix:prefix,hidden:hidden,token:token) }
        pathField.folderProvider = provider;breadcrumb.folderProvider = provider
        let connection = remote.connection
        pathField.directoryValidator = { url,token in _ = try RemoteService.list(connection,path:url.path,token:token) }
    }
    func navigateRemote(_ url: URL,history: Bool = true) {
        guard let remote else { return }
        do {
            let value = try remote.resolve(url.absoluteString,relativeTo:currentURL)
            if routeLockedNavigation(value) { return }
            tab.url = value;tab.remoteEntries = [];tab.filter = "";tab.filterRegex = false;filterField.stringValue = "";filterRegex.state = .off
            if history { tab.history = Array(tab.history.prefix(tab.position+1));tab.history.append(value);tab.position = tab.history.count-1 }
            rebuildTabs();refresh();focus()
        } catch { status.stringValue = error.localizedDescription;status.toolTip = error.localizedDescription }
    }
}
