import AppKit
import CommanderCore

final class ExternalToolLaunchController:NSWindowController,NSWindowDelegate {
    let tool:ExternalTool,context:ExternalToolContext
    let text = CommanderTextView(),status = label("",size:12),refresh = ActionButton("Neu prüfen",symbol:"arrow.clockwise",action:{}),start = ActionButton("Jetzt starten",symbol:"play.fill",action:{}),cancel = ActionButton("Abbrechen",action:{})
    private(set) var plan:ExternalToolPlan?,isPreparing = false,isRunning = false,closed = false,result:ExternalToolExecutionResult?,lastError:String?
    private var generation = 0,token = CancellationToken(),jobID:UUID?
    var onExecute:((ExternalToolPlan)->UUID?)?,onCancel:((UUID)->Void)?
    var onValidateDefinition:(()throws->Void)?
    var onApplicationLaunch:((ExternalToolPlan,ExternalToolInvocation,@escaping(Error?)->Void)->Void)?
    var isLaunchingApplication:Bool { isRunning && tool.kind == .application }
    init(tool:ExternalTool,context:ExternalToolContext) {
        self.tool = tool;self.context = context
        let window = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:920,height:680),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "Werkzeugaufruf prüfen";window.minSize = NSSize(width:760,height:560);window.isReleasedWhenClosed = false
        super.init(window:window);window.delegate = self
        let root = OperationContent(frame:window.contentView!.bounds);root.autoresizingMask = [.width,.height];window.contentView = root
        let heading = label("Werkzeugaufruf prüfen",size:21,weight:.semibold);heading.frame = NSRect(x:22,y:626,width:876,height:32);heading.autoresizingMask = [.width,.minYMargin];root.addSubview(heading)
        let hint = label("Das Werkzeug kann Dateien verändern. Ziel, Argumente und Auswahl vor dem bewussten Start kontrollieren.",size:12);hint.frame = NSRect(x:22,y:592,width:876,height:25);hint.autoresizingMask = [.width,.minYMargin];root.addSubview(hint)
        let scroll = NSScrollView(frame:NSRect(x:22,y:132,width:876,height:446));scroll.autoresizingMask = [.width,.height];scroll.hasHorizontalScroller = true;scroll.hasVerticalScroller = true;scroll.borderType = .bezelBorder
        text.frame = scroll.bounds;text.autoresizingMask = [.width];text.isEditable = false;text.isSelectable = true;text.isRichText = false;text.font = .monospacedSystemFont(ofSize:12,weight:.regular);text.textContainerInset = NSSize(width:12,height:12);scroll.documentView = text;root.addSubview(scroll)
        status.frame = NSRect(x:22,y:70,width:876,height:52);status.autoresizingMask = [.width];status.maximumNumberOfLines = 3;status.lineBreakMode = .byWordWrapping;status.cell?.usesSingleLineMode = false;root.addSubview(status)
        refresh.frame = NSRect(x:22,y:22,width:150,height:29);refresh.perform = { [weak self] in self?.prepare() }
        cancel.frame = NSRect(x:184,y:22,width:150,height:29);cancel.perform = { [weak self] in self?.cancelRun() }
        start.frame = NSRect(x:568,y:22,width:160,height:29);start.autoresizingMask = [.minXMargin];start.perform = { [weak self] in self?.execute() }
        let close = ActionButton("Schließen",action:{ [weak self] in self?.window?.performClose(nil) });close.frame = NSRect(x:740,y:22,width:158,height:29);close.autoresizingMask = [.minXMargin]
        [refresh,cancel,start,close].forEach { root.addSubview($0) }
        refresh.setHelp("Neu prüfen","Programmdatei, lokale Auswahl und Arbeitsordner erneut erfassen.",shortcut:"⌘R");start.setHelp("Jetzt starten","Den vollständig angezeigten Aufruf ausführen.",shortcut:"⌘↩");cancel.setHelp("Abbrechen","Prüfung oder laufende Programmdatei abbrechen. Bereits gestartete Apps bleiben geöffnet.",shortcut:"⌘.");close.setHelp("Schließen","Eine Prüfung abbrechen oder das Fenster schließen.",shortcut:"Esc")
        window.workflowKeys = { [weak self] event in guard let self else { return false };if WorkflowKeys.matches(event,"r",.command) { self.prepare();return true };if WorkflowKeys.matches(event,"\r",.command) { self.execute();return true };if WorkflowKeys.matches(event,".",.command) { self.cancelRun();return true };if event.keyCode == 53 { self.window?.performClose(nil);return true };return false }
        window.center();prepare()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { token.cancel() }
    func prepare() {
        guard !closed,!isRunning else { return };token.cancel();token = CancellationToken();generation += 1;let version = generation,token = token,tool = tool,context = context
        plan = nil;result = nil;lastError = nil;isPreparing = true;text.string = "";status.stringValue = "Prüfe Programm und Argumente für die eingefrorene lokale Auswahl …";status.textColor = .secondaryLabelColor;updateButtons()
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let prepared = Result { try ExternalToolPlanner.prepare(tool,context:context,token:token) }
            DispatchQueue.main.async { [weak self] in
                guard let self,!self.closed,self.generation == version,!token.isCancelled else { return };self.isPreparing = false
                switch prepared {
                case .success(let plan):self.plan = plan;self.text.string = plan.preview;self.status.stringValue = tool.kind == .application ? "App-Aufruf geprüft. macOS verwaltet den Arbeitsordner; Dokumente und Argumente werden ausdrücklich übergeben." : "Aufruf geprüft. Argumente werden einzeln übergeben; es gibt keine automatische Shell-Auswertung."
                case .failure(let error):self.lastError = error.localizedDescription;self.status.stringValue = error.localizedDescription;self.status.textColor = .systemOrange
                };self.updateButtons()
            }
        }
    }
    func execute() {
        guard !closed,!isPreparing,!isRunning,let plan else { return }
        do { try onValidateDefinition?();try ExternalToolPlanner.validate(plan) } catch { failed(error);return }
        isRunning = true;result = nil;lastError = nil;status.stringValue = "Werkzeugstart angefordert …";updateButtons()
        if tool.kind == .application { launchApplications(plan,index:0,completed:0);return }
        guard let id = onExecute?(plan) else { failed(CommanderError.message("Werkzeugstart ist nicht verbunden."));return };jobID = id
    }
    private func launchApplications(_ plan:ExternalToolPlan,index:Int,completed:Int) {
        guard !closed,isRunning,!token.isCancelled else { return }
        guard plan.invocations.indices.contains(index) else { finished(.init(completed:completed,planned:plan.invocations.count,cancelled:false,output:"\(completed) App-Aufruf(e) an macOS übergeben. Bereits gestartete Apps arbeiten unabhängig weiter.",error:nil));return }
        do { try onValidateDefinition?();try ExternalToolPlanner.validate(plan,invocation:index) } catch { finished(.init(completed:completed,planned:plan.invocations.count,cancelled:false,output:"\(completed) App-Aufruf(e) bestätigt.",error:error.localizedDescription));return }
        let version = generation,call = plan.invocations[index]
        let completion:(Error?)->Void = { [weak self] error in DispatchQueue.main.async { [weak self] in guard let self,!self.closed,self.generation == version,self.isRunning else { return };if let error { self.finished(.init(completed:completed,planned:plan.invocations.count,cancelled:false,output:"\(completed) App-Aufruf(e) bestätigt.",error:error.localizedDescription));return };self.status.stringValue = "\(completed+1) von \(plan.invocations.count) App-Aufrufen gestartet";self.launchApplications(plan,index:index+1,completed:completed+1) } }
        if let onApplicationLaunch { onApplicationLaunch(plan,call,completion);return }
        let configuration = NSWorkspace.OpenConfiguration();configuration.arguments = call.arguments;configuration.createsNewApplicationInstance = true
        if call.documents.isEmpty { NSWorkspace.shared.openApplication(at:plan.target,configuration:configuration) { _,error in completion(error) } }
        else { NSWorkspace.shared.open(call.documents,withApplicationAt:plan.target,configuration:configuration) { _,error in completion(error) } }
    }
    func finished(_ result:ExternalToolExecutionResult) {
        guard !closed else { return };self.result = result;lastError = result.error;isRunning = false;jobID = nil;plan = nil
        text.string += "\n\nERGEBNIS\n"+result.output+(result.error.map { "\n"+$0 } ?? "")
        status.stringValue = "\(result.completed) von \(result.planned) Aufrufen abgeschlossen"+(result.cancelled ? " · abgebrochen" : result.error == nil ? "" : " · angehalten")
        status.textColor = result.succeeded ? .secondaryLabelColor : .systemOrange;updateButtons()
    }
    func failed(_ error:Error) { guard !closed else { return };lastError = error.localizedDescription;isPreparing = false;isRunning = false;jobID = nil;plan = nil;status.stringValue = error.localizedDescription;status.textColor = .systemOrange;updateButtons() }
    func cancelRun() {
        guard !closed else { return }
        if isRunning,let jobID { onCancel?(jobID);status.stringValue = "Abbruch angefordert; abgeschlossene Aufrufe bleiben wirksam.";cancel.isEnabled = false;return }
        let launched = isLaunchingApplication;token.cancel();generation += 1;isPreparing = false;isRunning = false;plan = nil
        status.stringValue = launched ? "Weitere App-Aufrufe abgebrochen. Bereits an macOS übergebene Apps können noch öffnen und bleiben unabhängig gestartet." : "Prüfung abgebrochen";updateButtons()
    }
    private func updateButtons() { refresh.isEnabled = !isRunning;start.isEnabled = plan != nil && !isPreparing && !isRunning;cancel.isEnabled = isPreparing || isRunning }
    func windowShouldClose(_ sender:NSWindow) -> Bool { if isRunning { cancelRun();return !isRunning };return true }
    func windowWillClose(_ notification:Notification) { closed = true;token.cancel();generation += 1;plan = nil;onExecute = nil;onCancel = nil;onValidateDefinition = nil;onApplicationLaunch = nil }
}
