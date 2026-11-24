import VoicedCore
import SwiftUI

/// Popover listing saved transcripts. Choosing one puts it back on screen so recording continues
/// into it. The field at the top searches every record's lines; choosing a result opens the record
/// with the same search in the main window, so the matching lines are what shows.
struct HistoryView: View {
    @ObservedObject var controller: TranscriptionController
    @Binding var isPresented: Bool
    /// Opens the main window's search with this text, after a search result was chosen.
    var openSearch: (String) -> Void = { _ in }

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var strings: AppStrings { controller.strings }

    /// Each record with what of it matches the search; every record, unmatched, while the search is empty.
    private var rows: [(record: TranscriptRecord, match: HistorySearchResult?)] {
        guard HistorySearch.normalized(query) != nil else {
            return controller.history.map { ($0, nil) }
        }
        return HistorySearch.results(in: controller.history, for: query).map { ($0.record, $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // In the wordmark's face and colour, as the Settings sidebar's title is.
            Text(strings.history)
                .font(.custom("GillSans-Bold", size: 24))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 16)
                .padding(.top, 16)

            if controller.history.isEmpty {
                // Nothing to list: the popover shows only its title.
                Spacer().frame(height: 4)
            } else {
                searchField
                let rows = rows
                if rows.isEmpty {
                    // Nothing matches: nothing is listed under the field.
                    Spacer().frame(height: 4)
                } else {
                    ScrollView {
                        // One card per record, matching the rounded rows of the main window.
                        VStack(spacing: Theme.rowGap) {
                            ForEach(rows, id: \.record.id) { row in
                                let record = row.record
                                HistoryRow(
                                    record: record,
                                    match: row.match,
                                    query: query,
                                    isCurrent: record.id == controller.currentRecordID,
                                    summary: summaryState(of: record),
                                    strings: strings,
                                    select: {
                                        controller.resume(record)
                                        if row.match != nil, let search = HistorySearch.normalized(query) {
                                            openSearch(search)
                                        }
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
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                    .frame(maxHeight: 360)
                }
            }
        }
        .frame(width: 340)
        .background(Theme.background)
    }

    /// A rounded field under the title, drawn like the search field of the main window.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            // No placeholder, as in the main window's search field; the name stays for VoiceOver.
            TextField("", text: $query)
                .accessibilityLabel(strings.searchHistory)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isSearchFocused)
                // Escape empties the field first; with nothing in it, the popover closes as usual.
                .onExitCommand {
                    if query.isEmpty { isPresented = false } else { query = "" }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    isSearchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(strings.close)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accent.opacity(Theme.rowFillOpacity))
        )
        .padding(.horizontal, 16)
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
    /// What of the record matches the search, while there is one.
    let match: HistorySearchResult?
    let query: String
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
        // A fixed, compact "2026-10-27 12:12" keeps the date on one line beside the sentence count.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(Self.dateFormatter.string(from: record.updatedAt))
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .foregroundStyle(Theme.accent)
                    // The number of sentences on its own, without a unit; while searching, the matches.
                    Text(match.map { strings.matchCount($0.matchCount) } ?? "\(record.lines.count)")
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
                // While searching, the first matching line with the match picked out, in place
                // of the record's opening line.
                Group {
                    if let match {
                        Text(HistorySearch.highlighted(match.matchedText, query: query, color: Theme.accentDark))
                    } else {
                        Text(record.preview)
                    }
                }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accent.opacity(isHovered ? Theme.rowFillHoverOpacity : Theme.rowFillOpacity))
            )
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
