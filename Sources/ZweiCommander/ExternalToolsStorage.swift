import AppKit
import CommanderCore

struct ExternalToolsSnapshot { let library:ExternalToolLibrary,raw:Data? }
private final class ExternalToolsDecodeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var raw:Data?,library:ExternalToolLibrary?
    func decode(_ data:Data) throws -> ExternalToolLibrary {
        lock.lock();defer { lock.unlock() }
        if raw == data,let library { return library }
        let value = try ExternalToolLibrary.decode(data);raw = data;library = value;return value
    }
}
extension Preferences {
    static let externalToolsKey = "ZweiCommander.externalTools.v1"
    static var externalToolsTestDefaults:UserDefaults?
    private static let externalToolsCache = ExternalToolsDecodeCache()
    private static var externalToolsDefaults:UserDefaults? { testMode ? externalToolsTestDefaults : .standard }
    static func externalToolsSnapshot() throws -> ExternalToolsSnapshot {
        guard let object = externalToolsDefaults?.object(forKey:externalToolsKey) else { return ExternalToolsSnapshot(library:ExternalToolLibrary(),raw:nil) }
        guard let data = object as? Data else { throw CommanderError.message("Die gespeicherten Werkzeuge sind nicht lesbar und bleiben unverändert.") }
        return ExternalToolsSnapshot(library:try externalToolsCache.decode(data),raw:data)
    }
    static func externalToolLibrary() throws -> ExternalToolLibrary { try externalToolsSnapshot().library }
    static func saveExternalTools(_ library:ExternalToolLibrary) throws { try saveExternalTools(library,replacing:externalToolsSnapshot()) }
    static func saveExternalTools(_ library:ExternalToolLibrary,replacing snapshot:ExternalToolsSnapshot) throws {
        let finishMutation = try SettingsBackupStorage.beginSettingsMutation();defer { finishMutation() }
        let data = try library.encoded(),current = try externalToolsSnapshot()
        guard current.raw == snapshot.raw else { throw CommanderError.message("Die Werkzeuge wurden in einem anderen Fenster geändert. Dieses Fenster neu laden; es wurde nichts ersetzt.") }
        externalToolsDefaults?.set(data,forKey:externalToolsKey)
        if let defaults = externalToolsDefaults,defaults.data(forKey:externalToolsKey) != data { throw CommanderError.message("Werkzeuge konnten nicht gespeichert werden.") }
    }
}
struct ExternalToolDescriptor {
    let id:UUID,title:String,category:String,symbol:String
    let slot:Int?
    let showInToolbar:Bool,enabled:Bool
}
private struct ExternalToolExecutionFailure:LocalizedError {
    let result:ExternalToolExecutionResult
    var errorDescription:String? { result.error ?? "Werkzeugaufruf nicht vollständig abgeschlossen." }
}
extension MainWindow {
    var externalToolDescriptors:[ExternalToolDescriptor] {
        ((try? Preferences.externalToolLibrary())?.tools ?? []).map { ExternalToolDescriptor(id:$0.id,title:$0.title,category:$0.category,symbol:$0.kind == .application ? "app" : "terminal",slot:$0.shortcutSlot,showInToolbar:$0.showInToolbar,enabled:$0.enabled) }
    }
    func externalToolContext() -> ExternalToolContext? {
        guard NSApp.keyWindow === window,window?.attachedSheet == nil,!active.pathField.sessionActive,!active.inlineRename.isEditing,!(window?.firstResponder is NSTextView),active.canUseDisplayedEntries,
              active.remote == nil,active.archive == nil,active.tab.collection == nil,!active.isSessionTemporary(active.currentURL) else { return nil }
        let selected = Set(active.selectedURLs),ordered = active.visibleEntries.filter { selected.contains($0.url) }.map(\.url)
        guard ordered.count == selected.count,ordered.count <= ExternalToolPlanner.maximumSelection,ordered.allSatisfy({ $0.isFileURL && !active.isSessionTemporary($0) }) else { return nil }
        let inactive = other.remote == nil && other.archive == nil && other.tab.collection == nil && !other.isSessionTemporary(other.currentURL) ? other.currentURL : nil
        return ExternalToolContext(activeDirectory:active.currentURL,inactiveDirectory:inactive,focused:active.focusedEntryURL,selection:ordered)
    }
    func externalToolCommandEnabled(_ id:UUID) -> Bool { externalToolContext() != nil && externalToolDescriptors.contains { $0.id == id && $0.enabled } }
    func externalToolSlotEnabled(_ slot:Int) -> Bool { externalToolContext() != nil && externalToolDescriptors.contains { $0.slot == slot && $0.enabled } }
    func showExternalTools() {
        do {
            let controller = ExternalToolsController(snapshot:try Preferences.externalToolsSnapshot(),context:externalToolContext())
            controller.onApply = { [weak self] library,snapshot in
                try Preferences.saveExternalTools(library,replacing:snapshot);self?.buildToolbar();self?.onRebuildMenus?()
                return try Preferences.externalToolsSnapshot()
            }
            controller.onPreview = { [weak self,weak controller] tool,context in
                guard let controller else { return };let expected = controller.library
                self?.presentExternalTool(tool,context:context,validateDraft:{ [weak controller] in
                    guard let controller,controller.library == expected,try controller.draft() == tool else { throw CommanderError.message("Die Werkzeugdefinition wurde nach der Vorschau bearbeitet. Den Aufruf neu öffnen.") }
                },expectedRaw:controller.snapshot.raw)
            }
            secondaryWindows.append(controller);controller.showWindow(nil)
        } catch { showFailure(error) }
    }
    func launchExternalToolSlot(_ slot:Int) { guard let tool = externalToolDescriptors.first(where:{ $0.slot == slot }) else { return };launchExternalTool(tool.id) }
    func launchExternalTool(_ id:UUID) {
        guard let context = externalToolContext() else { content.status.stringValue = "Eigene Werkzeuge benötigen einen aktiven lokalen Ordnertab und eine abgeschlossene Eingabe.";return }
        do { let snapshot = try Preferences.externalToolsSnapshot();guard let tool = snapshot.library.tools.first(where:{ $0.id == id && $0.enabled }) else { return };presentExternalTool(tool,context:context,expectedRaw:snapshot.raw) } catch { showFailure(error) }
    }
    func presentExternalTool(_ tool:ExternalTool,context:ExternalToolContext,validateDraft:(()throws->Void)? = nil,expectedRaw:Data? = nil) {
        let controller = ExternalToolLaunchController(tool:tool,context:context)
        let validateStore:()throws->Void = {
            guard try Preferences.externalToolsSnapshot().raw == expectedRaw else { throw CommanderError.message("Die Werkzeugliste wurde seit der Vorschau geändert. Den Aufruf neu öffnen.") }
        }
        controller.onValidateDefinition = { try validateStore();try validateDraft?() }
        controller.onExecute = { [weak self,weak controller] plan in
            guard let self,let controller else { return nil }
            return self.jobs.submitReported("Werkzeug · "+plan.tool.title,notifyQueuedCancellation:true,body:{ token,reporter in
                let result = try ExternalToolPlanner.execute(plan,token:token,validateExecution:validateStore,progress:{ complete,total in reporter.report("\(complete) von \(total) Aufrufen",fraction:Double(complete)/Double(max(1,total))) })
                if !result.succeeded { throw ExternalToolExecutionFailure(result:result) };return result
            },completion:{ [weak self,weak controller] result in
                switch result {
                case .success(let value):controller?.finished(value)
                case .failure(let error):if let failure = error as? ExternalToolExecutionFailure { controller?.finished(failure.result) } else { controller?.failed(error) }
                };self?.refresh()
            })
        }
        controller.onCancel = { [weak self] id in self?.jobs.scheduler.cancel(id) }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }
}
