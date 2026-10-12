import Foundation

public struct TransferEngine: Sendable {
    public let transport: any MTPTransport
    public init(transport: any MTPTransport) { self.transport = transport }

    private struct LocalItem: Sendable {
        let url: URL
        let path: [String]
        let isFolder: Bool
        let size: UInt64
    }
    private struct DownloadItem: Sendable {
        let entry: RemoteEntry
        let url: URL
    }

    public func upload(_ source: URL, storage: DeviceStorage, parent: UInt32,
                       cancellation: TransferCancellation, progress: @escaping ProgressHandler) async throws {
        try cancellation.check()
        guard storage.writable else { throw MTPError.message("This storage is read-only.") }
        // Enumerate and validate the entire local tree before creating anything on the phone.
        var items: [LocalItem] = []
        try collectLocal(source, path: [source.lastPathComponent], depth: 0, items: &items, cancellation: cancellation)
        let total = try sumSizes(items.map(\.size))
        let currentStorages = try await transport.storages()
        guard let current = currentStorages.first(where: { $0.id == storage.id }) else {
            throw MTPError.message("The destination storage is no longer available.")
        }
        guard total <= current.freeBytes else { throw MTPError.message("There is not enough free space on the device for this transfer.") }
        let existing = try await transport.list(storage: storage.id, parent: parent)
        try FileSafety.checkUnique(source.lastPathComponent, among: existing)
        var folders: [[String]: UInt32] = [ []: parent ]
        var completed: UInt64 = 0
        var filesCompleted = 0
        let filesTotal = items.filter { !$0.isFolder }.count
        for item in items {
            try cancellation.check()
            let parentPath = Array(item.path.dropLast())
            guard let parentID = folders[parentPath] else { throw MTPError.message("Could not resolve the destination folder.") }
            progress(TransferProgress(name: item.url.lastPathComponent, completed: completed, total: total,
                                      filesCompleted: filesCompleted, filesTotal: filesTotal))
            if item.isFolder {
                folders[item.path] = try await transport.createFolder(name: item.url.lastPathComponent, storage: storage.id, parent: parentID)
            } else {
                let base = completed
                let count = filesCompleted
                try await transport.upload(item.url, name: item.url.lastPathComponent, size: item.size,
                                           storage: storage.id, parent: parentID, cancellation: cancellation) { sent, _ in
                    progress(TransferProgress(name: item.url.lastPathComponent, completed: base + min(sent, item.size), total: total,
                                              filesCompleted: count, filesTotal: filesTotal))
                }
                completed += item.size
                filesCompleted += 1
            }
        }
        progress(TransferProgress(name: source.lastPathComponent, completed: total, total: total,
                                  filesCompleted: filesCompleted, filesTotal: filesTotal))
    }

