import VoicedCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: TranscriptionController
    @State private var isSettingsPresented = false
    /// Counts clicks on the settings button, so a click while settings are already open still
    /// brings their window to the front.
    @State private var settingsFocusRequest = 0
    @State private var isHistoryPresented = false
    /// Whether the search field sits under the header. Opening it focuses the field.
    @State private var isSearchPresented = false
    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool
    /// How far the transcript list has been scrolled down from its top. An observable object
    /// rather than plain state: only the top fade reads it, so scrolling redraws the fade alone
    /// and never rebuilds the rows.
    @State private var scrollFade = ScrollFadeState()
    /// The confirmation pill under the header: after a copy, or a command sent or not.
    @State private var toast: ToastContent?
    /// Whether the machine popover, from the button left of the record button, is open.
    @State private var isMachinesPresented = false
    /// The record button or Space is down; see `pressBegan`.
    @State private var pressing = false
    /// The press has lasted long enough to be a hold.
    @State private var pressHolding = false
    @State private var holdTimer: Task<Void, Never>?
    /// Whether the TYPE row is open, after a hold for the machine heard nothing.
    @State private var isTypingCommand = false
    /// Measured height of the model banner above the record button, 0 while there is none.
    @State private var preparationBannerHeight: CGFloat = 0
    @State private var copiedToastResetTask: Task<Void, Never>?
    /// The line whose text is being edited in its row, chosen from the row's menu.
    @State private var editingLineID: String?
    /// When the last edit ended, so the click that ended it does not also act on its row.
    @State private var editEndedAt: Date?

    private var strings: AppStrings { controller.strings }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isSearchPresented {
                searchField
            }
            // The list runs underneath the record button and fades out as rows slide beneath it.
            ZStack(alignment: .bottom) {
                transcriptList
                bottomControl
            }
        }
        // The hint sits at the center of the whole window, not just the list area.
        .overlay {
            if isTranscriptEmpty {
                emptyState
            }
        }
        // A copy is confirmed under the header; a send, just above the record button that sent it.
        .overlay(alignment: toast?.atBottom == true ? .bottom : .top) {
            if let toast {
                toastView(toast)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isSearchPresented)
        // A new record empties the list, which leaves nothing to search in.
        .onChange(of: controller.lines.isEmpty) { _, isEmpty in
            if isEmpty { closeSearch() }
        }
        .background(Theme.background)
        .background(WindowLevelSetter(isFloating: controller.keepWindowOnTop))
        // A hold for the machine that heard nothing: the command is typed instead.
        .onChange(of: controller.typeCommandRequests) {
            guard controller.sendToMacEnabled, !isTypingCommand else { return }
            closeSearch()
            withAnimation(.easeOut(duration: 0.2)) { isTypingCommand = true }
        }
        // Space, while this window has the focus and no text is being edited: a tap starts or
        // stops recording, a hold records one clip, as the record button does.
        .background(SpaceKeyMonitor(onDown: pressBegan, onUp: { pressEnded(inside: true) }))
        .modifier(TranslationHost(translator: controller.translator))
        .preferredColorScheme(.light)
        // No scroll bars anywhere in the window, even where the system would show them.
        .scrollIndicators(.never)
        // Not a sheet: a sheet hangs from the title bar and blocks the window. This is a separate
        // window centered on this one; both stay focusable.
        .background(
            SettingsWindowPresenter(
                isPresented: isSettingsPresented,
                focusRequest: settingsFocusRequest,
                isFloating: controller.keepWindowOnTop,
                size: SettingsView.windowSize
            ) {
                SettingsView(controller: controller, isPresented: $isSettingsPresented)
                    .scrollIndicators(.never)
            }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(strings.results)
                // Gill Sans ships with macOS; the system font stands in if it is ever missing.
                .font(.custom("GillSans-Bold", size: 28))
                .kerning(-0.5)
                .foregroundStyle(Theme.accent)
            Spacer()
            if case .failed = controller.phase {
                ToolbarIconButton(systemName: "arrow.clockwise", help: strings.retry, action: controller.retryPreparation)
            }
            ToolbarIconButton(systemName: "plus", help: strings.newRecord, action: controller.startNewRecord)
            ToolbarIconButton(systemName: "magnifyingglass", help: strings.search) {
                if isSearchPresented {
                    closeSearch()
                } else {
                    isSearchPresented = true
                    isSearchFocused = true
                }
            }
            .disabled(controller.lines.isEmpty)
            ToolbarIconButton(systemName: "clock.arrow.circlepath", help: strings.history) {
                isHistoryPresented = true
            }
            .disabled(controller.isRecording)
            .popover(isPresented: $isHistoryPresented, arrowEdge: .bottom) {
                HistoryView(controller: controller, isPresented: $isHistoryPresented) { query in
                    // The chosen record shows only its lines that match, as the history did.
                    searchQuery = query
                    isSearchPresented = true
                }
                .scrollIndicators(.never)
            }
            ToolbarIconButton(systemName: "gearshape", help: strings.settings) {
                isSettingsPresented = true
                settingsFocusRequest += 1
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        // Kept small so the list's scroll edge sits just under the header.
        .padding(.bottom, Self.headerBottomInset)
        .padding(.top, Self.headerTopInset)
    }

    // MARK: - Search

    /// A rounded field under the header, tinted like a transcript row. Typing narrows the list to
    /// the sentences containing the text; Escape closes the field and shows everything again.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            TextField("", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isSearchFocused)
                .onExitCommand(perform: closeSearch)
            Button(action: closeSearch) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(strings.close)
        }
        // The box spans the same width as the transcript rows, which reach 8 pt past the text
        // columns on each side, and its symbol lines up with their timestamps.
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accent.opacity(Theme.rowFillOpacity))
        )
        .padding(.horizontal, Theme.contentPadding - 8)
        .padding(.top, Self.headerGap)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func closeSearch() {
        isSearchPresented = false
        isSearchFocused = false
        searchQuery = ""
    }

    /// The text being searched for, or nil while the field is closed or empty.
    private var activeSearch: String? {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return isSearchPresented && !query.isEmpty ? query : nil
    }

    /// The committed lines shown, newest first: all of them, or the ones whose text in either
    /// language contains the search, ignoring case. Each comes with the texts its row shows,
    /// worked out here once so the rows compare by value and skip their own body when unchanged.
    private var visibleRows: [TranscriptRowModel] {
        let query = activeSearch
        return controller.lines.reversed().compactMap { line in
            let texts = controller.displayTexts(for: line)
            if let query,
               !texts.primary.localizedCaseInsensitiveContains(query),
               texts.secondary?.localizedCaseInsensitiveContains(query) != true {
                return nil
            }
            // A command waiting to be sent says so where its time would be.
            let delivery = controller.macDelivery(of: line)
            let waiting = controller.isUnsentMacCommand(line) && delivery == nil
            return TranscriptRowModel(
                line: line,
                timestamp: waiting ? "PROMPT" : controller.timestamp(for: line),
                primaryText: texts.primary,
                secondaryText: texts.secondary,
                mac: delivery ?? (waiting ? true : nil),
                notSentNote: delivery == false ? strings.notSentToMachine : nil
            )
        }
    }

    // MARK: - Transcript

    /// The hint is shown only while idle with nothing on screen; recording shows the LIVE row at once.
    private var isTranscriptEmpty: Bool {
        controller.lines.isEmpty && controller.liveText.isEmpty && !controller.isRecording
            && !isTypingCommand && !controller.holding && !controller.recognizingHold
    }

    @ViewBuilder
    private var transcriptList: some View {
        if isTranscriptEmpty {
            Color.clear
        } else {
            let rows = visibleRows
            VStack(spacing: 0) {
                // The LIVE row leads the list and committed sentences follow newest first, so the
                // newest text sits at the top without any scrolling.
                // Lazy, so a long meeting's thousands of rows are only laid out as they scroll
                // into view. A LazyVStack once hung the app: its content size flipped between
                // height estimates while the scroll offset, then plain state, rebuilt the whole
                // list on every point scrolled. The offset now reaches only the top fade, so
                // scrolling never touches the rows.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.rowGap) {
                        // The AI's notes lead the list, newest first, above the LIVE row. Each
                        // leaves once it has been on screen long enough to be read.
                        // While searching, only the matching sentences are listed: the hints and
                        // the LIVE row would push the results down.
                        if activeSearch == nil {
                            ForEach(controller.hints.reversed()) { hint in
                                HintRow(hint: hint, timestampWidth: timestampWidth, dismissHelp: strings.close) {
                                    controller.dismiss(hint)
                                }
                            }
                            if controller.holding || controller.recognizingHold {
                                // A hold shows its speech as a waveform, then its text once let go.
                                SpeechRow(controller: controller, waveform: controller.waveform, timestampWidth: timestampWidth)
                            } else if controller.isRecording || !controller.liveText.isEmpty {
                                LiveRow(text: controller.liveText, timestampWidth: timestampWidth)
                            }
                            if isTypingCommand {
                                CommandDraftRow(timestampWidth: timestampWidth) { text in
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        isTypingCommand = false
                                        if let text { controller.addTypedCommand(text) }
                                    }
                                }
                                .transition(.opacity)
                            }
                        }
                        ForEach(rows) { row in
                            TranscriptRow(
                                model: row,
                                timestampWidth: timestampWidth,
                                isPlaying: controller.playingLineID == row.id,
                                isEditing: editingLineID == row.id,
                                onTap: { tap(row.line) },
                                onEndEditing: { endEditing(row.line, text: $0) }
                            )
                            // Compared by value, closure aside, so a row whose texts are the same
                            // keeps its body when the list is rebuilt for a new LIVE text or line.
                            .equatable()
                            .contextMenu { lineMenu(row.line) }
                            // The machine's Claude Code run of a line sent with Run, under it.
                            if let run = controller.claudeRun(forLine: row.id) {
                                ClaudeRunRow(controller: controller, run: run, timestampWidth: timestampWidth)
                            }
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: controller.hints)
                    .padding(.horizontal, Theme.contentPadding)
                    // The first row sits the same gap below the search field, or the header
                    // buttons, as the rows keep between themselves.
                    .padding(.top, isSearchPresented ? Theme.rowGap : Self.headerGap)
                    // Room to scroll the last row clear of the record button, leaving the same
                    // gap above the button as between the header and the first row.
                    .padding(.bottom, Self.listBottomInset + bottomExtraInset)
                }
                .scrollIndicators(.never)
                .modifier(ScrollOffsetReader(fade: scrollFade, limit: Self.topFadeHeight))
                .mask(
                    VStack(spacing: 0) {
                        TopFade(fade: scrollFade)
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.bottomFadeHeight)
                        Color.clear
                            .frame(height: Self.hiddenHeight + bottomExtraInset)
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Gap between the list's bottom edge and the last row, above the record button when
    /// scrolled to the end.
    private static let rowEdgeGap: CGFloat = 14
    /// Space added under the header so the header buttons and what comes next, the search field
    /// or the first row, are as far apart as two rows; the header's own bottom inset makes up the rest.
    private static let headerGap: CGFloat = Theme.rowGap - headerBottomInset
    /// Rows fade out over this strip at the top edge once they scroll under the header.
    private static let topFadeHeight: CGFloat = 120
    /// Rows are fully hidden across the lower half of the button area…
    private static let hiddenHeight: CGFloat = edgeInset + recordButtonSize / 2
    /// …and fade out between the last row's resting place and that hidden strip.
    private static let bottomFadeHeight: CGFloat = listBottomInset - hiddenHeight
    /// The last row stops this far above the list's bottom edge: clear of the record button, with
    /// nearly the same gap above it as the header leaves above the first row. The button's round
    /// shape reads as extra space, so the row sits a little closer than the top gap.
    private static let listBottomInset: CGFloat = edgeInset + recordButtonSize + headerBottomInset + rowEdgeGap - 5
    /// Extra room at the bottom while the model banner sits above the record button.
    private var bottomExtraInset: CGFloat {
        controller.isPreparing && preparationBannerHeight > 0 ? preparationBannerHeight + Self.preparationBannerGap : 0
    }

    private var timestampWidth: CGFloat {
        controller.timestampMode == .current && controller.showTimestampDate ? 78 : 66
    }

    /// A click plays from the line when clicking plays and nothing is being recognized, and stops
    /// the playback, whichever row is clicked, while one runs. While recording a click copies,
    /// as it always did.
    /// A row's menu, opened by a right-click or Control-click: the same actions as a sentence's
    /// menu on the iPhone, less sending to the Mac.
    @ViewBuilder
    private func lineMenu(_ line: TranscriptLine) -> some View {
        Button(strings.copy, systemImage: "doc.on.doc") {
            controller.copy(line)
            showToast(.copied(strings))
        }
        Button(strings.playFromRow, systemImage: "play") {
            if controller.playingLineID != nil { controller.stopPlayback() }
            controller.togglePlayback(of: line, onlyLine: false)
        }
        .disabled(!controller.canPlay(from: line))
        Button(strings.edit, systemImage: "pencil") { editingLineID = line.id }
        // Only for a command (a blue line, waiting or already sent, to send again).
        if controller.sendToMacEnabled, controller.isUnsentMacCommand(line) || controller.macDelivery(of: line) != nil {
            Button(strings.sendCommand, systemImage: "laptopcomputer") {
                showToast(controller.sendLineToMac(line) ? .sent(strings) : .notSent(strings))
            }
        }
        Divider()
        Button(role: .destructive) {
            withAnimation(.easeOut(duration: 0.2)) { controller.deleteLine(line) }
        } label: {
            DeleteMenuLabel(title: strings.delete)
        }
    }

    /// Ends the edit of `line`'s row, keeping `text`, or the old text when nil. Only the first
    /// end counts: Return or Escape is followed by the field losing focus.
    private func endEditing(_ line: TranscriptLine, text: String?) {
        guard editingLineID == line.id else { return }
        editingLineID = nil
        editEndedAt = Date()
        if let text { controller.editLine(line, text: text) }
    }

    private func tap(_ line: TranscriptLine) {
        // A click on another row while editing only ends the edit. The field may already have
        // lost focus, and ended it, when the button went down, before this click arrives.
        if editingLineID != nil {
            NSApp.keyWindow?.makeFirstResponder(nil)
            return
        }
        if let editEndedAt, Date().timeIntervalSince(editEndedAt) < 0.5 { return }
        if controller.lineClickAction.plays, !controller.isRecording {
            controller.togglePlayback(of: line, onlyLine: controller.lineClickAction == .play)
        } else {
            controller.copy(line)
            showToast(.copied(strings))
        }
    }

    private var emptyState: some View {
        Text(strings.emptyTitle)
            .font(.title3.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(Theme.contentPadding)
            .offset(y: -5)
            .allowsHitTesting(false)
    }

    // MARK: - Copied toast

    /// A small pill that fades in just under the header after a copy and fades out on its own.
    private func toastView(_ toast: ToastContent) -> some View {
        Label(toast.text, systemImage: toast.symbol)
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accentDark.opacity(0.9)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Theme.accentDark.opacity(0.25), radius: 6, x: 0, y: 3)
            )
            .padding(.top, toast.atBottom ? 0 : Self.toastTopInset)
            .padding(.bottom, toast.atBottom ? Self.toastBottomInset : 0)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    /// Distance from the window's top edge to the toast: just below the header row.
    private static let toastTopInset: CGFloat = headerTopInset + 36 + 12
    /// Distance from the window's bottom edge to a bottom toast: just above the record button.
    private static let toastBottomInset: CGFloat = edgeInset + recordButtonSize + 12

    private func showToast(_ content: ToastContent) {
        withAnimation(.easeOut(duration: 0.2)) { toast = content }
        copiedToastResetTask?.cancel()
        copiedToastResetTask = Task {
            try? await Task.sleep(for: content.duration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { toast = nil }
        }
    }

    // MARK: - Bottom bar

    /// Gap between the window's top edge and the header.
    private static let headerTopInset: CGFloat = 8
    /// Gap between the header and the list's top edge.
    private static let headerBottomInset: CGFloat = 4
    /// Gap between the window's bottom edge and the record button.
    private static let edgeInset: CGFloat = 18
    private static let recordButtonSize: CGFloat = 72

    private var bottomControl: some View {
        VStack(spacing: Self.preparationBannerGap) {
            if controller.isPreparing {
                preparationBanner
            }
            // The side buttons sit a fixed distance from the record button, whatever the
            // window's width: the gaps are those of the default window. With "Send to Machine"
            // on, the left one is the button for where and how to send, without a ring and a
            // little smaller than the header buttons.
            HStack(spacing: Self.sideButtonGap) {
                Group {
                    if controller.sendToMacEnabled {
                        machineButton
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                    }
                }
                recordButton
                    .overlay(alignment: .trailing) {
                        statusDot
                            .offset(x: 20)
                    }
                // While a command waits, a button to give it up, placed as the machine button
                // on the left is, mirrored: the record button records again.
                Group {
                    if controller.sendsCommand {
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { controller.discardPendingCommand() }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(strings.discardCommand)
                        .transition(.opacity)
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                    }
                }
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Self.edgeInset)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: controller.isPreparing)
    }

    private static let preparationBannerGap: CGFloat = 12
    /// Between the record button's ring and the 44 pt buttons beside it.
    private static let sideButtonGap: CGFloat = 32
    /// Space between the banner's edge and its content, and between the rows inside it.
    private static let preparationBannerPadding: CGFloat = 12
    private static let progressBarHeight: CGFloat = 6

    /// What the model is doing before recognition can start: the phase text over a progress bar,
    /// filled to the downloaded fraction, or sweeping while the model loads into memory. The bar
    /// is drawn here rather than with `ProgressView`, whose control is taller than the bar it
    /// shows, so the rows sit at even distances from each other and from the banner's edges. The
    /// banner sizes itself to its rows and reports its height so the list can make room for it.
    private var preparationBanner: some View {
        VStack(spacing: Self.preparationBannerPadding) {
            Text(controller.phaseLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 10) {
                Group {
                    if case .downloading(let fraction) = controller.phase {
                        ProgressBar(fraction: fraction)
                    } else {
                        ProgressBar(fraction: nil)
                    }
                }
                .frame(height: Self.progressBarHeight)
                // The download percentage is already in the label above the bar.
                if case .loading = controller.phase, let startedAt = controller.loadingStartedAt {
                    // Ticks once a second so the user can see the load is alive: down from the last
                    // load of this model when that is known, otherwise up.
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(strings.loadingClock(startedAt: startedAt, expected: controller.expectedLoadSeconds, now: context.date))
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Theme.accentDark)
                            .fixedSize()
                    }
                }
            }
            if case .loading = controller.phase {
                Text(strings.loadingModelHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Self.preparationBannerPadding)
        .frame(width: 300)
        // The row tint over the window's own colour: the same shade as before, but solid, so
        // rows scrolling beneath the banner do not show through it.
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent.opacity(Theme.rowFillOpacity))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.background)
                )
        )
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: BannerHeightKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(BannerHeightKey.self) { preparationBannerHeight = $0 }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// Where and how to send: the machine, Type or Run, and their settings, in a popover.
    private var machineButton: some View {
        Button { isMachinesPresented = true } label: {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 20, weight: .regular))
                // An outline, as in the record button, rather than a grey screen.
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(controller.machineChoiceLabel(controller.sendToMacTarget))
        .popover(isPresented: $isMachinesPresented, arrowEdge: .top) {
            SendToMachinePanel(controller: controller)
        }
    }

    /// The press tracker over the button decides between a click and a hold, as Space does, so a
    /// hold never ends as a click. The button underneath only draws the ring.
    private var recordButton: some View {
        Button {} label: {
            // Held: speaking into it, so it shows the microphone even over a running recording.
            // A command waits: the machine, as a click sends it there (a hold records it again).
            let send = !pressHolding && controller.sendsCommand
            let filled = pressing
            Image(systemName: send ? "laptopcomputer"
                  : !pressHolding && (controller.isRecording || controller.isPreparing) ? "stop.fill" : "mic.fill")
                .font(.system(size: send ? 26 : 28, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(filled ? Color.white : Theme.accent)
                .contentTransition(.symbolEffect(.replace))
                // A play mark inside the laptop's screen: a click runs the waiting command.
                .overlay {
                    if send {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .regular))
                            .foregroundStyle(filled ? Color.white : Theme.accent)
                            .offset(x: 0.5, y: -0.5)
                            .transition(.opacity)
                    }
                }
        }
        // A thin ring, filled black only while pressed, as on iOS.
        .buttonStyle(RingButtonStyle(size: Self.recordButtonSize, symbolSize: 28, lineWidth: 2, held: pressing))
        .allowsHitTesting(false)
        .overlay {
            Circle()
                .fill(Color.clear)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in if !pressing { pressBegan() } }
                        .onEnded { drag in
                            let radius = Self.recordButtonSize / 2
                            let dx = drag.location.x - radius, dy = drag.location.y - radius
                            pressEnded(inside: dx * dx + dy * dy <= radius * radius * 1.4)
                        }
                )
        }
        .help(recordButtonHelp)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(recordButtonLabel)
        .accessibilityAction { tapped() }
    }

    private var recordButtonLabel: String {
        if controller.sendsCommand { return strings.sendCommand }
        if controller.isRecording { return strings.stopRecognition }
        if controller.isPreparing { return strings.cancel }
        return strings.startRecognition
    }

    private var recordButtonHelp: String {
        recordButtonLabel + "\n" + strings.spaceBarHint
    }

    /// The record button or Space went down. Held for half a second, it is a hold: what is said
    /// until it is let go is one clip, recognised whole. With the model not in memory yet, a
    /// press only does what a click does, which loads it.
    private func pressBegan() {
        guard !pressing else { return }
        pressing = true
        pressHolding = false
        holdTimer?.cancel()
        guard controller.modelReady || controller.isRecording, !controller.isPreparing else { return }
        holdTimer = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, pressing, !controller.preview.isActive else { return }
            pressHolding = true
            closeSearch()
            controller.beginHold()
        }
    }

    /// The record button or Space was let go: a hold ends, anything shorter is a click.
    private func pressEnded(inside: Bool) {
        guard pressing else { return }
        pressing = false
        holdTimer?.cancel()
        holdTimer = nil
        if pressHolding {
            pressHolding = false
            controller.endHold()
        } else if inside {
            tapped()
        }
    }

    /// A click sends the command a hold left waiting; otherwise it starts or stops recording, or
    /// cancels a model load.
    private func tapped() {
        if controller.sendsCommand {
            showToast(controller.sendPendingCommand() ? .sent(strings) : .notSent(strings))
        } else {
            if !controller.isRecording { closeSearch() }
            controller.toggleRecording()
        }
    }

    /// A small dot to the right of the record button; the phase text lives in its tooltip.
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .help(controller.phaseLabel)
    }

    private var statusColor: Color {
        // Held: blue while speaking into a hold, as on the iPhone.
        if controller.holding { return VoicedPalette.macAccent.opacity(0.6) }
        return switch controller.phase {
        case .recording: Theme.accent
        case .ready: .green
        case .failed: .red
        case .downloading, .loading: .gray
        }
    }
}

