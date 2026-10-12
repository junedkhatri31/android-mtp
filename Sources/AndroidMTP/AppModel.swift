import SwiftUI
import AppKit
import AndroidMTPCore
import UniformTypeIdentifiers

struct FolderLocation: Identifiable {
    let id: UInt32
    let name: String
}

struct TransferRecord: Identifiable {
    enum State: String { case queued = "Queued", running = "Transferring", cancelling = "Cancelling…", complete = "Complete", failed = "Failed", cancelled = "Cancelled" }
    let id: UUID
    let name: String
    let upload: Bool
    let location: String
    var state: State = .queued
    var progress: TransferProgress?
    var error: String?
    var started: Date?
    var destination: URL?
    var isActive: Bool { state == .queued || state == .running || state == .cancelling }
}

private struct TransferJob {
    let id: UUID
    let source: URL?
    let entry: RemoteEntry?
    let directory: URL?
    let storage: DeviceStorage
    let parent: UInt32
    let cancellation: TransferCancellation
}

@MainActor
final class AppModel: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    @Published var connectedDevice: DeviceInfo?
    @Published var deviceName = "Android device"
    @Published var storages: [DeviceStorage] = []
    @Published var storageID: UInt32?
    @Published var path: [FolderLocation] = []
    @Published var entries: [RemoteEntry] = []
    @Published var selection = Set<UInt32>()
    @Published var search = ""
    @Published var operation: String?
    @Published var isPresentingDialog = false
    @Published var errorMessage: String?
    @Published var transfers: [TransferRecord] = []
    @Published var showTransfers = true
    @Published var sortOrder = [KeyPathComparator(\RemoteEntry.name, comparator: .localizedStandard)]
    let isPreview: Bool
    let transport: any MTPTransport
    private var started = false
    private var jobs: [TransferJob] = []
    private var queueTask: Task<Void, Never>?

    init(preview: Bool = false) {
        isPreview = preview
        transport = preview ? PreviewMTP() : NativeMTP()
    }

    var isConnected: Bool { connectedDevice != nil }
    var hasActiveTransfers: Bool { transfers.contains(where: \.isActive) }
    var isBusy: Bool { operation != nil || hasActiveTransfers || isPresentingDialog }
    var storage: DeviceStorage? { storages.first { $0.id == storageID } }
    var parentID: UInt32 { path.last?.id ?? 0 }
    var currentFolder: String { path.last?.name ?? storage?.name ?? "Device storage" }
    var canWrite: Bool { isConnected && storage?.writable == true && !isBusy && !isPreview }
    var selectedEntries: [RemoteEntry] { entries.filter { selection.contains($0.id) } }
    var displayedTransfers: [TransferRecord] {
        transfers.enumerated().sorted { left, right in
            func rank(_ record: TransferRecord) -> Int {
                switch record.state { case .running, .cancelling: 0; case .queued: 1; default: 2 }
            }
            let a = rank(left.element), b = rank(right.element)
            if a != b { return a < b }
            return a == 2 ? left.offset > right.offset : left.offset < right.offset
        }.map(\.element)
    }
    var displayedEntries: [RemoteEntry] {
        let filtered = search.isEmpty ? entries : entries.filter { $0.name.localizedStandardContains(search) }
        return filtered.sorted(using: sortOrder).sorted { $0.isFolder && !$1.isFolder }
    }

    func start() async {
        guard !started else { return }
        started = true
        await scan()
    }

    func scan() async {
        guard !isBusy else { return }
        if isConnected { await refresh(); return }
        operation = "Looking for devices…"
        defer { operation = nil }
        do {
            devices = try await transport.detect()
            if devices.count == 1 { try await establish(devices[0]) }
        } catch { errorMessage = error.localizedDescription }
    }

    func connect(_ device: DeviceInfo) async {
        guard !isBusy else { return }
        operation = "Connecting to \(device.name)…"
        defer { operation = nil }
        do { try await establish(device) } catch { errorMessage = error.localizedDescription }
    }

    private func establish(_ device: DeviceInfo) async throws {
        do {
            deviceName = try await transport.connect(device)
            let available = try await transport.storages()
            guard !available.isEmpty else {
                throw MTPError.message("The device has no accessible storage. Unlock it, enable USB File transfer, then reconnect.")
            }
            storages = available
            storageID = available[0].id
            connectedDevice = device
            path = []
            try await load()
        } catch {
            await transport.disconnect()
            clearConnection()
            throw error
        }
    }

    func disconnect() async {
        guard !isBusy else { return }
        operation = "Disconnecting…"
        await transport.disconnect()
        clearConnection()
        operation = nil
    }

    private func clearConnection() {
        connectedDevice = nil; storages = []; storageID = nil
        path = []; entries = []; selection = []; search = ""
    }

    func refresh() async {
        guard !isBusy, isConnected else { return }
        operation = "Refreshing…"
        defer { operation = nil }
        do {
            storages = try await transport.storages()
            guard storages.contains(where: { $0.id == storageID }) else {
                storageID = storages.first?.id
                path = []
                if storageID == nil { throw MTPError.message("No storage is available. Unlock your phone or reconnect it.") }
                try await load()
                return
            }
            try await load()
        } catch {
            entries = []; selection = []
            errorMessage = "\(error.localizedDescription)\n\nIf the phone was unplugged, disconnect this session and reconnect it."
        }
    }

    private func load() async throws {
        guard let storageID else { return }
        entries = try await transport.list(storage: storageID, parent: parentID)
        selection.formIntersection(Set(entries.map(\.id)))
    }

    func selectStorage(_ id: UInt32) async {
        guard !isBusy, storageID != id else { return }
        storageID = id; path = []; selection = []; search = ""
        await loadLocation()
    }

    func open(_ entry: RemoteEntry) async {
        guard entry.isFolder, !isBusy else { return }
        path.append(FolderLocation(id: entry.id, name: entry.name))
        selection = []; search = ""
        await loadLocation()
    }

    func navigate(to index: Int?) async {
        guard !isBusy else { return }
        path = index.map { Array(path.prefix($0 + 1)) } ?? []
        selection = []; search = ""
        await loadLocation()
    }

    private func loadLocation() async {
        operation = "Reading folder…"
        entries = []
        defer { operation = nil }
        do { try await load() } catch { errorMessage = error.localizedDescription }
    }

    func createFolder(_ name: String) async {
        guard canWrite, let storageID else { return }
        operation = "Creating folder…"
        defer { operation = nil }
        do {
            try FileSafety.checkUnique(name, among: entries)
            _ = try await transport.createFolder(name: name, storage: storageID, parent: parentID)
            try await load()
        } catch { errorMessage = error.localizedDescription }
    }

    func rename(_ entry: RemoteEntry, to name: String) async {
        guard canWrite else { return }
        operation = "Renaming…"
        defer { operation = nil }
        do {
            try FileSafety.checkUnique(name, among: entries, excluding: entry.id)
            if name != entry.name { try await transport.rename(entry, to: name) }
            try await load()
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteSelection() async {
        guard canWrite, !selectedEntries.isEmpty else { return }
        let selected = selectedEntries
        operation = "Deleting items…"
        defer { operation = nil }
        do {
            try await TransferEngine(transport: transport).delete(selected)
            selection = []
            try await load()
        } catch {
            errorMessage = "\(error.localizedDescription)\n\nSome items may already have been deleted."
            try? await load()
        }
    }

    func chooseUpload() {
        guard canWrite else { return }
        let panel = NSOpenPanel()
        panel.title = "Upload to \(currentFolder)"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        operation = "Choosing files…"
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.operation = nil
                if response == .OK { self.enqueueUploads(panel.urls) }
            }
        }
    }

    func chooseDownload() {
        guard isConnected, !isBusy, !isPreview, !selectedEntries.isEmpty else { return }
        let selected = selectedEntries
        let panel = NSOpenPanel()
        panel.title = "Choose a download destination"
        panel.prompt = "Download here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        operation = "Choosing destination…"
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.operation = nil
                if response == .OK, let directory = panel.url { self.enqueueDownloads(selected, into: directory) }
            }
        }
    }

    func enqueueUploads(_ urls: [URL]) {
        guard canWrite, let storage else { return }
        for url in urls {
            let id = UUID()
            transfers.append(TransferRecord(id: id, name: url.lastPathComponent, upload: true, location: currentFolder))
            jobs.append(TransferJob(id: id, source: url, entry: nil, directory: nil, storage: storage,
                                    parent: parentID, cancellation: TransferCancellation()))
        }
        beginQueue()
    }

    private func enqueueDownloads(_ entries: [RemoteEntry], into directory: URL) {
        guard isConnected, !isBusy, !isPreview, let storage else { return }
        for entry in entries {
            let id = UUID()
            let destination = directory.appendingPathComponent(entry.name)
            transfers.append(TransferRecord(id: id, name: entry.name, upload: false, location: directory.lastPathComponent, destination: destination))
            jobs.append(TransferJob(id: id, source: nil, entry: entry, directory: directory, storage: storage,
                                    parent: parentID, cancellation: TransferCancellation()))
        }
        beginQueue()
    }

    private func beginQueue() {
        showTransfers = true
        guard queueTask == nil else { return }
        queueTask = Task { await runQueue() }
    }

    private func runQueue() async {
        let engine = TransferEngine(transport: transport)
        for job in jobs {
            guard !job.cancellation.isCancelled else { continue }
            update(job.id) { $0.state = .running; $0.started = Date() }
            let report: ProgressHandler = { [weak self] progress in
                Task { @MainActor in
                    self?.update(job.id) { record in
                        if record.state == .running { record.progress = progress }
                    }
                }
            }
            do {
                if let source = job.source {
                    try await engine.upload(source, storage: job.storage, parent: job.parent,
                                            cancellation: job.cancellation, progress: report)
                } else if let entry = job.entry, let directory = job.directory {
                    try await engine.download(entry, into: directory, cancellation: job.cancellation, progress: report)
                }
                update(job.id) { $0.state = .complete }
            } catch {
                update(job.id) {
                    $0.state = job.cancellation.isCancelled ? .cancelled : .failed
                    $0.error = error.localizedDescription
                }
            }
        }
        jobs = []
        queueTask = nil
        await refresh()
    }

    private func update(_ id: UUID, _ action: (inout TransferRecord) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        action(&transfers[index])
    }

    func cancel(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        job.cancellation.cancel()
        update(id) {
            if $0.state == .queued { $0.state = .cancelled }
            else if $0.state == .running { $0.state = .cancelling }
        }
    }

    func cancelAll() { for job in jobs { cancel(job.id) } }
    func clearFinished() { transfers.removeAll { !$0.isActive } }
}
