import AppKit
import ImageIO
import CommanderCore

final class FileImages {
    private let cache = NSCache<NSString,NSImage>()
    private let queue: OperationQueue = { let q = OperationQueue();q.maxConcurrentOperationCount = 3;q.qualityOfService = .userInitiated;return q }()
    private var epoch = 0
    private var placeholders: [String:NSImage] = [:]
    private(set) var completedRequests = 0
    init() { cache.countLimit = 1000;cache.totalCostLimit = 32*1024*1024 }
    deinit { queue.cancelAllOperations() }
    func cancelPending() { epoch += 1;queue.cancelAllOperations() }
    @discardableResult func load(_ entry:FileEntry,preview:Bool,completion:@escaping(NSImage)->Void) -> (NSImage,Operation?) {
        let key = entry.url.path+"|\(entry.modified.timeIntervalSince1970)|\(entry.size)|\(preview)" as NSString
        if let cached = cache.object(forKey:key) { return (cached,nil) }
        let type = entry.isDirectory ? "folder.fill" : "doc"
        let placeholder = placeholders[type] ?? NSImage(systemSymbolName:type,accessibilityDescription:nil)!
        placeholders[type] = placeholder
        let requestEpoch = epoch,operation = BlockOperation()
        operation.addExecutionBlock { [weak self,weak operation] in
            guard let operation,!operation.isCancelled else { return }
            autoreleasepool {
                var image = NSWorkspace.shared.icon(forFile:entry.url.path)
                if !operation.isCancelled,preview,!entry.isDirectory,!entry.isSymbolicLink,entry.size < 10_000_000,
                   ["png","jpg","jpeg","gif","heic","tif","tiff","webp"].contains(entry.fileExtension.lowercased()),
                   let source = CGImageSourceCreateWithURL(entry.url as CFURL,nil),
                   let bitmap = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:144] as CFDictionary) {
                    image = NSImage(cgImage:bitmap,size:NSSize(width:bitmap.width,height:bitmap.height))
                }
                guard !operation.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self,!operation.isCancelled,self.epoch == requestEpoch else { return }
                    let cost = image.representations.reduce(0) { $0+max(1024,min(8*1024*1024,$1.pixelsWide*$1.pixelsHigh*4)) }
                    self.cache.setObject(image,forKey:key,cost:max(1024,cost));self.completedRequests += 1;completion(image)
                }
            }
        }
        queue.addOperation(operation);return (placeholder,operation)
    }
}
