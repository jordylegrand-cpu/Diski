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

    private func key(for item: FileItem, bucket: Int) -> String {
        "\(item.path)|\(item.modified)|\(item.size)|\(bucket)"
    }

    func cached(for item: FileItem, points: CGFloat) -> NSImage? {
        let b = Self.bucket(for: points)
        if let image = cache.object(forKey: key(for: item, bucket: b) as NSString) { return image }
        // A larger thumbnail scales down nicely.
        for larger in [64, 128, 256, 512, 1024] where larger > b {
            if let image = cache.object(forKey: key(for: item, bucket: larger) as NSString) { return image }
        }
        return nil
    }

    func hasFailed(_ item: FileItem, points: CGFloat) -> Bool {
        failed.contains(key(for: item, bucket: Self.bucket(for: points)))
    }

    /// Requests a thumbnail. Returns a token for `cancel(_:)`. `completion` runs on the main thread.
    @discardableResult
    func request(for item: FileItem, points: CGFloat, scale: CGFloat,
                 completion: @escaping (NSImage?) -> Void) -> String? {
        let b = Self.bucket(for: points)
        let k = key(for: item, bucket: b)
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
