import AppKit
import CommanderCore

final class ArchivePasswordController:NSWindowController,NSWindowDelegate {
    let password = NSSecureTextField(string:"");var onSubmit:((String)->Void)?
    init(name:String,error:String?) {
        let w = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:540,height:225),styleMask:[.titled,.closable],backing:.buffered,defer:false);w.title = "Archiv öffnen";w.isReleasedWhenClosed = false
        super.init(window:w);w.delegate = self;let root = OperationContent(frame:w.contentView!.bounds);w.contentView = root
        let title = label(name,size:18,weight:.semibold);title.frame = NSRect(x:22,y:181,width:496,height:26);root.addSubview(title)
        let info = label((error ?? "Passwort für dieses Archiv eingeben.")+"\nPasswörter bleiben nur in dieser Sitzung.",size:12);info.maximumNumberOfLines = 3;info.lineBreakMode = .byWordWrapping;info.frame = NSRect(x:22,y:100,width:496,height:73);root.addSubview(info)
        password.placeholderString = "Archivpasswort";password.frame = NSRect(x:22,y:60,width:496,height:28);password.setAccessibilityLabel("Archivpasswort");root.addSubview(password)
        let cancel = ActionButton("Abbrechen",action:{ [weak self] in self?.close() });cancel.keyEquivalent = "\u{1b}";cancel.keyEquivalentModifierMask = []
        let open = ActionButton("Erneut öffnen",action:{ [weak self] in self?.submit() });open.keyEquivalent = "\r";open.keyEquivalentModifierMask = []
        let actions = row([cancel,open]);actions.frame = NSRect(x:22,y:14,width:496,height:30);root.addSubview(actions)
        w.workflowKeys = { [weak self] in if WorkflowKeys.matches($0,"\r",.command) { self?.submit();return true };return false };w.initialFirstResponder = password;w.center()
    }
    required init?(coder:NSCoder) { fatalError() }
    func submit() { let value = password.stringValue;onSubmit?(value);close() }
    func windowWillClose(_ notification:Notification) { password.stringValue = "";onSubmit = nil }
}