// MARK: - Components

private struct BannerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A capsule progress bar of exactly the height it is given: filled to `fraction`, or, when the
/// fraction is unknown, a short segment sweeping back and forth. The sweep is driven by the clock
/// rather than a repeating state animation: the bar's width changes while it is on screen (the
/// elapsed label appears beside it once a load starts), and a repeating animation begun at the
/// old width keeps sliding the segment to the old end, out past the track.
private struct ProgressBar: View {
    let fraction: Double?

    /// One sweep from one end to the other.
    private static let sweepDuration: TimeInterval = 1.1

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.accent.opacity(0.25))
                if let fraction {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(0, min(1, fraction)) * width)
                        .animation(.linear(duration: 0.2), value: fraction)
                } else {
                    let segment = width * 0.3
                    TimelineView(.animation) { context in
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: segment)
                            .offset(x: Self.sweepOffset(at: context.date) * (width - segment))
                    }
                }
            }
            .clipShape(Capsule())
        }
    }

    /// Where the sweeping segment sits at `date`, as 0...1 of its travel, easing in and out at
    /// each end like the state animation it replaces.
    static func sweepOffset(at date: Date) -> CGFloat {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: sweepDuration * 2)
        let linear = cycle < sweepDuration ? cycle / sweepDuration : 2 - cycle / sweepDuration
        return CGFloat(0.5 - cos(linear * .pi) / 2)
    }
}

