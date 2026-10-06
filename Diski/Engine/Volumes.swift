import AppKit

struct VolumeInfo: Hashable {
    let url: URL
    let name: String
    let isRoot: Bool
    let isInternal: Bool
    let isEjectable: Bool
    let isRemovable: Bool
    let isLocal: Bool
    let totalCapacity: Int64
    let availableCapacity: Int64

    var path: String { url.path }
    var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return 1 - Double(availableCapacity) / Double(totalCapacity)
    }
}

/// Mounted volumes, kept current through workspace mount notifications.
final class VolumeMonitor {
    static let shared = VolumeMonitor()
    static let didChange = Notification.Name("DiskiVolumesDidChange")

    private(set) var volumes: [VolumeInfo] = []
    private var observers: [NSObjectProtocol] = []

    private static let keys: [URLResourceKey] = [
        .volumeLocalizedNameKey, .volumeNameKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
        .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ]

    private init() {
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            })
        }
    }

    func refresh() {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.keys,
                                                          options: [.skipHiddenVolumes]) ?? []
        var result: [VolumeInfo] = []
        for url in urls {
            guard let info = Self.info(for: url) else { continue }
            result.append(info)
        }
        // Boot volume first, then internal, then the rest by name.
        result.sort { a, b in
            if a.isRoot != b.isRoot { return a.isRoot }
            if a.isInternal != b.isInternal { return a.isInternal }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if result != volumes {
            volumes = result
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    static func info(for url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if values.volumeIsBrowsable == false { return nil }
        let isRoot = values.volumeIsRootFileSystem ?? (url.path == "/")
        let name = values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent
        let total = Int64(values.volumeTotalCapacity ?? 0)
        var available = values.volumeAvailableCapacityForImportantUsage ?? 0
        if available <= 0 { available = Int64(values.volumeAvailableCapacity ?? 0) }
        return VolumeInfo(url: url, name: name, isRoot: isRoot,
                          isInternal: values.volumeIsInternal ?? isRoot,
                          isEjectable: values.volumeIsEjectable ?? false,
                          isRemovable: values.volumeIsRemovable ?? false,
                          isLocal: values.volumeIsLocal ?? true,
                          totalCapacity: total, availableCapacity: available)
    }

    /// The volume containing `path` (longest mount-point prefix).
    func volume(containing path: String) -> VolumeInfo? {
        var best: VolumeInfo?
        for volume in volumes {
            let mount = volume.path
            if mount == "/" || path == mount || path.hasPrefix(mount + "/") {
                if best == nil || mount.count > best!.path.count { best = volume }
            }
        }
        return best
    }

    /// Free space for the volume holding `path` (fresh value, not cached).
    static func availableCapacity(forPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                              .volumeAvailableCapacityKey]) else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values.volumeAvailableCapacity.map { Int64($0) }
    }

    func eject(_ volume: VolumeInfo, completion: @escaping (Error?) -> Void) {
        let url = volume.url
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            } catch {
                failure = error
            }
            DispatchQueue.main.async {
                self.refresh()
                completion(failure)
            }
        }
    }
}
