import VoicedCore
import AppKit
import SwiftUI
import WhisperKit

/// The pages of the settings window, listed in its sidebar.
enum SettingsSection: CaseIterable, Identifiable {
    case general
    case audioInput
    case recognition
    case translation
    case ai

    var id: Self { self }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .audioInput: "mic.fill"
        case .recognition: "waveform"
        case .translation: "translate"
        case .ai: "sparkles"
        }
    }

    /// Fill of the rounded square behind the symbol, the way System Settings colours its panes.
    var color: Color {
        switch self {
        case .general: Color(red: 0.55, green: 0.55, blue: 0.58)
        case .audioInput: Color(red: 0.94, green: 0.33, blue: 0.31)
        case .recognition: Color(red: 0.25, green: 0.52, blue: 0.96)
        case .translation: Color(red: 0.30, green: 0.72, blue: 0.42)
        case .ai: Theme.aiAccent
        }
    }

    func title(_ strings: AppStrings) -> String {
        switch self {
        case .general: strings.general
        case .audioInput: strings.audioInput
        case .recognition: strings.recognition
        case .translation: strings.translation
        case .ai: strings.ai
        }
    }
}

/// The settings window, laid out like System Settings: a sidebar of pages on the left and the
/// selected page's grouped rows on the right.
struct SettingsView: View {
    @ObservedObject var controller: TranscriptionController
    @Binding var isPresented: Bool
    @State private var section: SettingsSection = .general
    @State private var isResetConfirmationPresented = false
    @State private var isEngineHelpPresented = false
    /// Whether the API key shows as text rather than dots. Starts hidden and is never saved.
    @State private var isAPIKeyRevealed = false

    private var strings: AppStrings { controller.strings }

