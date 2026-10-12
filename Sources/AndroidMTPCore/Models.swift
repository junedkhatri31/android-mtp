import Foundation
import MTPBridge

public struct DeviceInfo: Identifiable, Hashable, Sendable {
    public let bus: UInt32
    public let number: UInt8
    public let name: String
    public var id: String { "\(bus):\(number)" }
    public init(bus: UInt32, number: UInt8, name: String) {
        self.bus = bus; self.number = number; self.name = name
    }
}

public struct DeviceStorage: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    public let capacity: UInt64
    public let freeBytes: UInt64
    public let writable: Bool
    public var usedFraction: Double {
        capacity == 0 ? 0 : 1 - Double(min(freeBytes, capacity)) / Double(capacity)
    }
    public init(id: UInt32, name: String, capacity: UInt64, freeBytes: UInt64, writable: Bool = true) {
        self.id = id; self.name = name; self.capacity = capacity
        self.freeBytes = freeBytes; self.writable = writable
    }
}

public struct RemoteEntry: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let parentID: UInt32
    public let storageID: UInt32
    public let name: String
    public let size: UInt64
    public let modified: Date?
    public let isFolder: Bool
    public init(id: UInt32, parentID: UInt32, storageID: UInt32, name: String,
                size: UInt64 = 0, modified: Date? = nil, isFolder: Bool = false) {
        self.id = id; self.parentID = parentID; self.storageID = storageID
        self.name = name; self.size = size; self.modified = modified; self.isFolder = isFolder
    }
    public var kind: String {
        if isFolder { return "Folder" }
        let ext = (name as NSString).pathExtension.uppercased()
        return ext.isEmpty ? "File" : "\(ext) file"
    }
    public var symbol: String {
        if isFolder { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "webp", "heic", "gif": return "photo"
        case "mp4", "mov", "mkv", "webm": return "film"
        case "mp3", "m4a", "ogg", "wav", "flac": return "music.note"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}

public enum MTPError: LocalizedError, Sendable, Equatable {
    case message(String)
    case notConnected
    case cancelled
    case invalidName(String)
    case alreadyExists(String)
    public var errorDescription: String? {
        switch self {
        case .message(let value): value
        case .notConnected: "Your device is disconnected. Reconnect it and try again."
        case .cancelled: "Transfer cancelled. Files already completed are kept."
        case .invalidName(let name): "“\(name)” cannot be used as a file name. Use 1–255 UTF-8 bytes without slashes, colons, or control characters."
        case .alreadyExists(let name): "“\(name)” already exists in the destination. Rename it or choose another folder. Existing files have been kept."
        }
    }
}

public enum FileSafety {
    public static func validateName(_ name: String) throws {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", name.utf8.count <= 255,
              name.rangeOfCharacter(from: forbidden) == nil else { throw MTPError.invalidName(name) }
    }
    public static func child(named name: String, in directory: URL) throws -> URL {
        try validateName(name)
        return directory.appendingPathComponent(name, isDirectory: false)
    }
    public static func checkUnique(_ name: String, among entries: [RemoteEntry], excluding id: UInt32? = nil) throws {
        try validateName(name)
        if entries.contains(where: { $0.id != id && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            throw MTPError.alreadyExists(name)
        }
    }
    public static func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
}

/// Only the atomic cancellation flag is shared with the USB callback thread.
public final class TransferCancellation: @unchecked Sendable {
    let pointer: OpaquePointer
    public init() {
        guard let pointer = am_cancellation_new() else { fatalError("Could not allocate cancellation flag") }
        self.pointer = pointer
    }
    deinit { am_cancellation_free(pointer) }
    public func cancel() { am_cancel(pointer) }
    public var isCancelled: Bool { am_is_cancelled(pointer) != 0 }
    public func check() throws { if isCancelled { throw MTPError.cancelled } }
}

public struct TransferProgress: Sendable {
    public let name: String
    public let completed: UInt64
    public let total: UInt64
    public let filesCompleted: Int
    public let filesTotal: Int
    public var fraction: Double { total == 0 ? 0 : min(1, Double(completed) / Double(total)) }
    public init(name: String, completed: UInt64, total: UInt64, filesCompleted: Int, filesTotal: Int) {
        self.name = name; self.completed = completed; self.total = total
        self.filesCompleted = filesCompleted; self.filesTotal = filesTotal
    }
}

public typealias ByteProgress = @Sendable (UInt64, UInt64) -> Void
public typealias ProgressHandler = @Sendable (TransferProgress) -> Void

public protocol MTPTransport: Sendable {
    func detect() async throws -> [DeviceInfo]
    func connect(_ device: DeviceInfo) async throws -> String
    func disconnect() async
    func storages() async throws -> [DeviceStorage]
    func list(storage: UInt32, parent: UInt32) async throws -> [RemoteEntry]
    func createFolder(name: String, storage: UInt32, parent: UInt32) async throws -> UInt32
    func rename(_ entry: RemoteEntry, to name: String) async throws
    func delete(_ entry: RemoteEntry) async throws
    func upload(_ source: URL, name: String, size: UInt64, storage: UInt32, parent: UInt32,
                cancellation: TransferCancellation, progress: @escaping ByteProgress) async throws
    func download(_ entry: RemoteEntry, to target: URL, cancellation: TransferCancellation,
                  progress: @escaping ByteProgress) async throws
}
