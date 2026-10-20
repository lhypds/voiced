import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: TranscriptionController
    @State private var isSettingsPresented = false
    @State private var isHistoryPresented = false
    /// How far the transcript list has been scrolled down from its top.
    @State private var transcriptScrollOffset: CGFloat = 0
    @State private var showsCopiedToast = false
    /// Measured height of the model banner above the record button, 0 while there is none.
    @State private var preparationBannerHeight: CGFloat = 0
    @State private var copiedToastResetTask: Task<Void, Never>?

    private var strings: AppStrings { controller.strings }

    var body: some View {
        VStack(spacing: 0) {
            header
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
        .background(Theme.background)
        .background(WindowLevelSetter(isFloating: controller.keepWindowOnTop))
        .preferredColorScheme(.light)
        // Not a sheet: a sheet hangs from the title bar, this panel is centered on the window.
        .background(
            SettingsWindowPresenter(isPresented: isSettingsPresented) {
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
            ToolbarIconButton(systemName: "doc.on.doc", help: strings.copyAll) {
                controller.copyTranscript()
                showCopiedToast()
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
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        // Kept small so the list's scroll edge sits just under the header.
        .padding(.bottom, Self.headerBottomInset)
        .padding(.top, Self.headerTopInset)
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
            VStack(spacing: 0) {
                // The LIVE row leads the list and committed sentences follow newest first, so the
                // newest text sits at the top without any scrolling.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.rowGap) {
                        if controller.isRecording || !controller.liveText.isEmpty {
                            LiveRow(text: controller.liveText, timestampWidth: timestampWidth)
                        }
                        ForEach(controller.lines.reversed()) { line in
                            TranscriptRow(
                                timestamp: controller.timestamp(for: line),
                                text: line.text,
                                timestampWidth: timestampWidth,
                                onCopy: {
                                    controller.copy(line)
                                    showCopiedToast()
                                }
                            )
                        }
                    }
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.top, Self.rowEdgeGap)
                    // Room to scroll the last row clear of the record button, leaving the same
                    // gap above the button as between the header and the first row.
                    .padding(.bottom, Self.listBottomInset + bottomExtraInset)
                }
                .scrollIndicators(.hidden)
                .modifier(ScrollOffsetReader(offset: $transcriptScrollOffset))
                .mask(
                    VStack(spacing: 0) {
                        // The top fade only exists once rows have scrolled under the edge, growing
                        // with the scroll offset so the newest rows are not dimmed at rest.
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: min(max(transcriptScrollOffset, 0), Self.topFadeHeight))
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
    private static let edgeInset: CGFloat = 21
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
/// fraction is unknown, a short segment sweeping back and forth.
private struct ProgressBar: View {
    let fraction: Double?

    @State private var sweep = false

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
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: segment)
                        .offset(x: sweep ? width - segment : 0)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: sweep)
                        .onAppear { sweep = true }
                }
            }
        }
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

private struct TranscriptRow: View {
    let timestamp: String
    let text: String
    let timestampWidth: CGFloat
    let onCopy: () -> Void

    @State private var isHovering = false

    private var timestampPieces: [String] {
        timestamp.split(separator: " ").map(String.init)
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
            Text(text)
                .font(.system(size: Theme.bodyFontSize))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accent.opacity(isHovering ? Theme.rowFillHoverOpacity : Theme.rowFillOpacity))
        )
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onCopy)
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

/// Reports how far a scroll view has scrolled down from its top. Needs macOS 15; on macOS 14 the
/// offset stays at zero, which only disables the top fade.
private struct ScrollOffsetReader: ViewModifier {
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, new in
                offset = new
            }
        } else {
            content
        }
    }
}
