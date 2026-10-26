import AppKit
import CommanderCore

final class PaneMediaMetadataCache {
    enum Value { case ready(MediaMetadata),failed(String) }
    private var values:[MediaMetadataIdentity:Value] = [:],order:[MediaMetadataIdentity] = []
    private var pending:[MediaMetadataIdentity:(CancellationToken,[(Value)->Void])] = [:]
    private var generation = -1
    private let queue:OperationQueue = { let value = OperationQueue();value.maxConcurrentOperationCount = 2;value.qualityOfService = .utility;return value }()
    deinit { pending.values.forEach { $0.0.cancel() };queue.cancelAllOperations() }
    func context(_ version:Int) { guard generation != version else { return };generation = version;pending.values.forEach { $0.0.cancel() };pending.removeAll();queue.cancelAllOperations() }
    func seed(_ media:[MediaMetadata]) { for value in media { store(.ready(value),for:value.identity) } }
    private func store(_ value:Value,for identity:MediaMetadataIdentity) {
        values[identity] = value;order.removeAll { $0 == identity };order.append(identity)
        while order.count > 256 { values.removeValue(forKey:order.removeFirst()) }
    }
    func request(_ entry:FileEntry,generation:Int,completion:@escaping(Value)->Void) -> Value? {
        context(generation)
        guard entry.url.isFileURL,entry.isRegularFile,!entry.isSymbolicLink,let identity = entry.mediaIdentity else { return .failed("Mediendaten sind nur für lokale reguläre Dateien verfügbar.") }
        guard MediaMetadataReader.supportedExtensions.contains(entry.fileExtension.lowercased()) else { return .failed("Für diesen Dateityp ist kein begrenzter Medienleser vorhanden.") }
        if let value = values[identity] { return value }
        if pending[identity] != nil { if pending[identity]!.1.count < 32 { pending[identity]!.1.append(completion) };return nil }
        guard pending.count < 64 else { return .failed("Medienprüfung ausgelastet; neu einblenden oder aktualisieren.") }
        let token = CancellationToken();pending[identity] = (token,[completion]);let url = entry.url
        queue.addOperation { [weak self] in
            let result:Value
            do { let media = try MediaMetadataReader.read(url,token:token);guard media.identity == identity else { throw CommanderError.message("Datei seit Einlesen der Liste verändert; aktualisieren.") };result = .ready(media) }
            catch { result = .failed(error.localizedDescription) }
            DispatchQueue.main.async { [weak self] in
                guard let self,self.generation == generation,!token.isCancelled,let task = self.pending.removeValue(forKey:identity) else { return }
                self.store(result,for:identity);task.1.forEach { $0(result) }
            }
        }
        return nil
    }
}

extension PaneView {
    func configureMediaCell(_ cell:FileCellView,entry:FileEntry,field:MediaMetadataField) {
        let version = mediaGeneration
        func install(_ value:PaneMediaMetadataCache.Value,into cell:FileCellView) {
            switch value {
            case .ready(let metadata):cell.textField?.stringValue = field.text(metadata) ?? "—";cell.toolTip = field.text(metadata).map { field.title+": "+$0 } ?? "Feld nicht im unterstützten Dateikopf vorhanden."
            case .failed(let error):cell.textField?.stringValue = "—";cell.toolTip = "Nicht verfügbar: "+error
            }
        }
        if let value = mediaCache.request(entry,generation:version,completion:{ [weak self,weak cell] value in
            guard let self,let cell,self.mediaGeneration == version,cell.entryURL == entry.url,self.visibleEntries.contains(where:{ $0.mediaIdentity == entry.mediaIdentity }) else { return };install(value,into:cell)
        }) { install(value,into:cell) }
        else { cell.textField?.stringValue = "…";cell.toolTip = "Mediendaten werden im Hintergrund gelesen." }
    }
}
