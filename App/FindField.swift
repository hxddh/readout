import AppKit

/// The toolbar's find field. At its end it shows which match is the current
/// one of how many ("3 of 12"), or that there is none.
final class FindField: NSSearchField {
    override class var cellClass: AnyClass? {
        get { FindFieldCell.self }
        set {}
    }

    /// What the field shows at its end ("": nothing).
    var count: String {
        get { (cell as? FindFieldCell)?.count ?? "" }
        set {
            guard let cell = cell as? FindFieldCell, newValue != cell.count else { return }
            let before = cell.countWidth
            cell.count = newValue
            // While editing, the field editor covers the text's part of the
            // field (laid out as editing began): it gives the count its room.
            if let clip = currentEditor()?.superview {
                clip.frame.size.width = max(0, clip.frame.width + before - cell.countWidth)
            }
            needsDisplay = true
        }
    }
}

final class FindFieldCell: NSSearchFieldCell {
    var count = ""

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular),
         .foregroundColor: NSColor.secondaryLabelColor]
    }

    var countWidth: CGFloat {
        count.isEmpty ? 0 : ceil((count as NSString).size(withAttributes: attributes).width) + 6
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        var r = super.searchTextRect(forBounds: rect)
        r.size.width = max(0, r.width - countWidth)
        return r
    }

    override func drawInterior(withFrame frame: NSRect, in view: NSView) {
        super.drawInterior(withFrame: frame, in: view)
        guard !count.isEmpty else { return }
        let text = searchTextRect(forBounds: frame)
        let size = (count as NSString).size(withAttributes: attributes)
        (count as NSString).draw(at: NSPoint(x: text.maxX + 3, y: frame.midY - size.height / 2), withAttributes: attributes)
    }
}
