import AppKit
import CommanderCore

extension MainWindow {
    func applyLaunchRequest(_ request: LaunchRequest) throws {
        guard !request.isEmpty else { return }
        try request.validate()
        guard keyWorkflowWindow == nil, !left.inlineRename.isEditing, !right.inlineRename.isEditing,
              !left.pathField.sessionActive, !right.pathField.sessionActive else {
            throw CommanderError.message("Zuerst die aktuelle Eingabe oder das Arbeitsfenster schließen und den Startaufruf wiederholen.")
        }
        let applying = isApplyingWorkspace, wasLinked = linked
        isApplyingWorkspace = true;linked = false
        defer { linked = wasLinked;isApplyingWorkspace = applying;saveState() }
        for (target, pane) in [(request.left, left), (request.right, right)] {
            guard let target else { continue }
            if request.newTabs || pane.remote != nil || pane.archive != nil || pane.tab.collection != nil || [.fixed, .newTab].contains(pane.tab.lockMode) {
                pane.newTab(url: target.directory)
            } else { pane.navigate(target.directory) }
            if let selected = target.selection {
                if selected.lastPathComponent.hasPrefix(".") { pane.showHidden = true }
                pane.requestSelection([selected]);pane.refresh()
            }
        }
        if request.left != nil || request.right != nil {
            if request.left != nil { left.isHidden = false }
            if request.right != nil { right.isHidden = false }
            content.firstLayout = true;content.needsLayout = true
        }
        let side = request.active ?? (request.left != nil ? .left : request.right != nil ? .right : active === left ? .left : .right)
        let chosen = side == .left ? left : right
        chosen.isHidden = false;setActive(chosen);chosen.focus()
        content.status.stringValue = "Startziele geöffnet"
    }
}