    /// The width and sidebar of System Settings. The width is fixed; the height is the user's,
    /// dragged between the minimum and the screen. The size never follows the content: sized to
    /// its content, the window would jump between pages, and a content-sized window is where
    /// AppKit's update-constraints loop aborted the app before.
    static let windowSize = SettingsWindowSize(width: 715, minHeight: 420, defaultHeight: 537)
    private static let sidebarWidth: CGFloat = 215

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: Self.windowSize.width)
        .frame(minHeight: Self.windowSize.minHeight, maxHeight: .infinity)
        .background(Theme.background)
        // Toggles, sliders, pickers and radio choices pick up the app's orange.
        .tint(Theme.accent)
        // The level bars listen to the selected device for as long as the window is open.
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

    // MARK: - Layout

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(strings.settings)
                .font(.custom("GillSans-Bold", size: 24))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WindowDragArea())

            ForEach(SettingsSection.allCases) { item in
                SidebarItem(section: item, title: item.title(strings), isSelected: item == section) {
                    section = item
                }
            }

            Spacer(minLength: 0)

            if let version = AppVersion.current {
                Text(strings.version(version))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, Theme.contentPadding)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.accent.opacity(0.06))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(section.title(strings))
                    .font(.title2.weight(.semibold))
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
                .keyboardShortcut(.cancelAction)
            }
            .frame(height: 28)
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, Theme.contentPadding)
            .padding(.bottom, 14)
            .background(WindowDragArea())

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    switch section {
                    case .general: generalPage
                    case .audioInput: audioInputPage
                    case .recognition: recognitionPage
                    case .translation: translationPage
                    case .ai: aiPage
                    }
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.bottom, Theme.contentPadding)
            }
            // Each page starts at the top rather than where the previous one was scrolled to.
            .id(section)
        }
    }

    // MARK: - Pages

    @ViewBuilder
    private var generalPage: some View {
        SettingsGroup {
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

            SettingsRow(title: strings.lineClick, hint: strings.lineClickHint) {
                HStack(spacing: 12) {
                    RadioChoice(strings.copyText, selected: controller.lineClickAction == .copy) {
                        controller.lineClickAction = .copy
                    }
                    RadioChoice(strings.playAudio, selected: controller.lineClickAction == .play) {
                        controller.lineClickAction = .play
                    }
                }
                .fixedSize()
            }
        }

        SettingsGroup {
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
        }

        SettingsGroup {
            SettingsRow(title: strings.resetAllSettings, hint: strings.resetAllSettingsHint) {
                Button(strings.reset, role: .destructive) {
                    isResetConfirmationPresented = true
                }
                .fixedSize()
                .disabled(controller.isRecording || controller.preview.isActive)
                .confirmationDialog(strings.resetAllSettingsConfirmation, isPresented: $isResetConfirmationPresented) {
                    Button(strings.reset, role: .destructive) {
                        controller.resetSettings()
                    }
                    Button(strings.cancel, role: .cancel) {}
                }
            }
        }
    }

    @ViewBuilder
    private var audioInputPage: some View {
        SettingsGroup {
            SettingsRow(title: strings.input, hint: strings.inputHint) {
                InputDevicePopUp(
                    devices: controller.audioDevices,
                    selection: $controller.selectedDeviceID,
                    refresh: {
                        // A device plugged in after the window opened is listed without reopening it.
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
        }

        SettingsGroup {
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
        }
    }

    @ViewBuilder
    private var recognitionPage: some View {
        SettingsGroup {
            // The progress appears under the menu while a model loads; on the baseline the title
            // stays level with the menu instead of re-centring on the taller column. The hint
            // explains the busy machine while the other models compile in the background.
            SettingsRow(
                title: strings.recognitionEngine,
                hint: controller.isCompilingOtherModels ? strings.compilingOtherModels : nil,
                alignment: .firstTextBaseline,
                accessory: engineHelpButton
            ) {
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
            // fine-tuned for, so the choices depend on the model picked above. A single choice
            // still shows as enabled; greyed out, it read as if the setting did not apply.
            SettingsRow(title: strings.recognitionLanguage, hint: strings.recognitionLanguageHint) {
                Picker(strings.recognitionLanguage, selection: $controller.selectedLanguage) {
                    ForEach(RecognitionLanguage.choices(for: controller.selectedEngine)) { language in
                        Text(language.isAutomatic ? strings.automaticDetection : language.nativeName)
                            .tag(language)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 140, alignment: .trailing)
                .disabled(controller.isRecording || controller.preview.isActive)
            }

            if controller.selectedLanguage.isAutomatic {
                Divider()

                detectionLanguagesSection
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
        }

        SettingsGroup {
            RecognitionPreviewSection(controller: controller, preview: controller.preview)
        }
    }

    @ViewBuilder
    private var translationPage: some View {
        SettingsGroup {
            SettingsRow(
                title: strings.translation,
                hint: controller.isTranslationAvailable ? strings.translationHint : strings.translationUnavailable
            ) {
                Toggle(strings.translation, isOn: $controller.translationEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!controller.isTranslationAvailable)
            }
            if let error = controller.translationError {
                Text(strings.translationFailed(error))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 10)
            }

            Divider()

            translationRulesSection

            Divider()

            SettingsRow(title: strings.translationEmphasis, hint: strings.translationEmphasisHint) {
                HStack(spacing: 12) {
                    RadioChoice(strings.originalText, selected: controller.translationEmphasis == .original) {
                        controller.translationEmphasis = .original
                    }
                    RadioChoice(strings.translatedText, selected: controller.translationEmphasis == .translation) {
                        controller.translationEmphasis = .translation
                    }
                }
                .disabled(!controller.translationEnabled)
            }

            Divider()

            SettingsRow(title: strings.speakTranslation, hint: strings.speakTranslationHint) {
                Toggle(strings.speakTranslation, isOn: $controller.speakTranslation)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!controller.translationEnabled)
            }

            // One voice per language translated into; each language keeps its own choice.
            ForEach(controller.translationTargets) { language in
                Divider()
                speechVoiceRow(for: language)
            }
        }
    }

    @ViewBuilder
    private var aiPage: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(strings.openAIAPIKey)
                        .font(.body)
                    getAPIKeyLink
                    Spacer()
                    revealAPIKeyButton
                }
                // A box three lines tall under the title. The key is a secret: unless the eye
                // above reveals it, every character shows as a dot and it cannot be copied out.
                // It wraps wherever it reaches the edge, and Return does nothing: a key has no
                // line breaks.
                CharacterWrappingTextView(text: Binding(
                    get: { controller.openAIAPIKey },
                    set: { controller.openAIAPIKey = $0 }
                ), lines: 3, isRevealed: isAPIKeyRevealed)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.accent.opacity(Theme.rowFillOpacity))
                )
            }
            .padding(.vertical, 14)
        }

        SettingsGroup {
            SettingsRow(
                title: strings.aiHints,
                hint: controller.canHint ? strings.aiHintsHint : strings.aiHintsNeedsKey
            ) {
                Toggle(strings.aiHints, isOn: $controller.aiHintsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if let error = controller.hintError {
                Text(strings.aiHintFailed(error))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 10)
            }

            Divider()

            SettingsRow(title: strings.aiModel, hint: strings.aiModelHint) {
                ModelNameField(name: $controller.aiHintModel, resetTitle: strings.resetToDefault)
                    .disabled(!controller.aiHintsEnabled)
            }

            Divider()

            SettingsRow(title: strings.aiHintWebSearch, hint: strings.aiHintWebSearchHint) {
                Toggle(strings.aiHintWebSearch, isOn: $controller.aiHintWebSearchEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!controller.aiHintsEnabled)
            }

            Divider()

            SettingsRow(title: strings.aiHintLanguage, hint: strings.aiHintLanguageHint) {
                Picker(strings.aiHintLanguage, selection: $controller.aiHintLanguage) {
                    Text(strings.sameAsInterfaceLanguage).tag(AppLanguage?.none)
                    Divider()
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(AppLanguage?.some(language))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160, alignment: .trailing)
                .disabled(!controller.aiHintsEnabled)
            }
        }

        SettingsGroup {
            SettingsRow(
                title: strings.aiSummary,
                hint: controller.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? strings.aiHintsNeedsKey : strings.aiSummaryHint
            ) {
                Toggle(strings.aiSummary, isOn: $controller.aiSummaryEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider()

            SettingsRow(title: strings.aiModel, hint: strings.aiModelHint) {
                ModelNameField(name: $controller.summaryModel, resetTitle: strings.resetToDefault)
                    .disabled(!controller.aiSummaryEnabled)
            }
        }
    }

    // MARK: - Controls

    /// The rules, one per line as "source → target", with a button to add another. Translating
    /// a language into itself would show every sentence twice, so a rule's target never offers
    /// its own source.
    private var translationRulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsRow(title: strings.translationRules, hint: strings.translationRulesHint) {
                Button(strings.addTranslationRule) {
                    if let rule = newTranslationRule() {
                        controller.translationRules.append(rule)
                    }
                }
                .fixedSize()
                .disabled(newTranslationRule() == nil)
            }
            .padding(.bottom, -6)
            ForEach($controller.translationRules) { $rule in
                HStack(spacing: 8) {
                    // A source another rule already has would contradict it, so only free ones
                    // and the rule's own are offered.
                    let taken = controller.translationRules.filter { $0.id != rule.id }.map(\.source)
                    Picker(strings.translationRules, selection: $rule.source) {
                        if !taken.contains(nil) {
                            Text(strings.anyOtherLanguage).tag(AppLanguage?.none)
                        }
                        ForEach(AppLanguage.allCases.filter { !taken.contains($0) }) { language in
                            Text(language.nativeName).tag(Optional(language))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Text("→")
                        .foregroundStyle(.secondary)
                    Picker(strings.translationRules, selection: $rule.target) {
                        ForEach(AppLanguage.allCases.filter { $0 != rule.source }) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .onChange(of: rule.source) { _, source in
                        if rule.target == source, let other = AppLanguage.allCases.first(where: { $0 != source }) {
                            rule.target = other
                        }
                    }
                    // At least one rule stays; turning translation off is the way to stop it.
                    if controller.translationRules.count > 1 {
                        Button(strings.delete) {
                            controller.translationRules.removeAll { $0.id == rule.id }
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                        .padding(.leading, 4)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: 28)
            }
        }
        .padding(.bottom, 14)
        .disabled(!controller.translationEnabled)
    }

    /// The languages automatic detection picks from, one per line, laid out like the
    /// translation rules. With none listed a single "all languages" line stands in; picking a
    /// language there starts the list, and deleting the last line returns to it. Adding is
    /// off on that line: every language is already included.
    private var detectionLanguagesSection: some View {
        let languages = controller.detectionLanguages
        return VStack(alignment: .leading, spacing: 8) {
            SettingsRow(title: strings.detectionLanguages, hint: strings.detectionLanguagesHint) {
                Button(strings.addDetectionLanguage) {
                    if let code = unlistedDetectionLanguages(besides: nil).first?.code {
                        controller.detectionLanguages.append(code)
                    }
                }
                .fixedSize()
                .disabled(languages.isEmpty || unlistedDetectionLanguages(besides: nil).isEmpty)
            }
            .padding(.bottom, -6)
            if languages.isEmpty {
                detectionLanguageLine(Binding(
                    get: { nil },
                    set: { code in controller.detectionLanguages = code.map { [$0] } ?? [] }
                ), offersAll: true, onDelete: nil)
            } else {
                ForEach(Array(languages.enumerated()), id: \.element) { index, code in
                    detectionLanguageLine(Binding(
                        get: { code },
                        set: { if let code = $0 { controller.detectionLanguages[index] = code } }
                    ), offersAll: false) {
                        controller.detectionLanguages.removeAll { $0 == code }
                    }
                }
            }
        }
        .padding(.bottom, 14)
        .disabled(controller.isRecording || controller.preview.isActive)
    }

    /// One line of the detection list: a language picker (nil is "all languages") and, when
    /// `onDelete` is given, a delete button.
    private func detectionLanguageLine(_ code: Binding<String?>, offersAll: Bool, onDelete: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            // A language listed on another line is not offered again.
            Picker(strings.detectionLanguages, selection: code) {
                if offersAll {
                    Text(strings.allLanguages).tag(String?.none)
                }
                ForEach(unlistedDetectionLanguages(besides: code.wrappedValue)) { language in
                    Text(language.nativeName).tag(language.code)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            if let onDelete {
                Button(strings.delete, action: onDelete)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 28)
    }

    /// The detectable languages not yet listed, plus `code` itself so a line's picker keeps
    /// its own choice.
    private func unlistedDetectionLanguages(besides code: String?) -> [RecognitionLanguage] {
        RecognitionLanguage.detectable.filter { $0.code == code || !controller.detectionLanguages.contains($0.code ?? "") }
    }

    /// A rule for the first language no rule has yet, or for any other language once every one
    /// has a rule, into the interface language, or into English when that is the source. Nil
    /// when every source is taken.
    private func newTranslationRule() -> TranslationRule? {
        let taken = controller.translationRules.map(\.source)
        let source: AppLanguage?
        if let free = AppLanguage.allCases.first(where: { !taken.contains($0) }) {
            source = free
        } else if !taken.contains(nil) {
            source = nil
        } else {
            return nil
        }
        let target = source == controller.appLanguage ? (source == .english ? .chinese : .english) : controller.appLanguage
        return TranslationRule(source: source, target: target)
    }

    private func speechVoiceRow(for language: AppLanguage) -> some View {
        SettingsRow(title: "\(strings.speechVoice) · \(language.nativeName)") {
            HStack(spacing: 8) {
                Picker(strings.speechVoice, selection: Binding(
                    get: { controller.speechVoiceID(for: language) },
                    set: { controller.setSpeechVoiceID($0, for: language) }
                )) {
                    Text(strings.defaultVoice).tag(String?.none)
                    ForEach(controller.speechVoices(for: language)) { voice in
                        Text(voiceLabel(voice)).tag(Optional(voice.id))
                    }
                }
                .labelsHidden()
                .frame(width: 180)
                // Next to the hint the row runs short of width, and the button was the
                // view squeezed down to an empty sliver.
                Button(strings.previewVoice) {
                    controller.previewSpeechVoice(for: language)
                }
                .fixedSize()
            }
            .disabled(!controller.translationEnabled || !controller.speakTranslation)
        }
    }

    /// A voice's name with its region, such as "Meijia · 中文（台湾）", and its quality when it is
    /// a downloaded one, named in the interface language.
    private func voiceLabel(_ voice: SpeechVoice) -> String {
        let region = Locale(identifier: strings.language.code).localizedString(forIdentifier: voice.language) ?? voice.language
        let quality = voice.isHighQuality ? " ★" : ""
        return "\(voice.name)\(quality) · \(region)"
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

    /// Opens OpenAI's API key page in the browser, next to the key field's title.
    private var getAPIKeyLink: some View {
        Button(strings.getAPIKey) {
            NSWorkspace.shared.open(URL(string: "https://platform.openai.com/api-keys")!)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(Theme.accent)
    }

    /// Shows or hides the API key in the box under it.
    private var revealAPIKeyButton: some View {
        Button {
            isAPIKeyRevealed.toggle()
        } label: {
            Image(systemName: isAPIKeyRevealed ? "eye.slash" : "eye")
                .foregroundStyle(Theme.accent)
                // Both symbols take the same room, so the title row does not shift on a click.
                .frame(width: 22)
        }
        .buttonStyle(.plain)
        .help(isAPIKeyRevealed ? strings.hideAPIKey : strings.showAPIKey)
        .accessibilityLabel(isAPIKeyRevealed ? strings.hideAPIKey : strings.showAPIKey)
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

/// Start/stop control plus, while running, the input level and the text the recognizer produces
/// with the current settings. The level is repeated from the audio input page, which is not in
/// view here.
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
                    VStack(spacing: 10) {
                        InputLevelBar(
                            monitor: controller.inputLevelMonitor,
                            source: controller.noiseReductionEnabled && controller.noiseProfile != nil ? .denoised : .input,
                            threshold: controller.speechEnergyFloor,
                            help: strings.inputLevel
                        )
                        previewText
                    }
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

/// A secret text box several lines tall, for a value such as an API key: unless revealed, every
/// character is drawn as a dot and copying and cutting do nothing. The text wraps by character
/// since a key has no words. Line breaks cannot be typed or pasted in.
private struct CharacterWrappingTextView: NSViewRepresentable {
    @Binding var text: String
    let lines: Int
    /// Shows the text as it is, and lets it be copied.
    var isRevealed = false

    private static let font = NSFont.monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        let textView = SecretTextView(frame: .zero)
        textView.isRevealed = isRevealed
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        textView.delegate = context.coordinator
        textView.font = Self.font
        textView.drawsBackground = false
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Accessing the TextKit 1 layout manager opts the view out of TextKit 2, which breaks
        // lines by the text's paragraph style and ignores the container's mode. TextKit 1 is
        // also what lets the delegate below draw each character as a dot.
        textView.layoutManager?.delegate = context.coordinator
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.defaultParagraphStyle = Self.paragraphStyle
        textView.typingAttributes = Self.attributes
        textView.string = text
        Self.restyle(textView)
        context.coordinator.watchClicks(outside: textView)
        return scrollView
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.stopWatchingClicks()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let textView = scrollView.documentView as! SecretTextView
        if textView.string != text {
            textView.string = text
            Self.restyle(textView)
        }
        if textView.isRevealed != isRevealed {
            textView.isRevealed = isRevealed
            // The glyphs were made as dots or as letters; they are made again the other way.
            if let layoutManager = textView.layoutManager {
                let all = NSRange(location: 0, length: (textView.string as NSString).length)
                layoutManager.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
                layoutManager.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
            }
            textView.needsDisplay = true
        }
    }

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        return style
    }()

    private static var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .paragraphStyle: paragraphStyle, .foregroundColor: NSColor.textColor]
    }

    /// Every character carries the wrapping style; a string set or pasted in has none of its own.
    static func restyle(_ textView: NSTextView) {
        guard let storage = textView.textStorage else { return }
        storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        textView.typingAttributes = attributes
    }

    /// Pinned: the window is sized by the user and every row keeps a stable height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let line = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        return CGSize(width: proposal.width ?? 300, height: line * CGFloat(lines))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Keeps the secret on the screen while hidden: what it shows cannot be copied, cut or
    /// dragged out. Revealed, it behaves as any text box. Pasting and typing always work.
    final class SecretTextView: NSTextView {
        var isRevealed = false

        override func copy(_ sender: Any?) {
            if isRevealed { super.copy(sender) }
        }

        override func cut(_ sender: Any?) {
            if isRevealed { super.cut(sender) }
        }

        override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            if !isRevealed, item.action == #selector(copy(_:)) || item.action == #selector(cut(_:)) { return false }
            return super.validateUserInterfaceItem(item)
        }

        override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
            isRevealed ? super.writablePasteboardTypes : []
        }

        override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
            isRevealed ? super.dragSelection(with: event, offset: mouseOffset, slideBack: slideBack) : false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSLayoutManagerDelegate {
        var parent: CharacterWrappingTextView
        private var clickMonitor: Any?

        init(parent: CharacterWrappingTextView) {
            self.parent = parent
        }

        deinit {
            stopWatchingClicks()
        }

        /// Ends editing on a click anywhere else in the window, as System Settings does. The
        /// pages sit in a scroll view, so a click on a page never reaches a view behind it;
        /// watching the window's events catches it wherever it lands.
        func watchClicks(outside textView: NSTextView) {
            stopWatchingClicks()
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak textView] event in
                guard let textView, let window = textView.window, event.window === window,
                      window.firstResponder === textView
                else { return event }
                let point = textView.convert(event.locationInWindow, from: nil)
                if !textView.bounds.contains(point) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        func stopWatchingClicks() {
            if let clickMonitor {
                NSEvent.removeMonitor(clickMonitor)
                self.clickMonitor = nil
            }
        }

        /// Lays out a dot in place of every character. The font is monospaced, so the dots take
        /// the room the characters would and the text wraps the same.
        func layoutManager(
            _ layoutManager: NSLayoutManager,
            shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
            properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
            characterIndexes: UnsafePointer<Int>,
            font: NSFont,
            forGlyphRange glyphRange: NSRange
        ) -> Int {
            // Zero keeps the glyphs the layout manager made: the letters themselves.
            guard !parent.isRevealed else { return 0 }
            var bullet: [UniChar] = Array("•".utf16)
            var bulletGlyph = CGGlyph(0)
            guard CTFontGetGlyphsForCharacters(font as CTFont, &bullet, &bulletGlyph, 1) else { return 0 }
            let count = glyphRange.length
            let dots = [CGGlyph](repeating: bulletGlyph, count: count)
            dots.withUnsafeBufferPointer { buffer in
                layoutManager.setGlyphs(
                    buffer.baseAddress!,
                    properties: properties,
                    characterIndexes: characterIndexes,
                    font: font,
                    forGlyphRange: glyphRange
                )
            }
            return count
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            CharacterWrappingTextView.restyle(textView)
            parent.text = textView.string
        }

        /// Return, and anything else that would insert a line break, is dropped.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            commandSelector == #selector(NSResponder.insertNewline(_:))
                || commandSelector == #selector(NSResponder.insertLineBreak(_:))
                || commandSelector == #selector(NSResponder.insertParagraphSeparator(_:))
                || commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        }

        /// Pasted text loses its line breaks before it goes in.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString, replacement.contains(where: \.isNewline) else { return true }
            let cleaned = replacement.filter { !$0.isNewline }
            if textView.shouldChangeText(in: range, replacementString: cleaned) {
                textView.replaceCharacters(in: range, with: cleaned)
                textView.didChangeText()
            }
            return false
        }
    }
}

/// One page in the sidebar: the page's symbol on a coloured rounded square, then its title.
private struct SidebarItem: View {
    let section: SettingsSection
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(section.color)
                            // A slight lift off the sidebar, on the square only so the symbol
                            // does not get a second shadow of its own.
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    )
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            // Pinned, like every settings row that puts a symbol next to a flexible view.
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(Theme.rowFillHoverOpacity) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Rows on a rounded card, the way System Settings groups related settings on a page.
private struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06))
        )
    }
}

