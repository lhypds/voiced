import SwiftUI
import VoicedCore

/// Claude's colour on the rows for its runs, as on the iPhone.
private let claudeAccent = Color(red: 0.80, green: 0.45, blue: 0.32)

/// How long a run has taken: "12s", "1m 5s".
private func runDuration(_ seconds: Double) -> String {
    let whole = max(0, Int(seconds.rounded()))
    return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
}

private func elapsed(_ run: ClaudeRun, now: Date) -> Double? {
    guard let startedAt = run.startedAt else { return nil }
    return (run.endedAt ?? now.timeIntervalSince1970) - startedAt
}

/// The machine's Claude Code run of a line sent with Run, under the line: what it is doing now,
/// or how it ended, with what Claude said last. A tool waiting for permission is allowed or
/// denied right here. A click unfolds the whole run below, in a box of limited height that
/// scrolls; another click on the top of the bubble folds it again.
struct ClaudeRunRow: View {
    @ObservedObject var controller: TranscriptionController
    let run: ClaudeRun
    let timestampWidth: CGFloat

    @State private var isHovering = false
    @State private var isExpanded = false
    /// Tool results opened, by item index.
    @State private var expandedResults: Set<Int> = []

    /// The tallest the unfolded run gets before it scrolls.
    private static let maxTranscriptHeight: CGFloat = 540

    private var strings: AppStrings { controller.strings }
    private var connected: Bool { controller.macLink.connectedName != nil }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "Claude")
                    .font(.system(.caption, design: .monospaced).weight(.bold))
                Image(systemName: "terminal")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(claudeAccent)
            .frame(width: timestampWidth, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(claudeAccent.opacity(isHovering ? 0.16 : 0.1))
        )
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // Folded, a click anywhere unfolds it; unfolded, only the top line folds it, so the run
        // below can be selected and its results opened.
        .onTapGesture { if !isExpanded { toggle() } }
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ClaudeRunStatus(run: run, strings: strings)
                Spacer(minLength: 4)
                if run.state.isGoing {
                    Button { controller.command(.stop, run: run) } label: {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(claudeAccent)
                    .disabled(!connected)
                    .help(strings.runStop)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(claudeAccent)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            // The whole top line folds and unfolds, its empty middle too; the stop button
            // keeps its own click.
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            if isExpanded {
                expandedTranscript
            } else if let pending = run.pending {
                PendingRequest(pending: pending, connected: connected, strings: strings) { action in
                    controller.command(action, run: run)
                }
            } else if let tool = run.activeTool, let summary = tool.summary, !summary.isEmpty {
                Text(summary)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let text = lastText {
                Text(text)
                    .font(.system(size: Theme.hintFontSize))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(run.state.isGoing ? 3 : 4)
            }
        }
    }

    /// The whole run: the line and folder, Claude's text, each tool call with its result, and a
    /// tool waiting for permission at the end. Scrolls once taller than the limit, kept at the
    /// end while the run goes on.
    private var expandedTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    RunTranscript(controller: controller, run: run, expandedResults: $expandedResults)
                        .padding(12)
                    Color.clear.frame(height: 0).id("end")
                }
            }
            // As tall as the run, up to the limit, worked out by layout alone: a height measured
            // and fed back as state made the list's lazy stack lay out without end, which froze
            // the window while a long run streamed in.
            .frame(maxHeight: Self.maxTranscriptHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollIndicators(.never)
            // No bouncing while it all fits.
            .scrollBounceBehavior(.basedOnSize)
            // On a card a little lighter than the bubble's orange, with a thin border: white
            // laid half over the bubble's tint.
            .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(claudeAccent.opacity(0.25), lineWidth: 1)
            )
            // A finished run opens at its start; one still going at its latest step, once laid out.
            .onAppear {
                guard run.state.isGoing else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: run) { if run.state.isGoing { proxy.scrollTo("end", anchor: .bottom) } }
        }
        .transition(.opacity)
    }

    /// What Claude wrote last, or why the run failed, on one run of lines: line breaks and blank
    /// lines become single spaces. The whole run keeps them.
    private var lastText: String? {
        let items = run.items ?? []
        let text: String?
        if run.state == .failed, let failure = items.last(where: { $0.kind == .error || ($0.kind == .result && $0.isError == true) }) {
            text = failure.text
        } else {
            text = items.last(where: { $0.kind == .text && !($0.text ?? "").isEmpty })?.text
        }
        guard let text else { return nil }
        let flat = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.isEmpty ? nil : flat
    }
}

