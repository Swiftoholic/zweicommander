import AppKit
import CommanderCore

private final class AttributeCompletion {
    private let lock = NSLock()
    private var stored: AttributeReport?
    func set(_ value: AttributeReport) { lock.lock();stored = value;lock.unlock() }
    func take() -> AttributeReport? { lock.lock();defer { lock.unlock() };let value = stored;stored = nil;return value }
}

extension MainWindow {
    var attributesCommandEnabled: Bool {
        NSApp.keyWindow === window && keyWorkflowWindow == nil && !(window?.firstResponder is NSTextView) &&
        !active.pathField.sessionActive && active.remote == nil && active.archive == nil &&
        active.canUseDisplayedEntries && !active.selectedURLs.isEmpty && !SettingsBackupStorage.persistenceSuspended
    }
    func showAttributes() {
        guard attributesCommandEnabled else { return }
        let controller = AttributesController(sources:active.selectedURLs)
        controller.onCancel = { [weak self] id in self?.jobs.scheduler.cancel(id) }
        controller.onAfterMutation = { [weak self] in self?.refresh() }
        controller.onSubmit = { [weak self,weak controller] plan,start in
            guard let self,!SettingsBackupStorage.persistenceSuspended else { return nil }
            let completion = AttributeCompletion()
            return self.jobs.submitReported("Rechte und Datum ändern",start:start,items:plan.initialItems,notifyQueuedCancellation:true,body:{ token,reporter in
                let report = AttributeEngine.execute(plan,token:token,progress:{ reporter.transfer($0) })
                completion.set(report);return report.operationReport
            },completion:{ [weak self,weak controller] result in
                if let report = completion.take() {
                    controller?.finished(report)
                    if !report.completed.isEmpty { self?.undoSteps = [];self?.renameUndo = nil }
                } else if case .failure(let error) = result { controller?.finished(.failure(error)) }
                self?.refresh()
            })
        }
        secondaryWindows.append(controller);controller.showWindow(nil)
    }

    func configureExternalToolButton(_ button:ActionButton,tool:ExternalToolDescriptor) {
        let shortcut = tool.slot.map { CommandHelp.shortcut("externalTool\($0)") } ?? ""
        button.setHelp(tool.title,(tool.category.isEmpty ? "" : tool.category+"\n")+"Den konkreten Programmaufruf prüfen und starten.",shortcut:shortcut)
        button.isEnabled = !SettingsBackupStorage.persistenceSuspended && externalToolCommandEnabled(tool.id)
    }
}
