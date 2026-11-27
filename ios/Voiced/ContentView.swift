import AVFoundation
import SwiftUI
import UIKit
import Translation
import VoicedCore

/// The same black-and-grey palette as the macOS Theme, kept independent of AppKit.
enum MobileTheme {
    static let background = VoicedPalette.background
    static let accent = VoicedPalette.accent
    static let accentDark = VoicedPalette.accentDark
    static let ink = VoicedPalette.ink
    static let card = accent.opacity(VoicedPalette.rowFillOpacity)
    /// The playing line's deeper fill, matching the macOS row's hover/playing shade.
    static let cardActive = accent.opacity(0.10)
    static let timestamp = VoicedPalette.timestamp
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

struct ContentView: View {
    @EnvironmentObject private var model: MobileTranscriber
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showSettings = false
    @State private var showMachines = false
    /// The line being edited in its own card, from the card's menu, and the text being typed.
    @State private var editingLineID: String?
    /// The Claude Code run shown whole, opened from its card.
    @State private var openRun: RunSheetID?
    @State private var editText = ""
    @FocusState private var editFocused: Bool
    /// The blue card a hold that heard nothing opens, for typing the command instead, and what is
    /// typed into it.
    @State private var typingCommand = false
    @State private var commandText = ""
    @FocusState private var commandFocused: Bool
    @State private var commandFieldFrame: CGRect = .zero
    /// Where the field being edited is on screen, so a tap anywhere else ends the editing.
    @State private var editorFrame: CGRect = .zero
    /// The card being edited and the keyboard's top edge on screen. The keyboard covers the list
    /// rather than shrinking it, so the list's content is lifted by `editLift`, without scrolling,
    /// until the card sits above the keyboard; it drops back once the editing ends.
    @State private var editingCardFrame: CGRect = .zero
    @State private var keyboardTop: CGFloat?
    @State private var editLift: CGFloat = 0
    /// Whether a finger is on the microphone; the ring is filled meanwhile.
    @State private var micTouching = false
    /// Whether the current touch on the microphone has become a hold.
    @State private var micHolding = false
    /// Whether the finger has moved off the microphone; letting go there cancels a hold.
    @State private var micOutside = false
    /// Whether the current touch on the microphone only started loading the model, so letting go
    /// does nothing.
    @State private var micLoadOnly = false
    /// Bumped by a tap or hold on the microphone, to bring the list back to its top, where the LIVE card is.
    @State private var scrollToTopRequest = 0
    /// Turns the current touch into a hold once it has lasted half a second.
    @State private var micHoldTimer: Task<Void, Never>?
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
    /// How far the list reaches up behind the header, so a long-pressed card's shadow is not cut
    /// off at the list's top edge. Needs the scroll offset (iOS 18) to hide it once scrolled.
    private static var topBleed: CGFloat {
        if #available(iOS 18, *) { 32 } else { 0 }
    }
    /// The microphone button's diameter, and the space the recording controls keep above and below it.
    private static let micSize: CGFloat = 84
    private static let controlsTopPadding: CGFloat = 24
    private static let controlsBottomPadding: CGFloat = 4
    /// The recording controls float over the list; its last card can scroll up clear of them.
    private static let controlsHeight: CGFloat = controlsTopPadding + micSize + controlsBottomPadding
    /// The soft bottom edge of the list: cards fade out over this height, clear from about the top
    /// of the microphone down.
    private static let bottomFadeHeight: CGFloat = controlsHeight + 16
    /// Scroll offset for the top fade, kept out of plain state so scrolling redraws the fade alone.
    @State private var scrollFade = ScrollFadeState()
    /// The notice shown above the microphone for a moment: after a copy, or after a hold while
    /// "Send to Mac" is off.
    @State private var toast: Toast?
    private enum Toast { case copied, releaseToCancel, sentToMac, notSentToMac }
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
                header.simultaneousGesture(dismissHeaderKeyboard).zIndex(1)
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
                    .zIndex(1)
                }
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Self.rowGap) {
                        if model.holding || model.recognizingHold {
                            // A hold shows its speech as a waveform, then its text once let go.
                            speechCard
                        } else if !model.recordingForHold,
                                  model.recording || model.stopping || (!model.liveText.isEmpty && query.isEmpty) {
                            // Blue while what is said goes to the Mac.
                            transcriptCard(label: "LIVE", text: model.liveText, live: true,
                                           mac: model.liveForMac ? true : nil)
                        }
                        ForEach(model.hints) { hint in
                            HintCard(hint: hint, labelWidth: timestampColumnWidth, stacked: dynamicTypeSize.isAccessibilitySize) {
                                model.ai.dismiss(hint)
                            }
                        }
                        if let message = model.hintError { Text(message).font(.caption).foregroundStyle(.red) }
                        if let message = model.translationError { Text(message).font(.caption).foregroundStyle(.red) }
                        if typingCommand { commandDraftCard }
                        ForEach(lines) { line in
                            // A command waiting to be sent says so where its time would be, as
                            // SPEECH and TYPE do for the hold and typed cards before it.
                            let waiting = model.isUnsentMacCommand(line) && model.macDelivery(of: line) == nil
                            transcriptCard(label: waiting ? "PROMPT"
                                           : line.timestamp(mode: TimestampMode(rawValue: model.timestampID) ?? .current,
                                                                showDate: model.showDate), text: model.displayTexts(line).primary, secondary: model.displayTexts(line).secondary, line: line,
                                           // A command from a hold not sent yet is blue too, with no note.
                                           mac: model.macDelivery(of: line) ?? (model.isUnsentMacCommand(line) ? true : nil))
                            // The Mac's Claude Code run of a line sent with Run, under it.
                            if let run = model.claudeRun(forLine: line.id) {
                                ClaudeRunCard(run: run, labelWidth: timestampColumnWidth, stacked: dynamicTypeSize.isAccessibilitySize,
                                              connected: model.macLink.connectedName != nil,
                                              open: { openRun = RunSheetID(id: run.id) }) { action in
                                    model.macLink.send(ClaudeRunCommand(command: action, run: run.id, pending: run.pending?.id))
                                }
                            }
                        }
                    }
                    // Under the search field the first card keeps the gap the cards keep between
                    // themselves; under the header, the wider one.
                    // The last card comes to rest just above the floating controls.
                    .padding(.horizontal, 20).padding(.top, (searching ? Self.rowGap : 16) + Self.topBleed)
                    .padding(.bottom, Self.bottomFadeHeight)
                    .frame(maxWidth: 820).frame(maxWidth: .infinity)
                    // The whole content, padding included, so scrolling to it shows the very top.
                    .id(Self.listTopID)
                    .offset(y: -editLift)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollIndicators(.hidden)
                // While a line is edited the list stays put; a drag anywhere but in the field ends
                // the editing instead, which saves it and lets the card drop back.
                .scrollDisabled(editingLineID != nil)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8, coordinateSpace: .global).onChanged { drag in
                        if editingLineID != nil, !editorFrame.contains(drag.startLocation) { editFocused = false }
                    },
                    including: editingLineID != nil ? .all : .subviews
                )
                .modifier(ScrollOffsetReader(fade: scrollFade, limit: Self.topFadeHeight))
                .onChange(of: scrollToTopRequest) {
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.listTopID, anchor: .top) }
                }
                // A hold for the Mac that heard nothing: the command is typed instead.
                .onChange(of: model.typeCommandRequests) { startTypingCommand() }
                .onChange(of: keyboardTop) { liftEditedCard() }
                .onChange(of: editingCardFrame.height) { liftEditedCard() }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                    guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                    let screen = UIScreen.main.bounds.height
                    keyboardTop = frame.minY < screen ? frame.minY : nil
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                    keyboardTop = nil
                }
                }
                // As on macOS: cards fade out under the header once scrolled.
                .mask(
                    VStack(spacing: 0) {
                        TopFade(fade: scrollFade, bleed: Self.topBleed)
                        Color.black
                        // The same soft edge at the bottom, where cards scroll on under the
                        // microphone. Scrolled to the end, the last card rests just above it.
                        LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .clear, location: 0.5)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.bottomFadeHeight)
                    }
                )
                // After the mask, so neither is faded. The controls float over the cards, which
                // scroll on behind them; their empty side columns let taps through to the list.
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        if micHolding && micOutside { toastView(.releaseToCancel) }
                        else if let toast { toastView(toast) }
                        recordingControls
                    }
                }
                // Blank space included, so a tap anywhere but the search field puts the keyboard away.
                .contentShape(Rectangle())
                .simultaneousGesture(dismissSearchKeyboard)
                // Up behind the header (and search field), which stay on top and keep their taps.
                .padding(.top, -Self.topBleed)
            }
            // Apply this inside NavigationStack too: its content receives its own keyboard safe area.
            // An overlay rather than safeAreaInset, which would lift the controls above the keyboard.
            .background(MobileTheme.background.ignoresSafeArea())
            .overlay {
                // Not while a command is being typed: the TYPE card is already there.
                if !model.recording && !model.previewActive && !model.stopping && !model.busy && !model.modelLoading
                    && !typingCommand && query.isEmpty && model.current.lines.isEmpty && model.liveText.isEmpty && model.hints.isEmpty
                    && model.hintError == nil && model.translationError == nil {
                    emptyState.padding(.horizontal, 20).allowsHitTesting(false)
                }
            }
            // Include the centered overlay in the same keyboard-independent canvas.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .modifier(MobileTranslationHost(translator: model.translator))
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $openRun) { run in ClaudeRunSheet(runID: run.id).environmentObject(model) }
            .sheet(isPresented: $showMachines) { SendToMachineSheet().environmentObject(model) }
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
            // As on macOS: a record left with nothing to search, a new one say, closes the search.
            .onChange(of: model.current.lines.isEmpty) { _, isEmpty in
                guard isEmpty, searching else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    query = ""
                    searching = false
                    searchFocused = false
                }
            }
        }
        // Keep the home canvas at its full height while the search keyboard overlays it.
        // In particular, the centered prompt and microphone must not follow the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // The microphone sits near the bottom edge, where iOS holds a touch back while it checks
        // for the home swipe; deferring that swipe lets the press show at once and the hold time
        // from the real touch.
        .defersSystemGestures(on: .bottom)
        .tint(MobileTheme.accent)
        .foregroundStyle(MobileTheme.ink)
        .preferredColorScheme(.light)
        .environment(\.locale, Locale(identifier: model.appLanguage.code))
    }

    /// Alongside whatever the tap does, so the cards and buttons still answer it.
    /// Also ends editing a line, which saves it, for a tap anywhere but the field being edited,
    /// where a tap moves the cursor.
    private var dismissSearchKeyboard: some Gesture {
        SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
            searchFocused = false
            if editingLineID != nil, !editorFrame.contains(tap.location) { editFocused = false }
            if typingCommand, !commandFieldFrame.contains(tap.location) { commandFocused = false }
        }
    }

    /// The header holds no field being edited: any tap there ends the editing.
    private var dismissHeaderKeyboard: some Gesture {
        TapGesture().onEnded { searchFocused = false; editFocused = false; commandFocused = false }
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
            // Always available, as on macOS: it stops a running recognition before starting the new record.
            Button { model.newRecord(); query = "" } label: { Image(systemName: "plus") }
                .accessibilityLabel("新建转写")
            Button { withAnimation(.easeInOut(duration: 0.2)) { searching.toggle(); if !searching { query = "" } } } label: {
                Image(systemName: "magnifyingglass")
            }.accessibilityLabel("搜索转写")
                // As on macOS: nothing to search until the record has a sentence.
                .disabled(model.current.lines.isEmpty)
            Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                // Grey with nothing in the history yet, as well as while recording.
                .accessibilityLabel("历史记录").disabled(model.locked || model.records.isEmpty)
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("设置").disabled(model.busy || model.stopping || model.calibrating)
        }.buttonStyle(RingButtonStyle())
    }

    /// `mac` marks a card for the Mac: light blue, with a blue timestamp. For a sent line it says
    /// whether the sentence went out; false adds a note that no Mac was connected.
    private func transcriptCard(label: String, text: String, live: Bool = false, secondary: String? = nil, line: TranscriptLine? = nil,
                                mac: Bool? = nil) -> some View {
        let note: String? = mac == false ? "未连接电脑，未发送" : nil
        let editing = line != nil && line?.id == editingLineID
        // A command waiting to be sent (PROMPT) is as tall as the SPEECH card it replaces.
        let waiting = line.map { model.isUnsentMacCommand($0) && model.macDelivery(of: $0) == nil } ?? false
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    timestampLabel(label, live: live, mac: mac != nil)
                    transcriptText(text, secondary: secondary, note: note, editing: editing ? line : nil)
                }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    timestampLabel(label, live: live, mac: mac != nil).frame(width: timestampColumnWidth, alignment: .leading)
                    transcriptText(text, secondary: secondary, note: note, editing: editing ? line : nil)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(live ? MobileTheme.ink.opacity(0.5) : MobileTheme.ink)
        .padding(16).frame(maxWidth: .infinity, minHeight: live || waiting ? 64 : nil, alignment: .leading)
        .background(cardFill(line: line, mac: mac != nil), in: RoundedRectangle(cornerRadius: 18))
        // Nil for the other cards, so starting to edit this one reports its frame even though it has not moved.
        .onGeometryChange(for: CGRect?.self) { editing ? $0.frame(in: .global) : nil } action: { if let frame = $0 { editingCardFrame = frame } }
        // The long-press lift and highlight take the card's own shape; by default iOS draws them
        // with a corner radius of its own, leaving a thin gap at the corners.
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 18))
        .textSelection(.enabled)
        // While editing, a tap places the cursor instead of copying or playing the line.
        // A tap on another card while editing only ends the editing, which saves it.
        .onTapGesture {
            if editing { return }
            if editingLineID != nil { editFocused = false; return }
            guard let line else { return }
            // A command still waiting to be sent opens for editing rather than playing or copying:
            // what is fixed here is what the send button then sends.
            if model.isUnsentMacCommand(line) && model.macDelivery(of: line) == nil {
                beginEditing(line, afterMenu: false)
                return
            }
            if model.tap(line, in: model.current) { showCopiedToast() }
        }
        .contextMenu {
            // No menu over the text being edited: a long press there selects text.
            if !editing {
                Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = text; showCopiedToast() }
            }
            if let line, !editing {
                Button("从此处播放", systemImage: "play") { model.play(model.current, from: line) }
                    .disabled(model.locked || model.current.audioPosition(of: line) == nil)
                Button("编辑", systemImage: "pencil") { beginEditing(line) }
                // Only with "Send to machine" on in Settings; again for a line already sent.
                if model.sendToMacEnabled {
                    Button("发送到电脑", systemImage: "laptopcomputer") {
                        show(model.sendLineToMac(line) ? .sentToMac : .notSentToMac, for: .seconds(2))
                    }
                }
                // The view's tint would colour the symbol with the accent and leave only the title
                // red; an image drawn red in its own colours is kept as it is.
                Button(role: .destructive) {
                    withAnimation(.easeOut(duration: 0.2)) { model.deleteLine(line) }
                } label: {
                    Label {
                        Text("删除")
                    } icon: {
                        Image(uiImage: UIImage(systemName: "trash")!.withTintColor(.systemRed, renderingMode: .alwaysOriginal))
                    }
                }
            }
        }
    }

    /// Wide enough for the timestamp in its current form; the AI notes use it for their label too.
    private var timestampColumnWidth: CGFloat {
        model.showDate && model.timestampID == "current" ? 84 : 55
    }

    /// The live card while the microphone is held: SPEECH and a waveform of the input, then, once
    /// let go, a note while the clip is recognised. Its text then arrives as a line of its own.
    private var speechCard: some View {
        let mac = model.liveForMac
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { timestampLabel("SPEECH", live: true, mac: mac); speechContent }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    timestampLabel("SPEECH", live: true, mac: mac).frame(width: timestampColumnWidth, alignment: .leading)
                    speechContent.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(cardFill(line: nil, mac: mac), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var speechContent: some View {
        if model.holding {
            WaveformView(meter: model.waveform, color: model.liveForMac ? VoicedPalette.macAccent : MobileTheme.ink.opacity(0.5))
                .frame(height: 28)
                .accessibilityLabel(Text("正在录音"))
        } else {
            Text("识别中…").font(.body.bold()).foregroundStyle(MobileTheme.ink.opacity(0.5))
        }
    }

    private func cardFill(line: TranscriptLine?, mac: Bool) -> Color {
        let playing = line.map { model.playingLineID == $0.id } ?? false
        // A line sent to the Mac stays blue while it plays, a deeper blue.
        if mac { return VoicedPalette.macAccent.opacity(playing ? 0.32 : 0.14) }
        return playing ? MobileTheme.cardActive : MobileTheme.card
    }

    /// The blue card a hold opens when it heard nothing, with the keyboard up: what is typed
    /// becomes the command, a blue line waiting to be sent as a spoken one would. Return, or the
    /// keyboard going away, adds it; left empty, the card just goes.
    private var commandDraftCard: some View {
        let textField = TextField("", text: $commandText, prompt: Text("输入要发送到电脑的内容"), axis: .vertical)
            .font(.body.bold())
            .focused($commandFocused)
            .submitLabel(.done)
            .accessibilityIdentifier("command-editor")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { commandFieldFrame = $0 }
            // A vertical field takes Return as a line break; a command has none, so it is added instead.
            .onChange(of: commandText) { _, value in
                guard value.contains("\n") else { return }
                commandText = value.replacingOccurrences(of: "\n", with: "")
                finishTypingCommand()
            }
            .onChange(of: commandFocused) { _, focused in
                if !focused { finishTypingCommand() }
            }
        // The field is a few points taller than its text, all of it below the glyphs, which left
        // the prompt above the card's middle. As in lineEditor: laid from the top over the same
        // text, hidden, so the card is sized by the text and centres it.
        let field = (commandText.isEmpty ? Text("输入要发送到电脑的内容") : Text(verbatim: commandText))
            .font(.body.bold())
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) { textField.fixedSize(horizontal: false, vertical: true) }
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { timestampLabel("TYPE", mac: true); field }
            } else {
                HStack(alignment: .center, spacing: 16) {
                    timestampLabel("TYPE", mac: true).frame(width: timestampColumnWidth, alignment: .leading)
                    field.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(MobileTheme.ink)
        .padding(16).frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(cardFill(line: nil, mac: true), in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { commandFocused = true }
        // Fades in where it stands, rather than dropping down from above.
        .transition(.opacity)
    }

    private func startTypingCommand() {
        guard model.sendToMacEnabled else { return }
        // Already open: what has been typed stays.
        if typingCommand { commandFocused = true; return }
        editFocused = false
        searchFocused = false
        commandText = ""
        withAnimation(.easeOut(duration: 0.2)) { typingCommand = true }
        scrollToTopRequest += 1
        // Once the field is there to take focus.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if typingCommand { commandFocused = true }
        }
    }

    private func finishTypingCommand() {
        guard typingCommand else { return }
        let text = commandText
        commandText = ""
        commandFocused = false
        withAnimation(.easeOut(duration: 0.2)) {
            typingCommand = false
            model.addTypedCommand(text)
        }
    }

    /// Edits a line in its own card: the original text, not a translation shown in its place.
    /// Typed straight in, with no buttons: Return, or the keyboard going away, saves it. Left
    /// empty, the line stays as it was.
    private func lineEditor(_ line: TranscriptLine) -> some View {
        // The field is a few points taller than the text, all of it below the glyphs: laid over the
        // same text, hidden, from the top, so the card keeps its size and the text does not move.
        Text(editText.isEmpty ? " " : editText)
            .font(.body.bold())
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) { lineField(line).fixedSize(horizontal: false, vertical: true) }
    }

    private func lineField(_ line: TranscriptLine) -> some View {
        TextField("", text: $editText, axis: .vertical)
            .font(.body.bold())
            .focused($editFocused)
            .submitLabel(.done)
            .accessibilityIdentifier("line-editor")
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { editorFrame = $0 }
            // A vertical field takes Return as a line break; a line has none, so it saves instead.
            .onChange(of: editText) { _, value in
                guard value.contains("\n") else { return }
                editText = value.replacingOccurrences(of: "\n", with: "")
                finishEditing(line)
            }
            // The keyboard put away, by scrolling or a tap elsewhere: what was typed is kept.
            .onChange(of: editFocused) { _, focused in
                if !focused { finishEditing(line) }
            }
    }

    /// Lifts the list until the card being edited sits just above the keyboard, when the keyboard
    /// covers any of it; again when the card grows a line. A card clear of it stays where it is.
    /// The card's frame is where it is drawn, lift included, so only the rest is added.
    private func liftEditedCard() {
        guard editingLineID != nil, let keyboardTop, editingCardFrame.height > 0 else { return }
        let covered = editingCardFrame.maxY - (keyboardTop - Self.rowGap)
        guard covered > 0.5 else { return }
        withAnimation(.easeOut(duration: 0.25)) { editLift += covered }
    }

    private func beginEditing(_ line: TranscriptLine, afterMenu: Bool = true) {
        editText = line.text
        editingLineID = line.id
        // After the context menu has closed, or the field is not there yet to take focus.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(afterMenu ? 350 : 50))
            if editingLineID == line.id { editFocused = true }
        }
    }

    private func finishEditing(_ line: TranscriptLine) {
        guard editingLineID == line.id else { return }
        editingCardFrame = .zero
        model.editLine(line, text: editText)
        editFocused = false
        editingLineID = nil
        withAnimation(.easeOut(duration: 0.25)) { editLift = 0 }
    }

    /// While `editing`, the field takes the main text's place and everything else stays, so
    /// nothing moves.
    private func transcriptText(_ primary: String, secondary: String?, note: String? = nil, editing: TranscriptLine? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let editing { lineEditor(editing) } else { Text(primary).font(.body.bold()) }
            if let secondary { Text(secondary).font(.subheadline).foregroundStyle(.secondary) }
            if let note { Text(LocalizedStringKey(note)).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func timestampLabel(_ label: String, live: Bool = false, mac: Bool = false) -> some View {
        Text(label.replacingOccurrences(of: " ", with: "\n"))
            .font(.system(.caption, design: .monospaced, weight: .bold))
            .foregroundStyle(mac ? VoicedPalette.macAccent : live ? Color.red : MobileTheme.timestamp)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Copied toast

    /// A small pill that fades in above the microphone after a copy and fades out on its own,
    /// matching the macOS window's confirmation. It sits at the bottom so it never covers the
    /// transcript that was just copied.
    private func toastView(_ toast: Toast) -> some View {
        Group {
            switch toast {
            case .copied: Label(model.strings.copied, systemImage: "checkmark")
            case .releaseToCancel: Label("松开手指，取消识别", systemImage: "xmark")
            case .sentToMac: Label("已发送到电脑", systemImage: "laptopcomputer")
            case .notSentToMac: Label("未连接电脑，未发送", systemImage: "laptopcomputer.slash")
            }
        }
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

    private func showCopiedToast() { show(.copied, for: .seconds(1.2)) }

    private func show(_ notice: Toast, for duration: Duration) {
        withAnimation(.easeOut(duration: 0.2)) { toast = notice }
        copiedToastResetTask?.cancel()
        copiedToastResetTask = Task {
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { toast = nil }
        }
    }

    private var emptyState: some View {
        Text(model.strings.emptyTitle)
            .accessibilityIdentifier("empty-transcript-prompt")
            .font(.callout.weight(.medium)).foregroundStyle(MobileTheme.accent)
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
                        // Down from the last load of this model when that is known, otherwise up.
                        Text(model.strings.loadingClock(startedAt: startedAt, expected: model.expectedLoadSeconds, now: context.date))
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

    private static let listTopID = "list-top"

    /// A finger landed on the microphone.
    private func micPressBegan() {
        guard !micTouching, !model.stopping else { return }
        micTouching = true
        micHolding = false
        micHoldTimer?.cancel()
        // A Whisper model is not loaded yet: the press, tap or hold, only loads it, and nothing
        // starts until the next press once it is ready. Apple Speech starts at once.
        micLoadOnly = !(model.recording || model.busy || model.previewActive) && model.pressOnlyLoadsModel
        if micLoadOnly {
            model.prepareModel()
            return
        }
        micHoldTimer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, micTouching, !model.previewActive, !model.stopping else { return }
            // A hold is never a tap, so it never stops a recording. It records a clip that is
            // transcribed whole once let go, and also sent to the Mac when "Send to Mac" is on.
            micHolding = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if !(model.recording || model.busy) { clearSearch() }
            scrollToTopRequest += 1
            model.beginHold()
        }
    }

    /// The finger left the microphone: a hold ends, anything shorter is a tap, unless the finger
    /// was dragged well away first or the touch was cancelled.
    private func micPressEnded(inside: Bool) {
        guard micTouching else { return }
        micTouching = false
        micOutside = false
        micHoldTimer?.cancel()
        micHoldTimer = nil
        if micLoadOnly {
            micLoadOnly = false
        } else if micHolding {
            micHolding = false
            // Let go away from the button (or the touch was cancelled): the hold is dropped.
            if inside { model.endHold() } else { model.cancelHold() }
        } else if inside {
            micTapped()
        }
    }

    /// A tap sends the command a hold left waiting; otherwise it starts or stops recording.
    private func micTapped() {
        guard !model.stopping else { return }
        scrollToTopRequest += 1
        if sendsCommand {
            show(model.sendPendingCommand() ? .sentToMac : .notSentToMac, for: .seconds(2))
        } else if model.recording || model.busy || model.previewActive {
            model.stop()
        } else if model.pressOnlyLoadsModel {
            // A Whisper model not loaded yet: only load it; the next tap, once it is ready, starts recording.
            model.prepareModel()
        } else {
            clearSearch()
            model.start()
        }
    }

    /// A previous search must not hide incoming live text or new sentences.
    private func clearSearch() {
        query = ""
        searching = false
        searchFocused = false
    }

    /// Whether the microphone is a send button: a hold's command waits and nothing else is under way.
    private var sendsCommand: Bool {
        model.pendingCommand != nil && !model.holding && !model.recognizingHold && !model.stopping
    }

    /// The dot beside the microphone, in the Mac's colours (statusColor in its ContentView): the
    /// accent while recording, grey while the model downloads or loads, red after a failure, green
    /// when ready. Light blue while held, which the Mac has no counterpart for, as what is said
    /// then goes to the Mac.
    private var statusColor: Color {
        if model.holding { return VoicedPalette.macAccent.opacity(0.6) }
        if model.busy { return .gray }
        if model.recording { return MobileTheme.accent }
        if model.modelLoading { return .gray }
        if model.error != nil { return .red }
        return .green
    }

    private var recordingControls: some View {
        VStack(spacing: 12) {
            // Also once a stop has left the model loading in the background.
            if model.busy || model.modelLoading {
                preparationBanner
                    .padding(.horizontal, 24)
            }
            HStack(spacing: 12) {
                // Equal side columns keep the microphone centered, as on macOS. With "Send to
                // machine" on, the left one has the button for where and how to send
                // (SendToMachineSheet), in its middle, without a ring and a little smaller than
                // the buttons above.
                Group {
                    if model.sendToMacEnabled {
                        Button { showMachines = true } label: {
                            Image(systemName: "laptopcomputer")
                                .font(.system(size: 20, weight: .regular))
                                // An outline, as in the microphone, rather than a grey screen.
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(MobileTheme.accent)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("电脑"))
                        .accessibilityValue(model.machineChoiceLabel(model.sendToMacTarget))
                        .accessibilityIdentifier("machine-button")
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                    }
                }
                // In the middle of the column, halfway between the edge and the microphone, then a
                // little towards the microphone, which looks better balanced.
                .offset(x: 12)
                .frame(maxWidth: .infinity)
                // One touch tracker decides between a tap and a hold, so a hold can never end as a
                // tap. A touch released before half a second is a tap: it starts or stops
                // recording, or, while a hold's command waits, sends it. Held longer, with "Send to
                // Mac" on, what is said until the release becomes a command for the Mac, left
                // waiting (and replacing one already waiting), whether or not a recording is
                // running; held from idle, it records just for the hold. The button underneath
                // only draws the ring.
                Button {} label: {
                    if model.stopping { ProgressView() }
                    else {
                        // Held: speaking into it, so it shows the microphone even over a running
                        // recording. A command waits: the Mac, as a tap sends it there (a hold
                        // records it again).
                        let send = !micHolding && sendsCommand
                        // Monochrome, so the laptop's screen stays an outline with the ring showing
                        // through, rather than a second, filled layer. The colours repeat
                        // RingButtonStyle's, which this has to set over.
                        let filled = micTouching && !micOutside && !micLoadOnly
                        Image(systemName: send ? "laptopcomputer"
                              : !micHolding && (model.recording || model.busy || model.previewActive) ? "stop.fill" : "mic.fill")
                            .font(.system(size: send ? 30 : 33, weight: .regular))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(filled ? Color.white : MobileTheme.accent)
                            .contentTransition(.symbolEffect(.replace))
                            // A play mark inside the laptop's screen: a tap runs the waiting
                            // command. The screen's inner centre sits half a point above the
                            // symbol's; the half point right centres the triangle by eye.
                            .overlay {
                                if send {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 10, weight: .regular))
                                        .foregroundStyle(filled ? Color.white : MobileTheme.accent)
                                        .offset(x: 0.5, y: -0.5)
                                        .transition(.opacity)
                                }
                            }
                    }
                }
                .buttonStyle(RingButtonStyle(size: Self.micSize, lineWidth: 2, held: micTouching && !micOutside && !micLoadOnly))
                .disabled(model.stopping)
                .allowsHitTesting(false)
                .overlay {
                    PressTracker(onBegan: micPressBegan, onMoved: { inside in withAnimation(.easeOut(duration: 0.15)) { micOutside = !inside } }, onEnded: micPressEnded)
                        .clipShape(Circle())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text(LocalizedStringKey(sendsCommand ? "发送到电脑" : model.recording ? "停止录音" : model.busy ? "取消准备" : "开始录音")))
                .accessibilityValue(Text(LocalizedStringKey(model.status)))
                .accessibilityAction { micTapped() }
                // VoiceOver's double-tap and hold passes the touch through, so holding works there too.
                .accessibilityHint(sendsCommand ? Text("按住重新录制")
                                   : model.sendToMacEnabled ? Text("按住说话，识别为发给电脑的命令") : Text("按住说话，松开后整段识别"))
                ZStack {
                    HStack {
                        #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                            // Lets UI tests see that a hold took effect, which a press cannot observe.
                            Text(verbatim: "\(model.holdCount)").font(.system(size: 1)).opacity(0.02)
                                .accessibilityIdentifier("ui-hold-count")
                        }
                        #endif
                        Circle().fill(statusColor)
                            .frame(width: 7, height: 7)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    // While a command waits, a button to give it up, placed as the machine button
                    // on the left is, mirrored: the microphone is the microphone again.
                    if sendsCommand {
                        Button { withAnimation(.easeOut(duration: 0.2)) { model.discardPendingCommand() } } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(MobileTheme.accent)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: -12)
                        .accessibilityLabel(Text("取消发送"))
                        .accessibilityIdentifier("discard-command")
                        .transition(.opacity)
                    }
                }.frame(maxWidth: .infinity)
            }
        }
        .padding(.top, Self.controlsTopPadding).padding(.bottom, Self.controlsBottomPadding)
        .overlay(alignment: .top) {
            if model.stopping {
                // Backed by the screen's colour, as cards may be scrolling behind it.
                Text(LocalizedStringKey(model.status)).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(MobileTheme.background, in: Capsule())
                    .padding(.horizontal, 24)
            }
        }
    }

}

