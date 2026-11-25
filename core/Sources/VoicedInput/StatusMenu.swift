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
    /// Why the latest sentence could not be delivered; cleared by the next one that is.
    var deliveryError: String?
    let startedAt = Date()
}

/// The service's icon at the right of the menu bar, a black-and-white template image like the
/// system's own. Clicking it opens a card with the service's status.
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
        let card = NSHostingController(rootView: StatusCard(status: status))
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
    }
}

private struct StatusCard: View {
    @Bindable var status: ServiceStatus

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

            if let error = status.deliveryError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            if case .failed(let detail) = status.listener {
                Text(detail).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(width: 300)
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

    private func openAccessibilitySettings() {
        KeyboardTyper.requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
