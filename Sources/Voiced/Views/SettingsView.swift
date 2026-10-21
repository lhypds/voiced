import AppKit
import SwiftUI
import WhisperKit

/// The settings sheet: input device, recognition engine and language, timestamps, UI language.
struct SettingsView: View {
    @ObservedObject var controller: TranscriptionController
    @Binding var isPresented: Bool
    @State private var isEngineHelpPresented = false

    private var strings: AppStrings { controller.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            titleBar

            VStack(spacing: 0) {
                SettingsRow(title: strings.interfaceLanguage, hint: strings.interfaceLanguageHint) {
                    Picker(strings.interfaceLanguage, selection: $controller.appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140, alignment: .trailing)
                }

                Divider()

                SettingsRow(title: strings.keepWindowOnTop, hint: strings.keepWindowOnTopHint) {
                    Toggle(strings.keepWindowOnTop, isOn: $controller.keepWindowOnTop)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                Divider()

                SettingsRow(title: strings.timestamp) {
                    HStack(spacing: 12) {
                        RadioChoice(strings.relativeTime, selected: controller.timestampMode == .relative) {
                            controller.timestampMode = .relative
                        }
                        RadioChoice(strings.currentTime, selected: controller.timestampMode == .current) {
                            controller.timestampMode = .current
                        }
                    }
                }

                Divider()

                SettingsRow(title: strings.showDate) {
                    Toggle(strings.showDate, isOn: $controller.showTimestampDate)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(controller.timestampMode == .relative)
                }

                Divider()

                SettingsRow(title: strings.input, hint: strings.inputHint) {
                    InputDevicePopUp(
                        devices: controller.audioDevices,
                        selection: $controller.selectedDeviceID,
                        refresh: {
                            // A device plugged in after the sheet opened is listed without reopening it.
                            controller.refreshAudioDevices()
                            return controller.audioDevices
                        }
                    )
                    .frame(maxWidth: 150, alignment: .trailing)
                    .disabled(controller.isRecording || controller.preview.isActive)
                }
                InputLevelBar(
                    monitor: controller.inputLevelMonitor,
                    source: .input,
                    threshold: controller.speechEnergyFloor,
                    help: strings.inputLevel
                )
                .padding(.bottom, 14)

                Divider()

                SettingsRow(title: strings.energyThreshold, hint: strings.energyThresholdHint, accessory: resetThresholdButton) {
                    VStack(alignment: .trailing, spacing: 6) {
                        HStack(spacing: 8) {
                            Slider(
                                value: $controller.speechEnergyFloor,
                                in: LiveTranscriber.speechEnergyFloorRange
                            )
                            .frame(width: 110)
                            Text(String(format: "%.3f", controller.speechEnergyFloor))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 38, alignment: .trailing)
                        }
                        calibrateNoiseButton
                    }
                }
                if let error = controller.noiseCalibrationError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.bottom, 10)
                }

                Divider()

                SettingsRow(
                    title: strings.noiseReduction,
                    hint: controller.noiseProfile == nil ? strings.noiseReductionNeedsProfile : strings.noiseReductionHint
                ) {
                    Toggle(strings.noiseReduction, isOn: $controller.noiseReductionEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(controller.noiseProfile == nil || controller.isRecording || controller.preview.isActive)
                }
                // What the input looks like after subtracting the measured noise, whether or not
                // noise reduction is on, so the user can see what turning it on would do.
                if controller.noiseProfile != nil {
                    InputLevelBar(
                        monitor: controller.inputLevelMonitor,
                        source: .denoised,
                        threshold: controller.speechEnergyFloor,
                        help: strings.denoisedLevel
                    )
                    .padding(.bottom, 14)
                }

                Divider()

                SettingsRow(
                    title: strings.voiceFilter,
                    hint: controller.isDownloadingVoiceFilter ? strings.voiceFilterDownloading : strings.voiceFilterHint
                ) {
                    Toggle(strings.voiceFilter, isOn: $controller.voiceFilterEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(controller.isRecording || controller.preview.isActive)
                }
                if let error = controller.voiceFilterError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.bottom, 10)
                }

                Divider()

