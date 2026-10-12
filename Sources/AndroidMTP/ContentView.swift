import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AndroidMTPCore

private let accent = Color(red: 0.13, green: 0.57, blue: 0.48)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    @State private var dropTargeted = false
    @State private var naming: NameAction?
    @State private var confirmDelete = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 238, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if model.isConnected { browser } else { connectionView }
                Divider()
                if model.showTransfers && !model.transfers.isEmpty { transferPanel; Divider() }
                statusBar
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("Android MTP")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.operation != nil { ProgressView().controlSize(.small) }
                    Button { Task { await model.scan() } } label: { Image(systemName: "arrow.clockwise") }
                        .help(model.isConnected ? "Refresh folder (⌘R)" : "Find devices (⌘R)").disabled(model.isBusy)
                    Button { model.showTransfers.toggle() } label: { Image(systemName: "arrow.up.arrow.down.circle") }
                        .help("Show transfers (⇧⌘T)").accessibilityLabel("Transfers")
                    if model.isConnected {
                        Button { Task { await model.disconnect() } } label: { Image(systemName: "eject") }
                            .help("Disconnect device (⌘E)").disabled(model.isBusy)
                    }
                }
            }
        }
        .tint(accent)
        .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        .sheet(item: $naming, onDismiss: { model.isPresentingDialog = false }) { action in
            NameSheet(title: action.entry == nil ? "New folder" : "Rename item",
                      initialName: action.entry?.name ?? "", submitLabel: action.entry == nil ? "Create" : "Rename") { name in
                model.isPresentingDialog = false
                Task {
                    if let entry = action.entry { await model.rename(entry, to: name) }
                    else { await model.createFolder(name) }
                }
            }
            .onAppear { model.isPresentingDialog = true }
        }
        .alert("Delete \(model.selection.count == 1 ? "this item" : "\(model.selection.count) items")?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) { model.isPresentingDialog = false }
            Button("Delete", role: .destructive) { model.isPresentingDialog = false; Task { await model.deleteSelection() } }
        } message: {
            Text("These items and any folder contents will be permanently deleted from your Android device. This cannot be undone.")
        }
        .alert("Device operation failed", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .newMTPFolder)) { _ in if model.canWrite { naming = NameAction(entry: nil) } }
        .onChange(of: model.search) { _, _ in model.selection = [] }
        .onChange(of: confirmDelete) { _, value in model.isPresentingDialog = value }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(accent.gradient).frame(width: 36, height: 36)
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Android MTP").font(.headline)
                    Text("A little closer to your Mac").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 18).padding(.top, 23).padding(.bottom, 24)

            List(selection: Binding<UInt32?>(get: { model.storageID }, set: { id in
                if let id { Task { await model.selectStorage(id) } }
            })) {
                Section("DEVICE") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: "smartphone").font(.system(size: 25, weight: .light)).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.isConnected ? model.deviceName : "No device connected").font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                HStack(spacing: 5) {
                                    Circle().fill(model.isConnected ? accent : Color.secondary).frame(width: 5, height: 5)
                                    Text(model.isConnected ? "Connected via USB" : "Ready when you are").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if model.isPreview {
                            Text("READ-ONLY PREVIEW").font(.system(size: 9, weight: .bold)).tracking(1.2)
                                .foregroundStyle(.orange).padding(.vertical, 5).padding(.horizontal, 7)
                                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .padding(.vertical, 8)
                }
                if !model.storages.isEmpty {
                    Section("STORAGE") {
                        ForEach(model.storages) { storage in
                            Label(storage.name, systemImage: storage.id == model.storages.first?.id ? "internaldrive" : "sdcard")
                                .font(.system(size: 12)).padding(.vertical, 3).tag(storage.id)
                        }
                    }
                }
                Section("ON YOUR MAC") {
                    Button {
                        if let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first { NSWorkspace.shared.open(url) }
                    } label: { Label("Downloads", systemImage: "arrow.down.circle").font(.system(size: 12)) }
                    .buttonStyle(.plain).padding(.vertical, 3)
                }
            }
            .listStyle(.sidebar)
            .disabled(model.isBusy)
            Spacer(minLength: 0)
            if let storage = model.storage {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("\(FileSafety.byteCount(storage.freeBytes)) available").font(.system(size: 11, weight: .medium))
                        Spacer()
                        if !storage.writable { Image(systemName: "lock").font(.caption) }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(accent).frame(width: max(0, geo.size.width * storage.usedFraction))
                        }
                    }.frame(height: 5)
                    Text("\(FileSafety.byteCount(storage.capacity - min(storage.capacity, storage.freeBytes))) of \(FileSafety.byteCount(storage.capacity)) used")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(18)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "cable.connector")
                    Text("USB transfers. Simply native.")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(18)
            }
        }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: pathSymbol).font(.system(size: 28, weight: .light)).foregroundStyle(accent)
                    .frame(width: 42, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.currentFolder).font(.system(size: 23, weight: .semibold))
                    Text("\(itemCount(model.entries.count)) · \(model.deviceName)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.chooseDownload() } label: { Label("Download", systemImage: "arrow.down") }
                    .disabled(model.selection.isEmpty || model.isBusy || model.isPreview)
                Button { model.chooseUpload() } label: { Label("Upload", systemImage: "arrow.up") }
                    .buttonStyle(.borderedProminent).disabled(!model.canWrite)
                Button { naming = NameAction(entry: nil) } label: { Image(systemName: "folder.badge.plus") }
                    .help("New folder (⇧⌘N)").disabled(!model.canWrite)
            }
            .controlSize(.regular).padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 22)

            HStack(spacing: 8) {
                Button { Task { await model.navigate(to: model.path.count > 1 ? model.path.count - 2 : nil) } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless).help("Enclosing folder (⌘[)")
                .keyboardShortcut("[", modifiers: .command).disabled(model.path.isEmpty || model.isBusy)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { Task { await model.navigate(to: nil) } } label: {
                            Label(model.storage?.name ?? "Storage", systemImage: "internaldrive")
                        }.buttonStyle(.plain)
                        ForEach(Array(model.path.enumerated()), id: \.element.id) { index, folder in
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .medium)).foregroundStyle(.tertiary)
                            Button(folder.name) { Task { await model.navigate(to: index) } }.buttonStyle(.plain)
                        }
                    }.font(.system(size: 11)).foregroundStyle(.secondary).disabled(model.isBusy)
                }
                Spacer(minLength: 8)
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search this folder", text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
                    }
                }.font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 7)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7)).frame(width: 195)
            }.padding(.horizontal, 24).padding(.bottom, 14)

            Divider()
            ZStack {
                fileTable
                if model.displayedEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: model.search.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.tertiary)
                        Text(model.operation != nil ? "Reading folder…" : model.search.isEmpty ? "A little room for something new" : "No matching files")
                            .font(.system(size: 16, weight: .medium))
                        Text(model.search.isEmpty ? "Drop files and folders here to upload them." : "Try another name or clear the search.")
                            .font(.callout).foregroundStyle(.secondary)
                        if model.search.isEmpty { Button("Choose files…") { model.chooseUpload() }.disabled(!model.canWrite) }
                    }.allowsHitTesting(true)
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.1))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
                        .overlay(Label("Upload to \(model.currentFolder)", systemImage: "arrow.up.doc").font(.title3.weight(.medium)).padding(16).background(.regularMaterial, in: Capsule()))
                        .padding(12).allowsHitTesting(false)
                }
            }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTargeted) { providers in
                guard model.canWrite, !providers.isEmpty else { return false }
                model.operation = "Reading dropped files…"
                let collector = DropCollector(count: providers.count) { urls in
                    model.operation = nil
                    if !urls.isEmpty { model.enqueueUploads(urls) }
                }
                for provider in providers {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        Task { @MainActor in collector.received(url) }
                    }
                }
                return true
            }
        }
    }

    private var pathSymbol: String { model.path.isEmpty ? "internaldrive" : "folder" }

    private var fileTable: some View {
        Table(model.displayedEntries, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.symbol).font(.system(size: 16))
                        .foregroundStyle(entry.isFolder ? accent.opacity(0.85) : .secondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    Text(entry.name).font(.system(size: 12)).lineLimit(1)
                }.padding(.vertical, 6)
            }.width(min: 230, ideal: 370)
            TableColumn("Size", value: \.size) { entry in
                Text(entry.isFolder ? "—" : FileSafety.byteCount(entry.size)).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }.width(min: 75, ideal: 95, max: 120)
            TableColumn("Kind") { entry in Text(entry.kind).font(.system(size: 11)).foregroundStyle(.secondary) }
                .width(min: 70, ideal: 90, max: 125)
            TableColumn("Modified") { entry in
                if let date = entry.modified { Text(date, format: .dateTime.month(.abbreviated).day().year()).font(.system(size: 11)).foregroundStyle(.secondary) }
                else { Text("—").foregroundStyle(.tertiary) }
            }.width(min: 90, ideal: 110, max: 145)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: UInt32.self) { ids in
            if !ids.isEmpty {
                let items = model.entries.filter { ids.contains($0.id) }
                if items.count == 1, let item = items.first, item.isFolder {
                    Button("Open Folder") { Task { await model.open(item) } }.disabled(model.isBusy)
                }
                Button("Download to Mac…") { model.selection = ids; model.chooseDownload() }.disabled(model.isBusy || model.isPreview)
                if items.count == 1, let item = items.first {
                    Button("Rename…") { naming = NameAction(entry: item) }.disabled(!model.canWrite)
                }
                Divider()
                Button("Delete…", role: .destructive) { model.selection = ids; confirmDelete = true }.disabled(!model.canWrite)
            } else {
                Button("New Folder…") { naming = NameAction(entry: nil) }.disabled(!model.canWrite)
                Button("Upload Files…") { model.chooseUpload() }.disabled(!model.canWrite)
            }
        } primaryAction: { ids in
            if ids.count == 1, let entry = model.entries.first(where: { ids.contains($0.id) }) {
                if entry.isFolder { Task { await model.open(entry) } }
                else { model.selection = ids; model.chooseDownload() }
            }
        }
        .disabled(model.isBusy)
    }

    private var connectionView: some View {
        ScrollView {
            VStack(spacing: 0) {
                ConnectionIllustration().frame(width: 270, height: 135).padding(.top, 68).padding(.bottom, 25)
                Text("Your Android. Right at home.").font(.system(size: 28, weight: .semibold))
                Text("A simple way to move files between your phone and Mac.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 10)
                HStack(alignment: .top, spacing: 26) {
                    ConnectionStep(number: "1", title: "Plug it in", detail: "Connect your phone with\na USB data cable.")
                    ConnectionStep(number: "2", title: "Unlock your phone", detail: "Keep your device unlocked\nwhile connecting.")
                    ConnectionStep(number: "3", title: "Choose File transfer", detail: "In your phone’s USB settings,\nselect File transfer / MTP.")
                }.padding(.top, 36).padding(.bottom, 30)
                if model.devices.count > 1 {
                    VStack(spacing: 8) {
                        Text("Choose a connected device").font(.callout).foregroundStyle(.secondary)
                        ForEach(model.devices) { device in
                            Button { Task { await model.connect(device) } } label: { Label(device.name, systemImage: "smartphone") }
                                .disabled(model.isBusy)
                        }
                    }
                } else {
                    Button { Task { await model.scan() } } label: {
                        HStack(spacing: 8) { Image(systemName: "cable.connector"); Text("Connect device") }.padding(.horizontal, 16).padding(.vertical, 5)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isBusy)
                }
                Text("Quit other Android file transfer apps before connecting.")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 16)
            }
            .frame(maxWidth: .infinity).padding(.bottom, 40)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transferPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Transfers", systemImage: "arrow.up.arrow.down").font(.system(size: 12, weight: .semibold))
                if model.hasActiveTransfers { Text("\(model.transfers.filter(\.isActive).count) active").font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                if model.hasActiveTransfers { Button("Cancel all") { model.cancelAll() }.font(.system(size: 11)) }
                Button("Clear finished") { model.clearFinished() }.font(.system(size: 11)).disabled(!model.transfers.contains { !$0.isActive })
                Button { model.showTransfers = false } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).help("Hide transfers")
            }.padding(.horizontal, 22).padding(.vertical, 12)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.displayedTransfers) { transfer in
                        TransferRow(record: transfer, cancel: { model.cancel(transfer.id) })
                    }
                }
            }.frame(maxHeight: 160)
        }.background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle().fill(model.isConnected ? accent : .secondary.opacity(0.5)).frame(width: 5, height: 5)
            Text(model.operation ?? (model.hasActiveTransfers ? "Transferring files…" : model.isConnected ? "Connected" : "No device connected"))
            if model.isPreview { Text("· Read-only preview").foregroundStyle(.orange) }
            Spacer()
            if !model.selection.isEmpty { Text("\(model.selection.count) selected"); Text("·").foregroundStyle(.tertiary) }
            if model.isConnected { Text(itemCount(model.displayedEntries.count)); Text("·").foregroundStyle(.tertiary); Text(model.isPreview ? "Browsing sample files" : model.storage?.writable == true ? "Drop files to upload" : "Read-only storage") }
            else { Text("Made for Apple Silicon") }
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 22).frame(height: 34)
    }

    private func itemCount(_ count: Int) -> String { "\(count) \(count == 1 ? "item" : "items")" }
}

