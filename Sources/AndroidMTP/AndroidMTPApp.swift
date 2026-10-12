import SwiftUI
import AppKit

@main
struct AndroidMTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel(preview: CommandLine.arguments.contains("--demo"))

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .task { appDelegate.model = model; await model.start() }
        }
        .defaultSize(width: 1120, height: 760)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Folder…") { NotificationCenter.default.post(name: .newMTPFolder, object: nil) }
                    .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!model.canWrite)
            }
            CommandMenu("Device") {
                Button("Refresh") { Task { await model.scan() } }
                    .keyboardShortcut("r").disabled(model.isBusy)
                Button("Upload Files…") { model.chooseUpload() }
                    .keyboardShortcut("u").disabled(!model.canWrite)
                Button("Download Selected…") { model.chooseDownload() }
                    .keyboardShortcut("d").disabled(model.selection.isEmpty || !model.isConnected || model.isBusy || model.isPreview)
                Divider()
                Button("Disconnect") { Task { await model.disconnect() } }
                    .keyboardShortcut("e").disabled(!model.isConnected || model.isBusy)
            }
            CommandGroup(after: .sidebar) {
                Toggle("Show Transfers", isOn: $model.showTransfers).keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
        Settings { SettingsView() }
    }
}

extension Notification.Name {
    static let newMTPFolder = Notification.Name("newMTPFolder")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.hasActiveTransfers == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Transfers are still in progress"
        alert.informativeText = "Wait for transfers to finish or cancel them before quitting. Completed files will be kept."
        alert.addButton(withTitle: "Keep Transferring")
        alert.addButton(withTitle: "Cancel Transfers")
        if alert.runModal() == .alertSecondButtonReturn { model?.cancelAll() }
        return .terminateCancel
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = "system"
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }
    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Text("Transfers use USB. Unlock your Android device and select File transfer in its USB settings.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Existing files are never overwritten. Folder transfers include their contents. Symbolic links are not followed.")
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Version", value: "\(appVersion) · Apple Silicon")
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 280)
    }
}
