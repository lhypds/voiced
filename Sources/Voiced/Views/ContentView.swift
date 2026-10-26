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
    @State private var showsCopiedToast = false
    /// Measured height of the model banner above the record button, 0 while there is none.
    @State private var preparationBannerHeight: CGFloat = 0
    @State private var copiedToastResetTask: Task<Void, Never>?

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
        .overlay(alignment: .top) {
            if showsCopiedToast {
                copiedToast
            }
        }
        .animation(.easeOut(duration: 0.15), value: isSearchPresented)
        // A new record empties the list, which leaves nothing to search in.
        .onChange(of: controller.lines.isEmpty) { _, isEmpty in
            if isEmpty { closeSearch() }
        }
        .background(Theme.background)
        .background(WindowLevelSetter(isFloating: controller.keepWindowOnTop))
        .modifier(TranslationHost(translator: controller.translator))
        .preferredColorScheme(.light)
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
                HistoryView(controller: controller, isPresented: $isHistoryPresented)
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
        .padding(.top, Self.rowEdgeGap - Self.headerBottomInset)
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
            return TranscriptRowModel(
                line: line,
                timestamp: controller.timestamp(for: line),
                primaryText: texts.primary,
                secondaryText: texts.secondary
            )
        }
    }

    // MARK: - Transcript

    /// The hint is shown only while idle with nothing on screen; recording shows the LIVE row at once.
    private var isTranscriptEmpty: Bool {
        controller.lines.isEmpty && controller.liveText.isEmpty && !controller.isRecording
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
                            if controller.isRecording || !controller.liveText.isEmpty {
                                LiveRow(text: controller.liveText, timestampWidth: timestampWidth)
                            }
                        }
                        ForEach(rows) { row in
                            TranscriptRow(
                                model: row,
                                timestampWidth: timestampWidth,
                                isPlaying: controller.playingLineID == row.id,
                                onTap: { tap(row.line) }
                            )
                            // Compared by value, closure aside, so a row whose texts are the same
                            // keeps its body when the list is rebuilt for a new LIVE text or line.
                            .equatable()
                        }
                    }
                    .animation(.easeOut(duration: 0.25), value: controller.hints)
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.top, Self.rowEdgeGap)
                    // Room to scroll the last row clear of the record button, leaving the same
                    // gap above the button as between the header and the first row.
                    .padding(.bottom, Self.listBottomInset + bottomExtraInset)
                }
                .scrollIndicators(.hidden)
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

    /// Gap between the list's edge and the nearest row: below the header at rest, and above the
    /// record button when scrolled to the end.
    private static let rowEdgeGap: CGFloat = 14
    /// Rows fade out over this strip at the top edge once they scroll under the header.
    private static let topFadeHeight: CGFloat = 120
    /// Rows are fully hidden across the lower half of the button area…
    private static let hiddenHeight: CGFloat = edgeInset + recordButtonSize / 2
    /// …and fade out between the last row's resting place and that hidden strip.
    private static let bottomFadeHeight: CGFloat = listBottomInset - hiddenHeight
    /// The last row stops this far above the list's bottom edge: clear of the record button, with
    /// nearly the same gap above it as the header leaves above the first row. The button's shadow
    /// and round shape read as extra space, so the row sits a little closer than the top gap.
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
    private func tap(_ line: TranscriptLine) {
        if controller.lineClickAction == .play, !controller.isRecording {
            controller.togglePlayback(of: line)
        } else {
            controller.copy(line)
            showCopiedToast()
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
    private var copiedToast: some View {
        Label(strings.copied, systemImage: "checkmark")
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
            .padding(.top, Self.toastTopInset)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    /// Distance from the window's top edge to the toast: just below the header row.
    private static let toastTopInset: CGFloat = headerTopInset + 36 + 12

    private func showCopiedToast() {
        withAnimation(.easeOut(duration: 0.2)) { showsCopiedToast = true }
        copiedToastResetTask?.cancel()
        copiedToastResetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { showsCopiedToast = false }
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
            recordButton
                .overlay(alignment: .trailing) {
                    statusDot
                        .offset(x: 20)
                }
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Self.edgeInset)
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.2), value: controller.isPreparing)
    }

    private static let preparationBannerGap: CGFloat = 12
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
                    // Ticks once a second so the user can see the load is alive.
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(strings.elapsed(max(0, Int(context.date.timeIntervalSince(startedAt)))))
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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent.opacity(Theme.rowFillOpacity))
        )
        .background(
            GeometryReader { geometry in
                Color.clear.preference(key: BannerHeightKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(BannerHeightKey.self) { preparationBannerHeight = $0 }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var recordButton: some View {
        Button(action: controller.toggleRecording) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accentDark.opacity(0.9)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Theme.accentDark.opacity(0.2), radius: 4, x: 0, y: 2)
                Image(systemName: controller.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: Self.recordButtonSize, height: Self.recordButtonSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!controller.canRecord)
        .help(controller.isRecording ? strings.stopRecognition : strings.startRecognition)
    }

    /// A small dot to the right of the record button; the phase text lives in its tooltip.
    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .help(controller.phaseLabel)
    }

    private var statusColor: Color {
        switch controller.phase {
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

/// A small round orange button with a white symbol, styled like the record button.
private struct ToolbarIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: { if isEnabled { action() } }) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.accent, Theme.accentDark.opacity(0.9)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: Theme.accentDark.opacity(0.2), radius: 3, x: 0, y: 1.5)
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
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

    var id: String { line.id }
}

private struct TranscriptRow: View, Equatable {
    let model: TranscriptRowModel
    let timestampWidth: CGFloat
    /// Whether the row's audio is being heard; the row then keeps its hover tint.
    let isPlaying: Bool
    let onTap: () -> Void

    @State private var isHovering = false

    /// Everything but the tap closure, which SwiftUI could not compare and which only ever
    /// does the same thing for the same line.
    static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.model == rhs.model && lhs.timestampWidth == rhs.timestampWidth && lhs.isPlaying == rhs.isPlaying
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
            .font(.system(.caption, design: .monospaced).weight(.medium))
            .foregroundStyle(Theme.accent)
            .frame(width: timestampWidth, height: Theme.timestampColumnHeight, alignment: .leading)
            VStack(alignment: .leading, spacing: Theme.secondaryTextGap) {
                Text(model.primaryText)
                    .font(.system(size: Theme.bodyFontSize))
                if let secondaryText = model.secondaryText {
                    Text(secondaryText)
                        .font(.system(size: Theme.secondaryFontSize))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accent.opacity(isHovering || isPlaying ? Theme.rowFillHoverOpacity : Theme.rowFillOpacity))
        )
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onTap)
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