    public func download(_ entry: RemoteEntry, into directory: URL,
                         cancellation: TransferCancellation, progress: @escaping ProgressHandler) async throws {
        try cancellation.check()
        let target = try FileSafety.child(named: entry.name, in: directory)
        if FileManager.default.fileExists(atPath: target.path) { throw MTPError.alreadyExists(entry.name) }
        var items: [DownloadItem] = []
        var visited = Set<UInt32>()
        try await collectRemote(entry, target: target, depth: 0, items: &items, visited: &visited, cancellation: cancellation)
        let total = try sumSizes(items.filter { !$0.entry.isFolder }.map { $0.entry.size })
        let volume = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = volume.volumeAvailableCapacityForImportantUsage, total > UInt64(max(0, available)) {
            throw MTPError.message("There is not enough free space on your Mac for this transfer.")
        }
        let filesTotal = items.filter { !$0.entry.isFolder }.count
        var completed: UInt64 = 0
        var filesCompleted = 0
        for item in items {
            try cancellation.check()
            progress(TransferProgress(name: item.entry.name, completed: completed, total: total,
                                      filesCompleted: filesCompleted, filesTotal: filesTotal))
            if FileManager.default.fileExists(atPath: item.url.path) { throw MTPError.alreadyExists(item.entry.name) }
            if item.entry.isFolder {
                try FileManager.default.createDirectory(at: item.url, withIntermediateDirectories: false)
            } else {
                let temporary = item.url.deletingLastPathComponent().appendingPathComponent(".androidmtp-\(UUID().uuidString).partial")
                defer { try? FileManager.default.removeItem(at: temporary) }
                let base = completed
                let count = filesCompleted
                try await transport.download(item.entry, to: temporary, cancellation: cancellation) { sent, _ in
                    progress(TransferProgress(name: item.entry.name, completed: base + min(sent, item.entry.size), total: total,
                                              filesCompleted: count, filesTotal: filesTotal))
                }
                try cancellation.check()
                let attributes = try FileManager.default.attributesOfItem(atPath: temporary.path)
                let actual = (attributes[.size] as? NSNumber)?.uint64Value
                guard actual == item.entry.size else { throw MTPError.message("“\(item.entry.name)” was incomplete. The partial download was removed.") }
                try FileManager.default.moveItem(at: temporary, to: item.url)
                if let date = item.entry.modified {
                    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.url.path)
                }
                completed += item.entry.size
                filesCompleted += 1
            }
        }
        progress(TransferProgress(name: entry.name, completed: total, total: total,
                                  filesCompleted: filesCompleted, filesTotal: filesTotal))
    }

    /// Gather the complete deletion plan before applying it, then remove children before parents.
    public func delete(_ entries: [RemoteEntry]) async throws {
        var plan: [RemoteEntry] = []
        var visited = Set<UInt32>()
        for entry in entries { try await collectDeletion(entry, depth: 0, plan: &plan, visited: &visited) }
        for entry in plan { try await transport.delete(entry) }
    }

    private func collectDeletion(_ entry: RemoteEntry, depth: Int, plan: inout [RemoteEntry], visited: inout Set<UInt32>) async throws {
        guard depth < 128, visited.insert(entry.id).inserted else { throw MTPError.message("The device returned a cyclic or excessively deep folder tree.") }
        if entry.isFolder {
            for child in try await transport.list(storage: entry.storageID, parent: entry.id) {
                try await collectDeletion(child, depth: depth + 1, plan: &plan, visited: &visited)
            }
        }
        plan.append(entry)
    }

    private func collectLocal(_ url: URL, path: [String], depth: Int, items: inout [LocalItem], cancellation: TransferCancellation) throws {
        try cancellation.check()
        guard depth < 128 else { throw MTPError.message("This folder tree is too deep to transfer.") }
        try FileSafety.validateName(url.lastPathComponent)
        let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
        guard info.isSymbolicLink != true else { throw MTPError.message("“\(url.lastPathComponent)” is a symbolic link. Transfer its original file instead.") }
        let isFolder = info.isDirectory == true
        guard isFolder || info.isRegularFile == true else { throw MTPError.message("“\(url.lastPathComponent)” is not a regular file or folder.") }
        let size = isFolder ? 0 : UInt64(max(0, info.fileSize ?? 0))
        items.append(LocalItem(url: url, path: path, isFolder: isFolder, size: size))
        if isFolder {
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var names = Set<String>()
            for child in children {
                let key = child.lastPathComponent.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard names.insert(key).inserted else { throw MTPError.alreadyExists(child.lastPathComponent) }
                try collectLocal(child, path: path + [child.lastPathComponent], depth: depth + 1, items: &items, cancellation: cancellation)
            }
        }
    }

    private func collectRemote(_ entry: RemoteEntry, target: URL, depth: Int, items: inout [DownloadItem],
                               visited: inout Set<UInt32>, cancellation: TransferCancellation) async throws {
        try cancellation.check()
        guard depth < 128, visited.insert(entry.id).inserted else { throw MTPError.message("The device returned a cyclic or excessively deep folder tree.") }
        items.append(DownloadItem(entry: entry, url: target))
        if entry.isFolder {
            var names = Set<String>()
            for child in try await transport.list(storage: entry.storageID, parent: entry.id) {
                let key = child.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                guard names.insert(key).inserted else { throw MTPError.alreadyExists(child.name) }
                let childURL = try FileSafety.child(named: child.name, in: target)
                try await collectRemote(child, target: childURL, depth: depth + 1, items: &items, visited: &visited, cancellation: cancellation)
            }
        }
    }

    private func sumSizes(_ values: [UInt64]) throws -> UInt64 {
        try values.reduce(0) { sum, value in
            let (result, overflow) = sum.addingReportingOverflow(value)
            guard !overflow else { throw MTPError.message("This transfer exceeds the supported size.") }
            return result
        }
    }
}
