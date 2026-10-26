import SwiftUI

/// Popover listing saved transcripts. Choosing one puts it back on screen so recording continues into it.
struct HistoryView: View {
    @ObservedObject var controller: TranscriptionController
    @Binding var isPresented: Bool

    private var strings: AppStrings { controller.strings }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(strings.history)
                    .font(.title3.weight(.bold))
                Text(strings.historyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            if controller.history.isEmpty {
                Text(strings.historyEmpty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .padding(.bottom, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(controller.history) { record in
                            HistoryRow(
                                record: record,
                                isCurrent: record.id == controller.currentRecordID,
                                summary: summaryState(of: record),
                                strings: strings,
                                select: {
                                    controller.resume(record)
                                    isPresented = false
                                },
                                copy: { controller.copyTranscript(of: record) },
                                openFolder: { controller.openRecordFolder(record) },
                                summarize: { controller.summarize(record) },
                                openSummary: { controller.openSummary(record) },
                                delete: { controller.deleteRecord(record) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .frame(width: 340)
        .background(Theme.background)
    }

    private func summaryState(of record: TranscriptRecord) -> HistoryRow.SummaryState {
        HistoryRow.SummaryState(
            isOffered: controller.canSummarize,
            isRunning: controller.summarizingRecordIDs.contains(record.id),
            exists: controller.summarizedRecordIDs.contains(record.id),
            error: controller.summaryErrors[record.id]
        )
    }
}

private struct HistoryRow: View {
    /// What the row shows about the record's AI summary.
    struct SummaryState {
        /// Whether summaries can be asked for at all: an API key is set.
        let isOffered: Bool
        let isRunning: Bool
        /// Whether `summary.txt` exists, so it can be opened.
        let exists: Bool
        let error: String?
    }

    let record: TranscriptRecord
    let isCurrent: Bool
    let summary: SummaryState
    let strings: AppStrings
    let select: () -> Void
    /// Puts the record's whole transcript on the clipboard.
    let copy: () -> Void
    let openFolder: () -> Void
    let summarize: () -> Void
    let openSummary: () -> Void
    let delete: () -> Void

    @State private var isHovered = false
    /// The copy symbol shows a checkmark for a moment after a copy: the popover covers the
    /// window's own "Copied" toast, so the row confirms it itself.
    @State private var showsCopied = false
    @State private var copiedResetTask: Task<Void, Never>?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Self.dateFormatter.string(from: record.updatedAt))
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(Theme.accent)
                    Text(strings.lineCount(record.lines.count))
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                    if isCurrent {
                        Text(strings.currentRecord)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.18), in: Capsule())
                    }
                    Spacer()
                    // The summary in progress stays visible without the pointer: it is the only
                    // sign that the request is running.
                    if summary.isRunning {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 16, height: 16)
                            .help(strings.summarizing)
                    }
                    // Small actions sit on the timestamp line, shown only while the pointer is
                    // over the row, so the preview below keeps the full width.
                    HStack(spacing: 6) {
                        // One button for the summary: it opens the summary once there is one,
                        // and asks for it until then.
                        if summary.exists {
                            rowAction("sparkles", help: strings.openSummary, action: openSummary)
                        } else if summary.isOffered && !summary.isRunning {
                            rowAction("sparkles", help: strings.summarize, action: summarize)
                        }
                        rowAction(showsCopied ? "checkmark" : "doc.on.doc", help: strings.copyAll, action: copyTranscript)
                        rowAction("folder", help: strings.openFolder, action: openFolder)
                        rowAction("trash", help: strings.delete, action: delete)
                    }
                    .opacity(isHovered || showsCopied ? 1 : 0)
                    .allowsHitTesting(isHovered)
                }
                Text(record.preview)
                    .font(.system(size: 14))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let error = summary.error {
                    Text(strings.summaryFailed(error))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isHovered ? Color.black.opacity(0.04) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            if summary.exists {
                Button(strings.openSummary, action: openSummary)
            }
            if summary.isOffered {
                Button(strings.summarize, action: summarize)
                    .disabled(summary.isRunning)
            }
            Button(strings.copyAll, action: copyTranscript)
            Button(strings.openFolder, action: openFolder)
            Button(strings.delete, role: .destructive, action: delete)
        }
    }

    private func copyTranscript() {
        copy()
        showsCopied = true
        copiedResetTask?.cancel()
        copiedResetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            showsCopied = false
        }
    }

    private func rowAction(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
