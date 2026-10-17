//
//  IntakeWatchSettingTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/11/2026.
//

import XCTest
@testable import M3

/// Turning "Automatically watch these folders" off used to abort the app:
/// saving a setting posts a defaults notification on the same stack while the
/// setting is still being written, and the Queue's observer read it back at
/// that moment (a simultaneous access). The observer now waits until the
/// save has finished.
final class IntakeWatchSettingTests: XCTestCase {

    func testSavingTheWatchSettingDoesNotAbort() {
        // Creating the shared Queue controller installs the observer.
        _ = QueueController.shared

        // Writing the current value again takes the same path as changing it
        // (the notification is posted either way) without changing anything.
        let current = MediaIntakePrefs.autoWatchIntakeFolder
        MediaIntakePrefs.autoWatchIntakeFolder = current

        // Let the observer run after the save.
        let observerRan = expectation(description: "observer ran")
        DispatchQueue.main.async { observerRan.fulfill() }
        wait(for: [observerRan], timeout: 5)

        XCTAssertEqual(MediaIntakePrefs.autoWatchIntakeFolder, current)
    }
}