                SettingsRow(title: strings.recognitionEngine, accessory: engineHelpButton) {
                    VStack(alignment: .trailing, spacing: 6) {
                        // A pop-up button sizes itself to its widest item, which left a blank
                        // stretch beside the shorter model names; a menu sizes to the chosen one.
                        Menu {
                            ForEach(RecognitionEngine.allCases) { engine in
                                Button {
                                    controller.selectEngine(engine)
                                } label: {
                                    if engine == controller.selectedEngine {
                                        Label(engine.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(engine.displayName)
                                    }
                                }
                            }
                        } label: {
                            Text(controller.selectedEngine.displayName)
                        }
                        .fixedSize()
                        .disabled(controller.isRecording || controller.isPreparing || controller.preview.isActive)
                        if controller.isPreparing {
                            enginePreparationProgress
                        }
                    }
                }

                Divider()

                // Under the model row: a specialized model offers only the language it was
                // fine-tuned for, so the choices depend on the model picked above.
                SettingsRow(title: strings.recognitionLanguage, hint: strings.recognitionLanguageHint) {
                    Picker(strings.recognitionLanguage, selection: $controller.selectedLanguage) {
                        ForEach(RecognitionLanguage.choices(for: controller.selectedEngine)) { language in
                            Text(language.isAutomatic ? strings.automaticDetection : language.nativeName)
                                .tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140, alignment: .trailing)
                    .disabled(
                        controller.isRecording || controller.preview.isActive
                            || RecognitionLanguage.choices(for: controller.selectedEngine).count < 2
                    )
                }

                Divider()

                SettingsRow(title: strings.recognitionPrompt, hint: strings.recognitionPromptHint) {
                    Button {
                        controller.openPromptFile()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.pencil")
                            Text(strings.editPromptFile)
                        }
                    }
                    .help(strings.editPromptFileHint)
                }

                Divider()

                RecognitionPreviewSection(controller: controller, preview: controller.preview)

            }
        }
        .padding(Theme.contentPadding)
        .frame(width: 460)
        .background(Theme.background)
        // Toggles, sliders, pickers and radio choices pick up the app's orange.
        .tint(Theme.accent)
        // The level bars listen to the selected device for as long as the sheet is open.
        .onAppear {
            controller.inputLevelMonitor.setNoiseProfile(controller.noiseProfile)
            controller.inputLevelMonitor.listen(to: controller.selectedDeviceID)
        }
        .onChange(of: controller.selectedDeviceID) { _, deviceID in
            controller.inputLevelMonitor.listen(to: deviceID)
        }
        .onChange(of: controller.noiseProfile) { _, profile in
            controller.inputLevelMonitor.setNoiseProfile(profile)
        }
        .onDisappear {
            controller.stopPreview()
            controller.inputLevelMonitor.stop()
        }
    }

    private var titleBar: some View {
        HStack {
            Text(strings.settings)
                .font(.custom("GillSans-Bold", size: 24))
                .foregroundStyle(Theme.accent)
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help(strings.close)
        }
    }

    /// Download or load progress of the engine just selected, under its picker: the bar on one
    /// line and the phase text on the next, so the row's title keeps its width.
    private var enginePreparationProgress: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Group {
                if case .downloading(let fraction) = controller.phase {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
            }
            .progressViewStyle(.linear)
            .frame(width: 160)
            Text(controller.phaseLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var resetThresholdButton: some View {
        if controller.speechEnergyFloor != LiveTranscriber.defaultSpeechEnergyFloor {
            Button(strings.resetToDefault) {
                controller.speechEnergyFloor = LiveTranscriber.defaultSpeechEnergyFloor
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Theme.accent)
        }
    }

    /// Sets the threshold from a short recording of the room. Shows a reminder to keep quiet
    /// while the measurement runs.
    private var calibrateNoiseButton: some View {
        Button {
            controller.calibrateNoise()
        } label: {
            HStack(spacing: 4) {
                if controller.isCalibratingNoise {
                    ProgressView()
                        .controlSize(.mini)
                    Text(strings.calibratingNoise)
                } else {
                    Image(systemName: "waveform.badge.minus")
                    Text(strings.calibrateNoise)
                }
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(controller.canCalibrateNoise ? Theme.accent : Color.secondary)
        .disabled(!controller.canCalibrateNoise)
        .help(strings.calibrateNoiseHint)
    }

    private var engineHelpButton: some View {
        Button {
            isEngineHelpPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .help(strings.engineHelp)
        .popover(isPresented: $isEngineHelpPresented, arrowEdge: .bottom) {
            EngineHelpPopover(strings: strings)
        }
    }
}

// MARK: - Recognition preview

/// Start/stop control plus, while running, the text the recognizer produces with the current
/// settings. The input level is on the meter under the input picker above.
private struct RecognitionPreviewSection: View {
    @ObservedObject var controller: TranscriptionController
    @ObservedObject var preview: RecognitionPreview

    private var strings: AppStrings { controller.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: strings.recognitionPreview, hint: strings.recognitionPreviewHint) {
                Button(preview.isActive ? strings.stopPreview : strings.startPreview) {
                    preview.isActive ? controller.stopPreview() : controller.startPreview()
                }
                .disabled(!preview.isActive && !controller.canPreview)
            }
            // The row ends with 14 points of padding; the box reaches up into it so only a
            // small gap separates it from the label.
            Group {
                if preview.isActive {
                    previewText
                } else if let error = preview.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, -4)
        }
        .padding(.bottom, preview.isActive || preview.errorMessage != nil ? 14 : 0)
    }

    /// Height of the text box: room for one sentence wrapped onto three lines of callout text plus
    /// the padding. The box never changes size while the preview runs. A sheet only grows reliably
    /// when its content changes in one step, not on the stream of live updates, so a box that grew
    /// with its text got squeezed and SwiftUI truncated it with an ellipsis.
    private static let textBoxHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let line = ceil(font.ascender - font.descender + font.leading)
        return line * 3 + 20
    }()

    /// One sentence only, always in the live style: the text being recognized, or the last finished
    /// sentence while nothing is in flight. The preview exists to check that speech is picked up,
    /// so it never distinguishes final text from in-flight text.
    private var previewText: some View {
        ScrollView(.vertical) {
            Group {
                if !preview.liveText.isEmpty {
                    Text(preview.liveText)
                        .foregroundStyle(.secondary)
                } else {
                    Text(strings.previewListening)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.callout)
            .padding(10)
            // Fills the box so short text sits at the top; the bottom anchor only matters once
            // the text overflows, when it keeps the newest words in view.
            .frame(maxWidth: .infinity, minHeight: Self.textBoxHeight, alignment: .topLeading)
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: Self.textBoxHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accent.opacity(Theme.rowFillOpacity))
        )
    }
}

// MARK: - Input level

/// The selected device's level against the energy floor, so the user can see both that the
/// device picks something up and whether it is loud enough to be decoded: the raw input under the
/// input picker, and the input after noise reduction under the noise reduction toggle.
private struct InputLevelBar: View {
    enum Source {
        case input
        case denoised
    }

    @ObservedObject var monitor: InputLevelMonitor
    let source: Source
    let threshold: Float
    let help: String

    private var level: Float {
        switch source {
        case .input: monitor.level
        case .denoised: monitor.denoisedLevel
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            // Sized by the glyph's own bounds rather than a text line, which has room under the
            // baseline and would leave the symbol sitting above the bar's centre line.
            Image(systemName: "mic.fill")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: Self.symbolHeight)
                .foregroundStyle(.secondary)
                // Nudged to where the symbol looks centred on the bar, which its bounds do not give.
                .alignmentGuide(VerticalAlignment.center) { $0[VerticalAlignment.center] - Self.symbolShift }
            LevelMeter(level: level, threshold: threshold)
                .frame(height: Self.barHeight)
        }
        // The row's height is pinned. Left to the symbol next to a flexible meter, it changes
        // between layout passes while the settings window is sized to its content, and AppKit
        // aborts the app once the window has asked for too many layout passes in a row.
        .frame(height: Self.height)
        .help(help)
    }

    /// Room for the symbol; the bar and its marker are far shorter.
    private static let height: CGFloat = 14
    /// About the size of a caption-font symbol.
    private static let symbolHeight: CGFloat = 11
    private static let barHeight: CGFloat = 6
    /// Vertical nudge of the symbol from bounds-centred; positive moves it down.
    private static let symbolShift: CGFloat = 0
}

