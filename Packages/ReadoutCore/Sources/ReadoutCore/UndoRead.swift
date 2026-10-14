import Foundation

extension DocumentSession {
    /// Shows the document again marked against `baseline`, the way reopening
    /// the window with that baseline saved would: what Edit ▸ Undo Mark All
    /// as Read does with the baseline from before. Blocks get new slots; the
    /// patch is a full one (`reset`).
    public func reload(baseline: [BlockKey]) -> RenderPatch {
        load(ParsedDocument(blocks: blocks, title: title), baseline: baseline)
    }
}
