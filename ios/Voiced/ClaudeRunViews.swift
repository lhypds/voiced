import SwiftUI
import VoicedCore

/// Claude's colour on the cards for its runs.
private let claudeAccent = Color(red: 0.80, green: 0.45, blue: 0.32)

/// How long a run has taken, as on the Mac: "12s", "1m 5s".
private func runDuration(_ seconds: Double) -> String {
    let whole = max(0, Int(seconds.rounded()))
    return whole < 60 ? "\(whole)s" : "\(whole / 60)m \(whole % 60)s"
}

private func elapsed(_ run: ClaudeRun, now: Date) -> Double? {
    guard let startedAt = run.startedAt else { return nil }
    return (run.endedAt ?? now.timeIntervalSince1970) - startedAt
}

/// The Mac's Claude Code run of a sentence sent with Run, under its line in the transcript: what
/// it is doing now, or how it ended, with what Claude said last. A tool waiting for permission is
/// allowed or denied right here. A tap opens the whole run.
struct ClaudeRunCard: View {
    let run: ClaudeRun
    let labelWidth: CGFloat
    let stacked: Bool
    let connected: Bool
    let open: () -> Void
    let command: (ClaudeRunCommand.Action) -> Void

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 8) { label; content }
            } else {
                // On the first line's baseline: "Claude" is smaller than the status beside it, and
                // the stop button makes that line taller still, so their tops never line up.
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    label.frame(width: labelWidth, alignment: .leading)
                    content.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(claudeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture(perform: open)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("claude-run")
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(verbatim: "Claude").font(.system(.caption, design: .monospaced, weight: .bold))
            Image(systemName: "terminal").font(.caption.weight(.bold))
        }
        .foregroundStyle(claudeAccent)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ClaudeRunStatus(run: run)
                Spacer(minLength: 4)
                if run.state.isGoing {
                    // A symbol inside Text sits on the text's baseline, as an Image alone does not.
                    Button { command(.stop) } label: {
                        Text(Image(systemName: "stop.circle")).font(.body.weight(.medium)).baselineOffset(-1.5)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(claudeAccent)
                    .disabled(!connected)
                    .accessibilityLabel(Text("停止"))
                }
            }
            if let pending = run.pending {
                PendingRequest(pending: pending, connected: connected, command: command)
            } else if let tool = run.activeTool, let summary = tool.summary, !summary.isEmpty {
                Text(summary).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            } else if let text = lastText {
                Text(text).font(.subheadline.bold()).foregroundStyle(MobileTheme.ink).lineLimit(run.state.isGoing ? 3 : 4)
            }
        }
    }

    /// What Claude wrote last, or why the run failed, on one run of lines: line breaks and blank
    /// lines become single spaces, so the card's few lines hold text rather than gaps. The whole
    /// run keeps them.
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // On the text's baseline, so the card can line this up with "Claude": centred, the
            // spinner gave the row its own baseline at its bottom edge, below the text's.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if run.state == .running && run.pending == nil {
                    ProgressView().controlSize(.small)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                }
                Group {
                    switch run.state {
                    case .queued: Text("排队中")
                    case .running:
                        if run.pending != nil { Text("等待批准") }
                        else if let tool = run.activeTool { Text("正在使用 \(tool.name ?? "tool")") }
                        else { Text("正在思考") }
                    case .done: Text("已完成")
                    case .failed: Text("执行失败")
                    case .stopped: Text("已停止")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(run.state == .failed ? .red : claudeAccent)
                if let seconds = elapsed(run, now: context.date) {
                    Text(verbatim: runDuration(seconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A tool Claude may not use without asking: its name and what it would do, and the answer.
private struct PendingRequest: View {
    let pending: ClaudeRun.Pending
    let connected: Bool
    let command: (ClaudeRunCommand.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: pending.tool).font(.subheadline.bold()).foregroundStyle(MobileTheme.ink)
                if !pending.summary.isEmpty {
                    Text(pending.summary).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).lineLimit(6)
                }
            }
            HStack(spacing: 10) {
                Button { command(.deny) } label: { Text("拒绝").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(.red)
                Button { command(.allow) } label: { Text("允许").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(claudeAccent)
            }
            .controlSize(.regular)
            .disabled(!connected)
        }
    }
}

/// The whole run: the sentence, then Claude's text, each tool call with its result, and how it
/// ended, following along while it runs.
struct ClaudeRunSheet: View {
    @EnvironmentObject private var model: MobileTranscriber
    let runID: String
    @Environment(\.dismiss) private var dismiss
    /// Tool results opened, by item index.
    @State private var expanded: Set<Int> = []

    private var run: ClaudeRun? { model.claudeRun(id: runID) }
    private var connected: Bool { model.macLink.connectedName != nil }

    var body: some View {
        NavigationStack {
            Group {
                if let run { transcript(run) }
                else { ContentUnavailableView("已停止", systemImage: "terminal") }
            }
            .navigationTitle(Text("执行过程"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                if let run, run.state.isGoing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("停止", role: .destructive) { model.macLink.send(ClaudeRunCommand(command: .stop, run: run.id)) }
                            .tint(.red)
                            .disabled(!connected)
                    }
                }
            }
        }
    }

    private func transcript(_ run: ClaudeRun) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(run.text).font(.headline)
                        Text(verbatim: run.folder).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                    ForEach(Array((run.items ?? []).enumerated()), id: \.offset) { index, item in
                        itemView(item, index: index)
                    }
                    if let pending = run.pending {
                        PendingRequest(pending: pending, connected: connected) { action in
                            model.macLink.send(ClaudeRunCommand(command: action, run: run.id, pending: pending.id))
                        }
                        .padding(14)
                        .background(claudeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                    }
                    ClaudeRunStatus(run: run)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(20)
                .textSelection(.enabled)
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: run) { withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
        }
    }

    @ViewBuilder
    private func itemView(_ item: ClaudeRunItem, index: Int) -> some View {
        switch item.kind {
        case .text:
            if let text = item.text, !text.isEmpty {
                Text(LocalizedStringKey(text)).font(.body).foregroundStyle(MobileTheme.ink)
            }
        case .tool:
            VStack(alignment: .leading, spacing: 4) {
                // Centred, not baseline-aligned: a ProgressView has no text baseline, so it would sit
                // with its bottom edge on the name's baseline, higher than the name.
                HStack(alignment: .center, spacing: 6) {
                    // One fixed square for all three states, so the mark that replaces the spinner is
                    // the spinner's size rather than the larger size of a symbol set in body text.
                    Group {
                        if item.done != true { ProgressView().controlSize(.mini) }
                        else {
                            Image(systemName: item.isError == true ? "xmark" : "checkmark")
                                .resizable().scaledToFit().fontWeight(.bold).frame(width: 10, height: 10)
                                .foregroundStyle(item.isError == true ? .red : .green)
                        }
                    }
                    .frame(width: 14, height: 14)
                    Text(verbatim: item.name ?? "tool").font(.subheadline.bold())
                }
                if let summary = item.summary, !summary.isEmpty {
                    Text(summary).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).lineLimit(4)
                }
                if let result = item.result, !result.isEmpty {
                    Text(result)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(item.isError == true ? .red : .secondary)
                        .lineLimit(expanded.contains(index) ? nil : 3)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) } }
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(claudeAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        case .result:
            if item.isError == true {
                Label(item.text ?? "", systemImage: "xmark.circle").foregroundStyle(.red).font(.subheadline)
            } else {
                Label {
                    Text(verbatim: [item.durationMs.map { runDuration($0 / 1000) }, item.turns.map { String(localized: "\($0) 轮") }]
                        .compactMap { $0 }.joined(separator: " · "))
                } icon: { Image(systemName: "checkmark.circle") }
                .foregroundStyle(.green).font(.subheadline)
            }
        case .error:
            Label(item.text ?? "", systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.subheadline)
        }
    }
}