/// The input picker as an `NSPopUpButton`, which SwiftUI's picker wraps anyway, so the device
/// list can be refreshed the moment the menu is about to open.
private struct InputDevicePopUp: NSViewRepresentable {
    let devices: [AudioDevice]
    @Binding var selection: DeviceID?
    /// Called as the menu is about to open; returns the devices to list.
    let refresh: () -> [AudioDevice]

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.didSelect(_:))
        // Long device names are cut rather than widening the row past its 150 pt limit.
        button.lineBreakMode = .byTruncatingTail
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.observeMenuOpening(of: button)
        Coordinator.populate(button, devices: devices, selection: selection)
        return button
    }

    /// Touches the button only where something changed. Every change to its items, title or
    /// state invalidates its intrinsic size, which asks the window for another constraints pass;
    /// the pass resizes the hosting view, SwiftUI updates this view again, and an unconditional
    /// update here would keep the window in that loop until AppKit aborts it.
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        Coordinator.populate(button, devices: devices, selection: selection)
        if button.isEnabled != context.environment.isEnabled {
            button.isEnabled = context.environment.isEnabled
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: InputDevicePopUp
        private var observation: (any NSObjectProtocol)?

        init(parent: InputDevicePopUp) {
            self.parent = parent
        }

        deinit {
            if let observation {
                NotificationCenter.default.removeObserver(observation)
            }
        }

        func observeMenuOpening(of button: NSPopUpButton) {
            observation = NotificationCenter.default.addObserver(
                forName: NSPopUpButton.willPopUpNotification, object: button, queue: .main
            ) { [weak self, weak button] _ in
                guard let self, let button else { return }
                // The binding reads the live selection, which the refresh may have moved.
                let devices = parent.refresh()
                Self.populate(button, devices: devices, selection: parent.selection)
            }
        }

        /// Brings the items and the selection in line with `devices` and `selection`, changing
        /// nothing that already matches: see `updateNSView`, and the menu may be open.
        static func populate(_ button: NSPopUpButton, devices: [AudioDevice], selection: DeviceID?) {
            let listed = button.itemArray.map { AudioDevice(id: $0.representedObject as? DeviceID ?? 0, name: $0.title) }
            if listed != devices {
                button.removeAllItems()
                for device in devices {
                    button.addItem(withTitle: device.name)
                    button.lastItem?.representedObject = device.id
                }
            }
            let index = devices.firstIndex(where: { $0.id == selection }) ?? -1
            if button.indexOfSelectedItem != index {
                button.selectItem(at: index)
            }
        }

        @objc func didSelect(_ button: NSPopUpButton) {
            guard let id = button.selectedItem?.representedObject as? DeviceID else { return }
            parent.selection = id
        }
    }
}

