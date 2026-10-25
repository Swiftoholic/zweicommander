import AppKit
import CommanderCore

extension MainWindow {
    /// Uses visible order, including real file references in local collections.
    /// Archive members and server locations never become local input paths.
    var fileComparisonURLs:(URL,URL)? {
        guard !(window?.firstResponder is NSTextView) else { return nil }
        @MainActor func selected(_ pane:PaneView) -> [URL]? {
            guard pane.archive == nil,pane.remote == nil,pane.canUseDisplayedEntries,!pane.pathField.sessionActive else { return nil }
            let selection = Set(pane.selectedURLs),entries = pane.visibleEntries.filter { selection.contains($0.url) }
            guard entries.count == selection.count,entries.allSatisfy({ $0.isRegularFile && !$0.isSymbolicLink && $0.url.isFileURL }) else { return nil }
            return entries.map(\.url)
        }
        guard let current = selected(active) else { return nil }
        if current.count == 2 { return (current[0],current[1]) }
        guard current.count == 1,let l = selected(left),let r = selected(right),l.count == 1,r.count == 1 else { return nil }
        return (l[0],r[0])
    }
    func compareSelectedFiles() {
        guard let (left,right) = fileComparisonURLs else { content.status.stringValue = "Zwei lokale Dateien auswählen: beide auf der aktiven Seite oder je eine pro Seite.";NSSound.beep();return }
        showFileComparison(left,right)
    }
    func showFileComparison(_ left:URL,_ right:URL) {
        let controller = FileDiffController(left:left,right:right)
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
}
