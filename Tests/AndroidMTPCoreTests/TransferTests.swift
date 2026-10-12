import Foundation
import Testing
@testable import AndroidMTPCore

private final class Fixture: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("AndroidMTP-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String, contents: String = "hello") throws -> URL {
        let child = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: child)
        return child
    }
}

private actor TestTransport: MTPTransport {
    struct Upload: Sendable, Equatable { let name: String; let size: UInt64; let parent: UInt32 }
    struct Folder: Sendable, Equatable { let name: String; let parent: UInt32; let id: UInt32 }
    var tree: [UInt32: [RemoteEntry]]
    var payload: Data
    var downloadFailure: Bool
    var uploads: [Upload] = []
    var folders: [Folder] = []
    var deleted: [UInt32] = []
    var nextID: UInt32 = 1000
    init(tree: [UInt32: [RemoteEntry]] = [:], payload: Data = Data("hello".utf8), downloadFailure: Bool = false) {
        self.tree = tree; self.payload = payload; self.downloadFailure = downloadFailure
    }
    func detect() -> [DeviceInfo] { [] }
    func connect(_ device: DeviceInfo) -> String { "Test device" }
    func disconnect() {}
    func storages() -> [DeviceStorage] { [testStorage] }
    func list(storage: UInt32, parent: UInt32) -> [RemoteEntry] { tree[parent] ?? [] }
    func createFolder(name: String, storage: UInt32, parent: UInt32) -> UInt32 {
        nextID += 1
        folders.append(Folder(name: name, parent: parent, id: nextID))
        return nextID
    }
    func rename(_ entry: RemoteEntry, to name: String) {}
    func delete(_ entry: RemoteEntry) { deleted.append(entry.id) }
    func upload(_ source: URL, name: String, size: UInt64, storage: UInt32, parent: UInt32,
                cancellation: TransferCancellation, progress: @escaping ByteProgress) throws {
        try cancellation.check()
        uploads.append(Upload(name: name, size: size, parent: parent))
        progress(size, size)
    }
    func download(_ entry: RemoteEntry, to target: URL, cancellation: TransferCancellation,
                  progress: @escaping ByteProgress) throws {
        try cancellation.check()
        try payload.write(to: target)
        if downloadFailure { throw MTPError.message("USB disconnected") }
        progress(UInt64(payload.count), entry.size)
    }
    func mutations() -> ([Upload], [Folder], [UInt32]) { (uploads, folders, deleted) }
}

private let testStorage = DeviceStorage(id: 1, name: "Internal", capacity: 1_000_000, freeBytes: 900_000)
private func fileEntry(id: UInt32 = 1, name: String = "hello.txt", parent: UInt32 = 0, size: UInt64 = 5) -> RemoteEntry {
    RemoteEntry(id: id, parentID: parent, storageID: 1, name: name, size: size)
}
private func folderEntry(id: UInt32 = 10, name: String = "Photos", parent: UInt32 = 0) -> RemoteEntry {
    RemoteEntry(id: id, parentID: parent, storageID: 1, name: name, isFolder: true)
}

@Test func rejectsTraversalAndNonportableNames() throws {
    for name in ["", " ", ".", "..", "../outside", "a/b", "a\\b", "a:b", "a\0b", "a\nb", String(repeating: "é", count: 128)] {
        #expect(throws: MTPError.self) { try FileSafety.validateName(name) }
    }
    for name in ["vacation.jpg", "résumé.pdf", "旅行", ".nomedia"] { try FileSafety.validateName(name) }
}

@Test func recursiveUploadPreservesParentFoldersAndByteSizes() async throws {
    let fixture = try Fixture()
    let source = fixture.url.appendingPathComponent("Trip")
    let nested = source.appendingPathComponent("Day 1")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("abc".utf8).write(to: nested.appendingPathComponent("photo.jpg"))
    try Data("hello".utf8).write(to: source.appendingPathComponent("notes.txt"))
    let transport = TestTransport()
    try await TransferEngine(transport: transport).upload(source, storage: testStorage, parent: 42, cancellation: TransferCancellation()) { _ in }
    let (uploads, folders, _) = await transport.mutations()
    #expect(folders.count == 2)
    #expect(folders[0].name == "Trip" && folders[0].parent == 42)
    #expect(folders[1].name == "Day 1" && folders[1].parent == folders[0].id)
    #expect(uploads.contains(TestTransport.Upload(name: "photo.jpg", size: 3, parent: folders[1].id)))
    #expect(uploads.contains(TestTransport.Upload(name: "notes.txt", size: 5, parent: folders[0].id)))
}

@Test func uploadCollisionLeavesDestinationUntouched() async throws {
    let fixture = try Fixture()
    let source = try fixture.file("hello.txt")
    let transport = TestTransport(tree: [0: [fileEntry(name: "HELLO.txt")]])
    await #expect(throws: MTPError.alreadyExists("hello.txt")) {
        try await TransferEngine(transport: transport).upload(source, storage: testStorage, parent: 0, cancellation: TransferCancellation()) { _ in }
    }
    let (uploads, folders, _) = await transport.mutations()
    #expect(uploads.isEmpty && folders.isEmpty)
}

