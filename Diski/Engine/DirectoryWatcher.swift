import CoreServices
import Foundation

/// Watches a set of directories with FSEvents and reports which of them
/// changed. Events for nested paths are mapped to the closest watched
/// directory so a folder refreshes when its children change.
final class DirectoryWatcher {
    /// Called on the main thread with the watched directories that changed and
    /// every raw changed path (used to invalidate folder sizes).
    var onChange: ((_ directories: Set<String>, _ rawPaths: [String]) -> Void)?

    private var stream: FSEventStreamRef?
    private var watched: Set<String> = []
    private let queue = DispatchQueue(label: "app.diski.fsevents", qos: .userInitiated)

    deinit {
        stopStream()
    }

    /// Replaces the set of watched directories (no-op when unchanged).
    func watch(_ paths: Set<String>) {
        let normalized = Set(paths.map { DirectoryReader.normalized($0) })
        guard normalized != watched else { return }
        watched = normalized
        stopStream()
        guard !normalized.isEmpty else { return }

        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as NSArray
            var paths: [String] = []
            paths.reserveCapacity(count)
            for case let path as String in array { paths.append(path) }
            watcher.handle(paths)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context,
                                               Array(normalized) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               0.08, flags) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        watched = []
        stopStream()
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(_ paths: [String]) {
        let watched = self.watched
        var hit = Set<String>()
        for raw in paths {
            var path = raw
            if path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            // The changed item itself may be a watched directory (renamed, attributes changed).
            if watched.contains(path) { hit.insert(path) }
            // A direct child changed, or something inside a direct child folder
            // (which changes that folder's date and item count).
            let parent = (path as NSString).deletingLastPathComponent
            if watched.contains(parent) {
                hit.insert(parent)
            } else {
                let grandparent = (parent as NSString).deletingLastPathComponent
                if watched.contains(grandparent) { hit.insert(grandparent) }
            }
        }
        guard !hit.isEmpty || !paths.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(hit, paths)
        }
    }
}