extension View {
    func settingsSurface(title: String, large: Bool = false) -> some View {
        // The page's text is ink, set here on the page rather than on the whole navigation stack,
        // where it would also recolour the black large title.
        self.foregroundStyle(MobileTheme.ink)
            .scrollContentBackground(.hidden)
            .background(MobileTheme.background.ignoresSafeArea())
            .navigationTitle(Text(LocalizedStringKey(title)))
            .navigationBarTitleDisplayMode(large ? .large : .inline)
            .toolbarBackground(MobileTheme.background, for: .navigationBar)
            .tint(MobileTheme.accent)
    }
}

/// The input's current waveform, shaking in place as lo's radio card does: mirrored around the
/// centre line, a faint fill under a thin trace, about thirty frames a second.
private struct WaveformView: View {
    let meter: WaveformMeter
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            Canvas { context, size in
                _ = timeline.date // Redrawn every frame.
                let columns = meter.frame(columns: max(24, min(128, Int(size.width / 2))))
                let mid = size.height / 2
                let reach = size.height * 0.45
                let step = size.width / CGFloat(columns.count - 1)
                let points = columns.enumerated().map { CGPoint(x: CGFloat($0.offset) * step, y: max(0.02, $0.element) * reach) }
                var fill = Path()
                fill.move(to: CGPoint(x: 0, y: mid - points[0].y))
                for point in points { fill.addLine(to: CGPoint(x: point.x, y: mid - point.y)) }
                for point in points.reversed() { fill.addLine(to: CGPoint(x: point.x, y: mid + point.y)) }
                fill.closeSubpath()
                context.fill(fill, with: .color(color.opacity(0.22)))
                var trace = Path()
                trace.move(to: CGPoint(x: 0, y: mid - points[0].y))
                for point in points { trace.addLine(to: CGPoint(x: point.x, y: mid - point.y)) }
                context.stroke(trace, with: .color(color.opacity(0.72)),
                               style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// An AI note laid out like a transcript card, as on macOS: "AI" where a card has its timestamp,
/// the topic in purple and the note beside it. It has no close button: it leaves on its own once
/// it has been on screen long enough to read. A tap keeps it until tapped again.
private struct RunSheetID: Identifiable {
    let id: String
}

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
        .accessibilityHint(Text(LocalizedStringKey(pinned ? "已固定，轻点后自动消失" : "轻点可固定")))
    }

    /// "AI" and its symbol, in the timestamp's font; a pin under them while the note is kept.
    private var label: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("AI").font(.system(.caption, design: .monospaced, weight: .bold))
                Image(systemName: "sparkles").font(.caption.weight(.bold))
            }
            if pinned { Image(systemName: "pin.fill").font(.caption2) }
        }
        .foregroundStyle(VoicedPalette.aiAccent)
    }

    /// A little smaller than the transcript's text, as on macOS, and bold like it; the purple
    /// topic tells them apart.
    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hint.topic).font(.subheadline.bold()).foregroundStyle(VoicedPalette.aiAccent)
            Text(hint.text).font(.subheadline.bold()).foregroundStyle(MobileTheme.ink)
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
    /// The strip the list reaches up behind the header. Shown only at rest, when all it holds is
    /// the space above the first card, so a long press's shadow there is not cut off; hidden as
    /// soon as the list scrolls, so cards never show behind the header.
    var bleed: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Color.black.opacity(fade.offset > 0 ? 0 : 1).frame(height: bleed)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: fade.offset)
        }
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