/// A small round ring button, styled like the record button: black only while pressed.
private struct ToolbarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: { if isEnabled { action() } }) {
            Image(systemName: systemName)
        }
        .buttonStyle(RingButtonStyle(size: 36, symbolSize: 15))
        // The system also dims disabled buttons, which stacked with our fade made them too
        // faint. Keep the button enabled for the system, gate the action ourselves, and apply
        // a single controlled fade.
        .environment(\.isEnabled, true)
        .opacity(isEnabled ? 1 : Self.disabledOpacity)
        .help(help)
    }

    private static let disabledOpacity: Double = 0.6
}

/// What a transcript row shows for one line: the line itself, for the tap, and the texts already
/// worked out from it, so the row can be compared by value.
private struct TranscriptRowModel: Identifiable, Equatable {
    let line: TranscriptLine
    let timestamp: String
    let primaryText: String
    /// The sentence in the other language, shown small and grey under the main text.
    let secondaryText: String?
    /// For a line sent to a machine or waiting to be: whether it went out (blue either way);
    /// nil for every other line.
    var mac: Bool? = nil
    /// Under a line that could not be sent.
    var notSentNote: String? = nil

    var id: String { line.id }
}

private struct TranscriptRow: View, Equatable {
    let model: TranscriptRowModel
    let timestampWidth: CGFloat
    /// Whether the row's audio is being heard; the row then keeps its hover tint.
    let isPlaying: Bool
    /// Whether the sentence is shown as a field to edit it in place.
    let isEditing: Bool
    let onTap: () -> Void
    /// Called with the edited text on Return or when the field loses focus, nil on Escape.
    let onEndEditing: (String?) -> Void

