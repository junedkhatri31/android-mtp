import Foundation
import MTPBridge

/// All libmtp calls run on this actor's executor, never on the main actor.
public actor NativeMTP: MTPTransport {
    private final class Connection {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { am_close(pointer) }
    }
    private var connection: Connection?
    public init() {}

    private func device() throws -> OpaquePointer {
        guard let connection else { throw MTPError.notConnected }
        return connection.pointer
    }
    private func failure(_ connection: OpaquePointer) -> MTPError {
        let value = String(cString: am_error(connection))
        return .message(value.isEmpty ? "The USB operation failed. Unlock or reconnect the device and try again." : value)
    }

    public func detect() throws -> [DeviceInfo] {
        var head: UnsafeMutablePointer<AMDevice>?
        var buffer = [CChar](repeating: 0, count: 2048)
        guard am_detect(&head, &buffer, buffer.count) == 0 else {
            throw MTPError.message(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        defer { am_free_devices(head) }
        var devices: [DeviceInfo] = []
        var cursor = head
        while let node = cursor {
            let d = node.pointee
            devices.append(DeviceInfo(bus: d.bus, number: d.number, name: String(cString: d.name)))
            cursor = d.next
        }
        return devices
    }

    public func connect(_ info: DeviceInfo) throws -> String {
        connection = nil
        var buffer = [CChar](repeating: 0, count: 2048)
        guard let pointer = am_open(info.bus, info.number, &buffer, buffer.count) else {
            throw MTPError.message(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        connection = Connection(pointer)
        return String(cString: am_device_name(pointer))
    }

    public func disconnect() { connection = nil }

    public func storages() throws -> [DeviceStorage] {
        let d = try device()
        var head: UnsafeMutablePointer<AMStorage>?
        guard am_storages(d, &head) == 0 else { throw failure(d) }
        defer { am_free_storages(head) }
        var result: [DeviceStorage] = []
        var cursor = head
        while let node = cursor {
            let s = node.pointee
            result.append(DeviceStorage(id: s.id, name: String(cString: s.name),
                                        capacity: s.capacity, freeBytes: s.free_bytes, writable: s.writable != 0))
            cursor = s.next
        }
        return result
    }

    public func list(storage: UInt32, parent: UInt32) throws -> [RemoteEntry] {
        let d = try device()
        var head: UnsafeMutablePointer<AMEntry>?
        guard am_list(d, storage, parent, &head) == 0 else { throw failure(d) }
        defer { am_free_entries(head) }
        var entries: [RemoteEntry] = []
        var cursor = head
        while let node = cursor {
            let e = node.pointee
            entries.append(RemoteEntry(id: e.id, parentID: e.parent, storageID: e.storage,
                                       name: String(cString: e.name), size: e.size,
                                       modified: e.modified > 0 ? Date(timeIntervalSince1970: Double(e.modified)) : nil,
                                       isFolder: e.is_folder != 0))
            cursor = e.next
        }
        return entries
    }

    public func createFolder(name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        try FileSafety.validateName(name)
        let d = try device()
        let id = am_create_folder(d, storage, parent, name)
        guard id != 0 else { throw failure(d) }
        return id
    }

    public func rename(_ entry: RemoteEntry, to name: String) throws {
        try FileSafety.validateName(name)
        let d = try device()
        guard am_rename(d, entry.id, entry.isFolder ? 1 : 0, name) == 0 else { throw failure(d) }
    }

    public func delete(_ entry: RemoteEntry) throws {
        let d = try device()
        guard am_delete(d, entry.id) == 0 else { throw failure(d) }
    }

    public func upload(_ source: URL, name: String, size: UInt64, storage: UInt32, parent: UInt32,
                       cancellation: TransferCancellation, progress: @escaping ByteProgress) throws {
        try cancellation.check()
        let d = try device()
        let context = CallbackContext(progress)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        let result = am_upload(d, storage, parent, source.path, name, size,
                               cancellation.pointer, progressCallback, pointer)
        withExtendedLifetime(context) {}
        if result != 0 {
            try cancellation.check()
            throw failure(d)
        }
    }

    public func download(_ entry: RemoteEntry, to target: URL, cancellation: TransferCancellation,
                         progress: @escaping ByteProgress) throws {
        try cancellation.check()
        let d = try device()
        let context = CallbackContext(progress)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        let result = am_download(d, entry.id, target.path, cancellation.pointer, progressCallback, pointer)
        withExtendedLifetime(context) {}
        if result != 0 {
            try cancellation.check()
            throw failure(d)
        }
    }
}

private final class CallbackContext {
    let handler: ByteProgress
    var lastUpdate: TimeInterval = 0
    init(_ handler: @escaping ByteProgress) { self.handler = handler }
    func report(_ completed: UInt64, _ total: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastUpdate >= 0.06 || completed == total {
            lastUpdate = now
            handler(completed, total)
        }
    }
}

private let progressCallback: @convention(c) (UInt64, UInt64, UnsafeMutableRawPointer?) -> Void = { completed, total, pointer in
    guard let pointer else { return }
    Unmanaged<CallbackContext>.fromOpaque(pointer).takeUnretainedValue().report(completed, total)
}
