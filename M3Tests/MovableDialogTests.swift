//
//  MovableDialogTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
@testable import M3

/// The review windows (naming, merge order, metadata) stay on top of the
/// app's other windows and open centred over the Queue.
final class MovableDialogTests: XCTestCase {

    private func window(_ width: CGFloat, _ height: CGFloat, at origin: NSPoint = .zero) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
                              styleMask: [.closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    func testDialogIsAboveOrdinaryWindows() {
        let parent = window(800, 600)
        let dialog = window(400, 300)
        XCTAssertEqual(dialog.level, .normal)
        MovableDialog.prepare(dialog, over: parent)
        XCTAssertEqual(dialog.level, .modalPanel)
        XCTAssertGreaterThan(dialog.level.rawValue, parent.level.rawValue)
    }

    func testDialogIsTitledAndMovable() {
        let dialog = window(400, 300)
        MovableDialog.prepare(dialog, over: window(800, 600))
        XCTAssertTrue(dialog.styleMask.contains(.titled))
        XCTAssertTrue(dialog.isMovableByWindowBackground)
    }

    func testDialogIsCentredOverTheParent() {
        let parent = window(800, 600, at: NSPoint(x: 100, y: 200))
        let dialog = window(400, 300)
        MovableDialog.prepare(dialog, over: parent)
        XCTAssertEqual(dialog.frame.midX, parent.frame.midX, accuracy: 1)
        XCTAssertEqual(dialog.frame.midY, parent.frame.midY, accuracy: 1)
    }
}