/// A label on the left, an optional hint below it, and a control on the right.
private struct SettingsRow<Accessory: View, Control: View>: View {
    let title: String
    var hint: String?
    /// Centred by default. A control that grows underneath, such as the engine menu with its
    /// progress, aligns on the first text baseline instead so the title does not move.
    var alignment: VerticalAlignment = .center
    let accessory: Accessory
    let control: Control

    init(
        title: String,
        hint: String? = nil,
        alignment: VerticalAlignment = .center,
        accessory: Accessory,
        @ViewBuilder control: () -> Control
    ) {
        self.title = title
        self.hint = hint
        self.alignment = alignment
        self.accessory = accessory
        self.control = control()
    }

    init(
        title: String,
        hint: String? = nil,
        alignment: VerticalAlignment = .center,
        @ViewBuilder control: () -> Control
    ) where Accessory == EmptyView {
        self.init(title: title, hint: hint, alignment: alignment, accessory: EmptyView(), control: control)
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
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

/// A menu of the known model names, with a link back to the default name while another is
/// chosen. A stored name the list does not know, from an earlier version or an edited settings
/// file, is listed too so the menu shows what is in use.
private struct ModelNameField: View {
    @Binding var name: String
    let resetTitle: String

    private var models: [String] {
        let current = OpenAIChatCompletion.modelName(name)
        let known = OpenAIChatCompletion.knownModels
        return known.contains(current) ? known : known + [current]
    }

    var body: some View {
        HStack(spacing: 6) {
            if OpenAIChatCompletion.modelName(name) != OpenAIChatCompletion.defaultModel {
                Button(resetTitle) { name = OpenAIChatCompletion.defaultModel }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .padding(.trailing, 4)
            }
            Picker(
                "",
                selection: Binding(
                    get: { OpenAIChatCompletion.modelName(name) },
                    set: { name = $0 }
                )
            ) {
                ForEach(models, id: \.self) { model in
                    Text(model).tag(model)
                }
            }
            .labelsHidden()
            // Its own width, so the menu sits flush with the row's right edge like the other controls.
            .fixedSize()
        }
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