@Test func symbolicLinksAreRejectedBeforeDeviceMutation() async throws {
    let fixture = try Fixture()
    let original = try fixture.file("original.txt")
    let folder = fixture.url.appendingPathComponent("Folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.txt"), withDestinationURL: original)
    let transport = TestTransport()
    await #expect(throws: MTPError.self) {
        try await TransferEngine(transport: transport).upload(folder, storage: testStorage, parent: 0, cancellation: TransferCancellation()) { _ in }
    }
    let (uploads, folders, _) = await transport.mutations()
    #expect(uploads.isEmpty && folders.isEmpty)
}

@Test func cancelledUploadDoesNotCreateObjects() async throws {
    let fixture = try Fixture()
    let source = try fixture.file("hello.txt")
    let transport = TestTransport()
    let cancellation = TransferCancellation()
    cancellation.cancel()
    await #expect(throws: MTPError.cancelled) {
        try await TransferEngine(transport: transport).upload(source, storage: testStorage, parent: 0, cancellation: cancellation) { _ in }
    }
    let (uploads, folders, _) = await transport.mutations()
    #expect(uploads.isEmpty && folders.isEmpty)
}

@Test func recursiveDownloadCreatesFolderAndVerifiesPayload() async throws {
    let fixture = try Fixture()
    let transport = TestTransport(tree: [10: [folderEntry(id: 11, name: "Camera", parent: 10)], 11: [fileEntry(parent: 11)]])
    try await TransferEngine(transport: transport).download(folderEntry(), into: fixture.url, cancellation: TransferCancellation()) { _ in }
    let target = fixture.url.appendingPathComponent("Photos/Camera/hello.txt")
    #expect(try Data(contentsOf: target) == Data("hello".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["hello.txt"])
}

@Test func failedDownloadRemovesPartialFile() async throws {
    let fixture = try Fixture()
    let transport = TestTransport(downloadFailure: true)
    await #expect(throws: MTPError.message("USB disconnected")) {
        try await TransferEngine(transport: transport).download(fileEntry(), into: fixture.url, cancellation: TransferCancellation()) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path).isEmpty)
}

@Test func truncatedDownloadNeverBecomesFinalFile() async throws {
    let fixture = try Fixture()
    let transport = TestTransport(payload: Data("he".utf8))
    await #expect(throws: MTPError.self) {
        try await TransferEngine(transport: transport).download(fileEntry(), into: fixture.url, cancellation: TransferCancellation()) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path).isEmpty)
}

@Test func cancellationDuringDownloadRemovesCurrentPartialFile() async throws {
    let fixture = try Fixture()
    let transport = TestTransport()
    let cancellation = TransferCancellation()
    await #expect(throws: MTPError.cancelled) {
        try await TransferEngine(transport: transport).download(fileEntry(), into: fixture.url, cancellation: cancellation) { progress in
            if progress.completed > 0 { cancellation.cancel() }
        }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path).isEmpty)
}

@Test func downloadCollisionPreservesOriginalBytes() async throws {
    let fixture = try Fixture()
    let target = try fixture.file("hello.txt", contents: "keep me")
    let transport = TestTransport()
    await #expect(throws: MTPError.alreadyExists("hello.txt")) {
        try await TransferEngine(transport: transport).download(fileEntry(), into: fixture.url, cancellation: TransferCancellation()) { _ in }
    }
    #expect(try Data(contentsOf: target) == Data("keep me".utf8))
}

@Test func malformedRemoteTreeDoesNotCreateLocalFolders() async throws {
    let fixture = try Fixture()
    let transport = TestTransport(tree: [10: [fileEntry(name: "../../escaped.txt", parent: 10)]])
    await #expect(throws: MTPError.self) {
        try await TransferEngine(transport: transport).download(folderEntry(), into: fixture.url, cancellation: TransferCancellation()) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path).isEmpty)
}

@Test func cyclicDeviceTreeIsRejectedBeforeDeletion() async throws {
    let root = folderEntry()
    let transport = TestTransport(tree: [10: [root]])
    await #expect(throws: MTPError.self) { try await TransferEngine(transport: transport).delete([root]) }
    let (_, _, deleted) = await transport.mutations()
    #expect(deleted.isEmpty)
}

@Test func deletingFolderRemovesChildrenBeforeParents() async throws {
    let transport = TestTransport(tree: [10: [folderEntry(id: 11, name: "Camera", parent: 10)], 11: [fileEntry(parent: 11)]])
    try await TransferEngine(transport: transport).delete([folderEntry()])
    let (_, _, deleted) = await transport.mutations()
    #expect(deleted == [1, 11, 10])
}

@Test func duplicateRemoteNamesAreRejectedBeforeDownload() async throws {
    let fixture = try Fixture()
    let transport = TestTransport(tree: [10: [fileEntry(id: 1, name: "PHOTO.jpg", parent: 10), fileEntry(id: 2, name: "photo.jpg", parent: 10)]])
    await #expect(throws: MTPError.self) {
        try await TransferEngine(transport: transport).download(folderEntry(), into: fixture.url, cancellation: TransferCancellation()) { _ in }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.url.path).isEmpty)
}

@Test func readOnlyStorageRejectsUploads() async throws {
    let fixture = try Fixture()
    let source = try fixture.file("hello.txt")
    let storage = DeviceStorage(id: 1, name: "Read-only", capacity: 1_000_000, freeBytes: 900_000, writable: false)
    let transport = TestTransport()
    await #expect(throws: MTPError.self) {
        try await TransferEngine(transport: transport).upload(source, storage: storage, parent: 0, cancellation: TransferCancellation()) { _ in }
    }
    let (uploads, _, _) = await transport.mutations()
    #expect(uploads.isEmpty)
}