/// The run's state in a line: a spinner and what it is doing while it runs, how it ended after.
private struct ClaudeRunStatus: View {
    let run: ClaudeRun
    let strings: AppStrings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if run.state == .running && run.pending == nil {
                    ProgressView().controlSize(.mini)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(run.state == .failed ? .red : claudeAccent)
                if let seconds = elapsed(run, now: context.date) {
                    Text(verbatim: runDuration(seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var label: String {
        switch run.state {
        case .queued: strings.runQueued
        case .running:
            if run.pending != nil { strings.runWaitingApproval }
            else if let tool = run.activeTool { strings.runUsingTool(tool.name ?? "tool") }
            else { strings.runThinking }
        case .done: strings.runDone
        case .failed: strings.runFailed
        case .stopped: strings.runStopped
        }
    }
}

/// A tool Claude may not use without asking: its name and what it would do, and the answer.
private struct PendingRequest: View {
    let pending: ClaudeRun.Pending
    let connected: Bool
    let strings: AppStrings
    let command: (ClaudeRunCommand.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: pending.tool)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accent)
                if !pending.summary.isEmpty {
                    Text(pending.summary)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
            HStack(spacing: 10) {
                Button { command(.deny) } label: { Text(strings.runDeny).frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .tint(.red)
                Button { command(.allow) } label: { Text(strings.runAllow).frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .tint(claudeAccent)
            }
            .disabled(!connected)
        }
    }
}

/// The whole run, laid out in the unfolded bubble: the line and its folder, then Claude's text
/// and each tool call with its result, then a tool waiting for permission.
private struct RunTranscript: View {
    @ObservedObject var controller: TranscriptionController
    let run: ClaudeRun
    @Binding var expandedResults: Set<Int>

    private var strings: AppStrings { controller.strings }
    private var connected: Bool { controller.macLink.connectedName != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(run.text)
                    .font(.system(size: Theme.hintFontSize, weight: .semibold))
                Text(verbatim: run.folder)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            ForEach(Array((run.items ?? []).enumerated()), id: \.offset) { index, item in
                itemView(item, index: index)
            }
            if let pending = run.pending {
                PendingRequest(pending: pending, connected: connected, strings: strings) { action in
                    controller.command(action, run: run)
                }
                .padding(12)
                .background(claudeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func itemView(_ item: ClaudeRunItem, index: Int) -> some View {
        switch item.kind {
        case .text:
            if let text = item.text, !text.isEmpty {
                Text(LocalizedStringKey(text)).font(.system(size: Theme.hintFontSize)).foregroundStyle(Theme.accent)
            }
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    Group {
                        if item.done != true {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: item.isError == true ? "xmark" : "checkmark")
                                .resizable().scaledToFit().fontWeight(.bold).frame(width: 10, height: 10)
                                .foregroundStyle(item.isError == true ? .red : .green)
                        }
                    }
                    .frame(width: 14, height: 14)
                    Text(verbatim: item.name ?? "tool").font(.system(size: 13, weight: .bold))
                }
                if let summary = item.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
                if let result = item.result, !result.isEmpty {
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(item.isError == true ? .red : .secondary)
                        .lineLimit(expandedResults.contains(index) ? nil : 3)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture {
                            if expandedResults.contains(index) { expandedResults.remove(index) } else { expandedResults.insert(index) }
                        }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(claudeAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        case .result:
            if item.isError == true {
                Label(item.text ?? "", systemImage: "xmark.circle").foregroundStyle(.red).font(.subheadline)
            } else {
                Label {
                    Text(verbatim: [item.durationMs.map { runDuration($0 / 1000) }, item.turns.map { strings.runTurns($0) }]
                        .compactMap { $0 }.joined(separator: " · "))
                } icon: { Image(systemName: "checkmark.circle") }
                .foregroundStyle(.green)
                .font(.subheadline)
            }
        case .error:
            Label(item.text ?? "", systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.subheadline)
        }
    }
}