    @State private var isHovering = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    /// Everything but the closures, which SwiftUI could not compare and which only ever do the
    /// same thing for the same line.
    static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.model == rhs.model && lhs.timestampWidth == rhs.timestampWidth && lhs.isPlaying == rhs.isPlaying
            && lhs.isEditing == rhs.isEditing
    }

    /// Grey, or blue for a line sent to a machine, deeper while hovered or playing.
    private var rowFill: Color {
        let active = isHovering || isPlaying
        if model.mac != nil { return VoicedPalette.macAccent.opacity(active ? 0.22 : 0.14) }
        return Theme.accent.opacity(active ? Theme.rowFillHoverOpacity : Theme.rowFillOpacity)
    }

    private var timestampPieces: [String] {
        model.timestamp.split(separator: " ").map(String.init)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.rowSpacing) {
            // "2026-10-18 09:05:07" is too wide for one line, so the date and time are
            // stacked. The column has the same fixed height as the LIVE label so rows keep
            // one height whichever label they show, and it sits vertically centred on the sentence.
            VStack(alignment: .leading, spacing: Theme.timestampLineSpacing) {
                ForEach(Array(timestampPieces.enumerated()), id: \.offset) { _, piece in
                    Text(piece)
                }
            }
            .font(.system(.caption, design: .monospaced).weight(model.mac != nil ? .bold : .medium))
            .foregroundStyle(model.mac != nil ? VoicedPalette.macAccent : Theme.timestamp)
            .frame(width: timestampWidth, height: Theme.timestampColumnHeight, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.secondaryTextGap) {
                if isEditing {
                    // The sentence itself is edited, whichever text the row shows first.
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: Theme.bodyFontSize))
                        .focused($isFieldFocused)
                        .onSubmit { onEndEditing(draft) }
                        .onExitCommand { onEndEditing(nil) }
                        .onAppear {
                            draft = model.line.text
                            isFieldFocused = true
                            // A focused field selects all its text; put the cursor at the end
                            // instead, once the field editor has taken focus.
                            DispatchQueue.main.async {
                                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
                            }
                        }
                        .onChange(of: isFieldFocused) { _, focused in
                            if !focused { onEndEditing(draft) }
                        }
                } else {
                    Text(model.primaryText)
                        .font(.system(size: Theme.bodyFontSize))
                }
                if !isEditing, let secondaryText = model.secondaryText {
                    Text(secondaryText)
                        .font(.system(size: Theme.secondaryFontSize))
                        .foregroundStyle(.secondary)
                }
                if let note = model.notSentNote {
                    Text(note)
                        .font(.system(size: Theme.secondaryFontSize))
                        .foregroundStyle(VoicedPalette.macAccent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowFill)
        )
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // A click while editing places the cursor rather than copying or playing the line.
        .onTapGesture { if !isEditing { onTap() } }
    }
}

