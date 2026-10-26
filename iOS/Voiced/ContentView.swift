import AVFoundation
import SwiftUI
import Translation
import VoicedCore

/// The same warm palette as the macOS Theme, kept independent of AppKit.
enum MobileTheme {
    static let background = VoicedPalette.background
    static let accent = VoicedPalette.accent
    static let accentDark = VoicedPalette.accentDark
    static let ink = VoicedPalette.ink
    static let card = accent.opacity(VoicedPalette.rowFillOpacity)
    /// The playing line's deeper fill, matching the macOS row's hover/playing shade.
    static let cardActive = accent.opacity(0.26)
    static let gradient = LinearGradient(colors: [accent, accentDark], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// A shared raised surface for secondary actions, including settings and history.
struct RaisedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [.white, MobileTheme.accent.opacity(0.09)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.85), lineWidth: 1)
                    }
                    .shadow(color: MobileTheme.ink.opacity(configuration.isPressed ? 0.04 : 0.12),
                            radius: configuration.isPressed ? 1 : 3, y: configuration.isPressed ? 1 : 3)
            }
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct OrangeButtonStyle: ButtonStyle {
    var size: CGFloat = 44
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                Circle().fill(
                    LinearGradient(colors: [
                        Color(red: 1.0, green: 0.69, blue: 0.43),
                        MobileTheme.accent,
                        MobileTheme.accentDark
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
            .shadow(color: MobileTheme.accentDark.opacity(configuration.isPressed ? 0.10 : 0.22),
                    radius: configuration.isPressed ? 2 : size * 0.09,
                    x: 0, y: configuration.isPressed ? 1 : size * 0.07)
            .offset(y: configuration.isPressed ? 2 : 0)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.9 : 1) : 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: MobileTranscriber
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The search a history result was chosen with, put into the field once the history closes.
    @State private var searchFromHistory: String?
    @ScaledMetric private var titleSize = 34
    /// Space between two transcript cards, and between the search field and the first card.
    private static let rowGap: CGFloat = 10
    /// Cards fade out over this strip at the top once they scroll under the header.
    private static let topFadeHeight: CGFloat = 72
    /// Cards fade out over this strip above the recording controls.
    private static let bottomFadeHeight: CGFloat = 24
    /// Scroll offset for the top fade, kept out of plain state so scrolling redraws the fade alone.
    @State private var scrollFade = ScrollFadeState()
    @State private var showsCopiedToast = false
    @State private var copiedToastResetTask: Task<Void, Never>?

    private var lines: [TranscriptLine] {
        // A translation counts too, as in the history's search, which can open a record by one.
        model.current.lines.reversed().filter {
            query.isEmpty || $0.text.localizedStandardContains(query)
                || $0.translation?.text.localizedStandardContains(query) == true
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if searching {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(MobileTheme.accent)
                        TextField("", text: $query)
                            .textFieldStyle(.plain).font(.body)
                            .focused($searchFocused).submitLabel(.search)
                            .accessibilityLabel("搜索当前转写")
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                query = ""
                                searching = false
                                searchFocused = false
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16)).foregroundStyle(.secondary)
                                .frame(width: 32, height: 32).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("取消")
                    }
                    .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                    // Fully rounded ends, the shape iOS gives a search field.
                    .background(MobileTheme.card, in: Capsule())
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .onAppear { searchFocused = true }
                }
                ScrollView {
                    LazyVStack(spacing: Self.rowGap) {
                        if model.recording || model.stopping || (!model.liveText.isEmpty && query.isEmpty) {
                            transcriptCard(label: "LIVE", text: model.liveText, live: true)
                        }
                        ForEach(model.hints) { hint in
                            HintCard(hint: hint, labelWidth: timestampColumnWidth, stacked: dynamicTypeSize.isAccessibilitySize) {
                                model.ai.dismiss(hint)
                            }
                        }
                        if let message = model.hintError { Text(message).font(.caption).foregroundStyle(.red) }
                        if let message = model.translationError { Text(message).font(.caption).foregroundStyle(.red) }
                        ForEach(lines) { line in
                            transcriptCard(label: line.timestamp(mode: TimestampMode(rawValue: model.timestampID) ?? .current,
                                                                showDate: model.showDate), text: model.displayTexts(line).primary, secondary: model.displayTexts(line).secondary, line: line)
                        }
                    }
                    // Under the search field the first card keeps the gap the cards keep between
                    // themselves; under the header, the wider one.
                    // The last card rests just above the bottom fade, so it is only dimmed while
                    // more of the list lies below it.
                    .padding(.horizontal, 20).padding(.top, searching ? Self.rowGap : 16).padding(.bottom, Self.bottomFadeHeight)
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .modifier(ScrollOffsetReader(fade: scrollFade, limit: Self.topFadeHeight))
                // As on macOS: cards fade out under the header once scrolled, and toward the
                // recording controls at the bottom.
                .mask(
                    VStack(spacing: 0) {
                        TopFade(fade: scrollFade)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.bottomFadeHeight)
                    }
                )
                // After the mask, so the toast itself is never faded.
                .overlay(alignment: .bottom) { if showsCopiedToast { copiedToast } }
                recordingControls
            }
            // Apply this inside NavigationStack too: its content receives its own keyboard safe area.
            // A regular bottom child avoids safeAreaInset lifting the controls above the keyboard.
            .background(MobileTheme.background.ignoresSafeArea())
            .overlay {
                if !model.recording && !model.previewActive && !model.stopping && !model.busy
                    && query.isEmpty && model.current.lines.isEmpty && model.liveText.isEmpty && model.hints.isEmpty
                    && model.hintError == nil && model.translationError == nil {
                    emptyState.padding(.horizontal, 20).allowsHitTesting(false)
                }
            }
            // Include the centered overlay in the same keyboard-independent canvas.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .modifier(MobileTranslationHost(translator: model.translator))
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings, onDismiss: { model.stopInputMeter(); if model.previewActive || model.busy || model.calibrating { model.stop() }; model.savePrompt() }) { MobileSettingsView().environmentObject(model) }
            .sheet(isPresented: $showHistory, onDismiss: {
                // A record opened from a history search shows only its matching lines; any other
                // way of closing the history starts from a clear search.
                if let search = searchFromHistory {
                    query = search
                    searching = true
                } else {
                    query = ""
                    searching = false
                }
                searchFromHistory = nil
                searchFocused = false
            }) {
                MobileHistoryView(openSearch: { searchFromHistory = $0 }).environmentObject(model)
            }
            .modifier(MobileErrorAlert(model: model, enabled: !showSettings && !showHistory))
        }
        // Keep the home canvas at its full height while the search keyboard overlays it.
        // In particular, the centered prompt and microphone must not follow the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .tint(MobileTheme.accent)
        .foregroundStyle(MobileTheme.ink)
        .preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: model.appLanguage.code))
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { wordmark; Spacer(minLength: 12); actions }
            VStack(alignment: .leading, spacing: 16) { wordmark; HStack { Spacer(); actions } }
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
    }

    private var wordmark: some View {
        Text("Voiced").font(.custom("GillSans-Bold", fixedSize: titleSize))
            .foregroundStyle(MobileTheme.accent).fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { model.newRecord(); query = "" } label: { Image(systemName: "plus") }
                .accessibilityLabel("新建转写").disabled(model.locked)
            Button { withAnimation(.easeInOut(duration: 0.2)) { searching.toggle(); if !searching { query = "" } } } label: {
                Image(systemName: "magnifyingglass")
            }.accessibilityLabel("搜索转写")
            Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                .accessibilityLabel("历史记录").disabled(model.locked)
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("设置").disabled(model.busy || model.stopping || model.calibrating)
        }.buttonStyle(OrangeButtonStyle())
    }

    private func transcriptCard(label: String, text: String, live: Bool = false, secondary: String? = nil, line: TranscriptLine? = nil) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { timestampLabel(label, live: live); transcriptText(text, secondary: secondary) }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    timestampLabel(label, live: live).frame(width: timestampColumnWidth, alignment: .leading)
                    transcriptText(text, secondary: secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(live ? MobileTheme.ink.opacity(0.5) : MobileTheme.ink)
        .padding(16).frame(maxWidth: .infinity, minHeight: live ? 64 : nil, alignment: .leading)
        .background(line != nil && model.playingLineID == line?.id ? MobileTheme.cardActive : MobileTheme.card,
                    in: RoundedRectangle(cornerRadius: 18))
        .textSelection(.enabled)
        .onTapGesture { if let line, model.tap(line, in: model.current) { showCopiedToast() } }
        .contextMenu {
            Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = text; showCopiedToast() }
            if let line {
                Button("从此处播放", systemImage: "play") { model.play(model.current, from: line) }
                    .disabled(model.locked || model.current.audioPosition(of: line) == nil)
            }
        }
    }

    /// Wide enough for the timestamp in its current form; the AI notes use it for their label too.
    private var timestampColumnWidth: CGFloat {
        model.showDate && model.timestampID == "current" ? 84 : 55
    }

    private func transcriptText(_ primary: String, secondary: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(primary).font(.body.bold())
            if let secondary { Text(secondary).font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    private func timestampLabel(_ label: String, live: Bool = false) -> some View {
        Text(label.replacingOccurrences(of: " ", with: "\n"))
            .font(.system(.caption, design: .monospaced, weight: .medium))
            .foregroundStyle(live ? Color.red : MobileTheme.accent).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Copied toast

    /// A small pill that fades in above the microphone after a copy and fades out on its own,
    /// matching the macOS window's confirmation. It sits at the bottom so it never covers the
    /// transcript that was just copied.
    private var copiedToast: some View {
        Label(model.strings.copied, systemImage: "checkmark")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(LinearGradient(colors: [MobileTheme.accent, MobileTheme.accentDark.opacity(0.9)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: MobileTheme.accentDark.opacity(0.25), radius: 6, x: 0, y: 3)
            )
            .padding(.bottom, 12)
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityIdentifier("copied-toast")
    }

    private func showCopiedToast() {
        withAnimation(.easeOut(duration: 0.2)) { showsCopiedToast = true }
        copiedToastResetTask?.cancel()
        copiedToastResetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showsCopiedToast = false }
        }
    }

    private var emptyState: some View {
        Text(model.strings.emptyTitle)
            .accessibilityIdentifier("empty-transcript-prompt")
            .font(.subheadline.weight(.medium)).foregroundStyle(MobileTheme.accent)
            .frame(maxWidth: .infinity)
    }

    private var preparationBanner: some View {
        VStack(spacing: 12) {
            Text(LocalizedStringKey(model.status))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(MobileTheme.accent.opacity(0.25))
                        if let fraction = model.downloadProgress {
                            Capsule().fill(MobileTheme.accent)
                                .frame(width: max(0, min(1, fraction)) * geometry.size.width)
                                .animation(.linear(duration: 0.2), value: fraction)
                        } else {
                            TimelineView(.animation) { context in
                                let cycle = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.2)
                                let linear = cycle < 1.1 ? cycle / 1.1 : 2 - cycle / 1.1
                                Capsule().fill(MobileTheme.accent)
                                    .frame(width: geometry.size.width * 0.3)
                                    .offset(x: CGFloat(0.5 - cos(linear * .pi) / 2) * geometry.size.width * 0.7)
                            }
                        }
                    }.clipShape(Capsule())
                }.frame(height: 6)
                if let startedAt = model.loadingStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(model.strings.elapsed(max(0, Int(context.date.timeIntervalSince(startedAt)))))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(MobileTheme.accentDark).fixedSize()
                    }
                }
            }
            if model.loadingStartedAt != nil {
                Text(model.strings.loadingModelHint).font(.caption2).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(maxWidth: 340)
        // The tint over the screen's own colour: the same shade, but solid, so the transcript
        // does not show through the banner.
        .background(MobileTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .background(MobileTheme.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var recordingControls: some View {
        VStack(spacing: 12) {
            if model.busy {
                preparationBanner
                    .padding(.horizontal, 24)
            }
            HStack(spacing: 12) {
                // Equal side columns keep the microphone centered, as on macOS.
                Color.clear.frame(width: 44, height: 44).frame(maxWidth: .infinity)
                Button {
                    if model.recording || model.busy || model.previewActive {
                        model.stop()
                    } else {
                        // A previous search must not hide incoming live text or new sentences.
                        query = ""
                        searching = false
                        searchFocused = false
                        model.start()
                    }
                } label: {
                    if model.stopping { ProgressView().tint(.white) }
                    else {
                        Image(systemName: model.recording || model.busy || model.previewActive ? "stop.fill" : "mic.fill")
                            .font(.system(size: 33, weight: .semibold))
                    }
                }
                .buttonStyle(OrangeButtonStyle(size: 84))
                .disabled(model.stopping)
                .accessibilityLabel(model.recording ? "停止录音" : model.busy ? "取消准备" : "开始录音")
                .accessibilityValue(Text(LocalizedStringKey(model.status)))
                HStack {
                    Circle().fill(model.busy ? Color.red : model.recording ? Color.green : MobileTheme.accent.opacity(0.35))
                        .frame(width: 9, height: 9)
                        .scaleEffect(model.recording ? 1 + CGFloat(min(model.level * 5, 0.5)) : 1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 24).padding(.bottom, 4)
        .overlay(alignment: .top) {
            if model.stopping {
                Text(LocalizedStringKey(model.status)).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
            }
        }
        .background {
            LinearGradient(stops: [.init(color: MobileTheme.background.opacity(0), location: 0),
                                   .init(color: MobileTheme.background, location: 0.25)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: .bottom)
        }
    }

}

extension View {
    func settingsSurface(title: String, large: Bool = false) -> some View {
        self.scrollContentBackground(.hidden)
            .background(MobileTheme.background.ignoresSafeArea())
            .navigationTitle(Text(LocalizedStringKey(title)))
            .navigationBarTitleDisplayMode(large ? .large : .inline)
            .toolbarBackground(MobileTheme.background, for: .navigationBar)
            .tint(MobileTheme.accent)
    }
}

/// An AI note laid out like a transcript card, as on macOS: "AI" where a card has its timestamp,
/// the topic in purple and the note beside it. It has no close button: it leaves on its own once
/// it has been on screen long enough to read. A tap keeps it until tapped again.
private struct HintCard: View {
    let hint: TranscriptHint
    /// Width of the transcript cards' timestamp column, so the texts line up.
    let labelWidth: CGFloat
    /// At accessibility text sizes the label sits above the text, as on the transcript cards.
    let stacked: Bool
    let dismiss: () -> Void
    @State private var pinned = false

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 8) { label; content }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    label.frame(width: labelWidth, alignment: .leading)
                    content.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(VoicedPalette.aiAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { pinned.toggle() }
        .task(id: pinned) {
            guard !pinned else { return }
            do { try await Task.sleep(for: .seconds(hint.readingTime)); dismiss() } catch {}
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(pinned ? "已固定，轻点后自动消失" : "轻点可固定")
    }

    /// "AI" and its symbol, in the timestamp's font; a pin under them while the note is kept.
    private var label: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("AI").font(.system(.caption, design: .monospaced, weight: .bold))
                Image(systemName: "sparkles").font(.caption.weight(.semibold))
            }
            if pinned { Image(systemName: "pin.fill").font(.caption2) }
        }
        .foregroundStyle(VoicedPalette.aiAccent)
    }

    /// A little smaller than the transcript's text, as on macOS; the purple topic tells them apart.
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hint.topic).font(.subheadline).foregroundStyle(VoicedPalette.aiAccent)
            Text(hint.text).font(.subheadline).foregroundStyle(MobileTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textSelection(.enabled)
    }
}

/// How far the transcript list has scrolled down from its top, as far as the top fade cares.
/// Observable so that only the view reading `offset` redraws when it changes.
@Observable
private final class ScrollFadeState {
    var offset: CGFloat = 0
}

/// The top of the list's mask: the fade only exists once cards have scrolled under the edge,
/// growing with the scroll offset so the newest cards are not dimmed at rest.
private struct TopFade: View {
    let fade: ScrollFadeState

    var body: some View {
        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            .frame(height: fade.offset)
    }
}

/// Reports how far a scroll view has scrolled down from its top, in whole points and clamped to
/// `0...limit`. Needs iOS 18; on iOS 17 the offset stays at zero, which only disables the top fade.
private struct ScrollOffsetReader: ViewModifier {
    let fade: ScrollFadeState
    let limit: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                min(max(geometry.contentOffset.y + geometry.contentInsets.top, 0), limit).rounded()
            } action: { _, new in
                fade.offset = new
            }
        } else {
            content
        }
    }
}

private struct MobileTranslationHost: ViewModifier {
    let translator: (any SentenceTranslating)?
    func body(content: Content) -> some View {
        if #available(iOS 18, *), let translator = translator as? AppleTranslator {
            content.modifier(MobileTranslationTasks(translator: translator))
        } else { content }
    }
}

@available(iOS 18, *)
private struct MobileTranslationTasks: ViewModifier {
    @ObservedObject var translator: AppleTranslator
    func body(content: Content) -> some View {
        content.background {
            ForEach(translator.pairs, id: \.self) { pair in
                Color.clear.translationTask(AppleTranslator.configuration(for: pair)) { session in
                    await translator.serve(session, for: pair)
                }
            }
        }
    }
}

struct MobileErrorAlert: ViewModifier {
    @ObservedObject var model: MobileTranscriber
    var enabled = true
    func body(content: Content) -> some View {
        content.alert("Voiced", isPresented: Binding(
            get: { enabled && model.error != nil },
            set: { if !$0 { model.error = nil } }
        )) {
            Button("好") { model.error = nil }
        } message: { Text(LocalizedStringKey(model.error ?? "")) }
    }
}
