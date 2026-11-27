import VoicedCore
import AppKit
import SwiftUI

/// "Send to Machine" at hand, opened from the button left of the record button, as the
/// iPhone's sheet is: what the machine does with what is sent (Type or Run and their setting),
/// which machine, and a refresh of the list under it.
struct SendToMachinePanel: View {
    @ObservedObject var controller: TranscriptionController

    private var strings: AppStrings { controller.strings }
    /// The height of the row under Type or Run: the switch's, the taller of the two.
    private static let optionRowHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings.sendToMachine)
                .font(.headline)

            section(strings.sendMethod) {
                VStack(alignment: .leading, spacing: 10) {
                    // Both halves equally wide, which SwiftUI's segmented picker does not do on macOS.
                    EqualSegments(labels: [strings.sendTypes, strings.sendRuns],
                                  selection: Binding(get: { controller.sendsToClaude ? 1 : 0 },
                                                     set: { controller.sendsToClaude = $0 == 1 }))
                        .frame(maxWidth: .infinity)
                    if controller.sendsToClaude {
                        HStack {
                            Text(strings.workingFolder)
                            TextField(AppSettings.defaultClaudeFolder, text: $controller.claudeFolder)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                        }
                        // Both rows one height, so switching between Type and Run does not
                        // resize the popover.
                        .frame(height: Self.optionRowHeight)
                    } else {
                        HStack {
                            Text(strings.pressReturnAfterTyping)
                            Spacer()
                            Toggle(strings.pressReturnAfterTyping, isOn: $controller.pressesReturn)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                        .frame(height: Self.optionRowHeight)
                    }
                }
            }

            section(strings.machines) {
                VStack(spacing: 0) {
                    ForEach(Array(controller.machineChoices.enumerated()), id: \.offset) { index, name in
                        if index > 0 { Divider() }
                        machineRow(name)
                    }
                }
            }

            Button {
                controller.macLink.refresh()
            } label: {
                Label(strings.refreshList, systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(card)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
        .padding(16)
        .frame(width: 300)
        .background(Theme.background)
        // The folder field takes the focus when the popover opens, and a focused field selects
        // all its text: the cursor goes to the end instead, once the field editor has the focus.
        .onAppear {
            // Again a moment later: the popover may become the key window only after appearing.
            DispatchQueue.main.async(execute: Self.deselectFocusedField)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: Self.deselectFocusedField)
        }
        .onChange(of: controller.sendsToClaude) { DispatchQueue.main.async(execute: Self.deselectFocusedField) }
    }

    private static func deselectFocusedField() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    /// A grey caption over a white card, like a grouped list's section.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(card)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white)
    }

    /// A machine, or Automatic, with its system and address in grey under it; a checkmark on the
    /// one chosen. Choosing one leaves the panel open, for the settings above.
    private func machineRow(_ name: String?) -> some View {
        Button {
            controller.sendToMacTarget = name
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.machineChoiceLabel(name))
                        .foregroundStyle(Theme.accent)
                    if let detail = controller.machineChoiceDetail(name) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if controller.sendToMacTarget == name {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A segmented control whose segments share its width equally.
private struct EqualSegments: NSViewRepresentable {
    let labels: [String]
    @Binding var selection: Int

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        for (index, label) in labels.enumerated() where control.label(forSegment: index) != label {
            control.setLabel(label, forSegment: index)
        }
        control.selectedSegment = selection
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject {
        var selection: Binding<Int>

        init(selection: Binding<Int>) { self.selection = selection }

        @objc func changed(_ control: NSSegmentedControl) {
            selection.wrappedValue = control.selectedSegment
        }
    }
}