/// A row above the LIVE row with one of the AI's notes: an "AI" label in the timestamp column,
/// then the topic in purple over the explanation, both a little under the transcript's text size, on a purple tint. A close button appears while
/// hovered. The row dismisses itself after the hint's reading time, counted from when it
/// appeared or from when the pointer last left it, so a hint being read is not taken away.
private struct HintRow: View {
    let hint: TranscriptHint
    let timestampWidth: CGFloat
    let dismissHelp: String
    let onDismiss: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.rowSpacing) {
            HStack(spacing: 4) {
                Text("AI")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.aiAccent)
            // The column keeps the fixed height of every row's label, symbol or not.
            .frame(width: timestampWidth, height: Theme.timestampColumnHeight, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.secondaryTextGap) {
                // Both a little smaller than the transcript's text; the purple topic tells them apart.
                Text(hint.topic)
                    .font(.system(size: Theme.hintFontSize))
                    .foregroundStyle(Theme.aiAccent)
                Text(hint.text)
                    .font(.system(size: Theme.hintFontSize))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    // Pinned so the row's height does not depend on the symbol's own metrics.
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(dismissHelp)
            .opacity(isHovering ? 1 : 0)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.aiAccent.opacity(isHovering ? Theme.rowFillHoverOpacity : Theme.rowFillOpacity))
        )
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Leaving the row starts a fresh countdown; hovering cancels the one running.
        .task(id: isHovering) {
            guard !isHovering else { return }
            try? await Task.sleep(for: .seconds(hint.readingTime))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// What the toast says: the text and its symbol, and how long it stays.
private struct ToastContent: Equatable {
    let text: String
    let symbol: String
    var duration: Duration = .seconds(1.2)
    /// Shown above the record button rather than under the header.
    var atBottom = false

    static func copied(_ strings: AppStrings) -> ToastContent { .init(text: strings.copied, symbol: "checkmark") }
    static func sent(_ strings: AppStrings) -> ToastContent { .init(text: strings.sentToMachine, symbol: "laptopcomputer", duration: .seconds(2), atBottom: true) }
    static func notSent(_ strings: AppStrings) -> ToastContent { .init(text: strings.notSentToMachine, symbol: "laptopcomputer.slash", duration: .seconds(2), atBottom: true) }
}

/// The row a hold opens above the transcript, in place of LIVE: its speech as a waveform while
/// held, then "Recognizing…" while the clip is transcribed. Blue when it records a command for
/// a machine, otherwise grey like the other rows.
private struct SpeechRow: View {
    @ObservedObject var controller: TranscriptionController
    let waveform: WaveformMeter
    let timestampWidth: CGFloat

    var body: some View {
        let mac = controller.liveForMac
        HStack(alignment: .center, spacing: Theme.rowSpacing) {
            Text("SPEECH")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(mac ? VoicedPalette.macAccent : .red)
                .frame(width: timestampWidth, height: Theme.timestampColumnHeight, alignment: .leading)
            Group {
                if controller.holding {
                    WaveformView(meter: waveform, color: mac ? VoicedPalette.macAccent : Theme.accent.opacity(0.5))
                        .frame(height: 28)
                } else {
                    // The rows' own type, grey as the LIVE text is.
                    Text(controller.strings.recognizingClip)
                        .font(.system(size: Theme.bodyFontSize))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(mac ? VoicedPalette.macAccent.opacity(0.14) : Theme.accent.opacity(Theme.rowFillOpacity))
        )
        .padding(.horizontal, -8)
    }
}

/// Space as the record button, while its window is the key window and no text is being edited
/// (a field editor would have the focus then). Repeats are swallowed; losing the focus mid-press
/// counts as letting go, since the key-up would go to another window.
private struct SpaceKeyMonitor: NSViewRepresentable {
    let onDown: () -> Void
    let onUp: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDown = onDown
        context.coordinator.onUp = onUp
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onDown: onDown, onUp: onUp) }

    final class Coordinator {
        var onDown: () -> Void
        var onUp: () -> Void
        weak var view: NSView?
        private var monitor: Any?
        private var resignObserver: NSObjectProtocol?
        private var isDown = false

        init(onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
            self.onDown = onDown
            self.onUp = onUp
        }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, self.isDown, note.object as? NSWindow === self.view?.window else { return }
                self.isDown = false
                self.onUp()
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            monitor = nil
            resignObserver = nil
        }

        /// Whether the event was Space for this window, and so handled here.
        private func handle(_ event: NSEvent) -> Bool {
            guard event.keyCode == 49, let window = view?.window, event.window === window else { return false }
            if event.type == .keyUp {
                guard isDown else { return false }
                isDown = false
                onUp()
                return true
            }
            if event.isARepeat { return isDown }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard modifiers.isEmpty, !(window.firstResponder is NSText) else { return false }
            isDown = true
            onDown()
            return true
        }
    }
}