/// Input RMS on a log scale. With a threshold, a marker sits at the energy floor and the bar fills
/// in the accent colour only once the level clears it, so the user can see when audio would be
/// decoded; without one, the bar is always in the accent colour.
private struct LevelMeter: View {
    let level: Float
    var threshold: Float?

    private static let floor: Float = 0.001
    private static let ceiling: Float = 0.5

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let levelX = width * CGFloat(Self.position(of: level))
            let clearsThreshold = threshold.map { level >= $0 } ?? true
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.accent.opacity(Theme.rowFillOpacity))
                Capsule()
                    .fill(clearsThreshold ? Theme.accent : Color.secondary.opacity(0.5))
                    .frame(width: max(0, levelX))
                    .animation(.linear(duration: 0.1), value: level)
            }
            // The marker pokes past the bar on each side so it reads as a line across it rather
            // than a notch in it. As an overlay it leaves the bar's layout size alone; as a stack
            // child it would stretch the stack to its own height and push the bar off centre.
            .overlay(alignment: .leading) {
                if let threshold {
                    Rectangle()
                        .fill(Theme.accentDark)
                        .frame(width: 2, height: geometry.size.height + 4)
                        .offset(x: width * CGFloat(Self.position(of: threshold)) - 1)
                }
            }
        }
    }

    private static func position(of value: Float) -> Float {
        let clamped = min(max(value, floor), ceiling)
        return (log10(clamped) - log10(floor)) / (log10(ceiling) - log10(floor))
    }
}

// MARK: - Components

/// A label on the left, an optional hint below it, and a control on the right.
private struct SettingsRow<Accessory: View, Control: View>: View {
    let title: String
    var hint: String?
    let accessory: Accessory
    let control: Control

    init(
        title: String,
        hint: String? = nil,
        accessory: Accessory,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.hint = hint
        self.accessory = accessory
        self.control = control()
    }

    init(title: String, hint: String? = nil, @ViewBuilder control: () -> Control) where Accessory == EmptyView {
        self.init(title: title, hint: hint, accessory: EmptyView(), control: control)
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body)
                    accessory
                }
                if let hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 14)
    }
}

private struct RadioChoice: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    init(_ title: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(selected ? Theme.accent : Theme.accent.opacity(Theme.rowFillHoverOpacity))
                        .frame(width: 16, height: 16)
                    if selected {
                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                    }
                }
                Text(title)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EngineHelpPopover: View {
    let strings: AppStrings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(strings.engineHelp)
                .font(.headline)
            ForEach(RecognitionEngine.allCases) { engine in
                engineDescription(engine.displayName, strings.engineDescription(engine))
            }
            Text(strings.engineDownloadHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320)
    }

    private func engineDescription(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
