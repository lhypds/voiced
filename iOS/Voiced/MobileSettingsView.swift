import AVFoundation
import SwiftUI
import VoicedCore

/// The API key's box. SwiftUI's fields cannot do what it needs: the key wraps at any character,
/// never at a word end or a hyphen; Return ends editing instead of adding a line; and while
/// hidden it shows one dot per character over as many lines as the key takes, where a secure
/// field keeps one line and cuts it short. Hidden edits are applied to the real key by range,
/// as each dot stands for one character.
private struct APIKeyField: UIViewRepresentable {
    @Binding var text: String
    let isRevealed: Bool
    let font: UIFont

    /// Room between the box's edge and the text; the whole box, inset included, takes taps.
    static let inset = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textContainerInset = Self.inset
        view.textContainer.lineFragmentPadding = 0
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartDashesType = .no
        view.smartQuotesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardType = .asciiCapable
        view.returnKeyType = .done
        view.accessibilityIdentifier = "openai-api-key"
        view.accessibilityLabel = "OpenAI API 密钥"
        // The frame SwiftUI gives decides the size, never the text.
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.render(in: view)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: APIKeyField

        init(_ parent: APIKeyField) { self.parent = parent }

        private var displayed: String {
            parent.isRevealed ? parent.text : String(repeating: "•", count: (parent.text as NSString).length)
        }

        private var attributes: [NSAttributedString.Key: Any] {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byCharWrapping
            return [.font: parent.font, .foregroundColor: UIColor(MobileTheme.ink), .paragraphStyle: style]
        }

        /// Shows the key, or its dots, keeping the caret where it was.
        func render(in view: UITextView, caret: Int? = nil) {
            let text = displayed
            let attributes = attributes
            view.typingAttributes = attributes
            guard view.text != text || caret != nil || view.font != parent.font else { return }
            let selection = caret.map { NSRange(location: $0, length: 0) } ?? view.selectedRange
            view.attributedText = NSAttributedString(string: text, attributes: attributes)
            let length = (text as NSString).length
            view.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText replacement: String) -> Bool {
            if replacement == "\n" {
                view.resignFirstResponder()
                return false
            }
            let key = parent.text as NSString
            guard NSMaxRange(range) <= key.length else { return false }
            // A pasted key may carry a line break; it is never part of the key.
            let inserted = replacement.filter { !$0.isNewline }
            parent.text = key.replacingCharacters(in: range, with: inserted)
            render(in: view, caret: range.location + (inserted as NSString).length)
            return false
        }
    }
}

