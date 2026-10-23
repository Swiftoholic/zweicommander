import AppKit
import CommanderCore

final class TestRemotePasswords: RemotePasswordStore {
    var values: [String:String] = [:]
    func password(account: String) throws -> String? { values[account] }
    func save(_ password: String,account: String) throws { values[account] = password }
    func remove(account: String) throws { values.removeValue(forKey:account) }
}
extension Preferences {
    static let remoteProfilesKey = "ZweiCommander.remoteProfiles.v1"
    static var remoteProfileTestDefaults: UserDefaults?
    static let remoteTestPasswords = TestRemotePasswords()
    private static var remoteMemory: Data?
    private static var remoteStorage: RemoteProfileStore?
    static var remoteProfiles: RemoteProfileStore {
        if let remoteStorage { return remoteStorage }
        let store = RemoteProfileStore(passwords:testMode ? remoteTestPasswords : RemoteKeychain(),read:{
            let defaults = testMode ? remoteProfileTestDefaults : UserDefaults.standard
            if let raw = defaults?.object(forKey:remoteProfilesKey),!(raw is Data) { throw CommanderError.message("Vorhandene Verbindungsprofile sind nicht lesbar und bleiben erhalten.") }
            return defaults?.data(forKey:remoteProfilesKey) ?? (testMode ? remoteMemory : nil)
        },write:{ data in
            if testMode { if let defaults = remoteProfileTestDefaults { defaults.set(data,forKey:remoteProfilesKey) } else { remoteMemory = data } }
            else { UserDefaults.standard.set(data,forKey:remoteProfilesKey) }
        })
        remoteStorage = store;return store
    }
}