private struct NameAction: Identifiable { let id = UUID(); let entry: RemoteEntry? }

private struct NameSheet: View {
    let title: String
    let initialName: String
    let submitLabel: String
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool
    private var validation: String? {
        do { try FileSafety.validateName(name); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: initialName.isEmpty ? "folder.badge.plus" : "pencil").font(.title3.weight(.semibold))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { if validation == nil { submit(name); dismiss() } }
            if !name.isEmpty, validation != nil { Text("Use a valid file name without slashes or colons.").font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(submitLabel) { submit(name); dismiss() }.keyboardShortcut(.defaultAction).disabled(validation != nil)
                    .buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 380).onAppear { name = initialName; focused = true }
    }
}

private struct TransferRow: View {
    let record: TransferRecord
    let cancel: () -> Void
    private var color: Color {
        switch record.state { case .complete: accent; case .failed: .red; case .cancelled: .secondary; default: accent }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.upload ? "arrow.up.doc" : "arrow.down.doc").font(.system(size: 20, weight: .light)).foregroundStyle(color)
                .frame(width: 28, height: 30)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(record.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("→ \(record.location)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(record.state.rawValue).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
                }
                if record.state == .running || record.state == .cancelling {
                    ProgressView(value: record.progress?.fraction ?? 0).tint(accent)
                    if let progress = record.progress {
                        HStack {
                            Text(progress.name).lineLimit(1)
                            Spacer()
                            Text("\(FileSafety.byteCount(progress.completed)) / \(FileSafety.byteCount(progress.total))")
                            if progress.filesTotal > 1 { Text("· \(progress.filesCompleted)/\(progress.filesTotal) files") }
                        }.font(.system(size: 9)).foregroundStyle(.secondary).monospacedDigit()
                    } else { Text("Preparing transfer…").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                if let error = record.error { Text(error).font(.system(size: 10)).foregroundStyle(record.state == .failed ? .red : .secondary).textSelection(.enabled) }
            }
            if record.isActive {
                Button(action: cancel) { Image(systemName: "xmark.circle").foregroundStyle(.secondary) }.buttonStyle(.plain).help("Cancel transfer").disabled(record.state == .cancelling)
            } else if record.state == .complete, let destination = record.destination {
                Button { NSWorkspace.shared.activateFileViewerSelecting([destination]) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).help("Show in Finder")
            } else { Image(systemName: record.state == .complete ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(color) }
        }.padding(.horizontal, 22).padding(.vertical, 10)
    }
}

private struct ConnectionStep: View {
    let number: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 9) {
            Text(number).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                .frame(width: 28, height: 28).background(accent.opacity(0.1), in: Circle())
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(3)
        }.frame(width: 155)
    }
}

