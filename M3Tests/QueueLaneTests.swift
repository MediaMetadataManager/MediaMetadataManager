import XCTest
@testable import M3

/// The queues taking turns.
final class QueueLaneTests: XCTestCase {

    func testNonExclusiveNeverWaitsAndTakesNothing() {
        let lane = QueueLane()
        XCTAssertFalse(lane.enter(exclusive: false))
        XCTAssertFalse(lane.enter(exclusive: false))
        lane.leave(false)
    }

    func testExclusiveLaneCanBeTakenAgainAfterLeaving() {
        let lane = QueueLane()
        let first = lane.enter(exclusive: true)
        XCTAssertTrue(first)
        lane.leave(first)
        let second = lane.enter(exclusive: true)
        XCTAssertTrue(second)
        lane.leave(second)
    }

    func testSecondWorkerWaitsUntilTheFirstLeaves() {
        let lane = QueueLane()
        let first = lane.enter(exclusive: true)

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let took = lane.enter(exclusive: true)
            done.signal()
            lane.leave(took)
        }

        XCTAssertEqual(done.wait(timeout: .now() + 0.3), .timedOut, "the second worker must wait while the lane is taken")
        lane.leave(first)
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    }

    func testNonExclusiveWorkerRunsWhileTheLaneIsTaken() {
        let lane = QueueLane()
        let first = lane.enter(exclusive: true)
        XCTAssertFalse(lane.enter(exclusive: false))
        lane.leave(first)
    }
}
