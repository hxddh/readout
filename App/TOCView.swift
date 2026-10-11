import SwiftUI
import ReadoutCore

/// Observable state shared between a reader window's sidebar, toolbar and controller.
@MainActor
final class ReaderModel: ObservableObject {
    @Published var toc: [TocEntry] = []
    @Published var activeSlot: Int = 0
    @Published var tasks = TaskStats()
    @Published var unread = 0
    @Published var title = ""
    @Published var status: String? = nil
    var onSelectHeading: ((Int) -> Void)?
}

struct TOCView: View {
    @ObservedObject var model: ReaderModel

    var body: some View {
        Group {
            if model.toc.isEmpty {
                VStack {
                    Spacer()
                    Text(NSLocalizedString("No headings", comment: "Sidebar empty"))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: selection) {
                        ForEach(model.toc) { entry in
                            TOCRow(entry: entry, minLevel: minLevel)
                                .tag(Optional(entry.slot))
                                .id(entry.slot)
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: model.activeSlot) { _, slot in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(slot, anchor: .center) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if let status = model.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var minLevel: Int { model.toc.map(\.level).min() ?? 1 }

    /// Programmatic changes (from scrolling) only move the highlight; user clicks also scroll the document.
    private var selection: Binding<Int?> {
        Binding(
            get: { model.activeSlot == 0 ? nil : model.activeSlot },
            set: { slot in
                guard let slot else { return }
                model.activeSlot = slot
                model.onSelectHeading?(slot)
            }
        )
    }
}

private struct TOCRow: View {
    let entry: TocEntry
    let minLevel: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.title.isEmpty ? "—" : entry.title)
                .font(entry.level == minLevel ? .body.weight(.medium) : .body)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if entry.tasks.total > 0 {
                Text("\(entry.tasks.done)/\(entry.tasks.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(entry.tasks.done == entry.tasks.total ? .secondary : .tertiary)
            }
        }
        .padding(.leading, CGFloat(max(0, entry.level - minLevel)) * 12)
        .help(entry.title)
    }
}