struct MobileSettingsView: View {
    @EnvironmentObject private var model: MobileTranscriber
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false
    /// Whether the API key shows as text. Starts hidden and is never saved.
    @State private var isAPIKeyRevealed = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let apiKeyLines = 4
    /// The key's font: monospaced at the caption size the reader has chosen, small enough that
    /// a whole key fits in the box's four lines on a phone.
    private static var apiKeyFont: UIFont {
        UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
    }
    /// Four lines of the key's font plus the box's inset, read again when the text size changes.
    private var apiKeyBoxHeight: CGFloat {
        _ = dynamicTypeSize
        return ceil(Self.apiKeyFont.lineHeight * CGFloat(Self.apiKeyLines)) + APIKeyField.inset.top + APIKeyField.inset.bottom
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { general } label: { settingsLabel("通用", symbol: "gearshape.fill", color: .gray) }
                    NavigationLink { audio } label: { settingsLabel("音频输入", symbol: "mic.fill", color: .red) }
                    NavigationLink { recognition } label: { settingsLabel("识别", symbol: "waveform", color: .blue) }
                    NavigationLink { translation } label: { settingsLabel("翻译", symbol: "character.bubble.fill", color: .green) }
                    NavigationLink { ai } label: { settingsLabel("AI", symbol: "sparkles", color: VoicedPalette.aiAccent) }
                }.listRowBackground(Color.white)
                Section {
                    NavigationLink { about } label: { settingsLabel("关于 Voiced", symbol: "info", color: MobileTheme.accent) }
                }.listRowBackground(Color.white)
            }
            // The default inset-grouped spacing sat the cards close under the large title and far
            // apart from each other; these give both gaps about the same room.
            .listSectionSpacing(24)
            .contentMargins(.top, 12, for: .scrollContent)
            .settingsSurface(title: "设置", large: true)
            .toolbar { Button("完成") { dismiss() }.fontWeight(.semibold).foregroundStyle(MobileTheme.accent) }
        }
        .tint(MobileTheme.accent).foregroundStyle(MobileTheme.ink).preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: model.appLanguage.code))
        .modifier(MobileErrorAlert(model: model))
    }

    private func settingsLabel(_ title: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                 .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
                .frame(width: 30, height: 30)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [.white.opacity(0.65), .black.opacity(0.1)],
                                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
                        }
                }
            Text(LocalizedStringKey(title))
        }.padding(.vertical, 2)
    }

    private var general: some View {
        Form {
            Section {
                NavigationLink {
                    List {
                        Section {
                            ForEach(AppLanguage.allCases) { language in
                                Button {
                                    model.appLanguage = language
                                } label: {
                                    HStack {
                                        Text(language.nativeName).foregroundStyle(MobileTheme.ink)
                                        Spacer()
                                        if model.appLanguage == language {
                                            Image(systemName: "checkmark")
                                                .fontWeight(.semibold).foregroundStyle(MobileTheme.accent)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 32)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(model.appLanguage == language ? .isSelected : [])
                            }
                        }.listRowBackground(Color.white)
                    }.settingsSurface(title: "界面语言")
                } label: {
                    HStack {
                        Text("界面语言")
                        Spacer()
                        Text(model.appLanguage.nativeName).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("interface-language")
                ChoicePicker("点击条目", selection: $model.lineClickAction, options: [LineClickAction.copy, .play]) { action in
                    Text(LocalizedStringKey(action == .copy ? "复制内容" : "播放音频"))
                }
            } footer: { Text("识别过程中点击始终复制。播放时再次点击任意条目停止。") }.listRowBackground(Color.white)
            Section {
                ChoicePicker("时间戳", selection: $model.timestampID,
                             options: [TimestampMode.relative.rawValue, TimestampMode.current.rawValue]) { id in
                    Text(LocalizedStringKey(id == TimestampMode.relative.rawValue ? "相对时间" : "当前时间"))
                }
                Toggle("显示日期", isOn: $model.showDate).disabled(model.timestampID == TimestampMode.relative.rawValue)
            } header: { Text("转写显示") } footer: { Text("相对时间从本次录音开始计时。当前时间显示每句话说出时的时间。") }
                .listRowBackground(Color.white)
            Section {
                Button("重置所有设置", role: .destructive) { confirmReset = true }.disabled(model.locked)
            } footer: { Text("重置偏好和 API 密钥，不删除历史记录、录音或已下载模型。") }.listRowBackground(Color.white)
        }
        .settingsSurface(title: "通用")
        .confirmationDialog("重置所有设置？", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("重置", role: .destructive) { model.resetSettings() }
            Button("取消", role: .cancel) {}
        }
    }

    private var recognition: some View {
        Form {
            Section {
                ChoicePicker("识别模型", selection: $model.engineID, options: RecognitionEngine.allCases.map(\.rawValue)) { id in
                    Text(RecognitionEngine(rawValue: id)?.displayName ?? id)
                }.disabled(model.locked)
                let languages = RecognitionLanguage.choices(for: model.engine)
                ChoicePicker("识别语言", selection: $model.languageID, options: languages.map(\.id)) { id in
                    let language = languages.first { $0.id == id }
                    return Text(language.map { $0.isAutomatic ? model.strings.automaticDetection : $0.nativeName } ?? id)
                }.disabled(model.locked)
                if model.languageID == "auto" {
                    NavigationLink("自动检测语言范围") { detectionLanguages }.disabled(model.locked)
                }
                NavigationLink("识别提示词") { promptEditor }
            } header: { Text("本地语音识别") } footer: {
                Text("建议优先使用 Turbo。首次选择模型时需联网下载，首次加载可能需要几分钟；完成后可离线识别。")
            }.listRowBackground(Color.white)
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("能量阈值")
                        Spacer()
                        Text(model.speechEnergyFloor, format: .number.precision(.fractionLength(3))).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $model.speechEnergyFloor, in: LiveTranscriber.speechEnergyFloorRange).accessibilityLabel("能量阈值")
                }.padding(.vertical, 4)
                Button("恢复默认阈值") { model.speechEnergyFloor = LiveTranscriber.defaultSpeechEnergyFloor }
            } footer: { Text("低于此音量的声音不会触发识别。声音较轻或距离较远时可适当调低。") }
                .listRowBackground(Color.white)
            Section {
                Button {
                    if model.previewActive || model.busy { model.stop() } else { model.startPreview() }
                } label: {
                    HStack {
                        Text(model.previewActive ? model.strings.stopPreview : model.busy ? model.strings.cancel : model.strings.startPreview)
                        Spacer()
                        if model.busy { ProgressView() }
                    }
                }.disabled(model.recording || model.stopping || model.calibrating || model.downloadingVoiceFilter)
                if model.previewActive {
                    ProgressView(value: min(Double(model.level) * 8, 1))
                    Text(model.previewText.isEmpty ? model.strings.subtitle : model.previewText).textSelection(.enabled)
                }
                if model.busy { Text(LocalizedStringKey(model.status)).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("识别预览") } footer: { Text("使用当前设置试听，不写入正文、历史或录音文件，也不发送 AI 请求。") }
                .listRowBackground(Color.white)
        }.settingsSurface(title: "识别")
            .onDisappear { if model.previewActive || model.busy { model.stop() } }
    }

    private var detectionLanguages: some View {
        List {
            Section {
                Button {
                    model.detectionLanguages = []
                } label: { HStack { Text("所有语言"); Spacer(); if model.detectionLanguages.isEmpty { Image(systemName: "checkmark") } } }
                ForEach(RecognitionLanguage.detectable) { language in
                    Button {
                        if model.detectionLanguages.contains(language.id) { model.detectionLanguages.removeAll { $0 == language.id } }
                        else { model.detectionLanguages.append(language.id) }
                    } label: {
                        HStack { Text(language.nativeName).foregroundStyle(MobileTheme.ink); Spacer(); if model.detectionLanguages.contains(language.id) { Image(systemName: "checkmark") } }
                    }
                }
            } footer: { Text("留空表示不限制。只选一种时请直接在识别语言中固定该语言。") }.listRowBackground(Color.white)
        }.settingsSurface(title: "自动检测语言范围")
    }

    private var promptEditor: some View {
        Form {
            Section {
                TextEditor(text: $model.promptText).font(.body.monospaced()).frame(minHeight: 320)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            } footer: { Text("每行一个人名、产品名或术语；# 开头的行被忽略。下一次识别或预览生效，最多使用前 223 个 token。") }
                .listRowBackground(Color.white)
        }.settingsSurface(title: "识别提示词").onDisappear { model.savePrompt() }
    }

    private var audio: some View {
        Form {
            Section {
                ChoicePicker("输入设备", selection: $model.selectedInputID,
                             options: [nil] + model.availableInputs.map { Optional($0.uid) }) { uid in
                    guard let input = model.availableInputs.first(where: { $0.uid == uid }) else { return Text("系统默认麦克风") }
                    return Text(input.portName)
                }.disabled(model.locked)
                Button("刷新输入设备") { model.refreshInputs() }.disabled(model.locked)
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.strings.inputLevel).font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: min(Double(model.inputLevelMonitor.level) * 8, 1))
                }
                LabeledContent { Text("前台录音") } label: { Text("录音方式") }
            } footer: { Text("使用系统提供的麦克风或外接输入。来电或进入后台时会结束录音，已采集音频会保存。") }.listRowBackground(Color.white)
            Section {
                Toggle("降噪", isOn: $model.noiseReduction).disabled(model.locked || model.noiseProfile == nil)
                if model.noiseProfile != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.strings.denoisedLevel).font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: min(Double(model.inputLevelMonitor.denoisedLevel) * 8, 1))
                    }
                }
                HStack { Text("噪声样本"); Spacer(); Text(LocalizedStringKey(model.noiseProfile == nil ? "未采集" : "已采集")).foregroundStyle(.secondary) }
                Button {
                    if model.calibrating { model.stop() } else { model.calibrateNoise() }
                } label: {
                    HStack { Text(model.calibrating ? model.strings.cancel : model.strings.calibrateNoise); Spacer(); if model.calibrating { ProgressView() } }
                }.disabled(model.locked && !model.calibrating)
            } footer: { Text("测量时请保持安静约 2 秒。采集背景噪声并自动调整阈值；开启降噪后会先处理输入再识别。") }
                .listRowBackground(Color.white)
            Section {
                Toggle("人声过滤", isOn: $model.voiceFilter).disabled(model.locked)
                    .onChange(of: model.voiceFilter) { _, enabled in if enabled { model.prepareVoiceFilter() } }
                if model.downloadingVoiceFilter { HStack { ProgressView(); Text("下载人声检测模型…") } }
            } footer: { Text("使用与 Mac 相同的 Silero VAD 模型过滤音乐等非人声。首次开启需下载约 1 MB 模型。") }
                .listRowBackground(Color.white)
            Section {
                Button { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } } label: {
                    HStack { Text("麦克风权限"); Spacer(); Image(systemName: "arrow.up.right") }
                }
            } footer: { Text("在系统设置中管理 Voiced 的麦克风访问权限。") }.listRowBackground(Color.white)
        }.settingsSurface(title: "音频输入").onAppear { model.showAudioInputs() }
            .onDisappear { model.stopInputMeter() }
            .onChange(of: model.selectedInputID) { _, _ in model.startInputMeter() }
    }

    private var translation: some View {
        Form {
            Section {
                Toggle("翻译", isOn: $model.translationEnabled).disabled(!model.translationAvailable)
                ChoicePicker("主要文字", selection: $model.translationEmphasis, options: [TranslationEmphasis.original, .translation]) { emphasis in
                    Text(LocalizedStringKey(emphasis == .original ? "原文" : "译文"))
                }.accessibilityIdentifier("translation-emphasis")
            } footer: {
                Text(model.translationAvailable ? LocalizedStringKey("由系统在本机翻译，不会上传。首次使用需下载语言包。") : LocalizedStringKey("翻译需要 iOS 18 或更高版本。"))
            }.listRowBackground(Color.white)
            if model.translationAvailable {
                ForEach($model.translationRules) { $rule in
                    Section {
                        ChoicePicker("来源语言", selection: $rule.source, options: [nil] + AppLanguage.allCases.map(Optional.init)) { language in
                            language.map { Text($0.nativeName) } ?? Text("任意语言")
                        }.accessibilityIdentifier("translation-source")
                        ChoicePicker("目标语言", selection: $rule.target, options: AppLanguage.allCases) { Text($0.nativeName) }
                            .accessibilityIdentifier("translation-target")
                        Button(role: .destructive) {
                            let id = rule.id
                            model.translationRules.removeAll { $0.id == id }
                        } label: { Label(model.strings.delete, systemImage: "trash") }
                    } header: { Text("翻译规则") }.listRowBackground(Color.white)
                }
                Section {
                    Button("添加翻译规则", systemImage: "plus") {
                        let used = Set(model.translationRules.compactMap(\.source))
                        if let source = AppLanguage.allCases.first(where: { !used.contains($0) }) {
                            model.translationRules.append(TranslationRule(source: source, target: model.appLanguage))
                        }
                    }
                } footer: { Text("优先匹配指定语言，再匹配任意语言规则。相同来源的首条规则生效。") }.listRowBackground(Color.white)
                Section {
                    Toggle("朗读译文", isOn: $model.speakTranslation)
                    ForEach(model.translationTargets) { language in
                        let voices = TranslationSpeaker.voices(for: language.code)
                        ChoicePicker(language.nativeName,
                                     selection: Binding(get: { model.speechVoices[language.code] }, set: { model.speechVoices[language.code] = $0 }),
                                     options: [nil] + voices.map { Optional($0.id) }) { id in
                            guard let voice = voices.first(where: { $0.id == id }) else { return Text("系统默认") }
                            return Text("\(voice.name) · \(voice.language)")
                        }
                        Button { model.previewVoice(language) } label: { Label(language.nativeName, systemImage: "speaker.wave.2") }
                    }
                } header: { Text("语音") } footer: { Text("只朗读新识别句子的译文；朗读时暂时屏蔽麦克风输入，避免回声被重复识别。") }
                    .listRowBackground(Color.white)
                if let error = model.translationError {
                    Section { Text(error).foregroundStyle(.red); Button("重试翻译") { model.configureTranslation() } }.listRowBackground(Color.white)
                }
            }
        }.settingsSurface(title: "翻译")
    }

    private var ai: some View {
        Form {
            Section {
                // As on macOS: what the field is for on the first line, with where to get a key, and
                // the field on the second, so the title stays once a key has been entered.
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("OpenAI API 密钥")
                        Link("获取密钥", destination: URL(string: "https://platform.openai.com/api-keys")!)
                            .font(.footnote).foregroundStyle(MobileTheme.accent)
                            // Only the link opens the page, not a tap anywhere on the row.
                            .buttonStyle(.borderless)
                        Spacer()
                        // Shows or hides the key, as the eye on macOS does.
                        Button { isAPIKeyRevealed.toggle() } label: {
                            Image(systemName: isAPIKeyRevealed ? "eye.slash" : "eye")
                                .foregroundStyle(MobileTheme.accent)
                                // Both symbols take the same room, so the row does not shift.
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(isAPIKeyRevealed ? "隐藏密钥" : "显示密钥")
                        .accessibilityIdentifier("reveal-api-key")
                    }
                    // A box four lines tall in both states. The key, or one dot per character while
                    // hidden, wraps at any character inside it. Its height never follows the text.
                    APIKeyField(text: $model.apiKey, isRevealed: isAPIKeyRevealed, font: Self.apiKeyFont)
                        .frame(maxWidth: .infinity, minHeight: apiKeyBoxHeight, maxHeight: apiKeyBoxHeight)
                        .overlay(alignment: .topLeading) {
                            if model.apiKey.isEmpty {
                                Text(verbatim: "sk-…").font(Font(Self.apiKeyFont)).foregroundStyle(.tertiary)
                                    .padding(EdgeInsets(top: APIKeyField.inset.top, leading: APIKeyField.inset.left,
                                                        bottom: 0, trailing: 0))
                                    .allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                        .background(MobileTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(.vertical, 6)
            } footer: { Text("密钥保存在此设备的设置中。开启 AI 提示后，仅值得询问的新句子及前文会发送给 OpenAI；摘要只在点击生成时发送整段文字。API 使用由你的 OpenAI 账户计费。") }
                .listRowBackground(Color.white)
            Section {
                Toggle("AI 提示", isOn: $model.aiHintsEnabled)
                modelPicker("提示模型", selection: $model.hintModel)
                Toggle("联网搜索", isOn: $model.hintWebSearch)
                ChoicePicker("AI 提示语言", selection: $model.hintLanguage, options: [nil] + AppLanguage.allCases.map(Optional.init)) { language in
                    language.map { Text($0.nativeName) } ?? Text("跟随界面语言")
                }
            } footer: { Text("联网搜索需要所选模型支持搜索工具，可能增加等待时间与费用。提示会自动消失，轻点可固定，再次轻点取消固定。") }
                .listRowBackground(Color.white)
            Section {
                Toggle("AI 摘要", isOn: $model.summaryEnabled)
                modelPicker("摘要模型", selection: $model.summaryModel)
            } footer: { Text("在历史记录中生成、查看和分享摘要。摘要使用界面语言，并与转写一起保存在该记录目录下。") }
                .listRowBackground(Color.white)
            if let error = model.hintError { Section { Text(error).foregroundStyle(.red) }.listRowBackground(Color.white) }
        }.settingsSurface(title: "AI")
    }

    private func modelPicker(_ title: String, selection: Binding<String>) -> some View {
        NavigationLink {
            Form {
                Section { TextField("模型名称", text: selection).autocorrectionDisabled().textInputAutocapitalization(.never) }
                Section {
                    ForEach(OpenAIChatCompletion.knownModels, id: \.self) { name in
                        Button { selection.wrappedValue = name } label: {
                            HStack { Text(name); Spacer(); if selection.wrappedValue == name { Image(systemName: "checkmark") } }
                        }
                    }
                } footer: { Text("可填写你的 API 账户支持的其他模型名称。服务端决定模型及联网搜索是否可用。") }
            }.settingsSurface(title: title)
        } label: {
            HStack { Text(LocalizedStringKey(title)); Spacer(); Text(OpenAIChatCompletion.modelName(selection.wrappedValue)).foregroundStyle(.secondary).lineLimit(1) }
        }.accessibilityIdentifier("modelPicker.\(title)")
    }

    private var about: some View {
        Form {
            Section {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                LabeledContent("语音识别", value: "WhisperKit · Core ML")
            }.listRowBackground(Color.white)
            Section("数据与隐私") {
                Text("语音识别、降噪、翻译和录音保存在此设备上。AI 提示和摘要仅在开启或点击时发送相应文字给 OpenAI。")
                Text("卸载应用会删除本地数据，请先导出重要文字、摘要和录音。")
            }.listRowBackground(Color.white)
        }.settingsSurface(title: "关于 Voiced")
    }
}

/// Stands in for `.pickerStyle(.navigationLink)`: the system picker pushes its own list, which
/// `settingsSurface` cannot restyle, so that page showed the default grey grouped background.
/// This pushes a themed list instead and pops as soon as a choice is made, like the system picker.
private struct ChoicePicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> Text

    init(_ title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> Text) {
        self.title = title
        _selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        NavigationLink {
            ChoiceList(title: title, selection: $selection, options: options, label: label)
        } label: {
            HStack {
                Text(LocalizedStringKey(title))
                Spacer()
                label(selection).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct ChoiceList<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> Text
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                        dismiss()
                    } label: {
                        HStack {
                            label(option).foregroundStyle(MobileTheme.ink)
                            Spacer()
                            if selection == option {
                                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(MobileTheme.accent)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
                }
            }.listRowBackground(Color.white)
        }.settingsSurface(title: title)
    }
}