final class RemoteConnectionController: NSWindowController,NSWindowDelegate {
    let profiles = NSPopUpButton(),kind = NSPopUpButton(),destination = NSPopUpButton()
    let name = input(placeholder:"Name für diese Verbindung"),host = input(placeholder:"Servername"),user = input(),port = input("21")
    let password = NSSecureTextField(string:""),remember = checkbox("Passwort beim Speichern im Schlüsselbund sichern")
    let identity = input(placeholder:"Leer: SSH-Agent / Standardschlüssel"),ca = input(placeholder:"Leer: System-Zertifikatsprüfung"),remotePath = input("/")
    let status = label("",size:12,color:.secondaryLabelColor)
    let save = ActionButton("Speichern",symbol:"square.and.arrow.down",action:{})
    let remove = ActionButton("Löschen …",symbol:"trash",action:{})
    let fresh = ActionButton("Neu",symbol:"plus",action:{})
    let connect = ActionButton("Verbinden",symbol:"network",action:{})
    private(set) var selected: RemoteProfile?
    private(set) var confirmation: NSAlert?
    private var library = RemoteProfileLibrary(),isBusy = false
    var isWorking: Bool { isBusy }
    var onConnect: ((RemoteConnection,String)->Void)?
    init() {
        let window = WorkflowWindow(contentRect:NSRect(x:0,y:0,width:680,height:650),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title = "Serververbindungen";window.minSize = NSSize(width:680,height:650);window.isReleasedWhenClosed = false
        super.init(window:window);window.delegate = self
        let root = OperationContent(frame:window.contentView!.bounds);root.autoresizingMask = [.width,.height];window.contentView = root
        let heading = label("Serververbindungen",size:22,weight:.semibold);heading.frame = NSRect(x:22,y:600,width:620,height:32);heading.autoresizingMask = [.width,.minYMargin];root.addSubview(heading)
        kind.addItems(withTitles:RemoteProtocol.allCases.map(\.rawValue));kind.selectItem(at:1);kind.target = self;kind.action = #selector(protocolChanged)
        profiles.target = self;profiles.action = #selector(selectProfile)
        destination.addItems(withTitles:["Aktive Seite · neuer Tab","Linke Seite · neuer Tab","Rechte Seite · neuer Tab","Eigenes Serverfenster"])
        destination.toolTip = "Serverordner als Tab neben lokalen Ordnern öffnen. Server-Tabs gelten für diese Sitzung."
        let fields = form([("Profil",profiles),("Name",name),("Protokoll",kind),("Server",host),("Port",port),("Benutzer",user),("Passwort",password),("",remember),("SSH-Schlüssel",identity),("CA-Datei",ca),("Serverordner",remotePath),("Öffnen in",destination)],width:636)
        fields.frame.origin = NSPoint(x:22,y:126);fields.autoresizingMask = [.width,.minYMargin];root.addSubview(fields)
        for (field,help) in [(identity,"Optionaler lokaler SSH-Schlüssel. Leer verwendet den SSH-Agenten und die Standardschlüssel. Hostschlüssel müssen bereits geprüft sein."),(ca,"Optionales lokales CA-Zertifikat für FTPS. Die Zertifikatsprüfung bleibt immer aktiv."),(remotePath,"Serverordner als absoluter Pfad, zum Beispiel / oder /Projekte."),(host,"Servername ohne Protokoll, Benutzer oder Pfad. ⌘L fokussiert dieses Feld.")] { field.toolTip = help }
        let note = label("Speichern legt ein lokales Profil an. Verbinden ohne Speichern gilt für diese Sitzung.\nSFTP: SSH-Schlüssel/Agent und bekannte Hostschlüssel. FTPS: explizites, geprüftes TLS.",size:11,color:.secondaryLabelColor)
        note.maximumNumberOfLines = 2;note.frame = NSRect(x:22,y:83,width:636,height:36);note.autoresizingMask = [.width];root.addSubview(note)
        status.maximumNumberOfLines = 2;status.lineBreakMode = .byWordWrapping;status.frame = NSRect(x:22,y:46,width:636,height:34);status.autoresizingMask = [.width];root.addSubview(status)
        let actions = row([fresh,save,remove,connect]);actions.frame = NSRect(x:20,y:10,width:638,height:32);root.addSubview(actions)
        fresh.perform = { [weak self] in self?.newProfile() };save.perform = { [weak self] in self?.saveProfile() };remove.perform = { [weak self] in self?.removeProfile() };connect.perform = { [weak self] in self?.connectNow() }
        connect.keyEquivalent = "\r";connect.keyEquivalentModifierMask = [];connect.setHelp("Verbinden","Server mit den angezeigten Einstellungen öffnen.",shortcut:"↩ / ⌘↩")
        save.setHelp("Profil speichern","Verbindungsdaten lokal speichern; ausgewählte Passwörter ausschließlich im Schlüsselbund.",shortcut:"⌘S")
        window.workflowKeys = { [weak self] event in
            guard let self,!self.isBusy else { return false }
            if WorkflowKeys.matches(event,"l",.command) { window.makeFirstResponder(self.host);self.host.selectText(nil);return true }
            if WorkflowKeys.matches(event,"s",.command) { self.saveProfile();return true }
            if WorkflowKeys.matches(event,"\r",.command) { self.connectNow();return true }
            return false
        }
        window.initialFirstResponder = host;window.center();reload();protocolChanged()
    }
    required init?(coder:NSCoder) { fatalError() }
    func reload(select id: UUID? = nil) {
        do {
            library = try Preferences.remoteProfiles.library();profiles.removeAllItems();profiles.addItem(withTitle:"Neue Verbindung")
            for profile in library.profiles { profiles.addItem(withTitle:profile.name);profiles.lastItem?.representedObject = profile.id }
            if let id,let index = profiles.itemArray.firstIndex(where: { $0.representedObject as? UUID == id }) { profiles.selectItem(at:index) }
            remove.isEnabled = selected != nil
        } catch { show(error);save.isEnabled = false;remove.isEnabled = false }
    }
    @objc func selectProfile() {
        guard let id = profiles.selectedItem?.representedObject as? UUID,let profile = library.profile(id) else { newProfile();return }
        selected = profile;name.stringValue = profile.name;host.stringValue = profile.host;user.stringValue = profile.user;port.stringValue = String(profile.port)
        kind.selectItem(at:RemoteProtocol.allCases.firstIndex(of:profile.kind)!);remotePath.stringValue = profile.remotePath;identity.stringValue = profile.identityPath;ca.stringValue = profile.caPath
        password.stringValue = "";password.placeholderString = profile.usesKeychain ? "Gespeichert – leer lassen zum Beibehalten" : "Nur für diese Sitzung";remember.state = profile.usesKeychain ? .on : .off
        remove.isEnabled = true;status.stringValue = "Profil geladen. Speichern sichert Änderungen dauerhaft.";protocolChanged()
    }
    func newProfile() {
        selected = nil;profiles.selectItem(at:0);name.stringValue = "";host.stringValue = "";user.stringValue = "";port.stringValue = "21";kind.selectItem(at:1)
        password.stringValue = "";password.placeholderString = "Nur für diese Sitzung";identity.stringValue = "";ca.stringValue = "";remember.state = .off;remotePath.stringValue = "/";remove.isEnabled = false;status.stringValue = "Neue Verbindung";protocolChanged()
    }
    @objc func protocolChanged() {
        let ssh = RemoteProtocol.allCases[kind.indexOfSelectedItem] == .sftp
        if ["21","22", ""].contains(port.stringValue) { port.stringValue = ssh ? "22" : "21" }
        if ssh { password.stringValue = "";remember.state = .off }
        password.isEnabled = !ssh;remember.isEnabled = !ssh;identity.isEnabled = ssh;ca.isEnabled = RemoteProtocol.allCases[kind.indexOfSelectedItem] == .ftps
    }
    func connection() throws -> RemoteConnection {
        let kind = RemoteProtocol.allCases[kind.indexOfSelectedItem]
        return try RemoteConnection(kind:kind,host:host.stringValue.trimmingCharacters(in:.whitespaces),user:user.stringValue,port:Int(port.stringValue) ?? 0,identityFile:kind == .sftp && !identity.stringValue.isEmpty ? URL(fileURLWithPath:(identity.stringValue as NSString).expandingTildeInPath) : nil,caFile:kind == .ftps && !ca.stringValue.isEmpty ? URL(fileURLWithPath:(ca.stringValue as NSString).expandingTildeInPath) : nil)
    }
    private func busy(_ value: Bool) {
        isBusy = value
        for control: NSControl in [profiles,kind,destination,name,host,user,port,password,identity,ca,remotePath,remember,fresh,save,remove,connect] { control.isEnabled = !value }
        if !value { protocolChanged();remove.isEnabled = selected != nil }
    }
    private func show(_ error: Error) { status.stringValue = error.localizedDescription;status.toolTip = error.localizedDescription;status.textColor = .systemOrange }
    func saveProfile() {
        guard !isBusy else { return }
        do {
            let connection = try connection(),path = remotePath.stringValue,title = name.stringValue,secret = password.stringValue,old = selected,remember = connection.kind != .sftp && self.remember.state == .on
            let store = Preferences.remoteProfiles;busy(true);status.stringValue = "Profil und Schlüsselbund werden gespeichert …"
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                let result = Result { try store.save(name:title,connection:connection,path:path,remember:remember,password:secret.isEmpty ? nil : secret,replacing:old) }
                DispatchQueue.main.async {
                    guard let self else { return };self.busy(false)
                    switch result { case .success(let profile):self.selected = profile;self.reload(select:profile.id);if profile.usesKeychain { self.password.stringValue = "" };self.password.placeholderString = profile.usesKeychain ? "Im Schlüsselbund gespeichert" : "Nur für diese Sitzung";self.status.stringValue = "Profil lokal gespeichert";self.status.textColor = .secondaryLabelColor
                    case .failure(let error):self.show(error) }
                }
            }
        } catch { show(error) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isBusy }
    func windowWillClose(_ notification: Notification) { password.stringValue = "" }
    func removeProfile() {
        guard let selected,!isBusy,let window,window.attachedSheet == nil else { return }
        let alert = NSAlert();alert.messageText = "Verbindungsprofil löschen?"
        alert.informativeText = selected.name+"\n\nDas Profil und sein zugeordnetes Schlüsselbund-Passwort werden entfernt. Serverdateien bleiben erhalten."
        alert.addButton(withTitle:"Löschen");alert.addButton(withTitle:"Abbrechen");confirmation = alert
        alert.beginSheetModal(for:window) { [weak self] response in
            guard let self else { return };self.confirmation = nil
            guard response == .alertFirstButtonReturn else { return }
            let store = Preferences.remoteProfiles;self.busy(true)
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                let result = Result { try store.remove(selected) }
                DispatchQueue.main.async { guard let self else { return };self.busy(false);switch result { case .success:self.reload();self.newProfile();case .failure(let error):self.show(error) } }
            }
        }
    }
    func connectNow() {
        guard !isBusy else { return }
        do {
            let connection = try connection(),path = try RemoteService.normalized(remotePath.stringValue),secret = password.stringValue,profile = selected,store = Preferences.remoteProfiles
            busy(true);status.stringValue = "Anmeldung wird vorbereitet …"
            DispatchQueue.global(qos:.userInitiated).async { [weak self] in
                let result = Result { try store.connection(connection,profile:profile,enteredPassword:secret) }
                DispatchQueue.main.async {
                    guard let self else { return };self.busy(false)
                    switch result { case .success(let value):self.password.stringValue = "";self.onConnect?(value,path);self.close();case .failure(let error):self.show(error) }
                }
            }
        } catch { show(error) }
    }
}
