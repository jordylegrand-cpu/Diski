import AppKit
import QuickLookThumbnailing

/// Quick Look thumbnails for images, movies, PDFs and documents.
/// Requests are de-duplicated, cached per (path, modification date, size bucket)
/// and can be cancelled when a cell scrolls away.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private var requests: [String: QLThumbnailGenerator.Request] = [:]
    private var waiting: [String: [(NSImage?) -> Void]] = [:]
    /// Keys that produced no thumbnail, so they are not asked for again.
    private var failed = Set<String>()

    private init() {
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    static func bucket(for points: CGFloat) -> Int {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        let target = Int(points.rounded(.up))
        return sizes.first { $0 >= target } ?? 1024
    }

    /// Everything but the bucket (the modification date's bits: no Double formatting).
    private func baseKey(for item: FileItem) -> String {
        "\(item.path)|\(item.modified.bitPattern)|\(item.size)|"
    }

    /// Icon-mode thumbnails (Quick Look's own decoration) are cached apart from plain ones.
    private func key(for item: FileItem, bucket: Int, iconMode: Bool) -> String {
        baseKey(for: item) + String(bucket) + (iconMode ? "|icon" : "")
    }

    func cached(for item: FileItem, points: CGFloat, iconMode: Bool = false) -> NSImage? {
        let b = Self.bucket(for: points), base = baseKey(for: item), suffix = iconMode ? "|icon" : ""
        if let image = cache.object(forKey: (base + String(b) + suffix) as NSString) { return image }
        // The next size up scales down cleanly; much larger images alias when a layer shrinks them.
        for larger in [32, 64, 128, 256, 512, 1024] where larger > b && larger <= b * 2 {
            if let image = cache.object(forKey: (base + String(larger) + suffix) as NSString) { return image }
        }
        return nil
    }

    func hasFailed(_ item: FileItem, points: CGFloat, iconMode: Bool = false) -> Bool {
        failed.contains(key(for: item, bucket: Self.bucket(for: points), iconMode: iconMode))
    }

    /// Requests a thumbnail. Returns a token for `cancel(_:)`. `completion` runs on the main thread.
    /// `iconMode` asks for Finder's decorated style (rounded, inset and softly shadowed;
    /// music tiles for audio), as its list, column and icon views show thumbnails.
    @discardableResult
    func request(for item: FileItem, points: CGFloat, scale: CGFloat, iconMode: Bool = false,
                 completion: @escaping (NSImage?) -> Void) -> String? {
        let b = Self.bucket(for: points)
        let k = key(for: item, bucket: b, iconMode: iconMode)
        if let image = cache.object(forKey: k as NSString) {
            completion(image)
            return nil
        }
        if failed.contains(k) {
            completion(nil)
            return nil
        }
        if waiting[k] != nil {
            waiting[k]?.append(completion)
            return k
        }
        waiting[k] = [completion]
        let request = QLThumbnailGenerator.Request(fileAt: item.url,
                                                   size: CGSize(width: b, height: b),
                                                   scale: max(scale, 1),
                                                   representationTypes: .thumbnail)
        request.iconMode = iconMode
        requests[k] = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            DispatchQueue.main.async {
                guard let self else { return }
                // A cancelled (or superseded) request still calls back; ignore its failure.
                let isCurrent = self.requests[k] === request
                if isCurrent { self.requests.removeValue(forKey: k) }
                if let image {
                    let pixels = Int(image.size.width * image.size.height * 4 * scale * scale)
                    self.cache.setObject(image, forKey: k as NSString, cost: pixels)
                } else if isCurrent {
                    self.failed.insert(k)
                }
                guard isCurrent else { return }
                let callbacks = self.waiting.removeValue(forKey: k) ?? []
                for callback in callbacks { callback(image) }
            }
        }
        return k
    }

    func cancel(_ token: String?) {
        guard let token, let request = requests[token] else { return }
        // Only cancel when nobody else is waiting for the same thumbnail.
        if (waiting[token]?.count ?? 0) <= 1 {
            QLThumbnailGenerator.shared.cancel(request)
            requests.removeValue(forKey: token)
            waiting.removeValue(forKey: token)
        }
    }

    func invalidate(path: String) {
        failed = failed.filter { !$0.hasPrefix(path + "|") }
    }
}
