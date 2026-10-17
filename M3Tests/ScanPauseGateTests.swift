//
//  ScanPauseGateTests.swift
//
//             Media Metadata Manager
//                       M3
//  Created by: Hans Hoffmeister on 10/16/2026.
//

import XCTest
@testable import M3

/// Pausing the Library scan: the scan thread waits between files and carries
/// on when resumed or cancelled.
final class ScanPauseGateTests: XCTestCase {

    func testNotPausedDoesNotWait() {
        let gate = ScanPauseGate()
        var waited = false
        gate.waitWhilePaused(stopping: { false }) { waited = true }
        XCTAssertFalse(waited)
        XCTAssertFalse(gate.isPaused)
    }

    func testPauseAndResumeChangeState() {
        let gate = ScanPauseGate()
        gate.pause()
        XCTAssertTrue(gate.isPaused)
        gate.resume()
        XCTAssertFalse(gate.isPaused)
    }

    func testPausedScanWaitsUntilResumed() {
        let gate = ScanPauseGate()
        gate.pause()
        let lock = NSLock()
        var carriedOn = false
        let started = expectation(description: "started waiting")
        let finished = expectation(description: "carried on")
        DispatchQueue.global().async {
            gate.waitWhilePaused(stopping: { false }) { started.fulfill() }
            lock.lock(); carriedOn = true; lock.unlock()
            finished.fulfill()
        }
        wait(for: [started], timeout: 2)
        // Still waiting a moment later: it has not carried on without a resume.
        Thread.sleep(forTimeInterval: 0.2)
        lock.lock(); let early = carriedOn; lock.unlock()
        XCTAssertFalse(early)
        gate.resume()
        wait(for: [finished], timeout: 2)
    }

    func testCancelWakesAPausedScan() {
        let gate = ScanPauseGate()
        gate.pause()
        let lock = NSLock()
        var cancelled = false
        let started = expectation(description: "started waiting")
        let finished = expectation(description: "woke up")
        DispatchQueue.global().async {
            gate.waitWhilePaused(stopping: { lock.lock(); defer { lock.unlock() }; return cancelled }) { started.fulfill() }
            finished.fulfill()
        }
        wait(for: [started], timeout: 2)
        lock.lock(); cancelled = true; lock.unlock()
        gate.resume()
        wait(for: [finished], timeout: 2)
    }

    func testAlreadyCancelledScanDoesNotWait() {
        let gate = ScanPauseGate()
        gate.pause()
        var waited = false
        gate.waitWhilePaused(stopping: { true }) { waited = true }
        XCTAssertFalse(waited)
    }
}
