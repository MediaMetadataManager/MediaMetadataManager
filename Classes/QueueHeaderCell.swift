//
//  QueueHeaderCell.swift
//  M3
//
//  The column headers of the Queue tables. They are drawn on a tinted
//  background with a thin line under them so they stand out from the rows
//  below, and show the sort arrow on the column the Queue is sorted by.
//

import Cocoa

final class QueueHeaderCell: NSTableHeaderCell {

    /// The sort key of the column this header belongs to; nil for a column
    /// that cannot be sorted.
    var sortKey: String?

    private func isDark(_ view: NSView) -> Bool {
        return view.effectiveAppearance.name.rawValue.lowercased().contains("dark")
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let dark = isDark(controlView)
        let background = dark ? NSColor(calibratedWhite: 0.30, alpha: 1) : NSColor(calibratedWhite: 0.86, alpha: 1)
        let line = dark ? NSColor(calibratedWhite: 0.12, alpha: 1) : NSColor(calibratedWhite: 0.68, alpha: 1)

        (isHighlighted ? background.blended(withFraction: 0.15, of: dark ? .white : .black) ?? background : background).setFill()
        cellFrame.fill()

        // A thin line under the header and a faint one between columns.
        line.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()
        line.withAlphaComponent(0.5).setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 3, width: 1, height: max(cellFrame.height - 6, 0)).fill()

        drawInterior(withFrame: cellFrame, in: controlView)

        if let key = sortKey,
           let table = (controlView as? NSTableHeaderView)?.tableView,
           let descriptor = table.sortDescriptors.first,
           descriptor.key == key {
            drawSortIndicator(withFrame: cellFrame, in: controlView, ascending: descriptor.ascending, priority: 0)
        }
    }
}
