import Foundation

/// Computes recursive folder sizes in the background with a small pool of
/// workers sharing one directory stack. Results are cached and invalidated by
/// file-system events.
final class FolderSizer {
    static let shared = FolderSizer()

    struct Result {
        let bytes: Int64
        let items: Int
        let computedAt: Date
    }

    /// Main-thread state.
    private var cache: [String: Result] = [:]
    private var jobs: [String: Walk] = [:]
    private var waiting: [String: [(Result) -> Void]] = [:]
    private let queue = DispatchQueue(label: "app.diski.foldersize", qos: .utility, attributes: .concurrent)
    private let maxAge: TimeInterval = 180

    func cached(_ path: String) -> Result? {
        guard let result = cache[path] else { return nil }
        if Date().timeIntervalSince(result.computedAt) > maxAge {
            cache.removeValue(forKey: path)
            return nil
        }
        return result
    }

    func isComputing(_ path: String) -> Bool { jobs[path] != nil }

    /// Computes (or returns the cached) size; `completion` runs on the main thread.
    func size(of path: String, progress: ((Int64) -> Void)? = nil, completion: @escaping (Result) -> Void) {
        if let result = cached(path) {
            completion(result)
            return
        }
        waiting[path, default: []].append(completion)
        if jobs[path] != nil { return }
        let walk = Walk(root: path)
        jobs[path] = walk
        walk.onProgress = progress.map { callback in
            { bytes in DispatchQueue.main.async { callback(bytes) } }
        }
        queue.async { [weak self] in
            let (bytes, items) = walk.run()
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.jobs[path] === walk else { return }
                self.jobs.removeValue(forKey: path)
                guard !walk.isCancelled else {
                    self.waiting.removeValue(forKey: path)
                    return
                }
                let result = Result(bytes: bytes, items: items, computedAt: Date())
                self.cache[path] = result
                let callbacks = self.waiting.removeValue(forKey: path) ?? []
                for callback in callbacks { callback(result) }
            }
        }
    }

    func cancel(_ path: String) {
        jobs[path]?.cancel()
        jobs.removeValue(forKey: path)
        waiting.removeValue(forKey: path)
    }

    /// Drops cached sizes of every folder containing one of `changedPaths`.
    func invalidate(changedPaths: [String]) {
        guard !cache.isEmpty else { return }
        for changed in changedPaths {
            for key in cache.keys where changed == key || changed.hasPrefix(key + "/") {
                cache.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Parallel walk

    final class Walk {
        private let condition = NSCondition()
        private var stack: [String]
        private var active = 0
        private var bytes: Int64 = 0
        private var items = 0
        private var cancelled = false
        private var lastReport = Date.distantPast
        var onProgress: ((Int64) -> Void)?

        init(root: String) {
            stack = [root]
        }

        var isCancelled: Bool {
            condition.lock(); defer { condition.unlock() }
            return cancelled
        }

        func cancel() {
            condition.lock()
            cancelled = true
            condition.broadcast()
            condition.unlock()
        }

        func run() -> (Int64, Int) {
            let workers = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
            DispatchQueue.concurrentPerform(iterations: workers) { _ in work() }
            return (bytes, items)
        }

        private func work() {
            while true {
                condition.lock()
                while stack.isEmpty && active > 0 && !cancelled {
                    condition.wait()
                }
                if cancelled || (stack.isEmpty && active == 0) {
                    condition.broadcast()
                    condition.unlock()
                    return
                }
                let directory = stack.removeLast()
                active += 1
                condition.unlock()

                var subdirectories: [String] = []
                var localBytes: Int64 = 0
                var localItems = 0
                let prefix = directory == "/" ? "/" : directory + "/"
                try? DirectoryReader.forEachRawEntry(inDirectory: directory) { entry in
                    localItems += 1
                    if entry.isDirectory {
                        if !entry.isMountPoint { subdirectories.append(prefix + entry.nameString) }
                    } else if entry.size > 0 {
                        localBytes += entry.size
                    }
                }

                condition.lock()
                stack.append(contentsOf: subdirectories)
                bytes += localBytes
                items += localItems
                active -= 1
                var report: Int64? = nil
                if onProgress != nil, Date().timeIntervalSince(lastReport) > 0.25 {
                    lastReport = Date()
                    report = bytes
                }
                condition.broadcast()
                condition.unlock()
                if let report { onProgress?(report) }
            }
        }
    }
}
