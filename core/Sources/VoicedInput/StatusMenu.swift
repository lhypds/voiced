import AppKit
import Observation
import SwiftUI

/// What the menu bar card shows about the running service.
@MainActor
@Observable
final class ServiceStatus {
    enum Listener: Equatable {
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    var listener: Listener = .starting
    var connections = 0
    var accessibilityAllowed = KeyboardTyper.isTrusted
    var sentencesTyped = 0
    var lastSentenceAt: Date?
    var workFolder = ServiceSettings.workFolder {
        didSet { if workFolder != oldValue { ServiceSettings.workFolder = workFolder } }
    }
    /// Why the latest sentence could not be delivered; cleared by the next one that is.
    var deliveryError: String?
    let startedAt = Date()
}

/// The service's icon at the right of the menu bar, a black-and-white template image like the
/// system's own. Clicking it opens a card with the service's status and a button to stop it.
@MainActor
final class StatusMenu: NSObject {
    private let status: ServiceStatus
    private let item: NSStatusItem
    private let popover = NSPopover()
    private var refreshTimer: Timer?

    init(status: ServiceStatus) {
        self.status = status
        self.item = Self.makeItem()
        super.init()

        if let button = item.button {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "voiced")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(toggle(_:))
        }

        popover.behavior = .transient
        popover.animates = true
        let card = NSHostingController(rootView: StatusCard(
            status: status,
            voicedApp: Self.voicedAppURL,
            onStop: { ServiceControl.stop() }
        ))
        // Keep the popover sized to the card. Without a size up front the popover is placed for
        // a larger default and then shrinks toward its bottom edge, leaving it well below the icon.
        card.sizingOptions = .preferredContentSize
        popover.contentViewController = card
    }

    private static let autosaveName = "VoicedInput"

    /// Creates the item at a position where it can be seen. Without a remembered position macOS
    /// puts a new item at the far left of the status area, which on a full menu bar is behind the
    /// notch, and with Hidden Bar or a similar app behind its divider. The position is the
    /// distance from the right edge of the screen; once the user ⌘-drags the item elsewhere,
    /// macOS stores that under the same key and it is kept.
    private static func makeItem() -> NSStatusItem {
        let key = "NSStatusItem Preferred Position \(autosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(defaultPosition, forKey: key)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = autosaveName
        return item
    }

    /// Among the system items at the right, which menu bar managers such as Hidden Bar leave
    /// visible and a full menu bar does not push behind the notch.
    private static let defaultPosition: Double = 200

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        refresh()
        if let view = popover.contentViewController?.view {
            view.layoutSubtreeIfNeeded()
            popover.contentSize = view.fittingSize
        }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // The permission can be granted while the card is open; keep the row current.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.popover.isShown {
                    self.refresh()
                } else {
                    self.refreshTimer?.invalidate()
                    self.refreshTimer = nil
                }
            }
        }
    }

    private func refresh() {
        status.accessibilityAllowed = KeyboardTyper.isTrusted
        // `voiced <folder>` changes the folder from outside.
        status.workFolder = ServiceSettings.workFolder
    }

    /// The Voiced app built from the same checkout: this binary is core/.build/voiced and the app is
    /// macos/.build/Voiced.app at the repository root.
    private static var voicedAppURL: URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let root = executable
            .deletingLastPathComponent() // core/.build
            .deletingLastPathComponent() // core
            .deletingLastPathComponent() // repository root
        let app = root.appending(path: "macos/.build/Voiced.app")
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }
}

/// The service's own preferences, in its defaults domain (com.local.voiced.input). They are not
/// in ~/.voiced/settings.json: the Voiced app keeps a copy of that file and writes all of it back
/// on every change, which would undo a change made here.
enum ServiceSettings {
    private static let workFolderKey = "workFolder"

    /// The folder Claude Code starts in. `voiced` sets it to the home folder, and
    /// `voiced <folder>` (such as `voiced .`) to that folder.
    static var workFolder: String {
        get {
            if let folder = UserDefaults.standard.string(forKey: workFolderKey), !folder.isEmpty { return folder }
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        set { UserDefaults.standard.set(newValue, forKey: workFolderKey) }
    }
}

/// Stops the service the way `voiced stop` does.
enum ServiceControl {
    static let label = "com.local.voiced.input"

    @MainActor
    static func stop() {
        log("Stopping from the menu bar")
        // Without the plist the service does not come back at the next login.
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
        try? FileManager.default.removeItem(at: plist)

        // Unloading the job is what keeps launchd from restarting the service; launchd then
        // terminates this process. Started by hand, there is no job and the process just exits.
        let launchctl = Process()
        launchctl.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        launchctl.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        try? launchctl.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }
}

private struct StatusCard: View {
    @Bindable var status: ServiceStatus
    let voicedApp: URL?
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("voiced").font(.headline)
                    HStack(spacing: 5) {
                        Circle().fill(stateColor).frame(width: 7, height: 7)
                        Text(stateText).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                row("Advertised as", Host.current().localizedName ?? "This Mac")
                row("iPhones connected", "\(status.connections)")
                row("Sentences typed", sentencesText)
                row("Running since", status.startedAt.formatted(date: .omitted, time: .shortened))
                HStack {
                    Text("Accessibility").foregroundStyle(.secondary)
                    Spacer()
                    if status.accessibilityAllowed {
                        Text("Allowed")
                    } else {
                        Button("Allow…") { openAccessibilitySettings() }
                            .buttonStyle(.link)
                    }
                }
            }
            .font(.callout)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Claude Code folder").font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(abbreviated(status.workFolder))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Change…") { chooseFolder() }.buttonStyle(.link)
                }
                Text("The iPhone chooses what happens to each sentence: typed at the cursor, typed and followed by Return, or run by Claude Code, which opens in Terminal in this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = status.deliveryError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let detail) = status.listener {
                Text(detail).font(.caption).foregroundStyle(.red)
            }

            Divider()

            HStack {
                if let voicedApp {
                    Button("Open Voiced") {
                        NSWorkspace.shared.openApplication(at: voicedApp, configuration: .init())
                    }
                }
                Spacer()
                Button("Stop Service", role: .destructive, action: onStop)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: status.workFolder)
        panel.prompt = "Choose"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            status.workFolder = url.path
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }

    private var stateText: String {
        switch status.listener {
        case .starting: "Starting…"
        case .listening(let port): "Running · port \(port)"
        case .failed: "Failed"
        }
    }

    private var stateColor: Color {
        switch status.listener {
        case .starting: .yellow
        case .listening: .green
        case .failed: .red
        }
    }

    private var sentencesText: String {
        guard let last = status.lastSentenceAt else { return "\(status.sentencesTyped)" }
        return "\(status.sentencesTyped) · last \(last.formatted(date: .omitted, time: .shortened))"
    }

    private func openAccessibilitySettings() {
        KeyboardTyper.requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
