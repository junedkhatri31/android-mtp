import Foundation

/// A visibly labelled, read-only preview for development without a physical phone.
public actor PreviewMTP: MTPTransport {
    public init() {}
    public func detect() -> [DeviceInfo] { [DeviceInfo(bus: 1, number: 1, name: "Pixel 9 Pro · Preview")] }
    public func connect(_ device: DeviceInfo) -> String { device.name }
    public func disconnect() {}
    public func storages() -> [DeviceStorage] {
        [DeviceStorage(id: 1, name: "Internal storage", capacity: 128_000_000_000, freeBytes: 78_400_000_000),
         DeviceStorage(id: 2, name: "SD card", capacity: 64_000_000_000, freeBytes: 42_600_000_000)]
    }
    public func list(storage: UInt32, parent: UInt32) -> [RemoteEntry] {
        let date = Date(timeIntervalSince1970: 1_791_504_000)
        if parent == 0 {
            let folders = ["Alarms", "Android", "DCIM", "Documents", "Download", "Movies", "Music", "Pictures"]
            return folders.enumerated().map {
                RemoteEntry(id: UInt32($0.offset + 10), parentID: 0, storageID: storage, name: $0.element, modified: date, isFolder: true)
            } + [RemoteEntry(id: 30, parentID: 0, storageID: storage, name: "Getting started.pdf", size: 2_420_000, modified: date),
                 RemoteEntry(id: 31, parentID: 0, storageID: storage, name: "Weekend playlist.m3u", size: 1240, modified: date)]
        }
        if parent == 12 {
            return [RemoteEntry(id: 40, parentID: parent, storageID: storage, name: "Camera", modified: date, isFolder: true),
                    RemoteEntry(id: 41, parentID: parent, storageID: storage, name: "Screenshots", modified: date, isFolder: true)]
        }
        if parent == 40 || parent == 17 {
            return (1...12).map { index in
                RemoteEntry(id: UInt32(index + 100), parentID: parent, storageID: storage,
                            name: String(format: "IMG_20261010_%04d.jpg", index), size: UInt64(index * 340_000 + 2_000_000), modified: date)
            }
        }
        return [RemoteEntry(id: parent + 200, parentID: parent, storageID: storage, name: "Notes.txt", size: 860, modified: date)]
    }
    private func readOnly() throws { throw MTPError.message("Preview mode is read-only. Relaunch without --demo to transfer files with a real device.") }
    public func createFolder(name: String, storage: UInt32, parent: UInt32) throws -> UInt32 { try readOnly(); return 0 }
    public func rename(_ entry: RemoteEntry, to name: String) throws { try readOnly() }
    public func delete(_ entry: RemoteEntry) throws { try readOnly() }
    public func upload(_ source: URL, name: String, size: UInt64, storage: UInt32, parent: UInt32,
                       cancellation: TransferCancellation, progress: @escaping ByteProgress) throws { try readOnly() }
    public func download(_ entry: RemoteEntry, to target: URL, cancellation: TransferCancellation,
                         progress: @escaping ByteProgress) throws { try readOnly() }
}
