import AppKit
import CommanderCore

/// An explicit backup makes inherited native columns self-contained without changing live tab rules.
enum SettingsBackupViewSnapshot {
    static func tabs(in pane:PaneView,fallbackFolder:URL) throws -> [SavedTab] {
        var tabs = pane.savedTabs
        let inherited = pane.defaultView ?? pane.viewSettings;try inherited.validate()
        if tabs.isEmpty {
            // This is the same local fallback used by a normal restart when only special tabs remain.
            tabs = [SavedTab(path:fallbackFolder.path,title:nil,locked:false,view:inherited,selected:nil)]
        } else {
            for index in tabs.indices where tabs[index].view == nil { tabs[index].view = inherited }
        }
        return tabs
    }
    static func capture(_ state:SavedState,left:PaneView,right:PaneView,vertical:Bool) throws -> Data {
        guard Thread.isMainThread else { throw CommanderError.message("Die aktuelle Ansicht muss im Dateifenster gesichert werden.") }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var snapshot = state
        snapshot.left = try tabs(in:left,fallbackFolder:home)
        snapshot.right = try tabs(in:right,fallbackFolder:home.appendingPathComponent("Downloads"))
        snapshot.vertical = vertical
        return try snapshot.encoded()
    }
    static func semanticallyEqual(_ lhs:Data,_ rhs:Data) -> Bool {
        guard let left = Preferences.decode(lhs),let right = Preferences.decode(rhs),
              let first = try? JSONSerialization.jsonObject(with:left.encoded()) as? NSDictionary,
              let second = try? JSONSerialization.jsonObject(with:right.encoded()) as? NSDictionary else { return false }
        return first == second
    }
}

extension MainWindow {
    func captureSettingsBackupState() throws -> Data {
        try SettingsBackupViewSnapshot.capture(Preferences.state,left:left,right:right,vertical:content.split.isVertical)
    }
}