/// Reports a touch the moment it lands and when it lifts, for a control that must tell a tap
/// from a hold itself. SwiftUI's own drag gesture reports the first touch late on a device, once
/// the finger has moved a little, so a hold timer started from it ran short and a press did not
/// show at once.
struct PressTracker: UIViewRepresentable {
    var onBegan: () -> Void
    /// Called when the finger crosses the view's edge (with its slack), with whether it is inside now.
    var onMoved: (_ inside: Bool) -> Void = { _ in }
    /// Called with whether the touch lifted inside the view; false when it was cancelled or left.
    var onEnded: (_ inside: Bool) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // VoiceOver reads and activates the SwiftUI element this sits on, not this view.
        view.isAccessibilityElement = false
        let recognizer = TouchRecognizer(target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.tracker = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(tracker: self) }

    final class Coordinator: NSObject {
        var tracker: PressTracker

        init(tracker: PressTracker) { self.tracker = tracker }

        @objc func changed(_ recognizer: TouchRecognizer) {
            switch recognizer.state {
            case .began: tracker.onBegan()
            case .changed:
                if recognizer.inside != recognizer.reportedInside {
                    recognizer.reportedInside = recognizer.inside
                    tracker.onMoved(recognizer.inside)
                }
            case .ended: tracker.onEnded(recognizer.endedInside)
            case .cancelled, .failed: tracker.onEnded(false)
            default: break
            }
        }
    }

    /// Begins on touch down, without waiting for movement, and ends on lift.
    final class TouchRecognizer: UIGestureRecognizer {
        private(set) var endedInside = false
        /// Whether the finger is within the view (with its slack) now.
        private(set) var inside = true
        /// What the tracker was last told, so it hears only of crossings.
        var reportedInside = true

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard state == .possible else { return }
            endedInside = false
            inside = true
            reportedInside = true
            state = .began
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first { inside = isInside(touch) }
            if state == .began || state == .changed { state = .changed }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first { endedInside = isInside(touch) }
            state = .ended
        }

        /// A little slack around the button, as a finger on it rarely stays exactly inside.
        private func isInside(_ touch: UITouch) -> Bool {
            guard let view else { return false }
            return view.bounds.insetBy(dx: -30, dy: -30).contains(touch.location(in: view))
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            state = .cancelled
        }

        override func reset() {
            endedInside = false
            inside = true
            reportedInside = true
        }
    }
}
