import SwiftUI
import VoicedCore

/// The saved transcripts. The search field above them looks through every record's lines;
/// choosing a result opens the record with the same search on the main screen.
struct MobileHistoryView: View {
    @EnvironmentObject private var model: MobileTranscriber
    @Environment(\.dismiss) private var dismiss
    /// Called with the search a result was chosen with, before the history closes.
    var openSearch: (String) -> Void = { _ in }
    @State private var query = ""

    /// The same fixed, compact "2026-10-27 12:12" the macOS history shows.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    /// Each record with what of it matches the search; every record, unmatched, while the search is empty.
    private var rows: [(record: TranscriptRecord, match: HistorySearchResult?)] {
        guard HistorySearch.normalized(query) != nil else { return model.records.map { ($0, nil) } }
        return HistorySearch.results(in: model.records, for: query).map { ($0.record, $0) }
    }

    var body: some View {
        NavigationStack {
            let rows = rows
            List {
                // The search field is the first card: tinted like the records and like the search on
                // the main screen, and as far from the first record as the records are from each other.
                if !model.records.isEmpty {
                    Section { searchField }
                }
                // One section per record so the inset-grouped list draws each record as its own card.
                ForEach(rows, id: \.record.id) { row in
                    let record = row.record
                    Section {
                        Button {
                            model.resume(record)
                            if row.match != nil, let search = HistorySearch.normalized(query) {
                                openSearch(search)
                            }
                            dismiss()
                        } label: {
                            // Cards size to their content: a one-line preview stays compact, and the
                            // summary status row only appears when there is something to show.
                            VStack(alignment: .leading, spacing: 6) {
                                // As on macOS: "2026-10-27 12:12" of the last change in the
                                // timestamp's font, then the number of sentences, or of matches
                                // while searching.
                                HStack(spacing: 8) {
                                    Text(Self.dateFormatter.string(from: record.updatedAt))
                                        .font(.system(.caption, design: .monospaced, weight: .medium))
                                    Text(row.match.map { model.strings.matchCount($0.matchCount) } ?? "\(record.lines.count)")
                                        .font(.caption)
                                    // The record on the main screen, marked as macOS marks it.
                                    if record.id == model.current.id {
                                        Text(model.strings.currentRecord)
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6).padding(.vertical, 1)
                                            .background(MobileTheme.accent.opacity(0.18), in: Capsule())
                                            .accessibilityIdentifier("current-record-badge")
                                    }
                                }
                                .foregroundStyle(MobileTheme.accent).lineLimit(1)
                                // While searching, the first matching line with the match picked
                                // out, in place of the record's opening line.
                                Group {
                                    if let match = row.match {
                                        Text(HistorySearch.highlighted(match.matchedText, query: query, color: MobileTheme.accentDark))
                                    } else {
                                        Text(record.preview.isEmpty ? model.localized("仅录音") : record.preview)
                                    }
                                }
                                    .font(.body).lineLimit(2)
                                if model.hasSummary(record) || model.ai.summarizingRecordIDs.contains(record.id) {
                                    // A plain HStack instead of Label: inside a List, Label pads the icon out to a
                                    // column and scales it up, which looks detached from caption text.
                                    HStack(spacing: 12) {
                                        if model.hasSummary(record) {
                                            HStack(spacing: 4) { Image(systemName: "sparkles"); Text("摘要") }
                                        }
                                        if model.ai.summarizingRecordIDs.contains(record.id) {
                                            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("正在生成摘要…") }
                                        }
                                    }.font(.caption).foregroundStyle(VoicedPalette.aiAccent).lineLimit(1)
                                }
                            }.padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("history-record.\(record.id)")
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                        .listRowBackground(MobileTheme.card)
                        .contextMenu {
                            if model.canSummarize {
                                Button(LocalizedStringKey(model.hasSummary(record) ? "重新生成摘要" : "生成摘要"), systemImage: "sparkles") { model.summarize(record) }
                                    .disabled(model.ai.summarizingRecordIDs.contains(record.id) || record.lines.isEmpty)
                            }
                            if model.hasSummary(record) { Button("查看摘要", systemImage: "doc.text") { model.openSummary(record) } }
                            ShareLink(item: model.export(record.lines)) { Label("导出文字", systemImage: "square.and.arrow.up") }
                            ForEach(model.audioURLs(for: record), id: \.self) { url in
                                ShareLink(item: url) { Label("音频文件", systemImage: "waveform") }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(record) } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
            }
            // Inset-grouped sections default to a wide gap; tighten it so records read as a list of cards,
            // and push the first card down so it does not crowd the large title.
            .scrollDismissesKeyboard(.interactively)
            .listSectionSpacing(12)
            .contentMargins(.top, 8, for: .scrollContent)
            .scrollContentBackground(.hidden).background(MobileTheme.background)
            .navigationTitle(Text("历史记录"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { Button("完成") { dismiss() }.foregroundStyle(MobileTheme.accent) }
            .sheet(item: $model.summaryPresentation) { summary in
                NavigationStack {
                    ScrollView { Text(summary.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(24) }
                        .background(MobileTheme.background)
                        .navigationTitle(Text("摘要")).navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) { ShareLink(item: summary.text) { Image(systemName: "square.and.arrow.up") } }
                            ToolbarItem(placement: .topBarTrailing) { Button("完成") { model.summaryPresentation = nil } }
                        }
                }
            }
            .onDisappear { model.stopPlayback() }
        }.tint(MobileTheme.accent).modifier(MobileErrorAlert(model: model))
    }

    /// Drawn like the search field on the main screen: an orange symbol, the text, and a clear button.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MobileTheme.accent)
            // No placeholder, as in the main screen's search field; the name stays for VoiceOver.
            TextField("", text: $query)
                .accessibilityLabel(model.strings.searchHistory)
                .textFieldStyle(.plain).font(.body)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("history-search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16)).foregroundStyle(.secondary)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.strings.close)
                .accessibilityIdentifier("history-search-clear")
            }
        }
        .frame(minHeight: 44)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 10))
        .listRowBackground(MobileTheme.card)
    }

    private func delete(_ record: TranscriptRecord) {
        model.delete(at: IndexSet(model.records.indices.filter { model.records[$0].id == record.id }))
    }
}

