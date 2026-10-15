import SwiftUI
import ReadoutCore

/// Observable state shared between a reader window's sidebar, toolbar and controller.
@MainActor
final class ReaderModel: ObservableObject {
    @Published var toc: [TocEntry] = [] {
        // Once per outline, not per row.
        didSet { baseLevel = ReaderChrome.outlineBaseLevel(toc.map(\.level)) }
    }
    /// The level outline rows indent from: under a lone H1 title, its sections' level.
    private(set) var baseLevel = 1
    @Published var activeSlot: Int = 0
    @Published var tasks = TaskStats()
    @Published var unread = 0
    @Published var title = ""
    @Published var status: String? = nil
    var onSelectHeading: ((Int) -> Void)?
}

struct TOCView: View {
    @ObservedObject var model: ReaderModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                            TOCRow(entry: entry, minLevel: model.baseLevel)
                                .tag(Optional(entry.slot))
                                .id(entry.slot)
                                // The row already selected jumps again when clicked
                                // (a selection that does not change reports nothing).
                                .simultaneousGesture(TapGesture().onEnded { jump(to: entry.slot) })
                        }
                    }
                    .listStyle(.sidebar)
                    // One surface with the sidebar above the list (behind the window buttons).
                    .scrollContentBackground(.hidden)
                    .onChange(of: model.activeSlot) { _, slot in
                        // No anchor: a row already in view stays where it is
                        // (the outline does not re-center on every heading);
                        // one out of view scrolls just into it.
                        guard slot != 0 else { return }
                        if reduceMotion {
                            proxy.scrollTo(slot)
                        } else {
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(slot) }
                        }
                    }
                }
            }
        }
    }

    /// Programmatic changes (from scrolling) only move the highlight; user clicks also scroll the document.
    private var selection: Binding<Int?> {
        Binding(
            get: { model.activeSlot == 0 ? nil : model.activeSlot },
            set: { slot in
                guard let slot else { return }
                jump(to: slot)
            }
        )
    }

    /// A click or a selection in the outline. The page reports the heading
    /// jumped to as the active one until the reader scrolls, so the highlight
    /// stays on the row clicked.
    private func jump(to slot: Int) {
        model.activeSlot = slot
        model.onSelectHeading?(slot)
    }
}

private struct TOCRow: View {
    let entry: TocEntry
    let minLevel: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.title.isEmpty ? "—" : entry.title)
                .font(entry.level <= minLevel ? .body.weight(.medium) : .body)
                .lineLimit(2)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if entry.tasks.total > 0 {
                Text("\(entry.tasks.done)/\(entry.tasks.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(entry.tasks.done == entry.tasks.total ? .secondary : .tertiary)
                    // VoiceOver: "2 of 5 tasks done", not "2 slash 5".
                    .accessibilityLabel(String(format: NSLocalizedString("%d of %d tasks done", comment: "Window subtitle"), entry.tasks.done, entry.tasks.total))
            }
        }
        // One element per row: the heading, then its tasks.
        .accessibilityElement(children: .combine)
        .padding(.leading, CGFloat(max(0, entry.level - minLevel)) * 12)
        .contentShape(Rectangle())
        .help(entry.title)
    }
}