/// The blue row a hold for the machine opens when it heard nothing: what is typed becomes the
/// command, a blue line waiting to be sent as a spoken one would. Return, or the field losing
/// focus, adds it; Escape, or leaving it empty, just closes the row.
private struct CommandDraftRow: View {
    let timestampWidth: CGFloat
    /// Called once, with the text, or nil when the row is closed without one.
    let onFinish: (String?) -> Void

    @State private var text = ""
    @State private var finished = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.rowSpacing) {
            Text("TYPE")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(VoicedPalette.macAccent)
                .frame(width: timestampWidth, height: Theme.timestampColumnHeight, alignment: .leading)
            // No placeholder: the TYPE label and the cursor say what the row is for.
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.bodyFontSize))
                .focused($isFocused)
                .onSubmit { finish(text) }
                .onExitCommand { finish(nil) }
                .onChange(of: isFocused) { _, focused in
                    if !focused { finish(text) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(VoicedPalette.macAccent.opacity(0.14))
        )
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear {
            // Once the field is there to take the focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { isFocused = true }
        }
    }

    private func finish(_ value: String?) {
        guard !finished else { return }
        finished = true
        onFinish(value)
    }
}

private struct LiveRow: View {
    let text: String
    let timestampWidth: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: Theme.rowSpacing) {
            Text("LIVE")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .foregroundStyle(.red)
                .frame(width: timestampWidth, height: Theme.timestampColumnHeight, alignment: .leading)
            Text(text)
                .font(.system(size: Theme.bodyFontSize))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        // The box reaches 8 pt past the text columns on each side, like the hover highlight on
        // transcript rows, so the LIVE label and timestamps below it stay aligned.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accent.opacity(Theme.rowFillOpacity))
        )
        .padding(.horizontal, -8)
    }
}

/// How far the transcript list has scrolled down from its top, as far as the top fade cares.
/// Observable so that only the view reading `offset` redraws when it changes.
@Observable
private final class ScrollFadeState {
    var offset: CGFloat = 0
}

/// The top of the list's mask: the fade only exists once rows have scrolled under the edge,
/// growing with the scroll offset so the newest rows are not dimmed at rest. Reading the offset
/// here, in its own view, keeps the rest of the window out of each scroll update.
private struct TopFade: View {
    let fade: ScrollFadeState

    var body: some View {
        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
            .frame(height: fade.offset)
    }
}

/// Reports how far a scroll view has scrolled down from its top, in whole points and clamped to
/// `0...limit`. Needs macOS 15; on macOS 14 the offset stays at zero, which only disables the top fade.
///
/// The value only changes when the fade would visibly change: scrolling deep into the list or
/// sub-point jitter writes nothing.
private struct ScrollOffsetReader: ViewModifier {
    let fade: ScrollFadeState
    let limit: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
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
