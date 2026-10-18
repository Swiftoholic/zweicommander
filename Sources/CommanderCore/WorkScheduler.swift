import Foundation

public enum WorkState: String, Codable { case waiting, running, pausing, paused, review, completed, failed, cancelled }
public struct WorkSnapshot: Identifiable, Codable {
    public let id: UUID
    public let title: String
    public var state: WorkState
    public var detail: String
    public var fraction: Double?
    public var transferredBytes: Int64?
    public var totalBytes: Int64?
    public var items: [TransferItemProgress]
    public var isPending: Bool { [.waiting,.running,.pausing,.paused].contains(state) }
    public var isFinished: Bool { [.completed,.failed,.cancelled].contains(state) }
    public static func waiting(id: UUID = UUID(),title: String,items: [TransferItemProgress] = []) -> WorkSnapshot {
        let tracked = !items.isEmpty && items.allSatisfy(\.isByteTracked)
        let pendingBytes = items.filter { $0.state != .skipped }.reduce(Int64(0)) { $0+$1.totalBytes }
        return WorkSnapshot(id:id,title:title,state:.waiting,detail:"Wartet",fraction:tracked && pendingBytes > 0 ? 0 : nil,transferredBytes:tracked ? 0 : nil,totalBytes:tracked ? pendingBytes : nil,items:items)
    }
}
public final class WorkReporter {
    private let update: (String,Double?,TransferProgress?) -> Void
    init(_ update: @escaping (String,Double?,TransferProgress?) -> Void) { self.update = update }
    public func report(_ detail: String,fraction: Double? = nil) { update(detail,fraction,nil) }
    public func transfer(_ progress: TransferProgress) { update(progress.detail,progress.fraction,progress) }
}
private final class ScheduledWork {
    var snapshot: WorkSnapshot
    let token = CancellationToken()
    var body: ((CancellationToken,WorkReporter) throws -> Void)?
    var completion: ((WorkSnapshot) -> Void)?
    init(_ snapshot: WorkSnapshot,body: ((CancellationToken,WorkReporter) throws -> Void)? = nil,completion: ((WorkSnapshot) -> Void)? = nil) {
        self.snapshot = snapshot;self.body = body;self.completion = completion
    }
    var visible: WorkSnapshot {
        var result = snapshot
        if result.state == .running && token.isPaused { result.state = token.isWaitingForResume ? .paused : .pausing }
        return result
    }
}
public final class WorkScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private let worker = DispatchQueue(label:"local.zweicommander.operations",qos:.userInitiated)
    private var records: [ScheduledWork] = []
    private var active: UUID?
    private var held = false
    public var onChange: (() -> Void)?
    public init() {}
    public var snapshots: [WorkSnapshot] { lock.lock(); defer { lock.unlock() }; return records.map(\.visible) }
    public var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
    @discardableResult public func enqueue(_ title: String,id: UUID = UUID(),start: Bool = true,items: [TransferItemProgress] = [],body: @escaping (CancellationToken,WorkReporter) throws -> Void,completion: @escaping (WorkSnapshot) -> Void = { _ in }) -> UUID {
        let work = ScheduledWork(.waiting(id:id,title:title,items:items),body:body,completion:completion)
        lock.lock(); records.append(work)
        if start { held = false } else if active == nil { held = true }
        lock.unlock(); onChange?(); schedule(); return work.snapshot.id
    }
    // Restored descriptions never contain executable work and cannot be started.
    public func restore(_ snapshots: [WorkSnapshot]) {
        lock.lock()
        for var snapshot in snapshots where !records.contains(where: { $0.snapshot.id == snapshot.id }) {
            if !snapshot.isFinished { snapshot.state = .review }
            records.append(ScheduledWork(snapshot))
        }
        lock.unlock();onChange?()
    }
    @discardableResult public func discardRestored(_ id: UUID) -> Bool {
        lock.lock()
        let index = records.firstIndex { $0.snapshot.id == id && !$0.snapshot.isPending && $0.body == nil }
        if let index { records.remove(at:index) }
        lock.unlock();onChange?();return index != nil
    }
    public func start(_ id: UUID? = nil) {
        lock.lock()
        if let id,let index = records.firstIndex(where:{$0.snapshot.id == id && $0.snapshot.state == .waiting}),let first = records.firstIndex(where:{$0.snapshot.state == .waiting}) {
            let item = records.remove(at:index); records.insert(item,at:first)
        }
        held = false; lock.unlock(); onChange?(); schedule()
    }
    public func move(_ id: UUID,by offset: Int) {
        lock.lock()
        let waiting = records.indices.filter { records[$0].snapshot.state == .waiting }
        if let position = waiting.firstIndex(where:{ records[$0].snapshot.id == id }),waiting.indices.contains(position+offset) { records.swapAt(waiting[position],waiting[position+offset]) }
        lock.unlock(); onChange?()
    }
    public func remove(_ id: UUID) {
        lock.lock()
        let work = records.first { $0.snapshot.id == id && [.waiting,.review].contains($0.snapshot.state) }
        if let work {
            work.token.cancel(); work.snapshot.state = .cancelled; work.snapshot.detail = "Aus Warteschlange entfernt"
            for i in work.snapshot.items.indices { work.snapshot.items[i].state = .cancelled;work.snapshot.items[i].message = "Nicht ausgeführt" }
            work.body = nil
        }
        let finish = work?.completion;work?.completion = nil
        lock.unlock()
        if let work { finish?(work.visible) }; onChange?()
    }
    public func pause() { lock.lock(); let work = records.first { $0.snapshot.id == active }; held = true; work?.token.pause(); lock.unlock(); onChange?() }
    public func resume() { lock.lock(); held = false; records.first { $0.snapshot.id == active }?.token.resume(); lock.unlock(); onChange?(); schedule() }
    public func cancel() { lock.lock(); records.first { $0.snapshot.id == active }?.token.cancel(); lock.unlock(); onChange?() }
    @discardableResult public func clearFinished() -> [UUID] {
        lock.lock();let ids = records.filter { $0.snapshot.isFinished }.map { $0.snapshot.id }
        records.removeAll { $0.snapshot.isFinished };lock.unlock();onChange?();return ids
    }
    private func schedule() {
        lock.lock()
        guard active == nil,!held,let work = records.first(where:{$0.snapshot.state == .waiting}) else { lock.unlock(); return }
        active = work.snapshot.id; work.snapshot.state = .running; work.snapshot.detail = "Wird gestartet …"
        lock.unlock(); onChange?()
        worker.async { [self,work] in
            let reporter = WorkReporter { [weak self,weak work] detail,fraction,transfer in
                guard let self,let work else { return }
                self.lock.lock(); work.snapshot.detail = detail; work.snapshot.fraction = fraction.map { max(0,min(1,$0)) }
                if let transfer { work.snapshot.items = transfer.items; work.snapshot.transferredBytes = transfer.measuredBytes ? transfer.bytes : nil; work.snapshot.totalBytes = transfer.measuredBytes ? transfer.totalBytes : nil }
                self.lock.unlock(); self.onChange?()
            }
            var failure: Error?
            do { try work.token.check(); try work.body?(work.token,reporter) } catch { failure = error }
            lock.lock()
            work.snapshot.state = work.token.isCancelled ? .cancelled : failure == nil ? .completed : .failed
            if let failure { work.snapshot.detail = failure.localizedDescription }
            else if work.snapshot.state == .completed { work.snapshot.fraction = 1 }
            active = nil; let result = work.visible
            let finish = work.completion;work.completion = nil;work.body = nil
            lock.unlock(); onChange?(); finish?(result); schedule()
        }
    }
}
