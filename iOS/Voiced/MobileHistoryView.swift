import SwiftUI
import VoicedCore

struct MobileHistoryView: View {
    @EnvironmentObject private var model: MobileTranscriber
    @Environment(\.dismiss) private var dismiss
    private var records: [TranscriptRecord] { model.records }

    var body: some View {
        NavigationStack {
            List {
                // One section per record so the inset-grouped list draws each record as its own card.
                ForEach(records) { record in
                    Section {
                        Button {
                            model.resume(record)
                            dismiss()
                        } label: {
                            // Cards size to their content: a one-line preview stays compact, and the
                            // summary status row only appears when there is something to show.
                            VStack(alignment: .leading, spacing: 6) {
                                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(MobileTheme.accent).lineLimit(1)
                                Text(record.preview.isEmpty ? model.localized("仅录音") : record.preview)
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
                            ForEach(model.audioURLs(for: record), id: \.self) { url in
                                ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "square.and.arrow.up") }
                            }
                            if model.canSummarize {
                                Button("生成摘要", systemImage: "sparkles") { model.summarize(record) }
                                    .disabled(model.ai.summarizingRecordIDs.contains(record.id) || record.lines.isEmpty)
                            }
                            if model.hasSummary(record) { Button("查看摘要", systemImage: "doc.text") { model.openSummary(record) } }
                            ShareLink(item: model.export(record.lines)) { Label("导出文字", systemImage: "square.and.arrow.up") }
                            ShareLink(item: model.transcriptURL(for: record)) { Label("JSON", systemImage: "doc") }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { delete(record) } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
            }
            // Inset-grouped sections default to a wide gap; tighten it so records read as a list of cards,
            // and push the first card down so it does not crowd the large title.
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

    private func delete(_ record: TranscriptRecord) {
        model.delete(at: IndexSet(model.records.indices.filter { model.records[$0].id == record.id }))
    }
}