private struct ConnectionIllustration: View {
    var body: some View {
        ZStack {
            Ellipse().fill(accent.opacity(0.06)).frame(width: 270, height: 120)
            HStack(spacing: 24) {
                VStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.55), lineWidth: 2)
                        .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(accent.opacity(0.7)))
                        .frame(width: 108, height: 74)
                    RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.45)).frame(width: 128, height: 5).padding(.top, 4)
                }
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 15, weight: .medium)).foregroundStyle(accent)
                RoundedRectangle(cornerRadius: 11).strokeBorder(.secondary.opacity(0.55), lineWidth: 2)
                    .background(accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(alignment: .top) { Capsule().fill(.secondary.opacity(0.5)).frame(width: 16, height: 3).padding(.top, 8) }
                    .overlay(Image(systemName: "photo.on.rectangle.angled").font(.system(size: 23)).foregroundStyle(accent.opacity(0.8)))
                    .frame(width: 53, height: 104)
            }
        }
    }
}

@MainActor
private final class DropCollector {
    private var remaining: Int
    private var urls: [URL] = []
    private let completion: ([URL]) -> Void
    init(count: Int, completion: @escaping ([URL]) -> Void) { remaining = count; self.completion = completion }
    func received(_ url: URL?) {
        if let url, url.isFileURL { urls.append(url) }
        remaining -= 1
        if remaining == 0 { completion(urls) }
    }
}
