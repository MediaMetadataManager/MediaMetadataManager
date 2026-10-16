import XCTest
@testable import M3

/// Which files added by hand to the Movies tab are sent to the TV Shows tab:
/// only those whose names carry an episode marker.
final class EpisodeRoutingTests: XCTestCase {

    private func isEpisode(_ name: String) -> Bool {
        return QueueController.isTVEpisodeFile(URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testEpisodeMarkersAreRecognised() {
        XCTAssertTrue(isEpisode("Sample Show S01E02.mkv"))
        XCTAssertTrue(isEpisode("Sample.Show.S10E114.1080p.WEB-DL.mkv"))
        XCTAssertTrue(isEpisode("Sample Show 1x02.mp4"))
    }

    func testMoviesAreNotTreatedAsEpisodes() {
        XCTAssertFalse(isEpisode("Sample Movie (2020).mkv"))
        XCTAssertFalse(isEpisode("Sample.Movie.2020.1080p.BluRay.mkv"))
        XCTAssertFalse(isEpisode("Sample Movie.mp4"))
    }
}
