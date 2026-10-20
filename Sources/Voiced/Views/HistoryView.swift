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
                                strings: strings,
                                select: {
                                    controller.resume(record)
                                    isPresented = false
                                },
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
}

private struct HistoryRow: View {
    let record: TranscriptRecord
    let isCurrent: Bool
    let strings: AppStrings
    let select: () -> Void
    let delete: () -> Void

    @State private var isHovered = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Button(action: select) {
            // Centre alignment keeps the delete button vertically centred on the row.
            HStack(alignment: .center, spacing: 12) {
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
                    }
                    Text(record.preview)
                        .font(.system(size: 14))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(strings.delete)
                .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(isHovered ? Color.black.opacity(0.04) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(strings.delete, role: .destructive, action: delete)
        }
    }
}
