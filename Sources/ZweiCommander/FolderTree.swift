import AppKit
import CommanderCore

@MainActor final class TreeNode {
    let url:URL
    fileprivate(set) var children:[TreeNode]?
    fileprivate(set) var error:String?
    fileprivate(set) var loading = false
    fileprivate(set) var generation = 0
    fileprivate var token = CancellationToken()
    lazy var status = TreeBranchStatus(self)
    init(_ url:URL) { self.url = url }
    deinit { token.cancel() }
}

@MainActor final class TreeBranchStatus {
    weak var branch:TreeNode?
    init(_ branch:TreeNode) { self.branch = branch }
}

@MainActor private final class FolderTreeOutline:NSOutlineView {
    weak var owner:FolderTree?
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 36,let owner,owner.retrySelected() { return }
        super.keyDown(with:event)
    }
}

@MainActor final class FolderTree:NSScrollView,NSOutlineViewDataSource,NSOutlineViewDelegate {
    let outline:NSOutlineView = FolderTreeOutline()
    var roots = [TreeNode(FileManager.default.homeDirectoryForCurrentUser),TreeNode(URL(fileURLWithPath:"/Volumes")),TreeNode(URL(fileURLWithPath:"/"))] {
        didSet { outline.reloadData() }
    }
    var onChoose:((URL)->Void)?
    private let worker:OperationQueue = { let queue = OperationQueue();queue.name = "Folder tree";queue.maxConcurrentOperationCount = 2;queue.qualityOfService = .userInitiated;return queue }()
    private var restoringExpansion = false
    override init(frame frameRect:NSRect) {
        super.init(frame:frameRect)
        (outline as? FolderTreeOutline)?.owner = self
        let column = NSTableColumn(identifier:.init("tree"));column.width = 165
        outline.addTableColumn(column);outline.outlineTableColumn = column;outline.headerView = nil;outline.rowHeight = 24
        outline.delegate = self;outline.dataSource = self;outline.target = self;outline.doubleAction = #selector(choose)
        outline.setAccessibilityLabel("Ordnerbaum")
        let menu = NSMenu(),branch = NSMenuItem(title:"Zweig erneut laden",action:#selector(refreshBranch),keyEquivalent:"")
        branch.target = self;menu.addItem(branch)
        let all = NSMenuItem(title:"Ordnerbaum aktualisieren",action:#selector(refreshTree),keyEquivalent:"");all.target = self;menu.addItem(all);outline.menu = menu
        documentView = outline;hasVerticalScroller = true;autohidesScrollers = true
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { worker.cancelAllOperations() }
    func refreshExpanded() {
        let branches = (0..<outline.numberOfRows).compactMap { outline.item(atRow:$0) as? TreeNode }.filter { outline.isItemExpanded($0) }
        for branch in branches { load(branch,force:true) }
    }
    func load(_ branch:TreeNode,force:Bool = false) {
        guard force || (!branch.loading && branch.children == nil && branch.error == nil) else { return }
        branch.token.cancel();branch.token = CancellationToken();branch.generation += 1;branch.loading = true;branch.error = nil
        let generation = branch.generation,url = branch.url,token = branch.token
        if branch.children == nil {
            let previous = restoringExpansion;restoringExpansion = true
            outline.reloadItem(branch,reloadChildren:true);restoringExpansion = previous
        }
        worker.addOperation { [weak self,weak branch] in
            let result = Result { try FolderNavigation.children(of:url,token:token) }
            DispatchQueue.main.async {
                guard let self,let branch,branch.generation == generation,!token.isCancelled else { return }
                guard self.outline.row(forItem:branch) >= 0 else { branch.loading = false;return }
                let expanded = Set((0..<self.outline.numberOfRows).compactMap { index -> String? in
                    guard let node = self.outline.item(atRow:index) as? TreeNode,self.outline.isItemExpanded(node) else { return nil };return node.url.path
                })
                let selected = (self.outline.item(atRow:self.outline.selectedRow) as? TreeNode)?.url
                branch.loading = false
                switch result {
                case .success(let urls):
                    let previous = Dictionary(uniqueKeysWithValues:(branch.children ?? []).map { ($0.url.path,$0) })
                    branch.children = urls.map { previous[$0.path] ?? TreeNode($0) };branch.error = nil
                case .failure(let error):branch.children = nil;branch.error = error.localizedDescription
                }
                // Reloading expanded items can synchronously emit expansion callbacks.
                // Guard the reload as well as explicit restoration, or each completed
                // read starts another forced read before the branch can become idle.
                let previousRestoring = self.restoringExpansion;self.restoringExpansion = true
                defer { self.restoringExpansion = previousRestoring }
                self.outline.reloadItem(branch,reloadChildren:true)
                var row = 0
                while row < self.outline.numberOfRows {
                    if let node = self.outline.item(atRow:row) as? TreeNode,expanded.contains(node.url.path) { self.outline.expandItem(node) }
                    row += 1
                }
                if let selected,let index = (0..<self.outline.numberOfRows).first(where:{ (self.outline.item(atRow:$0) as? TreeNode)?.url == selected }) { self.outline.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
            }
        }
    }
    private func rows(_ branch:TreeNode) -> [Any] {
        if let children = branch.children,!children.isEmpty { return children }
        if branch.children == nil,branch.error == nil { load(branch) }
        return [branch.status]
    }
    func outlineView(_ outlineView:NSOutlineView,numberOfChildrenOfItem item:Any?) -> Int {
        guard let item else { return roots.count };return (item as? TreeNode).map { rows($0).count } ?? 0
    }
    func outlineView(_ outlineView:NSOutlineView,child index:Int,ofItem item:Any?) -> Any {
        if let branch = item as? TreeNode { return rows(branch)[index] }
        precondition(item == nil,"Statuszeilen im Ordnerbaum haben keine Kinder.");return roots[index]
    }
    func outlineView(_ outlineView:NSOutlineView,isItemExpandable item:Any) -> Bool { item is TreeNode }
    func outlineViewItemWillExpand(_ notification:Notification) { if !restoringExpansion,let node = notification.userInfo?["NSObject"] as? TreeNode { load(node,force:true) } }
    func outlineView(_ outlineView:NSOutlineView,viewFor tableColumn:NSTableColumn?,item:Any) -> NSView? {
        if let node = item as? TreeNode { let field = label(node.url.path == "/" ? "Macintosh HD" : node.url.lastPathComponent,size:11);field.toolTip = node.url.path;return field }
        guard let status = item as? TreeBranchStatus,let branch = status.branch else { return nil }
        if let error = branch.error {
            let button = ActionButton("Nicht lesbar",symbol:"arrow.clockwise",action:{ [weak self,weak branch] in guard let branch else { return };self?.load(branch,force:true) })
            button.flat = true;button.font = .systemFont(ofSize:11);button.contentTintColor = .systemRed
            button.toolTip = error+"\nKlicken, Enter oder Doppelklick lädt diesen Zweig erneut.";button.setAccessibilityLabel("Ordner nicht lesbar: "+branch.url.lastPathComponent+". Erneut versuchen.");button.setAccessibilityHelp(error)
            return button
        }
        return label(branch.loading ? "Ordner werden geladen …" : "Keine sichtbaren Unterordner",size:11,color:.secondaryLabelColor)
    }
    @discardableResult func retrySelected() -> Bool {
        guard let status = outline.item(atRow:outline.selectedRow) as? TreeBranchStatus,let branch = status.branch,branch.error != nil else { return false };load(branch,force:true);return true
    }
    @objc private func refreshBranch() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        if let node = outline.item(atRow:row) as? TreeNode { load(node,force:true) }
        else if let node = (outline.item(atRow:row) as? TreeBranchStatus)?.branch { load(node,force:true) }
    }
    @objc private func refreshTree() { refreshExpanded() }
    @objc func choose() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        if let status = outline.item(atRow:row) as? TreeBranchStatus,let branch = status.branch,branch.error != nil { load(branch,force:true) }
        else if let node = outline.item(atRow:row) as? TreeNode { onChoose?(node.url) }
    }
}
